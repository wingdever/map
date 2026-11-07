/// 统一编辑模式的状态机（docs/design/12-edit-mode.md）。
///
/// 设计原则：**控制器只管「画到哪一步了」，不管弹窗与落库的 UI 细节**。
/// 需要用户填表单时（命名、选材质、填店铺宽度…），控制器把一个
/// [EditRequest] 挂到 state 上，由页面 `ref.listen` 收到后弹表单，
/// 再把结果通过 `resolve*` 方法交回来。
///
/// 这样做的好处：
/// - 状态迁移（点到第 2 个点该连线了 / 选了几条线能不能闭合）全部可推理，
///   不需要在 widget 里散布 if；
/// - 每个工具的行为都被限制在「积攒几何 → 发一个请求 → 收到结果落库」三步。
///
/// **[MapDomain] 与 [EditTool] 两个枚举定义在 `core/edit_layers.dart`**（第十九章）：
/// 它们是"图层怎么分、哪个工具归哪层"的领域知识，而且放在纯 Dart 里
/// 才能被 `tool/checks/layers_check.dart` 验证。这里用 export 转出去，
/// 于是 `EditTool.browse` / `MapDomain.world` 在 UI 那边的写法一个字都不用改。
library;

// 两个枚举（MapDomain / EditTool）定义在 core：这里 export 出去，
// 于是 `import 'edit_mode_controller.dart'` 的地方照样能写 `EditTool.browse`。
export '../../core/edit_layers.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/edit_layers.dart';
import '../../core/floor_set.dart';
import '../../core/geometry.dart';
import '../../core/hit_test.dart';
import '../../core/models.dart';
import '../../core/polyline.dart';
import '../../core/ring.dart';
import '../../data/app_repository.dart';
import '../../data/providers.dart';
import '../../services/location_service1.dart';
import '../../utils/platform_utils.dart';
import '../map/floor_provider.dart';
import '../map/import_layer_providers.dart';
import '../map/map_layers.dart';

/// 当前选中的要素（[EditTool.browse] 下的点选结果）。
///
/// 🔴 **v12 起每个选择都必须带 [domain]**。
///
/// v11 时 id 是全局唯一的（全世界只有一张 `lines` 表），所以 `SelLine(3)`
/// 这句话没有歧义。v12 把用户层分成三个域之后 **id 只在域内唯一**：
/// `way_lines.id = 3` 与 `world_lines.id = 3` 是毫不相干的两条线。
/// 只带 id 的选择会去找**另一层**的要素 —— 而且**不会报错**，只会选中/画出
/// 一个形状相似但完全不同的东西（最难查的那类 bug）。
///
/// 迁移后的旧数据侥幸不冲突（每条老线只进了一个域）；**新画的线一定会冲突**
/// （各域独立自增），所以不能靠"暂时没事"糊过去。
///
/// 门、世界要素、记录点都只在世界图域里，但它们的 [domain] 也照样写着 ——
/// 统一形状比"这一种恰好不需要"更好推理。
sealed class EditSelection {
  const EditSelection(this.domain, this.id);

  /// 这个选择属于哪个域（= 它在那张表里）。
  final MapDomain domain;

  /// 域内 id。
  final int id;

  /// `(域, id)` —— 去 [MapLayersData] 里查东西一律用它。
  ShapeRef get ref => (domain, id);
}

class SelPoint extends EditSelection {
  const SelPoint(super.domain, super.id);
}

class SelLine extends EditSelection {
  const SelLine(super.domain, super.id);
}

class SelArea extends EditSelection {
  const SelArea(super.domain, super.id);
}

class SelPlate extends EditSelection {
  const SelPlate(super.domain, super.id);
}

class SelGate extends EditSelection {
  const SelGate(super.domain, super.id);
}

/// 需要 UI 弹表单的挂起请求。
sealed class EditRequest {
  const EditRequest();
}

/// 新点落好了，请 UI 问名字。
class PointFormRequest extends EditRequest {
  const PointFormRequest(this.pointId, this.at);
  final int pointId;
  final GeoPoint at;
}

/// 记录点落好了，请 UI 问名字（记录模式）。
///
/// v12：记录点是自己一张表（`world_marks`），与"编辑模式的几何点"是两回事，
/// 所以它有**自己的**表单请求类型。
class MarkFormRequest extends EditRequest {
  const MarkFormRequest(this.markId, this.at);
  final int markId;
  final GeoPoint at;
}

/// 两个点已连成线，请 UI 问名称与属性。
class LineFormRequest extends EditRequest {
  const LineFormRequest(this.lineId, this.domain);
  final int lineId;

  /// 刚建出来的线属于哪个域 —— 表单据此预选类型，
  /// 免得用户点了「路线」工具、表单却默认勾着「界线」。
  final MapDomain domain;
}

/// 围合已闭合，请 UI 问区域名称与类型。
class RingFormRequest extends EditRequest {
  const RingFormRequest(this.lineIds, {this.domain = MapDomain.world});
  final List<int> lineIds;

  /// 这几条线属于哪个域。表单据此预选区域类型 ——
  /// 用行政线围出来的，域就是 `zone`（虚拟域整域跳过，见 [MapDomain.isVirtual]）。
  final MapDomain domain;

  /// 用行政线围出来的区域是**虚拟**的。
  bool get virtual => domain.isVirtual;
}

/// 在线上点了「店铺」或「墙体」工具，请 UI 填对应的表单。
class LineFeatureFormRequest extends EditRequest {
  const LineFeatureFormRequest({
    required this.type,
    required this.lineId,
    required this.at,
  });

  /// 要素类型（[EntityType.shop] / `building` / `unit` / `deliveryPoint` / `parking`）。
  /// v12 起**没有 `wall`**（D5：墙体段删除）。
  final EntityType type;

  /// 挂在哪条线上（世界图的界线）。
  final int lineId;

  /// 点击位置**吸附到线上之后**的坐标 —— 就是新要素的中心点。
  final GeoPoint at;
}

/// 在线上点了门工具，请 UI 弹门的属性表单。
///
/// 第十五章起不再需要 areaId：门挂在**线**上，线属于哪些区域由 area_lines 决定。
class GateFormRequest extends EditRequest {
  const GateFormRequest({required this.lineId, required this.at});

