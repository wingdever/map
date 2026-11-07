# 第十一章 用户标记的备份：导出与导入

> 状态：**编码完成，待验收**（2026-09-13）。
> 范围：**只做 Linux 桌面端**（本轮明确不管 Android，见 §8 R-11-2）。
> 上游：第六章 §2「数据备份与导入导出」只给了目标，未定语义；本章落定语义并实施。

---

## 1. 需求与范围

用户手动画在「最后一公里地图」上的标记 —— **封闭区块 / 出入口 / 界内路网 / 常送点**
（即 user.db 的用户层 5 表：`points` / `lines` / `areas` / `gates` / `entities`）——
必须能**导出成一个文件**、并在需要时**导入回来**。

这是整个 App 里唯一**无法重新生成**的数据：底图包可以重新 `adb push`，
OSM 数据可以从 PBF 重新切，但「大运城邦北门 07:00–21:00 只让电动车进」
是你一脚一脚跑出来的。所以它的优先级不低于寻路本身。

**不在本章范围内**：
- 底图包（`import_*` 四表 / `basemap/*.db`）—— 只读派生数据，可重新获取；
- 云端同步 / 增量同步 —— 本章是**本地文件**备份，不做网络；
- 自动定时备份 —— 见 §8 R-11-4。

---

## 2. 起点勘察（编码前实测）

| 事实 | 证据 |
|------|------|
| `lib/core/export.dart`（240 行）+ `lib/core/import.dart`（190 行）**早就存在** | M1 时代写的，GeoJSON FeatureCollection + `schema: map_area_gate` |
| 它们**是死代码** | `grep -rn "buildExportJson\|importFromJson" lib/` → **零命中**；只有 `test/core/export_test.dart`、`test/core/import_test.dart` 引用 |
| 因此缺的是**整整三层** | ① DAO 读全用户层 → `ExportBundle`；② `ImportResult` → 事务落库；③ 文件读写 + UI |
| 基线测试 | `flutter test` = **+83 −12**（8× `osm_xml`、1× `import_layer_test` 编译失败、2× `settings_page` 过期断言、1× 其它） |

一句话：**格式层写好了，但没有任何东西调用它**。本章的工作量主要在「接上去」。

---

## 3. 决策表

| ID | 决策 | 结论 | 理由 |
|----|------|------|------|
| D1 | Linux 文件对话框 | **引入官方 `file_selector`**（GTK 原生 FileChooser） | 体验最好；沙箱实测 `file_selector 1.1.0` + `file_selector_linux 0.9.4+1`，`flutter build linux` 通过，bundle 内有 `libfile_selector_linux_plugin.so` |
| D2 | 导入语义 | **合并追加（幂等），不做覆盖式恢复** | 用户拍板。合并是只增不改的操作，误导入不会毁数据 |
| D3 | 文件格式 | **明文 `.mapexport.json`** | 可 diff、可手工修、零依赖；个人数据量小（几十~几百 KB） |
| D4 | 导出范围 | 用户层 5 表 + 每个区块的边界环 | 底图不在其中 |
| D5 | 测试范围 | 只修与本功能相关的红测试 | 8 个 `osm_xml` 红测试是独立问题线（P2），本轮不动 |
| D6 | 导入前是否自动备份 | **不做** | 合并语义本身不破坏数据，再加一层自动备份是噪音 |

---

## 4. 导出

### 4.1 文件格式：GeoJSON FeatureCollection，schema v2

顶层：

```json
{
  "type": "FeatureCollection",
  "schema": "map_area_gate",
  "schema_version": 2,
  "crs": { "type": "name", "properties": { "name": "urn:ogc:def:crs:OGC:1.3:CRS84" } },
  "exported_at": "2026-09-13T04:47:12.000Z",
  "app": "map",
  "counts": { "points": 5, "lines": 4, "areas": 1, "gates": 1, "entities": 1 },
  "features": [ ... ]
}
```

每个 feature 的 `properties.table` 标明来自哪张表：`points` / `lines` / `areas` / `gates` / `entities`。
几何一律是 GeoJSON 标准顺序 **`[lng, lat]`**（内部模型是 WGS-84 `(lat, lng)`，转换只在这一层发生）。

`areas` 的几何是 `Polygon`（由边界线组环后**显式闭合**，即首尾点重复）；
`gates` 是 `Point`；`lines` 是 `LineString`；`points` 是 `Point`；`entities` **没有几何**
（它的位置由 `point_id` 指向 `points` 表表达）。

