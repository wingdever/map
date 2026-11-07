/// 数据库引擎与落点收口（Android + Linux 桌面共用）。
///
/// 为什么是 sqflite_common_ffi 而非 sqflite：
/// - 原生 sqflite 只对 Android/iOS/macOS 提供平台实现，Linux 桌面端没有，
///   顶层 `openDatabase()` 会因全局 databaseFactory 未初始化直接抛异常；
/// - sqflite_common_ffi 基于 sqlite3 包，后者的原生库由 Dart native assets
///   （sqlite3/hook/build.dart）自动打包进 APK / Linux bundle，
///   因此既不需要 sqlite3_flutter_libs，也不依赖系统 libsqlite3.so。
///
/// 设计文档：docs/design/09-linux-port.md
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../utils/platform_utils.dart';

/// 数据库文件名（两平台一致）。
const String kDbFileName = 'map.db';

/// 进程级一次性初始化。必须在任何 DB 访问之前调用。
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

// ---------------------------------------------------------------------------
// 底图包目录（docs/design/10-basemap-packs.md §4.1）
// ---------------------------------------------------------------------------

/// 底图包目录名（与 map.db 同级概念，但独立子目录）。
const String kBasemapDirName = 'basemap';

/// 底图包目录（**绝对路径**）。
///
/// 优先「外部应用专属目录」，理由：
/// - `adb push` 可直接写入（`/data/data/<pkg>/files/` 需要 root 或 run-as，推不进去）；
/// - App 无需任何存储权限即可读写自己的专属外部目录；
/// - 省掉「先推到公共目录、再拷进私有目录」的 1.97GB 双份存储开销。
///
/// 三级回退：
///   1. Android 且 `getExternalStorageDirectory()` 可用 → `<ext>/files/basemap`
///      （= `/sdcard/Android/data/com.example.map/files/basemap`）
///   2. 非 Android，或外部存储不可用/不可写 → `<applicationSupport>/basemap`
///   3. 目录不存在时创建
///
/// 注意：返回的必须是**绝对路径**——sqflite 会把相对路径解析到
/// `.dart_tool/sqflite_common_ffi/databases/` 之下（校验器已踩过该坑）。
Future<Directory> resolveBasemapDir() async {
  if (PlatformUtils.isAndroid()) {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final dir = Directory(p.join(ext.path, kBasemapDirName));
        await dir.create(recursive: true);
        return dir;
      }
    } catch (_) {
      // 外部存储未挂载 / 无写权限 → 走下面的回退
    }
  }
  final support = await getApplicationSupportDirectory();
  final dir = Directory(p.join(support.path, kBasemapDirName));
  await dir.create(recursive: true);
  return dir;
}
