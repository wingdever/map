/// **折线几何**（docs/design/18-polyline-lines.md §4）。
///
/// 第十八章之前，"一条线"在代码里到处都是 `(start, end)` 两个点：
/// 渲染、命中检测、店铺/墙体/门的定位、面积组环……各自把两个点当成一条直线段。
/// 线一旦能拐弯，这些地方全部会**悄悄把它拉直**（不报错、不崩溃，就是画错），
/// 所以折线的几何必须收口到一个文件里，别的模块只准从这里拿结论。
///
/// 与 [LineRow] 的分工：
/// - [LineRow.pointIds] 说的是"这条线由哪些**点 id** 组成"（数据）；
/// - 本文件说的是"这些点连起来是什么**形状**"（几何）。
///
/// 纯 Dart、零依赖、不 import flutter；所有距离单位为米。
library;

import 'dart:math' as math;

import 'geometry.dart';
import 'models.dart';

/// 折线顶点 id → 坐标序列（按绘制顺序）。
///
/// **任何一个顶点查不到坐标就返回 null**（整条线不画）：缺一个拐点的折线
/// 如果"跳过它继续连"，画出来是一条**穿过建筑物的假直线** —— 那比不画更糟，
/// 因为用户会照着自己看到的线去找路。宁可让它暂时不显示（数据修好就回来）。
List<GeoPoint>? polylineOf(LineRow line, Map<int, GeoPoint> pointsById) {
  final out = <GeoPoint>[];
  for (final id in line.pointIds) {
    final p = pointsById[id];
    if (p == null) return null;
    // 相邻重复顶点（同一个点既是起点又是拐点这类脏数据）会让"段长 0"、
    // 投影分母为 0，这里直接吞掉：几何上它不贡献任何形状。
    if (out.isNotEmpty && out.last == p) continue;
    out.add(p);
  }
  return out.length >= 2 ? out : null;
}

/// 一组线用到的**全部顶点 id**（含拐点）。
///
/// 组环、导出、迁移前的取坐标都要用它 —— 只取 `start/end` 的老写法
/// 会漏掉拐点，症状是"点明明存在，却报缺少顶点坐标"。
Set<int> vertexIdsOf(Iterable<LineRow> lines) {
  final ids = <int>{};
  for (final l in lines) {
    ids.addAll(l.pointIds);
  }
  return ids;
}

/// 折线总长（米）。少于两个点返回 0（不闭合 —— 它是一条路，不是一个环）。
double pathLengthMeters(List<GeoPoint> path) {
  if (path.length < 2) return 0;
  var sum = 0.0;
  for (var i = 0; i + 1 < path.length; i++) {
    sum += distanceMeters(path[i], path[i + 1]);
  }
  return sum;
}

/// 点 [p] 在折线上的**投影结果**。
class PathProjection {
  const PathProjection({
    required this.position,
    required this.alongM,
    required this.totalM,
    required this.segmentIndex,
    required this.distanceM,
  });

  /// 折线上离 [p] 最近的点（垂足；落在折线两端之外时取端点）。
  final GeoPoint position;

  /// 从**起点**沿折线量到 [position] 的距离（米）。
  final double alongM;

  /// 折线总长（米）。
  final double totalM;

  /// [position] 落在第几段上（0 起）。渲染墙体段时要知道它在哪一段上。
  final int segmentIndex;

  /// [p] 到折线的距离（米）。
  final double distanceM;

  /// 沿折线的**归一化**位置 0..1。
  ///
  /// 注意：这是**按总长**算的，不是"第几段里的第几成"。
  /// 折线时代 t 必须按总长才有意义 —— 否则一条 100 m 的线和它尾巴上
  /// 5 m 的小折段会得到同样量级的 t，详情面板里"在线上的 50%"就成了假话。
  double get t => totalM == 0 ? 0.0 : (alongM / totalM).clamp(0.0, 1.0);
}

