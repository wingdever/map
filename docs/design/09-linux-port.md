# 九 数据库引擎迁移与 Linux 适配（sqflite → sqflite_common_ffi）

> 状态：**计划待确认（尚未改动任何代码）**。
> 本轮目标：把数据库插件从 `sqflite` 迁移为 `sqflite_common_ffi`，使同一份 DB 层代码在
> **Android 与 Linux 桌面**上都能工作，并为后续「地图软件整体迁移到 Linux」打好地基。
> 协商日期：2026-09（本文件产出时点）。执行分工沿用项目铁律：**AI 写代码 + 只读离线校验，
> flutter 命令一律由 wing 在本机执行并回传输出**。

---

## 1. 目标与非目标

### 1.1 本轮目标（已协商确认）

| # | 目标 | 判定标准 |
|---|------|----------|
| G1 | 数据库插件从 `sqflite` **迁移为** `sqflite_common_ffi`（全平台统一，非双轨） | `pubspec.yaml` 里 `sqflite` 被移除，`sqflite_common_ffi` 升为正式依赖 |
| G2 | `AppRepository` 不再隐式依赖「已初始化的全局 factory」 | `open()` 走显式 factory 收口点 `lib/data/db_factory.dart` |
| G3 | Linux 上 DB 目录用 `getApplicationSupportDirectory()`，Android 保持不变 | Linux 落在 `$XDG_DATA_HOME/<app-id>/map.db`；Android 仍在 `app_flutter/` |
| G4 | Linux 上首启行为与 Android 完全一致（自动导入内置 corridor 底图） | 复用 `schema_meta` 三阶段标志位，无平台分支 |
| G5 | Linux 上 `flutter run -d linux` 能启动，且 `libre_location` 不再抛 `MissingPluginException` | 定位初始化在非 Android 平台安全跳过 |
| G6 | 严格**零行为变更**：schema / 查询 / UI / 交互一律不动 | `flutter analyze` 0 issues；`flutter test` 一项不差 |
| G7 | 清掉本轮暴露的死代码与死依赖（同 D12 / D13） | 4 个零引用 service 文件删除；6 个零引用直接依赖从 `pubspec.yaml` 移除 |

### 1.2 非目标（本轮明确不做）

- ❌ 不改 SQLite schema、不改任何 SQL 语句、不改索引；
- ❌ 不动 UI / 交互 / 渲染逻辑；
- ❌ 不抽 `AppRepository` 接口层、不引入 drift 等其他引擎；
- ❌ 不处理 `README` 里提到的「Windows / macOS 分发」；
- ❌ 不引入 `sqlite3_flutter_libs`（经核实不需要，见 §3.2）；
- ❌ 不做超出「本轮暴露的死代码」范围的重构（不动 `kBatchSize` / 999 切段、不清理 `docs/` 历史文档、不重排目录结构）。

> 注：4 个零引用 service 文件与 6 个零引用依赖**已拍板纳入本轮**（见 G7 / §2 D12-D13 /
> §4.5 / §4.6），不再属于「非目标」。

---

## 2. 已确认决策（本次协商结论）

| 编号 | 议题 | 结论 |
|------|------|------|
| D1 | 迁移范围 | **全平台统一** `sqflite_common_ffi`，`pubspec` 移除 `sqflite` |
| D2 | factory 接入方式 | 新增 `lib/data/db_factory.dart` 收口；`AppRepository.open()` 内部取用，**调用点与 6 个测试文件都不改** |
| D3 | factory 种类 | `databaseFactoryFfi`（isolate 版，全平台可用；DB IO 不阻塞 UI isolate） |
| D4 | Linux DB 目录 | `getApplicationSupportDirectory()` |
| D5 | Android DB 目录 | **保持 `getApplicationDocumentsDirectory()` 不变**，绝不迁移老用户数据 |
| D6 | sqlite3 原生库 | 用 native assets 自动打包版；**不依赖系统 libsqlite3.so、不加 `sqlite3_flutter_libs`** |
| D7 | Linux 首启导入 | 与 Android 完全一致，复用 `schema_meta` 三阶段标志位 |
| D8 | Linux 定位 | 加 `PlatformUtils` 守卫，非 Android 平台跳过（不接桌面定位） |
| D9 | 侵入边界 | 严格零行为变更 |
| D10 | 交付物 | 本文件（09 章）+ 验证通过后同步 `docs/AI-HANDOFF.md`、`docs/dev-status.md`、`docs/design/README.md` |
| D11 | 验收标准 | `flutter run -d linux` 能启动 + 地图页出矢量底图 + 圈地/建门后**重启仍在** |
| D12 | 死代码清理 | **执行**：删除 `lib/services/` 下 4 个零引用文件（`location_service.dart` / `location_service2.dart` / `compass_service.dart` / `velocity_service.dart`） |
| D13 | 死依赖清理 | **执行**：从 `pubspec.yaml` 移除 `location` / `geolocator` / `gnss_rtk` / `flutter_compass` / `sensors_plus` / `vector_map` 六个零引用直接依赖 |

