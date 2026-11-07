/// 编辑模式的属性表单（docs/design/12-edit-mode.md §4.4）。
///
/// 五个表单：点、线、区域、店铺、墙体。
///
/// **每一个都是 [StatefulWidget]** —— 这不是风格问题，而是必须：
/// 表单里有 SegmentedButton / ChoiceChip / Switch / Slider，它们的选中态**完全**
/// 依赖外部重建。早期版本把它们写成「一堆局部变量 + 返回静态 widget 树的函数」，
/// 结果是点了选项、变量变了、界面纹丝不动（TextField 看起来正常，因为它自己
/// 管状态），用户会以为属性改不了。这是实际收到过的反馈。
///
/// 表单只负责收集值，不碰数据库；落库由 `EditModeController` 完成。
library;

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/floor_set.dart';
import '../../core/geometry.dart';

// ---------------------------------------------------------------------------
// 返回值
// ---------------------------------------------------------------------------

class LineFormResult {
  const LineFormResult({
    required this.name,
    required this.domain,
    required this.floors,
    this.boundaryType,
    this.routeWidth,
    required this.oneWay,
    this.note,
  });

  final String name;
  final MapDomain domain;
  final FloorSet floors;

  /// **只对界线有意义**（[LineRow.hasMaterial]，由域派生）。路线/行政线时这个字段不代表任何东西，
  /// 调用方**不要**拿它去清空库里的值 —— 见 `saveLineProps` 里的说明。
  final BoundaryType? boundaryType;

  /// **只对路线有意义**（[LineRow.hasRouteWidth]，由域派生）。
  final RouteWidth? routeWidth;

  final bool oneWay;
  final String? note;
}

/// 「保存 or 删除」两种结局。
///
/// 不采用「null 表示取消、特殊字符串表示删除」那种约定：
/// 调用方必须能分清「用户点了取消」和「用户点了删除」。
class FormOutcome<T> {
  const FormOutcome.save(T this.result) : deleted = false;
  const FormOutcome.delete() : result = null, deleted = true;

  final T? result;
  final bool deleted;
}

typedef LineFormOutcome = FormOutcome<LineFormResult>;
typedef ShopFormOutcome = FormOutcome<ShopFormResult>;

class AreaFormResult {
  const AreaFormResult({
    required this.name,
    required this.type,
    required this.floors,
  });

  final String name;
  final AreaType type;
  final FloorSet floors;

  // ⚠️ v12 去掉了 `is_active`（真库全 1，19 章的"停用态"从未被用过）。
}

/// 店铺表单结果（13 章）。位置不在这里 —— 它由"点哪算哪"决定。
class ShopFormResult {
  const ShopFormResult({
    required this.name,
    this.doorNo,
    this.desc,
    required this.width,
  });

  final String name;
  final String? doorNo;
  final String? desc;

  /// 门面宽度（米）。
  final double width;
}

/// 墙体表单结果。
// ---------------------------------------------------------------------------
// 通用外壳
// ---------------------------------------------------------------------------

