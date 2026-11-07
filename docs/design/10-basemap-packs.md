# 十 全省矢量底图：分卷包 + ATTACH 按需加载

> 状态：**✅ 已实施并验收（Android + Linux 双端通过）；「全省打包」进行中**。
> 本轮目标：把「广东全省矢量底图」以 **0.1° 经纬网格分卷的预构建 SQLite 包**形式交付，
> 用户层与底图层通过 **`ATTACH`** 拼装；不再需要 App 运行时从 `.osmapp` 文本导入。
> 前置依赖：第九章（`docs/design/09-linux-port.md`，sqflite → sqflite_common_ffi 迁移）**已完成并验收**。
> 执行分工沿用项目铁律：**AI 写代码 + 只读离线校验；`flutter` 命令一律由 wing 在本机执行并回传**。
>
> **实施结果与偏差见 §11（必读）**；本轮实际踩到并修掉的 7 个问题见 §11.3。

---

## 1. 目标与非目标

### 1.1 本轮目标（已协商确认）

| # | 目标 | 判定标准 |
|---|------|----------|
| G1 | 底图数据以**预构建 SQLite 包**交付，不再运行时解析 `.osmapp` | 首启不再出现「正在导入默认底图节点…」阶段；无 JSON/对象解析 |
| G2 | 全省底图按 **0.1° 网格分卷**，每格一个独立 `.db` | 全省 2,772 个非空格；文件名 = `t<lat0>_<lng0>.db` |
| G3 | 用户层（可写）与底图层（只读）**分文件**，用 `ATTACH` 拼装 | `map.db` 只留用户层 5 表 + `schema_meta`；`import_*` 迁到包内 |
| G4 | **内置** corridor 覆盖的 4 格，开箱离线可用 | APK 净增 **+15.6MB**；首启无需任何外部文件 |
| G5 | 其余格通过 **`adb push`** 到设备包目录即可生效 | App 扫描包目录自动发现，无需重装 APK |
| G6 | 按视口**按需 ATTACH**，超出上限时安全降级 | 任何缩放/平移下不崩、不卡死；包数超限时按优先级取最近 |
| G7 | 顺便修好与引导逻辑相关的 **4 个既有红测试** | 基线 12 红 → 8 红（XML 解析 8 个属另一问题，本轮不动） |

### 1.2 非目标（本轮明确不做）

- ❌ 不改用户层 schema（`points/lines/areas/gates/entities` 与全部用户数据一行不动）；
- ❌ 不动寻路 / 门禁引擎 / 圈地编辑 / 单要素带入的业务逻辑；
- ❌ 不做 App 内下载（本轮包来源 = APK 内置 + `adb push` 两条；下载接口留到后续）；
- ❌ 不修 `osm_prep.dart` 手写 XML 解析器的 8 个红测试（另一条独立问题线）；
- ❌ 不为提高 `SQLITE_MAX_ATTACHED` 而改成从源码编译 sqlite3（见 §4.3）；
- ❌ 不做可变尺寸瓦片（四叉树）——本轮用固定 0.1° 网格。

---

## 2. 已确认决策

| 编号 | 议题 | 结论 |
|------|------|------|
| D1 | 范围 | **广东全省**（21,062,792 节点） |
| D2 | 分卷粒度 | **固定 0.1° × 0.1° 经纬网格** |
| D3 | 内置包 | **corridor 覆盖的 4 格**（APK +15.6MB）；其余走 `adb push` |
| D4 | 分发方式 | 内置包走 APK asset；其余格由 wing 手动 `adb push` |
| D5 | 文件布局 | **双文件 + `ATTACH`**：`map.db`（可写用户层）/ `basemap/*.db`（只读底图） |
| D6 | 包存放位置 | **外部应用专属目录**（Android：`/sdcard/Android/data/<pkg>/files/basemap/`）。`adb push` 可直接写入、App 无需权限、省掉 1.97GB 双份存储。非 Android 平台回退 `applicationSupport/basemap/` |
| D7 | `.osmapp` 链路 | **保留代码能力**（`OsmAppFile` / `importOsm*` / 设置页「导入演示数据」），但 **不再随包分发** `corridor.osmapp` |
| D8 | schema 防漂移 | Python 手写 DDL 副本 + **Dart 校验器**（`validate_pack.dart`）比对两边 |
| D9 | 4 个相关红测试 | **顺手修好** |
| D10 | 实施方式 | 保留现有 `schemaV2` 的 `import_*` DDL 原样复用到包内（不改列、不改索引） |
| D11 | `importOsm*` 写入目标 | 写入**临时 pack** `basemap/_import_tmp.db`（保留 D7 的代码能力，且与 pack 语义一致） |

---

## 3. 支撑事实（实测数据）

### 3.1 数据规模（用纯 Python 解析 `assets/guangdong-latest.osm.pbf` 实测）

```
文件 168,172,516 字节；2,889 个 blob（1 × OSMHeader + 2,888 × OSMData）
  nodes     = 21,062,792
  ways      =  1,985,941
  relations =     41,233
```

> **正确性自检**：同一条解析链路对 corridor bbox (22.65,114.10,22.76,114.28) 计数得
> **192,559**，与 `import_defaults.dart` 记录、以及现有库内 `import_bounds.node_count`
> **完全一致**，故上述全省数字可信。

### 3.2 网格粒度对照（0.1° 的选型依据）

