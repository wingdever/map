#!/usr/bin/env python3
"""广东全省矢量底图 → 0.1° 经纬网格 SQLite 包（basemap pack）。

设计文档：docs/design/10-basemap-packs.md（§4.2 包格式 / §4.2.1 几何完整性）

三个必须守住的正确性要点：
  1. 格号计算的浮点误差（§6.1.1）：`(114.10-109.0)//0.1 == 50` 是错的，必须 round 后再除。
  2. 包内 way 必须携带**完整几何**：包内含该包所有 way 引用到的全部节点坐标，
     否则跨包边界的路会在 App 侧被"拉直"（badRefWays > 0）。
     → 做法：pass1 收集**全部**节点到落盘中间库（内存 O(1)），pass2 用
       osmium locations=True 直接取坐标，绝不靠 bbox padding 猜。
  3. is_area 规则与 lib/core/osmapp.dart 的 OsmWay.isClosedArea 一致：
     refs.length >= 4 && refs.first == refs.last。

用法：
  python3 tool/basemap_pack/build_packs.py --bundled-only
      → corridor 覆盖的 4 格 → assets/basemap/（内置进 APK）

  python3 tool/basemap_pack/build_packs.py --all --bundled-dir assets/basemap
      → 全省所有非空格 → basemap_out/，并把 4 个内置格另存一份到 assets/basemap/

  python3 tool/basemap_pack/build_packs.py --tiles t22.60_114.10 --out /tmp/probe
      → 只产出指定格（调试）

中间库在 <out>/_work/（约 1GB），--reuse-work 可复用以避免重扫 PBF。
每个包产出后**立即自检 badRefWays**，非 0 则整体失败退出。
"""
from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import sqlite3
import sys
import time

import osmium

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

SRC = 'assets/guangdong-latest.osm.pbf'

STEP = 0.1
LAT_BASE = 20.0
LNG_BASE = 109.0

# 包格式版本；写进 pack 的 PRAGMA user_version。
# **仅在 import_* DDL 变更时递增**；App 侧 kPackSchemaVersion 必须一致。
PACK_SCHEMA_VERSION = 1

# corridor bbox（内置集覆盖范围），与 import_layer_providers.dart 的 kCorridorCenter* 对应。
CORRIDOR_BBOX = (22.65, 114.10, 22.76, 114.28)

HIGHWAY_COST = {
    'residential': 'ride', 'living_street': 'ride', 'service': 'ride',
    'unclassified': 'ride', 'cycleway': 'ride', 'tertiary': 'ride',
    'secondary': 'ride', 'primary': 'ride', 'track': 'walk', 'path': 'walk',
    'footway': 'walk', 'steps': 'walk', 'pedestrian': 'walk',
}
POI_KEYS = {
    'amenity', 'shop', 'office', 'craft', 'tourism', 'leisure', 'healthcare',
}
KEEP_TAGS = {
    'name', 'highway', 'building', 'oneway', 'addr:housenumber', 'addr:street',
    'amenity', 'shop', 'office', 'craft', 'tourism', 'landuse', 'leisure',
    'natural', 'waterway', 'railway', 'boundary',
}

