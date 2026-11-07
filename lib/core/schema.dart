/// SQLite Schema —— **v12「三层分域」**（docs/design/23-data-structure.md）
///
/// v12 把用户层从「7 张按类型混装的表」改成「**路网 / 世界图 / 行政区域** 三个域、
/// 每域自带一套表」，共 **19 张表**，**域之间零引用**。
///
/// 核心思路：**域由表名表达，不由字段表达** —— 于是
/// `LineKind` / `AreaType.isVirtual` / `PointKind` / `PointSource` / `EntityType`
/// 以及 `hasMaterial` / `hasRouteWidth` 这些判据全都不需要了：
/// 「这张表就是那个类型」。
///
/// | 域 | 表前缀 | 描述什么世界 |
/// |----|--------|-------------|
/// | 路网 | `way_`   | 我自己跑的路：路线 + 行驶轨迹 |
/// | 世界图 | `world_` | 现实实体：界线 / 区域 / 多边形 / 门 / 世界要素 / 记录点 |
/// | 行政区域 | `zone_` | 虚拟的行政边界 |
///
/// 三条贯穿全库的约定（23 章 §6）：
/// 1. **端点仍是两列**（D4）：`<域>_lines.start_point_id` / `end_point_id`，
///    拐点才在 `<域>_line_bends` 里；
/// 2. **拐点是链**（D13）：`(line_id, point_id, before_point_id)`，每行记"我的前驱"，
///    于是插入/删除是 O(1) 指针操作，不需要整段重编号；
/// 3. **封闭图形有两种构造**（D19）：`world_areas` 由**线**围成、
///    `world_polygons` 由**点**围成，两者同一语义、可互相转换。
///
/// 版本历史（v1~v11，细节见各自常量上的注释）：
/// - v11 点的"处理状态"与来源细分；v10 路线路宽；v9 折线拐点；v8 楼层；
/// - v7 门改成吸附在界线上的点；v6 点分类 + 界线/路线；v5 线上要素重做；
/// - v4 统一编辑模式（材质从 areas 搬到 lines、`area_lines` 多对多）；
/// - v3 导入层搬出 user.db；v2 OSM 导入层并入；v1 用户层五表。
///
/// 只包含 DDL 常量与版本号；DAO 层（data/ 目录）负责执行与迁移。
/// 保持零依赖（不 import sqflite），方便 schema 变更走 git review。
library;

/// **user.db** 的 schema 版本。
///
/// v12 = 三层分域（第二十三章）。**这正是 19 张表的版本**。
const int schemaVersion = 12;

/// **basemap pack** 的格式版本（写进 pack 的 `PRAGMA user_version`）。
///
/// 必须与 `tool/basemap_pack/build_packs.py` 的 `PACK_SCHEMA_VERSION` 一致，
/// 由 `tool/basemap_pack/validate_pack.dart` 在收尾时校验。
///
/// 与 [schemaVersion] 是**两条独立的时间线**：v12 只动用户层，所以这个值不变。
const int kPackSchemaVersion = 1;

/// 从 [fromV] 升级到 [schemaVersion] **能不能自动做**；不能就返回给用户看的原因。
///
/// 返回 `null` = 可以自动升级（或压根不用升级）；非 `null` = 必须**中止打开数据库**
/// 并把这段文字送给用户。
///
/// 为什么这段策略放在 `core/` 而不是 `data/app_repository.dart` 的 `onUpgrade` 里：
///
/// 1. **它是 schema 的职责**——"哪几个版本之间可以直接 CREATE/ALTER 搬过去"是
///    schema 演化的知识，不是某个 DAO 的实现细节；
/// 2. `core/` 零依赖（AGENTS §4），所以纯 Dart 脚本能直接验证它，
///    而 `data/` 因为 `db_factory.dart` 引了 `path_provider` 而**无法**被脚本 import
///    —— 之前这段逻辑藏在 `_onUpgrade` 里，等于**测不到**。
///
/// v11 → v12（23 章）是**结构性重构**（7 张按类型混装的表 → 19 张三域表，
/// 还要跨域复制点、重建拐点链、复活软删点、丢弃区域 1），
/// 必须在库里搬数据，不能靠建表语句完成。
///
/// 本项目**只构建最新版本**：旧库不自动升级，也**不在仓库里保存迁移脚本** ——
/// 当前版本的完整 DDL 就是本文件 [userV12Statements]（第一来源），
/// 旧库要么按它重建，要么放弃。规矩见 AGENTS.md §4。
/// 关键是**绝不能"什么都不做就放行"**：旧代码就是这么写的 —— 它绕过后
/// 在函数末尾把 `schema_meta.schema_version` 写成新版本，sqflite 也会在
/// `onUpgrade` 返回后把 `PRAGMA user_version` 写成新版本
/// （已核对 sqflite_common 2.5.11 `database_mixin.dart:1153-1169`，
/// onUpgrade **期间** user_version 仍是旧值）。结果是库**自称 v12、里面还是 v11 的
/// 7 张表** → 之后每次查询都 `no such table: way_points`。
String? autoUpgradeBlockReason(int fromV) {
  if (fromV >= schemaVersion) return null;
  // 只有 v11 这一个"关口"是必须手工的；更老的版本会先被 onUpgrade 里
  // v3~v11 那些分支推到 v11，然后同样撞在这里。
  return '这个地图数据库还是 v$fromV，但本版 App 需要 v$schemaVersion。\n'
      '\n'
      'v11 → v12 是一次结构性重构（7 张表 → 19 张三域表），必须在库里搬数据，\n'
      '不能靠建表语句自动完成；本项目只构建最新版本，不做旧库自动升级。\n'
      '\n'
      '请先备份整库（cp "<库文件>" "<库文件>.pre_v12.bak"），然后按当前版本的\n'
      'DDL 重建库：完整建表语句在 lib/core/schema.dart 的 userV12Statements，\n'
      '规矩见 AGENTS.md §4，结构见 docs/design/23-data-structure.md §7。\n'
      '\n'
      '（本次打开没有改动你的数据：事务已回滚，库仍是 v$fromV。）';
}

