import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_repository.dart';

/// 全局仓库 provider。main() 中初始化后 override 注入。
final repositoryProvider =
    Provider<AppRepository>((ref) => throw UnimplementedError('main 中注入'));
