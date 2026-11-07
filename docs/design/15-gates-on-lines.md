# 第十五章 门：吸附在界线上的点

> 状态：**编码完成，待本机验收**（2026-09-13）。

---

## 1. 需求（用户原话）

> 门去掉**时间管制、台阶、单向、启用**这些属性。
> 门和店铺一样是**吸附在界线上的点**，因此添加**中心点**属性，添加**吸附的线**属性。
> 渲染时和店铺一样渲染在吸附的线上。
> 同时分成**园区门、建筑门、楼梯口**三种类型。
> 如果是**楼梯口**表示会进入其它楼层，我们即将添加编辑其它楼层的功能。

---

## 2. 旧模型的问题

门以前挂在**区块**上：

```
gates.area_id            → 属于哪个区块（NOT NULL）
gates.boundary_line_id   → 吸附在哪条边界线上（可空）
gates.lat / lng          → 坐标
gates.line_weight        → 沿线位置 0..1（吸附的副产品）
```

三个问题：

1. **"属于哪个区块"是多余的一层。** 第十二章加了 `area_lines` 之后，
   区块的成员关系已经由线表达。门挂在线上，"这个门属于谁"就该由
   **线属于谁**推导 —— 而且这样"两个小区共用一堵墙、墙上有个门"
   自然成立（那个门对两边都算数），旧模型里门只能挑一个小区。
2. **坐标与线上位置两套并存。** `lat/lng` 是权威，`line_weight` 是吸附副产品，
   两者可能不一致，还得靠 `boundary_line_id` 才知道它到底贴在哪条线上。
3. **属性太重。** 时间窗要维护一整台求值引擎（`TimeSlots`），
   而它当时唯一的消费方只是地图上旗标的颜色 —— 一个没有任何路由求值的
   "引擎"，代码量比用它的地方还大。

---

## 3. 新模型（schema v7）

门和店铺/墙体**完全同一套定位**：

| 字段 | 说明 |
|------|------|
| `line_id` | **吸附的线** |
| `center_lat` / `center_lng` | **中心点**（不在线上时渲染吸附到最近点） |
| `gate_type` | **园区门 / 建筑门 / 楼梯口** |
| `vehicle_type` / `access_level` | 保留：什么车能过、要不要刷卡登记 |
| `is_permanent` | 保留：是否为永久门（用户没有要求移除） |

**已移除**：`time_slots`、`has_stairs`、`entry_only`、`is_active`
（用户点名的四个），以及旧模型带来的 `area_id`、`boundary_line_id`、
`lat`、`lng`、`line_weight`。

### 3.1 三种门类型

| 取值 | 名称 | 差别在哪 |
|------|------|----------|
| `park` | 园区门 | 小区/园区的出入口，通向街道 —— 寻路时它是"墙上的一个洞" |
| `building` | 建筑门 | 楼栋的单元门/大门，通向楼内 |
| `stair` | **楼梯口** | **通向其它楼层**，是把不同楼层路网接起来的钩子 |

三类的差别**不在"能不能过"**（那是车型/门禁两轴的事），而在**它通向哪里**。
所以旗标颜色改成按**类型**给（园区门绿 / 建筑门蓝 / 楼梯口橙），
需要刷卡或本车型禁行的叠一个角标。

> **多楼层的钩子**：`stair` 就是为它留的。下一章做多楼层编辑时，
> 楼梯口会需要"通向哪一层"的引用 —— 现在**故意不加这个字段**：
> 楼层功能怎么建模（楼层 id？层号？一栋楼一个楼层集合？）还没定，
> 先猜一个字段形状，大概率要推倒重来。空加一列 `ALTER TABLE ADD COLUMN` 随时能补。

### 3.2 定位数学只有一份

`core/line_feature_layout.dart` 里：

```dart
LinePlacement? locateOnLine(GeoPoint? center, GeoPoint start, GeoPoint end);
```

店铺、墙体、门**都走这一个函数**。这不是洁癖 —— 三者必须在渲染、
命中检测、详情面板里算出**完全相同**的位置，否则会出现
"旗标画在这里、点这里却选不中"这类极难查的问题。
校验脚本里有一条断言专门盯这件事：
同一个中心点，门与店铺算出的 `t` 与坐标必须逐位相同。

### 3.3 时间管制去哪了

**整套删掉了**（`TimeSlotRule` / `TimeSlots` / `isOpenAt` / `untilNextOpen`），
`evaluateGate` 从"临时关闭 → 车型 → 时间窗 → 门禁"四步缩成两步（车型 → 门禁）。

理由：这些代码当时唯一的消费方就是旗标颜色，而旗标颜色根本不需要精确到分钟。
真正需要时间窗的是**寻路**（M2，05 章）—— 到那时按路由求值的需要重建。
现在凭空保留一套从没被用过的算法，只会让后来的人以为它在起作用。

> 如果这是误判（比如你其实想保留时间窗，只是暂时不想在 UI 上看到），
> 说一声 —— 字段和表单都得重加，但重建比维护错的东西便宜。

---

## 4. 迁移（v6 → v7）

重建 `gates` 表（`CREATE → INSERT SELECT → DROP → RENAME`）：

```sql
INSERT INTO gates_v7 (id, name, gate_type, line_id, center_lat, center_lng, ...)
SELECT id, name, 'park', boundary_line_id, lat, lng, ... FROM gates;
```

- `lat`/`lng` → `center_lat`/`center_lng`
- `boundary_line_id` → `line_id`
- 老门一律 `gate_type = 'park'`（园区门）—— 它们本来就都挂在小区边界上
- `area_id` **丢弃**：线的归属由 `area_lines` 表达，信息不丢

