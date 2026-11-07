# 第十四章 记录模式、点的类别、界线与路线

> 状态：**编码完成，待本机验收**（2026-09-13）。

---

## 1. 需求（用户原话）

> 把**编辑我的地图按钮分成两个按钮、记录和编辑**。
> 点击**编辑**即为先前编辑我的地图的效果；
> 点击**记录**需要用户开启获取设备定位，会记录当前设备定位的点，**用户可以编辑该点**。
> 然后**点分成辅助点（默认，辅助构成其它地图要素）、店铺、门、路点**几类。
> 然后线扩展出**路线**这一种线。原本的线称为**界线**。
> **界线和路线各自独立运作，只是会同时渲染在地图上。**

---

## 2. 拆成两个按钮

| 按钮 | 干什么 | 为什么和另一个分开 |
|------|--------|--------------------|
| **记录**（红） | 采当前位置（或点地图）落一个点，落完立刻能改名/改类别 | 跑单时顺手一按，一秒一次 |
| **编辑**（绿） | 画点/线/面/店铺/墙体/门（第十二、十三章那套） | 坐下来慢慢描地图 |

两者是**不同的活**，所以是两个按钮而不是一个模式里的两个工具。

### 2.1 记录模式的做法（与字面要求的一点偏差，说明理由）

用户原话是"点击记录……会记录当前设备定位的点"。我做成**记录模式**而不是一次性动作，
理由是：一次只能记一个点的话，连着采一条街要重复"按按钮 → 授权检查 → 等定位"，
而**连着采同类点正是这个功能的主场景**。

记录模式的形态：

- 进模式时立刻检查定位可用性，**并把结论讲清楚**（不静默失败）；
- 顶部专用工具条：`下一类点` 的类别 chips + **「记录当前位置」** 按钮 + 定位精度；
- 点地图任意位置 = 在那个位置落一个点；
- 每落一个点立刻弹表单（改名 + 改类别），保存后**留在记录模式**继续；
- 结束按「完成记录」。

### 2.2 ⚠️ Linux 上没有定位

`libre_location` 在 pubspec 里**只声明了 android/ios**，桌面端调
`MethodChannel('libre_location')` 必抛 `MissingPluginException`。
第九章已经加了平台守卫（`PlatformUtils.isLocationSupported()` → 仅 Android），
所以 Linux 上 `locationStateProvider` **永远是 null**。

处理方式：
- 进记录模式时明确提示「这个平台没有定位能力……当前可以直接点地图落点记录」；
- 「记录当前位置」按钮在 Linux 上**置灰**；
- 点地图落点在所有平台都可用 → **记录的完整链路（落点 → 表单 → 入库 → 渲染 → 再编辑）
  在 Linux 上能端到端跑通**，只有"采 GPS 坐标"这一步要等 Android。

---

## 3. 点的类别（schema v6）

`points.kind` 从"结构角色"换成"语义类别"：

| 旧值（v5 及更早） | 新值 | 含义 |
|---|---|---|
| `vertex` | `auxiliary` **辅助点** | **默认**；用来拼出线、区域等其它要素 |
| `entity_point` | `waypoint` **路点** | 路线上的一个点 |
| `gps_log` | `auxiliary` | 归到辅助点，用户可改 |

新增两类：`shop` **店铺**、`gate` **门**。

**与 `entities` / `gates` 的分工**（容易混，这里说清）：

| 想干什么 | 用哪个 |
|---|---|
| 随手标一个位置 | **点**（`points`，一个坐标 + 类别 + 名字） |
| 给一家店记门牌号/门面宽 | **线上要素**（`entities.entity_type='shop'`，挂在线上） |
| 给一个门口记门禁/车型/时间窗 | **门**（`gates` 表） |

点是最轻的一等公民。想要完整属性时，把它挂到线上（店铺/墙体）或走门表单（门）即可。

新增 `points.source`：`manual`（手画）/ `gps`（定位记录）。
分开记是因为两者可信度不同 —— GPS 点带着 `accuracy`，手画的点是你自己认的。

### 渲染

点按类别上色：辅助点留白（它是骨架，不该抢眼），店铺/门/路点各一色。
有名字的点显示标签，没名字的只显示圆点。

---

## 4. 界线与路线

`lines.kind` 从"能不能走"换成**界线和路线**：