---

## 3. 支撑事实（只读勘察证据）

### 3.1 sqflite 在 Linux 上没有实现 —— 这就是当前 Linux 跑不起来的根因

`.flutter-plugins-dependencies` 的依赖图：

```json
{"name":"sqflite","dependencies":["sqflite_android","sqflite_darwin"]}
```

linux 段插件清单只有 `geolocator_linux / jni / location / package_info_plus / path_provider_linux`，
**没有任何 sqflite 实现**。因此 `lib/data/app_repository.dart:54` 的顶层 `openDatabase()` 在
Linux 上会因为全局 `databaseFactory` 未初始化而直接抛异常——这是 `main.dart` 启动路径上的
第一个硬崩点。

### 3.2 `sqlite3` v3 用 native assets 自动打包原生库（**推翻"要用系统库"的假设**）

`sqlite3` 3.5.2（`sqflite_common_ffi` 的传递依赖）已经改成 Dart **native assets / code hooks**：

- `lib/src/ffi/libsqlite3.g.dart` 头部：`@ffi.DefaultAsset('package:sqlite3/src/ffi/libsqlite3.g.dart')`
  —— 符号由 VM 从 code asset 解析，**不再有 `DynamicLibrary.open` 回退**；
- `hook/build.dart` 下载预编译库并以 `DynamicLoadingBundled()` 注册为 code asset；
  默认下载源 `github.com/simolus3/sqlite3.dart` releases，tag `sqlite3-3.5.2`。

本项目里这条链路**已经在跑**，证据：

```
.dart_tool/flutter_build/384f62f16a012ae6a44be6005ed6aed7/build_hooks_result.json
  {"linux_x64":{"encodedAssets":[{"file":".../shared/sqlite3/build/download-b1772918/libsqlite3.so",
    "id":"package:sqlite3/src/ffi/libsqlite3.g.dart","link_mode":{"type":"dynamic_loading_bundle"}}]}}

.dart_tool/flutter_build/28377b112027f2ab65b87f97f05844bd/build_hooks_result.json   → android_arm64
.dart_tool/flutter_build/c6d8684f51eeb2829481711c6ce7825f/build_hooks_result.json   → android_arm

build/app/outputs/flutter-apk/app-debug.apk  (Sep 10 18:44，即**当前** pubspec 状态下构建)
  lib/arm64-v8a/libsqlite3.so   1732360 bytes
build/linux/x64/debug/bundle/lib/libsqlite3.so
.dart_tool/hooks_runner/shared/sqlite3/build/download-{a42fa9d0,0c2d3bfc,949965f0,b1772918}/libsqlite3.so
```

> ⚠️ **修正之前的一个决策假设**：原计划选「Linux 先用系统 `libsqlite3.so`」。
> 实际不需要——原生库已经由 native assets 自动打进 APK 与 Linux bundle，
> 既不依赖系统库，也不需要 `sqlite3_flutter_libs`。
> `build/**/libsqlite3.so` 是**构建产物**，每次 `flutter build` 重新生成，**不要手动删改或拷入**。

把 `sqflite_common_ffi` 从 dev 依赖提升为正式依赖，只会让这条链路更稳（当前它能生效是因为
Flutter 的 build hooks 也会遍历 root package 的 dev_dependencies）。

### 3.3 API 面完全同构 —— 迁移量基本就是改一行 import

`sqflite_common_ffi/sqflite_ffi.dart` 的首行就是：

```dart
export 'package:sqflite_common/sqflite.dart';
```

`sqflite_common/sqflite.dart` 提供了 `AppRepository` 用到的全部符号：
`openDatabase` / `databaseFactory` / `Database` / `Transaction` / `ConflictAlgorithm` /
`OpenDatabaseOptions` / `inMemoryDatabasePath`（`sqflite_common-2.5.11/lib/src/constant.dart:167`）。
`sqflite` 本身也只是 `sqflite_common` 的一层平台转发，所以**类型层面零成本**。

### 3.4 `sqfliteFfiInit()` 在 Linux/Android 上是 no-op

`sqflite_common_ffi-2.4.2+1/lib/src/sqflite_ffi_io.dart:29`：

```dart
void sqfliteFfiInit() {
  if (Platform.isWindows) { windowsInit(); }
}
```

只需保证 `databaseFactory = databaseFactoryFfi`（或显式拿 `databaseFactoryFfi` 传给
`DatabaseFactory.openDatabase`）。另外 `databaseFactoryFfiNoIsolate` 的官方注释是
"Currently supports Win/Mac/Linux" —— 桌面专用，Android 不可用，所以选 isolate 版（D3）。

