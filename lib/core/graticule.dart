/// 经纬线参考网格的**刻度计算**（第十六章）。
///
/// 纯 Dart、零 Flutter 依赖：这一层只负责"该画哪些线、该不该画"，
/// 画出来是 `features/map/graticule_layer.dart` 的事。
/// 拆开是因为刻度生成有两个容易出错的地方（浮点漂移、范围失控），
/// 放在纯函数里才能脱离界面验证。
library;

/// 默认网格间距（度）。0.1° 在凤岗—龙岗一带 ≈ 11 km。
const double kGraticuleStep = 0.1;

/// 单方向最多画多少条。
///
/// 纯粹是防御性的：万一缩放/边界算出个离谱的范围（比如初始化瞬间的
/// 退化 bounds），不至于一帧内生成几万条线把界面卡死。
const int kGraticuleMaxLinesPerAxis = 80;

/// 生成 `[from, to]` 区间内**所有整 [step] 刻度**（含两端所在刻度）。
///
/// ⚠️ 用**整数下标 × step** 生成，而不是 `v += step` 反复累加。
/// 0.1 在二进制里除不尽，累加到第 3 条就变成 `22.800000000000004`，
/// 标签会显示成怪数字、和"整刻度"对不上。
/// （测试脚本里有一条断言专门盯这件事。）
List<double> graticuleTicks(double from, double to, {double step = kGraticuleStep}) {
  if (step <= 0 || to < from) return const [];
  final i0 = (from / step).floor();
  final i1 = (to / step).ceil();
  if (i1 - i0 > kGraticuleMaxLinesPerAxis) return const [];
  return [for (var i = i0; i <= i1; i++) i * step];
}

/// 这个范围是不是密到该放弃绘制。
bool graticuleTooDense(double from, double to, {double step = kGraticuleStep}) {
  if (step <= 0 || to < from) return true;
  return ((to / step).ceil() - (from / step).floor()) > kGraticuleMaxLinesPerAxis;
}

/// 刻度标签文案（`22.7°N` / `114.2°E`）。
String graticuleLabel(double value, {required bool isLat}) =>
    '${value.toStringAsFixed(1)}°${isLat ? 'N' : 'E'}';
