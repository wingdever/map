import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geometry.dart';
import '../../data/app_repository.dart';
import '../../data/basemap_packs.dart';
import '../../data/providers.dart';

import 'import_defaults.dart';

/// 地图当前视口（经纬度 bbox），用于导入层按视口裁剪查询（R-07 视口策略）。
class MapViewport {
  const MapViewport(this.minLat, this.minLng, this.maxLat, this.maxLng);

  final double minLat;
  final double minLng;
  final double maxLat;
  final double maxLng;
}

/// 10 号线走廊默认中心（约在平湖—大运中部，覆盖深圳地铁 10 号线沿线）。
///
/// 这里只取数字坐标，避免 provider 层依赖 `latlong2`（UI 才需要 LatLng）。
/// map_page 的 `kCorridorCenter` 与这里保持一致；任何一方改动都要同步。
///
/// 数字来历：corridor.osmapp 的 bounds ≈ (22.65, 114.10, 22.76, 114.28)，
/// 几何中心 = ((22.65+22.76)/2, (114.10+114.28)/2) ≈ (22.705, 114.190)，
/// 与用户真实活动区域（平湖 ⇄ 愉园）的中段吻合。
const double kCorridorCenterLat = 22.705;
const double kCorridorCenterLng = 114.190;

/// 首屏视口的半边长（≈ 5.5km，与 map_page 的 initState 初始视口一致）。
///
/// 选用这个值的原因：与 map_page 的「默认中心 ± 跨度」完全同步——
/// importLayerProvider 在 build 期间拿不到 mapViewportProvider 的值（map_page
/// 用 addPostFrameCallback 延后写入），需要一个保证有 bbox 的兜底视图，
/// 否则会走"全量扫表 + IN 子句超 999 上限"路径（见第二轮修复记录）。
///
/// 之前以 95 万级凤岗+龙岗为基线；现在走廊只有 19 万级，但视口策略本身不变。
const double kInitialViewportSpan = 0.05;

/// 首屏兜底视口（vp==null 时使用，等价于 map_page initState 写入的初始值）。
final MapViewport kInitialViewport = MapViewport(
  kCorridorCenterLat - kInitialViewportSpan,
  kCorridorCenterLng - kInitialViewportSpan,
  kCorridorCenterLat + kInitialViewportSpan,
  kCorridorCenterLng + kInitialViewportSpan,
);

/// 当前地图视口（相机移动时由 map_page 防抖更新）。
/// 初始为 null；map_page 在 initState 用默认中心初始化，避免无视口时全量加载。
class MapViewportNotifier extends Notifier<MapViewport?> {
  @override
  MapViewport? build() => null;

  void update(MapViewport? v) => state = v;
}

final mapViewportProvider = NotifierProvider<MapViewportNotifier, MapViewport?>(
  MapViewportNotifier.new,
);

/// 导入层可见性开关（07 章 §5.2）。
class ImportVisibility {
  const ImportVisibility({
    this.roads = true,
    this.buildings = true,
    this.pois = true,
  });

  final bool roads;
  final bool buildings;
  final bool pois;

  bool get nothingVisible => !roads && !buildings && !pois;

  ImportVisibility copyWith({bool? roads, bool? buildings, bool? pois}) =>
      ImportVisibility(
        roads: roads ?? this.roads,
        buildings: buildings ?? this.buildings,
        pois: pois ?? this.pois,
      );
}

final importVisibilityProvider =
    NotifierProvider<ImportVisibilityController, ImportVisibility>(
      ImportVisibilityController.new,
    );

class ImportVisibilityController extends Notifier<ImportVisibility> {
  @override
  ImportVisibility build() => const ImportVisibility();

  void toggleRoads() => state = state.copyWith(roads: !state.roads);
  void toggleBuildings() => state = state.copyWith(buildings: !state.buildings);
  void togglePois() => state = state.copyWith(pois: !state.pois);
}

// ---------------------------------------------------------------------------
// 地图数据加载进度：合并用户层 + 导入层两个来源的阶段，UI 只看这一条。
// ---------------------------------------------------------------------------

