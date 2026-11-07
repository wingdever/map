# 第七章 OSM 开放数据导入子系统（v0.2 修订）

> 目标：把开放数据平台的矢量地图数据导入 App，作为**独立的地图底图层**（只读参考、与用户层零耦合），
> 用户**在地图上单要素点选**导入层的道路/POI，逐个将其带入最后一公里图层作为初始路网边/常送点，
> 带入后即为独立用户数据，可继续自由编辑。
>
> 协商结论（2026-09 修订）：数据源 = OSM；导入内容 = 全类型；获取方式 = 预下载文件 + 桌面预处理；
> **图层关系 = 导入层与用户绘制层相互独立，除视觉渲染外无关联**；
> **底图 → 最后一公里图层的转换 = 单个选取方式（无批量转化）**。

## 1. 图层关系（本次修订核心）

```
（现有）底图栅格瓦片 OSM tile    —— 视觉参考（不参与数据编辑）
（新增）导入矢量层 import_*     —— OSM 要素只读入库：仅用于渲染/参考/查询
（现有）用户层 points/lines/areas/gates/entities —— 唯一可编辑事实源
```

**两条铁律：**

1. **导入层与用户层互相独立、零耦合**：不互相外键、不实时联动。
   导入层更新/替换时不影响用户层；用户层怎么改也不影响导入层。二者唯一交集是"同时画在地图上"。
2. **图层间转换 = 单要素点选（pick-one）**：用户在地图上点选导入层的**一条路或一个 POI**，
   通过一次性复制把它带入用户层（路 → 新建一条 route_edge；POI → 新建一个常送点 entity）。
   **不做批量转化**：没有"整片路网/全部 POI 一次导入用户层"的动作。

> 术语："种子初始化(seed) 批量转化"弃用；统一为**「单要素选取带入(pick & bring)」**。

## 2. 桌面预处理管线（osm_prep，独立 CLI）

```
Geofabrik 区域 PBF（或 Overpass 按矩形导出）
      │  osmium/osmfilter 过滤 + 裁剪到核心区矩形
      ▼
filtered.osm
      │  osm_prep：抽稀对齐、精简字段（type→cost_class、oneway、name…）
      ▼
  region.osmapp  —— 拷入手机 / App 设置页「导入开放数据」
```

桌面工具在 M2 桌面预处理器基础上扩展（02 章 §2.2 `osm_prep`），
产出与模型对齐的结构化文件，App 端导入快、不需要解析 PBF。

## 3. App 导入层数据结构（新增表，schema v2）

原则：**导入层要素只读**，独立于用户层；不混存、不互相外键。

| 表 | 说明 |
|----|------|
| `import_bounds` | 已导入区域（范围 + 数据版本 + 导入时间），用于展示与整体替换 |
| `import_nodes` | OSM 节点（道路交点/要素锚点）：osm_id、lat/lng、tags 精简 |
| `import_ways` | OSM 线段/折线要素：osm_id、kind（`road`/`building`/`water`/`green`/`railway`/`boundary`…）、refs 顶点序、cost_class、oneway、name |
| `import_pois` | 点状 POI/门牌：osm_id、kind、lat/lng、name、tags（addr:* 等） |

字段沿用 03 章语义（WGS-84）。建筑等面状要素存 `import_ways(kind=building)` 闭合环渲染。
不复制 OSM 全部 tags，仅保留精简字段 + tags 摘要 JSON，控制体积。

> 导入层不记录用户动作（无 adopted/used 之类标记）——它不关心用户怎么用，随时可整体替换。

## 4. 单要素选取带入（Pick & Bring）——底图 → 最后一公里图层

用户在地图上点选导入层要素，通过**单要素**动作把它带入用户层：

