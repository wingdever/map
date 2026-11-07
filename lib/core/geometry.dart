/// 几何原语（WGS-84，局部小范围使用；覆盖 3–5km 场景精度足够）
///
/// 设计来源：docs/design/05-routing.md §8 引擎接口草案。
/// 约定：角度一律为十进制度；距离单位为米；ring 顶点顺序按绘制顺序。
library;

import 'dart:math' as math;

/// 轻量经纬度点（core 层不依赖 latlong2，UI 层再转换）。
class GeoPoint {
  const GeoPoint(this.lat, this.lng);

  final double lat;
  final double lng;

  GeoPoint copyWith({double? lat, double? lng}) =>
      GeoPoint(lat ?? this.lat, lng ?? this.lng);

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() => 'GeoPoint($lat, $lng)';
}

const double _earthRadiusM = 6371000.0;
const double _degToRad = math.pi / 180.0;
const double _metersPerDegLat = 111320.0;

double _toRad(double deg) => deg * _degToRad;
double _cosDeg(double deg) => math.cos(deg * _degToRad);

/// 两点球面距离（米，Haversine）。
double distanceMeters(GeoPoint a, GeoPoint b) {
  final dLat = _toRad(b.lat - a.lat);
  final dLng = _toRad(b.lng - a.lng);
  final la1 = _toRad(a.lat);
  final la2 = _toRad(b.lat);
  final sinLat = math.sin(dLat / 2);
  final sinLng = math.sin(dLng / 2);
  final h = sinLat * sinLat + math.cos(la1) * math.cos(la2) * sinLng * sinLng;
  return 2 * _earthRadiusM * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
}

/// 点 p 到线段 a-b 的垂足（垂足落在线段外时取最近端点）。
GeoPoint projectPointToSegment(GeoPoint p, GeoPoint a, GeoPoint b) {
  final ax = a.lng;
  final ay = a.lat;
  final abx = b.lng - ax;
  final aby = b.lat - ay;
  final lenSq = abx * abx + aby * aby;
  if (lenSq == 0) return a;
  var t = ((p.lng - ax) * abx + (p.lat - ay) * aby) / lenSq;
  t = t.clamp(0.0, 1.0).toDouble();
  return GeoPoint(ay + aby * t, ax + abx * t);
}

/// 点 p 到线段 a-b 的垂直距离（米）。
double distancePointToSegmentMeters(GeoPoint p, GeoPoint a, GeoPoint b) {
  final foot = projectPointToSegment(p, a, b);
  return distanceMeters(p, foot);
}

/// 点 p 是否在多边形 ring 内（射线法；ring 无需显式闭合）。
bool pointInPolygon(GeoPoint p, List<GeoPoint> ring) {
  if (ring.length < 3) return false;
  var inside = false;
  var j = ring.length - 1;
  for (var i = 0; i < ring.length; i++) {
    final yi = ring[i].lat;
    final xi = ring[i].lng;
    final yj = ring[j].lat;
    final xj = ring[j].lng;
    final intersects =
        (yi > p.lat) != (yj > p.lat) &&
        p.lng < (xj - xi) * (p.lat - yi) / (yj - yi) + xi;
    if (intersects) inside = !inside;
    j = i;
  }
  return inside;
}

/// 点是否靠近多边形边界（容差 toleranceMeters 内）。用于边界吸附命中判断。
bool isNearPolygonBoundary(
  GeoPoint p,
  List<GeoPoint> ring,
  double toleranceMeters,
) {
  for (var i = 0; i < ring.length; i++) {
    final a = ring[i];
    final b = ring[(i + 1) % ring.length];
    if (distancePointToSegmentMeters(p, a, b) <= toleranceMeters) return true;
  }
  return false;
}

/// 线段 a-b 上比例 t(0..1) 处的点（小范围线性插值足够）。
GeoPoint pointOnSegmentAt(GeoPoint a, GeoPoint b, double t) {
  final c = t.clamp(0.0, 1.0).toDouble();
  return GeoPoint(a.lat + (b.lat - a.lat) * c, a.lng + (b.lng - a.lng) * c);
}

/// 在 a→b 方向、比例 t 处，向左（side=+1）/右（side=-1）垂直平移
/// offsetMeters 的点。用于"线上实体 + 垂直偏移"定位（03 章 §3.3）。
GeoPoint pointOffsetFromSegment(
  GeoPoint a,
  GeoPoint b,
  double t, {
  required double offsetMeters,
  int side = 1,
}) {
  if (offsetMeters == 0) return pointOnSegmentAt(a, b, t);
  final base = pointOnSegmentAt(a, b, t);
  final midLat = (a.lat + b.lat) / 2;
  final dx = (b.lng - a.lng) * _cosDeg(midLat); // 东向（米比例）
  final dy = b.lat - a.lat; // 北向
  final len = math.sqrt(dx * dx + dy * dy);
  if (len == 0) return base;
  // 左法线（东、北米坐标下的旋转）：(-dy, dx)/len
  final nx = -dy / len;
  final ny = dx / len;
  final dLat = ny * offsetMeters * side / _metersPerDegLat;
  final dLng =
      nx * offsetMeters * side / (_metersPerDegLat * _cosDeg(base.lat));
  return GeoPoint(base.lat + dLat, base.lng + dLng);
}