  final int lineId;

  /// 点击位置**吸附到线上**之后的坐标 —— 就是门的中心点。
  final GeoPoint at;
}

/// 选择态下点了要素，请 UI 弹对应属性表单。
class FeatureFormRequest extends EditRequest {
  const FeatureFormRequest(this.selection);
  final EditSelection selection;
}

class EditState {
  const EditState({
    this.active = false,
    this.recording = false,
    this.layer = MapDomain.way,
    this.tool = EditTool.browse,
    this.bendTargetLineId,
    this.lineDraftPointIds = const [],
    this.ringLineIds = const [],
    this.polygonDraft = const [],
    this.selection,
    this.request,
    this.notes = const [],
  });

  /// 是否处于编辑模式。
  final bool active;

  /// 是否处于**记录模式**（第十四章）。
  ///
  /// 与编辑模式是两件事，共用一套状态机只是为了省掉一份重复的
  /// 「草稿 / 请求 / 选中」管道：记录模式只有"落点 + 填表单"，
  /// 工具条也换成专用的那一套，不会看到编辑模式那 10 个工具。
  final bool recording;

  /// 编辑模式下正在编的**图层**（第十九章）：路网 / 世界图 / 行政区域。
  ///
  /// 默认落在**路网**：这是骑手最常干的事（把自己跑出来的路画下来），
  /// 而且它是三层里最不容易误伤已有数据的（世界图里有墙和小区）。
  final MapDomain layer;

  final EditTool tool;

  /// **「加拐点」模式的目标线 id**（第二十章）。null = 不在这个模式里。
  ///
  /// 这个模式的作用是：鼠标在图上移动时实时预览"新拐点插进去之后这条路长什么样"，
  /// 点一下就真的插进去。它**不是一个 [EditTool]** —— 工具是工具栏上的一等公民、
  /// 每层都摆着；而"给某一条线加拐点"是对**一条具体的线**的操作，
  /// 入口在那条线的属性面板上（和「改属性」「删除」并列）。
  final int? bendTargetLineId;

  /// 折线工具（界线/路线/行政线）**已点下的顶点 id**，按点按顺序（18 章）。
  ///
  /// 从"已选的起点"（一个 id）改成"一条正在拉的折线"（一串 id）：
  /// 第一个点是起点，之后每点一个点就多一个拐点，最后一个是当前终点。
  /// 落库时才拆成"起点 / 拐点… / 终点"。
  final List<int> lineDraftPointIds;

  /// 围合工具：已选的线 id（按点击顺序）。
  final List<int> ringLineIds;

  /// 一笔画工具：已落下的拐角。
  final List<GeoPoint> polygonDraft;

  final EditSelection? selection;

  /// 挂起的表单请求；UI 处理完调 `resolveRequest()` 清空。
  final EditRequest? request;

  /// 最近一次的提示（例如「这两条线没有连在一起」）。
  final List<String> notes;

  EditState copyWith({
    bool? active,
    bool? recording,
    MapDomain? layer,
    EditTool? tool,
    int? bendTargetLineId,
    bool clearBendTarget = false,
    List<int>? lineDraftPointIds,
    bool clearLineDraft = false,
    List<int>? ringLineIds,
    List<GeoPoint>? polygonDraft,
    EditSelection? selection,
    bool clearSelection = false,
    EditRequest? request,
    bool clearRequest = false,
    List<String>? notes,
  }) => EditState(
    active: active ?? this.active,
    recording: recording ?? this.recording,
    
    layer: layer ?? this.layer,
    tool: tool ?? this.tool,
    bendTargetLineId: clearBendTarget
        ? null
        : (bendTargetLineId ?? this.bendTargetLineId),
    lineDraftPointIds: clearLineDraft
        ? const []
        : (lineDraftPointIds ?? this.lineDraftPointIds),
    ringLineIds: ringLineIds ?? this.ringLineIds,
    polygonDraft: polygonDraft ?? this.polygonDraft,
    selection: clearSelection ? null : (selection ?? this.selection),
    request: clearRequest ? null : (request ?? this.request),
    notes: notes ?? this.notes,
  );

  /// 折线草稿的起点（null = 还没点第一个点）。
  ///
  /// 保留这个名字是因为 UI 上"起点已定，等下一个点"是个独立的状态，
  /// 直接问 `lineDraftPointIds.first` 在空列表上会抛异常。
  int? get lineStartPointId =>
      lineDraftPointIds.isEmpty ? null : lineDraftPointIds.first;

  /// 折线草稿能否落库（至少两个顶点才是一条线）。
  bool get canFinishLineDraft => lineDraftPointIds.length >= 2;

  /// 当前工具是否有"画到一半"的草稿（工具栏据此显示撤销/取消）。
  bool get hasDraft =>
      lineDraftPointIds.isNotEmpty ||
      ringLineIds.isNotEmpty ||
      polygonDraft.isNotEmpty;

  /// 当前图层里能用的工具（工具栏按它铺 chip）。
  List<EditTool> get toolsInLayer => EditTool.toolsOf(layer);

  /// 是否正在「加拐点」。
  bool get addingBend => bendTargetLineId != null;

  /// 一笔画能否闭合。
  bool get canClosePolygon => polygonDraft.length >= 3;
}

class EditModeController extends Notifier<EditState> {
  @override
  EditState build() => const EditState();

  AppRepository get _repo => ref.read(repositoryProvider);

  void _refreshLayers() => ref.invalidate(mapLayersProvider);

  void _note(String message) {
    state = state.copyWith(notes: [...state.notes, message]);
  }

  /// UI 处理完 tips 后清空（避免重复弹 SnackBar）。
  void clearNotes() {
    if (state.notes.isEmpty) return;
    state = state.copyWith(notes: const []);
  }

  // -------------------------------------------------------------------------
  // 模式与工具
  // -------------------------------------------------------------------------

  /// 进入**编辑模式**（画点/线/面/店铺/墙体/门）。
  ///
  /// 一律落回**路网 + 选择**：这两个默认值决定了"点一下编辑按钮之后我在哪"。
  /// 落进某个画图工具会很危险（一进来手一抖就画了一笔），
  /// 而落在世界图则会让"我就想画条路"每次都要先切一下。
  void enter() {
    state = state.copyWith(
      active: true,
      layer: MapDomain.way,
      tool: MapDomain.way.defaultTool,
      clearBendTarget: true,
      recording: false,
    );
  }

