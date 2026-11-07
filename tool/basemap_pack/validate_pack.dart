/// basemap pack 校验器（docs/design/10-basemap-packs.md §6.3）。
///
/// 用**真实的** lib/core/schema.dart 常量去校验生成的 .db 包，防止 Python 侧
/// 手写 DDL 与 Dart 侧漂移（风险 R-05）。
///
/// 校验项：
///   1. PRAGMA user_version == kPackSchemaVersion
///   2. 4 张表的列名集合与 DDL 常量逐一比对（缺列/多列都报错）
///   3. 每张表的索引清单与 DDL 常量比对
///   4. import_bounds 只有一行且 id=1、region 等于文件名、计数与实际 COUNT(*) 一致
///   5. **几何完整性**：包内每条 way 的 node_ids 都必须在 import_nodes 里（badRefWays）
///   6. （--deep）抽样核对 way 的 bbox 与其 refs 实际坐标是否一致
///
/// 用法：
///   dart run tool/basemap_pack/validate_pack.dart assets/basemap
///   dart run tool/basemap_pack/validate_pack.dart assets/basemap --deep
///   dart run tool/basemap_pack/validate_pack.dart a.db b.db
///
/// 退出码：全部通过 0，任一失败 1。
library;

import 'dart:convert';
import 'dart:io';

import 'package:map/core/schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// 包格式版本 kPackSchemaVersion 现由 lib/core/schema.dart 统一提供（单一真理源），
// 不再在本文件重复定义。

final RegExp _reCreateTable = RegExp(
  r'CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?["`\[]?(\w+)["`\]]?\s*\(([\s\S]*)\)\s*;?\s*$',
  caseSensitive: false,
);
final RegExp _reCreateIndex = RegExp(
  r'CREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?["`\[]?(\w+)["`\]]?'
  r'\s+ON\s+["`\[]?(\w+)["`\]]?',
  caseSensitive: false,
);

const Set<String> _constraintKeywords = {
  'primary',
  'unique',
  'check',
  'foreign',
  'constraint',
};

/// 从 DDL 语句里解析出「表名 -> 列名集合」与「表名 -> 索引名集合」。
///
/// 只做够用的解析：按顶层逗号切列定义，跳过约束子句（PRIMARY KEY / UNIQUE / CHECK / FOREIGN）。
({Map<String, Set<String>> columns, Map<String, Set<String>> indexes}) parseDdl(
  List<String> statements,
) {
  final columns = <String, Set<String>>{};
  final indexes = <String, Set<String>>{};

  for (final stmt in statements) {
    final m = _reCreateTable.firstMatch(stmt);
    if (m != null) {
      final table = m.group(1)!;
      final body = m.group(2)!;
      final cols = <String>{};
      for (final part in _splitTopLevel(body)) {
        final t = part.trim();
        if (t.isEmpty) continue;
        final first = t.split(RegExp(r'\s+')).first.toLowerCase();
        if (_constraintKeywords.contains(first)) continue;
        cols.add(first);
      }
      columns[table] = cols;
      continue;
    }
    final mi = _reCreateIndex.firstMatch(stmt);
    if (mi != null) {
      indexes.putIfAbsent(mi.group(2)!, () => <String>{}).add(mi.group(1)!);
    }
  }
  return (columns: columns, indexes: indexes);
}

