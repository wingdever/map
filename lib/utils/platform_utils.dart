import 'dart:io';

import 'package:flutter/foundation.dart';

class PlatformUtils {
  static bool isAndroid() => !kIsWeb && Platform.isAndroid;
  static bool isLinux() => !kIsWeb && Platform.isLinux;
  static bool isLocationSupported() => isAndroid(); // 仅Android启用定位
}