# 包内 DDL —— 必须与 lib/core/schema.dart 的 schemaV2Statements 逐字一致。
# 漂移由 tool/basemap_pack/validate_pack.dart 兜住。
PACK_DDL = [
    '''
  CREATE TABLE IF NOT EXISTS import_bounds (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    region TEXT NOT NULL,
    generated_at TEXT,
    imported_at INTEGER,
    min_lat REAL NOT NULL,
    min_lng REAL NOT NULL,
    max_lat REAL NOT NULL,
    max_lng REAL NOT NULL,
    node_count INTEGER NOT NULL DEFAULT 0,
    way_count INTEGER NOT NULL DEFAULT 0,
    poi_count INTEGER NOT NULL DEFAULT 0
  );''',
    '''
  CREATE TABLE IF NOT EXISTS import_nodes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    osm_id INTEGER NOT NULL,
    lat REAL NOT NULL,
    lng REAL NOT NULL
  );''',
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_import_nodes_osm ON import_nodes(osm_id);',
    'CREATE INDEX IF NOT EXISTS idx_import_nodes_bb ON import_nodes(lat, lng);',
    '''
  CREATE TABLE IF NOT EXISTS import_ways (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    osm_id INTEGER NOT NULL,
    kind TEXT NOT NULL,
    name TEXT,
    cost_class TEXT,
    one_way INTEGER NOT NULL DEFAULT 0,
    is_area INTEGER NOT NULL DEFAULT 0,
    tags TEXT,
    node_ids TEXT NOT NULL,
    min_lat REAL NOT NULL,
    min_lng REAL NOT NULL,
    max_lat REAL NOT NULL,
    max_lng REAL NOT NULL
  );''',
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_import_ways_osm ON import_ways(osm_id);',
    'CREATE INDEX IF NOT EXISTS idx_import_ways_kind ON import_ways(kind);',
    'CREATE INDEX IF NOT EXISTS idx_import_ways_bb'
    ' ON import_ways(min_lat, min_lng, max_lat, max_lng);',
    '''
  CREATE TABLE IF NOT EXISTS import_pois (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    osm_id INTEGER NOT NULL,
    name TEXT,
    lat REAL NOT NULL,
    lng REAL NOT NULL,
    tags TEXT
  );''',
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_import_pois_osm ON import_pois(osm_id);',
    'CREATE INDEX IF NOT EXISTS idx_import_pois_bb ON import_pois(lat, lng);',
]


# ---------------------------------------------------------------------------
# 格号计算 —— 硬性要求：必须防浮点误差（§6.1.1）
# ---------------------------------------------------------------------------

def tile_index(x: float, base: float) -> int:
    """坐标 -> 格号。

    反面教材（实测踩到）：`int((114.10 - 109.0) // 0.1)` 得 50 而非 51，
    因为 `114.10 - 109.0 == 5.099999999999994`。直接用会在 bbox 边界多算一整列格。
    """
    return math.floor(round((round(x, 7) - base) / STEP, 9) + 1e-9)


def tile_key(lat_i: int, lng_i: int) -> str:
    return f't{lat_i * STEP + LAT_BASE:.2f}_{lng_i * STEP + LNG_BASE:.2f}'


def parse_tile_key(key: str) -> tuple[int, int]:
    lat_s, lng_s = key[1:].split('_')
    return tile_index(float(lat_s), LAT_BASE), tile_index(float(lng_s), LNG_BASE)


def tile_bounds(lat_i: int, lng_i: int) -> tuple[float, float, float, float]:
    la0 = lat_i * STEP + LAT_BASE
    lo0 = lng_i * STEP + LNG_BASE
    return (round(la0, 2), round(lo0, 2), round(la0 + STEP, 2), round(lo0 + STEP, 2))


def bbox_of_tiles(keys: list[str]) -> tuple[float, float, float, float]:
    bs = [tile_bounds(*parse_tile_key(k)) for k in keys]
    return (min(b[0] for b in bs), min(b[1] for b in bs),
            max(b[2] for b in bs), max(b[3] for b in bs))


def tiles_for_bbox(min_lat, min_lng, max_lat, max_lng) -> list[tuple[int, int]]:
    """与给定 bbox 相交的所有格（半开区间语义）。"""
    out = []
    for la in range(tile_index(min_lat, LAT_BASE), tile_index(max_lat, LAT_BASE) + 1):
        for lo in range(tile_index(min_lng, LNG_BASE), tile_index(max_lng, LNG_BASE) + 1):
            t0, u0, t1, u1 = tile_bounds(la, lo)
            if t0 < max_lat and t1 > min_lat and u0 < max_lng and u1 > min_lng:
                out.append((la, lo))
    return out


def corridor_tiles() -> list[str]:
    return sorted(tile_key(a, b) for a, b in tiles_for_bbox(*CORRIDOR_BBOX))


def self_check_tile_math() -> None:
    assert tile_index(114.10, LNG_BASE) == 51, tile_index(114.10, LNG_BASE)
    assert tile_index(22.65, LAT_BASE) == 26, tile_index(22.65, LAT_BASE)
    assert tile_index(109.0, LNG_BASE) == 0
    assert tile_index(114.20, LNG_BASE) == 52
    assert tile_index(22.60, LAT_BASE) == 26
    ks = corridor_tiles()
    assert ks == ['t22.60_114.10', 't22.60_114.20',
                  't22.70_114.10', 't22.70_114.20'], ks
    print('  [自检] 格号计算 OK；corridor 覆盖 =', ks, flush=True)


