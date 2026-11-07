/// 领域模型 —— **v12 三层分域**（docs/design/23-data-structure.md）
///
/// 纯 Dart 模型 + 与 DB 行/GeoJSON 的映射。DAO 层见 data/ 目录（依赖 sqflite）。
/// 枚举的 storage 值与 SQLite 列值一致。
///
/// ## 这一版最大的变化：**表名就是那个类型**
///
/// 于是这些概念**整体消失**，不再有对应的枚举：
///
/// | 消失的 | 现在是什么 |
/// |--------|-----------|
/// | `LineKind`（界线/路线/行政线） | [MapDomain]：`world` / `way` / `zone` |
/// | `AreaType.administrative` + `isVirtual` | 表 `zone_areas`（虚拟域整域跳过） |
/// | `PointKind`（辅助点/店铺/门/路点） | 表：`*_points` / `world_gates` / `world_entities` |
/// | `PointSource`（manual/recorded/gps） | 表 `world_marks` + 一个 `by_gps` 布尔 |
/// | `EntityType` 的 7 值 | [EntityType] 收敛到 5 值（与 `area_type` 同一套写法） |
/// | `hasMaterial` / `hasRouteWidth` 判据 | 表：材质列只在 `world_lines`、路宽列只在 `way_lines` |
///
/// ## 三条贯穿全库的约定
///
/// 1. **端点仍是两列**：[LineRow.startPointId] / [LineRow.endPointId]，
///    拐点才在 [LineRow.bendPointIds] 里 —— 用户明确"保留 line 的端点特殊性"；
/// 2. **拐点是链**：`(line_id, point_id, before_point_id)`，每行记"我的前驱"，
///    于是插入/删除是 O(1) 指针操作（见 `core/line_edit.dart`）；
/// 3. **封闭图形有两种构造**：[AreaRow] 由**线**围成、[PolygonRow] 由**点**围成，
///    两者同一语义、可互相转换（见 `core/shape_convert.dart`）。
///
/// ## 读出口只有一个
///
/// [LineRow.pointIds] 是"这条线长什么样"的**唯一出口**（= `[起点, ...拐点, 终点]`）。
/// 任何地方都别自己拼 `[startPointId, endPointId]` —— 那会把折线悄悄拉直。
library;

import 'floor_set.dart';
import 'geometry.dart';

// ---------------------------------------------------------------------------
// 域
// ---------------------------------------------------------------------------

/// **域** —— 三层分域的第一层，也是 v12 唯一的"分类"轴。
///
/// 它的 [prefix] 就是**表前缀**，所以「一个域有哪些表」这件事只有这一处定义：
/// DAO 用 `domain.pointsTable` 之类拼表名，于是物理上真分表、代码上只有一份。
///
/// | 域 | 表前缀 | 描述什么世界 |
/// |----|--------|-------------|
/// | [way] 路网 | `way_` | 我自己跑的路：路线 + 行驶轨迹 |
/// | [world] 世界图 | `world_` | 现实实体：界线 / 区域 / 多边形 / 门 / 世界要素 / 记录点 |
/// | [zone] 行政区域 | `zone_` | 虚拟的行政边界（**寻路必须跳过整域**） |
enum MapDomain {
  way('way', '路网', '自己跑的路：路线（可以拐弯）与路上的点'),
  world('world', '世界图', '现实世界：围墙/铁栏、小区/建筑/河道、门、店铺、多边形'),
  zone('zone', '行政区域', '虚拟的行政边界：行政线，以及用行政线围出来的行政区域（寻路会跳过）');

  const MapDomain(this.prefix, this.label, this.hint);

  /// 表前缀。**域由表名表达**，所以它是这个枚举最重要的成员。
  final String prefix;

  final String label;

  /// 工具条/表单上给用户看的一句话说明。
  final String hint;

  String get pointsTable => '${prefix}_points';
  String get linesTable => '${prefix}_lines';
  String get lineBendsTable => '${prefix}_line_bends';

  /// 路网域没有"封闭图形"（路线是路径，不是环）。
  bool get hasAreas => this != MapDomain.way;

  /// 有 [hasAreas] 才有意义。
  String get areasTable => '${prefix}_areas';
  String get areaLinesTable => '${prefix}_area_lines';

  /// 图层主色（ARGB，UI 层包装成 Color）。
  ///
  /// 与三层的既有配色一致：路网=路线的蓝、世界图=界线的蓝灰、行政区域=行政线的青。
  /// 放在 core 里是为了与 [BoundaryType] / [AreaType] 那些"带默认色"的枚举保持一致。
  int get defaultColor => switch (this) {
    MapDomain.way => 0xFF1E88E5,
    MapDomain.world => 0xFF546E7A,
    MapDomain.zone => 0xFF00838F,
  };

  /// 这个域是虚拟的吗（不构成通行/访问的世界实体）。
  ///
  /// **寻路（M2）必须跳过虚拟域**，否则"凤岗镇"会变成一个不能穿越的巨型障碍。
  bool get isVirtual => this == MapDomain.zone;

  static MapDomain fromPrefix(String? v) => values.firstWhere(
    (e) => e.prefix == v,
    orElse: () => MapDomain.world,
  );
}

// ---------------------------------------------------------------------------
// 枚举与扩展（storage 值 = 数据库列值）
// ---------------------------------------------------------------------------

