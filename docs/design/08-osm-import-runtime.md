# 第八章 OSM 导入运行时全链路（runtime path）

> 承接 07 章（数据建模 + 桌面预处理 + §11 启动期内存治理）。
> 本章只讲**运行时**——从用户启动 App、进入主页，到地图渲染、单要素点选带入为止，**每一步是谁触发、做什么 IO、写什么状态、卡在哪**。
> 重点：把"启动期落库"和"运行时按视口加载"严格分开——前者是 `main` → `import_defaults` → `importOsmAppStrings`（一次性，全部数据，OOM 重灾区）；后者是 `map_page` → `importLayerProvider` → `queryImportLayer`（每次按视口拉，受 999 上限制约）。

---

## 0. 全文速览

```
┌──────────────────────────────────────────────────────────────────────┐
│ main.dart                                                            │
│   runApp(MapApp)                                                     │
│   addPostFrameCallback(ensureDefaultImportLayer)  ←── 启动期落库（07 §11）│
└──────────────────────────────────┬───────────────────────────────────┘
                                   │
        ┌──────────────────────────┴──────────────────────────┐
        ▼                                                     ▼
┌───────────────────────────┐                    ┌──────────────────────────┐
│  HomePage (TabBarView)    │                    │  Schema v2 已建           │
│   ├─ 地图 Tab → MapPage   │                    │  import_* 四表 + 索引    │
│   └─ 设置 Tab → Settings  │                    │  (idempotent CREATE IF) │
└─────────────┬─────────────┘                    └──────────────────────────┘
              │
              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ MapPage.initState                                                    │
│   addPostFrameCallback(mapViewportProvider.update(kInitialViewport)) │
│   ────────────────────────────────────────────────  ←── 关键：兜底 bbox │
└─────────────┬────────────────────────────────────────────────────────┘
              │
              ▼ build() 订阅
┌──────────────────────────────────────────────────────────────────────┐
│ 两个 FutureProvider.autoDispose 共享 sqflite 串行队列                 │
│   ┌──────────────────────────────┐  ┌─────────────────────────────┐ │
│   │ mapLayersProvider (用户层)    │  │ importLayerProvider (OSM)   │ │
│   │  areas → gates → areaRing×N   │  │  bounds → ways → pois →    │ │
│   │  progress: areas→gates→bounds │  │  nodes(按 999 切段)         │ │
│   └──────────────────────────────┘  └─────────────────────────────┘ │
│              ↓                                  ↓                     │
│        mapDataProgressProvider（合并上报，UI 只看一条）              │
└──────────────────────────────────────────────────────────────────────┘
              │
              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ map_page._statusBar（顶部进度条）                                    │
│   phase 中文 + details monospace + LinearProgressIndicator           │
│   done → 600ms 无新 report → clear                                  │
└──────────────────────────────────────────────────────────────────────┘
```

**两个独立 IO 流水线（关键！共享 sqflite 单线程串行队列）**：

| Provider | 频率 | 触发时机 | 触发表 | 触发行数 | 进度阶段 |
|---|---|---|---|---|---|
| `mapLayersProvider` | 每次进入地图 Tab / 编辑提交后 invalidate | build 期间同步 | `areas / gates / lines / points` | 用户数据规模（百级） | `areas → gates → bounds(areaRing)` |
| `importLayerProvider` | 视口变化 / 导入层替换 | build 期间同步 | `import_bounds / import_ways / import_pois / import_nodes` | 视口内要素（千~万级） | `bounds → importRoads → importPois → importNodes → done` |

> **设计铁律**：provider 设计者必须**先想这条查询能不能用 bbox 缩小**。sqflite 单线程串行执行——任何 provider 的慢查询都会把其他 provider 的 IO 顶在队列后等。

---

## 1. 启动期 vs 运行时（严格分开）