  /// 进入**记录模式**（定位采点）。
  ///
  /// 进去时就把"这个平台有没有定位"讲清楚，而不是让用户点半天没反应。
  void enterRecording() {
    final ok = PlatformUtils.isLocationSupported();
    state = state.copyWith(
      active: true,
      recording: true,
      tool: EditTool.browse,
      clearBendTarget: true,
      clearSelection: true,
      notes: ok
          ? const []
          : const [
              '这个平台没有定位能力（libre_location 只支持 Android/iOS）。'
              '当前可以直接点地图落点记录；在 Android 上这里会采当前位置。',
            ],
    );
  }

  /// 记录模式下切换"下一类点"。
  void exit() {
    state = const EditState();
  }

  void setTool(EditTool tool) {
    if (state.tool == tool) return;
    // **工具与图层必须自洽**：工具若不在当前图层里（比如在路网层点了线面板上的
    // 「加店铺」），就把图层一起切过去 —— 否则工具条上没有任何 chip 是高亮的，
    // 用户看不出自己现在拿着什么工具，而它其实已经生效了。
    final layer = tool.domains.contains(state.layer)
        ? state.layer
        : tool.primaryDomain;
    // 换工具 = 丢掉上一个工具画到一半的草稿（避免"点了个点又去连线"这种混乱），
    // 也退出「加拐点」模式（两件事都占着"点一下地图"这个动作）
    state = state.copyWith(
      layer: layer,
      tool: tool,
      clearBendTarget: true,
      clearLineDraft: true,
      ringLineIds: const [],
      polygonDraft: const [],
      clearSelection: true,
      clearRequest: true,
    );
  }

  /// 切换**图层**（第十九章）。
  ///
  /// 两条规则：
  /// 1. 草稿一律丢掉 —— 一个画到一半的界线草稿跨到路网层毫无意义，
  ///    更重要的是它会让"完成"按钮落出一条你此刻已经不看的那种线；
  /// 2. 当前工具若在新图层里也有（「选择」「标点」三层都有），就**留着** ——
  ///    三层之间来回切时，选择工具不该被重置，否则每切一次都要重新点一下。
  void setLayer(MapDomain layer) {
    if (state.layer == layer) return;
    final keepTool = state.tool.domains.contains(layer);
    state = state.copyWith(
      layer: layer,
      tool: keepTool ? state.tool : layer.defaultTool,
      clearBendTarget: true,
      clearLineDraft: true,
      ringLineIds: const [],
      polygonDraft: const [],
      clearSelection: true,
      clearRequest: true,
    );
  }

  void resolveRequest() {
    if (state.request == null) return;
    state = state.copyWith(clearRequest: true);
  }

  /// 撤销当前工具的上一步。
  void undo() {
    switch (state.tool) {
      case EditTool.boundaryLine:
      case EditTool.routeLine:
      case EditTool.adminLine:
        // 撤销 = **退掉最后一个顶点**（而不是把整条草稿清空）：
        // 拉一条拐了五道弯的路时，点错最后一个点应该只退一步 ——
        // 清空的话用户得从头再点一遍，这个工具就没法用了。
        if (state.lineDraftPointIds.isEmpty) return;
        state = state.copyWith(
          lineDraftPointIds: state.lineDraftPointIds.sublist(
            0,
            state.lineDraftPointIds.length - 1,
          ),
        );
      case EditTool.area:
        if (state.ringLineIds.isEmpty) return;
        state = state.copyWith(
          ringLineIds: state.ringLineIds.sublist(0, state.ringLineIds.length - 1),
        );
      case EditTool.polygon:
        if (state.polygonDraft.isEmpty) return;
        state = state.copyWith(
          polygonDraft: state.polygonDraft.sublist(
            0,
            state.polygonDraft.length - 1,
          ),
        );
      case EditTool.browse:
      case EditTool.point:
      case EditTool.shop:
      case EditTool.gate:
      case EditTool.basemap:
        return;
    }
  }

  /// 放弃当前工具画到一半的东西。
  void cancelDraft() {
    state = state.copyWith(
      clearBendTarget: true,
      clearLineDraft: true,
      ringLineIds: const [],
      polygonDraft: const [],
      clearRequest: true,
    );
  }

  // -------------------------------------------------------------------------
  // 地图点击分发
  // -------------------------------------------------------------------------

  /// 页面把地图点击交给这里。返回后 UI 应检查 `state.request` / `state.notes`。
  Future<void> onMapTap(GeoPoint p, MapLayersData? data) async {
    if (!state.active || data == null) return;

    // 记录模式：点哪就把哪记成一个点（类别取自当前选中的那一类）
    if (state.recording) {
      await recordPointAt(p);
      return;
    }

    final tol = snapToleranceForZoom(ref.read(mapZoomProvider));

    // 「加拐点」模式优先：这时一次点按的意思是"就放在这里"，
    // 而不是去选中它下面的东西（否则点了半天只是换了选中项，拐点一个没加）。
    if (state.addingBend) {
      await placeBend(p, data);
      return;
    }

    switch (state.tool) {
      case EditTool.browse:
        selectAt(p, data);
      case EditTool.point:
        await _createPoint(p);
      case EditTool.boundaryLine:
        await _handleLineTap(p, data, tol, MapDomain.world);
      case EditTool.routeLine:
        await _handleLineTap(p, data, tol, MapDomain.way);
      case EditTool.adminLine:
        await _handleLineTap(p, data, tol, MapDomain.zone);
      case EditTool.area:
        _handleRingTap(p, data, tol);
      case EditTool.shop:
        _handleLineFeatureTap(p, data, tol, EntityType.shop);
      case EditTool.gate:
        _handleGateTap(p, data, tol);
      case EditTool.polygon:
        state = state.copyWith(polygonDraft: [...state.polygonDraft, p]);
      case EditTool.basemap:
        // 「选取底图」整条链路（命中 OSM 要素 → 弹"是否带入"对话框 → 落库）
        // 都由页面负责：它才有 BuildContext，而且导入层的数据结构
        // （ImportLayerView）不属于编辑状态机该知道的东西。
        break;
    }
  }

