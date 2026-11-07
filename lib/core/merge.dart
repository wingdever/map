/// 备份合并（docs/design/11-backup-export-import.md + 23 章 §8.1）
///
/// 导入**不是覆盖式恢复，而是按业务键的幂等合并**：
/// - 同一个文件导两次 → 第二次全部跳过，不会翻倍；
/// - A 机 / B 机各画一半 → 合起来两边都在。
///
/// 本文件是**纯 Dart、零依赖**：只做计划（[planMerge]）与执行（[applyMergePlan]），
/// 不碰数据库 —— 执行时由调用方给一个 `insert(table, values)`。
///
/// ## 🔴 业务键必须带「判别信息」—— 这是第 4、5 次同类教训
///
/// | 章 | 教训 |
/// |----|------|
/// | 17 | 键必须带**楼层**（1 层与 2 层足迹重合 → 整层丢失） |
/// | 18 | 键必须带**拐点**（端点相同、拐法不同的两条折线会静默合并） |
/// | 23 | 键必须带**域前缀**（实测有 4 个点在两个域各存一份、坐标完全相同） |
/// | 23 | 世界要素的键必须带 **`entity_type`**（同位置同名的店铺与停车点是两条记录） |
/// | 23 | 封闭图形的键必须区分 **`area` / `poly`**（同一块地转过一次构造方式 → 否则静默丢掉一次转换） |
///
/// 所以本文件里每一个键函数的第一件事都是把"它到底是什么"写进去。
library;

import 'dart:math' as math;

import 'export.dart';
import 'floor_set.dart';
import 'geometry.dart';
import 'line_edit.dart';
import 'models.dart';
import 'ring.dart';

/// 键里坐标的小数位。7 位 ≈ 1.1 cm —— 手工画图远达不到这个精度，
/// 而再细就会因为浮点尾数不同而"同一个点算成两个"。
const int kPointKeyDecimals = 7;

/// 区域的键用更少的位数（5 位 ≈ 1.1 m）：质心是算出来的，允许一点点漂移。
const int kAreaKeyDecimals = 5;

// ---------------------------------------------------------------------------
// 业务键
// ---------------------------------------------------------------------------

/// 点键：`"域:point|纬度,经度@楼层"`。
///
/// **域前缀是必须的**：三个域的点表各有各的自增 id，而 v11→v12 迁移时
/// 有 4 个点被**复制**到两个域（原来被界线和路线共用的那 4 个"围墙拐角 = 路口"），
/// 它们的坐标完全相同 —— 键不带域就会在导入时互相顶掉一个。
String pointKeyOf(MapDomain d, GeoPoint p, [FloorSet? floors]) =>
    '${d.prefix}:point|'
    '${p.lat.toStringAsFixed(kPointKeyDecimals)},'
    '${p.lng.toStringAsFixed(kPointKeyDecimals)}'
    '@${(floors ?? FloorSet.ground).shortLabel}';

/// 封闭图形的键：`"域:area|名字|质心@楼层"`（多边形用 `poly`）。
///
/// 两个端点键**排序**后才拼：正着画与倒着画是同一条线。
String _shapeKeyOf(
  String what,
  MapDomain d,
  String name,
  List<GeoPoint>? ring,
  FloorSet? floors,
) {
  final fl = (floors ?? FloorSet.ground).shortLabel;
  final c = ringCentroid(ring);
  if (c == null) return '${d.prefix}:$what|$name|noRing@$fl';
  return '${d.prefix}:$what|$name|'
      '${c.lat.toStringAsFixed(kAreaKeyDecimals)},'
      '${c.lng.toStringAsFixed(kAreaKeyDecimals)}@$fl';
}

/// 区域键（**由线围成**）。
String areaKeyOf(MapDomain d, String name, List<GeoPoint>? ring, [FloorSet? fl]) =>
    _shapeKeyOf('area', d, name, ring, fl);

/// 多边形键（**由点围成**）。
///
/// 与 [areaKeyOf] 只差一个词，但**必须有这个差别**：同一块地转过一次
/// 构造方式之后，键若不区分就会被当成同一块地，导入时静默丢掉一次转换。
String polygonKeyOf(
  MapDomain d,
  String name,
  List<GeoPoint>? ring, [
  FloorSet? fl,
]) => _shapeKeyOf('poly', d, name, ring, fl);

