/// 显示偏好（第十六章）。
///
/// 三类开关都是"想让地图少点东西"时用的：
///   - 经纬线：参考网格，**默认关闭**（用户要求）；
///   - 店铺标签：一条商业街几十家店时会盖住底图；
///   - 行政区域：虚拟区域，做别的活时不想看到它。
///
/// **持久化在 `schema_meta`**（`getMeta` / `setMeta`）而不是内存里：
/// 这些都是"设一次就一直想要的"，每次启动都重置回默认会很烦。
/// 写是 fire-and-forget —— 开关手感不该等一次磁盘写入。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';

/// meta 表的键名。加 `display.` 前缀，跟其它标志位区分开。
const String kMetaShowGraticule = 'display.graticule';
const String kMetaShowShops = 'display.shops';
const String kMetaShowAdministrative = 'display.administrative';

class DisplayPrefs {
  const DisplayPrefs({
    this.showGraticule = false,
    this.showShops = true,
    this.showAdministrative = true,
  });

  /// 经纬线参考网格（每 0.1°）。**默认关闭**。
  final bool showGraticule;

  /// 店铺标签。
  final bool showShops;

  /// 行政区域（虚拟区域）。
  final bool showAdministrative;

  DisplayPrefs copyWith({
    bool? showGraticule,
    bool? showShops,
    bool? showAdministrative,
  }) => DisplayPrefs(
    showGraticule: showGraticule ?? this.showGraticule,
    showShops: showShops ?? this.showShops,
    showAdministrative: showAdministrative ?? this.showAdministrative,
  );
}

class DisplayPrefsNotifier extends Notifier<DisplayPrefs> {
  @override
  DisplayPrefs build() {
    // 先把默认值给出去（界面立刻可用），再异步把存过的偏好读回来。
    // 用 microtask 而不是在 build 里直接 await：Riverpod 不允许在 build
    // 期间同步改自己的 state（会抛 "modified while building"）。
    Future<void>.microtask(_load);
    return const DisplayPrefs();
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(repositoryProvider);
      final g = await repo.getMeta(kMetaShowGraticule);
      final s = await repo.getMeta(kMetaShowShops);
      final a = await repo.getMeta(kMetaShowAdministrative);
      state = DisplayPrefs(
        // 没存过 → 保持默认（经纬线关、店铺开、行政区开）
        showGraticule: g == null ? false : g == '1',
        showShops: s == null ? true : s == '1',
        showAdministrative: a == null ? true : a == '1',
      );
    } catch (_) {
      // 读不到就用默认值，不影响使用
    }
  }

  Future<void> _persist(String key, bool value) async {
    try {
      await ref.read(repositoryProvider).setMeta(key, value ? '1' : '0');
    } catch (_) {
      // 写失败不阻断交互：本次会话内开关仍然生效
    }
  }

  void toggleGraticule() {
    state = state.copyWith(showGraticule: !state.showGraticule);
    unawaited(_persist(kMetaShowGraticule, state.showGraticule));
  }

  void setGraticule(bool v) {
    state = state.copyWith(showGraticule: v);
    unawaited(_persist(kMetaShowGraticule, v));
  }

  void toggleShops() {
    state = state.copyWith(showShops: !state.showShops);
    unawaited(_persist(kMetaShowShops, state.showShops));
  }

  void toggleAdministrative() {
    state = state.copyWith(showAdministrative: !state.showAdministrative);
    unawaited(_persist(kMetaShowAdministrative, state.showAdministrative));
  }
}

/// `unawaited` 的最小实现，免得为了一个函数引入 dart:async 的 import。
void unawaited(Future<void> f) {}

final displayPrefsProvider =
    NotifierProvider<DisplayPrefsNotifier, DisplayPrefs>(
      DisplayPrefsNotifier.new,
    );