  // ---- 加拐点（第二十章）----

  /// 进入**「加拐点」模式**：给 [lineId] 这条线再插一个拐点。
  ///
  /// 入口在那条线的属性面板上（与「改属性」「删除」并列），不在工具栏里 ——
  /// 它是"对某一条具体的线"的操作，而工具栏上的工具都是"开始画一个新东西"。
  ///
  /// 进去之后：
  ///   - 清掉选中（面板收起来，地图上不挡路）；
  ///   - 鼠标在地图上移动时实时预览（预览由 `EditDraftOverlay` 画）；
  ///   - **点一下就真的插一个拐点，并留在这个模式里**（一条路常常要连加几个弯）。
  void startAddBend(int lineId) {
    state = state.copyWith(
      active: true,
      bendTargetLineId: lineId,
      tool: EditTool.browse,
      clearSelection: true,
      clearLineDraft: true,
      ringLineIds: const [],
      polygonDraft: const [],
      notes: const [],
    );
  }

  /// 退出「加拐点」模式（「取消」按钮 / 切工具 / 切图层都会走这里）。
  void cancelAddBend() {
    if (!state.addingBend) return;
    state = state.copyWith(clearBendTarget: true);
  }

  /// 放下一个拐点：**新建一个点**，插进目标线的最近那一段。
  ///
  /// 三个刻意的选择（2026-09-14 用户拍板）：
  /// 1. **一律新建点**，不吸附已有顶点 —— 这个动作的语义就是"我要在这条路上
  ///    多一个顶点"，鼠标指哪就是哪。所以它是"拉线只吸附已有点"那条红线的
  ///    **一个明确开的口子**：红线防的是"连线时手抖凭空多出孤点"，
  ///    而这里每一次点按都是用户明确要求的一次插入；
  /// 2. **插到最近的那一段里**（最近的两个已有顶点之间），其余形状不动
  ///    （见 `planBendInsertion`，不会顺手把别的拐角磨圆）；
  /// 3. 落点离已有顶点太近（< 0.5 m）时**拒绝**并说明 —— 那会造出一段长度为零的边。
  Future<void> placeBend(GeoPoint at, MapLayersData data) async {
    final lineId = state.bendTargetLineId;
    if (lineId == null) return;
    // 目标线属于哪个域：加拐点是"对一条具体的线"的操作，
    // 而这条线是在**当前编辑域**里选出来的（19 章：图层只决定能编辑什么）。
    final line = data.linesByRef[(state.layer, lineId)];
    if (line == null) {
      _note('要加拐点的那条线已经不在了（可能被删掉了）');
      state = state.copyWith(clearBendTarget: true);
      return;
    }

    final plan = planBendInsertion(line, data.pointsOf(line.domain), at);
    if (plan == null) {
      _note('这条线的顶点数据不全（有顶点被删了），先把它的点补齐再加拐点');
      return;
    }
    if (plan.tooCloseToVertex) {
      _note('这里离已有顶点太近了（不足 1 米），换个位置再加');
      return;
    }

    // 新点继承这条线的楼层：2 层画的路线，它的拐点也必须在 2 层，
    // 否则切到 2 层时这条线会因为"缺拐点坐标"整个画不出来。
    // 它也继承这条线的**域**：拐点必须和线在同一张点表里（D2：域之间零引用）。
    final pointId = await _repo.insertPoint(
      PointRow(
        lat: at.lat,
        lng: at.lng,
        domain: line.domain,
        floors: line.floors ?? FloorSet.ground,
      ),
    );
    // 🔴 用**局部指针操作**插入（O(1)），锚点就是"插在哪两个顶点之间"的**前一个点**：
    //   plan.bendIndex 是"插在顶点序列的第 i 与第 i+1 之间"，而顶点序列是
    //   `[起点, 拐点…, 终点]`，所以前一个顶点 = `pointIds[plan.bendIndex]`。
    //   点名一个**点**去插入，没有下标可以算错（20 章那条"下标红线"因此消失）。
    final anchor = line.pointIds[plan.bendIndex];
    await _repo.insertBendAfter(
      line.domain,
      lineId,
      anchorPointId: anchor,
      newPointId: pointId,
    );
    _refreshLayers();

    final sign = plan.addedMeters >= 0 ? '+' : '';
    _note(
      '已加拐点（这条线现在 ${line.pointCount + 1} 个点，'
      '全长 $sign${plan.addedMeters.round()} m）。'
      '继续点可以再加；点「取消」结束',
    );
  }

  // ---- 选择 ----

  /// 上一次「选择」点按的位置。
  ///
  /// 用来实现**同一位置连点循环**：点、线、面经常叠在一起（区域里必然有它的边线），
  /// 光靠几何优先级只能猜一个"最可能"的；连点同一个地方逐个切换，
  /// 是让用户自己说清意图的最省事办法。
  GeoPoint? _lastSelectTap;

  /// 「选择」工具：算出该点下方的全部候选，选中最该选的那个。
  ///
  /// 若**在同一个位置再次点按**，则切换到下一个候选（循环）。
  void selectAt(GeoPoint p, MapLayersData data) {
    final tol = snapToleranceForZoom(ref.read(mapZoomProvider));
    final candidates = rankFeatureHits(
      p: p,
      points: data.points,
      lines: data.lines,
      areas: [for (final a in data.areas) a.area],
      lineFeatures: data.entities,
      gates: data.gates,
      pointsByDomain: data.pointsByDomain,
      ringsByRef: data.ringsByRef,
      toleranceM: tol,
    );

    if (candidates.isEmpty) {
      _lastSelectTap = null;
      state = state.copyWith(clearSelection: true);
      return;
    }

    // 「同一个位置」的判定阈值取容差的 1/4（≈10px）：容得下手抖，
    // 又不会把两次不同意图的点按误判成连点。
    final prev = _lastSelectTap;
    final samePlace = prev != null && distanceMeters(p, prev) <= tol * 0.25;
    _lastSelectTap = p;

    var index = 0;
    if (samePlace && candidates.length > 1) {
      final cur = state.selection;
      if (cur != null) {
        final i = candidates.indexWhere(
          (c) => c.kind == _hitKindOf(cur) && c.id == cur.id,
        );
        if (i >= 0) index = (i + 1) % candidates.length;
      }
    }

    final chosen = candidates[index];
    state = state.copyWith(selection: _toSelection(chosen));

    if (index > 0) {
      _note(
        '同一位置有 ${candidates.length} 个要素，已切到「${_describeHit(chosen, data)}」'
        '（再点一次继续切换）',
      );
    }
  }