| 源（导入层） | 用户动作 | 目标（用户层） | 说明 |
|-------------|---------|---------------|------|
| 道路折线 `import_ways(kind=road)` | 点选 →「以这条路建立我的路网」 | 新建 `points(kind=vertex)`×N + 一条 `lines(kind=route_edge)`，cost_class/oneway 带入 | 复制为一条可编辑边 |
| POI/门牌 `import_pois` | 点选 →「加入我的常送点」 | 新建 `entities(entity_type 映射)`，name/addr 带入 | 复制为一个常送点 |
| 建筑 `import_ways(kind=building)` | 点选 → 仅查看/可选「取其入口为常送点」 | （Q-12 待定） | 默认只做道路与 POI |

**语义要点：**

- **每次只处理一个要素**：无范围选择、无类别批量；用户在地图上逐个点、逐个建；
- 复制式一次性：带入即成为普通用户数据（分配用户侧自增 id），与导入层断开关联，可编辑/可删/可导出；
- 已带入提示：导入层要素若已在用户层有对应物，前端按 `ext.osm_way_id/osm_node_id` 查询后显示"已在我的图层"角标（仅提示，无耦合存储；导入层替换后提示失效可接受）；
- 带入后自动进入对应既有编辑流程（路 → 可改 oneway/cost_class；POI → 常送点表单），保持编辑体验一致。

## 5. UI/UX

1. **设置 → 数据管理 → 导入开放数据**：选 `.osmapp` → 预览（计数/范围/版本）→ 确认（整体替换导入层）。
2. 地图渲染：底图瓦片之上叠加导入层（淡显，独立开关）：
   - 路网：细灰蓝线（骑行/推行/步行分深浅）；建筑：浅灰面；POI：小圆点；
   - 图层面板可分别开关「导入路网/建筑/POI」，并可一键"隐藏导入层"只看自己的数据。
3. **单要素带入交互**（默认浏览/编辑模式下）：
   - 点选导入层道路 → 高亮整条路 + 底部卡：「以这条路建立我的路网」→ 确认后进入该边编辑（同 M1 路网边）；
   - 点选导入层 POI → 卡：「加入我的常送点」→ 确认后进入常送点表单（同 M1 实体）；
   - 点选建筑 → 卡显示名称/轮廓信息；「取其入口为常送点」为可选动作（Q-12）；
   - 已带入要素显示"已在我的图层"角标（防止重复带入）。
4. 全程不提供"批量导入/整片转化"入口——保持单要素原则。

## 6. 覆盖与试点

- 试点范围 = 核心区矩形：雁田、油甘埔、大运城邦、翰邻城一带（≈ 05 章路由底网同范围）；
- 桌面工具先出核心区；扩展包=凤岗镇全域（与瓦片扩展包对齐）。

## 7. 数据规模与性能（预估，M2 前实测回填）

| 项 | 估计 | 说明 |
|----|------|------|
| 核心区 .osmapp 体积 | < 10–30 MB | 精简字段 + 抽稀 |
| 导入节点数 | 万级~十万级 | 核心区道路+建筑 |
| 渲染 | 视口裁剪 + 抽稀（只画屏幕内） | 沿用 R-07 |
| 导入耗时 | 秒级~数十秒（手机） | 事务批量 + 进度条 |
| 单要素带入耗时 | 毫秒级 | 单条复制事务 |

## 8. 里程碑归属与验收

- 独立 **M2.5「开放数据底图与单要素带入」**（可与 M2 并行/前置）：
  1. M2a 桌面 osm_prep → `.osmapp`（含核心区样例文件）；
  2. M2b App：schema v2 导入表 + 导入/整体替换 + 导入层渲染与开关；
  3. M2c App：单要素点选带入（道路→route_edge；POI→常送点）→ 进入既有编辑。
- **验收**：手机导入核心区 `.osmapp` 成功且路网淡显可开关；点选一条 OSM 路「建立我的路网」后
  用户层出现该可编辑 route_edge；点选一个 POI「加入常送点」后出现对应 entity；
  导入层重新替换后用户层数据不受影响、照常可编辑导出。

## 9. 本章开放问题（Q-11 起，供你拍板）

