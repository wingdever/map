/// **线的形状：存与改**（docs/design/23-data-structure.md §4.4）
///
/// 纯 Dart、零依赖 —— 放 `core/` 的理由与 `edit_layers.dart` 相同：
/// 纯逻辑才能被 `tool/checks/` 的脚本直接验证（`features/` 依赖 flutter，脚本 import 不进来）。
///
/// ## 存法：端点是两列，拐点是链
///
/// ```
/// <域>_lines.start_point_id ─┐
/// <域>_line_bends（每行记前驱）├─→ 点序列 = [起点, 沿链…, 终点]
/// <域>_lines.end_point_id   ─┘
/// ```
///
/// 拐点表 `(line_id, point_id, before_point_id)` 里每行记的是「我的**前驱**」，
/// 于是插入/删除是 O(1) 指针操作，不需要整段重编号。
///
/// ## 🔴 两个最容易写错的地方
///
/// 1. **终点不在链上** —— 链只覆盖中间拐点，走完链**必须把 `end_point_id` 接上去**。
///    漏掉它每条线就少一个点（写迁移脚本时实测过：564 个点会变成 517）。
/// 2. **步数上限** —— 链坏成环时 `while` 会**死循环**。所有走链的地方都必须带计数保护，
///    超过"本线拐点数 + 1"就判定链坏了并报出来。
///
/// ## 链的完整性，SQL 只守得住一半
///
/// | 不变式 | 谁守 |
/// |--------|------|
/// | 同一条线里同一点只出现一次 | `PRIMARY KEY (line_id, point_id)` |
/// | 一个前驱最多一个后继（不分叉） | `UNIQUE (line_id, before_point_id)` |
/// | 恰好一个头、无环、能走到终点 | **这里**（[assembleLineChain]） |
library;

import 'models.dart';

/// 链坏掉的原因。
enum LineChainError {
  /// 一条线连两个端点都没有（不该发生：两列是 `NOT NULL`）。
  noPoints,

  /// 链断了：某个拐点的前驱既不是起点、也不是本线别的拐点。
  danglingLink,

  /// 成环或走不到终点：步数超过了拐点数。
  cycleOrTooLong,

  /// 终点被链吞了（终点同时也是某个拐点的前驱）—— 说明链接了终点，那是违法的。
  endpointInChain,

  /// 多边形少于 3 个点，构不成封闭图形。
  tooFewPointsForRing,

  /// 环走不回去：要么断了，要么被拆成了几个小环。
  ringNotClosed,
}

extension LineChainErrorLabel on LineChainError {
  String get label => switch (this) {
    LineChainError.noPoints => '这条线没有点',
    LineChainError.danglingLink => '链断了（有一个拐点的前驱找不到）',
    LineChainError.cycleOrTooLong => '链成环了或者走不到终点',
    LineChainError.endpointInChain => '终点被当成拐点接进了链',
    LineChainError.tooFewPointsForRing => '多边形至少要 3 个点',
    LineChainError.ringNotClosed => '环接不上（走 N 步没有回到起点）',
  };
}

/// 走链的结果。[error] 非空时 [pointIds] 是能走出来的那一截（供排错用），别拿它去画图。
class LineChain {
  const LineChain(this.pointIds, [this.error]);

  /// 完整的点序列（**已含终点**）。出错时是残链。
  final List<int> pointIds;

  final LineChainError? error;

  bool get ok => error == null;

  /// 拐点数（不含两个端点）。
  int get bendCount => pointIds.length < 2 ? 0 : pointIds.length - 2;

  static const LineChain failed = LineChain(<int>[], LineChainError.noPoints);
}

// ---------------------------------------------------------------------------
// 读：链 → 点序列
// ---------------------------------------------------------------------------

