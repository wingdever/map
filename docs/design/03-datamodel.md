# 第三章 数据模型设计（v0.1 草案）

> 依据你提供的「三层结构 + 点/线/实体表」原始设计细化。保留你定义的核心字段，补充 ID 策略、坐标约定、索引、软删除与一致性约束。正文用表字段命名（snake_case 存储，Dart 侧 camelCase 映射，见 §7）。

## 1. 总体 ER 关系

```
points (几何锚点，多边形顶点 / 独立点位)
   │1:N
lines (线段：闭合多边形边 / 可路由道路边 / 常送点承载线)
   │
   ├─N:1─ areas.boundary（区块边界 = 若干闭合边集合）
   │
entities ──(绑定线, line_index/line_weight)→ 定位在线上某处
   │         或 绑定独立坐标点
gates ── area_id → areas ；location 吸附在 area 某条 boundary line 上
```

数据在逻辑上分两族：

1. **区块族**：`areas` + `gates`（封闭区块与出入口，MVP 核心）；
2. **线网族**：`points` + `lines` + `entities`（底网几何 + 可寻路边 + 线上实体），同时作为区块边界的几何载体。

### 1.1 两层线网的澄清（重要）

你给的 `lines` 表我拆成**两种语义共存一张表**，用 `kind` 区分：

| kind | 含义 | 用途 |
|------|------|------|
| `area_boundary` | 区块边界线段（组成闭合环） | 渲染高墙、门吸附目标、寻路"不可穿越边界" |
| `route_edge` | 可通行的路（骑行/推行/步行） | 底网边或自绘巷道，参与寻路 |

一个 `area` 的多边形由若干 `lines(kind=area_boundary)` 首尾相接成环，而非直接存 GeoJSON 坐标数组——这样门能"吸附到某条边界线并记忆它"，边界被编辑移动时门可联动。

> 待你确认（Q-01）：区块几何是**纯几何环（自持坐标）**还是**由线段组成（引用共享点）**？本稿采用"引用 lines/points"，好处是支持共享边界与门联动；代价是实现更复杂。若你更希望简单，可改为 area 自持 JSON 坐标数组（04 章按需调整渲染与吸附实现）。

## 2. 通用约定

- **ID**：一律 `INTEGER PRIMARY KEY AUTOINCREMENT`（你此前 areas/gates 用 string 示例 id，改为自增整型；`name` 可重复、不做唯一键）。显示用短码如 `area_12` 仅作 UI 别名。
- **坐标**：仅存 **WGS-84 经纬度** `lat REAL, lng REAL`；无 GCJ。多边形顶点顺序=用户绘制顺序（默认顺时针存储，不强制校验）。
- **时间**：一律本地时间（Asia/Shanghai）；存 `HH:MM` 字符串或分钟整数。
- **软删除**：统一 `deleted_at INTEGER NULL`；删除=标记，避免误操作不可恢复，并支持导出过滤。
- **审计**：`created_at`, `updated_at`。
- **版本**：`schema_version` 表，供 migration。

## 3. 线网族表（points / lines / entities）

### 3.1 坐标点表 `points`（你原表 #0 扩展）

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER PK AUTOINCREMENT | |
| lat | REAL NOT NULL | WGS-84 |
| lng | REAL NOT NULL | WGS-84 |
| kind | TEXT | 点用途：`vertex`(线端点/多边形顶点), `entity_point`(独立实体点), `gps_log`(快采原始点, 可选) |
| accuracy | REAL NULL | 采集时 GPS 精度（米），快采参考 |
| created_at / updated_at / deleted_at | INTEGER | 审计 |
| ext | TEXT NULL | JSON 扩展（如平台来源、照片引用） |

### 3.2 线段表 `lines`（你原表 #1 扩展）

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER PK | |
| kind | TEXT NOT NULL | `area_boundary` \| `route_edge`（见 §1.1） |
| start_point_id / end_point_id | INTEGER FK→points | 两端点 |
| area_id | INTEGER FK→areas NULL | kind=area_boundary 时所属区块 |
| cost_class | TEXT NULL | kind=route_edge 用：`ride`(可骑行) `push`(推行) `walk`(仅步行) `stair`(台阶) |
| one_way | INTEGER 0/1 | 骑行方向约束（默认 0；巷子/小区单行） |
| note | TEXT | 备注（如"仅早晚高峰能过"） |
| created_at / updated_at / deleted_at | INTEGER | |
| ext | TEXT | JSON 扩展（来源=osm/user/修正；osm 原始 id 等） |

