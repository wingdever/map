/// 内置底图包的**解包引导**（docs/design/10-basemap-packs.md §4.5）。
///
/// v3 起，底图不再以 `.osmapp` 文本形式在首启解析入库，而是**预构建好的
/// SQLite 包**直接随 APK 分发、首启只需「解包 → 落盘」一次文件拷贝。
///
/// 与 v2 的 `ensureDefaultImportLayer` 对比：
/// - ❌ 三阶段 `schema_meta` 标志位（started/loaded/corrupt）
/// - ❌ 25MB JSON 字符串 + `OsmAppFile` 对象树 + 分批 Batch
/// - ❌ corrupt 自愈
/// - ✅ 只有「文件级幂等」：marker 版本一致 + 文件齐全 → 秒过
///
/// 首启内存：单包最大 14.9MB，内存里只有一个 `ByteData`（v2 时代是 25MB
/// 字符串 + 解析对象同时常驻，正是当年 OOM 的根因）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../data/app_repository.dart';
import 'import_layer_providers.dart';

/// 内置包资源清单。
///
/// **必须与 pubspec.yaml 的 `flutter.assets` 保持一致**，且这四个文件由
/// `python3 tool/basemap_pack/build_packs.py --bundled-only` 产出
/// （corridor 覆盖的 0.1° 网格 4 格）。
const List<String> kBundledPackAssets = [
  'assets/basemap/t22.60_114.10.db',
  'assets/basemap/t22.60_114.20.db',
  'assets/basemap/t22.70_114.10.db',
  'assets/basemap/t22.70_114.20.db',
];

/// 内置包集合的**版本标记**。
///
/// 重新生成内置包（换了 bbox / 网格 / 数据源）后**必须递增**，否则老设备上
/// 已解包的旧文件不会被覆盖。
const String kBundledPackVersion = '1';

/// 解包完成标记文件名（放在包目录里）。
const String kBundledMarkerFile = '.bundled.json';

/// 首启解包内置底图包。
///
/// **不阻塞 App 启动**：调用方通常在 `addPostFrameCallback` 里 fire-and-forget；
/// 内部所有异常均兜底吃掉（资源缺失 / 磁盘满 / 权限异常），失败时 App 照常
/// 运行，只是没有内置底图（用户仍可 adb push 包进来）。
///
/// 幂等策略：
///   1. 读包目录里的 [kBundledMarkerFile]，版本 == [kBundledPackVersion]
///      **且** 4 个目标文件都存在 → 直接返回（零 IO，正常启动路径）；
///   2. 否则逐个解包：`rootBundle.load` → 写 `.tmp` → `rename` 原子替换；
///   3. 全部成功后写 marker。
///
/// 用文件级 marker 而不是 `schema_meta` 标志位，是因为包文件才是真相：
/// 用户手动删了某个包、或包目录被系统清理（卸载重装），marker 与文件不一致
/// 就会被发现并自动修复。
Future<void> ensureBundledPacks(
  AppRepository repo, {
  bool force = false,
  MapDataProgressNotifier? progress,
}) async {
  try {
    final dir = repo.packs.directory;
    if (dir == null) return; // 无包目录（单测场景）
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final sep = Platform.pathSeparator;
    final marker = File('${dir.path}$sep$kBundledMarkerFile');

    // ---- 快路径 ----
    if (!force && await _markerOk(marker) && _allPacksPresent(dir, sep)) {
      return;
    }

    final total = kBundledPackAssets.length;
    var done = 0;

    for (final asset in kBundledPackAssets) {
      final key = asset.split('/').last.replaceAll('.db', '');
      final destPath = '${dir.path}$sep$key.db';
      final dest = File(destPath);

      done++;
      progress?.report(
        MapDataPhase.extractingPacks,
        details: '解包内置底图 [$done/$total] $key.db',
      );

      final bytes = await rootBundle.load(asset);
      final tmp = File('$destPath.tmp');
      if (tmp.existsSync()) tmp.deleteSync();
      await tmp.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
      if (dest.existsSync()) dest.deleteSync();
      tmp.renameSync(destPath);

      // 让 UI 有机会重绘进度（14.9MB 的单包写入约几十毫秒）
      await Future<void>.delayed(Duration.zero);
    }

    // ---- 写 marker ----
    await marker.writeAsString(
      jsonEncode({
        'version': kBundledPackVersion,
        'keys': [
          for (final a in kBundledPackAssets)
            a.split('/').last.replaceAll('.db', ''),
        ],
        'at': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );

    await repo.rescanPacks();
    progress?.report(
      MapDataPhase.scanningPacks,
      details: '底图包 ${repo.packs.all.length} 个就绪',
    );
  } catch (e) {
    // 兜底：内置包缺失/损坏不崩溃，App 照常启动（仅无内置底图）。
    // 不写 marker，下次启动会重试。
  }
}

/// marker 版本是否匹配。
Future<bool> _markerOk(File marker) async {
  if (!marker.existsSync()) return false;
  try {
    final obj = jsonDecode(await marker.readAsString());
    return obj is Map && obj['version'] == kBundledPackVersion;
  } catch (_) {
    return false; // 损坏的 marker 视为不匹配
  }
}

/// 4 个目标文件是否都在。
bool _allPacksPresent(Directory dir, String sep) {
  for (final asset in kBundledPackAssets) {
    final key = asset.split('/').last;
    if (!File('${dir.path}$sep$key').existsSync()) return false;
  }
  return true;
}
