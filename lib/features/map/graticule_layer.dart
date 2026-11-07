/// 经纬线参考网格（第十六章）。
///
/// 每 [step] 经纬度画一条线（默认 **0.1°**）：
/// 在凤岗—龙岗这一带，0.1° 纬差 ≈ 11.1 km、经差 ≈ 10.3 km —— 放大到街区级
/// 是看不见的，它本来就是**拉远看方位**用的参考网格，不是街区尺度的辅助线。
///
/// 为什么做成 FlutterMap 的**子图层**而不是用 `mapViewportProvider`：
/// 后者是防抖 300ms 的（为了不让拖动期间狂查数据库），网格跟着它走会明显滞后，
/// 拖动时线"粘"在原地。`MapCamera.of(context)` 每次相机变化都同步重建，
/// 网格才跟得住手。
///
/// 标签贴在**上边缘**（经线）与**左边缘**（纬线）：贴着屏幕边看得最方便，
/// 又不会盖住中间的内容。
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/graticule.dart';

class GraticuleLayer extends StatelessWidget {
  const GraticuleLayer({super.key, this.step = kGraticuleStep});

  /// 网格间距（度）。
  final double step;

  static const Color _line = Color(0x66455A64);
  static const Color _labelBg = Color(0xCCFFFFFF);

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final b = camera.visibleBounds;

    final spanLat = b.north - b.south;
    final spanLng = b.east - b.west;
    if (spanLat <= 0 || spanLng <= 0) return const SizedBox.shrink();

    // 刻度计算在 core/graticule.dart（纯 Dart，可脱离界面验证）
    if (graticuleTooDense(b.south, b.north, step: step)) {
      return const SizedBox.shrink();
    }
    if (graticuleTooDense(b.west, b.east, step: step)) {
      return const SizedBox.shrink();
    }

    final polylines = <Polyline>[];
    final markers = <Marker>[];

    // 纬线（东西向）
    for (final lat in graticuleTicks(b.south, b.north, step: step)) {
      if (lat < b.south || lat > b.north) continue;
      polylines.add(
        Polyline(
          points: [LatLng(lat, b.west), LatLng(lat, b.east)],
          color: _line,
          strokeWidth: 1,
        ),
      );
      markers.add(
        Marker(
          point: LatLng(lat, b.west + spanLng * 0.04),
          width: 62,
          height: 14,
          child: _GraticuleLabel(text: graticuleLabel(lat, isLat: true)),
        ),
      );
    }

    // 经线（南北向）
    for (final lng in graticuleTicks(b.west, b.east, step: step)) {
      if (lng < b.west || lng > b.east) continue;
      polylines.add(
        Polyline(
          points: [LatLng(b.south, lng), LatLng(b.north, lng)],
          color: _line,
          strokeWidth: 1,
        ),
      );
      markers.add(
        Marker(
          point: LatLng(b.north - spanLat * 0.03, lng),
          width: 62,
          height: 14,
          child: _GraticuleLabel(text: graticuleLabel(lng, isLat: false)),
        ),
      );
    }

    return Stack(
      children: [
        PolylineLayer(polylines: polylines),
        MarkerLayer(markers: markers),
      ],
    );
  }
}

/// 刻度小标签：白底细边，压在网格线上也读得清。
class _GraticuleLabel extends StatelessWidget {
  const _GraticuleLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: GraticuleLayer._labelBg,
        borderRadius: BorderRadius.circular(2),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Text(
          text,
          maxLines: 1,
          style: const TextStyle(
            fontSize: 9,
            fontFamily: 'monospace',
            color: Color(0xFF37474F),
          ),
        ),
      ),
    ),
  );
}