  /// 直接设定选中项（地图上的 Marker 点击走这里）。
  ///
  /// 手工指定时清掉连点状态：否则紧接着在地图上点同一个地方会
  /// 莫名其妙地"切到下一个"。
  void select(EditSelection? s) {
    _lastSelectTap = null;
    if (s == null) {
      state = state.copyWith(clearSelection: true);
    } else {
      state = state.copyWith(selection: s);
    }
  }

  static EditSelection _toSelection(HitCandidate c) => switch (c.kind) {
    HitKind.point => SelPoint(c.domain, c.id),
    HitKind.line => SelLine(c.domain, c.id),
    HitKind.area => SelArea(c.domain, c.id),
    HitKind.lineFeature => SelPlate(c.domain, c.id),
    HitKind.gate => SelGate(c.domain, c.id),
  };

  static HitKind _hitKindOf(EditSelection s) => switch (s) {
    SelPoint() => HitKind.point,
    SelLine() => HitKind.line,
    SelArea() => HitKind.area,
    SelPlate() => HitKind.lineFeature,
    SelGate() => HitKind.gate,
  };

  /// 候选要素的人类可读名字（连点切换时告诉用户切到了什么）。
  static String _describeHit(HitCandidate c, MapLayersData data) =>
      switch (c.kind) {
        HitKind.point =>
          data.points
              .where((x) => x.id == c.id && x.domain == c.domain)
              .firstOrNull
              ?.displayName ??
              '点 #${c.id}',
        HitKind.line =>
          data.linesByRef[c.ref]?.displayName ?? '线 #${c.id}',
        HitKind.area =>
          data.areas
              .where((a) => a.area.id == c.id && a.domain == c.domain)
              .firstOrNull
              ?.area
              .name ??
              '区域 #${c.id}',
        HitKind.lineFeature =>
          data.entities.where((x) => x.id == c.id).firstOrNull?.name ??
              '线上要素 #${c.id}',
        HitKind.gate =>
          data.gates.where((x) => x.id == c.id).firstOrNull?.displayName ??
              '门 #${c.id}',
      };

  /// 点选态的要素 → 打开它的属性表单。
  void editSelected() {
    final s = state.selection;
    if (s == null) return;
    state = state.copyWith(request: FeatureFormRequest(s));
  }

  // ---- 标点 ----

  /// 新建要素的默认楼层 = **当前正在看的那一层**。
  ///
  /// 用户说的是"默认一层" —— 那在最常见的情况下（当前就在 1 层）就是这个行为；
  /// 而当你切到 2 层再画墙时，墙落在 2 层才符合直觉
  /// （不然画完立刻看不见，还得回头把它改到 2 层）。
  FloorSet get _defaultFloors => FloorSet([ref.read(currentFloorProvider)]);

  Future<void> _createPoint(GeoPoint p) async {
    final id = await _repo.insertPoint(
      PointRow(
        lat: p.lat,
        lng: p.lng,
        // v12：几何点表**没有 kind 列**了（D9）—— 「这个点是干什么用的」
        // 由它落在哪个域（哪张表）表达：路网的点 / 世界图的点 / 行政的点。
        domain: state.layer,
        floors: _defaultFloors,
      ),
    );
    _refreshLayers();
    state = state.copyWith(request: PointFormRequest(id, p));
  }

  /// **记录一个点**（「记录」模式：定位采点或手点地图）。
  ///
  /// v12 起记录点是**自己的表**（`world_marks`），不再是"几何点 + 一个 source 标记"。
  /// 于是「浏览态只显示记录录入且未处理的点」从"猜 source"变成一句 `processed = 0`
  /// （[WorldMarkRow]）—— 22 章那个补丁之所以需要，正是因为当时两者挤在同一张表里。
  ///
  /// [byGps] = 这个坐标是"记录当前位置"（定位）来的，还是手点地图来的；
  /// [accuracy] 只有定位才有。落库后立刻挂一个表单请求，用户马上就能命名 ——
  /// 这就是「记录 → 可编辑」的完整闭环；保存后**留在记录模式**，方便连着采。
  Future<void> recordPointAt(
    GeoPoint p, {
    bool byGps = false,
    double? accuracy,
  }) async {
    final id = await _repo.insertWorldMark(
      WorldMarkRow(
        lat: p.lat,
        lng: p.lng,
        byGps: byGps,
        floors: _defaultFloors,
        accuracy: accuracy,
      ),
    );
    _refreshLayers();
    state = state.copyWith(request: MarkFormRequest(id, p));
  }

  /// 记录模式下采一次**当前定位**。
  ///
  /// 定位不可用时不静默失败 —— 明确告诉用户为什么、以及现在能做什么。
  Future<void> recordCurrentLocation() async {
    if (!PlatformUtils.isLocationSupported()) {
      _note('这个平台没有定位能力，请直接点地图上要记录的位置');
      return;
    }
    final pos = ref.read(locationStateProvider);
    if (pos == null) {
      _note('还没拿到定位。请确认已开启系统定位与应用权限，稍等几秒再试');
      return;
    }
    await recordPointAt(
      GeoPoint(pos.latitude, pos.longitude),
      byGps: true,
      accuracy: pos.accuracy,
    );
  }

  // ---- 拉折线（界线 / 路线 / 行政线）----