| 粒度 | 全省非空格 | 中位格 | p90 | 最大格 | corridor 覆盖 | 内置 APK 增量 |
|------|-----------:|-------:|----:|-------:|--------------:|--------------:|
| 0.25° | 691 | 222 (0.02MB) | 62,694 (5.9MB) | **2,279,043 (212.7MB)** | 4 格 | +72.9MB |
| **0.1°** | **2,772** | **2,422 (0.23MB)** | **13,912 (1.3MB)** | **627,338 (58.5MB)** | **4 格** | **+15.6MB** |
| 0.05° | 8,997 | 775 (0.07MB) | 4,134 (0.4MB) | 310,025 (28.9MB) | 20 格 | +19.3MB |

0.1° 全局分布补充：**99.0% 的格 < 10MB**，仅 **1 格 > 50MB**（`t22.30_114.10` = 香港，
627,338 节点 / 58.5MB）。中位 2,422 与最大 627,338 相差 **259 倍**，密度极度倾斜。

选 **0.1°** 的理由：文件数（2,772）比 0.05° 少 3.2 倍；最大包 58.5MB 仍在可控范围；
内置体积（15.6MB）比 0.05°（19.3MB）更小 —— 因为 corridor 恰好只需 4 格。

**体积换算式**（后续所有估算都用它）：

```
seed_MB   ≈ 17.97 × nodes / 192,559        # 由 corridor 实测标定
APK_MB    ≈ seed_MB × 0.452                # 实测 deflate 压缩比
全省 seed ≈ 1,966 MB   （单包/合计同值）
```

### 3.3 corridor 覆盖的 4 格明细（= 本轮内置集）

corridor bbox = (22.65, 114.10, 22.76, 114.28)，按半开区间 `[lo, hi)` 取相交格：

| tile key | bbox (lat, lng) | nodes | seed MB |
|----------|-----------------|------:|--------:|
| `t22.60_114.10` | 22.60~22.70, 114.10~114.20 | 142,026 | 13.3 |
| `t22.60_114.20` | 22.60~22.70, 114.20~114.30 | 73,571 | 6.9 |
| `t22.70_114.10` | 22.70~22.80, 114.10~114.20 | 80,464 | 7.5 |
| `t22.70_114.20` | 22.70~22.80, 114.20~114.30 | 73,673 | 6.9 |
| **合计** | | **369,734** | **34.5 → APK 15.6MB** |

> ⚠️ **编写生成器时务必注意浮点陷阱**（我实测踩到过）：
> `(114.10 - 109.0) // 0.1` 在 Python 里返回 **50.0 而非 51.0**，因为
> `114.10 - 109.0 == 5.099999999999994`。若直接用它算格号，会在 bbox 边界上**多算一整列格**。
> 正确做法：先 `round(x, 7)` 再除以 `STEP`，最后 `floor(... + 1e-9)`。
> 这个 bug 我最初就犯了，把内置集从 4 格错算成 6 格（56.3MB → 真实 34.5MB）。

> 注意：内置范围（36.97 万节点）是 corridor 本身（19.2 万）的 **1.9 倍**。
> 这是网格对齐的必然代价——但也带来好处：**跑出走廊边界不会突然没数据**。
> 若你之后想要「精确等于 corridor」，唯一办法是保留一个非网格特殊包（会与网格包重叠，需按 osm_id 去重）。

### 3.4 平台约束（实测核实）

| 约束 | 值 | 影响 |
|------|----|------|
| `SQLITE_MAX_ATTACHED` | **10**（打包版 sqlite3 未覆盖默认值） | 最多同时挂 9 个底图包 + 1 个 main |
| 提高该上限 | ❌ 不可行 | `hooks.user_defines` 的 `defines` 只作用于「从源码编译 sqlite3」；默认走 GitHub **预编译二进制**，改不了编译选项 |
| `SQLITE_MAX_VARIABLE_NUMBER` | 32766（默认，未覆盖） | 现有 999 切段过于保守但无害；**本轮不改**（守 D9 精神） |

---

## 4. 架构设计

### 4.1 文件布局

```
map.db                      ← main，可写：points/lines/areas/gates/entities/schema_meta

<包目录 basemap/>                Android: /sdcard/Android/data/com.example.map/files/basemap
                                 Linux : ~/.local/share/com.example.map/basemap
  t22.60_114.10.db              ← pack，只读，ATTACH
  t22.60_114.20.db
  t22.70_114.10.db
  t22.70_114.20.db
  _import_tmp.db                ← D11：importOsm* 的落点（临时 pack）
```

**包目录解析规则**（`db_factory.dart` 的 `resolveBasemapDir()`）：

1. Android：`getExternalStorageDirectory()`（= `/storage/emulated/0/Android/data/<pkg>/files`）
   → 拼 `basemap/`；
2. 若它返回 `null`（外部存储未挂载）或不可写 → **回退** `getApplicationSupportDirectory()/basemap/`；
3. 非 Android（Linux 桌面）：直接 `getApplicationSupportDirectory()/basemap/`。

> **为什么外部专属目录是关键**：`/data/data/<pkg>/files/` 需要 root 或 `run-as` 才能写入，
> `adb push` 进不去；而 `/sdcard/Android/data/<pkg>/files/` 既是 App 专属（无需任何权限）、
> 又能被 `adb push` 直接写入 —— 省掉「先推到公共目录再拷贝进私有目录」的 1.97GB 双份开销。
>
> **代价**：卸载 App 时该目录会被系统清除（包需重推）。§8 R-09 记录。

### 4.2 包（pack）格式

**一个 pack = 一个独立的 SQLite 文件**，内部结构与现有导入层**完全同构**：