| 维度 | 启动期落库 | 运行时按视口加载 |
|---|---|---|
| 入口 | `main.dart` `addPostFrameCallback` | `MapPage.build` 的 `ref.watch(importLayerProvider)` |
| 函数 | `ensureDefaultImportLayer` | `importLayerProvider` |
| repository 方法 | `importOsmAppStrings`（或 `importOsmFiles`） | `queryImportLayer({minLat,minLng,maxLat,maxLng})` |
| 数据量 | **全量**（95 万节点 / 9.3 万路 / 4258 POI） | **视口内**（bbox 限制后的千~万级） |
| 频率 | **App 启动仅一次**（`schema_meta.default_osm_loaded=1` 标志保护） | **每次进入地图 Tab + 每次相机移动 300ms 防抖后** |
| 失败处理 | corrupt 自愈 + 全量重导 | 用户卡死，必须立即诊断 |
| 内存治理 | 分批 `kBatchSize=2000` + IN 子句按 999 切段 + 字符串入口立即丢 String 引用（07 §11） | bbox 限制 + IN 子句按 999 切段 + 单次 snapshot（不再保存查询结果） |
| 进度上报 | 不进 `mapDataProgressProvider`（独立后台任务） | 必进 `mapDataProgressProvider`，UI 必看 |

> **绝不能在启动期路径上同步 await `importLayerProvider` 的全量 IO**。一切"启动后立刻卡在 `_db.query('gates')`" 都是因为 `importLayerProvider` 在 build 期走了"全量分支"，把 sqflite 队列堵死。

---

## 2. 启动期落库（07 §11 摘要，仅作"上下文"）

```dart
// main.dart
runApp(MapApp(repository: repo));             // 先让 UI 可见
WidgetsBinding.instance.addPostFrameCallback((_) {
  ensureDefaultImportLayer(repo);              // fire-and-forget
});
```

```dart
// import_defaults.dart 状态机（schema_meta 三标志）
default_osm_started  = '<ISO ts>'      // 抢占：上一轮中断后下次不重试
default_osm_loaded   = '1'              // 已完成
default_osm_corrupt  = '1'              // 半截残留：下次先 clearImportLayer()
```

`ensureDefaultImportLayer` 流程：

1. `corrupt=1` → `clearImportLayer()` + 写 `corrupt=0`（自愈）。
2. `loaded=1 && !force` → return（首启后不再触发）。
3. 写 `started=<ISO ts>`（抢占）。**这一步是冷启动期 OOM 的关键保险**：中途被 GC / 系统杀，下次启动看到 `started && !loaded` 也不会再发起新导入，避免叠加 OOM。
4. `rootBundle.loadString(fenggang.osmapp + longgang.osmapp)` → 拿到 `fg / lg` 两个 String（74MB）。
5. `await repo.importOsmAppStrings(files: [fgSource, lgSource])`：repository 内部 `OsmAppFile.fromJsonString` 一次解析，**立刻丢 String 引用**让 GC 回收；分批 `kBatchSize=2000` 一批一 `commit`；`ways.node_ids` 按 999 切段 IN 子句。
6. 写 `corrupt=0` + `loaded=1`。

> 详尽治理过程、`OsmAppStringSource` 引入原因、5 个单测见 07 章 §11。

---

## 3. 运行时按视口加载（本章重点）

### 3.1 视口坐标：单一真理源

```
import_layer_providers.dart:
  const double kFenggangCenterLat = 22.717;
  const double kFenggangCenterLng = 114.136;
  const double kInitialViewportSpan = 0.05;        // ≈ 5.5km
  final MapViewport kInitialViewport = MapViewport(
    kFenggangCenterLat - kInitialViewportSpan,
    kFenggangCenterLng - kInitialViewportSpan,
    kFenggangCenterLat + kInitialViewportSpan,
    kFenggangCenterLng + kInitialViewportSpan,
  );
```