**派生属性**：起点/终点、长度(米)、方向角在读取时由 points 计算，不入库（除非大数据量需要加速索引，再物化）。

### 3.3 线上实体表 `entities`（你原表 #2 细化为「常送点/门牌等」）

线上实体 = 沿一条线定位的"第几个"实体；用于**巷道上的门牌/楼栋/档口**这类"路线上经过即到达"的目标。

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER PK | |
| name | TEXT NOT NULL | 名称（"雁田 三巷 12 号"、"大运城邦 3 栋 2 单元"） |
| desc | TEXT | 补充说明（门禁备注/客户特征等，脱敏原则下自用） |
| entity_type | TEXT | `door`(门牌/户) `building`(楼栋) `unit`(单元) `stall`(档口/店铺) `gate_landmark`(地标) `delivery_point`(常送点) `parking`(停车点) 等 |
| line_id | INTEGER FK→lines NULL | 绑定承载线（route_edge 或 area_boundary 内侧参考） |
| line_index | INTEGER NULL | 该线上第几个实体（顺序号；你原定义） |
| line_weight | REAL NULL | 线上位置权重 0..1（沿 line 起点→终点的归一化位置；你原定义"占线宽"我理解为沿线比例，请确认 Q-02） |
| side_offset_m | REAL NULL | 与线中心垂直偏移（米，正=左 负=右；0=线上） |
| point_id | INTEGER FK→points NULL | 若不用线定位，直接用独立坐标点 |
| gate_id | INTEGER FK→gates NULL | 若实体即"某门附近的目标"，可反指 |
| tags | TEXT | JSON：楼层、门牌、电话前缀(脱敏可选)、客户备注 |
| created_at / updated_at / deleted_at | INTEGER | |

**定位规则**：`point_id` 与 `line_id` 二选一（校验约束）；用 line 定位时运行时由几何模块计算实际经纬度 = `line(start,end) 上 line_weight 处 + side_offset_m 垂直平移`。

> 待确认（Q-02）：原稿 `line_weight` 注释为"占线段的宽度"。请确认其语义——A. 沿线比例位置(0..1)（本稿默认）；B. 垂直偏移量；C. 其他（如占道宽度）。这决定实体精确摆放的含义。

## 4. 区块族表（areas / gates）

### 4.1 封闭区块表 `areas`（你原表 #1 细化）

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER PK | |
| name | TEXT NOT NULL | “大运城邦一期” |
| boundary_type | TEXT NOT NULL | `wall`(实体墙) `fence`(铁栅栏) `hedge`(绿化带) `river`(河道) `construction`(施工围挡) `none`(软边界/城中村片区边界，仅提示不阻断，可选) |
| boundary_height | TEXT NULL | “2 米铁栏”“不可翻越”“矮灌木” |
| is_active | INTEGER 1/0 | 是否生效（临时围挡可关闭） |
| dismantle_date | TEXT NULL | boundary_type=construction 时的预计拆除日期 |
| color_override | TEXT NULL | 蒙层颜色覆盖（默认按 boundary_type 取，见 04 章） |
| sort_order | INTEGER | 图层叠放排序（小区叠在城中村上时先画谁） |
| created_at / updated_at / deleted_at | INTEGER | |
| ext | TEXT | JSON 扩展 |

**区块边界几何** = 若干 `lines(kind=area_boundary, area_id=本区块)` 组成的闭合环；环可用一条自闭合线或多条首尾相连。几何一致性约束见 §6。

