/// 编辑模式下的**要素命中检测与吸附**（docs/design/12-edit-mode.md §4）。
///
/// 编辑模式的每一次点按都要回答两个问题：
///   1. 我点到了哪个要素？（点 / 线 / 门牌 / 区域）
///   2. 如果我正在连线或挂门牌，应该吸附到哪个已有点/线？
///
/// 这些都属于纯几何计算，和渲染、数据库无关，因此集中在这里。
/// 容差随缩放变化：放得越大，手指越精确，吸附范围就越小 —— 否则在
/// 19 级缩放下点哪都吸附到同一个点，根本没法画新点。
library;

import 'dart:math' as math;

import 'geometry.dart';
import 'models.dart';
import 'line_feature_layout.dart';
import 'polyline.dart';

/// 手指点选的等效半径（像素）。
///
/// 28 是权衡后的取值，不是拍脑袋：
/// - **太小**（早期版本的固定米数换算下来只有 5–7 px）→ 手指点不中，
///   用户会以为"吸附坏了"；
/// - **太大**（试过 40 px）→ zoom 15 时容差 176 m、40% 的"精确半径"就有 70 m，
///   比一个 100 m 见方区域的半宽（50 m）还大 → **区域永远选不中**，
///   正是用户反馈的"想点区域却点到区域的线"。
///
/// 28 px 下 zoom 15 的精确半径是 43 m < 50 m，区域能正常选中。
const double kFingerRadiusPx = 28;

/// Web Mercator 在 zoom 0、赤道处的每像素米数。
const double _kEquatorMetersPerPxAtZoom0 = 156543.03392804097;

/// 本 App 覆盖区域的纬度（凤岗—龙岗）。
///
/// 吸附容差只跟 `cos(lat)` 有关，而 22.6°–22.8° 之间 cos 的变化 < 0.5%，
/// 所以用一个常数完全够，不需要每次去问地图中心。
const double _kCorridorLat = 22.7;

/// 容差下限/上限（米）：下限防止极端缩放下的浮点退化，上限防止远景误吸。
const double kMinToleranceM = 3;
const double kMaxToleranceM = 300;

/// 按当前缩放算吸附容差（米）。
///
/// **按「手指大小」换算，而不是给一个固定的米数** —— 这是 v4 的一处重要手感修正。
/// 固定米数在高缩放下会变得比手指还小（用户点不中，以为功能坏了），
/// 在低缩放下又会大到离谱。按像素换算后，无论缩放多少，
/// 屏幕上「能点中的范围」始终是同一个圈。
///
/// 实测对照（lat 22.7）：
/// | zoom | m/px | 容差 |
/// |------|------|------|
/// | 12 | 35.3 | 300 m（触上限） |
/// | 15 | 4.41 | 176 m |
/// | 17 | 1.10 | 44 m |
/// | 19 | 0.275 | 11 m |
double snapToleranceForZoom(double zoom, {double? centerLat}) {
  final lat = centerLat ?? _kCorridorLat;
  final metersPerPx =
      _kEquatorMetersPerPxAtZoom0 *
      math.cos(lat * math.pi / 180) /
      math.pow(2, zoom);
  return (metersPerPx * kFingerRadiusPx).clamp(
    kMinToleranceM,
    kMaxToleranceM,
  );
}

// ---------------------------------------------------------------------------
// 命中结果
// ---------------------------------------------------------------------------

/// 命中的点。
class PointHit {
  const PointHit({required this.point, required this.distanceM});
  final PointRow point;
  final double distanceM;
}

/// 命中的线（含吸附位置与沿线比例）。
class LineHit {
  const LineHit({
    required this.line,
    required this.snapped,
    required this.t,
    required this.distanceM,
    this.alongM = 0,
    this.segmentIndex = 0,
  });

  final LineRow line;

  /// 点击位置在该线上的垂足（吸附点）。
  final GeoPoint snapped;

  /// 沿线归一化位置 0..1（起点侧为 0）。**按折线总长**算。
  final double t;

  final double distanceM;

  /// 从起点沿折线量到 [snapped] 的距离（米）。
  final double alongM;

  /// [snapped] 落在第几段上（0 起）—— 折线时代"点到了哪一段"是有用的信息。
  final int segmentIndex;
}

// ---------------------------------------------------------------------------
// 命中检测
// ---------------------------------------------------------------------------