```
map_page.dart:
  final LatLng kFenggangCenter = LatLng(kFenggangCenterLat, kFenggangCenterLng);
  // initState 内 addPostFrameCallback:
  ref.read(mapViewportProvider.notifier).update(MapViewport(
    kFenggangCenterLat - kInitialViewportSpan,
    kFenggangCenterLng - kInitialViewportSpan,
    kFenggangCenterLat + kInitialViewportSpan,
    kFenggangCenterLng + kInitialViewportSpan,
  ));
```

**这两个值必须 byte-equal**。任何一边改了另一边没改 → build 期间 `importLayerProvider` 拿到 `vp==null` 走兜底视图，但兜底视图与真正写入的不同，bbox 真的不一样 → 第一次 invalidate 触发重查 → 用户看到进度条再次启动。

### 3.2 `MapPage.initState`：写入视口的微妙时机

```dart
@override
void initState() {
  super.initState();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    ref.read(mapViewportProvider.notifier).update(MapViewport(...));
  });
}
```

**为什么必须 `addPostFrameCallback`**：
- `HomePage` 的 `TabBarView` 默认会一次性构建所有 Tab 子树（包括 `MapPage`）；
- 第一次 build 期间 `importLayerProvider` 已经在 `ref.watch(mapViewportProvider)`；
- 若 build 阶段同步 `state = newViewport`，Riverpod 3 会抛 `try to modify a provider while the widget tree was building`；
- `addPostFrameCallback` 把写入延后到首帧画完后 → 既保留"首屏就带视口"语义，又避开 build 期状态写入校验。

**但是这引入了一个 0~16ms 的窗口期**：`build` 期间 `mapViewportProvider.state == null`。`importLayerProvider` 必须处理这个窗口期——它用 `kInitialViewport` 兜底。

### 3.3 `importLayerProvider`：兜底视口，禁止全量分支

```dart
final importLayerProvider =
    FutureProvider.autoDispose<ImportLayerView?>((ref) async {
  final repo = ref.watch(repositoryProvider);
  final progress = ref.read(mapDataProgressProvider.notifier);

  // —— 阶段 0: 必走的 begin → bounds(检查 import_bounds) ——
  progress.begin(details: '_openDatabase(repo)');
  await Future<void>.delayed(Duration.zero);  // 让 UI 至少重建一帧 checking
  progress.report(MapDataPhase.bounds, details: "_db.query('import_bounds', limit 1)");
  final hasImport = await repo.hasImportLayer();
  if (!hasImport) {
    progress.finish();
    return null;
  }

  try {
    // 视口兜底：build 期 vp 还是 null 时用 kInitialViewport，全部走视口路径。
    final rawVp = ref.watch(mapViewportProvider);
    final vp = rawVp ?? kInitialViewport;
    final isInitialFallback = rawVp == null;
    final bboxTag = "[${vp.minLat.toStringAsFixed(4)},...";

    final view = await repo.queryImportLayer(
      minLat: vp.minLat, minLng: vp.minLng,
      maxLat: vp.maxLat, maxLng: vp.maxLng,
      onPhase: (p) {
        switch (p) {
          case ImportLayerPhase.roads:
            progress.report(MapDataPhase.importRoads,
              details: "_db.query('import_ways' WHERE $bboxTag)"
                       "${isInitialFallback ? ' [兜底视口]' : ''}");
          case ImportLayerPhase.pois:
            progress.report(MapDataPhase.importPois, ...);
          case ImportLayerPhase.nodes:
            progress.report(MapDataPhase.importNodes,
              details: '_db.query(\'import_nodes\' IN <way节点id>)'
                       "${isInitialFallback ? ' [兜底视口]' : ''}");
          case ImportLayerPhase.done:
            progress.report(MapDataPhase.done, details: '拼装 ImportLayerView…');
        }
      },
    );
    return view;
  } finally {
    progress.finish();
  }
});
```