/// 线键：`"域:line|端点键|端点键|排序后的拐点键"`。
///
/// 没有拐点时**保持老格式**（只有两段）—— 这样拿一份老备份再导一次，
/// 两点直线仍然被认成"已存在"，不会整库翻倍。
///
/// [startPointKey] / [endPointKey] 会被排序；[bendVertexKeys] 也会排序
/// （正着画/倒着画是同一条线）。**域已经在前缀里，不再需要 kind。**
String lineKeyOf(
  MapDomain d, {
  required String startPointKey,
  required String endPointKey,
  List<String> bendVertexKeys = const [],
}) {
  final (a, b) = startPointKey.compareTo(endPointKey) <= 0
      ? (startPointKey, endPointKey)
      : (endPointKey, startPointKey);
  final head = '${d.prefix}:line|$a|$b';
  if (bendVertexKeys.isEmpty) return head;
  final sorted = [...bendVertexKeys]..sort();
  return '$head|${sorted.join(';')}';
}

/// 门键：`"world:gate|类型|名字|所属线键"`。
String gateKeyOf({
  required GateType type,
  required String? name,
  required String? lineKey,
}) => 'world:gate|${type.storage}|${name ?? ''}|${lineKey ?? ''}';

/// 世界要素键：`"world:entity|**类型**|名字|门牌号|所属线键"`。
///
/// 🔴 类型必须在键里（D18）：同一位置同名的「店铺」与「停车点」是两条记录。
String entityKeyOf({
  required EntityType type,
  required String name,
  String? doorNo,
  String? lineKey,
}) =>
    'world:entity|${type.storage}|$name|${doorNo ?? ''}|${lineKey ?? ''}';

/// 记录点键：`"world:mark|纬度,经度@楼层"`。
///
/// 记录点的身份就是"那个位置" —— 是手点的还是定位来的不参与身份。
String markKeyOf(GeoPoint p, [FloorSet? floors]) =>
    'world:mark|'
    '${p.lat.toStringAsFixed(kPointKeyDecimals)},'
    '${p.lng.toStringAsFixed(kPointKeyDecimals)}'
    '@${(floors ?? FloorSet.ground).shortLabel}';

/// 轨迹段键：`"way:trip|段标识"`（段标识就是开始记录的时刻）。
String tripKeyOf(String trip) => 'way:trip|$trip';

/// 关联键（area_lines）：`"区域键|线键"`。
String areaLineKeyOf(String areaKey, String lineKey) => '$areaKey|$lineKey';

// ---------------------------------------------------------------------------
// 现有库的索引
// ---------------------------------------------------------------------------

/// 现有库的「业务键 → id」索引（按域分开：同名键在不同域是不同东西）。
class MergeIndex {
  const MergeIndex({
    required this.pointIds,
    required this.lineIds,
    required this.areaIds,
    required this.polygonIds,
    required this.gateIds,
    required this.entityKeys,
    required this.markKeys,
    required this.tripKeys,
    required this.areaLineKeys,
  });

  final Map<String, int> pointIds;
  final Map<String, int> lineIds;
  final Map<String, int> areaIds;
  final Map<String, int> polygonIds;
  final Map<String, int> gateIds;
  final Set<String> entityKeys;
  final Set<String> markKeys;
  final Set<String> tripKeys;
  final Set<String> areaLineKeys;

  bool get isEmpty =>
      pointIds.isEmpty &&
      lineIds.isEmpty &&
      areaIds.isEmpty &&
      polygonIds.isEmpty &&
      gateIds.isEmpty &&
      entityKeys.isEmpty &&
      markKeys.isEmpty &&
      tripKeys.isEmpty;
}

