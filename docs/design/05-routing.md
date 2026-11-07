# 第五章 门禁时间引擎与寻路引擎（v0.1 草案）

> 本章回答两个核心问题：
> 1. "这个门，我现在（周几几点、骑电动车）能不能过？" —— 门禁时间引擎（MVP 即可交付）；
> 2. "从 A 到 B，在'高墙不可穿、门按状态开'的约束下怎么走？" —— 本地寻路引擎（M2 交付，架构本章先定）。

## 1. 领域语义（最重要，先对齐）

- **区块 = 高墙多边形**：任何路径**不得穿越**区块边界线，除非恰好经过该区块的一个"开放的门"；
- 区块**内部**存在可通行的路网（自绘 + OSM 底网内部路段），从门外到内部点必须经由门；
- 若某区块当前所有门均关闭（或车型不匹配），则该区块内部目标**视为不可达**——引擎必须明确告诉用户"此刻进不去，预计 X 点开放"，而不是给一条穿过墙的假路；
- 城中村若不设区块（或无边界），则内部巷道直接作为路网的一部分，退化为普通寻路。

## 2. 路线模型（M2 的三种边与门约束）

```
骑行边 route_edge(cost_class=ride)    —— 电动车正常行驶
推行边 route_edge(cost_class=push)    —— 下车推行（巷内、闸口、缓坡）
步行边 route_edge(cost_class=walk)    —— 纯步行段（小区内禁车处）
穿越边 = gate（连通区块外边界点 与 区块内边界点）
```

- 骑行时：ride 代价最低，push/walk 为高代价"可走"；步行模式：walk 最低；
- 门是**区块内外路网唯一的连接点**；门状态(开/关/需登记/车型)在求路时作为**约束 + 代价**双层作用：
  - 硬约束：关闭的门不可用（除非启用"绕行登记门"配置）；
  - 软代价：guard/swipe 门有绕行惩罚，避免引擎总把用户引导去需登记的门。

## 3. 门禁时间引擎（gate_time）

### 3.1 输入输出

```
输入: gate(含 time_slots, vehicle_type, access_level, is_active,
           has_stairs, entry_only), DateTime now, myVehicle=ev_bike
输出: GateStatus ∈ {OPEN, CLOSED_BY_TIME, CLOSED_TEMP, VEHICLE_DENIED,
                    RESTRICTED(guard/swipe/face), UNKNOWN}
+ 可读文案(如 "18:00 开放"、"需刷卡")  + 下一开放时刻 nextOpen(可选)
```

### 3.2 求值顺序（伪代码）

```
1  gate.is_active == false            → CLOSED_TEMP
2  myVehicle 不满足 gate.vehicle_type → VEHICLE_DENIED
    (ev_bike 满足 ev_bike/pedestrian/all；不满足 car)
3  time_slots 为空(null)              → 进入第4步前先跳过时间判断
4  解析 rules：匹配 now(weekday 与时间) 的第一条规则
     - 命中 closed:true 或 时段外 → CLOSED_BY_TIME
     - 命中开放时段 → 继续
5  access_level != free               → RESTRICTED
    (但时间/车型已过，RESTRICTED 表示"能过但需配合"，寻路给软惩罚)
6  否则                                → OPEN
```

- `nextOpen`：扫描当日+次日规则求最早开放时刻（用于"预计 X 点开放"文案与 M2 到达时间估算）；
- 性能：门数量小，直接逐门求值即可；如需批量做 24h 覆盖图（寻路 ETA 交叉），缓存 1440 分钟位图（按门），见 §5.3。

## 4. 路由底网构建（M2，桌面工具 + App 导入）

### 4.1 数据来源合并

```
OSM 矢量路网(桌面预过滤: 骑行/步行可通行的 highway 类别)
      │  osm_prep 工具: 裁剪到凤岗-龙岗核心矩形 → 抽稀 → 输出底网文件
      ▼
路由底网文件 (.graph: 节点+边+类别+速度)     ← App 首次启动/设置中导入
      │
用户自绘高精度层（巷道/内部路/修正边）叠加 + 区块/门层
      ▼
运行时寻路图 = osm_bottom_net ∪ user_net，切割自交，门作为跨界唯一边
```

### 4.2 OSM 类别映射（初版）

| OSM highway | 映射 | cost_class |
|-------------|------|-----------|
| residential / living_street / service / unclassified | 可骑行 | ride |
| track / path / footway / steps | 步行/推行 | walk/push |
| cycleway | 骑行 | ride |
| primary/secondary/tertiary | 骑行（电动车可走城市道路） | ride（禁摩路段后续在自绘层标注修正） |

