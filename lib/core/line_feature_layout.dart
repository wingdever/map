/// 线上要素（店铺 / 墙体）的定位（docs/design/13-line-features.md §4）。
///
/// 需求一句话：
/// > 渲染时不再按权重逐个排布，而是**先看要素自己的中心点**；
/// > 中心点不在线上时，取**线上离它最近的点**作为中心点。
///
/// 这比"按权重沿线分配"更贴近现实：店铺的位置是量出来的，不是算出来的。
/// 老模型（权重）有一个很难受的副作用 —— 改一个门牌的权重，
/// 整条街上所有门牌的位置都会跟着挪。
///
/// **第十八章起"线"是折线**：定位的数学没变（投影到线上取最近点），
/// 但"线上"不再是一条直线段，而是一条折线 —— 投影、沿线比例、按宽度取跨度
/// 全部改走 `core/polyline.dart`。本文件仍是**唯一**的定位实现：
/// 店铺、墙体、门三者必须算出同一个位置，否则会出现"旗标画在这儿、
/// 点这儿却选不中"这类极难查的问题。
///
/// 纯 Dart、零依赖；UI 只负责把结果画出来。
library;

import 'dart:math' as math;

import 'geometry.dart';
import 'models.dart';
import 'polyline.dart';

/// 中心点与线的距离小于这个值（米）就算"本来就在线上"，不算吸附。
///
/// 0.5 m 是刻意的：GPS 快采的点几乎不可能精确落在线上，
/// 但用户手点线上时应当被认作"就在线上"（不提示吸附），
/// 否则每次保存都会看到一个"已吸附"的提示，很烦。
const double kOnLineEpsilonM = 0.5;

/// 定位结果（与具体是哪张表的行无关）—— 店铺 / 墙体 / 门共用同一套数学。
class LinePlacement {
  const LinePlacement({
    required this.position,
    required this.t,
    required this.snapped,
    required this.offsetM,
  });

  /// 最终渲染位置：中心点（已吸附到线上）。
  final GeoPoint position;

  /// 在所属线上的归一化位置 0..1。
  final double t;

  /// 是否发生了吸附（中心点原本不在线上）。
  final bool snapped;

  /// 吸附前中心点离线的距离（米）；未吸附时为 0。
  final double offsetM;
}

/// **定位的核心**：把一个中心点落到折线上。
///
/// 1. 中心点为空（或折线不足两点）→ 返回 null
///    （宁可这条不画，也不要随便找个位置糊上去）；
/// 2. 投影到折线（垂足落在折线外时取最近端点）；
/// 3. 投影距离 > [kOnLineEpsilonM] → 记为"已吸附"，UI 可据此提示。
///
/// 店铺、墙体、门都走这里 —— 三者的定位语义必须完全一致，否则"同一个门"
/// 会在渲染、命中检测、详情面板里算出三个不同的位置。
///
/// [t] 是**按折线总长**归一化的位置：折线时代只有这一种 t 有意义
/// （一条 100 m 的长边接一段 5 m 的短折，若按"第几段里的第几成"报，
/// 详情面板的"在线上的 50%"就是假话）。
LinePlacement? locateOnPath(GeoPoint? center, List<GeoPoint>? path) {
  if (center == null || path == null || path.length < 2) return null;
  final proj = projectOntoPath(center, path);
  if (proj == null) return null;
  return LinePlacement(
    position: proj.position,
    t: proj.t,
    snapped: proj.distanceM > kOnLineEpsilonM,
    offsetM: proj.distanceM,
  );
}

/// 两个端点的直线段版本（保留给"只有一条边、没有拐点"的老调用点）。
///
/// 实现上就是 [locateOnPath] 的特例 —— **不允许**再写一份自己的投影数学。
LinePlacement? locateOnLine(GeoPoint? center, GeoPoint start, GeoPoint end) =>
    locateOnPath(center, [start, end]);

/// 一个已定位的**线上要素**（店铺 / 墙体）。
class PlacedFeature {
  const PlacedFeature({required this.feature, required this.placement});

  final EntityRow feature;
  final LinePlacement placement;

  GeoPoint get position => placement.position;
  double get t => placement.t;
  bool get snapped => placement.snapped;
  double get offsetM => placement.offsetM;

