/// .osmapp 开放数据导入包格式（docs/design/07-osm-import.md §2/§3）
///
/// 桌面 osm_prep 工具将 OSM 区域文件裁剪/精简后输出本格式；
/// App 端解析后写入 import_* 表（schema v2）。纯 Dart、零依赖、可单测。
///
/// 格式：UTF-8 JSON 单文件。
/// ```json
/// {
///   "schema": "map_osmapp",
///   "version": 1,
///   "region": "core",
///   "generated_at": "2026-09-10T...",
///   "bounds": { "min_lat":..,"min_lng":..,"max_lat":..,"max_lng":.. },
///   "nodes": [ {"osm_id":1,"lat":..,"lng":..}, ... ],
///   "ways":  [ {"osm_id":..,"kind":"road","name":"..","cost_class":"ride",
///               "one_way":false,"node_ids":[..],"tags":{...}}, ... ],
///   "pois":  [ {"osm_id":..,"kind":"shop","name":"..","lat":..,"lng":..,
///               "tags":{...}}, ... ]
/// }
/// ```
library;

import 'dart:convert';

/// 包 schema 标识与当前版本。
const String kOsmappSchema = 'map_osmapp';
const int kOsmappVersion = 1;

/// 导入层要素大类（对应 import_ways.kind / import_pois.kind）。
enum ImportKind {
  road('road', '道路'),
  building('building', '建筑'),
  water('water', '水系'),
  green('green', '绿地'),
  railway('railway', '铁路'),
  boundary('boundary', '边界'),
  poi('poi', 'POI/门牌');

  const ImportKind(this.storage, this.label);
  final String storage;
  final String label;

  static ImportKind fromStorage(String? v) => values.firstWhere(
        (e) => e.storage == v,
        orElse: () => ImportKind.poi,
      );
}

/// 区域边界。
class OsmBounds {
  const OsmBounds({
    required this.minLat,
    required this.minLng,
    required this.maxLat,
    required this.maxLng,
  });

  final double minLat;
  final double minLng;
  final double maxLat;
  final double maxLng;

  Map<String, Object?> toJson() => {
        'min_lat': minLat,
        'min_lng': minLng,
        'max_lat': maxLat,
        'max_lng': maxLng,
      };

  factory OsmBounds.fromJson(Map<String, Object?> json) => OsmBounds(
        minLat: (json['min_lat'] as num).toDouble(),
        minLng: (json['min_lng'] as num).toDouble(),
        maxLat: (json['max_lat'] as num).toDouble(),
        maxLng: (json['max_lng'] as num).toDouble(),
      );
}

/// 节点（道路交点/要素锚点）。
class OsmNode {
  const OsmNode({
    required this.osmId,
    required this.lat,
    required this.lng,
  });

  final int osmId;
  final double lat;
  final double lng;

  Map<String, Object?> toJson() =>
      {'osm_id': osmId, 'lat': lat, 'lng': lng};

  factory OsmNode.fromJson(Map<String, Object?> json) => OsmNode(
        osmId: (json['osm_id'] as num).toInt(),
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
      );
}

/// 折线/面要素（道路、建筑轮廓、水系等）。
class OsmWay {
  const OsmWay({
    required this.osmId,
    required this.kind,
    this.name,
    this.costClass,
    this.oneWay = false,
    required this.nodeIds,
    this.tags,
  });

  final int osmId;
  final ImportKind kind;
  final String? name;
  final String? costClass; // ride/push/walk（road 用，语义同 CostClass）
  final bool oneWay;
  final List<int> nodeIds;
  final Map<String, Object?>? tags;

  /// 是否为闭合面要素（建筑等）。
  bool get isClosedArea =>
      nodeIds.length >= 4 && nodeIds.first == nodeIds.last;

