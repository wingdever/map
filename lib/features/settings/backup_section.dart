/// 设置页「我的标记 · 备份」区块（docs/design/11-backup-export-import.md §6）。
///
/// 交互只有两步，刻意做得没有分支：
///   导出 —— 选路径 → 立刻写盘 → 提示完整路径；
///   导入 —— 选文件 → **先出预览对话框**（新增什么、跳过什么）→ 确认才落库。
///
/// 「先预览再落库」不是装饰：导入是合并语义，用户需要在上屏之前看到
/// 「这次到底会多出哪些区块」，否则一旦导入两份来路相似的备份，
/// 事后只能靠肉眼在地图上找重复。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/backup_service.dart';
import '../../core/models.dart';
import '../../data/app_repository.dart';
import '../../data/providers.dart';
import '../map/import_layer_providers.dart';
import '../map/map_layers.dart';

/// 用户层标记的统计（导出前让用户确认"我要备份的是这些"）。
class UserLayerStats {
  const UserLayerStats({
    required this.areas,
    required this.gates,
    required this.lines,
    required this.entities,
    required this.points,
  });

  final int areas;
  final int gates;
  final int lines;
  final int entities;
  final int points;

  bool get isEmpty => areas == 0 && gates == 0 && lines == 0 && entities == 0;

  String get summary =>
      '区块 $areas · 门 $gates · 路 $lines · 常送点 $entities · 坐标点 $points';
}

/// 标记统计 provider。
final userLayerStatsProvider = FutureProvider.autoDispose<UserLayerStats>((
  ref,
) async {
  final repo = ref.watch(repositoryProvider);
  // v12：用户层是三个域，统计也要**逐域**加一遍（同一个 id 在不同域是两回事）。
  var points = 0, lines = 0, areas = 0;
  for (final d in MapDomain.values) {
    points += (await repo.listPoints(d)).length;
    lines += (await repo.listLines(d)).length;
  }
  for (final d in AppRepository.areaDomains) {
    areas += (await repo.listAreas(d)).length;
  }
  return UserLayerStats(
    areas: areas + (await repo.listPolygons(MapDomain.world)).length,
    gates: (await repo.listGates()).length,
    lines: lines,
    entities: (await repo.listEntities()).length,
    points: points + (await repo.listWorldMarks()).length,
  );
});

/// 「我的标记 · 备份」区块。
class BackupSection extends ConsumerStatefulWidget {
  const BackupSection({super.key});

  @override
  ConsumerState<BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends ConsumerState<BackupSection> {
  /// 正在导出/导入时为 true：按钮置灰 + 显示转圈，避免连点两次。
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  // -------------------------------------------------------------------------
  // 导出
  // -------------------------------------------------------------------------

  Future<void> _export() async {
    await _run(() async {
      final service = ref.read(backupServiceProvider);
      try {
        final path = await service.exportToFile();
        if (path == null) return; // 用户取消
        _toast('已导出到 $path');
      } catch (e) {
        _toast('导出失败：$e');
      }
    });
  }

  // -------------------------------------------------------------------------
  // 导入
  // -------------------------------------------------------------------------

  Future<void> _import() async {
    await _run(() async {
      final service = ref.read(backupServiceProvider);
      final PickedBackup? picked;
      try {
        picked = await service.pickForImport();
      } on FormatException catch (e) {
        await _showError('这个文件不是本应用的备份', e.message);
        return;
      } catch (e) {
        await _showError('读取失败', '$e');
        return;
      }
      if (picked == null) return; // 用户取消

      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => _ImportPreviewDialog(picked: picked!),
      );
      if (confirmed != true) return;

      try {
        final stats = await service.apply(picked.plan);
        _invalidateLayers();
        _toast('导入完成：${stats.summary}');
      } catch (e) {
        _toast('导入失败（数据未改动）：$e');
      }
    });
  }

  Future<void> _showError(String title, String? detail) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(detail ?? '（无详细信息）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 导入后地图/统计必须立刻反映新数据。
  void _invalidateLayers() {
    ref.invalidate(userLayerStatsProvider);
    ref.invalidate(mapLayersProvider);
    ref.invalidate(importBoundsProvider);
    ref.invalidate(importLayerProvider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = ref.watch(userLayerStatsProvider).value;
    final hasData = stats != null && !stats.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('我的标记 · 备份', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          '你手动画的区块 / 门 / 路网 / 常送点是这个 App 里唯一无法重新生成的东西。'
          '导出一份 .mapexport.json 存到网盘，换机或重装后导入即可。'
          '底图包不在备份里（那是只读的，重新 push 就行）。',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),

        // ---- 现有数据统计 ----
        Card(
          child: ListTile(
            leading: const Icon(Icons.push_pin_outlined),
            title: Text(
              stats == null ? '正在统计…' : stats.summary,
            ),
            subtitle: Text(
              hasData ? '导出会包含以上全部内容' : '还没有任何标记，先在地图上画一个区块吧',
            ),
          ),
        ),

        // ---- 导出 ----
        Card(
          child: ListTile(
            leading: const Icon(Icons.ios_share_outlined),
            title: const Text('导出备份'),
            subtitle: const Text('另存为 .mapexport.json（纯文本，可看可 diff）'),
            trailing: FilledButton.tonal(
              onPressed: _busy || !hasData ? null : () => unawaited(_export()),
              child: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('导出'),
            ),
          ),
        ),

        // ---- 导入 ----
        Card(
          child: ListTile(
            leading: const Icon(Icons.merge_type_outlined),
            title: const Text('导入备份'),
            subtitle: const Text(
              '合并式导入：只补上你库里没有的区块/门/常送点，'
              '不会删除或覆盖现有标记；同一个文件导两次也不会翻倍',
            ),
            isThreeLine: true,
            trailing: FilledButton.tonal(
              onPressed: _busy ? null : () => unawaited(_import()),
              child: const Text('导入'),
            ),
          ),
        ),

        const SizedBox(height: 24),
      ],
    );
  }
}

/// 导入预览对话框：把「新增什么 / 跳过什么」摊开给用户看。
class _ImportPreviewDialog extends StatelessWidget {
  const _ImportPreviewDialog({required this.picked});

  final PickedBackup picked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = picked.plan.stats;
    final nothingToDo = stats.added == 0;

    return AlertDialog(
      title: Text(nothingToDo ? '没有新内容可导入' : '导入预览'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              picked.fileName,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 12),

            if (nothingToDo)
              Text(
                '这个备份里的内容你都已经有了（跳过 ${stats.skipped} 项）。\n'
                '确认也不会产生任何改动。',
                style: theme.textTheme.bodyMedium,
              )
            else ...[
              _Row('新增区块', stats.areasAdded),
              _Row('新增门', stats.gatesAdded),
              _Row('新增路网边', stats.linesAdded),
              _Row('新增常送点', stats.entitiesAdded),
              if (stats.skipped > 0) ...[
                const Divider(height: 20),
                _Row('跳过（已存在）', stats.skipped, muted: true),
              ],
            ],

            // v12：合并计划改按"域 + 类别"统计（旧版按区块名字列清单，
            // 但三个域各有各的区域，名字清单已经说不清"新增的是哪一层的"）。
            if (picked.warnings.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('导入时的改动说明：', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              ...picked.warnings.take(8).map(
                (w) => Text('· $w', style: theme.textTheme.bodySmall),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(nothingToDo ? '仍然导入' : '确认导入'),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.muted = false});

  final String label;
  final int value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = muted ? theme.colorScheme.outline : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: color)),
          Text(
            '$value',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
