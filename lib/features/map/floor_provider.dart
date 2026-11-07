/// 当前查看的楼层（第十七章「等高」）。
///
/// 需求：点/线/面各自带一个楼层集合，**查看第 N 层时只显示包含 N 的要素**。
/// 这个 provider 就是那个"第 N 层"。
///
/// **不做持久化**（与显示偏好不同）：如果上次退出时停在第 3 层，
/// 下次打开 App 会看到一张几乎空白的地图，而用户完全不知道发生了什么。
/// 每次启动都回到地面层，是"意外最小"的选择；
/// 楼层状态在界面上有专门的楼层条，一眼能看出当前在第几层。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/floor_set.dart';

/// 地面层 = 1。
const int kGroundFloor = FloorSet.groundFloor;

class CurrentFloorNotifier extends Notifier<int> {
  @override
  int build() => kGroundFloor;

  void set(int floor) => state = floor;

  void up() => state = state + 1;

  /// 往下。**不越过地面层以下** —— 地下层还没做，别让用户掉进去。
  void down() {
    if (state <= kGroundFloor) return;
    state = state - 1;
  }

  void reset() => state = kGroundFloor;
}

final currentFloorProvider = NotifierProvider<CurrentFloorNotifier, int>(
  CurrentFloorNotifier.new,
);