### 4.2 出入口表 `gates`（你原表 #2 细化）

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER PK | |
| area_id | INTEGER FK→areas NOT NULL | 所属区块 |
| name | TEXT | “北门(正门)”“东侧小门”“消防通道” |
| boundary_line_id | INTEGER FK→lines | 吸附在哪条边界线上（area_boundary） |
| location | REAL(lat,lng) | 吸附后的精确经纬度（由几何模块沿 line 计算，**必须落在线上**） |
| line_weight | REAL | 在 boundary_line 上的位置 0..1（门吸附参数；若拆分多段线可加 segment 序号） |
| vehicle_type | TEXT NOT NULL | `ev_bike`(仅电动车) `pedestrian`(仅步行) `car`(汽车) `all`(全通行) |
| access_level | TEXT NOT NULL | `free`(自由进出) `guard`(保安询问/登记) `swipe_card`(需门禁卡) `face_recognition`(需人脸) |
| time_slots | TEXT(JSON) | 开放时间窗（schema 见 §5） |
| has_stairs | INTEGER 0/1 | 是否有台阶（电动车需推行） |
| is_permanent | INTEGER 1/0 | 是否为永久门 |
| entry_only | INTEGER 0/1 | 是否单向入口（只进不出） |
| is_active | INTEGER 1/0 | 临时封门开关（如疫情/维修期） |
| note | TEXT | 备注：登记流程、卡在谁那、照片引用 |
| created_at / updated_at / deleted_at | INTEGER | |

**门状态是推导值，不落库**：`open/closed/restricted/by_time/unknown` 由 05 章门禁时间引擎在查询时实时计算（依赖 current time + 车型 + 星期）。

## 5. 时间窗 JSON Schema（time_slots）

目的：MVP 支持"每日固定时段"，schema 天然扩展到"按星期/例外日"。

```json
{
  "v": 1,
  "timezone": "Asia/Shanghai",
  "rules": [
    { "days": null,            "start": "06:00", "end": "22:00" },
    { "days": [6,7],           "start": "00:00", "end": "23:59" },
    { "days": null,            "start": null,    "end": null, "closed": true }
  ]
}
```

- `rules[]` 顺序匹配：先命中先生效；
- `days`：`null`=每天；`[1..7]`=周一..周日（与 Dart DateTime.weekday 对齐）；可含例外节假日（v2 扩展 `exceptions`：日期列表强制开/关）；
- `start/end` 为 `HH:MM`（24h）；`closed:true` 表示"该规则窗口内关闭"（用于表达"周六日关闭"之类）；
- `null`（整列空）＝ 无时间管制，默认全开；
- 求值函数见 05 章 §3。

> 示例："工作日 06:00–22:00、周末 08:00–20:00" 如上所示两条规则即可表达。

## 6. 一致性约束（编辑校验规则，供表单与保存前校验）

| 规则 | 说明 |
|------|------|
| 区块边界闭合 | area 的 boundary lines 首尾成环（相邻线共享端点）；保存时校验 |
| 门在边界上 | gate.location 到其 boundary_line 的垂直距离 < 容差(默认 1.5m) |
| 门唯一性建议 | 同一区块同一位置不重复建门（提示不强制） |
| 实体定位合法 | line_weight ∈ [0,1]；line_id 存在且 kind 允许承载 |
| 区块不可自交 | 绘制时对多边形自交给出警告（允许保存但渲染提示） |
| 删除保护 | 有门的区块删除需二次确认（级联标记） |

## 7. 命名映射与迁移

- DB 字段 snake_case；Dart 模型 camelCase；ORM（drift/sqflite + json）统一映射；
- 提供 `schema_migrations` 表，后续版本字段演进走迁移文件；
- 导入导出统一 GeoJSON FeatureCollection + `properties.schema` 标记版本（06 章 §2）。

## 8. 本稿相对你原始设计的主要变更汇总（请逐条确认）

| 原设计 | 本稿变更 | 原因 |
|--------|----------|------|
| areas.id / gates.id 用 String 示例 | 整型自增主键 | 简单可靠；短码仅 UI 显示 |
| areas.geometry 直接存 GeoJSON 多边形 | 边界由 lines(kind=area_boundary) 组成，门引用 boundary_line | 支持"门吸附在线上并随边界编辑联动" |
| entities.line_weight="占线宽" | 语义待你确认（Q-02），默认=沿线比例位置 | 精度与可计算性 |
| 新增 kind / cost_class / one_way | 区分边界边与可通路边 | 寻路语义必需（05 章） |
| 新增软删除/审计/schema_version | 防止误删、支持演进 | 编辑型工具刚需 |
| time_slots 以文本窗口 | 结构化 JSON rules（v1 每日时段，可扩星期） | 机器可求值 |