/// 当前版本的完整建表语句（新库直接用它建）。
///
/// 顺序即依赖顺序：点 → 线 → 拐点链 → ……，世界域的点必须早于它的线与多边形。
const List<String> schemaStatements = [
  // ==========================================================================
  // 一、路网域（way_）—— 我自己跑的路
  // ==========================================================================

  // ---- 点表：几何点（含连线前的暂存点）----
  '''
  CREATE TABLE way_points (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    lat REAL NOT NULL,
    lng REAL NOT NULL,
    floors TEXT NOT NULL DEFAULT '[1]',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  );''',
  'CREATE INDEX idx_way_points_deleted ON way_points(deleted_at);',

  // ---- 路线。端点仍是两列（D4）；路宽/单行/通行代价只属于路线 ----
  //
  // route_width: fenced/main/narrow/bike_bridge/walk_bridge/crossing（21 章含换路口）
  // cost_class:  **冻结**，列与数据都留，不进表单（19 章）
  '''
  CREATE TABLE way_lines (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT,
    floors TEXT NOT NULL DEFAULT '[1]',
    start_point_id INTEGER NOT NULL REFERENCES way_points(id),
    end_point_id   INTEGER NOT NULL REFERENCES way_points(id),
    route_width TEXT,
    one_way INTEGER NOT NULL DEFAULT 0,
    cost_class TEXT,
    note TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  );''',
  'CREATE INDEX idx_way_lines_deleted ON way_lines(deleted_at);',
  'CREATE INDEX idx_way_lines_start ON way_lines(start_point_id) WHERE deleted_at IS NULL;',
  'CREATE INDEX idx_way_lines_end ON way_lines(end_point_id) WHERE deleted_at IS NULL;',

  // ---- 拐点链（D13）----
  //
  // 点序列 = `start_point_id →（沿 before 关系走）→ end_point_id`，**终点不在链上**。
  // 两条 SQL 约束挡住两种最常见的链损坏：
  //   PRIMARY KEY (line_id, point_id)     同一条线里同一点只能出现一次
  //   UNIQUE (line_id, before_point_id)   **不分叉**：一个前驱最多一个后继
  // 环与断头 SQL 管不了 → 靠 `tool/checks` 的自检脚本 + 读链时的步数上限。
  '''
  CREATE TABLE way_line_bends (
    line_id         INTEGER NOT NULL REFERENCES way_lines(id),
    point_id        INTEGER NOT NULL REFERENCES way_points(id),
    before_point_id INTEGER NOT NULL REFERENCES way_points(id),
    PRIMARY KEY (line_id, point_id),
    UNIQUE (line_id, before_point_id)
  );''',
  'CREATE INDEX idx_way_line_bends_point ON way_line_bends(point_id);',

  // ---- 行驶轨迹（D15）：一行一个采样点，按 trip 分段 ----
  //
  // **原始采集数据，不是几何**：不进点表、不参与吸附；唯一出口是"转成路线"。
  // 只存**不可从其它列推导**的量（speed/heading 由相邻点推导，故不存）。
  // ⚠️ altitude 不可用于判断楼层（城市峡谷误差 ±10~20 m）。
  '''
  CREATE TABLE way_marks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trip        TEXT    NOT NULL,
    recorded_at INTEGER NOT NULL,
    lat REAL NOT NULL,
    lng REAL NOT NULL,
    accuracy REAL,
    altitude REAL,
    floors TEXT NOT NULL DEFAULT '[1]',
    processed INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  );''',
  'CREATE INDEX idx_way_marks_trip ON way_marks(trip, recorded_at);',
  'CREATE INDEX idx_way_marks_time ON way_marks(recorded_at) WHERE deleted_at IS NULL;',
  'CREATE INDEX idx_way_marks_bb ON way_marks(lat, lng);',

  // ==========================================================================
  // 二、世界图域（world_）—— 现实世界的客观实体
  // ==========================================================================

  '''
  CREATE TABLE world_points (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    lat REAL NOT NULL,
    lng REAL NOT NULL,
    floors TEXT NOT NULL DEFAULT '[1]',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  );''',
  'CREATE INDEX idx_world_points_deleted ON world_points(deleted_at);',

  // ---- 界线（围墙/铁栏/绿化带/河道/施工/软边界）。材质只在这里 ----
  '''
  CREATE TABLE world_lines (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT,
    floors TEXT NOT NULL DEFAULT '[1]',
    start_point_id INTEGER NOT NULL REFERENCES world_points(id),
    end_point_id   INTEGER NOT NULL REFERENCES world_points(id),
    boundary_type TEXT,
    note TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  );''',
  'CREATE INDEX idx_world_lines_deleted ON world_lines(deleted_at);',
  'CREATE INDEX idx_world_lines_start ON world_lines(start_point_id) WHERE deleted_at IS NULL;',
  'CREATE INDEX idx_world_lines_end ON world_lines(end_point_id) WHERE deleted_at IS NULL;',

  '''
  CREATE TABLE world_line_bends (
    line_id         INTEGER NOT NULL REFERENCES world_lines(id),
    point_id        INTEGER NOT NULL REFERENCES world_points(id),
    before_point_id INTEGER NOT NULL REFERENCES world_points(id),
    PRIMARY KEY (line_id, point_id),
    UNIQUE (line_id, before_point_id)
  );''',
  'CREATE INDEX idx_world_line_bends_point ON world_line_bends(point_id);',

  // ---- 区域：**由线围成**（边是共享实体：有材质、能挂门、能被多个区域共用）----
  //
  // area_type 只剩 4 值（道路/小区/建筑/阻隔）——「行政区域」不是值，而是 zone_areas 那张表。
  // 没有 sort_order（D14）：组环器按"边"建图，不读顺序；顺序的权威是几何。
  '''
  CREATE TABLE world_areas (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    area_type TEXT NOT NULL DEFAULT 'community',
    floors TEXT NOT NULL DEFAULT '[1]',
    color_override INTEGER,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  );''',
  'CREATE INDEX idx_world_areas_deleted ON world_areas(deleted_at);',

  '''
  CREATE TABLE world_area_lines (
    area_id INTEGER NOT NULL REFERENCES world_areas(id),
    line_id INTEGER NOT NULL REFERENCES world_lines(id),
    PRIMARY KEY (area_id, line_id)
  );''',
  'CREATE INDEX idx_world_area_lines_line ON world_area_lines(line_id);',

  // ---- 多边形：**由点围成**（D19）。与 world_areas 同一语义、可互相转换 ----
  //
  // ⚠️ 门与世界要素挂不上它（D21：单一锚点在线）—— 要挂门先转成 area。
  '''
  CREATE TABLE world_polygons (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    area_type TEXT NOT NULL DEFAULT 'community',
    floors TEXT NOT NULL DEFAULT '[1]',
    color_override INTEGER,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  );''',
  'CREATE INDEX idx_world_polygons_deleted ON world_polygons(deleted_at);',

  // 环链（D20）：与拐点链同一套写法，但**环没有头** ——
  // 不变量是「从任意一点走 N 步（N = 行数）回到起点」，最少 3 个点。
  '''
  CREATE TABLE world_polygon_points (
    polygon_id      INTEGER NOT NULL REFERENCES world_polygons(id),
    point_id        INTEGER NOT NULL REFERENCES world_points(id),
    before_point_id INTEGER NOT NULL REFERENCES world_points(id),
    PRIMARY KEY (polygon_id, point_id),
    UNIQUE (polygon_id, before_point_id)
  );''',
  'CREATE INDEX idx_world_polygon_points_point ON world_polygon_points(point_id);',

  // ---- 门（15 章）：吸附在界线上的一处出入口。单一锚点 = world_lines.id（D21）----
  '''
  CREATE TABLE world_gates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT,
    gate_type TEXT NOT NULL DEFAULT 'park',
    line_id INTEGER REFERENCES world_lines(id),
    lat REAL NOT NULL,
    lng REAL NOT NULL,
    vehicle_type TEXT NOT NULL DEFAULT 'all',
    access_level TEXT NOT NULL DEFAULT 'free',
    is_permanent INTEGER NOT NULL DEFAULT 1,
    note TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  );''',
  'CREATE INDEX idx_world_gates_line ON world_gates(line_id) WHERE deleted_at IS NULL;',
  'CREATE INDEX idx_world_gates_deleted ON world_gates(deleted_at);',

  // ---- 世界要素（13 章 + D18）。entity_type = shop/building/unit/delivery_point/parking ----
  //
  // 与 world_areas.area_type 同一套逻辑：这些类型**列完全相同**，所以共用一张表；
  // 而门单独一张（列集不同：车型/门禁/永久性）。
  '''
  CREATE TABLE world_entities (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL DEFAULT 'shop',
    name TEXT NOT NULL,
    door_no TEXT,
    desc TEXT,
    line_id INTEGER REFERENCES world_lines(id),
    lat REAL NOT NULL,
    lng REAL NOT NULL,
    width REAL,
    note TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  );''',
  'CREATE INDEX idx_world_entities_line ON world_entities(line_id) WHERE deleted_at IS NULL;',
  'CREATE INDEX idx_world_entities_deleted ON world_entities(deleted_at);',

  // ---- 记录点：记录模式下"我在这儿"的落点（22 章）----
  //
  // 它有自己的表，所以 PointSource 三值枚举塌缩成一个 by_gps 布尔，
  // 而"浏览态只显示未处理的记录点"变成一句话的查询。
  '''
  CREATE TABLE world_marks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT,
    lat REAL NOT NULL,
    lng REAL NOT NULL,
    floors TEXT NOT NULL DEFAULT '[1]',
    accuracy REAL,
    by_gps INTEGER NOT NULL DEFAULT 0,
    processed INTEGER NOT NULL DEFAULT 0,
    note TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  );''',
  'CREATE INDEX idx_world_marks_pending ON world_marks(processed) WHERE deleted_at IS NULL;',

  // ==========================================================================
  // 三、行政区域域（zone_）—— 虚拟的行政边界（寻路必须跳过整域）
  // ==========================================================================

  '''
  CREATE TABLE zone_points (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    lat REAL NOT NULL,
    lng REAL NOT NULL,
    floors TEXT NOT NULL DEFAULT '[1]',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  );''',
  'CREATE INDEX idx_zone_points_deleted ON zone_points(deleted_at);',

  '''
  CREATE TABLE zone_lines (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT,
    floors TEXT NOT NULL DEFAULT '[1]',
    start_point_id INTEGER NOT NULL REFERENCES zone_points(id),
    end_point_id   INTEGER NOT NULL REFERENCES zone_points(id),
    note TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  );''',
  'CREATE INDEX idx_zone_lines_deleted ON zone_lines(deleted_at);',
  'CREATE INDEX idx_zone_lines_start ON zone_lines(start_point_id) WHERE deleted_at IS NULL;',
  'CREATE INDEX idx_zone_lines_end ON zone_lines(end_point_id) WHERE deleted_at IS NULL;',

  '''
  CREATE TABLE zone_line_bends (
    line_id         INTEGER NOT NULL REFERENCES zone_lines(id),
    point_id        INTEGER NOT NULL REFERENCES zone_points(id),
    before_point_id INTEGER NOT NULL REFERENCES zone_points(id),
    PRIMARY KEY (line_id, point_id),
    UNIQUE (line_id, before_point_id)
  );''',
  'CREATE INDEX idx_zone_line_bends_point ON zone_line_bends(point_id);',

  // 行政区域：**没有 area_type 列** —— 整张表就是"行政区域"。
  '''
  CREATE TABLE zone_areas (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    floors TEXT NOT NULL DEFAULT '[1]',
    color_override INTEGER,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  );''',
  'CREATE INDEX idx_zone_areas_deleted ON zone_areas(deleted_at);',

  '''
  CREATE TABLE zone_area_lines (
    area_id INTEGER NOT NULL REFERENCES zone_areas(id),
    line_id INTEGER NOT NULL REFERENCES zone_lines(id),
    PRIMARY KEY (area_id, line_id)
  );''',
  'CREATE INDEX idx_zone_area_lines_line ON zone_area_lines(line_id);',
];

