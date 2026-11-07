/// 编辑模式的草稿渲染层（docs/design/12-edit-mode.md §4.5）。
///
/// 只画「还没落库的东西」：正在拉的**折线**（界线/路线/行政线）、围合工具已选的线、
/// 一笔画圈地的顶点与折线，以及「加拐点」模式下**跟着鼠标的拟合预览**（第二十章）。
/// 已经落库的要素由 `map_page._buildSavedLayers` 画。
///
/// 拆成独立文件是为了让编辑态的视觉反馈（虚线、高亮、锚点手柄）集中在一处，
/// 不去污染主图层那段已经很长的渲染代码。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/geometry.dart';
import '../../core/models.dart';
import '../../core/polyline.dart';
import 'edit_mode_controller.dart';

class EditDraftOverlay extends StatelessWidget {
  const EditDraftOverlay({
    super.key,
    required this.edit,
    required this.pointsByDomain,
    required this.linesByRef,
    this.bendHover,
  });

  final EditState edit;

  /// **域 →（点 id → 坐标）**（连线起点、围合已选线的端点都要用它换算）。
  ///
  /// 🔴 必须按域分开：三个域的点表各有各的自增 id，合成一张会静默串味
  /// （拿另一层的点去拼几何 = 画出一条穿过街区的假线）。
  final Map<MapDomain, Map<int, GeoPoint>> pointsByDomain;

  /// **(域, id) → 线**。草稿与围合都发生在**当前编辑域**里（19 章）。
  final Map<(MapDomain, int), LineRow> linesByRef;

  /// 鼠标当前位置（「加拐点」模式的实时预览用）。
  ///
  /// 用 [ValueListenable] 而不是普通字段：hover 每帧都变，
  /// 走它可以让"重画"只发生在这一个图层里（见 `map_page._bendHover` 的说明）。
  final ValueListenable<GeoPoint?>? bendHover;

  static const _accent = Color(0xFF2E7D32);
  static const _ring = Color(0xFFEF6C00);

  /// 「加拐点」预览的主色（橙色，与工具栏横幅同色）。
  static const _bend = Color(0xFFEF6C00);

