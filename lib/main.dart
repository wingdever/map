import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/app_repository.dart';
import 'data/db_factory.dart';
import 'data/providers.dart';
import 'features/home/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 数据库引擎初始化（全平台统一 sqflite_common_ffi）+ 落点解析：
  //   - Android 保持 app_flutter/，老用户数据原地不动；
  //   - Linux 桌面用 applicationSupport（~/.local/share/com.example.map）。
  // 详见 lib/data/db_factory.dart 与 docs/design/09-linux-port.md。
  initDatabaseFactory();

  // ⚠️ 这一段**必须**包在 try 里：开库是在 `runApp` 之前 await 的，
  // 一旦抛异常，`runApp` 根本不会被执行 —— 用户看到的只是一个**黑窗口**，
  // 原因只留在终端里（桌面端还可能根本没有终端）。而开库失败的原因
  // 恰恰都是用户必须知道、且必须自己动手处理的（库还是 v11 要跑迁移脚本、
  // 文件损坏、权限不对……），所以失败也要给出**能读的界面**。
  String? dbPath;
  try {
    dbPath = await resolveDatabasePath();
    // 底图包目录：Android 走外部应用专属目录（adb push 可直接写），
    // 其他平台走 applicationSupport（见 db_factory.resolveBasemapDir）。
    final repo = await AppRepository.open(dbPath);
    final container = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(repo)],
    );
    runApp(
      UncontrolledProviderScope(container: container, child: const MapApp()),
    );
  } catch (e, st) {
    runApp(_StartupFailureApp(error: e, stack: st, dbPath: dbPath));
  }
  // 内置底图包的解包**不在这里触发**：改由 importLayerProvider 在查询前 await
  // ensureBundledPacks（见 lib/features/map/import_layer_providers.dart）。
  //
  // 这样做的原因：曾经在 postFrame 里 fire-and-forget 调用，会与 importLayerProvider
  // 的首查形成竞态 —— 首查在解包完成前返回空、进度状态又被解包的回调覆盖，
  // 表现为「首启底图为空且进度条卡在正在扫描底图包，切 Tab 才恢复」。
  // runApp 依然不被阻塞（provider 的 await 是异步的）。
}

class MapApp extends StatelessWidget {
  const MapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '最后一公里地图',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32)),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

/// 开库失败时替代整个 App 的界面。
///
/// 它存在的理由只有一个：**把失败原因送到用户眼前**。
/// 不做"重试"按钮 —— 上面那些原因（库版本没迁、文件损坏、权限）都不是点一下
/// 就能好的，给个假按钮反而让人以为再点几次就行。
class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({
    required this.error,
    required this.stack,
    this.dbPath,
  });

  final Object error;
  final StackTrace stack;

  /// 解析失败时为 null（那种情况下连路径都没拿到）。
  final String? dbPath;

  @override
  Widget build(BuildContext context) {
    // 迁移失败与文件损坏的处置完全不同，所以按"看起来像不像数据库"给一句提示。
    final looksLikeDbProblem =
        dbPath != null && !error.toString().contains('底图包目录');

    return MaterialApp(
      title: '最后一公里地图 · 启动失败',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFB3261E)),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.error_outline, size: 32),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '地图数据打不开，App 没有启动',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '你的数据没有被改动 —— 打开数据库是在一个事务里做的，'
                      '出错会整体回滚。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 20),
                    if (dbPath != null) ...[
                      const Text(
                        '库文件位置',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        dbPath!,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                    const Text(
                      '原因',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    // 迁移脚本给的提示是**多行**的，原样展示（含要照抄的命令）
                    SelectableText(
                      error.toString().replaceFirst('Bad state: ', ''),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                    if (looksLikeDbProblem) ...[
                      const SizedBox(height: 20),
                      Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: const [
                              Text(
                                '常见的两种处置',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              SizedBox(height: 6),
                              Text(
                                '1. 提示"还是 v11"→ 按上面给的命令先备份、再跑迁移脚本；\n'
                                '2. 文件损坏 / 权限不对 → 用备份恢复：\n'
                                '     ls -la 库文件所在的目录（找 .bak 与 .mapexport.json）',
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('技术细节（贴回来给 AI 看）'),
                      children: [
                        SelectableText(
                          '$stack',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
