/// **点的显示规则**（docs/design/22-point-visibility.md）。
///
/// 用户原话（2026-09-14）：
/// > 1. 非编辑状态不要显示点，除非是**用户定位录入的但未处理**的定位点。
/// > 2. 编辑状态点的显示过于稠密了：如果地图比例尺大到一定程度就不显示点；
/// >    即便没有那么大，当点的显示过于稠密时也只显示部分点。
///
/// 实测（真库 686 个点）：一屏 1200×800 在 zoom 15 有 **452** 个点、
/// zoom 16 有 228、zoom 17 有 56；而且 **40% 的点最近邻在 0.5 m 以内**（近乎重合）。
/// 所以"稠密"不是错觉，必须按缩放与像素密度来管。
///
/// 两条规则（互相独立）：
/// 1. **浏览态**（不在编辑模式）：只显示"**记录录入且未处理**"的点 ——
///    画图用的那些顶点平时一个都不显示；
/// 2. **编辑态**：`zoom < 15` 一个点都不画（除了手上正在用的那几个）；
///    zoom ≥ 15 时按**屏幕 24 px 网格**抽稀，每格最多画 1 个。
///
/// 纯 Dart、零依赖 —— 放在 core 是为了让"到底显示了多少个点"能用**真实坐标**算出来
/// （`tool/checks/point_density_check.dart`），而不是只能靠肉眼看地图。
library;

import 'dart:math' as math;

import 'models.dart';

/// 抽稀网格的边长（**屏幕像素**）。
///
/// 取 24 的理由：命中/吸附的手指半径是 `kFingerRadiusPx = 28`（见 `hit_test.dart`）。
/// 比它略小一点，意味着"画出来的点"彼此在屏幕上至少能分辨，
/// 而"没画出来的点"就在某个画出来的点旁边一两像素内 —— 用户不会觉得漏了什么。
const double kPointGridPx = 24;

/// 低于这个缩放就**一个点都不画**（编辑态）。
///
/// 15 是拿真库的数字定的：zoom 15 一屏 452 个点（抽稀后仍有意义），
/// zoom 14 是 661 个、13 与 12 是全部 686 个 —— 那几级上点已经连成一片，
/// 画出来只有害处（既看不清路，也点不中任何东西）。
/// 地图的 `minZoom` 是 12，所以这个阈值恰好把"看全省/看全镇"那几级排除在外。
const double kPointMinZoom = 15;

/// 这个缩放下，**批量点**还画不画（编辑态）。
///
/// 注意"批量"两个字：选中的点与草稿顶点**永远**画（见 [alwaysShowIds]），
/// 因为正在编辑的东西不能在眼皮底下消失。
bool bulkPointsVisibleAtZoom(double zoom) => zoom >= kPointMinZoom;

/// 浏览态要不要显示这个**记录点**（第二十二章规则 1）。
///
/// v12 起这件事变得非常简单，因为"记录点"已经是自己的表（`world_marks`）：
/// **几何点**（`<域>_points`，画线用的顶点）浏览态**一个都不显示**；
/// 而记录点只显示"还没处理"的（用户原话："标记已处理的定位点，默认不显示"）。
///
/// 判据从"猜 source 是不是 recorded"变成了一句 `!processed` ——
/// 22 章那个 `source` 补丁之所以需要，正是因为当时两者挤在同一张表里。
bool visibleInBrowseMode(WorldMarkRow m) => m.deletedAt == null && !m.processed;

/// 抽稀时**必须保留**的点 id：手上正在用的那几个。
///
/// - [selectedPointId]：「选择」工具选中的点（不然选完就看不见了）；
/// - [draftPointIds]：正在拉的折线草稿顶点（不然画到一半的点会凭空消失）。
///
/// 用户 2026-09-14 明确只要这两个（有名字的点**不**豁免）——
/// 所以别在这里顺手把"有名字的"也算进去，那会让规则变得说不清。
Set<int> alwaysShowIds({
  int? selectedPointId,
  Iterable<int> draftPointIds = const [],
}) => {
  ?selectedPointId,
  ...draftPointIds,
};

/// 按**屏幕像素网格**抽稀：同一格最多保留一个点。
///
/// 实现上不去做投影变换，而是把 24 px 换算成"这个缩放下的经纬度格子"：
/// `格子边长(度) = 24 px × 每像素米数 ÷ 每度米数`。这样：
/// - 结果与**视口位置无关**（格子锚在地理坐标上），拖动地图时不会有点忽隐忽现；
/// - 纯算术，能在脚本里用真实坐标验证。
///
/// 同一格里保留谁：**有名字的优先**（标签比一个匿名圆点信息量大），
/// 其次 **id 小的**（决定论：同一份数据每次得到同一个结果，不会闪）。
///
/// [allPoints] 传已经过滤过楼层/可见性的点（本函数只管密度）。
/// [alwaysShow] 里的点**一定保留**，并从它所在格子里"占位"（同格不会再画第二个）。
List<PointRow> thinPointsByGrid(
  Iterable<PointRow> allPoints, {
  required double zoom,
  Set<int> alwaysShow = const {},
  double gridPx = kPointGridPx,
}) {
  final points = [for (final p in allPoints) if (p.id != null) p];

  // 每像素多少米（Web Mercator，赤道基准；22.7° 走廊上 cos 的变化 <0.5%，
  // 与 hit_test.dart 里吸附容差的取法一致，不必每次去问地图中心）。
  const equatorMetersPerPxAtZoom0 = 156543.03392804097;
  const corridorLat = 22.7;
  final metersPerPx =
      equatorMetersPerPxAtZoom0 *
      math.cos(corridorLat * math.pi / 180) /
      math.pow(2, zoom);
  if (metersPerPx <= 0 || !metersPerPx.isFinite) return points;

  final cellMeters = gridPx * metersPerPx;
  // 纬度方向：1 度 ≈ 111320 m；经度方向再除以 cos(lat)
  final cellLat = cellMeters / 111320.0;
  final cellLng = cellLat / math.cos(corridorLat * math.pi / 180);
  if (cellLat <= 0 || cellLng <= 0) return points;

  final kept = <int, PointRow>{}; // 格子键 → 保留的点
  final keys = <int, (int, int)>{};
  for (final p in points) {
    keys[p.id!] = (
      (p.lat / cellLat).floor(),
      (p.lng / cellLng).floor(),
    );
  }

  // 1) 豁免点先占位
  for (final p in points) {
    if (!alwaysShow.contains(p.id)) continue;
    kept[_key(keys[p.id]!)] = p;
  }
  // 2) 其余按 id 小优先排序后，逐格填空
  //
  // v12 去掉了"有名字的点优先"那一条：**几何点表没有 name 列了**（D9）——
  // 要给一个位置起名字就用世界域的要素（门/世界要素/记录点），
  // 那些东西本来各有各的渲染方式，不该混进点的抽稀规则里。
  final rest = [for (final p in points) if (!alwaysShow.contains(p.id)) p]
    ..sort((a, b) => a.id!.compareTo(b.id!));
  for (final p in rest) {
    final k = _key(keys[p.id!]!);
    kept.putIfAbsent(k, () => p);
  }

  // 按 id 排序返回：渲染顺序稳定（不然每帧 marker 顺序都在变）
  return kept.values.toList()..sort((a, b) => a.id!.compareTo(b.id!));
}

int _key((int, int) c) => c.$1 * 1000003 + c.$2;
