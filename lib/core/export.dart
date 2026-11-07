/// 数据导出 —— 备份 **v10**（docs/design/23-data-structure.md §8）
///
/// 把本地数据导出为带 schema 版本的 GeoJSON FeatureCollection（`.mapexport.json`）。
/// 纯 Dart、零依赖，便于脚本验证；DAO 层只负责喂模型、接结果。
///
/// 坐标约定：GeoJSON 标准为 `[lng, lat]`；内部模型为 WGS-84 `(lat, lng)`。
///
/// ## v10 相对 v9 的三处变化
///
/// 1. **每个 feature 多带 `domain` 与 `table`** ——「域」是 v12 的第一分类轴，
///    导入时靠它决定落哪张表。顶层另加 `"domain_layout": "three-domain"`，
///    让人一眼看出这是哪一代格式。
/// 2. **封闭图形有两种构造**：`world_areas`（由**线**围成，几何是 Polygon、
///    properties 带 `line_ids`）与 `world_polygons`（由**点**围成，
///    properties 带 `point_ids`）。两者的 `table` 不同，导入时据此分流。
/// 3. **拐点仍是有序数组 `bend_point_ids`**（不是链）—— 链是**存储**细节，
///    导出时走一遍链把它拍平，导入时按数组顺序重建链。所以存储形态换了，
///    **对外契约没变**，老文件照旧能读。
///
/// ⚠️ **轨迹（`way_marks`）默认不导出**：半小时一趟 1800 个点，塞进来会把备份
/// 从几百 KB 撑到几十 MB（R-23-7）。要带就显式传 `includeTracks`。
library;

import 'dart:convert';

import 'floor_set.dart';
import 'geometry.dart';
import 'models.dart';

/// 导出包版本（用于导入侧校验）。
///
/// - v1：最初版本，只带业务字段；
/// - v2：补 `created_at` / `updated_at` 与顶层 `exported_at` / `counts`；
/// - v3~v9：跟随 schema v4~v11（详见 11~22 章）；
/// - **v10（23 章）**：三层分域 —— 每个 feature 带 `domain` / `table`；
///   点/线/区域按域分组；新增**多边形**（`world_polygons`）与**记录点**
///   （`world_marks`，自带表）；拐点仍是 `bend_point_ids`。
///
/// **导入侧向后兼容**：v1~v9 文件照常可读 —— 那时没有 `domain`，
/// 就按原来的 `kind` / `source` / `area_type` 推出域（映射表见 `import.dart`）。
const int exportSchemaVersion = 10;

/// 单类要素的临时载体。
///
/// 点/线/区域**按键是域**：三个域各一套表，各自的 id 也是独立的，
/// 合成一个大 list 会丢掉"这个点是哪个域的"这个关键信息。
class ExportBundle {
  const ExportBundle({
    required this.points,
    required this.lines,
    required this.areas,
    this.polygons = const [],
    this.gates = const [],
    this.entities = const [],
    this.marks = const [],
    this.tracks = const [],
    this.areaRings = const {},
    this.polygonRings = const {},
  });

  final Map<MapDomain, List<PointRow>> points;
  final Map<MapDomain, List<LineRow>> lines;
  final Map<MapDomain, List<AreaRow>> areas;

  /// 多边形（**由点围成**；只有世界图域有）。
  final List<PolygonRow> polygons;

  final List<GateRow> gates;
  final List<EntityRow> entities;

  /// 记录点（"我在这儿"）。
  final List<WorldMarkRow> marks;

  /// 行驶轨迹采样点（默认空 —— 见文件头）。
  final List<WayMarkRow> tracks;

  /// `(域, areaId) → 已组好的边界环`。取不到环的区域不出现。
  final Map<(MapDomain, int), List<GeoPoint>> areaRings;

  /// `polygonId → 环`（多边形自带环，这里只是省一次查点）。
  final Map<int, List<GeoPoint>> polygonRings;

  List<PointRow> get allPoints => [
    for (final d in MapDomain.values) ...?points[d],
  ];
  List<LineRow> get allLines => [for (final d in MapDomain.values) ...?lines[d]];
  List<AreaRow> get allAreas => [for (final d in MapDomain.values) ...?areas[d]];