| 对象 | 定义 |
|------|------|
| `import_nodes(id, osm_id, lat, lng)` | 复用 `lib/core/schema.dart` 的 `schemaV2Statements[1]` + 唯一索引 + bbox 索引 |
| `import_ways(id, osm_id, kind, name, cost_class, one_way, is_area, tags, node_ids, min_lat, min_lng, max_lat, max_lng)` | 复用 `schemaV2Statements[3..6]` |
| `import_pois(id, osm_id, name, lat, lng, tags)` | 复用 `schemaV2Statements[7..9]` |
| `import_bounds(id=1, …)` | **充当 pack 清单**：`region` = tile key，bbox/counts = 该包统计 |
| `PRAGMA user_version` | = `kPackSchemaVersion`（复用 sqflite 存版本的位置） |

**好处**：现有 `schemaV2` 的 DDL 常量**一字不改**即可复用；`ImportBoundsRow.fromDb` 等
既有解析代码也能直接读 pack 清单。

#### 4.2.1 ⚠️ 跨包边界的 way 必须写完整几何（关键正确性要求）

如果按 bbox 粗暴裁剪，一个横跨两个 tile 的 way 会在两个包里各存半截 → 地图上出现**断裂的路**。

**正确规则**：

1. **way 归属**：way 的 bbox 与 tile 相交 → 进入该 tile 的包（**允许一个 way 进多个包**）。
2. **节点写入**：包内**必须包含该包所有 way 引用到的全部节点坐标**，即使节点落在 tile 之外。
   → 即「先定 way，再补全其节点」，而不是「先裁节点，再裁 way」。
3. **POI 归属**：半开区间 `[lat0, lat0+0.1) × [lng0, lng0+0.1)` —— 保证每个 POI **只属于一个包**。
4. **跨包去重**：查询层按 `osm_id` 去重（way/POI）。跨界 way 会在多个包里出现，去重后只画一次。

代价：相邻包间会有**重叠节点**（各自独立存储）。实测包体积已包含这部分开销。

### 4.3 ATTACH 生命周期与 `MAX_ATTACHED=10` 约束

**上限**：`main`(map.db) + 最多 **9** 个底图包。

**视口跨格数估算**（`m/px = 40075016.686 × cos(22.7°) / (256 × 2^z)`，按 800px 宽屏）：

| zoom | m/px | 视口跨度 | 0.1° 格数 |
|-----:|-----:|---------:|----------:|
| 11 | 141 | ~113 km ≈ 1.0° | **11×11 → 爆** |
| 12 | 70 | ~56 km ≈ 0.5° | **6×6 → 爆** |
| 13 | 35 | ~28 km ≈ 0.25° | 3×3 = 9（临界） |
| 14 | 18 | ~14 km ≈ 0.13° | 2×2 = 4 |
| ≥15 | ≤9 | ≤7 km | 1~2 |

**因此必须设缩放下限**：

> **zoom < 13.5 时不加载矢量底图层**（返回空视图，不 attach 任何包）。

这与现有 `ImportLayerZoomPolicy` 天然吻合——`zi <= 13` 档本来就只画主干路 + 大型 POI，
远景视觉由 OSM 栅格瓦片承担。加了这条之后，实际跨格数 ≤ 9，稳在 `MAX_ATTACHED` 内。

**额外兜底**（防止意外超限）：若命中包数 > 9，按「视口中心距离」排序取最近 9 个，
其余丢弃并在 `details` 里标注 `[包数超限 N→9]`。

**ATTACH 切换成本**：`ATTACH`/`DETACH` 是廉价的（不复制数据，只打开文件句柄）。
按视口语义做 diff：只 DETACH 不再需要的、ATTACH 新需要的。

**只读打开**：`ATTACH DATABASE 'file:...?mode=ro' AS basemap_x`（URI 形式）保证底图包不被误写；
同时因为包来自 APK 解包/adb push，App 侧全程只读。

### 4.4 查询层改造（`AppRepository.queryImportLayer`）

保持**对外签名与返回类型不变**（`ImportLayerView{ways, pois}`），改动都在内部：

```
1. 若 zoom < kBasemapMinZoom(13.5) → 直接返回空 ImportLayerView（onPhase 仍按序上报）
2. 计算视口命中的 pack key 集合（从已扫描的 pack 清单里按 bbox 相交筛）
3. diff 当前 attached 集合 → DETACH 多余 / ATTACH 缺失（受 9 上限保护）
4. 对每个 attached pack 执行现有 roads / pois 查询（表名前缀改成 <alias>.）
5. 合并结果：ways 按 osm_id 去重、pois 按 osm_id 去重
6. 跨包收集 node_ids → 对每个 pack 用 <alias>.import_nodes 查它自己有的那些（999 切段保留）
7. 组装 ImportWayView / ImportPoiView（与现在完全一致）
```

**`hasImportLayer()` / `getImportBounds()` 语义变更**：
- 从「user.db 里有没有 import_bounds」→「**包清单是否非空**」；
- `getImportBounds()` 返回**所有已安装包的并集摘要**（region 显示为 `packs:N`）。

### 4.5 首启引导（替换 `ensureDefaultImportLayer`）

现有那套「三阶段 `schema_meta` 标志位 + 分批导入 + corrupt 自愈」**整体删除**，换成文件级幂等逻辑：

```
ensureBundledPacks():
  for each asset in kBundledPackAssets:            # pubspec 登记的 6 个 .db
      dest = <packDir>/<key>.db
      if dest 存在且大小 == asset 大小 → skip     # 幂等，天然无需标志位
      bytes = rootBundle.load(asset)               # 单包最大 58.5MB，内存可控
      写 dest.tmp → rename(dest)                   # 原子，避免半截文件被 ATTACH
  刷新 pack 清单
```

