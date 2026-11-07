# 第二十三章 数据结构重构：三层分域（路网 / 世界图 / 行政区域）

> **状态：设计已定，未实施。** 本章只定义**目标数据结构与迁移方案**，本轮不动任何代码。
> 决策日期 2026-09-14（会话：数据结构重构讨论）。
>
> 所有依据都来自用户本机真库 `~/.local/share/com.example.map/map.db`
> （`user_version = 11`）的**实测数字**，不是估算。凡标「实测」的数字都可以用 §12 的
> SQL 原样复现。
>
> **与前面各章的关系**：本章**取代** 03 章那套 v1 时代的「三层结构 + 点/线/实体表」，
> 并**收编** 12~22 章逐轮累加在 schema 上的补丁（v4~v11）。
> 实施后 `lib/core/schema.dart` 的 **v12** 是唯一真相，旧迁移语句归档不再执行。

---

## 1. 为什么要重构

### 1.1 现状：7 张表，两张几乎是空的

| 表 | 行数（实测） | 定位 | 谁在写 |
|----|------|------|--------|
| `points` | 698（活 686 / 软删 12） | 几何点 **+** 独立点 | 编辑标点 / 记录模式 |
| `line_bends` | 470 | 折线拐点 | 编辑加拐点 |
| `lines` | 62（活 52 / 软删 10） | 界线 5 + 路线 57 | 编辑连线 |
| `areas` | 2 | 区块（1 道路 + 1 建筑） | 编辑围合 |
| `area_lines` | 8 | 区块 ⇄ 线 | — |
| `entities` | **1** | 店铺 / 墙体段 | 线上要素表单 |
| `gates` | **1** | 门 | 门表单 |

引用完整性全绿（悬空引用 0）。**问题不在数据，在结构。**

### 1.2 六个结构性问题

**P1 同一个概念有两套互不相通的表示。**
门既是 `gates` 表、又是 `points.kind='gate'`；店铺既是 `entities.entity_type='shop'`、
又是 `points.kind='shop'`。而实测 `points.kind` **只有** `auxiliary`(689) 与 `waypoint`(9)，
`shop`/`gate` 是 **0 行**；`PointKind.shop`/`PointKind.gate` 在 `lib/` 里**零引用**
（芯片画得出来：`feature_forms.dart:436`、`map_page.dart:1983`，但 `core/` 从没按它分岔过）。
代价：门不能当线端点、不能被吸附、不能做拐点、不在点面板里；每加一个功能都要在
「点 / 线上要素 / 门」三条路上各写一遍。

**P2 折线的形状有三个真相 —— 但本轮决定「保留」。**
`lines.start_point_id` + `line_bends(seq)` + `lines.end_point_id`。端点没有 `seq`，
所以「插到中间」与「插到开头/结尾」原本是两条不同的代码路径（20 章的 `planBendInsertion`
只管中间）。爆炸半径实测：`startPointId/endPointId` 共 **79 处引用、10 个文件**。

用户 2026-09-14 明确：**保留 line 的端点特殊性**（D4）—— 端点承载「这条线从哪到哪」
这个身份（业务键就含端点），而拐点只是形状。所以本条不再当作"要消除的问题"，
而是**要靠约束守住的既有结构**：三处存储仍然存在，但「这条线长什么样」必须**只有一个读出口**
（`LineRow.pointIds` → `core/polyline.dart`，18 章已经收口），
而拐点那一处**换成链**（D13）：它把"插入/删除"从"整段重编号"变成 O(1) 指针操作，
代价是链的完整性（无环、恰好一个头、能走到 end）**SQL 约束不了**，得靠自检脚本 + 读链保护（§6.3）。

**P3 `points` 是「几何点」和「世界点」的混装。**
判定角色靠的不是字段，而是「有没有线引用它」。22 章不得不给 `source` 补一个 `recorded`
值来打补丁。实测：686 个活点里 **147 个不被任何活线引用**（含 12 个只被已删线引用）——
按红线「连线只吸附已有点」，它们其实是**连线前的暂存点**，但结构上与「我记录的点」
长得一模一样。

**P4 属性列按类型分岔，却共处一张表。**
`lines` 有 4 个互斥语义的属性列，实测：

| 列 | 有值行数 | 语义 | 只对谁有意义 |
|----|---------|------|-------------|
| `boundary_type` | 5（全是 `wall`） | 材质 | 界线 |
| `route_width` | 24（main 10 / crossing 8 / fenced 6） | 路宽 | 路线 |
| `cost_class` | 33（ride 30 / walk 3） | 通行代价（**已冻结**） | 路线 |
| `one_way` | 23 条 = 1 | 单行 | 路线 |

**P5 一批列设计了但从未落地。** 实测：

- `points.created_at` / `lines.created_at`：**0 行有值**（`toDb()` 只在非 null 时写，
  而 `lib/data`、`lib/features` 里**没有任何地方赋过 `createdAt:`**）→ 审计从未生效；
- `ext`：0/698、0/62、0/2；
- `points.accuracy`：0（Linux 无定位）；`entities.tags/desc/door_no/point_id/gate_id`：全 0；
- `areas.dismantle_date` / `color_override`：0；`is_active`：全 1；
- `points.name`：14 行非空但**真名字 0 个**（全是空串）；对照 `lines.name` 有 **27 个真名字**；
- `floors`：**698/698、62/62、2/2 全是 `[1]`** —— 17 章整套楼层机制目前零真实数据；
- `area_lines.sort_order`：**有值，但不参与任何几何**。真库取值确实是"点选次序"
  （区域 1 = `5→7→1→6`，恰好构成一条连续的路），可是组环器按**边**建图遍历、**不读它**，
  唯一消费方是导出数组的顺序；而写它的 `setAreaLines` **在 `lib/` 里没有任何调用者**（D14）。

**P6 迁移路径分叉。**
新库走 `schemaStatements`、老库走 `userV3..userV11` 九段迁移，两条路必须逐列一致；
`schema.dart` 639 行里约 300 行是历史，且已踩过两次坑（v6 漏 `ADD COLUMN`、v8 引号被扫描漏掉）。

### 1.3 一个正在发生的事故（重构的直接收益之一）

`lines.id = 3` 与 `4` 的端点里各有一个**已被软删的点**（`points.id = 8 / 9 / 11`）：

```
line 3: start=8(软删) end=9(软删)
line 4: start=10        end=11(软删)
```

而 `listPointsByIds`（`app_repository.dart:678`）会过滤软删点 →
`polylineOf` 缺任何一个点的坐标就返回 null（红线 8）→ `map_page.dart:1397` 直接 `continue`。

**结论：这两条路线现在在地图上根本画不出来，而且不报错、不崩溃。**
根因是「点没有生命周期」——删点不检查引用，删完也没人发现。
新设计用「删点必须检查引用 + 本域孤立点清理」把这类问题变成可自检的（§6）。

### 1.4 本轮已拍板的决策（D1~D12）

> 全部由用户在本轮会话中拍板。正文各处的 `（D n）` 引用都指这张表。

| # | 决策 | 被否决的选项 / 备注 |
|---|------|-------------------|
| **D1** | **真物理分表**：路网 / 世界图 / 行政区域**各一套表**，共 16 张 | 否决「一张物理表 + `layer` 列 + 三个图层视图」（语义等价、DAO 只写一份，但用户要的是真隔离）；否决「只分点表、线/区域共用」（点要 `(layer,id)` 双列引用，外键无法约束） |
| **D2** | **彻底禁止跨域引用**：吸附与命中只在当前域内 | 否决「允许要素点挂别域的线」、否决「保留跨域共享点」。代价：跨域连接今后靠 M2 建图按坐标容差处理 |
| **D3** | **门 / 店铺 / 记录点归世界域**；原 4 个跨域共享点**复制成两行** | 用户原话：「门/店铺/记录点属于世界图的数据域」 |
| **D4** | **保留 line 的端点特殊性**：`<域>_lines` 仍带 `start_point_id` / `end_point_id` 两列（`NOT NULL` + 外键）。点序列由 `LineRow.pointIds` 派生 | 用户 2026-09-14 明确「保留 line 的端点特殊性」。**被否决**：把端点并入拐点表 —— 那样端点的 `NOT NULL`/外键/索引都得靠应用层补，还会引入"点 < 2 的空线"这个本来不存在的失效模式 |
| **D5** | **删墙体段**（`entities.entity_type='wall'`，真库 0 行）；`cost_class` **留列留数据、继续冻结**；`ext` 与 `areas.dismantle_date` 删除 | 依据见 P5：这些列全 0 行且语义已死；而 `cost_class` 有 33 行真数据 |
| **D6** | **审计时间真写**：`created_at` / `updated_at` 一律 `NOT NULL` 并由 DAO 实际赋值 | 今天的 `points`/`lines` 两列**从未写过**（P5） |
| **D7** | **迁移时清理垃圾**：147 个孤立点 + 9 个软删且无人引用的点 + 10 条软删线 | 用户授权。爆炸半径与回滚见 §7.1 |
| **D8** | **放弃区域 1**（那 2 条"路线边"不回填、不搬家） | 见 §7.5。代价：丢 1 个区域（`areas` 2 → 1），**不丢任何线** |
| **D9** | **点表不带 `name`** | 实测 0 个真名字（P5）；要给位置起名就用世界域要素 |
| **D10** | **「删端点」与「删点」是两个动作**：删端点只改线的构成（点行不动、影响 1 条线）；删点要反查并报出「会影响 N 条线」由用户确认 | 今天 `softDeletePoint` 把两者揉在一起、且两边都做错（§4.4） |
| **D11** | **一条线至少 2 个点**；删到不足 2 时**拒绝落库**，并建议改成「删这条线」 | 因为 D4 保留了两列 `NOT NULL`，「点数 ≥ 2」**在结构上自动成立**；D11 守的是**操作层**——删端点要靠"相邻拐点顶上"，没有拐点可顶时必须拦住 |
| **D12** | **孤立点不自动回收**，只在编辑模式里提供手动「清理孤立点」（先报数字再删） | 与 D7 分工：D7 管迁移时的一次性清理，D12 管运行时 |
| **D13** | **拐点存成链表**：`<域>_line_bends(line_id, point_id, before_point_id)` —— 每行记「我的前驱」而不是「我是第几个」。插入/删除变成 O(1) 指针操作，**不再整段重编号**，`seq` 列取消 | 用户 2026-09-14 明确。取代最初设想的 `(line_id, seq, point_id)`。**读取不受影响**：全表平查 + 内存按 `before → point` 组装即可，不需要递归 CTE（§4.4） |
| **D14** | **关联表不存顺序**：`<域>_area_lines` **删掉 `sort_order`**，只留 `(area_id, line_id)` | 依据：组环器（`ring.dart`）按**边**建图遍历，**不读顺序** —— 顺序的真正权威是几何。原列只在创建时写一次（`setAreaLines` 从无调用者），唯一消费方是导出的 `line_ids` 数组顺序。代价：备份里 `line_ids` 改按 `line_id` 升序（同样确定；对合并无影响，`merge` 用集合/键判等） |
| **D15** | **新增轨迹表 `way_marks`**（路网域）：**一行 = 一个采样点** + `trip` 分组键 | 否决「一行 = 一段、几何内嵌 JSON」：记录是**流式**的，每秒一条 `INSERT` 才 O(1) 且崩溃安全；一行一段就得每秒重写整个 blob（写放大），App 被杀则**整段丢失**。否决「另建 `way_trips` 表」：本轮只要一张表（`trip` 键留了升级余地，见 §4.1） |
| **D16** | **采集时不过滤**：1 Hz **原样全落**，抽稀与降噪留到「转成路线」那一刻 | 依据 `docs/requirements.md` 第 2 条（每秒更新一次）。代价：等红灯会堆同坐标点、半小时一趟约 1800 行 —— 所以 `accuracy` 必须存下来，供转换时剔坏点 |
| **D17** | **一段的边界只由「开始记录 / 停止记录」决定**，GPS 中断（进地下室、隧道）**不断段** | 与"手动点开始/结束"的编辑习惯一致；中断只在数据里留下时间空洞（转换时看得见）。否决「按时间间隔自动断段」—— 推断结果会随参数变化，不可复现 |
| **D18** | **`world_entities` 带 `entity_type`**：店铺 / 楼栋 / 单元 / 常送点 / 停车点（**去掉**已删的 `wall` 与从未用过的 `gate_landmark`） | 与 `world_areas.area_type` 同构 —— 这些类型**列完全相同**，共用一张表；而门单独一张（列集不同）。⚠️ 业务键因此必须带类型（§8.1），否则同名的店铺与停车点会互相顶掉 |
| **D19** | **新增 `world_polygons` + `world_polygon_points`**：与 `world_areas` **同一语义、两种构造** —— area 由**线**围成、polygon 由**点**围成。**必须提供双向转换** | 判据一句话：**这条边需要单独设属性、挂东西、或被别处共用吗？需要 → area，不需要 → polygon**。实测依据：真库那 5 条界线**全是 2 点直线、0 拐点**，两个区域的环就是 4 条这样的线拼的四边形 —— 几何上 area 与 polygon 可以完全一样，差别只在"边是不是一等公民"（详情见 §4.5）。否决「不加新表、在 `world_areas` 里加构造方式字段」
| **D20** | 多边形的环也存成**链**：`world_polygon_points(polygon_id, point_id, before_point_id)` | 与 D13 同一套写法，O(1) 增删。**封闭环比路径更干净：环没有头** —— 不变量是「从任意一点走 N 步必须回到起点」（N = 行数），不需要"恰好一个头"那一条（§4.5） |
| **D21** | **门与要素只能挂线**；polygon **挂不上**门/要素 —— 要挂就先转成 area | `world_gates.line_id` / `world_entities.line_id` 保持**单一锚点**，于是定位、吸附、校验、导出全不用分支。若允许挂 polygon，就得把锚点变成**多态**，而 `locateOnLine` 那套红线（三者的定位必须走同一个函数）要再复制一套 |

