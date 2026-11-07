/// 楼层集合（第十七章「等高」）。
///
/// 需求一句话：
/// > 点、线、面都可以指定**它参与构成哪些楼层**（默认只有 1 层，可以再加 2、3 层…）；
/// > 查看某一层时，只显示**楼层属性里包含这一层**的要素。
///
/// 为什么是"集合"而不是"一个层号"：一堵承重墙、一部楼梯、一根柱子是**贯穿多层**的，
/// 它在 1、2、3 层都存在。用集合才能表达"同一个要素参与构成多层"。
///
/// 纯 Dart、零依赖；存储是 JSON 数组（`[1,2]`）—— 与 `tags`/`ext` 同一套风格，
/// 而且楼层号范围一旦要扩到 0 / 负数（地下层）也不用改列类型。
library;

import 'dart:convert';

/// 楼层集合：升序、去重、**非空**。
///
/// 「非空」是刻意的约束：一个"哪层都不属于"的要素永远不会被显示出来，
/// 那是数据错误而不是一种状态 —— 所以移除最后一层时自动回到 [groundFloor]。
class FloorSet {
  FloorSet(Iterable<int> values) : floors = normalize(values);

  /// 升序去重后的楼层号。
  final List<int> floors;

  /// 地面层。单层要素的默认值。
  static const int groundFloor = 1;

  /// 只有地面层（默认状态）。
  static FloorSet get ground => FloorSet(const [groundFloor]);

  /// 把任意一组楼层号整理成"升序 + 去重 + 非空"。
  static List<int> normalize(Iterable<int> values) {
    final set = values.toSet();
    if (set.isEmpty) return const [groundFloor];
    final list = set.toList()..sort();
    return list;
  }

  bool contains(int floor) => floors.contains(floor);
  int get lowest => floors.first;
  int get highest => floors.last;

  /// 是不是"只有一层"，且就是地面层 —— 也就是默认状态。
  bool get isGroundOnly => floors.length == 1 && floors.first == groundFloor;

  bool get isMultiFloor => floors.length > 1;

  /// 楼层号是否连续（1,2,3 是；1,3 不是）。
  bool get isContiguous {
    for (var i = 1; i < floors.length; i++) {
      if (floors[i] != floors[i - 1] + 1) return false;
    }
    return true;
  }

  FloorSet withFloor(int floor) => FloorSet([...floors, floor]);

  FloorSet withoutFloor(int floor) =>
      FloorSet(floors.where((f) => f != floor));

  FloorSet toggle(int floor) =>
      contains(floor) ? withoutFloor(floor) : withFloor(floor);

  /// 人类可读的标签：`1层` / `1、2层` / `1-3层`（连续时用区间）。
  String get label {
    if (floors.length == 1) return '${floors.first}层';
    if (isContiguous) return '$lowest-$highest层';
    return '${floors.join('、')}层';
  }

  /// 短标签（放在地图小胶囊里）：`1` / `1-3` / `1,3`。
  String get shortLabel {
    if (floors.length == 1) return '${floors.first}';
    if (isContiguous) return '$lowest-$highest';
    return floors.join(',');
  }

  /// 存储形式：JSON 数组，例如 `[1,2]`。
  String toStorage() => jsonEncode(floors);

  /// 解析。null / 坏数据一律回到默认的 [groundFloor] ——
  /// 解析失败时"当作一层"比"当作不存在"安全得多（后者会让要素凭空消失）。
  static FloorSet fromStorage(String? raw) {
    if (raw == null || raw.isEmpty) return FloorSet.ground;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final ints = decoded.whereType<num>().map((n) => n.toInt()).toList();
        return FloorSet(ints);
      }
      // 容忍手工写成 "1" 或 "1,2" 的形式
      if (decoded is num) return FloorSet([decoded.toInt()]);
    } catch (_) {
      // 落到下面的字符串兜底
    }
    final parts = raw.split(RegExp(r'[,\s]+')).where((s) => s.isNotEmpty);
    return FloorSet(parts.map(int.tryParse).whereType<int>());
  }

  /// 显示过滤：这个要素在 [floor] 层要不要画出来。
  bool visibleOn(int floor) => contains(floor);

  @override
  bool operator ==(Object other) =>
      other is FloorSet &&
      other.floors.length == floors.length &&
      List.generate(floors.length, (i) => other.floors[i] == floors[i]).every(
        (b) => b,
      );

  @override
  int get hashCode => Object.hashAll(floors);

  @override
  String toString() => label;
}

/// 楼层选择器要展示的候选层号（1 .. 上界）。
///
/// 上界 = max(已选最高层 + 1, 至少到 [minShown])。
/// 这样"想加第 2 层"时第 2 层已经在眼前，不用先点一次"+"；
/// 而想加到第 5 层时就点 "+" 逐次展开。
List<int> floorCandidates(FloorSet current, {int minShown = 3}) {
  final top = current.highest + 1;
  final n = top > minShown ? top : minShown;
  return [for (var f = 1; f <= n; f++) f];
}
