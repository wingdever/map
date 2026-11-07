/// 换路口的连接判定（docs/design/21-route-crossing.md §3）。
///
/// 用户原话（2026-09-14）：
/// > 为路线增加**换路口**这一类型，表示**围栏路的两侧可以交换**的行驶路口。
///
/// 定下来的画法：**换路口是一条横穿的短线**，连接一往一来的两条「围栏路」——
/// 它的两个端点分别落在两条围栏路上（见 21 章 §2）。
/// 本文件回答一个问题：**这条换路口到底接上了没有、接在哪几条围栏路上**。
///
/// 为什么要单独一个纯 Dart 文件：
/// 1. 判定要同时用"共享顶点"和"坐标离得够近"两种证据，两处逻辑必须一致 ——
///    散在 UI 里迟早分叉；
/// 2. 判定结果直接变成**给用户看的一句人话**，这句话要能被脚本验（用真实坐标）。
library;

import 'dart:math' as math;

import 'geometry.dart';
import 'models.dart';
import 'polyline.dart';

/// 端点算"接上了"的容差（米）。
///
/// 5 m 的取法：手画的换路口要么**直接复用了**围栏路上的那个点（共享顶点，0 m），
/// 要么差个一两米。5 m 高于 GPS 抖动与手抖，又明显小于"两条平行车道"的间距
/// （一往一来通常在 3–8 m），不至于把对向车道误判成"接上了"。
const double kCrossingLinkToleranceM = 5;

/// 端点算"旁边就有围栏路"的容差（米）。
///
/// 比连接容差宽得多（30 m ≈ 一条街的宽度）：用来区分两种完全不同的毛病 ——
/// "旁边根本没画围栏路"（那得先去把路标出来）与
/// "围栏路就在旁边、只是两个端点是悬空的"（那是画的时候没接上）。
/// 这两种情况给用户的提示是不一样的，混成一句话他会不知道该干什么。
const double kCrossingNearToleranceM = 30;

/// 一条换路口的连接情况。
class CrossingLink {
  const CrossingLink({
    required this.startOn,
    required this.endOn,
    required this.nearby,
    required this.startGapM,
    required this.endGapM,
  });

  /// 起点接上的围栏路线 id（空 = 那个端点没接上任何围栏路）。
  final List<int> startOn;

  /// 终点接上的围栏路线 id。
  final List<int> endOn;

  /// **任一端点** [kCrossingNearToleranceM] 之内出现过的围栏路线 id
  /// （"旁边有围栏路"—— 用来区分"没画"和"没接上"）。
  ///
  /// 注意它是两端点的并集：一端接上了、另一端悬着 1 km 时，这里仍然会有
  /// 那几条线（因为接上那一头就在旁边）。判"哪一头悬着"要用
  /// [startOn]/[endOn] 与 [startGapM]/[endGapM]。
  final List<int> nearby;

  /// 起点到最近围栏路线的距离（米）；旁边没有围栏路时是 [double.infinity]。
  final double startGapM;

  /// 终点到最近围栏路线的距离（米）。
  final double endGapM;

  /// 接上了几头（0 / 1 / 2）。
  int get connectedEnds =>
      (startOn.isEmpty ? 0 : 1) + (endOn.isEmpty ? 0 : 1);

  /// 两个端点是不是接在**同一条**围栏路上。
  ///
  /// 这不是"完美"：一往一来按约定是**两条**线，两端落在同一条线上，
  /// 通常意味着画成了一个圈、或者这条"围栏路"其实是把双向画成了一条。
  bool get sameSingleRoad {
    if (startOn.isEmpty || endOn.isEmpty) return false;
    final shared = startOn.toSet().intersection(endOn.toSet());
    if (shared.isEmpty) return false;
    return startOn.toSet().length == 1 && endOn.toSet().length == 1;
  }

  /// 算不算"接得好"：两头都接上了，且不是两端接在同一条线上。
  bool get ok => connectedEnds == 2 && !sameSingleRoad;