/// 地图首页加载的阶段枚举。
///
/// 顺序固定：`checking` → `areas` → `gates` → `bounds` → `import_roads` →
/// `import_pois` → `import_nodes` → `done`。
///
/// - `import_*` 阶段仅在已安装导入层时触发；无导入层直接跳到 `done`。
/// - `bounds` 阶段读 schema_meta；它非常快，用做「导入层是否在线」的过渡态。
enum MapDataPhase {
  /// 数据库打开 / 检查数据状态（瞬时，主要给"首帧加载中"一个稳定相位）。
  checking,

  /// 读取用户区块列表（areas）。
  areas,

  /// 读取门列表（gates）。
  gates,

  /// 读取导入层范围（import_bounds）。
  bounds,

  /// 读取视口内的路（import_ways）。
  importRoads,

  /// 读取视口内的兴趣点（import_pois）。
  importPois,

  /// 按节点 osm_id 批量拉坐标（包内 import_nodes，仅当视口内有路时触发）。
  importNodes,

  /// 扫描底图包目录（[PackRegistry.scan]，只做 listSync + stat）。
  scanningPacks,

  /// 解包内置底图包（首启 / rescan 时从 asset 落到包目录）。
  extractingPacks,

  /// 非阶段性的提示行（包数超限 / 缩放低于下限 / 视口内无路等）。
  /// 只用于把 details 写到状态条第二行，不推进进度。
  importingNote,

  /// 全部加载完成。
  done,
}

/// 单次进度值（phase + tick + details），tick 用来让 indeterminate ProgressIndicator 不退化为静止。
/// [details] 是当前 IO 命中点的可读字符串（例如 `_db.query('areas')` / `listAreas()`），
/// 供顶层状态条第二行做 monospace 细节提示。
class MapDataProgress {
  const MapDataProgress(this.phase, this.tick, {this.details});
  final MapDataPhase phase;
  final int tick;
  final String? details;

  MapDataProgress copyWith({MapDataPhase? phase, int? tick, String? details}) =>
      MapDataProgress(
        phase ?? this.phase,
        tick ?? this.tick,
        details: details ?? this.details,
      );
}

/// 单例进度 provider。被 [importLayerProvider] / mapLayersProvider 写入，
/// 被 map_page 顶层状态条读取。
class MapDataProgressNotifier extends Notifier<MapDataProgress?> {
  /// 当 `begin()` / `report()` 在同一 microtask 连续触发、导致 state 还没消费到
  /// checking 帧就立刻被覆盖时，先把 details 缓存在这里；下一次成功写入
  /// state 时把缓存细节并入，避免「阶段看起来在跳、但细节那行永远是 _openDatabase」的丢帧。
  MapDataPhase? _stagedPhase;
  String? _stagedDetails;

  @override
  MapDataProgress? build() => null;

  /// 开始一次加载。把状态置为 `checking`，UI 立即可见。
  void begin({String? details}) {
    _stagedPhase = MapDataPhase.checking;
    _stagedDetails = details ?? _stagedDetails;
    state = MapDataProgress(_stagedPhase!, 0, details: _stagedDetails);
  }

  /// 进入新阶段。已完成/已清空时不更新，避免被旧 callback 覆盖。
  ///
  /// 关键：`finish()` 之后我们**不再自动清空** state。理由：mapLayersProvider 的
  /// areaRing 循环可能晚于 importLayerProvider 的 finish() 触发 report；如果 600ms
  /// 后把 state 清成 null，areaRing 的 report 会被这里的 `if (cur == null) return`
  /// 静默吃掉，导致 UI 卡在 gates 阶段不动、而 areaRing 还在跑。
  ///
  /// 改为：「done 阶段之后接到的 report 不再忽略，但需要新 begin 才覆盖」。
  /// 实际的"进度条隐藏"逻辑改由 UI 层在收到 done + 持续 600ms 无更新后才清空，
  /// 见 map_page 的 _statusBar 进度分支。
  void report(MapDataPhase phase, {String? details}) {
    _stagedPhase = phase;
    if (details != null) _stagedDetails = details;
    final cur = state;
    // 只有"从未开始过"（cur == null）才丢帧；finish 后的 state 仍是 done，
    // 允许后续 report 接管并继续推进。
    if (cur == null) return;
    state = MapDataProgress(phase, cur.tick + 1, details: _stagedDetails);
  }