**重要约束**：
- **build 期间 vp 必须有值**（用兜底）。否则 → 走"全量扫表 95 万行 + IN 子句超 999"路径（详见 §5 真凶案例）。
- **bbox Tag 末尾的 `[兜底视口]` 标记**：debug 时一眼能看出本次查询是 build 期首查（带兜底视口）还是相机移动触发的二次查（真实视口）。

### 3.4 `mapLayersProvider`：用户层 IO（与导入层并行跑）

```dart
final mapLayersProvider = FutureProvider.autoDispose<MapLayersData>((ref) async {
  final repo = ref.watch(repositoryProvider);
  final progress = ref.read(mapDataProgressProvider.notifier);
  progress.report(MapDataPhase.areas, details: "_db.query('areas')");
  final areas = await repo.listAreas();
  progress.report(MapDataPhase.gates, details: "_db.query('gates')");
  final gates = await repo.listGates();
  // 每个区块还要再查一次其轮廓（area_points 临时表或类似），用区域 id 标识。
  final withRing = <AreaWithRing>[];
  for (var i = 0; i < areas.length; i++) {
    final a = areas[i];
    if (a.id == null) { withRing.add(AreaWithRing(area: a, ring: null)); continue; }
    progress.report(MapDataPhase.bounds,
        details: "areaRing(area #${a.id}) [${i + 1}/${areas.length}]");
    final ring = await repo.areaRing(a.id!);
    withRing.add(AreaWithRing(area: a, ring: ring));
  }
  return MapLayersData(areas: withRing, gates: gates);
});
```

注意：用户层 IO 完全在用户侧表上跑，与导入层 IO **共用 sqflite 串行队列**——这是关键约束（不是真的"并行"）。

### 3.5 进度合并上报

两个 provider 都写 `mapDataProgressProvider`（Notifier<MapDataProgress?>）：

```dart
class MapDataProgress {
  final MapDataPhase phase;     // checking/areas/gates/bounds/importRoads/importPois/importNodes/done
  final int tick;                // 每次 state 写入 +1，让 indeterminate 动画不"退化"
  final String? details;         // 当前 IO 命中点（monospace 细节行）
}
```

**写顺序由 sqflite 串行队列自然串行化**——`importLayerProvider` 拿到 `importRoads` 阶段的 await token 期间，`mapLayersProvider` 的 `listAreas / listGates / areaRing` 都在后面排队。反之亦然。**两者互不阻塞逻辑，但物理上共享同一个串行队列**。

### 3.6 `map_page._statusBar`：UI 只看一条进度

```dart
// 只看 mapDataProgressProvider，不分别看两个 layer provider。
final dataProgress = ref.watch(mapDataProgressProvider);
if (dataProgress != null) {
  // 第一行：phase 中文 + 转圈图标
  Text(mapDataPhaseLabel(dataProgress.phase)),
  // 第二行：details（monospace 灰色 11pt）
  Text(dataProgress.details, fontFamily: 'monospace', fontSize: 11, ...),
  // LinearProgressIndicator：阶段填充比例 0.08/0.25/0.45/...
  LinearProgressIndicator(value: _phaseToFraction(dataProgress.phase)),
}
```

### 3.7 done 后清空：UI 决定时机

```dart
// Notifier 只置 done，不清 state
void finish() {
  state = MapDataProgress(MapDataPhase.done, 999, details: _stagedDetails);
}

// map_page 决定"何时消失"
void _handleProgressDone(MapDataProgress? p) {
  // 阶段 == done 且 tick 推进 → 启动 600ms Timer
  // 期间 phase 退回非 done → 立即取消 Timer（防止清掉正在跑的进度）
  // Timer 到点再校验 state.phase==done && state.tick==_seenTick 才 clear
}
```

为什么不让 Notifier 自己清：`mapLayersProvider` 的 `areaRing` 循环晚于 `importLayerProvider` 的 `finish()`，如果在 Notifier 内自动清 state，后续 `report(bounds)` 命中 `if (cur == null) return` 丢帧——进度条永远停在 gates。