/// 表单统一的骨架：标题 + 说明 + 内容 + 底部按钮。
///
/// 抽出来是为了让四个表单长得一模一样；每个表单只提供自己的 state 与字段。
class _SheetShell extends StatelessWidget {
  const _SheetShell({
    required this.title,
    required this.subtitle,
    required this.children,
    required this.onCancel,
    required this.onConfirm,
    required this.confirmLabel,
    this.onDelete,
    this.deleteLabel = '删除',
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  final String confirmLabel;
  final VoidCallback? onDelete;
  final String deleteLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      // 键盘弹起时把整张表单顶上去，否则输入框会被挡住
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(subtitle, style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              ...children,
              const SizedBox(height: 16),
              Row(
                children: [
                  if (onDelete != null)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text(deleteLabel),
                    ),
                  const Spacer(),
                  TextButton(onPressed: onCancel, child: const Text('取消')),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: onConfirm, child: Text(confirmLabel)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// **楼层选择器**（第十七章「等高」）。
///
/// 语义：这个要素**参与构成哪些楼层**。默认只有 1 层；
/// 要加第 2 层就点第 2 层那个 chip，要加第 5 层就连点两次「+」把范围摊开。
///
/// 为什么不是"起始层 + 层数"那种输入：承重墙/柱子/楼梯是**贯穿多层**的，
/// 但也可能"只在 1 层和 3 层"（比如 2 层挑空）。集合表达力更强，而且点一下就改。
class FloorPicker extends StatefulWidget {
  const FloorPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.currentFloor,
  });

  final FloorSet value;
  final ValueChanged<FloorSet> onChanged;

  /// 当前正在查看的楼层（会标一个"正在看"的小记号）。
  final int? currentFloor;

  @override
  State<FloorPicker> createState() => _FloorPickerState();
}

class _FloorPickerState extends State<FloorPicker> {
  /// 「+」摊开到的最高层（至少到 [floorCandidates] 给的下界）。
  int _extra = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = floorCandidates(widget.value);
    final shown = [...base, for (var i = 1; i <= _extra; i++) base.last + i];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final f in shown)
              ChoiceChip(
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$f 层'),
                    if (widget.currentFloor == f) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.visibility, size: 12),
                    ],
                  ],
                ),
                selected: widget.value.contains(f),
                onSelected: (_) => widget.onChanged(widget.value.toggle(f)),
              ),
            ActionChip(
              avatar: const Icon(Icons.add, size: 16),
              label: const Text('加层'),
              onPressed: () => setState(() => _extra++),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          widget.value.isGroundOnly
              ? '只有 1 层（默认）。点其它层号可以把它加到多层里去。'
              : '参与构成 ${widget.value.label}'
                    '${widget.value.isContiguous ? '' : '（不连续）'}',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// 表单里的小标题（可选一行说明）。
class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text, {this.hint});
  final String text;
  final String? hint;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(text, style: Theme.of(context).textTheme.labelLarge),
        if (hint != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(hint!, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// 点
// ---------------------------------------------------------------------------

/// **几何点**表单的结果：只剩楼层。
///
/// v12：点表没有 `name` 也没有 `kind`/`source` 了（D9）——
/// 几何点的全部属性就是"坐标 + 参与哪些楼层"。
/// 「这个点是干什么用的」由它落在哪个域表达（`<域>_points`）；
/// 要命名、要"处理状态"，那是**记录点**（[MarkFormResult]）或世界要素的事。
class PointFormResult {
  const PointFormResult({required this.floors});

  final FloorSet floors;
}

typedef PointFormOutcome = FormOutcome<PointFormResult>;

/// **记录点**（`world_marks`）表单的结果：名字 + 楼层。
///
/// 记录点与几何点是两件事：它有名字、有"处理过了吗"、坐标可能来自定位。
class MarkFormResult {
  const MarkFormResult({required this.name, required this.floors});

  final String name;
  final FloorSet floors;
}

typedef MarkFormOutcome = FormOutcome<MarkFormResult>;

Future<MarkFormOutcome?> showMarkForm(
  BuildContext context, {
  String? initialName,
  FloorSet? initialFloors,
  int? currentFloor,
  bool byGps = false,
  double? accuracy,
  bool canDelete = false,
  bool isNew = false,
}) => showModalBottomSheet<MarkFormOutcome>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _MarkFormSheet(
    initialName: initialName,
    initialFloors: initialFloors,
    currentFloor: currentFloor,
    byGps: byGps,
    accuracy: accuracy,
    canDelete: canDelete,
    isNew: isNew,
  ),
);

Future<PointFormOutcome?> showPointForm(
  BuildContext context, {
  FloorSet? initialFloors,
  int? currentFloor,
  bool canDelete = false,
  bool isNew = false,
}) => showModalBottomSheet<PointFormOutcome>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _PointFormSheet(
    initialFloors: initialFloors,
    currentFloor: currentFloor,
    canDelete: canDelete,
    isNew: isNew,
  ),
);

class _PointFormSheet extends StatefulWidget {
  const _PointFormSheet({
    required this.initialFloors,
    required this.currentFloor,
    required this.canDelete,
    required this.isNew,
  });

  final FloorSet? initialFloors;
  final int? currentFloor;
  final bool canDelete;
  final bool isNew;

  @override
  State<_PointFormSheet> createState() => _PointFormSheetState();
}

