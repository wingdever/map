import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../map/display_prefs.dart';
import '../map/import_defaults.dart';
import '../map/import_layer_providers.dart';
import '../map/map_layers.dart';
import 'backup_section.dart';
import 'sample_data.dart';

/// 设置页（M2.5 → v3 → 第十一章）：用户层备份 + 底图包管理。
///
/// - **我的标记 · 备份**（11 章）：把用户手画的区块/门/路网/常送点导出成
///   一个 `.mapexport.json`，再合并式导入回来；
/// - 底图包（10 章）：内置 4 格由 `ensureBundledPacks` 从 asset 解包，
///   全省其余格由 wing 用 `adb push` 放进包目录，运行期按视口 `ATTACH`。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  /// 后台「重装内置底图」：fire-and-forget，完成后 SnackBar 提示。
  ///
  /// v3：只是把 4 个内置包重新解包一次（文件拷贝级，秒级），
  /// 不再是 v2 那种「25MB JSON 解析 + 19 万行入库」。
  static Future<void> _restoreBundled(
    WidgetRef ref,
    BuildContext context,
  ) async {
    final repo = ref.read(repositoryProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final stillMounted = context.mounted;
    try {
      await ensureBundledPacks(repo, force: true);
      ref.invalidate(importBoundsProvider);
      ref.invalidate(importLayerProvider);
      if (stillMounted && messenger != null) {
        messenger.showSnackBar(
          SnackBar(content: Text('已重装内置底图（${kBundledPackAssets.length} 个包）')),
        );
      }
    } catch (_) {
      if (stillMounted && messenger != null) {
        messenger.showSnackBar(const SnackBar(content: Text('重装失败，请稍后再试')));
      }
    }
  }

  /// 重新扫描包目录（App 运行期间 adb push 了新包后用它，免重启）。
  static Future<void> _rescan(WidgetRef ref, BuildContext context) async {
    final repo = ref.read(repositoryProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final stillMounted = context.mounted;
    await repo.rescanPacks();
    ref.invalidate(importBoundsProvider);
    ref.invalidate(importLayerProvider);
    if (stillMounted && messenger != null) {
      messenger.showSnackBar(
        SnackBar(content: Text('已重新扫描：${repo.packs.all.length} 个包')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    final bounds = ref.watch(importBoundsProvider).value;
    final packs = repo.packs;
    final tileCount = packs.tiles.length;
    final attached = repo.attachedPackKeys.length;

    // 自带 Scaffold + AppBar：设置现在是**被 push 进来的独立页面**，
    // 不再挂在首页 TabBarView 里（那时 Scaffold 由首页提供）。
    // 有了 AppBar 才有返回按钮 —— 用户从地图点进来，必须能明显退回去。
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
        // ---- 地图显示（第十六章）----
        Text('地图显示', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          '这些开关只影响"看到什么"，不动任何数据；设置会记住，下次启动仍然生效。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),

        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.grid_4x4_outlined),
            title: const Text('显示经纬线'),
            subtitle: const Text(
              '每 0.1 经纬度画一条参考网格（0.1° 约 11 km，'
              '适合拉远看方位；默认关闭）',
            ),
            value: ref.watch(displayPrefsProvider).showGraticule,
            onChanged: (v) =>
                ref.read(displayPrefsProvider.notifier).setGraticule(v),
          ),
        ),

        const Divider(height: 32),

        // ---- 用户层备份（第十一章）----
        const BackupSection(),

        const Divider(height: 32),

        Text('底图包', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          '开放数据（OSM 矢量）以独立只读包存放，按视口 ATTACH 挂载，'
          '与你的绘制数据完全隔离。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),

        // ---- 包清单状态 ----
        Card(
          child: ListTile(
            leading: const Icon(Icons.map_outlined),
            title: Text(
              '底图包状态（$tileCount 个格包'
              '${attached == 0 ? '' : ' · 已挂载 $attached'}）',
            ),
            subtitle: Text(
              '${bounds?.importSummary ?? '尚无底图包'}'
              '${packs.temp == null ? '' : ' · 含临时导入包'}',
            ),
            trailing: IconButton(
              tooltip: '重新扫描包目录',
              onPressed: () => unawaited(_rescan(ref, context)),
              icon: const Icon(Icons.refresh),
            ),
          ),
        ),

        // ---- 包目录路径（adb push 用）----
        Card(
          child: ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('包目录'),
            subtitle: Text(
              packs.directory?.path ?? '（不可用）',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
            isThreeLine: true,
            trailing: IconButton(
              tooltip: '复制路径',
              onPressed: () {
                // 这里只做提示：真正的复制需要 Clipboard（已随 services 引入）
                Clipboard.setData(
                  ClipboardData(text: packs.directory?.path ?? ''),
                );
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('路径已复制')));
              },
              icon: const Icon(Icons.copy),
            ),
          ),
        ),

        // ---- 清除临时导入包 ----
        Card(
          child: ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('清除临时导入包'),
            subtitle: const Text(
              '删除「导入演示数据」产生的 _import_tmp.db；'
              '不动 adb push 进来的格包',
            ),
            trailing: FilledButton.tonal(
              onPressed: packs.temp == null
                  ? null
                  : () async {
                      await repo.clearImportLayer();
                      ref.invalidate(importBoundsProvider);
                      ref.invalidate(importLayerProvider);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已清除临时导入包')),
                        );
                      }
                    },
              child: const Text('清除'),
            ),
          ),
        ),

        // ---- 导入演示数据（D7：保留 .osmapp 代码能力，写进临时包）----
        Card(
          child: ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('导入演示数据'),
            subtitle: const Text(
              '导入一小片"大运城邦一带"样例到临时包，'
              '体验图层与点选带入',
            ),
            trailing: FilledButton.tonal(
              onPressed: () async {
                await repo.replaceImportLayer(sampleFenggangCore());
                ref.invalidate(importBoundsProvider);
                ref.invalidate(importLayerProvider);
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('演示数据已写入临时包')));
                }
              },
              child: const Text('导入'),
            ),
          ),
        ),

        const SizedBox(height: 12),

        // ---- 重装内置底图 ----
        Card(
          child: ListTile(
            leading: const Icon(Icons.restore_outlined),
            title: const Text('重装内置底图'),
            subtitle: Text(
              '重新解包 ${kBundledPackAssets.length} 个内置包'
              '（10 号线走廊所在网格，覆盖当前同名文件）',
            ),
            trailing: FilledButton.tonal(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('重装内置底图？'),
                    content: Text(
                      '将重新解包 ${kBundledPackAssets.length} 个内置底图包'
                      '（共约 38.5 MB）。\n'
                      '文件级覆盖，秒级完成；不影响你的绘制数据。',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('确认重装'),
                      ),
                    ],
                  ),
                );
                if (confirm != true) return;
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('正在后台重装内置底图…完成时会再提示一次'),
                    duration: Duration(seconds: 2),
                  ),
                );
                unawaited(_restoreBundled(ref, context));
              },
              child: const Text('重装'),
            ),
          ),
        ),

        // ---- 删除全部底图包 ----
        Card(
          child: ListTile(
            leading: Icon(
              Icons.delete_forever_outlined,
              color: Theme.of(context).colorScheme.error,
            ),
            title: const Text('删除全部底图包'),
            subtitle: const Text(
              '连同 adb push 进来的格包一起删；'
              '内置包会在下次启动自动重装',
            ),
            trailing: FilledButton.tonal(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('删除全部底图包？'),
                    content: Text(
                      '将删除包目录下的全部 ${packs.all.length} 个文件。\n'
                      '内置的 ${kBundledPackAssets.length} 个包会在下次启动自动重装；'
                      'adb push 进来的包需要重新推送。\n'
                      '你的绘制数据（区块/门/路网/常送点）不受影响。',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('确认删除'),
                      ),
                    ],
                  ),
                );
                if (confirm != true) return;
                final n = await repo.deleteAllPacks();
                ref.invalidate(importBoundsProvider);
                ref.invalidate(importLayerProvider);
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('已删除 $n 个包文件')));
                }
              },
              child: const Text('删除'),
            ),
          ),
        ),

        const SizedBox(height: 8),
        Text(
          '扩充覆盖：在电脑上跑 tool/basemap_pack/build_packs.py --all，'
          '再把 basemap_out/*.db 用 adb push 到上面的包目录，'
          '然后点「重新扫描」即可，无需重装 APK。',
          style: Theme.of(context).textTheme.bodySmall,
        ),

        const SizedBox(height: 24),
        Text('使用说明', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const _Bullet('底图是只读参考数据，平时点地图不会碰到它；'
            '要把底图上的路/POI 变成自己的数据，进「编辑我的地图」→「选取底图」再点。'),
        const _Bullet('带入即复制为你的数据，之后可独立编辑/删除，不受底图包更新影响。'),
        const _Bullet('左下角图标可单独开关底图的路网 / 建筑 / POI 显示。'),
        const _Bullet('缩放低于 13.5 时不加载矢量底图（远景看 OSM 栅格瓦片即可）。'),
          const _Bullet('底图包随时可整体替换或清除，不影响区块/门/路网/常送点。'),
          const _Bullet('地图左下角的小胶囊可单独开关「店铺」标签与「行政区」蒙层；'
              '经纬线开关在本页最上面。'),
          const _Bullet('「行政区域」是虚拟区域（用行政线围成），只用来标出行政边界，'
              '不参与通行判定。'),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• '),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