/// 把点 [p] 投影到折线上（逐段取最近）。
///
/// [path] 少于两个点时返回 null（调用方应当跳过这条线，而不是崩）。
PathProjection? projectOntoPath(GeoPoint p, List<GeoPoint> path) {
  if (path.length < 2) return null;

  var bestDist = double.infinity;
  var bestPos = path.first;
  var bestSeg = 0;
  var bestAlong = 0.0;
  var walked = 0.0;

  for (var i = 0; i + 1 < path.length; i++) {
    final a = path[i];
    final b = path[i + 1];
    final foot = projectPointToSegment(p, a, b);
    final d = distanceMeters(p, foot);
    if (d < bestDist) {
      bestDist = d;
      bestPos = foot;
      bestSeg = i;
      bestAlong = walked + distanceMeters(a, foot);
    }
    walked += distanceMeters(a, b);
  }

  return PathProjection(
    position: bestPos,
    alongM: bestAlong,
    totalM: walked,
    segmentIndex: bestSeg,
    distanceM: bestDist,
  );
}

/// 点 [p] 到折线的**最短距离**（米）。折线不足两个点时返回 [double.infinity]
/// （"算不出距离"比"距离 0"安全：0 会被当成"就在线上"）。
double distanceToPathMeters(GeoPoint p, List<GeoPoint> path) {
  if (path.length < 2) return double.infinity;
  final proj = projectOntoPath(p, path);
  return proj?.distanceM ?? double.infinity;
}

/// 沿折线从起点走 [meters] 米后的坐标（超出两端自动夹住）。
///
/// 用途：店铺/墙体段的跨度取点、按里程找位置。
GeoPoint pointAtPathDistance(List<GeoPoint> path, double meters) {
  if (path.isEmpty) throw ArgumentError('空折线没有"沿程位置"可言');
  if (path.length == 1 || meters <= 0) return path.first;
  var remaining = meters;
  for (var i = 0; i + 1 < path.length; i++) {
    final a = path[i];
    final b = path[i + 1];
    final segLen = distanceMeters(a, b);
    if (remaining <= segLen) {
      if (segLen == 0) return a;
      return pointOnSegmentAt(a, b, remaining / segLen);
    }
    remaining -= segLen;
  }
  return path.last;
}

/// 折线上归一化位置 [t] 处前后各展开 `widthM/2` 得到的一段（两个端点）。
///
/// 折线版与"两点版"的区别只在取点方式：距离要**沿折线**量，
/// 而不是在一条直线段上按比例插值 —— 否则拐弯处的墙体段会跑到线外面去。
(GeoPoint, GeoPoint) spanAlongPath(
  List<GeoPoint> path,
  double t,
  double widthM,
) {
  if (path.isEmpty) throw ArgumentError('空折线取不出跨度');
  // 退化折线（只有一个点）没有"前后各半个宽度"可言，两端就是它自己 ——
  // 绝不能返回 (0,0)：那会在几内亚湾画出一段莫名其妙的墙。
  if (path.length < 2) return (path.first, path.first);
  final total = pathLengthMeters(path);
  if (total == 0) return (path.first, path.last);
  final c = t.clamp(0.0, 1.0).toDouble();
  final centerM = total * c;
  final half = widthM <= 0 ? 0.0 : widthM / 2;
  return (
    pointAtPathDistance(path, centerM - half),
    pointAtPathDistance(path, centerM + half),
  );
}

/// 折线的中点（按**长度**对半，中点不在顶点上时落在某一段内部）。
///
/// 给"没定过位的要素"一个兜底候选位置用。
GeoPoint midpointOfPath(List<GeoPoint> path) {
  if (path.isEmpty) throw ArgumentError('空折线没有中点');
  if (path.length == 1) return path.first;
  return pointAtPathDistance(path, pathLengthMeters(path) / 2);
}

// ---------------------------------------------------------------------------
// 给已有折线**加一个拐点**（第二十章）
// ---------------------------------------------------------------------------

/// 加拐点的判定：`at` 这个位置插进去，会插到哪、插完长什么样。
///
/// 用户的说法是"拐点会向路线上最近两个点形成新的路线，会自动拟合" ——
/// 所以这里的规则就是：**找离 `at` 最近的那一段，把新顶点插在它的两个端点之间**，
/// 其余部分的形状一个字节都不动（"拟合"= 实时把插入后的折线画出来，
/// 而不是把附近的拐角磨圆 —— 磨圆会悄悄改掉用户已经认可的形状）。
class BendInsertion {
  const BendInsertion({
    required this.bendIndex,
    required this.preview,
    required this.distanceM,
    required this.addedMeters,
    required this.tooCloseToVertex,
  });

