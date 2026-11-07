/// **编辑工具与它的域归属**（docs/design/19-layers-and-route-width.md + 23 章）
///
/// 用户原话（2026-09-14）：
/// > 编辑界面可以编辑**路网、世界图、行政区域**三种地图图层。
///
/// ## v12 之后：图层就是域
///
/// 19 章时"图层"还是编辑界面上的一层壳（`MapLayer`），数据层并不按它分。
/// v12 起两者合而为一 —— **域就是表前缀**（[MapDomain]），
/// 所以这个文件不再需要自己的 `MapLayer` 枚举与 `ofLineKind` / `ofAreaType`
/// 那两个映射函数：**线的域就是它的表**，"这张表就是界线 / 路线 / 行政线"。
///
/// 这里只剩下**工具**以及"每个工具属于哪些域"。
///
/// 这个文件是**纯 Dart**（枚举 + 归属关系，不 import flutter），理由有两条：
/// 1. **域归属是领域知识，不是 UI 细节** —— "界线的工具属于世界图、路线的工具属于路网"
///    是我们对地图的划分方式，任何界面（桌面、将来的移动版、甚至批量脚本）
///    都该得到同一份划分；
/// 2. 于是 `tool/checks/` 能在**纯 Dart VM** 里验证"每个工具至少属于一个域、
///    每个域都有选择工具"这些不变式 —— 放在 `features/` 里就只能靠人眼看。
library;

import 'models.dart';

/// 域在编辑界面上的补充属性。
///
/// 放在这个文件（而不是 models.dart）是为了**避免循环 import**：
/// `EditTool` 住在这里，而 `models.dart` 不该反过来认识工具。
extension MapDomainEdit on MapDomain {
  /// 切到这个域时默认选中的工具：统一是「选择」。
  ///
  /// 切图层不等于要马上画东西，直接落进某个画图工具会让"我只是想看看这层"
  /// 变成"我画了一笔"。
  EditTool get defaultTool => EditTool.browse;
}

/// 编辑工具。
///
/// v12 的两处变化：
/// - **`wall`（加墙体段）删除** —— D5：真库 0 行，墙体段这个概念没有了；
/// - **`polygon`（一笔画圈地）的落点变了** —— 它现在产出 **`world_polygons`**
///   （只造一圈点，**不再造线**），而「围合成区域」[area] 才是用线围。
///   判据见 23 章：**这条边需要单独设属性、挂东西、或被别处共用吗？**
enum EditTool {
  browse('选择', '点选已画的点/线/面进行改名、改属性、删除'),
  point('标点', '在地图上落一个点，供拼线/拼面用'),
  boundaryLine('界线', '逐段点已有**点**拉出一条界线（可以拐弯），点「完成」结束'),
  routeLine('路线', '逐段点已有**点**拉出一条路线（可以拐弯），点「完成」结束'),
  adminLine('行政线', '逐段点已有**点**拉出一条行政线（虚拟，可以拐弯），点「完成」结束'),
  area('围合成区域', '依次点几条首尾相接的**线**，闭合后成为一个区域（边是共享实体）'),
  polygon(
    '一笔画多边形',
    '连续点若干拐角，一次圈出一个多边形 —— **只造点、不造线**；'
        '要给它挂门或给边设材质，再用「转成区域」',
  ),
  shop('店铺', '点一条界线，在线上加店铺（店名/门牌号/描述/宽度）'),
  gate('门', '点一条界线，在线上放置出入口'),
  basemap('选取底图', '点按底图上的路 / POI，把它们带走变成你自己的数据');

  const EditTool(this.label, this.hint);
  final String label;

  /// 工具栏上给用户看的一句话说明。
  final String hint;

  /// 这个工具在**哪些域**里出现。
  ///
  /// 一个工具可以属于多个域：「选择」三层都要（不然切过去就动不了）、
  /// 「围合成区域」在世界图围普通区域、在行政区域层围行政区域、
  /// 「选取底图」既能带路（→路网）也能带 POI（→世界图的常送点）。
  ///
  /// **每个工具至少要属于一个域** —— 否则它就是个点不到的死代码；
  /// **每个域都要有「选择」** —— 否则切过去连东西都点不中。
  Set<MapDomain> get domains => switch (this) {
    EditTool.browse => const {
      MapDomain.way,
      MapDomain.world,
      MapDomain.zone,
    },
    EditTool.point => const {
      MapDomain.way,
      MapDomain.world,
      MapDomain.zone,
    },
    EditTool.boundaryLine => const {MapDomain.world},
    EditTool.routeLine => const {MapDomain.way},
    EditTool.adminLine => const {MapDomain.zone},
    // 围合成区域：世界图围普通区域、行政区域层围行政区域。
    // 落库时按所选线的域自动判定（commitRing 里那套校验），所以同一个工具够用。
    EditTool.area => const {MapDomain.world, MapDomain.zone},
    // 多边形只存在于世界图的表里（23 章没有 zone_polygons）。
    EditTool.polygon => const {MapDomain.world},
    EditTool.shop => const {MapDomain.world},
    // 门与要素都锚定在**世界图的界线**上（D21），所以它们只在世界图域里出现。
    EditTool.gate => const {MapDomain.world},
    // 底图带入的主产物是**路线**（路网域），顺带也能带 POI 成常送点（世界图）。
    EditTool.basemap => const {MapDomain.way, MapDomain.world},
  };

  /// 这个域里的工具（按 [EditTool.values] 的声明顺序）。
  static List<EditTool> toolsOf(MapDomain domain) =>
      [for (final t in values) if (t.domains.contains(domain)) t];

  /// 这个工具的**归属域**：`domains` 里的第一个。
  ///
  /// 用于"工具不在当前域时该切到哪一层"（见 `EditModeController.setTool`）。
  /// 所以 `domains` 里的**顺序有意义**：第一个必须是这个工具最常被用到的那一层
  /// （例如「选取底图」先写路网）。
  MapDomain get primaryDomain => domains.first;

  /// 这个工具是不是"点已有点 → 拉出一条折线"。
  bool get isPolyline =>
      this == EditTool.boundaryLine ||
      this == EditTool.routeLine ||
      this == EditTool.adminLine;

  /// 折线工具拉出来的线属于哪个域（不是折线工具时返回 null）。
  ///
  /// 这就是 19 章 `MapLayer.ofLineKind` 的**反向**：那时要从线的 kind 推图层，
  /// 现在工具直接决定域 —— 因为**域就是表**，不存在"两边不一致"的可能。
  MapDomain? get lineDomain => switch (this) {
    EditTool.boundaryLine => MapDomain.world,
    EditTool.routeLine => MapDomain.way,
    EditTool.adminLine => MapDomain.zone,
    _ => null,
  };
}
