/// OSM XML 子集解析与转换（桌面 osm_prep 核心；M2a）
///
/// 只解析 .osmapp 需要的要素：
/// `osm > bounds / node(id,lat,lon, tag) / way(id, nd(ref), tag)`
/// 忽略 relation 等无关元素。容忍属性顺序。纯 Dart、可单测。
library;

import 'dart:convert';

import 'osmapp.dart';

/// OSM highway → cost_class 映射（05 章 §4.2 骑手语义）。
const Map<String, String> _highwayCost = {
  'residential': 'ride',
  'living_street': 'ride',
  'service': 'ride',
  'unclassified': 'ride',
  'cycleway': 'ride',
  'tertiary': 'ride',
  'secondary': 'ride',
  'primary': 'ride',
  'track': 'walk',
  'path': 'walk',
  'footway': 'walk',
  'steps': 'walk',
  'pedestrian': 'walk',
};

/// 是否算 POI 的 key 前缀（保留为常送点候选）。
const Set<String> _poiKeys = {
  'amenity',
  'shop',
  'office',
  'craft',
  'tourism',
  'leisure',
  'healthcare',
};

/// 原始 OSM 数据解析结果。
class RawOsm {
  RawOsm({
    required this.bounds,
    required this.nodes,
    required this.rawTags,
  });

  final ({double minLat, double minLng, double maxLat, double maxLng})? bounds;
  final Map<int, ({double lat, double lng})> nodes;
  /// osm id → (tags, nodeRefs)
  final Map<int, ({Map<String, String> tags, List<int> nodeRefs})> rawTags;
}

/// 极简 XML 元素。
class _XmlElement {
  _XmlElement(this.name, this.attrs);
  final String name;
  final Map<String, String> attrs;
  final List<_XmlElement> children = [];
  final List<String> textParts = [];
}

/// 解析 OSM XML（足够健壮：自动处理引号、自闭合、注释）。
RawOsm parseOsmXml(String source) {
  final root = _parseXml(source);

  double? minLat, minLng, maxLat, maxLng;
  final nodes = <int, ({double lat, double lng})>{};
  final elements = <int, ({Map<String, String> tags, List<int> nodeRefs})>{};

  void handleElement(_XmlElement el) {
    switch (el.name) {
      case 'bounds':
        minLat = double.tryParse(el.attrs['minlat'] ?? '');
        minLng = double.tryParse(el.attrs['minlon'] ?? '');
        maxLat = double.tryParse(el.attrs['maxlat'] ?? '');
        maxLng = double.tryParse(el.attrs['maxlon'] ?? '');
      case 'node':
        final id = int.tryParse(el.attrs['id'] ?? '');
        final lat = double.tryParse(el.attrs['lat'] ?? '');
        final lon = double.tryParse(el.attrs['lon'] ?? '');
        if (id != null && lat != null && lon != null) {
          final tags = <String, String>{};
          for (final c in el.children) {
            if (c.name == 'tag') {
              final k = c.attrs['k'];
              final v = c.attrs['v'];
              if (k != null && v != null) tags[k] = v;
            }
          }
          if (tags.isNotEmpty) {
            elements[id] = (tags: tags, nodeRefs: const []);
          }
          nodes[id] = (lat: lat, lng: lon);
        }
      case 'way':
        final id = int.tryParse(el.attrs['id'] ?? '');
        if (id != null) {
          final refs = <int>[];
          final tags = <String, String>{};
          for (final c in el.children) {
            if (c.name == 'nd') {
              final r = int.tryParse(c.attrs['ref'] ?? '');
              if (r != null) refs.add(r);
            } else if (c.name == 'tag') {
              final k = c.attrs['k'];
              final v = c.attrs['v'];
              if (k != null && v != null) tags[k] = v;
            }
          }
          elements[id] = (tags: tags, nodeRefs: refs);
        }
    }
    for (final c in el.children) {
      handleElement(c);
    }
  }

  handleElement(root);
  if (minLat == null) {
    return RawOsm(bounds: null, nodes: nodes, rawTags: elements);
  }
  final bMinLat = minLat!;
  final bMinLng = minLng!;
  final bMaxLat = maxLat!;
  final bMaxLng = maxLng!;
  return RawOsm(
    bounds: (
      minLat: bMinLat,
      minLng: bMinLng,
      maxLat: bMaxLat,
      maxLng: bMaxLng,
    ),
    nodes: nodes,
    rawTags: elements,
  );
}