  /// 标记完成。把 state 置为 `done`，但**不**自动清空——等待 UI 看到 done 后
  /// 自己决定何时清（map_page 用一个 600ms 计时器）。
  void finish() {
    _stagedPhase = MapDataPhase.done;
    _stagedDetails ??= '即将完成';
    state = MapDataProgress(MapDataPhase.done, 999, details: _stagedDetails);
  }

  /// 立即清空（错误路径 / UI 主动关闭）。
  void clear() {
    _stagedPhase = null;
    _stagedDetails = null;
    state = null;
  }
}

/// 进度条最少保留可见时长（移到 UI 层控制，见 map_page._statusBar）。
const Duration kMinProgressVisible = Duration(milliseconds: 600);

// ---------------------------------------------------------------------------
// 当前地图缩放级别（map_page 在 onMapEvent 里同步写入，UI / 绘制层共用）
// ---------------------------------------------------------------------------

/// 当前 FlutterMap 的 zoom（double，12.0 ~ 19.0）。
///
/// 由 map_page 的 `_onMapEvent` 同步写入。**仅 zoom 整数部分变化时不主动触发**
/// importLayerProvider 重查（避免每帧抖动）。状态条、_buildImportLayers
/// 内的 zoom 阈值过滤都从这里读取。
class MapZoomNotifier extends Notifier<double> {
  @override
  double build() => 15.0; // 与 map_page.initialZoom 一致。

  void update(double z) {
    // 仅当整数部分变化时才写 state，避免每像素缩放都触发 widget rebuild。
    if (z.floor() != state.floor() || (z - state).abs() > 0.5) {
      state = z;
    }
  }
}

final mapZoomProvider = NotifierProvider<MapZoomNotifier, double>(
  MapZoomNotifier.new,
);

/// 各 zoom 档位的渲染阈值（与 `kImportLayerZoom*` 配套使用）。
///
/// **核心策略**：缩得越远，越只显示主干 / 大型 POI；zoom 越近才把全部细节摆出来。
/// - zoom ≤ 13：远景。**只显示主干路**（costClass='cycleway' 或 highway 主干道）
///                + **大型 POI**（amenity in {mall,hospital,school,station,subway,bus_station,airport}）。
/// - zoom == 14：过渡。路全显示但 POI 仍只看带 name 的。
/// - zoom ≥ 15：近景。路/建筑/POI 全显示。
///
/// 数据查询阶段 [queryImportLayer] 也按这档阈值过滤；绘制阶段 [_buildImportLayers]
/// 再兜一道。
class ImportLayerZoomPolicy {
  const ImportLayerZoomPolicy({
    required this.showAllRoads,
    required this.showWalkRoads,
    required this.showBuildings,
    required this.showAllPois,
    required this.poiNameRequired,
  });

  final bool showAllRoads;
  final bool showWalkRoads;
  final bool showBuildings;
  final bool showAllPois;
  final bool poiNameRequired;

  static ImportLayerZoomPolicy forZoom(double z) {
    final zi = z.floor();
    if (zi <= 13) {
      return const ImportLayerZoomPolicy(
        showAllRoads: false,
        showWalkRoads: false,
        showBuildings: false,
        showAllPois: false,
        poiNameRequired: true,
      );
    }
    if (zi == 14) {
      return const ImportLayerZoomPolicy(
        showAllRoads: true,
        showWalkRoads: false,
        showBuildings: true,
        showAllPois: false,
        poiNameRequired: true,
      );
    }
    return const ImportLayerZoomPolicy(
      showAllRoads: true,
      showWalkRoads: true,
      showBuildings: true,
      showAllPois: true,
      poiNameRequired: false,
    );
  }
}

final mapZoomPolicyProvider = Provider<ImportLayerZoomPolicy>((ref) {
  return ImportLayerZoomPolicy.forZoom(ref.watch(mapZoomProvider));
});

final mapDataProgressProvider =
    NotifierProvider<MapDataProgressNotifier, MapDataProgress?>(
      MapDataProgressNotifier.new,
    );

