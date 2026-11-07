/// 备份导入（docs/design/11-backup-export-import.md + 23 章 §8.2）
///
/// 把 `.mapexport.json` 解析成 [ExportBundle]（与导出侧同一个类型），
/// **不落库** —— 落库是 `merge.dart` 的事。
///
/// ## 向后兼容：v1~v9 的老文件照样能读
///
/// 老文件里**没有 `domain`**，所以域要靠原来那套字段推出来：
///
/// | 老文件里的东西 | 落到哪个域 / 哪张表 |
/// |---------------|-------------------|
/// | `lines.kind = 'route'` | 路网 `way_lines` |
/// | `lines.kind = 'boundary'` / `'area_boundary'` | 世界图 `world_lines` |
/// | `lines.kind = 'administrative'` | 行政 `zone_lines` |
/// | `points`（被某条线当点用） | 跟那条线同域 |
/// | `points.source = 'recorded'/'gps'` | 世界图 `world_marks`（记录点） |
/// | `points.kind = 'waypoint'` 且无人引用 | 路网 `way_points` |
/// | 其余孤立点 | 世界图 `world_points` |
/// | `gates` | `world_gates` |
/// | `entities('shop')` / `('door')` | `world_entities`（`door` → `shop`） |
/// | `entities('wall')` | **丢弃**（D5：墙体段已删） |
/// | `areas.area_type = 'administrative'` | `zone_areas` |
/// | 其余 `areas` | `world_areas` |
///
/// 「孤立点按 kind 落域」这条不是拍脑袋：它**正好就是** 19 章
/// `MapLayer.defaultPointKind` 已有的映射（路网落点 = 路点、世界图落点 = 辅助点）。
///
/// 纯 Dart、零依赖。
library;

import 'dart:convert';

import 'floor_set.dart';
import 'geometry.dart';
import 'models.dart';
import 'export.dart';

/// 解析结果：[bundle] 是可直接喂给 [planMerge] 的数据，
/// [warnings] 记录"老文件被翻译时丢掉了什么"（比如 `wall` 被丢弃），
/// 好让导入预览能把代价说清楚。
class ImportReport {
  const ImportReport({
    required this.bundle,
    required this.sourceVersion,
    this.warnings = const [],
  });

  final ExportBundle bundle;
  final int sourceVersion;
  final List<String> warnings;

  bool get isEmpty => bundle.isEmpty;
}

/// 校验顶层结构；不通过抛 [FormatException]。
void assertImportable(Map<String, Object?> json) {
  if (json['type'] != 'FeatureCollection') {
    throw const FormatException('不是有效的 FeatureCollection');
  }
  final schema = json['schema'];
  if (schema != 'map_area_gate') {
    throw FormatException('未知 schema: $schema');
  }
  final v = json['schema_version'];
  if (v is! int) throw const FormatException('缺少 schema_version');
  if (v > exportSchemaVersion) {
    throw FormatException('备份版本 $v 高于当前支持的 $exportSchemaVersion，请先升级应用');
  }
}