/// 把现有库的快照索引成"业务键 → id"。
MergeIndex buildMergeIndex(ExportBundle snap) {
  final pointIds = <String, int>{};
  final lineIds = <String, int>{};
  final areaIds = <String, int>{};
  final polygonIds = <String, int>{};
  final gateIds = <String, int>{};
  final entityKeys = <String>{};
  final markKeys = <String>{};
  final tripKeys = <String>{};
  final areaLineKeys = <String>{};

  final geoByDomain = <MapDomain, Map<int, GeoPoint>>{};
  final floorsByDomain = <MapDomain, Map<int, FloorSet>>{};
  for (final d in MapDomain.values) {
    final geo = <int, GeoPoint>{};
    final fl = <int, FloorSet>{};
    for (final p in snap.points[d] ?? const <PointRow>[]) {
      if (p.id == null) continue;
      geo[p.id!] = p.geo;
      fl[p.id!] = p.floors ?? FloorSet.ground;
      pointIds.putIfAbsent(pointKeyOf(d, p.geo, p.floors), () => p.id!);
    }
    geoByDomain[d] = geo;
    floorsByDomain[d] = fl;
  }

  // 区域的环：优先用快照里已经组好的，缺了就现场组
  final rings = resolveAreaRings(snap);

  final lineKeyById = <(MapDomain, int), String>{};
  for (final d in MapDomain.values) {
    for (final l in snap.lines[d] ?? const <LineRow>[]) {
      if (l.id == null) continue;
      final k = _lineKeyFromRefs(d, l, geoByDomain[d]!, floorsByDomain[d]!);
      if (k == null) continue;
      lineKeyById[(d, l.id!)] = k;
      lineIds.putIfAbsent(k, () => l.id!);
    }
  }

  for (final d in MapDomain.values) {
    for (final a in snap.areas[d] ?? const <AreaRow>[]) {
      if (a.id == null) continue;
      final ak = areaKeyOf(d, a.name, rings[(d, a.id!)], a.floors);
      areaIds.putIfAbsent(ak, () => a.id!);
      for (final lineId in a.lineIds) {
        final lk = lineKeyById[(d, lineId)];
        if (lk != null) areaLineKeys.add(areaLineKeyOf(ak, lk));
      }
    }
  }

  for (final pg in snap.polygons) {
    if (pg.id == null) continue;
    final ring = snap.polygonRings[pg.id!];
    polygonIds.putIfAbsent(
      polygonKeyOf(pg.domain, pg.name, ring, pg.floors),
      () => pg.id!,
    );
  }

  for (final g in snap.gates) {
    final lk = g.lineId == null ? null : lineKeyById[(MapDomain.world, g.lineId!)];
    gateIds.putIfAbsent(
      gateKeyOf(type: g.gateType, name: g.name, lineKey: lk),
      () => g.id!,
    );
  }

  for (final e in snap.entities) {
    final lk = e.lineId == null ? null : lineKeyById[(MapDomain.world, e.lineId!)];
    entityKeys.add(
      entityKeyOf(
        type: e.entityType,
        name: e.name,
        doorNo: e.doorNo,
        lineKey: lk,
      ),
    );
  }

  for (final m in snap.marks) {
    markKeys.add(markKeyOf(m.geo, m.floors));
  }

  for (final t in snap.tracks) {
    tripKeys.add(tripKeyOf(t.trip));
  }

  return MergeIndex(
    pointIds: pointIds,
    lineIds: lineIds,
    areaIds: areaIds,
    polygonIds: polygonIds,
    gateIds: gateIds,
    entityKeys: entityKeys,
    markKeys: markKeys,
    tripKeys: tripKeys,
    areaLineKeys: areaLineKeys,
  );
}

/// 每个区域的环：优先用快照里组好的，缺了就用它的成员线现场组。
///
/// 为什么要有这条兜底：文件里若缺某个区域的多边形，键会退化成 `名字|noRing`，
/// 而现有库那边算出的是 `名字|质心` —— 同一个区域会被误判成新块，导入出重复。
Map<(MapDomain, int), List<GeoPoint>> resolveAreaRings(ExportBundle snap) {
  final out = <(MapDomain, int), List<GeoPoint>>{for (final e in snap.areaRings.entries) e.key: e.value};
  for (final d in MapDomain.values) {
    final geo = <int, GeoPoint>{
      for (final p in snap.points[d] ?? const <PointRow>[])
        if (p.id != null) p.id!: p.geo,
    };
    final byId = <int, LineRow>{
      for (final l in snap.lines[d] ?? const <LineRow>[])
        if (l.id != null) l.id!: l,
    };
    for (final a in snap.areas[d] ?? const <AreaRow>[]) {
      if (a.id == null) continue;
      if (out.containsKey((d, a.id!))) continue;
      final members = [
        for (final id in a.lineIds)
          if (byId[id] != null) byId[id]!,
      ];
      if (members.isEmpty) continue;
      try {
        out[(d, a.id!)] = assembleAreaRing(members, geo);
      } catch (_) {
        // 组不出来就让它退化成 noRing 键（与现有库那侧的算法保持一致）
      }
    }
  }
  return out;
}

