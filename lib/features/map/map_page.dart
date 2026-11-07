import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:libre_location/libre_location.dart';

import '../../core/gate_time.dart';
import '../../core/floor_set.dart';
import '../../core/geometry.dart';
import '../../core/hit_test.dart';
import '../../core/models.dart';
import '../../core/line_feature_layout.dart';
import '../../core/point_density.dart';
import '../../core/polyline.dart';
import '../../core/route_crossing.dart';
import '../../data/app_repository.dart';
import '../../data/providers.dart';
import '../../services/location_service1.dart';
import '../../utils/platform_utils.dart';
import '../editor/edit_mode_controller.dart';
import '../editor/edit_overlay.dart';
import '../editor/feature_forms.dart';
import '../editor/gate_form_sheet.dart';
import 'display_prefs.dart';
import 'floor_provider.dart';
import 'graticule_layer.dart';
import 'import_layer_providers.dart';
import 'map_layers.dart';

/// 拖动顶点时的落库节流间隔（毫秒）。
///
/// 100ms ≈ 10 次/秒：人手拖动的视觉流畅度够用，而每条 UPDATE 后面还跟着
/// 一次整层刷新（十几条 SQL），再密就会明显掉帧。
const int _kDragThrottleMs = 100;

/// 10 号线走廊默认中心（平湖—大运中段，可后续改为定位）。
///
/// 数字常量在 `import_layer_providers.dart` 的 `kCorridorCenterLat/Lng` 定义，
/// 这里只做 LatLng 包装，保证 importLayerProvider 的兜底 bbox 与 initState
/// 写入的初始视口完全一致。
final LatLng kCorridorCenter = LatLng(kCorridorCenterLat, kCorridorCenterLng);

class MapPage extends ConsumerStatefulWidget {
  const MapPage({super.key, this.topTrailing});

  /// 顶部状态条**右侧**的附加控件（首页用它放"设置"入口）。
  ///
  /// 做成插槽而不是让首页自己 Positioned 一层：状态条的文字长度是变的
  /// （缩放、要素计数、导入层摘要），浮动叠加迟早会盖住它。
  final Widget? topTrailing;

  @override
  ConsumerState<MapPage> createState() => _MapPageState();
}

class _MapPageState extends ConsumerState<MapPage> {
  final MapController _mapController = MapController();

  /// 拖拽顶点时要把「手指的屏幕坐标」换算回经纬度，需要地图控件自己的
  /// RenderBox（`globalToLocal`）。没有它就只能拿全局坐标硬算，一旦地图
  /// 不在屏幕原点就会整体偏移。
  final GlobalKey _mapKey = GlobalKey();

  /// 鼠标在地图上的当前位置（第二十章「加拐点」的实时预览用）。
  ///
  /// **刻意不放进 `EditState`**：hover 每帧都触发，走 Riverpod 会把工具条、
  /// 图层、状态条全部跟着重建一遍（肉眼可见的卡）。用一个 ValueNotifier
  /// 只让预览那一层重画，代价就只剩一条折线的 draw。
  final ValueNotifier<GeoPoint?> _bendHover = ValueNotifier(null);

  Timer? _viewportTimer;

  /// 进度条 done 阶段"清空延迟"计时器。state 进入 done 后等 600ms 无新 report
  /// 就清空（避免 finish() 后立刻消失看不见）。
  Timer? _progressHideTimer;
  int _progressSeenTick = -1;

  LocationService? _locationService;