/// 距离 [p] 最近的点；超过 [toleranceM] 返回 null。
///
/// 并列时取 id 更小的那个，保证结果稳定（同一份数据每次点击命中同一个点）。
PointHit? hitNearestPoint(
  GeoPoint p,
  List<PointRow> points, {
  double toleranceM = kMaxToleranceM,
}) {
  PointHit? best;
  for (final pt in points) {
    final d = distanceMeters(p, pt.geo);
    if (d > toleranceM) continue;
    if (best == null ||
        d < best.distanceM - 1e-6 ||
        (d < best.distanceM + 1e-6 && (pt.id ?? 0) < (best.point.id ?? 0))) {
      best = PointHit(point: pt, distanceM: d);
    }
  }
  return best;
}

/// 距离 [p] 最近的线；超过 [toleranceM] 返回 null。
///
/// **折线时代（18 章）这里必须逐段比**：一条拐了三道弯的路，可能离你很近的
/// 是它**中段**的一部分，而首尾连线远在几十米之外 —— 只看两端点的话，
/// 用户站在路边却"点不中这条路"。
///
/// 一个顶点坐标查不到的线（脏数据）整条跳过：几何不完整的线不能用于吸附，
/// 否则会把店/门挂到一个画不出来的位置上。
LineHit? hitNearestLine(
  GeoPoint p,
  List<LineRow> lines,
  Map<MapDomain, Map<int, GeoPoint>> pointsByDomain, {
  double toleranceM = kMaxToleranceM,
}) {
  LineHit? best;
  for (final line in lines) {
    // 线的点必须取**它自己那个域**的坐标表：三个域的自增 id 是独立的，
    // 混用会拿另一层的点去拼几何（画出来是一条穿过街区的假线）。
    final path = polylineOf(line, pointsByDomain[line.domain] ?? const {});
    if (path == null) continue;
    final proj = projectOntoPath(p, path);
    if (proj == null || proj.distanceM > toleranceM) continue;
    if (best == null || proj.distanceM < best.distanceM) {
      best = LineHit(
        line: line,
        snapped: proj.position,
        t: proj.t,
        distanceM: proj.distanceM,
        alongM: proj.alongM,
        segmentIndex: proj.segmentIndex,
      );
    }
  }
  return best;
}

/// 命中的区域（点在多边形内；多个重叠时取**面积最小**的那个）。
///
/// 取最小面积是为了「小区套在城中村范围里」的情况：用户点小区内部时，
/// 想要的是小区而不是把它包住的那个大范围。
AreaRow? hitArea(
  GeoPoint p,
  List<AreaRow> areas,
  Map<(MapDomain, int), List<GeoPoint>> ringsByRef,
) {
  AreaRow? best;
  var bestArea = double.infinity;
  for (final a in areas) {
    final ring = ringsByRef[(a.domain, a.id)];
    if (ring == null || ring.length < 3) continue;
    if (!pointInPolygon(p, ring)) continue;
    final area = ringAreaMeters2(ring);
    if (area < bestArea) {
      bestArea = area;
      best = a;
    }
  }
  return best;
}

// ---------------------------------------------------------------------------
// 连线/围合的辅助
// ---------------------------------------------------------------------------

/// 一组线能否首尾相接组成闭合环（不抛异常的版本，供 UI 实时提示用）。
///
/// 返回 null 表示可以；否则返回人类可读的原因。
///
/// **判据与 `core/ring.dart` 的组环器保持一致**（这是硬要求：提示说"能闭合"
/// 而落库时组不出来，用户会以为程序坏了）：
/// 一条折线贡献"顶点数 - 1"条边，每个顶点必须**恰好被两条边用到**。
/// 两点直线只是"一条边的折线"，所以老数据的判据与以前完全相同。
String? checkRingClosure(List<LineRow> lines, {int minLines = 3}) {
  if (lines.isEmpty) return '还没有选线';
  if (lines.length < minLines) return '至少需要 $minLines 条线';
  final degree = <int, int>{};
  var edgeCount = 0;
  for (final l in lines) {
    final vs = l.pointIds;
    for (var i = 0; i + 1 < vs.length; i++) {
      if (vs[i] == vs[i + 1]) continue;
      edgeCount++;
      degree[vs[i]] = (degree[vs[i]] ?? 0) + 1;
      degree[vs[i + 1]] = (degree[vs[i + 1]] ?? 0) + 1;
    }
  }
  if (edgeCount == 0) return '这几条线没有可以用来的边';
  for (final entry in degree.entries) {
    if (entry.value != 2) {
      return '点 ${entry.key} 连了 ${entry.value} 条边，闭合环要求每个顶点恰好连 2 条'
          '（拐点也算顶点，所以折线的中间点会一起参与判断）';
    }
  }
  return null;
}