/// **basemap pack 内的 DDL**（v2 时代曾是 user.db 的一部分）。
///
/// v3 起这四个表**只存在于 pack 文件**里，user.db 不再包含它们；
/// 由 `tool/basemap_pack/build_packs.py`（Python 侧手写副本）生成，
/// 并由 `tool/basemap_pack/validate_pack.dart` 用本常量反查，防止两边漂移。
///
/// ⚠️ 别和用户层的 `way_*` 搞混：那是 `user.db` 里**可写**的路网域，
/// 这是 pack 文件里**只读**的 OSM 导入层。两者唯一共同点是名字里都有 "way"。
///
/// 保留 `IF NOT EXISTS` 幂等语义：Python 生成器与校验器都直接复用本列表。
const List<String> packDdlStatements = [
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
  'CREATE INDEX IF NOT EXISTS idx_import_ways_bb ON import_ways(min_lat, min_lng, max_lat, max_lng);',
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
];

// ============================================================================
// 历史迁移（v1 → v11）。**一条都不能删** —— 老用户可能从任意一版升上来。
// ============================================================================

/// v2 → v3 迁移：把导入层四表从 user.db 移除。
///
/// `DROP ... IF EXISTS` 幂等：从 v1 直接升到 v3 的老库（v1 本来就没有这些表）
/// 也能安全执行，因此 `_onUpgrade` 里不必再区分 oldV<2 / oldV<3 两条路径。
const List<String> userV3DropStatements = [
  'DROP TABLE IF EXISTS import_ways;',
  'DROP TABLE IF EXISTS import_pois;',
  'DROP TABLE IF EXISTS import_nodes;',
  'DROP TABLE IF EXISTS import_bounds;',
];

