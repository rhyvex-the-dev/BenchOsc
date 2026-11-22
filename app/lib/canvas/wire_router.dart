import 'dart:math' as math;
import 'dart:ui';

import '../state/circuit_doc.dart';

const double kGridStep = 24.0;

double wireMidX(WireLink w, Offset a, Offset b) =>
    w.bendX != null ? w.bendX! * kGridStep : ((a.dx + b.dx) * 0.5 / kGridStep).round() * kGridStep;

const int _gridPackBias = 0x80000;
int _packGrid(int x, int y) => ((x + _gridPackBias) << 20) | ((y + _gridPackBias) & 0xFFFFF);

/// Builds the full component body/pin obstacle grid for wire routing.
Set<int> buildObstacleGrid(CircuitDoc doc) {
  final blocked = <int>{};
  for (final c in doc.components) {
    if (c.kind == CompKind.netPort && (c.hexPattern ?? '').startsWith('J')) continue;
    if (c.pinOffsets.isEmpty) {
      blocked.add(_packGrid(c.gridX, c.gridY));
      continue;
    }
    var minPx = 1 << 20;
    var maxPx = -(1 << 20);
    var minPy = 1 << 20;
    var maxPy = -(1 << 20);
    for (var p = 0; p < c.pinOffsets.length; p++) {
      final pg = c.pinGridPos(p);
      final gx = pg.dx.round();
      final gy = pg.dy.round();
      if (gx < minPx) minPx = gx;
      if (gx > maxPx) maxPx = gx;
      if (gy < minPy) minPy = gy;
      if (gy > maxPy) maxPy = gy;
    }
    final bMinX = (maxPx - minPx >= 2) ? minPx + 1 : c.gridX;
    final bMaxX = (maxPx - minPx >= 2) ? maxPx - 1 : c.gridX;
    final bMinY = (maxPy - minPy >= 2 && c.pinOffsets.length <= 2)
        ? minPy + 1
        : (minPy == maxPy ? c.gridY : minPy);
    final bMaxY = (maxPy - minPy >= 2 && c.pinOffsets.length <= 2)
        ? maxPy - 1
        : (minPy == maxPy ? c.gridY : maxPy);

    for (var x = bMinX; x <= bMaxX; x++) {
      for (var y = bMinY; y <= bMaxY; y++) {
        blocked.add(_packGrid(x, y));
      }
    }
  }
  return blocked;
}

/// Computes an obstacle-avoiding orthogonal Manhattan polyline blocking full component footprints.
List<Offset> routeWirePoints(CircuitDoc doc, WireLink w, Offset a, Offset b, {Set<int>? obstacles}) {
  final midX = wireMidX(w, a, b);
  final fallback = <Offset>[a, Offset(midX, a.dy), Offset(midX, b.dy), b];
  if (w.bendX != null) return fallback;

  final ax = (a.dx / kGridStep).round();
  final ay = (a.dy / kGridStep).round();
  final bx = (b.dx / kGridStep).round();
  final by = (b.dy / kGridStep).round();
  if (ax == bx && ay == by) return [a, b];

  final blocked = obstacles ?? buildObstacleGrid(doc);
  final startKey = _packGrid(ax, ay);
  final goalKey = _packGrid(bx, by);

  final minX = math.min(ax, bx) - 4;
  final maxX = math.max(ax, bx) + 4;
  final minY = math.min(ay, by) - 4;
  final maxY = math.max(ay, by) + 4;

  // Check fast collinear unobstructed route before running A*.
  if (ax == bx) {
    final lo = math.min(ay, by) + 1;
    final hi = math.max(ay, by) - 1;
    var clear = true;
    for (var y = lo; y <= hi; y++) {
      final k = _packGrid(ax, y);
      if (k != startKey && k != goalKey && blocked.contains(k)) {
        clear = false;
        break;
      }
    }
    if (clear) return [a, b];
  } else if (ay == by) {
    final lo = math.min(ax, bx) + 1;
    final hi = math.max(ax, bx) - 1;
    var clear = true;
    for (var x = lo; x <= hi; x++) {
      final k = _packGrid(x, ay);
      if (k != startKey && k != goalKey && blocked.contains(k)) {
        clear = false;
        break;
      }
    }
    if (clear) return [a, b];
  }

  final gScore = <int, int>{startKey: 0};
  final parent = <int, int>{};
  final dirOf = <int, int>{}; // 0: start, 1: H, 2: V
  final open = <(int f, int x, int y)>[((ax - bx).abs() + (ay - by).abs(), ax, ay)];
  final closed = <int>{};
  const dirs = [(1, 0, 1), (-1, 0, 1), (0, 1, 2), (0, -1, 2)];

  var iters = 0;
  var found = false;
  while (open.isNotEmpty && iters++ < 450) {
    var bestIdx = 0;
    for (var i = 1; i < open.length; i++) {
      if (open[i].$1 < open[bestIdx].$1) bestIdx = i;
    }
    final cur = open.removeAt(bestIdx);
    final ck = _packGrid(cur.$2, cur.$3);
    if (ck == goalKey) {
      found = true;
      break;
    }
    if (!closed.add(ck)) continue;
    final cg = gScore[ck] ?? 0;
    final prevDir = dirOf[ck] ?? 0;

    for (final (dx, dy, dKind) in dirs) {
      final nx = cur.$2 + dx;
      final ny = cur.$3 + dy;
      if (nx < minX || nx > maxX || ny < minY || ny > maxY) continue;
      final nk = _packGrid(nx, ny);
      if (nk != startKey && nk != goalKey && blocked.contains(nk)) continue;
      if (closed.contains(nk)) continue;
      final bendCost = (prevDir != 0 && prevDir != dKind) ? 2 : 0;
      final ng = cg + 1 + bendCost;
      if (ng < (gScore[nk] ?? 1 << 29)) {
        gScore[nk] = ng;
        parent[nk] = ck;
        dirOf[nk] = dKind;
        open.add((ng + (nx - bx).abs() + (ny - by).abs(), nx, ny));
      }
    }
  }

  if (!found) return fallback;
  final raw = <Offset>[];
  var curK = goalKey;
  while (true) {
    final x = (curK >> 20) - _gridPackBias;
    final y = (curK & 0xFFFFF) - _gridPackBias;
    raw.add(Offset(x * kGridStep, y * kGridStep));
    final p = parent[curK];
    if (p == null) break;
    curK = p;
  }
  final pts = raw.reversed.toList();
  if (pts.length <= 2) return pts;
  final simplified = <Offset>[pts.first];
  for (var i = 1; i < pts.length - 1; i++) {
    final p0 = simplified.last;
    final p1 = pts[i];
    final p2 = pts[i + 1];
    final sameX = (p0.dx - p1.dx).abs() < 0.1 && (p1.dx - p2.dx).abs() < 0.1;
    final sameY = (p0.dy - p1.dy).abs() < 0.1 && (p1.dy - p2.dy).abs() < 0.1;
    if (!sameX && !sameY) simplified.add(p1);
  }
  simplified.add(pts.last);
  return simplified;
}