  /// 折线工具的一次点按：**把一个已有点接到正在拉的折线上**（第十八章）。
  ///
  /// 流程：第一次点按定起点 → 之后每点一个点延长一段（那个点成为拐点）
  /// → 点工具栏的「完成」落库。中途点错可以「撤销」退掉最后一个顶点。
  ///
  /// 仍然刻意**不新建点**：拐点必须是已经存在的点。理由是这条红线本来就在
  /// （连线只吸附已有点），而折线让它更重要 —— 现在一次点按就可能凭空多出
  /// 一个"看起来只是手抖"的拐点，而每个拐点都会永久留在数据里，
  /// 让这条线的业务键、围合关系、店铺定位全部跟着变。
  /// 想在路上加一个弯，先用「标点」把那个拐角落下来（也可以长按拖动微调）。
  Future<void> _handleLineTap(
    GeoPoint p,
    MapLayersData data,
    double tol,
    MapDomain kind,
  ) async {
    if (data.points.isEmpty) {
      _note('还没有任何点。请先用「标点」工具落点，再回来拉线');
      return;
    }
    final hit = hitNearestPoint(p, data.points, toleranceM: tol);
    if (hit == null) {
      _note('附近没有已有点（吸附范围约 ${tol.round()} 米）。'
          '拐点也要先落成点：用「标点」工具点一下这里，再回来继续拉');
      return;
    }
    final pointId = hit.point.id!;
    final draft = state.lineDraftPointIds;

    if (draft.contains(pointId)) {
      // 同一个点用两次 = 这一段长度为 0，几何上不成立（也会让比例、角度失去意义）
      _note(draft.last == pointId
          ? '这个点就是当前终点，请点下一个点'
          : '这个点已经在草稿里了，折线不能重复经过同一个点');
      return;
    }

    state = state.copyWith(lineDraftPointIds: [...draft, pointId]);
    // 这里**不**刷新图层：草稿只活在编辑状态里（`EditDraftOverlay` 直接读 state），
    // 一次点按就 invalidate 整个 mapLayersProvider 等于每点一下重查十几条 SQL。
    if (draft.isEmpty) {
      _note('起点已定。接着点下一个点延长这条线，拐几个弯都行；'
          '点「完成」结束（至少两个点）');
    }
  }

  /// 折线草稿落库（工具栏「完成」按钮）。
  ///
  /// 顶点序列拆成：第一个 = 起点、最后一个 = 终点、中间的全部 = **拐点**。
  /// 两个点时为一条直线段（拐点为空），与老数据完全同构。
  Future<void> finishLineDraft() async {
    final domain = state.tool.lineDomain;
    if (domain == null) return; // 当前工具不是折线工具
    final ids = state.lineDraftPointIds;
    if (ids.length < 2) {
      _note('至少点两个点才能连成一条线');
      return;
    }
    final lineId = await _repo.insertLine(
      LineRow(
        domain: domain,
        floors: _defaultFloors,
        startPointId: ids.first,
        endPointId: ids.last,
        bendPointIds: ids.length > 2
            ? ids.sublist(1, ids.length - 1)
            : const <int>[],
      ),
    );
    _refreshLayers();
    state = state.copyWith(
      clearLineDraft: true,
      request: LineFormRequest(lineId, domain),
    );
  }

  // ---- 围合区域 ----

  void _handleRingTap(GeoPoint p, MapLayersData data, double tol) {
    final hit = hitNearestLine(p, data.lines, data.pointsByDomain, toleranceM: tol);
    if (hit == null) {
      _note('没点到线，请点按靠近线条的位置');
      return;
    }
    final (next, error) = appendLineToRing(
      state.ringLineIds,
      hit.line,
      // 围合的成员必须是**同一个域**的线（D2/D19）：区域 1 当年就是把路线混进来，
      // 导致它三层分域之后根本围不成环。
      linesByRef: data.linesByRef,
    );
    if (error != null) {
      _note(error);
      return;
    }
    state = state.copyWith(ringLineIds: next);
  }

  /// 已选的线当前能否闭合成环（null = 可以）。
  String? ringStatus(MapLayersData? data) {
    if (data == null) return '数据还没加载完';
    final lines = [
      for (final id in state.ringLineIds)
        if (data.linesByRef[(state.layer, id)] != null)
          data.linesByRef[(state.layer, id)]!,
    ];
    return checkRingClosure(lines);
  }

  /// 点「围合成区域」按钮 → 请 UI 填名字与类型。
  void requestRingCommit() {
    final ids = state.ringLineIds;
    if (ids.length < 3) {
      _note('至少选 3 条线');
      return;
    }
    // 域就是虚实：行政域是虚拟的（寻路整域跳过），所以表单据此预选区域类型。
    state = state.copyWith(
      request: RingFormRequest(ids, domain: state.layer),
    );
  }

  /// 已选线是不是**全部为虚拟线**（供 UI 预选区域类型）。
  bool ringIsVirtual(MapLayersData? data) {
    if (data == null || state.ringLineIds.isEmpty) return false;
    for (final id in state.ringLineIds) {
      final l = data.linesByRef[(state.layer, id)];
      if (l == null || !l.domain.isVirtual) return false;
    }
    return true;
  }

  /// UI 填完名字与类型后回来落库。
  Future<bool> commitRing(String name, AreaType type, FloorSet floors) async {
    final req = state.request;
    if (req is! RingFormRequest) return false;

    // **虚拟/实体不能混着围**（第十六章）：
    // 「行政区域」由一个虚拟的东西围成，这是个要么全真要么全假的性质 ——
    // 混着围出来的区域既不是障碍也不是行政区，说不清它是什么。
    final ringLines = await _repo.listLinesByIds(req.domain, req.lineIds);
    final virtualCount = ringLines.where((l) => l.domain.isVirtual).length;
    if (virtualCount > 0 && virtualCount < ringLines.length) {
      _note('行政线（虚拟）和界线/路线（实体）不能混着围成同一个区域');
      return false;
    }
    // v12：**域就是虚实** —— 行政区域是 `zone_areas` 那张表，不是 area_type 的一个值。
    // 所以这里校验的是"表单选出来的域"与"这些线所在的域"一致，
    // 而不是比较两个枚举值（那正是 16 章那套 isVirtual 判据的替代）。
    if (req.domain.isVirtual && ringLines.any((l) => !l.domain.isVirtual)) {
      return false;
    }

    try {
      await _repo.createAreaFromLines(
        AreaRow(name: name, areaType: type, floors: floors),
        req.lineIds,
      );
    } on RingAssembleException catch (e) {
      _note('这几条线围不成闭合区域：$e');
      return false;
    } on ArgumentError catch (e) {
      _note('$e');
      return false;
    }
    _refreshLayers();
    state = state.copyWith(
      ringLineIds: const [],
      clearRequest: true,
      selection: null,
    );
    return true;
  }

  // ---- 一笔画圈地 ----