/// 阶段中文文案（顶部状态条右侧文案）。
String mapDataPhaseLabel(MapDataPhase phase) {
  switch (phase) {
    case MapDataPhase.checking:
      return '正在打开本地数据库…';
    case MapDataPhase.areas:
      return '正在加载区块…';
    case MapDataPhase.gates:
      return '正在加载门…';
    case MapDataPhase.bounds:
      return '正在检查导入层…';
    case MapDataPhase.importRoads:
      return '正在查视口内路…';
    case MapDataPhase.importPois:
      return '正在查视口内兴趣点…';
    case MapDataPhase.importNodes:
      return '正在加载节点坐标…';
    case MapDataPhase.scanningPacks:
      return '正在扫描底图包…';
    case MapDataPhase.extractingPacks:
      return '正在解包内置底图…';
    case MapDataPhase.importingNote:
      return '底图提示';
    case MapDataPhase.done:
      return '即将完成…';
  }
}

// ---------------------------------------------------------------------------
// 导入层数据源（视口变更 / 切换标签后会重新跑）
// ---------------------------------------------------------------------------

/// 导入层数据源：存在导入数据时按当前视口裁剪加载（视口变化/替换后 invalidate 刷新）。
///
/// **视口兜底**（第三轮修复）：`ref.watch(mapViewportProvider)` 在 build 期间是 null
/// （map_page 用 addPostFrameCallback 延后写入首屏视口）。如果走 `vp == null` 分支去
/// 全量扫表，会触发"无 WHERE 扫 95 万行 import_ways + IN 子句超 999 上限"，
/// 把 sqflite 串行队列堵死、连带把 mapLayersProvider 的 `_db.query('gates')` 顶
/// 在队列后等几十秒——这是用户看到的"卡在 _db.query('gates')"的真正根因。
///
/// 改为：vp==null 时用 [kInitialViewport] 兜底（与 map_page.initState 写入的初始
/// 视口完全一致），统一走视口路径；后续 initState 真正写入时 mapViewportProvider
/// 触发 invalidate 让本 provider 重跑一次，用真实视口再裁一次。
///
/// **进度上报**：每进一个阶段都通过 [MapDataPhase] 在 [mapDataProgressProvider]
/// 上写一次。该 provider 在 map_page 顶部状态条被订阅，保证写一次就有一次 UI 重建。
final importLayerProvider = FutureProvider.autoDispose<ImportLayerView?>((
  ref,
) async {
  final repo = ref.watch(repositoryProvider);
  final progress = ref.read(mapDataProgressProvider.notifier);

  // **Build 期跨 provider 写 state 是反模式（Riverpod 3 会在被订阅者 build
  // 期间写 state 时抛 "The Provider modified while building"）。** 必须让
  // 出当前 microtask，让订阅本 provider 的 widget 先 build 完再写 progress。
  // 一句 scheduleMicrotask 即可——下一帧进度条显示「正在打开本地数据库…」。
  scheduleMicrotask(() {
    if (ref.mounted) {
      progress.begin(details: '_openDatabase(repo)');
    }
  });

  // 让 UI 至少重建一帧「正在打开数据库」的瞬间，避免后续 await 直接抹掉它。
  await Future<void>.delayed(Duration.zero);

  // **v3 关键顺序**：先确保内置底图包已解包到包目录，再查询。
  //
  // 必须严格串行，否则会出现两个症状（同一个竞态根因）：
  //   1. 首启时 hasImportLayer() 在解包完成前返回 false → 底图为空，
  //      且没有任何东西 invalidate 本 provider → 必须切 Tab 才恢复；
  //   2. 解包完成后 report(scanningPacks) 会把已经落地的 done 覆盖掉
  //      → map_page 的隐藏逻辑（要求 phase==done）永远不触发 → 进度条卡住。
  //
  // 正常启动时这里是零 IO 快路径（marker 版本一致 + 4 个文件齐全 → 直接返回）。
  await ensureBundledPacks(repo, progress: progress);

  final hasImport = await repo.hasImportLayer();
  if (!hasImport) {
    scheduleMicrotask(() {
      if (ref.mounted) progress.finish();
    });
    return null;
  }
  try {
    // 视口兜底：build 期 vp 还是 null 时用首屏兜底视图，禁用全量分支（见上方注释）。
    final rawVp = ref.watch(mapViewportProvider);
    final vp = rawVp ?? kInitialViewport;
    final String bboxTag =
        "[${vp.minLat.toStringAsFixed(4)},${vp.minLng.toStringAsFixed(4)},"
        "${vp.maxLat.toStringAsFixed(4)},${vp.maxLng.toStringAsFixed(4)}]";
    final isInitialFallback = rawVp == null;
    // **第二处防 build 期间写**：onPhase 是 sqflite 同步路径里调 report 的——
    // 若 queryImportLayer 同步进入第一个 phase（roads），会踩在订阅者 build 中。
    // 用 scheduleMicrotask 包一层，回退到 microtask 队列里写。
    void guardedReport(ImportLayerPhase p) {
      scheduleMicrotask(() {
        if (!ref.mounted) return;
        switch (p) {
          case ImportLayerPhase.roads:
            progress.report(
              MapDataPhase.importRoads,
              details:
                  "_db.query('import_ways' WHERE $bboxTag)"
                  "${isInitialFallback ? ' [兜底视口]' : ''}",
            );
          case ImportLayerPhase.pois:
            progress.report(
              MapDataPhase.importPois,
              details:
                  "_db.query('import_pois' WHERE $bboxTag)"
                  "${isInitialFallback ? ' [兜底视口]' : ''}",
            );
          case ImportLayerPhase.nodes:
            progress.report(
              MapDataPhase.importNodes,
              details:
                  '_db.query(\'import_nodes\' IN <way节点id>)'
                  "${isInitialFallback ? ' [兜底视口]' : ''}",
            );
          case ImportLayerPhase.done:
            progress.report(MapDataPhase.done, details: '拼装 ImportLayerView…');
        }
      });
    }

    // v3：非阶段性的提示（包数超限 / 缩放低于下限 / 视口内无路）也走进度条的
    // details 行，方便在真机上肉眼判断底图为空的原因。
    void guardedNote(String note) {
      scheduleMicrotask(() {
        if (!ref.mounted) return;
        progress.report(MapDataPhase.importingNote, details: note);
      });
    }

    final zoom = ref.watch(mapZoomProvider);
    final view = await repo.queryImportLayer(
      minLat: vp.minLat,
      minLng: vp.minLng,
      maxLat: vp.maxLat,
      maxLng: vp.maxLng,
      zoomLevel: zoom,
      onPhase: guardedReport,
      onNote: guardedNote,
    );
    return view;
  } finally {
    scheduleMicrotask(() {
      if (ref.mounted) progress.finish();
    });
  }
});