---

## 2. 三个域的定义

沿 19 章既有的图层划分（用户原话：编辑界面分**路网、世界图、行政区域**三种地图图层），
把它从「编辑界面的组织方式」升级为**数据的组织方式**：

| 域 | 表前缀 | 描述什么世界 | 包含 |
|----|--------|-------------|------|
| **路网** | `way_` | 我自己跑的路 | 路线（可拐弯、带路宽/单行）与其点；**我自己的行驶轨迹** |
| **世界图** | `world_` | 现实世界的客观实体 | 界线（围墙/铁栏/河道）、区域（小区/建筑/道路/阻隔）、**门、世界要素（店铺等）、记录点**、拼线点 |
| **行政区域** | `zone_` | 虚拟的行政边界 | 行政线、行政区域与其点 |

三条贯穿全章的规则：

1. **每个域自带一整套表**（点 / 线 / 拐点链；世界与行政另有区域与区域⇄线）；
2. **域之间零引用** —— 一条线只能引用本域点，门/店铺只能挂本域的线；
3. **域由表名表达，不由字段表达** —— 这是本章最大的一处简化（见 §5）。

> ⚠️ **别和底图 pack 的 `import_ways` 搞混**：那是 OSM 导入层的只读表（在 pack 文件里，
> 经 `ATTACH` 挂上），`way_*` 是**用户路网域**（在 `user.db` 里、可写）。
> 两者唯一的共同点是名字里都有 "way"。

---

## 3. 目标结构：19 张表

```
路网域  way_points ──┬─< way_line_bends（before 链）>── way_lines
                     └─── way_lines.start/end_point_id ──> way_points（端点是两列）
        way_marks ← **我自己的行驶轨迹**（D15）：一行一个采样点，按 `trip` 分段，
                    不引用任何表（连点也不是）

世界域  world_points ──┬─< world_line_bends >── world_lines ──< world_area_lines >── world_areas
                       │                            │                                 （由线围成）
                       │                            └─── world_gates / world_entities 锚定在这
                       └─< world_polygon_points（before 环链）>── world_polygons（由点围成）
                        world_marks（记录点，可空 line_id）

行政域  zone_points ──┬─< zone_line_bends >── zone_lines ──< zone_area_lines >── zone_areas
                      └─── zone_lines.start/end_point_id ──> zone_points
```

**19 张表**：路网 4 + 世界 10 + 行政 5。

**两种封闭图形**（D19）：`world_areas` **由线围成**（边是共享的线，有材质、能挂门）、
`world_polygons` **由点围成**（边没有实体）。两者**同一语义、可互相转换**（§4.5），
判据是「这条边要不要单独设属性 / 挂东西 / 被别处共用」。

**端点的特殊性（D4）**：`<域>_lines` 带 `start_point_id` / `end_point_id` 两列（`NOT NULL` + 外键），
**拐点才在 `<域>_line_bends` 里 —— 而且是链**（D13）：每行记「我的前驱」。
点序列是**派生**的：`start →（沿 before 关系走）→ end`（出口仍是 `LineRow.pointIds`）。

**轨迹不是几何**（D15）：`way_marks` 的点**不进** `way_points`，也**不参与吸附**。
它是**原始采集数据**，只有"转成路线"那一刻，抽稀后的点才会被新建为点（§4.1）。

| # | 表 | 行数预测（真库迁移后） | 说明 |
|---|----|------------------|------|
| 1 | `way_points` | 540 | 路线点（含连线前的暂存点） |
| 2 | `way_lines` | 47 | 路线（**含 94 个端点列值**） |
| 3 | `way_line_bends` | **470** | **拐点链**（`line_id, point_id, before_point_id`） |
| 4 | `way_marks` | **0** | **行驶轨迹采样点**（D15；真库 0 行 —— 老库升级后是空表） |
| 5 | `world_points` | 6 | 界线点 |
| 6 | `world_lines` | 5 | 界线（含 10 个端点列值） |
| 7 | `world_line_bends` | **0** | 5 条界线**都没有拐点** |
| 8 | `world_areas` | **1** | 区域 —— **由线围成**（小区/建筑/道路/阻隔；区域 1 按 D8 丢弃） |
| 9 | `world_area_lines` | **4** | 区域 ⇄ 界线（多对多，**线是共享的**） |
| 10 | `world_polygons` | **0** | **多边形 —— 由点围成**（D19；真库 0 行，老库升级后是空表） |
| 11 | `world_polygon_points` | **0** | 多边形的**环链**（`polygon_id, point_id, before_point_id`，D20） |
| 12 | `world_gates` | 1 | 门（锚在 `world_lines.line_id` 上，D21） |
| 13 | `world_entities` | 1 | **世界要素**：`entity_type` = 店铺 / 楼栋 / 单元 / 常送点 / 停车点（真库那 1 行是**店铺**，D18） |
| 14 | `world_marks` | 0 | **记录点**（现状是 `points.source='recorded'/'gps'`，真库 0 行） |
| 15 | `zone_points` | 0 | 行政线点 |
| 16 | `zone_lines` | 0 | 行政线 |
| 17 | `zone_line_bends` | 0 | — |
| 18 | `zone_areas` | 0 | 行政区域（由线围成） |
| 19 | `zone_area_lines` | 0 | — |

> 合计：点 **546**（540+6，含跨域复制出的 4 个）／线 **52**／端点列值 **104**（52×2）／拐点 **470**／
> 区域 **1**／多边形 **0**／轨迹点 **0**。点槽位总计 **574** = 104 + 470。

### 3.1 列的公共约定

| 类别 | 列 | 约定 |
|------|----|------|
| 元素表（线/区域/门/店铺/记录点） | `id`、`name`、`created_at`、`updated_at`、`deleted_at` | 审计时间**真写**（`NOT NULL`，D6），软删保留；`note` 除两张区域表外都有 |
| 点表 | `id`、`lat`、`lng`、`floors`、`created_at`、`updated_at`、`deleted_at` | **无 `name`**（D9：有名字的位置用世界域要素表达） |
| 序列/关联表 | 无 `id`、无时间戳、无 `deleted_at` | 随主体级联删除 |

---

## 4. 完整 DDL

> 实施时整段搬进 `lib/core/schema.dart` 作为 `schemaStatements`。
> **索引一律建在 `deleted_at IS NULL` 的偏索引上**（沿用现状）。

### 4.1 路网域

```sql
CREATE TABLE way_points (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  lat REAL NOT NULL,
  lng REAL NOT NULL,
  floors TEXT NOT NULL DEFAULT '[1]',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
);
CREATE INDEX idx_way_points_deleted ON way_points(deleted_at);

-- 路线。**路宽/单行/通行代价只在这里**——表本身就是判据，不再需要
-- LineKind.hasRouteWidth 之类的守卫。
--
-- **端点仍是两列**（D4：保留端点的特殊性）：`NOT NULL` + 外键 +
-- 「起点/终点各一个索引」，于是"这条线从哪到哪"一次查询就拿到，
-- 而且"点数 ≥ 2"在结构上自动成立（空线不可能存在）。
--
-- route_width: fenced/main/narrow/bike_bridge/walk_bridge/crossing（21 章含换路口）
-- cost_class:  **冻结**，列与数据都留，不进表单（19 章）
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
);
CREATE INDEX idx_way_lines_deleted ON way_lines(deleted_at);
CREATE INDEX idx_way_lines_start ON way_lines(start_point_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_way_lines_end   ON way_lines(end_point_id)   WHERE deleted_at IS NULL;

-- **拐点链**（端点**不在链里**：它们仍是 `<域>_lines` 的两列，D4）。
-- 每行存「我是谁的后继」：before_point_id = 前驱点（start_point_id 或另一个拐点）。
-- 点序列 = 沿 before 关系从 start 走到底，再接 end：
--     start → b1 → b2 → … → bn → end
-- 两条 SQL 约束挡住两种最常见的链损坏：
--     PRIMARY KEY (line_id, point_id)    同一条线里同一点只能出现一次
--     UNIQUE (line_id, before_point_id)  **不分叉**：一个前驱最多一个后继
-- 环与断头 SQL 管不了 → 靠自检脚本 + 读链时的步数上限（§6.3）。
CREATE TABLE way_line_bends (
  line_id         INTEGER NOT NULL REFERENCES way_lines(id),
  point_id        INTEGER NOT NULL REFERENCES way_points(id),
  before_point_id INTEGER NOT NULL REFERENCES way_points(id),
  PRIMARY KEY (line_id, point_id),
  UNIQUE (line_id, before_point_id)
);
-- 反查：这个点被哪些线用着（删点前的检查、点面板的"连着 N 条线"）
CREATE INDEX idx_way_line_bends_point ON way_line_bends(point_id);

-- ---- way_marks：**我自己的行驶轨迹**（D15 / D16 / D17）----
--
-- 一行 = 一个**采样点**；「一段连续行驶」= 同一个 `trip` 下按 `recorded_at` 排序的点序列。
--
-- 这是**原始采集数据**，不是地图要素：
--   * **不进** `way_points`、**不参与吸附** —— 否则画线时会吸到一堆 GPS 噪声点上；
--   * 不进业务键、不参与组环、不参与命中排序；
--   * 它唯一的出口是「**转成路线**」：抽稀降噪 → 新建点 → `setLineShape`（§4.4）。
--
-- `trip` 的边界只由「开始记录 / 停止记录」决定（D17），GPS 中断不断段。
-- `trip` 现在是该段开始时刻的 ISO8601 串：自解释、可排序、**不需要分配器**；
-- 将来若要给"一段"起名字/存距离摘要，加一张 `way_trips`、把这列当外键即可，
-- **不需要迁移点表**（这也是选它当分组键的理由）。
--
-- 只存**不可从其它列推导**的原始量（D16：1 Hz 原样全落，不做采集期过滤）：
--   `speed` / `heading` **不存** —— `docs/requirements.md` 第 4 条就是
--   「速度矢量通过连续位置变化获取」，相邻两点的距离与时间已经够推导；
--   界面上的实时速度用设备上报值就行，不必落库。
--   `altitude` 存下来，但 ⚠️ **绝对不要用它判断楼层**：城市峡谷里 GPS 高程误差
--   ±10~20 m，远超一层楼高。天桥/高架/地下的分层只能靠 `floors` 人工标（17 章）。
--
-- 备注不在这里：备注属于「一段」，那是 `way_trips` 的活（本轮不做，见 §11）。
CREATE TABLE way_marks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  trip        TEXT    NOT NULL,          -- 分组键：一段连续行驶
  recorded_at INTEGER NOT NULL,          -- 采样时刻（epoch ms）—— 轨迹的灵魂
  lat REAL NOT NULL,
  lng REAL NOT NULL,
  accuracy REAL,                         -- 水平精度（米）；0/NULL = 设备未给。转换时用它剔坏点
  altitude REAL,                         -- 原始高程（米）—— 见上面的警告
  floors TEXT NOT NULL DEFAULT '[1]',    -- GPS 给不出楼层 → 默认地面（17 章）
  processed INTEGER NOT NULL DEFAULT 0,  -- 这一段转成路线了吗（与 world_marks 同款语义）
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
);
-- 取一段轨迹并按时间排（转换与渲染都走这条）
CREATE INDEX idx_way_marks_trip ON way_marks(trip, recorded_at);
-- 按时间段查（"昨天跑的"）
CREATE INDEX idx_way_marks_time ON way_marks(recorded_at) WHERE deleted_at IS NULL;
-- 空间查询 / 按视口加载（"我在这一带跑过吗"）；与底图 pack 的 idx_import_*_bb 同款做法
CREATE INDEX idx_way_marks_bb ON way_marks(lat, lng);
```

