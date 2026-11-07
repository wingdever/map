/// 数据访问仓库（docs/design/02-architecture.md §2.2 storage）
///
/// sqflite_common_ffi 封装：schema v1 用户层（CRUD/事务/软删除）+ v2 OSM 导入层（07 章）。
/// 纯数据层，不依赖 UI；编辑状态机（core/area_draft、core/gate_snap）在上层调用。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/export.dart';
import '../core/floor_set.dart';
import '../core/geometry.dart';
import '../core/import.dart';
import '../core/line_edit.dart';
import '../core/merge.dart';
import '../core/models.dart';
import '../core/osmapp.dart';
import '../core/polyline.dart';
import '../core/ring.dart';
import '../core/schema.dart';
import '../core/shape_convert.dart';
import 'basemap_packs.dart';
import 'db_factory.dart';

/// 常用 where 片段。
const String _notDeleted = 'deleted_at IS NULL';

/// 批量入库单批提交行数。设计目标：单批 sql 参数量可控，避免内存峰值。
///
/// 经验值：2000 行/批 ≈ 4-6MB Node 临时对象 / Batch 内部缓冲,
/// 远低于 256MB 堆上限。结合 NDK 端 fragment 化 GC，能稳 OOM-safe。
const int kBatchSize = 2000;

double? _minOr(double? a, double b) => a == null ? b : (a < b ? a : b);
double? _maxOr(double? a, double b) => a == null ? b : (a > b ? a : b);

/// .osmapp 字符串源（[importOsmAppStrings] 入口）。
class OsmAppStringSource {
  const OsmAppStringSource({required this.name, required this.source});

  /// 例如 'corridor'，用于 import_bounds.region 拼接。
  final String name;

  /// 完整的 .osmapp UTF-8 JSON 文本。
  final String source;
}

/// [importOsmAppStrings] 内部使用的解析结果（仅保留 metadata，
/// nodes / ways / pois 在流式写入路径上以列表形式遍历后即丢）。
class _ParsedOsmApp {
  const _ParsedOsmApp({required this.name, required this.file});
  final String name;
  final OsmAppFile file;
}

class AppRepository {
  AppRepository._(this._db, this._registry);

  final Database _db;

  /// 底图包清单（扫描自包目录；不含已挂载状态）。
  final PackRegistry _registry;

  /// ATTACH/DETACH 生命周期（见 lib/data/basemap_packs.dart）。
  final PackAttachManager _attach = PackAttachManager();

  /// 底图包清单（设置页 / 测试观察用）。
  PackRegistry get packs => _registry;

  /// 当前已挂载的底图包 key。
  Set<String> get attachedPackKeys => _attach.attachedKeys;

  /// 打开（或创建）数据库并执行 schema 初始化/迁移（v1 → v2 → v3）。
  ///
  /// 显式取 [resolveDatabaseFactory]，不依赖全局 `databaseFactory` +
  /// 顶层 `openDatabase()`，这样本方法不受 main() 的初始化顺序影响。
  /// 引擎与落点的收口见 lib/data/db_factory.dart。
  ///
  /// [basemapDir] 为底图包目录；null 时用 [resolveBasemapDir]（Android 走
  /// 外部应用专属目录，可直接 adb push）。打开后立即扫描一次包清单。
  ///
  /// **注意**：这里**不**预挂载任何包 —— 包按视口在 [queryImportLayer] 里
  /// 懒挂载，避免为用不到的区域白开文件句柄。
  static Future<AppRepository> open(
    String path, {
    Directory? basemapDir,
  }) async {
    final factory = resolveDatabaseFactory();
    await _backupBeforeV4(path, factory);
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    final registry = PackRegistry(
      directory: basemapDir ?? await resolveBasemapDir(),
      factory: factory,
    );
    await registry.scan();
    return AppRepository._(db, registry);
  }