**为什么比现在安全**：单包最大 13.3MB（内置集）/ 58.5MB（全省最大格，仅在 adb push 场景出现，
不经过 asset），内存里只有一个 `ByteData`；无 JSON 解析、无对象常驻、无分批 Batch
—— 第九章分析过的 OOM 三要素全部消失。

**进度上报**：`MapDataPhase.importingNodes` 保留，语义改为「正在解包内置底图…（i/N）」。
新增 `MapDataPhase.scanningPacks`（正在扫描底图包…）。

### 4.6 schema 版本演进（v2 → v3）

`lib/core/schema.dart`：

| 项 | 变更 |
|----|------|
| `schemaVersion` | `2` → **`3`** |
| `schemaV1Statements` | **不动**（用户层 5 表 + 索引） |
| `schemaV2Statements` | **拆成两份**：`packDdlStatements`（`import_*` 四表，供 pack 生成器与校验器复用）与 `userV3DropStatements`（`DROP TABLE IF EXISTS import_*`） |
| `_onCreate` | v3 全新建库 = v1 用户层 + `schema_meta`，**不再建 `import_*`** |
| `_onUpgrade(2→3)` | 执行 `DROP TABLE IF EXISTS import_bounds/import_nodes/import_ways/import_pois`，写 `schema_version=3` |

**既有 Android 用户影响**：升级后 user.db 里的导入层被丢弃，改由 pack 提供。
因为内置 4 格覆盖 corridor 且范围更大（36.97 万 vs 19.2 万节点），**用户感知为底图变多、不会丢失**。
用户层数据（区块/门/常路点）与「带入」产生的数据完全不受影响。

---

## 5. 改动清单

### 5.1 新增文件

| 文件 | 作用 |
|------|------|
| `tool/basemap_pack/build_packs.py` | 生成器：PBF → 0.1° 网格 pack（详见 §6） |
| `tool/basemap_pack/validate_pack.dart` | schema 漂移校验器 + pack 结构校验（详见 §6.3） |
| `lib/data/basemap_packs.dart` | pack 扫描 / 清单 / ATTACH 生命周期管理（`PackRegistry` + `PackAttachManager`） |
| `assets/basemap/t*.db` × 4 | 内置包（生成器产物，登记进 `pubspec.yaml`） |

### 5.2 修改文件

| 文件 | 改动 |
|------|------|
| `lib/core/schema.dart` | `schemaVersion=3`；拆出 `packDdlStatements` / `userV3DropStatements` |
| `lib/data/app_repository.dart` | ① `_onCreate`/`_onUpgrade` 走 v3；② `queryImportLayer` 改为跨 pack 查询 + 去重；③ `hasImportLayer`/`getImportBounds` 改语义；④ `importOsm*` 保留（D7）但改为写入临时 pack `basemap/_import_tmp.db`（D11） |
| `lib/data/db_factory.dart` | 新增 `resolveBasemapDir()`（外部专属目录优先，三级回退，见 §4.1），并确保目录存在 |
| `lib/main.dart` | `ensureDefaultImportLayer` → `ensureBundledPacks` + 初始化 pack 注册表 |
| `lib/features/map/import_defaults.dart` | **重写**：三阶段标志位/分批导入 → 文件级幂等解包 |
| `lib/features/map/import_layer_providers.dart` | 新增 `kBasemapMinZoom`；`importLayerProvider` 接入 pack 感知；`MapDataPhase` 增 `scanningPacks` |
| `lib/features/settings/settings_page.dart` | 新增「底图包管理」区（列出已装包 / 占用 / 清除）；「恢复默认底图」→「重装内置包」 |
| `pubspec.yaml` | `assets` 增 6 个 `assets/basemap/t*.db`；移除 `assets/osm/corridor.osmapp`（D7：不再随包） |
| `test/data/import_layer_test.dart` | 重写导入层相关用例为 pack 语义；修好「首启默认底图兜底」 |
| `test/widgets/{widget_test,map_smoke_test,map_smoke_test}.dart` | 修好 3 个冒烟红测试 |

### 5.3 删除

| 对象 | 说明 |
|------|------|
| `lib/features/map/import_defaults.dart` 里的 `kMetaDefaultOsmStarted/Loaded/Corrupt` 三阶段机 | 文件级幂等取代之 |
| `pubspec.yaml` 的 `assets/osm/corridor.osmapp` | D7；`.osmapp` 代码能力保留，仅不再分发 |
| `assets/osm/corridor.osmapp`（本地文件） | 生成器改为直接产出 pack；保留 `.bak` 供回滚 |

---

## 6. 生成器设计

### 6.1 `tool/basemap_pack/build_packs.py`

- 依赖：`pyosmium`（与现有 `tool/pbf_extract/main.py` 一致）+ 标准库 `sqlite3`（零额外依赖）；
- 流程：
  1. **pass 1（nodes）**：流式读取，按 0.1° 半开区间分箱，写入 `nodes_by_tile[tile][osm_id] = (lat, lng)`；POI 按同一规则分箱；
  2. **pass 2（ways）**：对每个 way 计算 refs 与 bbox；对每个与 bbox 相交的 tile，登记该 way；
  3. **补全几何**：对每个 tile，把其 way 引用的**全部节点**（含 tile 外）从 pass 1 的全局节点表取出；
  4. **写包**：每 tile 一个 `.db`，事务批量插入 + `PRAGMA journal_mode=OFF, synchronous=OFF`，
     末尾 `VACUUM` + `PRAGMA user_version = kPackSchemaVersion` + 写 `import_bounds`；
