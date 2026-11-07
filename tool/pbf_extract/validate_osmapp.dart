// 离线校验：用 App 端真实的 OsmAppFile 解析器读取生成的 .osmapp，确认结构可被 App 消费。
import 'dart:convert';
import 'dart:io';

import 'package:map/core/osmapp.dart';

void main(List<String> args) {
  for (final name in ['corridor']) {
    final path = 'assets/osm/$name.osmapp';
    final src = File(path).readAsStringSync();
    final file = OsmAppFile.fromJsonString(src);
    final json = jsonDecode(src) as Map<String, Object?>;
    final ways = (json['ways'] as List).cast<Map<String, Object?>>();
    var badRef = 0;
    final nodeIds = {for (final n in file.nodes) n.osmId: n};
    for (final w in ways) {
      final ids = (w['node_ids'] as List).cast<int>();
      for (final r in ids) {
        if (!nodeIds.containsKey(r)) {
          badRef++;
          break;
        }
      }
    }
    stdout.writeln('$name: region=${file.region} nodes=${file.nodes.length} '
        'ways=${file.ways.length} pois=${file.pois.length} '
        'badRefWays=$badRef bounds=${file.bounds}');
  }
  stdout.writeln('OsmAppFile parse OK');
}