### 3.5 Linux DB 落点已可精确预测

`path_provider_linux-2.2.2/lib/src/path_provider_linux.dart:47`：

```dart
final directory = Directory(path.join(xdg.dataHome.path, await _getId()));
...
// This plugin originally used the executable name as a directory.
// Use that if it exists for backwards compatibility.
final legacyDirectory = Directory(path.join(xdg.dataHome.path, await _getExecutableName()));
```

`_getId()` = `getApplicationId()`（GTK `g_application_get_default()` 的 application-id），
取不到才回退到可执行文件名。`linux/runner/my_application.cc:146` 用的是
`APPLICATION_ID = "com.example.map"`，所以：

- **预期**：`~/.local/share/com.example.map/map.db`
- **兜底**（GTK app-id 未取到时）：`~/.local/share/map/map.db`

目录不存在时 `path_provider` 会自动 `create(recursive: true)`，无需手建。

> 顺带收益：Linux 上 `getApplicationDocumentsDirectory()` 返回的是
> `xdg.getUserDirectory('DOCUMENTS')?.path`，**可能是 null**（无 XDG user-dirs 配置时），
> 现状 `main.dart:13-14` 的 `dir.path` 会因此空指针崩溃。换 `applicationSupport` 同时消掉这个隐患。

### 3.6 Android DB 路径确认（迁移前后必须一致）

`path_provider_android-2.3.1/lib/src/path_provider_android_real.dart:36`：

```dart
Future<String?> getApplicationDocumentsPath() async {
  final JString directory = 'flutter'.toJString();
  final File? file = _applicationContext.getDir(directory, Context.MODE_PRIVATE);
  ...
}
```

→ Android 实际路径 = `/data/data/com.example.map/app_flutter/map.db`。
D5 保持不动的语义就是：**老用户升级后原地读回自己的库，零迁移、零丢数据**。

> 📌 附带纠正：`.workbuddy/memory/2026-09-10.md` 里那份 adb 清库命令写的是
> `databases/map.db`，与实际 `app_flutter/map.db` 不符，后续同步文档时一并改正。

### 3.7 Linux 上唯一的运行时插件风险点是 `libre_location`

| 插件 | 平台声明 | lib/ 里的引用位置 | Linux 启动时会被调用？ | 本轮处置 |
|------|----------|-------------------|------------------------|----------|
| `libre_location` | 仅 `android` / `ios`（**无 `linux/` 目录**，走 `MethodChannel('libre_location')`） | `services/location_service1.dart`（**活代码**）、`map_page.dart:8`（仅取 `Position` 类型） | ✅ **会** —— `map_page.dart:66-67` 的 postFrame 里 `_locationService?.init()` | **保留** + 加平台守卫（§4.4） |
| `location` | 有 linux（`liblocation_plugin.so` 已编译） | 仅 `services/location_service.dart`（零引用） | ❌ 不会 | **删除**（§4.5 + §4.6） |
| `gnss_rtk` | 无 linux | 仅 `services/location_service2.dart`（零引用） | ❌ 不会 | **删除**（同上） |
| `flutter_compass` | 无 linux | 仅 `services/compass_service.dart`（零引用） | ❌ 不会 | **删除**（同上） |
| `sensors_plus` | 有 web / 无 linux native | **lib/ 里零引用** | ❌ 不会 | **删除**（同上） |
| `geolocator` | 有 `geolocator_linux` | **lib/ 里零引用** | ❌ 不会 | **删除**（同上） |
| `vector_map` | — | **lib/ 里零引用** | ❌ 不会 | **删除**（同上） |

结论：**只要守住 `libre_location` 这一个点，Linux 启动路径就干净了。**
（`map_page.dart` 里 `Position` 只是类型引用，不触发平台通道。）

> 上表的「零引用」已做过**全项目**审计（`lib/` `test/` `tool/` `scripts/`，见 §4.6 证据），
> 不是只看了 `lib/`。另外顺带确认：`package_info_plus` 全项目只被 `geolocator_linux`
> 依赖，移除 `geolocator` 会连带摘掉它，而 `lib/` 里也零引用它——**安全**。

---

## 4. 改动清单（施工单）

> 共 **9 个文件**：1 新增 + 4 修改 + 4 删除。以下为计划内容，**尚未执行**。

### 4.1 【新增】`lib/data/db_factory.dart`

单一收口点：引擎 factory + DB 目录/路径解析。