- 输出：
  - `assets/basemap/`：内置 4 格（corridor 覆盖集，用 `--bundled` 或写死 key 列表）
  - `basemap_out/`：其余全部格（供 `adb push`）
- CLI：`--bbox`（只生成某区域）、`--tiles`（只生成指定 key）、`--bundled-only`
- **预估耗时**：PBF 两遍遍历（现有 corridor 生成器同流程，全省约 5–10 分钟）+ 写 1.97GB SQLite。

#### 6.1.1 🚨 格号计算必须防浮点误差（硬性要求）

**唯一真理**：`tile_index(x) = floor(round(x, 7) / 0.1 - round(BASE, 7) / 0.1 + 1e-9)`

反面教材（我实测踩到）：

```python
# ❌ 错误：会在 bbox 边界多算一整列格
t = int((lon - 109.0) // 0.1)      # lon=114.10 时 → 50（应为 51）
# 原因：114.10 - 109.0 == 5.099999999999994，// 0.1 == 50.0

# ✅ 正确
t = math.floor(round((round(lon, 7) - 109.0) / 0.1, 9) + 1e-9)
```

必须配套的**自检**（生成器内置断言，不通过就退出）：

1. `tile_index(114.10) == 51`、`tile_index(22.65) == 26`（边界值专测）；
2. 每个内置格的节点数写入日志，与 §3.3 的实测值比对（容差 0，因为数据源相同）；
3. 所有格的节点数之和 == 全省节点数（不重不漏）。

> 我在勘察阶段就因为这个 bug 把内置集从 **4 格错算成 6 格**（34.5MB 错报为 56.3MB）。
> 生成器里若不设断言，这类错误会以「多出一个空/低密度包」的形式静默发生。

> 内存注意：pass 1 的全量节点表 ≈ 2106 万 × (int + 2 float) 在 Python dict 里约 **2.5–3.5GB**。
> 若本机内存吃紧，改为「**按 tile 分批**」：先扫一遍只统计 tile→way 归属，再对每个 tile
> 单独一遍扫描取所需节点。这会把内存压到单 tile 级别，但遍历次数上升。**计划里默认走内存方案，
> 实测爆内存再切分批**（记为 R-02）。

### 6.2 DDL 单一真理源防漂移

- Python 侧**手写**一份 `import_*` DDL 副本（复制自 `lib/core/schema.dart` 的 `schemaV2Statements`），
  并定义 `PACK_SCHEMA_VERSION = 3`；
- 两边任何一处改动都可能漂移 → 由 §6.3 的 Dart 校验器兜住。

### 6.3 `tool/basemap_pack/validate_pack.dart`

用**真实的 `lib/core/schema.dart` 常量**去校验一个真实 pack：

1. `PRAGMA user_version` == `kPackSchemaVersion`；
2. `PRAGMA table_info(import_nodes/ways/pois/bounds)` 的列名集合，与从
   `packDdlStatements` 解析出的期望列集合**逐一比对**（缺列 / 多列都报错）；
3. 索引清单比对（`PRAGMA index_list`）；
4. 抽样一致性：随机抽 50 条 way，检查其 `node_ids` 引用的节点**在本包内全部命中**
   （即 §4.2.1 的「几何完整」要求），统计 `badRefWays`；
5. 对内置 4 格跑一遍，输出 `OK / 失败清单`。

（仿现有 `tool/pbf_extract/validate_osmapp.dart` 的形态。）

---

## 7. 验证步骤

### 7.0 生成器阶段（可在小范围先验证）

```bash
cd ~/Projects/flutter/map
# 先只生成 corridor 覆盖的 4 格，验证流程
python3 tool/basemap_pack/build_packs.py --bundled-only
# 校验结构 + schema 一致性
dart run tool/basemap_pack/validate_pack.dart assets/basemap
```

### 7.1 离线静态校验

```bash
dart analyze lib/                 # 期望 No issues found!（0 error / 0 warning / 0 info）
                                  # ⚠️ 只分析 lib/，不要带 test/（AGENTS.md §1）
```

### 7.2 ~~单测~~（**已作废，2026-09-15**）

> 按 `AGENTS.md` §1，本项目**不写测试、不跑测试**；`test/` 下的文件都是早期语义、编译不过。
> 本节原计划的 `flutter test`（期望失败数 **12 → 8**）**作废、不执行**。
> 那一轮想要覆盖的能力（pack 扫描、ATTACH diff、跨包查询合并去重、跨包 node 解析、
> zoom 下限降级、包数超限降级）改由 **`tool/checks/` 下的一次性脚本**或**手工实测**验证。

### 7.3 Android 实测（主验收）

```bash
flutter build apk --debug
unzip -l build/app/outputs/flutter-apk/app-debug.apk | grep -E "basemap|sqlite"
# 期望：6 个 assets/basemap/t*.db + lib/arm64-v8a/libsqlite3.so
```

装到手机后：
1. 首启能进地图页，**4 个内置包自动解包**，底图正常显示；
2. **控制台无异常**，尤其是 ATTACH 相关；
3. 平移出内置范围 → 底图消失但**不崩**（无该区域包）；
4. 推到手机几个相邻格 → **重启 App**（或触发重新扫描）→ 底图无缝出现，
   **跨包边界处道路不断裂**（这是 §4.2.1 的验收点）；
5. 缩到 zoom 13 以下 → 底图层关闭且**不报错**；
6. 圈地/建门后重启 → 用户数据仍在。

推送样例（**注意 §9 L-01 决定最终目录**）：