### 4.2 世界图域

```sql
CREATE TABLE world_points (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  lat REAL NOT NULL,
  lng REAL NOT NULL,
  floors TEXT NOT NULL DEFAULT '[1]',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
);
CREATE INDEX idx_world_points_deleted ON world_points(deleted_at);

-- 界线（围墙/铁栏/绿化带/河道/施工/软边界）。材质只在这里。端点仍是两列（D4）。
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
);
CREATE INDEX idx_world_lines_deleted ON world_lines(deleted_at);
CREATE INDEX idx_world_lines_start ON world_lines(start_point_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_world_lines_end   ON world_lines(end_point_id)   WHERE deleted_at IS NULL;

-- 拐点链（端点仍是两列，D4/D13）。同 way_line_bends。
CREATE TABLE world_line_bends (
  line_id         INTEGER NOT NULL REFERENCES world_lines(id),
  point_id        INTEGER NOT NULL REFERENCES world_points(id),
  before_point_id INTEGER NOT NULL REFERENCES world_points(id),
  PRIMARY KEY (line_id, point_id),
  UNIQUE (line_id, before_point_id)
);
CREATE INDEX idx_world_line_bends_point ON world_line_bends(point_id);

-- 区域。area_type 只剩 4 值（道路/小区/建筑/阻隔）——
-- 「行政区域」不是一个值，而是一张表（zone_areas），isVirtual 随之消失。
-- ⚠️ 这里的 `sort_order` 是**图层叠放顺序（z-order）**，与已删除的
-- `area_lines.sort_order`（成员的点选次序，D14）**不是一回事**，别混。
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
);
CREATE INDEX idx_world_areas_deleted ON world_areas(deleted_at);

-- 区域 ⇄ 界线（多对多）：两个小区共用一堵墙 = 同一条线被引用两次（12 章）。
-- ⚠️ 成员**只能是本域的 world_lines**：区域 1 的教训见 §7.5。
-- **没有 `sort_order`**（D14）：组环器按「边」建图遍历，不读顺序（`ring.dart:63`
-- 只是从 `edges.first` 起步，换个起点只是同一个环的旋转）；顺序的真正权威是几何。
CREATE TABLE world_area_lines (
  area_id INTEGER NOT NULL REFERENCES world_areas(id),
  line_id INTEGER NOT NULL REFERENCES world_lines(id),
  PRIMARY KEY (area_id, line_id)
);
CREATE INDEX idx_world_area_lines_line ON world_area_lines(line_id);

-- ---- world_polygons：**由点围成的封闭图形**（D19）----
--
-- 与 `world_areas` **同一语义、两种构造**：
--   * `world_areas`  —— 边是**共享的线**（有材质、能命名、能挂门、能被多个区域共用）；
--   * `world_polygons` —— 边**没有实体**，就是环上相邻两点之间的连线。
-- 判据一句话：**这条边需要单独设属性、挂东西、或被别处共用吗？需要 → area，不需要 → polygon。**
-- 两者**可以互相转换**（§4.5），所以不会变成"同一件事两套不相通的表示"（P1）。
--
-- 属性与 `world_areas` **完全对齐**（同名同义），因为语义就是同一个：
-- 同样可以是道路/小区/建筑/阻隔，同样有楼层与叠放顺序。
-- ⚠️ 但**门与要素挂不上它**（D21：`world_gates.line_id` / `world_entities.line_id` 是单一锚点）——
-- 要给这个多边形挂门，先转成 area（§4.5）。
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
);
CREATE INDEX idx_world_polygons_deleted ON world_polygons(deleted_at);

-- 多边形的**环链**（D20）。写法与 `<域>_line_bends` 一模一样，只有一处关键差别：
-- **环没有头** —— 不需要 `start_point_id` 那样的锚，从环上任意一点都能走回自己。
-- 于是不变量变成：**从任意一点走 N 步（N = 本图形的行数）必须回到起点，且途中不重复**。
--   走不到（断链）／提前回到别的点（成了两个小环）／步数对不上，都是坏数据。
-- 最少 **3 个点**（两点构不成封闭图形）。
CREATE TABLE world_polygon_points (
  polygon_id      INTEGER NOT NULL REFERENCES world_polygons(id),
  point_id        INTEGER NOT NULL REFERENCES world_points(id),
  before_point_id INTEGER NOT NULL REFERENCES world_points(id),
  PRIMARY KEY (polygon_id, point_id),
  UNIQUE (polygon_id, before_point_id)
);
-- 反查：这个点被哪些多边形用着（删点前的检查）
CREATE INDEX idx_world_polygon_points_point ON world_polygon_points(point_id);

-- 门：吸附在本域界线上的一处出入口（15 章）。**不再是独立的一张"世界表"**。
-- 无 floors —— 身份继承所挂线的楼层（17 章红线）。
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
);
CREATE INDEX idx_world_gates_line ON world_gates(line_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_world_gates_deleted ON world_gates(deleted_at);

-- **世界要素**：吸附在本域界线上的一处现实实体（13 章）。原 `entities` 表。
--
-- 带 `entity_type` 判别列 —— 这与 `world_areas.area_type` 是**同一套逻辑**：
-- 这些类型的**列完全相同**（类型/名字/门牌号/描述/挂线/坐标/宽度），所以共用一张表；
-- 而**门**（`world_gates`）单独一张，因为它的列集完全不同（车型/门禁/永久性）。
--
-- 值域（D18）：`shop` 店铺 / `building` 楼栋 / `unit` 单元 /
--              `delivery_point` 常送点 / `parking` 停车点
--   * **真库只有 1 行，是 `shop`** —— 其余四个值是给送餐场景留的位，目前没有数据；
--   * **`wall`（墙体段）已删**（D5：真库 0 行）—— 别无声无息把它加回来；
--   * `gate_landmark` 也删了：门有自己的表，不需要"地标"这个中间物；
--   * 加值**不需要 schema 迁移**（自由文本列 + `fromStorage` 兜底）。
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
);
CREATE INDEX idx_world_entities_line ON world_entities(line_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_world_entities_deleted ON world_entities(deleted_at);

-- 记录点：记录模式下"我在这儿"的落点（22 章）。原 points(source='recorded'/'gps')。
-- 它有自己的表，所以 **PointSource 三值枚举塌缩成一个 by_gps 布尔**，
-- 而 22 章那条"浏览态只显示记录录入且未处理的点"的判据变成一句话：
--   SELECT * FROM world_marks WHERE deleted_at IS NULL AND processed = 0
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
);
CREATE INDEX idx_world_marks_pending ON world_marks(processed) WHERE deleted_at IS NULL;
```

### 4.3 行政区域域

```sql
CREATE TABLE zone_points (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  lat REAL NOT NULL,
  lng REAL NOT NULL,
  floors TEXT NOT NULL DEFAULT '[1]',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
);
CREATE INDEX idx_zone_points_deleted ON zone_points(deleted_at);

-- 行政线：**虚拟**，不构成墙也不构成路。寻路必须跳过整张表（16 章红线）。端点仍是两列（D4）。
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
);
CREATE INDEX idx_zone_lines_deleted ON zone_lines(deleted_at);
CREATE INDEX idx_zone_lines_start ON zone_lines(start_point_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_zone_lines_end   ON zone_lines(end_point_id)   WHERE deleted_at IS NULL;

-- 拐点链（端点仍是两列，D4/D13）。同 way_line_bends。
CREATE TABLE zone_line_bends (
  line_id         INTEGER NOT NULL REFERENCES zone_lines(id),
  point_id        INTEGER NOT NULL REFERENCES zone_points(id),
  before_point_id INTEGER NOT NULL REFERENCES zone_points(id),
  PRIMARY KEY (line_id, point_id),
  UNIQUE (line_id, before_point_id)
);
CREATE INDEX idx_zone_line_bends_point ON zone_line_bends(point_id);

-- 行政区域：**没有 area_type 列** —— 整张表就是"行政区域"。
-- `sort_order` 同样是 z-order（见 world_areas 的注释），不是成员顺序。
CREATE TABLE zone_areas (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  floors TEXT NOT NULL DEFAULT '[1]',
  color_override INTEGER,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
);
CREATE INDEX idx_zone_areas_deleted ON zone_areas(deleted_at);

-- 没有 `sort_order`（D14），理由同 world_area_lines。
CREATE TABLE zone_area_lines (
  area_id INTEGER NOT NULL REFERENCES zone_areas(id),
  line_id INTEGER NOT NULL REFERENCES zone_lines(id),
  PRIMARY KEY (area_id, line_id)
);
CREATE INDEX idx_zone_area_lines_line ON zone_area_lines(line_id);
```

### 4.4 线的编辑原语（写路径全在这里）

> 用户 2026-09-14 的需求：**要有「删除端点」「添加端点」来编辑具体线条，线的端点也可能重设**；
> 同时明确 **保留 line 的端点特殊性**（D4）—— 端点是 `<域>_lines` 的两列，
> **不是**序列里的一个位置。这一节定义这些需求怎么落在 §4.1~4.3 那三张表上。

**读出**（一条平查询 + 内存组装，**不需要递归 CTE**）：

```sql
SELECT start_point_id, end_point_id FROM way_lines WHERE id = ?;
SELECT point_id, before_point_id FROM way_line_bends WHERE line_id = ?;
-- 组装：先建 beforeOf = { point_id → before_point_id }，反转成 nextOf = { before → point }，
--      再从 start_point_id 沿 nextOf 走到底，最后接上 end_point_id
```

批量读 N 条线同样是**一条** SQL（`WHERE line_id IN (…)`），按 `line_id` 分组后在内存里各走一遍 ——
所以链表**没有**把读取退化成 N 次递归。这一步落在 `core/polyline.dart` 的邻域
（18 章已有的 `LineRow.pointIds` 就是它的出口，只是内部从"排序"改成"走链"）。