/// **走链得到一条线的完整点序列**：`[起点, 拐点…, 终点]`。
///
/// [beforeOf] 是 `point_id → before_point_id`（直接来自 `<域>_line_bends`）。
///
/// 🔴 **终点一定被接上**：链只覆盖中间拐点。这是"一条线缺一个点"bug 的唯一来源，
/// 所以接终点这件事写死在这里，调用方不用管。
///
/// 出现下列任一情况即判定链坏了（[LineChain.error] 非空）：
/// - 某个拐点的前驱不是"起点"也不是"本线另一个拐点" → [LineChainError.danglingLink]；
/// - 走了超过拐点数 + 1 步还没走完 → 成环 → [LineChainError.cycleOrTooLong]；
/// - 终点出现在链里 → [LineChainError.endpointInChain]（终点是链尾，不该有前驱）。
LineChain assembleLineChain({
  required int startPointId,
  required int endPointId,
  required Map<int, int> beforeOf,
}) {
  if (beforeOf.isEmpty) {
    // 没有拐点：就是一条两点直线。
    if (startPointId == endPointId) {
      return const LineChain(<int>[], LineChainError.noPoints);
    }
    return LineChain(<int>[startPointId, endPointId]);
  }

  if (beforeOf.containsKey(endPointId)) {
    return LineChain(<int>[startPointId, endPointId],
        LineChainError.endpointInChain);
  }

  // next = { 前驱 → 后继 }。PK 保证 point_id 唯一，所以一个前驱最多一个后继。
  final next = <int, int>{};
  for (final e in beforeOf.entries) {
    if (next.containsKey(e.value)) {
      // 同一个前驱被两行引用（SQL 的 UNIQUE 本该拦住；手工改库才可能）。
      return LineChain(<int>[startPointId, endPointId],
          LineChainError.danglingLink);
    }
    next[e.value] = e.key;
  }

  final out = <int>[startPointId];
  var current = startPointId;
  // 步数上限：最多"拐点数 + 1"步（最后一步走到终点）。成环时这里会兜住。
  for (var step = 0; step <= beforeOf.length + 1; step++) {
    final nxt = next[current];
    if (nxt == null) {
      // 链到头了 —— 正常情况：此时 out 的最后一个就是本线最后一个拐点，接上终点。
      out.add(endPointId);
      // 🔴 **必须走完全部拐点**才算链是好的。
      // 少了这一步，下面这种库就会"静默变成一条两点直线"：
      // 拐点挂在从起点走不到的孤岛（或自成一个小环）上 —— 走链一步就到头，
      // 看着毫无异常，实际库里那些拐点全被忽略、画出来是一条直路。
      // 真库上 470 个拐点全部可达，所以这条断言在正常数据上恒真。
      if (out.length - 2 != beforeOf.length) {
        return LineChain(out, LineChainError.danglingLink);
      }
      return LineChain(out);
    }
    out.add(nxt);
    current = nxt;
    if (nxt == startPointId) {
      return LineChain(out, LineChainError.cycleOrTooLong);
    }
  }
  return LineChain(out, LineChainError.cycleOrTooLong);
}

/// **走环链得到一个封闭图形的环**：`[p0, p1, …]`（首尾**不**重复）。
///
/// 与线不同，**环没有头** —— 从环上任意一点出发都能走回自己，
/// 所以不变量是「走 N 步（N = 行数）回到起点，且途中不重复」。
///
/// ⚠️ 返回的环**可能被旋转**（起点取决于 [fromPointId] 或 map 的迭代顺序）。
/// 同一个环的旋转与反向都是等价的 —— 填色、面积、质心、命中都不受影响；
/// 只有导出 GeoJSON 时环的起点会不一样（见 23 章 R-23-13）。
LineChain assembleRingChain(
  Map<int, int> beforeOf, {
  int? fromPointId,
}) {
  if (beforeOf.length < 3) {
    return const LineChain(<int>[], LineChainError.tooFewPointsForRing);
  }

  final next = <int, int>{};
  for (final e in beforeOf.entries) {
    if (next.containsKey(e.value)) {
      return const LineChain(<int>[], LineChainError.danglingLink);
    }
    next[e.value] = e.key;
  }

  final start = fromPointId ?? beforeOf.keys.first;
  if (!beforeOf.containsKey(start)) {
    return const LineChain(<int>[], LineChainError.danglingLink);
  }

  final out = <int>[start];
  var current = start;
  // 环的步数上限 = 行数；走满就该回到起点。
  for (var step = 0; step < beforeOf.length; step++) {
    final nxt = next[current];
    if (nxt == null) {
      return LineChain(out, LineChainError.danglingLink);
    }
    if (nxt == start) {
      // 恰好走满一圈：长度必须等于行数，否则说明这是环里的一小段（被拆成了两个小环）。
      if (out.length != beforeOf.length) {
        return LineChain(out, LineChainError.ringNotClosed);
      }
      return LineChain(out);
    }
    if (out.contains(nxt)) {
      return LineChain(out, LineChainError.ringNotClosed);
    }
    out.add(nxt);
    current = nxt;
  }
  return LineChain(out, LineChainError.ringNotClosed);
}

// ---------------------------------------------------------------------------
// 写：整段重写 vs 局部指针
// ---------------------------------------------------------------------------

/// 点序列 → 前驱映射（`point_id → before_point_id`），**给整段重写用**。
///
/// 这是「一个列表 → 一条链」的唯一转换点：起点不出现（它是链的头），
/// 终点也不出现（它是链的尾），中间每点记前一个点。
Map<int, int> beforeOfFromPoints(List<int> pointIds) {
  final out = <int, int>{};
  for (var i = 1; i < pointIds.length - 1; i++) {
    out[pointIds[i]] = pointIds[i - 1];
  }
  return out;
}