class _PointFormSheetState extends State<_PointFormSheet> {
  late FloorSet _floors = widget.initialFloors ?? FloorSet.ground;

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      title: widget.isNew ? '落了一个点' : '点属性',
      subtitle: '几何点只有坐标与楼层 —— 它是拼线/拼面的材料。'
          '要命名、要记录位置，请用「记录」模式（那是记录点）',
      confirmLabel: '保存',
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: () => Navigator.of(context).pop(
        PointFormOutcome.save(PointFormResult(floors: _floors)),
      ),
      onDelete: widget.canDelete
          ? () => Navigator.of(context).pop(const PointFormOutcome.delete())
          : null,
      deleteLabel: '删除此点',
      children: [
        const _FieldLabel('楼层（等高）', hint: '这个点参与构成哪些楼层'),
        FloorPicker(
          value: _floors,
          currentFloor: widget.currentFloor,
          onChanged: (v) => setState(() => _floors = v),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 记录点（world_marks）—— v12 起它自己一张表
// ---------------------------------------------------------------------------

class _MarkFormSheet extends StatefulWidget {
  const _MarkFormSheet({
    required this.initialName,
    required this.initialFloors,
    required this.currentFloor,
    required this.byGps,
    required this.accuracy,
    required this.canDelete,
    required this.isNew,
  });

  final String? initialName;
  final FloorSet? initialFloors;
  final int? currentFloor;
  final bool byGps;
  final double? accuracy;
  final bool canDelete;
  final bool isNew;

  @override
  State<_MarkFormSheet> createState() => _MarkFormSheetState();
}

class _MarkFormSheetState extends State<_MarkFormSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName ?? '',
  );
  late FloorSet _floors = widget.initialFloors ?? FloorSet.ground;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      title: widget.isNew ? '记录了一个点' : '记录点属性',
      subtitle: [
        if (widget.byGps) '来源：定位记录',
        if (!widget.byGps) '来源：手点地图',
        if (widget.accuracy != null)
          '精度 ±${widget.accuracy!.toStringAsFixed(0)} m',
      ].join(' · '),
      confirmLabel: '保存',
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: () => Navigator.of(context).pop(
        MarkFormOutcome.save(
          MarkFormResult(name: _name.text.trim(), floors: _floors),
        ),
      ),
      onDelete: widget.canDelete
          ? () => Navigator.of(context).pop(const MarkFormOutcome.delete())
          : null,
      deleteLabel: '删除此记录点',
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '名称',
            hintText: '例如：油甘埔村口',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        const _FieldLabel('楼层（等高）', hint: '这个记录点属于哪些楼层'),
        FloorPicker(
          value: _floors,
          currentFloor: widget.currentFloor,
          onChanged: (v) => setState(() => _floors = v),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 线
// ---------------------------------------------------------------------------

Future<LineFormOutcome?> showLineForm(
  BuildContext context, {
  required String title,
  required String subtitle,
  LineRow? initial,
  FloorSet? initialFloors,
  int? currentFloor,
  bool canDelete = false,
}) => showModalBottomSheet<LineFormOutcome>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _LineFormSheet(
    title: title,
    subtitle: subtitle,
    initial: initial,
    initialFloors: initialFloors,
    currentFloor: currentFloor,
    canDelete: canDelete,
  ),
);

class _LineFormSheet extends StatefulWidget {
  const _LineFormSheet({
    required this.title,
    required this.subtitle,
    required this.initial,
    required this.initialFloors,
    required this.currentFloor,
    required this.canDelete,
  });

  final String title;
  final String subtitle;
  final LineRow? initial;
  final FloorSet? initialFloors;
  final int? currentFloor;
  final bool canDelete;

  @override
  State<_LineFormSheet> createState() => _LineFormSheetState();
}

class _LineFormSheetState extends State<_LineFormSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?.name ?? '',
  );
  late final TextEditingController _note = TextEditingController(
    text: widget.initial?.note ?? '',
  );