**为什么链比 `seq` 更贴合这里**：编辑动作的语义本来就是"在两个点之间插一个"，
链表把它表达成「**在点 x 之后插入**」—— 不需要先算出"第几段"。

#### 局部指针操作（O(1)，不再整段重编号）

| 动作 | SQL（`L` = line_id；**顺序不能调换**，见下面的警告） |
|---|---|
| **在 x 之后插入 v** | ① `UPDATE … SET before_point_id = v WHERE line_id=L AND before_point_id = x`（把 x 原来的后继改指向 v）<br>② `INSERT (L, v, before = x)` |
| **删除拐点 v** | ① 先读出 `x` = v 的前驱<br>② `DELETE … WHERE line_id=L AND point_id = v`<br>③ `UPDATE … SET before_point_id = x WHERE line_id=L AND before_point_id = v`（把后继接到 x 上） |
| **添加端点**（头部延伸，新起点 s′） | ① `INSERT (L, 旧 start, before = s′)`<br>② `UPDATE lines SET start_point_id = s′ WHERE id=L` |
| **删除起点** | ① `DELETE` 链头那行（`before = start_point_id` 的行）<br>② `UPDATE lines SET start_point_id = 链头的 point_id` |
| **重设起点 v** | ① `UPDATE lines SET start_point_id = v`<br>② `UPDATE … SET before_point_id = v WHERE line_id=L AND before_point_id = 旧 start` |
| **添加 / 删除终点** | 对称。**链尾天然接 end，不需要改任何行的 `before`** |

> 🔴 **语句顺序不能反**（这是 `UNIQUE (line_id, before_point_id)` 逼出来的）：
> SQLite 的唯一约束是**逐行立即检查**的、没有延迟约束，所以
> **插入必须"先改后继、再插新行"**（否则新行和旧后继会同时持有 `before = x`），
> **删除必须"先删自己、再把后继接上"**（否则后继和被删行会同时持有 `before = x`）。
> 好消息：写反了会**直接撞唯一约束报错**，而不是静默画错——它落在"能被发现"的那一半。

「删除端点」仍然是**让相邻的拐点顶上**（D11：链为空时没有候选，必须拒绝）。

#### 整体重写：`setLineShape(lineId, List<int> pointIds)`

反转线、两线合并、拆线用指针做不划算（**反转必须把整条链倒过来**），
所以保留一个"整体重写"入口，事务内三步：

```
1. UPDATE <域>_lines SET start_point_id = vs.first, end_point_id = vs.last WHERE id = ?
2. DELETE FROM <域>_line_bends WHERE line_id = ?
3. 逐行 INSERT (line_id, point_id = vs[i], before_point_id = vs[i-1])   -- i 从 1 到 n-1
```

#### 🔴 链的不变式：SQL 只守得住一半

| 不变式 | 谁来守 |
|---|---|
| 同一条线里同一点只出现一次 | `PRIMARY KEY (line_id, point_id)` ✅ |
| 一个前驱最多一个后继（**不分叉**） | `UNIQUE (line_id, before_point_id)` ✅ |
| 前驱是本域真实点 | 外键声明了，但 ⚠️ **sqflite 默认不开 `PRAGMA foreign_keys`** → 实际靠写入时的校验 |
| **恰好一个头**（`before = start_point_id` 至多一行）且**链能走到 end** | ❌ 自检脚本 |
| **无环** | ❌ 自检脚本 + **读链步数上限** |

⚠️ **读链必须带保护**：循环里放一个计数器，步数超过"本线拐点行数 + 1"就判定链坏了并**报出来**。
链的坏法是**静默**的 —— 断链少一段、成环**死循环**；这比 `seq` 版"有洞"更危险，
所以 `tool/checks` 里必须有一条**链自检**脚本，UI 也要能把"这条线的点数据不全"显示给用户
（18 章那条红线"缺一个点就整条不画"因此更要保留）。

#### 这次改动白拿的两样

1. **20 章那条"下标"红线自然消失**。HANDOFF 工程红线 16 说：「插拐点的位置必须用
   `planBendInsertion` 返回的 `bendIndex`，自己算错**不会报错，只会画出一条形状不同的路**」。
   链的接口是「在**点 x** 之后插入」——**点名那个点，没有下标可错**。
2. **对外格式不变**。备份里仍然是**有序数组** `bend_point_ids`：导出时走一遍链把它拍平，
   导入时按数组顺序重建链。链是**存储**细节，不是备份契约（§8）。

#### 🔴 「删除端点」与「删除点」是两个动作（D10）

| | **A 删端点** | **B 删点** |
|---|---|---|
| 做什么 | 只改 `<域>_lines` 的两列与 `<域>_line_bends`，**点行不动** | 软删点行 |
| 影响面 | **1 条线**（它就变短了） | **N 条线**（所有引用它的线） |
| UI 入口 | 线面板：删端点 / 删拐点 | 点面板：删除 |
| 要不要反查 | 不用 | **必须**（`countLinesUsingPoint`，今天是死代码） |

今天的 `softDeletePoint`（`app_repository.dart:605`）把两者揉成一个动作，而且两边都做错：

```dart
final removedBends = await txn.delete('line_bends', where: 'point_id = ?', ...); // 物理删 → 今天留 seq 空洞；换成链后是**断链**
await txn.update('points', {'deleted_at': nowMs}, where: 'id = ?', ...);         // 软删点
// 但完全不碰 lines.start_point_id / end_point_id
```

于是同一个操作的结果取决于那个点扮演什么角色：
**删拐点 → 线少一个弯但照常画；删端点 → 整条线消失**（线 3/4 的现状，不报错）。
换成链之后前者更危险：直接 `DELETE` 一行会让链**从中间断开**，后面那半截静默丢失
—— 删拐点必须走「把后继的前驱改成自己的前驱」那两步（§4.4 局部操作表）。

#### 端点规则（D4 / D10 / D11 / D12）

1. **结构上**：两列 `NOT NULL` + 外键 → **点数 ≥ 2 天然成立，空线不可能存在**。
   这是保留端点特殊性的直接收益（换成"端点并入序列表"反而要额外守这条）。
2. **但操作上仍要拦**（D11）：**删除端点**意味着"让相邻的拐点顶上"——
   bends 为空时没有候选，说明这条线只有两个端点，**拒绝**并提示
   「这条线只剩两个端点了，要删就删整条线」。
3. **端点不得与相邻点相同**：`start ≠ bends[0]`、`end ≠ bends[last]`；
   且 **`start ≠ end`**（两个端点重合的"线"既没有方向也没有长度）。
   今天 `polyline.dart:31` 与 `ring.dart:50` **各自在防**相邻重复 ——
   说明它发生过；第一道校验收口到一处。
4. 新增 / 重设的点必须**存在、未删、同域**（D2）。
5. **删端点后留下的孤立点不自动回收**（D12），进入「清理孤立点」的候选
   —— 实测那 147 个孤立点里可能正有"连线前先散的点"。

#### ⚠️ 重设端点会改变这条线的**身份**

线的业务键是 `kind|min(端点键)|max(端点键)|排序(拐点键)`（`merge.dart:89`）：

- 两个**端点键本来就排序** → **反转线不改键**，「把方向反过来」是免费的；
- **重设端点或删端点会改键** → 坐标变了，导入备份时这条线会被当成**另一条线**
  （新增而不是合并）。这是 11 章幂等合并的必然代价，用户需要知情。

#### 空线为什么不可能存在（保留端点特殊性的直接收益）

`start_point_id` / `end_point_id` 是 `NOT NULL` 且带外键 → 一条线**至少**有两个点，
而且它们必须真实存在于本域点表里。"0 或 1 个点的线"这种在纯序列表方案里
需要额外红线和渲染兜底的失效模式，在这里**从结构上就不存在**。
要守的只剩唯一性（规则 3）与操作层的拒绝（规则 2）。

#### 落点：`lib/core/line_edit.dart`（纯 Dart，新增）

编辑动作的**链组装、遍历与校验**是领域知识，放 `core/`（与 `core/edit_layers.dart` 同样的
理由：纯 Dart 才能被 `tool/checks/` 的脚本验证）：

```dart
/// 走链 → 点序列（从 start 沿 before→point 走到底，再接 end）；**带步数上限保护**
List<int> assemblePointChain({
  required int startPointId,
  required int endPointId,
  required Map<int, int> beforeOf,        // point_id → before_point_id
});

/// 序列 → 链的校验（相邻重复、端点自环、点存在性）
LineChainError? validatePointChain(List<int> vs, {required Set<int> knownPointIds});

/// 「插到最近那一段」的落点：返回**锚点 id**（不是下标 —— 20 章那条下标红线因此消失）
int anchorPointForInsertion(LineRow line, GeoPoint at, Map<int, GeoPoint> pointGeo);
```

DAO 只认这几个入口：`insertBendAfter` / `removeBend` / `extendStart` / `removeStart` /
`resetStart` / `resetEnd` / `setLineShape`。**别处不许直接写 `<域>_line_bends`
或改 `<域>_lines` 的两列**（§6.11）。

### 4.5 两种封闭图形：环怎么改、以及互相转换

#### 多边形的环＝链的最简情形（复用 §4.4 的那套 SQL）

`world_polygon_points` 是与 `<域>_line_bends` **完全相同的链**（D20），所以 §4.4
的局部指针操作**原样适用**，只是少了端点的四个动作：

| 动作 | SQL（`P` = polygon_id） |
|---|---|
| **在点 x 之后插入 v** | ① `UPDATE … SET before_point_id=v WHERE polygon_id=P AND before_point_id=x` ② `INSERT (P, v, before=x)` |
| **删除环上的点 v** | ① 读出 `x` = v 的前驱 ② `DELETE … WHERE polygon_id=P AND point_id=v` ③ `UPDATE … SET before_point_id=x WHERE polygon_id=P AND before_point_id=v` |
| **整体重写** | `setPolygonRing(polygonId, List<int> pointIds)`（事务内全删全建链） |

- **环没有头**（没有 `start/end_point_id` 那样的锚），所以「添加端点 / 删除端点」这四个动作
  对多边形**不存在** —— 环上每一点的地位相同；
- **最少 3 个点**（两点构不成封闭图形）；
- 编辑动作的形状与线**完全一样**，只是不变量不同（见 §4.5 末的对照表）。

#### 🔴 双向转换（D19）：**是搬家，不是复制**

同一块地**不允许**在两张表里各存一份 —— 那正是 P1（同一个概念两套表示）的复现。
转换必须是"搬过去"，而不是"再建一个"。

**polygon → area**（要给出边加实体了）：

1. 读环链 → 点序列；
2. **为每条边新建一条 `world_lines`**（`boundary_type` 留 NULL = 未指定材质，名字留空）；
3. 建 `world_areas` + `world_area_lines`；
4. **软删该 `world_polygons`、物理删它的 `world_polygon_points`**。

- 点**复用**，不复制。
- 爆炸半径：**界线数 +N**。实测这正是今天「一笔画圈地」的行为
  （`saveAreaWithRing` 会造 N 条界线 + N 个点）—— 新设计把它**从默认行为改成显式动作**（§5）。

**area → polygon**（不要边实体了）：

1. **组环**（`assembleAreaRing`）—— ⚠️ **会失败**（开口 / 分叉 / 接不上）。失败就**拒绝转换**并说明原因；
2. **检查每条边线**：被别的区域引用吗？上面挂了门或要素吗？→ 有就**警告**（说明这些线会留下）；
3. 按环序写 `world_polygon_points`、建 `world_polygons`；
4. **软删该 `world_areas`、物理删它的 `world_area_lines`**；
5. **那些线本身一条都不删** —— 它们可能被别的区域共用（实测线 1 同时属于区域 1 和 2），
   或上面挂着门/店铺。删了就等于把第 2 步的警告变成数据损失。