/// 按顶层（括号深度 0）逗号切分。
List<String> _splitTopLevel(String s) {
  final out = <String>[];
  final buf = StringBuffer();
  var depth = 0;
  for (final ch in s.split('')) {
    if (ch == '(') depth++;
    if (ch == ')') depth--;
    if (ch == ',' && depth == 0) {
      out.add(buf.toString());
      buf.clear();
      continue;
    }
    buf.write(ch);
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}

String _bytes(int n) => n >= 1048576
    ? '${(n / 1048576).toStringAsFixed(1)}MB'
    : '${(n / 1024).toStringAsFixed(0)}KB';

Future<void> main(List<String> args) async {
  final deep = args.contains('--deep');
  final targets = args.where((a) => !a.startsWith('--')).toList();
  if (targets.isEmpty) {
    stderr.writeln(
      '用法: dart run tool/basemap_pack/validate_pack.dart '
      '<目录或 .db 文件>... [--deep]',
    );
    exit(2);
  }

  // 期望结构：唯一真理源 = lib/core/schema.dart
  final expected = parseDdl(packDdlStatements);
  stdout.writeln('== 期望结构（来自 lib/core/schema.dart 的 packDdlStatements）==');
  for (final e in expected.columns.entries) {
    stdout.writeln(
      '  ${e.key}: ${e.value.length} 列  '
      '索引 ${(expected.indexes[e.key] ?? const {}).length} 个',
    );
  }
  stdout.writeln('  期望 user_version = $kPackSchemaVersion\n');

  final files = <String>[];
  for (final t in targets) {
    final type = FileSystemEntity.typeSync(t);
    if (type == FileSystemEntityType.directory) {
      for (final f in Directory(t).listSync().whereType<File>()) {
        final base = f.uri.pathSegments.last;
        if (base.endsWith('.db')) files.add(f.path);
      }
    } else if (type == FileSystemEntityType.file) {
      files.add(t);
    } else {
      stderr.writeln('跳过不存在: $t');
    }
  }
  files.sort();
  if (files.isEmpty) {
    stderr.writeln('没有找到任何 .db 包');
    exit(2);
  }

  // sqflite_common_ffi 会把**相对路径**解析到
  // .dart_tool/sqflite_common_ffi/databases/ 之下，因此必须显式传绝对路径，
  // 否则会报 "file .../.dart_tool/sqflite_common_ffi/databases/assets/... not found"。
  final absFiles = files.map((f) => File(f).absolute.path).toList();

  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  var failed = 0;
  var totNodes = 0, totWays = 0, totPois = 0, totBytes = 0;
  final problems = <String>[];

  void check(String pack, bool ok, String what, [String? detail]) {
    if (!ok) {
      problems.add('[$pack] $what${detail == null ? '' : ' — $detail'}');
    }
  }

  for (final path in absFiles) {
    final stem = path.split(Platform.pathSeparator).last;
    final key = stem.endsWith('.db')
        ? stem.substring(0, stem.length - 3)
        : stem;
    stdout.writeln('--- $key ---');

    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      // 1. user_version
      final uvRows = await db.rawQuery('PRAGMA user_version');
      final uv = (uvRows.first.values.first as num?)?.toInt() ?? 0;
      stdout.writeln('  user_version = $uv');
      check(
        key,
        uv == kPackSchemaVersion,
        'user_version 不符',
        '实际 $uv，期望 $kPackSchemaVersion',
      );

      // 2. 列 + 3. 索引
      for (final entry in expected.columns.entries) {
        final table = entry.key;
        final want = entry.value;

        final info = await db.rawQuery('PRAGMA table_info($table)');
        if (info.isEmpty) {
          check(key, false, '表缺失', table);
          continue;
        }
        final got = info
            .map((r) => (r['name'] as String).toLowerCase())
            .toSet();
        final missing = want.difference(got);
        final extra = got.difference(want);
        final ok = missing.isEmpty && extra.isEmpty;
        stdout.writeln(
          '  $table: ${got.length} 列'
          '${ok ? ' ✅' : ' ❌ 缺 $missing 多 $extra'}  '
          '索引 ${(await db.rawQuery('PRAGMA index_list($table)')).length}',
        );
        check(key, ok, '$table 列不匹配', '缺 $missing / 多 $extra');

        final wantIdx = expected.indexes[table] ?? const <String>{};
        final gotIdx = (await db.rawQuery('PRAGMA index_list($table)'))
            .map((r) => r['name'] as String)
            .where((n) => !n.startsWith('sqlite_autoindex'))
            .toSet();
        final mIdx = wantIdx.difference(gotIdx);
        final eIdx = gotIdx.difference(wantIdx);
        check(
          key,
          mIdx.isEmpty && eIdx.isEmpty,
          '$table 索引不匹配',
          '缺 $mIdx / 多 $eIdx',
        );
      }

      // 4. import_bounds 清单
      final bounds = await db.rawQuery('SELECT * FROM import_bounds');
      if (bounds.length != 1) {
        check(key, false, 'import_bounds 行数不为 1', '${bounds.length}');
      } else {
        final b = bounds.first;
        check(key, b['id'] == 1, 'import_bounds.id 不为 1', '${b['id']}');
        check(
          key,
          b['region'] == key,
          'region 与文件名不符',
          '${b['region']} vs $key',
        );
      }

      final n =
          (await db.rawQuery('SELECT COUNT(*) c FROM import_nodes')).first['c']
              as int;
      final w =
          (await db.rawQuery('SELECT COUNT(*) c FROM import_ways')).first['c']
              as int;
      final p =
          (await db.rawQuery('SELECT COUNT(*) c FROM import_pois')).first['c']
              as int;
      if (bounds.length == 1) {
        final b = bounds.first;
        check(
          key,
          b['node_count'] == n,
          'node_count 与实际不符',
          '${b['node_count']} vs $n',
        );
        check(
          key,
          b['way_count'] == w,
          'way_count 与实际不符',
          '${b['way_count']} vs $w',
        );
        check(
          key,
          b['poi_count'] == p,
          'poi_count 与实际不符',
          '${b['poi_count']} vs $p',
        );
      }

      // 5. 几何完整性（badRefWays）—— R-04 的关门条件
      final ids = <int>{};
      for (final r in await db.rawQuery('SELECT osm_id FROM import_nodes')) {
        ids.add((r['osm_id'] as num).toInt());
      }
      var bad = 0;
      final samples = <String>[];
      for (final r in await db.rawQuery(
        'SELECT osm_id, node_ids FROM import_ways',
      )) {
        final refs = (jsonDecode(r['node_ids'] as String) as List).map(
          (e) => (e as num).toInt(),
        );
        final miss = refs.where((x) => !ids.contains(x)).length;
        if (miss > 0) {
          bad++;
          if (samples.length < 3) {
            samples.add('way ${r['osm_id']}(缺 $miss)');
          }
        }
      }
      stdout.writeln(
        '  nodes=$n ways=$w pois=$p  '
        'badRefWays=$bad ${bad == 0 ? '✅' : '❌'}',
      );
      check(
        key,
        bad == 0,
        'badRefWays > 0',
        '$bad 条${samples.isEmpty ? '' : ' 例: ${samples.join(', ')}'}',
      );

      // 6. --deep：抽样核对 way bbox
      if (deep) {
        final rows = await db.rawQuery(
          'SELECT osm_id, node_ids, min_lat, min_lng, max_lat, max_lng '
          'FROM import_ways LIMIT 300',
        );
        final coord = <int, (double, double)>{};
        for (final r in await db.rawQuery(
          'SELECT osm_id, lat, lng FROM import_nodes',
        )) {
          coord[(r['osm_id'] as num).toInt()] = (
            (r['lat'] as num).toDouble(),
            (r['lng'] as num).toDouble(),
          );
        }
        var mismatch = 0;
        for (final r in rows) {
          final refs = (jsonDecode(r['node_ids'] as String) as List)
              .map((e) => (e as num).toInt())
              .where(coord.containsKey)
              .toList();
          if (refs.isEmpty) continue;
          final lats = refs.map((x) => coord[x]!.$1);
          final lngs = refs.map((x) => coord[x]!.$2);
          final ok =
              (lats.reduce((a, b) => a < b ? a : b) - (r['min_lat'] as num))
                      .abs() <
                  1e-9 &&
              (lats.reduce((a, b) => a > b ? a : b) - (r['max_lat'] as num))
                      .abs() <
                  1e-9 &&
              (lngs.reduce((a, b) => a < b ? a : b) - (r['min_lng'] as num))
                      .abs() <
                  1e-9 &&
              (lngs.reduce((a, b) => a > b ? a : b) - (r['max_lng'] as num))
                      .abs() <
                  1e-9;
          if (!ok) mismatch++;
        }
        stdout.writeln(
          '  --deep: 抽 ${rows.length} 条 way，bbox 不一致 $mismatch '
          '${mismatch == 0 ? '✅' : '❌'}',
        );
        check(key, mismatch == 0, 'way bbox 与 refs 坐标不一致', '$mismatch 条');
      }

      totNodes += n;
      totWays += w;
      totPois += p;
      totBytes += File(path).lengthSync();
    } finally {
      await db.close();
    }
  }

  stdout.writeln('\n== 汇总 ==');
  stdout.writeln(
    '  包 ${files.length} 个  节点 $totNodes  ways $totWays  '
    'POI $totPois  合计 ${_bytes(totBytes)}',
  );
  if (problems.isEmpty) {
    stdout.writeln('  ✅ 全部校验通过');
    exit(0);
  }
  stdout.writeln('  ❌ ${problems.length} 项失败：');
  for (final p in problems) {
    stdout.writeln('     - $p');
  }
  exit(1);
}
