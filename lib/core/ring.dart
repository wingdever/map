/// 区块边界组装（docs/design/03-datamodel.md §6、04 章 §6）。
///
/// 一个 area 的边界由若干 lines 组成闭合环。
/// 本模块负责：把无序/乱向的边界线段还原为有序顶点环（供渲染、门吸附、导出）。
/// 纯 Dart、零依赖。
///
/// **第十八章起线是折线**：一条线本身就是「起点 → 拐点… → 终点」的一串**边**，
/// 所以组环不能再"一条线 = 一条边"地走 —— 那样一条拐过弯的界线会被当成
/// 一根直棍，围出来的区域会缺一块（而且不报错，只是画错）。
/// 现在统一按**边（相邻顶点对）**建图：
///   - 每条线贡献 `顶点数 - 1` 条边；
///   - 每个顶点被两条边用到（闭合环的必要条件）；
///   - 从任意一条边出发、沿未用过的边一路走到回到起点为止。
///
/// 这样一来"两点直线"只是"只有一条边的折线"，老数据的行为**逐字不变**。
library;

import 'models.dart';
import 'geometry.dart';

/// 组装失败原因。
enum RingAssembleError { noLines, notClosed, disconnected }

/// 尝试把区块的边界线组装成**有序顶点 id 环**。
///
/// 前提：边界应为简单闭合环（首尾相接，每个顶点恰被两条边用到）。
/// 若成闭环且全部连通则成功。
///
/// 返回：
/// - 成功：顶点 id 顺序列表（长度 = 顶点数，首尾不相连重复）；
/// - 失败：抛出 [RingAssembleException]。
List<int> assembleAreaRingVertexIds(List<LineRow> lines) {
  if (lines.isEmpty) {
    throw RingAssembleException(RingAssembleError.noLines);
  }

  // ---- 1. 展开成边：每条线贡献 (v0,v1) (v1,v2) … ----
  final edges = <(int, int)>[];
  for (final l in lines) {
    final vs = l.pointIds;
    for (var i = 0; i + 1 < vs.length; i++) {
      // 相邻重复顶点（脏数据）不构成一条真正的边
      if (vs[i] == vs[i + 1]) continue;
      edges.add((vs[i], vs[i + 1]));
    }
  }
  if (edges.isEmpty) {
    throw RingAssembleException(RingAssembleError.noLines);
  }

  // ---- 2. 顶点 → 用到它的边 ----
  final byVertex = <int, List<int>>{};
  for (var i = 0; i < edges.length; i++) {
    byVertex.putIfAbsent(edges[i].$1, () => []).add(i);
    byVertex.putIfAbsent(edges[i].$2, () => []).add(i);
  }

  // ---- 3. 从第一条边开始走 ----
  final startVertex = edges.first.$1;
  final ringIds = <int>[startVertex, edges.first.$2];
  final used = <int>{0};
  var current = edges.first.$2;
  var guard = 0;

  while (current != startVertex && used.length < edges.length) {
    if (guard++ > edges.length * 4) {
      throw RingAssembleException(RingAssembleError.disconnected);
    }
    int? nextEdge;
    for (final ei in byVertex[current] ?? const <int>[]) {
      if (used.contains(ei)) continue;
      nextEdge = ei;
      break;
    }
    if (nextEdge == null) {
      throw RingAssembleException(
        RingAssembleError.disconnected,
        detail: '顶点 $current 处的边走进了死胡同（是一个开口或分叉）',
      );
    }
    used.add(nextEdge);
    final (a, b) = edges[nextEdge];
    final other = a == current ? b : a;
    ringIds.add(other);
    current = other;
  }

  if (current != startVertex) {
    throw RingAssembleException(RingAssembleError.notClosed);
  }
  if (used.length != edges.length) {
    throw RingAssembleException(
      RingAssembleError.disconnected,
      detail: '存在未连通的孤立边界边',
    );
  }
  // 移除行走中的重复终点（末尾回到 start 的那一个）
  return ringIds.sublist(0, ringIds.length - 1);
}

/// 组装为坐标环（渲染用）。失败抛出异常。
List<GeoPoint> assembleAreaRing(
  List<LineRow> lines,
  Map<int, GeoPoint> pointsById,
) {
  final ids = assembleAreaRingVertexIds(lines);
  return ids.map((id) {
    final p = pointsById[id];
    if (p == null) {
      throw RingAssembleException(
        RingAssembleError.disconnected,
        detail: '缺少顶点 $id 的坐标',
      );
    }
    return p;
  }).toList();
}

class RingAssembleException implements Exception {
  RingAssembleException(this.error, {this.detail});
  final RingAssembleError error;
  final String? detail;

  @override
  String toString() =>
      'RingAssembleException($error${detail == null ? '' : ': $detail'})';
}