- 转换后会留下**不属于任何区域的线**（它们照常渲染）。这是**预期结果，不是脏数据**：
  渲染不依赖区域，区域只是"线的分组"。

#### 两张表带来的查询代价（要认下来）

因为语义相同，下面这些从此都要**同时考虑两张表**：渲染填色、命中测试（`hitArea` 要有两份
或统一抽象）、楼层过滤、视口裁剪、按名字搜索、备份、业务键。

**收口办法**：在 `core/` 里定义一个**「封闭图形」抽象**（名字 / 类型 / 楼层 / 取环），
让命中、渲染、导出都只认它，两张表各自提供一个"取环"的实现 ——
area 走**组环**（可能失败）、polygon 走**链**（永远有效）。
这与 `edit_layers.dart` 把"图层归属"收口到一处是同一套做法（§9）。

#### 两种封闭图形的不变量对照

| | `world_areas`（由线围成） | `world_polygons`（由点围成） |
|---|---|---|
| 环从哪来 | **推导**（组环算法，**可能失败**） | **存下来的**（链，永远有效） |
| 成员关系 | 多对多，**线是共享实体** | 每图形一条私有环链 |
| 边的属性 | ✅ `boundary_type`、可命名 | ❌ 没有边实体 |
| 挂门 / 要素 | ✅（锚在 `line_id`） | ❌（D21：要挂就先转 area） |
| 最少几个 | 3 条线 | 3 个点 |
| 完整性约束 | 闭合、连通、每点度数 = 2（`checkRingClosure`） | 走 N 步回到起点（链不变式） |
| 一张图能有几个这玩意 | 一个区域 = 一个环 | 一个多边形 = 一个环 |

---

## 5. 消失的概念

这是本章**最值钱**的部分：一堆枚举、判据、补丁不再需要存在，因为「表名就是那个类型」。

| 今天的东西 | 今天在哪 | 新设计里它是什么 |
|-----------|---------|----------------|
| `LineKind`（boundary/route/zoneistrative） | `models.dart` | **表名** `world_lines` / `way_lines` / `zone_lines` |
| `LineKind.isVirtual` | `models.dart` | 消失（表名即语义） |
| `LineKind.hasMaterial` / `hasRouteWidth` | `models.dart` | 消失（材质列只在 `world_lines`，路宽列只在 `way_lines`） |
| `AreaType.zoneistrative` | `models.dart` | **表** `zone_areas`；`world_areas.area_type` 只剩 4 值 |
| `AreaType.isVirtual` | `models.dart` | 消失（寻路跳过 `zone_*` 三张表即可） |
| `PointKind`（auxiliary/shop/gate/waypoint） | `models.dart` | **表名**：`*_points` / `world_gates` / `world_entities` |
| `PointSource`（manual/recorded/gps） | `models.dart` | 表 `world_marks` + 一个 `by_gps` 布尔 |
| `EntityType`（7 值） | `models.dart` | **收敛到 5 值**，成为 `world_entities.entity_type` 的值域（D18）：删 `wall`（D5）与 `gate_landmark`（门有自己的表）。写法与 `AreaType` → `world_areas.area_type` 完全一致 |
| `MapLayer.ofLineKind` / `ofAreaType` | `edit_layers.dart` | 退化成「域 → 表前缀」一个映射 |
| `MapLayer.defaultPointKind` | `edit_layers.dart` | 退化成「当前域 = 当前点表」 |
| 22 章 `source='recorded'` 那个补丁 | `models.dart` | 不需要（记录点在自己的表里） |
| `PointSource.gps`（定位记录的**单点**） | `models.dart` | **一分为二**：单点记录 → `world_marks.by_gps`（"我在这儿"）；**连续轨迹 → `way_marks`**（D15，"我跑过的路"）。两者不是一回事，别再挤在一个 `points` 表里 |
| `EditTool.polygon`（一笔画圈地）**造 N 条界线** | `app_repository.dart` `saveAreaWithRing` | 落点改成 **`world_polygons`**：只造 **N 个点 + 一圈环链**，**不再产生线**（D19）。想要"边能挂门/有材质"时，用转换动作显式转成 area（§4.5） |
| `area_lines.sort_order`（D14） | `schema.dart` | **删掉**。关联表只表达成员关系；组环不读顺序，顺序的权威是几何 |
| `AppRepository.setAreaLines`（**死代码**：`lib/` 里没有调用者） | `app_repository.dart` | 随 D14 一起消失（它存在的唯一理由是"整体替换含 sort_order"） |
| 门/店铺的**双重表示**（P1） | 全库 | 消失 |
| `lines.start_point_id` / `end_point_id` / `line_bends` 三真相（P2） | schema + 10 个文件 | **保留**（D4：端点特殊，不是要消除的问题）；三个域各一份 `<域>_lines` + `<域>_line_bends`，读出口仍是 `LineRow.pointIds`，写入口收成 `setLineShape` |

---

## 6. 新红线（不变量）

1. **域内自洽**：`<域>_lines.start_point_id` / `end_point_id` 与 `<域>_line_bends.point_id`
   都只能指向**同域**点；
   `world_gates.line_id` / `world_entities.line_id` 只能指向**同域**的线。
   由外键 + 迁移自检脚本双重保证。
2. **零跨域引用**。要跨域连接，靠 M2 建图时按坐标容差处理，**不在数据里存跨域外键**。
3. **拐点链必须完整**（D13）：`<域>_line_bends` 每行记前驱（`before_point_id`）。
   SQL 只守得住「同线不重复点」（PK）与「不分叉」（`UNIQUE (line_id, before_point_id)`）；
   **恰好一个头、无环、能走到 end** 靠自检脚本。
   ⚠️ **读链必须带步数上限** —— 成环会**死循环**，断链会**静默丢段**，
   这比 `seq` 版"有洞"更危险（§4.4）。

   🔴 **并且：走完必须"用光"全部拐点行**（`out.length - 2 == beforeOf.length`）。
   少了这条，下面这种数据会**静默变成一条两点直线**：拐点挂在
   「从起点走不到的孤岛」或「自成的小环」上 —— 走链一步就到头，看着毫无异常，
   库里那些拐点却被全部忽略。这一条是 2026-09-14 的校验脚本
   （`tool/checks/three_domain_check.dart`）抓出来的：当时 `assembleLineChain`
   只接终点、不核对消耗数，孤岛与悬挂两种坏链都返回 **`ok`**。
   真库 470 个拐点全部可达，所以这条断言在正常数据上恒真。
4. **删线不级联删点**（点可能被同域别的线用）。删点前必须反查 `line_bends` 与
   `*_lines` 的端点列（对应今天的 `countLinesUsingPoint`，按域各一份）。删线 / 删端点后留下的孤立点
   **不自动回收**，交给手动「清理孤立点」（D12）。
5. **备份的业务键必须带域前缀**（§8.1）。不带就会被"坐标完全相同的跨域点"顶掉。
6. **点表没有 `name`**（D9）。要给一个位置起名字，用世界域要素。
7. **老备份（v1~v9）导入必须落进正确的域**，映射表见 §8.2。
8. **顺带修复**：点的坐标缺失即整条线不画（18 章红线）**保留**；但新设计要求
   「删点前检查引用」，所以这条红线以后不该再被触发。
9. **端点必须互不相同、且不同于相邻拐点**：`start ≠ end`、`start ≠ bends[0]`、
   `end ≠ bends[last]`。"点数 ≥ 2"由两列 `NOT NULL` **结构性保证**（D4），不用守；
   要守的是**唯一性**与操作层的拒绝（bends 为空时不许删端点，D11）。
10. **相邻点不得相同**（段长 0 / 投影分母 0）。第一道校验收口在
    `core/line_edit.dart`（落库前拦）；`polyline.dart:31` 与 `ring.dart:50` 里那两处
    防御性判断**保留**当最后一道防线，但它们不该再被触发。
11. **写链只有 §4.4 列的那几个入口**（`insertBendAfter` / `removeBend` / `extendStart` /
    `removeStart` / `resetStart` / `resetEnd` / `setLineShape`）。
    不许有第二个地方直接写 `<域>_line_bends` 或改 `<域>_lines` 的两列 ——
    **链是"改一处必须同时改另一处"的结构，绕过入口就是断链**。
    删端点是改线的构成（不碰点行），删点必须反查引用 —— 两个入口不许合并（D10）。
12. **关联表只表达成员关系**（D14）：`<域>_area_lines` 不带顺序列。
    顺序类信息**一律不存进关联表** —— 要顺序就存几何（点链），不要塞一个整数。
    判据很简单：**如果消费者（组环 / 渲染 / 命中）不读它，它就不是数据，是装饰。**
13. **轨迹点是原始数据，不是几何**（D15）：`way_marks` 的点**不许**进
    `way_points`、**不许**参与吸附、**不许**进业务键。要让它变成地图要素，
    唯一通路是「转成路线」：抽稀降噪 → 新建点 → `setLineShape`（§4.4）。
14. **轨迹的显示必须与"点"分开**：一段半小时约 **1800** 个采样点，浏览态**不能画点**
    （画成一条淡线，且**默认关闭 + 开关持久化** —— 与 16 章经纬线同款做法）。
    22 章那套"编辑态 24 px 网格抽稀"**不适用于轨迹**：它是另一个图层的东西，
    既不该被抽稀，也不该参与吸附。
15. **`way_marks` 是唯一会无限增长的表**：1 Hz × 骑行 ≈ 半小时 1800 行 ≈ 160 KB/趟；
    天天跑一年约 **23 万行 / 230 MB**。所以**保留策略必须在实现前定下来**（R-23-8），
    清理只删**已处理**的段（`processed = 1`），绝不碰未处理的。
16. **两种封闭图形之间必须有转换通路，且转换是「搬家」不是「复制」**（D19）。
    同一块地**不许**在 `world_areas` 与 `world_polygons` 里各存一份 —— 那正是 P1
    （同一个概念两套表示）的复现。转换的爆炸半径见 §4.5，**一条定律**：
    `area → polygon` **一条线都不删**（线可能被别的区域共用、或挂着门）。
17. **多边形的环：`≥ 3` 个点，且"走 N 步回到起点"**（D20）。环**没有头**，
    所以没有"恰好一个头"这一条；坏数据表现为断链、成两个小环、或步数对不上。
    读环同样要带**步数上限**（§6.3）。
18. **门与要素只挂线**（D21）：`world_gates.line_id` / `world_entities.line_id` 是**单一锚点**，
    不许加 `polygon_id`。要给多边形挂门，先 `polygon → area` 转换（§4.5）。
    判据：**一个要素只能有一个"我在哪"的答案**，多态锚点会让 `locateOnLine` 那套红线失去意义。

---

## 7. 迁移 v11 → v12

### 7.0 ✅ 迁移脚本已写好，并已在**真库副本上真跑过**

**`tool/migrations/v11_to_v12.sql`** —— 用法、预期结果、回滚方式都写在文件头。

实测记录（2026-09-14，真库副本；脚本在事务里跑，任何一步失败整体回滚）：