  @override
  void initState() {
    super.initState();
    // 初始化首屏视口（默认中心 ± 跨度），避免无视口时全量加载导入层。
    // 这里必须在首帧之后再写 mapViewportProvider：
    //   HomePage 直接构建 MapPage，第一次 build 期间
    //   importLayerProvider 已经在 ref.watch(mapViewportProvider)，
    //   若我们在 build 阶段同步 `state = newViewport`，Riverpod 3 会
    //   抛 "try to modify a provider while the widget tree was building"。
    // addPostFrameCallback 把写入延后到首帧画完之后，既保留「首屏就带
    // 视口，不会触发 importLayerProvider 的全量分支」这个语义，又避开
    // 上述 build 期状态写入校验。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 视口与 import_layer_providers.kInitialViewport 必须保持一致——
      // 见 importLayerProvider 顶部注释。否则 build 期间 vp=null 时 provider
      // 用的兜底视口会跟这里写的不一样，第一次 invalidate 会重查。
      _locationService = ref.read(locationStateProvider.notifier);
      _locationService?.init();
      ref
          .read(mapViewportProvider.notifier)
          .update(
            MapViewport(
              kCorridorCenterLat - kInitialViewportSpan,
              kCorridorCenterLng - kInitialViewportSpan,
              kCorridorCenterLat + kInitialViewportSpan,
              kCorridorCenterLng + kInitialViewportSpan,
            ),
          );
    });
  }

  @override
  void dispose() {
    _viewportTimer?.cancel();
    _progressHideTimer?.cancel();
    _mapController.dispose();
    _locationService?.dispose();
    _bendHover.dispose();
    super.dispose();
  }

  /// 监听进度 state：进入 done 阶段且无新变化 600ms 后清空。
  ///
  /// 设计要点：之前用 [MapDataProgressNotifier.finish] 内部 600ms 后清 state，
  /// 但那样会让 `mapLayersProvider.areaRing` 的后续 `report(bounds)` 命中
  /// `if (cur == null) return` 丢帧——结果就是进度条永远卡在 gates。
  ///
  /// 现在改为：Notifier.finish 不自动清 state，由 UI 层统一控制隐藏时机。
  /// _seenTick 用来区分「同一个 done 帧多次 build」与「新一次 done」：
  /// 只有 tick 真正变化才重置计时器。
  void _handleProgressDone(MapDataProgress? p) {
    if (p == null) {
      _progressHideTimer?.cancel();
      _progressHideTimer = null;
      _progressSeenTick = -1;
      return;
    }
    if (p.phase != MapDataPhase.done) {
      // 任何非 done 阶段都取消隐藏计时器（防止清掉正在跑的进度）。
      _progressHideTimer?.cancel();
      _progressHideTimer = null;
      _progressSeenTick = p.tick;
      return;
    }
    // phase == done：如果是新的一次 done（tick 推进了），重置计时器。
    if (p.tick == _progressSeenTick) return;
    _progressSeenTick = p.tick;
    _progressHideTimer?.cancel();
    _progressHideTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      // 清空前再核对一次：state 是否仍是同一个 done（防止期间被新 report 抢走）。
      final cur = ref.read(mapDataProgressProvider);
      if (cur?.phase == MapDataPhase.done && cur?.tick == _progressSeenTick) {
        ref.read(mapDataProgressProvider.notifier).clear();
      }
    });
  }

  /// 相机移动时防抖更新地图视口（~300ms），驱动导入层按视口裁剪重查。
  void _onMapEvent(MapEvent event) {
    final bounds = event.camera.visibleBounds;
    final zoom = event.camera.zoom;
    // zoom 是每次相机变化都同步写（Notifier 内部按整数部分节流）；
    // 视口仍然防抖 300ms 后写，避免拖动期间数据库查询风暴。
    ref.read(mapZoomProvider.notifier).update(zoom);
    _viewportTimer?.cancel();
    _viewportTimer = Timer(const Duration(milliseconds: 300), () {
      ref
          .read(mapViewportProvider.notifier)
          .update(
            MapViewport(
              bounds.southWest.latitude,
              bounds.southWest.longitude,
              bounds.northEast.latitude,
              bounds.northEast.longitude,
            ),
          );
    });
  }

  Marker? _buildUserMarker(Position? pos) {
    if (pos == null) return null;

    return Marker(
      point: LatLng(pos.latitude, pos.longitude),
      width: 40,
      height: 40,
      child: Transform.rotate(
        angle:
            0, //pos.heading.isNaN ? 0.0 : pos.heading * 3.14159 / 180, // 度转弧度
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: Colors.blue,
                shape: BoxShape.circle,
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios, // 尖锐箭头
              color: Colors.white,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final domains = ref.watch(mapLayersProvider);
    final edit = ref.watch(editModeProvider);
    final importLayer = ref.watch(importLayerProvider);
    final dataProgress = ref.watch(mapDataProgressProvider);
    final importVis = ref.watch(importVisibilityProvider);
    final locationState = ref.watch(locationStateProvider);
    // 当前查看的楼层（第十七章）：渲染、状态条、楼层条都要用
    final floor = ref.watch(currentFloorProvider);

    // 挂起的表单请求 / 提示：控制器不碰 BuildContext，由这里统一弹窗。
    //
    // **必须推迟到帧后**：listener 是在 provider 状态变更的那一刻同步跑的，
    // 那个时刻可能正处在 build/布局阶段。此时同步 showDialog 或再写一次
    // provider 都会撞上 "setState() or markNeedsBuild() called during build"。
    ref.listen<EditState>(editModeProvider, (prev, next) {
      final request = next.request;
      final isNewRequest = request != null && request != prev?.request;
      final hasNewNote =
          next.notes.isNotEmpty && next.notes.length != (prev?.notes.length ?? 0);
      if (!isNewRequest && !hasNewNote) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (isNewRequest) unawaited(_handleEditRequest(request));
        if (hasNewNote) {
          _toast(next.notes.last);
          ref.read(editModeProvider.notifier).clearNotes();
        }
      });
    });

    _handleProgressDone(dataProgress);

    return Stack(
      children: [
        // 「加拐点」模式下把光标换成十字：鼠标移到地图上时，用户需要知道
        // "现在这一次点按会落到地图上（而不是拖地图）"。桌面端这是最直接的暗示。
        MouseRegion(
          cursor: edit.addingBend
              ? SystemMouseCursors.precise
              : MouseCursor.defer,
          child: FlutterMap(
            key: _mapKey,
            mapController: _mapController,
            options: MapOptions(
              initialCenter: kCorridorCenter,
              initialZoom: 15,
              minZoom: 12,
              maxZoom: 19,
              backgroundColor: const Color(0xFFE8EDF2),
              onTap: (_, latLng) => _onMapTap(latLng),
              onMapEvent: _onMapEvent,
              // 鼠标跟随（20 章「加拐点」的实时预览）。
              // 只在那个模式里记录位置：hover 每帧都触发，
              // 不做这个判断的话整个地图会被无意义地刷新。
              onPointerHover: (_, latLng) {
                if (!ref.read(editModeProvider).addingBend) return;
                _bendHover.value = GeoPoint(latLng.latitude, latLng.longitude);
              },
            ),
            children: [
              MarkerLayer(
                markers: [
                  if (locationState != null) _buildUserMarker(locationState)!,
                ].whereType<Marker>().toList(),
              ),
              // 经纬线参考网格（默认关闭）。放在最前 = 画在所有东西下面，
              // 它只是参考线，不该压住用户自己画的任何要素。
              if (ref.watch(displayPrefsProvider).showGraticule)
                const GraticuleLayer(),
              // 导入层（OSM 矢量，淡显；在用户区块层之下）
              if (importLayer.value case final iv?)
                ..._buildImportLayers(iv, importVis),
              if (domains case AsyncData(:final value))
                ..._buildSavedLayers(value, edit),
              // 编辑草稿预览（未落库的折线草稿 / 已选线 / 圈地顶点 / 加拐点的拟合预览）
              if (edit.active && (edit.hasDraft || edit.addingBend))
                if (domains.value case final data?)
                  EditDraftOverlay(
                    edit: edit,
                    pointsByDomain: data.pointsByDomain,
                    linesByRef: data.linesByRef,
                    bendHover: _bendHover,
                  ),
            ],
          ),
        ),
        // 顶部信息条 + 模式工具条（贴顶、收缩高度）
        //
        // 用 Row 而不是把插槽浮在上面：状态条与工具条的宽度都随内容变，
        // 给插槽让出固定的一列，它们就永远不会互相压盖。
        SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _statusBar(
                          context,
                          domains,
                          importLayer,
                          dataProgress,
                          edit,
                          floor,
                        ),
                        if (edit.active && edit.recording)
                          _recordToolbar(context, edit)
                        else if (edit.active)
                          _editToolbar(context, edit, domains.value),
                      ],
                    ),
                  ),
                  if (widget.topTrailing != null) ...[
                    const SizedBox(width: 8),
                    widget.topTrailing!,
                  ],
                ],
              ),
            ),
          ),
        ),
        // 楼层条（第十七章）：右侧竖排，不占地图中间的地方
        Positioned(
          right: 12,
          top: 0,
          bottom: 0,
          child: Center(child: _FloorStepper(floor: floor)),
        ),
        // 地图到我的位置按钮
        Positioned(
          right: 16, // 和 primaryAction 保持相同的 right 值，完全靠右对齐
          bottom: 156, // 24(bottom) + 48(编辑) + 10(间距) + 48(记录) + 26 = 156
          child: FloatingActionButton(
            heroTag: "locateMe",
            backgroundColor: Colors.white,
            foregroundColor: Colors.blueAccent,
            mini: true,
            onPressed: () {
              if (locationState == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("暂未获取到当前位置，请稍后再试")),
                );
                return;
              }
              _mapController.move(
                LatLng(locationState.latitude, locationState.longitude),
                15.5,
              );
            },
            child: const Icon(Icons.my_location),
          ),
        ),
        // 右下主按钮：**记录 / 编辑**（第十四章从一个按钮拆成两个）
        //
        // 编辑 = 画点/线/面/店铺/墙体/门；
        // 记录 = 采当前位置（或点地图）落一个点，落完立刻能改。
        // 两者是不同的活：画地图是坐下来慢慢描，记录是跑单时顺手一按。
        Positioned(
          right: 16,
          bottom: 24,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!edit.active) ...[
                FloatingActionButton.extended(
                  heroTag: 'recordToggle',
                  backgroundColor: const Color(0xFFB71C1C),
                  foregroundColor: Colors.white,
                  onPressed: () =>
                      ref.read(editModeProvider.notifier).enterRecording(),
                  icon: const Icon(Icons.my_location),
                  label: const Text('记录'),
                ),
                const SizedBox(height: 10),
              ],
              FloatingActionButton.extended(
                heroTag: 'editModeToggle',
                backgroundColor: edit.active ? const Color(0xFF2E7D32) : null,
                foregroundColor: edit.active ? Colors.white : null,
                onPressed: () {
                  final ctrl = ref.read(editModeProvider.notifier);
                  if (edit.active) {
                    ctrl.exit();
                  } else {
                    ctrl.enter();
                  }
                },
                icon: Icon(edit.active ? Icons.check : Icons.edit_location_alt),
                label: Text(
                  edit.active
                      ? (edit.recording ? '完成记录' : '完成编辑')
                      : '编辑',
                ),
              ),
            ],
          ),
        ),
        // 图层显示开关（只在这类要素确实存在时才出现，没东西可藏就不占地方）
        Positioned(
          left: 12,
          bottom: 140,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (domains.value case final d? when d.shops.isNotEmpty) ...[
                const _DisplayToggleChip(
                  icon: Icons.storefront_outlined,
                  label: '店铺',
                  which: _DisplayToggle.shops,
                ),
                const SizedBox(height: 6),
              ],
              // v12：**域就是虚实**（行政区域是 zone_areas 那张表）
              if (domains.value case final d?
                  when d.areas.any((a) => a.domain.isVirtual)) ...[
                const _DisplayToggleChip(
                  icon: Icons.account_balance_outlined,
                  label: '行政区',
                  which: _DisplayToggle.administrative,
                ),
              ],
            ],
          ),
        ),
        // 导入层开关快捷入口（左下小胶囊，仅当有导入数据时）
        if (importLayer.value case final data?)
          if (data.ways.isNotEmpty || data.pois.isNotEmpty)
            Positioned(
              left: 12,
              bottom: 24,
              child: _ImportToggleChip(vis: importVis),
            ),
        // 比例尺（左下角，导入层开关上方）。始终可见，跟 zoom 联动。
        Positioned(
          left: 12,
          bottom: 92,
          child: _ScaleBar(
            zoom: ref.watch(mapZoomProvider),
            centerLat: kCorridorCenterLat,
            screenWidth: MediaQuery.of(context).size.width,
          ),
        ),
        // 底部：选中要素面板（浏览模式与编辑模式的「选择」工具共用）
        if (edit.selection != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: _buildSelectionPanel(domains, edit),
          ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // 点击分发
  // -------------------------------------------------------------------------

  void _onMapTap(LatLng latLng) {
    final p = GeoPoint(latLng.latitude, latLng.longitude);
    final edit = ref.read(editModeProvider);

    // ---- 编辑模式的「选取底图」子模式：唯一能和底图交互的地方 ----
    //
    // 为什么把底图交互单独关起来：底图是 OSM 的只读参考数据，
    // 用户点地图的**绝大多数**时候是想选自己的东西。以前浏览态随手一点
    // 就弹「要不要把这条路变成你的路网？」，既打断操作，
    // 又容易在无意中把 OSM 数据灌进用户层（一旦带入就是独立数据，
    // 用户根本分不清哪些是自己画的）。
    if (edit.active && edit.tool == EditTool.basemap) {
      _handleBasemapTap(p);
      return;
    }

    // ---- 编辑模式的其它工具：交给编辑控制器按工具分发 ----
    if (edit.active) {
      unawaited(
        ref
            .read(editModeProvider.notifier)
            .onMapTap(p, ref.read(mapLayersProvider).value),
      );
      return;
    }

    // ---- 浏览模式：只选自己的要素，点空白清除选中 ----
    //
    // 走与编辑模式**完全同一条**命中逻辑（controller.selectAt），
    // 免得"浏览时点得到、进编辑模式又点不到"这种最让人困惑的不一致。
    final data = ref.read(mapLayersProvider).value;
    if (data == null) return;
    ref.read(editModeProvider.notifier).selectAt(p, data);
  }

  /// 标成「换路口」却没接上围栏路时**警告但不拦**（第二十一章）。
  ///
  /// 用户 2026-09-14 明确：校验强度是"只警告不拦" ——
  /// 允许先标路口、回头再把那两条路标成「围栏路」（现实中这两件事的先后本来就不固定）。
  /// 所以这里做的事只有一件：**把问题说清楚**，说清到"该去改哪条路"的程度 ——
  /// [CrossingLink.describe] 会把"旁边根本没画围栏路"与"围栏路就在旁边但端点悬着"
  /// 分成两句不同的话，用户才知道下一步该干什么。
  Future<void> _warnIfCrossingUnlinked(
    int lineId,
    RouteWidth? width,
    MapLayersData? data,
  ) async {
    if (width != RouteWidth.crossing) return;
    var snapshot = data;
    if (snapshot == null ||
        !snapshot.linesByRef.containsKey((MapDomain.way, lineId))) {
      // 刚画完的线可能还没进当前这份快照（provider 刚被 invalidate）——
      // 没有它就算不了连接，所以等一次真正的加载。
      try {
        snapshot = await ref.read(mapLayersProvider.future);
      } catch (_) {
        return;
      }
    }
    final loaded = snapshot;
    if (loaded == null) return;
    final line = loaded.linesByRef[(MapDomain.way, lineId)];
    if (line == null) return;
    final link = checkCrossingLink(
      crossing: line,
      allLines: loaded.lines,
      pointsByDomain: loaded.pointsByDomain,
    );
    if (link.ok) return;
    _toast('换路口还没接好：${link.describe()}');
  }

  /// 「选取底图」子模式：命中 OSM 路 / POI → 询问是否带入为我的数据。
  ///
  /// 命中优先级 POI > 路：POI 是点，视觉上更小、更"精确"，
  /// 而一条路上往往压着好几个 POI，先判 POI 更符合点哪得哪的直觉。
  void _handleBasemapTap(GeoPoint p) {
    final view = ref.read(importLayerProvider).value;
    if (view == null) {
      _toast('底图还没加载完，稍后再试');
      return;
    }
    final vis = ref.read(importVisibilityProvider);
    if (vis.nothingVisible) {
      _toast('底图层当前是隐藏的，先用左下角的图层开关打开路网或 POI');
      return;
    }
    final tol = snapToleranceForZoom(ref.read(mapZoomProvider));
    if (vis.pois) {
      final hitPoi = hitNearestPoi(view.pois, p, maxDistanceM: tol);
      if (hitPoi != null) {
        unawaited(_offerAdoptPoi(hitPoi.$1));
        return;
      }
    }
    if (vis.roads) {
      final hitWay = hitNearestWay(view.ways, p, maxDistanceM: tol);
      if (hitWay != null) {
        unawaited(_offerAdoptWay(hitWay.$1));
        return;
      }
    }
    _toast('附近没有可选取的底图要素');
  }

  // -------------------------------------------------------------------------
  // 编辑模式：请求 → 表单 → 回填
  // -------------------------------------------------------------------------

  /// 控制器挂起了表单请求 → 弹对应的表单 → 把结果交回控制器。
  Future<void> _handleEditRequest(EditRequest request) async {
    final notifier = ref.read(editModeProvider.notifier);
    final data = ref.read(mapLayersProvider).value;
    if (!mounted) {
      notifier.cancelRequest();
      return;
    }

    switch (request) {
      case MarkFormRequest():
        // v12：记录点是**自己的表**（`world_marks`），表单问名字 + 楼层。
        final out = await showMarkForm(
          context,
          initialFloors: FloorSet([ref.read(currentFloorProvider)]),
          currentFloor: ref.read(currentFloorProvider),
          byGps: false,
          isNew: true,
          canDelete: false,
        );
        if (out == null || out.deleted) {
          notifier.cancelRequest();
        } else if (out.result case final r?) {
          await notifier.saveMark(request.markId, r.name, r.floors);
        } else {
          notifier.cancelRequest();
        }

      case PointFormRequest():
        // 几何点只剩楼层（D9）—— 点表没有名字也没有类别，
        // 「这个点是干什么用的」由它落在哪个域表达。
        final edit = ref.read(editModeProvider);
        final out = await showPointForm(
          context,
          initialFloors: FloorSet([ref.read(currentFloorProvider)]),
          currentFloor: ref.read(currentFloorProvider),
          isNew: true,
          canDelete: false,
        );
        if (out == null || out.deleted) {
          notifier.cancelRequest();
        } else if (out.result case final r?) {
          await notifier.savePoint(request.pointId, edit.layer, r.floors);
        } else {
          notifier.cancelRequest();
        }

      case LineFormRequest():
        final line = data?.linesByRef[(request.domain, request.lineId)];
        // 刚拉完的线先让用户确认形状（几个顶点）——折线最容易出的错
        // 就是"点漏了一个拐点"；这时说清"有 5 个顶点"他立刻能对上，
        // 而要改形状也不必重新画：用「选择」长按拖动那个顶点就行。
        final verts = line?.pointCount ?? 0;
        final out = await showLineForm(
          context,
          title: '给这条线命名',
          subtitle: line == null
              ? '线是区域的边界、也是可走的路。可以现在命名，也可以之后在「选择」工具里改。'
              : '这条线有 $verts 个顶点（起点 + ${verts - 2} 个拐点 + 终点）。'
                    '点漏了拐点不用重画：之后用「选择」长按拖动顶点就能改形状。',
          initial: line,
          initialFloors: FloorSet([ref.read(currentFloorProvider)]),
          currentFloor: ref.read(currentFloorProvider),
        );
        if (out == null) {
          notifier.cancelRequest();
        } else if (out.deleted) {
          await notifier.deleteSelection();
        } else if (out.result case final r?) {
          await notifier.saveLineProps(
            request.lineId,
            name: r.name,
            domain: r.domain,
            floors: r.floors,
            boundaryType: r.boundaryType,
            routeWidth: r.routeWidth,
            oneWay: r.oneWay,
            note: r.note,
          );
          await _warnIfCrossingUnlinked(request.lineId, r.routeWidth, data);
        }

      case RingFormRequest(:final lineIds):
        final isPolygon = lineIds.isEmpty;
        // 用行政线围出来的，域就是 zone（**域就是虚实**）—— 表单据此预选类型
        final ringVirtual = request.virtual;
        final res = await showAreaForm(
          context,
          title: isPolygon ? '为圈出的多边形命名' : '这 ${lineIds.length} 条线围成了一个区域',
          subtitle: isPolygon
              ? '一笔画多边形：刚才点的拐角会建成这个多边形的一圈点（**不造线**）'
              : (ringVirtual
                    ? '这几条是**行政线**（虚拟），所以是行政区域'
                    : '给它起个名字并选择类型；之后这些线也可以被别的区域共用'),
          // 行政域没有 area_type 这一列（整张表就是"行政区域"），所以不预选类型
          initialDomain: request.domain,
          initialType: ringVirtual ? null : AreaType.community,
          initialFloors: FloorSet([ref.read(currentFloorProvider)]),
          currentFloor: ref.read(currentFloorProvider),
        );
        if (res == null) {
          notifier.cancelRequest();
        } else if (isPolygon) {
          await notifier.commitPolygon(res.name, res.type, res.floors);
        } else {
          await notifier.commitRing(res.name, res.type, res.floors);
        }

      case LineFeatureFormRequest(:final lineId, :final at):
        // v12：**墙体段没有了**（D5：真库 0 行，且"这段是墙"应该由线的材质表达，
        // 而不是往线上再挂一个要素）。所以这里只剩店铺一条支路。
        final line = data?.linesByRef[(MapDomain.world, lineId)];
        final lineName = line?.displayName ?? '线 #$lineId';
        {
          final out = await showShopForm(
            context,
            lineName: lineName,
            center: at,
            shopCount: data == null
                ? 0
                : placeFeaturesOfType(
                    line: line!,
                    pointsById: data.pointsOf(MapDomain.world),
                    entities: data.entities,
                    type: EntityType.shop,
                  ).length,
          );
          if (out?.result case final r?) {
            await notifier.saveLineFeature(
              type: EntityType.shop,
              lineId: lineId,
              name: r.name,
              desc: r.desc,
              doorNo: r.doorNo,
              center: at,
              width: r.width,
            );
          } else {
            notifier.cancelRequest();
          }
        }

      case GateFormRequest(:final lineId, :final at):
        // 门只挂世界图的界线（D21：单一锚点）
        final line = data?.linesByRef[(MapDomain.world, lineId)];
        if (line == null) {
          notifier.cancelRequest();
          return;
        }
        if (!mounted) return;
        final res = await showGateFormSheet(
          context,
          lineName: line.displayName,
          center: at,
        );
        if (res == null) {
          notifier.cancelRequest();
        } else {
          await notifier.saveGate(
            lineId: lineId,
            center: at,
            gateType: res.gateType,
            name: res.name,
            vehicleType: res.vehicleType,
            accessLevel: res.accessLevel,
            note: res.note,
          );
        }

      case FeatureFormRequest(:final selection):
        await _handleFeatureForm(selection);
    }
  }

  /// 「选择」工具点开某个要素的属性表单。
  Future<void> _handleFeatureForm(EditSelection selection) async {
    final notifier = ref.read(editModeProvider.notifier);
    final data = ref.read(mapLayersProvider).value;
    if (data == null || !mounted) {
      notifier.cancelRequest();
      return;
    }

    switch (selection) {
      case SelPoint(:final id):
        final cur = data.points
            .where((p) => p.id == id && p.domain == selection.domain)
            .firstOrNull;
        final out = await showPointForm(
          context,
          initialFloors: cur?.floors,
          currentFloor: ref.read(currentFloorProvider),
          canDelete: true,
        );
        if (out == null) {
          notifier.cancelRequest();
        } else if (out.deleted) {
          await notifier.deleteSelection();
        } else if (out.result case final r?) {
          await notifier.savePoint(id, selection.domain, r.floors);
        } else {
          notifier.cancelRequest();
        }

      case SelLine(:final id):
        final cur = data.linesByRef[(selection.domain, id)];
        final out = await showLineForm(
          context,
          title: '线属性',
          subtitle: '材质只属界线、路宽只属路线（由这条线所在的图层决定）',
          initial: cur,
          currentFloor: ref.read(currentFloorProvider),
          canDelete: true,
        );
        if (out == null) {
          notifier.cancelRequest();
        } else if (out.deleted) {
          await notifier.deleteSelection();
        } else if (out.result case final r?) {
          await notifier.saveLineProps(
            id,
            name: r.name,
            domain: r.domain,
            floors: r.floors,
            boundaryType: r.boundaryType,
            routeWidth: r.routeWidth,
            oneWay: r.oneWay,
            note: r.note,
          );
          await _warnIfCrossingUnlinked(id, r.routeWidth, data);
        }

      case SelArea(:final id):
        final cur = data.areas
            .where((a) => a.area.id == id && a.domain == selection.domain)
            .map((a) => a.area)
            .firstOrNull;
        final res = await showAreaForm(
          context,
          title: '区域属性',
          subtitle: '类型决定寻路怎么对待它（道路可走 / 小区只能走门 / 阻隔谁都别想穿）',
          initial: cur,
          initialDomain: selection.domain,
          currentFloor: ref.read(currentFloorProvider),
        );
        if (res == null) {
          notifier.cancelRequest();
        } else {
          await notifier.saveAreaProps(
            id,
            domain: selection.domain,
            name: res.name,
            type: res.type,
            floors: res.floors,
          );
        }

      case SelPlate(:final id):
        final f = data.entities.where((e) => e.id == id).firstOrNull;
        if (f == null || f.lineId == null) {
          notifier.cancelRequest();
          return;
        }
        final lineId = f.lineId!;
        final line = data.linesByRef[(MapDomain.world, lineId)];
        final lineName = line?.displayName ?? '线 #$lineId';
        // 编辑已有要素时不改位置：位置由"在哪条线上点"决定，想换位置就在线上重新点一个。
        //
        // v12：**墙体段没有了**（D5），所以这里只剩店铺一条支路。
        {
          final out = await showShopForm(
            context,
            lineName: lineName,
            center: f.center,
            initial: f,
          );
          if (out == null) {
            notifier.cancelRequest();
          } else if (out.deleted) {
            await notifier.deleteLineFeature(id);
          } else if (out.result case final r?) {
            await notifier.saveLineFeature(
              type: EntityType.shop,
              lineId: lineId,
              id: id,
              name: r.name,
              desc: r.desc,
              doorNo: r.doorNo,
              width: r.width,
            );
          }
        }

      case SelGate(:final id):
        final gate = data.gates.where((g) => g.id == id).firstOrNull;
        notifier.cancelRequest();
        if (gate != null) await _showGateDetail(gate);
    }
  }

  // -------------------------------------------------------------------------
  // 导入层：渲染 / 单要素带入（M2b/M2c）
  // -------------------------------------------------------------------------

  List<Widget> _buildImportLayers(ImportLayerView view, ImportVisibility vis) {
    if (vis.nothingVisible) return const [];
    final domains = <Widget>[];
    // 按当前缩放档位过滤（与 ImportLayerZoomPolicy 同步）。**绘制层兜底**：
    // 即使 queryImportLayer 已经按 zoomLevel 在 DB 层过滤过，UI 这边再
    // 过一次条件，避免远景档在 GPU 上堆几千条 Polyline。
    final policy = ImportLayerZoomPolicy.forZoom(ref.read(mapZoomProvider));
    // 建筑（浅灰面）——需先于道路
    if (vis.buildings && policy.showBuildings) {
      final polys = <Polygon>[];
      for (final w in view.ways.where((w) => w.isArea)) {
        final pts = w.coords.map((c) => LatLng(c.lat, c.lng)).toList();
        if (pts.length >= 3) {
          polys.add(
            Polygon(
              points: toClockwiseRing(w.coords)
                  .map((c) => LatLng(c.lat, c.lng))
                  .toList(),
              color: const Color(0x22000000),
              borderColor: const Color(0x44000000),
              borderStrokeWidth: 1,
            ),
          );
        }
      }
      domains.add(PolygonLayer(polygons: polys));
    }
    // 道路（细蓝线，骑行/推行深浅）
    if (vis.roads) {
      final lines = <Polyline>[];
      // 远景档（≤13）只画主干路；中景档（14）全画但隐藏 walk；近景档全画。
      for (final w in view.ways.where((w) => w.kind.storage == 'road')) {
        if (!policy.showAllRoads &&
            w.costClass != 'cycleway' &&
            w.costClass != 'trunk') {
          continue;
        }
        if (!policy.showWalkRoads && w.costClass == 'walk') {
          continue;
        }
        lines.add(
          Polyline(
            points: w.coords.map((c) => LatLng(c.lat, c.lng)).toList(),
            color: w.costClass == 'walk'
                ? const Color(0xAA26A69A)
                : const Color(0xAA1565C0),
            strokeWidth: 2.5,
          ),
        );
      }
      domains.add(PolylineLayer(polylines: lines));
    }
    // POI（小圆点）
    if (vis.pois) {
      final markers = <Marker>[];
      for (final poi in view.pois) {
        // 中景档：要求 POI 必须带 name（远景档 DB 已过滤；近景档不过滤）。
        if (policy.poiNameRequired && (poi.name == null || poi.name!.isEmpty)) {
          continue;
        }
        markers.add(
          Marker(
            point: LatLng(poi.lat, poi.lng),
            width: 12,
            height: 12,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0xBBF9A825),
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      }
      domains.add(MarkerLayer(markers: markers));
    }
    return domains;
  }

  /// 点中一条导入路 → 确认"以这条路建立我的路网"。
  Future<void> _offerAdoptWay(ImportWayView way) async {
    if (!mounted) return;
    final adopt = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('建立我的路网'),
        content: Text(
          '把 OSM 路段「${way.name ?? 'way ${way.osmId}'}」复制为我的路网边？\n'
          '（复制后为独立数据，可再编辑属性/删除）',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('带入'),
          ),
        ],
      ),
    );
    if (adopt != true || !mounted) return;
    final repo = ref.read(repositoryProvider);
    await repo.adoptWay(way);
    ref.invalidate(mapLayersProvider);
    if (mounted) _toast('已建立我的路网边（来源 OSM way ${way.osmId}）');
  }

  /// 点中一个 POI → 确认"加入我的常送点"。
  Future<void> _offerAdoptPoi(ImportPoiView poi) async {
    if (!mounted) return;
    final adopt = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('加入我的常送点'),
        content: Text(
          '把「${poi.name ?? 'OSM POI ${poi.osmId}'}」复制为常送点？\n'
          '（复制后为独立数据，可编辑备注/删除）',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('加入'),
          ),
        ],
      ),
    );
    if (adopt != true || !mounted) return;
    final repo = ref.read(repositoryProvider);
    await repo.adoptPoi(poi);
    ref.invalidate(mapLayersProvider);
    if (mounted) _toast('已加入常送点（来源 OSM node ${poi.osmId}）');
  }

  // -------------------------------------------------------------------------
  // 选中要素面板
  // -------------------------------------------------------------------------

  Widget _buildSelectionPanel(
    AsyncValue<MapLayersData> domains,
    EditState edit,
  ) {
    final data = domains.value;
    final sel = edit.selection;
    if (data == null || sel == null) return const SizedBox.shrink();
    final notifier = ref.read(editModeProvider.notifier);

    switch (sel) {
      case SelArea(:final id):
        final aw = data.areas.where((a) => a.area.id == id).firstOrNull;
        if (aw == null) return const SizedBox.shrink();
        // 门挂在线上，所以"这个区域有几个门" = 它的线上有几个门
        final gatesOfArea = data.gates
            .where((g) => g.lineId != null && aw.area.lineIds.contains(g.lineId))
            .toList();
        final lineCount = aw.area.lineIds.length;
        return _FeaturePanel(
          title: aw.area.name,
          color: Color(aw.area.color),
          subtitle: '${aw.area.areaType.label} · '
              '线 $lineCount 条 · 门 ${gatesOfArea.length} 个',
          hint: '${aw.area.areaType.hint}｜'
              '原地再点一次可切换到压在它下面的线或点',
          onDeselect: () => notifier.select(null),
          actions: [
            _PanelAction(
              icon: Icons.edit_outlined,
              label: '改属性',
              onTap: notifier.editSelected,
            ),
            _PanelAction(
              icon: Icons.door_front_door_outlined,
              label: '加门',
              onTap: () {
                if (!edit.active) notifier.enter();
                notifier.setTool(EditTool.gate);
              },
            ),
            _PanelAction(
              icon: Icons.delete_outline,
              label: '删除',
              danger: true,
              onTap: () => unawaited(notifier.deleteSelection()),
            ),
          ],
        );

      case SelLine(:final id, :final domain):
        final line = data.linesByRef[(domain, id)];
        if (line == null) return const SizedBox.shrink();
        final features = placeFeaturesOnLine(
          line: line,
          pointsById: data.pointsOf(line.domain),
          entities: data.entities,
        );
        final shops = features.where((p) => p.feature.isShop).length;
        final owners = data.areas
            .where(
              (a) => a.domain == line.domain && a.area.lineIds.contains(id),
            )
            .map((a) => a.area.name)
            .toList();
        // 折线信息（18 章）：顶点数 + 全长。有了它，用户才能一眼确认
        // "这条我画的路线到底拐了几个弯、绕了多远"。
        final linePath = polylineOf(line, data.pointsOf(line.domain));
        final shape = linePath == null
            ? ' · 顶点数据缺失，画不出来'
            : ' · ${line.isBent ? '折线 ${line.pointCount} 个顶点' : '直线段'}'
                  ' · 全长 ${pathLengthMeters(linePath).round()} m';
        return _FeaturePanel(
          title: line.displayName,
          color: line.domain == MapDomain.way
              // 路线按**路宽**取色（与地图上的线一致，19 章）
              ? Color(line.routeWidth?.defaultColor ?? 0xFF1E88E5)
              : (line.boundaryType == null
                    ? const Color(0xFF546E7A)
                    : Color(line.boundaryType!.defaultColor)),
          subtitle: '${line.domain.label}'
              // 属性按域只显示**这一个**（19 章：材质是界线的、路宽是路线的）
              '${_lineAttrText(line)}'
              ' · 店铺 $shops 个'
              '$shape'
              '${owners.isEmpty ? '' : ' · 属于 ${owners.join('、')}'}',
          hint: owners.length > 1
              ? '这条线被 ${owners.length} 个区域共用，改它会同时影响它们'
              : null,
          // 线和它围出的区域叠在一起是常态，提一句循环切换的存在；
          // 折线的拐点本身就是点，所以"改形状"有两条路：
          // 精确地拖某个顶点（选择工具长按拖动），或者**加一个新拐点**（下面的按钮）。
          footer: line.isBent
              ? '拐点也是点：长按拖动现成的拐点改形状；要新加一个弯用下面的「加拐点」。'
                    '（想选它围出的区域？在原地再点一次即可切换）'
              : '想选它围出的区域？在原地再点一次即可切换',
          onDeselect: () => notifier.select(null),
          actions: [
            _PanelAction(
              icon: Icons.edit_outlined,
              label: '改属性',
              onTap: notifier.editSelected,
            ),
            // 加拐点：三种线都有（形状操作与类型无关，18 章起三种线都是折线）
            _PanelAction(
              icon: Icons.timeline,
              label: '加拐点',
              onTap: () {
                // 清掉上一次留在 notifier 里的鼠标位置：不然一进模式就会在
                // 那个旧位置上先画出一个预览，看着像是"它自己长了个拐点"。
                _bendHover.value = null;
                notifier.startAddBend(id);
              },
            ),
            // 店铺/墙体挂在「世界图」的线上（它们的定位靠线的中心坐标与材质）。
            // 面板上的动作**按这条线所属的图层**给（20 章）：
            // 路线的面板上出现"加店铺"就是错的 —— 那是另一层的事。
            // 店铺挂在**世界图的界线**上（面板动作按这条线所属的域给，20 章）。
            // v12：**「加墙体」没有了**（D5：墙体段删除）—— "这段是墙"由线的
            // 材质（`boundary_type`）表达，不该往线上再挂一个要素。
            if (line.domain == MapDomain.world) ...[
              _PanelAction(
                icon: Icons.storefront_outlined,
                label: '加店铺',
                onTap: () {
                  if (!edit.active) notifier.enter();
                  notifier.setTool(EditTool.shop);
                },
              ),
            ],
            _PanelAction(
              icon: Icons.delete_outline,
              label: '删除',
              danger: true,
              onTap: () => unawaited(notifier.deleteSelection()),
            ),
          ],
        );

      case SelPlate(:final id):
        final f = data.entities.where((e) => e.id == id).firstOrNull;
        if (f == null) return const SizedBox.shrink();
        final lineId = f.lineId;
        final line = lineId == null
            ? null
            : data.linesByRef[(MapDomain.world, lineId)];
        // 位置与宽度都按**折线**算（18 章）：只拿首尾两点的话，
        // 一条拐弯的街上，面板里的"在线上的 x%"和宽度占比都会与实际不符。
        final path = line == null
            ? null
            : polylineOf(line, data.pointsOf(line.domain));
        final placed = path == null ? null : placeFeatureOnPath(f, path);
        return _FeaturePanel(
          title: f.displayName,
          // v12：要素只剩店铺一类（墙体段删除），所以颜色不再需要分叉
          color: const Color(0xFF00695C),
          subtitle: describeLineFeature(
            f,
            placement: placed == null ? null : describePlacement(placed),
            widthText: path == null
                ? null
                : describeWidthOnPath(f.effectiveWidth, path),
          ),
          hint: line == null ? null : '所属线：${line.displayName}',
          footer: placed?.snapped == true
              ? '中心点不在线上，渲染时已吸附到最近点'
              : null,
          onDeselect: () => notifier.select(null),
          actions: [
            _PanelAction(
              icon: Icons.edit_outlined,
              label: '编辑',
              onTap: notifier.editSelected,
            ),
            _PanelAction(
              icon: Icons.delete_outline,
              label: '删除',
              danger: true,
              onTap: () => unawaited(notifier.deleteLineFeature(id)),
            ),
          ],
        );

      case SelPoint(:final id, :final domain):
        final pt = data.points
            .where((p) => p.id == id && p.domain == domain)
            .firstOrNull;
        if (pt == null) return const SizedBox.shrink();
        // v12：几何点**只有坐标与楼层**（D9 去掉了 name，也没有 kind/source/
        // processed/accuracy）——「这个点是干什么用的」由它落在哪个域表达，
        // "处理状态"与"来源"属于**记录点**（world_marks，那是另一张表、另一套面板）。
        //
        // "连着几条线"要**把拐点也算进去**（18 章）：一个只当拐点的点，
        // 按端点去数会得到 0，用户会以为它是个孤点，删了却毁掉一条路。
        final touching = data.lines
            .where((l) => l.domain == domain && l.hasPoint(id))
            .toList();
        final asBend = touching.where((l) => l.bendPointIds.contains(id)).length;
        return _FeaturePanel(
          title: '点 #$id',
          color: Color(domain.defaultColor),
          subtitle: '${domain.label} · ${(pt.floors ?? FloorSet.ground).label}'
              ' · 连着 ${touching.length} 条线'
              '${asBend == 0 ? '' : '（其中 $asBend 条是拐点）'}',
          hint: '编辑模式下可以直接拖动这个点来挪墙角',
          onDeselect: () => notifier.select(null),
          actions: [
            _PanelAction(
              icon: Icons.delete_outline,
              label: '删除',
              danger: true,
              onTap: () => unawaited(notifier.deleteSelection()),
            ),
          ],
        );

      case SelGate(:final id):
        final gate = data.gates.where((g) => g.id == id).firstOrNull;
        if (gate == null) return const SizedBox.shrink();
        return _FeaturePanel(
          title: gate.displayName,
          color: const Color(0xFF2E7D32),
          subtitle: '${gate.vehicleType.label} · ${gate.accessLevel.label}',
          onDeselect: () => notifier.select(null),
          actions: [
            _PanelAction(
              icon: Icons.info_outline,
              label: '详情',
              onTap: () => unawaited(_showGateDetail(gate)),
            ),
            _PanelAction(
              icon: Icons.delete_outline,
              label: '删除',
              danger: true,
              onTap: () => unawaited(notifier.deleteSelection()),
            ),
          ],
        );
    }
  }

  // -------------------------------------------------------------------------
  // 图层
  // -------------------------------------------------------------------------

  /// 用户层全量渲染（v4）：
  /// 区域蒙层 → 线（按材质上色） → 点 → 墙体段 → 店铺标签 → 门旗标。
  ///
  /// 顺序即绘制层级：面在最下，其次线、墙体段、点、店铺文字，门旗标在最上（最要紧）。
  List<Widget> _buildSavedLayers(MapLayersData data, EditState edit) {
    final widgets = <Widget>[];
    final selected = edit.selection;
    // 按域取点坐标（**别在逐线循环里重建 Map** —— 那会变成 O(线数 × 点数)）。
    // 线的几何一律用 `data.pointsOf(line.domain)`：三个域的自增 id 是独立的，
    // 混用会拿另一层的点去拼形状。
    Map<int, GeoPoint> ptsOf(LineRow l) => data.pointsOf(l.domain);

    // 编辑模式下用了「非选择」工具时，要素上的 Marker 必须**让开点击**：
    // 否则用户想用「连线」工具点一个点当作端点，手指正好落在那个点的小圆点上，
    // Marker 自己的 onTap 会把事件吃掉，变成"选中了这个点"，
    // 地图的 onTap 根本收不到 → 连线永远连不起来。onTap 给 null 时
    // GestureDetector 不注册 tap 识别器，事件自然落到地图上。
    //
    // 「加拐点」模式同理（20 章）：那时一次点按的含义是"拐点就放这里"，
    // 若被线上的 Marker 吃掉，用户会发现"点了半天拐点一个没加"。
    final passthrough =
        edit.active && (edit.tool != EditTool.browse || edit.addingBend);
    final prefs = ref.watch(displayPrefsProvider);
    final floor = ref.watch(currentFloorProvider);
    // 「拉折线」工具下把点画大一圈：明确告诉用户"这些就是能吸附的靶子"。
    // 三个折线工具（界线/路线/行政线）都要，否则行政线那一个用起来手感突变。
    final emphasizePoints =
        edit.active &&
        (edit.tool == EditTool.boundaryLine ||
            edit.tool == EditTool.routeLine ||
            edit.tool == EditTool.adminLine);

    // ---- 1. 区域蒙层（颜色按 areaType；选中的加黄色外描边）----
    final polygons = <Polygon>[];
    for (final aw in data.areas) {
      final ring = aw.ring;
      if (ring == null || ring.length < 3) continue;
      // 虚拟区域（行政区域）可以被整体关掉：它不是世界实体，
      // 做别的活时不想让它占着屏幕。
      if (aw.domain.isVirtual && !prefs.showAdministrative) continue;
      // 楼层过滤（第十七章）：只看参与构成当前层的区域
      if (!(aw.area.floors ?? FloorSet.ground).visibleOn(floor)) continue;
      final isSelected = selected is SelArea && selected.id == aw.area.id;
      final color = Color(aw.area.color);
      final virtual = aw.domain.isVirtual;
      polygons.add(
        Polygon(
          points: toClockwiseRing(ring).map((p) => LatLng(p.lat, p.lng)).toList(),
          // 虚拟区域：填充更淡（它是"背景分区"，不是障碍）
          // 虚拟区域填充更淡（它是"背景分区"，不是障碍）。
          // v12 去掉了 is_active 列，所以实体区域固定 0.12。
          color: color.withValues(alpha: virtual ? 0.05 : 0.12),
          borderColor: isSelected ? const Color(0xFFFFC107) : color,
          borderStrokeWidth: isSelected ? 5 : (virtual ? 1.5 : 2),
          // 虚线是"这是虚拟的"最直观的表达：一眼就知道它不挡路
          pattern: virtual
              ? StrokePattern.dashed(segments: const [14, 8])
              : const StrokePattern.solid(),
        ),
      );
    }
    widgets.add(PolygonLayer(polygons: polygons));

    // ---- 2. 线（材质决定颜色；不可穿越的线更粗）----
    //
    // 第十八章起一条线是**折线**：画的是它的**全部顶点**（起点 → 拐点… → 终点）。
    // 以前只连首尾两点，一条拐了弯的路会被画成一条穿过街区的直线 ——
    // 不报错、不崩溃，就是"看着像那么回事、照着走不通"，最坏的一种错。
    final polylines = <Polyline>[];
    // 换路口的小旗标（21 章）：一条换路口只有几米长，在 zoom 15 下不到 2 像素，
    // 光靠那条粉线用户**看不见也点不中**。所以额外给它的中点放一个小旗标 ——
    // 它既是"这里有换路口"的提示，也是这一小段线的可点区域。
    final crossingMarkers = <Marker>[];
    for (final l in data.lines) {
      final path = polylineOf(l, ptsOf(l));
      if (path == null) continue;
      final isSelected = selected is SelLine && selected.id == l.id;
      // 界线与路线**同时渲染但各自成风格**（14 章：两者独立运作）：
      //   界线 = 围合区域的边，按**材质**上色、偏粗、实线感；
      //   路线 = 自己走的路，按**路宽**上色与定粗细（19 章）：
      //          大马路粗、窄巷细、天桥画虚线（它在空中，不在地面上）。
      // 这样一眼就能分清"这堵墙"和"我常走的那条路"，还看得出那条路是什么路。
      if (l.domain.isVirtual && !prefs.showAdministrative) continue;
      // 楼层过滤
      if (!(l.floors ?? FloorSet.ground).visibleOn(floor)) continue;
      final Color base;
      final double width;
      final StrokePattern pattern;
      switch (l.domain) {
        case MapDomain.world:
          base = l.boundaryType == null
              ? const Color(0xFF546E7A) // 未指定材质：中性蓝灰
              : Color(l.boundaryType!.defaultColor);
          width = 3.5;
          pattern = const StrokePattern.solid();
        case MapDomain.way:
          // 未指定路宽 → 沿用老的统一蓝（不强迫用户先分类才能画路）
          final rw = l.routeWidth;
          base = rw == null ? const Color(0xFF1E88E5) : Color(rw.defaultColor);
          width = rw?.strokeWidth ?? 2.5;
          pattern = (rw?.isBridge ?? false)
              ? StrokePattern.dashed(segments: const [10, 6])
              : const StrokePattern.solid();
        case MapDomain.zone:
          // 虚拟线：细 + 虚线，视觉上明确"这不是墙也不是路"
          base = const Color(0xFF00838F);
          width = 1.5;
          pattern = StrokePattern.dashed(segments: const [12, 8]);
      }
      polylines.add(
        Polyline(
          points: [for (final g in path) LatLng(g.lat, g.lng)],
          color: isSelected ? const Color(0xFFFFC107) : base,
          strokeWidth: isSelected ? 6 : width,
          pattern: pattern,
        ),
      );
      if (l.routeWidth?.isCrossing == true && l.id != null) {
        final mid = midpointOfPath(path);
        final sel = selected is SelLine && selected.id == l.id;
        crossingMarkers.add(
          Marker(
            point: LatLng(mid.lat, mid.lng),
            width: 30,
            height: 30,
            child: GestureDetector(
              onTap: passthrough
                  ? null
                  : () => ref
                        .read(editModeProvider.notifier)
                        .select(SelLine(l.domain, l.id!)),
              child: _CrossingBadge(
                color: Color(l.routeWidth!.defaultColor),
                selected: sel,
              ),
            ),
          ),
        );
      }
    }
    widgets.add(PolylineLayer(polylines: polylines));
    if (crossingMarkers.isNotEmpty) {
      widgets.add(MarkerLayer(markers: crossingMarkers));
    }

    // ---- 3. 点（无名字的小圆点；有名字的带标签）----
    //
    // **点的显示有三道过滤**（第二十二章，用户要求："非编辑状态不要显示点"、
    // "编辑状态太稠密了"）：
    //   ① 浏览态（不在编辑模式）：只留"记录录入且未处理"的点 ——
    //      画图用的那 686 个顶点一个都不显示；
    //   ② 编辑态：zoom < 15 一个点都不画（那几级上一屏 661~686 个点，纯点墙）；
    //   ③ 编辑态：zoom ≥ 15 时按**屏幕 24 px 网格**抽稀，每格最多画 1 个。
    //      "手上的点"（选中的 / 折线草稿的顶点）永远画 —— 正在编辑的东西
    //      不能在眼皮底下消失；记录模式下未处理的记录点也不藏（正在采）。
    final zoom = ref.watch(mapZoomProvider);
    final keepIds = alwaysShowIds(
      selectedPointId: selected is SelPoint ? selected.id : null,
      draftPointIds: edit.lineDraftPointIds,
    );
    final visiblePoints = _visiblePoints(
      data.points,
      edit: edit,
      zoom: zoom,
      keepIds: keepIds,
      floor: floor,
    );
    final pointMarkers = <Marker>[];
    for (final pt in visiblePoints) {
      final id = pt.id;
      if (id == null) continue;
      final isSelected =
          selected is SelPoint && selected.id == pt.id;
      // v12：几何点**没有名字**（D9）—— 要命名就用世界域的要素。
      // 于是渲染不再需要"长名字用大 Marker / 画标签"那一支。
      // 编辑模式下顶点可以**长按拖动**（改墙角位置最直接的方式）。
      // 用长按而不是直接 pan：flutter_map 自己也在抢 drag 手势，
      // 长按是它不会碰的，冲突最小。
      final draggable = edit.active && edit.tool == EditTool.browse;
      final big = draggable || emphasizePoints;
      pointMarkers.add(
        Marker(
          point: LatLng(pt.lat, pt.lng),
          width: big ? 34 : 14,
          height: big ? 34 : 14,
          child: GestureDetector(
            onTap: passthrough
                ? null
                : () => ref
                      .read(editModeProvider.notifier)
                      .select(SelPoint(pt.domain, id)),
            onLongPressStart: draggable
                ? (_) => _toast('拖动中…松手即定位')
                : null,
            onLongPressMoveUpdate: draggable
                ? (d) => unawaited(_dragPoint(id, d.globalPosition))
                : null,
            onLongPressEnd: draggable
                ? (d) => unawaited(
                    _dragPoint(id, d.globalPosition, force: true),
                  )
                : null,
            child: Center(
              child: _PointDot(
                domain: pt.domain,
                selected: isSelected,
                emphasized: emphasizePoints,
              ),
            ),
          ),
        ),
      );
    }

    // ---- 记录点（world_marks）：**浏览态显示的就是它**（22 章）----
    //
    // 规则一句话：`!processed`。它有自己的表之后，这条判据不再需要"猜 source"。
    // 编辑态也画未处理的（记录完还要接着处理它），处理过的只在记录模式里画。
    for (final m in data.marks) {
      final id = m.id;
      if (id == null) continue;
      if (!(m.floors ?? FloorSet.ground).visibleOn(floor)) continue;
      if (edit.active && m.processed) continue;
      pointMarkers.add(
        Marker(
          point: LatLng(m.lat, m.lng),
          width: 26,
          height: 26,
          child: GestureDetector(
            onTap: passthrough
                ? null
                : () => _toast(
                    '${m.displayName}${m.byGps ? '（定位记录）' : ''}'
                    '${m.processed ? ' · 已处理' : ' · 未处理'}',
                  ),
            child: Center(
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: const Color(0xFF00ACC1),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
              ),
            ),
          ),
        ),
      );
    }
    widgets.add(MarkerLayer(markers: pointMarkers));

    // ---- 4. 世界要素：店铺标签（挂在线上的那些）----
    //
    // 定位规则（13 章）：**先看要素自己的中心点**；中心点不在线上时，
    // 取线上离它最近的点。不再按权重沿线排布 —— 那样改一个店铺的宽度，
    // 整条街的位置都会跟着挪。
    //
    // v12：这里只剩店铺一类（墙体段删除，D5）。
    final shopMarkers = <Marker>[];
    for (final line in data.lines) {
      if (line.id == null) continue;
      // 顶点不全（有拐点的坐标查不到）→ 这条线的几何不可信，
      // 那它上面挂的店铺/墙体也不该画在一个猜出来的位置上。
      final linePath = polylineOf(line, ptsOf(line));
      if (linePath == null) continue;
      if (!(line.floors ?? FloorSet.ground).visibleOn(floor)) continue;
      final placedList = placeFeaturesOnLine(
        line: line,
        pointsById: ptsOf(line),
        entities: data.entities,
      );
      for (final placed in placedList) {
        final f = placed.feature;
        if (f.id == null) continue;

        // v12：**墙体段没有了**（D5）—— "这段是墙"由线的材质表达，
        // 不再往线上挂一个要素，所以这里也没有"画粗那一段"的分支了。
        if (!prefs.showShops) continue;
        final isSel = selected is SelPlate && selected.id == f.id;
        shopMarkers.add(
          Marker(
            point: LatLng(placed.position.lat, placed.position.lng),
            width: 112,
            height: 28,
            child: GestureDetector(
              onTap: passthrough
                  ? null
                  : () => ref
                        .read(editModeProvider.notifier)
                        .select(SelPlate(MapDomain.world, f.id!)),
              child: _ShopChip(
                label: f.doorNo == null || f.doorNo!.isEmpty
                    ? f.name
                    : '${f.doorNo} ${f.name}'.trim(),
                selected: isSel,
              ),
            ),
          ),
        );
      }
    }
    widgets.add(MarkerLayer(markers: shopMarkers));

    // ---- 5. 门：**和店铺一样定位到吸附的线上**（第十五章）----
    //
    // 先按线取"已定位的门"，再补上那些没挂线的老门（它们只能画在中心点上）。
    final gateMarkers = <Marker>[];
    final placedGateIds = <int>{};
    for (final line in data.lines) {
      if (line.id == null) continue;
      // 门的楼层**跟随它吸附的线**：墙只在 1 层，墙上的门自然也不该出现在 2 层。
      // （门自己不带楼层属性 —— 用户这轮只要求给点/线/面加。）
      if (!(line.floors ?? FloorSet.ground).visibleOn(floor)) continue;
      final placed = placeGatesOnLine(
        line: line,
        pointsById: ptsOf(line),
        gates: data.gates,
      );
      for (final pg in placed) {
        final g = pg.gate;
        if (g.id == null) continue;
        placedGateIds.add(g.id!);
        gateMarkers.add(_gateMarker(g, pg.position, selected, passthrough, pg.snapped));
      }
    }
    for (final g in data.gates) {
      if (g.id == null || placedGateIds.contains(g.id)) continue;
      // 没挂线的门没有可以跟随的层，任何楼层都画出来（宁可多画也别让它消失）
      gateMarkers.add(_gateMarker(g, g.center, selected, passthrough, false));
    }
    widgets.add(MarkerLayer(markers: gateMarkers));
    return widgets;
  }

  /// 算出这一刻**真正要画**的点（第二十二章的三道过滤）。
  ///
  /// 抽成方法而不是写在渲染循环里，是为了让"到底画了几个"这句话**有处可查**：
  /// 过滤规则本身在 `core/point_density.dart`（纯 Dart），
  /// 这里只负责把当前的模式/缩放/楼层喂进去。
  List<PointRow> _visiblePoints(
    List<PointRow> all, {
    required EditState edit,
    required double zoom,
    required Set<int> keepIds,
    required int floor,
  }) {
    // 楼层过滤对所有模式一视同仁（它说的是"这个点属不属于我现在看的这层"）
    bool onFloor(PointRow p) =>
        (p.floors ?? FloorSet.ground).visibleOn(floor);

    // ① 浏览态：**几何点一个都不显示**。
    //
    // 22 章那句话在 v12 变得非常直白：几何点是"拼线/拼面的材料"（画图中间产物），
    // 浏览态该显示的是**记录点**（`world_marks`）—— 那是另一张表、另一条渲染支路
    // （见下面 `data.marks` 那一段）。所以这里直接空掉，不需要再靠 source 去猜。
    if (!edit.active) return const [];

    // 浏览/编辑都不变的一条：选中的点与草稿顶点永远画
    final kept = [
      for (final p in all)
        if (onFloor(p) && (p.id != null && keepIds.contains(p.id))) p,
    ];

    // ② 记录模式：正在采的点不能藏起来 —— 但 v12 起记录点落在 `world_marks`
    // （不走这条几何点支路），所以这里没有需要额外豁免的东西。
    if (edit.recording) return kept;

    // ③ 普通编辑态：缩放阈值 + 像素网格抽稀
    if (!bulkPointsVisibleAtZoom(zoom)) return kept;
    final thinned = thinPointsByGrid(
      [for (final p in all) if (onFloor(p)) p],
      zoom: zoom,
      alwaysShow: {for (final p in kept) if (p.id != null) p.id!},
    );
    return thinned;
  }

  /// 门旗标。颜色按**类型 + 门禁**给：楼梯口/建筑门/园区门各一色，
  /// 需刷卡/登记的叠一个感叹号。时间管制已移除，所以不再随"现在几点"变化。
  Marker _gateMarker(
    GateRow g,
    GeoPoint at,
    EditSelection? selected,
    bool passthrough,
    bool snapped,
  ) {
    final eval = evaluateGate(
      GateEvalInput(vehicleType: g.vehicleType, accessLevel: g.accessLevel),
    );
    final isSel = selected is SelGate && selected.id == g.id;
    return Marker(
      point: LatLng(at.lat, at.lng),
      width: 40,
      height: 40,
      child: GestureDetector(
        onTap: passthrough ? null : () => _showGateDetail(g),
        child: _GateFlag(
          status: eval.status,
          label: g.displayName,
          type: g.gateType,
          selected: isSel,
          snapped: snapped,
        ),
      ),
    );
  }

  Future<void> _showGateDetail(GateRow g) async {
    final eval = evaluateGate(
      GateEvalInput(vehicleType: g.vehicleType, accessLevel: g.accessLevel),
    );
    // 门挂在线上，所以"属于哪些区域" = 这条线被哪些区域引用
    final data = ref.read(mapLayersProvider).value;
    final owners = <String>[];
    if (data != null && g.lineId != null) {
      for (final aw in data.areas) {
        if (aw.area.lineIds.contains(g.lineId)) owners.add(aw.area.name);
      }
    }
    final ownerText = owners.isEmpty ? '（这条线还没被任何区域引用）' : owners.join('、');
    if (!mounted) return;
    final delete = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(g.displayName, style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text('类型：${g.gateType.label}'),
              Text('状态：${eval.status.label}（${eval.message}）'),
              Text('车型：${g.vehicleType.label} · 门禁：${g.accessLevel.label}'),
              Text('属于：$ownerText'),
              if (g.note != null) Text('备注：${g.note}'),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('关闭'),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(ctx).colorScheme.error,
                    ),
                    onPressed: () => Navigator.of(ctx).pop(true),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('删除此门'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (delete == true && mounted) {
      await ref.read(repositoryProvider).softDeleteGate(g.id!);
      ref.invalidate(mapLayersProvider);
      if (mounted) _toast('门已删除');
    }
  }

  // -------------------------------------------------------------------------
  // 顶部工具条 / 状态条
  // -------------------------------------------------------------------------

  Widget _statusBar(
    BuildContext context,
    AsyncValue<MapLayersData> domains,
    AsyncValue<ImportLayerView?> importLayer,
    MapDataProgress? dataProgress,
    EditState edit,
    int floor,
  ) {
    // 编辑模式优先（不能让工具条被进度条抢走）。
    if (edit.active) {
      return _StatusCard(
        child: Row(
          children: [
            Icon(
              edit.recording ? Icons.fiber_manual_record : Icons.edit_location_alt,
              size: 18,
              color: edit.recording ? const Color(0xFFB71C1C) : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                edit.recording
                    ? '记录模式 · 点地图记录一个点 · $floor 层'
                    : '编辑模式 · ${edit.tool.label} · $floor 层',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            if (domains.value case final d?)
              Text(
                '点 ${d.points.length} · 线 ${d.lines.length} · '
                '区域 ${d.areas.length} · 店铺 ${d.shops.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      );
    }
    // 数据加载中：进度条 + 阶段文案。**这是用户最需要的反馈**，所以放在最前。
    if (dataProgress != null) {
      final isDone = dataProgress.phase == MapDataPhase.done;
      return _StatusCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    mapDataPhaseLabel(dataProgress.phase),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            // 当前 IO 命中点（monospace 细节行）：
            // 让用户一眼看出「具体卡在哪条 SQL / 哪个方法」，
            // 而不是只知道「正在打开本地数据库」。
            if (dataProgress.details != null) ...[
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.only(left: 26),
                child: Text(
                  dataProgress.details!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            // 阶段 filled：roads/pois/nodes 三个核心阶段各占 1/3 段（粗略让用户有 "在动" 的感觉）。
            // done 帧填满 100%；否则 indeterminate。
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 4,
                value: isDone ? 1.0 : _phaseToFraction(dataProgress.phase),
              ),
            ),
          ],
        ),
      );
    }
    // 导入层查询报错（少见）：单独提示，区块统计仍可显示。
    if (importLayer.hasError) {
      // 截断错误文本——sqflite 抛 DatabaseException 时 toString 可能含 query 全文 +
      // stack trace + binding values，单 Text 渲染会撑爆父容器高度（实测破 397k px）。
      final raw = importLayer.error.toString();
      final truncated = raw.length > 240 ? '${raw.substring(0, 240)}…' : raw;
      return _StatusCard(
        child: Text(
          '导入层加载失败: $truncated',
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.error),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    // 静态文案：拼接当前可见信息。
    final zoom = ref.watch(mapZoomProvider);
    final zoomLabel = '缩放 ${zoom.toStringAsFixed(1)}';
    final importSummary = (importLayer.value == null)
        ? '导入层未启用'
        : '导入层 ${importLayer.value!.ways.length} 路 / ${importLayer.value!.pois.length} POI';
    final message = domains.when(
      data: (d) =>
          '$zoomLabel · $floor 层 · 区域 ${d.areas.length} · '
          '线 ${d.lines.length} · 点 ${d.points.length} · '
          '店铺 ${d.shops.length} · 门 ${d.gates.length} · $importSummary',
      loading: () => '$zoomLabel · 加载用户数据… · $importSummary',
      error: (e, _) => '$zoomLabel · 用户数据加载失败: $e · $importSummary',
    );
    return _StatusCard(
      child: Text(message, style: Theme.of(context).textTheme.bodyMedium),
    );
  }

  /// 把 phase 映射到 0..1 的视觉填充（即使 indeterminate 也看起来"有进展"）。
  double? _phaseToFraction(MapDataPhase phase) {
    switch (phase) {
      case MapDataPhase.checking:
        return 0.08;
      case MapDataPhase.areas:
        return 0.25;
      case MapDataPhase.gates:
        return 0.45;
      case MapDataPhase.bounds:
        return 0.55;
      case MapDataPhase.importRoads:
        return 0.7;
      case MapDataPhase.importPois:
        return 0.85;
      case MapDataPhase.importNodes:
        return 0.95;
      case MapDataPhase.extractingPacks:
        return 0.7;
      case MapDataPhase.scanningPacks:
        return 0.15;
      case MapDataPhase.importingNote:
        return 0.95;
      case MapDataPhase.done:
        return 1.0;
    }
  }

  /// **记录模式**工具栏（第十四章）。
  ///
  /// 刻意做得比编辑模式简单得多：记录模式下只有一件事 —— 落点。
  /// 所以不摆那 10 个工具，只给「记哪一类」+「采当前位置」+ 计数。
  ///
  /// 「先选类别再连点」是有意的：跑单时常常要连着记同类的几个点
  /// （比如一条街上的三家店），每落一个点还要重选类别会很烦。
  Widget _recordToolbar(BuildContext context, EditState edit) {
    final theme = Theme.of(context);
    final notifier = ref.read(editModeProvider.notifier);
    final hasLocation = PlatformUtils.isLocationSupported();
    final pos = ref.watch(locationStateProvider);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.fiber_manual_record, size: 14, color: Color(0xFFB71C1C)),
                const SizedBox(width: 6),
                Text('记录模式', style: theme.textTheme.labelLarge),
                const Spacer(),
                if (hasLocation)
                  Text(
                    pos == null
                        ? '定位搜索中…'
                        : '±${pos.accuracy.toStringAsFixed(0)}m',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            // v12：记录模式**没有"类别"可选**了 —— 记录点就是记录点
            // （`world_marks`，有名字与"处理状态"）；"随手标的店铺/门"那两类
            // 现在由世界图要素与门表表达，不再从记录模式进。
            Row(
              children: [
                Expanded(
                  child: Text(
                    hasLocation
                        ? '点地图上任意位置，或按右边按钮采当前位置；'
                              '落点后可以立刻改名'
                        : '这个平台没有定位能力，点地图上要记录的位置即可',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: hasLocation
                      ? () => unawaited(notifier.recordCurrentLocation())
                      : null,
                  icon: const Icon(Icons.my_location, size: 18),
                  label: const Text('记录当前位置'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 编辑模式工具栏：**图层 → 工具 → 草稿操作** 三层（第十九章）。
  ///
  /// 布局刻意做成三层：
  ///   第一层是**图层切换**（路网 / 世界图 / 行政区域）—— 决定下面这排工具是什么；
  ///   第二层是**该图层里的工具**（只铺这一层的，不再把 11 个工具平铺）；
  ///   第三层是**当前工具的草稿状态与提交按钮**，只在有草稿时出现。
  /// 这样用户永远看得到"我在哪一层、我现在在干什么、下一步点什么"。
  ///
  /// 「加拐点」模式（20 章）下整个工具条换成**一条横幅**：那个模式里
  /// "点一下地图"的含义已经变了（放下拐点），把图层/工具 chip 摆在那里
  /// 只会让人误以为还能顺手切工具。
  Widget _editToolbar(
    BuildContext context,
    EditState edit,
    MapLayersData? data,
  ) {
    final notifier = ref.read(editModeProvider.notifier);
    final theme = Theme.of(context);
    final layerColor = Color(edit.layer.defaultColor);

    if (edit.addingBend) {
      return _bendModeToolbar(context, edit, data, notifier);
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---- 第一层：图层 ----
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final layer in MapDomain.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: ChoiceChip(
                        avatar: Icon(
                          _layerIcon(layer),
                          size: 18,
                          color: edit.layer == layer
                              ? Colors.white
                              : Color(layer.defaultColor),
                        ),
                        // 图层是**单选**（地图上一次只编一层），用 ChoiceChip；
                        // 三层都很短，不换行、可以横滑。
                        selected: edit.layer == layer,
                        selectedColor: Color(layer.defaultColor),
                        labelStyle: TextStyle(
                          fontWeight: edit.layer == layer
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: edit.layer == layer ? Colors.white : null,
                        ),
                        onSelected: (_) => notifier.setLayer(layer),
                        label: Text(layer.label),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            // ---- 第二层：该图层的工具 ----
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final tool in edit.toolsInLayer)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: ChoiceChip(
                        selected: edit.tool == tool,
                        onSelected: (_) => notifier.setTool(tool),
                        label: Text(tool.label),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                // 一行说明，按"你现在需要知道什么"切换：
                // 拿着「选择」= 还没决定干什么 → 讲这一层是什么；
                // 选了具体工具 → 讲这个工具怎么用。
                // 两句都摆出来的话工具条会长高一截，而屏幕上最要紧的是地图。
                edit.tool == EditTool.browse
                    ? '${edit.layer.label}：${edit.layer.hint}'
                    : edit.tool.hint,
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (edit.tool != EditTool.browse)
              Padding(
                padding: const EdgeInsets.only(top: 2, left: 2),
                child: Row(
                  children: [
                    if (edit.hasDraft)
                      TextButton.icon(
                        onPressed: notifier.undo,
                        icon: const Icon(Icons.undo, size: 18),
                        label: const Text('撤销'),
                      ),
                    if (edit.hasDraft)
                      TextButton.icon(
                        onPressed: notifier.cancelDraft,
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('取消'),
                      ),
                    const Spacer(),
                    _editToolPrimaryAction(context, edit, data, notifier),
                  ],
                ),
              ),
            // 图层色条：贴在卡片底部，让"我现在在哪一层"在余光里也能看出来
            // （工具栏文字小，画图时不会盯着读）。
            Container(
              height: 3,
              margin: const EdgeInsets.only(top: 4, left: 2, right: 2),
              decoration: BoxDecoration(
                color: layerColor.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 图层图标（图标属于 UI，不放进 `core` 的状态机里）。
  static IconData _layerIcon(MapDomain layer) => switch (layer) {
    MapDomain.way => Icons.alt_route,
    MapDomain.world => Icons.apartment,
    MapDomain.zone => Icons.public,
  };

  /// 「加拐点」模式下的工具条（第二十章）。
  ///
  /// 只留三样东西：**目标线是谁**、**怎么用**、**取消**。
  /// 目标线的名字要写清楚 —— 地图上可能有好几条线，用户得确认自己正在改哪一条。
  Widget _bendModeToolbar(
    BuildContext context,
    EditState edit,
    MapLayersData? data,
    EditModeController notifier,
  ) {
    final theme = Theme.of(context);
    final line = data?.linesByRef[(edit.layer, edit.bendTargetLineId)];
    const accent = Color(0xFFEF6C00);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: const Color(0xFFFFF3E0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.timeline, size: 18, color: accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '加拐点：${line?.displayName ?? '这条线'}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () {
                    _bendHover.value = null;
                    notifier.cancelAddBend();
                  },
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('取消'),
                ),
              ],
            ),
            Text(
              line == null
                  ? '这条线已经不在了，请先关掉这个模式'
                  : '把鼠标移到地图上：橙点跟着走，并实时画出"插进去之后"的折线；'
                        '点一下就放下。放完还留在这个模式里，可以接着加下一个弯。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  /// 工具栏右下角的主操作按钮（随工具变化）。
  Widget _editToolPrimaryAction(
    BuildContext context,
    EditState edit,
    MapLayersData? data,
    EditModeController notifier,
  ) {
    switch (edit.tool) {
      case EditTool.area:
        final status = notifier.ringStatus(data);
        final count = edit.ringLineIds.length;
        final ready = count >= 3 && status == null;
        return FilledButton.icon(
          onPressed: ready ? notifier.requestRingCommit : null,
          icon: const Icon(Icons.check),
          label: Text(
            count == 0
                ? '点线开始围合'
                : (status ?? '围合成区域（已选 $count 条）'),
          ),
        );
      case EditTool.polygon:
        return FilledButton.icon(
          onPressed: edit.canClosePolygon ? notifier.requestPolygonCommit : null,
          icon: const Icon(Icons.check),
          label: Text(
            edit.canClosePolygon
                ? '闭合为区域（${edit.polygonDraft.length} 个拐角）'
                : '还需 ${3 - edit.polygonDraft.length} 个拐角',
          ),
        );
      case EditTool.boundaryLine:
      case EditTool.routeLine:
      case EditTool.adminLine:
        final what = switch (edit.tool) {
          EditTool.boundaryLine => '界线',
          EditTool.routeLine => '路线',
          _ => '行政线',
        };
        final n = edit.lineDraftPointIds.length;
        if (n == 0) {
          return Text(
            '点按一个已有点作为$what 的起点',
            style: Theme.of(context).textTheme.bodySmall,
          );
        }
        // 已经能落库（≥2 个点）才给「完成」按钮：只点了一个点时按下去
        // 只会得到一句"至少点两个点"，不如干脆不让按。
        return FilledButton.icon(
          onPressed: edit.canFinishLineDraft ? notifier.finishLineDraft : null,
          icon: const Icon(Icons.check),
          label: Text(
            edit.canFinishLineDraft
                ? '完成$what（$n 个顶点）'
                : '再点一个点，就有 $what 了',
          ),
        );
      case EditTool.shop:
        return Text(
          '点按一条线，在线上加店铺',
          style: Theme.of(context).textTheme.bodySmall,
        );
      case EditTool.gate:
        return Text(
          '点按区块的边界线放置门',
          style: Theme.of(context).textTheme.bodySmall,
        );
      case EditTool.point:
        return Text(
          '点按地图落一个点',
          style: Theme.of(context).textTheme.bodySmall,
        );
      case EditTool.basemap:
        final importView = ref.watch(importLayerProvider).value;
        final vis = ref.watch(importVisibilityProvider);
        if (vis.nothingVisible) {
          return Text(
            '底图层是隐藏的，先用左下角开关打开',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          );
        }
        return Text(
          importView == null
              ? '底图加载中…'
              : '点底图上的路 / POI 带入（路 ${importView.ways.length} · '
                    'POI ${importView.pois.length}）',
          style: Theme.of(context).textTheme.bodySmall,
        );

      case EditTool.browse:
        return const SizedBox.shrink();
    }
  }

  /// 拖拽时的落库节流时间戳（毫秒）。
  ///
  /// 每次拖动都会 invalidate 整个图层 provider（十几条 SQL），
  /// 不节流的话拖动会明显掉帧。
  int _lastDragWriteMs = 0;

  /// 长按拖动一个顶点：把屏幕坐标换算成经纬度后写回 DB。
  ///
  /// 拖动过程中**边拖边落库**（而不是"松手才写"）是有意的：顶点很轻（一行 UPDATE），
  /// 松手才写需要额外的暂存状态与取消逻辑。但落库会连带刷新整个图层，
  /// 所以按 [_kDragThrottleMs] 节流，并在 [force] 时（拖动结束）补最后一下。
  Future<void> _dragPoint(
    int pointId,
    Offset globalPosition, {
    bool force = false,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!force && nowMs - _lastDragWriteMs < _kDragThrottleMs) return;
    _lastDragWriteMs = nowMs;

    final box = _mapKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPosition);
    final latLng = _mapController.camera.screenOffsetToLatLng(local);
    await ref
        .read(editModeProvider.notifier)
        .movePoint(
          ref.read(editModeProvider).layer,
          pointId,
          GeoPoint(latLng.latitude, latLng.longitude),
        );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }
}

/// 一条线的**属性摘要**（19 章：按类型只显示它真正拥有的那个属性）。
///
/// 以前这里不管什么线都显示"材质"，于是路线面板上会出现
/// "路线 · 实体墙"这种自相矛盾的组合 —— 材质是界线的属性，
/// 路线自己的属性是路宽。
String _lineAttrText(LineRow line) => switch (line.domain) {
  MapDomain.world =>
    line.boundaryType == null ? '' : ' · ${line.boundaryType!.label}',
  MapDomain.way =>
    ' · ${line.routeWidth?.label ?? '路宽未指定'}',
  // 行政线是虚拟的：既不构成墙也不构成路，两个属性都不适用
  MapDomain.zone => ' · 虚拟线',
};

/// 选中要素的底部面板：一个标题 + 若干操作按钮。
///
/// 点 / 线 / 区域 / 店铺 / 墙体 / 门 共用同一个外壳 —— 差异只在标题、
/// 颜色、副标题与按钮列表，各写一个卡片会让「选中后面板长什么样」失去一致性。
class _FeaturePanel extends StatelessWidget {
  const _FeaturePanel({
    required this.title,
    required this.color,
    required this.subtitle,
    required this.onDeselect,
    required this.actions,
    this.hint,
    this.footer,
  });

  final String title;
  final Color color;
  final String subtitle;

  /// 额外的一行提示（例如"这条线被 2 个区域共用"）。
  final String? hint;

  /// 面板底部的一行小字（操作提示，例如"再点一次可切换"）。
  final String? footer;

  final VoidCallback onDeselect;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: '取消选中',
                  onPressed: onDeselect,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(subtitle, style: theme.textTheme.bodySmall),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(
                hint!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: actions),
            ],
            if (footer != null) ...[
              const SizedBox(height: 6),
              Text(
                footer!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 面板上的一个操作按钮。
class _PanelAction extends StatelessWidget {
  const _PanelAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final style = danger
        ? FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
            foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
          )
        : null;
    return FilledButton.tonalIcon(
      style: style,
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}

/// 地图上的点：**按类别上色**（第十四章）。
///
/// 辅助点用中性灰（它是"骨架"，不该抢眼），店铺/门/路点各给一个颜色，
/// 这样一眼就能看出这片点里哪些是有含义的。
class _PointDot extends StatelessWidget {
  const _PointDot({
    required this.domain,
    required this.selected,
    required this.emphasized,
  });

  /// v12：点没有"类别"这个字段了 —— 它的样子按**域**上色
  /// （路网/世界图/行政区域各一色，与图层主色一致）。
  final MapDomain domain;
  final bool selected;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final size = selected || emphasized ? 16.0 : 11.0;
    return Tooltip(
      message: domain.label,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          // 选中时统一黄色；否则按**域**上色。
          // 世界图的点多半是画墙用的顶点，用白底当"背景骨架"，不抢视线。
          color: selected
              ? const Color(0xFFFFC107)
              : (domain == MapDomain.world
                    ? Colors.white
                    : Color(domain.defaultColor)),
          shape: BoxShape.circle,
          border: Border.all(
            color: emphasizePointsBorderColor(domain, emphasized),
            width: emphasized ? 3 : 2,
          ),
        ),
      ),
    );
  }
}

/// 边框色：世界图的点（画图顶点）用中性深灰，其它域用本域主色。
Color emphasizePointsBorderColor(MapDomain domain, bool emphasized) {
  if (emphasized) return const Color(0xFF2E7D32);
  if (domain == MapDomain.world) return const Color(0xFF37474F);
  return Color(domain.defaultColor);
}


/// 店铺在地图上的标签，**只有名字**（门牌号 + 店名）。
///
/// 刻意做成"纯文字"（用户 2026-09-13 要求去掉宽度、再去掉左侧图标）：
/// 地图上一条街可能挤十几家店，任何多余的装饰（图标、宽度后缀）
/// 都在加宽胶囊、加剧互相压盖，而缩放后那些小字根本读不清。
/// 店铺的位置本身已经说明了"这是店铺"，不需要再画一个店铺小图标。
///
/// 被吸附、宽度、类型这些**编辑时**才关心的信息，都在详情面板里看。
class _ShopChip extends StatelessWidget {
  const _ShopChip({required this.label, required this.selected});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFFFFC107) : const Color(0xF2FFFFFF),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: selected ? const Color(0xFFEF6C00) : const Color(0xFF00695C),
          width: selected ? 2 : 1,
        ),
      ),
      child: Text(
        label.isEmpty ? '未命名店铺' : label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 10, color: Color(0xFF004D40)),
      ),
    ),
  );
}

/// 门旗标（第十五章重做）。
///
/// 颜色**按门的类型**给（园区门绿 / 建筑门蓝 / 楼梯口橙），
/// 因为时间管制去掉之后，"现在能不能过"已经不再随时刻变化，
/// 而"这是一扇什么门"才是用户扫一眼地图最想知道的事。
/// 需要刷卡/登记或本车型禁行的，叠一个角标。
class _GateFlag extends StatelessWidget {
  const _GateFlag({
    required this.status,
    required this.label,
    required this.type,
    required this.selected,
    required this.snapped,
  });

  final GateStatus status;
  final String label;
  final GateType type;
  final bool selected;
  final bool snapped;

  @override
  Widget build(BuildContext context) {
    final base = Color(type.defaultColor);
    final badge = switch (status) {
      GateStatus.restricted => Icons.warning_amber_rounded,
      GateStatus.vehicleDenied => Icons.block,
      GateStatus.open || GateStatus.unknown => null,
    };
    return Tooltip(
      message: '$label（${type.label}）：${status.label}'
          '${snapped ? ' · 已吸附到线上' : ''}',
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.door_front_door,
            color: selected ? const Color(0xFFFFC107) : base,
            size: selected ? 30 : 26,
          ),
          if (badge != null)
            Positioned(
              right: 4,
              top: 4,
              child: Icon(badge, size: 14, color: base),
            ),
        ],
      ),
    );
  }
}

/// **楼层条**（第十七章）：右侧竖排的 ▲/层号/▼。
///
/// 做成常驻的竖向控件而不是藏在设置里：切楼层是**看地图时的高频动作**
/// （楼上楼下对照着看），藏起来每次都要点两次菜单。
/// 也正因为常驻，"我现在在第几层"这件事一直摆在眼前 —— 这很重要，
/// 否则用户会以为"我画的墙丢了"，其实只是切到了 2 层。
class _FloorStepper extends ConsumerWidget {
  const _FloorStepper({required this.floor});

  final int floor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(currentFloorProvider.notifier);
    final onGround = floor <= kGroundFloor;
    final accent = onGround ? const Color(0xFF546E7A) : const Color(0xFFEF6C00);
    return Card(
      elevation: 4,
      margin: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '上一层',
            visualDensity: VisualDensity.compact,
            onPressed: notifier.up,
            icon: const Icon(Icons.keyboard_arrow_up),
          ),
          // 层号
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: Column(
              children: [
                Text(
                  '$floor',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
                Text(
                  '层',
                  style: TextStyle(fontSize: 10, color: accent),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: onGround ? '已经在最底层' : '下一层',
            visualDensity: VisualDensity.compact,
            onPressed: onGround ? null : notifier.down,
            icon: const Icon(Icons.keyboard_arrow_down),
          ),
        ],
      ),
    );
  }
}

/// 换路口的旗标（21 章）：一个粉色小圆底 + ⇄ 图标 ——
/// "这里两侧可以交换"用双向箭头是最直白的表达。
class _CrossingBadge extends StatelessWidget {
  const _CrossingBadge({required this.color, required this.selected});

  final Color color;
  final bool selected;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '换路口：围栏路两侧在这里可以交换',
    child: Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFC107) : Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 2.5),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 3,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: const Padding(
          padding: EdgeInsets.all(3),
          child: Icon(Icons.swap_horiz, size: 14, color: Color(0xFFC2185B)),
        ),
      ),
    ),
  );
}