/// v3 → v4 迁移：区块/线 的属性归属纠正 + 一线多区（12 章 §3）。
///
/// 顺序**不能调换**：加列 → 建关联表 → 趁 `lines.area_id` 还在时灌进去 →
/// 重建 lines（带 boundary_type）→ 重建 areas（boundary_type → area_type）。
const List<String> userV4Statements = [
  'ALTER TABLE points ADD COLUMN name TEXT;',
  '''
  CREATE TABLE IF NOT EXISTS area_lines (
    area_id INTEGER NOT NULL REFERENCES areas(id),
    line_id INTEGER NOT NULL REFERENCES lines(id),
    sort_order INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (area_id, line_id)
  );''',
  '''
  INSERT OR IGNORE INTO area_lines (area_id, line_id, sort_order)
  SELECT area_id, id, 0 FROM lines WHERE area_id IS NOT NULL;''',
  '''
  CREATE TABLE lines_v4 (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    name TEXT,
    floors TEXT NOT NULL DEFAULT '[1]',
    start_point_id INTEGER NOT NULL REFERENCES points(id),
    end_point_id INTEGER NOT NULL REFERENCES points(id),
    boundary_type TEXT,
    cost_class TEXT,
    one_way INTEGER NOT NULL DEFAULT 0,
    note TEXT,
    created_at INTEGER,
    updated_at INTEGER,
    deleted_at INTEGER,
    ext TEXT
  );''',
  '''
  INSERT INTO lines_v4
    (id, kind, name, start_point_id, end_point_id, boundary_type,
     cost_class, one_way, note, created_at, updated_at, deleted_at, ext)
  SELECT
    l.id, l.kind, NULL, l.start_point_id, l.end_point_id,
    -- 材质只回填给**边界线**：v3 里 area_id 只标在边界线上，但万一有内部路
    -- 也被标了 area_id（手工数据），给它安一个"铁栏"材质是错的。
    CASE WHEN l.kind = 'area_boundary'
         THEN (SELECT a.boundary_type FROM areas a WHERE a.id = l.area_id)
         ELSE NULL END,
    l.cost_class, l.one_way, l.note, l.created_at, l.updated_at, l.deleted_at, l.ext
  FROM lines l;''',
  'DROP TABLE lines;',
  'ALTER TABLE lines_v4 RENAME TO lines;',
  'CREATE INDEX IF NOT EXISTS idx_lines_deleted ON lines(deleted_at);',
  'CREATE INDEX IF NOT EXISTS idx_lines_start ON lines(start_point_id) WHERE deleted_at IS NULL;',
  'CREATE INDEX IF NOT EXISTS idx_lines_end ON lines(end_point_id) WHERE deleted_at IS NULL;',
  'CREATE INDEX IF NOT EXISTS idx_area_lines_line ON area_lines(line_id);',
  'CREATE INDEX IF NOT EXISTS idx_gates_line ON gates(boundary_line_id) WHERE deleted_at IS NULL;',
  '''
  CREATE TABLE areas_v4 (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    area_type TEXT NOT NULL DEFAULT 'community',
    floors TEXT NOT NULL DEFAULT '[1]',
    is_active INTEGER NOT NULL DEFAULT 1,
    dismantle_date TEXT,
    color_override INTEGER,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER,
    updated_at INTEGER,
    deleted_at INTEGER,
    ext TEXT
  );''',
  '''
  INSERT INTO areas_v4
    (id, name, area_type, is_active, dismantle_date, color_override,
     sort_order, created_at, updated_at, deleted_at, ext)
  SELECT
    id, name,
    CASE boundary_type
      WHEN 'river' THEN 'barrier'
      WHEN 'construction' THEN 'barrier'
      ELSE 'community'
    END,
    is_active, dismantle_date, color_override, sort_order,
    created_at, updated_at, deleted_at, ext
  FROM areas;''',
  'DROP TABLE areas;',
  'ALTER TABLE areas_v4 RENAME TO areas;',
  'CREATE INDEX IF NOT EXISTS idx_areas_deleted ON areas(deleted_at);',
];

/// v4 → v5 迁移：线上要素重做（13 章 §3）。
///
/// 门牌 → 店铺（`door` → `shop`）；`line_weight`（权重）→ `width`（宽度）；
/// 去掉 `side_offset_m`。老数据的位置回填在 `AppRepository` 里用 Dart 做。
const List<String> userV5Statements = [
  '''
  CREATE TABLE entities_v5 (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    desc TEXT,
    door_no TEXT,
    entity_type TEXT NOT NULL DEFAULT 'delivery_point',
    line_id INTEGER REFERENCES lines(id),
    line_index INTEGER,
    center_lat REAL,
    center_lng REAL,
    width REAL,
    boundary_type TEXT,
    point_id INTEGER REFERENCES points(id),
    gate_id INTEGER REFERENCES gates(id),
    tags TEXT,
    created_at INTEGER,
    updated_at INTEGER,
    deleted_at INTEGER
  );''',
  '''
  INSERT INTO entities_v5
    (id, name, desc, door_no, entity_type, line_id, line_index,
     center_lat, center_lng, width, boundary_type, point_id, gate_id, tags,
     created_at, updated_at, deleted_at)
  SELECT
    id, name, desc, NULL,
    CASE entity_type WHEN 'door' THEN 'shop' ELSE entity_type END,
    line_id, line_index,
    NULL, NULL,
    line_weight,
    NULL,
    point_id, gate_id, tags,
    created_at, updated_at, deleted_at
  FROM entities;''',
  'DROP TABLE entities;',
  'ALTER TABLE entities_v5 RENAME TO entities;',
  'CREATE INDEX IF NOT EXISTS idx_entities_deleted ON entities(deleted_at);',
  'CREATE INDEX IF NOT EXISTS idx_entities_line ON entities(line_id) WHERE deleted_at IS NULL;',
  '''
  UPDATE entities SET
    center_lat = (SELECT lat FROM points WHERE points.id = entities.point_id),
    center_lng = (SELECT lng FROM points WHERE points.id = entities.point_id)
  WHERE point_id IS NOT NULL;''',
];

/// v5 → v6 迁移：点分类 + 界线/路线（14 章 §3）。纯枚举值重命名。
const List<String> userV6Statements = [
  // ⚠️ 必须先加列：`points.source` 是 v6 才有的，
  // 只有新建库的 DDL 里才有它 —— 老库不补这一步，下面的 UPDATE 会报 no such column。
  '''
  ALTER TABLE points ADD COLUMN source TEXT NOT NULL DEFAULT 'manual';''',
  '''
  UPDATE points SET kind = CASE kind
    WHEN 'entity_point' THEN 'waypoint'
    ELSE 'auxiliary'
  END;''',
  '''
  UPDATE lines SET kind = CASE kind
    WHEN 'route_edge' THEN 'route'
    ELSE 'boundary'
  END;''',
];