### 4.2 v1 → v2 改了什么，为什么

| 变更 | 原因 |
|------|------|
| 每类要素补 `created_at` / `updated_at`（epoch 毫秒） | v1 导出的数据导入后时间戳全丢 —— 作为**备份**这是不能接受的 |
| 顶层补 `exported_at` / `app` / `counts` | 不用解析 features 就能确认「这份备份是什么时候的、有多少东西」 |

**向后兼容**：`assertImportable` 只拒绝 `schema_version > exportSchemaVersion`，
所以 v1 文件照常可读（缺的字段取 `null`）。有专门的回归测试守着
（`test/core/import_test.dart` 的「v1 文件照常可读」）。

### 4.3 软删除的处理

导出**只导 `deleted_at IS NULL` 的行**。备份是「我现在拥有的东西」，
不是「审计流水」；把墓碑一起搬来搬去只会让导入侧的去重更难做。

---

## 5. 导入：按业务键的幂等合并

### 5.1 为什么不能按导出文件里的 `id` 插入

导出文件里每个 feature 都带 `id`（`points.id` / `areas.id` / …），
而且 `lines.start_point_id`、`gates.area_id`、`gates.boundary_line_id`、
`entities.point_id/line_id/gate_id` 全都用这些 id 互相引用 ——
**看起来**直接照着插一遍就能完美还原。

**但那是导出时那一台设备的 rowid**。新库的 rowid 与它毫无关系：

- 直接插 → 撞主键（`areas.id=1` 在新库里可能已经被别的区块占了）；
- 忽略 `id` 插 → 每一个引用都指错行（门挂到别人的区块上，甚至指向不存在的行）。

所以必须**重映射**。而一旦要重映射，就必然要回答「备份里的这一条，在新库里
是不是已经有了」—— 这正是「合并」而不是「覆盖」的由来。

### 5.2 业务键（本章的核心设计）

用**业务键**而不是 rowid 判定「同一条记录」：

| 表 | 业务键 | 精度 / 容差 | 为什么 |
|----|--------|-------------|--------|
| `points` | 坐标 → `"lat,lng"` | 7 位小数 ≈ **1.1 cm** | 坐标就是点的身份；1 cm 容差吸收 JSON 双精度往返误差 |
| `areas` | `名字 + 环质心` | 4 位小数 ≈ **11 m** | 区块的身份是「名字 + 大致位置」。11 m 容差让「导出后手工微调几个顶点」仍命中同一区块，同时不同地点的同名区块仍能区分 |
| `lines` | `kind + 所属区块键 + 两个端点坐标键` | 端点为 1.1 cm，端点**无序** | A→B 与 B→A 是同一条边 |
| `gates` | `所属区块键 + 名字 + 坐标键` | 1.1 cm | 同一个区块下的门按名字+位置区分 |
| `entities` | `名字 + 锚点坐标键` | 1.1 cm | 常送点同名但位置不同 = 两个点 |

**为什么 `lines` 的键里要包含「所属区块键」**（容易忽略但很关键）：

区块边界边只在**所属区块**内部有身份。若两个区块各画了一次同一段墙
（坐标相同），它们是两条独立的边，各自挂在各自区块下。
如果只按坐标去重，后导入的那个区块会变成**没有边界的空壳**。

反过来，当区块本身因为「名字+质心」命中而被跳过时，
它的边界线也会因为「区块键相同 + 端点坐标相同」而逐条命中 → 一起跳过。
**不需要为「区块被跳过」写任何特判** —— 这是业务键设计自然带来的性质。

### 5.3 算法

```
planMerge(existing, incoming):
  index ← buildMergeIndex(existing)          # 四张「业务键 → id」表 + 实体键集合
  解析 incoming 内部的引用（旧 id → 键）

  for p in incoming.points:                  # ① 点
      key = pointKey(p);  index 有 → 跳过；否则登记为「待插入」
  for a in incoming.areas:                   # ② 区块
      key = areaKey(a);   index 有 → 跳过；否则待插入
  for l in incoming.lines:                   # ③ 线（两端点必须都能解析，否则整条丢弃）
      key = lineKey(l);   index 有 → 跳过；否则待插入（记下端点键 + 区块键）
  for g in incoming.gates:                   # ④ 门
      key = gateKey(g);   同上（记下区块键 + 边界线键）
  for e in incoming.entities:                # ⑤ 实体
      key = entityKey(e); 同上（记下点/线/门键）

  return MergePlan{index, ops(按 ①→⑤ 排序), stats, addedAreaNames, skippedAreaNames}

applyMergePlan(plan, insert):                # insert = txn.insert，或单测里的假实现
  以 index 的键→id 表为种子
  for op in plan.ops:                        # 顺序保证「引用一定已存在」
      解析 op 里的键 → 真实 id，插行，把新 id 写回键→id 表
```