  bool get isEmpty =>
      allPoints.isEmpty &&
      allLines.isEmpty &&
      allAreas.isEmpty &&
      polygons.isEmpty &&
      gates.isEmpty &&
      entities.isEmpty &&
      marks.isEmpty &&
      tracks.isEmpty;
}

/// 生成导出 JSON（可直接 jsonEncode 写盘）。失败抛 FormatException。
Map<String, Object?> buildExportJson(ExportBundle bundle, {DateTime? now}) {
  final features = <Map<String, Object?>>[];

  for (final d in MapDomain.values) {
    for (final p in bundle.points[d] ?? const <PointRow>[]) {
      if (p.deletedAt == null) features.add(_pointFeature(d, p));
    }
  }
  for (final d in MapDomain.values) {
    for (final l in bundle.lines[d] ?? const <LineRow>[]) {
      if (l.deletedAt == null) features.add(_lineFeature(d, l, bundle));
    }
  }
  for (final d in MapDomain.values) {
    for (final a in bundle.areas[d] ?? const <AreaRow>[]) {
      if (a.deletedAt == null) {
        features.add(_areaFeature(d, a, bundle.areaRings[(d, a.id)]));
      }
    }
  }
  for (final pg in bundle.polygons) {
    if (pg.deletedAt == null) {
      features.add(_polygonFeature(pg, bundle.polygonRings[pg.id]));
    }
  }
  for (final g in bundle.gates) {
    if (g.deletedAt == null) features.add(_gateFeature(g));
  }
  for (final e in bundle.entities) {
    if (e.deletedAt == null) features.add(_entityFeature(e));
  }
  for (final m in bundle.marks) {
    if (m.deletedAt == null) features.add(_markFeature(m));
  }
  for (final t in bundle.tracks) {
    if (t.deletedAt == null) features.add(_trackFeature(t));
  }

  return {
    'type': 'FeatureCollection',
    'schema': 'map_area_gate',
    'schema_version': exportSchemaVersion,
    // 一眼看出"这是三层分域之后的格式"
    'domain_layout': 'three-domain',
    'crs': {
      'type': 'name',
      'properties': {'name': 'urn:ogc:def:crs:OGC:1.3:CRS84'},
    },
    'exported_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'app': 'map',
    // 按域分组统计：不解析 features 就能看出"哪一层有什么"
    'counts': {
      for (final d in MapDomain.values)
        d.prefix: {
          'points': (bundle.points[d] ?? const []).where((p) => p.deletedAt == null).length,
          'lines': (bundle.lines[d] ?? const []).where((l) => l.deletedAt == null).length,
          'areas': (bundle.areas[d] ?? const []).where((a) => a.deletedAt == null).length,
        },
      'world': {
        'polygons': bundle.polygons.where((p) => p.deletedAt == null).length,
        'gates': bundle.gates.where((g) => g.deletedAt == null).length,
        'entities': bundle.entities.where((e) => e.deletedAt == null).length,
        'marks': bundle.marks.where((m) => m.deletedAt == null).length,
      },
      'way': {
        'tracks': bundle.tracks.where((t) => t.deletedAt == null).length,
      },
    },
    'features': features,
  };
}

/// 导出为 UTF-8 JSON 字符串（落盘用）。
String exportToJsonString(ExportBundle bundle, {DateTime? now}) =>
    const JsonEncoder.withIndent(
      '  ',
    ).convert(buildExportJson(bundle, now: now));

// ---------------------------------------------------------------------------
// feature 构造
// ---------------------------------------------------------------------------

Map<String, Object?> _base(
  String domain,
  String table,
  Map<String, Object?> props, {
  Object? geometry,
}) => {
  'type': 'Feature',
  // `domain` 决定落哪一组表，`table` 决定落哪张表 —— 两个都写，
  // 冗余一次换来"文件自解释"（人肉眼也能看出这是哪一层的什么）
  'properties': {'domain': domain, 'table': table, ...props},
  'geometry': geometry,
};

Map<String, Object?> _tsProps(DateTime? createdAt, DateTime? updatedAt) => {
  if (createdAt != null) 'created_at': createdAt.millisecondsSinceEpoch,
  if (updatedAt != null) 'updated_at': updatedAt.millisecondsSinceEpoch,
};