ImportReport importFromJson(Map<String, Object?> json) {
  assertImportable(json);
  final feats = json['features'];
  if (feats is! List) throw const FormatException('缺少 features 数组');

  final points = <MapDomain, List<PointRow>>{};
  final lines = <MapDomain, List<LineRow>>{};
  final areas = <MapDomain, List<AreaRow>>{};
  final polygons = <PolygonRow>[];
  final gates = <GateRow>[];
  final entities = <EntityRow>[];
  final marks = <WorldMarkRow>[];
  final tracks = <WayMarkRow>[];
  final warnings = <String>[];
  final rings = <(MapDomain, int), List<GeoPoint>>{};
  final polygonRings = <int, List<GeoPoint>>{};

  // 老文件（v9 及更早）没有 domain：先把原始 feature 收下来，
  // 等线都解析完、知道"哪些点被哪些域用了"，再决定每个点落哪。
  final rawPoints = <Map<String, Object?>>[];
  final pointDomainUse = <int, Set<MapDomain>>{};

  void addPoint(MapDomain d, PointRow p) =>
      points.putIfAbsent(d, () => []).add(p);
  void addLine(MapDomain d, LineRow l) =>
      lines.putIfAbsent(d, () => []).add(l);
  void addArea(MapDomain d, AreaRow a) =>
      areas.putIfAbsent(d, () => []).add(a);

  for (final f in feats) {
    if (f is! Map) continue;
    final props = (f['properties'] as Map?)?.cast<String, Object?>();
    if (props == null) continue;
    final table = props['table'] as String?;
    if (table == null) continue; // 没有 table 标记的 feature 一律跳过
    final geom = f['geometry'] as Map?;

    switch (table) {
      // ---- v10：新表名（带域）----
      case 'way_points' || 'world_points' || 'zone_points':
        addPoint(_domainOfTable(table), _point(props, f, _domainOfTable(table)));

      case 'way_lines' || 'world_lines' || 'zone_lines':
        {
          final d = _domainOfTable(table);
          final l = _line(props, d);
          addLine(d, l);
          _notePointUse(pointDomainUse, l, d);
        }

      case 'way_areas' || 'world_areas' || 'zone_areas':
        {
          final d = _domainOfTable(table);
          addArea(d, _area(props, d));
          final id = (props['id'] as num?)?.toInt();
          final ring = _ringOf(geom);
          if (id != null && ring != null) rings[(d, id)] = ring;
        }

      case 'way_polygons' || 'world_polygons':
        {
          final p = _polygon(props);
          polygons.add(p);
          final ring = _ringOf(geom);
          if (p.id != null && ring != null) polygonRings[p.id!] = ring;
        }

      case 'way_marks' || 'world_marks':
        if (table == 'way_marks') {
          tracks.add(_track(props, f));
        } else {
          marks.add(_mark(props, f));
        }

      case 'world_gates' || 'gates':
        gates.add(_gate(props, f));

      case 'world_entities' || 'entities':
        {
          final e = _entity(props, f);
          if (e != null) {
            entities.add(e);
          } else {
            warnings.add('丢弃了一个"墙体段"要素（v12 起没有这个概念）');
          }
        }

      // ---- v9 及更早：老表名，域要从 kind / area_type 推 ----
      case 'lines':
        {
          final d = _legacyLineDomain(props['kind'] as String?);
          final l = _line(props, d);
          addLine(d, l);
          _notePointUse(pointDomainUse, l, d);
        }
      case 'areas':
        {
          final d = (props['area_type'] as String?) == 'administrative'
              ? MapDomain.zone
              : MapDomain.world;
          addArea(d, _area(props, d));
          final id = (props['id'] as num?)?.toInt();
          final ring = _ringOf(geom);
          if (id != null && ring != null) rings[(d, id)] = ring;
        }
      case 'points':
        rawPoints.add(props);

      default:
        warnings.add('跳过了不认识的一张表：$table');
    }
  }

  // ---- 老文件：把"没有域的原始点"分派下去 ----
  if (rawPoints.isNotEmpty) {
    for (final props in rawPoints) {
      final id = (props['id'] as num?)?.toInt();
      final src = props['source'] as String?;
      final kind = props['kind'] as String?;
      // 1) 记录点：自己一张表（真库 0 行，但老备份里可能有）
      if (src == 'recorded' || src == 'gps') {
        marks.add(_mark(props, props));
        continue;
      }
      // 2) 被线当点用 → 跟那条线同域（一个点被两个域用就各存一份）
      final used = id == null ? const <MapDomain>{} : (pointDomainUse[id] ?? const <MapDomain>{});
      if (used.isNotEmpty) {
        for (final d in used) {
          addPoint(d, _point(props, props, d));
        }
        continue;
      }
      // 3) 孤立点：按原来的 kind 落域（= 19 章 defaultPointKind 那套映射）
      addPoint(
        kind == 'waypoint' ? MapDomain.way : MapDomain.world,
        _point(props, props, kind == 'waypoint' ? MapDomain.way : MapDomain.world),
      );
    }
  }

  for (final d in MapDomain.values) {
    points.putIfAbsent(d, () => []);
    lines.putIfAbsent(d, () => []);
  }

  return ImportReport(
    bundle: ExportBundle(
      points: points,
      lines: lines,
      areas: areas,
      polygons: polygons,
      gates: gates,
      entities: entities,
      marks: marks,
      tracks: tracks,
      areaRings: rings,
      polygonRings: polygonRings,
    ),
    sourceVersion: json['schema_version'] as int,
    warnings: warnings,
  );
}