// ---------------------------------------------------------------------------
// 转换：RawOsm → OsmAppFile
// ---------------------------------------------------------------------------

/// 将解析出的 OSM 数据转换为 .osmapp 包。
///
/// [include] 决定保留的要素大类：road/building/water/green/railway/boundary/poi。
OsmAppFile convertRawOsm(
  RawOsm raw, {
  required String region,
  Set<String> include = const {
    'road',
    'building',
    'water',
    'green',
    'railway',
    'poi',
  },
}) {
  // way 面/线映射
  ImportKind? wayKindOf(Map<String, String> tags, List<int> refs) {
    final highway = tags['highway'];
    if (highway != null) {
      // 仅在“可通行映射表”内的道路才保留（motorway/trunk 等骑行不可达丢弃）
      final cost = _highwayCost[highway];
      if (cost == null) return null;
      return include.contains('road') ? ImportKind.road : null;
    }
    final building = tags['building'];
    if (building != null && refs.length >= 2) {
      return include.contains('building') ? ImportKind.building : null;
    }
    if (tags['waterway'] != null || tags['natural'] == 'water') {
      return include.contains('water') ? ImportKind.water : null;
    }
    if (tags.containsKey('landuse') ||
        tags.containsKey('leisure') ||
        tags['natural'] == 'wood') {
      return include.contains('green') ? ImportKind.green : null;
    }
    if (tags['railway'] != null) {
      return include.contains('railway') ? ImportKind.railway : null;
    }
    if (tags['boundary'] != null) {
      return include.contains('boundary') ? ImportKind.boundary : null;
    }
    return null;
  }

  bool isPoi(Map<String, String> tags) {
    for (final k in _poiKeys) {
      if (tags.containsKey(k)) return true;
    }
    return tags.containsKey('addr:housenumber');
  }

  final ways = <OsmWay>[];
  final pois = <OsmPoi>[];

  raw.rawTags.forEach((osmId, el) {
    final tags = el.tags;
    if (el.nodeRefs.isNotEmpty) {
      // 是 way
      final kind = wayKindOf(tags, el.nodeRefs);
      if (kind == null) return;
      final highway = tags['highway'];
      ways.add(OsmWay(
        osmId: osmId,
        kind: kind,
        name: tags['name'],
        costClass: kind == ImportKind.road ? _highwayCost[highway] : null,
        oneWay: tags['oneway'] == 'yes',
        nodeIds: el.nodeRefs,
        tags: _compactTags(tags),
      ));
    } else {
      // 是点状 tagged node → POI
      if (!isPoi(tags)) return;
      final node = raw.nodes[osmId];
      if (node == null) return;
      pois.add(OsmPoi(
        osmId: osmId,
        name: tags['name'],
        lat: node.lat,
        lng: node.lng,
        tags: _compactTags(tags),
      ));
    }
  });

  final b = raw.bounds;
  return OsmAppFile(
    region: region,
    generatedAt: DateTime.now().toUtc().toIso8601String(),
    bounds: OsmBounds(
      minLat: b?.minLat ?? 0,
      minLng: b?.minLng ?? 0,
      maxLat: b?.maxLat ?? 0,
      maxLng: b?.maxLng ?? 0,
    ),
    nodes: raw.nodes.entries
        .map((e) => OsmNode(
              osmId: e.key,
              lat: e.value.lat,
              lng: e.value.lng,
            ))
        .toList()
      ..sort((a, b) => a.osmId.compareTo(b.osmId)),
    ways: ways..sort((a, b) => a.osmId.compareTo(b.osmId)),
    pois: pois..sort((a, b) => a.osmId.compareTo(b.osmId)),
  );
}

/// 精简 tags：去掉大字段，保留少量导航/编辑相关字段。
Map<String, Object?>? _compactTags(Map<String, String> tags) {
  const keep = {
    'name',
    'highway',
    'building',
    'oneway',
    'addr:housenumber',
    'addr:street',
    'amenity',
    'shop',
    'office',
    'craft',
    'tourism',
  };
  final out = <String, Object?>{};
  for (final k in keep) {
    final v = tags[k];
    if (v != null) out[k] = v;
  }
  if (out.isEmpty) return null;
  return out;
}

