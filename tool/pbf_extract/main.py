#!/usr/bin/env python3
"""从 assets/guangdong-latest.osm.pbf 抽取「10 号线走廊」1 份 .osmapp 导入包。

依赖：pyosmium（`pip install osmium`）。纯 Python 桌面预处理工具，非 Flutter 运行期依赖。
两步流式读取全省 PBF（pyosmium C++ 内核读取，Python 仅做裁剪/分类）：
  1) 节点 pass：收集落在「10 号线走廊」并集 bbox（外扩 0.01°）内的节点与 POI；
  2) 路网 pass：仅保留任一节点落在并集内的 way，按 osm_prep 规则分类；
  3) 按 corridor bbox 裁剪输出 corridor.osmapp，
     节点按 osm_id、路/POI 按 osm_id（交给 App 端 importOsmFiles 的 INSERT OR IGNORE）去重合并。

之前：凤岗镇 + 龙岗区两个行政大块共 ~120MB。
现在：只装用户实际活动的「平湖 ⇄ 愉园」走廊，~8-15MB（缩 80%+）。

输出 JSON 严格对齐 lib/core/osmapp.dart 的 OsmAppFile.toJson 结构。
"""
import json
import os
import time

import osmium

SRC = 'assets/guangdong-latest.osm.pbf'
OUT_DIR = 'assets/osm'

# 区域 bbox（度）：10 号线走廊（平湖 ⇄ 愉园，约 144 km²）。
# 之前是凤岗镇 + 龙岗区两个行政大块，但实际活动只压在这条约 14km 的走廊
# 上。龙岗中部（中心城/横岗等）完全用不上，徒增 100MB+ 默认体积。
# 走廊 bbox 用窄长条刚好包住平湖-双拥-大运-愉园这一段。
REGIONS = {
    'corridor': (22.65, 114.10, 22.76, 114.28),
}
# 并集外扩 0.01°，避免路在区域边界被裁断。
UNION = (22.64, 114.09, 22.77, 114.29)

# OSM highway -> cost_class（与 lib/core/osm_prep.dart 一致）。
HIGHWAY_COST = {
    'residential': 'ride', 'living_street': 'ride', 'service': 'ride',
    'unclassified': 'ride', 'cycleway': 'ride', 'tertiary': 'ride',
    'secondary': 'ride', 'primary': 'ride', 'track': 'walk', 'path': 'walk',
    'footway': 'walk', 'steps': 'walk', 'pedestrian': 'walk',
}

# 是否算 POI 的 key。
POI_KEYS = {
    'amenity', 'shop', 'office', 'craft', 'tourism', 'leisure', 'healthcare',
}

# 精简保留的 tag（与 lib/core/osm_prep.dart _compactTags 对齐）。
KEEP_TAGS = {
    'name', 'highway', 'building', 'oneway', 'addr:housenumber', 'addr:street',
    'amenity', 'shop', 'office', 'craft', 'tourism', 'landuse', 'leisure',
    'natural', 'waterway', 'railway', 'boundary',
}


def in_box(lat, lon, box):
    return box[0] <= lat <= box[2] and box[1] <= lon <= box[3]


def tags_to_dict(tags):
    return {t.k: t.v for t in tags}


def compact(tags):
    out = {}
    for k in KEEP_TAGS:
        if k in tags:
            out[k] = tags[k]
    return out or None


def way_kind(tags):
    hw = tags.get('highway')
    if hw:
        c = HIGHWAY_COST.get(hw)
        return ('road', c) if c else None
    if 'building' in tags:
        return ('building', None)
    if 'waterway' in tags or tags.get('natural') == 'water':
        return ('water', None)
    if 'landuse' in tags or 'leisure' in tags or tags.get('natural') == 'wood':
        return ('green', None)
    if 'railway' in tags:
        return ('railway', None)
    if 'boundary' in tags:
        return ('boundary', None)
    return None


def is_poi(tags):
    for k in POI_KEYS:
        if k in tags:
            return True
    return 'addr:housenumber' in tags