/// 在 [anchorPointId] **之后**插入一个新点（局部指针操作的目标状态）。
///
/// 与 20 章「加拐点」的接口对上了：那边返回一个**锚点顶点 id**（不是下标）——
/// 点名"插在哪个点之后"，**没有下标可以算错**。
///
/// [anchorPointId] 可以是起点（插到最前面）、也可以是某个拐点。
/// 不允许插在终点之后（终点是链尾）。
List<int> withPointInsertedAfter(
  List<int> pointIds, {
  required int anchorPointId,
  required int newPointId,
}) {
  final at = pointIds.indexOf(anchorPointId);
  if (at < 0 || at >= pointIds.length - 1) {
    // 锚点不在线上、或锚点就是终点（终点后面没地方插）
    throw ArgumentError('锚点 $anchorPointId 不在点序列里，或者是终点');
  }
  return [...pointIds.sublist(0, at + 1), newPointId, ...pointIds.sublist(at + 1)];
}

/// 从线上摘掉一个点（只改这条线的构成，**不动那个点本身**，见 D10）。
///
/// 摘端点（第一个/最后一个）会让相邻的拐点顶上 —— 这正是"删除端点"的实现，
/// 也是 [removableEndpoint] 要守的地方：没有拐点可顶时必须拒绝。
List<int> withPointRemoved(List<int> pointIds, int pointId) {
  final at = pointIds.indexOf(pointId);
  if (at < 0) throw ArgumentError('点 $pointId 不在这条线上');
  if (pointIds.length <= 2) {
    throw StateError('这条线只剩两个端点了，要删就删整条线');
  }
  return [...pointIds.sublist(0, at), ...pointIds.sublist(at + 1)];
}

/// 这条线的端点**能不能删**（D11）：要有相邻的拐点能顶上。
///
/// 与"删哪一头"**无关** —— 两头是对称的：只要除端点外还剩至少一个点，
/// 它顶上来仍是线（≥2 个点）；只剩两个点时删掉端点就只剩一个点了，
/// 那种情况该走"删整条线"（`withPointRemoved` 也会 `StateError`）。
bool removableEndpoint(List<int> pointIds) => pointIds.length > 2;

/// 重设端点：接到另一个已有点上（只改端点，拐点一个都不动）。
List<int> withEndpointReset(
  List<int> pointIds, {
  required bool atStart,
  required int newPointId,
}) {
  if (pointIds.isEmpty) throw StateError('这条线没有点');
  final out = [...pointIds];
  final at = atStart ? 0 : out.length - 1;
  // 相邻点不能相同：否则段长为 0、投影分母为 0（polyline/ring 都在防这个脏数据）
  final neighbour = atStart ? out[1] : out[out.length - 2];
  if (newPointId == neighbour) {
    throw ArgumentError('新端点与相邻的点是同一个点，会得到一段零长度的边');
  }
  if (out.contains(newPointId)) {
    throw ArgumentError('这个点已经在这条线上了');
  }
  out[at] = newPointId;
  return out;
}

/// 反转线的方向。**不改变线的身份**：业务键里两个端点键本来就排序。
List<int> withReversed(List<int> pointIds) => pointIds.reversed.toList();

// ---------------------------------------------------------------------------
// 校验
// ---------------------------------------------------------------------------

/// 提交前的统一校验。返回 null = 通过。
///
/// 第一道防线（落库前拦）就在这里；`core/polyline.dart` 与 `core/ring.dart` 里
/// 那两处「相邻重复点」的防御性判断**保留**当最后一道防线，但不该再被触发。
LineChainError? validateLineChain(
  List<int> pointIds, {
  required Set<int> knownPointIds,
}) {
  if (pointIds.length < 2) return LineChainError.noPoints;
  if (pointIds.first == pointIds.last) return LineChainError.cycleOrTooLong;
  final seen = <int>{};
  for (var i = 0; i < pointIds.length; i++) {
    final p = pointIds[i];
    if (!knownPointIds.contains(p)) return LineChainError.danglingLink;
    if (!seen.add(p)) {
      // 同一条线上同一个点出现两次：段长 0 / 投影分母 0，而且链的 PK 会拒绝它
      return LineChainError.cycleOrTooLong;
    }
    if (i > 0 && pointIds[i - 1] == p) return LineChainError.danglingLink;
  }
  return null;
}

/// 环的校验（多边形）。返回 null = 通过。
LineChainError? validateRingChain(
  List<int> pointIds, {
  required Set<int> knownPointIds,
}) {
  if (pointIds.length < 3) return LineChainError.tooFewPointsForRing;
  final seen = <int>{};
  for (final p in pointIds) {
    if (!knownPointIds.contains(p)) return LineChainError.danglingLink;
    if (!seen.add(p)) return LineChainError.ringNotClosed;
  }
  return null;
}

/// 这条线的点序列里，[pointId] 是不是端点。
bool isEndpointOf(LineRow line, int pointId) =>
    pointId == line.startPointId || pointId == line.endPointId;