// ---------------------------------------------------------------------------
// 极简 XML 解析器
// ---------------------------------------------------------------------------

_XmlElement _parseXml(String source) {
  final parser = _XmlParser(source);
  final el = parser.parseDocument();
  if (el == null || el.name != 'osm') {
    throw const FormatException('不是 OSM XML（缺少 <osm> 根）');
  }
  return el;
}

class _XmlParser {
  _XmlParser(this._src);
  final String _src;
  int _pos = 0;

  _XmlElement? parseDocument() {
    _skipMisc();
    final el = _parseElement();
    if (el == null) throw const FormatException('XML 为空');
    return el;
  }

  _XmlElement? _parseElement() {
    if (_pos >= _src.length || _src[_pos] != '<') return null;
    if (_src.startsWith('</', _pos)) return null; // 结束标签由父处理
    _pos++; // <
    final name = _readName();
    if (name.isEmpty) throw const FormatException('非法标签名');
    final el = _XmlElement(name, {});
    _skipWs();
    // 属性
    while (_pos < _src.length && _src[_pos] != '>' && !_src.startsWith('/>', _pos)) {
      final key = _readName();
      _skipWs();
      if (_pos < _src.length && _src[_pos] == '=') {
        _pos++;
        _skipWs();
        final quote = _src[_pos];
        if (quote != '"' && quote != "'") {
          throw const FormatException('非法属性值');
        }
        _pos++;
        final end = _src.indexOf(quote, _pos);
        if (end < 0) throw const FormatException('属性值未闭合');
        el.attrs[key] = _src.substring(_pos, end);
        _pos = end + 1;
      } else {
        el.attrs[key] = '';
      }
      _skipWs();
    }
    if (_pos >= _src.length) throw const FormatException('标签未闭合');
    if (_src.startsWith('/>', _pos)) {
      _pos += 2;
      return el; // 自闭合
    }
    if (_src[_pos] == '>') _pos++;
    // 子节点 / 文本
    while (_pos < _src.length) {
      if (_src.startsWith('</', _pos)) {
        _pos += 2;
        final closeName = _readName();
        _skipUntil('>');
        if (_src[_pos] == '>') _pos++;
        if (closeName != name) {
          throw FormatException('标签不匹配: <$name> vs </$closeName>');
        }
        return el;
      }
      if (_src[_pos] == '<') {
        final child = _parseElement();
        if (child != null) el.children.add(child);
      } else {
        final next = _src.indexOf('<', _pos);
        final chunk =
            (next < 0 ? _src.substring(_pos) : _src.substring(_pos, next))
                .trim();
        if (chunk.isNotEmpty) el.textParts.add(chunk);
        _pos = next < 0 ? _src.length : next;
      }
    }
    throw FormatException('标签未闭合: $name');
  }

  String _readName() {
    _skipWs();
    final start = _pos;
    while (_pos < _src.length) {
      final c = _src[_pos];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r' ||
          c == '=' || c == '>' || c == '/') {
        break;
      }
      _pos++;
    }
    return _src.substring(start, _pos);
  }

  void _skipUntil(String target) {
    final i = _src.indexOf(target, _pos);
    _pos = i < 0 ? _src.length : i + target.length;
  }

  void _skipWs() {
    while (_pos < _src.length) {
      final c = _src[_pos];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        _pos++;
      } else {
        break;
      }
    }
  }

  void _skipMisc() {
    while (_pos < _src.length) {
      if (_src[_pos] != '<') {
        _pos++;
        continue;
      }
      if (_src.startsWith('<?', _pos) || _src.startsWith('<!', _pos)) {
        _skipUntil('>');
      } else {
        break;
      }
    }
  }
}

/// JSON 便捷（供工具 debug）。
String encodeJson(Object? o) => _jsonEncode(o);

final JsonEncoder _jsonEncoder = const JsonEncoder.withIndent('  ');
String _jsonEncode(Object? o) => _jsonEncoder.convert(o);