  void requestPolygonCommit() {
    if (!state.canClosePolygon) {
      _note('至少需要 3 个拐角');
      return;
    }
    // 复用 RingFormRequest 的表单，但落点是**多边形**（只造点、不造线）
    state = state.copyWith(
      request: RingFormRequest(const [], domain: state.layer),
    );
  }

  Future<bool> commitPolygon(String name, AreaType type, FloorSet floors) async {
    if (!state.canClosePolygon) return false;
    final ring = List<GeoPoint>.of(state.polygonDraft);
    // 自交的环存进去只会得到一个渲染诡异、组环也怪的多边形 ——
    // 这里挡在落库之前（原 area_draft.dart 的 isValidRing 能力，v4 起由
    // geometry.isSimpleRing 提供，两条路径共用）。
    if (!isSimpleRing(ring)) {
      _note('这个多边形自己交叉了（比如走了个 8 字），请撤销重画');
      return false;
    }
    // v12 的**行为改变**（D19）：一笔画圈地产出**多边形** —— 只造一圈点，
    // **不再造 N 条界线**。老版本走 saveAreaWithRing，会为每条边建一条界线，
    // 于是"随手圈一块地"会往世界图里塞一堆脚手架线（每条都能挂门、都有材质，
    // 但其实没人会给它们设属性）。要边实体的时候，用「转成区域」显式转（§4.5）。
    await _repo.savePolygonRing(
      PolygonRow(name: name, areaType: type, floors: floors),
      ring,
    );
    _refreshLayers();
    state = state.copyWith(polygonDraft: const [], clearRequest: true);
    return true;
  }

  // ---- 线上要素（店铺 / 墙体）----

  void _handleLineFeatureTap(
    GeoPoint p,
    MapLayersData data,
    double tol,
    EntityType type,
  ) {
    final hit = hitNearestLine(p, data.lines, data.pointsByDomain, toleranceM: tol);
    if (hit == null) {
      _note('${type.label}必须挂在线上，请点按靠近线条的位置');
      return;
    }
    // 新要素的中心点 = 点击位置**吸附到线上**的那个点。
    // 这样一落库就已经在线上，用户不用再手动纠一次。
    state = state.copyWith(
      request: LineFeatureFormRequest(
        type: type,
        lineId: hit.line.id!,
        at: hit.snapped,
      ),
    );
  }

  /// 保存线上要素（店铺 / 墙体）。[id] 为空即新建。
  ///
  /// [center] 传 null 表示"不改位置"（编辑时用户没重新点线）。
  Future<void> saveLineFeature({
    required EntityType type,
    required int lineId,
    int? id,
    required String name,
    String? desc,
    String? doorNo,
    GeoPoint? center,
    required double width,
    BoundaryType? boundaryType,
  }) async {
    if (id == null) {
      await _repo.addLineFeature(
        lineId: lineId,
        type: type,
        name: name,
        desc: desc,
        doorNo: doorNo,
        center: center ?? const GeoPoint(0, 0),
        width: width,
      );
    } else {
      final existing = await _repo.listEntitiesOfLine(lineId);
      final cur = existing.where((e) => e.id == id).firstOrNull;
      if (cur != null) {
        await _repo.updateEntity(
          cur.copyWith(
            name: name,
            desc: desc,
            doorNo: doorNo,
            clearDoorNo: doorNo == null,
            lat: center?.lat,
            lng: center?.lng,
            width: width,
          ),
        );
      }
    }
    _refreshLayers();
    state = state.copyWith(clearRequest: true);
  }

  Future<void> deleteLineFeature(int id) async {
    await _repo.softDeleteEntity(id);
    _refreshLayers();
    state = state.copyWith(clearSelection: true, clearRequest: true);
  }

  // ---- 门 ----

  void _handleGateTap(GeoPoint p, MapLayersData data, double tol) {
    final hit = hitNearestLine(p, data.lines, data.pointsByDomain, toleranceM: tol);
    if (hit == null) {
      _note('门要放在区块的边界线上，请点按靠近线条的位置');
      return;
    }
    // 门挂在**线**上，不再要求这条线已经属于某个区块 ——
    // 你可以先把门标好，回头再围区域把它圈进去。
    state = state.copyWith(
      request: GateFormRequest(lineId: hit.line.id!, at: hit.snapped),
    );
  }

  /// 保存门（新建或更新）。
  Future<void> saveGate({
    required int lineId,
    int? id,
    required GateType gateType,
    required GeoPoint center,
    String? name,
    VehicleType vehicleType = VehicleType.all,
    AccessLevel accessLevel = AccessLevel.free,
    String? note,
  }) async {
    if (id == null) {
      await _repo.addGate(
        lineId: lineId,
        gateType: gateType,
        center: center,
        name: name,
        vehicleType: vehicleType,
        accessLevel: accessLevel,
        note: note,
      );
    } else {
      final gates = await _repo.listGates();
      final cur = gates.where((g) => g.id == id).firstOrNull;
      if (cur != null) {
        await _repo.updateGate(
          cur.copyWith(
            name: name,
            gateType: gateType,
            lineId: lineId,
            center: center,
            vehicleType: vehicleType,
            accessLevel: accessLevel,
            note: note,
          ),
        );
      }
    }
    _refreshLayers();
    state = state.copyWith(clearRequest: true);
  }

  /// UI 取消了表单。
  void cancelRequest() {
    state = state.copyWith(clearRequest: true, clearLineDraft: true);
  }

  // -------------------------------------------------------------------------
  // 选择态下的增删改
  // -------------------------------------------------------------------------

  /// 保存一个**记录点**的属性（名字 + 楼层）。v12：记录点是自己一张表。
  Future<void> saveMark(int id, String name, FloorSet floors) async {
    final marks = await _repo.listWorldMarks();
    final cur = marks.where((m) => m.id == id).firstOrNull;
    if (cur == null) return;
    await _repo.updateWorldMark(
      cur.copyWith(name: name.isEmpty ? null : name, floors: floors),
    );
    _refreshLayers();
    state = state.copyWith(clearRequest: true);
  }