```dart
/// 数据库引擎与落点收口（Android + Linux 桌面共用）。
///
/// 为什么是 sqflite_common_ffi 而非 sqflite：
/// - 原生 sqflite 只对 Android/iOS/macOS 提供实现，Linux 桌面端没有平台实现，
///   `openDatabase()` 会因全局 databaseFactory 未初始化直接抛异常；
/// - sqflite_common_ffi 基于 sqlite3 包，后者的原生库由 Dart native assets
///   （sqlite3/hook/build.dart）自动打包进 APK / Linux bundle，
///   因此既不需要 sqlite3_flutter_libs，也不依赖系统 libsqlite3.so。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../utils/platform_utils.dart';

/// 数据库文件名（两平台一致）。
const String kDbFileName = 'map.db';

/// 进程级一次性初始化。必须在任何 DB 访问之前调用（main 的第一行之后）。
///
/// `sqfliteFfiInit()` 只在 Windows 上有实际动作，Linux/macOS/Android/iOS 上是
/// no-op，但调用它幂等且无害。同时把全局 `databaseFactory` 指向 FFI 实现——
/// `sqflite_common` 的顶层 `openDatabase()` 依赖这个全局。
void initDatabaseFactory() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

/// 当前平台应使用的 factory。
///
/// 现在全平台统一返回 [databaseFactoryFfi]（isolate 版：SQLite 跑在独立 isolate，
/// DB IO 不阻塞 UI isolate，语义最接近原生 sqflite 的后台线程）。
/// 保留这个函数是为了给「将来按平台分档」留一个唯一收口点。
DatabaseFactory resolveDatabaseFactory() => databaseFactoryFfi;

/// 数据库所在目录。
///
/// - Android：`getApplicationDocumentsDirectory()`（= `data/data/<pkg>/app_flutter`），
///   **与迁移前完全一致**，保证老用户升级后原地读回自己的库；
/// - 其他平台（Linux 桌面等）：`getApplicationSupportDirectory()`
///   （Linux 上是 `$XDG_DATA_HOME/<app-id>`，通常是
///   `~/.local/share/com.example.map`），目录不存在时由 path_provider 创建。
Future<Directory> resolveDatabaseDirectory() => PlatformUtils.isAndroid()
    ? getApplicationDocumentsDirectory()
    : getApplicationSupportDirectory();

/// 数据库绝对路径。
Future<String> resolveDatabasePath() async =>
    p.join((await resolveDatabaseDirectory()).path, kDbFileName);
```

### 4.2 【修改】`lib/data/app_repository.dart`

| 位置 | 现状 | 改为 |
|------|------|------|
| 行 3 docstring | `sqflite 封装：...` | `sqflite_common_ffi 封装：...`（措辞同步） |
| 行 10 | `import 'package:sqflite/sqflite.dart';` | `import 'package:sqflite_common_ffi/sqflite_ffi.dart';`<br>+ `import 'db_factory.dart';` |
| 行 53-61 `open()` | `final db = await openDatabase(path, version: ..., onCreate: ..., onUpgrade: ...);`（隐式依赖全局 factory） | 显式 factory：<br>`final db = await resolveDatabaseFactory().openDatabase(`<br>`  path,`<br>`  options: OpenDatabaseOptions(`<br>`    version: schemaVersion,`<br>`    onCreate: _onCreate,`<br>`    onUpgrade: _onUpgrade,`<br>`  ),`<br>`);` |

**不动**的部分（零行为变更的关键）：

- `openInMemory(DatabaseFactory factory)`（行 64-74）—— 测试注入路径，签名与实现都不动；
- `_onCreate` / `_onUpgrade` / 全部 DAO 方法 / `kBatchSize` / `_chunk(…, 999)` / `queryImportLayer` —— 一律不改；
- `Database` / `Transaction` / `ConflictAlgorithm` / `inMemoryDatabasePath` 等类型的来源随 import 自动切换。

> 说明：改成「显式 factory」而不是依赖全局 `databaseFactory`，是为了让
> `AppRepository.open()` 在**没有调用 `initDatabaseFactory()` 的场景下也能工作**（更健壮，
> 少一个隐式启动顺序约束）。语义与原来完全等价。

### 4.3 【修改】`lib/main.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/app_repository.dart';
import 'data/db_factory.dart';          // 新增
import 'data/providers.dart';
import 'features/home/home_page.dart';
import 'features/map/import_defaults.dart';
// 删除：package:path_provider/path_provider.dart
// 删除：package:path/path.dart as p

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initDatabaseFactory();                     // 新增：sqfliteFfiInit + 全局 factory
  final dbPath = await resolveDatabasePath(); // 替换原 3 行（dir + p.join）
  final repo = await AppRepository.open(dbPath);
  final container = ProviderContainer(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  runApp(UncontrolledProviderScope(container: container, child: const MapApp()));
  // ↓ 以下 addPostFrameCallback + ensureDefaultImportLayer 一字不改
}
```

其余部分（`MapApp`、`addPostFrameCallback` 里带 `container` 的
`ensureDefaultImportLayer`）**完全不动**。

### 4.4 【修改】`lib/services/location_service1.dart` —— Linux 定位守卫

`libre_location` 只声明了 android/ios 平台，Linux 上调 `LibreLocation.requestPermission()`
会抛 `MissingPluginException`。而 `map_page.dart:66-67` 在 postFrame 里调 `init()`，
且 `map_page.dart:86` 在 `dispose()` 里调 `dispose()` → 后者会调 `LibreLocation.stop()`，
**同样会抛**。所以守卫要放在 **service 内部**（一处覆盖 init 和 dispose 两条路径），
`map_page.dart` 不需要改：

```dart
import '../utils/platform_utils.dart';   // 新增