  /// v3 → v4 迁移前的**原库文件备份**（12 章 §3.4）。
  ///
  /// 为什么值得单独做：v4 会在事务里 DROP + 重建 `areas` 与 `lines` 两张表。
  /// 事务本身保证失败回滚，但「回滚了但代码有 bug」和「真的把表搞坏了」在
  /// 用户眼里没区别 —— 而这是用户一脚一脚跑出来的数据，没有第二份。
  /// 所以升级前先把整个 .db 复制一份，成本是几百 KB 的磁盘。
  ///
  /// 只在「文件已存在且 user_version < 4」时做；完成后由 `.pre_v4.bak` 的存在
  /// 保证只做一次（不会每次启动都复制）。
  static Future<void> _backupBeforeV4(
    String path,
    DatabaseFactory factory,
  ) async {
    try {
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() == 0) return;
      final backup = File('$path.pre_v4.bak');
      if (backup.existsSync()) return; // 已经备份过

      // 只读开一次拿 user_version（不动数据、不触发迁移）
      final probe = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      int version;
      try {
        final rows = await probe.rawQuery('PRAGMA user_version');
        version = (rows.first.values.first as num?)?.toInt() ?? 0;
      } finally {
        await probe.close();
      }
      if (version >= 4) return; // 已是 v4，不需要备份

      await file.copy(backup.path);
    } catch (_) {
      // 备份失败不阻断启动：迁移事务本身仍然是原子的。
    }
  }

  /// 内存库（测试用）。需要 sqflite_common_ffi 的 factory 注入。
  ///
  /// [basemapDir] 默认 null = 无包目录；要测跨包查询就传一个放着真实 pack
  /// 的临时目录。
  static Future<AppRepository> openInMemory(
    DatabaseFactory factory, {
    Directory? basemapDir,
  }) async {
    final db = await factory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    final registry = PackRegistry(directory: basemapDir, factory: factory);
    await registry.scan();
    return AppRepository._(db, registry);
  }

  /// 全新库：**只有用户层六表 + schema_meta**（v4 多了 area_lines）。
  static Future<void> _onCreate(Database db, int version) async {
    for (final stmt in schemaStatements) {
      await db.execute(stmt);
    }
    await db.execute(schemaMetaTable);
    await db.insert('schema_meta', {
      'key': 'schema_version',
      'value': '$schemaVersion',
    });
  }

  /// 既有库升级。
  ///
  /// - v1 → v2：曾把导入层四表加进 user.db（历史路径）；
  /// - 任意 → v3：把导入层四表从 user.db **删除**，数据改由 basemap pack 提供；
  /// - **v3 → v4**（12 章）：`boundary_type` 从 areas 搬到 lines、areas 换成
  ///   `area_type`、`lines.area_id` 换成多对多表 `area_lines`、points/lines 加 `name`。
  ///
  /// 各步都幂等或带存在性判断，所以从 v1 直接跳到 v4 也安全。
  static Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    // schema_meta 在极老的库里可能不存在（v1 建库时就有，但防御一下）
    await db.execute(schemaMetaTable);

    if (oldV < 3) {
      for (final stmt in userV3DropStatements) {
        await db.execute(stmt);
      }
    }
    if (oldV < 4) {
      for (final stmt in userV4Statements) {
        await db.execute(stmt);
      }
    }
    if (oldV < 5) {
      for (final stmt in userV5Statements) {
        await db.execute(stmt);
      }
      // 表结构搬完了，但"位置"还没搬：老的权重排布要换算成具体坐标。
      await _backfillLineFeatureCenters(db);
    }
    if (oldV < 6) {
      for (final stmt in userV6Statements) {
        await db.execute(stmt);
      }
    }
    if (oldV < 7) {
      for (final stmt in userV7Statements) {
        await db.execute(stmt);
      }
    }
    if (oldV < 8) {
      for (final stmt in userV8Statements) {
        await db.execute(stmt);
      }
    }
    if (oldV < 9) {
      // v8 → v9（18 章）：线支持折线。只建一张空的拐点表 ——
      // 老线没有拐点，而"没有拐点"的语义正好就是它们本来的样子（两点直线）。
      for (final stmt in userV9Statements) {
        await db.execute(stmt);
      }
    }
    if (oldV < 10) {
      // v9 → v10（19 章）：路线加「路宽」。一条 ADD COLUMN，老数据零搬运。
      for (final stmt in userV10Statements) {
        await db.execute(stmt);
      }
    }
    if (oldV < 11) {
      // v10 → v11（22 章）：点加「处理状态」。老点一律"未处理"（用户口述的默认）。
      for (final stmt in userV11Statements) {
        await db.execute(stmt);
      }
    }

    // ---------------------------------------------------------------------
    // v11 → v12（23 章）：**故意不在这里自动迁移**。
    //
    // 策略与给用户看的原因都在 `core/schema.dart` 的 [autoUpgradeBlockReason] 里
    // （放在 core 是为了它能被纯 Dart 脚本验证 —— `data/` 引了 path_provider，
    // 脚本 import 不进来）。这里只负责"抛错中止"这一件事。
    //
    // 抛错会让整个 onUpgrade 事务回滚：库保持原样、一个字节都不变 ——
    // 这是唯一安全的失败方式（旧代码在这里静默放行，见上面那段注释的警告）。
    // ---------------------------------------------------------------------
    final blocked = autoUpgradeBlockReason(oldV);
    if (blocked != null) throw StateError(blocked);

    await db.insert('schema_meta', {
      'key': 'schema_version',
      'value': '$newV',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// v4 → v5：把老「门牌」按权重排布算出来的位置，**反算成具体中心坐标**。
  ///
  /// 老模型的位置是"算"出来的：
  ///     t_i = (Σ_{j<i} w_j + w_i/2) / Σw
  /// 新模型要求每个要素自带中心坐标。如果不做这一步，用户升级后
  /// **整条街的门牌会全部挤到线的起点**（因为 center 都是 NULL）。
  ///
  /// 所以这里用**同一套算法**把 t 反算成经纬度，位置与升级前逐个对得上。
  ///
  /// 之所以放在 Dart 里而不是 SQL 窗口函数里：这段逻辑要长期和
  /// `core/line_feature_layout.dart` 保持一致，写在 SQL 里没人看得懂，
  /// 而且一旦算法调整两边就对不上了。
  static Future<void> _backfillLineFeatureCenters(Database db) async {
    final rows = await db.query(
      'entities',
      columns: ['id', 'line_id', 'line_index', 'width'],
      where: 'line_id IS NOT NULL AND center_lat IS NULL',
      orderBy: 'line_id ASC, line_index ASC, id ASC',
    );
    if (rows.isEmpty) return;

    // 按线分组
    final byLine = <int, List<Map<String, Object?>>>{};
    for (final r in rows) {
      byLine.putIfAbsent(r['line_id'] as int, () => []).add(r);
    }

    for (final entry in byLine.entries) {
      final lineId = entry.key;
      final lineRows = await db.query(
        'lines',
        columns: ['start_point_id', 'end_point_id'],
        where: 'id = ?',
        whereArgs: [lineId],
        limit: 1,
      );
      if (lineRows.isEmpty) continue;
      final startId = lineRows.first['start_point_id'] as int;
      final endId = lineRows.first['end_point_id'] as int;
      final pts = await db.query(
        'points',
        columns: ['id', 'lat', 'lng'],
        where: 'id IN (?, ?)',
        whereArgs: [startId, endId],
      );
      final byId = {for (final p in pts) p['id'] as int: p};
      final a = byId[startId];
      final b = byId[endId];
      if (a == null || b == null) continue;
      final aLat = (a['lat'] as num).toDouble();
      final aLng = (a['lng'] as num).toDouble();
      final bLat = (b['lat'] as num).toDouble();
      final bLng = (b['lng'] as num).toDouble();

      double weightOf(Map<String, Object?> r) {
        final w = (r['width'] as num?)?.toDouble();
        return (w == null || w <= 0) ? 1.0 : w;
      }

      var total = 0.0;
      for (final r in entry.value) {
        total += weightOf(r);
      }
      if (total <= 0) total = entry.value.length.toDouble();

      var cursor = 0.0;
      for (final r in entry.value) {
        final w = weightOf(r);
        final t = ((cursor + w / 2) / total).clamp(0.0, 1.0);
        cursor += w;
        await db.update(
          'entities',
          {
            'center_lat': aLat + (bLat - aLat) * t,
            'center_lng': aLng + (bLng - aLng) * t,
          },
          where: 'id = ?',
          whereArgs: [r['id']],
        );
      }
    }
  }

  /// 关闭连接。先卸载全部底图包（避免文件句柄残留），再关库。
  Future<void> close() async {
    try {
      await _attach.detachAll(_db);
    } catch (_) {
      // 连接已断时忽略
    }
    await _registry.scan(); // 刷新清单，便于测试断言
    await _db.close();
  }

  /// 重新扫描底图包目录。
  ///
  /// 用于：设置页「重新扫描」按钮；App 运行期间 adb push 了新包之后。
  Future<void> rescanPacks() => _registry.scan();

  // ===========================================================================
  // 通用：把"域"参数化到表名
  //
  // v12 的物理形态是**三个域各一套表**，但代码只有一份 —— 靠的就是
  // `MapDomain.pointsTable` 这类 getter（定义在 core/models.dart）。
  // 所以下面所有方法都吃一个 [MapDomain]，而不是写三遍。
  // ===========================================================================

  /// 三个域（导出/备份/全局清理用）。
  static const List<MapDomain> allDomains = MapDomain.values;

  /// 有封闭图形的域（路网域没有区域）。`<域>_areas` / `<域>_area_lines` 用它过滤。
  static List<MapDomain> get areaDomains =>
      [for (final d in MapDomain.values) if (d.hasAreas) d];

  // -------------------------------------------------------------------------
  // 点：几何点（`<域>_points`）
  //
  // 它就是"一条线的点"（端点与拐点都是它）。**没有名字**（D9）——
  // 要给位置起名字用世界域的要素（门 / world_entities / world_marks）。
  // -------------------------------------------------------------------------

  Future<int> insertPoint(PointRow p) =>
      _db.insert(p.domain.pointsTable, p.toDb());

  Future<void> updatePoint(PointRow p) async {
    await _db.update(
      p.domain.pointsTable,
      {...p.toDb(), 'updated_at': nowMs},
      where: 'id = ?',
      whereArgs: [p.id],
    );
  }

  Future<List<PointRow>> listPoints(
    MapDomain domain, {
    bool includeDeleted = false,
  }) async {
    final rows = await _db.query(
      domain.pointsTable,
      where: includeDeleted ? null : _notDeleted,
      orderBy: 'id ASC',
    );
    return rows.map((r) => PointRow.fromDb(r, domain: domain)).toList();
  }

  Future<List<PointRow>> listPointsByIds(
    MapDomain domain,
    Set<int> ids,
  ) async {
    if (ids.isEmpty) return const [];
    final ph = List.filled(ids.length, '?').join(',');
    final rows = await _db.query(
      domain.pointsTable,
      where: 'id IN ($ph) AND $_notDeleted',
      whereArgs: ids.toList(),
    );
    return rows.map((r) => PointRow.fromDb(r, domain: domain)).toList();
  }

  /// 每个域的点坐标表：`域 → {点 id → 坐标}`。
  ///
  /// 🔴 **为什么按域分开，而不是一张大 map**：三个域的点表**各有各的自增 id**
  /// （`way_points.id = 8` 与 `world_points.id = 8` 是毫不相干的两个点）。
  /// 合成一张 `Map<int, GeoPoint>` 会静默串味 —— 画一条线时查到的是另一个域的点。
  /// 调用方按 `line.domain` 取对应那张表（`core/polyline.dart` 的签名因此不用改）。
  Future<Map<MapDomain, Map<int, GeoPoint>>> pointCoordsByDomain({
    bool includeDeleted = false,
  }) async {
    final out = <MapDomain, Map<int, GeoPoint>>{};
    for (final d in MapDomain.values) {
      final rows = await _db.query(
        d.pointsTable,
        columns: ['id', 'lat', 'lng'],
        where: includeDeleted ? null : _notDeleted,
      );
      out[d] = {
        for (final r in rows)
          r['id'] as int: GeoPoint(
            (r['lat'] as num).toDouble(),
            (r['lng'] as num).toDouble(),
          ),
      };
    }
    return out;
  }

  /// 这个点参与构成多少条线（端点**或拐点**）。点面板的"连着 N 条线"用它。
  Future<int> countLinesUsingPoint(MapDomain domain, int pointId) async {
    final rows = await _db.rawQuery(
      '''
      SELECT COUNT(DISTINCT l.id) AS n FROM ${domain.linesTable} l
      LEFT JOIN ${domain.lineBendsTable} b ON b.line_id = l.id
      WHERE l.deleted_at IS NULL
        AND (l.start_point_id = ? OR l.end_point_id = ? OR b.point_id = ?)''',
      [pointId, pointId, pointId],
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  /// 本域里**没有被任何线引用**的点（"清理孤立点"用，D12 手动触发）。
  ///
  /// ⚠️ 不要自动删它们：实测真库那 147 个孤立点里可能正有"连线前先散的点"
  /// （红线：连线只吸附已有点，所以先散点再连线是**正常工作流**）。
  Future<List<PointRow>> listOrphanPoints(MapDomain domain) async {
    final rows = await _db.rawQuery(
      '''
      SELECT p.* FROM ${domain.pointsTable} p
      WHERE p.deleted_at IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM ${domain.linesTable} l
           WHERE l.deleted_at IS NULL
             AND (l.start_point_id = p.id OR l.end_point_id = p.id))
        AND NOT EXISTS (
          SELECT 1 FROM ${domain.lineBendsTable} b WHERE b.point_id = p.id)
      ORDER BY p.id ASC''',
    );
    return rows.map((r) => PointRow.fromDb(r, domain: domain)).toList();
  }

  /// **删除一个点**（点面板的"删除"）。
  ///
  /// 与"从某条线上去掉一个点"是**两个动作**（D10）：
  /// - 这里的语义是"这个世界上的那个位置没了"，所以要**反查所有引用它的线**；
  /// - 拐点被摘掉只是那条线少个弯（仍然画得出来）；
  /// - **端点被摘掉会让整条线缺一个点**（`polylineOf` 返回 null → 整条线不画）。
  ///   那正是线 3/4 今天看不见的原因，所以默认**拒绝**，
  ///   要强制就显式传 `allowEndpointBreak: true`（UI 必须先告诉用户"会影响 N 条线"）。
  Future<PointDeleteReport> softDeletePoint(
    PointRow p, {
    bool allowEndpointBreak = false,
  }) async {
    final domain = p.domain;
    final id = p.id!;
    return _db.transaction((txn) async {
      final bendRows = await txn.query(
        domain.lineBendsTable,
        columns: ['line_id'],
        where: 'point_id = ?',
        whereArgs: [id],
      );
      final bendLines = {for (final r in bendRows) r['line_id'] as int};

      final endRows = await txn.query(
        domain.linesTable,
        columns: ['id'],
        where: 'deleted_at IS NULL AND (start_point_id = ? OR end_point_id = ?)',
        whereArgs: [id, id],
      );
      final endpointLines = {for (final r in endRows) r['id'] as int};

      if (endpointLines.isNotEmpty && !allowEndpointBreak) {
        throw StateError(
          '这个点还是 ${endpointLines.length} 条线的端点，删掉它那些线会缺一个点（整条线不画）。'
          '先把那些线的端点改到别的点上，或者确认要一起放弃它们。',
        );
      }

      final removed = await txn.delete(
        domain.lineBendsTable,
        where: 'point_id = ?',
        whereArgs: [id],
      );
      await txn.update(
        domain.pointsTable,
        {'deleted_at': nowMs},
        where: 'id = ?',
        whereArgs: [id],
      );
      return PointDeleteReport(
        domain: domain,
        bendOnlyLines: [for (final l in bendLines) if (!endpointLines.contains(l)) l],
        endpointLines: endpointLines.toList(),
        removedBends: removed,
      );
    });
  }

  /// 手动清理孤立点（D12）。返回删掉的个数。
  Future<int> purgeOrphanPoints(MapDomain domain) async {
    final orphans = await listOrphanPoints(domain);
    if (orphans.isEmpty) return 0;
    await _db.transaction((txn) async {
      for (final p in orphans) {
        await txn.update(
          domain.pointsTable,
          {'deleted_at': nowMs},
          where: 'id = ?',
          whereArgs: [p.id],
        );
      }
    });
    return orphans.length;
  }

  // -------------------------------------------------------------------------
  // 线：`<域>_lines` + 拐点链 `<域>_line_bends`
  //
  // **端点是两列、拐点是一条链**（D4 + D13）：
  //   start_point_id → b1 → b2 → … → bn → end_point_id
  // 链上每行记的是"我的前驱"，所以插入/删除是 O(1) 指针操作。
  // 🔴 链的语句顺序**不能反**（见下面各方法的注释）。
  // -------------------------------------------------------------------------

  /// 插入一条线（**含它的拐点链**，一个事务）。
  Future<int> insertLine(LineRow l) => _db.transaction((txn) async {
    final id = await txn.insert(l.domain.linesTable, l.toDb());
    await _writeChain(txn, l.domain, id, l.pointIds);
    return id;
  });

  /// 只更新 `<域>_lines` 自己的列。**不动形状** —— 形状走 [setLineShape] 一族。
  ///
  /// 分开是因为"改名字"和"改形状"是完全不同的意图：混在一起的话，
  /// 一次改名就可能把没读全的拐点列表清空。
  Future<void> updateLine(LineRow l) async {
    await _db.update(
      l.domain.linesTable,
      {...l.toDb(), 'updated_at': nowMs},
      where: 'id = ?',
      whereArgs: [l.id],
    );
  }

  /// 软删除一条线：摘掉它的拐点链与区域关联，并软删挂在它上面的门与世界要素。
  ///
  /// 链行与关联行都是**物理删除**：它们的"存在"就是事实本身（这条线在哪拐弯、
  /// 属于哪个区域），留个墓碑只会让走链与组环多一层过滤。
  Future<void> softDeleteLine(LineRow l) async {
    final domain = l.domain;
    await _db.transaction((txn) async {
      await txn.update(
        domain.linesTable,
        {'deleted_at': nowMs},
        where: 'id = ?',
        whereArgs: [l.id],
      );
      await txn.delete(
        domain.lineBendsTable,
        where: 'line_id = ?',
        whereArgs: [l.id],
      );
      if (domain.hasAreas) {
        await txn.delete(
          domain.areaLinesTable,
          where: 'line_id = ?',
          whereArgs: [l.id],
        );
      }
      // 门与世界要素都锚定在**世界图的界线**上（D21），所以只有世界域有线挂件。
      if (domain == MapDomain.world) {
        await txn.update(
          'world_gates',
          {'deleted_at': nowMs},
          where: 'line_id = ?',
          whereArgs: [l.id],
        );
        await txn.update(
          'world_entities',
          {'deleted_at': nowMs},
          where: 'line_id = ?',
          whereArgs: [l.id],
        );
      }
    });
  }

  Future<List<LineRow>> listLines(
    MapDomain domain, {
    bool includeDeleted = false,
  }) async {
    final rows = await _db.query(
      domain.linesTable,
      where: includeDeleted ? null : _notDeleted,
      orderBy: 'id ASC',
    );
    return _attachLineBends(domain, rows);
  }

  /// 三个域的线一起读（渲染要同时看到界线、路线、行政线）。
  Future<List<LineRow>> listAllLines({bool includeDeleted = false}) async {
    final out = <LineRow>[];
    for (final d in MapDomain.values) {
      out.addAll(await listLines(d, includeDeleted: includeDeleted));
    }
    return out;
  }

  Future<List<LineRow>> listLinesByIds(
    MapDomain domain,
    List<int> ids,
  ) async {
    if (ids.isEmpty) return const [];
    final ph = List.filled(ids.length, '?').join(',');
    final rows = await _db.query(
      domain.linesTable,
      where: 'id IN ($ph) AND $_notDeleted',
      whereArgs: ids,
    );
    return _attachLineBends(domain, rows);
  }

  /// 把线行读成 [LineRow]，并**走链**补上拐点。
  ///
  /// 用**一条**链查询填所有人（地图一次要读几百条线，N+1 在这里是能感觉到的卡顿）。
  ///
  /// 🔴 走链由 `core/line_edit.dart` 的 [assembleLineChain] 完成 —— 它**会把终点接上**，
  /// 并带**步数上限**保护（链坏成环时死循环）。别在这里自己写 while。
  Future<List<LineRow>> _attachLineBends(
    MapDomain domain,
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return const [];
    final lineIds = [
      for (final r in rows)
        if (r['id'] != null) r['id'] as int,
    ];
    final beforeOf = <int, Map<int, int>>{};
    if (lineIds.isNotEmpty) {
      final ph = List.filled(lineIds.length, '?').join(',');
      final bendRows = await _db.query(
        domain.lineBendsTable,
        columns: ['line_id', 'point_id', 'before_point_id'],
        where: 'line_id IN ($ph)',
        whereArgs: lineIds,
      );
      for (final b in bendRows) {
        beforeOf
            .putIfAbsent(b['line_id'] as int, () => <int, int>{})[b['point_id']
            as int] = b['before_point_id'] as int;
      }
    }
    return [
      for (final r in rows)
        LineRow.fromDb(
          r,
          domain: domain,
          bendPointIds: _bendIdsOf(
            domain,
            r['id'] as int?,
            r['start_point_id'] as int,
            r['end_point_id'] as int,
            beforeOf,
          ),
        ),
    ];
  }

  /// 走一次链，拿到"中间拐点"的 id 列表（起点与终点不在里面）。
  static List<int> _bendIdsOf(
    MapDomain domain,
    int? lineId,
    int startPointId,
    int endPointId,
    Map<int, Map<int, int>> beforeOf,
  ) {
    if (lineId == null) return const [];
    final chain = assembleLineChain(
      startPointId: startPointId,
      endPointId: endPointId,
      beforeOf: beforeOf[lineId] ?? const {},
    );
    if (!chain.ok || chain.pointIds.length < 2) {
      // 链坏了：返回空（= 画成两点直线）而不是崩掉。
      // 真正的坏链由 tool/checks 的自检脚本与 UI 的"顶点数据不全"提示兜住。
      return const [];
    }
    return chain.pointIds.sublist(1, chain.pointIds.length - 1);
  }

  // ---- 形状：整体重写 + 局部指针操作 ----------------------------------------

  /// **整体重写一条线的形状**（两列 + 全删全建链，一个事务）。
  ///
  /// 用于反转线、两线合并、拆线，以及任何"在内存里把点序列改完再写回"的动作。
  /// 局部的小改动用下面那几个指针操作更省（也更能表达意图）。
  Future<void> setLineShape(LineRow l, List<int> pointIds) =>
      _db.transaction((txn) async {
        if (pointIds.length < 2) {
          throw ArgumentError('一条线至少要 2 个点（现在是 ${pointIds.length} 个）');
        }
        await txn.update(
          l.domain.linesTable,
          {
            'start_point_id': pointIds.first,
            'end_point_id': pointIds.last,
            'updated_at': nowMs,
          },
          where: 'id = ?',
          whereArgs: [l.id],
        );
        await txn.delete(
          l.domain.lineBendsTable,
          where: 'line_id = ?',
          whereArgs: [l.id],
        );
        await _writeChain(txn, l.domain, l.id!, pointIds);
      });

  /// 把点序列写成链（**只写中间拐点**：起点是链头、终点是链尾，都不在表里）。
  static Future<void> _writeChain(
    DatabaseExecutor txn,
    MapDomain domain,
    int lineId,
    List<int> pointIds,
  ) async {
    final beforeOf = beforeOfFromPoints(pointIds);
    for (final e in beforeOf.entries) {
      await txn.insert(domain.lineBendsTable, {
        'line_id': lineId,
        'point_id': e.key,
        'before_point_id': e.value,
      });
    }
  }

  /// 在 [anchorPointId] **之后**插入一个拐点（O(1)，两步）。
  ///
  /// 🔴 **顺序不能反**：`UNIQUE (line_id, before_point_id)` 是逐行立即检查的，
  /// 先插新行会让"新行"和"旧后继"同时持有 `before = x` → 直接撞唯一约束。
  /// 所以必须**先改后继、再插新行**。
  ///
  /// [anchorPointId] 可以是起点（插到最前面）或某个拐点；**不能是终点**。
  Future<void> insertBendAfter(
    MapDomain domain,
    int lineId, {
    required int anchorPointId,
    required int newPointId,
  }) => _db.transaction((txn) async {
    await txn.update(
      domain.lineBendsTable,
      {'before_point_id': newPointId},
      where: 'line_id = ? AND before_point_id = ?',
      whereArgs: [lineId, anchorPointId],
    );
    await txn.insert(domain.lineBendsTable, {
      'line_id': lineId,
      'point_id': newPointId,
      'before_point_id': anchorPointId,
    });
  });

  /// 从线上摘掉一个拐点（O(1)，三步）。
  ///
  /// 🔴 **顺序不能反**：必须**先删自己、再把后继接上**（先接的话，
  /// 后继与被删行会同时持有同一个 `before` → 撞唯一约束）。
  Future<void> removeBend(
    MapDomain domain,
    int lineId,
    int pointId,
  ) => _db.transaction((txn) async {
    final rows = await txn.query(
      domain.lineBendsTable,
      columns: ['before_point_id'],
      where: 'line_id = ? AND point_id = ?',
      whereArgs: [lineId, pointId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final before = rows.first['before_point_id'] as int;
    await txn.delete(
      domain.lineBendsTable,
      where: 'line_id = ? AND point_id = ?',
      whereArgs: [lineId, pointId],
    );
    await txn.update(
      domain.lineBendsTable,
      {'before_point_id': before},
      where: 'line_id = ? AND before_point_id = ?',
      whereArgs: [lineId, pointId],
    );
  });

  /// **添加端点**（头部延伸）：新的点成为起点，旧起点降级成第一个拐点。
  ///
  /// 两步，而且**不需要动任何别的拐点** —— 它们的前驱还是旧起点（现在它是拐点了）。
  Future<void> extendStart(
    MapDomain domain,
    int lineId,
    int newStartPointId,
  ) => _db.transaction((txn) async {
    final rows = await txn.query(
      domain.linesTable,
      columns: ['start_point_id'],
      where: 'id = ?',
      whereArgs: [lineId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('线 $lineId 不存在');
    final oldStart = rows.first['start_point_id'] as int;
    await txn.insert(domain.lineBendsTable, {
      'line_id': lineId,
      'point_id': oldStart,
      'before_point_id': newStartPointId,
    });
    await txn.update(
      domain.linesTable,
      {'start_point_id': newStartPointId, 'updated_at': nowMs},
      where: 'id = ?',
      whereArgs: [lineId],
    );
  });

  /// **删除起点**：让相邻的拐点顶上（D11）。没有拐点可顶时抛错 ——
  /// 那说明这条线只剩两个端点，要删就删整条线。
  Future<void> removeStart(MapDomain domain, int lineId) =>
      _db.transaction((txn) async {
        final rows = await txn.query(
          domain.lineBendsTable,
          columns: ['point_id'],
          where: 'line_id = ? AND before_point_id = '
              '(SELECT start_point_id FROM ${domain.linesTable} WHERE id = ?)',
          whereArgs: [lineId, lineId],
          limit: 1,
        );
        if (rows.isEmpty) {
          throw StateError('这条线只剩两个端点了，要删就删整条线');
        }
        final newStart = rows.first['point_id'] as int;
        // 先删链头那行，再把起点挪过去（顺序无关，但这样中途失败更安全）
        await txn.delete(
          domain.lineBendsTable,
          where: 'line_id = ? AND point_id = ?',
          whereArgs: [lineId, newStart],
        );
        await txn.update(
          domain.linesTable,
          {'start_point_id': newStart, 'updated_at': nowMs},
          where: 'id = ?',
          whereArgs: [lineId],
        );
      });

  /// **重设起点**：接到另一个已有点上。
  ///
  /// 两步：改列 + 把旧起点的后继改成新起点。
  /// ⚠️ 业务键含端点坐标，所以这会**改变这条线的身份**（备份导入时会被当成另一条线）。
  Future<void> resetStart(
    MapDomain domain,
    int lineId,
    int newStartPointId,
  ) => _db.transaction((txn) async {
    final rows = await txn.query(
      domain.linesTable,
      columns: ['start_point_id'],
      where: 'id = ?',
      whereArgs: [lineId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('线 $lineId 不存在');
    final oldStart = rows.first['start_point_id'] as int;
    await txn.update(
      domain.linesTable,
      {'start_point_id': newStartPointId, 'updated_at': nowMs},
      where: 'id = ?',
      whereArgs: [lineId],
    );
    await txn.update(
      domain.lineBendsTable,
      {'before_point_id': newStartPointId},
      where: 'line_id = ? AND before_point_id = ?',
      whereArgs: [lineId, oldStart],
    );
  });

  /// **重设终点**：终点是链尾、不在链上，所以**只改一列**，链一个字节都不动。
  Future<void> resetEnd(
    MapDomain domain,
    int lineId,
    int newEndPointId,
  ) async {
    await _db.update(
      domain.linesTable,
      {'end_point_id': newEndPointId, 'updated_at': nowMs},
      where: 'id = ?',
      whereArgs: [lineId],
    );
  }

  // -------------------------------------------------------------------------
  // 区域：`<域>_areas` + `<域>_area_lines`（**由线围成**，边是共享实体）
  // -------------------------------------------------------------------------

  Future<int> insertArea(AreaRow area) =>
      _db.insert(area.domain.areasTable, area.toDb());

  Future<void> updateArea(AreaRow area) async {
    await _db.update(
      area.domain.areasTable,
      {...area.toDb(), 'updated_at': nowMs},
      where: 'id = ?',
      whereArgs: [area.id],
    );
  }

  /// 软删除区域：级联软删它**独占**的线与挂在那些线上的门/要素。
  ///
  /// 一条线若还被**别的区域**引用，就**不能**跟着删 —— 否则删掉小区甲会顺手
  /// 把小区乙的一堵墙也删了（实测真库 `line 1` 同时属于两个区域）。
  Future<void> softDeleteArea(AreaRow area) async {
    final domain = area.domain;
    final id = area.id!;
    await _db.transaction((txn) async {
      final lineIds = await lineIdsOfArea(domain, id, txn: txn);
      final exclusive = <int>[];
      for (final lineId in lineIds) {
        final others = await areasOfLine(domain, lineId, txn: txn);
        if (others.where((a) => a != id).isEmpty) exclusive.add(lineId);
      }
      if (exclusive.isNotEmpty && domain == MapDomain.world) {
        final ph = List.filled(exclusive.length, '?').join(',');
        await txn.rawUpdate(
          'UPDATE world_lines SET deleted_at = ? WHERE id IN ($ph)',
          [nowMs, ...exclusive],
        );
        await txn.rawUpdate(
          'UPDATE world_gates SET deleted_at = ? WHERE line_id IN ($ph)',
          [nowMs, ...exclusive],
        );
        await txn.rawUpdate(
          'UPDATE world_entities SET deleted_at = ? WHERE line_id IN ($ph)',
          [nowMs, ...exclusive],
        );
      } else if (exclusive.isNotEmpty) {
        final ph = List.filled(exclusive.length, '?').join(',');
        await txn.rawUpdate(
          'UPDATE ${domain.linesTable} SET deleted_at = ? WHERE id IN ($ph)',
          [nowMs, ...exclusive],
        );
      }
      await txn.delete(
        domain.areaLinesTable,
        where: 'area_id = ?',
        whereArgs: [id],
      );
      await txn.update(
        domain.areasTable,
        {'deleted_at': nowMs},
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  Future<List<AreaRow>> listAreas(
    MapDomain domain, {
    bool includeDeleted = false,
  }) async {
    final rows = await _db.query(
      domain.areasTable,
      where: includeDeleted ? null : _notDeleted,
      orderBy: 'sort_order ASC, id ASC',
    );
    final areas = rows.map((r) => AreaRow.fromDb(r, domain: domain)).toList();
    if (areas.isEmpty) return areas;
    // 一次性把全部 area→line 关联读出来再分发，避免 N+1 查询
    final links = await _db.query(
      domain.areaLinesTable,
      orderBy: 'area_id ASC, line_id ASC',
    );
    final byArea = <int, List<int>>{};
    for (final r in links) {
      byArea.putIfAbsent(r['area_id'] as int, () => []).add(r['line_id'] as int);
    }
    return [
      for (final a in areas) a.copyWith(lineIds: byArea[a.id] ?? const <int>[]),
    ];
  }

  /// 所有域的区域（渲染/命中要同时认世界图与行政区域）。
  Future<List<AreaRow>> listAllAreas({bool includeDeleted = false}) async {
    final out = <AreaRow>[];
    for (final d in areaDomains) {
      out.addAll(await listAreas(d, includeDeleted: includeDeleted));
    }
    return out;
  }

  Future<AreaRow?> getArea(MapDomain domain, int id) async {
    final rows = await _db.query(
      domain.areasTable,
      where: 'id = ? AND $_notDeleted',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final area = AreaRow.fromDb(rows.first, domain: domain);
    return area.copyWith(lineIds: await lineIdsOfArea(domain, id));
  }

  /// 区域用到的线 id。⚠️ **顺序无意义**（D14：组环按边建图，不读顺序）。
  Future<List<int>> lineIdsOfArea(
    MapDomain domain,
    int areaId, {
    DatabaseExecutor? txn,
  }) async {
    final ex = txn ?? _db;
    final rows = await ex.query(
      domain.areaLinesTable,
      columns: ['line_id'],
      where: 'area_id = ?',
      whereArgs: [areaId],
      orderBy: 'line_id ASC',
    );
    return rows.map((r) => r['line_id'] as int).toList();
  }

  /// 一条线被哪些区域引用（"共享边不能跟着区域一起删"的判断）。
  Future<List<int>> areasOfLine(
    MapDomain domain,
    int lineId, {
    DatabaseExecutor? txn,
  }) async {
    final ex = txn ?? _db;
    final rows = await ex.query(
      domain.areaLinesTable,
      columns: ['area_id'],
      where: 'line_id = ?',
      whereArgs: [lineId],
    );
    return rows.map((r) => r['area_id'] as int).toList();
  }

  /// 覆盖式设置区域的线集合（整体替换）。**没有顺序列**（D14）。
  Future<void> setAreaLines(
    MapDomain domain,
    int areaId,
    List<int> lineIds, {
    DatabaseExecutor? txn,
  }) async {
    Future<void> run(DatabaseExecutor ex) async {
      await ex.delete(
        domain.areaLinesTable,
        where: 'area_id = ?',
        whereArgs: [areaId],
      );
      for (final lineId in lineIds) {
        await ex.insert(domain.areaLinesTable, {
          'area_id': areaId,
          'line_id': lineId,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }

    if (txn != null) {
      await run(txn);
    } else {
      await _db.transaction(run);
    }
  }

  /// **由一组已有的线围成一个区域**（编辑模式"围合成区域"的主路径）。
  ///
  /// 与 [savePolygon] 的分工：这条路径**不新建任何点或线**，只是把用户已经
  /// 画好的线"认领"为一个区域 —— 这正是「标点 → 连线 → 围成区域」的最后一步。
  ///
  /// ⚠️ **成员只能是本域的线**（D2/D19）：区域 1 当年就是把 2 条**路线**当边
  /// 混进来，导致它在三层分域之后根本围不成环。这里显式拒绝跨域成员。
  Future<int> createAreaFromLines(AreaRow area, List<int> lineIds) async {
    if (lineIds.length < 3) {
      throw ArgumentError('围成一个区域至少需要 3 条线');
    }
    final domain = area.domain;
    final lines = await listLinesByIds(domain, lineIds);
    if (lines.length != lineIds.length) {
      throw ArgumentError('有 ${lineIds.length - lines.length} 条线不存在或已删除');
    }
    final pointIds = vertexIdsOf(lines);
    final pts = await listPointsByIds(domain, pointIds);
    final byId = {for (final p in pts) p.id!: p.geo};
    final ring = assembleAreaRing(lines, byId); // 失败抛 RingAssembleException
    // 度数校验只保证"每条边首尾相接"，围成一个 8 字也满足 —— 那不是一个区域。
    if (!isSimpleRing(ring)) {
      throw ArgumentError('这几条线围成的形状自交了，请检查是不是漏了/多选了一条');
    }
    return _db.transaction((txn) async {
      final areaId = await txn.insert(domain.areasTable, area.toDb());
      for (final lineId in lineIds) {
        await txn.insert(domain.areaLinesTable, {
          'area_id': areaId,
          'line_id': lineId,
        });
      }
      return areaId;
    });
  }

  Future<List<LineRow>> listAreaBoundaryLines(
    MapDomain domain,
    int areaId,
  ) async {
    final ids = await lineIdsOfArea(domain, areaId);
    return listLinesByIds(domain, ids);
  }

  /// 区域的边界坐标环。无法组环（未闭合/孤立边）时返回 null。
  Future<List<GeoPoint>?> areaRing(MapDomain domain, int areaId) async {
    final lines = await listAreaBoundaryLines(domain, areaId);
    if (lines.isEmpty) return null;
    final pointIds = vertexIdsOf(lines);
    final pts = await listPointsByIds(domain, pointIds);
    final byId = {for (final p in pts) p.id!: p.geo};
    if (byId.length != pointIds.length) return null;
    try {
      return assembleAreaRing(lines, byId);
    } on RingAssembleException {
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // 多边形：`world_polygons` + `world_polygon_points`（**由点围成**，D19）
  //
  // 与区域**同一语义、两种构造**，判据：这条边需要单独设属性、挂东西、
  // 或被别处共用吗？需要 → 区域，不需要 → 多边形。
  // 环是**链**（D20），而且**环没有头** —— 从任意一点走 N 步回到起点。
  // -------------------------------------------------------------------------

  Future<int> insertPolygon(PolygonRow p) => _db.transaction((txn) async {
    final id = await txn.insert(p.table, p.toDb());
    await _writeRingChain(txn, id, p.pointIds);
    return id;
  });

  /// **用一个坐标环新建多边形**（一笔画圈地的落点）。
  ///
  /// 与老版本 `saveAreaWithRing` 的关键差别：**它一条线都不造**。
  /// 老版本会为环的每条边建一条界线，于是"随手圈一块地"会往世界图里塞 N 条
  /// 脚手架线（每条都能挂门、都有材质，但其实没人会给它们设属性）。
  /// v12 把这件事变成**显式动作**：要边实体就调 [polygonToArea]。
  ///
  /// 点与图形一起落库（一个事务）：中途失败不会留下"点建了但图形没建"的垃圾点。
  Future<int> savePolygonRing(PolygonRow p, List<GeoPoint> ring) async {
    if (ring.length < 3) {
      throw ArgumentError('多边形至少要 3 个点（现在是 ${ring.length} 个）');
    }
    return _db.transaction((txn) async {
      final floors = p.floors ?? FloorSet.ground;
      final pointIds = <int>[];
      for (final g in ring) {
        pointIds.add(
          await txn.insert(
            p.domain.pointsTable,
            PointRow(
              domain: p.domain,
              lat: g.lat,
              lng: g.lng,
              floors: floors,
            ).toDb(),
          ),
        );
      }
      final polygonId = await txn.insert(
        p.table,
        p.copyWith(pointIds: pointIds).toDb(),
      );
      await _writeRingChain(txn, polygonId, pointIds);
      return polygonId;
    });
  }

  Future<void> updatePolygon(PolygonRow p) async {
    await _db.update(
      p.table,
      {...p.toDb(), 'updated_at': nowMs},
      where: 'id = ?',
      whereArgs: [p.id],
    );
  }

  Future<void> softDeletePolygon(PolygonRow p) async {
    await _db.transaction((txn) async {
      await txn.update(
        p.table,
        {'deleted_at': nowMs},
        where: 'id = ?',
        whereArgs: [p.id],
      );
      await txn.delete(
        '${p.domain.prefix}_polygon_points',
        where: 'polygon_id = ?',
        whereArgs: [p.id],
      );
    });
  }

  Future<List<PolygonRow>> listPolygons(
    MapDomain domain, {
    bool includeDeleted = false,
  }) async {
    final rows = await _db.query(
      '${domain.prefix}_polygons',
      where: includeDeleted ? null : _notDeleted,
      orderBy: 'sort_order ASC, id ASC',
    );
    if (rows.isEmpty) return const [];
    final table = '${domain.prefix}_polygon_points';
    final rings = <int, Map<int, int>>{};
    final linkRows = await _db.query(table, columns: [
      'polygon_id',
      'point_id',
      'before_point_id',
    ]);
    for (final r in linkRows) {
      rings.putIfAbsent(r['polygon_id'] as int, () => <int, int>{})[r[
          'point_id'
      ] as int] = r['before_point_id'] as int;
    }
    return [
      for (final r in rows)
        PolygonRow.fromDb(
          r,
          domain: domain,
          pointIds: _ringIdsOf(rings[r['id'] as int]),
        ),
    ];
  }

  Future<PolygonRow?> getPolygon(MapDomain domain, int id) async {
    final rows = await _db.query(
      '${domain.prefix}_polygons',
      where: 'id = ? AND $_notDeleted',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final table = '${domain.prefix}_polygon_points';
    final linkRows = await _db.query(
      table,
      columns: ['point_id', 'before_point_id'],
      where: 'polygon_id = ?',
      whereArgs: [id],
    );
    final beforeOf = {
      for (final r in linkRows)
        r['point_id'] as int: r['before_point_id'] as int,
    };
    return PolygonRow.fromDb(
      rows.first,
      domain: domain,
      pointIds: _ringIdsOf(beforeOf),
    );
  }

  /// **整体重写一个多边形的环**（全删全建链，一个事务）。
  Future<void> setPolygonRing(PolygonRow p, List<int> pointIds) =>
      _db.transaction((txn) async {
        if (pointIds.length < 3) {
          throw ArgumentError('多边形至少要 3 个点（现在是 ${pointIds.length} 个）');
        }
        await _db.update(
          p.table,
          {'updated_at': nowMs},
          where: 'id = ?',
          whereArgs: [p.id],
        );
        await txn.delete(
          '${p.domain.prefix}_polygon_points',
          where: 'polygon_id = ?',
          whereArgs: [p.id],
        );
        await _writeRingChain(txn, p.id!, pointIds);
      });

  /// 把环写成链。与线的链**唯一的区别**：环没有起点/终点，
  /// 所以最后一点的前驱是第一点 —— **首尾相接**。
  static Future<void> _writeRingChain(
    DatabaseExecutor txn,
    int polygonId,
    List<int> pointIds,
  ) async {
    final n = pointIds.length;
    final table = '${MapDomain.world.prefix}_polygon_points';
    for (var i = 0; i < n; i++) {
      await txn.insert(table, {
        'polygon_id': polygonId,
        'point_id': pointIds[i],
        'before_point_id': pointIds[(i - 1 + n) % n],
      });
    }
  }

  /// 走环链拿到环序（首尾不重复）。环坏了返回空列表（渲染层会跳过它）。
  static List<int> _ringIdsOf(Map<int, int>? beforeOf) {
    if (beforeOf == null || beforeOf.isEmpty) return const [];
    final ring = assembleRingChain(beforeOf);
    return ring.ok ? ring.pointIds : const [];
  }

  /// 在环上的 [anchorPointId] 之后插入一个点（与线的链同一套两步写法）。
  Future<void> insertPointOnRing(
    int polygonId, {
    required int anchorPointId,
    required int newPointId,
  }) => _db.transaction((txn) async {
    final table = '${MapDomain.world.prefix}_polygon_points';
    await txn.update(
      table,
      {'before_point_id': newPointId},
      where: 'polygon_id = ? AND before_point_id = ?',
      whereArgs: [polygonId, anchorPointId],
    );
    await txn.insert(table, {
      'polygon_id': polygonId,
      'point_id': newPointId,
      'before_point_id': anchorPointId,
    });
  });

  /// 从环上摘掉一个点（三步；最少留 3 个）。
  Future<void> removePointFromRing(int polygonId, int pointId) =>
      _db.transaction((txn) async {
        final table = '${MapDomain.world.prefix}_polygon_points';
        final rows = await txn.query(
          table,
          columns: ['before_point_id'],
          where: 'polygon_id = ? AND point_id = ?',
          whereArgs: [polygonId, pointId],
          limit: 1,
        );
        if (rows.isEmpty) return;
        final before = rows.first['before_point_id'] as int;
        final cnt = await txn.rawQuery(
          'SELECT COUNT(*) AS n FROM $table WHERE polygon_id = ?',
          [polygonId],
        );
        final n = (cnt.first['n'] as num?)?.toInt() ?? 0;
        if (n <= 3) {
          throw StateError('多边形至少要 3 个点，要删就把整个多边形删掉');
        }
        await txn.delete(
          table,
          where: 'polygon_id = ? AND point_id = ?',
          whereArgs: [polygonId, pointId],
        );
        await txn.update(
          table,
          {'before_point_id': before},
          where: 'polygon_id = ? AND before_point_id = ?',
          whereArgs: [polygonId, pointId],
        );
      });

  // -------------------------------------------------------------------------
  // 两种构造的互转（D19）
  //
  // 🔴 **转换是「搬家」，不是「复制」** —— 同一块地不许在两张表里各存一份，
  // 那正是 P1（同一个概念两套表示）的复现。所以两个方向都以"删掉原来那个"收尾。
  // 计划由 `core/shape_convert.dart` 算（纯逻辑，可脚本验证），这里只负责落库。
  // -------------------------------------------------------------------------

  /// **多边形 → 区域**：给每条边新建一条界线，再建区域。返回新区域 id。
  ///
  /// 爆炸半径：**界线数 +N**（每条边一条）。实测这正是今天「一笔画圈地」的行为
  /// （老的 `saveAreaWithRing` 会造 N 条界线 + N 个点）—— v12 把它从**默认行为**
  /// 改成了**显式动作**：默认只造多边形（一圈点），要边实体的时候才转。
  Future<int> polygonToArea(PolygonRow p) async {
    final plan = planPolygonToArea(p);
    if (plan is ShapeConvertRejection) {
      throw StateError(plan.toString());
    }
    final conv = plan as PolygonToAreaPlan;
    final domain = p.domain;
    return _db.transaction((txn) async {
      // 1) 每条边一条界线（材质留空 = 未指定）
      final lineIds = <int>[];
      for (final (a, b) in conv.edges) {
        lineIds.add(
          await txn.insert(
            domain.linesTable,
            LineRow(
              domain: domain,
              floors: p.floors,
              startPointId: a,
              endPointId: b,
            ).toDb(),
          ),
        );
      }
      // 2) 区域 + 成员关系
      final areaId = await txn.insert(domain.areasTable, conv.area.toDb());
      for (final lineId in lineIds) {
        await txn.insert(domain.areaLinesTable, {
          'area_id': areaId,
          'line_id': lineId,
        });
      }
      // 3) 搬完就把多边形删掉（**不是复制**）
      await txn.update(
        p.table,
        {'deleted_at': nowMs},
        where: 'id = ?',
        whereArgs: [p.id],
      );
      await txn.delete(
        '${domain.prefix}_polygon_points',
        where: 'polygon_id = ?',
        whereArgs: [p.id],
      );
      return areaId;
    });
  }

  /// **区域 → 多边形**：丢掉边实体，只留一圈点。返回新多边形 id。
  ///
  /// ⚠️ 两处硬约束（见 `core/shape_convert.dart`）：
  /// - **组环必须成功**（区域的环是推导出来的，开口/分叉/接不上就转不了）；
  /// - **那些线一条都不删** —— 它们可能被别的区域共用（实测 `line 1` 就同时属于
  ///   两个区域），或上面挂着门/店铺。转换后会留下"不属于任何区域的线"，
  ///   那是**预期结果，不是脏数据**（渲染不依赖区域）。
  ///
  /// 返回 `(新多边形 id, 提醒列表)`。
  Future<(int, List<String>)> areaToPolygon(AreaRow area) async {
    final domain = area.domain;
    final members = await listAreaBoundaryLines(domain, area.id!);
    // 引用检查：这条边还被几个区域引用？上面挂了门/要素吗？
    final lineUsage = <int, int>{};
    final anchored = <int>{};
    for (final l in members) {
      if (l.id == null) continue;
      lineUsage[l.id!] = (await areasOfLine(domain, l.id!)).length;
    }
    if (domain == MapDomain.world) {
      final gateRows = await _db.query(
        'world_gates',
        columns: ['line_id'],
        where: 'deleted_at IS NULL AND line_id IS NOT NULL',
      );
      final entRows = await _db.query(
        'world_entities',
        columns: ['line_id'],
        where: 'deleted_at IS NULL AND line_id IS NOT NULL',
      );
      for (final r in [...gateRows, ...entRows]) {
        anchored.add(r['line_id'] as int);
      }
    }
    final plan = planAreaToPolygon(
      area: area,
      memberLines: members,
      lineUsage: lineUsage,
      anchoredLineIds: anchored,
    );
    if (plan is ShapeConvertRejection) {
      throw StateError(plan.toString());
    }
    final conv = plan as AreaToPolygonPlan;
    final id = await _db.transaction((txn) async {
      final polygonId = await txn.insert(conv.polygon.table, conv.polygon.toDb());
      final ring = conv.ringPointIds;
      final n = ring.length;
      for (var i = 0; i < n; i++) {
        await txn.insert('${domain.prefix}_polygon_points', {
          'polygon_id': polygonId,
          'point_id': ring[i],
          'before_point_id': ring[(i - 1 + n) % n],
        });
      }
      // 只删区域与它的成员关系；**线一条都不动**
      await txn.delete(
        domain.areaLinesTable,
        where: 'area_id = ?',
        whereArgs: [area.id],
      );
      await txn.update(
        domain.areasTable,
        {'deleted_at': nowMs},
        where: 'id = ?',
        whereArgs: [area.id],
      );
      return polygonId;
    });
    return (id, conv.warnings);
  }

  // -------------------------------------------------------------------------
  // 门：`world_gates`（吸附在世界图界线上的一处出入口，单一锚点 D21）
  // -------------------------------------------------------------------------

  Future<int> insertGate(GateRow g) => _db.insert('world_gates', g.toDb());

  Future<void> updateGate(GateRow g) async {
    await _db.update(
      'world_gates',
      {...g.toDb(), 'updated_at': nowMs},
      where: 'id = ?',
      whereArgs: [g.id],
    );
  }

  Future<void> softDeleteGate(int id) => _db.update(
    'world_gates',
    {'deleted_at': nowMs},
    where: 'id = ?',
    whereArgs: [id],
  );

  Future<List<GateRow>> listGates({int? lineId}) async {
    final rows = lineId == null
        ? await _db.query('world_gates', where: _notDeleted, orderBy: 'id ASC')
        : await _db.query(
            'world_gates',
            where: 'line_id = ? AND $_notDeleted',
            whereArgs: [lineId],
            orderBy: 'id ASC',
          );
    return rows.map(GateRow.fromDb).toList();
  }

  Future<int> addGate({
    required int lineId,
    required GateType gateType,
    required GeoPoint center,
    String? name,
    VehicleType vehicleType = VehicleType.all,
    AccessLevel accessLevel = AccessLevel.free,
    String? note,
  }) => _db.insert(
    'world_gates',
    GateRow(
      name: name,
      gateType: gateType,
      lineId: lineId,
      center: center,
      vehicleType: vehicleType,
      accessLevel: accessLevel,
      note: note,
    ).toDb(),
  );

  Future<GateRow?> getGate(int id) async {
    final rows = await _db.query(
      'world_gates',
      where: 'id = ? AND $_notDeleted',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return GateRow.fromDb(rows.first);
  }

  // -------------------------------------------------------------------------
  // 世界要素：`world_entities`（店铺 / 楼栋 / 单元 / 常送点 / 停车点，D18）
  // -------------------------------------------------------------------------

  Future<int> insertEntity(EntityRow e) =>
      _db.insert('world_entities', e.toDb());

  Future<void> updateEntity(EntityRow e) async {
    await _db.update(
      'world_entities',
      {...e.toDb(), 'updated_at': nowMs},
      where: 'id = ?',
      whereArgs: [e.id],
    );
  }

  Future<List<EntityRow>> listEntities() async {
    final rows = await _db.query(
      'world_entities',
      where: _notDeleted,
      orderBy: 'id ASC',
    );
    return rows.map(EntityRow.fromDb).toList();
  }

  Future<List<EntityRow>> listEntitiesOfLine(int lineId) async {
    final rows = await _db.query(
      'world_entities',
      where: 'line_id = ? AND $_notDeleted',
      whereArgs: [lineId],
      orderBy: 'id ASC',
    );
    return rows.map(EntityRow.fromDb).toList();
  }

  /// 在一条界线上追加一个世界要素。
  ///
  /// [center] 是它的**中心坐标**；调用方通常已经把点击位置吸附到线上了，
  /// 即使没吸附也没关系 —— 渲染时会再吸附一次，数据里保留原始中心点更忠实。
  Future<int> addLineFeature({
    required int lineId,
    required EntityType type,
    required String name,
    String? desc,
    String? doorNo,
    required GeoPoint center,
    double? width,
    String? note,
  }) => _db.insert(
    'world_entities',
    EntityRow(
      entityType: type,
      name: name,
      desc: desc,
      doorNo: doorNo,
      lineId: lineId,
      lat: center.lat,
      lng: center.lng,
      width: width,
      note: note,
    ).toDb(),
  );

  Future<void> softDeleteEntity(int id) => _db.update(
    'world_entities',
    {'deleted_at': nowMs},
    where: 'id = ?',
    whereArgs: [id],
  );

  // -------------------------------------------------------------------------
  // 记录点：`world_marks`（"我在这儿"，22 章）
  //
  // v12 起它就是自己的表 —— 于是"浏览态只显示记录录入且未处理的点"
  // 从"猜 source 是不是 recorded"变成一句 `processed = 0`。
  // -------------------------------------------------------------------------

  Future<int> insertWorldMark(WorldMarkRow m) =>
      _db.insert('world_marks', m.toDb());

  Future<void> updateWorldMark(WorldMarkRow m) async {
    await _db.update(
      'world_marks',
      {...m.toDb(), 'updated_at': nowMs},
      where: 'id = ?',
      whereArgs: [m.id],
    );
  }

  /// 读记录点。[pendingOnly] = 只读"还没处理"的（浏览态就是这么读的）。
  Future<List<WorldMarkRow>> listWorldMarks({
    bool pendingOnly = false,
    bool includeDeleted = false,
  }) async {
    final where = <String>[
      if (!includeDeleted) _notDeleted,
      if (pendingOnly) 'processed = 0',
    ].join(' AND ');
    final rows = await _db.query(
      'world_marks',
      where: where.isEmpty ? null : where,
      orderBy: 'id ASC',
    );
    return rows.map(WorldMarkRow.fromDb).toList();
  }

  /// 把一个记录点标记为「已处理」/「未处理」。
  ///
  /// 这是**用户自己下的判断**（"这个点我已经用过了/确认过了"），
  /// 不是系统按"有没有被线用到"推出来的 —— 用户 2026-09-14 明确要这样。
  Future<void> setWorldMarkProcessed(int id, bool processed) => _db.update(
    'world_marks',
    {'processed': processed ? 1 : 0, 'updated_at': nowMs},
    where: 'id = ?',
    whereArgs: [id],
  );

  Future<void> softDeleteWorldMark(int id) => _db.update(
    'world_marks',
    {'deleted_at': nowMs},
    where: 'id = ?',
    whereArgs: [id],
  );

  // -------------------------------------------------------------------------
  // 行驶轨迹：`way_marks`（D15）
  //
  // 一行 = 一个采样点；一段 = 同一个 trip 下按 recorded_at 排序的点序列。
  // **原始采集数据，不是几何**：不进点表、不参与吸附。
  // -------------------------------------------------------------------------

  /// 落一个采样点。采集是 1 Hz 的**流式写入**，所以这里必须是一次 INSERT
  /// （这正是"一行一个采样点"而不是"一行一段"的理由：一行一段就得每秒重写整个 blob，
  /// 而且 App 被杀就整段丢失）。
  Future<int> insertWayMark(WayMarkRow m) =>
      _db.insert('way_marks', m.toDb());

  /// 批量落点（采集器攒一批再写，减少事务开销）。
  Future<void> insertWayMarks(List<WayMarkRow> marks) async {
    if (marks.isEmpty) return;
    await _db.transaction((txn) async {
      for (final m in marks) {
        await txn.insert('way_marks', m.toDb());
      }
    });
  }

  /// 一段轨迹的全部采样点（按时间排）。
  Future<List<WayMarkRow>> listWayMarksOfTrip(String trip) async {
    final rows = await _db.query(
      'way_marks',
      where: 'trip = ? AND $_notDeleted',
      whereArgs: [trip],
      orderBy: 'recorded_at ASC, id ASC',
    );
    return rows.map(WayMarkRow.fromDb).toList();
  }

  /// 现有的轨迹段（每段一行摘要：trip 键、点数、起止时刻、是否已处理）。
  Future<List<TripSummary>> listTrips({bool pendingOnly = false}) async {
    final rows = await _db.rawQuery('''
      SELECT trip,
             COUNT(*)            AS n,
             MIN(recorded_at)    AS started_at,
             MAX(recorded_at)    AS ended_at,
             MAX(processed)      AS processed
        FROM way_marks
       WHERE deleted_at IS NULL
       GROUP BY trip
       ${pendingOnly ? 'HAVING MAX(processed) = 0' : ''}
       ORDER BY started_at DESC''');
    return [
      for (final r in rows)
        TripSummary(
          trip: r['trip'] as String,
          pointCount: (r['n'] as num).toInt(),
          startedAt: DateTime.fromMillisecondsSinceEpoch(
            (r['started_at'] as num).toInt(),
          ),
          endedAt: DateTime.fromMillisecondsSinceEpoch(
            (r['ended_at'] as num).toInt(),
          ),
          processed: (r['processed'] as num? ?? 0) != 0,
        ),
    ];
  }

  /// 把一整段标记为已处理（转换完成之后调用）。一条 UPDATE 覆盖全段。
  Future<void> setTripProcessed(String trip, {bool processed = true}) =>
      _db.update(
        'way_marks',
        {'processed': processed ? 1 : 0, 'updated_at': nowMs},
        where: 'trip = ?',
        whereArgs: [trip],
      );

  /// 删除一整段轨迹。**这是 `way_marks` 唯一的清理入口** ——
  /// 默认只允许删**已处理**的段（红线：绝不碰未处理的）。
  Future<int> deleteTrip(String trip, {bool allowUnprocessed = false}) =>
      _db.transaction((txn) async {
        if (!allowUnprocessed) {
          final rows = await txn.rawQuery(
            'SELECT MAX(processed) AS p FROM way_marks '
            'WHERE trip = ? AND deleted_at IS NULL',
            [trip],
          );
          final p = (rows.first['p'] as num?)?.toInt() ?? 0;
          if (p == 0) {
            throw StateError('这一段还没处理过（没转成路线），先处理或显式确认要删');
          }
        }
        return txn.update(
          'way_marks',
          {'deleted_at': nowMs},
          where: 'trip = ?',
          whereArgs: [trip],
        );
      });

  /// **轨迹 → 路线**（D15 里那条"唯一出口"）。返回新路线的 id。
  ///
  /// [path] 是**已经在 Dart 侧抽稀降噪过**的点序列（见 `core/track.dart`）；
  /// 本方法只负责：新建点 → 建线 → 写链 → 把整段标记为已处理，**一个事务**。
  ///
  /// 点的楼层由调用方指定（R-23-11：GPS 判不出楼层，所以要用户选）。
  Future<int> lineFromTrack({
    required String trip,
    required List<GeoPoint> path,
    MapDomain domain = MapDomain.way,
    String? name,
    RouteWidth? routeWidth,
    FloorSet? floors,
    bool markTripProcessed = true,
  }) async {
    if (path.length < 2) {
      throw ArgumentError('抽稀之后至少要剩 2 个点才成一条线');
    }
    return _db.transaction((txn) async {
      final fs = floors ?? FloorSet.ground;
      final pointIds = <int>[];
      for (final g in path) {
        pointIds.add(
          await txn.insert(
            domain.pointsTable,
            PointRow(lat: g.lat, lng: g.lng, domain: domain, floors: fs).toDb(),
          ),
        );
      }
      final lineId = await txn.insert(
        domain.linesTable,
        LineRow(
          domain: domain,
          name: name,
          floors: fs,
          startPointId: pointIds.first,
          endPointId: pointIds.last,
          routeWidth: routeWidth,
          note: '由轨迹 $trip 转换',
        ).toDb(),
      );
      await _writeChain(txn, domain, lineId, pointIds);
      if (markTripProcessed) {
        await txn.update(
          'way_marks',
          {'processed': 1, 'updated_at': nowMs},
          where: 'trip = ?',
          whereArgs: [trip],
        );
      }
      return lineId;
    });
  }

  // -------------------------------------------------------------------------
  // 用户层备份：导出 / 合并导入（docs/design/11-backup-export-import.md + 23 章 §8）
  //
  // 格式仍是纯文本 GeoJSON FeatureCollection，导入仍是**按业务键的幂等合并**。
  // v10 的两处变化：每个 feature 多带 `domain`/`table`；**业务键加域前缀**
  // （否则三个域里坐标相同的点会互相顶掉 —— 实测有 4 个跨域共享点）。
  // -------------------------------------------------------------------------

  /// 读整个用户层快照（19 张表里"活的"那部分 + 每个封闭图形的环）。
  ///
  /// ⚠️ **轨迹（`way_marks`）默认不进快照**（R-23-7 未定）：
  /// 它的体量和别的东西不是一个量级（半小时一趟 1800 个点），
  /// 塞进 GeoJSON 会把备份从几百 KB 撑到几十 MB。
  Future<ExportBundle> snapshotUserLayer({
    bool includeTracks = false,
  }) async {
    final points = <MapDomain, List<PointRow>>{};
    final lines = <MapDomain, List<LineRow>>{};
    final areas = <MapDomain, List<AreaRow>>{};
    for (final d in MapDomain.values) {
      points[d] = await listPoints(d);
      lines[d] = await listLines(d);
      if (d.hasAreas) areas[d] = await listAreas(d);
    }
    final polygons = await listPolygons(MapDomain.world);
    final gates = await listGates();
    final entities = await listEntities();
    final marks = await listWorldMarks();

    // 封闭图形的环：区域要组环（可能失败）、多边形读链
    final rings = <(MapDomain, int), List<GeoPoint>>{};
    for (final d in areaDomains) {
      for (final a in areas[d] ?? const <AreaRow>[]) {
        if (a.id == null) continue;
        final r = await areaRing(d, a.id!);
        if (r != null && r.isNotEmpty) rings[(d, a.id!)] = r;
      }
    }
    final byDomain = await pointCoordsByDomain();
    final polygonRings = <int, List<GeoPoint>>{};
    for (final pg in polygons) {
      if (pg.id == null) continue;
      final pts = byDomain[pg.domain]!;
      final geo = [for (final id in pg.pointIds) if (pts[id] != null) pts[id]!];
      if (geo.length >= 3) polygonRings[pg.id!] = geo;
    }

    return ExportBundle(
      points: points,
      lines: lines,
      areas: areas,
      polygons: polygons,
      gates: gates,
      entities: entities,
      marks: marks,
      tracks: includeTracks ? await _allWayMarks() : const [],
      areaRings: rings,
      polygonRings: polygonRings,
    );
  }

  Future<List<WayMarkRow>> _allWayMarks() async {
    final rows = await _db.query(
      'way_marks',
      where: _notDeleted,
      orderBy: 'trip ASC, recorded_at ASC',
    );
    return rows.map(WayMarkRow.fromDb).toList();
  }

  /// 导出为 `.mapexport.json` 文本（可直接写盘）。
  Future<String> exportUserLayerJson({bool includeTracks = false}) async =>
      exportToJsonString(await snapshotUserLayer(includeTracks: includeTracks));

  /// 解析备份文本，**同时**给出合并计划与解析报告（导入前预览要用 warnings：
  /// 老文件被翻译时丢了什么、跳过了哪些不认识的表 —— 这些代价要说给用户听）。
  Future<(MergePlan, ImportReport)> planUserLayerImportDetailed(
    String source,
  ) async {
    final report = importFromJsonString(source);
    final existing = await snapshotUserLayer();
    return (planMerge(existing: existing, incoming: report.bundle), report);
  }

  /// 解析备份文本并与现有库比对，得到**不落库**的合并计划（导入前预览用）。
  Future<MergePlan> planUserLayerImport(String source) async {
    final existing = await snapshotUserLayer();
    return planMerge(
      existing: existing,
      incoming: importFromJsonString(source).bundle,
    );
  }

  /// 执行一份合并计划（单事务，失败整体回滚）。
  Future<MergeStats> applyUserLayerMerge(MergePlan plan) => _db.transaction(
    (txn) => applyMergePlan(plan, (table, values) => txn.insert(table, values)),
  );

  /// 一步到位：备份文本 → 合并入库。UI 走的是"先预览、确认后再合并"。
  Future<MergeStats> importUserLayerJson(String source) async =>
      applyUserLayerMerge(await planUserLayerImport(source));

  // -------------------------------------------------------------------------
  // 导入层：写入**临时 pack**（D11；docs/design/10-basemap-packs.md §9）
  //
  // v3 起 user.db 不再有 import_* 表（已 DROP），导入层改为写成一个独立的
  // pack 文件 `basemap/_import_tmp.db`，由 [queryImportLayer] 像普通格包一样
  // ATTACH 使用。这样「.osmapp 手动导入」与「预构建包」走**同一条**查询路径，
  // 不需要任何特殊分支。
  // -------------------------------------------------------------------------

  /// 临时 pack 的最终绝对路径。无包目录时返回 null。
  String? get _tempPackPath {
    final dir = _registry.directory;
    if (dir == null) return null;
    return '${dir.path}${Platform.pathSeparator}$kTempPackKey.db';
  }

  /// 把导入层内容写进临时 pack，**整体替换**语义。
  ///
  /// 流程（原子性 + 安全）：
  ///   1. DETACH 全部已挂载包（避免改文件时句柄占用）；
  ///   2. 写到 `<pack>.db.tmp`（新库，绝不半途污染现有包）；
  ///   3. 建 pack DDL + 设 `PRAGMA user_version = kPackSchemaVersion`；
  ///   4. 执行 [fill]（拿到的是 [Database]，用法与原来的 Transaction 一致）；
  ///   5. 关库 → `rename` 原子替换 → 重新扫描包目录。
  ///
  /// 任何一步抛异常，旧的临时包**保持原样**（因为写的是 .tmp）。
  Future<void> _writeTempPack(Future<void> Function(Database txn) fill) async {
    final finalPath = _tempPackPath;
    if (finalPath == null) {
      throw StateError('没有底图包目录，无法写临时 pack（见 AppRepository.open）');
    }
    final dir = _registry.directory!;
    if (!dir.existsSync()) dir.createSync(recursive: true);

    await _attach.detachAll(_db);

    final tmpPath = '$finalPath.tmp';
    final stale = File(tmpPath);
    if (stale.existsSync()) stale.deleteSync();

    final tdb = await resolveDatabaseFactory().openDatabase(tmpPath);
    try {
      for (final stmt in packDdlStatements) {
        await tdb.execute(stmt);
      }
      await tdb.execute('PRAGMA user_version = $kPackSchemaVersion');
      await fill(tdb);
      await tdb.execute('PRAGMA user_version = $kPackSchemaVersion');
    } finally {
      await tdb.close();
    }

    final dst = File(finalPath);
    if (dst.existsSync()) dst.deleteSync();
    File(tmpPath).renameSync(finalPath);

    await _registry.scan();
  }

  /// 整体替换导入层：清空并写入一个新的 .osmapp 包（等价于 [importOsmFiles] 单文件）。
  Future<void> replaceImportLayer(OsmAppFile file) =>
      importOsmFiles(<OsmAppFile>[file]);

  /// 批量写入一次入库、单事务整体替换。
  ///
  /// 与 [importOsmAppStrings] 的区别：本方法先在 Dart 端把 [List<OsmAppFile>] 全量解析
  /// 后再统一入库（[importOsmAppStrings] 直接接收字符串流式解码）。保留它是为了
  /// 单测与「导入演示数据」按钮等小数据场景。
  ///
  /// 多个文件按 [OsmAppFile] 顺序写入；节点/路/POI 按 osm_id
  /// [ConflictAlgorithm.ignore] 去重合并；bounds 取各文件并集，计数取实际入库行数
  /// （避免重复被 IGNORE 后偏大）。调用前旧数据被清空。
  Future<void> importOsmFiles(List<OsmAppFile> files) async {
    // v3：写入独立的临时 pack（参数名仍叫 txn，方法体无需改动）。
    await _writeTempPack((txn) async {
      await txn.delete('import_ways');
      await txn.delete('import_pois');
      await txn.delete('import_nodes');
      await txn.delete('import_bounds');

      // 合并节点（跨文件按 osm_id 去重）
      final nodeMap = <int, (double, double)>{};
      for (final f in files) {
        for (final n in f.nodes) {
          nodeMap[n.osmId] = (n.lat, n.lng);
        }
      }
      await _commitNodes(txn, nodeMap);

      // 写入路/面：坐标从合并节点解析，bbox 外无法解析的边丢弃
      for (final f in files) {
        await _commitWays(txn, f.ways, nodeMap);
      }

      // 写入 POI（跨文件按 osm_id 去重）
      for (final f in files) {
        await _commitPois(txn, f.pois);
      }

      // 合并 bounds / 计数（计数取实际入库行数，避免重复被 IGNORE 后偏大）
      double? minLat, minLng, maxLat, maxLng;
      final regions = <String>[];
      String? generatedAt;
      for (final f in files) {
        regions.add(f.region);
        generatedAt = f.generatedAt;
        minLat = _minOr(minLat, f.bounds.minLat);
        minLng = _minOr(minLng, f.bounds.minLng);
        maxLat = _maxOr(maxLat, f.bounds.maxLat);
        maxLng = _maxOr(maxLng, f.bounds.maxLng);
      }
      await _commitBounds(
        txn,
        regions: regions,
        generatedAt: generatedAt,
        minLat: minLat,
        minLng: minLng,
        maxLat: maxLat,
        maxLng: maxLng,
      );
    });
  }

  /// 从 .osmapp 字符串原文直接入库（分批 + 流式解码 + 节点坐标按段查询）。
  ///
  /// **解决 M2.5+ 在低端机冷启动 OOM 的问题（08 章 §11）**：
  /// - 95 万级节点不再装进 Dart 端 `Map<int,(double,double)>` 全量常驻；
  ///   先 `INSERT OR IGNORE` 入库，ways/POs 路径上按段 `SELECT osm_id IN (...)`
  ///   一次拉 999 个参数（即 SQLite IN 子句的硬上限）流式查坐标；
  /// - 节点/路/POI 统一按 [kBatchSize]（2000）一批一 commit；
  /// - corrupt 自检：若 import_bounds 已写，但节点计数与实际 COUNT(*) 不一致，
  ///   调 [onCorrupt]（设置层会写 `default_osm_corrupt=1`，下次启动再清一次）。
  ///
  /// [files] 的字符串必须是无换行压缩后的 JSON（[OsmAppFile.fromJsonString] / 抽取器
  /// `tool/pbf_extract/main.py` 默认输出都对得上）；boundary 等元数据来自各 [files.name]
  /// 用于拼接 region。
  Future<void> importOsmAppStrings({
    required List<OsmAppStringSource> files,
    FutureOr<void> Function()? onCorrupt,

    /// 节点导入进度（每 2000 行/批触发一次，与 [kBatchSize] 对齐，避免 Riverpod
    /// state 被高频写导致 frame 抖动）。回调接收本次 Batch 的首尾 osm_id 与
    /// 当前文件 + 已累计导入数。
    void Function({
      required String fileName,
      required int batchStartId,
      required int batchEndId,
      required int nodesWritten,
      required int nodesTotal,
    })?
    onNodeBatch,
  }) async {
    // 预解析 bounds / region / 时间戳，但不持久化 nodes/ways/pois 全量对象。
    final parsed = <_ParsedOsmApp>[];
    for (final s in files) {
      final f = OsmAppFile.fromJsonString(s.source);
      parsed.add(
        _ParsedOsmApp(
          name: s.name,
          file: f,
          // 立即丢弃 source 引用即可让 Dart GC 释放字符串原文。
        ),
      );
    }

    // v3：写入独立的临时 pack（参数名仍叫 txn，方法体无需改动）。
    await _writeTempPack((txn) async {
      await txn.delete('import_ways');
      await txn.delete('import_pois');
      await txn.delete('import_nodes');
      await txn.delete('import_bounds');

      // 1) 节点：分批 commit（合并跨文件 osm_id 去重）。
      final seenNodes = <int>{};
      final pendingNodeBatch = txn.batch();
      var pendingNodeCount = 0;
      // 单文件维度进度：fileName → {total, written, firstId}
      final fileNodeTotal = <String, int>{
        for (final p in parsed) p.name: p.file.nodes.length,
      };
      final fileNodeWritten = <String, int>{for (final p in parsed) p.name: 0};
      String? currentFileName;
      int? batchStartId;
      var globalWritten = 0;
      final globalTotal = fileNodeTotal.values.fold<int>(0, (a, b) => a + b);

      int? pendingLastId;

      Future<void> flushBatch(String fileName) async {
        await pendingNodeBatch.commit(noResult: true);
        if (onNodeBatch != null && batchStartId != null) {
          onNodeBatch(
            fileName: fileName,
            batchStartId: batchStartId!,
            batchEndId: pendingLastId ?? batchStartId!,
            nodesWritten: globalWritten,
            nodesTotal: globalTotal,
          );
        }
        pendingNodeCount = 0;
        batchStartId = null;
        pendingLastId = null;
      }

      for (final p in parsed) {
        currentFileName = p.name;
        for (final n in p.file.nodes) {
          if (!seenNodes.add(n.osmId)) continue;
          batchStartId ??= n.osmId;
          pendingLastId = n.osmId;
          pendingNodeBatch.insert('import_nodes', {
            'osm_id': n.osmId,
            'lat': n.lat,
            'lng': n.lng,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          pendingNodeCount++;
          fileNodeWritten[p.name] = (fileNodeWritten[p.name] ?? 0) + 1;
          globalWritten++;
          if (pendingNodeCount >= kBatchSize) {
            await flushBatch(p.name);
          }
        }
      }
      if (pendingNodeCount > 0) {
        await flushBatch(currentFileName ?? parsed.last.name);
      }

      // 2) 路 / 面：每条 way 走批量查节点坐标后 commit 到 batch。
      //    节点查询 IN 子句一次最多 999 个参数，超过即按段切。
      final seenWays = <int>{};
      final pendingWayBatch = txn.batch();
      var pendingWayCount = 0;
      for (final p in parsed) {
        for (final w in p.file.ways) {
          if (!seenWays.add(w.osmId)) continue;

          // 流式查这段路涉及的节点坐标
          final coords = await _resolveWayCoords(txn, w.nodeIds);
          if (coords.isEmpty) continue; // bbox 外无法解析的边丢弃

          pendingWayBatch.insert('import_ways', {
            'osm_id': w.osmId,
            'kind': w.kind.storage,
            if (w.name != null) 'name': w.name,
            if (w.costClass != null) 'cost_class': w.costClass,
            if (w.oneWay) 'one_way': 1 else 'one_way': 0,
            if (w.isClosedArea) 'is_area': 1 else 'is_area': 0,
            'node_ids': jsonEncode(w.nodeIds),
            'tags': w.tags == null ? null : jsonEncode(w.tags),
            'min_lat': coords.map((c) => c.$1).reduce((a, b) => a < b ? a : b),
            'min_lng': coords.map((c) => c.$2).reduce((a, b) => a < b ? a : b),
            'max_lat': coords.map((c) => c.$1).reduce((a, b) => a > b ? a : b),
            'max_lng': coords.map((c) => c.$2).reduce((a, b) => a > b ? a : b),
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          pendingWayCount++;
          if (pendingWayCount >= kBatchSize) {
            await pendingWayBatch.commit(noResult: true);
            pendingWayCount = 0;
          }
        }
      }
      if (pendingWayCount > 0) {
        await pendingWayBatch.commit(noResult: true);
      }

      // 3) POI：跨文件按 osm_id 去重。
      final seenPois = <int>{};
      final pendingPoiBatch = txn.batch();
      var pendingPoiCount = 0;
      for (final p in parsed) {
        for (final poi in p.file.pois) {
          if (!seenPois.add(poi.osmId)) continue;
          pendingPoiBatch.insert('import_pois', {
            'osm_id': poi.osmId,
            if (poi.name != null) 'name': poi.name,
            'lat': poi.lat,
            'lng': poi.lng,
            'tags': poi.tags == null ? null : jsonEncode(poi.tags),
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          pendingPoiCount++;
          if (pendingPoiCount >= kBatchSize) {
            await pendingPoiBatch.commit(noResult: true);
            pendingPoiCount = 0;
          }
        }
      }
      if (pendingPoiCount > 0) {
        await pendingPoiBatch.commit(noResult: true);
      }

      // 4) bounds：合 region，并取各文件 bbox 并集；计数取实际入库行数。
      double? minLat, minLng, maxLat, maxLng;
      final regions = <String>[];
      String? generatedAt;
      for (final p in parsed) {
        regions.add(p.name);
        generatedAt = p.file.generatedAt;
        minLat = _minOr(minLat, p.file.bounds.minLat);
        minLng = _minOr(minLng, p.file.bounds.minLng);
        maxLat = _maxOr(maxLat, p.file.bounds.maxLat);
        maxLng = _maxOr(maxLng, p.file.bounds.maxLng);
      }
      final nodeCount =
          (await txn.query(
                'import_nodes',
                columns: ['COUNT(*) AS c'],
              )).first['c']
              as int;
      final wayCount =
          (await txn.query(
                'import_ways',
                columns: ['COUNT(*) AS c'],
              )).first['c']
              as int;
      final poiCount =
          (await txn.query(
                'import_pois',
                columns: ['COUNT(*) AS c'],
              )).first['c']
              as int;

      await txn.insert('import_bounds', {
        'id': 1,
        'region': regions.join('+'),
        'generated_at': generatedAt ?? '',
        'imported_at': nowMs,
        'min_lat': minLat ?? 0,
        'min_lng': minLng ?? 0,
        'max_lat': maxLat ?? 0,
        'max_lng': maxLng ?? 0,
        'node_count': nodeCount,
        'way_count': wayCount,
        'poi_count': poiCount,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // 5) corrupt 自检：理论上 bounds 写入的 *_count 与前面 commit 后的库内
      // 计数必须一致（同一事务内可见），万一出现不一致就触发 onCorrupt 回调。
      if (onCorrupt != null) {
        // 二次回查，避免任何缓存或潜在 edge case。
        final n2 =
            (await txn.query(
                  'import_nodes',
                  columns: ['COUNT(*) AS c'],
                )).first['c']
                as int;
        final w2 =
            (await txn.query(
                  'import_ways',
                  columns: ['COUNT(*) AS c'],
                )).first['c']
                as int;
        if (n2 != nodeCount || w2 != wayCount) {
          await onCorrupt();
        }
      }
    });
  }

  /// 单批提交节点（[importOsmFiles] 走 Dart 端内存 Map 时复用）。
  Future<void> _commitNodes(
    DatabaseExecutor txn,
    Map<int, (double lat, double lng)> nodes,
  ) async {
    final batch = txn.batch();
    var pending = 0;
    for (final entry in nodes.entries) {
      batch.insert('import_nodes', {
        'osm_id': entry.key,
        'lat': entry.value.$1,
        'lng': entry.value.$2,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      pending++;
      if (pending >= kBatchSize) {
        await batch.commit(noResult: true);
        pending = 0;
      }
    }
    if (pending > 0) {
      await batch.commit(noResult: true);
    }
  }

  /// 单批提交路 / 面。坐标从传入的 [nodeMap] 解析。
  Future<void> _commitWays(
    DatabaseExecutor txn,
    List<OsmWay> ways,
    Map<int, (double lat, double lng)> nodeMap,
  ) async {
    final batch = txn.batch();
    var pending = 0;
    final seen = <int>{};
    for (final w in ways) {
      if (!seen.add(w.osmId)) continue;
      final coords = <(double, double)>[];
      for (final ref in w.nodeIds) {
        final n = nodeMap[ref];
        if (n != null) coords.add(n);
      }
      if (coords.isEmpty) continue;
      batch.insert('import_ways', {
        'osm_id': w.osmId,
        'kind': w.kind.storage,
        if (w.name != null) 'name': w.name,
        if (w.costClass != null) 'cost_class': w.costClass,
        if (w.oneWay) 'one_way': 1 else 'one_way': 0,
        if (w.isClosedArea) 'is_area': 1 else 'is_area': 0,
        'node_ids': jsonEncode(w.nodeIds),
        'tags': w.tags == null ? null : jsonEncode(w.tags),
        'min_lat': coords.map((c) => c.$1).reduce((a, b) => a < b ? a : b),
        'min_lng': coords.map((c) => c.$2).reduce((a, b) => a < b ? a : b),
        'max_lat': coords.map((c) => c.$1).reduce((a, b) => a > b ? a : b),
        'max_lng': coords.map((c) => c.$2).reduce((a, b) => a > b ? a : b),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      pending++;
      if (pending >= kBatchSize) {
        await batch.commit(noResult: true);
        pending = 0;
      }
    }
    if (pending > 0) {
      await batch.commit(noResult: true);
    }
  }

  /// 单批提交 POI。
  Future<void> _commitPois(DatabaseExecutor txn, List<OsmPoi> pois) async {
    final batch = txn.batch();
    var pending = 0;
    final seen = <int>{};
    for (final poi in pois) {
      if (!seen.add(poi.osmId)) continue;
      batch.insert('import_pois', {
        'osm_id': poi.osmId,
        if (poi.name != null) 'name': poi.name,
        'lat': poi.lat,
        'lng': poi.lng,
        'tags': poi.tags == null ? null : jsonEncode(poi.tags),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      pending++;
      if (pending >= kBatchSize) {
        await batch.commit(noResult: true);
        pending = 0;
      }
    }
    if (pending > 0) {
      await batch.commit(noResult: true);
    }
  }

  Future<void> _commitBounds(
    DatabaseExecutor txn, {
    required List<String> regions,
    required String? generatedAt,
    required double? minLat,
    required double? minLng,
    required double? maxLat,
    required double? maxLng,
  }) async {
    final counts = await Future.wait([
      txn.query('import_nodes', columns: ['COUNT(*) AS c']),
      txn.query('import_ways', columns: ['COUNT(*) AS c']),
      txn.query('import_pois', columns: ['COUNT(*) AS c']),
    ]);
    final nodeCount = counts[0].first['c'] as int;
    final wayCount = counts[1].first['c'] as int;
    final poiCount = counts[2].first['c'] as int;
    await txn.insert('import_bounds', {
      'id': 1,
      'region': regions.join('+'),
      'generated_at': generatedAt ?? '',
      'imported_at': nowMs,
      'min_lat': minLat ?? 0,
      'min_lng': minLng ?? 0,
      'max_lat': maxLat ?? 0,
      'max_lng': maxLng ?? 0,
      'node_count': nodeCount,
      'way_count': wayCount,
      'poi_count': poiCount,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 把 [nodeIds] 涉及到的节点坐标从 import_nodes 流式查出。
  ///
  /// IN 子句一次最多 999 个参数（SQLite 编译期硬限制），超出即按段切。
  /// 返回长度可短于 [nodeIds] —— 找不到的视为 bbox 外被丢弃。
  Future<List<(double, double)>> _resolveWayCoords(
    DatabaseExecutor txn,
    List<int> nodeIds,
  ) async {
    final coords = <(double, double)>[];
    for (final chunk in _chunk(nodeIds, 999)) {
      final ph = List.filled(chunk.length, '?').join(',');
      final rows = await txn.query(
        'import_nodes',
        columns: ['osm_id', 'lat', 'lng'],
        where: 'osm_id IN ($ph)',
        whereArgs: chunk,
      );
      // 保持输入顺序，按 osm_id 建临时 map 再按 nodeIds 顺序取。
      final byId = <int, (double, double)>{};
      for (final r in rows) {
        byId[(r['osm_id'] as num).toInt()] = (
          (r['lat'] as num).toDouble(),
          (r['lng'] as num).toDouble(),
        );
      }
      for (final ref in chunk) {
        final c = byId[ref];
        if (c != null) coords.add(c);
      }
    }
    return coords;
  }

  static List<List<T>> _chunk<T>(List<T> src, int size) {
    final out = <List<T>>[];
    for (var i = 0; i < src.length; i += size) {
      out.add(src.sublist(i, (i + size).clamp(0, src.length)));
    }
    return out;
  }

  /// 是否有可用底图。
  ///
  /// **v3 语义变更**：v2 时代查 user.db 的 import_bounds；
  /// v3 起看包目录里有没有包（格包或临时包）。
  Future<bool> hasImportLayer() async => !_registry.isEmpty;

  /// 底图摘要（null = 一个包都没有）。
  ///
  /// **v3 语义变更**：不再返回单个 import_bounds 行，而是**包目录的汇总**。
  /// 包数/占用来自 stat，不打开任何包（[PackRegistry.scan] 的设计约束）；
  /// 因此 nodeCount/wayCount/poiCount 不再有全局含义，走 [packCount] 分支展示。
  Future<ImportBoundsRow?> getImportBounds() async {
    if (_registry.isEmpty) return null;
    final list = _registry.all;
    final mtime = (() {
      var newest = 0;
      for (final p in list) {
        final t = File(p.path).statSync().modified.millisecondsSinceEpoch;
        if (t > newest) newest = t;
      }
      return newest;
    })();
    return ImportBoundsRow(
      region: _registry.temp == null
          ? '底图包 ${_registry.tiles.length} 个'
          : '底图包 ${_registry.tiles.length} 个 + 临时包',
      generatedAt: null,
      importedAt: mtime == 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(mtime),
      nodeCount: 0,
      wayCount: 0,
      poiCount: 0,
      packCount: list.length,
      totalBytes: _registry.totalBytes,
      attachedCount: _attach.attachedKeys.length,
    );
  }

  /// 清除**临时导入层**（`importOsm*` 的产物 `basemap/_import_tmp.db`）。
  ///
  /// **v3 语义变更**：不再删 user.db 的表，而是删临时包文件。
  /// **故意不动** adb push 进来的格包 —— 那是用户自己的文件，静默删除会很糟；
  /// 要清格包请用 [deleteAllPacks]。
  Future<void> clearImportLayer() async {
    await _attach.detachAll(_db);
    final t = _registry.temp;
    if (t != null) {
      final f = File(t.path);
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {
          // 文件被占用等：留给下次启动重试
        }
      }
    }
    await _registry.scan();
  }

  /// 删除**全部**底图包（含内置解出来的与 adb push 的）。
  ///
  /// 安全：内置包会在下次启动时由 `ensureBundledPacks` 重新解出。
  /// 返回实际删除的文件数。设置页二次确认后调用。
  Future<int> deleteAllPacks() async {
    await _attach.detachAll(_db);
    var n = 0;
    for (final p in _registry.all) {
      final f = File(p.path);
      if (!f.existsSync()) continue;
      try {
        f.deleteSync();
        n++;
      } catch (_) {
        // 忽略单个失败
      }
    }
    await _registry.scan();
    return n;
  }

  /// 读取 schema_meta 键值（如"默认底图是否已加载"标志）。
  Future<String?> getMeta(String key) async {
    final rows = await _db.query(
      'schema_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  /// 写入 schema_meta 键值（存在则覆盖）。
  Future<void> setMeta(String key, String value) async {
    await _db.insert('schema_meta', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 视口裁剪查询：roads（含节点坐标）与 POI。供地图渲染（R-07 视口策略）。
  ///
  /// **v3 架构（docs/design/10-basemap-packs.md §4.3/§4.4）**：
  /// 数据不再来自 user.db，而是来自**按视口语义按需 ATTACH 的 basemap pack**。
  /// 本方法是 packs 的唯一查询入口，对上层保持返回值不变。
  ///
  /// 执行步骤：
  ///   1. **缩放下限**：[zoomLevel] < [kBasemapMinZoom] 直接返回空视图。
  ///      原因是 SQLITE_MAX_ATTACHED=10（打包版 sqlite3 未覆盖默认值），
  ///      远景视口会跨越远超 9 个格包；同时远景视觉由 OSM 栅格瓦片承担。
  ///   2. 选出与视口相交的包（含临时包），交给 [PackAttachManager.sync] 做
  ///      ATTACH/DETACH 差量；命中 > [kMaxAttachedPacks] 时按「距视口中心」
  ///      保留最近的那些，其余通过 [onNote] 上报（状态条会显示）。
  ///   3. 逐包查 ways（bbox + zoom 档过滤）→ 逐包查 pois → 逐包解析节点坐标。
  ///      **节点只在它所属的那个包里查** —— 生成器已保证每个包携带其 way
  ///      引用的全部节点（§4.2.1），所以不存在跨包找节点的需求。
  ///   4. 跨包结果按 `osm_id` 去重（跨界 way/POI 会出现在多个包里）。
  ///
  /// **必须传 bbox**：不传时返回空视图（不再有「全量扫表」分支 —— 那正是
  /// 历史上把 sqflite 队列堵死、UI 卡在「正在加载门」的根因）。
  ///
  /// [onPhase] 顺序固定：roads → pois → nodes → done（[ImportLayerPhase]）。
  /// [onNote] 用于上报非阶段性的提示（如包数超限）。
  Future<ImportLayerView> queryImportLayer({
    double? minLat,
    double? minLng,
    double? maxLat,
    double? maxLng,
    double? zoomLevel,
    void Function(ImportLayerPhase phase)? onPhase,
    void Function(String note)? onNote,
  }) async {
    const empty = ImportLayerView(ways: [], pois: []);

    // ---- 1) 缩放下限：远景不挂底图 ----
    if (zoomLevel != null && zoomLevel < kBasemapMinZoom) {
      onNote?.call(
        '缩放 ${zoomLevel.toStringAsFixed(1)} < $kBasemapMinZoom，'
        '矢量底图已关闭',
      );
      onPhase?.call(ImportLayerPhase.done);
      return empty;
    }

    // ---- 0) 必须有 bbox ----
    if (minLat == null || minLng == null || maxLat == null || maxLng == null) {
      onPhase?.call(ImportLayerPhase.done);
      return empty;
    }

    // ---- 2) 选包 + 差量挂载 ----
    final want = <BasemapPack>[
      ..._registry.intersecting(minLat, minLng, maxLat, maxLng),
    ];
    if (want.isEmpty) {
      onPhase?.call(ImportLayerPhase.done);
      return empty;
    }

    final sync = await _attach.sync(
      db: _db,
      want: want,
      centerLat: (minLat + maxLat) / 2,
      centerLng: (minLng + maxLng) / 2,
    );
    if (sync.overflow.isNotEmpty) {
      onNote?.call(
        '底图包数超限，丢弃 ${sync.overflow.length} 个'
        '（上限 $kMaxAttachedPacks）',
      );
    }

    // zoom 档位过滤条件（与 import_layer_providers.ImportLayerZoomPolicy 同源）。
    // 远景档：路只取 kind='road' AND cost_class IN ('cycleway','trunk')；
    //        POI 只取大型 amenity + aeroway。
    // 中景档：路全取，POI 必须带 name。
    // 近景档：全取。
    final String? zoomWayClause;
    final List<Object?> zoomWayArgs;
    final String? zoomPoiClause;
    final List<Object?> zoomPoiArgs;
    if (zoomLevel == null) {
      zoomWayClause = null;
      zoomWayArgs = const [];
      zoomPoiClause = null;
      zoomPoiArgs = const [];
    } else {
      final zi = zoomLevel.floor();
      if (zi <= 13) {
        zoomWayClause = "kind = ? AND cost_class IN (?, ?)";
        zoomWayArgs = const ['road', 'cycleway', 'trunk'];
        zoomPoiClause =
            "tags LIKE '%\"amenity\":\"hospital\"%' "
            "OR tags LIKE '%\"amenity\":\"school\"%' "
            "OR tags LIKE '%\"amenity\":\"mall\"%' "
            "OR tags LIKE '%\"amenity\":\"station\"%' "
            "OR tags LIKE '%\"amenity\":\"subway\"%' "
            "OR tags LIKE '%\"amenity\":\"bus_station\"%' "
            "OR tags LIKE '%\"aeroway\":\"aerodrome\"%'";
        zoomPoiArgs = const [];
      } else if (zi == 14) {
        zoomWayClause = null;
        zoomWayArgs = const [];
        zoomPoiClause = "name IS NOT NULL AND name != ''";
        zoomPoiArgs = const [];
      } else {
        zoomWayClause = null;
        zoomWayArgs = const [];
        zoomPoiClause = null;
        zoomPoiArgs = const [];
      }
    }

    // bbox 相交（路用 bbox 相交，POI 用落点命中）
    const bboxWay =
        '(max_lat >= ? AND min_lat <= ? AND max_lng >= ? AND min_lng <= ?)';
    const bboxPoi = '(lat >= ? AND lat <= ? AND lng >= ? AND lng <= ?)';
    final bboxWayArgs = <Object?>[minLat, maxLat, minLng, maxLng];
    final bboxPoiArgs = <Object?>[minLat, maxLat, minLng, maxLng];

    // 逐包查询用的 (alias, pack) 列表（顺序稳定，便于去重时「先到先得」可复现）
    final attached = <(String, BasemapPack)>[
      for (final p in want)
        if (_attach.isAttached(p.key)) (p.alias, p),
    ];

    // ---- 3a) roads ----
    onPhase?.call(ImportLayerPhase.roads);
    final wayRowsByPack = <(String, BasemapPack), List<Map<String, Object?>>>{};
    for (final ap in attached) {
      final (alias, _) = ap;
      final where = [
        bboxWay,
        if (zoomWayClause != null) '($zoomWayClause)',
      ].join(' AND ');
      final rows = await _db.query(
        '$alias.import_ways',
        where: where,
        whereArgs: [...bboxWayArgs, ...zoomWayArgs],
        orderBy: 'id ASC',
      );
      if (rows.isNotEmpty) wayRowsByPack[ap] = rows;
    }

    // ---- 3b) pois ----
    onPhase?.call(ImportLayerPhase.pois);
    final poiViews = <int, ImportPoiView>{};
    for (final ap in attached) {
      final (alias, _) = ap;
      final where = [
        bboxPoi,
        if (zoomPoiClause != null) '($zoomPoiClause)',
      ].join(' AND ');
      final rows = await _db.query(
        '$alias.import_pois',
        where: where,
        whereArgs: [...bboxPoiArgs, ...zoomPoiArgs],
        orderBy: 'id ASC',
      );
      for (final r in rows) {
        final osmId = (r['osm_id'] as num).toInt();
        poiViews.putIfAbsent(
          osmId,
          () => ImportPoiView(
            osmId: osmId,
            name: r['name'] as String?,
            lat: (r['lat'] as num).toDouble(),
            lng: (r['lng'] as num).toDouble(),
          ),
        );
      }
    }

    // ---- 3c) nodes（每包只查它自己的节点）----
    onPhase?.call(ImportLayerPhase.nodes);
    final wayViews = <int, ImportWayView>{};
    var anyWays = false;
    for (final entry in wayRowsByPack.entries) {
      final (alias, _) = entry.key;
      final rows = entry.value;
      anyWays = true;

      // 本包这批 way 需要的全部节点 id
      final needed = <int>{};
      for (final row in rows) {
        needed.addAll(
          (jsonDecode(row['node_ids'] as String) as List).map(
            (e) => (e as num).toInt(),
          ),
        );
      }

      // IN 子句一次最多 999 个参数（SQLite 编译期硬限制），按段切。
      // 生成器已保证全命中，但保留了容错（缺失的 ref 只是被跳过）。
      final nodeMap = <int, (double, double)>{};
      final neededList = needed.toList();
      for (final chunk in _chunk(neededList, 999)) {
        final ph = List.filled(chunk.length, '?').join(',');
        final nodeRows = await _db.query(
          '$alias.import_nodes',
          columns: ['osm_id', 'lat', 'lng'],
          where: 'osm_id IN ($ph)',
          whereArgs: chunk,
        );
        for (final r in nodeRows) {
          nodeMap[(r['osm_id'] as num).toInt()] = (
            (r['lat'] as num).toDouble(),
            (r['lng'] as num).toDouble(),
          );
        }
      }

      for (final row in rows) {
        final osmId = (row['osm_id'] as num).toInt();
        if (wayViews.containsKey(osmId)) continue; // 跨界 way：先到先得
        final nodeIds = (jsonDecode(row['node_ids'] as String) as List)
            .map((e) => (e as num).toInt())
            .toList();
        final coords = <GeoPoint>[];
        for (final ref in nodeIds) {
          final n = nodeMap[ref];
          if (n != null) coords.add(GeoPoint(n.$1, n.$2));
        }
        if (coords.isEmpty) continue;
        wayViews[osmId] = ImportWayView(
          osmId: osmId,
          kind: ImportKind.fromStorage(row['kind'] as String?),
          name: row['name'] as String?,
          costClass: row['cost_class'] as String?,
          oneWay: (row['one_way'] as int? ?? 0) == 1,
          isArea: (row['is_area'] as int? ?? 0) == 1,
          coords: coords,
        );
      }
    }
    if (!anyWays) {
      // 视口内没有任何路 → nodes 阶段无事可做（保持与 v2 一致的阶段语义）
      onNote?.call('视口内无道路，跳过节点解析');
    }

    onPhase?.call(ImportLayerPhase.done);
    return ImportLayerView(
      ways: wayViews.values.toList(growable: false),
      pois: poiViews.values.toList(growable: false),
    );
  }

  /// 单要素带入（M2c）：把导入层一条路**复制为**用户层的路线。
  /// 返回新 line 主键；带入后即为普通用户数据，可再编辑/删除。
  ///
  /// **整条几何都带进来**：OSM 的一条 way 本来就是一串节点（中间那些是它的弯），
  /// 只取首尾两点等于**把一条拐了五道弯的路拉成一条横穿街区的直线**。
  /// 所以中间的节点全部落成这条线的拐点（v12：写成**链**）。
  Future<int> adoptWay(ImportWayView way) async {
    if (way.coords.length < 2) {
      throw ArgumentError('道路至少需要 2 个顶点才能带入');
    }
    // 点、线、链必须一起成功或一起失败：留下"点建了但线没建"的垃圾点，
    // 或者"线建了但没有拐点"的假直线，都比整条带入失败更难收拾。
    return _db.transaction((txn) async {
      final pointIds = <int>[];
      for (final g in way.coords) {
        pointIds.add(
          await txn.insert(
            MapDomain.way.pointsTable,
            PointRow(lat: g.lat, lng: g.lng, domain: MapDomain.way).toDb(),
          ),
        );
      }
      final lineId = await txn.insert(
        MapDomain.way.linesTable,
        LineRow(
          // 从 OSM 带入的是"我要走的路"，所以落在**路网域**
          domain: MapDomain.way,
          startPointId: pointIds.first,
          endPointId: pointIds.last,
          costClass: way.costClass == null
              ? null
              : CostClass.fromStorage(way.costClass),
          oneWay: way.oneWay,
          note: 'OSM 带入: ${way.name ?? 'way ${way.osmId}'}',
        ).toDb(),
      );
      await _writeChain(txn, MapDomain.way, lineId, pointIds);
      return lineId;
    });
  }

  /// 单要素带入（M2c）：把一个 POI 复制为世界要素（常送点），返回新 id。
  ///
  /// v12：`world_entities` **自己带坐标**（`lat`/`lng`），不再需要先建一个点
  /// 再拿 `point_id` 指过去 —— 那条路会往点表里塞一个永远不会被线引用的孤立点。
  Future<int> adoptPoi(ImportPoiView poi) async => _db.insert(
    'world_entities',
    EntityRow(
      name: poi.name ?? 'OSM POI ${poi.osmId}',
      desc: '由开放数据导入',
      entityType: EntityType.deliveryPoint,
      lat: poi.lat,
      lng: poi.lng,
      note: '来源：osm node ${poi.osmId}',
    ).toDb(),
  );

  // -------------------------------------------------------------------------

  static const String kindClause = 'kind';
  static int get nowMs => DateTime.now().millisecondsSinceEpoch;
}

/// 导入层展示视图（供渲染/命中）。
class ImportWayView {
  const ImportWayView({
    required this.osmId,
    required this.kind,
    this.name,
    this.costClass,
    required this.oneWay,
    required this.isArea,
    required this.coords,
  });

  final int osmId;
  final ImportKind kind;
  final String? name;
  final String? costClass;
  final bool oneWay;
  final bool isArea;
  final List<GeoPoint> coords;
}

class ImportPoiView {
  const ImportPoiView({
    required this.osmId,
    this.name,
    required this.lat,
    required this.lng,
  });

  final int osmId;
  final String? name;
  final double lat;
  final double lng;
}

class ImportLayerView {
  const ImportLayerView({required this.ways, required this.pois});

  final List<ImportWayView> ways;
  final List<ImportPoiView> pois;
}

/// [AppRepository.queryImportLayer] 的执行阶段（用于 UI 进度上报）。
///
/// 顺序固定：roads → pois → nodes → done。
/// - `nodes` 仅在本次视口命中至少一条路（needed 非空）时才会触发；
///   否则跳过该阶段直接进 done。
enum ImportLayerPhase {
  /// 正在查视口内的路（import_ways）。
  roads,

  /// 正在查视口内的 POI（import_pois）。
  pois,

  /// 正在按路节点 osm_id 批量拉坐标（import_nodes）。
  nodes,

  /// 查询完成。
  done,
}

/// 删点的结果报告（D10：「删点」与「从线上去掉一个点」是两个动作）。
///
/// DAO 只做机械劳动并把"会影响谁"如实报出来，**要不要继续由 UI 决定**：
/// - [bendOnlyLines]：那些线只是少了个弯，**仍然画得出来**；
/// - [endpointLines]：端点在它上面 → 那些线会**缺一个点**（整条线不画）。
///   默认不允许走到这一步（[AppRepository.softDeletePoint] 会直接抛错）。
class PointDeleteReport {
  const PointDeleteReport({
    required this.domain,
    required this.bendOnlyLines,
    required this.endpointLines,
    required this.removedBends,
  });

  final MapDomain domain;
  final List<int> bendOnlyLines;
  final List<int> endpointLines;
  final int removedBends;

  int get affectedLineCount => bendOnlyLines.length + endpointLines.length;

  @override
  String toString() =>
      '删点：影响 $affectedLineCount 条线（其中 ${endpointLines.length} 条会缺顶点）';
}

/// 一段行驶轨迹的摘要（`way_marks` 按 `trip` 分组）。
///
/// 「一段」的边界只由「开始记录 / 停止记录」决定（D17），GPS 中断不断段 ——
/// 所以这里没有"自动断段"的逻辑，只有一个 GROUP BY。
class TripSummary {
  const TripSummary({
    required this.trip,
    required this.pointCount,
    required this.startedAt,
    required this.endedAt,
    required this.processed,
  });

  final String trip;
  final int pointCount;
  final DateTime startedAt;
  final DateTime endedAt;
  final bool processed;

  Duration get duration => endedAt.difference(startedAt);
}

class ImportBoundsRow {
  const ImportBoundsRow({
    required this.region,
    this.generatedAt,
    required this.importedAt,
    required this.nodeCount,
    required this.wayCount,
    required this.poiCount,
    this.packCount,
    this.totalBytes,
    this.attachedCount,
  });

  final String region;
  final String? generatedAt;
  final DateTime? importedAt;
  final int nodeCount;
  final int wayCount;
  final int poiCount;

  /// v3：包模式的字段。非 null 表示这是「包目录汇总」而非单行 import_bounds，
  /// [nodeCount]/[wayCount]/[poiCount] 无全局含义、不应展示。
  final int? packCount;
  final int? totalBytes;
  final int? attachedCount;

  /// 状态摘要（设置页展示）。
  ///
  /// 两种模式：
  /// - 包模式（[packCount] != null）：只报包数 / 占用 / 已挂载数，不谎报行数；
  /// - 旧单包模式（临时包自身的 import_bounds）：沿用 v2 的文案。
  String get importSummary {
    if (packCount != null) {
      return '$region · ${_fmtBytes(totalBytes ?? 0)}'
          '${attachedCount == null ? '' : ' · 已挂载 $attachedCount'}'
          '${importedAt == null ? '' : ' · 更新于 ${_fmtDate(importedAt!)}'}';
    }
    return '$region · 路/面 $wayCount · POI $poiCount'
        '${importedAt == null ? '' : ' · 导入于 ${_fmtDate(importedAt!)}'}';
  }

  static String _fmtBytes(int n) {
    if (n >= 1073741824) return '${(n / 1073741824).toStringAsFixed(2)} GB';
    if (n >= 1048576) return '${(n / 1048576).toStringAsFixed(1)} MB';
    if (n >= 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
    return '$n B';
  }

  static String _fmtDate(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  factory ImportBoundsRow.fromDb(Map<String, Object?> row) => ImportBoundsRow(
    region: row['region'] as String,
    generatedAt: row['generated_at'] as String?,
    importedAt: row['imported_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['imported_at'] as int),
    nodeCount: row['node_count'] as int? ?? 0,
    wayCount: row['way_count'] as int? ?? 0,
    poiCount: row['poi_count'] as int? ?? 0,
  );
}