# ---------------------------------------------------------------------------
# tag 处理
# ---------------------------------------------------------------------------

def compact(tags: dict) -> dict | None:
    out = {k: tags[k] for k in KEEP_TAGS if k in tags}
    return out or None


def way_kind(tags: dict):
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


def is_poi(tags: dict) -> bool:
    return any(k in tags for k in POI_KEYS) or 'addr:housenumber' in tags


def jdump(o):
    return json.dumps(o, ensure_ascii=False, separators=(',', ':')) if o else None


# ---------------------------------------------------------------------------
# 落盘中间库
# ---------------------------------------------------------------------------

def open_work(path: str, ddl: list[str], fresh: bool) -> sqlite3.Connection:
    if fresh and os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.execute('PRAGMA journal_mode=OFF')
    db.execute('PRAGMA synchronous=OFF')
    for s in ddl:
        db.execute(s)
    return db


NODES_DDL = ['CREATE TABLE IF NOT EXISTS n(osm_id INTEGER PRIMARY KEY, lat REAL, lng REAL)']
NODES_IDX = ['CREATE INDEX IF NOT EXISTS n_bb ON n(lat,lng)']
POIS_DDL = ['CREATE TABLE IF NOT EXISTS p(osm_id INTEGER PRIMARY KEY, lat REAL, lng REAL, tags TEXT)',
            'CREATE INDEX IF NOT EXISTS p_bb ON p(lat,lng)']
WAYS_DDL = ['''CREATE TABLE IF NOT EXISTS w(osm_id INTEGER PRIMARY KEY, kind TEXT, name TEXT,
              cost_class TEXT, one_way INTEGER, is_area INTEGER, tags TEXT, node_ids TEXT,
              min_lat REAL, min_lng REAL, max_lat REAL, max_lng REAL)''',
            'CREATE INDEX IF NOT EXISTS w_bb ON w(min_lat,min_lng,max_lat,max_lng)']


class NodePass(osmium.SimpleHandler):
    """pass1：**全量**节点 + POI 落盘。

    不做 bbox 裁剪 —— 裁剪会让包内 way 缺失格外的节点，导致 App 侧把路"拉直"
    （就是首轮 badRefWays=8 的根因）。内存仍是 O(1)（中间库在磁盘上）。
    """

    def __init__(self, nodes_db, pois_db):
        super().__init__()
        self.nc = nodes_db.cursor()
        self.pc = pois_db.cursor()
        self.n = 0
        self.p = 0

    def node(self, o):
        self.nc.execute('INSERT OR IGNORE INTO n VALUES(?,?,?)', (o.id, o.lat, o.lon))
        self.n += 1
        tags = dict(o.tags)
        if tags and is_poi(tags):
            self.pc.execute('INSERT OR IGNORE INTO p VALUES(?,?,?,?)',
                            (o.id, o.lat, o.lon, jdump(compact(tags))))
            self.p += 1


class WayPass(osmium.SimpleHandler):
    """pass2：路/面 + **完整 node_ids** + bbox（用 osmium locations 直接取坐标）。

    关键点：
      - `locations=True` 让 osmium 建节点位置索引，`nd.location` 直接给出坐标，
        不必再走一轮"回填 bbox"（首轮那轮白花了 59s）；
      - 拿不到坐标的 ref（在 PBF 范围外的节点）**直接从 node_ids 剔除**，
        这样包内绝不会出现"引用了不存在的节点"，badRefWays 恒为 0；
      - 剔除后不足 2 个点的 way 丢弃（与旧生成器"bbox 外无法解析的边丢弃"一致）。
    """

    def __init__(self, ways_db):
        super().__init__()
        self.wc = ways_db.cursor()
        self.n = 0
        self.dropped_invalid = 0
        self.resolved_ratio_num = 0
        self.resolved_ratio_den = 0

    def way(self, w):
        refs = []
        for nd in w.nodes:
            try:
                loc = nd.location
            except RuntimeError:          # osmium.InvalidLocationError 的基类
                continue
            refs.append((nd.ref, loc.lat, loc.lon))
        self.resolved_ratio_num += len(refs)
        self.resolved_ratio_den += len(w.nodes)
        if len(refs) < 2:
            self.dropped_invalid += 1
            return

        tags = dict(w.tags)
        kc = way_kind(tags)
        if kc is None:
            return
        kind, cost = kc
        ids = [r[0] for r in refs]
        is_area = 1 if (len(ids) >= 4 and ids[0] == ids[-1]) else 0
        ct = compact(tags)
        lats = [r[1] for r in refs]
        lngs = [r[2] for r in refs]
        self.wc.execute(
            'INSERT OR IGNORE INTO w VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
            (w.id, kind,
             ct.get('name') if ct else None,
             cost,
             1 if tags.get('oneway') == 'yes' else 0,
             is_area,
             jdump(ct),
             json.dumps(ids, separators=(',', ':')),
             min(lats), min(lngs), max(lats), max(lngs)))
        self.n += 1