/// 从文本解析（UI 与脚本的入口）。
ImportReport importFromJsonString(String source) =>
    importFromJson((jsonDecode(source) as Map).cast<String, Object?>());

// ---------------------------------------------------------------------------
// 内部：field 解析
// ---------------------------------------------------------------------------

MapDomain _domainOfTable(String table) {
  final prefix = table.contains('_') ? table.substring(0, table.indexOf('_')) : table;
  return MapDomain.fromPrefix(prefix);
}

MapDomain _legacyLineDomain(String? kind) => switch (kind) {
  'route' || 'route_edge' => MapDomain.way,
  'administrative' => MapDomain.zone,
  _ => MapDomain.world, // 'boundary' / 'area_boundary' / null
};

void _notePointUse(
  Map<int, Set<MapDomain>> use,
  LineRow l,
  MapDomain d,
) {
  for (final pid in l.pointIds) {
    use.putIfAbsent(pid, () => <MapDomain>{}).add(d);
  }
}

double _lat(Map<String, Object?> p, Map f) =>
    ((p['lat'] ?? _coord(f, 1)) as num).toDouble();
double _lng(Map<String, Object?> p, Map f) =>
    ((p['lng'] ?? _coord(f, 0)) as num).toDouble();

double? _coord(Map f, int i) {
  final g = f['geometry'];
  if (g is! Map) return null;
  if (g['type'] != 'Point') return null;
  final c = g['coordinates'];
  if (c is! List || c.length < 2) return null;
  return (c[i] as num?)?.toDouble();
}

PointRow _point(
  Map<String, Object?> p,
  Map f,
  MapDomain d,
) => PointRow(
  id: (p['id'] as num?)?.toInt(),
  domain: d,
  lat: _lat(p, f),
  lng: _lng(p, f),
  floors: FloorSet.fromStorage(_floorsJson(p['floors'])),
  createdAt: _ts(p['created_at']),
  updatedAt: _ts(p['updated_at']),
);

LineRow _line(Map<String, Object?> p, MapDomain d) => LineRow(
  id: (p['id'] as num?)?.toInt(),
  domain: d,
  startPointId: (p['start_point_id'] as num?)?.toInt() ?? -1,
  endPointId: (p['end_point_id'] as num?)?.toInt() ?? -1,
  bendPointIds: [
    for (final v in (p['bend_point_ids'] as List?) ?? const [])
      (v as num).toInt(),
  ],
  name: p['name'] as String?,
  floors: FloorSet.fromStorage(_floorsJson(p['floors'])),
  boundaryType: BoundaryType.fromStorageOrNull(p['boundary_type'] as String?),
  routeWidth: RouteWidth.fromStorageOrNull(p['route_width'] as String?),
  costClass: p['cost_class'] == null
      ? null
      : CostClass.fromStorage(p['cost_class'] as String?),
  oneWay: p['one_way'] == true,
  note: p['note'] as String?,
  createdAt: _ts(p['created_at']),
  updatedAt: _ts(p['updated_at']),
);

AreaRow _area(Map<String, Object?> p, MapDomain d) => AreaRow(
  id: (p['id'] as num?)?.toInt(),
  domain: d,
  name: (p['name'] as String?) ?? '（未命名区域）',
  areaType: AreaType.fromStorage(p['area_type'] as String?),
  floors: FloorSet.fromStorage(_floorsJson(p['floors'])),
  colorOverride: (p['color_override'] as num?)?.toInt(),
  sortOrder: (p['sort_order'] as num?)?.toInt() ?? 0,
  lineIds: [
    for (final v in (p['line_ids'] as List?) ?? const []) (v as num).toInt(),
  ],
  createdAt: _ts(p['created_at']),
  updatedAt: _ts(p['updated_at']),
);

PolygonRow _polygon(Map<String, Object?> p) => PolygonRow(
  id: (p['id'] as num?)?.toInt(),
  name: (p['name'] as String?) ?? '（未命名多边形）',
  areaType: AreaType.fromStorage(p['area_type'] as String?),
  floors: FloorSet.fromStorage(_floorsJson(p['floors'])),
  colorOverride: (p['color_override'] as num?)?.toInt(),
  sortOrder: (p['sort_order'] as num?)?.toInt() ?? 0,
  pointIds: [
    for (final v in (p['point_ids'] as List?) ?? const []) (v as num).toInt(),
  ],
  createdAt: _ts(p['created_at']),
  updatedAt: _ts(p['updated_at']),
);