/// 左侧的图层显示开关有哪几种。
enum _DisplayToggle { shops, administrative }

/// 图层显示开关（左下小胶囊）。
///
/// 做成通用的一枚，而不是给每个图层写一个 —— 它们长得一样、行为一样，
/// 差别只有图标/文字/写哪个偏好。
class _DisplayToggleChip extends ConsumerWidget {
  const _DisplayToggleChip({
    required this.icon,
    required this.label,
    required this.which,
  });

  final IconData icon;
  final String label;
  final _DisplayToggle which;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(displayPrefsProvider);
    final notifier = ref.read(displayPrefsProvider.notifier);
    final on = switch (which) {
      _DisplayToggle.shops => prefs.showShops,
      _DisplayToggle.administrative => prefs.showAdministrative,
    };
    final color = on ? const Color(0xFF00695C) : Colors.grey;
    return Card(
      elevation: 4,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => switch (which) {
          _DisplayToggle.shops => notifier.toggleShops(),
          _DisplayToggle.administrative => notifier.toggleAdministrative(),
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(fontSize: 12, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 导入层开关胶囊（07 章 §5.2）。作为 Consumer 组件使用。
class _ImportToggleChip extends ConsumerWidget {
  const _ImportToggleChip({required this.vis});

  final ImportVisibility vis;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(importVisibilityProvider.notifier);
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '导入路网',
              isSelected: vis.roads,
              onPressed: controller.toggleRoads,
              icon: const Icon(Icons.route_outlined, size: 20),
              color: vis.roads ? const Color(0xFF1565C0) : Colors.grey,
            ),
            IconButton(
              tooltip: '导入建筑',
              isSelected: vis.buildings,
              onPressed: controller.toggleBuildings,
              icon: const Icon(Icons.home_work_outlined, size: 20),
              color: vis.buildings ? const Color(0xFF455A64) : Colors.grey,
            ),
            IconButton(
              tooltip: '导入 POI',
              isSelected: vis.pois,
              onPressed: controller.togglePois,
              icon: const Icon(Icons.location_on_outlined, size: 20),
              color: vis.pois ? const Color(0xFFF9A825) : Colors.grey,
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部状态条统一样式：圆角 Card + 内边距（_statusBar 四种分支共用）。
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      // 左右不再留边：外层 Row 已经统一给了 8 的水平内边距，
      // 这里再留一次会让状态条与右侧的设置按钮错开一截。
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: child,
      ),
    );
  }
}

/// 地图比例尺（左下角水平线 + 米/km 数字）。
///
/// 设计参考百度/高德：
/// - 段长自适应：选 1/4 屏宽对应的米数，然后归一到 1/2/5 × 10^n。
/// - 数学：Web Mercator，256px 瓦片下 `metersPerPixel = 156543.03 * cos(lat) / 2^zoom`。
/// - 输入 zoom 必须 >= 0，否则算不出正数（zoom<0 时 fall back 到 zoom=0）。
class _ScaleBar extends StatelessWidget {
  const _ScaleBar({
    required this.zoom,
    required this.centerLat,
    required this.screenWidth,
  });