> **已用真实 SQLite 验证**：造含 2 个门（一个带时间窗/台阶/单向/停用 + 备注，
> 一个消防通道）的 v6 库 → 迁移后**门一个不少**、坐标与吸附线正确搬家、
> 车型/门禁/备注保留、九个旧列全部移除、索引重建。

⚠️ 顺带修掉的一处：`softDeleteArea` / `softDeleteLine` 里级联软删门的 SQL
原来写的是 `WHERE boundary_line_id IN (...)`，v7 之后必须改成 `line_id`
（不改的话删线时门会变成孤儿，还留在图上）。

---

## 5. 备份格式 v5

`gates` 的 feature：去掉 `area_id`/`boundary_line_id`/`line_weight`/
`time_slots`/`has_stairs`/`entry_only`/`is_active`，
补 `gate_type`/`line_id`，**中心坐标写进 GeoJSON 的 `geometry`（Point）**。

**向后兼容**：v4 及更早的备份照常可读 —— 导入侧认 `lat/lng`（老）
或几何里的坐标（新），认 `boundary_line_id`（老）或 `line_id`（新），
没有 `gate_type` 时兜底为园区门。

导入去重键也换了：从「区块键 + 名字 + 坐标」改成
**「类型 + 名字 + 所属线键」**（与店铺同一套思路）。

---

## 6. 落地文件

| 文件 | 动作 |
|------|------|
| `lib/core/schema.dart` | **v7**：新 gates DDL + `userV7Statements` |
| `lib/core/models.dart` | `GateType` 枚举；`GateRow` 重写（lineId/center/gateType；去掉九个字段） |
| `lib/core/gate_time.dart` | **删掉时间引擎**；`evaluateGate` 缩成车型 + 门禁两步 |
| `lib/core/line_feature_layout.dart` | 抽出 `LinePlacement` + `locateOnLine`；新增 `PlacedGate` / `placeGateOnLine` / `placeGatesOnLine` |
| `lib/core/hit_test.dart` | 门按吸附位置命中；没挂线的门退化为按中心点命中 |
| `lib/core/export.dart` / `import.dart` / `merge.dart` | 备份 **v5** + 新门键 |
| `lib/data/app_repository.dart` | v7 迁移；`addGate`；级联软删的列名修正 |
| `lib/features/editor/gate_form_sheet.dart` | 重写：类型/名称/车型/门禁/备注 |
| `lib/features/editor/edit_mode_controller.dart` | `GateFormRequest` 去掉 areaId；`saveGate` 新签名 |
| `lib/features/map/map_page.dart` | 门按吸附线渲染；旗标按类型上色；详情面板去掉时间窗/台阶 |

---

## 7. 取舍与未做

| ID | 项 | 说明 |
|----|----|------|
| R-15-1 | **时间管制整套删除** | 见 §3.3。若是误判，重加即可 |
| R-15-2 | `is_permanent` 保留 | 你点名的四个里没有它，所以留下。要一起删说一声 |
| R-15-3 | **楼梯口暂时只是个标记** | 多楼层编辑还没做；"通向哪一层"的字段刻意留到那一章再定 |
| R-15-4 | 没挂线的老门仍会渲染 | 退化到画在自己的中心点上，而不是丢失。编辑模式下点它 → 门表单里可以重新挂线 |
| R-15-5 | 门不再有"所属区块"直接字段 | "这个区域有几个门"改成由 `line_ids` 反查（地图面板已按新逻辑算） |
| R-15-6 | 旧的 `test/` 更加失效 | 按 `AGENTS.md` §1 不修 |

---

## 8. 请在本机验收

```bash
cd ~/Projects/flutter/map
flutter pub get
dart analyze lib/          # 期望 No issues found!（0 error / 0 warning / 0 info）
flutter run -d linux
```

**A. 升级不丢门**

```bash
sqlite3 ~/.local/share/com.example.map/map.db \
  "pragma user_version;                                   -- 期望 7
   select id,name,gate_type,line_id,round(center_lat,6) from gates;
   select count(*) from gates where line_id is null;"      -- 原来挂线的门不该变 null
```

**B. 门是"线上吸附的点"**

1. 进编辑模式 → 「界线」画一条线；
2. 工具切「门」→ 点这条线上一点 → 表单里选**类型**、填名称/车型/门禁 → 放置；
3. 门旗标应出现在**你点的那条线上**（不是鼠标位置偏出去）；
4. **把这条线的一个端点拖走**（选择工具长按拖）→ 门应该**跟着线动**
   （中心点没变，但它吸附的线变了 → 渲染位置跟着变）；
5. 换成「店铺」工具在同一条线上加一个店铺 → 两者位置算法一致。

**C. 三种类型**

1. 同一条线或不同线上，分别放**园区门 / 建筑门 / 楼梯口**三个门；
2. 旗标颜色应**各不相同**（绿 / 蓝 / 橙）；
3. 选「建筑门」或「楼梯口」时，表单下方会跟着换说明文字；
4. 选「楼梯口」时会多一行提示"多楼层编辑还没做，现在楼梯口只是一个标记"。

**D. 属性确实少了吗**

1. 门的表单里应该**只有**：名称、类型、什么车能过、门禁、备注；
2. **不该再有**：时间窗、台阶、单向、启用；
3. 点已有门 → 详情弹窗里不该再有"时间窗"和"⚠ 有台阶"两行，
   改为显示「类型」「属于：<区域名>」。

**E. 门跟着线一起删**

1. 选中一条挂门的线 → 删除 → 门应一起消失（级联）。

**F. 备份往返**

导出备份 → `schema_version` 应为 **5**，门的 feature 带
`gate_type`/`line_id` 与点几何；再导回来 → 「没有新内容可导入」。