```bash
# 外部应用专属目录，adb push 可直接写（无需 root / run-as）
DEST=/sdcard/Android/data/com.example.map/files/basemap
adb shell mkdir -p $DEST
adb push basemap_out/t22.60_114.10.db $DEST/
adb shell ls -la $DEST
```

### 7.4 Linux 实测（回归）

```bash
flutter run -d linux
ls -la ~/.local/share/com.example.map/basemap/
```
期望：4 个内置包解包成功、底图显示、第九章的全部结论不退化。

---

## 8. 风险与回滚

| 编号 | 风险 | 影响 | 缓解 |
|------|------|------|------|
| R-01 | `MAX_ATTACHED` 被突破 | 查询抛 `too many attached databases` | zoom < 13.5 不加载（§4.3）+ 命中数 > 9 时取最近 9 个；两者叠加冗余 |
| R-02 | 生成器 pass 1 节点表吃满内存（估 2.5–3.5GB） | 生成失败 | 先按内存方案跑；爆了改「按 tile 分批扫描」（§6.1），CPU 换内存 |
| R-03 | 生成器耗时（PBF 两遍 + 写 1.97GB） | 每次全量重生成成本高 | `--bbox` / `--tiles` 支持增量；内置 4 格可单独快速重生成 |
| R-04 | **跨包边界道路断裂**（最容易出错的一点） | 地图出现半截路 | §4.2.1 的「先定 way 再补全节点」规则 + §6.3 校验器的 `badRefWays` 检查 + §7.3 第 4 步人工确认 |
| R-05 | Python 手写 DDL 与 `schema.dart` 漂移 | 运行期「no such column」 | §6.3 Dart 校验器；列为收尾必跑项 |
| R-05b | **格号计算的浮点误差**（实测已踩） | 边界上多算/少算整列格 → 内置集与统计全错 | §6.1.1 的三条内置断言（边界值专测 + 节点数比对 + 不重不漏） |
| R-06 | v2→v3 升级丢掉旧导入层 | 老用户底图暂时变空 | 内置 4 格覆盖 corridor 且范围更大（36.97 万 vs 19.2 万），实际是「变多」；用户层数据不受影响 |
| R-07 | 查询跨 9 个包的性能 | 视口查询变慢 | 实测单包走廊级查询 108ms；9 个包串行查询需实测（§7.3）。若过慢，后续加「按 zoom 限制包数」或「调小包粒度」 |
| R-08 | 首启解包 4 个包（34.5MB）耗时 | 首启等待 | 单包原子写 + 幂等 skip；预计秒级（相比原来解析 25MB JSON + 19 万行入库，是大幅加速） |
| R-09 | 外部应用专属目录在**卸载 App 时被系统清除** | 重装后 adb push 的包全丢，需重推 | 属预期行为（内置 4 格仍在 APK 内，重装后开箱可用）；设置页显示「已装包数」便于发现；`adb push` 一条脚本化命令即可恢复 |
| R-10 | 外部存储未挂载 / 无写权限 | 包目录不可用 | `resolveBasemapDir()` 三级回退到私有目录（§4.1），最差情况退化为「只有内置包」 |

**回滚**：

1. `git` 不存在（项目无版本控制）→ **动手前先整体备份 `lib/` 与 `pubspec.yaml`**；
2. 生成器与 pack 文件可直接删除，不影响代码回滚；
3. `schemaVersion` 从 3 回退到 2 需要重建 user.db 里的 `import_*` 表（沿用 `importOsm*` 代码路径 + 旧的 `corridor.osmapp.bak`）；
4. 因此**回滚代价高于第九章**，建议本轮开工前先做一次完整目录备份。

---

## 9. 已定夺的决策（原待定夺项）

| 编号 | 问题 | **结论** |
|------|------|----------|
| L-01 | 包目录用私有还是外部专属 | ✅ **外部应用专属目录**（D6 / §4.1）。解决 `adb push` 写不进私有目录的问题，并省掉 1.97GB 双份存储；非 Android 与异常情况三级回退 |
| L-02 | `importOsm*` 写入哪 | ✅ **写入临时 pack** `basemap/_import_tmp.db`（D11）。保留 D7 的代码能力，且与 pack 语义一致 —— `queryImportLayer` 无需为它写特殊分支，它就是一个普通 pack |
| L-03 | 内置 4 格是 corridor 的 1.9 倍数据（36.97 万 vs 19.2 万节点） | ✅ **接受**（换来「跑出走廊不空窗」）。若之后更在意 APK 体积，可只内置 `t22.60_114.10` 单格（14.2 万节点 / 13.3MB seed → APK ~6MB），但走廊大半会空窗 |
| L-04 | Linux 桌面包目录策略 | ✅ 直接 `~/.local/share/com.example.map/basemap/`；`adb push` 换成 `cp` |
| L-05 | 临时 pack 的生命周期 | 不纳入「已装包」计数；设置页单独显示；重导时整体替换（沿用现有 `replaceImportLayer` 语义） |

---

## 10. 开放问题（本轮不做）

| 编号 | 问题 |
|------|------|
| P-01 | App 内下载 pack（需要托管位置 + 断点续传 + 校验和） |
| P-02 | 可变尺寸瓦片（四叉树）以消除 0.1° 网格的密度倾斜（中位 2,422 vs 最大 627,338，差 259 倍） |
| P-03 | 从源码编译 sqlite3 以提高 `SQLITE_MAX_ATTACHED`（代价：需要 C 工具链 + amalgamation） |
| P-04 | `node_ids` 由 JSON 文本改为二进制 BLOB（varint + 中位数增量），进一步压缩包体积 |
| P-05 | `osm_prep.dart` 手写 XML 解析器不支持 `<!-- -->` 注释导致 8 个红测试 |
| P-06 | 包完整性校验（生成时写 SHA-256 到 `import_bounds`，App 侧加载前校验） |
| P-07 | **ATTACH 目前是读写打开，未按 §4.3 用 `mode=ro`**（见 §11.4 O-01） |
| P-08 | **`test/` 全套仍是 v2 语义、无法编译**（见 §11.4 O-02） |