| 验证项 | 结果 |
|--------|------|
| 19 张新表的行数 | 与 §7.4 **逐项吻合**（540 / 47 / 470 / 6 / 5 / 0 / 1 / 4 / 0 / 0 / 1 / 1 / 0，`zone_*` 全 0） |
| **新链走出的点序列 + 终点，与老库顶点顺序逐位比对** | **差异 0**（老 564 点 → 新 564 点） |
| 每条线：点数 = 端点 2 + 链上拐点数 | 0 处不符 |
| 老库 `line 22` 缺 `seq=15` 那个洞 | 104 个拐点一个不少搬过去，洞里那一位**自然消失**（新结构没有 `seq`） |
| 4 个跨域共享点 | 两域各一份 ✓ |
| 区域成员 | 只剩区域 2 的 `1/8/9/10`（区域 1 按 §7.5 丢弃）✓ |
| 门 / 要素锚点 | 门 → `world_lines.id = 9`；要素 → `world_lines.id = 1` ✓ |
| 丢弃清单 | 点 **156** / 线 **10** / 区域 **1** ✓ |
| **重复运行** | 被版本闸门拦住（`CHECK constraint failed: 库必须正好是_v11`），库**不受损** ✓ |

🔴 **跑完那一刻 app 会打不开**：脚本把 `user_version` 推到 **12**，而 Dart 侧还写着
`schemaVersion = 11`，sqflite 会走 `onDowngrade` 抛异常。所以顺序必须是
**先跑脚本 → 再改 Dart**（这正是本轮定下的分工）。
回滚 = `cp -a map.db.pre_v12.bak map.db`。

老表**不删**，改名归档成 `_v11_*`（方便逐项对照新旧数据）；等 Dart 重构验收完，
再跑脚本末尾那段注释掉的 `DROP`。

#### 7.0.1 ✅ 脚本可**完全复现**（2026-09-14 补验）

把真库里归档的 `_v11_*` 表还原成原名、把 19 张新表删掉、`user_version` 改回 11，
就得到一个**真正的 v11 库**（行数 698 点 / 62 线 / 470 拐点 / 2 区域 —— 与真库 v11 期一致）。
在这个还原库上重跑迁移脚本，与真库逐表比对：

| 比对方式 | 结果 |
|----------|------|
| 19 张表行数 | **19/19 全等** |
| 19 张表**内容哈希**（含全部列） | 15/19 全等 |
| 4 张"不等"的表，**排除 `created_at`/`updated_at` 后** | **4/4 全等** |

那 4 张（`way_points` / `way_lines` / `world_gates` / `world_entities`）的差异**只有时间戳**，
而且**不是 bug**：v11 库里 `created_at` **全部为 NULL**，`updated_at` 也只有
15/698 个点、34/62 条线有值。脚本第 77 行与第 369 行就是这么写的 ——
`COALESCE(updated_at, 迁移时刻)`，**真实存在的时间戳会保留**（如 `1789332447409`），
只有"本来就没有时间戳"的行才被填成迁移运行时刻。

> 这条验证的意义：**任何一份 v11 老库都走这条路**（与"本机恰好是什么状态"无关）。
> 它证明迁移不依赖"本机恰好是什么状态"，同一份 v11 数据无论什么时候跑，
> 出来的业务数据都完全一样。

### 7.1 爆炸半径与备份（先看这一节）

这是本项目**历史上最大的一次结构改动**：用户层 7 张表 → 19 张表，
`points`/`lines`/`line_bends`/`areas`/`gates`/`entities` 全部重新落位。

**迁移前必须做两件事**（缺一不可）：

1. 复制整库为 `map.db.pre_v12.bak`（沿用 v4 的老办法）；
2. **自动导出**一份 v9 格式的 `.mapexport.json` 到用户文档目录
   —— 老格式的导出器在迁移**之后**就不存在了，这是"事后还能救回来"的唯一通路。

### 7.2 拐点重建（顺带修掉旧的 `seq` 空洞）

实测旧库的病：`line_bends` 里有 **1 条线的 seq 不连续** —— `lines.id = 22`（龙平西路，
104 个拐点）`min=1, max=105, count=104`，**缺 `seq=15`**。其余 29 条有拐点的线都连续。
（成因见 §4.4：`softDeletePoint` 直接 `DELETE` 单行。）

所以迁移时：

- **两个端点原样搬**（D4：`start_point_id` / `end_point_id` 直接进 `<域>_lines` 的同名列）；
- **拐点按点顺序重建成链**：把每条活线展开成 `[start, b1…bn, end]`，
  然后 `b_i.before_point_id = v_{i-1}`（`v_0` = start）。
  **旧 `seq` 一个都不搬** —— 新结构里根本没有 seq 这一列，
  所以线 22 那个空洞**自然就被修掉了**，不需要任何"补洞"逻辑。

### 7.3 实体级映射表

| 旧 | 条件 | 新 |
|----|------|----|
| `points` | 被**活线**引用（含软删但被引用的 3 个，见 §7.6） | `<域>_points`（域 = 引用它的线的所属域） |
| `points` | 跨域共用（4 个） | **复制成两行**，两域各一份（D3） |
| `points` | `source` 为 `recorded`/`gps` | `world_marks`（真库 0 行） |
| `points` | 孤立（147 个） | **丢弃**（D7） |
| `points` | 软删且无人引用（9 个） | **丢弃**（D7） |
| `lines` | `kind='route'` | `way_lines`（47 条） |
| `lines` | `kind='boundary'` | `world_lines`（5 条） |
| `lines` | `kind='zoneistrative'` | `zone_lines`（0 条） |
| `lines` | 软删（10 条） | **丢弃**（D7） |
| `lines.start_point_id` / `end_point_id` | 全部活线 | `<域>_lines` 的同名列，**原样搬**（52×2 = 104 个列值） |
| `line_bends` | 全部活线 | `<域>_line_bends`，**按点顺序重建成链**（`before` = 前一个点；470 行） |
| `areas` | `area_type ≠ zoneistrative` | `world_areas` |
| `areas` | `area_type = zoneistrative` | `zone_areas`（0 个） |
| `area_lines` | — | `<域>_area_lines`，**丢掉 `sort_order`**（D14）；**区域 1 的 4 行丢弃**（§7.5） |
| `gates` | — | `world_gates`（1 个） |
| `entities` | `entity_type='shop'` | `world_entities`（1 个，`entity_type` **原样带过去**，D18） |
| `entities` | `entity_type='wall'` | **丢弃**（D5，0 行） |
| （没有来源） | — | **`way_marks` 建空表**：真库 0 条轨迹，`points.source='gps'` 也是 **0 行** —— 轨迹是从这一版才开始采集的（D15） |
| （没有来源） | — | **`world_polygons` + `world_polygon_points` 建空表**（D19）：今天"由点围成的封闭图形"都得靠 `saveAreaWithRing` 伪装成 N 条界线，所以**没有一个旧图形能对应到多边形**。已有的 2 个区域都是"由线围成"，**原样留在 `world_areas`**；要不要转成多边形由用户自己决定（§4.5） |
| `lines.boundary_type` | 有值 5 行 | `world_lines.boundary_type` |
| `lines.route_width` / `one_way` / `cost_class` | 分别 24 / 23 / 33 行 | `way_lines` 的同名列（`cost_class` 继续冻结） |

### 7.4 预期行数（迁移的验收判据）

| 新表 | 预期 | 新表 | 预期 |
|------|------|------|------|
| `way_points` | **540** | `world_areas` | **1** |
| `way_lines` | **47** | `world_area_lines` | **4** |
| `way_line_bends` | **470** | `world_polygons` | **0** |
| `way_marks` | **0** | `world_polygon_points` | **0** |
| `world_points` | **6** | `world_gates` | **1** |
| `world_lines` | **5** | `world_entities` | **1** |
| `world_line_bends` | **0** | `world_marks` | **0** |
| | | `zone_*`（5 张） | **0** |

> 端点不是行，是 `*_lines` 上的列：`47×2 + 5×2 = ` **104 个端点列值**（不参与上面的行数核对）。

任何一个数字对不上，迁移就算失败（整体回滚）。

### 7.5 唯一被丢弃的实体：区域 1

区域 1「沿嘉辉广场的嘉辉中路」（`area_type='road'`）的环由 4 条线组成，
**其中 2 条是路线**：

```
line 1  (界线 wall)  2 → 3       line 5 (界线 wall) 10 → 7
line 6  (路线)      10 → 3       line 7 (路线)       7 → 2
环：2 → 3 → 10 → 7 → 2
```

那 4 个「跨域共享点」`points.id = 2 / 3 / 7 / 10` **就是这个四边形的 4 个角**。
新设计里路线属于路网域、区域属于世界域，这条引用非法 → 只剩 2 条边 → **组环失败**。

**D8 决策：放弃区域 1。** 连带丢弃它的 4 行 `area_lines`。
爆炸半径（已核实）：
- 丢 1 个区域（`areas` 2 → 1）；`area_lines` 8 → 4；
- **不丢线**：线 1 / 5 / 6 / 7 全部保留（5、6、7 只是不再属于任何区域，仍然照常渲染）；
- 区域 2「嘉辉广场」（`building`，成员全是界线 1/8/9/10）不受影响。

> 教训值得单独记一笔：**「围合区域」工具今天允许把路线当边**（`checkRingClosure`
> 不区分线类型）。新设计必须让区域只接受本域线 —— 否则用户会再画出第二个区域 1。

### 7.6 顺带修复：两条看不见的路线会回来

软删点 `8 / 9 / 11` 被活线当端点用（§1.3），迁移时**复活**（清掉 `deleted_at`）
并正常落进 `way_points`。

**用户可见的变化**：升级后地图上会**多出 2 条路线**（`lines.id = 3`、`4`）。
这不是新数据，是你早就画好、但因为上面那个 bug 一直没显示出来的线。

### 7.7 迁移自检（跑在迁移事务的末尾）

迁移完成前必须全绿，否则抛异常回滚：

1. 每张新表的行数 = §7.4 的预期；
2. 悬空引用 0：`*_line_bends.point_id` / `*_area_lines.line_id` /
   `world_gates.line_id` / `world_entities.line_id` 全部指向存在的行；
3. **拐点链完整**：每条线恰好一个头（`before_point_id = start_point_id` 的行 ≤ 1）、
   无环、沿链走到底后紧接 `end_point_id`，且不重复点（PK 已保证，复核一次）；
4. **零跨域**：不存在 `world_*` 引用 `way_*`/`zone_*`（反之亦然）；
5. 每条活线 `start_point_id ≠ end_point_id`，且端点不与相邻拐点相同；
6. `pragma foreign_key_check` 干净。

---

## 8. 备份格式（`.mapexport.json` → v10）

格式仍然是 **GeoJSON FeatureCollection + `schema_version`**（11 章 D3），但：

- 每个 feature 的 `properties` 多一个 **`domain`**（`way` / `world` / `zone`），
  并与 **`table`**（具体表名）一致；
- 顶层加 `"domain_layout": "three-domain"`，让人一眼看出是哪一代格式；
- `counts` 按域分组；
- 🔴 **拐点在备份里仍然是「有序数组」`bend_point_ids`，不是链**。
  链是**存储**细节：导出时走一遍链把它拍平，导入时按数组顺序重建链（§4.4）。
  所以 D13 换了存储形态，**对外契约没变**，老文件照旧能读。
- 🔴 **`line_ids` 也仍是有序数组，但顺序改由 `line_id` 升序决定**（D14 删掉了
  `area_lines.sort_order`）。对导入没有影响 —— `merge` 用集合/键判等，不看数组顺序；
  对"逐字节复现同一份备份"也是确定的。
- ⚠️ **轨迹（`way_marks`）要不要进备份，本轮没定**（R-23-7）。
  它的体量和别的东西不是一个量级（半小时一趟 1800 个点），塞进 GeoJSON 会把备份文件
  从几百 KB 撑到几十 MB。倾向：**默认不进**，或做成"含轨迹"的可选项。
  这一条必须在动手做备份 v10 **之前**定下来。

### 8.1 🔴 业务键必须带域前缀（本章最容易踩的坑）

今天的业务键是 `纬度,经度@楼层`（`pointKeyOf`）。**新设计下它会出事**：
那 4 个跨域共享点在拆开之后，**两域各有一个坐标完全相同的点**——
键不带域前缀，导入时会互相顶掉一个。