---

## 4. 相机移动 → 视口变更 → 重查

```dart
// map_page.dart
void _onMapEvent(MapEvent event) {
  final bounds = event.camera.visibleBounds;
  _viewportTimer?.cancel();
  _viewportTimer = Timer(const Duration(milliseconds: 300), () {
    ref.read(mapViewportProvider.notifier).update(MapViewport(
      bounds.southWest.latitude,
      bounds.southWest.longitude,
      bounds.northEast.latitude,
      bounds.northEast.longitude,
    ));
  });
}
```

`mapViewportProvider` 是 `NotifierProvider<MapViewportNotifier, MapViewport?>`，**不是 FutureProvider**——它的 update 是同步 `state =`。但 `importLayerProvider` 内 `ref.watch(mapViewportProvider)`：视口变化 → `importLayerProvider` 因 `ref.watch` 自动 invalidate → 重新跑 → 重新调 `queryImportLayer({bbox})`。

> 因为 build 期兜底视口与 initState 写入值 byte-equal，第一次 invalidate 触发重查时 bbox 几乎一致，**实际只产生 0 行差异**（不重复查）。

---

## 5. 卡死真凶案例（运行时三轮排查汇总）

> 这一节是这次"卡在 `_db.query('gates')` 30 秒+"的完整故事——用户没改任何代码，但每次进地图 Tab 都卡。

### 5.1 现象

| 场景 | 用户看到 |
|---|---|
| 冷启动进地图 Tab | 进度条卡在「正在加载门…_db.query('gates')」30 秒+ 不动 |
| 点设置页 → 再回地图 Tab | 进度条倒退回「正在打开本地数据库…_openDatabase(repo)」，仍然卡 |

### 5.2 误诊 + 误修（两轮）

#### 第一轮（已修）：进度条无 details

- 症状：用户不知道 IO 走到哪。
- 修复：`MapDataProgress` 加 `details: String?` 字段；`MapDataProgressNotifier` 加 `_stagedPhase / _stagedDetails` 缓存防同 microtask 丢帧；`importLayerProvider` 在 `begin()` 后插 `await Future<void>.delayed(Duration.zero)` 让 UI 至少看到 checking 帧；`mapLayersProvider` 每个 areaRing 都更新 details。
- **这只是 UI 增强，没解决卡死**。

#### 第二轮（已修）：finish 抢清 state 丢帧

- 误诊：原 `Notifier.finish()` 在 600ms 后自动清 state；`mapLayersProvider` 的 areaRing 循环在 `listGates` 返回后才跑到下一次 `report(bounds)`——此时 state 已被清成 null，`report()` 第 `if (cur == null) return` 直接吞掉 → UI 永远停在 gates。
- 修复：Notifier.finish 不再自动清 state；UI 层 `map_page._handleProgressDone(progress)` 用 Timer + tick 检测在 done 后 600ms 无新 report 才 clear。
- **这也只是 UI 层修复，没解决 IO 真实卡**。

### 5.3 真凶（第三轮修复）

**根因**：`importLayerProvider` 在 build 期间 `ref.watch(mapViewportProvider)` 拿到 `null`（map_page 用 `addPostFrameCallback` 延后写入首屏视口）→ 走 `vp == null` 全量分支 → `_db.query('import_ways')` 无 WHERE 扫 9.3 万行 → 收集所有 node_ids → `_db.query('import_nodes' IN <N ids>)`，N 远超 `SQLITE_MAX_VARIABLE_NUMBER=999` 直接报错或被 sqflite 单线程串行队列堵死。

**串行化放大效应**：
- `importLayerProvider` 的全量 IO 把 sqflite 队列占满。
- `mapLayersProvider` 的 `_db.query('areas') / 'gates')` 排在后面等 → 用户看到"卡在 gates 30 秒+"。
- 实际 `listGates` 只需要几毫秒，但被全量查询顶在队列后面。