---

## 11. 实施结果（本轮实测定稿）

### 11.1 交付物清单

| 文件 | 状态 | 说明 |
|------|------|------|
| `tool/basemap_pack/build_packs.py` | 新增 | 生成器：PBF → 0.1° 网格 pack；内置 `badRefWays` 自检，非 0 则退出码 1 |
| `tool/basemap_pack/validate_pack.dart` | 新增 | 校验器：以 `lib/core/schema.dart` 为唯一真理源反查 DDL 漂移 + badRefWays + `--deep` bbox 抽样 |
| `lib/data/basemap_packs.dart` | 新增 | `PackRegistry`（bbox 从文件名解析，不打开包）+ `PackAttachManager`（差量 ATTACH/DETACH） |
| `assets/basemap/t*.db` × 4 | 新增 | 内置包，38.5MB（见 §11.2） |
| `lib/core/schema.dart` | 改 | `schemaVersion` 2→3；`schemaV2Statements` → `packDdlStatements`；新增 `kPackSchemaVersion=1` / `userV3DropStatements` |
| `lib/data/db_factory.dart` | 改 | 新增 `resolveBasemapDir()`（外部应用专属目录优先，三级回退） |
| `lib/data/app_repository.dart` | 改 | v3 迁移；`queryImportLayer` 改跨包查询；`_writeTempPack`（D11）；`hasImportLayer`/`getImportBounds`/`clearImportLayer` 改语义；新增 `deleteAllPacks`/`rescanPacks` |
| `lib/features/map/import_defaults.dart` | **重写** | 三阶段标志位 + 分批导入 → **文件级幂等解包**（marker `.bundled.json` + `kBundledPackVersion`） |
| `lib/features/map/import_layer_providers.dart` | 改 | 新增阶段 `scanningPacks`/`extractingPacks`/`importingNote`；`importingNodes` 移除；接 `onNote` |
| `lib/features/settings/settings_page.dart` | 重写 | 底图包管理 UI（状态/包目录/重扫/清临时包/重装内置/删全部） |
| `lib/main.dart` | 改 | 移除 postFrame 引导（见 §11.3 问题 6） |
| `pubspec.yaml` | 改 | assets 换为 4 个 `.db`；移除 `corridor.osmapp` |
| `docs/design/README.md` | 改 | 登记第九章、第十章 |

### 11.2 内置包实测数据（4 格）

生成命令：`python3 tool/basemap_pack/build_packs.py --bundled-only`

| pack | 总节点 | **本格自身** | 格外补全 | ways | POI | 体积 |
|------|---:|---:|---:|---:|---:|---:|
| `t22.60_114.10` | 149,507 | **142,026** | 7,481 | 14,992 | 465 | 14.9 MB |
| `t22.60_114.20` | 80,246 | **73,571** | 6,675 | 4,924 | 382 | 7.4 MB |
| `t22.70_114.10` | 85,362 | **80,464** | 4,898 | 8,347 | 267 | 8.4 MB |
| `t22.70_114.20` | 78,754 | **73,673** | 5,081 | 6,764 | 453 | 7.7 MB |
| **合计** | **393,869** | **369,734** | 24,135 | **35,027** | **1,567** | **38.5 MB** |

**三重独立验证**：

1. 生成器 pass1 报 `nodes=21,062,792`，与用纯 Python 独立解析 PBF 的结果**逐位一致**；
2. 四格「本格自身」节点数与我独立解析的实测值**逐格精确吻合**（142,026 / 73,571 / 80,464 / 73,673），合计 369,734；
3. `badRefWays = 0` —— 生成器自检与 `validate_pack.dart --deep`（每包抽 300 条 way 核对 bbox）双重复核通过。

**体积偏差**：计划预测 APK +15.6MB，实测 **+17.4MB**（seed 38.5MB × 0.452）。多出的 1.8MB 来自 24,135 个「格外补全」节点——这是 §4.2.1 几何完整性的必要代价。

**vs 旧方案**：`corridor.osmapp` 23.91MB / APK 3.49MB（19.2 万节点）。
新方案数据量 **1.9 倍**、APK **5 倍**，换来「跑出走廊不空窗」+ 首启从「解析 25MB JSON + 19 万行入库」变成「秒级文件解包」。

### 11.3 本轮实际踩到并修掉的 7 个问题（重要经验）