| ID | 问题 | 默认倾向 |
|----|------|---------|
| Q-11 | 导入层与用户层物理分表 | 分表（import_* 独立表，整体替换方便） |
| Q-12 | 建筑要素点选后是否提供"取其入口为常送点" | 默认不提供（仅道路与 POI 带入）；M3 再评估 |
| Q-13 | 重复带入提示"已在我的图层" | 前端按 osm_id 匹配角标提示，不强制去重 |
| Q-14 | 道路折线过长是否自动按交点拆分后带入 | 带入为一条多段 line，用户可自行用"切分"编辑（后续迭代） |
| Q-15 | POI→常送点后与自建常送点如何区分 | entities.ext.osm_* 溯源字段 + 列表筛选"来源=OSM" |

## 10. 默认内置底图（凤岗 + 龙岗全域，随 APK 分发）

> 承接本子系统，把「导入层」与 M0/M1 工程进一步整合：App **默认已内置凤岗镇 + 龙岗区全域**开放地图数据，
> 用户首次启动即可看到完整矢量为底图，**无需手动跑桌面工具或逐个导入**。导入层仍遵循 §1 两条铁律（零耦合、整体替换、单要素带入）。

### 10.1 资源生成（纯 Python 抽取器）

沙箱无 `osmium`/`osconvert` 命令，且 `osm_prep`（M2a）只认 XML。改用**零依赖纯 Python 抽取器**直接从 PBF 裁 bbox 生成 `.osmapp`：

- 入口：`tool/pbf_extract/main.py`；源文件：`assets/guangdong-latest.osm.pbf`（160MB 全省 PBF）。
- 复用已安装的 `pyosmium 4.3.1`（用户 site-packages 已有），两遍流式裁剪：
  - Pass1（NodePass）：读取所有 node，落在其并集 bbox（凤岗+龙岗并再外扩 0.01°）内的入内存 `D:osm_id→(lat,lng)`，并收集带 POI tag 的节点；
  - Pass2（WayPass）：way 任一 node ref ∈ D 则保留（bbox 外 ref 丢弃——边界处路被截断，对底图可接受），按 `way_kind` 分类（road/building/water/green/railway/boundary/poi-ish）后写出。
- 区域 bbox：凤岗 `(22.69,114.04,22.79,114.22)`、龙岗 `(22.55,114.04,22.79,114.42)`。
- 产物（已生成并校验）：
  - `assets/osm/fenggang.osmapp`：11.7MB / 154328 节点 / 14955 ways / 481 POIs；
  - `assets/osm/longgang.osmapp`：61.9MB / 816089 节点 / 78174 ways / 3777 POIs。
- 输出严格匹配 `OsmAppFile.toJson`（顶层 schema/version/region/generated_at/bounds；nodes: osm_id/lat/lng；ways: osm_id/kind/name/cost_class/one_way/node_ids/tags；pois: osm_id/name/lat/lng/tags）。
- 校验：`tool/pbf_extract/validate_osmapp.dart` 用真实 `OsmAppFile.fromJsonString` 离线解析两份文件，确认结构正确、badRefWays=0。
- `osm_prep`（XML 路径）保留，供手动 XML 导入。

### 10.2 资源登记与首启静默加载

- 登记：`pubspec.yaml` 的 `flutter.assets` 新增 `assets/osm/fenggang.osmapp` 与 `assets/osm/longgang.osmapp`（`flutter pub get` 后随 APK 分发；用户接受 APK 体积增长约 74MB）。
- 加载逻辑：`lib/features/map/import_defaults.dart` 的 `ensureDefaultImportLayer(repo, {force})`：
  1. 读 `schema_meta` 的 `default_osm_loaded` 标志；非 `force` 且已是 `1` 则跳过（仅加载一次）；
  2. `rootBundle` 解析两份资源 → `repo.importOsmFiles([fg, lg])` 合并去重写入导入层；
  3. 置标志 `default_osm_loaded=1`；全程 `try/catch` 兜底（资源坏/缺失不崩溃，App 照常启动，仅无底图）。