String? _lineKeyFromRefs(
  MapDomain d,
  LineRow l,
  Map<int, GeoPoint> geo,
  Map<int, FloorSet> floors,
) {
  final keys = <String>[];
  for (final id in l.pointIds) {
    final g = geo[id];
    if (g == null) return null;
    keys.add(pointKeyOf(d, g, floors[id]));
  }
  if (keys.length < 2) return null;
  return lineKeyOf(
    d,
    startPointKey: keys.first,
    endPointKey: keys.last,
    bendVertexKeys: keys.length > 2 ? keys.sublist(1, keys.length - 1) : const [],
  );
}

// ---------------------------------------------------------------------------
// 合并计划
// ---------------------------------------------------------------------------

/// 一条待执行的写入。每个 op 都知道自己要落哪张表。
sealed class MergeOp {
  const MergeOp();
}

class InsertPoint extends MergeOp {
  const InsertPoint({required this.domain, required this.key, required this.row});
  final MapDomain domain;
  final String key;
  final PointRow row;
}

class InsertLine extends MergeOp {
  const InsertLine({
    required this.domain,
    required this.key,
    required this.row,
    required this.startPointKey,
    required this.endPointKey,
    required this.bendPointKeys,
  });
  final MapDomain domain;
  final String key;
  final LineRow row;
  final String startPointKey;
  final String endPointKey;
  final List<String> bendPointKeys;
}

class InsertArea extends MergeOp {
  const InsertArea({
    required this.domain,
    required this.key,
    required this.row,
    required this.lineKeys,
  });
  final MapDomain domain;
  final String key;
  final AreaRow row;
  final List<String> lineKeys;
}

class InsertPolygon extends MergeOp {
  const InsertPolygon({
    required this.key,
    required this.row,
    required this.pointKeys,
  });
  final String key;
  final PolygonRow row;
  final List<String> pointKeys;
}

class InsertGate extends MergeOp {
  const InsertGate({required this.key, required this.row, this.lineKey});
  final String key;
  final GateRow row;
  final String? lineKey;
}

class InsertEntity extends MergeOp {
  const InsertEntity({required this.key, required this.row, this.lineKey});
  final String key;
  final EntityRow row;
  final String? lineKey;
}

class InsertMark extends MergeOp {
  const InsertMark({required this.key, required this.row});
  final String key;
  final WorldMarkRow row;
}

/// 一整段轨迹一次进来（它的身份是"那一段"，不能按点去重）。
class InsertTrack extends MergeOp {
  const InsertTrack({required this.key, required this.marks});
  final String key;
  final List<WayMarkRow> marks;
}

/// 合并统计（导入预览与结果提示都用它）。
class MergeStats {
  const MergeStats({
    this.pointsAdded = 0,
    this.linesAdded = 0,
    this.areasAdded = 0,
    this.polygonsAdded = 0,
    this.gatesAdded = 0,
    this.entitiesAdded = 0,
    this.marksAdded = 0,
    this.tracksAdded = 0,
    this.skipped = 0,
  });

  final int pointsAdded;
  final int linesAdded;
  final int areasAdded;
  final int polygonsAdded;
  final int gatesAdded;
  final int entitiesAdded;
  final int marksAdded;
  final int tracksAdded;
  final int skipped;

  int get added =>
      pointsAdded +
      linesAdded +
      areasAdded +
      polygonsAdded +
      gatesAdded +
      entitiesAdded +
      marksAdded +
      tracksAdded;

  bool get isEmpty => added == 0 && skipped == 0;

  MergeStats operator +(MergeStats o) => MergeStats(
    pointsAdded: pointsAdded + o.pointsAdded,
    linesAdded: linesAdded + o.linesAdded,
    areasAdded: areasAdded + o.areasAdded,
    polygonsAdded: polygonsAdded + o.polygonsAdded,
    gatesAdded: gatesAdded + o.gatesAdded,
    entitiesAdded: entitiesAdded + o.entitiesAdded,
    marksAdded: marksAdded + o.marksAdded,
    tracksAdded: tracksAdded + o.tracksAdded,
    skipped: skipped + o.skipped,
  );