  Map<String, Object?> toJson() => {
        'osm_id': osmId,
        'kind': kind.storage,
        if (name != null) 'name': name,
        if (costClass != null) 'cost_class': costClass,
        if (oneWay) 'one_way': true,
        'node_ids': nodeIds,
        if (tags != null) 'tags': tags,
      };

  factory OsmWay.fromJson(Map<String, Object?> json) => OsmWay(
        osmId: (json['osm_id'] as num).toInt(),
        kind: ImportKind.fromStorage(json['kind'] as String?),
        name: json['name'] as String?,
        costClass: json['cost_class'] as String?,
        oneWay: json['one_way'] == true,
        nodeIds: (json['node_ids'] as List)
            .map((e) => (e as num).toInt())
            .toList(),
        tags: json['tags'] as Map<String, Object?>?,
      );
}

/// 点状 POI / 门牌。
class OsmPoi {
  const OsmPoi({
    required this.osmId,
    this.name,
    required this.lat,
    required this.lng,
    this.tags,
  });

  final int osmId;
  final String? name;
  final double lat;
  final double lng;
  final Map<String, Object?>? tags;

  Map<String, Object?> toJson() => {
        'osm_id': osmId,
        if (name != null) 'name': name,
        'lat': lat,
        'lng': lng,
        if (tags != null) 'tags': tags,
      };

  factory OsmPoi.fromJson(Map<String, Object?> json) => OsmPoi(
        osmId: (json['osm_id'] as num).toInt(),
        name: json['name'] as String?,
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
        tags: json['tags'] as Map<String, Object?>?,
      );
}

/// 一个 .osmapp 包。
class OsmAppFile {
  const OsmAppFile({
    required this.region,
    required this.generatedAt,
    required this.bounds,
    required this.nodes,
    required this.ways,
    required this.pois,
  });

  final String region;
  final String generatedAt;
  final OsmBounds bounds;
  final List<OsmNode> nodes;
  final List<OsmWay> ways;
  final List<OsmPoi> pois;

  Map<String, Object?> toJson() => {
        'schema': kOsmappSchema,
        'version': kOsmappVersion,
        'region': region,
        'generated_at': generatedAt,
        'bounds': bounds.toJson(),
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'ways': ways.map((w) => w.toJson()).toList(),
        'pois': pois.map((p) => p.toJson()).toList(),
      };

  String encodeJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  static OsmAppFile fromJsonString(String source) {
    final json = jsonDecode(source);
    if (json is! Map<String, Object?>) {
      throw const FormatException('.osmapp 必须是 JSON 对象');
    }
    return fromJson(json);
  }

  static OsmAppFile fromJson(Map<String, Object?> json) {
    if (json['schema'] != kOsmappSchema) {
      throw FormatException('未知 schema: ${json['schema']}');
    }
    final v = json['version'];
    if (v is int && v > kOsmappVersion) {
      throw FormatException('.osmapp 版本 $v 高于支持的 $kOsmappVersion');
    }
    Object? listOf(String key) => json[key];

    return OsmAppFile(
      region: json['region'] as String? ?? 'unknown',
      generatedAt: json['generated_at'] as String? ?? '',
      bounds: OsmBounds.fromJson(
        ((json['bounds'] as Map?) ?? const {}).cast<String, Object?>(),
      ),
      nodes: _mapList(listOf('nodes'), OsmNode.fromJson),
      ways: _mapList(listOf('ways'), OsmWay.fromJson),
      pois: _mapList(listOf('pois'), OsmPoi.fromJson),
    );
  }

  static List<T> _mapList<T>(
    Object? raw,
    T Function(Map<String, Object?>) convert,
  ) {
    if (raw == null) return const [];
    if (raw is! List) throw const FormatException('要素列表必须是数组');
    return raw
        .map((e) => convert((e as Map).cast<String, Object?>()))
        .toList();
  }

  /// 摘要文本（导入预览用）。
  String get summary =>
      '区域 $region · 节点 ${nodes.length} · 折线 ${ways.length} · POI ${pois.length}';
}