/// 追加一条线到「围合」选择里。
///
/// 规则：
/// - 已选过 → 直接返回原列表（幂等，用户重复点同一条不会出错）；
/// - 空列表 → 接受；
/// - 否则要求与已选线**共用至少一个顶点**（端点或拐点都算 —— 折线的拐点
///   和另一条线的端点重合是完全正常的画法，比如"主路在路口拐弯"）。
///
/// 返回 `(新列表, 错误信息)`，错误非空时新列表等于原列表。
(List<int>, String?) appendLineToRing(
  List<int> selected,
  LineRow candidate, {
  required Map<(MapDomain, int), LineRow> linesByRef,
}) {
  if (selected.contains(candidate.id)) return (selected, null);
  if (selected.isEmpty) return ([candidate.id!], null);

  // 已选的线必然与候选**同域**（围合的成员只能是同一个域的线，见 D2/D19），
  // 所以用 candidate.domain 去索引即可。
  final d = candidate.domain;
  final vertices = <int>{};
  for (final id in selected) {
    final l = linesByRef[(d, id)];
    if (l == null) continue;
    vertices.addAll(l.pointIds);
  }
  final touches = candidate.pointIds.any(vertices.contains);
  if (!touches) return (selected, '这条线跟已选的线没有连在一起，请先点相邻的那条');
  return ([...selected, candidate.id!], null);
}

// ---------------------------------------------------------------------------
// 候选排序（点选歧义的正面解决）
// ---------------------------------------------------------------------------

/// 要素类别。core 层只表达"是什么"，UI 再翻译成自己的选择类型。
enum HitKind { lineFeature, gate, point, line, area }

/// 一个候选要素。
///
/// 🔴 **必须带 [domain]**：v12 起 id 只在域内唯一（`way_lines.id = 3` 与
/// `world_lines.id = 3` 是两条线）。命中测试是"选中"的源头，这里不带域，
/// 下游就会拿一个 id 去另一层找东西 —— 而且不报错，只是选中了别的东西。
class HitCandidate {
  const HitCandidate({
    required this.kind,
    required this.domain,
    required this.id,
    required this.distanceM,
    required this.precise,
  });

  final HitKind kind;

  /// 这个候选属于哪个域（= 它在那张表里）。
  final MapDomain domain;

  /// 域内 id。
  final int id;

  /// `(域, id)` —— 去 `MapLayersData` 里查东西一律用它。
  (MapDomain, int) get ref => (domain, id);

  final double distanceM;

  /// 是否落在**精确半径**内。
  ///
  /// 这个标记是解决"点区域却点到区域的线"的关键：手指半径（[kFingerRadiusPx]）
  /// 是为了**找得到**细小的要素，不是为了**判得准**。
  /// 一个 100 m 见方的区域，站在正中离边界 50 m，而 zoom 15 的容差是 176 m ——
  /// 用同一个半径判定的话，区域永远抢不过它自己的边线。
  /// 所以点/线/门/门牌只有在"手指中心"这个更小的圈里才盖过区域。
  final bool precise;
}

/// 精确命中半径占吸附容差的比例（0.35 × 28px ≈ 10px）。
///
/// 取值逻辑：28px 是"能碰到"，10px 是"指着它"。太小则点线变得很难点中，
/// 太大则区域又选不出来。实测对照（100 m 见方区域、站在正中）：
///
/// | zoom | 容差 | 精确半径 | 结果 |
/// |------|------|----------|------|
/// | 15 | 123 m | 43 m | 区域赢（50 m > 43 m）✅ |
/// | 17 | 31 m | 11 m | 区域赢 ✅ |
/// | 19 | 7.7 m | 2.7 m | 区域赢 ✅ |
const double kPreciseHitFraction = 0.35;