class LocationService extends Notifier<Position?> {
  StreamSubscription<Position>? _subscription;
  String? errorMessage;
  bool _started = false;                 // 新增

  @override
  Position? build() => null;

  Future<void> init() async {
    // libre_location 只声明了 android/ios 平台（pubspec 无 linux 段、仓库无 linux/ 目录），
    // 桌面端走 MethodChannel('libre_location') 必抛 MissingPluginException。
    // 这里直接跳过，state 保持 null（地图不显示用户定位点），不阻塞其他逻辑。
    if (!PlatformUtils.isLocationSupported()) return;   // 新增
    _started = true;                                     // 新增（放在守卫之后、原逻辑之前）
    print("LocationService: 初始化定位服务");
    ...  // 原逻辑一字不改
  }

  void dispose() {
    if (!_started) return;                               // 新增
    ...  // 原逻辑一字不改
  }
}
```

`_started = true` 放在守卫之后、原逻辑之前，保证 **Android 行为逐字节不变**
（dispose 仍然无条件走 `LibreLocation.stop()`），Linux 上则两条路径都安全早退。

> 注：`lib/utils/platform_utils.dart` 的 `isLocationSupported()` 定义不改（仍为 `isAndroid()`），
> 本轮不接桌面定位（D8）。`isLinux()` 已有，暂不使用。

### 4.5 【修改】`pubspec.yaml` —— 引擎迁移 + 死依赖清理

```diff
 dependencies:
   flutter:
     sdk: flutter

   cupertino_icons: ^1.0.8
   flutter_map: ^8.3.2
   latlong2: ^0.10.1
-  sqflite: ^2.4.3
+  # 数据库引擎：全平台统一用 sqflite_common_ffi。
+  # 原生 sqflite 只对 Android/iOS/macOS 提供平台实现，Linux 桌面端没有；
+  # sqflite_common_ffi 基于 sqlite3 包，其原生库由 Dart native assets
+  # （sqlite3/hook/build.dart）自动打包进 APK / Linux bundle——
+  # 无需 sqlite3_flutter_libs，也不依赖系统 libsqlite3.so。
+  # 详见 docs/design/09-linux-port.md
+  sqflite_common_ffi: ^2.4.2+1
   path_provider: ^2.1.6
-  geolocator: ^14.0.3
   flutter_riverpod: ^3.4.3
   path: ^1.9.1
-  location: ^10.0.2
   libre_location: ^0.4.3
-  sensors_plus: ^7.1.0
-  vector_map: ^0.7.0
-  # 指南针
-  flutter_compass: ^0.8.1
-  # GPS
-  gnss_rtk: ^1.0.0

 dev_dependencies:
   flutter_test:
     sdk: flutter

   flutter_lints: ^6.0.0
-  sqflite_common_ffi: ^2.4.2+1
```

**移除的 6 个依赖及理由**（全部经全项目审计确认零引用，见 §4.6）：

| 依赖 | 原用途 | 移除理由 |
|------|--------|----------|
| `location: ^10.0.2` | 定位（备用实现） | 仅被 `lib/services/location_service.dart` 引用，该文件零引用 |
| `geolocator: ^14.0.3` | 定位 | `lib/` `test/` 全项目零引用（连 import 都没有） |
| `gnss_rtk: ^1.0.0` | RTK 高精度 GPS | 仅被 `lib/services/location_service2.dart` 引用，该文件零引用 |
| `flutter_compass: ^0.8.1` | 指南针 | 仅被 `lib/services/compass_service.dart` 引用，该文件零引用 |
| `sensors_plus: ^7.1.0` | 传感器 | `lib/` `test/` 全项目零引用 |
| `vector_map: ^0.7.0` | 矢量地图（替代方案） | `lib/` `test/` 全项目零引用 |

**连带效果（已确认无害）**：

- `package_info_plus`（transitive）全项目只被 `geolocator_linux` 依赖 → 会随 `geolocator` 一起消失；
  `lib/` 中零引用，安全；
- Linux bundle 里的 `liblocation_plugin.so` 会消失 → Linux 构建面更干净；
- `sqlite3`（transitive）保持不动：`sqflite_common_ffi` 升为正式依赖后它仍由前者传递引入，
  native assets 打包链路不受影响；
- `libre_location` **保留**（Android 上的活定位来源，且 `map_page.dart:8` 需要它的 `Position` 类型）；
- `path_provider` / `path` / `flutter_map` / `latlong2` / `flutter_riverpod` / `cupertino_icons` 全部保留。

`flutter_test` / `flutter_lints` 保持不动。`sqflite_common_ffi` 升为正式依赖后，
6 个测试文件里的 `sqfliteFfiInit()` + `databaseFactoryFfi` 引用**无需任何改动**。

### 4.6 【删除】4 个零引用 service 文件

审计证据（对 `lib/` `test/` `tool/` `scripts/` 做全项目引用扫描，排除 `.tools` / `build` /
`.dart_tool`，并对 `lib/` 做逐文件「文件名是否被 import」扫描）：

```
lib/ 全量未引用文件扫描（除 main.dart 外逐文件核对基名是否被 import）
  未引用: lib/services/compass_service.dart  (73 行)
  未引用: lib/services/location_service2.dart  (84 行)
  未引用: lib/services/location_service.dart  (117 行)
  未引用: lib/services/velocity_service.dart  (8 行)
