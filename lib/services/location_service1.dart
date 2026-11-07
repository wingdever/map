import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libre_location/libre_location.dart';

import '../utils/platform_utils.dart';

// Position(lat: 22.720952, lng: 114.185383, acc: 15.0m 初始化数值

final locationStateProvider = NotifierProvider<LocationService, Position?>(
  LocationService.new,
);

class LocationService extends Notifier<Position?> {
  StreamSubscription<Position>? _subscription;
  String? errorMessage;

  /// 是否真的走到了平台通道。用于让 [dispose] 在「从未启动」时安全早退
  /// （否则 Linux 桌面上 `LibreLocation.stop()` 同样会抛 MissingPluginException）。
  bool _started = false;

  @override
  Position? build() => null;

  Future<void> init() async {
    // libre_location 只声明了 android/ios 平台（pubspec 无 linux 段、仓库无 linux/ 目录），
    // 桌面端走 MethodChannel('libre_location') 必抛 MissingPluginException。
    // 这里直接跳过，state 保持 null（地图不显示用户定位点），不阻塞其他逻辑。
    if (!PlatformUtils.isLocationSupported()) return;
    _started = true;
    // 用 debugPrint 而不是 print：`avoid_print` 要求生产代码别直接用 print，
    // 而 debugPrint 是 Flutter 官方替代品 —— 输出仍进 `flutter run` 控制台与
    // Android logcat，但可被 `debugPrint = ...` 统一接管（例如将来接日志框架）。
    debugPrint('LocationService: 初始化定位服务');
    final permission = await LibreLocation.requestPermission();
    debugPrint('定位权限: $permission');
    if (permission == LocationPermission.denied) {
      errorMessage = '定位权限被拒绝';
      debugPrint('定位权限被拒绝');
      return;
    }
    await LibreLocation.start(preset: TrackingPreset.high);
    _subscription = LibreLocation.onLocation.listen(
      (pos) {
        state = pos; // 更新状态
        errorMessage = null;
      },
      onError: (error) {
        errorMessage = '定位服务错误: $error';
        state = null;
        debugPrint('定位服务错误: $error');
      },
    );
    debugPrint('LocationService: 定位服务已初始化');
  }

  void dispose() {
    if (!_started) return;
    _subscription?.cancel();
    debugPrint('LocationService: 正在停止定位服务');
    LibreLocation.stop();
    debugPrint('LocationService: 定位服务已停止');
  }
}
