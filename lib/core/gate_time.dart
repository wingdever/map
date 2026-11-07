/// 门的通行属性（docs/design/05-routing.md §3、第十五章）。
///
/// **第十五章把时间管制整套移除了**（用户要求）：门不再有开放时间窗、
/// 台阶、单向、启用开关。现在只剩两个属性轴：
///   1. **什么车能过**（[VehicleType]）；
///   2. **要不要刷卡 / 登记**（[AccessLevel]）。
///
/// 原来的 `TimeSlotRule` / `TimeSlots` / `isOpenAt` / `untilNextOpen`
/// 一并删除 —— 它们当时唯一的消费方就是这里的求值函数，
/// 而求值函数又只服务于地图上的旗标颜色。留着就是没人读的死代码。
/// 真正需要时间窗的是**寻路**（M2，05 章）；到那时按路由求值的需要重建，
/// 现在凭空保留一套没被用过的算法只会误导后来的人。
///
/// 纯 Dart、零 Flutter 依赖。
library;

import 'models.dart';

// v12：`VehicleType` / `AccessLevel` 是**门的列**（world_gates.vehicle_type /
// access_level），所以它们搬去了 models.dart。以前这里也各定义一份，
// 结果是每个 import 这个文件的地方都要提防 `ambiguous_import`
// —— 同一个枚举两处定义，改了一处另一处不会跟着变。
//
// 这里只留"由车型 + 门禁推导出的**门状态**"那点求值逻辑（04 章旗标颜色用它）。

/// 门当前状态（推导值，不落库；04 章 §3 旗标语义）。
enum GateStatus {
  open('可进'),
  restricted('需刷卡/登记'),
  vehicleDenied('本车型禁行'),
  unknown('未知');

  const GateStatus(this.label);
  final String label;
}

/// 门禁求值输入（来自 gates 行，见 03 章 §4.2）。
class GateEvalInput {
  const GateEvalInput({required this.vehicleType, required this.accessLevel});

  final VehicleType vehicleType;
  final AccessLevel accessLevel;
}

/// 主求值函数（05 章 §3.2 的精简版）。
///
/// 我 = [myVehicle]（默认电动车）。返回状态 + 可读说明。
({GateStatus status, String message}) evaluateGate(
  GateEvalInput gate, {
  VehicleType myVehicle = VehicleType.evBike,
}) {
  // 1 车型不满足（电动车可满足 ev_bike/pedestrian/all，不满足 car；
  //   pedestrian 门对电动车=需下车推行，仍视为可通行，05 章 §3.2）
  if (!_gateAllows(gate.vehicleType, myVehicle)) {
    return (
      status: GateStatus.vehicleDenied,
      message: '${gate.vehicleType.label}禁行',
    );
  }
  // 2 门禁强度
  if (gate.accessLevel != AccessLevel.free) {
    return (status: GateStatus.restricted, message: gate.accessLevel.label);
  }
  return (status: GateStatus.open, message: '可进');
}

/// 门是否允许「我（myVehicle）」通行。all=全通行；与车型相同可通过；
/// pedestrian 门对电动车需推行仍视为可通（推行成本由寻路层惩罚）。
bool _gateAllows(VehicleType gateType, VehicleType mine) {
  if (gateType == VehicleType.all) return true;
  if (gateType == mine) return true;
  if (gateType == VehicleType.pedestrian && mine == VehicleType.evBike) {
    return true;
  }
  return false;
}