/// **way_lines.route_width** —— 路线是什么路（第十九章，v10 新增）。
///
/// 前三个是**宽度/形态**（街边有围栏的通道、主干道、城中村窄巷），
/// 接着两个是**桥**（骑行天桥能骑上去、步行天桥只能推 —— 骑手最在意的差别），
/// 所以"天桥"和"路宽"合成一根轴（[isBridge] 让渲染画虚线）。
///
/// **[crossing] 换路口**（21 章）是第 6 个值，性质与前五个不同：它不是"一段什么样的路"，
/// 而是**路口处那一小段横穿的连接线**（把一往一来的两条围栏路接起来）。
/// 判据用 [isCrossing]；"接没接上"一律问 `core/route_crossing.dart`。
enum RouteWidth {
  fenced(
    'fenced',
    '围栏路',
    0xFF00897B,
    2.6,
    '两侧有围栏/铁丝网的通道（小区间、工地旁）',
  ),
  main('main', '大马路', 0xFF1E88E5, 3.4, '主干道，双向、车流大，一般不堵但绕'),
  narrow('narrow', '小窄路', 0xFF5C6BC0, 2.0, '城中村窄巷，能过但会车困难'),
  bikeBridge(
    'bike_bridge',
    '骑行天桥',
    0xFF8E24AA,
    2.6,
    '能骑上去的天桥/高架便道（有坡道）',
  ),
  walkBridge(
    'walk_bridge',
    '步行天桥',
    0xFFEF6C00,
    2.0,
    '只能推着走的步行天桥/台阶道',
  ),
  crossing(
    'crossing',
    '换路口',
    0xFFC2185B,
    3.6,
    '围栏路两侧可以交换的路口：画成横穿的那一小段线，'
        '两个端点各点一下两条围栏路上的点（一往一来各一条）',
  );

  const RouteWidth(
    this.storage,
    this.label,
    this.defaultColor,
    this.strokeWidth,
    this.hint,
  );

  final String storage;
  final String label;

  /// 线颜色（ARGB，UI 层包装成 Color）。
  final int defaultColor;

  /// 渲染线宽（像素）。大马路粗、窄巷细 —— 一眼看出这条路的体量。
  final double strokeWidth;

  /// 表单里给用户看的一句话说明。
  final String hint;

  /// 是不是**天桥**（渲染画虚线：它在空中，不在地面上）。
  bool get isBridge =>
      this == RouteWidth.bikeBridge || this == RouteWidth.walkBridge;

  /// 是不是**换路口**（21 章）：路口处横穿的那一小段连接线。
  bool get isCrossing => this == RouteWidth.crossing;

  static RouteWidth? fromStorageOrNull(String? v) {
    if (v == null) return null;
    for (final e in values) {
      if (e.storage == v) return e;
    }
    return null;
  }
}

/// **way_lines.cost_class** —— **已冻结**（第十九章）。
///
/// 2026-09-14 用户明确：**路线的属性是路宽（[RouteWidth]），不是通行代价**。
/// 但列与模型都留着：老数据里有值（真库 33 行），删了就是白丢数据；
/// 而且 M2 寻路一定会重新需要"这条边好不好走"这个输入。
///
/// 界限：**不准再往表单里加回来**，除非寻路那一章明确给出了它的求值语义。
enum CostClass {
  ride('ride', '可骑行'),
  push('push', '推行'),
  walk('walk', '仅步行'),
  stair('stair', '台阶');

  const CostClass(this.storage, this.label);
  final String storage;
  final String label;

  static CostClass fromStorage(String? v) =>
      values.firstWhere((e) => e.storage == v, orElse: () => CostClass.ride);
}

/// **world_lines.boundary_type** —— 界线的物理材质（v4 从 areas 搬到 lines）。
///
/// 决定渲染线型与颜色；也是「能不能翻过去」的直观提示。
/// **只对界线有意义** —— 路线的形态看 [RouteWidth]，行政线两者皆无。
/// 这条判据现在由表保证（材质列只在 `world_lines` 上）。
enum BoundaryType {
  wall('wall', '实体墙', 0xFFD32F2F),
  fence('fence', '铁栅栏', 0xFFE57373),
  hedge('hedge', '绿化带', 0xFF66BB6A),
  river('river', '河道', 0xFF29B6F6),
  construction('construction', '施工围挡', 0xFFFFA726),
  none('none', '软边界', 0xFF9E9E9E);

  const BoundaryType(this.storage, this.label, this.defaultColor);
  final String storage;
  final String label;

  /// 线颜色（ARGB，可在 UI 层包装成 Color）。
  final int defaultColor;

  static BoundaryType fromStorage(String? v) =>
      values.firstWhere((e) => e.storage == v, orElse: () => BoundaryType.none);

  /// 可空版本：材质可以是「未指定」（区别于显式的「软边界」）。
  static BoundaryType? fromStorageOrNull(String? v) {
    if (v == null) return null;
    for (final e in values) {
      if (e.storage == v) return e;
    }
    return null;
  }
}

/// **world_areas.area_type / world_polygons.area_type** —— 封闭图形的语义类型。
///
/// 前四类是**世界实体**（会影响通行/访问判定）：
/// - [road] 道路：是**能走的地方**，寻路时要走进去；
/// - [community] 小区：有门、有门禁，只能从门进出（本 App 的核心场景）；
/// - [building] 建筑：具体的楼栋本体，实心不可穿越（与阻隔的区别是它**有确切轮廓**）；
/// - [barrier] 阻隔：纯障碍（河道、工地、山体），谁都不能穿。
///
/// ⚠️ **`administrative` 已经不是这个枚举的一个值了**（v12）：行政区域是
/// **`zone_areas` 那张表**，`isVirtual` 也随之上移到 [MapDomain.isVirtual]。
/// 于是"忘了跳过虚拟区域"这类 bug 在结构上很难再发生 —— 域一分，跳过整域即可。
///
/// 加值**不需要 schema 迁移**（自由文本列 + `fromStorage` 兜底）。
enum AreaType {
  road('road', '道路', 0xFF8D6E63, '可以走进去的区域'),
  community('community', '小区', 0xFF7E57C2, '有门禁，只能从门进出'),
  building('building', '建筑', 0xFF546E7A, '具体的楼栋本体，不可穿越'),
  barrier('barrier', '阻隔', 0xFFD32F2F, '纯障碍，谁都不能穿');