「备份内部自身有重复」也在同一步被折叠（登记进键集合后再遇到就跳过）——
手改过的备份文件不会把重复灌进库里。

### 5.4 由此得到的三个性质（都有测试守着）

1. **幂等**：同一个文件导入 N 次，第 2 次起 `added == 0`，行数不变；
2. **可叠加**：A 机画的区块 + B 机画的区块合到一起，两边都在，
   且各自仍能组出完整的边界环；
3. **引用不串**：`gates.area_id` / `lines.start_point_id` / `entities.point_id`
   一律指向**新库里真实存在**的行。

### 5.5 已知取舍

| 取舍 | 说明 |
|------|------|
| **坐标重合的点会被合并成一个** | 例如常送点锚点恰好落在某个环顶点上 → 导入后两者共用一行 `points`。这是刻意的（否则相邻区块共享的墙角会被复制成多份）。代价：被合并掉的那一行的 `kind` / `accuracy` / `ext` 会丢。有专门用例记录该行为 |
| **区块改名后再导入旧备份会产生重复区块** | 业务键含名字，改名 = 新身份。UI 的预览对话框会把「将新增哪些区块」列出来，用户能在上屏前发现 |
| **不追踪「谁改了谁」** | 合并只判「有没有」，不做字段级合并（同名同址的区块不会用备份里的属性去覆盖库里的）。这是 D2 的直接后果 |
| **区块微调超过 ~11 m 会被当成新块** | 容差取值的必然结果；同样是「保守新增、绝不误删」的取向 |

---

## 6. 文件与 UI

### 6.1 文件选择：`file_selector`（已在沙箱实测）

| 动作 | API | Linux 行为 |
|------|-----|-----------|
| 导出 | `getSaveLocation(suggestedName:, acceptedTypeGroups:)` | GTK 原生「另存为」 |
| 导入 | `openFile(acceptedTypeGroups:)` | GTK 原生「打开」 |

GTK 的保存对话框**不会**因为给了 filter 就自动补扩展名，所以
`_ensureJsonExtension` 会兜一次（用户敲 `mybackup` → `mybackup.json`；
用户明确写了扩展名则原样尊重）。

bundle 里已确认有 `lib/libfile_selector_linux_plugin.so`。

### 6.2 文件名

`map_20260913-044712.mapexport.json` —— 纯 ASCII + `YYYYMMDD-HHMMSS`。
刻意不用中文文件名：网盘、Windows、`adb pull` 之间倒腾时最容易踩编码坑；
时间戳前缀让**按文件名排序 = 按时间排序**。

### 6.3 交互：**先预览，再落库**

```
设置页 → 「我的标记 · 备份」
  ├─ 统计卡：区块 N · 门 M · 路 K · 常送点 J · 坐标点 P
  ├─ [导出] → 另存为 → SnackBar 给出完整路径
  └─ [导入] → 选文件 → ┌─────────────────────────┐
                       │ 导入预览                 │
                       │ 新增区块 1 / 门 2 / …    │
                       │ 跳过（已存在）7          │
                       │ 将新增的区块：· 油甘埔村 │
                       │ [取消]      [确认导入]   │
                       └─────────────────────────┘
```

**为什么必须先预览**：导入是合并语义，用户需要在上屏之前知道
「这次到底会多出哪些区块」。否则一旦导入两份来路相似的备份，
事后只能靠肉眼在地图上找重复。

导入成功 / 失败后：`invalidate` 图层与统计 provider（地图立刻反映新数据）；
落库失败时提示明确写「数据未改动」（因为整个合并跑在一个事务里）。

### 6.4 可测性接缝

原生文件对话框是唯一无法在测试里点的东西，所以它被抽成接口：

```dart
abstract class BackupFilePicker {           // lib/data/backup_service.dart
  Future<String?> pickSavePath({required String suggestedName});
  Future<String?> pickOpenPath();
}
final backupPickerProvider = Provider<BackupFilePicker>(...);
final backupServiceProvider = Provider<BackupService>(...);
```

widget 测试里 `overrideWithValue` 塞一个假 picker（返回临时目录路径），
于是「点导出真的落盘、点导入真的进库」这条链路**不弹任何原生窗口**也能跑。