  // 新建的线默认落在**世界图**（界线）：编辑模式里界线（围合区域）是主要用途，
  // 而"路线"有独立的工具入口，进来时会带上有值的 initial。
  late MapDomain _domain = widget.initial?.domain ?? MapDomain.world;
  late BoundaryType? _material = widget.initial?.boundaryType;
  late RouteWidth? _routeWidth = widget.initial?.routeWidth;
  late bool _oneWay = widget.initial?.oneWay ?? false;
  late FloorSet _floors =
      widget.initial?.floors ?? widget.initialFloors ?? FloorSet.ground;

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SheetShell(
    title: widget.title,
    subtitle: widget.subtitle,
    confirmLabel: '保存',
    onCancel: () => Navigator.of(context).pop(),
    onConfirm: () => Navigator.of(context).pop(
      LineFormOutcome.save(
        LineFormResult(
          name: _name.text.trim(),
          domain: _domain,
          floors: _floors,
          // 只把**当前域真正拥有的**那个属性交出去：另一个传 null，
          // 由 saveLineProps 判定"不适用 → 保持库里的原值不动"。
          // 判据收在 LineRow.hasMaterial / hasRouteWidth（域派生，只有一处定义）。
          boundaryType: _domain == MapDomain.world ? _material : null,
          routeWidth: _domain == MapDomain.way ? _routeWidth : null,
          oneWay: _oneWay,
          note: _note.text.trim().isEmpty ? null : _note.text.trim(),
        ),
      ),
    ),
    onDelete: widget.canDelete
        ? () => Navigator.of(context).pop(const LineFormOutcome.delete())
        : null,
    deleteLabel: '删除此线',
    children: [
      TextField(
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '线名称',
          hintText: '例如：大运城邦北围墙',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 16),
      const _FieldLabel('线的类型', hint: '界线用来围合区域；路线是自己跑的路径'),
      SegmentedButton<MapDomain>(
        segments: const [
          ButtonSegment(
            value: MapDomain.world,
            icon: Icon(Icons.fence_outlined),
            label: Text('界线'),
          ),
          ButtonSegment(
            value: MapDomain.way,
            icon: Icon(Icons.route_outlined),
            label: Text('路线'),
          ),
          ButtonSegment(
            value: MapDomain.zone,
            icon: Icon(Icons.public_outlined),
            label: Text('行政线'),
          ),
        ],
        selected: {_domain},
        onSelectionChanged: (s) => setState(() => _domain = s.first),
      ),
      const SizedBox(height: 6),
      Text(
        _domain == MapDomain.world
            ? '界线：围合区域的边。物理形态看下面的「边界材质」——'
                  '选「软边界」就是能穿过的界线。'
            : _domain == MapDomain.way
            ? '路线：你自己要走的路。它是什么样的路看下面的「路宽」——'
                  '大马路/小窄路/围栏路，以及能不能骑上去的天桥。'
            : '行政线：虚拟的边界线，只用来圈出行政区域，既不构成墙也不构成路。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      // ---- 属性区：**按类型分岔**（19 章）----
      //
      // 这里以前对界线与路线显示同一组属性（材质 + 通行代价），
      // 结果路线表单问的是"这堵墙是什么材质" —— 用户 2026-09-14 指出：
      // **材质是界线的属性，路宽才是路线的属性**。
      if (_domain == MapDomain.world) ...[
        const SizedBox(height: 16),
        const _FieldLabel('边界材质', hint: '只影响显示与提示，可留空'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('未指定'),
              selected: _material == null,
              onSelected: (_) => setState(() => _material = null),
            ),
            for (final m in BoundaryType.values)
              ChoiceChip(
                avatar: CircleAvatar(
                  backgroundColor: Color(m.defaultColor),
                  radius: 8,
                ),
                label: Text(m.label),
                selected: _material == m,
                onSelected: (_) => setState(() => _material = m),
              ),
          ],
        ),
      ],
      if (_domain == MapDomain.way) ...[
        const SizedBox(height: 16),
        const _FieldLabel('路宽', hint: '这条路是什么样的路，可留空'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('未指定'),
              selected: _routeWidth == null,
              onSelected: (_) => setState(() => _routeWidth = null),
            ),
            for (final w in RouteWidth.values)
              ChoiceChip(
                avatar: CircleAvatar(
                  backgroundColor: Color(w.defaultColor),
                  radius: 8,
                ),
                label: Text(w.label),
                selected: _routeWidth == w,
                onSelected: (_) => setState(() => _routeWidth = w),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _routeWidth?.hint ??
              '选一个最接近的：围栏路（两侧有围栏的通道）、大马路、小窄路、'
                  '骑行天桥（能骑上去）、步行天桥（只能推着走）。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        // 换路口是唯一"通常双向"的类型：路口就是给你两边都能过的，
        // 顺手勾了「单向」会让它在寻路里变成一个只能往一边走的怪东西。
        if (_routeWidth?.isCrossing ?? false) ...[
          const SizedBox(height: 4),
          Text(
            '换路口一般是「双向」的，所以下面的「单向」不用勾。'
            '标完之后如果它没接上围栏路，会提示你先把那两条路的路宽改成「围栏路」。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFFC2185B),
            ),
          ),
        ],
      ],
      const SizedBox(height: 8),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('单向'),
        subtitle: const Text('只能从起点走到终点（寻路用）'),
        value: _oneWay,
        onChanged: (v) => setState(() => _oneWay = v),
      ),
      TextField(
        controller: _note,
        decoration: const InputDecoration(
          labelText: '备注',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 16),
      const _FieldLabel('楼层（等高）', hint: '这条线参与构成哪些楼层'),
      FloorPicker(
        value: _floors,
        currentFloor: widget.currentFloor,
        onChanged: (v) => setState(() => _floors = v),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// 区域
// ---------------------------------------------------------------------------

Future<AreaFormResult?> showAreaForm(
  BuildContext context, {
  required String title,
  required String subtitle,
  AreaRow? initial,
  MapDomain initialDomain = MapDomain.world,
  AreaType? initialType,
  FloorSet? initialFloors,
  int? currentFloor,
}) => showModalBottomSheet<AreaFormResult>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _AreaFormSheet(
    title: title,
    subtitle: subtitle,
    initial: initial,
    initialDomain: initialDomain,
    initialType: initialType,
    initialFloors: initialFloors,
    currentFloor: currentFloor,
  ),
);

class _AreaFormSheet extends StatefulWidget {
  const _AreaFormSheet({
    required this.title,
    required this.subtitle,
    required this.initial,
    this.initialDomain = MapDomain.world,
    this.initialType,
    this.initialFloors,
    this.currentFloor,
  });

  final String title;
  final String subtitle;
  final AreaRow? initial;

  /// 新建时这个区域属于哪个域（由"正在围的东西"决定）。
  ///
  /// v12：**域就是虚实** —— 行政区域是 `zone_areas` 那张表。
  final MapDomain initialDomain;

  /// 新建时的预选类型（实体域才有类型可选）。
  final AreaType? initialType;

  final FloorSet? initialFloors;
  final int? currentFloor;

  @override
  State<_AreaFormSheet> createState() => _AreaFormSheetState();
}

class _AreaFormSheetState extends State<_AreaFormSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?.name ?? '',
  );
  late AreaType _type =
      widget.initial?.areaType ?? widget.initialType ?? AreaType.community;

