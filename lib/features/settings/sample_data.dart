import 'package:map/core/osmapp.dart';

/// 演示用的核心区样例数据（M2.5 供设置页"导入样例"一键体验）。
///
/// 真实使用：运行 tool/osm_prep/main.dart 从 OSM 区域文件生成 .osmapp 后，
/// 在设置页选择导入（07 章 §2/§5.1）。
OsmAppFile sampleFenggangCore() => OsmAppFile(
      region: 'core-demo（大运城邦一带）',
      generatedAt: '2026-09-10T00:00:00Z',
      bounds: const OsmBounds(
        minLat: 22.7000,
        minLng: 114.1200,
        maxLat: 22.7300,
        maxLng: 114.1500,
      ),
      nodes: const [
        OsmNode(osmId: 1, lat: 22.7100, lng: 114.1300),
        OsmNode(osmId: 2, lat: 22.7150, lng: 114.1300),
        OsmNode(osmId: 3, lat: 22.7200, lng: 114.1300),
        OsmNode(osmId: 4, lat: 22.7200, lng: 114.1350),
        OsmNode(osmId: 5, lat: 22.7200, lng: 114.1400),
        OsmNode(osmId: 6, lat: 22.7150, lng: 114.1400),
        OsmNode(osmId: 7, lat: 22.7100, lng: 114.1400),
        OsmNode(osmId: 8, lat: 22.7100, lng: 114.1350),
      ],
      ways: const [
        // 主路：沿 lat 22.72 的东西向道路（骑行）
        OsmWay(
          osmId: 101,
          kind: ImportKind.road,
          name: '龙平西路（示例）',
          costClass: 'ride',
          nodeIds: [3, 4, 5],
        ),
        // 另一条南北路（推行/步行）
        OsmWay(
          osmId: 102,
          kind: ImportKind.road,
          name: '内部路（示例）',
          costClass: 'ride',
          nodeIds: [1, 2, 3],
        ),
        // 示范建筑轮廓
        OsmWay(
          osmId: 201,
          kind: ImportKind.building,
          name: '大运城邦一期（示例楼）',
          nodeIds: [1, 8, 7, 6, 1],
        ),
      ],
      pois: const [
        OsmPoi(
          osmId: 301,
          name: '示例便利店',
          lat: 22.7150,
          lng: 114.1350,
          tags: {'shop': 'convenience'},
        ),
        OsmPoi(
          osmId: 302,
          name: '雁田三巷 12 号（示例）',
          lat: 22.7120,
          lng: 114.1330,
          tags: {'addr:housenumber': '12'},
        ),
      ],
    );