  /// 中文摘要（导入预览面板直接显示）。
  String get summary {
    final parts = <String>[
      if (pointsAdded > 0) '点 $pointsAdded',
      if (linesAdded > 0) '线 $linesAdded',
      if (areasAdded > 0) '区域 $areasAdded',
      if (polygonsAdded > 0) '多边形 $polygonsAdded',
      if (gatesAdded > 0) '门 $gatesAdded',
      if (entitiesAdded > 0) '世界要素 $entitiesAdded',
      if (marksAdded > 0) '记录点 $marksAdded',
      if (tracksAdded > 0) '轨迹段 $tracksAdded',
    ];
    if (parts.isEmpty) {
      return skipped > 0 ? '全部 $skipped 项都已存在，无需导入' : '没有可导入的内容';
    }
    final s = '新增 ${parts.join('、')}';
    return skipped > 0 ? '$s；另跳过 $skipped 项（已存在）' : s;
  }
}

/// 一份不落库的合并计划。
class MergePlan {
  MergePlan({required this.ops, required this.stats});

  final List<MergeOp> ops;
  final MergeStats stats;

  bool get isEmpty => ops.isEmpty;
}

/// 比对现有库与备份，算出该新增什么。
MergePlan planMerge({
  required ExportBundle existing,
  required ExportBundle incoming,
}) {
  final index = buildMergeIndex(existing);
  final ops = <MergeOp>[];
  var skipped = 0;
  var pointsAdded = 0, linesAdded = 0, areasAdded = 0, polygonsAdded = 0;
  var gatesAdded = 0, entitiesAdded = 0, marksAdded = 0, tracksAdded = 0;

  // ---- 键集合：现有库 + 本次已计划（文件内部重复也要折叠） ----
  final pointKeys = Set<String>.of(index.pointIds.keys);
  final lineKeys = Set<String>.of(index.lineIds.keys);
  final areaKeys = Set<String>.of(index.areaIds.keys);
  final polygonKeys = Set<String>.of(index.polygonIds.keys);
  final gateKeys = Set<String>.of(index.gateIds.keys);
  final entityKeys = Set<String>.of(index.entityKeys);
  final markKeys = Set<String>.of(index.markKeys);
  final tripKeys = Set<String>.of(index.tripKeys);

  // 备份内部的"旧 id → 键"（解析引用用）
  final pointKeyById = <(MapDomain, int), String>{};
  final pointGeoById = <(MapDomain, int), GeoPoint>{};
  final pointFloorsById = <(MapDomain, int), FloorSet>{};
  final lineKeyById = <(MapDomain, int), String>{};

  for (final d in MapDomain.values) {
    for (final p in incoming.points[d] ?? const <PointRow>[]) {
      if (p.id == null) continue;
      final k = pointKeyOf(d, p.geo, p.floors);
      pointKeyById[(d, p.id!)] = k;
      pointGeoById[(d, p.id!)] = p.geo;
      pointFloorsById[(d, p.id!)] = p.floors ?? FloorSet.ground;
    }
  }
  for (final d in MapDomain.values) {
    for (final l in incoming.lines[d] ?? const <LineRow>[]) {
      if (l.id == null) continue;
      final k = _lineKeyFromRefs(d, l, {
        for (final e in pointGeoById.entries)
          if (e.key.$1 == d) e.key.$2: e.value,
      }, {
        for (final e in pointFloorsById.entries)
          if (e.key.$1 == d) e.key.$2: e.value,
      });
      if (k != null) lineKeyById[(d, l.id!)] = k;
    }
  }

  // ---- 1. 点 ----
  for (final d in MapDomain.values) {
    for (final p in incoming.points[d] ?? const <PointRow>[]) {
      final k = p.id == null ? pointKeyOf(d, p.geo, p.floors) : pointKeyById[(d, p.id!)]!;
      if (!pointKeys.add(k)) {
        skipped++;
        continue;
      }
      ops.add(InsertPoint(domain: d, key: k, row: p));
      pointsAdded++;
    }
  }

  // ---- 2. 线（拐点必须一起进来，否则会建出一条"拉直"的假路） ----
  for (final d in MapDomain.values) {
    for (final l in incoming.lines[d] ?? const <LineRow>[]) {
      final startK = pointKeyById[(d, l.startPointId)];
      final endK = pointKeyById[(d, l.endPointId)];
      if (startK == null || endK == null) {
        skipped++;
        continue; // 端点缺定义：这条线导不进来（宁可跳过，也不要建一条形状错的）
      }
      final bendKs = <String>[];
      var missing = false;
      for (final id in l.bendPointIds) {
        final k = pointKeyById[(d, id)];
        if (k == null) {
          missing = true;
          break;
        }
        bendKs.add(k);
      }
      if (missing) {
        skipped++;
        continue;
      }
      final k = lineKeyOf(
        d,
        startPointKey: startK,
        endPointKey: endK,
        bendVertexKeys: bendKs,
      );
      if (!lineKeys.add(k)) {
        skipped++;
        continue;
      }
      ops.add(
        InsertLine(
          domain: d,
          key: k,
          row: l,
          startPointKey: startK,
          endPointKey: endK,
          bendPointKeys: bendKs,
        ),
      );
      linesAdded++;
    }
  }

  // ---- 3. 区域（由线围成）----
  final rings = resolveAreaRings(incoming);
  for (final d in MapDomain.values) {
    for (final a in incoming.areas[d] ?? const <AreaRow>[]) {
      final ring = a.id == null ? null : rings[(d, a.id!)];
      final ak = areaKeyOf(d, a.name, ring, a.floors);
      final lineKs = <String>[
        for (final id in a.lineIds)
          if (lineKeyById[(d, id)] != null) lineKeyById[(d, id)]!,
      ];
      if (!areaKeys.add(ak)) {
        skipped++;
        continue;
      }
      ops.add(
        InsertArea(domain: d, key: ak, row: a, lineKeys: lineKs),
      );
      areasAdded++;
    }
  }

  // ---- 4. 多边形（由点围成）----
  for (final pg in incoming.polygons) {
    final ring = pg.id == null ? null : incoming.polygonRings[pg.id!];
    final pk = polygonKeyOf(pg.domain, pg.name, ring, pg.floors);
    final pointKs = <String>[];
    for (final id in pg.pointIds) {
      final k = pointKeyById[(pg.domain, id)];
      if (k != null) pointKs.add(k);
    }
    if (pointKs.length < 3) {
      skipped++;
      continue; // 环上的点凑不齐，这个多边形导不进来
    }
    if (!polygonKeys.add(pk)) {
      skipped++;
      continue;
    }
    ops.add(InsertPolygon(key: pk, row: pg, pointKeys: pointKs));
    polygonsAdded++;
  }

  // ---- 5. 门 ----
  for (final g in incoming.gates) {
    final lk = g.lineId == null ? null : lineKeyById[(MapDomain.world, g.lineId!)];
    final k = gateKeyOf(type: g.gateType, name: g.name, lineKey: lk);
    if (!gateKeys.add(k)) {
      skipped++;
      continue;
    }
    ops.add(InsertGate(key: k, row: g, lineKey: lk));
    gatesAdded++;
  }

  // ---- 6. 世界要素 ----
  for (final e in incoming.entities) {
    final lk = e.lineId == null ? null : lineKeyById[(MapDomain.world, e.lineId!)];
    final k = entityKeyOf(
      type: e.entityType,
      name: e.name,
      doorNo: e.doorNo,
      lineKey: lk,
    );
    if (!entityKeys.add(k)) {
      skipped++;
      continue;
    }
    ops.add(InsertEntity(key: k, row: e, lineKey: lk));
    entitiesAdded++;
  }

  // ---- 7. 记录点 ----
  for (final m in incoming.marks) {
    final k = markKeyOf(m.geo, m.floors);
    if (!markKeys.add(k)) {
      skipped++;
      continue;
    }
    ops.add(InsertMark(key: k, row: m));
    marksAdded++;
  }

  // ---- 8. 轨迹：**按段**去重（一段的身份是"那一段"，不按点算） ----
  final tracksByTrip = <String, List<WayMarkRow>>{};
  for (final t in incoming.tracks) {
    tracksByTrip.putIfAbsent(t.trip, () => []).add(t);
  }
  for (final e in tracksByTrip.entries) {
    final k = tripKeyOf(e.key);
    if (!tripKeys.add(k)) {
      skipped++;
      continue;
    }
    ops.add(InsertTrack(key: k, marks: e.value));
    tracksAdded++;
  }

  return MergePlan(
    ops: ops,
    stats: MergeStats(
      pointsAdded: pointsAdded,
      linesAdded: linesAdded,
      areasAdded: areasAdded,
      polygonsAdded: polygonsAdded,
      gatesAdded: gatesAdded,
      entitiesAdded: entitiesAdded,
      marksAdded: marksAdded,
      tracksAdded: tracksAdded,
      skipped: skipped,
    ),
  );
}