  late FloorSet _floors =
      widget.initial?.floors ?? widget.initialFloors ?? FloorSet.ground;

  bool get _isNew => widget.initial == null;

  /// 这个区域属于哪个域（决定它是**虚拟的行政区域**还是现实世界里的区域）。
  ///
  /// v12：**域就是虚实** —— 行政区域是 `zone_areas` 那张表，不是 `area_type`
  /// 的一个值。所以这里直接存域，[AreaType] 也就不用再兜一个 `administrative`。
  MapDomain get _domain =>
      widget.initial?.domain ?? widget.initialDomain;

  /// 可选的区域类型。
  ///
  /// 行政域**没有 area_type 这一列**（整张表就是"行政区域"），所以那里不显示类型选择器。
  /// 实体域只给出真正可用的 4 个 —— 让用户先选一个会被拒绝的选项是坏 UI。
  List<AreaType> get _allowedTypes => _domain.isVirtual
      ? const []
      : const [
          AreaType.road,
          AreaType.community,
          AreaType.building,
          AreaType.barrier,
        ];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SheetShell(
    title: widget.title,
    subtitle: widget.subtitle,
    confirmLabel: _isNew ? '创建区域' : '保存',
    onCancel: () => Navigator.of(context).pop(),
    onConfirm: () => Navigator.of(context).pop(
      AreaFormResult(
        name: _name.text.trim().isEmpty ? '未命名区域' : _name.text.trim(),
        type: _type,
        floors: _floors,
      ),
    ),
    children: [
      TextField(
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '区域名称',
          hintText: '例如：大运城邦一期',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 16),
      _FieldLabel(
        '区域类型',
        // 行政域**没有 area_type 这一列** —— 整张表就是"行政区域"
        hint: _domain.isVirtual ? '行政域整域是虚拟的，没有"类型"这个属性' : null,
      ),
      // 用 ChoiceChip 而不是 RadioListTile：后者的 groupValue/onChanged
      // 在 Flutter 3.32 起已弃用（要迁到 RadioGroup），本项目用不到那层复杂度。
      Wrap(
        spacing: 8,
        children: [
          for (final t in _allowedTypes)
            ChoiceChip(
              avatar: CircleAvatar(
                backgroundColor: Color(t.defaultColor),
                radius: 8,
              ),
              label: Text(t.label),
              selected: _type == t,
              onSelected: (_) => setState(() => _type = t),
            ),
        ],
      ),
      const SizedBox(height: 8),
      Text(_type.hint, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 8),
      const _FieldLabel('楼层（等高）', hint: '这个区域参与构成哪些楼层'),
      FloorPicker(
        value: _floors,
        currentFloor: widget.currentFloor,
        onChanged: (v) => setState(() => _floors = v),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// 店铺
// ---------------------------------------------------------------------------

/// 店铺表单。[center] 只用于展示"中心点会落在哪"，不在这里改。
Future<ShopFormOutcome?> showShopForm(
  BuildContext context, {
  required String lineName,
  required GeoPoint center,
  EntityRow? initial,
  int shopCount = 0,
}) => showModalBottomSheet<ShopFormOutcome>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _ShopFormSheet(
    lineName: lineName,
    center: center,
    initial: initial,
    shopCount: shopCount,
  ),
);

class _ShopFormSheet extends StatefulWidget {
  const _ShopFormSheet({
    required this.lineName,
    required this.center,
    required this.initial,
    required this.shopCount,
  });

  final String lineName;
  final GeoPoint center;
  final EntityRow? initial;
  final int shopCount;

  @override
  State<_ShopFormSheet> createState() => _ShopFormSheetState();
}

class _ShopFormSheetState extends State<_ShopFormSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?.name ?? '',
  );
  late final TextEditingController _doorNo = TextEditingController(
    text: widget.initial?.doorNo ?? '',
  );
  late final TextEditingController _desc = TextEditingController(
    text: widget.initial?.desc ?? '',
  );
  late double _width = widget.initial?.width ?? 4.0;

  bool get _isNew => widget.initial == null;

  @override
  void dispose() {
    _name.dispose();
    _doorNo.dispose();
    _desc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _SheetShell(
      title: _isNew ? '在线上添加店铺' : '编辑店铺',
      subtitle: '挂在「${widget.lineName}」上 · '
          '${widget.center.lat.toStringAsFixed(6)}, '
          '${widget.center.lng.toStringAsFixed(6)}',
      confirmLabel: _isNew ? '添加' : '保存',
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: () {
        final name = _name.text.trim();
        if (name.isEmpty && _doorNo.text.trim().isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('店名和门牌号至少要填一个')),
          );
          return;
        }
        Navigator.of(context).pop(
          ShopFormOutcome.save(
            ShopFormResult(
              name: name,
              doorNo: _doorNo.text.trim().isEmpty
                  ? null
                  : _doorNo.text.trim(),
              desc: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
              width: _width,
            ),
          ),
        );
      },
      onDelete: _isNew
          ? null
          : () => Navigator.of(context).pop(const ShopFormOutcome.delete()),
      deleteLabel: '删除此店铺',
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '店名',
            hintText: '例如：沙县小吃 / 美宜佳',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _doorNo,
          decoration: const InputDecoration(
            labelText: '门牌号',
            hintText: '例如：12号 / 3栋2单元',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _desc,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: '描述',
            hintText: '例如：后门可进、晚上十点关',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        const _FieldLabel('宽度', hint: '门面沿街占多宽（米）'),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: _width.clamp(0.5, 40),
                min: 0.5,
                max: 40,
                divisions: 79,
                label: _width.toStringAsFixed(1),
                onChanged: (v) => setState(() => _width = v),
              ),
            ),
            SizedBox(
              width: 56,
              child: Text(
                '${_width.toStringAsFixed(1)} m',
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
        Text(
          '中心点就是你在线上点的位置；渲染时若中心点不在线上，'
          '会自动吸附到线上离它最近的点。',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 墙体
// ---------------------------------------------------------------------------

/// 世界要素详情面板用的一段人话（名字/门牌号/宽度/描述/中心点）。
///
/// v12：**没有"材质"了** —— 它只属于线（界线），不属于挂在线上的要素。
String describeLineFeature(
  EntityRow e, {
  String? placement,
  String? widthText,
}) {
  final parts = <String>['类型：${e.entityType.label}'];
  if (e.doorNo != null && e.doorNo!.isNotEmpty) parts.add('门牌号：${e.doorNo}');
  parts.add('宽度：${widthText ?? '${e.effectiveWidth.toStringAsFixed(1)} m'}');
  if (e.desc != null && e.desc!.isNotEmpty) parts.add('描述：${e.desc}');
  parts.add(
    '中心点：${e.lat.toStringAsFixed(6)}, ${e.lng.toStringAsFixed(6)}',
  );
  if (placement != null) parts.add(placement);
  return parts.join('\n');
}