  /// 保存一个**几何点**的属性。
  ///
  /// v12：几何点表只剩坐标与楼层（D9 去掉了 `name`，也没有 `kind`/`source`）——
  /// 「这个点是干什么用的」由它落在哪个域表达，要命名就用世界域的要素
  /// （门 / 世界要素 / 记录点）。所以这里只能存楼层。
  Future<void> savePoint(int id, MapDomain domain, FloorSet floors) async {
    final points = await _repo.listPoints(domain);
    final cur = points.where((p) => p.id == id).firstOrNull;
    if (cur == null) return;
    await _repo.updatePoint(cur.copyWith(floors: floors));
    _refreshLayers();
    state = state.copyWith(clearRequest: true);
  }

  /// 保存线的属性（改名/类型/材质或路宽/单向/楼层）。
  ///
  /// **属性按类型分岔**（19 章，用户明确）：
  ///   - 界线 → `boundary_type`（材质）。表单给了值就写，给了 null（用户选"未指定"）就清空；
  ///   - 路线 → `route_width`（路宽）。同上；
  ///   - 另一边的属性**保持库里原值不动** —— 把一条界线改成路线时，
  ///     它的旧材质留在列里（下次改回来还在），而不是被"顺手"清掉。
  ///     表单没有义务替用户删数据，尤其这里清掉是不可撤销的。
  ///
  /// `cost_class`（通行代价）**完全不碰**：它已冻结，见 [CostClass]。
  /// 老代码在这里写 `clearCostClass: costClass == null`，而表单现在不编辑它 ——
  /// 照旧写的话，**每次给一条老路线改名都会把它的通行代价悄悄清空**。
  Future<void> saveLineProps(
    int id, {
    required String name,
    required MapDomain domain,
    FloorSet? floors,
    BoundaryType? boundaryType,
    RouteWidth? routeWidth,
    required bool oneWay,
    String? note,
  }) async {
    final lines = await _repo.listLines(domain);
    final cur = lines.where((l) => l.id == id).firstOrNull;
    if (cur == null) return;
    // 判据收在 [LineRow.hasMaterial] / [LineRow.hasRouteWidth]（域派生，只有一处定义）
    final materialApplies = cur.hasMaterial;
    final widthApplies = cur.hasRouteWidth;
    await _repo.updateLine(
      cur.copyWith(
        name: name,
        floors: floors,
        // 不适用时把**原值**传回去（等价于"不动"）；clear 只在适用时按用户选择生效。
        boundaryType: materialApplies ? boundaryType : cur.boundaryType,
        clearBoundaryType: materialApplies && boundaryType == null,
        routeWidth: widthApplies ? routeWidth : cur.routeWidth,
        clearRouteWidth: widthApplies && routeWidth == null,
        oneWay: oneWay,
        note: note,
      ),
    );
    _refreshLayers();
    state = state.copyWith(clearRequest: true);
  }

  Future<void> saveAreaProps(
    int id, {
    required MapDomain domain,
    required String name,
    required AreaType type,
    FloorSet? floors,
  }) async {
    final areas = await _repo.listAreas(domain);
    final cur = areas.where((a) => a.id == id).firstOrNull;
    if (cur == null) return;
    // ⚠️ v12 去掉了 `is_active` 列（19 章的"停用态"从未被用过，真库全 1）。
    // 文档 R-23-2 曾写"保留"，但 DDL 里没有它 —— 以 DDL 为准，这里不再传。
    await _repo.updateArea(
      cur.copyWith(name: name, areaType: type, floors: floors),
    );
    _refreshLayers();
    state = state.copyWith(clearRequest: true);
  }

  /// 删除当前选中的要素（点 / 线 / 面 / 店铺 / 墙体 / 门）。
  Future<void> deleteSelection() async {
    final s = state.selection;
    if (s == null) return;
    switch (s) {
      case SelPoint():
        // 🔴 v12 把"删点"与"从线上去掉一个点"分成了两个动作（D10）：
        //   · 拐点被摘掉只是那条线少一个弯（仍然画得出来）；
        //   · **端点在它上面时会让整条线缺一个点**（整条线不画）—— 那正是线 3/4
        //     今天看不见的原因，所以 DAO 默认**拒绝**，这里先查清代价再决定。
        final points = await _repo.listPoints(s.domain);
        final cur = points.where((p) => p.id == s.id).firstOrNull;
        if (cur == null) return;
        final report = await _repo.softDeletePoint(cur);
        if (report.affectedLineCount > 0) {
          _note('这个点是 ${report.affectedLineCount} 条线的点，已顺带摘掉：'
              '线还在，只是少了一个弯');
        }
      case SelLine():
        final lines = await _repo.listLines(s.domain);
        final line = lines.where((l) => l.id == s.id).firstOrNull;
        if (line == null) return;
        await _repo.softDeleteLine(line);
      case SelArea():
        final area = await _repo.getArea(s.domain, s.id);
        if (area == null) return;
        await _repo.softDeleteArea(area);
      case SelPlate():
        await _repo.softDeleteEntity(s.id);
        return;
      case SelGate():
        await _repo.softDeleteGate(s.id);
    }
    _refreshLayers();
    state = state.copyWith(clearSelection: true);
  }

  /// 把一个**记录点**标记为「已处理」/「未处理」（第二十二章）。
  ///
  /// 用户原话："已处理的话由用户自行标记，标记已处理的定位点，默认不显示"。
  /// 所以这是**用户下的判断**，系统不替他推断（比如"被线用到了就算处理过"）——
  /// 记录点常常是先记下来、过几天才拿去拼线，自动推断会把还没用上的点藏起来。
  Future<void> markPointProcessed(int id, bool processed) async {
    await _repo.setWorldMarkProcessed(id, processed);
    _refreshLayers();
    _note(
      processed
          ? '已标记为「已处理」—— 浏览地图时不再显示这个点（编辑模式里仍然在）'
          : '已改回「未处理」—— 浏览地图时会显示这个点',
    );
  }

  /// 拖拽移动一个顶点（编辑模式最重要的"改"能力）。
  Future<void> movePoint(MapDomain domain, int id, GeoPoint to) async {
    final points = await _repo.listPoints(domain);
    final cur = points.where((p) => p.id == id).firstOrNull;
    if (cur == null) return;
    await _repo.updatePoint(cur.copyWith(lat: to.lat, lng: to.lng));
    _refreshLayers();
  }
}

final editModeProvider = NotifierProvider<EditModeController, EditState>(
  EditModeController.new,
);

