/// 门属性表单（第十五章重做）。
///
/// 门现在和店铺一样是"吸附在界线上的点"，所以这个表单**不再需要吸附结果**
/// （位置在点线那一刻就定了），只需要填属性：
///   类型（园区门 / 建筑门 / 楼梯口）、名称、什么车能过、要不要刷卡。
///
/// 已移除（用户要求）：时间管制、台阶、单向、启用。
library;

import 'package:flutter/material.dart';

import '../../core/geometry.dart';
import '../../core/models.dart';

/// 门表单的收集结果（位置由调用方连同线一起传回来）。
class GateFormResult {
  const GateFormResult({
    required this.gateType,
    this.name,
    required this.vehicleType,
    required this.accessLevel,
    this.note,
  });

  final GateType gateType;
  final String? name;
  final VehicleType vehicleType;
  final AccessLevel accessLevel;
  final String? note;
}

/// 弹门属性表单。返回 null = 用户取消。
Future<GateFormResult?> showGateFormSheet(
  BuildContext context, {
  required String lineName,
  required GeoPoint center,
  GateRow? initial,
}) => showModalBottomSheet<GateFormResult>(
  context: context,
  isScrollControlled: true,
  builder: (_) =>
      _GateFormSheet(lineName: lineName, center: center, initial: initial),
);

class _GateFormSheet extends StatefulWidget {
  const _GateFormSheet({
    required this.lineName,
    required this.center,
    required this.initial,
  });

  final String lineName;
  final GeoPoint center;
  final GateRow? initial;

  @override
  State<_GateFormSheet> createState() => _GateFormSheetState();
}

class _GateFormSheetState extends State<_GateFormSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?.name ?? '',
  );
  late final TextEditingController _note = TextEditingController(
    text: widget.initial?.note ?? '',
  );

  late GateType _type = widget.initial?.gateType ?? GateType.park;
  late VehicleType _vehicle = widget.initial?.vehicleType ?? VehicleType.evBike;
  late AccessLevel _access = widget.initial?.accessLevel ?? AccessLevel.free;

  bool get _isNew => widget.initial == null;

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
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
              Text(
                _isNew ? '在线上放置门' : '门属性',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                '挂在「${widget.lineName}」上 · '
                '${widget.center.lat.toStringAsFixed(6)}, '
                '${widget.center.lng.toStringAsFixed(6)}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),

              TextField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '门名称',
                  hintText: '例如：北门（正门）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),

              Text('门的类型', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final t in GateType.values)
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
              const SizedBox(height: 6),
              Text(_type.hint, style: theme.textTheme.bodySmall),
              if (_type == GateType.stair) ...[
                const SizedBox(height: 4),
                Text(
                  '（多楼层编辑还没做，现在楼梯口只是一个标记）',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
              const SizedBox(height: 16),

              Text('什么车能过', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              SegmentedButton<VehicleType>(
                segments: const [
                  ButtonSegment(
                    value: VehicleType.all,
                    label: Text('全通行'),
                  ),
                  ButtonSegment(
                    value: VehicleType.evBike,
                    label: Text('电动车'),
                  ),
                  ButtonSegment(
                    value: VehicleType.pedestrian,
                    label: Text('步行'),
                  ),
                  ButtonSegment(value: VehicleType.car, label: Text('汽车')),
                ],
                selected: {_vehicle},
                onSelectionChanged: (s) => setState(() => _vehicle = s.first),
              ),
              const SizedBox(height: 16),

              Text('门禁', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final a in AccessLevel.values)
                    ChoiceChip(
                      label: Text(a.label),
                      selected: _access == a,
                      onSelected: (_) => setState(() => _access = a),
                    ),
                ],
              ),
              const SizedBox(height: 16),

              TextField(
                controller: _note,
                decoration: const InputDecoration(
                  labelText: '备注',
                  hintText: '例如：晚上锁门、从旁边小门绕',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),

              Row(
                children: [
                  if (!_isNew)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('关闭'),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(
                      GateFormResult(
                        gateType: _type,
                        name: _name.text.trim().isEmpty
                            ? null
                            : _name.text.trim(),
                        vehicleType: _vehicle,
                        accessLevel: _access,
                        note: _note.text.trim().isEmpty
                            ? null
                            : _note.text.trim(),
                      ),
                    ),
                    child: Text(_isNew ? '放置' : '保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
