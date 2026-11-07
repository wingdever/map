/// **两种封闭图形的互转**（docs/design/23-data-structure.md §4.5）
///
/// 判据一句话：**这条边需要单独设属性、挂东西、或被别处共用吗？需要 → area，不需要 → polygon。**
///
/// ## 🔴 转换是「搬家」，不是「复制」
///
/// 同一块地**不允许**在两张表里各存一份 —— 那正是 P1（同一个概念两套表示）的复现。
/// 所以两个方向都以"搬过去并删掉原来那个"收尾，而这个文件只算**计划**，
/// 落库由 DAO 在**一个事务**里执行。
///
/// ## 两个方向的爆炸半径完全不对称
///
/// | 方向 | 会造什么 | 会删什么 | 硬约束 |
/// |------|---------|---------|--------|
/// | polygon → area | **N 条界线**（每条边一条） | 多边形 | 无（随时可转） |
/// | area → polygon | 无 | **只删区域与它的成员关系** | **组环必须成功**；线**一条都不删** |
///
/// `area → polygon` 那条"线一条都不删"是硬约束：线可能被**别的区域共用**
/// （实测真库 `line 1` 同时属于两个区域），或上面挂着门/店铺。删了就是数据损失。
/// 于是转换后会留下"不属于任何区域的线" —— 这是**预期结果，不是脏数据**
/// （渲染不依赖区域，区域只是"线的分组"）。
///
/// 纯 Dart、零依赖（同 `line_edit.dart` 的理由：能被 `tool/checks/` 脚本验证）。
library;

import 'models.dart';
import 'ring.dart';

/// 转换被拒绝的原因（给用户看的一句话）。
class ShapeConvertRejection {
  const ShapeConvertRejection(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message（$detail）';
}

// ---------------------------------------------------------------------------
// polygon → area
// ---------------------------------------------------------------------------

/// 「多边形 → 区域」的计划：**为每条边新建一条界线**，点则复用。
class PolygonToAreaPlan {
  const PolygonToAreaPlan({
    required this.area,
    required this.ringPointIds,
    required this.edges,
    required this.warnings,
  });

  /// 要新建的区域（`id` 为空，由 DAO 插入后回填）。
  final AreaRow area;

  /// 环上的点（**复用已有的点**，不新建）。
  final List<int> ringPointIds;

  /// 每条边 = 环上相邻两点。DAO 为**每一条边**插一条界线，再写 `area_lines`。
  ///
  /// 环是闭合的：最后一条边从末点回到首点。
  final List<(int, int)> edges;

  /// 给用户看的提醒（这条转换会带来什么）。
  final List<String> warnings;
}

/// 规划「多边形 → 区域」。前提不满足时返回 [ShapeConvertRejection]。
///
/// 这条方向**不需要组环**（环是存下来的），所以唯一的拒绝理由是"点不够"。
Object planPolygonToArea(PolygonRow polygon) {
  if (!polygon.isClosedEnough) {
    return const ShapeConvertRejection(
      '多边形至少要 3 个点才能转成区域',
      detail: '先去环上补几个点',
    );
  }
  final ring = polygon.pointIds;
  final edges = <(int, int)>[];
  for (var i = 0; i < ring.length; i++) {
    edges.add((ring[i], ring[(i + 1) % ring.length]));
  }
  return PolygonToAreaPlan(
    area: AreaRow(
      domain: polygon.domain,
      name: polygon.name,
      areaType: polygon.areaType,
      floors: polygon.floors,
      colorOverride: polygon.colorOverride,
      sortOrder: polygon.sortOrder,
    ),
    ringPointIds: ring,
    edges: edges,
    warnings: [
      '会新建 ${edges.length} 条界线（每条边一条）—— 之后才能给边单独设材质、挂牌、或与别的区域共用',
      '这些新界线一开始没有材质（红线 §6.1：材质只属于界线），可以在世界图里逐条指定',
    ],
  );
}

// ---------------------------------------------------------------------------
// area → polygon
// ---------------------------------------------------------------------------

/// 「区域 → 多边形」的计划。
class AreaToPolygonPlan {
  const AreaToPolygonPlan({
    required this.polygon,
    required this.ringPointIds,
    required this.warnings,
  });

  /// 要新建的多边形（`id` 为空，由 DAO 插入后回填）。
  final PolygonRow polygon;

  /// 环上的点，**按环序**（组环得来；可能被旋转，见 [ClosedShape] 的说明）。
  final List<int> ringPointIds;

  final List<String> warnings;
}

/// 规划「区域 → 多边形」。
///
/// 三种结果：
/// - 返回 [AreaToPolygonPlan]：可以转，[AreaToPolygonPlan.warnings] 里说明代价；
/// - 返回 [ShapeConvertRejection]：**不能转**（组环失败 —— 开口/分叉/接不上）；
///
/// ⚠️ **组环失败是这条方向最常见的失败**，而且是"沉默"的：`world_areas` 的环是
/// 推导出来的，一条边不对就整块地围不出来。所以这里把失败原因原样带出去给用户看。
Object planAreaToPolygon({
  required AreaRow area,
  required List<LineRow> memberLines,
  Map<int, int> lineUsage = const {},
  Set<int> anchoredLineIds = const {},
}) {
  final List<int> ring;
  try {
    ring = assembleAreaRingVertexIds(memberLines);
  } on RingAssembleException catch (e) {
    return ShapeConvertRejection(
      '这个区域围不成环，转不了多边形',
      detail: '$e。多边形要求环是完整闭合的 —— 先把这个区域的边补齐（或者它本来就该是"由线围成"的样子）',
    );
  }

  if (ring.length < 3) {
    return const ShapeConvertRejection('这个区域的环少于 3 个点，转不了');
  }

  final warnings = <String>[];

  // 会被"留下"的线：被别的区域共用、或上面挂着门/要素的。**一条都不会被删**。
  final shared = <int>[];
  final anchored = <int>[];
  for (final l in memberLines) {
    final id = l.id;
    if (id == null) continue;
    if ((lineUsage[id] ?? 0) > 1) shared.add(id);
    if (anchoredLineIds.contains(id)) anchored.add(id);
  }
  if (shared.isNotEmpty) {
    warnings.add(
      '有 ${shared.length} 条边还被别的区域共用（线 ${shared.join('、')}）—— 它们会留在世界里继续用',
    );
  }
  if (anchored.isNotEmpty) {
    warnings.add(
      '有 ${anchored.length} 条边上挂着门或要素（线 ${anchored.join('、')}）—— '
      '它们会留在世界里；转成多边形之后这些门就挂不到这块地上了',
    );
  }
  if (shared.isEmpty && anchored.isEmpty) {
    warnings.add(
      '这 ${memberLines.length} 条边将不再属于任何区域 —— 它们仍然照常显示，'
      '只是不再是"某个区域的边"（要彻底删掉请去世界图里逐条删）',
    );
  }
  warnings.add('转换后**不能再给这块地挂门或要素**（多边形没有边实体）—— 要挂就再转回区域');

  return AreaToPolygonPlan(
    polygon: PolygonRow(
      domain: area.domain,
      name: area.name,
      areaType: area.areaType,
      floors: area.floors,
      colorOverride: area.colorOverride,
      sortOrder: area.sortOrder,
      pointIds: ring,
    ),
    ringPointIds: ring,
    warnings: warnings,
  );
}