```

扫描结果**只有这 4 个**，无额外牵连。逐个说明：

| 待删文件 | 行数 | 内容 | 为什么可以删 |
|----------|------|------|--------------|
| `lib/services/location_service.dart` | 117 | 基于 `package:location` 的定位实现，内含 `PlatformUtils.isLocationSupported()` 守卫 | 零引用；已被 `location_service1.dart`（libre_location 版）取代 |
| `lib/services/location_service2.dart` | 84 | 基于 `package:gnss_rtk` 的 RTK 定位实现 | 零引用 |
| `lib/services/compass_service.dart` | 73 | 基于 `package:flutter_compass` 的指南针实现 | 零引用 |
| `lib/services/velocity_service.dart` | 8 | **只有注释、零行代码**的占位文件 | 零引用；文件本身不含任何可执行代码 |

删除后 `lib/services/` 只剩 `location_service1.dart`（活代码，本轮加平台守卫）。

> ⚠️ 执行顺序约束：**先删文件，再 `flutter pub get`**。反之若先摘依赖，
> 这 4 个文件会因为 import 找不到包而让 `flutter analyze` 报错。

### 4.7 本轮不动的文件（明确列出以防误伤）

| 文件 | 为什么不动 |
|------|-----------|
| `lib/core/schema.dart` | DDL 与 `schemaVersion=2` 不变；迁移不涉及 schema |
| `lib/features/map/import_defaults.dart` | D7：Linux 复用同一套 `schema_meta` 三阶段标志位 |
| `lib/features/map/import_layer_providers.dart` | 只有 docstring 提到 sqflite，无 import；不改 |
| `lib/features/map/map_page.dart` | 定位守卫放在 service 内，此处零改动 |
| `lib/services/location_service1.dart` | **例外**：本轮要改（加平台守卫，见 §4.4），列在此处仅为对照 |
| `test/**`（15 个文件、111 项） | 已全部走 `databaseFactoryFfi`，零改动 |
| `linux/**`、`android/**` | 无平台配置需要改 |
| `docs/AI-HANDOFF.md`、`docs/dev-status.md`、`docs/design/README.md` | 验证全绿后再同步（§7 第 9 步），本轮施工阶段不动 |

---

## 5. 验证步骤（请在 wing 本机执行，把输出回传）

### 5.0 前置

```bash
cd ~/Projects/flutter/map
```

### 5.1 依赖解析 + 静态分析 + 单测

```bash
flutter pub get
flutter analyze          # 期望：No issues found!
flutter test             # 期望：All tests passed!（基线 111 项，必须一项不差）
```

> 基线：迁移前 `test/` 共 15 个文件、**111** 处 `test()/testWidgets()`。
> 本轮不改测试，所以数字必须与迁移前完全一致——这是「零行为变更」最硬的证据。
> （删掉 4 个死代码文件**不应**改变测试数——它们本来就没有测试覆盖。）

顺手确认死代码/死依赖真的摘干净了（可选但推荐）：

```bash
ls lib/services/                     # 期望只剩 location_service1.dart
grep -c "sqflite\|geolocator\|vector_map\|sensors_plus\|flutter_compass\|gnss_rtk" pubspec.yaml
                                     # 期望只剩下 sqflite_common_ffi 那一处（= 1）
for p in sqflite geolocator vector_map sensors_plus flutter_compass gnss_rtk location package_info_plus; do
  grep -q "^  $p:$" pubspec.lock && echo "❌ 仍在 lock: $p" || echo "✅ 已移除: $p"
done
```

### 5.2 Android 回归（关键：确认 FFI 引擎在 Android 上也能建库/导入）

```bash
flutter build apk --debug        # 期望：构建成功
# 可选：确认 APK 里带了 sqlite3 原生库（预期看到 lib/arm64-v8a/libsqlite3.so）
unzip -l build/app/outputs/flutter-apk/app-debug.apk | grep sqlite
```

装到手机上跑一次，确认：
1. 能进地图页、能看到矢量底图（说明导入层写入成功）；
2. **既有数据仍在** —— 老库路径 `app_flutter/map.db` 未被重建：

```bash
adb shell run-as com.example.map ls -la app_flutter/
adb exec-out run-as com.example.map cat app_flutter/map.db > /tmp/android_map.db
sqlite3 /tmp/android_map.db "select key,value from schema_meta;"
sqlite3 /tmp/android_map.db "select count(*) from areas; select count(*) from gates;"
```

期望：`default_osm_loaded=1`，`areas`/`gates` 计数与迁移前一致（**不归零**）。

### 5.3 Linux 运行（本轮主验收）

```bash
flutter run -d linux
```

期望（对应 D11）：

1. 应用正常启动，**控制台不出现 `MissingPluginException`**（也不出现 databaseFactory 相关异常）；
2. 地图页出现 OSM 瓦片 + **矢量底图**（道路蓝线 / 建筑灰面 / POI），
   说明 `applicationSupport` 下的新库建表 + `ensureDefaultImportLayer` 全链路成功
   （25MB / 19.2 万节点，桌面预期秒级）；
3. 圈一个区块、建一扇门 → 关掉 app → 重新 `flutter run -d linux` → **区块与门还在**。

### 5.4 确认 DB 实际落点

```bash
# 预期 ~/.local/share/com.example.map/
ls -la ~/.local/share/com.example.map/
ls -la ~/.local/share/map/ 2>/dev/null   # 仅当 GTK app-id 未取到时的兜底位置

DB=~/.local/share/com.example.map/map.db
sqlite3 "$DB" ".tables"        # 期望 10 张：areas/entities/gates/lines/points
                               #            + import_bounds/nodes/ways/pois + schema_meta
sqlite3 "$DB" "select key,value from schema_meta;"
sqlite3 "$DB" "select count(*) from import_nodes; select count(*) from import_ways; select count(*) from import_pois;"
```

期望导入层计数 ≈ `192559 / 18362 / 672`（以 corridor.osmapp 实际内容为准，
与 Android 侧同一份数据）。

### 5.5 需要重置 Linux 侧状态时

```bash
rm -rf ~/.local/share/com.example.map   # 清库 + schema_meta 标志位，下次启动重走首启全链路
```

---

## 6. 风险与回滚

| 编号 | 风险 | 影响 | 缓解 |
|------|------|------|------|
| R1 | 构建期需从 GitHub releases 下载 sqlite3 预编译库（tag `sqlite3-3.5.2`） | 换机器 / 清 `.dart_tool` / 清缓存后首次构建需要网络 | 本项目缓存已存在（arm / arm64 / x64 三份，见 §3.2）；真的不通时可用 `user_defines` 把 `source` 改成 `system` 或 `source`（本地编译），或把 `download-*` 目录保留备份。**仅记录，本轮不主动改** |
| R2 | Android 侧 SQLite 从「系统内置版本」换成「打包 3.5x」 | 理论上有版本行为差异 | schema 只用 `CREATE TABLE` / `CREATE [UNIQUE] INDEX [IF NOT EXISTS]` / 部分索引（SQLite ≥ 3.8.0）/ `LIKE` / `COUNT(*)` / `INSERT OR IGNORE`，无版本敏感特性；未使用 `getDatabasesPath()`；未开 `PRAGMA foreign_keys`（两种实现默认都不强制）。风险低，靠 §5.2 实测兜底 |
| R3 | APK 体积增加 | 每个 ABI 约 +1.7MB（已实测 arm64-v8a = 1732360 B） | 用户已知晓并接受（相对于内置 25MB corridor 底图可忽略） |
| R4 | `databaseFactoryFfi` 走独立 isolate，与原生 sqflite 的后台线程模型不同 | 极端情况下并发/锁行为有差异 | `singleInstance: true` 默认语义一致；19.2 万节点导入性能靠 §5.3 实测确认。若桌面导入慢，再单独评估（**本轮不改 `kBatchSize`/999 切段**） |
| R5 | 误把 Android 也改成 `applicationSupport` | 老用户会看到"空库" | D5 已在代码评审点锁死：`resolveDatabaseDirectory()` 里 Android 分支必须是 `getApplicationDocumentsDirectory()`。§5.2 的计数校验是硬性验收项 |
| R6 | native assets 链路在 Flutter 升级后行为变化 | 构建失败或原生库缺失 | 已记录证据链（§3.2）；若 `flutter` 升级后 `flutter build linux` 报 sqlite3 相关错误，优先把 `sqlite3` 显式钉到当前可用的 `^3.5.2` |
| R7 | 移除 6 个依赖可能连带摘掉某个仍被需要的传递依赖 | `flutter analyze` 报找不到包 | 已提前反查：`package_info_plus` 只被 `geolocator_linux` 依赖且 `lib/` 零引用（§4.5）。§5.1 的 `flutter analyze` 是兜底闸门；执行顺序必须**先删文件后摘依赖**（§4.6），否则 4 个待删文件会先报 import 错误，掩盖真实问题 |
| R8 | 未来若要接桌面定位，得把 `location` 依赖加回来 | 返工成本低 | LQ-01 已记录；本轮按 D8 只做守卫，不接桌面定位 |

**回滚方案（三步，完全可逆）**：

1. `pubspec.yaml`：`sqflite_common_ffi` 从 dependencies 移回 dev_dependencies，加回 `sqflite: ^2.4.3`；
2. `lib/data/app_repository.dart`：import 改回 `package:sqflite/sqflite.dart`，`open()` 改回顶层 `openDatabase()`；
3. `lib/main.dart`：改回 `getApplicationDocumentsDirectory()` + `p.join`。

`lib/data/db_factory.dart` 与定位守卫可留着（不生效）。
**数据库文件格式完全兼容**（同一个 SQLite 文件，schema 未变），Android 可双向回滚；
Linux 侧一旦跑过 FFI 引擎建的库，回滚到 sqflite 后 Linux 依然跑不起来（回到本轮原点），
但该库文件本身无损坏。

> 关于 D12/D13 的死代码清理：**项目没有 git 仓库**（`git log` → `fatal: not a git repository`），
> 所以这 4 个文件的删除**没有版本控制兜底**。若要保留退路，执行前先备份：
>
> ```bash
> mkdir -p /tmp/map_deadcode_backup
> cp lib/services/{location_service,location_service2,compass_service,velocity_service}.dart \
>    /tmp/map_deadcode_backup/
> ```
>
> 4 个文件共 282 行、全部零引用，实际回滚需求极低；但既然无 git，备份是零成本的保险。

---

## 7. 施工顺序（建议）

1. 【AI】新增 `lib/data/db_factory.dart`；
2. 【AI】改 `lib/data/app_repository.dart`（import + 显式 factory）；
3. 【AI】改 `lib/main.dart`（初始化 + 路径 + 清理 import）；
4. 【AI】改 `lib/services/location_service1.dart`（平台守卫）；
5. 【AI】删除 4 个零引用 service 文件（§4.6）——**必须在改 `pubspec.yaml` 之前**；
6. 【AI】改 `pubspec.yaml`（引擎迁移 + 移除 6 个死依赖）；
7. 【AI】只读离线校验：`dart analyze lib test tool`（用 `.tools/flutter-sdk` 内 dart，不跑 flutter）；
8. 【wing】执行 §5.1 → §5.2 → §5.3，回传输出；
9. 【AI】按失败项修复，必要时补一轮离线校验；
10. 【AI】验证全绿后同步 `docs/design/README.md` 索引、`docs/AI-HANDOFF.md`、`docs/dev-status.md`
    （含 §3.6 提到的 adb 路径纠正，以及本轮「引擎迁移 + 死代码清理」记录）。

---

## 8. 开放问题（本轮不阻塞，留待后续）

| 编号 | 问题 | 备注 |
|------|------|------|
| LQ-01 | Linux 上要不要接桌面定位？ | 原本 `location` 包在 Linux 侧确实编译出了 `liblocation_plugin.so`；但 D13 已把它移除，将来要接需重新加回依赖，或另找 Linux 定位方案。要改 `PlatformUtils.isLocationSupported()` 并替换/并存 `libre_location` |
| LQ-02 | `sqlite3` 是否显式钉版本（如 `sqlite3: ^3.5.2`）？ | 能锁定 native assets 下载缓存，避免 `pub upgrade` 触发重新下载 |
| LQ-03 | Linux 桌面是否需要放宽 `kBatchSize=2000` / IN 子句 999 切段？ | 打包版 SQLite 的 `SQLITE_MAX_VARIABLE_NUMBER` 上限远高于 999，桌面内存也宽裕；但本轮守 D9「零行为变更」，先不动 |
| LQ-04 | macOS / Windows 是否也要支持？ | 现有实现天然可用（`databaseFactoryFfi` 全平台），只差各自 runner 与平台目录策略 |
| LQ-05 | 项目没有 git 仓库，本轮删除文件无版本控制兜底 | 见 §6 回滚小节的备份建议；是否要初始化 git 由 wing 决定 |

> **已闭环**（本轮拍板执行，不再列为开放问题）：
> `LQ-02 4 个死代码 service 是否清理` → 见 D12 / §4.6；
> `LQ-03 6 个零引用依赖是否移除` → 见 D13 / §4.5。