/// 几何点。**没有 name**（D9）—— 要给位置起名字用世界域的要素。
Map<String, Object?> _pointFeature(MapDomain d, PointRow p) => _base(
  d.prefix,
  d.pointsTable,
  {
    if (p.id != null) 'id': p.id,
    'floors': (p.floors ?? FloorSet.ground).floors,
    ..._tsProps(p.createdAt, p.updatedAt),
  },
  geometry: {'type': 'Point', 'coordinates': [p.lng, p.lat]},
);

/// 线。**几何写全点**（起点 → 拐点… → 终点），这样丢进 QGIS 看到的是真实形状；
/// 而 **properties 才是导入时用的**（靠 id 复用已有点，不靠坐标猜）。
Map<String, Object?> _lineFeature(
  MapDomain d,
  LineRow l,
  ExportBundle b,
) {
  final pts = b.points[d] ?? const <PointRow>[];
  final byId = {for (final p in pts) if (p.id != null) p.id!: p.geo};
  final start = byId[l.startPointId];
  final end = byId[l.endPointId];
  if (start == null || end == null) {
    throw FormatException('线 ${l.id} 的端点缺定义，无法导出');
  }
  // 拐点缺坐标（点被删了/文件被手改过）时**跳过这一个拐点**，而不是让整份备份
  // 导出失败：宁可备份里这条线少一个弯，也不要用户在最需要备份的时候导不出来。
  final bendCoords = <List<double>>[];
  final bendIds = <int>[];
  for (final id in l.bendPointIds) {
    final g = byId[id];
    if (g == null) continue;
    bendIds.add(id);
    bendCoords.add([g.lng, g.lat]);
  }
  return _base(
    d.prefix,
    d.linesTable,
    {
      if (l.id != null) 'id': l.id,
      if (l.name != null) 'name': l.name,
      'floors': (l.floors ?? FloorSet.ground).floors,
      'start_point_id': l.startPointId,
      'end_point_id': l.endPointId,
      // 中间拐点（顺序 = 从起点到终点）。**存储里是链，导出是有序数组。**
      if (bendIds.isNotEmpty) 'bend_point_ids': bendIds,
      // 域特有的属性列：材质只在世界域、路宽/单行/通行代价只在路网域。
      // 导出**照写不误**：备份的职责是"把库里有什么原样带走"，不是替用户清理属性。
      if (l.boundaryType != null) 'boundary_type': l.boundaryType!.storage,
      if (l.routeWidth != null) 'route_width': l.routeWidth!.storage,
      if (l.costClass != null) 'cost_class': l.costClass!.storage,
      if (l.oneWay) 'one_way': true,
      if (l.note != null) 'note': l.note,
      ..._tsProps(l.createdAt, l.updatedAt),
    },
    geometry: {
      'type': 'LineString',
      'coordinates': [
        [start.lng, start.lat],
        ...bendCoords,
        [end.lng, end.lat],
      ],
    },
  );
}

/// 区域（**由线围成**）：几何由成员线组环得来，properties 带 `line_ids`。
Map<String, Object?> _areaFeature(
  MapDomain d,
  AreaRow a,
  List<GeoPoint>? ringOverride,
) => _base(
  d.prefix,
  d.areasTable,
  {
    if (a.id != null) 'id': a.id,
    'name': a.name,
    // 行政域**没有 area_type 列**（整张表就是"行政区域"），所以不写它。
    if (d != MapDomain.zone) 'area_type': a.areaType.storage,
    'floors': (a.floors ?? FloorSet.ground).floors,
    // 成员关系（多对多）。一条线可以出现在多个区域的 line_ids 里 ——
    // 这正是「两个小区共用一堵墙」的表达，备份里那条线只存一份。
    'line_ids': a.lineIds,
    if (a.colorOverride != null) 'color_override': a.colorOverride,
    'sort_order': a.sortOrder,
    ..._tsProps(a.createdAt, a.updatedAt),
  },
  geometry: {
    'type': 'Polygon',
    'coordinates': [
      if (ringOverride != null && ringOverride.length >= 3)
        [
          ...ringOverride.map((p) => [p.lng, p.lat]),
          [ringOverride.first.lng, ringOverride.first.lat], // 环需显式闭合
        ]
      else
        const <List<double>>[],
    ],
  },
);