  /// 一句给人看的话（UI 直接显示，不用再拼字符串）。
  String describe() {
    String ids(List<int> v) =>
        v.isEmpty ? '没接上' : v.map((i) => '线 #$i').join('、');
    if (ok) {
      return '两头都接上了：起点 → ${ids(startOn)}，终点 → ${ids(endOn)}';
    }
    if (connectedEnds == 0) {
      if (nearby.isEmpty) {
        return '旁边 ${kCrossingNearToleranceM.round()} m 内没有「围栏路」：'
            '换路口要横穿一往一来的两条围栏路，'
            '先把这两条路的路宽标成「围栏路」，再画这个路口';
      }
      return '旁边有围栏路（${ids(nearby)}），但两个端点都悬着：'
              '起点离它 ${_m(startGapM)}、终点离它 ${_m(endGapM)}，都没接上';
    }
    if (sameSingleRoad) {
      return '两个端点接在**同一条**围栏路（${ids(startOn)}）上：'
          '一往一来按约定是两条线，接成一条容易把"换边"画成"绕圈"';
    }
    // 注意：这里要报**悬着那一头**的距离。用两端取小的话，
    // 接上的那头距离≈0，话就变成"另一头离最近的围栏路还有 0 m" —— 自相矛盾，
    // 用户照这句话根本找不到问题在哪。
    final dangling = <double>[
      if (startOn.isEmpty) startGapM,
      if (endOn.isEmpty) endGapM,
    ];
    final gap = dangling.isEmpty
        ? double.infinity
        : dangling.reduce(math.min);
    return '只接上了一头（${ids(startOn)}）：另一头离最近的围栏路还有 ${_m(gap)}';
  }

  static String _m(double v) =>
      v.isFinite ? '${v.toStringAsFixed(0)} m' : '很远';
}

/// 判定一条换路口接了哪些围栏路。
///
/// [allLines] 传**当前地图上的全部线**（含它自己）；函数内部会跳过它自己、
/// 跳过软删除的、且只看 `route_width == 围栏路` 的。
///
/// 端点算接上的两种证据（任一成立即可）：
/// 1. **共享顶点** —— 换路口的端点 id 就是那条围栏路的一个顶点
///    （起点、终点或拐点）。这是画的时候"点了那个已有点"的结果，最强；
/// 2. **坐标够近** —— 端点离那条围栏路的折线 ≤ [toleranceM]
///    （手画时差了一两米的情况，18 章之后围栏路多半是折线，所以按折线算距离）。
CrossingLink checkCrossingLink({
  required LineRow crossing,
  required Iterable<LineRow> allLines,
  required Map<MapDomain, Map<int, GeoPoint>> pointsByDomain,
  double toleranceM = kCrossingLinkToleranceM,
  double nearToleranceM = kCrossingNearToleranceM,
}) {
  final fenced = <LineRow>[
    for (final l in allLines)
      if (l.id != crossing.id &&
          l.deletedAt == null &&
          l.routeWidth == RouteWidth.fenced)
        l,
  ];

  // 换路口只存在于路网域，所以端点坐标取路网那张点表
  final pts = pointsByDomain[crossing.domain] ?? const <int, GeoPoint>{};
  final startPt = pts[crossing.startPointId];
  final endPt = pts[crossing.endPointId];

  final startOn = <int>[];
  final endOn = <int>[];
  final nearby = <int>{};
  var startGap = double.infinity;
  var endGap = double.infinity;

  for (final f in fenced) {
    final path = polylineOf(f, pointsByDomain[f.domain] ?? const {});
    if (path == null) continue;
    for (final (i, pt) in [startPt, endPt].indexed) {
      if (pt == null) continue;
      final isStart = i == 0;
      final sharedVertex = f.hasPoint(
        isStart ? crossing.startPointId : crossing.endPointId,
      );
      final gap = distanceToPathMeters(pt, path);
      if (isStart) {
        startGap = math.min(startGap, gap);
      } else {
        endGap = math.min(endGap, gap);
      }
      if (gap <= nearToleranceM) nearby.add(f.id!);
      if (sharedVertex || gap <= toleranceM) {
        (isStart ? startOn : endOn).add(f.id!);
      }
    }
  }

  return CrossingLink(
    startOn: startOn,
    endOn: endOn,
    nearby: nearby.toList()..sort(),
    startGapM: startGap,
    endGapM: endGap,
  );
}