所以键一律加域前缀：

| 要素 | 新键 |
|------|------|
| 点 | `way:point\|22.7203,114.1833@1` |
| 线 | `way:line\|<p0键>\|<p1键>\|…@1`（域已在前缀里，不再需要 kind） |
| 区域 | `world:area\|名字\|质心@1` |
| **多边形** | `world:poly\|名字\|质心@1` |
| 门 / 世界要素 | `world:gate\|名字\|点键`、`world:entity\|**类型**\|名字\|点键` |
| 记录点 | `world:mark\|点键` |

> 🔴 世界要素的键**必须带 `entity_type`**（D18）：同一位置同名的「店铺」与「停车点」
> 是两条不同的记录，键不带类型就会在导入时互相顶掉（与「业务键必须带楼层/拐点/域前缀」
> 是同一类错误的第四次出现）。
>
> 🔴 封闭图形的键**必须区分「由线围成」与「由点围成」**（D19）：两者语义相同、几何可以完全一样，
> 一块地转过一次构造方式之后，键若不区分就会在导入时被当成同一块地而**静默丢掉一次转换**
> （同一类错误的第五次）。

这与「业务键必须带楼层（17 章）」「必须带拐点（18 章）」是**同一类错误**的第三次出现，
所以它写进红线（§6.5）。

### 8.2 老文件（v1~v9）导入映射

老备份里没有 `domain`，按**原来那个 `kind`/`source`** 落域：

| 老文件里的东西 | 落到 |
|---------------|------|
| `lines.kind='route'` | `way_lines` |
| `lines.kind='boundary'` / `'area_boundary'` | `world_lines` |
| `lines.kind='zoneistrative'` | `zone_lines` |
| `points`（被某条线当点用） | 跟那条线同域 |
| `points.source='recorded'/'gps'` | `world_marks` |
| `points.kind='waypoint'` 且无人引用 | `way_points` |
| `points.kind='auxiliary'` 且无人引用 | `world_points` |
| `gates` | `world_gates` |
| `entities('shop')` / `('door')` | `world_entities`，`entity_type` → `shop`（D18；`door` 是 v4 及更早的门牌） |
| `entities('building')` / `('unit')` / `('delivery_point')` / `('parking')` | `world_entities`，`entity_type` **原样带过去**（真库 0 行，但老备份文件里可能有） |
| `entities('wall')` | 丢弃（D5） |
| `entities('gate_landmark')` 及其它认不出的值 | `gate_landmark` **丢弃**（语义已被 `world_gates` 取代）；其余认不出的值兜底成 `delivery_point`（沿用旧 `EntityType.fromStorage` 的 `orElse`） |
| `areas.area_type='zoneistrative'` | `zone_areas` |
| 其余 `areas` | `world_areas` |

> 「孤立点按 `kind` 落域」这条不是拍脑袋：它**正好就是** 19 章
> `MapLayer.defaultPointKind` 已有的映射（路网落点 = 路点、世界图落点 = 辅助点）。

---

## 9. 代码改动半径

| 文件 | 行数 | 改动 |
|------|------|------|
| `lib/core/schema.dart` | 639 | **重写**（19 张表 DDL + v12 迁移；v3~v11 归档） |
| `lib/core/models.dart` | 1079 | **重写**（枚举大幅精简 §5；行模型按域） |
| `lib/data/app_repository.dart` | 2127 | **用户层约 1000 行重写**（63 个公开方法） |
| `lib/core/export.dart` | 341 | **重写**（v10 + `domain`） |
| `lib/core/import.dart` | 346 | **重写**（§8.2 映射） |
| `lib/core/merge.dart` | 832 | **重写**（键加域前缀） |
| `lib/features/editor/edit_mode_controller.dart` | 1251 | 适配（工具按域分派） |
| `lib/features/editor/feature_forms.dart` | 1180 | 适配（表单按域/表） |
| `lib/features/map/map_page.dart` | 3001 | 读写路径适配；**22 章的显示规则反而变简单** |
| `lib/features/editor/gate_form_sheet.dart` | 240 | 适配（写 `world_gates`） |
| `lib/features/settings/backup_section.dart` | 342 | 适配（v10、按域统计） |
| `lib/core/edit_layers.dart` | 187 | **简化**（判据退化成域 → 表前缀） |
| `lib/core/line_edit.dart` | **新增** | 线的编辑原语（§4.4）：链的组装/遍历（带步数保护）+ 链校验 + 插入锚点计算；纯 Dart，供 `tool/checks` 脚本验证 |
| `lib/core/track.dart` | **新增** | **轨迹处理（纯 Dart）**：抽稀降噪（按 `accuracy` 剔坏点 + 距离/转角抽稀）、时间空洞检测、速度与航向派生、`trip` 分组。放 `core/` 的理由同 `line_edit.dart` —— 能被脚本用**合成轨迹**验证（Linux 上也能验，见 §12） |
| `lib/services/location_service1.dart` | 65 | 现在是 `Notifier<Position?>`（**只持有当前位置，不累积**）→ 扩成**轨迹记录器**：开始/停止、按 1 Hz 落 `way_marks`。（2026-09-15 已把它的 8 条历史 lint 清掉：日志改 `debugPrint`、导入改 `flutter_riverpod`；扩成记录器时**继续用 `debugPrint`，不要回退成 `print`**） |
| `lib/features/map/`（轨迹图层 + 显示开关） | — | 新增：把一段轨迹画成**淡线**（不画点），开关持久化（同经纬线做法） |
| `lib/core/closed_shape.dart` | **新增** | **「封闭图形」抽象**（名字 / 类型 / 楼层 / 取环）：让命中、渲染、导出、楼层过滤都只认它 —— area 的实现走**组环**（可能失败），polygon 的实现走**链**（永远有效）。这是 D19 两表的**收口点**（§4.5），不加它就会到处写 `if (是 area) … else …` |
| `lib/core/hit_test.dart` | 453 | ⚠️ **从下面那行"不动"里挪出来**：`hitArea` 现在只收 `AreaRow`，要扩成收「封闭图形」 |
| `lib/core/shape_convert.dart` | **新增** | **两种构造的互转**（§4.5）：`polygonToArea` / `areaToPolygon`，含组环失败处理、**引用检查**（线被别的区域共用？挂着门/要素？）。纯 Dart，可脚本验证 |
| `tool/migrations/v11_to_v12.sql` | **新增（已完成）** | **迁移脚本**（§7.0）：已在真库副本上跑通全部结构自检。实施期 1 时把它里面的语句搬进 `schema.dart` 的 `userV12Statements` |
| **不动** | | `polyline.dart`(287)、`ring.dart`(127)、`geometry.dart`(241)、`floor_set.dart`(128)、`point_density.dart`(139)、`route_crossing.dart`(185)、`gate_snap.dart`(51)、`graticule.dart`(40)、`line_feature_layout.dart`(293)、`osm_prep.dart`(412)、`basemap_packs.dart`(373) |
| `tool/checks/*.dart` | 3192 | 7 个脚本全部失效（都 import `models.dart`/`schema.dart`）→ 另写一个三层分域校验脚本 |
| `test/**` | — | **不管**（AGENTS §2.1） |

**为什么"命中与渲染"改动很小**：`hit_test.dart` 的公开函数收的都是
`List<PointRow>` / `List<LineRow>` 这样的**模型列表**，只要 DAO 把本域（或跨域合并）的查询结果喂进去，
UI 一行都不用动。**代价集中在 DAO 与 schema。**
唯一例外是**封闭图形**：`hitArea` 现在只认 `AreaRow`，有了 polygon 之后要改成认
`closed_shape.dart` 那个抽象（否则每处调用点都要 `if`）。

**一份代码怎么服务三张表**：三套表的命名是**统一后缀**
（`_points` / `_lines` / `_line_bends` / `_areas` / `_area_lines`），
所以 DAO 可以用「域前缀」参数化 —— 物理上真分表，代码上仍只有一份。
表名前缀的来源收口在一个枚举里（`MapDomain`），并用校验脚本守
「19 张表都存在且列齐全」，与 `basemap_pack/validate_pack.dart` 是同一套做法。

---

## 10. 实施分期（建议）

| 期 | 内容 | 出口判据 |
|----|------|---------|
| 0 | ~~本章文档 + 一次性校验脚本~~ → **✅ 已完成**：`tool/migrations/v11_to_v12.sql` 在**真库副本**上跑通，19 张表行数与 §7.4 逐项吻合、链与老库顺序逐位相同（§7.0） | 已达成 |
| 1 | **用户在本机真库上跑迁移脚本**（跑完 app 会打不开，正常）→ 然后 `schema.dart` v12 + DAO（先让**老功能**在新结构上跑通） | `dart analyze lib/` 干净；用户在 app 里能照常看地图 |
| 2 | 编辑控制器 / 表单 / 渲染适配（工具按域分派、区域只收本域线） | 用户在 Linux 上手工实测编辑全流程 |
| 3 | 备份 v10 + 老文件导入映射（§8.2） | 真库 v12 导出 → 导入空库 → 与源库逐表对齐 |
| 4 | 用户手工验收 + 清理孤立点等新动作 | 见 §12 |

> 每一期结束都必须 `dart analyze lib/` 干净（AGENTS §3.4），且不留"中间态编译不过"。
> 期 0 的脚本**先写**，是本章最像"高风险部分先行"（AGENTS §3.3）的一步：
> 迁移语句的真假，只有真库副本说了算。

---

## 11. 未决问题

| # | 问题 | 现状 |
|---|------|------|
| R-23-1 | **换路口（`crossing`）仍塞在 `route_width` 里** | 21 章用户明确要求做成"第 6 种路宽"，但语义上它是"一处路口"而非"一段路"。新结构里它仍是 `way_lines.route_width` 的一个值。要不要拆成独立标志，等 M2 建图时一起定 |
| R-23-2 | `areas.is_active` / `color_override` / `sort_order` | 真库全 1 / 0 / 0，即从未改过。本次**保留**（UI 有语义：停用态会改透明度）。`dismantle_date` 与 `ext` 则**删除**（0 值 + 语义已死） |
| R-23-3 | `world_marks.name` | 记录点要不要名字。保留（22 章的记录点面板本来就有名字位） |
| R-23-4 | 三层是否各自单独备份 | 新结构让"只导出路网"变得自然，但 11 章定的是整体导出。暂不做 |
| R-23-5 | Android 老库（`app_flutter/map.db`） | 平台暂缓（09 章），但 v12 迁移代码必须在两端都能跑 |
| R-23-6 | `world_marks` 是否该叫别的名字 | 表名可改，语义不变 |
| R-23-7 | **轨迹进不进备份** | 见 §8 末条。体量与别的东西差一个量级，**必须在动手做备份 v10 之前定** |
| R-23-8 | **轨迹保留策略** | `way_marks` 是唯一会无限增长的表（一年 ≈ 23 万行 / 230 MB）。候选：① 已处理满 30 天自动清理；② 只保留最近 N 趟；③ 纯手动。**红线 §6.15 要求实现前定下来** |
| R-23-9 | **抽稀算法** | 转成路线时怎么抽：Douglas–Peucker（保形状）？按 `accuracy` 加权？按转角阈值（`turnAngleDegreesAt` 已备好）？倾向：`core/track.dart` 先只做「精度过滤 + 距离抽稀」，DP 等实测出问题再上 |
| R-23-10 | **Linux 上无法采集** | `libre_location` 只有 android/ios 实现（09 章 P1）。所以「真实采集」只能 Android 验收；但**存储 / 渲染 / 转换**可以在 Linux 上用**合成轨迹**验收（§12.3），别把整条链路都推给 Android |
| R-23-11 | **天桥 / 高架的分层** | GPS 高程不可信（§4.1 的警告），轨迹**判不出楼层**。倾向：在「转成路线」的表单里让用户指定 `floors`，而不是猜 |
| R-23-12 | **行政域要不要也有"由点围成"的多边形** | 本轮只加了 `world_polygons`（用户要求）。若 `zone_areas` 也需要，照 `<域>_polygons` + `<域>_polygon_points` 复制一份即可（不要跨域引用，D2） |
| R-23-13 | **多边形的环绕向要不要规范化** | 环没有头也没有固定方向，`world_area` 组环出来的起点/方向也不确定。对填色、面积、质心、命中**都无影响**；只有导出成 GeoJSON 时环的起点会不同（同一环的旋转/反向）。倾向：不规范化，导出时就按链的顺序写 |
| R-23-14 | **转换动作放在哪个入口** | `polygon → area` 与 `area → polygon` 需要 UI 位置（形状面板的动作？还是编辑模式的一个工具？）。倾向：放**形状面板**（与 20 章"加拐点"同款，属于"这条形状还能变成什么"），且转换前必须弹确认（爆炸半径见 §4.5） |
| R-23-15 | **多边形能不能有"孔"** | 今天的区域模型不支持孔（04 章提过"圈地与打孔"）。多边形要不要支持内环，取决于是否真需要"小区里挖掉一栋楼"。倾向：不做，用两个图形近似 |