/// 多边形周长（米）。
double ringLengthMeters(List<GeoPoint> ring) {
  if (ring.length < 2) return 0;
  var sum = 0.0;
  for (var i = 0; i < ring.length; i++) {
    sum += distanceMeters(ring[i], ring[(i + 1) % ring.length]);
  }
  return sum;
}

/// 多边形面积（近似，m²；小范围用鞋带公式 + 米制坐标）。
double ringAreaMeters2(List<GeoPoint> ring, {GeoPoint? anchor}) {
  if (ring.length < 3) return 0;
  final a0 = anchor ?? ring.first;
  var sum = 0.0;
  for (var i = 0; i < ring.length; i++) {
    final p = ring[i];
    final q = ring[(i + 1) % ring.length];
    final x1 =
        (p.lng - a0.lng) * _cosDeg((p.lat + a0.lat) / 2) * _metersPerDegLat;
    final y1 = (p.lat - a0.lat) * _metersPerDegLat;
    final x2 =
        (q.lng - a0.lng) * _cosDeg((q.lat + a0.lat) / 2) * _metersPerDegLat;
    final y2 = (q.lat - a0.lat) * _metersPerDegLat;
    sum += x1 * y2 - x2 * y1;
  }
  return sum.abs() / 2;
}

/// 判定坐标环是否为 flutter_map 语义下的「顺时针」。
///
/// flutter_map 8 的 Polygon 填充仅对 isClockwise(points) 为 true 的点集生效；
/// 此函数与 flutter_map 8.3.2 `Polygon.isClockwise` 的实现逐字一致
/// （sum = Σ(lng_{i+1}-lng_i)·(lat_{i+1}+lat_i)；sum >= 0 视为顺时针），
/// 以便渲染层用本函数归一化方向后填充必定生效。
bool ringIsClockwise(List<GeoPoint> ring) {
  if (ring.length < 3) return true; // 退化环按顺时针处理
  var sum = 0.0;
  for (var i = 0; i < ring.length; i++) {
    final p = ring[i];
    final q = ring[(i + 1) % ring.length];
    sum += (q.lng - p.lng) * (q.lat + p.lat);
  }
  return sum >= 0;
}

/// 将坐标环归一化为 flutter_map 顺时针（若已满足则原样返回）。
List<GeoPoint> toClockwiseRing(List<GeoPoint> ring) {
  if (ring.length < 3) return List.of(ring);
  if (ringIsClockwise(ring)) return List.of(ring);
  return List.of(ring.reversed);
}

// ---------------------------------------------------------------------------
// 环的合法性
// ---------------------------------------------------------------------------

/// 坐标环是否为**简单环**（不自交）。
///
/// 从原 `area_draft.dart` 提升为几何原语：圈地（一笔画）与「用线围合」
/// 两条路径都需要它，而它本身与"草稿状态机"没有任何关系。
///
/// 判定：任意两条**非相邻**边是否真相交（端点接触不算自交 —— 相邻边本来就共享端点，
/// 而"顶点重复出现"要判为自交）。退化环（< 3 点）返回 false。
bool isSimpleRing(List<GeoPoint> ring) {
  final n = ring.length;
  if (n < 3) return false;
  // 顶点重复 = 自交（把 8 字形写成一个环的典型症状）
  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      if (ring[i] == ring[j]) return false;
    }
  }
  for (var i = 0; i < n; i++) {
    final a1 = ring[i];
    final a2 = ring[(i + 1) % n];
    for (var j = i + 1; j < n; j++) {
      // 跳过共享端点的相邻边组合
      if (j == i || j == (i + 1) % n || i == (j + 1) % n) continue;
      final b1 = ring[j];
      final b2 = ring[(j + 1) % n];
      if (_segmentsProperlyIntersect(a1, a2, b1, b2)) return false;
    }
  }
  return true;
}

/// 判断两条线段是否"真相交"（交点在两线段内部，非端点接触）。
bool _segmentsProperlyIntersect(
  GeoPoint a1,
  GeoPoint a2,
  GeoPoint b1,
  GeoPoint b2,
) {
  final o1 = _orientation(a1, a2, b1);
  final o2 = _orientation(a1, a2, b2);
  final o3 = _orientation(b1, b2, a1);
  final o4 = _orientation(b1, b2, a2);
  if (o1 == 0 || o2 == 0 || o3 == 0 || o4 == 0) return false; // 端点接触不算
  return (o1 != o2) && (o3 != o4);
}

/// 叉积符号（-1/0/1），用于自交检测。
int _orientation(GeoPoint p, GeoPoint q, GeoPoint r) {
  final v = (q.lng - p.lng) * (r.lat - p.lat) -
      (q.lat - p.lat) * (r.lng - p.lng);
  if (v > 1e-9) return 1;
  if (v < -1e-9) return -1;
  return 0;
}

/// 环的顶点平均值（够用即可；不做面积加权质心）。
GeoPoint? ringCentroid(List<GeoPoint>? ring) {
  if (ring == null || ring.isEmpty) return null;
  var lat = 0.0;
  var lng = 0.0;
  for (final p in ring) {
    lat += p.lat;
    lng += p.lng;
  }
  return GeoPoint(lat / ring.length, lng / ring.length);
}