class NodePass(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.nodes = {}   # osm_id -> [lat, lon]
        self.pois = []    # [{osm_id, lat, lon, tags}]
        self.count = 0

    def node(self, n):
        self.count += 1
        lat, lon = n.lat, n.lon
        if in_box(lat, lon, UNION):
            self.nodes[n.id] = [lat, lon]
            if is_poi(dict(n.tags)):
                self.pois.append({
                    'osm_id': n.id, 'lat': lat, 'lon': lon,
                    'tags': compact(dict(n.tags)),
                })


class WayPass(osmium.SimpleHandler):
    def __init__(self, nodes):
        super().__init__()
        self.nodes = nodes
        self.ways = []   # [{osm_id, refs, tags, kind, cost, one_way}]
        self.count = 0

    def way(self, w):
        self.count += 1
        refs = [nd.ref for nd in w.nodes]
        # 仅保留任一节点落在并集内的 way（即与目标区域相交）
        hit = False
        for r in refs:
            if r in self.nodes:
                hit = True
                break
        if not hit:
            return
        tags = tags_to_dict(w.tags)
        kc = way_kind(tags)
        if kc is None:
            return
        kind, cost = kc
        self.ways.append({
            'osm_id': w.id, 'refs': refs, 'tags': compact(tags),
            'kind': kind, 'cost': cost,
            'one_way': tags.get('oneway') == 'yes',
        })


def build_region(name, box, nodes, pois, ways):
    rn = {i: (la, lo) for i, (la, lo) in nodes.items() if in_box(la, lo, box)}
    rpois = [p for p in pois if in_box(p['lat'], p['lon'], box)]
    rways = []
    for w in ways:
        rr = [r for r in w['refs'] if r in rn]
        if not rr:
            continue
        rways.append({
            'osm_id': w['osm_id'], 'refs': rr, 'tags': w['tags'],
            'kind': w['kind'], 'cost': w['cost'], 'one_way': w['one_way'],
        })

    lats = [v[0] for v in rn.values()] + [p['lat'] for p in rpois]
    lons = [v[1] for v in rn.values()] + [p['lon'] for p in rpois]
    if lats:
        bounds = {
            'min_lat': min(lats), 'min_lng': min(lons),
            'max_lat': max(lats), 'max_lng': max(lons),
        }
    else:
        bounds = {
            'min_lat': box[0], 'min_lng': box[1],
            'max_lat': box[2], 'max_lng': box[3],
        }

    way_objs = []
    for w in rways:
        o = {'osm_id': w['osm_id'], 'kind': w['kind'], 'node_ids': w['refs']}
        if w['tags'] and w['tags'].get('name'):
            o['name'] = w['tags']['name']
        if w['cost']:
            o['cost_class'] = w['cost']
        if w['one_way']:
            o['one_way'] = True
        if w['tags']:
            o['tags'] = w['tags']
        way_objs.append(o)

    poi_objs = []
    for p in rpois:
        o = {'osm_id': p['osm_id'], 'lat': p['lat'], 'lng': p['lon']}
        if p['tags'] and p['tags'].get('name'):
            o['name'] = p['tags']['name']
        if p['tags']:
            o['tags'] = p['tags']
        poi_objs.append(o)

    return {
        'schema': 'map_osmapp',
        'version': 1,
        'region': name,
        'generated_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'bounds': bounds,
        'nodes': [{'osm_id': i, 'lat': la, 'lng': lo}
                  for i, (la, lo) in rn.items()],
        'ways': way_objs,
        'pois': poi_objs,
    }


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    t0 = time.time()
    print('[1/2] pass1: nodes + pois ...', flush=True)
    p1 = NodePass()
    p1.apply_file(SRC, locations=False)
    print(f'  union nodes={len(p1.nodes)} pois={len(p1.pois)} '
          f'({time.time() - t0:.1f}s)', flush=True)

    t1 = time.time()
    print('[2/2] pass2: ways ...', flush=True)
    p2 = WayPass(p1.nodes)
    p2.apply_file(SRC, locations=False)
    print(f'  kept ways={len(p2.ways)} ({time.time() - t1:.1f}s)', flush=True)

    for name, box in REGIONS.items():
        obj = build_region(name, box, p1.nodes, p1.pois, p2.ways)
        path = os.path.join(OUT_DIR, f'{name}.osmapp')
        with open(path, 'w', encoding='utf-8') as f:
            # 多行缩进版（缩进 2 空格）便于人工 diff / review；
            # 体积代价仅 ~30%（35MB→45MB），仍在 64MB 限制内。
            # 注意：App 端 OsmAppFile.fromJsonString 用 jsonDecode 解析，对空白不敏感。
            json.dump(obj, f, ensure_ascii=False, indent=2)
        size = os.path.getsize(path)
        print(f'  {name}: nodes={len(obj["nodes"])} ways={len(obj["ways"])} '
              f'pois={len(obj["pois"])} -> {path} ({size/1024/1024:.1f} MB)',
              flush=True)
    print('DONE', flush=True)


if __name__ == '__main__':
    main()