  /// 要素沿线的跨度（米），由 [EntityRow.effectiveWidth] 决定。
  double get widthM => feature.effectiveWidth;
}

/// 一个已定位的**门**（第十五章：门和店铺一样吸附在界线上）。
class PlacedGate {
  const PlacedGate({required this.gate, required this.placement});

  final GateRow gate;
  final LinePlacement placement;

  GeoPoint get position => placement.position;
  double get t => placement.t;
  bool get snapped => placement.snapped;
  double get offsetM => placement.offsetM;

  /// 没挂线的门（老数据）不能吸附，只能按中心点画。
  bool get onLine => gate.lineId != null;
}

/// 把一条线上的要素定位好。
///
/// 规则：
/// 1. 没有中心坐标的要素**直接跳过** —— 宁可这条要素不画，
///    也不要随便找个位置糊上去（用户会以为数据错了）；
/// 2. 把中心点投影到**折线**上（垂足落在折线外时取最近端点）得到渲染位置；
/// 3. 投影距离 > [kOnLineEpsilonM] 时标记为"已吸附"，
///    UI 可以据此提示用户"这个点被拉回线上了"。
PlacedFeature? placeFeatureOnPath(EntityRow feature, List<GeoPoint>? path) {
  final placement = locateOnPath(feature.center, path);
  if (placement == null) return null;
  return PlacedFeature(feature: feature, placement: placement);
}

/// 两点版本的兼容包装（只有一条边的场景）。
PlacedFeature? placeFeatureOnLine(
  EntityRow feature,
  GeoPoint start,
  GeoPoint end,
) => placeFeatureOnPath(feature, [start, end]);

/// 把一个门定位到它吸附的**折线**上。
///
/// 门没挂线（老数据）时返回 null —— 调用方应当退化为"直接画在门自己的中心点上"，
/// 而不是把它整条丢掉。
PlacedGate? placeGateOnPath(GateRow gate, List<GeoPoint>? path) {
  final placement = locateOnPath(gate.center, path);
  if (placement == null) return null;
  return PlacedGate(gate: gate, placement: placement);
}

/// 两点版本的兼容包装。
PlacedGate? placeGateOnLine(GateRow gate, GeoPoint start, GeoPoint end) =>
    placeGateOnPath(gate, [start, end]);

/// 一条线上的全部门（按沿线位置排序）。
List<PlacedGate> placeGatesOnLine({
  required LineRow line,
  required Map<int, GeoPoint> pointsById,
  required Iterable<GateRow> gates,
}) {
  final path = polylineOf(line, pointsById);
  if (path == null) return const [];
  final out = <PlacedGate>[];
  for (final g in gates) {
    if (g.deletedAt != null || g.lineId != line.id) continue;
    final placed = placeGateOnPath(g, path);
    if (placed != null) out.add(placed);
  }
  out.sort((x, y) {
    final c = x.t.compareTo(y.t);
    if (c != 0) return c;
    return (x.gate.id ?? 0).compareTo((y.gate.id ?? 0));
  });
  return out;
}

/// 一条线上的全部要素（按沿线位置排序，方便列表/渲染稳定）。
List<PlacedFeature> placeFeaturesOnLine({
  required LineRow line,
  required Map<int, GeoPoint> pointsById,
  required Iterable<EntityRow> entities,
}) {
  final path = polylineOf(line, pointsById);
  if (path == null) return const [];

  final out = <PlacedFeature>[];
  for (final e in entities) {
    if (e.deletedAt != null) continue;
    if (e.lineId != line.id) continue;
    final placed = placeFeatureOnPath(e, path);
    if (placed != null) out.add(placed);
  }
  out.sort((x, y) {
    final c = x.t.compareTo(y.t);
    if (c != 0) return c;
    return (x.feature.id ?? 0).compareTo(y.feature.id ?? 0);
  });
  return out;
}

/// 取这条线上的一类要素（店铺 / 墙体）。
List<PlacedFeature> placeFeaturesOfType({
  required LineRow line,
  required Map<int, GeoPoint> pointsById,
  required Iterable<EntityRow> entities,
  required EntityType type,
}) => placeFeaturesOnLine(
  line: line,
  pointsById: pointsById,
  entities: entities,
).where((p) => p.feature.entityType == type).toList();