- 入口：`lib/main.dart` 在 `AppRepository.open(dbPath)` 之后、`runApp` 之前 `await ensureDefaultImportLayer(repo);`。

### 10.3 多文件合并去重（importOsmFiles）

- `AppRepository.importOsmFiles(List<OsmAppFile> files)`：先清空 4 张导入表，再写入多份文件；按 osm_id `INSERT OR IGNORE`（复用 `idx_import_*_osm` 唯一索引）去重——凤岗/龙岗 bbox 沿交界重叠，重叠要素只留一份。
- 合并 `import_bounds(id=1)`：`region` = 各 `region` 用 `+` 连接（如 `fenggang+longgang`）、`bounds` 取并集、计数取实际行数 `COUNT(*)`。
- `replaceImportLayer(file)` 内部复用 `importOsmFiles([file])`（单文件等价），保留供设置页手动导入。

### 10.4 视口裁剪（性能必须项）

全域数据下原 `importLayerProvider` 不加视口过滤、POI 全量加载会卡死；本轮修复：

- 新增 `MapViewport(minLat,minLng,maxLat,maxLng)` 与 `mapViewportProvider`（`StateProvider<MapViewport?>`）；
- `map_page` 相机移动时 **300ms 防抖** 更新视口（flutter_map v8 `MapOptions.onMapEvent` → `MapEvent.camera.visibleBounds`）；`initState` 用初始中心 `kFenggangCenter` ±跨度初始化首屏视口，避免无视口时全量加载；
- `importLayerProvider` watch 视口，向 `queryImportLayer` 传 bbox：**路**（bbox 相交）与 **POI**（`lat/lng` 范围）均裁剪；节点坐标由逐 way 单查改为「收集本次 ways 的全部 node id → 一次 `WHERE osm_id IN (...)`」批量解析，查询从 O(ways×节点) 降为 1 次。

### 10.5 设置页「恢复默认底图」

- `settings_page.dart` 新增按钮：调 `ensureDefaultImportLayer(force:true)` 重载内置底图，并 `ref.invalidate(importBoundsProvider)` / `ref.invalidate(importLayerProvider)`；不打扰首启语义（首启标志已置时仅按钮可触发重载）。

### 10.6 约束与边界

- 不改动 §1 两条铁律（独立/只读/整体替换/单要素带入）；
- 首启加载异常兜底：资源损坏不导致崩溃，缺失时 App 仍可用（仅无底图）；
- 复用既有索引：`idx_import_pois_bb(lat,lng)`、`idx_import_ways_bb`、`idx_import_nodes_bb`、`idx_import_*_osm`（去重）；
- 不引入新依赖；flutter 命令由用户本机执行，AI 仅离线 `dart analyze` + 结构校验。
## 11. 启动期内存峰值治理（M2.5+ 修复，2026-09-09）

**症状**：在魅族 18s（Android 12，Vulkan Impeller 后端）冷启动 `flutter run` → 安装 APK → 启动主页 → 加载导入层阶段发生 `java.lang.OutOfMemoryError: Failed to allocate a 24 byte allocation with 18512 free bytes ... target footprint 268435456, growth limit 268435456, giving up on allocation because <1% of heap free after GC`（heap 上限 256MB）。崩溃栈出现在 `StandardMessageCodec.readValue` 链路上，提示 `WaitForGcToComplete blocked ... 252ms` 的串行等 GC 心跳。

**根因**：原 `ensureDefaultImportLayer` 在 `runApp` 之前一次性 `await`：
1. `rootBundle.loadString` 拉 12MB + 62MB 的两段 JSON 文本 → Dart 端两个 String 实例直接常驻 74MB；
2. 紧接 `OsmAppFile.fromJsonString` 把整段反序列化为 `List<OsmNode>/<OsmWay>/<OsmPoi>` → 95 万级对象再叠一份；
3. 同时 `importOsmFiles` 内部一次性构造 `Map<int,(double,double)>`（96 万 entries）+ 单个 `Batch` 几乎装下所有 way 行 → 等价 Dart 堆 ≈ 200MB+；
4. 单事务把 ~95 万 INSERT 串行提交，UI 主线程被挤压在 `WaitForGcToComplete` 上 → 老一代挪不动，堆被顶上 255/256MB 直至 OOM。