  const AreaType(this.storage, this.label, this.defaultColor, this.hint);

  final String storage;
  final String label;

  /// 蒙层颜色（ARGB，UI 层包装成 Color）。
  final int defaultColor;

  /// 一句话说明（表单里给用户看）。
  final String hint;

  static AreaType fromStorage(String? v) {
    // v11 及更早的备份里可能有 'administrative' —— 行政区域已搬到 zone_areas，
    // 落到这里说明文件被手改过或来自更老的版本；兜底成小区（宁可显示也不要丢）。
    return values.firstWhere(
      (e) => e.storage == v,
      orElse: () => AreaType.community,
    );
  }
}

/// **world_gates.gate_type** —— 门的类型（第十五章）。
///
/// 三类的差别不在"能不能过"，而在**它通向哪里**：
/// - [park] 园区门：小区的出入口，通向街道 —— 寻路时它是"墙上的一个洞"；
/// - [building] 建筑门：楼栋的单元门/大门，通向楼内；
/// - [stair] 楼梯口：**通向其它楼层**，多楼层路网要靠它接起来。
enum GateType {
  park('park', '园区门', 0xFF2E7D32, '小区/园区的出入口，通向街道'),
  building('building', '建筑门', 0xFF1565C0, '楼栋的单元门/大门，通向楼内'),
  stair('stair', '楼梯口', 0xFFEF6C00, '通向其它楼层（多楼层编辑要用）');

  const GateType(this.storage, this.label, this.defaultColor, this.hint);

  final String storage;
  final String label;

  /// 旗标颜色。
  final int defaultColor;

  /// 表单里给用户看的一句话说明。
  final String hint;

  static GateType fromStorage(String? v) =>
      values.firstWhere((e) => e.storage == v, orElse: () => GateType.park);
}

/// **world_entities.entity_type** —— 世界要素的类型（D18：从 7 值收敛到 5 值）。
///
/// 与 [AreaType] 是**同一套逻辑**：这些类型的**列完全相同**（类型/名字/门牌号/
/// 描述/挂线/坐标/宽度），所以共用一张 `world_entities` 表；
/// 而**门**单独一张 `world_gates`，因为它的列集完全不同（车型/门禁/永久性）。
///
/// 去掉的两个值：
/// - `wall`（墙体段）—— D5 删除，真库 0 行；
/// - `gate_landmark`（地标）—— 门有自己的表，不需要"地标"这个中间物。
enum EntityType {
  shop('shop', '店铺'),
  building('building', '楼栋'),
  unit('unit', '单元'),
  deliveryPoint('delivery_point', '常送点'),
  parking('parking', '停车点');

  const EntityType(this.storage, this.label);
  final String storage;
  final String label;

  static EntityType fromStorage(String? v) {
    // 老备份（v3/v4）里可能是 door（门牌）或 stall（档口）—— 语义上都是"沿街门面"。
    if (v == 'door' || v == 'stall') return EntityType.shop;
    return values.firstWhere(
      (e) => e.storage == v,
      orElse: () => EntityType.deliveryPoint,
    );
  }
}

// ---------------------------------------------------------------------------
// 行模型
// ---------------------------------------------------------------------------

