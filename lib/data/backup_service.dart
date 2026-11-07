/// 用户层标记的备份文件读写（docs/design/11-backup-export-import.md §6）。
///
/// 职责边界：
/// - **本文件**：文件系统 + 原生文件对话框（`file_selector`）+ 文件名约定；
/// - `core/export.dart` / `core/import.dart`：领域模型 ⇄ JSON；
/// - `core/merge.dart`：合并计划与执行；
/// - `data/app_repository.dart`：事务落库。
///
/// 文件选择被抽成 [BackupFilePicker] 接口，不是为了"将来换实现"这种空话，
/// 而是为了**可测**：widget 测试里塞一个假 picker（返回临时目录路径），
/// 就能把「点导出 → 落盘 → 点导入 → 合并」整条链路跑完，不弹任何原生窗口。
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/merge.dart';
import 'app_repository.dart';
import 'providers.dart';

/// 备份文件扩展名与类型过滤器。
const String kBackupExtension = 'json';
const String kBackupSuffix = '.mapexport.json';

/// 保存对话框里建议的文件名：`map_20260913-044712.mapexport.json`。
///
/// 刻意用纯 ASCII 文件名（时间戳排序天然有序），避免中文文件名在
/// Windows / 网盘 / adb 之间来回倒腾时踩编码坑。
String suggestedBackupFileName([DateTime? now]) {
  final t = (now ?? DateTime.now());
  String two(int n) => n.toString().padLeft(2, '0');
  return 'map_'
      '${t.year}${two(t.month)}${two(t.day)}'
      '-${two(t.hour)}${two(t.minute)}${two(t.second)}'
      '$kBackupSuffix';
}

/// 文件选择接缝（原生对话框）。
abstract class BackupFilePicker {
  /// 弹出「另存为」。用户取消返回 null。
  Future<String?> pickSavePath({required String suggestedName});

  /// 弹出「打开文件」。用户取消返回 null。
  Future<String?> pickOpenPath();
}

/// 基于 `file_selector` 的实现（Linux 走 GTK 原生 FileChooser）。
///
/// ⚠️ `getSaveLocation` 在 Android 上没有实现（会抛 `UnimplementedError`）；
/// Android 端要支持导出时，需换成 MediaStore / SAF 方案（本轮不做，
/// 见 11 章 §8 风险 R-11-2）。
class FileSelectorBackupPicker implements BackupFilePicker {
  const FileSelectorBackupPicker();

  static const XTypeGroup _group = XTypeGroup(
    label: '最后一公里地图备份',
    extensions: <String>[kBackupExtension],
  );

  @override
  Future<String?> pickSavePath({required String suggestedName}) async {
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: const <XTypeGroup>[_group],
    );
    if (location == null) return null;
    return _ensureJsonExtension(location.path);
  }

  @override
  Future<String?> pickOpenPath() async {
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[_group],
      confirmButtonText: '导入',
    );
    return file?.path;
  }
}

/// GTK 的保存对话框不会因为我们给了 filter 就自动补扩展名，
/// 用户敲 `mybackup` 会得到无扩展名的文件。这里补一次。
String _ensureJsonExtension(String path) {
  final sep = Platform.pathSeparator;
  final slash = path.lastIndexOf(sep);
  final base = slash < 0 ? path : path.substring(slash + 1);
  if (base.contains('.')) return path;
  return '$path.$kBackupExtension';
}

/// 备份服务：导出 / 选择导入 / 应用合并。
class BackupService {
  BackupService({required this.repo, required this.picker});

  final AppRepository repo;
  final BackupFilePicker picker;

  /// 弹保存对话框并导出。
  ///
  /// 返回写入的文件绝对路径；用户在对话框里取消时返回 null。
  Future<String?> exportToFile() async {
    final path = await picker.pickSavePath(
      suggestedName: suggestedBackupFileName(),
    );
    if (path == null) return null;
    await exportToPath(path);
    return path;
  }

  /// 导出到指定路径（不弹对话框；测试与"手输路径"用）。
  Future<void> exportToPath(String path) async {
    final json = await repo.exportUserLayerJson();
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(json, flush: true);
  }

  /// 弹打开对话框 + 解析成合并计划。
  ///
  /// 返回 null = 用户取消。解析失败向上抛 [FormatException]（UI 负责提示）。
  Future<PickedBackup?> pickForImport() async {
    final path = await picker.pickOpenPath();
    if (path == null) return null;
    return planFromPath(path);
  }

  /// 从指定路径解析出合并计划（不弹对话框）。
  Future<PickedBackup> planFromPath(String path) async {
    final source = await File(path).readAsString();
    final (plan, report) = await repo.planUserLayerImportDetailed(source);
    return PickedBackup(path: path, plan: plan, warnings: report.warnings);
  }

  /// 落库。
  Future<MergeStats> apply(MergePlan plan) => repo.applyUserLayerMerge(plan);
}

/// 已选中的备份 + 它的合并计划（预览对话框的数据）。
class PickedBackup {
  const PickedBackup({
    required this.path,
    required this.plan,
    this.warnings = const [],
  });

  final String path;
  final MergePlan plan;

  /// 解析这份备份时的说明（老文件被翻译/丢弃了什么）。导入预览要显示它 ——
  /// 静默丢数据是最坏的一种体验。
  final List<String> warnings;

  /// 文件名（不含目录），用于提示文案。
  String get fileName {
    final sep = Platform.pathSeparator;
    final i = path.lastIndexOf(sep);
    return i < 0 ? path : path.substring(i + 1);
  }
}

/// 文件选择器 provider。测试里用 `overrideWithValue` 塞假实现。
final backupPickerProvider = Provider<BackupFilePicker>(
  (ref) => const FileSelectorBackupPicker(),
);

/// 备份服务 provider。
final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(
    repo: ref.watch(repositoryProvider),
    picker: ref.watch(backupPickerProvider),
  ),
);