---

## 7. 测试

| 文件 | 层次 | 覆盖 |
|------|------|------|
| `test/core/merge_test.dart` | 纯 Dart（假 inserter，**不碰 SQLite**） | 业务键语义、空库全新增、**幂等**、叠加、备份内部重复折叠、引用重映射（id 从 1000 起，任何旧 id 泄漏都会被断言抓住）、插入顺序、悬空引用丢弃 |
| `test/data/backup_test.dart` | 真实 SQLite + 真实文件 | 快照内容、软删除过滤、v2 元数据、**往返一致**、门的时间窗/通行类型保真、幂等、叠加、引用不串、坏文件不脏库、预览不落库、`BackupService` 文件读写、文件名约定、provider 接线 |
| `test/widgets/backup_section_test.dart` | widget | 按钮启停、**预览对话框内容**、取消不落库、空操作预览、错误提示、**真实链路（假 picker + 真文件 IO）** |
| `test/core/export_test.dart` / `import_test.dart` | 纯 Dart | 更新为 v2；新增「v1 向后兼容」「区块多边形还原成环」 |

⚠️ **测试里的一个坑（值得记下来）**：`AppRepository.openInMemory` 用的是
`inMemoryDatabasePath`（`':memory:'`），而 sqflite 默认 `singleInstance: true`
—— **同一个测试里开两次拿到的是同一个连接**。于是「导出到新库」会退化成
「导出到自己」，幂等测试会假绿。因此备份测试改用**真实临时文件库**
（`AppRepository.open(<tmp>/map.db, basemapDir: ...)`）。

---

## 8. 风险与本章未做

| ID | 项 | 说明 |
|----|----|------|
| R-11-1 | **没有事务外的"撤销"** | 合并跑在单事务里（失败整体回滚），但**成功之后**没有一键撤销。真要撤销只能再导一份「撤销前的备份」——而本章不自动备份（D6）。若日后觉得疼，再补「导入前自动落一份 .bak」 |
| R-11-2 | **Android 端不可用** | `getSaveLocation` 在 Android 上没有实现（抛 `UnimplementedError`），且 Android 需要 MediaStore / SAF 才能写到用户可见目录。本轮明确不管；**Android 上点导出会看到"导出失败"提示**，不会崩 |
| R-11-3 | 大备份的导入耗时 | 目前全量在内存里解析 + 单事务插入。个人数据量（几千点）毫秒级；若将来上到十万级需要改成分批 |
| R-11-4 | 无自动/定时备份 | 与第六章 §2 的「每日差异备份」相比是缺的。属于「手动能用了再说」 |
| R-11-5 | 备份不含底图包 | 刻意。换机后底图要走 `adb push` 或重装 APK 解包内置 4 格 |

---

## 9. 实施结果

> 待用户在本机跑完 §10 的命令后回填。

### 9.1 新增/改动文件

| 文件 | 动作 |
|------|------|
| `lib/core/merge.dart` | **新增**：业务键 + `planMerge` + `applyMergePlan`（纯 Dart，`RowInserter` 注入） |
| `lib/data/backup_service.dart` | **新增**：`BackupFilePicker` 接口 + `file_selector` 实现 + 文件名约定 + provider |
| `lib/features/settings/backup_section.dart` | **新增**：统计卡 + 导出/导入按钮 + 导入预览对话框 |
| `lib/core/export.dart` | schema v1 → **v2**：补时间戳 + 顶层元数据 |
| `lib/core/import.dart` | 补时间戳解析、**捕获区块 Polygon → 边界环**、向后兼容 v1 |
| `lib/data/app_repository.dart` | 新增 `snapshotUserLayer` / `exportUserLayerJson` / `planUserLayerImport` / `applyUserLayerMerge` / `importUserLayerJson` |
| `lib/features/settings/settings_page.dart` | 顶部接入 `BackupSection` |
| `pubspec.yaml` | 新增依赖 `file_selector ^1.1.0` |
| `test/core/merge_test.dart`、`test/data/backup_test.dart`、`test/widgets/backup_section_test.dart` | **新增**（19 + 19 + 9 = **47** 个用例） |
| `test/core/export_test.dart`、`import_test.dart` | 更新为 v2 并补兼容性用例 |
| `test/data/import_layer_test.dart` | 修 v2 遗留的编译错（`ensureDefaultImportLayer` → `ensureBundledPacks`） |
| `test/widgets/settings_page_test.dart` | 修 v2/v3 遗留的过期断言 |