/// v6 → v7 迁移：门改成"吸附在界线上的点"（15 章 §3）。
///
/// `lat`/`lng` → `center_lat`/`center_lng`；`boundary_line_id` → `line_id`；
/// 旧 `area_id` / `line_weight` / 时间管制四件套**丢弃**；新增 `gate_type`。
const List<String> userV7Statements = [
  '''
  CREATE TABLE gates_v7 (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT,
    gate_type TEXT NOT NULL DEFAULT 'park',
    line_id INTEGER REFERENCES lines(id),
    center_lat REAL NOT NULL,
    center_lng REAL NOT NULL,
    vehicle_type TEXT NOT NULL DEFAULT 'all',
    access_level TEXT NOT NULL DEFAULT 'free',
    is_permanent INTEGER NOT NULL DEFAULT 1,
    note TEXT,
    created_at INTEGER,
    updated_at INTEGER,
    deleted_at INTEGER,
    ext TEXT
  );''',
  '''
  INSERT INTO gates_v7
    (id, name, gate_type, line_id, center_lat, center_lng,
     vehicle_type, access_level, is_permanent, note,
     created_at, updated_at, deleted_at, ext)
  SELECT
    id, name, 'park', boundary_line_id, lat, lng,
    vehicle_type, access_level, is_permanent, note,
    created_at, updated_at, deleted_at, ext
  FROM gates;''',
  'DROP TABLE gates;',
  'ALTER TABLE gates_v7 RENAME TO gates;',
  'CREATE INDEX IF NOT EXISTS idx_gates_line ON gates(line_id) WHERE deleted_at IS NULL;',
  'CREATE INDEX IF NOT EXISTS idx_gates_deleted ON gates(deleted_at);',
];

/// v7 → v8 迁移：给点/线/面加「楼层（等高）」（17 章）。
///
/// 三条 `ALTER TABLE ADD COLUMN` 就够 —— **不需要重建表**。
/// 全部用三引号：混用两种定界符会让"按定界符扫语句"的校验脚本漏掉它（v6 已踩过）。
const List<String> userV8Statements = [
  '''
  ALTER TABLE points ADD COLUMN floors TEXT NOT NULL DEFAULT '[1]';''',
  '''
  ALTER TABLE lines ADD COLUMN floors TEXT NOT NULL DEFAULT '[1]';''',
  '''
  ALTER TABLE areas ADD COLUMN floors TEXT NOT NULL DEFAULT '[1]';''',
];

/// v8 → v9 迁移：线支持折线（第十八章）。**只建一张空表**，没有任何数据搬运。
const List<String> userV9Statements = [
  '''
  CREATE TABLE IF NOT EXISTS line_bends (
    line_id INTEGER NOT NULL REFERENCES lines(id),
    seq INTEGER NOT NULL,
    point_id INTEGER NOT NULL REFERENCES points(id),
    PRIMARY KEY (line_id, seq)
  );''',
  '''
  CREATE INDEX IF NOT EXISTS idx_line_bends_point ON line_bends(point_id);''',
];

/// v9 → v10 迁移：路线加「路宽」（第十九章）。一条 `ADD COLUMN`，老路线为 NULL。
const List<String> userV10Statements = [
  '''
  ALTER TABLE lines ADD COLUMN route_width TEXT;''',
];

/// v10 → v11 迁移：点的"处理状态"（第二十二章）。
///
/// ⚠️ `ALTER TABLE ADD COLUMN` **不幂等**，重复执行会报 `duplicate column name`
/// —— 迁移分支必须挂在 `oldV < 11` 上。
const List<String> userV11Statements = [
  '''
  ALTER TABLE points ADD COLUMN processed INTEGER NOT NULL DEFAULT 0;''',
];

