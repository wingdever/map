import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geometry.dart';
import '../../core/models.dart';
import '../../data/app_repository.dart';
import '../../data/providers.dart';
import 'import_layer_providers.dart';

/// **形状引用**：域 + id。
///
/// 🔴 v12 起 **id 只在域内唯一** —— `world_lines.id = 1` 与 `way_lines.id = 1`
/// 是毫不相干的两条线，`world_areas.id = 2` 与 `zone_areas.id = 2` 也一样。
/// 所以在 UI 侧任何"用 id 找东西"的映射里，**域必须一起当键**，
/// 否则会出现"点中一堵墙却发现是另一条路"这种极难查的问题。
typedef ShapeRef = (MapDomain domain, int id);

/// 封闭图形 + 已组好的环（UI 展示单元）。
///
/// v12 有两种构造：**区域**（由线围成，环是推导的、**可能失败**）与
/// **多边形**（由点围成，环是存下来的、永远有效）。
/// 渲染与命中都只认这一个结构 —— 别处不要再分叉。
class AreaWithRing {
  const AreaWithRing({
    required this.area,
    required this.ring,
    required this.domain,
    this.isPolygon = false,
    this.ringError,
  });

  /// 区域行；多边形时是**从 PolygonRow 转出来的等价物**（名字/类型/楼层/颜色）。
  final AreaRow area;

  final MapDomain domain;

  /// 可为 null（区域未闭合/数据异常时 UI 仅显示列表）。
  final List<GeoPoint>? ring;

  /// true = 由**点**围成（多边形）。业务键与"能不能挂门"都看它。
  final bool isPolygon;

  /// 环取不出来时的一句话原因（给 UI 提示）。
  final String? ringError;

  int? get id => area.id;

  ShapeRef? get ref => id == null ? null : (domain, id!);

  String get name => area.name;
}

/// 地图图层数据（用户层全量），一次异步装载。
///
/// v12 起用户层是**三个域**，所以这里不再是一个大列表，而是"按域分组"：
/// 渲染时一条线要拿自己域的点去算几何（`pointsOf(line.domain)`），
/// 命中时一个 id 要配对自己的域（[ShapeRef]）。
class MapLayersData {
  MapLayersData({
    required this.areas,
    required this.gates,
    this.points = const [],
    this.lines = const [],
    this.entities = const [],
    this.marks = const [],
    this.trips = const [],
  });

  /// 全部封闭图形（区域 + 多边形，两种构造混在一起 —— UI 不必区分，
  /// 只在"能不能挂门/怎么来的"这类地方看 [AreaWithRing.isPolygon]）。
  final List<AreaWithRing> areas;

  final List<GateRow> gates;

  /// 全部几何点（三个域合在一起；每行自带 `domain`）。
  final List<PointRow> points;

  /// 全部线（三个域合在一起；每行自带 `domain`）。
  final List<LineRow> lines;

  /// 世界要素（店铺 / 楼栋 / 单元 / 常送点 / 停车点）。
  final List<EntityRow> entities;

  /// 记录点（"我在这儿"）—— **浏览态地图上显示的就是它**。
  final List<WorldMarkRow> marks;

  /// 轨迹段摘要（渲染轨迹要另外取点，见 `way_marks`）。
  final List<TripSummary> trips;

  /// **按域分开的点坐标表**。
  ///
  /// 调用方拿 `pointsOf(line.domain)` 去喂 `polylineOf` —— 这样
  /// `core/polyline.dart` 的签名不用改，而域之间也不会串味。
  Map<int, GeoPoint> pointsOf(MapDomain d) => _pointsByDomain[d] ?? const {};

  /// 整个"域 → 点坐标"表（命中测试要它：它一次判所有域的线）。
  Map<MapDomain, Map<int, GeoPoint>> get pointsByDomain => _pointsByDomain;

  late final Map<MapDomain, Map<int, GeoPoint>> _pointsByDomain = () {
    final out = <MapDomain, Map<int, GeoPoint>>{
      for (final d in MapDomain.values) d: <int, GeoPoint>{},
    };
    for (final p in points) {
      if (p.id == null) continue;
      out[p.domain]![p.id!] = p.geo;
    }
    return out;
  }();

  /// `(域, id) → 线`（围合区域时校验"是否首尾相接"、面板找线都要用）。
  late final Map<ShapeRef, LineRow> linesByRef = {
    for (final l in lines)
      if (l.id != null) (l.domain, l.id!): l,
  };