**切到设置页回来同样卡的原因**：
- `importLayerProvider / mapLayersProvider` 都是 `FutureProvider.autoDispose`，页面 dispose → 销毁。
- 回到地图 Tab：`ref.watch(importLayerProvider)` 重新触发。
- 仍然没等到 `addPostFrameCallback`，仍然 `vp == null`，仍然走全量。

### 5.4 修法（已合入）

```dart
// import_layer_providers.dart 顶部
const double kFenggangCenterLat = 22.717;
const double kFenggangCenterLng = 114.136;
const double kInitialViewportSpan = 0.05;
final MapViewport kInitialViewport = MapViewport(
  kFenggangCenterLat - kInitialViewportSpan,
  kFenggangCenterLng - kInitialViewportSpan,
  kFenggangCenterLat + kInitialViewportSpan,
  kFenggangCenterLng + kInitialViewportSpan,
);

// importLayerProvider 内部：禁用 vp == null 全量分支
final rawVp = ref.watch(mapViewportProvider);
final vp = rawVp ?? kInitialViewport;
final isInitialFallback = rawVp == null;
// queryImportLayer(minLat, minLng, maxLat, maxLng, onPhase: ...)
// details 末尾附加 "[兜底视口]" 标记方便 debug
```

```dart
// map_page.dart：与 provider 兜底视图 byte-equal
final LatLng kFenggangCenter = LatLng(kFenggangCenterLat, kFenggangCenterLng);
// initState 内 addPostFrameCallback 用同样的 4 个数字
```

### 5.5 设计要点（防再犯）

1. **视口语义**：`importLayerProvider` 内 build 期 vp 必须有值，**不允许走全量**。兜底值与 initState 写入值 byte-equal。
2. **sqflite 单线程串行**：任何 provider 的慢查询都会阻塞其他 provider。写新 provider 时必须先想"这条查询能不能用 bbox 缩小"。
3. **`autoDispose` + 视口联动**：mapViewportProvider 一变 importLayerProvider 会自动 invalidate 重查——但只在 bbox 真的不同时才有意义；如果兜底视图与真实首屏不一致，第一次 invalidate 会重新扫一次。
4. **provider 内禁止 `ref.watch` 修改本 state**：Riverpod 3 抛 "try to modify a provider while the widget tree was building"。如果需要响应其他 provider 变化，用 `ref.listen` 监听。

---

## 6. 渲染 & 单要素点选带入（简洁流程）

### 6.1 渲染

`MapPage.build` 内：

```dart
FlutterMap(
  mapController: _mapController,
  options: MapOptions(initialCenter: kFenggangCenter, initialZoom: 15, ...),
  children: [
    TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', ...),
    if (importLayer.value case final iv?) ..._buildImportLayers(iv, importVis),
    if (layers case AsyncData(:final value)) ..._buildSavedLayers(value, gateEditor),
    if (areaEditor.isDrawing) AreaDrawOverlay(editor: areaEditor),
  ],
)
```

`_buildImportLayers`（`map_page.dart`）：
- `vis.buildings` → 浅灰面 `PolygonLayer`（`import_ways(is_area=1)` 闭合环，`toClockwiseRing` 顺时针）
- `vis.roads` → 细蓝/绿 `PolylineLayer`（按 `cost_class` 区分骑行/推行）
- `vis.pois` → 小圆点 `MarkerLayer`

### 6.2 单要素点选带入

`MapPage._onMapTap(latLng)` 流程（按优先级）：