GateRow _gate(Map<String, Object?> p, Map f) => GateRow(
  id: (p['id'] as num?)?.toInt(),
  name: p['name'] as String?,
  gateType: GateType.fromStorage(p['gate_type'] as String?),
  lineId: (p['line_id'] as num?)?.toInt(),
  center: GeoPoint(_lat(p, f), _lng(p, f)),
  vehicleType: VehicleType.fromStorage(p['vehicle_type'] as String?),
  accessLevel: AccessLevel.fromStorage(p['access_level'] as String?),
  isPermanent: p['is_permanent'] != false,
  note: p['note'] as String?,
  createdAt: _ts(p['created_at']),
  updatedAt: _ts(p['updated_at']),
);

/// `wall` / `gate_landmark` 返回 null（这两种老类型已不在新世界模型里）。
EntityRow? _entity(Map<String, Object?> p, Map f) {
  final raw = p['entity_type'] as String?;
  if (raw == 'wall' || raw == 'gate_landmark') return null;
  return EntityRow(
    id: (p['id'] as num?)?.toInt(),
    entityType: EntityType.fromStorage(raw),
    name: (p['name'] as String?) ?? '',
    doorNo: p['door_no'] as String?,
    desc: p['desc'] as String?,
    lineId: (p['line_id'] as num?)?.toInt(),
    lat: _lat(p, f),
    lng: _lng(p, f),
    width: (p['width'] as num?)?.toDouble(),
    note: p['note'] as String?,
    createdAt: _ts(p['created_at']),
    updatedAt: _ts(p['updated_at']),
  );
}

WorldMarkRow _mark(Map<String, Object?> p, Map f) => WorldMarkRow(
  id: (p['id'] as num?)?.toInt(),
  name: p['name'] as String?,
  lat: _lat(p, f),
  lng: _lng(p, f),
  floors: FloorSet.fromStorage(_floorsJson(p['floors'])),
  accuracy: (p['accuracy'] as num?)?.toDouble(),
  byGps: p['by_gps'] == true || p['source'] == 'gps',
  processed: p['processed'] == true,
  note: p['note'] as String?,
  createdAt: _ts(p['created_at']),
  updatedAt: _ts(p['updated_at']),
);

WayMarkRow _track(Map<String, Object?> p, Map f) => WayMarkRow(
  id: (p['id'] as num?)?.toInt(),
  trip: (p['trip'] as String?) ?? 'unknown',
  recordedAt: DateTime.fromMillisecondsSinceEpoch(
    (p['recorded_at'] as num?)?.toInt() ?? 0,
  ),
  lat: _lat(p, f),
  lng: _lng(p, f),
  accuracy: (p['accuracy'] as num?)?.toDouble(),
  altitude: (p['altitude'] as num?)?.toDouble(),
  floors: FloorSet.fromStorage(_floorsJson(p['floors'])),
  processed: p['processed'] == true,
  createdAt: _ts(p['created_at']),
  updatedAt: _ts(p['updated_at']),
);

List<GeoPoint>? _ringOf(Map? geom) {
  if (geom == null || geom['type'] != 'Polygon') return null;
  final coords = geom['coordinates'];
  if (coords is! List || coords.isEmpty) return null;
  final ring = coords.first;
  if (ring is! List || ring.length < 3) return null;
  final out = <GeoPoint>[
    for (final c in ring)
      if (c is List && c.length >= 2)
        GeoPoint((c[1] as num).toDouble(), (c[0] as num).toDouble()),
  ];
  // GeoJSON 环首尾重复，去掉最后那个与首点相同的点
  if (out.length > 1 && out.first.lat == out.last.lat && out.first.lng == out.last.lng) {
    out.removeLast();
  }
  return out.length >= 3 ? out : null;
}

/// 导出侧 `floors` 写的是**裸数组**（`[1,2]`），而 `FloorSet.fromStorage`
/// 认的是 JSON 字符串 —— 这里统一成字符串再交给它。
String? _floorsJson(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is List) return jsonEncode(v);
  return null;
}

DateTime? _ts(Object? v) =>
    v == null ? null : DateTime.fromMillisecondsSinceEpoch((v as num).toInt());