| 旧值 | 新值 | 用途 | 属性轴 |
|---|---|---|---|
| `area_boundary` | `boundary` **界线** | 围合区域 | `boundary_type` 材质（墙/铁栏/河道/**软边界**…） |
| `route_edge` | `route` **路线** | 自己跑的路径 | `cost_class` 通行代价（可骑行/推行/步行/台阶） |

**为什么改名**：用户从来不是按"能不能走"理解这两类线的，而是
"这条是围栏、那条是我走的路"。而"能不能走"其实是**材质/代价**那两根轴的产物
（软边界就是能穿过的界线）—— 把它塞进 `kind` 是概念错位。

**各自独立运作**：

- 工具栏里 **「界线」和「路线」是两个独立的工具**，不会混；
- 「围合区域」只认界线；
- 渲染上分开上色：界线按材质色、偏粗；路线统一蓝色、偏细。一眼能分清"这堵墙"和"我常走的那条路"；
- 线的属性表单里可以直接切换类型（表单会跟着换说明文字）。

---

## 5. 迁移（v5 → v6）

纯枚举值重命名，**没有结构变化**，三条语句：

```sql
ALTER TABLE points ADD COLUMN source TEXT NOT NULL DEFAULT 'manual';
UPDATE points SET kind = CASE kind WHEN 'entity_point' THEN 'waypoint' ELSE 'auxiliary' END;
UPDATE lines  SET kind = CASE kind WHEN 'route_edge' THEN 'route' ELSE 'boundary' END;
```

> **第一条是被校验脚本逮出来的 bug**：最初只写了三条 UPDATE，
> 但 `points.source` 是 v6 才有的列，**老库不补 ADD COLUMN 会直接报
> `no such column: source`** —— 也就是说所有老用户升级都会失败。
> 校验脚本用真实 SQLite 造了个 v5 库跑迁移，一下就暴露了。

**已用真实数据验证**：造含 4 个点（vertex/entity_point/gps_log/vertex，其中一个带精度）
+ 3 条线（area_boundary/route_edge×2）的 v5 库 →
迁移后**点一个不少**、类别映射正确、`source` 全为 `manual`、精度保留、旧枚举无残留。

---

## 6. 备份兼容

`points` 的 feature 新增 `source` 字段（可选）。`kind` 的**新旧取值都认**
（`PointKind.fromStorage` 把 `vertex`/`entity_point`/`gps_log` 映射到新类别），
所以 **v1~v4 的备份文件照样能导入**，不需要升备份格式版本。

---

## 7. 落地文件

| 文件 | 动作 |
|------|------|
| `lib/core/models.dart` | `PointKind` 换成四类 + `PointSource`；`LineKind` 换成界线/路线；`PointRow.source` |
| `lib/core/schema.dart` | **v6**：`userV6Statements` |
| `lib/data/app_repository.dart` | v6 迁移分支；`LineKind.boundary/route` |
| `lib/core/export.dart` / `import.dart` | 点带 `source` |
| `lib/features/editor/edit_mode_controller.dart` | `recording`/`recordKind`；`recordPointAt`/`recordCurrentLocation`；`boundaryLine`/`routeLine` 两个工具；`savePoint(名字+类别)` |
| `lib/features/editor/feature_forms.dart` | 点表单加**类别选择**与来源/精度显示；线表单的"能不能走"换成"界线/路线" |
| `lib/features/map/map_page.dart` | 两个主按钮；记录模式专用工具条；点按类别上色；界线/路线分开渲染 |

---

## 8. 取舍与未做

| ID | 项 | 说明 |
|----|----|------|
| R-14-1 | **记录做成了"模式"而非一次性动作** | 见 §2.1。若要严格的一次性，改 5 行即可 |
| R-14-2 | **Linux 采不到 GPS** | `libre_location` 无 Linux 实现。要点地图落点的全套链路在 Linux 上可用（见 §2.2） |
| R-14-3 | 点类别与线上要素是两套 | 「店铺点」和「线上的店铺」不是同一个东西（见 §3 的分工表）。需要时可以加"把这个点升级成线上店铺" |
| R-14-4 | 路线还没有"沿线串成一串"的编辑 | 现在是一条线一条线地画；后续可加"选中若干路线 → 合成一条路线" |
| R-14-5 | 「区块」Tab 已删除 | 见第十二章 §4.1b。区块的浏览/编辑全在编辑模式里 |

---

## 9. 请在本机验收

```bash
cd ~/Projects/flutter/map
flutter pub get
dart analyze lib/          # 期望 No issues found!（0 error / 0 warning / 0 info）
flutter run -d linux
```

**A. 两个按钮**

1. 地图右下角应是**两个按钮**：红色「记录」在上、绿色「编辑」在下；
2. 点「编辑」→ 与之前完全一样（工具条、10 个工具、完成编辑）。

**B. 记录模式（Linux 上跑得通的部分）**

1. 点「记录」→ 顶部出现**记录模式**工具条，并提示"这个平台没有定位能力……"；
2. 「记录当前位置」按钮应**置灰**（Linux 无定位）；在有定位的设备上它是可点的；
3. **点地图上任意位置** → 立刻弹出点表单，标题是「记录了一个点」；
4. 填名字、选类别（辅助点/店铺/门/路点）→ 保存 →
   **仍在记录模式**，可以继续点下一个；
5. 连点三四个点，分别选不同类别 → 地图上这些点的**颜色应该各不相同**
   （辅助点留白、店铺青、门绿、路点蓝）；
6. 按「完成记录」退出。

**C. 点的类别可编辑**

1. 编辑模式下用「选择」点一个点 → 面板应显示 `辅助点 · 手动 · 连着 N 条线`；
2. 「改名」→ 表单里有**类别 chips** → 改成「店铺」→ 保存 → 地图上的点颜色与标签跟着变。

**D. 界线与路线**

1. 编辑模式的工具条里应有**「界线」和「路线」两个独立工具**；
2. 用「界线」连两个点 → 表单里"线的类型"预选**界线**；
3. 用「路线」连另外两个点 → 表单里预选**路线**，且那条线画出来是**蓝色细线**；
4. 地图上两条线**同时显示**，颜色区分明显；
5. 「围合区域」工具只认界线：点一条路线应该提示"这条线跟已选的线没有连在一起"
   或选不上（路线的端点若与已选界线相连则仍可选中 —— 这是按几何判的，符合预期）。

**E. 升级不丢数据**

```bash
sqlite3 ~/.local/share/com.example.map/map.db \
  "pragma user_version;                                  -- 期望 6
   select kind, count(*) from points group by kind;      -- 应无 vertex/gps_log
   select kind, count(*) from lines group by kind;       -- 应无 area_boundary/route_edge
   select count(*) from points where source is null;"    -- 期望 0
```