  final double zoom;
  final double centerLat;
  final double screenWidth;

  /// 赤道处 256 像素对应的米数（Web Mercator 常量）。
  static const double _kEarthCircumferenceMeters = 40075016.686;

  /// 选出距离 target 最近、且不超过 target 的「1/2/5 × 10^n」数。
  /// 这样视觉上段长恰好铺到屏宽 1/4 的位置，又不会越界。
  static double _niceRoundMeters(double target) {
    if (target <= 0 || target.isNaN || target.isInfinite) return 1;
    final exp = (math.log(target) / math.ln10).floor();
    final pow10 = math.pow(10.0, exp).toDouble();
    for (final mantissa in const [1.0, 2.0, 5.0, 10.0]) {
      final v = mantissa * pow10;
      if (v <= target) return v;
    }
    return target;
  }

  /// 把米数格式化成"100 m / 5 km"的形式（>= 1000m 用 km，1 位小数）。
  static String _formatMeters(double m) {
    if (m >= 1000) {
      final km = m / 1000;
      return km >= 10
          ? '${km.toStringAsFixed(0)} km'
          : '${km.toStringAsFixed(1)} km';
    }
    return '${m.toStringAsFixed(0)} m';
  }

  @override
  Widget build(BuildContext context) {
    // zoom<0 时 cos 因子会失真，按 0 处理；cos(lat) 在纬度≈90 时趋近 0，
    // 给一个最小值 0.01 防 div-by-zero（实际 corridor 22° 远不会触发）。
    final z = zoom.isFinite && zoom >= 0 ? zoom : 0.0;
    final cosLat = math.cos(centerLat * math.pi / 180.0).abs().clamp(0.01, 1.0);
    final metersPerPixel =
        (_kEarthCircumferenceMeters * cosLat) / (256.0 * math.pow(2.0, z));
    // 目标段长 = 屏宽 1/4；归一到 1/2/5 × 10^n。
    final targetPx = (screenWidth / 4).clamp(40.0, 240.0);
    final targetMeters = metersPerPixel * targetPx;
    final niceMeters = _niceRoundMeters(targetMeters);
    final barPx = (niceMeters / metersPerPixel).clamp(8.0, targetPx * 1.5);

    return Semantics(
      label:
          '地图比例尺：屏幕 ${barPx.toStringAsFixed(0)} 像素 = ${_formatMeters(niceMeters)}',
      child: Card(
        elevation: 3,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 上半段：黑色横线 + 两端竖直短刻度（典型地图 UI 样式）。
              SizedBox(
                width: barPx,
                height: 8,
                child: Stack(
                  children: [
                    // 横线
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 3,
                      child: Container(
                        height: 2,
                        color: const Color(0xCC000000),
                      ),
                    ),
                    // 左端刻度
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        width: 2,
                        color: const Color(0xCC000000),
                      ),
                    ),
                    // 右端刻度
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        width: 2,
                        color: const Color(0xCC000000),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 1),
              // 下半段：米/km 数字标签
              Text(
                _formatMeters(niceMeters),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: Color(0xDD000000),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
