/// 底图包（basemap pack）注册表 + ATTACH 生命周期管理。
///
/// 一个 pack = 一个只读 SQLite 文件，内含 import_nodes / import_ways /
/// import_pois / import_bounds 四表，结构与 lib/core/schema.dart 的
/// [packDdlStatements] 完全同构。
///
/// App 侧通过 `ATTACH` 把它挂进 map.db（main），查询时用
/// `<alias>.import_ways` 等形式引用。设计文档：docs/design/10-basemap-packs.md
///
/// **关键性能设计**：包的 bbox 直接**从文件名解析**（`t22.60_114.10.db`
/// → (22.60, 114.10, 22.70, 114.20)），因此 [PackRegistry.scan] 只需
/// `Directory.listSync()` + `stat`，**不需要打开任何一个包文件**。
/// 全省 2772 个包若逐个 open 读清单，启动会慢到几十秒。
library;

import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 同时可挂载的底图包上限。
///
/// SQLITE_MAX_ATTACHED 默认 10（打包版 sqlite3 未覆盖此默认值），
/// 其中 main(map.db) 占 1 个，故底图包最多 9 个。
/// 见 docs/design/10-basemap-packs.md §3.4 / §4.3。
const int kMaxAttachedPacks = 9;

/// 矢量底图的**缩放加载下限**。
///
/// 低于此值直接返回空视图、不 ATTACH 任何包。依据（§4.3 实测）：
/// 按 800px 宽屏 + `m/px = 40075016.686 × cos(22.7°) / (256 × 2^z)` 估算，
/// zoom 12 的视口约 0.5°（6×6=36 格）、zoom 13 约 0.25°（3×3=9 格，已临界），
/// 而 `SQLITE_MAX_ATTACHED` 只允许 9 个底图包。取 13.5 留出余量。
///
/// 这同时与 [ImportLayerZoomPolicy] 的分档天然吻合：zi ≤ 13 档本来就只画
/// 主干路 + 大型 POI，远景视觉由 OSM 栅格瓦片承担。
const double kBasemapMinZoom = 13.5;

/// 临时包的 key（`importOsm*` 的落点，D11）。
const String kTempPackKey = '_import_tmp';

/// 包清单里的一个条目。
class BasemapPack {
  const BasemapPack({
    required this.key,
    required this.path,
    required this.minLat,
    required this.minLng,
    required this.maxLat,
    required this.maxLng,
    required this.bytes,
    this.isTemp = false,
  });

  /// 格 key（如 `t22.60_114.10`）或 [kTempPackKey]。
  final String key;

  /// **绝对路径**。务必是绝对路径——sqflite 会把相对路径解析到
  /// `.dart_tool/sqflite_common_ffi/databases/` 之下（校验器已踩过这个坑）。
  final String path;

  final double minLat;
  final double minLng;
  final double maxLat;
  final double maxLng;

  /// 文件字节数（来自 stat，用于设置页展示占用）。
  final int bytes;

  /// 是否为临时包（`importOsm*` 写入的那个）。
  final bool isTemp;

  /// ATTACH 用的别名。
  ///
  /// 必须是合法 SQLite 标识符：格 key 里的 `.` 不能直接用作别名
  /// （`t22.60_114.10` 会被解析成库名 `t22` + 表名 `60_114`），故做字符净化。
  String get alias => 'bm_${key.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}';

  /// 与给定 bbox 是否相交（闭区间语义，与 queryImportLayer 的 bbox 过滤一致）。
  bool intersects(
    double aMinLat,
    double aMinLng,
    double aMaxLat,
    double aMaxLng,
  ) =>
      minLat <= aMaxLat &&
      maxLat >= aMinLat &&
      minLng <= aMaxLng &&
      maxLng >= aMinLng;

  /// 包中心（用于「超出上限时取离视口最近的 N 个」）。
  double get centerLat => (minLat + maxLat) / 2;
  double get centerLng => (minLng + maxLng) / 2;

  @override
  String toString() => 'BasemapPack($key, ${bytes ~/ 1024}KB)';
}