**修复策略（增量、对 §1 两条铁律零影响）**：

### 11.1 启动期不入库，挪到首帧之后

`lib/main.dart`：
```
runApp(MapApp(repository: repo));
WidgetsBinding.instance.addPostFrameCallback((_) {
  ensureDefaultImportLayer(repo); // fire-and-forget；内部吃掉一切异常
});
```
主线程不再被大导入阻塞；冷启动看到的第一个页面是已经渲染好的主页 UI（无 OSM 层），用户感知"层立刻显示"。

### 11.2 三阶段 `schema_meta` 状态机

`import_defaults.dart` 引入 3 个标志，避免冷启动首启路径因 OOM 中断后下次启动无限重试：

| 标志 | 含义 |
|---|---|
| `default_osm_started` | 抢占式时间戳。第二次启动看到 `started && !loaded` → 上一轮被 OOM 中断，不再重复发起新导入（避免叠加）。 |
| `default_osm_loaded` | 完整落库标志。`1` 时首启路径直接 return。 |
| `default_osm_corrupt` | 自愈标记。当 repository 内部 COUNT(*) 自检发现 import_bounds 写入值与库内实际值不一致时回写 `1`，下次启动入口先 `clearImportLayer()` 再重导。 |

### 11.3 字符串入口 `importOsmAppStrings`：释放源码 + 分批 commit + IN(≤999)

`lib/data/app_repository.dart` 新增 `importOsmAppStrings({files, onCorrupt})`，与既有 `importOsmFiles(List<OsmAppFile>)` 并存：

- 入口先 `OsmAppFile.fromJsonString` 一次把每段 source 解析、丢弃 source 引用（让 `string` GC 立刻回收 74MB）。
- 全部入库动作按 `kBatchSize=2000` 一批一 `commit(noResult: true)`：节点/路/POI 三段都是分批；不构造全量 `Map<int,(double,double)>`。
- `ways.node_ids` 跨段：每条 way 单独走 `SELECT ... WHERE osm_id IN (...)`，IN 子句按 999 切段（SQLite 编译期硬限制），逐段查完即释放临时 results；解析失败的 `bbox` 外边丢弃。
- 末尾二次回查 COUNT(*)，与 `import_bounds.*_count` 比对：一致 → onCorrupt 不调用；不一致 → onCorrupt 写 `default_osm_corrupt=1`，下次启动先清残再重导。

### 11.4 设置页「恢复默认底图」二次确认 + 后台执行

`settings_page.dart` 按钮触发：
1. 先 `showDialog<bool>` 二次确认（明示"过程约需几秒到数十秒"）；
2. 用户确认后立即 SnackBar「正在后台恢复默认底图…」；
3. `unawaited(_restoreDefault(ref, context))` 异步完成，结束再 SnackBar「已恢复默认底图」；
4. 期间 UI 不阻塞，用户可自由浏览/切换页面，导入完成后会自动 invalidate `importBoundsProvider` / `importLayerProvider`。

### 11.5 单测新增

`test/data/import_layer_test.dart`：
- `importOsmFiles 分批 commit（5000 节点 > 2000/batch）`：验证 `kBatchSize` 实际生效；
- `importOsmAppStrings 字符串入口结果与 importOsmFiles 等价`：确认两入口产出同 `region / nodeCount / wayCount / poiCount`；
- `importOsmAppStrings 多文件按 osm_id 去重 + 跨段节点查`：凤岗+龙岗场景的去重；
- `corrupt callback 在计数一致时不触发`：sanity check；
- `ways.node_ids > 999 时切段不丢坐标`：跨 IN 子句 999 硬限制边界。