/// 算出该点下方的**全部**候选要素，**按"最该被选中"排序**（越靠前越优先）。
///
/// 排序规则（这是本节的核心）：
///
/// | 优先级 | 类别 | 条件 |
/// |--------|------|------|
/// | 1 | 线上要素 / 门 / 点 / 线 | **精确命中**（≤ 0.35 × 容差） |
/// | 2 | **区域** | 点在区域内 |
/// | 3 | 线上要素 / 门 / 点 / 线 | 只是宽松命中（≤ 容差） |
///
/// 区域夹在"精确命中"和"宽松命中"之间，正是为了上面的场景：
/// 站在区域里、离边线 50 m —— 线只是宽松命中，区域该赢；
/// 而手指真的压在线上（精确命中）时，线该赢。
///
/// 返回全部候选而不是只返回第一名，是为了让 UI 能做「同一位置再点一次切换」。
List<HitCandidate> rankFeatureHits({
  required GeoPoint p,
  required List<PointRow> points,
  required List<LineRow> lines,
  required List<AreaRow> areas,
  required List<EntityRow> lineFeatures,
  required List<GateRow> gates,
  required Map<MapDomain, Map<int, GeoPoint>> pointsByDomain,
  required Map<(MapDomain, int), List<GeoPoint>> ringsByRef,
  required double toleranceM,
}) {
  final preciseM = toleranceM * kPreciseHitFraction;
  final out = <HitCandidate>[];

  // ---- 线上要素（店铺 / 墙体）：位置与渲染同源（都走 placeFeaturesOnLine）----
  for (final line in lines) {
    if (line.id == null) continue;
    final placed = placeFeaturesOnLine(
      line: line,
      pointsById: pointsByDomain[line.domain] ?? const {},
      entities: lineFeatures,
    );
    for (final pl in placed) {
      final id = pl.feature.id;
      if (id == null) continue;
      final d = distanceMeters(p, pl.position);
      if (d > toleranceM) continue;
      out.add(
        HitCandidate(
          kind: HitKind.lineFeature,
          domain: MapDomain.world, // 世界要素只属于世界图域
          id: id,
          distanceM: d,
          precise: d <= preciseM,
        ),
      );
    }
  }

  // ---- 门：和店铺一样，先定位到它吸附的线上再判距离 ----
  //
  // 没挂线的老门退化为直接用它自己的中心点 —— 否则这些门会变成"看得到点不到"。
  for (final line in lines) {
    if (line.id == null) continue;
    final placed = placeGatesOnLine(
      line: line,
      pointsById: pointsByDomain[line.domain] ?? const {},
      gates: gates,
    );
    for (final pg in placed) {
      final id = pg.gate.id;
      if (id == null) continue;
      final d = distanceMeters(p, pg.position);
      if (d > toleranceM) continue;
      out.add(
        HitCandidate(
          kind: HitKind.gate,
          domain: MapDomain.world, // 门只属于世界图域
          id: id,
          distanceM: d,
          precise: d <= preciseM,
        ),
      );
    }
  }
  for (final g in gates) {
    final id = g.id;
    if (id == null || g.lineId != null) continue; // 挂线的已在上面处理
    final d = distanceMeters(p, g.center);
    if (d > toleranceM) continue;
    out.add(
      HitCandidate(
        kind: HitKind.gate,
        domain: MapDomain.world,
        id: id,
        distanceM: d,
        precise: d <= preciseM,
      ),
    );
  }

  // ---- 点 ----
  final ph = hitNearestPoint(p, points, toleranceM: toleranceM);
  if (ph != null && ph.point.id != null) {
    out.add(
      HitCandidate(
        kind: HitKind.point,
        domain: ph.point.domain,
        id: ph.point.id!,
        distanceM: ph.distanceM,
        precise: ph.distanceM <= preciseM,
      ),
    );
  }

  // ---- 线 ----
  final lh = hitNearestLine(p, lines, pointsByDomain, toleranceM: toleranceM);
  if (lh != null && lh.line.id != null) {
    out.add(
      HitCandidate(
        kind: HitKind.line,
        domain: lh.line.domain,
        id: lh.line.id!,
        distanceM: lh.distanceM,
        precise: lh.distanceM <= preciseM,
      ),
    );
  }

  // ---- 区域（含该点的**最小**面积区域，由 hitArea 保证）----
  final area = hitArea(p, areas, ringsByRef);
  if (area != null && area.id != null) {
    out.add(
      HitCandidate(
        kind: HitKind.area,
        domain: area.domain,
        id: area.id!,
        // 区域没有"距离"可言（点在里面）；给 0 让同组内稳定。
        // 多个区域重叠时 hitArea 已经只留了最小的那个。
        distanceM: 0,
        precise: false,
      ),
    );
  }

  out.sort((a, b) {
    final ra = _hitRank(a);
    final rb = _hitRank(b);
    if (ra != rb) return ra.compareTo(rb);
    return a.distanceM.compareTo(b.distanceM);
  });
  return out;
}

/// 优先级分组编号（小的排前面）。
///
/// 精确命中的点/线/门/门牌（0–3）< 区域（5）< 宽松命中的（6–9）。
/// 中间空出来的 4 是留给"将来还有别的中间层"的余量。
int _hitRank(HitCandidate c) {
  const base = {
    HitKind.lineFeature: 0,
    HitKind.gate: 1,
    HitKind.point: 2,
    HitKind.line: 3,
  };
  if (c.kind == HitKind.area) return 5;
  final b = base[c.kind]!;
  return c.precise ? b : b + 6;
}