/// 包文件名解析：`t22.60_114.10.db` → (key, minLat, minLng, maxLat, maxLng)。
///
/// 返回 null 表示不是合法的格文件名（会被 scan 忽略）。
({String key, double minLat, double minLng, double maxLat, double maxLng})?
parseTileFileName(String baseName) {
  if (!baseName.endsWith('.db')) return null;
  final stem = baseName.substring(0, baseName.length - 3);
  final m = RegExp(r'^t(\d{2}\.\d{2})_(\d{3}\.\d{2})$').firstMatch(stem);
  if (m == null) return null;
  final lat = double.parse(m.group(1)!);
  final lng = double.parse(m.group(2)!);
  // 网格边长固定 0.1°（与 build_packs.py 的 STEP 一致）。
  return (
    key: stem,
    minLat: lat,
    minLng: lng,
    maxLat: double.parse((lat + 0.1).toStringAsFixed(2)),
    maxLng: double.parse((lng + 0.1).toStringAsFixed(2)),
  );
}

/// 包目录扫描结果。
///
/// 只做 `listSync` + `stat`，不打开包文件 —— 见库顶部说明。
class PackRegistry {
  PackRegistry({required this.directory, required this.factory});

  /// 包目录（绝对路径）。**null 表示没有包目录**（单测 in-memory 场景），
  /// 此时 [scan] 得到空清单，一切包相关逻辑安全退化为「无底图」。
  final Directory? directory;

  /// 仅用于读取**临时包**的真实 bbox（临时包文件名不含 bbox）。
  final DatabaseFactory factory;

  List<BasemapPack> _tiles = const [];
  BasemapPack? _temp;

  /// 格包（不含临时包），按 key 升序。
  List<BasemapPack> get tiles => _tiles;

  /// 临时包（不存在时为 null）。
  BasemapPack? get temp => _temp;

  /// 格包 + 临时包。
  List<BasemapPack> get all => [..._tiles, ?_temp];

  bool get isEmpty => _tiles.isEmpty && _temp == null;

  int get totalBytes => all.fold<int>(0, (a, p) => a + p.bytes);

  /// 重新扫描包目录。
  ///
  /// 幂等、可反复调用（用户在 App 运行期间 adb push 新包后，设置页可触发重扫）。
  Future<void> scan() async {
    final tiles = <BasemapPack>[];
    BasemapPack? temp;

    final dir = directory;
    if (dir != null && dir.existsSync()) {
      for (final e in dir.listSync(followLinks: false)) {
        if (e is! File) continue;
        final base = e.uri.pathSegments.last;
        final stat = e.statSync();
        if (stat.size == 0) continue; // 半截文件（.tmp 是别的名字，防御性跳过）

        if (base == '$kTempPackKey.db') {
          final b = await _readTempBounds(e.path);
          if (b != null) {
            temp = BasemapPack(
              key: kTempPackKey,
              path: e.absolute.path,
              minLat: b.$1,
              minLng: b.$2,
              maxLat: b.$3,
              maxLng: b.$4,
              bytes: stat.size,
              isTemp: true,
            );
          }
          continue;
        }

        final parsed = parseTileFileName(base);
        if (parsed == null) continue; // 非格文件名（含 .tmp / .db-wal 等）忽略
        tiles.add(
          BasemapPack(
            key: parsed.key,
            path: e.absolute.path,
            minLat: parsed.minLat,
            minLng: parsed.minLng,
            maxLat: parsed.maxLat,
            maxLng: parsed.maxLng,
            bytes: stat.size,
          ),
        );
      }
    }

    tiles.sort((a, b) => a.key.compareTo(b.key));
    _tiles = tiles;
    _temp = temp;
  }

  /// 与视口相交的格包（不含临时包）。
  List<BasemapPack> intersecting(
    double minLat,
    double minLng,
    double maxLat,
    double maxLng,
  ) => _tiles
      .where((p) => p.intersects(minLat, minLng, maxLat, maxLng))
      .toList(growable: false);

  /// 读临时包的真实 bbox（从它自己的 import_bounds）。
  ///
  /// 只对最多 1 个文件做一次 open，可接受。
  Future<(double, double, double, double)?> _readTempBounds(String path) async {
    Database? db;
    try {
      db = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      final rows = await db.rawQuery(
        'SELECT min_lat, min_lng, max_lat, max_lng FROM import_bounds LIMIT 1',
      );
      if (rows.isEmpty) return null;
      final r = rows.first;
      return (
        (r['min_lat'] as num).toDouble(),
        (r['min_lng'] as num).toDouble(),
        (r['max_lat'] as num).toDouble(),
        (r['max_lng'] as num).toDouble(),
      );
    } catch (_) {
      return null; // 损坏/半截的临时包直接忽略
    } finally {
      await db?.close();
    }
  }
}

/// 一次 [PackAttachManager.sync] 的结果（供进度条/日志/设置页展示）。
class AttachSyncResult {
  const AttachSyncResult({
    required this.attached,
    required this.detached,
    required this.kept,
    required this.overflow,
  });