- **优先在自绘层修正**：本地"禁摩/禁电动车"路段、实际不通的 OSM 错误、门内实际走向，以 user 层为准覆盖。

## 5. 寻路引擎设计

### 5.1 图模型

- 顶点：路网节点 + 门节点 + 常送点（挂接到最近可走边）；
- 有向边：
  - 路网边（含 one_way）；
  - **门穿越边**：boundary_line 两端点 ∈ 图 → 在门处人为连通（若路网恰未在门处设节点，则门向最近路网节点加短连接边，模拟"到门口—进门—到内部最近路网点"）；
- 区块处理：**不把整块挖空**——区块内部的正常路网保留；只是**边界线的穿越唯一来自门**。这样"进去之后在内部找楼栋"天然可解。

### 5.2 代价函数（简化）

```
cost(edge) = length_m × 模式系数(mode_factor) + 转向/爬坡惩罚(可选)
mode_factor: ride=1.0, push=1.8, walk=2.2(骑行模式)
门穿越边额外：
  + guard/swipe/face 登记惩罚(如 +60s)
  + has_stairs → 按推行边处理(骑行模式高代价)
  + 关闭门 → 硬排除(或按配置转软: 极高代价并提示)
```

### 5.3 时间相关寻路（增强，可选 M3）

目标到达时门是否开放是"到达时刻"的函数；初版以"出发时门状态"近似 + 行程时间预估反馈校正一次；不做完整 time-dependent 寻路（保持 MVP 简单）。

## 6. 「最后一公里」综合工作流（M2 起，最终形态）

以"送大运城邦 3 栋 2 单元"为例：

```
1 用户选常送点(或粘贴地址解析定位) → 终点=常送点
2 反查所属区块 area（终点在多边形内）→ 无区块则普通寻路
3 收集 area 的所有门 → gate_time 逐门求状态 → 得到“此刻可用门集合”
4 若可用门为空 → UI: "该小区当前所有门关闭，最早 06:00 开放" (红色)
5 否则 对每个可用门:
      path = 寻路(起点 → 门外锚点) + 门穿越 + 寻路(门内锚点 → 终点)
   取总代价最小者
6 输出路线: 骑到北门 → (下车)推行/步行 180m → 3栋2单元
   + 沿途提示: "北门 22:00 关闭，请留意返回时间"(反向可达校验)
```

> 反向校验：若该区块 entry_only 门或时间窗导致**出不去**（如单向门 + 夜间只出不进），对"送完要回"场景提醒用户是否换门进。

## 7. 导航呈现（M2，先文本+箭头）

- 路线在地图上高亮（骑行段蓝、推行段紫、步行段绿，与路网色一致）；
- 顶部卡片：总里程/预计时间/经过的门名与状态；
- 到门提示：距门 50m 弹出门状态卡（"北门：开放至 22:00 / 需刷卡"）+ 可选系统通知；
- 常送点到达卡片：显示点备注（"3 栋 2 单元，放前台"）。
- 语音导航不在 MVP；后续可加（TTS 播报转弯/到门）。

## 8. 引擎接口草案（供 M0 预留模块边界）

```dart
// geometry（核心原语，M0 即可实现并单测）
double distancePointToSegment(p, a, b);
LatLng projectPointToSegment(p, a, b);       // 垂足（吸附）
bool pointInPolygon(p, List<LatLng> ring);   // 射线法
List<LatLng>? polygonRingOfArea(areaId);     // 由 lines 组环

// gate_time（MVP 交付）
GateStatus evaluateGateStatus(Gate g, DateTime now, VehicleType mine);

// routing（M2）
RouteResult route({required LatLng from, required LatLng to, Mode mode});
```

## 9. 本章开放确认项

- Q-05：城中村**是否也建议圈成区块**（软边界 `none`），还是完全不圈、纯靠自绘巷道？本稿支持两种，倾向：对"有明显出入口的村"圈 none 型区块以便门控提示；对开放式片区不圈。
- Q-06：M2 是否接受**以 OSM 底网为准**的粗底图路网（个别新小区路缺失由自绘补齐）？还是宁可 M2 之前先把核心区全部手工自绘？
- Q-07：时间窗 UI 是否按 MVP 仅"每天一致"，还是直接做"周一~周日可分别设置"（后端 schema 已支持，只是 UI 复杂度差异）？