### 9.2 关键数字（沙箱侧实测，编码过程中）

| 项 | 结果 |
|----|------|
| `dart analyze lib/ test/` | **0 error / 0 warning**；仅剩 9 条历史遗留 info（与第十章基线逐条相同） |
| `test/core/merge_test.dart` | 19 用例（编码过程中在沙箱跑过，全绿） |
| `test/data/backup_test.dart` | 19 用例（编码过程中在沙箱跑过，全绿） |
| `flutter build linux --debug` | 通过（含 `file_selector_linux` 原生插件） |

---

## 10. 请在本机执行的验收命令

> 沿用项目约定：**命令一律由你执行，把输出贴回来**（`AGENTS.md` §2）。
> ⚠️ **2026-09-15 修订**：本节原有的 `flutter test` 三步**已作废** ——
> 按 `AGENTS.md` §1，本项目不写测试、不跑测试，`test/` 下那些文件也早已编译不过。
> 现在的验收 = **静态分析 + 构建 + 启动后手工端到端（§10.2）**。

### 10.1 命令行验收（按顺序）

```bash
cd ~/Projects/flutter/map

# 0) 拉依赖（本轮新增 file_selector）
flutter pub get

# 1) 静态分析：期望 No issues found!（0 error / 0 warning / 0 info）
#    ⚠️ 只分析 lib/（AGENTS.md §1）：不要带 test/ —— 那些老测试是 schema v3 时代的，必然一堆 error
dart analyze lib/

# 2) Linux 构建（确认 file_selector 原生插件链接正常）
flutter build linux --debug

# 3) 启动实跑
flutter run -d linux
```

### 10.2 手工端到端（这一步才是真正的验收）

在跑起来的窗口里：

1. **地图页**随便圈一个区块（点「新增封闭区」→ 连点 4 个角 → 闭合），给它起个名；
2. 从**设置页**往下看，最顶上应该是「我的标记 · 备份」，
   统计卡显示 `区块 1 · 门 0 · 路 0 · 常送点 0 · 坐标点 4`；
3. 点 **[导出]** → 原生「另存为」→ 存到 `~/Documents/`（文件名已预填时间戳）；
4. 终端里确认文件确实存在、且是可读的 JSON：

   ```bash
   ls -la ~/Documents/map_*.mapexport.json
   head -30 ~/Documents/map_*.mapexport.json
   python3 -c "import json,glob;d=json.load(open(sorted(glob.glob('$HOME/Documents/map_*.mapexport.json'))[-1]));print(d['schema_version'],d['counts'])"
   ```

   期望：`2 {'points': 4, 'lines': 4, 'areas': 1, 'gates': 0, 'entities': 0}`

5. **幂等验证**：再点一次 **[导入]**，选同一个文件 →
   预览应显示**「没有新内容可导入」**，跳过 9 项 → 确认后统计卡数字**不变**；
6. **真恢复验证**（关键）：
   ```bash
   # 先备份现有库再删（便于出问题时还原）
   cp ~/.local/share/com.example.map/map.db ~/map.db.bak
   sqlite3 ~/.local/share/com.example.map/map.db "select count(*) from areas;"
   # 关掉 App，然后清库
   rm ~/.local/share/com.example.map/map.db
   ```
   重开 App → 设置页统计卡应显示「还没有任何标记」；
7. 再点 **[导入]** 选同一个文件 → 预览显示「新增区块 1 / 新增路网边 4」→ 确认 →
   统计卡回到 `区块 1 · 路 0 · 常送点 0 · 坐标点 4`，**地图上区块重新出现**；
8. 数据库侧复核：

   ```bash
   sqlite3 ~/.local/share/com.example.map/map.db \
     "select count(*) from areas; select count(*) from points; select count(*) from lines;"
   # 引用完整性：不该有悬空的 area_id / boundary_line_id
   sqlite3 ~/.local/share/com.example.map/map.db \
     "select count(*) from lines where area_id is not null and area_id not in (select id from areas);"
   ```

   期望：`1` / `4` / `4` / `0`

### 10.3 报错时请回传这些

- `dart analyze lib/` 或 `flutter build linux --debug` 的完整尾部输出（定位是类型错、插件链接错还是运行期错）；
- 若第 5~7 步行为不符：`~/Documents/map_*.mapexport.json` 的内容
  （可以只贴前 60 行）＋ 设置页截图或统计卡文字。