| # | 问题 | 根因 | 修法 |
|---|------|------|------|
| 1 | **格号计算浮点陷阱** | `(114.10 - 109.0) // 0.1 == 50.0`（应为 51），因为 `114.10-109.0 == 5.099999999999994` | 先 `round(x,7)` 再除；并加 3 条内置断言（边界值专测 / 与实测值比对 / 不重不漏）。**勘察阶段此 bug 曾把内置集从 4 格错算成 6 格（34.5MB 错报为 56.3MB）** |
| 2 | `WayPass` 忽略 `scan_box` | 忘了在 `way()` 里用传入的过滤条件 → 把全省 1,677,445 条 way 全写进中间库，再由回填删掉 94%。白花 41.7s + 59.1s（138s 里的 100s） | 改为用 `locations=True` 直接取坐标，彻底去掉「回填」这一轮 |
| 3 | **`badRefWays = 8`（跨界 way 被截断）** | 我自己加的 `scan_box` 优化（0.1° padding）容不下跨越很远的长 way（有一条缺 79 个节点、横跨 3 个包） | **去掉 bbox 裁剪，全量收集节点**（落盘中间库，内存仍 O(1)）。修后 `丢失 ref = 0 (0.000%)`、`badRefWays = 0` |
| 4 | 校验器报 `file .../.dart_tool/sqflite_common_ffi/databases/assets/... not found` | **sqflite 会把相对路径解析到 `.dart_tool/sqflite_common_ffi/databases/` 之下** | 传绝对路径（`File(f).absolute.path`）。App 侧同理：`PackRegistry` 存的必须是绝对路径 |
| 5 | `use_null_aware_elements` lint | `[..._tiles, if (_temp != null) _temp!]` | 改 `[..._tiles, ?_temp]` |
| 6 | **首启底图为空 + 进度条卡在「正在扫描底图包」，切 Tab 才恢复** | `main.dart` 在 postFrame 里 fire-and-forget 调 `ensureBundledPacks`，与 `importLayerProvider` 的首查形成**竞态**：① 首查在解包完成前 `hasImportLayer()` 返回 false 且无人 invalidate → 底图空；② 解包最后的 `report(scanningPacks)` 覆盖了已落地的 `done` → `map_page` 的隐藏逻辑（要求 `phase==done`）永不触发 | **把顺序改成严格串行**：`importLayerProvider` 在查询前 `await ensureBundledPacks(repo, progress: progress)`；移除 main 的 postFrame 引导。修后首启进度条正常走完并自动消失、底图直接显示 |
| 7 | `settings_page` 两个 warning（未用 import / 未用局部变量） | 重写时留下的 | 删 import；把 `attached` 用进标题（顺便变成有用的信息） |

> **问题 6 的教训**：这是纯运行时竞态，静态分析抓不到。**凡是「后台任务」与「provider 首查」共享状态的地方，都应该串行化而不是靠 invalidate 补**。

### 11.4 开放问题（下一轮优先）

| 编号 | 问题 | 说明 |
|------|------|------|
| **O-01** | **ATTACH 是读写打开，不是 §4.3 要求的只读** | `sqflite_ffi_impl_io.dart:28` 的 `isUri = path.startsWith('file:')` 决定了 `SQLITE_OPEN_URI` **只在主库路径以 `file:` 开头时**才设置。我们传裸路径 → 连接的 URI 处理关闭 → `ATTACH 'file:...?mode=ro'` 会被当字面文件名而失败。所以 §4.3 写的 `mode=ro` 在当前实现下**不可行**。<br>现状（裸 ATTACH，读写）在 Android 上可用（模拟外部存储走 FUSE，权限按 `Android/data/<pkg>` 整棵树判定，`adb push` 进来的 `shell:ext_data_rw 644` 文件仍可被 app 打开）；Linux 也正常。<br>要真正只读，需把主库改成 `file:` URI 打开（`Uri.file(abs) + '?mode=rwc'`），**爆炸半径大**（主库打不开就是灾难），建议单独一轮做并充分回归 |
| **O-02** | **`test/` 全套仍是 v2 语义、无法编译** | 本轮为省时间选择「手动实测」跳过 `flutter test`。`test/data/import_layer_test.dart`、`test/widgets/settings_page_test.dart` 等仍调 `ensureDefaultImportLayer`、依赖 user.db 里的 `import_*` 表。<br>后果：**`flutter analyze`（全项目）会报 test/ 的 error**（`dart analyze lib/` 干净不代表全项目干净）。<br>且 §1.1 G7 承诺的「基线 12 红 → 8 红」**未兑现**（未跑）。 |
| O-03 | 全省打包与 push | 见 §11.5 |
| O-04 | `SQLITE_MAX_VARIABLE_NUMBER` 实际是 32766，但代码仍按 999 切段 | 保守但无害；`kBasemapMinZoom` 已经绕开了最大风险 |
| O-05 | `import_layer_providers.dart` 里 `kInitialViewport` / `kCorridorCenter*` 仍是 corridor 语境 | 现在视口跨格是常态，命名与注释需要更新 |

### 11.5 全省打包与分发

```bash
# 生成（约 20–40 分钟：PBF 两遍 226s + 逐格产出）
python3 tool/basemap_pack/build_packs.py --all --out basemap_out

# 抽样校验（全量校验 2772 个包太慢，建议内置 4 格 + 最大的那格）
dart run tool/basemap_pack/validate_pack.dart assets/basemap --deep
dart run tool/basemap_pack/validate_pack.dart basemap_out/t22.30_114.10.db --deep

# 分发（外部应用专属目录，adb push 可直接写）
DEST=/sdcard/Android/data/com.example.map/files/basemap
tar -C basemap_out -cf - . | adb shell "cat > /sdcard/bm.tar"
adb shell "cd $DEST && tar xf /sdcard/bm.tar && rm /sdcard/bm.tar"
```

> 2772 个文件逐个 `adb push` 会因每文件开销极慢，用 `tar` 管道快得多。
> 磁盘需求：`basemap_out/` ≈ 2.1GB + `_work/` ≈ 1.5GB（跑完自动清理）→ 请预留 ≥4GB。

**⚠️ 内置 4 格与 `--all` 的产物必须一致**：`--all` 会重新生成同样 4 个 key 的包。若生成器逻辑变了（比如改了 `KEEP_TAGS`），必须同步把 `assets/basemap/` 的 4 个包也更新并递增 `kBundledPackVersion`，否则设备上会出现「内置包与 push 包数据口径不一致」。