/// 几何点表 `<域>_points`。
///
/// 它就是"一条线的点"（端点与拐点都是它），**没有名字**（D9）——
/// 要给一个位置起名字，用世界域的要素（门/世界要素/记录点）。
/// 轨迹点不在这里，在 [WayMarkRow]（它是原始采集数据，不是几何）。
class PointRow {
  const PointRow({
    this.id,
    this.domain = MapDomain.world,
    required this.lat,
    required this.lng,
    this.floors,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final int? id;

  /// 这个点属于哪个域（= 它在哪张表里）。
  final MapDomain domain;

  final double lat;
  final double lng;

  /// **参与构成哪些楼层**（v8「等高」）。null = 默认只有地面层。
  final FloorSet? floors;

  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  GeoPoint get geo => GeoPoint(lat, lng);

  /// 列表/标签里显示的名字。点没有名字，只能给个可读的兜底。
  String get displayName => '点 #$id';

  PointRow copyWith({
    int? id,
    MapDomain? domain,
    double? lat,
    double? lng,
    FloorSet? floors,
  }) => PointRow(
    id: id ?? this.id,
    domain: domain ?? this.domain,
    lat: lat ?? this.lat,
    lng: lng ?? this.lng,
    floors: floors ?? this.floors,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
  );

  Map<String, Object?> toDb() => {
    if (id != null) 'id': id,
    'lat': lat,
    'lng': lng,
    'floors': (floors ?? FloorSet.ground).toStorage(),
    'created_at': (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
    'updated_at': (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
    if (deletedAt != null) 'deleted_at': deletedAt!.millisecondsSinceEpoch,
  };

  factory PointRow.fromDb(
    Map<String, Object?> row, {
    MapDomain domain = MapDomain.world,
  }) => PointRow(
    id: row['id'] as int?,
    domain: domain,
    lat: (row['lat'] as num).toDouble(),
    lng: (row['lng'] as num).toDouble(),
    floors: FloorSet.fromStorage(row['floors'] as String?),
    createdAt: _ts(row['created_at']),
    updatedAt: _ts(row['updated_at']),
    deletedAt: _ts(row['deleted_at']),
  );
}

/// 线表 `<域>_lines`。**三个域的线都是它**，差别只在域（哪张表）与域特有的属性列。
///
/// **端点是两列、拐点是链**（D4 + D13）：
/// - [startPointId] / [endPointId] 是 DB 列，`NOT NULL` —— 于是"点数 ≥ 2"天然成立；
/// - [bendPointIds] 读自 `<域>_line_bends`，**顺序是沿链走出来的**，
///   由 `AppRepository` 单独查一次填进来（与 [AreaRow.lineIds] 的处理方式一致），
///   `toDb()` 不写它 —— 链的增删由 `setLineShape` 一族维护。
///
/// [pointIds] 是"这条线长什么样"的**唯一出口**。别自己拼 `[start, end]`。
class LineRow {
  const LineRow({
    this.id,
    this.domain = MapDomain.way,
    required this.startPointId,
    required this.endPointId,
    this.bendPointIds = const [],
    this.name,
    this.floors,
    this.boundaryType,
    this.routeWidth,
    this.costClass,
    this.oneWay = false,
    this.note,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final int? id;

  /// 这条线属于哪个域 —— 它就是"界线 / 路线 / 行政线"这个区分本身。
  final MapDomain domain;

  final int startPointId;
  final int endPointId;

  /// **中间拐点**的 id，按从起点到终点的顺序（读链得来，见类注释）。
  final List<int> bendPointIds;

  final String? name;

  /// **参与构成哪些楼层**（v8「等高」）。
  final FloorSet? floors;

  /// 边界材质（只有 `world_lines` 有这一列）。null = 未指定。
  final BoundaryType? boundaryType;

  /// **路宽 / 道路类型**（只有 `way_lines` 有这一列）。null = 未指定。
  final RouteWidth? routeWidth;

  /// 通行代价（**已冻结、不再编辑**，只有 `way_lines` 有这一列）。见 [CostClass]。
  final CostClass? costClass;

  /// 单行（只有 `way_lines` 有这一列）。
  final bool oneWay;

  final String? note;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  String get displayName => (name == null || name!.isEmpty) ? '线 #$id' : name!;

  /// **完整的点序列**（起点 → 拐点… → 终点）。
  ///
  /// 一切需要"这条线长什么样"的地方都应当从这里出发 ——
  /// 自己拼 `[startPointId, endPointId]` 会把所有折线**悄悄拉直**
  /// （不报错、不崩溃，就是画错）。
  List<int> get pointIds => [startPointId, ...bendPointIds, endPointId];

  /// 点数（含两个端点）。2 = 一条直线段。
  int get pointCount => bendPointIds.length + 2;

  /// 是不是折线（有拐点）。
  bool get isBent => bendPointIds.isNotEmpty;

  /// 这个点是否参与构成这条线（端点**或**拐点）。
  bool hasPoint(int pointId) =>
      pointId == startPointId ||
      pointId == endPointId ||
      bendPointIds.contains(pointId);

  /// 这条线能不能有「边界材质」——**只有世界图的界线有**。
  ///
  /// 判据收在这里：别处一律问它，别再写 `domain == MapDomain.world`
  /// （表名就是那个类型，所以这条判据天然只有一处）。
  bool get hasMaterial => domain == MapDomain.world;

  /// 这条线能不能有「路宽」——**只有路网的路线有**。
  bool get hasRouteWidth => domain == MapDomain.way;

  /// 现在的表名（域 + 角色）。DAO 用它拼 SQL。
  String get table => domain.linesTable;

  LineRow copyWith({
    int? id,
    MapDomain? domain,
    int? startPointId,
    int? endPointId,
    List<int>? bendPointIds,
    String? name,
    bool clearName = false,
    FloorSet? floors,
    BoundaryType? boundaryType,
    bool clearBoundaryType = false,
    RouteWidth? routeWidth,
    bool clearRouteWidth = false,
    CostClass? costClass,
    bool clearCostClass = false,
    bool? oneWay,
    String? note,
  }) => LineRow(
    id: id ?? this.id,
    domain: domain ?? this.domain,
    startPointId: startPointId ?? this.startPointId,
    endPointId: endPointId ?? this.endPointId,
    bendPointIds: bendPointIds ?? this.bendPointIds,
    name: clearName ? null : (name ?? this.name),
    floors: floors ?? this.floors,
    boundaryType: clearBoundaryType ? null : (boundaryType ?? this.boundaryType),
    routeWidth: clearRouteWidth ? null : (routeWidth ?? this.routeWidth),
    costClass: clearCostClass ? null : (costClass ?? this.costClass),
    oneWay: oneWay ?? this.oneWay,
    note: note ?? this.note,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
  );

  /// ⚠️ 只写 `<域>_lines` 自己的列。**拐点链不在这里** —— 它由
  /// `AppRepository.setLineShape` 一族维护（两处必须原子地一起改）。
  Map<String, Object?> toDb() => {
    if (id != null) 'id': id,
    if (name != null) 'name': name,
    'floors': (floors ?? FloorSet.ground).toStorage(),
    'start_point_id': startPointId,
    'end_point_id': endPointId,
    if (boundaryType != null) 'boundary_type': boundaryType!.storage,
    if (routeWidth != null) 'route_width': routeWidth!.storage,
    if (costClass != null) 'cost_class': costClass!.storage,
    if (oneWay) 'one_way': 1,
    if (note != null) 'note': note,
    'created_at': (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
    'updated_at': (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
    if (deletedAt != null) 'deleted_at': deletedAt!.millisecondsSinceEpoch,
  };

  /// [bendPointIds] 由调用方从链上走出来带上（见 `AppRepository._attachLineBends`）。
  factory LineRow.fromDb(
    Map<String, Object?> row, {
    MapDomain domain = MapDomain.way,
    List<int> bendPointIds = const [],
  }) => LineRow(
    id: row['id'] as int?,
    domain: domain,
    startPointId: row['start_point_id'] as int,
    endPointId: row['end_point_id'] as int,
    bendPointIds: bendPointIds,
    name: row['name'] as String?,
    floors: FloorSet.fromStorage(row['floors'] as String?),
    boundaryType: BoundaryType.fromStorageOrNull(row['boundary_type'] as String?),
    routeWidth: RouteWidth.fromStorageOrNull(row['route_width'] as String?),
    costClass: row['cost_class'] == null
        ? null
        : CostClass.fromStorage(row['cost_class'] as String?),
    oneWay: (row['one_way'] as int? ?? 0) == 1,
    note: row['note'] as String?,
    createdAt: _ts(row['created_at']),
    updatedAt: _ts(row['updated_at']),
    deletedAt: _ts(row['deleted_at']),
  );
}

/// 区域表 `<域>_areas` —— **由线围成**的封闭图形。
///
/// 它的边是**共享的线**：有材质、能命名、能挂门与要素、能被多个区域共用
/// （实测真库 `line 1` 同时属于两个区域）。所以环是**推导**出来的
/// （`core/ring.dart` 按边建图遍历，**可能失败**）。
///
/// 对比 [PolygonRow]：那个由**点**围成、环是**存下来的**、永远有效。
/// 两者同一语义、可互相转换（`core/shape_convert.dart`）。
class AreaRow {
  const AreaRow({
    this.id,
    this.domain = MapDomain.world,
    required this.name,
    this.areaType = AreaType.community,
    this.floors,
    this.colorOverride,
    this.sortOrder = 0,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
    this.lineIds = const [],
  });

  final int? id;
  final MapDomain domain;
  final String name;

  /// 封闭图形的语义类型。**行政区域不是这个枚举的值** —— 它是 `zone_areas` 那张表，
  /// 那儿的行不读这一列（`zone_areas` 根本没有这一列）。
  final AreaType areaType;

  final FloorSet? floors;

  /// 蒙层颜色覆盖。null = 按 [areaType] 取默认色。
  final int? colorOverride;

  /// 叠放顺序（z-order）。⚠️ 与已删除的 `area_lines.sort_order`（成员的点选次序）
  /// **不是一回事**（D14）。
  final int sortOrder;

  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  /// 围成该区域的线 id（来自 `<域>_area_lines`）。
  ///
  /// **不是 DB 列**：读库时由 `AppRepository` 单独查一次填进来。放在这里是为了让
  /// 「一个 AreaRow」就能表达完整的区域，UI 与导出不必再各自查一次。
  /// ⚠️ 顺序**无意义**（组环按边建图，不读顺序）。
  final List<int> lineIds;

  /// UI 可读摘要（04 章 §2）。
  String get summary => areaType.label;

  /// 蒙层颜色：用户覆盖优先，否则按类型。
  int get color => colorOverride ?? areaType.defaultColor;

  String get table => domain.areasTable;

  AreaRow copyWith({
    int? id,
    MapDomain? domain,
    String? name,
    AreaType? areaType,
    FloorSet? floors,
    int? colorOverride,
    int? sortOrder,
    List<int>? lineIds,
  }) => AreaRow(
    id: id ?? this.id,
    domain: domain ?? this.domain,
    name: name ?? this.name,
    areaType: areaType ?? this.areaType,
    floors: floors ?? this.floors,
    colorOverride: colorOverride ?? this.colorOverride,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
    lineIds: lineIds ?? this.lineIds,
  );

  Map<String, Object?> toDb() => {
    if (id != null) 'id': id,
    'name': name,
    'area_type': areaType.storage,
    'floors': (floors ?? FloorSet.ground).toStorage(),
    if (colorOverride != null) 'color_override': colorOverride,
    'sort_order': sortOrder,
    'created_at': (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
    'updated_at': (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
    if (deletedAt != null) 'deleted_at': deletedAt!.millisecondsSinceEpoch,
  };

  factory AreaRow.fromDb(
    Map<String, Object?> row, {
    MapDomain domain = MapDomain.world,
  }) => AreaRow(
    id: row['id'] as int?,
    domain: domain,
    name: row['name'] as String,
    // zone_areas **没有 area_type 列** → 那里读出来是 null，兜底成 community
    // （反正虚拟域整域跳过，这个值不会被用到）。
    areaType: AreaType.fromStorage(row['area_type'] as String?),
    floors: FloorSet.fromStorage(row['floors'] as String?),
    colorOverride: row['color_override'] as int?,
    sortOrder: row['sort_order'] as int? ?? 0,
    createdAt: _ts(row['created_at']),
    updatedAt: _ts(row['updated_at']),
    deletedAt: _ts(row['deleted_at']),
  );
}

/// 多边形表 `world_polygons` —— **由点围成**的封闭图形（D19）。
///
/// 与 [AreaRow] **同一语义、两种构造**，判据一句话：
/// **这条边需要单独设属性、挂东西、或被别处共用吗？需要 → area，不需要 → polygon。**
///
/// ⚠️ 门与世界要素**挂不上它**（D21：单一锚点在线）——
/// 要给多边形挂门，先 `polygonToArea` 转成区域。
class PolygonRow {
  const PolygonRow({
    this.id,
    this.domain = MapDomain.world,
    required this.name,
    this.areaType = AreaType.community,
    this.floors,
    this.colorOverride,
    this.sortOrder = 0,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
    this.pointIds = const [],
  });

  final int? id;
  final MapDomain domain;
  final String name;

  /// 与 [AreaRow.areaType] 同一套值域 —— 因为语义就是同一个。
  final AreaType areaType;

  final FloorSet? floors;
  final int? colorOverride;
  final int sortOrder;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  /// 环上的点，**按环序**（读链得来；环没有头，从哪一点开始都等价）。
  ///
  /// **不是 DB 列**：读库时由 `AppRepository` 走链填进来（与 [LineRow.bendPointIds] 同理）。
  final List<int> pointIds;

  String get summary => areaType.label;

  int get color => colorOverride ?? areaType.defaultColor;

  /// 至少 3 个点才构成封闭图形。
  bool get isClosedEnough => pointIds.length >= 3;

  String get table => '${domain.prefix}_polygons';

  PolygonRow copyWith({
    int? id,
    MapDomain? domain,
    String? name,
    AreaType? areaType,
    FloorSet? floors,
    int? colorOverride,
    int? sortOrder,
    List<int>? pointIds,
  }) => PolygonRow(
    id: id ?? this.id,
    domain: domain ?? this.domain,
    name: name ?? this.name,
    areaType: areaType ?? this.areaType,
    floors: floors ?? this.floors,
    colorOverride: colorOverride ?? this.colorOverride,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
    pointIds: pointIds ?? this.pointIds,
  );

  Map<String, Object?> toDb() => {
    if (id != null) 'id': id,
    'name': name,
    'area_type': areaType.storage,
    'floors': (floors ?? FloorSet.ground).toStorage(),
    if (colorOverride != null) 'color_override': colorOverride,
    'sort_order': sortOrder,
    'created_at': (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
    'updated_at': (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
    if (deletedAt != null) 'deleted_at': deletedAt!.millisecondsSinceEpoch,
  };

  factory PolygonRow.fromDb(
    Map<String, Object?> row, {
    MapDomain domain = MapDomain.world,
    List<int> pointIds = const [],
  }) => PolygonRow(
    id: row['id'] as int?,
    domain: domain,
    name: row['name'] as String,
    areaType: AreaType.fromStorage(row['area_type'] as String?),
    floors: FloorSet.fromStorage(row['floors'] as String?),
    colorOverride: row['color_override'] as int?,
    sortOrder: row['sort_order'] as int? ?? 0,
    createdAt: _ts(row['created_at']),
    updatedAt: _ts(row['updated_at']),
    deletedAt: _ts(row['deleted_at']),
    pointIds: pointIds,
  );
}

/// 门表 `world_gates`（第十五章）。
///
/// **门是"吸附在界线上的一处出入口"**：
///   - [lineId] —— 吸附在哪条界线上（**单一锚点**，D21：挂不上多边形）；
///   - [center] —— 中心点（不在线上时渲染会吸附到线上最近点，与世界要素同一套逻辑）。
///
/// **已移除的属性**（15 章）：时间管制、台阶、单向、启用。
class GateRow {
  const GateRow({
    this.id,
    this.name,
    this.gateType = GateType.park,
    this.lineId,
    required this.center,
    this.vehicleType = VehicleType.all,
    this.accessLevel = AccessLevel.free,
    this.isPermanent = true,
    this.note,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final int? id;
  final String? name;

  /// 门类型：园区门 / 建筑门 / 楼梯口。
  final GateType gateType;

  /// 吸附的界线。null = 还没挂线（老数据或手工插入）→ 渲染直接画在 [center] 上。
  final int? lineId;

  final GeoPoint center;

  final VehicleType vehicleType;
  final AccessLevel accessLevel;

  /// 是否为永久门（临时门可设为 false）。
  final bool isPermanent;

  final String? note;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  String get displayName => (name == null || name!.isEmpty) ? '未命名门' : name!;

  String get summary =>
      '${gateType.label} · ${vehicleType.label} · ${accessLevel.label}';

  GateRow copyWith({
    int? id,
    String? name,
    GateType? gateType,
    int? lineId,
    GeoPoint? center,
    VehicleType? vehicleType,
    AccessLevel? accessLevel,
    bool? isPermanent,
    String? note,
  }) => GateRow(
    id: id ?? this.id,
    name: name ?? this.name,
    gateType: gateType ?? this.gateType,
    lineId: lineId ?? this.lineId,
    center: center ?? this.center,
    vehicleType: vehicleType ?? this.vehicleType,
    accessLevel: accessLevel ?? this.accessLevel,
    isPermanent: isPermanent ?? this.isPermanent,
    note: note ?? this.note,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
  );

  Map<String, Object?> toDb() => {
    if (id != null) 'id': id,
    if (name != null) 'name': name,
    'gate_type': gateType.storage,
    if (lineId != null) 'line_id': lineId,
    'lat': center.lat,
    'lng': center.lng,
    'vehicle_type': vehicleType.storage,
    'access_level': accessLevel.storage,
    if (isPermanent) 'is_permanent': 1 else 'is_permanent': 0,
    if (note != null) 'note': note,
    'created_at': (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
    'updated_at': (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
    if (deletedAt != null) 'deleted_at': deletedAt!.millisecondsSinceEpoch,
  };

  factory GateRow.fromDb(Map<String, Object?> row) => GateRow(
    id: row['id'] as int?,
    name: row['name'] as String?,
    gateType: GateType.fromStorage(row['gate_type'] as String?),
    lineId: row['line_id'] as int?,
    center: GeoPoint(
      (row['lat'] as num).toDouble(),
      (row['lng'] as num).toDouble(),
    ),
    vehicleType: VehicleType.fromStorage(row['vehicle_type'] as String?),
    accessLevel: AccessLevel.fromStorage(row['access_level'] as String?),
    isPermanent: (row['is_permanent'] as int? ?? 1) == 1,
    note: row['note'] as String?,
    createdAt: _ts(row['created_at']),
    updatedAt: _ts(row['updated_at']),
    deletedAt: _ts(row['deleted_at']),
  );
}

/// 世界要素表 `world_entities`（13 章 + D18）。
///
/// 关键设计（13 章 §3）：**位置由「中心坐标」决定，不再由权重排布**。
/// 门牌时代用 `line_weight` 沿线路按比例分配位置，问题是改一个门牌的权重，
/// 整条街上所有门牌的位置都会跟着挪 —— 而真实世界的位置是**测量出来的**。
/// 现在每个要素自带 [lat]/[lng]，渲染时若不在线上就吸附到线上最近的点。
class EntityRow {
  const EntityRow({
    this.id,
    this.entityType = EntityType.deliveryPoint,
    required this.name,
    this.doorNo,
    this.desc,
    this.lineId,
    required this.lat,
    required this.lng,
    this.width,
    this.note,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final int? id;

  /// 要素类型（5 值，见 [EntityType]）。**业务键必须带它** ——
  /// 否则同一位置同名的「店铺」与「停车点」会在导入时互相顶掉。
  final EntityType entityType;

  final String name;
  final String? doorNo;
  final String? desc;

  /// 挂在哪条界线上。
  final int? lineId;

  /// **中心坐标** —— 渲染位置的真身（不在线上时吸附到线上最近点）。
  final double lat;
  final double lng;

  /// 宽度（米）：店铺是门面宽。
  final double? width;

  final String? note;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  GeoPoint get center => GeoPoint(lat, lng);

  bool get isShop => entityType == EntityType.shop;

  /// 参与渲染的有效宽度（null / 非正数一律按 1 米算）。
  double get effectiveWidth => (width == null || width! <= 0) ? 1.0 : width!;

  /// 列表/标签里显示的名字：优先门牌号 + 店名。
  String get displayName {
    if (doorNo != null && doorNo!.isNotEmpty) {
      return name.isEmpty ? doorNo! : '$doorNo $name';
    }
    return name.isEmpty ? '${entityType.label} #$id' : name;
  }

  EntityRow copyWith({
    int? id,
    EntityType? entityType,
    String? name,
    String? doorNo,
    bool clearDoorNo = false,
    String? desc,
    int? lineId,
    double? lat,
    double? lng,
    double? width,
    String? note,
  }) => EntityRow(
    id: id ?? this.id,
    entityType: entityType ?? this.entityType,
    name: name ?? this.name,
    doorNo: clearDoorNo ? null : (doorNo ?? this.doorNo),
    desc: desc ?? this.desc,
    lineId: lineId ?? this.lineId,
    lat: lat ?? this.lat,
    lng: lng ?? this.lng,
    width: width ?? this.width,
    note: note ?? this.note,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
  );

  Map<String, Object?> toDb() => {
    if (id != null) 'id': id,
    'entity_type': entityType.storage,
    'name': name,
    if (doorNo != null) 'door_no': doorNo,
    if (desc != null) 'desc': desc,
    if (lineId != null) 'line_id': lineId,
    'lat': lat,
    'lng': lng,
    if (width != null) 'width': width,
    if (note != null) 'note': note,
    'created_at': (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
    'updated_at': (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
    if (deletedAt != null) 'deleted_at': deletedAt!.millisecondsSinceEpoch,
  };

  factory EntityRow.fromDb(Map<String, Object?> row) => EntityRow(
    id: row['id'] as int?,
    entityType: EntityType.fromStorage(row['entity_type'] as String?),
    name: row['name'] as String,
    doorNo: row['door_no'] as String?,
    desc: row['desc'] as String?,
    lineId: row['line_id'] as int?,
    lat: (row['lat'] as num).toDouble(),
    lng: (row['lng'] as num).toDouble(),
    width: (row['width'] as num?)?.toDouble(),
    note: row['note'] as String?,
    createdAt: _ts(row['created_at']),
    updatedAt: _ts(row['updated_at']),
    deletedAt: _ts(row['deleted_at']),
  );
}

/// 记录点表 `world_marks` —— 记录模式下"我在这儿"的落点（22 章）。
///
/// 它有自己的表，所以**整个 `PointSource` 三值枚举塌缩成一个 [byGps] 布尔**，
/// 而 22 章那条"浏览态只显示记录录入且未处理的点"变成一句话的查询。
class WorldMarkRow {
  const WorldMarkRow({
    this.id,
    this.name,
    required this.lat,
    required this.lng,
    this.floors,
    this.accuracy,
    this.byGps = false,
    this.processed = false,
    this.note,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final int? id;
  final String? name;
  final double lat;
  final double lng;
  final FloorSet? floors;

  /// 采集精度（米）。只有定位来的点才有。
  final double? accuracy;

  /// 坐标是"记录当前位置"（定位）来的，还是手点地图来的。
  final bool byGps;

  /// **这个记录点处理过了吗**（22 章）。**默认 false = 未处理**，由用户自己标记。
  /// 浏览态只显示"未处理"的；处理过的默认不再显示。
  final bool processed;

  final String? note;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  GeoPoint get geo => GeoPoint(lat, lng);

  String get displayName =>
      (name == null || name!.isEmpty) ? '记录点 #$id' : name!;

  WorldMarkRow copyWith({
    int? id,
    String? name,
    double? lat,
    double? lng,
    FloorSet? floors,
    double? accuracy,
    bool? byGps,
    bool? processed,
    String? note,
  }) => WorldMarkRow(
    id: id ?? this.id,
    name: name ?? this.name,
    lat: lat ?? this.lat,
    lng: lng ?? this.lng,
    floors: floors ?? this.floors,
    accuracy: accuracy ?? this.accuracy,
    byGps: byGps ?? this.byGps,
    processed: processed ?? this.processed,
    note: note ?? this.note,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
  );

  Map<String, Object?> toDb() => {
    if (id != null) 'id': id,
    if (name != null) 'name': name,
    'lat': lat,
    'lng': lng,
    'floors': (floors ?? FloorSet.ground).toStorage(),
    if (accuracy != null) 'accuracy': accuracy,
    // 显式写 0/1：这是"用户有没有处理过"的事实，不靠默认值兜
    'by_gps': byGps ? 1 : 0,
    'processed': processed ? 1 : 0,
    if (note != null) 'note': note,
    'created_at': (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
    'updated_at': (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
    if (deletedAt != null) 'deleted_at': deletedAt!.millisecondsSinceEpoch,
  };

  factory WorldMarkRow.fromDb(Map<String, Object?> row) => WorldMarkRow(
    id: row['id'] as int?,
    name: row['name'] as String?,
    lat: (row['lat'] as num).toDouble(),
    lng: (row['lng'] as num).toDouble(),
    floors: FloorSet.fromStorage(row['floors'] as String?),
    accuracy: (row['accuracy'] as num?)?.toDouble(),
    byGps: (row['by_gps'] as int? ?? 0) == 1,
    processed: (row['processed'] as int? ?? 0) == 1,
    note: row['note'] as String?,
    createdAt: _ts(row['created_at']),
    updatedAt: _ts(row['updated_at']),
    deletedAt: _ts(row['deleted_at']),
  );
}

/// 行驶轨迹采样点表 `way_marks`（D15）—— 一行 = 一个采样点。
///
/// 「一段连续行驶」= 同一个 [trip] 下按 [recordedAt] 排序的点序列。
///
/// ⚠️ 这是**原始采集数据，不是几何**：
/// - 它**不进** `<域>_points`、**不参与吸附**（否则画线时会吸到一堆 GPS 噪声点上）；
/// - 不进业务键、不参与组环、不参与命中排序；
/// - 唯一的出口是「**转成路线**」：抽稀降噪 → 新建点 → `setLineShape`（见 `core/track.dart`）。
class WayMarkRow {
  const WayMarkRow({
    this.id,
    required this.trip,
    required this.recordedAt,
    required this.lat,
    required this.lng,
    this.accuracy,
    this.altitude,
    this.floors,
    this.processed = false,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final int? id;

  /// 分组键：一段连续行驶。边界只由「开始记录 / 停止记录」决定（D17）。
  ///
  /// 现在是该段开始时刻的 ISO8601 串：自解释、可排序、**不需要分配器**。
  final String trip;

  /// 采样时刻（epoch ms）—— 轨迹的灵魂。
  final DateTime recordedAt;

  final double lat;
  final double lng;

  /// 水平精度（米）。0/null = 设备未给。**转换时用它剔坏点**。
  final double? accuracy;

  /// 原始高程（米）。⚠️ **绝对不要用它判断楼层**：城市峡谷里 GPS 高程误差 ±10~20 m，
  /// 远超一层楼高。天桥/高架/地下的分层只能靠 [floors] 人工标。
  final double? altitude;

  final FloorSet? floors;

  /// 这一段转成路线了吗。清理只删已处理的段。
  final bool processed;

  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  GeoPoint get geo => GeoPoint(lat, lng);

  WayMarkRow copyWith({
    int? id,
    String? trip,
    DateTime? recordedAt,
    double? lat,
    double? lng,
    double? accuracy,
    double? altitude,
    FloorSet? floors,
    bool? processed,
  }) => WayMarkRow(
    id: id ?? this.id,
    trip: trip ?? this.trip,
    recordedAt: recordedAt ?? this.recordedAt,
    lat: lat ?? this.lat,
    lng: lng ?? this.lng,
    accuracy: accuracy ?? this.accuracy,
    altitude: altitude ?? this.altitude,
    floors: floors ?? this.floors,
    processed: processed ?? this.processed,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
  );

  Map<String, Object?> toDb() => {
    if (id != null) 'id': id,
    'trip': trip,
    'recorded_at': recordedAt.millisecondsSinceEpoch,
    'lat': lat,
    'lng': lng,
    if (accuracy != null) 'accuracy': accuracy,
    if (altitude != null) 'altitude': altitude,
    'floors': (floors ?? FloorSet.ground).toStorage(),
    'processed': processed ? 1 : 0,
    'created_at': (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
    'updated_at': (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
    if (deletedAt != null) 'deleted_at': deletedAt!.millisecondsSinceEpoch,
  };

  factory WayMarkRow.fromDb(Map<String, Object?> row) => WayMarkRow(
    id: row['id'] as int?,
    trip: row['trip'] as String,
    recordedAt: DateTime.fromMillisecondsSinceEpoch(
      (row['recorded_at'] as num).toInt(),
    ),
    lat: (row['lat'] as num).toDouble(),
    lng: (row['lng'] as num).toDouble(),
    accuracy: (row['accuracy'] as num?)?.toDouble(),
    altitude: (row['altitude'] as num?)?.toDouble(),
    floors: FloorSet.fromStorage(row['floors'] as String?),
    processed: (row['processed'] as int? ?? 0) == 1,
    createdAt: _ts(row['created_at']),
    updatedAt: _ts(row['updated_at']),
    deletedAt: _ts(row['deleted_at']),
  );
}

// ---------------------------------------------------------------------------
// 门的两根属性轴（15 章保留）
// ---------------------------------------------------------------------------

/// 车型限制。
enum VehicleType {
  all('all', '全通行'),
  evBike('ev_bike', '仅电动车'),
  pedestrian('pedestrian', '仅步行'),
  car('car', '汽车');

  const VehicleType(this.storage, this.label);
  final String storage;
  final String label;

  static VehicleType fromStorage(String? v) =>
      values.firstWhere((e) => e.storage == v, orElse: () => VehicleType.all);
}

/// 门禁方式。
enum AccessLevel {
  free('free', '自由进出'),
  guard('guard', '保安询问'),
  swipeCard('swipe_card', '需门禁卡'),
  face('face_recognition', '需人脸');

  const AccessLevel(this.storage, this.label);
  final String storage;
  final String label;

  static AccessLevel fromStorage(String? v) =>
      values.firstWhere((e) => e.storage == v, orElse: () => AccessLevel.free);
}

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

DateTime? _ts(Object? v) =>
    v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);