// ---------------------------------------------------------------------------
// 执行
// ---------------------------------------------------------------------------

/// 一行插入：返回新的 rowid。DAO 传 `(table, values) => txn.insert(table, values)`。
typedef RowInserter = Future<int> Function(
  String table,
  Map<String, Object?> values,
);

/// 执行一份计划（调用方负责包在**一个事务**里，失败整体回滚）。
///
/// 顺序不能乱：**点先落**（线要引用它们）、然后是线/多边形，最后才是
/// 依赖线键的门与世界要素。
Future<MergeStats> applyMergePlan(MergePlan plan, RowInserter insert) async {
  final pointIds = <String, int>{};
  final lineIds = <String, int>{};
  final areaIds = <String, int>{};

  // pass 1：点
  for (final op in plan.ops) {
    if (op is InsertPoint) {
      pointIds[op.key] = await insert(
        op.domain.pointsTable,
        op.row.toDb()..remove('id'),
      );
    }
  }

  // pass 2：线 + 多边形（要引用点；线还要写链）
  for (final op in plan.ops) {
    switch (op) {
      case InsertLine():
        final values = op.row.toDb()..remove('id');
        values['start_point_id'] = pointIds[op.startPointKey];
        values['end_point_id'] = pointIds[op.endPointKey];
        final lineId = await insert(op.domain.linesTable, values);
        lineIds[op.key] = lineId;
        // 形状必须**等线拿到新 id 之后**再写，而且写成**链**（D13）
        final ids = <int>[
          pointIds[op.startPointKey]!,
          for (final k in op.bendPointKeys)
            if (pointIds[k] != null) pointIds[k]!,
          pointIds[op.endPointKey]!,
        ];
        final beforeOf = beforeOfFromPoints(ids);
        for (final e in beforeOf.entries) {
          await insert(op.domain.lineBendsTable, {
            'line_id': lineId,
            'point_id': e.key,
            'before_point_id': e.value,
          });
        }

      case InsertPolygon():
        final values = op.row.toDb()..remove('id');
        final polygonId = await insert(op.row.table, values);
        final ids = [
          for (final k in op.pointKeys)
            if (pointIds[k] != null) pointIds[k]!,
        ];
        // 环链：首尾相接（环没有头，所以最后一点的前驱是第一点）
        final n = ids.length;
        for (var i = 0; i < n; i++) {
          await insert('${op.row.domain.prefix}_polygon_points', {
            'polygon_id': polygonId,
            'point_id': ids[i],
            'before_point_id': ids[(i - 1 + n) % n],
          });
        }

      case _:
        continue;
    }
  }

  // pass 3：区域（引用线）+ 门 + 世界要素 + 记录点 + 轨迹
  for (final op in plan.ops) {
    switch (op) {
      case InsertArea():
        final areaId = await insert(op.domain.areasTable, op.row.toDb()..remove('id'));
        areaIds[op.key] = areaId;
        for (final lk in op.lineKeys) {
          final lineId = lineIds[lk];
          if (lineId == null) continue; // 线没进来（悬空引用）→ 跳过这一条关联
          await insert(op.domain.areaLinesTable, {
            'area_id': areaId,
            'line_id': lineId,
          });
        }

      case InsertGate():
        final values = op.row.toDb()..remove('id');
        values['line_id'] = op.lineKey == null ? null : lineIds[op.lineKey];
        await insert('world_gates', values);

      case InsertEntity():
        final values = op.row.toDb()..remove('id');
        values['line_id'] = op.lineKey == null ? null : lineIds[op.lineKey];
        await insert('world_entities', values);

      case InsertMark():
        await insert('world_marks', op.row.toDb()..remove('id'));

      case InsertTrack():
        for (final m in op.marks) {
          await insert('way_marks', m.toDb()..remove('id'));
        }

      case _:
        continue;
    }
  }

  return plan.stats;
}

/// 两个地理点是否在键精度上重合（导入预览里"这两个点其实是一个"的提示用）。
bool samePointWithinKeyPrecision(GeoPoint a, GeoPoint b) {
  final eps = 2.0 / math.pow(10, kPointKeyDecimals);
  return (a.lat - b.lat).abs() < eps && (a.lng - b.lng).abs() < eps;
}