1. **`areaEditor.isDrawing`** → 圈地模式，落点。
2. **`gateEditor.isPlacing`** → 打孔模式，吸附到选中区块边线 → 门表单。
3. **浏览模式 + importLayer.value != null**：先看 POI（`hitNearestPoi(importView.pois, p)` 容差 25m）→ `_offerAdoptPoi`（showDialog「加入我的常送点」→ 复制为 entity）；再看路（`hitNearestWay(importView.ways, p)` 容差 25m）→ `_offerAdoptWay`（showDialog「建立我的路网」→ 复制为 points + line）。
5. **都没命中**：点选区块（`pointInPolygon(p, ring)`）→ `gateEditor.selectArea(id)`；空白点 → `clearSelection()`。

带入函数核心：

```dart
// _offerAdoptWay
final adopt = await showDialog<bool>(...);
if (adopt != true) return;
await ref.read(repositoryProvider).adoptWay(way);   // 见下文
ref.invalidate(mapLayersProvider);                  // 让区块/门 UI 立刻重画
_toast('已建立我的路网边（来源 OSM way ${way.osmId}）');
```

```dart
// _offerAdoptPoi
await ref.read(repositoryProvider).adoptPoi(poi);
ref.invalidate(mapLayersProvider);
```

`adoptWay / adoptPoi` 在 `app_repository.dart`：把导入层**单个**要素（路 → N 个 points + 1 条 line / POI → 1 个 entity）复制为用户层数据，分配用户侧自增 id，与导入层 osm_id 用 `ext.osm_*` 字段建立溯源（仅用于"已在我的图层"提示，无外键）。

---

## 7. 阶段汇总（debug 时一眼定位）

| 阶段 | phase 枚举 | 中文文案（mapDataPhaseLabel） | IO 命中点（details 示例） | 在哪个 provider |
|---|---|---|---|---|
| 0 | `checking` | 正在打开本地数据库… | `_openDatabase(repo)` | importLayerProvider.begin |
| 1 | `areas` | 正在加载区块… | `_db.query('areas')` | mapLayersProvider |
| 2 | `gates` | 正在加载门… | `_db.query('gates')` | mapLayersProvider |
| 3 | `bounds` | 正在检查导入层… | `_db.query('import_bounds', limit 1)` | importLayerProvider |
| 3.b | `bounds` | 同上 | `areaRing(area #N) [i/n]` | mapLayersProvider（areaRing 循环） |
| 4 | `importRoads` | 正在查视口内路… | `_db.query('import_ways' WHERE [...bbox...])` `[兜底视口]` | importLayerProvider |
| 5 | `importPois` | 正在查视口内兴趣点… | `_db.query('import_pois' WHERE [...bbox...])` `[兜底视口]` | importLayerProvider |
| 6 | `importNodes` | 正在加载节点坐标… | `_db.query('import_nodes' IN <way节点id>)` `[兜底视口]` | importLayerProvider（按 999 切段） |
| 7 | `done` | 即将完成… | （UI 600ms 后清空） | importLayerProvider.finish |

> 看到 details 末尾有 `[兜底视口]`：本次是 build 期首查或 setState 写入触发的二次查（bbox 接近但不完全相同）。无此标记：相机移动触发的二次查。

---

## 8. 单测覆盖现状（运行时）

> 启动期落库 5 个单测见 07 §11.5。
> 运行时按视口加载目前**暂无单测**——下面列出建议补的覆盖点（下一步可考虑）：

| 覆盖点 | 类型 | 关键断言 |
|---|---|---|
| `queryImportLayer(bbox)` 与全量分支结果一致（同样数据下） | 集成 | 视口涵盖整个 import_bounds 时，行数 = 全量分支行数 |
| `queryImportLayer` bbox 缩小后行数严格 ≤ 全量 | 集成 | 1/2 视口：行数 ≤ 全量 |
| `queryImportLayer` bbox 外交集为 0 | 集成 | 所有返回的 lat/lng 都在 bbox 内 |
| `importLayerProvider` vp==null 用兜底视口 | 单测 | mock mapViewportProvider 不写值，验证 queryImportLayer 收到的是 kInitialViewport |
| `importLayerProvider` 不再触发 vp==null 全量分支 | 单测 | 验证 queryImportLayer 调用 100% 带 bbox 参数 |
| `progress` 上报顺序：checking → bounds → importRoads → importPois → importNodes → done | 单测 | 记录 report 调用序列 |
| `mapLayersProvider` areaRing 循环每个 i 都更新 progress.details | 单测 | 验证 details 包含 `[i/n]` |