  /// 插进 [LineRow.bendPointIds] 的下标（`bendPointIds.insert(bendIndex, newId)`）。
  ///
  /// 顶点序列是 `[起点, 拐点…, 终点]`，所以"插在第 i 与第 i+1 个顶点之间"
  /// 等价于"插进拐点列表的下标 i"。**必须用它而不是自己算**：
  /// 插错位置不会报错，只会画出一条形状不同的路。
  final int bendIndex;

  /// 插入后的坐标序列（预览用；也可直接和 `polylineOf` 的结果对照）。
  final List<GeoPoint> preview;

  /// 落点离原折线的距离（米）—— 离得越远，这次加拐点越"偏"。
  final double distanceM;

  /// 加了这一个拐点，这条路变长多少米（绕路的代价，提示里给用户看）。
  final double addedMeters;

  /// 落点离**已有顶点**太近（< [kNearVertexEpsilonM]）：加进去会得到一段长度为 0
  /// 的边，几何上没有任何意义，界面上应当**拒绝**并说明原因。
  final bool tooCloseToVertex;
}

/// 落点离已有顶点多近就算"重复"（米）。
///
/// 取 0.5 m：比它更近的话，那一段在地图任何缩放级别下都短于一个像素，
/// 用户看不出来自己加了什么，而库里的折线却多了一个永久的顶点。
const double kNearVertexEpsilonM = 0.5;

/// 规划一次"加拐点"：算插入位置、预览形状、以及绕路代价。
///
/// 顶点不足两个（线画不出来）时返回 null —— 调用方应当提示"这条线的顶点数据不全"。
BendInsertion? planBendInsertion(
  LineRow line,
  Map<int, GeoPoint> pointsById,
  GeoPoint at,
) {
  final path = polylineOf(line, pointsById);
  if (path == null) return null;
  final proj = projectOntoPath(at, path);
  if (proj == null) return null;

  // 顶点序列里的位置：第 proj.segmentIndex 段 = v[i] → v[i+1]，插在它们中间
  final vertexIndex = proj.segmentIndex;
  final tooClose =
      distanceMeters(at, path[vertexIndex]) < kNearVertexEpsilonM ||
      distanceMeters(at, path[vertexIndex + 1]) < kNearVertexEpsilonM;

  final preview = [...path]..insert(vertexIndex + 1, at);
  final added = pathLengthMeters(preview) - pathLengthMeters(path);

  return BendInsertion(
    bendIndex: vertexIndex,
    preview: preview,
    distanceM: proj.distanceM,
    addedMeters: added,
    tooCloseToVertex: tooClose,
  );
}

/// 折线在 [vertexIndex] 处的**转角**（度，0 = 直着走，180 = 掉头）。
///
/// 用途：详情面板告诉用户"这个拐点拐了多少度"，以及将来做
/// "把过于平缓的拐点合并掉"的辅助判断（< 5° 的拐点在 19 级缩放下都看不出来）。
double turnAngleDegreesAt(List<GeoPoint> path, int vertexIndex) {
  if (vertexIndex <= 0 || vertexIndex >= path.length - 1) return 0;
  final a = path[vertexIndex - 1];
  final b = path[vertexIndex];
  final c = path[vertexIndex + 1];
  // 用"东向按纬度缩过"的米制坐标算角度：直接拿经纬度当平面算的话，
  // 在这个纬度上东西向会被压扁约 8%，一条正东→正北的直角会显示成 97°。
  final kx = math.cos(b.lat * math.pi / 180);
  final abx = (b.lng - a.lng) * kx;
  final aby = b.lat - a.lat;
  final bcx = (c.lng - b.lng) * kx;
  final bcy = c.lat - b.lat;
  final la = math.sqrt(abx * abx + aby * aby);
  final lb = math.sqrt(bcx * bcx + bcy * bcy);
  if (la == 0 || lb == 0) return 0;
  final cos = ((abx * bcx + aby * bcy) / (la * lb)).clamp(-1.0, 1.0);
  return math.acos(cos) * 180 / math.pi;
}
