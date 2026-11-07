import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../map/map_page.dart';
import '../settings/settings_page.dart';

/// 首页 = 地图（唯一主界面）+ 右上角的设置入口。
///
/// **为什么不再用底部 TabBar**（用户 2026-09-13 要求）：
/// - 原来的「区块」Tab 从头到尾是个占位页，而区块的浏览/创建/改名/删除
///   早就全部落进了地图页的编辑模式 —— 留着它只会让人以为
///   "还有个没做完的功能"，而且点了发现是空的，比没有更糟；
/// - 地图是这个 App **唯一**的主界面。底部导航白占 56px，
///   还让"我现在在哪一层"变模糊（切到设置页时地图还在后台跑着定位与查询）。
///
/// 设置不是"另一个主界面"，而是偶尔进去改一次配置的地方 ——
/// 用按钮 push 一个独立页面更贴切：进去、改完、返回，语义干净。
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: MapPage(
        // 放进地图页顶部的同一行，而不是自己 Positioned 一层：
        // 顶部状态条的文字长度是变的（缩放/要素计数/导入层摘要），
        // 叠一层浮按钮迟早会盖住它。让地图页把它当成"状态行的尾巴"来排版，
        // 两者永远不会打架。
        topTrailing: _SettingsButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
          ),
        ),
      ),
    );
  }
}

/// 设置入口按钮（与顶部状态条同高的小卡片）。
class _SettingsButton extends StatelessWidget {
  const _SettingsButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Card(
    // 与左侧状态条同高对齐（状态条自己留了 8 的上下外边距）
    margin: const EdgeInsets.symmetric(vertical: 8),
    elevation: 4,
    child: IconButton(
      tooltip: '设置',
      onPressed: onPressed,
      icon: const Icon(Icons.settings_outlined),
    ),
  );
}