---

## 12. 验收方式

### 12.1 迁移前的现状核对（可原样复现本章所有数字）

```bash
DB=~/.local/share/com.example.map/map.db
sqlite3 "$DB" "pragma user_version;"                    # 11
sqlite3 -header -column "$DB" "
  select 'points',count(*) from points union all select 'lines',count(*) from lines
  union all select 'areas',count(*) from areas union all select 'area_lines',count(*) from area_lines
  union all select 'gates',count(*) from gates union all select 'entities',count(*) from entities
  union all select 'line_bends',count(*) from line_bends;"
# 1.3 的事故：软删点仍被活线引用
sqlite3 -header -column "$DB" "
  with used_live as (select start_point_id pid from lines where deleted_at is null
    union select end_point_id from lines where deleted_at is null
    union select b.point_id from line_bends b join lines l on l.id=b.line_id where l.deleted_at is null)
  select p.id,p.deleted_at from points p where p.deleted_at is not null and p.id in (select pid from used_live);"
# 7.2 的 seq 空洞
sqlite3 -header -column "$DB" "
  select line_id,min(seq),max(seq),count(*) from line_bends group by line_id
   having min(seq)<>1 or max(seq)<>count(*);"          # line 22: 1 / 105 / 104
```

### 12.2 迁移后（预期见 §7.4）

```bash
sqlite3 "$DB" "pragma user_version;"                    # 12
sqlite3 -header -column "$DB" "
  select 'way_points',count(*) from way_points
  union all select 'way_lines',count(*) from way_lines
  union all select 'way_line_bends',count(*) from way_line_bends
  union all select 'world_points',count(*) from world_points
  union all select 'world_lines',count(*) from world_lines
  union all select 'world_line_bends',count(*) from world_line_bends
  union all select 'world_areas',count(*) from world_areas
  union all select 'world_area_lines',count(*) from world_area_lines
  union all select 'world_gates',count(*) from world_gates
  union all select 'world_entities',count(*) from world_entities
  union all select 'world_marks',count(*) from world_marks
  union all select 'way_marks',count(*) from way_marks;"
# 拐点链完整性：下面两条都应为 0 行
sqlite3 -header -column "$DB" "
  -- 分叉（一个前驱被两行引用）——UNIQUE 已挡住，这里是复核
  select line_id, before_point_id, count(*) from way_line_bends
   group by line_id, before_point_id having count(*) > 1;
  -- 重复点（PK 已挡住，复核）
  select line_id, point_id, count(*) from way_line_bends
   group by line_id, point_id having count(*) > 1;"
# 悬空前驱（应为 0 行）
sqlite3 -header -column "$DB" "
  select b.line_id, b.before_point_id from way_line_bends b
   left join way_points v on v.id = b.before_point_id where v.id is null;"
# 端点唯一性（应为 0 行）
sqlite3 -header -column "$DB" "
  select id from way_lines where start_point_id = end_point_id;"
# 关联表不该有顺序列（D14）—— 下面这条应当**报错 no such column**
sqlite3 "$DB" "select sort_order from world_area_lines limit 1;"
# ⚠️ 「恰好一个头 / 无环 / 能走到 end / 拐点全部可达」SQL 查不出来
#    → 交给 tool/checks/three_domain_check.dart（见 §12.4）
# 零跨域（应为 0）
sqlite3 -header -column "$DB" "
  pragma foreign_key_check;"
```

### 12.4 ✅ 链与分域的自检脚本（`tool/checks/three_domain_check.dart`）

上一条那句「SQL 查不出来」的部分由这个脚本兜住 —— 它是本章的**可执行判据**。
2026-09-14 在真库副本上跑：**76 通过 / 0 失败**。

```bash
cd ~/Projects/flutter/map
dart run tool/checks/three_domain_check.dart \
  logs/check_ro.db          # 建议传副本；不传则用真库（只跑 SELECT）
```

它验四件事（**不是** `test/` 下的测试文件，见 AGENTS.md §1）：

| # | 内容 | 抓的是哪种事故 |
|---|------|----------------|
| 1 | 链原语：往返 / 插点 / 删点 / 反转 / 重设端点 / 与环的兜底 | 原语写错会**静默画出另一条形状**，不报错 |
| 2 | **真库每条线真的走一遍链** | 「点数 = 拐点数 + 2」对不上 = 少接终点；点不在同域 = 跨域引用 |
| 3 | 域隔离：三域 id 撞号数、**撞号已波及多少线端点** | 「选择没带域」这类 bug 的症状是**隐性的**（共享点坐标当前相同） |
| 4 | 封闭图形：环组装 / 断口 / `polygon ⇄ area` 双向门槛 | 坏环被默默画成半个面；转换丢点丢线 |

> ⚠️ **另外 7 个 `tool/checks/*.dart` 脚本已全部失效**（都 import 了 `LineKind` /
> `vertices` / `areas` 那套老模型）。它们记录的是 18~22 章的验证思路，
> 需要哪个再照本章脚本的骨架（`sql()` 直连 sqlite3、`check()` 计数）逐个搬过来，
> 不要当成还能跑的东西。

### 12.3 用户手工实测清单

1. **升级前先备份**：确认 `map.db.pre_v12.bak` 与一份 `.mapexport.json` 都已生成；
2. 升级后**浏览态**：地图外观与升级前逐项一致，**除了多出 2 条路线**（§7.6 的修复）
   与**少了区域 1 的填色**（§7.5 的决策）；
3. 编辑模式三层（路网/世界图/行政区域）各自：落点 → 连线 → 加拐点 → 改属性 → 删除；
4. **端点编辑（本轮新增需求，§4.4）**：
   - **删起点 / 删终点** → 线变短，那个点**仍在**（点面板还能选到它），别的线不受影响；
   - **从头部 / 尾部添加端点** → 线变长；
   - **重设起点 / 终点** → 接到另一个已有点上；确认**反转线**同样可行；
   - **拒绝路径**：一条线只剩两个端点（没有拐点可顶上）时要删端点，必须**被拦住**，
     并提示「要删就删整条线」（D11）；
   - 反例（不许发生）：删掉一个端点后**整条线消失**（这是今天线 3/4 的症状）；
5. 点面板删除一个**被线用着**的点：必须先报出「会影响 N 条线」再让你确认（D10）；
6. 世界图：门与**世界要素**（店铺）各建一个，确认落在界线上、能被选中、能删；
   若将来加了楼栋/单元/常送点/停车点，确认**同位置同名的不同类型互不顶掉**（D18）；
7. 区域：用**界线**围一个新区，确认能闭合；再试着用**路线**去围 —— 应当被拒绝（§7.5 的教训）；
8. **两种封闭图形（§4.5）**：
   - 「一笔画圈地」现在应当产出**一个多边形**（`world_polygons`），
     确认**没有多出任何界线**（这是本轮的行为改变，§5）；
   - 多边形的环上增删点（在点 x 之后插入 / 删环上的点），确认形状跟着变、**没有头**的概念；
   - 只留 2 个点时必须**被拦住**（最少 3 个）；
   - `polygon → area`：界线数 +N、多边形消失；再 `area → polygon`：多边形回来、
     **那些线一条都没少**（红线 §6.16）；
   - `area → polygon` 的**拒绝路径**：拿一个组环失败的开口形状（或那两条"路线当边"的
     区域 1）去转，必须**被拒绝并说明原因**；
   - 给多边形挂门：**应当挂不上**（D21），提示"先转成区域"；
9. 记录模式：落几个点，确认浏览态只显示未处理的；标记已处理后消失；
10. 备份导出 → 清空 → 导入：逐表行数与源库一致；
11. **老备份文件**（迁移前导出的那份）导入空库：确认 §8.2 的映射正确；
12. **轨迹（`way_marks`，§4.1）** —— ⚠️ **真实采集只能在 Android 上验**
    （`libre_location` 没有 Linux 实现，R-23-10），但下面这些 Linux 上就能做：
    - **合成轨迹**：用脚本往库里灌一段造出来的轨迹（含正常的、精度差的、等红灯堆叠的
      三种点），然后验**显示**与**转换**——这样"存储 / 渲染 / 转换"不必等 Android；
    - 浏览态：轨迹画成**一条淡线、不画点**；开关关掉后它应该整个消失（§6.14）；
    - **转成路线**：选中一段 → 抽稀降噪 → 得到一条路线；好点被保留、坏点被剔掉、
      停车堆积被合成成一个点；转换表单里能选楼层（R-23-11）；
    - 转换后该段 `processed = 1`，浏览态不再显示；**未处理的段不会被清理**（§6.15）；
    - 点**不该**能吸附到轨迹点上：进「连线」工具点轨迹附近，应当吸不到（§6.13）。
    Android 侧另需实测：权限、后台定位、锁屏后是否还在记、一趟的真实点数与耗时。

---

## 13. 一句话总结

> 用户层从「7 张按类型混装的表」改成「**路网 / 世界图 / 行政区域**三个域、每域自带
> 点表·线表·拐点链」，共 **19 张表**；**域之间零引用**。
> **端点的特殊性保留**（D4）：`<域>_lines` 带 `start_point_id` / `end_point_id` 两列，
> 拐点存在 `<域>_line_bends` 里、**而且是链**（D13：每行记「我的前驱」而不是「我是第几个」）——
> 插入/删除变成 O(1) 指针操作，`seq` 与它的空洞问题一起消失；
> 读出口是走链得到 `pointIds`，写入口是 §4.4 那七个动作。
> **封闭图形有两种构造**（D19）：`world_areas` 由**线**围成（边是共享实体，有材质、能挂门）、
> `world_polygons` 由**点**围成（边没有实体），两者**同一语义、可互相转换** ——
> 所以它们不会退化成"同一件事两套不相通的表示"（P1）。
> 新增 **`way_marks`（我自己的行驶轨迹，D15）**：一行一个采样点、按 `trip` 分段，
> 是**原始采集数据**而非几何 —— 不进点表、不参与吸附，唯一出口是「转成路线」。
> 于是 `LineKind`、`AreaType.isVirtual`、`PointKind`、`PointSource`、`EntityType`
> 以及 `hasMaterial`/`hasRouteWidth` 这些判据**全部消失**——**表名就是那个类型**。
> 代价是一次大迁移（真库 698 点 / 62 线 / 470 拐点 / 2 区域 / 1 门 / 1 店铺，轨迹与多边形从零开始），
> 换来的是一套**每条规则都只存在一处**的结构。