/// **v11 → v12 迁移：三层分域**（第二十三章）。这是本项目历史上最大的一次结构改动。
///
/// 7 张按类型混装的表 → 19 张按域分表的表。步骤（本文件 [userV12Statements]
/// 是 DDL 的第一来源；v12 重构当时已在真库副本上逐项实测通过）：
///
/// 0. **闸门**：库必须是 v11；同一条线里不许有重复的点；线不许自我闭合；
/// 1. 建 19 张新表；
/// 2. 活线按 `kind` 分域（route→way / boundary→world / administrative→zone）；
/// 3. 点按域落表 —— **沿用旧 id**，于是线/门/要素的引用一个都不用重映射；
///    只搬"被活线引用"的点（孤立点与无人引用的软删点丢弃），
///    `deleted_at` 一律写 NULL（软删但被引用的点因此**复活**，顺带修好"线画不出来"）；
/// 4. 线按域落三张表；
/// 5. 拐点**重建成链**：顺序 = [起点, 按旧 seq 的拐点…, 终点]，每点记"我的前驱"；
///    旧 `seq` 一个都不搬（真库 `line 22` 缺 `seq=15`，重编号后空洞自然消失）；
/// 6. 区域：**成员里只要有一条不是"活界线"，整个区域丢掉**（区域 1 的环里有 2 条路线）；
/// 7. 门 / 世界要素（`entity_type` 收敛到 5 值）/ 记录点；
/// 8. 自检（端点悬空、链悬空、点数守恒、拐点里混进端点、跨域引用、**链接线**）；
/// 9. 老表改名归档成 `_v11_*`（**不删**，方便逐项对照新旧数据）；
/// 10. 版本号：`PRAGMA user_version` 由 sqflite 按 [schemaVersion] 写，
///     这里只补 `schema_meta.schema_version`。
///
/// **闸门与自检都靠"命名 CHECK 约束"实现**：SQLite 的 `RAISE()` 只能在触发器里用，
/// 而 `SELECT ... FROM 不存在的表` 在 prepare 阶段就会失败（WHERE 拦不住），
/// 所以「插一行注定违反 CHECK 的数据」是唯一能在纯 SQL 里可靠中止事务的办法。
/// 它抛出的异常会让整个 `onUpgrade` 事务回滚 —— **库保持 v11，什么都没发生**。
const List<String> userV12Statements = [
  // ---- 0. 闸门 ----
  '''
  CREATE TEMP TABLE _gate_version (
    v INTEGER NOT NULL,
    CONSTRAINT 库必须正好是_v11 CHECK (v = 11)
  );''',
  'INSERT INTO _gate_version(v) SELECT * FROM pragma_user_version;',
  '''
  CREATE TEMP TABLE _gate_dup (
    n INTEGER NOT NULL,
    CONSTRAINT 同一条线里有重复的点 CHECK (n = 0)
  );''',
  '''
  INSERT INTO _gate_dup(n)
  SELECT COUNT(*) FROM (
    SELECT line_id, point_id FROM (
        SELECT id AS line_id, start_point_id AS point_id FROM lines WHERE deleted_at IS NULL
        UNION ALL SELECT id, end_point_id FROM lines WHERE deleted_at IS NULL
        UNION ALL SELECT b.line_id, b.point_id FROM line_bends b
                   JOIN lines l ON l.id = b.line_id WHERE l.deleted_at IS NULL
    ) GROUP BY line_id, point_id HAVING COUNT(*) > 1
  );''',
  '''
  CREATE TEMP TABLE _gate_loop (
    n INTEGER NOT NULL,
    CONSTRAINT 线不能自己闭合 CHECK (n = 0)
  );''',
  '''
  INSERT INTO _gate_loop(n)
  SELECT COUNT(*) FROM lines WHERE deleted_at IS NULL AND start_point_id = end_point_id;''',
  '''CREATE TEMP TABLE _now AS
     SELECT CAST(strftime('%s', 'now') AS INTEGER) * 1000 AS ms;''',

  // ---- 1. 建 19 张新表 ----
  // 复用 schemaStatements：**新库与老库升级走同一份 DDL**，
  // 这样"两条路径必须逐列一致"这件事不再靠人眼（历史上 v6/v8 都踩过）。
  ...schemaStatements,

  // ---- 2. 活线 + 域 ----
  '''
  CREATE TEMP TABLE _mig_lines AS
  SELECT l.id AS line_id,
         CASE l.kind
           WHEN 'route'          THEN 'way'
           WHEN 'boundary'       THEN 'world'
           WHEN 'administrative' THEN 'zone'
           ELSE 'world'
         END AS domain,
         l.start_point_id, l.end_point_id
  FROM lines l WHERE l.deleted_at IS NULL;''',
  '''
  CREATE TEMP TABLE _mig_point_domain AS
  SELECT DISTINCT point_id, domain FROM (
      SELECT start_point_id AS point_id, domain FROM _mig_lines
      UNION ALL SELECT end_point_id, domain FROM _mig_lines
      UNION ALL SELECT b.point_id, m.domain
                FROM line_bends b JOIN _mig_lines m ON m.line_id = b.line_id
  );''',

  // ---- 3. 点按域落表（沿用旧 id）----
  '''
  INSERT INTO way_points (id, lat, lng, floors, created_at, updated_at, deleted_at)
  SELECT p.id, p.lat, p.lng, COALESCE(p.floors, '[1]'),
         COALESCE(p.updated_at, (SELECT ms FROM _now)), COALESCE(p.updated_at, (SELECT ms FROM _now)), NULL
  FROM points p JOIN _mig_point_domain d ON d.point_id = p.id
  WHERE d.domain = 'way';''',
  '''
  INSERT INTO world_points (id, lat, lng, floors, created_at, updated_at, deleted_at)
  SELECT p.id, p.lat, p.lng, COALESCE(p.floors, '[1]'),
         COALESCE(p.updated_at, (SELECT ms FROM _now)), COALESCE(p.updated_at, (SELECT ms FROM _now)), NULL
  FROM points p JOIN _mig_point_domain d ON d.point_id = p.id
  WHERE d.domain = 'world';''',
  '''
  INSERT INTO zone_points (id, lat, lng, floors, created_at, updated_at, deleted_at)
  SELECT p.id, p.lat, p.lng, COALESCE(p.floors, '[1]'),
         COALESCE(p.updated_at, (SELECT ms FROM _now)), COALESCE(p.updated_at, (SELECT ms FROM _now)), NULL
  FROM points p JOIN _mig_point_domain d ON d.point_id = p.id
  WHERE d.domain = 'zone';''',

  // ---- 4. 线按域落表 ----
  '''
  INSERT INTO way_lines (id, name, floors, start_point_id, end_point_id,
                         route_width, one_way, cost_class, note,
                         created_at, updated_at, deleted_at)
  SELECT l.id, l.name, COALESCE(l.floors, '[1]'), l.start_point_id, l.end_point_id,
         l.route_width, COALESCE(l.one_way, 0), l.cost_class, l.note,
         COALESCE(l.updated_at, (SELECT ms FROM _now)), COALESCE(l.updated_at, (SELECT ms FROM _now)), NULL
  FROM lines l WHERE l.deleted_at IS NULL AND l.kind = 'route';''',
  '''
  INSERT INTO world_lines (id, name, floors, start_point_id, end_point_id,
                           boundary_type, note, created_at, updated_at, deleted_at)
  SELECT l.id, l.name, COALESCE(l.floors, '[1]'), l.start_point_id, l.end_point_id,
         l.boundary_type, l.note,
         COALESCE(l.updated_at, (SELECT ms FROM _now)), COALESCE(l.updated_at, (SELECT ms FROM _now)), NULL
  FROM lines l WHERE l.deleted_at IS NULL AND l.kind = 'boundary';''',
  '''
  INSERT INTO zone_lines (id, name, floors, start_point_id, end_point_id,
                          note, created_at, updated_at, deleted_at)
  SELECT l.id, l.name, COALESCE(l.floors, '[1]'), l.start_point_id, l.end_point_id,
         l.note,
         COALESCE(l.updated_at, (SELECT ms FROM _now)), COALESCE(l.updated_at, (SELECT ms FROM _now)), NULL
  FROM lines l WHERE l.deleted_at IS NULL AND l.kind = 'administrative';''',

  // ---- 5. 拐点重建成链 ----
  '''
  CREATE TEMP TABLE _mig_seq AS
  SELECT line_id, point_id, rn, cnt FROM (
    SELECT line_id, point_id, pos,
           ROW_NUMBER() OVER (PARTITION BY line_id ORDER BY pos) AS rn,
           COUNT(*)     OVER (PARTITION BY line_id)              AS cnt
    FROM (
        SELECT line_id, 0 AS pos, start_point_id AS point_id FROM _mig_lines
        UNION ALL
        SELECT m.line_id, b.seq, b.point_id
          FROM line_bends b JOIN _mig_lines m ON m.line_id = b.line_id
        UNION ALL
        SELECT line_id, 2000000000, end_point_id FROM _mig_lines
    )
  );''',
  '''
  INSERT INTO way_line_bends (line_id, point_id, before_point_id)
  SELECT s.line_id, s.point_id, p.point_id
  FROM _mig_seq s
  JOIN _mig_seq p ON p.line_id = s.line_id AND p.rn = s.rn - 1
  JOIN _mig_lines m ON m.line_id = s.line_id
  WHERE m.domain = 'way' AND s.rn >= 2 AND s.rn < s.cnt;''',
  '''
  INSERT INTO world_line_bends (line_id, point_id, before_point_id)
  SELECT s.line_id, s.point_id, p.point_id
  FROM _mig_seq s
  JOIN _mig_seq p ON p.line_id = s.line_id AND p.rn = s.rn - 1
  JOIN _mig_lines m ON m.line_id = s.line_id
  WHERE m.domain = 'world' AND s.rn >= 2 AND s.rn < s.cnt;''',
  '''
  INSERT INTO zone_line_bends (line_id, point_id, before_point_id)
  SELECT s.line_id, s.point_id, p.point_id
  FROM _mig_seq s
  JOIN _mig_seq p ON p.line_id = s.line_id AND p.rn = s.rn - 1
  JOIN _mig_lines m ON m.line_id = s.line_id
  WHERE m.domain = 'zone' AND s.rn >= 2 AND s.rn < s.cnt;''',

  // ---- 6. 区域：成员里只要有一条不是"活界线"，整个区域丢掉 ----
  '''
  INSERT INTO world_areas (id, name, area_type, floors, color_override, sort_order,
                           created_at, updated_at, deleted_at)
  SELECT a.id, a.name, COALESCE(a.area_type, 'community'), COALESCE(a.floors, '[1]'),
         a.color_override, COALESCE(a.sort_order, 0),
         COALESCE(a.updated_at, (SELECT ms FROM _now)), COALESCE(a.updated_at, (SELECT ms FROM _now)), NULL
  FROM areas a
  WHERE a.deleted_at IS NULL
    AND a.area_type <> 'administrative'
    AND NOT EXISTS (
          SELECT 1 FROM area_lines al
          LEFT JOIN lines l
                 ON l.id = al.line_id AND l.deleted_at IS NULL AND l.kind = 'boundary'
          WHERE al.area_id = a.id AND l.id IS NULL
        );''',
  '''
  INSERT INTO zone_areas (id, name, floors, color_override, sort_order,
                          created_at, updated_at, deleted_at)
  SELECT a.id, a.name, COALESCE(a.floors, '[1]'),
         a.color_override, COALESCE(a.sort_order, 0),
         COALESCE(a.updated_at, (SELECT ms FROM _now)), COALESCE(a.updated_at, (SELECT ms FROM _now)), NULL
  FROM areas a
  WHERE a.deleted_at IS NULL
    AND a.area_type = 'administrative'
    AND NOT EXISTS (
          SELECT 1 FROM area_lines al
          LEFT JOIN lines l
                 ON l.id = al.line_id AND l.deleted_at IS NULL AND l.kind = 'administrative'
          WHERE al.area_id = a.id AND l.id IS NULL
        );''',
  // 关联表：丢掉 sort_order（D14）
  '''
  INSERT INTO world_area_lines (area_id, line_id)
  SELECT al.area_id, al.line_id
  FROM area_lines al
  JOIN world_areas wa ON wa.id = al.area_id
  JOIN world_lines wl ON wl.id = al.line_id;''',
  '''
  INSERT INTO zone_area_lines (area_id, line_id)
  SELECT al.area_id, al.line_id
  FROM area_lines al
  JOIN zone_areas za ON za.id = al.area_id
  JOIN zone_lines zl ON zl.id = al.line_id;''',

  // ---- 7. 门 / 世界要素 / 记录点 ----
  '''
  INSERT INTO world_gates (id, name, gate_type, line_id, lat, lng,
                           vehicle_type, access_level, is_permanent, note,
                           created_at, updated_at, deleted_at)
  SELECT g.id, g.name, COALESCE(g.gate_type, 'park'),
         CASE WHEN EXISTS (SELECT 1 FROM world_lines wl WHERE wl.id = g.line_id)
              THEN g.line_id ELSE NULL END,
         g.center_lat, g.center_lng,
         COALESCE(g.vehicle_type, 'all'), COALESCE(g.access_level, 'free'),
         COALESCE(g.is_permanent, 1), g.note,
         COALESCE(g.updated_at, (SELECT ms FROM _now)), COALESCE(g.updated_at, (SELECT ms FROM _now)), NULL
  FROM gates g
  WHERE g.deleted_at IS NULL;''',
  // entity_type 收敛：door/stall → shop；wall / gate_landmark 丢弃；认不出的兜底 delivery_point
  '''
  INSERT INTO world_entities (id, entity_type, name, door_no, desc, line_id, lat, lng,
                              width, note, created_at, updated_at, deleted_at)
  SELECT e.id,
         CASE e.entity_type
           WHEN 'shop' THEN 'shop'
           WHEN 'door' THEN 'shop'
           WHEN 'stall' THEN 'shop'
           WHEN 'building' THEN 'building'
           WHEN 'unit' THEN 'unit'
           WHEN 'parking' THEN 'parking'
           WHEN 'delivery_point' THEN 'delivery_point'
           ELSE 'delivery_point'
         END,
         e.name, e.door_no, e.desc,
         CASE WHEN EXISTS (SELECT 1 FROM world_lines wl WHERE wl.id = e.line_id)
              THEN e.line_id ELSE NULL END,
         COALESCE(e.center_lat, (SELECT p.lat FROM points p WHERE p.id = e.point_id)),
         COALESCE(e.center_lng, (SELECT p.lng FROM points p WHERE p.id = e.point_id)),
         e.width, NULL,
         COALESCE(e.updated_at, (SELECT ms FROM _now)), COALESCE(e.updated_at, (SELECT ms FROM _now)), NULL
  FROM entities e
  WHERE e.deleted_at IS NULL
    AND COALESCE(e.entity_type, '') NOT IN ('wall', 'gate_landmark')
    AND COALESCE(e.center_lat, (SELECT p.lat FROM points p WHERE p.id = e.point_id)) IS NOT NULL
    AND COALESCE(e.center_lng, (SELECT p.lng FROM points p WHERE p.id = e.point_id)) IS NOT NULL;''',
  '''
  INSERT INTO world_marks (id, name, lat, lng, floors, accuracy, by_gps, processed, note,
                           created_at, updated_at, deleted_at)
  SELECT p.id, p.name, p.lat, p.lng, COALESCE(p.floors, '[1]'), p.accuracy,
         CASE WHEN p.source = 'gps' THEN 1 ELSE 0 END,
         COALESCE(p.processed, 0), NULL,
         COALESCE(p.updated_at, (SELECT ms FROM _now)), COALESCE(p.updated_at, (SELECT ms FROM _now)), NULL
  FROM points p
  WHERE p.deleted_at IS NULL
    AND p.source IN ('recorded', 'gps')
    AND p.id NOT IN (SELECT point_id FROM _mig_point_domain);''',
  // ⚠️ way_marks（行驶轨迹）：老库没有轨迹采集，**没有来源，保持空表**。

  // ---- 8. 自检（任何一条不过 → 抛异常 → 整个 onUpgrade 事务回滚）----
  '''
  CREATE TEMP TABLE _chk_endpoint (
    n INTEGER NOT NULL,
    CONSTRAINT 线有悬空的端点 CHECK (n = 0)
  );''',
  '''
  INSERT INTO _chk_endpoint(n)
  SELECT (SELECT COUNT(*) FROM way_lines l   LEFT JOIN way_points   p ON p.id = l.start_point_id WHERE p.id IS NULL)
       + (SELECT COUNT(*) FROM way_lines l   LEFT JOIN way_points   p ON p.id = l.end_point_id   WHERE p.id IS NULL)
       + (SELECT COUNT(*) FROM world_lines l LEFT JOIN world_points p ON p.id = l.start_point_id WHERE p.id IS NULL)
       + (SELECT COUNT(*) FROM world_lines l LEFT JOIN world_points p ON p.id = l.end_point_id   WHERE p.id IS NULL)
       + (SELECT COUNT(*) FROM zone_lines l  LEFT JOIN zone_points  p ON p.id = l.start_point_id WHERE p.id IS NULL)
       + (SELECT COUNT(*) FROM zone_lines l  LEFT JOIN zone_points  p ON p.id = l.end_point_id   WHERE p.id IS NULL);''',
  '''
  CREATE TEMP TABLE _chk_bend (
    n INTEGER NOT NULL,
    CONSTRAINT 拐点链有悬空引用 CHECK (n = 0)
  );''',
  '''
  INSERT INTO _chk_bend(n)
  SELECT (SELECT COUNT(*) FROM way_line_bends b   LEFT JOIN way_points   p ON p.id = b.point_id        WHERE p.id IS NULL)
       + (SELECT COUNT(*) FROM way_line_bends b   LEFT JOIN way_points   p ON p.id = b.before_point_id WHERE p.id IS NULL)
       + (SELECT COUNT(*) FROM world_line_bends b LEFT JOIN world_points p ON p.id = b.point_id        WHERE p.id IS NULL)
       + (SELECT COUNT(*) FROM world_line_bends b LEFT JOIN world_points p ON p.id = b.before_point_id WHERE p.id IS NULL)
       + (SELECT COUNT(*) FROM zone_line_bends b  LEFT JOIN zone_points  p ON p.id = b.point_id        WHERE p.id IS NULL)
       + (SELECT COUNT(*) FROM zone_line_bends b  LEFT JOIN zone_points  p ON p.id = b.before_point_id WHERE p.id IS NULL);''',
  '''
  CREATE TEMP TABLE _chk_chain (
    bad INTEGER NOT NULL,
    CONSTRAINT 拐点链断链 CHECK (bad = 0)
  );''',
  '''
  INSERT INTO _chk_chain(bad)
  SELECT COUNT(*) FROM (
    SELECT l.id FROM way_lines l
    LEFT JOIN way_line_bends b ON b.line_id = l.id
    GROUP BY l.id
    HAVING (SELECT COUNT(*) FROM _mig_seq s JOIN _mig_lines m ON m.line_id = s.line_id
             WHERE s.line_id = l.id AND m.domain = 'way') <> COUNT(b.point_id) + 2
  );''',
  '''
  CREATE TEMP TABLE _chk_endpoint_in_bends (
    n INTEGER NOT NULL,
    CONSTRAINT 拐点表里混进了端点 CHECK (n = 0)
  );''',
  '''
  INSERT INTO _chk_endpoint_in_bends(n)
  SELECT (SELECT COUNT(*) FROM way_line_bends b   JOIN way_lines l   ON l.id = b.line_id
           WHERE b.point_id IN (l.start_point_id, l.end_point_id))
       + (SELECT COUNT(*) FROM world_line_bends b JOIN world_lines l ON l.id = b.line_id
           WHERE b.point_id IN (l.start_point_id, l.end_point_id))
       + (SELECT COUNT(*) FROM zone_line_bends b  JOIN zone_lines l  ON l.id = b.line_id
           WHERE b.point_id IN (l.start_point_id, l.end_point_id));''',
  '''
  CREATE TEMP TABLE _chk_area_lines (
    n INTEGER NOT NULL,
    CONSTRAINT 区域成员跨域 CHECK (n = 0)
  );''',
  '''
  INSERT INTO _chk_area_lines(n)
  SELECT (SELECT COUNT(*) FROM world_area_lines al LEFT JOIN world_lines wl ON wl.id = al.line_id WHERE wl.id IS NULL)
       + (SELECT COUNT(*) FROM zone_area_lines al  LEFT JOIN zone_lines  zl ON zl.id = al.line_id WHERE zl.id IS NULL);''',
  '''
  CREATE TEMP TABLE _chk_anchor (
    n INTEGER NOT NULL,
    CONSTRAINT 门或要素锚点跨域 CHECK (n = 0)
  );''',
  '''
  INSERT INTO _chk_anchor(n)
  SELECT (SELECT COUNT(*) FROM world_gates g
           WHERE g.line_id IS NOT NULL AND g.line_id NOT IN (SELECT id FROM world_lines))
       + (SELECT COUNT(*) FROM world_entities e
           WHERE e.line_id IS NOT NULL AND e.line_id NOT IN (SELECT id FROM world_lines));''',
  // 链的**接线**：每个 before 必须是"本线起点"或"本线另一个拐点"，且 before=起点 的恰好一个
  '''
  CREATE TEMP TABLE _chk_wire (
    n INTEGER NOT NULL,
    CONSTRAINT 拐点链接线错误 CHECK (n = 0)
  );''',
  '''
  INSERT INTO _chk_wire(n)
  SELECT
    (SELECT COUNT(*) FROM way_line_bends b JOIN way_lines l ON l.id = b.line_id
      WHERE b.before_point_id <> l.start_point_id
        AND b.before_point_id NOT IN (SELECT point_id FROM way_line_bends b2 WHERE b2.line_id = b.line_id))
  + (SELECT COUNT(*) FROM world_line_bends b JOIN world_lines l ON l.id = b.line_id
      WHERE b.before_point_id <> l.start_point_id
        AND b.before_point_id NOT IN (SELECT point_id FROM world_line_bends b2 WHERE b2.line_id = b.line_id))
  + (SELECT COUNT(*) FROM zone_line_bends b JOIN zone_lines l ON l.id = b.line_id
      WHERE b.before_point_id <> l.start_point_id
        AND b.before_point_id NOT IN (SELECT point_id FROM zone_line_bends b2 WHERE b2.line_id = b.line_id))
  + (SELECT COUNT(*) FROM (SELECT l.id FROM way_lines l JOIN way_line_bends b ON b.line_id = l.id
      GROUP BY l.id HAVING SUM(CASE WHEN b.before_point_id = l.start_point_id THEN 1 ELSE 0 END) <> 1))
  + (SELECT COUNT(*) FROM (SELECT l.id FROM world_lines l JOIN world_line_bends b ON b.line_id = l.id
      GROUP BY l.id HAVING SUM(CASE WHEN b.before_point_id = l.start_point_id THEN 1 ELSE 0 END) <> 1))
  + (SELECT COUNT(*) FROM (SELECT l.id FROM zone_lines l JOIN zone_line_bends b ON b.line_id = l.id
      GROUP BY l.id HAVING SUM(CASE WHEN b.before_point_id = l.start_point_id THEN 1 ELSE 0 END) <> 1));''',

  // ---- 9. 老表归档（**不删**：方便逐项对照新旧数据；验收完再手动 DROP）----
  'ALTER TABLE points     RENAME TO _v11_points;',
  'ALTER TABLE lines      RENAME TO _v11_lines;',
  'ALTER TABLE line_bends RENAME TO _v11_line_bends;',
  'ALTER TABLE areas      RENAME TO _v11_areas;',
  'ALTER TABLE area_lines RENAME TO _v11_area_lines;',
  'ALTER TABLE gates      RENAME TO _v11_gates;',
  'ALTER TABLE entities   RENAME TO _v11_entities;',

  // ---- 10. schema_meta 里的版本（PRAGMA user_version 由 sqflite 写）----
  "INSERT OR REPLACE INTO schema_meta (key, value) VALUES ('schema_version', '12');",
];

/// schema_version 元数据表（供迁移/导出判断）。
const String schemaMetaTable = '''
CREATE TABLE IF NOT EXISTS schema_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);''';