/// 沿线要素的中心点向前后各展开 `widthM/2`，得到它占据的那一段。
///
/// 用途：店铺画成一段门面、墙体段画成一段墙。
/// 结果会被裁到折线范围内（不会跑到线外面去），折线时代这是
/// `core/polyline.dart` 的 [spanAlongPath] 的转调 —— 距离必须**沿折线**量，
/// 否则拐弯处的墙体段会横穿到线外。
(GeoPoint, GeoPoint) spanAlongLine(
  GeoPoint start,
  GeoPoint end,
  double t,
  double widthM,
) => spanAlongPath([start, end], t, widthM);

/// 让要素的中心点**吸附到线上**（保存前调用）。
///
/// 与 [placeFeatureOnPath] 的区别：那个只算渲染位置、不改数据；
/// 这个返回一个已经把 center 换成线上最近点的 [EntityRow]，
/// 供"点击线上位置 → 直接落库"的路径使用。
EntityRow snapFeatureToPath(EntityRow feature, List<GeoPoint>? path) {
  if (path == null) return feature;
  // v12：中心坐标是 lat/lng 两个非空列（不再是可空的 center），所以直接拿来投影
  final proj = projectOntoPath(feature.center, path);
  if (proj == null) return feature;
  return feature.copyWith(lat: proj.position.lat, lng: proj.position.lng);
}

/// 详情面板用的一句人话。
String describePlacement(PlacedFeature p) {
  final parts = <String>['在线上的 ${(p.t * 100).round()}% 处'];
  if (p.snapped) {
    parts.add('（中心点离线 ${p.offsetM.round()} m，已吸附到最近点）');
  }
  return parts.join('');
}

/// 把宽度换算成"占这条线多少"（详情面板展示用）。
///
/// 分母是**折线总长**：折线时代按单段长度算会给出荒谬的比例
/// （一条 3 段的路，店铺宽度占"第一段"的 80% 并不说明它占了整条路的 80%）。
String describeWidthOnPath(double widthM, List<GeoPoint>? path) {
  final total = path == null ? 0.0 : pathLengthMeters(path);
  if (total <= 0) return '${widthM.toStringAsFixed(1)} m';
  final ratio = (widthM / total * 100).clamp(0, 100);
  return '${widthM.toStringAsFixed(1)} m（约占这条线的 ${ratio.round()}%）';
}

/// 两点版本的兼容包装。
String describeWidth(double widthM, GeoPoint start, GeoPoint end) =>
    describeWidthOnPath(widthM, [start, end]);

/// 数值收敛用（避免 -0.0 之类的显示问题）。
double tidy(double v) => (v.abs() < 1e-9) ? 0 : v;

/// 把数学上的 0..1 位置转成"从起点量多少米"。
double metersFromStartOnPath(List<GeoPoint> path, double t) =>
    pathLengthMeters(path) * t.clamp(0.0, 1.0);

/// 两点版本的兼容包装。
double metersFromStart(GeoPoint start, GeoPoint end, double t) =>
    metersFromStartOnPath([start, end], t);

/// 判断一条线是不是几乎水平/垂直（渲染时给标签选左右侧用）。
bool isMostlyHorizontal(GeoPoint a, GeoPoint b) =>
    (math.cos(b.lat * math.pi / 180) * (b.lng - a.lng)).abs() >=
    (b.lat - a.lat).abs();

/// 折线的整体走向是不是"更像东西向"（标签放上/下侧用）。
///
/// 折线不能只看首尾两点：一条先北后东的 L 形路，首尾连线是东北向，
/// 但它大部分长度其实是东西向的 —— 那就该把标签放在上下侧。
bool isMostlyHorizontalPath(List<GeoPoint> path) {
  if (path.length < 2) return true;
  var east = 0.0;
  var north = 0.0;
  for (var i = 0; i + 1 < path.length; i++) {
    final a = path[i];
    final b = path[i + 1];
    final kx = math.cos((a.lat + b.lat) / 2 * math.pi / 180);
    east += (b.lng - a.lng) * kx;
    north += b.lat - a.lat;
  }
  return east.abs() >= north.abs();
}