  /// 本次新挂载的 key。
  final List<String> attached;

  /// 本次卸载的 key。
  final List<String> detached;

  /// 沿用未动的 key。
  final List<String> kept;

  /// 因超出 [kMaxAttachedPacks] 被丢弃的候选 key（按距视口中心由远到近）。
  final List<String> overflow;

  bool get changed => attached.isNotEmpty || detached.isNotEmpty;

  @override
  String toString() =>
      'Attach+${attached.length} -${detached.length} '
      '=${kept.length}${overflow.isEmpty ? '' : ' 超限丢弃${overflow.length}'}';
}

/// ATTACH / DETACH 生命周期管理。
///
/// **只做差量**：目标是「当前视口需要的包集合」，管理器比对已挂载集合，
/// 只 DETACH 不再需要的、只 ATTACH 新需要的 —— ATTACH 不复制数据，
/// 只打开文件句柄，成本很低，但也没必要每帧重挂。
///
/// 无状态化设计：不持有 Database；每次 [sync] 传入当前连接。
/// 这样它可以在单测里用内存库驱动。
class PackAttachManager {
  final Map<String, String> _aliasByKey = {};

  /// 当前已挂载：key -> alias。
  Map<String, String> get aliasByKey => Map.unmodifiable(_aliasByKey);

  /// 已挂载的 key 集合。
  Set<String> get attachedKeys => _aliasByKey.keys.toSet();

  bool isAttached(String key) => _aliasByKey.containsKey(key);

  /// 把已挂载集合调整为目标集合 [want]。
  ///
  /// - 超出 [kMaxAttachedPacks] 时，按「距视口中心 [centerLat]/[centerLng] 由近到远」
  ///   保留最近的若干个，其余记入 [AttachSyncResult.overflow]；
  /// - 未提供中心时按 key 升序保留。
  Future<AttachSyncResult> sync({
    required DatabaseExecutor db,
    required List<BasemapPack> want,
    double? centerLat,
    double? centerLng,
  }) async {
    // 1) 超限裁剪
    var target = want;
    final overflow = <String>[];
    if (target.length > kMaxAttachedPacks) {
      final sorted = [...target];
      if (centerLat != null && centerLng != null) {
        sorted.sort(
          (a, b) => _dist2(
            a,
            centerLat,
            centerLng,
          ).compareTo(_dist2(b, centerLat, centerLng)),
        );
      } else {
        sorted.sort((a, b) => a.key.compareTo(b.key));
      }
      target = sorted.take(kMaxAttachedPacks).toList(growable: false);
      final keep = target.map((p) => p.key).toSet();
      for (final p in sorted) {
        if (!keep.contains(p.key)) overflow.add(p.key);
      }
    }

    final wantKeys = {for (final p in target) p.key};

    // 2) DETACH 不再需要的
    final detached = <String>[];
    for (final key in _aliasByKey.keys.toList()) {
      if (wantKeys.contains(key)) continue;
      final alias = _aliasByKey.remove(key)!;
      await db.execute('DETACH DATABASE $alias');
      detached.add(key);
    }

    // 3) ATTACH 新需要的
    final attached = <String>[];
    for (final p in target) {
      if (_aliasByKey.containsKey(p.key)) continue;
      await db.execute('ATTACH DATABASE ${_sqlString(p.path)} AS ${p.alias}');
      _aliasByKey[p.key] = p.alias;
      attached.add(p.key);
    }

    final kept = _aliasByKey.keys
        .where(wantKeys.contains)
        .toList(growable: false);
    return AttachSyncResult(
      attached: attached,
      detached: detached,
      kept: kept,
      overflow: overflow,
    );
  }

  /// 卸载全部（关闭 App / 切库 / 清空底图时调用）。
  Future<void> detachAll(DatabaseExecutor db) async {
    for (final alias in _aliasByKey.values.toList()) {
      try {
        await db.execute('DETACH DATABASE $alias');
      } catch (_) {
        // 连接已断/库已关时忽略
      }
    }
    _aliasByKey.clear();
  }

  static double _dist2(BasemapPack p, double lat, double lng) {
    final dLat = p.centerLat - lat;
    final dLng = p.centerLng - lng;
    return dLat * dLat + dLng * dLng;
  }

  /// SQLite 字符串字面量转义（路径里可能出现单引号）。
  static String _sqlString(String s) => "'${s.replaceAll("'", "''")}'";
}