  @override
  Widget build(BuildContext context) {
    final layers = <Widget>[];

    // ---- 加拐点：目标线高亮 + 鼠标处的拟合预览（20 章）----
    final targetId = edit.bendTargetLineId;
    if (targetId != null && bendHover != null) {
      final line = linesByRef[(edit.layer, targetId)];
      final target = line == null
          ? null
          : polylineOf(line, pointsByDomain[line.domain] ?? const {});
      if (target != null) {
        layers.add(
          // 目标线整体加一层橙描边：地图上可能有好几条路，
          // 先说清"现在改的是这一条"，再谈拐点插在哪。
          PolylineLayer(
            polylines: [
              Polyline(
                points: target.map(_ll).toList(),
                color: _bend.withValues(alpha: 0.55),
                strokeWidth: 7,
              ),
            ],
          ),
        );
        layers.add(
          ValueListenableBuilder<GeoPoint?>(
            valueListenable: bendHover!,
            builder: (context, hover, _) {
              if (hover == null) return const SizedBox.shrink();
              final plan = planBendInsertion(
                line!,
                pointsByDomain[line.domain] ?? const {},
                hover,
              );
              if (plan == null) return const SizedBox.shrink();
              final bad = plan.tooCloseToVertex;
              final color = bad ? const Color(0xFFD32F2F) : _bend;
              return Stack(
                children: [
                  // **拟合预览**：插进去之后这条折线长什么样。
                  // 这是这个功能的全部意义 —— 用户看到的是结果，不是"一个点"。
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: plan.preview.map(_ll).toList(),
                        color: color,
                        strokeWidth: 4,
                      ),
                    ],
                  ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: _ll(hover),
                        width: 30,
                        height: 30,
                        child: _BendHandle(
                          bad: bad,
                          label: bad
                              ? '离已有顶点太近，这里放不下'
                              : '新拐点：离原线 ${plan.distanceM.round()} m，'
                                    '这条路全长 ${plan.addedMeters >= 0 ? '+' : ''}'
                                    '${plan.addedMeters.round()} m',
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        );
      }
    }

    // ---- 折线草稿（界线/路线/行政线）：把已点的顶点连起来预览 ----
    //
    // 这一步不是装饰：折线是**多点**的，用户点到第四个点时如果看不到
    // 前三段画在哪，就只能凭记忆判断"我是不是点歪了"，而这个工具
    // 恰好要把一条路拐三道弯。所以草稿必须实时画出来。
    final draftIds = edit.lineDraftPointIds;
    if (draftIds.isNotEmpty) {
      final pts = <GeoPoint>[];
      final draftPts = pointsByDomain[edit.layer] ?? const <int, GeoPoint>{};
      for (final id in draftIds) {
        final p = draftPts[id];
        if (p == null) continue; // 顶点被删了 → 跳过，不让草稿整条消失
        pts.add(p);
      }
      if (pts.length >= 2) {
        layers.add(
          PolylineLayer(
            polylines: [
              Polyline(
                points: pts.map(_ll).toList(),
                color: _accent,
                strokeWidth: 4,
              ),
            ],
          ),
        );
      }
      if (pts.isNotEmpty) {
        layers.add(
          MarkerLayer(
            markers: [
              for (var i = 0; i < pts.length; i++)
                Marker(
                  point: _ll(pts[i]),
                  width: 26,
                  height: 26,
                  child: _DraftHandle(
                    // 起点与当前终点各自标出来：终点那个是"下一个点接这里"
                    label: i == 0
                        ? '起点'
                        : (i == pts.length - 1 ? '终点（还没完成）' : '拐点 $i'),
                  ),
                ),
            ],
          ),
        );
      }
    }

    // ---- 围合：已选的线高亮（橙色加粗）----
    if (edit.ringLineIds.isNotEmpty) {
      final polys = <Polyline>[];
      final markers = <Marker>[];
      for (final id in edit.ringLineIds) {
        final line = linesByRef[(edit.layer, id)];
        if (line == null) continue;
        // 折线也要按**全部顶点**高亮：只连首尾的话，用户明明选中的是
        // 一条拐了弯的墙，看到的却是一条横穿的直线，会以为选错了线。
        final path = polylineOf(line, pointsByDomain[line.domain] ?? const {});
        if (path == null) continue;
        polys.add(
          Polyline(
            points: path.map(_ll).toList(),
            color: _ring,
            strokeWidth: 5,
          ),
        );
        for (final g in path) {
          markers.add(
            Marker(
              point: _ll(g),
              width: 12,
              height: 12,
              child: const _DraftDot(color: _ring),
            ),
          );
        }
      }
      if (polys.isNotEmpty) layers.add(PolylineLayer(polylines: polys));
      if (markers.isNotEmpty) layers.add(MarkerLayer(markers: markers));
    }

    // ---- 一笔画圈地：折线 + 闭合预览 ----
    if (edit.polygonDraft.isNotEmpty) {
      final pts = edit.polygonDraft.map(_ll).toList();
      final closed = edit.canClosePolygon;
      if (closed) {
        layers.add(
          PolygonLayer(
            polygons: [
              Polygon(
                points: toClockwiseRing(edit.polygonDraft)
                    .map(_ll)
                    .toList(),
                color: const Color(0x332E7D32),
                borderColor: _accent,
                borderStrokeWidth: 3,
              ),
            ],
          ),
        );
      }
      layers.add(
        PolylineLayer(
          polylines: [
            Polyline(
              points: [...pts, if (closed) pts.first],
              color: _accent,
              strokeWidth: 3,
            ),
          ],
        ),
      );
      layers.add(
        MarkerLayer(
          markers: [
            for (var i = 0; i < pts.length; i++)
              Marker(
                point: pts[i],
                width: 18,
                height: 18,
                child: _DraftHandle(label: i == 0 ? '起' : ''),
              ),
          ],
        ),
      );
    }

    return Stack(children: layers);
  }

  LatLng _ll(GeoPoint p) => LatLng(p.lat, p.lng);
}

class _DraftHandle extends StatelessWidget {
  const _DraftHandle({this.label = ''});
  final String label;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: EditDraftOverlay._accent, width: 3),
      ),
    ),
  );
}

/// 跟着鼠标走的「新拐点」手柄：橙色菱形 + 一句"这一拐让路长多少"。
///
/// 用 Tooltip 而不是常驻文字：鼠标跟着一个标签跑会挡住地图，
/// 而"绕了多远"是**放下之前**想确认一下的信息，悬停看到就够。
class _BendHandle extends StatelessWidget {
  const _BendHandle({required this.bad, required this.label});

  final bool bad;
  final String label;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Transform.rotate(
      angle: 0.7853981633974483, // 45°：菱形一眼就能和"已有顶点"（圆点）区分开
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bad ? const Color(0xFFD32F2F) : Colors.white,
          border: Border.all(
            color: bad ? const Color(0xFFD32F2F) : EditDraftOverlay._bend,
            width: 3,
          ),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    ),
  );
}

class _DraftDot extends StatelessWidget {
  const _DraftDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