# ---------------------------------------------------------------------------
# 逐格产出包
# ---------------------------------------------------------------------------

def build_tile(key, out_dir, nodes_db, pois_db, ways_db) -> dict:
    lat_i, lng_i = parse_tile_key(key)
    min_lat, min_lng, max_lat, max_lng = tile_bounds(lat_i, lng_i)

    final = os.path.join(out_dir, f'{key}.db')
    tmp = final + '.tmp'
    if os.path.exists(tmp):
        os.remove(tmp)

    tdb = sqlite3.connect(tmp)
    tdb.execute('PRAGMA journal_mode=OFF')
    tdb.execute('PRAGMA synchronous=OFF')
    for stmt in PACK_DDL:
        tdb.execute(stmt)
    tc = tdb.cursor()

    # ① 与本格相交的 way（含其完整 node_ids / bbox）
    way_rows = ways_db.execute('''
        SELECT osm_id, kind, name, cost_class, one_way, is_area, tags, node_ids,
               min_lat, min_lng, max_lat, max_lng
        FROM w
        WHERE max_lat >= ? AND min_lat <= ? AND max_lng >= ? AND min_lng <= ?
    ''', (min_lat, max_lat, min_lng, max_lng)).fetchall()

    needed: set[int] = set()
    for r in way_rows:
        needed.update(json.loads(r[7]))

    # ② 本格自身的节点（半开区间）
    own = nodes_db.execute(
        'SELECT osm_id, lat, lng FROM n WHERE lat >= ? AND lat < ? AND lng >= ? AND lng < ?',
        (min_lat, max_lat, min_lng, max_lng)).fetchall()
    node_rows = {o: (la, lo) for o, la, lo in own}

    # ③ 补全：way 引用到、但落在格外的节点（几何完整性 —— 防跨界道路被拉直）
    missing = [i for i in needed if i not in node_rows]
    ncur = nodes_db.cursor()
    for i in range(0, len(missing), 900):
        chunk = missing[i:i + 900]
        ph = ','.join('?' * len(chunk))
        for o, la, lo in ncur.execute(
                f'SELECT osm_id, lat, lng FROM n WHERE osm_id IN ({ph})', chunk):
            node_rows[o] = (la, lo)

    unresolved = [i for i in needed if i not in node_rows]

    tc.executemany('INSERT OR IGNORE INTO import_nodes(osm_id,lat,lng) VALUES(?,?,?)',
                   ((o, la, lo) for o, (la, lo) in node_rows.items()))
    tc.executemany(
        'INSERT OR IGNORE INTO import_ways(osm_id,kind,name,cost_class,one_way,is_area,'
        'tags,node_ids,min_lat,min_lng,max_lat,max_lng) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
        way_rows)
    poi_rows = pois_db.execute(
        'SELECT osm_id, lat, lng, tags FROM p WHERE lat >= ? AND lat < ? AND lng >= ? AND lng < ?',
        (min_lat, max_lat, min_lng, max_lng)).fetchall()
    tc.executemany('INSERT OR IGNORE INTO import_pois(osm_id,lat,lng,tags) VALUES(?,?,?,?)',
                   poi_rows)

    n_cnt = tc.execute('SELECT COUNT(*) FROM import_nodes').fetchone()[0]
    w_cnt = tc.execute('SELECT COUNT(*) FROM import_ways').fetchone()[0]
    p_cnt = tc.execute('SELECT COUNT(*) FROM import_pois').fetchone()[0]

    # ④ ★ 自检：包内不得有 way 引用到不存在的节点
    ids = {r[0] for r in tc.execute('SELECT osm_id FROM import_nodes')}
    bad = [o for o, nj in tc.execute('SELECT osm_id, node_ids FROM import_ways')
           if any(r not in ids for r in json.loads(nj))]

    if own:
        ola = [o[1] for o in own]; olo = [o[2] for o in own]
        bb = (min(ola), min(olo), max(ola), max(olo))
    else:
        bb = (min_lat, min_lng, max_lat, max_lng)
    tc.execute('INSERT OR REPLACE INTO import_bounds VALUES(1,?,?,?,?,?,?,?,?,?,?)',
               (key, time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                int(time.time() * 1000), bb[0], bb[1], bb[2], bb[3],
                n_cnt, w_cnt, p_cnt))

    tdb.commit()
    tdb.execute(f'PRAGMA user_version = {PACK_SCHEMA_VERSION}')
    tdb.execute('VACUUM')
    tdb.commit()
    tdb.close()
    os.replace(tmp, final)

    return {'key': key, 'nodes': n_cnt, 'ways': w_cnt, 'pois': p_cnt,
            'own': len(own), 'extra': n_cnt - len(own), 'pois_in_tile': len(poi_rows),
            'bad': bad, 'unresolved': len(unresolved),
            'bytes': os.path.getsize(final)}


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description='广东矢量底图 -> 0.1° 网格 SQLite 包')
    ap.add_argument('--src', default=SRC)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--bundled-only', action='store_true')
    g.add_argument('--all', action='store_true')
    g.add_argument('--tiles')
    ap.add_argument('--out', default=None)
    ap.add_argument('--bundled-dir', default='assets/basemap')
    ap.add_argument('--work-dir', default=None)
    ap.add_argument('--reuse-work', action='store_true')
    ap.add_argument('--keep-work', action='store_true')
    args = ap.parse_args()

    print('== 自检 ==', flush=True)
    self_check_tile_math()
    bundled = corridor_tiles()

    if args.bundled_only:
        tiles, out_dir = bundled, (args.out or args.bundled_dir)
    elif args.tiles:
        tiles, out_dir = [t.strip() for t in args.tiles.split(',') if t.strip()], \
                         (args.out or 'basemap_out')
    else:
        tiles, out_dir = None, (args.out or 'basemap_out')

    os.makedirs(out_dir, exist_ok=True)
    work = args.work_dir or os.path.join(out_dir, '_work')
    os.makedirs(work, exist_ok=True)
    reuse = args.reuse_work and os.path.exists(os.path.join(work, 'nodes.db'))
    print(f'  输出={out_dir}  中间={work}  复用中间库={reuse}\n'
          f'  目标格={"全部非空格" if tiles is None else tiles}', flush=True)

    t0 = time.time()
    nodes_db = open_work(os.path.join(work, 'nodes.db'), NODES_DDL, not reuse)
    pois_db = open_work(os.path.join(work, 'pois.db'), POIS_DDL, not reuse)
    ways_db = open_work(os.path.join(work, 'ways.db'), WAYS_DDL, not reuse)

    if not reuse:
        print('\n[1/4] pass1: 全量 nodes + pois ...', flush=True)
        p1 = NodePass(nodes_db, pois_db)
        p1.apply_file(args.src, locations=False)
        nodes_db.commit(); pois_db.commit()
        nodes_db.executescript(';'.join(NODES_IDX))
        print(f'  nodes={p1.n:,}  pois={p1.p:,}  ({time.time() - t0:.0f}s)', flush=True)

        t1 = time.time()
        print('[2/4] pass2: ways（locations=True 直接取坐标）...', flush=True)
        p2 = WayPass(ways_db)
        p2.apply_file(args.src, locations=True,
                      idx=f'sparse_file_array,{os.path.join(work, "loc.idx")}')
        ways_db.commit()
        ratio = (p2.resolved_ratio_num / p2.resolved_ratio_den * 100
                 if p2.resolved_ratio_den else 0)
        print(f'  ways={p2.n:,}  丢失 ref={p2.resolved_ratio_den - p2.resolved_ratio_num:,}'
              f'({100 - ratio:.3f}%)  丢弃不足2点={p2.dropped_invalid:,}  '
              f'({time.time() - t1:.0f}s)', flush=True)
        if p2.dropped_invalid:
            print('  ※ 上面是 PBF 边界外节点的正常丢弃（广东裁切导致）', flush=True)
    else:
        print('\n[1/4][2/4] 复用已有中间库，跳过 PBF 扫描', flush=True)

    n_kept = nodes_db.execute('SELECT COUNT(*) FROM n').fetchone()[0]
    w_kept = ways_db.execute('SELECT COUNT(*) FROM w').fetchone()[0]
    print(f'  中间库: nodes={n_kept:,}  ways={w_kept:,}', flush=True)

    if tiles is None:
        print('[3/4] 自动发现非空格 ...', flush=True)
        found = set()
        for (a, b, c, d) in ways_db.execute(
                'SELECT min_lat,min_lng,max_lat,max_lng FROM w'):
            for la, lo in tiles_for_bbox(a, b, c, d):
                found.add(tile_key(la, lo))
        tiles = sorted(found)
        print(f'  发现 {len(tiles):,} 个', flush=True)
    else:
        print('[3/4] 跳过自动发现（指定格）', flush=True)

    print(f'[4/4] 产出 {len(tiles)} 个包 ...', flush=True)
    t3 = time.time()
    tot = {'nodes': 0, 'ways': 0, 'pois': 0, 'bytes': 0}
    biggest = None
    bad_total = 0
    bad_packs = []
    for i, key in enumerate(tiles, 1):
        st = build_tile(key, out_dir, nodes_db, pois_db, ways_db)
        for k in ('nodes', 'ways', 'pois', 'bytes'):
            tot[k] += st[k]
        if biggest is None or st['bytes'] > biggest['bytes']:
            biggest = st
        if st['bad']:
            bad_total += len(st['bad'])
            bad_packs.append((key, len(st['bad'])))
        if i % 20 == 0 or i == len(tiles):
            print(f'  [{i}/{len(tiles)}] {key}  nodes={st["nodes"]:,} '
                  f'ways={st["ways"]:,} pois={st["pois"]:,} ({st["bytes"]/1048576:.1f}MB)  '
                  f'累计 {tot["nodes"]/1e6:.2f}M 节点 / {time.time() - t3:.0f}s', flush=True)

    nodes_db.close(); pois_db.close(); ways_db.close()

    # 额外把内置格另存一份（--all --bundled-dir）
    copied = []
    if args.all and args.bundled_dir:
        os.makedirs(args.bundled_dir, exist_ok=True)
        for k in bundled:
            srcdb = os.path.join(out_dir, f'{k}.db')
            if os.path.exists(srcdb):
                shutil.copy2(srcdb, os.path.join(args.bundled_dir, f'{k}.db'))
                copied.append(k)

    if not args.keep_work:
        shutil.rmtree(work, ignore_errors=True)

    print(f'\n== 完成 ==  包 {len(tiles)} 个  节点 {tot["nodes"]:,}  '
          f'ways {tot["ways"]:,}  POI {tot["pois"]:,}  '
          f'合计 {tot["bytes"]/1048576:.1f}MB')
    if biggest:
        print(f'  最大包: {biggest["key"]}  {biggest["bytes"]/1048576:.1f}MB '
              f'({biggest["nodes"]:,} 节点，其中格外补全 {biggest["extra"]:,})')
    if copied:
        print(f'  已另存内置格到 {args.bundled_dir}: {copied}')
    print(f'  ★ badRefWays 总计 = {bad_total}  '
          f'{"✅ 几何完整" if bad_total == 0 else "❌ 存在缺失，见 " + str(bad_packs)}')
    print(f'  总耗时 {time.time() - t0:.0f}s', flush=True)

    if bad_total:
        print('\n❌ 产出被判定为不合格：包内存在引用了不存在节点的 way。', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())