---

## 9. 排错清单（如果你下次又卡死，按这个查）

1. **进度条卡在「正在打开本地数据库」不动**：
   - `main.dart` `addPostFrameCallback(ensureDefaultImportLayer)` 是不是被改了；
   - `schema_meta.default_osm_started` 是否被设但 `loaded` 没设——可能是冷启动 OOM 中断，下次启动入口要识别"未完成"不重试（07 §11.2）。

2. **进度条卡在「正在加载门…_db.query('gates')」**：
   - 检查 `importLayerProvider` 内 `vp == null` 是不是又出现了全量分支代码；
   - 检查 `kInitialViewport` 与 `map_page.initState` 写入的视口是否 byte-equal；
   - 看 `importLayerProvider` 的 details 末尾有没有 `[兜底视口]`——有但仍在卡 → 兜底视口范围内要素过多，考虑缩 span；
   - 看 details 有没有 `import_ways WHERE [...bbox...]` 但仍未推进 → 99% 是 `import_nodes IN <N ids>` 超 999 上限被 sqflite 静默拖慢——查 `queryImportLayer` 节点段是否按 999 切段。

3. **进度条卡在 `areaRing(area #N) [i/n]`**：
   - 用户区块数量大（百级以上）+ 每个 areaRing 多次 listPointsByIds → 单次 IO 不卡但循环累加慢。可考虑批量预拉 points（按 area_id IN (...)）。

4. **进度条卡在「正在加载节点坐标」**：
   - 视口内路过多（万级以上）→ 单段 way 的 node_ids 总和过大 → `import_nodes IN <N ids>` 切段后仍要 K 次查询。
   - 临时方案：缩视口或缩路过滤（只查 kind=road）。
   - 长期方案：节点预拉 + cache。

5. **进度条卡在「正在检查导入层」但 `import_bounds` 已经在库**：
   - 检查 `hasImportLayer` 是否被改：`Future<bool> hasImportLayer() async { final r = await _db.query('import_bounds', limit: 1); return r.isNotEmpty; }` —— 单独 IO，如果数据库自身忙也会卡。
   - 或 `schema_meta` 标志位被写错（corrupt=1 但没 clear）→ 下次启动先 clearImportLayer 再重导。

6. **进度条反复横跳（checking → areas → bounds → checking）**：
   - 检查是否有地方重新 `importLayerProvider` 触发了重建（invalidate）；
   - 检查 `mapViewportProvider.update` 是否在 build 期间被同步调用——Riverpod 3 异常栈里有提示。

7. **OOM 复发（启动期）**：
   - 看 `schema_meta.default_osm_started` 是不是有值但 `loaded` 没有 → 说明上一轮中断。
   - 检查是否走了老的 `importOsmFiles(List<OsmAppFile>)` 路径（一次性常驻全量解析对象）——应改用 `importOsmAppStrings({files})`。

---

## 10. 与 07 章的关系

- **07 §1-9**：图层关系 / 数据建模 / 单要素带入语义 / UI 流程；
- **07 §10**：默认内置底图（凤岗+龙岗，74MB assets）；
- **07 §11**：启动期内存治理（三阶段状态机 + 字符串入口）；
- **08 本章（新增）**：运行时全链路（视口加载 + 进度条 + 渲染 + 卡死排查）。

07 是"是什么"，08 是"运行时怎么走、卡在哪怎么查"。两者互补；任何新需求或重构（如新增 provider、加新阶段、改视口策略）应同时更新 07 与 08。