// ---------------------------------------------------------------------------
// 点选命中辅助函数（M2c）
// ---------------------------------------------------------------------------

/// 容差内命中最近 POI（M2c 点选）。返回 null = 未命中。
(ImportPoiView, double)? hitNearestPoi(
  List<ImportPoiView> pois,
  GeoPoint p, {
  double maxDistanceM = 25,
}) {
  (ImportPoiView, double)? best;
  for (final poi in pois) {
    final d = distanceMeters(p, GeoPoint(poi.lat, poi.lng));
    if (d <= maxDistanceM && (best == null || d < best.$2)) {
      best = (poi, d);
    }
  }
  return best;
}

/// 容差内命中最近道路折线（点到多段线距离，M2c 点选）。
(ImportWayView, double)? hitNearestWay(
  List<ImportWayView> ways,
  GeoPoint p, {
  double maxDistanceM = 25,
}) {
  (ImportWayView, double)? best;
  for (final w in ways) {
    if (w.kind.storage == 'road' && w.coords.length < 2) continue;
    var minD = double.infinity;
    for (var i = 0; i + 1 < w.coords.length; i++) {
      final d = distancePointToSegmentMeters(p, w.coords[i], w.coords[i + 1]);
      if (d < minD) minD = d;
    }
    if (minD <= maxDistanceM && (best == null || minD < best.$2)) {
      best = (w, minD);
    }
  }
  return best;
}
