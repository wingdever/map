/// osm_prep 桌面工具 CLI（docs/design/07-osm-import.md §2 / 06 章 M2a）
///
/// 用法（在工程根目录）：
/// ```bash
/// dart run tool/osm_prep/main.dart --input region.osm --output region.osmapp \
///     --region core [--only road,building,poi]
/// ```
/// 读 OSM XML（geofabrik 下载 / overpass 导出皆可），输出精简 .osmapp 导入包。
library;

import 'dart:io';

import 'package:map/core/osm_prep.dart';

void main(List<String> args) {
  String? input;
  String? output;
  String region = 'unknown';
  final include = <String>{
    'road',
    'building',
    'water',
    'green',
    'railway',
    'poi',
  };

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--input':
      case '-i':
        input = args[++i];
      case '--output':
      case '-o':
        output = args[++i];
      case '--region':
      case '-r':
        region = args[++i];
      case '--only':
        include
          ..clear()
          ..addAll(args[++i].split(','));
      case '--help':
      case '-h':
        _usage();
        return;
      default:
        stderr.writeln('未知参数: ${args[i]}');
        _usage();
        exitCode = 2;
        return;
    }
  }
  if (input == null || output == null) {
    _usage();
    exitCode = 2;
    return;
  }

  try {
    final src = File(input).readAsStringSync();
    final raw = parseOsmXml(src);
    final file = convertRawOsm(raw, region: region, include: include);
    File(output).writeAsStringSync(file.encodeJson());
    stdout.writeln('OK: ${file.summary}');
    stdout.writeln('写入 $output');
  } on FormatException catch (e) {
    stderr.writeln('解析失败: ${e.message}');
    exitCode = 1;
  } on IOException catch (e) {
    stderr.writeln('文件错误: $e');
    exitCode = 1;
  }
}

void _usage() {
  stdout.writeln('''
osm_prep — OSM XML → .osmapp 转换
用法: dart run tool/osm_prep/main.dart --input <file.osm> --output <file.osmapp> [选项]
选项:
  -i, --input   OSM XML 输入文件（必填）
  -o, --output  .osmapp 输出文件（必填）
  -r, --region  区域名，如 core / fenggang（写入包内）
  --only        仅保留大类，逗号分隔: road,building,water,green,railway,poi
''');
}
