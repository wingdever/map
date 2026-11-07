/// **「封闭图形」抽象**（docs/design/23-data-structure.md §4.5）
///
/// v12 里"一块地"有两种构造：
///
/// | | `world_areas`（由**线**围成） | `world_polygons`（由**点**围成） |
/// |---|---|---|
/// | 环从哪来 | **推导**（组环算法，**可能失败**） | **存下来的**（链，永远有效） |
/// | 边的属性 | 有材质、能命名 | 没有边实体 |
/// | 挂门/要素 | 能 | **不能**（D21） |
///
/// 两者**同一语义**，所以命中测试、渲染填色、楼层过滤、导出、搜索都得
/// **同时认它们**。如果每个调用点各写一遍 `if (是 area) … else …`，
/// 那就又变成了"同一件事两套代码" —— 这个文件就是那个收口点。
///
/// 于是调用方只认 [ClosedShape]：
/// - 要环 → [ringPointIds]（null 表示取不出来，[ringError] 说明为什么）；
/// - 要坐标 → [ringGeo]；
/// - 要判命中 → [covers]；
/// - 要面积/质心/名字/颜色/楼层 → 直接读字段。
///
/// 纯 Dart、零依赖（同 `line_edit.dart` 的理由：能被 `tool/checks/` 脚本验证）。
library;

import 'floor_set.dart';
import 'geometry.dart';
import 'models.dart';
import 'ring.dart';

/// 一种封闭图形（区域或多边形）。构造走 [ClosedShape.ofArea] / [ClosedShape.ofPolygon]。
class ClosedShape {
  const ClosedShape({
    this.id,
    required this.domain,
    required this.name,
    required this.areaType,
    this.floors,
    required this.color,
    required this.byPoints,
    this.ringPointIds,
    this.ringError,
  });

  final int? id;
  final MapDomain domain;
  final String name;
  final AreaType areaType;
  final FloorSet? floors;

  /// 蒙层颜色（用户覆盖优先）。
  final int color;

  /// **构造方式**：true = 由点围成（多边形），false = 由线围成（区域）。
  ///
  /// 这是两者**唯一**的结构性区别，所以业务键必须带上它（否则同一块地
  /// 转过一次构造方式之后，导入时会被当成同一块地而静默丢掉一次转换）。
  final bool byPoints;

  /// 环上的点（按环序，首尾不重复）。**null = 取不出来**。
  ///
  /// 区域取不出来是因为**组环失败**（开口/分叉/接不上）；
  /// 多边形取不出来是因为**链坏了**。原因见 [ringError]。
  final List<int>? ringPointIds;

  /// 环取不出来时的一句话原因（给用户看）。
  final String? ringError;

  bool get isPolygon => byPoints;
  bool get isArea => !byPoints;

  /// 环有效吗（至少 3 个点）。
  bool get isClosed => (ringPointIds?.length ?? 0) >= 3;

  /// 用它拼 SQL 的表名。
  String get table => byPoints ? '${domain.prefix}_polygons' : domain.areasTable;

  /// 环的点坐标。取不出环或有点缺坐标时返回 null。
  List<GeoPoint>? ringGeo(Map<int, GeoPoint> pointById) {
    final ids = ringPointIds;
    if (ids == null || ids.length < 3) return null;
    final out = <GeoPoint>[];
    for (final pid in ids) {
      final g = pointById[pid];
      if (g == null) return null;
      out.add(g);
    }
    return out;
  }

  /// 这个点落在图形里吗（含边界附近）。
  ///
  /// ⚠️ **环取不出来时一律返回 false**：宁可点不中，也不要拿一个残缺的环去判命中
  /// —— 那会得到一个"看起来能点中、其实围错了"的区域。
  bool covers(GeoPoint p, Map<int, GeoPoint> pointById) {
    final ring = ringGeo(pointById);
    if (ring == null) return false;
    // 容差 1 m：与"点在边界上"的手感对齐（太大会把隔壁地块也判进来）
    return pointInPolygon(p, ring) || isNearPolygonBoundary(p, ring, 1.0);
  }

  /// 面积（平方米）。取不出环时为 null。
  double? areaM2(Map<int, GeoPoint> pointById) {
    final ring = ringGeo(pointById);
    if (ring == null) return null;
    return ringAreaMeters2(ring);
  }

  /// 环的**质心**（业务键用；取不出环时为 null）。
  GeoPoint? centroid(Map<int, GeoPoint> pointById) {
    final ring = ringGeo(pointById);
    if (ring == null) return null;
    return ringCentroid(ring);
  }

  /// 由**区域**构造：环要现场组（**可能失败** —— 这正是两者最大的差别）。
  factory ClosedShape.ofArea(AreaRow a, List<LineRow> memberLines) {
    try {
      final ids = assembleAreaRingVertexIds(memberLines);
      return ClosedShape(
        id: a.id,
        domain: a.domain,
        name: a.name,
        areaType: a.areaType,
        floors: a.floors,
        color: a.color,
        byPoints: false,
        ringPointIds: ids,
      );
    } on RingAssembleException catch (e) {
      return ClosedShape(
        id: a.id,
        domain: a.domain,
        name: a.name,
        areaType: a.areaType,
        floors: a.floors,
        color: a.color,
        byPoints: false,
        ringError: e.toString(),
      );
    }
  }

  /// 由**多边形**构造：环是存下来的（读链得来），永远有效。
  factory ClosedShape.ofPolygon(PolygonRow p, {String? ringError}) => ClosedShape(
    id: p.id,
    domain: p.domain,
    name: p.name,
    areaType: p.areaType,
    floors: p.floors,
    color: p.color,
    byPoints: true,
    ringPointIds: ringError == null ? p.pointIds : null,
    ringError: ringError,
  );
}