/// 多边形（**由点围成**）。环是存下来的，所以几何总是画得出来。
Map<String, Object?> _polygonFeature(PolygonRow p, List<GeoPoint>? ring) => _base(
  p.domain.prefix,
  p.table,
  {
    if (p.id != null) 'id': p.id,
    'name': p.name,
    'area_type': p.areaType.storage,
    'floors': (p.floors ?? FloorSet.ground).floors,
    'point_ids': p.pointIds,
    if (p.colorOverride != null) 'color_override': p.colorOverride,
    'sort_order': p.sortOrder,
    ..._tsProps(p.createdAt, p.updatedAt),
  },
  geometry: {
    'type': 'Polygon',
    'coordinates': [
      if (ring != null && ring.length >= 3)
        [
          ...ring.map((g) => [g.lng, g.lat]),
          [ring.first.lng, ring.first.lat],
        ]
      else
        const <List<double>>[],
    ],
  },
);

Map<String, Object?> _gateFeature(GateRow g) => _base(
  MapDomain.world.prefix,
  'world_gates',
  {
    if (g.id != null) 'id': g.id,
    if (g.name != null) 'name': g.name,
    'gate_type': g.gateType.storage,
    if (g.lineId != null) 'line_id': g.lineId,
    'vehicle_type': g.vehicleType.storage,
    'access_level': g.accessLevel.storage,
    if (g.isPermanent) 'is_permanent': true else 'is_permanent': false,
    if (g.note != null) 'note': g.note,
    ..._tsProps(g.createdAt, g.updatedAt),
  },
  geometry: {
    'type': 'Point',
    'coordinates': [g.center.lng, g.center.lat],
  },
);

Map<String, Object?> _entityFeature(EntityRow e) => _base(
  MapDomain.world.prefix,
  'world_entities',
  {
    if (e.id != null) 'id': e.id,
    // 🔴 类型必须写：业务键会带上它，否则同位置同名的店铺与停车点会互相顶掉
    'entity_type': e.entityType.storage,
    'name': e.name,
    if (e.doorNo != null) 'door_no': e.doorNo,
    if (e.desc != null) 'desc': e.desc,
    if (e.lineId != null) 'line_id': e.lineId,
    if (e.width != null) 'width': e.width,
    if (e.note != null) 'note': e.note,
    ..._tsProps(e.createdAt, e.updatedAt),
  },
  // 几何就是中心坐标 —— 导出文件在 GIS 工具里直接能看
  geometry: {
    'type': 'Point',
    'coordinates': [e.lng, e.lat],
  },
);

Map<String, Object?> _markFeature(WorldMarkRow m) => _base(
  MapDomain.world.prefix,
  'world_marks',
  {
    if (m.id != null) 'id': m.id,
    if (m.name != null) 'name': m.name,
    'floors': (m.floors ?? FloorSet.ground).floors,
    if (m.accuracy != null) 'accuracy': m.accuracy,
    'by_gps': m.byGps,
    'processed': m.processed,
    if (m.note != null) 'note': m.note,
    ..._tsProps(m.createdAt, m.updatedAt),
  },
  geometry: {
    'type': 'Point',
    'coordinates': [m.lng, m.lat],
  },
);

/// 轨迹采样点：**一个点一个 feature**（与库里一行一个采样点一致）。
Map<String, Object?> _trackFeature(WayMarkRow t) => _base(
  MapDomain.way.prefix,
  'way_marks',
  {
    if (t.id != null) 'id': t.id,
    'trip': t.trip,
    'recorded_at': t.recordedAt.millisecondsSinceEpoch,
    'floors': (t.floors ?? FloorSet.ground).floors,
    if (t.accuracy != null) 'accuracy': t.accuracy,
    if (t.altitude != null) 'altitude': t.altitude,
    'processed': t.processed,
    ..._tsProps(t.createdAt, t.updatedAt),
  },
  geometry: {
    'type': 'Point',
    'coordinates': [t.lng, t.lat],
  },
);
