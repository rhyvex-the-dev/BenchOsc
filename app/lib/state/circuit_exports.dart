import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import '../canvas/comp_symbols.dart';
import '../canvas/wire_router.dart';
import '../theme/circuit_theme.dart';
import 'circuit_doc.dart';

/// Encodes captured scope voltage samples into a 16-bit mono PCM `.wav` file.
Uint8List encodeWav16Pcm(List<double> samples, {List<double>? times, int sampleRate = 8000}) {
  if (times != null && times.length >= 2) {
    final dt = (times.last - times.first) / (times.length - 1);
    if (dt > 1e-7) {
      sampleRate = (1.0 / dt).round().clamp(1000, 192000);
    }
  }
  final n = samples.length;
  final dataBytes = n * 2;
  final out = ByteData(44 + dataBytes);

  void writeStr(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      out.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeStr(0, 'RIFF');
  out.setUint32(4, 36 + dataBytes, Endian.little);
  writeStr(8, 'WAVE');
  writeStr(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little);
  out.setUint16(22, 1, Endian.little);
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, sampleRate * 2, Endian.little);
  out.setUint16(32, 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  writeStr(36, 'data');
  out.setUint32(40, dataBytes, Endian.little);

  var peak = 1e-6;
  for (final v in samples) {
    if (!v.isFinite) continue;
    final a = v.abs();
    if (a > peak) peak = a;
  }
  final gain = 30000.0 / math.max(peak, 1.0);
  for (var i = 0; i < n; i++) {
    final s = samples[i].isFinite ? samples[i] : 0.0;
    final pcm = (s * gain).round().clamp(-32767, 32767);
    out.setInt16(44 + i * 2, pcm, Endian.little);
  }
  return out.buffer.asUint8List();
}

({double w, double h, double ox, double oy, Map<int, PlacedComponent> compById, List<List<Offset>> wires})
    _exportGeometry(CircuitDoc doc) {
  var minX = 0.0, minY = 0.0, maxX = 480.0, maxY = 320.0;
  if (doc.components.isNotEmpty) {
    minX = double.infinity;
    minY = double.infinity;
    maxX = double.negativeInfinity;
    maxY = double.negativeInfinity;
    for (final c in doc.components) {
      final cx = c.gridX * kGridStep;
      final cy = c.gridY * kGridStep;
      minX = math.min(minX, cx - 72);
      minY = math.min(minY, cy - 72);
      maxX = math.max(maxX, cx + 72);
      maxY = math.max(maxY, cy + 72);
    }
  }
  final w = math.max(240.0, maxX - minX);
  final h = math.max(180.0, maxY - minY);
  final ox = -minX;
  final oy = -minY;
  final compById = {for (final c in doc.components) c.id: c};

  Offset? rawPin(PinRef ref) {
    final c = compById[ref.compId];
    if (c == null || ref.pinIdx >= c.pinOffsets.length) return null;
    return c.pinGridPos(ref.pinIdx) * kGridStep;
  }

  final wires = <List<Offset>>[];
  for (final wire in doc.wires) {
    final a = rawPin(wire.from);
    final b = rawPin(wire.to);
    if (a == null || b == null) continue;
    final pts = routeWirePoints(doc, wire, a, b);
    wires.add([for (final p in pts) Offset(p.dx + ox, p.dy + oy)]);
  }
  return (w: w, h: h, ox: ox, oy: oy, compById: compById, wires: wires);
}

Offset? _shiftedPin(Map<int, PlacedComponent> byId, PinRef ref, double ox, double oy) {
  final c = byId[ref.compId];
  if (c == null || ref.pinIdx >= c.pinOffsets.length) return null;
  final g = c.pinGridPos(ref.pinIdx);
  return Offset(g.dx * kGridStep + ox, g.dy * kGridStep + oy);
}

String _svgEsc(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _f(double v) => v.toStringAsFixed(1);

void _writeSvgSymbol(StringBuffer buf, PlacedComponent c, CircuitDoc doc) {
  final g = kGridStep;
  const stroke = '#F5E6D3';
  const amber = '#FFB300';
  String line(double x1, double y1, double x2, double y2, {String col = stroke, double w = 2.0}) =>
      '    <line x1="${_f(x1)}" y1="${_f(y1)}" x2="${_f(x2)}" y2="${_f(y2)}" stroke="$col" stroke-width="$w" stroke-linecap="round"/>';
  String txt(String t, double x, double y, {String col = amber, int sz = 10}) =>
      '    <text x="${_f(x)}" y="${_f(y + sz * 0.35)}" fill="$col" font-family="monospace" font-size="$sz" text-anchor="middle">${_svgEsc(t)}</text>';

  switch (c.kind) {
    case CompKind.ground:
      buf
        ..writeln(line(0, -g, 0, 0))
        ..writeln(line(-14, 0, 14, 0))
        ..writeln(line(-9, 6, 9, 6))
        ..writeln(line(-4, 12, 4, 12));
    case CompKind.resistor:
      final pts = <String>['M${_f(-g * 2)},0', 'L${_f(-g * 0.9)},0'];
      for (var i = 0; i < 4; i++) {
        final x0 = -g * 0.9 + i * (g * 0.45);
        pts.add('L${_f(x0 + g * 0.11)},-7 L${_f(x0 + g * 0.34)},7');
      }
      pts.addAll(['L${_f(g * 0.9)},0', 'L${_f(g * 2)},0']);
      buf.writeln('    <path d="${pts.join(' ')}" fill="none" stroke="$stroke" stroke-width="2" stroke-linejoin="round"/>');
    case CompKind.capacitor || CompKind.polarizedCapacitor || CompKind.varCapacitor:
      buf
        ..writeln(line(-g * 2, 0, -5, 0))
        ..writeln(line(5, 0, g * 2, 0))
        ..writeln(line(-5, -13, -5, 13))
        ..writeln(line(5, -13, 5, 13));
    case CompKind.inductor || CompKind.varInductor:
      buf
        ..writeln(line(-g * 2, 0, -g, 0))
        ..writeln(line(g, 0, g * 2, 0))
        ..writeln('    <path d="M${_f(-g)},0 Q${_f(-g * 0.67)},-12 ${_f(-g * 0.33)},0 Q0,-12 ${_f(g * 0.33)},0 Q${_f(g * 0.67)},-12 ${_f(g)},0" fill="none" stroke="$stroke" stroke-width="2"/>');
    case CompKind.dcSource || CompKind.acSource || CompKind.funcGen || CompKind.dcCurrent || CompKind.acCurrent || CompKind.pulseVoltage || CompKind.pwlSource:
      final tag = switch (c.kind) {
        CompKind.dcSource => 'DC',
        CompKind.acSource => '~',
        CompKind.funcGen => 'FG',
        CompKind.dcCurrent => 'I',
        CompKind.acCurrent => 'I~',
        CompKind.pulseVoltage => 'PLS',
        _ => 'PWL',
      };
      buf
        ..writeln(line(0, -g * 2, 0, -g * 0.8))
        ..writeln(line(0, g * 0.8, 0, g * 2))
        ..writeln('    <circle cx="0" cy="0" r="${_f(g * 0.8)}" fill="#1C1814" stroke="$stroke" stroke-width="2"/>')
        ..writeln(txt(tag, 0, 0));
    case CompKind.diode || CompKind.zener || CompKind.schottkyDiode || CompKind.varactorDiode || CompKind.led:
      buf
        ..writeln(line(-g * 2, 0, -10, 0))
        ..writeln(line(10, 0, g * 2, 0))
        ..writeln('    <polygon points="-10,-11 -10,11 10,0" fill="none" stroke="$stroke" stroke-width="2"/>')
        ..writeln(line(10, -11, 10, 11));
    case CompKind.opAmp || CompKind.comparatorOc || CompKind.instAmp || CompKind.schmittTrigger:
      buf
        ..writeln(line(-g * 2, -g, -g, -g))
        ..writeln(line(-g * 2, g, -g, g))
        ..writeln(line(g, 0, g * 2, 0))
        ..writeln('    <polygon points="${_f(-g)},${_f(-g * 1.4)} ${_f(-g)},${_f(g * 1.4)} ${_f(g)},0" fill="#1C1814" stroke="$stroke" stroke-width="2"/>')
        ..writeln(txt('+', -g + 8, -g * 0.6, col: stroke, sz: 10))
        ..writeln(txt('-', -g + 8, g * 0.6, col: stroke, sz: 10));
    case CompKind.notGate || CompKind.bufferGate || CompKind.triStateBuffer:
      buf
        ..writeln(line(-g * 2, 0, -g * 0.85, 0))
        ..writeln('    <polygon points="${_f(-g * 0.85)},${_f(-g * 0.9)} ${_f(-g * 0.85)},${_f(g * 0.9)} ${_f(g * 0.75)},0" fill="#1C1814" stroke="$stroke" stroke-width="2"/>');
      if (c.kind == CompKind.notGate) {
        buf
          ..writeln('    <circle cx="${_f(g * 0.75 + 4)}" cy="0" r="4" fill="#12100E" stroke="$stroke" stroke-width="2"/>')
          ..writeln(line(g * 0.75 + 8, 0, g * 2, 0));
      } else {
        buf.writeln(line(g * 0.75, 0, g * 2, 0));
        if (c.kind == CompKind.triStateBuffer) buf.writeln(line(0, -g * 2, 0, -g * 0.44));
      }
    case CompKind.andGate || CompKind.nandGate || CompKind.and3Gate || CompKind.nand4Gate:
      for (var i = 0; i < c.pinOffsets.length - 1; i++) {
        buf.writeln(line(-g * 2, c.pinOffsets[i].dy * g, -g * 0.9, c.pinOffsets[i].dy * g));
      }
      final inv = c.kind == CompKind.nandGate || c.kind == CompKind.nand4Gate;
      buf.writeln('    <path d="M${_f(-g * 0.9)},${_f(-g * 1.15)} L0,${_f(-g * 1.15)} C${_f(g)},${_f(-g * 1.15)} ${_f(g)},${_f(g * 1.15)} 0,${_f(g * 1.15)} L${_f(-g * 0.9)},${_f(g * 1.15)} Z" fill="#1C1814" stroke="$stroke" stroke-width="2"/>');
      if (inv) {
        buf
          ..writeln('    <circle cx="${_f(g * 0.85 + 4)}" cy="0" r="4" fill="#12100E" stroke="$stroke" stroke-width="2"/>')
          ..writeln(line(g * 0.85 + 8, 0, g * 2, 0));
      } else {
        buf.writeln(line(g * 0.85, 0, g * 2, 0));
      }
    case CompKind.orGate || CompKind.norGate || CompKind.xorGate || CompKind.xnorGate || CompKind.or3Gate:
      final xor = c.kind == CompKind.xorGate || c.kind == CompKind.xnorGate;
      final inv = c.kind == CompKind.norGate || c.kind == CompKind.xnorGate;
      final bx = xor ? -g * 0.65 : -g * 0.9;
      for (var i = 0; i < c.pinOffsets.length - 1; i++) {
        buf.writeln(line(-g * 2, c.pinOffsets[i].dy * g, bx + 4, c.pinOffsets[i].dy * g));
      }
      buf.writeln('    <path d="M${_f(bx)},-28 Q${_f(g * 0.25)},-28 ${_f(g * 0.85)},0 Q${_f(g * 0.25)},28 ${_f(bx)},28 Q${_f(bx + 10)},0 ${_f(bx)},-28 Z" fill="#1C1814" stroke="$stroke" stroke-width="2"/>');
      if (xor) buf.writeln('    <path d="M${_f(bx - 6)},-28 Q${_f(bx + 4)},0 ${_f(bx - 6)},28" fill="none" stroke="$stroke" stroke-width="2"/>');
      if (inv) {
        buf
          ..writeln('    <circle cx="${_f(g * 0.85 + 4)}" cy="0" r="4" fill="#12100E" stroke="$stroke" stroke-width="2"/>')
          ..writeln(line(g * 0.85 + 8, 0, g * 2, 0));
      } else {
        buf.writeln(line(g * 0.85, 0, g * 2, 0));
      }
    case CompKind.npnBjt || CompKind.pnpBjt || CompKind.nmos || CompKind.pmos || CompKind.njfet || CompKind.pjfet || CompKind.igbt:
      buf
        ..writeln(line(-g * 2, 0, -6, 0))
        ..writeln(line(-6, -15, -6, 15))
        ..writeln(line(-6, -8, g, -g * 2))
        ..writeln(line(-6, 8, g, g * 2))
        ..writeln(txt(c.kind.name.toUpperCase().substring(0, math.min(3, c.kind.name.length)), 8, 0, sz: 8));
    case CompKind.switchSpst || CompKind.pushbutton:
      final closed = c.params.isNotEmpty && c.params[0] >= 0.5;
      buf
        ..writeln(line(-g * 2, 0, -g * 0.7, 0))
        ..writeln(line(g * 0.7, 0, g * 2, 0))
        ..writeln(line(-g * 0.7, 0, closed ? g * 0.7 : g * 0.5, closed ? 0 : -14, col: closed ? amber : stroke));
    case CompKind.fuse:
      buf
        ..writeln(line(-g * 2, 0, -g * 0.9, 0))
        ..writeln(line(g * 0.9, 0, g * 2, 0))
        ..writeln('    <rect x="${_f(-g * 0.9)}" y="-7" width="${_f(g * 1.8)}" height="14" fill="#1C1814" stroke="$stroke" stroke-width="2"/>')
        ..writeln(line(-g * 0.9, 0, g * 0.9, 0));
    default:
      var minHy = -g, maxHy = g;
      for (final o in c.pinOffsets) {
        if (o.dx != 0) {
          minHy = math.min(minHy, o.dy * g);
          maxHy = math.max(maxHy, o.dy * g);
        }
      }
      final top = minHy - 6, bot = maxHy + 6, halfW = c.pinOffsets.length >= 6 ? g * 1.25 : g * 1.1;
      for (final o in c.pinOffsets) {
        final px = o.dx * g, py = o.dy * g;
        final sx = o.dx > 0 ? halfW : (o.dx < 0 ? -halfW : 0.0);
        final sy = o.dx == 0 ? (o.dy > 0 ? bot : top) : py;
        buf.writeln(line(px, py, sx, sy));
      }
      buf.writeln('    <rect x="${_f(-halfW)}" y="${_f(top)}" width="${_f(halfW * 2)}" height="${_f(bot - top)}" rx="4" fill="#1C1814" stroke="$stroke" stroke-width="2"/>');
      final tag = c.kind == CompKind.subcircuit ? (c.subcircuitName ?? 'SUB') : '${c.kind.name[0].toUpperCase()}${c.id}';
      buf.writeln(txt(tag, 0, 0));
  }
}

/// Exports the schematic geometry with real IEEE/IEC vector symbols as `.svg`.
String exportSchematicSvg(CircuitDoc doc) {
  final geo = _exportGeometry(doc);
  final buf = StringBuffer()
    ..writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" width="${geo.w.toInt()}" height="${geo.h.toInt()}" viewBox="0 0 ${geo.w.toInt()} ${geo.h.toInt()}">',
    )
    ..writeln('  <rect width="100%" height="100%" fill="#12100E"/>');

  for (final pts in geo.wires) {
    final coordStr = pts.map((p) => '${_f(p.dx)},${_f(p.dy)}').join(' ');
    buf.writeln('  <polyline fill="none" stroke="#D7CCC8" stroke-width="2" points="$coordStr"/>');
  }

  for (final c in doc.components) {
    final cx = c.gridX * kGridStep + geo.ox;
    final cy = c.gridY * kGridStep + geo.oy;
    final deg = (c.rotation % 4) * 90;
    final fx = c.flipX ? -1 : 1;
    final fy = c.flipY ? -1 : 1;
    buf.writeln('  <g transform="translate(${_f(cx)},${_f(cy)}) rotate($deg) scale($fx,$fy)">');
    _writeSvgSymbol(buf, c, doc);
    buf.writeln('  </g>');

    for (var p = 0; p < c.pinOffsets.length; p++) {
      final pt = _shiftedPin(geo.compById, PinRef(c.id, p), geo.ox, geo.oy)!;
      buf.writeln('  <circle cx="${_f(pt.dx)}" cy="${_f(pt.dy)}" r="2.8" fill="#FFB300"/>');
    }
    if (c.kind != CompKind.ground && !(c.kind == CompKind.netPort && (c.hexPattern ?? '').startsWith('J'))) {
      buf.writeln(
        '  <text x="${_f(cx)}" y="${_f(cy + kGridStep * 1.65)}" fill="#D7CCC8" font-family="monospace" font-size="9" text-anchor="middle">${_svgEsc(formatComponentBadge(c))}</text>',
      );
    }
  }
  for (final note in doc.notes) {
    final nx = note.gridX * kGridStep + geo.ox;
    final ny = note.gridY * kGridStep + geo.oy;
    buf.writeln(
      '  <text x="${_f(nx)}" y="${_f(ny)}" fill="#26C6DA" font-family="sans-serif" font-size="11">${_svgEsc('// ${note.text}')}</text>',
    );
  }
  buf.writeln('</svg>');
  return buf.toString();
}

/// Renders the schematic with full IEEE/IEC component symbols, badges, and notes to PNG.
Future<Uint8List?> renderSchematicPng(CircuitDoc doc) async {
  final geo = _exportGeometry(doc);
  final rawW = math.max(240, geo.w.ceil());
  final rawH = math.max(180, geo.h.ceil());
  const maxDim = 4096;
  final scale = math.min(1.0, maxDim / math.max(rawW, rawH));
  final w = (rawW * scale).round().clamp(1, maxDim);
  final h = (rawH * scale).round().clamp(1, maxDim);
  const colors = CircuitColors.darkAmber;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  if (scale < 1.0) canvas.scale(scale);
  canvas.drawRect(Rect.fromLTWH(0, 0, rawW.toDouble(), rawH.toDouble()), Paint()..color = colors.canvasBackground);

  final wirePaint = Paint()
    ..color = colors.wireDefault
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.0
    ..strokeJoin = StrokeJoin.round;
  for (final pts in geo.wires) {
    if (pts.isEmpty) continue;
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    canvas.drawPath(path, wirePaint);
  }

  void drawText(Canvas cv, String text, Offset center, Color color, double size, {bool cache = true}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: size, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(cv, center - Offset(tp.width * 0.5, tp.height * 0.5));
    tp.dispose();
  }

  final stroke = Paint()
    ..color = colors.componentStroke
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.0
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final pinPaint = Paint()..color = colors.pinHighlight;

  for (final c in doc.components) {
    final cx = c.gridX * kGridStep + geo.ox;
    final cy = c.gridY * kGridStep + geo.oy;
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(c.rotation * math.pi * 0.5);
    if (c.flipX || c.flipY) canvas.scale(c.flipX ? -1.0 : 1.0, c.flipY ? -1.0 : 1.0);
    paintComponentSymbol(
      canvas: canvas,
      c: c,
      doc: doc,
      colors: colors,
      stroke: stroke,
      nodeVoltages: const {},
      compCurrents: const {},
      drawText: drawText,
    );
    canvas.restore();
    for (var p = 0; p < c.pinOffsets.length; p++) {
      canvas.drawCircle(_shiftedPin(geo.compById, PinRef(c.id, p), geo.ox, geo.oy)!, 2.8, pinPaint);
    }
    if (c.kind != CompKind.ground && !(c.kind == CompKind.netPort && (c.hexPattern ?? '').startsWith('J'))) {
      drawText(canvas, formatComponentBadge(c), Offset(cx, cy + kGridStep * 1.45), colors.wireDefault, 9);
    }
  }
  for (final note in doc.notes) {
    drawText(canvas, '// ${note.text}', Offset(note.gridX * kGridStep + geo.ox, note.gridY * kGridStep + geo.oy), colors.scopeCh2, 10);
  }

  final img = await recorder.endRecording().toImage(w, h);
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return byteData?.buffer.asUint8List();
}

/// Strips directory prefixes, control characters, and leading `-` option flags for OS file dialogs.
String sanitizeDialogFilename(String suggestedName) {
  final base = suggestedName
      .split(RegExp(r'[/\\]'))
      .last
      .replaceAll(RegExp(r'[\r\n\x00]'), '')
      .replaceFirst(RegExp(r'^-+'), '')
      .trim();
  return base.isEmpty ? 'circuit' : base;
}

/// Launches the OS native file dialog and reports whether a native dialog backend was available.
// shortcut: native OS pickers + path dialog used because pub cache is offline; switch to file_selector on connected build.
Future<({String? path, bool available})> pickNativeFileResult({
  required bool save,
  required String suggestedName,
}) async {
  final safeName = sanitizeDialogFilename(suggestedName);
  try {
    if (Platform.isLinux) {
      final zArgs = save
          ? ['--file-selection', '--save', '--confirm-overwrite', '--filename=$safeName']
          : ['--file-selection', '--filename=$safeName'];
      try {
        final res = await Process.run('zenity', zArgs);
        if (res.exitCode == 0) {
          final out = (res.stdout as String).trim();
          return (path: out.isNotEmpty ? out : null, available: true);
        }
        if (res.exitCode == 1 && (res.stderr as String).trim().isEmpty) {
          return (path: null, available: true);
        }
      } catch (_) {}
      final kArgs = save ? ['--getsavefilename', './$safeName'] : ['--getopenfilename', '.'];
      final kRes = await Process.run('kdialog', kArgs);
      if (kRes.exitCode == 0) {
        final out = (kRes.stdout as String).trim();
        return (path: out.isNotEmpty ? out : null, available: true);
      }
      if (kRes.exitCode == 1 && (kRes.stderr as String).trim().isEmpty) {
        return (path: null, available: true);
      }
    } else if (Platform.isMacOS) {
      final args = save
          ? [
              '-e',
              'on run argv',
              '-e',
              'POSIX path of (choose file name default name (item 1 of argv))',
              '-e',
              'end run',
              '--',
              safeName,
            ]
          : ['-e', 'POSIX path of (choose file)'];
      final res = await Process.run('osascript', args);
      if (res.exitCode == 0) {
        final out = (res.stdout as String).trim();
        return (path: out.isNotEmpty ? out : null, available: true);
      }
      if ((res.stderr as String).contains('-128')) {
        return (path: null, available: true);
      }
    } else if (Platform.isWindows) {
      final safePs = safeName.replaceAll("'", "''");
      final dlgClass = save ? 'SaveFileDialog' : 'OpenFileDialog';
      final script =
          "Add-Type -AssemblyName System.Windows.Forms; "
          "\$d = New-Object System.Windows.Forms.$dlgClass; "
          "\$d.FileName = '$safePs'; "
          "if (\$d.ShowDialog() -eq 'OK') { Write-Output \$d.FileName }";
      final res = await Process.run('powershell', ['-NoProfile', '-STA', '-Command', script]);
      if (res.exitCode == 0) {
        final out = (res.stdout as String).trim();
        return (path: out.isNotEmpty ? out : null, available: true);
      }
    }
  } catch (_) {}
  return (path: null, available: false);
}

/// Launches the OS native file dialog when running interactively on desktop (falls back to null when unavailable).
Future<String?> pickNativeFile({
  required bool save,
  required String suggestedName,
}) async =>
    (await pickNativeFileResult(save: save, suggestedName: suggestedName)).path;