  /// `(域, id) → 环`（点选时"取面积最小的那个"要用）。
  late final Map<ShapeRef, List<GeoPoint>> ringsByRef = {
    for (final aw in areas)
      if (aw.ref != null && aw.ring != null) aw.ref!: aw.ring!,
  };

  /// 全部店铺（`entity_type == shop`）。
  List<EntityRow> get shops =>
      entities.where((e) => e.entityType == EntityType.shop).toList();
}

/// 地图图层数据源；编辑提交后 invalidate 以刷新。
///
/// **进度上报**：每段 IO 同步在 [mapDataProgressProvider] 上写一次。
/// importLayerProvider 共享同一进度枚举，方便顶层状态条统一呈现。
///
/// **finish 时机**：mapLayersProvider 不主动调 `progress.finish()`——
/// importLayerProvider 在更上层（驱动导入层 + 用户层的"完结"）。
/// 这避免了双重 finish 互相覆盖的丢帧。
final mapLayersProvider = FutureProvider.autoDispose<MapLayersData>((
  ref,
) async {
  final repo = ref.watch(repositoryProvider);
  final progress = ref.read(mapDataProgressProvider.notifier);
  // **Build 期跨 provider 写 state 是反模式** —— 改用 scheduleMicrotask 把
  // 进度写推到订阅者 build 之后；否则在 importLayerProvider build 期间这里
  // 触发 report 会抛 "The Provider modified while building"。
  void report(MapDataPhase phase, String details) {
    scheduleMicrotask(() {
      if (ref.mounted) progress.report(phase, details: details);
    });
  }

  // ---- 点与线：三个域各读一次（域决定表名）----
  report(MapDataPhase.bounds, "三个域：points / lines");
  final points = <PointRow>[];
  final lines = <LineRow>[];
  for (final d in MapDomain.values) {
    points.addAll(await repo.listPoints(d));
    lines.addAll(await repo.listLines(d));
  }

  // ---- 封闭图形：区域（两个域）+ 多边形（世界域）----
  report(MapDataPhase.areas, "areas / polygons");
  final shapes = <AreaWithRing>[];
  for (final d in AppRepository.areaDomains) {
    for (final a in await repo.listAreas(d)) {
      if (a.id == null) {
        shapes.add(AreaWithRing(area: a, ring: null, domain: d));
        continue;
      }
      report(MapDataPhase.areas, "areaRing(${d.prefix} #${a.id})");
      // 区域的环是**推导**出来的（按边建图组环）—— 组不出来就只是列表可见
      final ring = await repo.areaRing(d, a.id!);
      shapes.add(
        AreaWithRing(
          area: a,
          ring: ring,
          domain: d,
          ringError: ring == null ? '这几条线围不成一个闭合的环' : null,
        ),
      );
    }
  }
  final coordsByDomain = await repo.pointCoordsByDomain();
  for (final pg in await repo.listPolygons(MapDomain.world)) {
    if (pg.id == null) continue;
    final pts = coordsByDomain[pg.domain]!;
    final ring = <GeoPoint>[
      for (final id in pg.pointIds)
        if (pts[id] != null) pts[id]!,
    ];
    shapes.add(
      AreaWithRing(
        // 多边形与区域**同一语义**，所以这里把它转成同一个展示结构；
        // 渲染/命中就不用再分叉（`isPolygon` 仍留着供"能不能挂门"之类判断）
        area: AreaRow(
          id: pg.id,
          domain: pg.domain,
          name: pg.name,
          areaType: pg.areaType,
          floors: pg.floors,
          colorOverride: pg.colorOverride,
          sortOrder: pg.sortOrder,
        ),
        ring: ring.length >= 3 ? ring : null,
        domain: pg.domain,
        isPolygon: true,
        ringError: ring.length >= 3 ? null : '这个多边形少于 3 个点',
      ),
    );
  }

  // ---- 世界图特有的：门 / 世界要素 / 记录点 ----
  report(MapDataPhase.gates, "world_gates / world_entities / world_marks");
  final gates = await repo.listGates();
  final entities = await repo.listEntities();
  final marks = await repo.listWorldMarks();
  final trips = await repo.listTrips();

  return MapLayersData(
    areas: shapes,
    gates: gates,
    points: points,
    lines: lines,
    entities: entities,
    marks: marks,
    trips: trips,
  );
});

/// 导入层区域摘要（未导入 = null）。
final importBoundsProvider =
    FutureProvider.autoDispose<ImportBoundsRow?>((ref) async {
  final repo = ref.watch(repositoryProvider);
  return repo.getImportBounds();
});
