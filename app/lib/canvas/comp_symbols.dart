import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state/circuit_doc.dart';
import '../theme/circuit_theme.dart';
import 'wire_router.dart';

typedef DrawTextFn = void Function(
  Canvas canvas,
  String text,
  Offset center,
  Color color,
  double size, {
  bool cache,
});

/// Human-readable pin name for tooltips and subcircuit borders.
String pinLabel(CompKind kind, int pinIdx) {
  final list = switch (kind) {
    CompKind.ground => const ['GND'],
    CompKind.dcSource ||
    CompKind.dcCurrent ||
    CompKind.acSource ||
    CompKind.acCurrent ||
    CompKind.funcGen ||
    CompKind.pulseVoltage ||
    CompKind.pwlSource =>
      const ['+', '-'],
    CompKind.clock => const ['OUT', 'GND'],
    CompKind.powerRail => const ['V+'],
    CompKind.netPort => const ['NET'],
    CompKind.resistor ||
    CompKind.capacitor ||
    CompKind.polarizedCapacitor ||
    CompKind.varCapacitor ||
    CompKind.inductor ||
    CompKind.varInductor ||
    CompKind.crystal ||
    CompKind.lamp ||
    CompKind.fuse ||
    CompKind.buzzer ||
    CompKind.dcMotor ||
    CompKind.switchSpst ||
    CompKind.pushbutton ||
    CompKind.voltmeter ||
    CompKind.ammeter =>
      const ['A', 'B'],
    CompKind.potentiometer => const ['End A', 'End B', 'Wiper'],
    CompKind.switchSpdt => const ['COM', 'A', 'B'],
    CompKind.vControlledSwitch => const ['SW+', 'SW-', 'CTL+', 'CTL-'],
    CompKind.iControlledSwitch => const ['SW+', 'SW-', 'SNS+', 'SNS-'],
    CompKind.relay => const ['COIL+', 'COIL-', 'COM', 'NO'],
    CompKind.relaySpdt => const ['COIL+', 'COIL-', 'COM', 'NC', 'NO'],
    CompKind.relayDpdt => const ['C+', 'C-', 'COM1', 'NC1', 'NO1', 'COM2', 'NC2', 'NO2'],
    CompKind.coupledInductor || CompKind.transformer => const ['P+', 'P-', 'S+', 'S-'],
    CompKind.centerTapTransformer => const ['P+', 'P-', 'S+', 'CT', 'S-'],
    CompKind.diode ||
    CompKind.zener ||
    CompKind.schottkyDiode ||
    CompKind.varactorDiode ||
    CompKind.led =>
      const ['Anode (+)', 'Cathode (-)'],
    CompKind.rgbLed => const ['R', 'G', 'B', 'K'],
    CompKind.barGraphLed => const ['A1', 'A2', 'A3', 'A4', 'K'],
    CompKind.bridgeRectifier => const ['AC1', 'AC2', 'DC+', 'DC-'],
    CompKind.optocoupler => const ['A', 'K', 'C', 'E'],
    CompKind.opAmp || CompKind.comparatorOc || CompKind.instAmp => const ['IN+', 'IN-', 'OUT'],
    CompKind.voltageReg => const ['IN', 'GND', 'OUT'],
    CompKind.vco => const ['VCTL', 'OUT'],
    CompKind.analogMultiplier => const ['X', 'Y', 'OUT'],
    CompKind.sampleHold => const ['IN', 'CLK', 'OUT'],
    CompKind.npnBjt || CompKind.pnpBjt => const ['C', 'B', 'E'],
    CompKind.nmos || CompKind.pmos || CompKind.njfet || CompKind.pjfet => const ['D', 'G', 'S'],
    CompKind.scr => const ['A', 'K', 'G'],
    CompKind.triac => const ['MT2', 'MT1', 'G'],
    CompKind.diac => const ['A1', 'A2'],
    CompKind.igbt => const ['C', 'G', 'E'],
    CompKind.vcvs ||
    CompKind.vccs ||
    CompKind.cccs ||
    CompKind.ccvs =>
      const ['OUT+', 'OUT-', 'CTL+', 'CTL-'],
    CompKind.andGate ||
    CompKind.orGate ||
    CompKind.nandGate ||
    CompKind.norGate ||
    CompKind.xorGate ||
    CompKind.xnorGate =>
      const ['A', 'B', 'Y'],
    CompKind.notGate || CompKind.bufferGate => const ['A', 'Y'],
    CompKind.triStateBuffer => const ['A', 'EN', 'Y'],
    CompKind.and3Gate || CompKind.or3Gate => const ['A', 'B', 'C', 'Y'],
    CompKind.nand4Gate => const ['A', 'B', 'C', 'D', 'Y'],
    CompKind.srLatch => const ['S', 'R', 'Q', '!Q'],
    CompKind.dFlipFlop => const ['D', 'CLK', 'Q', '!Q'],
    CompKind.dFlipFlopAsync => const ['D', 'CLK', 'SET', 'RST', 'Q', '!Q'],
    CompKind.jkFlipFlop => const ['J', 'CLK', 'K', 'Q', '!Q'],
    CompKind.tFlipFlop => const ['T', 'CLK', 'Q', '!Q'],
    CompKind.logicProbe || CompKind.logicIndicator => const ['IN'],
    CompKind.timer555 => const ['TR', 'TH', 'DIS', 'OUT'],
    CompKind.sevenSeg || CompKind.wordGen || CompKind.hexKeypad => const ['D3', 'D2', 'D1', 'D0'],
    CompKind.schmittTrigger => const ['IN+', 'IN-', 'OUT'],
    CompKind.counter4Bit => const ['CLK', 'Q2', 'Q1', 'Q0'],
    CompKind.counter4BitFull => const ['CLK', 'RST', 'EN', 'Q3', 'Q2', 'Q1', 'Q0', 'RCO'],
    CompKind.shiftReg4Bit => const ['SI', 'CLK', 'RST', 'Q3', 'Q2', 'Q1', 'Q0'],
    CompKind.mux4To1 => const ['D0', 'D1', 'D2', 'D3', 'S1', 'S0', 'Y'],
    CompKind.demux1To4 => const ['IN', 'S1', 'S0', 'Y0', 'Y1', 'Y2', 'Y3'],
    CompKind.decoder2To4 => const ['A1', 'A0', 'EN', 'Y0', 'Y1', 'Y2', 'Y3'],
    CompKind.fullAdder => const ['A', 'B', 'Cin', 'Sum', 'Cout'],
    CompKind.magComparator => const ['A1', 'A0', 'B1', 'B0', 'A>B', 'A=B', 'A<B'],
    CompKind.alu2Bit => const ['A1', 'A0', 'B1', 'B0', 'OP1', 'OP0', 'F1', 'F0'],
    CompKind.adc4Bit => const ['VIN', 'VREF', 'D3', 'D2', 'D1', 'D0'],
    CompKind.dac4Bit => const ['D3', 'D2', 'D1', 'D0', 'VREF', 'VOUT'],
    CompKind.wattmeter => const ['I+', 'I-', 'V+', 'V-'],
    CompKind.dipSwitch4 => const ['1A', '1B', '2A', '2B', '3A', '3B', '4A', '4B'],
    CompKind.subcircuit => null,
  };
  if (list != null && pinIdx >= 0 && pinIdx < list.length) {
    return list[pinIdx];
  }
  return 'Pin ${pinIdx + 1}';
}

/// Pin name taking user-defined subcircuit port labels into account.
String pinLabelFor(PlacedComponent c, int pinIdx, CircuitDoc doc) {
  if (c.kind == CompKind.subcircuit) {
    final labels = doc.subcircuits[c.subcircuitName]?.pinLabels;
    if (labels != null && pinIdx >= 0 && pinIdx < labels.length) {
      return labels[pinIdx];
    }
  }
  return pinLabel(c.kind, pinIdx);
}

void _drawArrowHead(Canvas canvas, Offset tip, Offset dir, double len, Paint p) {
  final u = dir / dir.distance;
  final perp = Offset(-u.dy, u.dx);
  final path = Path()
    ..moveTo(tip.dx, tip.dy)
    ..lineTo(tip.dx - u.dx * len + perp.dx * (len * 0.52), tip.dy - u.dy * len + perp.dy * (len * 0.52))
    ..lineTo(tip.dx - u.dx * len - perp.dx * (len * 0.52), tip.dy - u.dy * len - perp.dy * (len * 0.52))
    ..close();
  canvas.drawPath(path, p..style = PaintingStyle.fill);
}

/// Draws the local un-rotated component symbol around `(0, 0)`.
void paintComponentSymbol({
  required Canvas canvas,
  required PlacedComponent c,
  required CircuitDoc doc,
  required CircuitColors colors,
  required Paint stroke,
  required Map<int, double> nodeVoltages,
  required Map<int, double> compCurrents,
  required DrawTextFn drawText,
  Set<int> blownFuseIds = const {},
}) {
  final g = kGridStep;
  final iMag = (compCurrents[c.id] ?? 0.0).abs();

  switch (c.kind) {
    case CompKind.ground:
      canvas.drawLine(Offset(0, -g), Offset.zero, stroke);
      canvas.drawLine(const Offset(-14, 0), const Offset(14, 0), stroke);
      canvas.drawLine(const Offset(-9, 6), const Offset(9, 6), stroke);
      canvas.drawLine(const Offset(-4, 12), const Offset(4, 12), stroke);

    case CompKind.dcSource || CompKind.acSource || CompKind.funcGen:
      canvas.drawLine(Offset(0, -g * 2), Offset(0, -g * 0.8), stroke);
      canvas.drawLine(Offset(0, g * 0.8), Offset(0, g * 2), stroke);
      canvas.drawCircle(Offset.zero, g * 0.8, stroke);
      final tag = c.kind == CompKind.dcSource ? 'DC' : (c.kind == CompKind.acSource ? '~' : 'FG');
      drawText(canvas, tag, Offset.zero, colors.accentAmber, 11);
      if (c.kind == CompKind.dcSource) {
        drawText(canvas, '+', Offset(11, -g * 1.25), colors.accentAmber, 12);
        drawText(canvas, '-', Offset(11, g * 1.25), colors.scopeCh2, 13);
      }

    case CompKind.dcCurrent:
      canvas.drawLine(Offset(0, -g * 2), Offset(0, -g * 0.8), stroke);
      canvas.drawLine(Offset(0, g * 0.8), Offset(0, g * 2), stroke);
      canvas.drawCircle(Offset.zero, g * 0.8, stroke);
      final arrowPaint = Paint()
        ..color = colors.accentAmber
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(const Offset(0, -9), const Offset(0, 9), arrowPaint);
      canvas.drawLine(const Offset(-5, 3), const Offset(0, 9), arrowPaint);
      canvas.drawLine(const Offset(5, 3), const Offset(0, 9), arrowPaint);

    case CompKind.acCurrent:
      canvas.drawLine(Offset(0, -g * 2), Offset(0, -g * 0.8), stroke);
      canvas.drawLine(Offset(0, g * 0.8), Offset(0, g * 2), stroke);
      canvas.drawCircle(Offset.zero, g * 0.8, stroke);
      drawText(canvas, 'I~', Offset.zero, colors.accentAmber, 11);

    case CompKind.pulseVoltage || CompKind.pwlSource:
      canvas.drawLine(Offset(0, -g * 2), Offset(0, -g * 0.8), stroke);
      canvas.drawLine(Offset(0, g * 0.8), Offset(0, g * 2), stroke);
      canvas.drawCircle(Offset.zero, g * 0.8, stroke);
      drawText(canvas, c.kind == CompKind.pulseVoltage ? 'PLS' : 'PWL', Offset.zero, colors.accentAmber, 9);

    case CompKind.powerRail:
      canvas.drawLine(Offset(0, g), Offset.zero, stroke);
      canvas.drawLine(const Offset(-12, 0), const Offset(12, 0), stroke);
      drawText(canvas, '${c.params[0] >= 0 ? "+" : ""}${formatEngValue(c.params[0])}V', const Offset(0, -10), colors.accentAmber, 9);

    case CompKind.netPort:
      if (isAutoJunctionComp(c)) {
        canvas.drawCircle(Offset(-g, 0), 4.5, Paint()..color = colors.accentAmber);
      } else {
        canvas.drawLine(Offset(-g, 0), Offset(-g * 0.4, 0), stroke);
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTRB(-g * 0.4, -10, g * 1.4, 10), const Radius.circular(4)),
          stroke,
        );
        drawText(canvas, c.hexPattern ?? 'NET', Offset(g * 0.5, 0), colors.scopeCh2, 9);
      }

    case CompKind.clock:
      canvas.drawLine(Offset(g, 0), Offset(g * 2, 0), stroke);
      canvas.drawLine(Offset(0, g), Offset(0, g * 2), stroke);
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: g * 1.6, height: g * 1.4), stroke);
      drawText(canvas, 'CLK', Offset.zero, colors.accentAmber, 10);

    case CompKind.resistor:
      canvas.drawLine(Offset(-g * 2, 0), Offset(-g * 0.9, 0), stroke);
      canvas.drawLine(Offset(g * 0.9, 0), Offset(g * 2, 0), stroke);
      final path = Path()..moveTo(-g * 0.9, 0);
      for (var i = 0; i < 4; i++) {
        final x0 = -g * 0.9 + i * (g * 0.45);
        path.lineTo(x0 + g * 0.11, -7);
        path.lineTo(x0 + g * 0.34, 7);
      }
      path.lineTo(g * 0.9, 0);
      canvas.drawPath(path, stroke);

    case CompKind.potentiometer:
      canvas.drawLine(Offset(0, -g * 2), Offset(0, -g * 0.9), stroke);
      canvas.drawLine(Offset(0, g * 0.9), Offset(0, g * 2), stroke);
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: 14, height: g * 1.8), stroke);
      final wiperY = (-0.8 + 1.6 * c.params[1].clamp(0.0, 1.0)) * g;
      canvas.drawLine(Offset(7, wiperY), Offset(g * 2, 0), stroke..color = colors.accentAmber);
      stroke.color = colors.componentStroke;

    case CompKind.capacitor:
      canvas.drawLine(Offset(-g * 2, 0), const Offset(-4, 0), stroke);
      canvas.drawLine(const Offset(4, 0), Offset(g * 2, 0), stroke);
      canvas.drawLine(const Offset(-4, -14), const Offset(-4, 14), stroke);
      canvas.drawLine(const Offset(4, -14), const Offset(4, 14), stroke);

    case CompKind.polarizedCapacitor || CompKind.varCapacitor:
      canvas.drawLine(Offset(-g * 2, 0), const Offset(-5, 0), stroke);
      canvas.drawLine(const Offset(5, 0), Offset(g * 2, 0), stroke);
      canvas.drawLine(const Offset(-5, -13), const Offset(-5, 13), stroke);
      if (c.kind == CompKind.polarizedCapacitor) {
        canvas.drawArc(const Rect.fromLTRB(5, -13, 13, 13), math.pi * 0.65, math.pi * 0.7, false, stroke);
        drawText(canvas, '+', const Offset(-13, -10), colors.accentAmber, 10);
        drawText(canvas, '-', const Offset(14, -10), colors.scopeCh2, 11);
      } else {
        canvas.drawLine(const Offset(5, -13), const Offset(5, 13), stroke);
        canvas.drawLine(const Offset(-11, 11), const Offset(11, -11), stroke);
      }

    case CompKind.inductor:
      canvas.drawLine(Offset(-g * 2, 0), Offset(-g, 0), stroke);
      canvas.drawLine(Offset(g, 0), Offset(g * 2, 0), stroke);
      for (var i = 0; i < 3; i++) {
        final cx = -g * 0.66 + i * (g * 0.66);
        canvas.drawArc(
          Rect.fromCenter(center: Offset(cx, 0), width: g * 0.66, height: 14),
          math.pi,
          math.pi,
          false,
          stroke,
        );
      }

    case CompKind.varInductor:
      canvas.drawLine(Offset(-g * 2, 0), Offset(-g, 0), stroke);
      canvas.drawLine(Offset(g, 0), Offset(g * 2, 0), stroke);
      for (var i = 0; i < 4; i++) {
        canvas.drawArc(
          Rect.fromLTWH(-g + i * (g * 0.5), -8, g * 0.5, 16),
          math.pi,
          math.pi,
          false,
          stroke,
        );
      }
      canvas.drawLine(const Offset(-12, 12), const Offset(12, -12), stroke);

    case CompKind.crystal:
      canvas.drawLine(Offset(-g * 2, 0), const Offset(-9, 0), stroke);
      canvas.drawLine(const Offset(9, 0), Offset(g * 2, 0), stroke);
      canvas.drawLine(const Offset(-9, -12), const Offset(-9, 12), stroke);
      canvas.drawLine(const Offset(9, -12), const Offset(9, 12), stroke);
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: 10, height: 18), stroke);

    case CompKind.switchSpst:
      final closed = c.params[0] >= 0.5;
      canvas.drawLine(Offset(-g * 2, 0), Offset(-g * 0.7, 0), stroke);
      canvas.drawLine(Offset(g * 0.7, 0), Offset(g * 2, 0), stroke);
      canvas.drawLine(
        Offset(-g * 0.7, 0),
        closed ? Offset(g * 0.7, 0) : Offset(g * 0.5, -14),
        Paint()
          ..color = closed ? colors.accentAmber : colors.componentStroke
          ..strokeWidth = 2.4,
      );

    case CompKind.switchSpdt:
      final throwB = c.params[0] >= 0.5;
      canvas.drawLine(Offset(-g * 2, 0), Offset(-g * 0.7, 0), stroke);
      canvas.drawLine(Offset(g * 0.7, -g), Offset(g * 2, -g), stroke);
      canvas.drawLine(Offset(g * 0.7, g), Offset(g * 2, g), stroke);
      canvas.drawLine(
        Offset(-g * 0.7, 0),
        Offset(g * 0.7, throwB ? g : -g),
        Paint()
          ..color = colors.accentAmber
          ..strokeWidth = 2.4,
      );

    case CompKind.pushbutton:
      final closed = c.params[0] >= 0.5;
      canvas.drawLine(Offset(-g * 2, 0), Offset(-g * 0.7, 0), stroke);
      canvas.drawLine(Offset(g * 0.7, 0), Offset(g * 2, 0), stroke);
      final yBar = closed ? 0.0 : -10.0;
      final barPaint = Paint()
        ..color = closed ? colors.accentAmber : colors.componentStroke
        ..strokeWidth = 2.4;
      canvas.drawLine(Offset(-g * 0.7, yBar), Offset(g * 0.7, yBar), barPaint);
      canvas.drawLine(Offset(0, yBar), Offset(0, yBar - 10), barPaint);
      canvas.drawLine(Offset(-8, yBar - 10), Offset(8, yBar - 10), barPaint);

    case CompKind.vControlledSwitch || CompKind.iControlledSwitch:
      final vc = (nodeVoltages[doc.resolvedNodes[PinRef(c.id, 2)] ?? 0] ?? 0.0) -
          (nodeVoltages[doc.resolvedNodes[PinRef(c.id, 3)] ?? 0] ?? 0.0);
      final closed = c.kind == CompKind.vControlledSwitch
          ? vc.abs() >= (c.params.isNotEmpty ? c.params[0] : 2.0)
          : iMag >= (c.params.isNotEmpty ? c.params[0] : 0.01);
      // Top switched path (pins 0 & 1 at y = -g).
      canvas.drawLine(Offset(-g * 2, -g), Offset(-g * 0.7, -g), stroke);
      canvas.drawLine(Offset(g * 0.7, -g), Offset(g * 2, -g), stroke);
      canvas.drawLine(
        Offset(-g * 0.7, -g),
        closed ? Offset(g * 0.7, -g) : Offset(g * 0.5, -g - 11),
        Paint()
          ..color = closed ? colors.accentAmber : colors.componentStroke
          ..strokeWidth = 2.4,
      );
      // Bottom control sense path (pins 2 & 3 at y = +g).
      canvas.drawLine(Offset(-g * 2, g), Offset(-g * 0.8, g), stroke);
      canvas.drawLine(Offset(g * 0.8, g), Offset(g * 2, g), stroke);
      canvas.drawRect(Rect.fromCenter(center: Offset(0, g), width: g * 1.6, height: 14), stroke);
      drawText(canvas, c.kind == CompKind.vControlledSwitch ? 'VCTL' : 'ICTL', Offset(0, g), colors.accentAmber, 7.5);
      // Dashed coupling stem.
      for (var y = -g * 0.4; y <= g * 0.4; y += 6) {
        canvas.drawLine(Offset(0, y), Offset(0, y + 3), Paint()..color = colors.gridMajor..strokeWidth = 1.4);
      }

    case CompKind.relay:
      _drawCoilWindings(canvas, -g * 1.0, -g, g, stroke);
      canvas.drawLine(Offset(-g * 2, -g), Offset(-g * 1.0, -g), stroke);
      canvas.drawLine(Offset(-g * 2, g), Offset(-g * 1.0, g), stroke);
      final vCoil = ((nodeVoltages[doc.resolvedNodes[PinRef(c.id, 0)] ?? 0] ?? 0.0) -
              (nodeVoltages[doc.resolvedNodes[PinRef(c.id, 1)] ?? 0] ?? 0.0))
          .abs();
      final energized = vCoil >= c.params[1];
      canvas.drawLine(Offset(g * 0.6, -g), Offset(g * 2, -g), stroke);
      canvas.drawLine(Offset(g * 0.6, g), Offset(g * 2, g), stroke);
      canvas.drawLine(
        Offset(g * 0.6, -g),
        Offset(energized ? g * 0.6 : 0.0, g),
        Paint()
          ..color = energized ? colors.accentAmber : colors.componentStroke
          ..strokeWidth = 2.4,
      );
      canvas.drawLine(
        const Offset(-4, 0),
        const Offset(4, 0),
        Paint()
          ..color = energized ? colors.accentAmber : colors.gridMajor
          ..strokeWidth = 1.4,
      );

    case CompKind.relaySpdt:
      _drawCoilWindings(canvas, -g * 1.0, -g, g, stroke);
      canvas.drawLine(Offset(-g * 2, -g), Offset(-g * 1.0, -g), stroke);
      canvas.drawLine(Offset(-g * 2, g), Offset(-g * 1.0, g), stroke);
      final vCoil = ((nodeVoltages[doc.resolvedNodes[PinRef(c.id, 0)] ?? 0] ?? 0.0) -
              (nodeVoltages[doc.resolvedNodes[PinRef(c.id, 1)] ?? 0] ?? 0.0))
          .abs();
      final energized = c.params.length > 1 && vCoil >= c.params[1];
      // COM at (2, 0), NC at (2, -1), NO at (2, 1)
      canvas.drawLine(Offset(g * 1.1, 0), Offset(g * 2, 0), stroke);
      canvas.drawLine(Offset(g * 0.7, -g), Offset(g * 2, -g), stroke);
      canvas.drawLine(Offset(g * 0.7, g), Offset(g * 2, g), stroke);
      canvas.drawLine(
        Offset(g * 1.1, 0),
        Offset(g * 0.7, energized ? g : -g),
        Paint()
          ..color = energized ? colors.accentAmber : colors.componentStroke
          ..strokeWidth = 2.4,
      );
      for (var x = -g * 0.55; x <= g * 0.45; x += 6) {
        canvas.drawLine(Offset(x, 0), Offset(x + 3, 0), Paint()..color = energized ? colors.accentAmber : colors.gridMajor..strokeWidth = 1.4);
      }

    case CompKind.lamp:
      canvas.drawLine(Offset(-g * 2, 0), Offset(-g * 0.8, 0), stroke);
      canvas.drawLine(Offset(g * 0.8, 0), Offset(g * 2, 0), stroke);
      final power = iMag * iMag * c.params[0];
      if (power > 0.002) {
        final glow = math.sqrt((power / 0.5).clamp(0.05, 1.0));
        canvas.drawCircle(Offset.zero, g * 1.35, Paint()..color = const Color(0xFFFFB300).withAlpha((155 * glow).round()));
        canvas.drawCircle(
          Offset.zero,
          g * 0.8,
          Paint()..color = Color.lerp(const Color(0xFFFFB300), Colors.white, 0.5 * glow)!.withAlpha((225 * glow).round()),
        );
        final rayPaint = Paint()
          ..color = Color.lerp(const Color(0xFFFFB300), Colors.white, 0.35)!.withAlpha((235 * glow).round())
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round;
        for (var r = 0; r < 8; r++) {
          final ang = r * math.pi * 0.25;
          final dir = Offset(math.cos(ang), math.sin(ang));
          canvas.drawLine(dir * (g * 0.98), dir * (g * 1.32), rayPaint);
        }
      }
      canvas.drawCircle(Offset.zero, g * 0.8, stroke);
      canvas.drawLine(Offset(-g * 0.55, -g * 0.55), Offset(g * 0.55, g * 0.55), stroke);
      canvas.drawLine(Offset(-g * 0.55, g * 0.55), Offset(g * 0.55, -g * 0.55), stroke);

    case CompKind.fuse:
      final blown = blownFuseIds.contains(c.id);
      canvas.drawLine(Offset(-g * 2, 0), Offset(-g * 0.9, 0), stroke);
      canvas.drawLine(Offset(g * 0.9, 0), Offset(g * 2, 0), stroke);
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: g * 1.8, height: 14),
        blown ? (Paint()..color = colors.dangerRed..style = PaintingStyle.stroke..strokeWidth = 2.0) : stroke,
      );
      if (blown) {
        final bp = Paint()..color = colors.dangerRed..strokeWidth = 2.0;
        canvas.drawLine(Offset(-g * 0.9, 0), const Offset(-6, -3), bp);
        canvas.drawLine(const Offset(6, 3), Offset(g * 0.9, 0), bp);
      } else {
        canvas.drawLine(Offset(-g * 0.9, 0), Offset(g * 0.9, 0), stroke);
      }

    case CompKind.buzzer:
      canvas.drawLine(Offset(-g * 2, 0), Offset(-g * 0.8, 0), stroke);
      canvas.drawLine(Offset(g * 0.8, 0), Offset(g * 2, 0), stroke);
      final ringing = iMag > 0.005;
      if (ringing) {
        canvas.drawCircle(Offset.zero, g * 1.1, Paint()..color = colors.accentAmber.withAlpha(70));
        canvas.drawArc(
          Rect.fromCenter(center: Offset.zero, width: g * 2.4, height: g * 2.4),
          -math.pi * 0.75,
          math.pi * 0.5,
          false,
          Paint()
            ..color = colors.accentAmber
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6,
        );
      }
      canvas.drawCircle(Offset.zero, g * 0.75, stroke);
      drawText(canvas, 'BZ', Offset.zero, colors.accentAmber, 10);

    case CompKind.dcMotor:
      canvas.drawLine(Offset(-g * 2, 0), Offset(-g * 0.85, 0), stroke);
      canvas.drawLine(Offset(g * 0.85, 0), Offset(g * 2, 0), stroke);
      canvas.drawCircle(Offset.zero, g * 0.85, stroke);
      drawText(canvas, 'M', Offset.zero, colors.accentAmber, 13);

    case CompKind.diode || CompKind.zener || CompKind.led:
      canvas.drawLine(Offset(-g * 2, 0), const Offset(-10, 0), stroke);
      canvas.drawLine(const Offset(10, 0), Offset(g * 2, 0), stroke);
      final tri = Path()
        ..moveTo(-10, -11)
        ..lineTo(-10, 11)
        ..lineTo(10, 0)
        ..close();
      final iFwd = compCurrents[c.id] ?? 0.0;
      final ledLit = c.kind == CompKind.led && iFwd > 1e-4;
      if (ledLit) {
        final glow = math.sqrt(((iFwd - 1e-4) / 0.015).clamp(0.06, 1.0));
        canvas.drawCircle(Offset.zero, 26, Paint()..color = const Color(0xFFFFB300).withAlpha((155 * glow).round()));
        canvas.drawCircle(Offset.zero, 15, Paint()..color = const Color(0xFFFFE066).withAlpha((195 * glow).round()));
        canvas.drawPath(tri, Paint()..color = Color.lerp(const Color(0xFFFF8F00), Colors.white, 0.4 * glow)!..style = PaintingStyle.fill);
      }
      canvas.drawPath(tri, stroke);
      canvas.drawLine(const Offset(10, -11), const Offset(10, 11), stroke);
      if (c.kind == CompKind.led) {
        final rayPaint = Paint()
          ..color = ledLit ? const Color(0xFFFFD54F) : colors.accentAmber.withAlpha(170)
          ..strokeWidth = ledLit ? 2.0 : 1.4
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(const Offset(-1, -13), const Offset(6, -21), rayPaint);
        canvas.drawLine(const Offset(5, -10), const Offset(13, -18), rayPaint);
        if (ledLit) canvas.drawLine(const Offset(-8, -14), const Offset(-4, -22), rayPaint);
      }
      drawText(canvas, '+', Offset(-g * 1.35, -9), colors.accentAmber, 9);
      drawText(canvas, '-', Offset(g * 1.35, -9), colors.scopeCh2, 10);
      if (c.kind == CompKind.zener) {
        canvas.drawLine(const Offset(10, -11), const Offset(15, -14), stroke);
        canvas.drawLine(const Offset(10, 11), const Offset(5, 14), stroke);
      }

    case CompKind.schottkyDiode || CompKind.varactorDiode:
      canvas.drawLine(Offset(-g * 2, 0), const Offset(-10, 0), stroke);
      canvas.drawLine(const Offset(10, 0), Offset(g * 2, 0), stroke);
      final tri = Path()
        ..moveTo(-10, -11)
        ..lineTo(-10, 11)
        ..lineTo(10, 0)
        ..close();
      canvas.drawPath(tri, stroke);
      canvas.drawLine(const Offset(10, -11), const Offset(10, 11), stroke);
      if (c.kind == CompKind.varactorDiode) {
        canvas.drawLine(const Offset(15, -11), const Offset(15, 11), stroke);
      } else {
        canvas.drawLine(const Offset(10, -11), const Offset(14, -11), stroke);
        canvas.drawLine(const Offset(6, 11), const Offset(10, 11), stroke);
      }

    case CompKind.bridgeRectifier:
      // Pins: (-2,-1) AC1, (-2,1) AC2, (2,-1) DC+, (2,1) DC-
      canvas.drawLine(Offset(-g * 2, -g), Offset(-g * 0.9, 0), stroke);
      canvas.drawLine(Offset(-g * 2, g), Offset(0, g * 0.9), stroke);
      canvas.drawLine(Offset(0, -g * 0.9), Offset(g * 2, -g), stroke);
      canvas.drawLine(Offset(g * 0.9, 0), Offset(g * 2, g), stroke);
      final diamond = Path()
        ..moveTo(0, -g * 0.9)
        ..lineTo(g * 0.9, 0)
        ..lineTo(0, g * 0.9)
        ..lineTo(-g * 0.9, 0)
        ..close();
      canvas.drawPath(diamond, stroke);
      drawText(canvas, '~', Offset(-g * 1.4, -g + 9), colors.componentStroke, 10);
      drawText(canvas, '+', Offset(g * 1.35, -g - 8), colors.accentAmber, 10);
      drawText(canvas, '-', Offset(g * 1.35, g + 8), colors.scopeCh2, 11);

    case CompKind.rgbLed:
      _drawIcBox(canvas, c, doc, colors, stroke, 'RGB', drawText);
      final vk = nodeVoltages[doc.resolvedNodes[PinRef(c.id, 3)] ?? 0] ?? 0.0;
      final rv = ((nodeVoltages[doc.resolvedNodes[PinRef(c.id, 0)] ?? 0] ?? 0.0) - vk - 1.3).clamp(0.0, 1.5) / 1.5;
      final gv = ((nodeVoltages[doc.resolvedNodes[PinRef(c.id, 1)] ?? 0] ?? 0.0) - vk - 1.3).clamp(0.0, 1.5) / 1.5;
      final bv = ((nodeVoltages[doc.resolvedNodes[PinRef(c.id, 2)] ?? 0] ?? 0.0) - vk - 1.3).clamp(0.0, 1.5) / 1.5;
      if (rv + gv + bv > 0.05) {
        final col = Color.fromARGB(230, (rv * 255).round().clamp(0, 255), (gv * 255).round().clamp(0, 255), (bv * 255).round().clamp(0, 255));
        canvas.drawCircle(Offset.zero, 16, Paint()..color = col);
      }

    case CompKind.barGraphLed:
      _drawIcBox(canvas, c, doc, colors, stroke, '', drawText);
      final vk = nodeVoltages[doc.resolvedNodes[PinRef(c.id, 4)] ?? 0] ?? 0.0;
      for (var b = 0; b < 4; b++) {
        final va = nodeVoltages[doc.resolvedNodes[PinRef(c.id, b)] ?? 0] ?? 0.0;
        final lit = (va - vk) > 1.4;
        canvas.drawRect(Rect.fromLTWH(-12, (-2 + b) * g - 5, 24, 10), Paint()..color = lit ? colors.accentAmber : colors.gridMajor);
      }

    case CompKind.optocoupler:
      for (final py in [-g, g]) {
        canvas.drawLine(Offset(-g * 2, py), Offset(-g * 1.1, py), stroke);
        canvas.drawLine(Offset(g * 1.1, py), Offset(g * 2, py), stroke);
      }
      final active = (compCurrents[c.id] ?? 0.0).abs() > 5e-4;
      if (active) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: g * 2.2, height: g * 2.6), const Radius.circular(4)),
          Paint()..color = colors.accentAmber.withAlpha(45),
        );
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: g * 2.2, height: g * 2.6), const Radius.circular(4)),
        stroke,
      );
      drawText(canvas, 'OC', Offset.zero, active ? colors.accentAmber : colors.componentStroke, 10);

    case CompKind.opAmp || CompKind.comparatorOc || CompKind.instAmp:
      canvas.drawLine(Offset(-g * 2, -g), Offset(-g, -g), stroke);
      canvas.drawLine(Offset(-g * 2, g), Offset(-g, g), stroke);
      canvas.drawLine(Offset(g, 0), Offset(g * 2, 0), stroke);
      final tri = Path()
        ..moveTo(-g, -g * 1.4)
        ..lineTo(-g, g * 1.4)
        ..lineTo(g, 0)
        ..close();
      canvas.drawPath(tri, stroke);
      drawText(canvas, '+', Offset(-g + 8, -g * 0.6), colors.componentStroke, 11);
      drawText(canvas, '-', Offset(-g + 8, g * 0.6), colors.componentStroke, 11);
      if (c.kind == CompKind.comparatorOc) {
        drawText(canvas, 'OC', Offset(-g * 0.1, 0), colors.accentAmber, 8);
      } else if (c.kind == CompKind.instAmp) {
        drawText(canvas, 'INA', Offset(-g * 0.1, 0), colors.accentAmber, 8);
      }

    case CompKind.analogMultiplier:
      canvas.drawLine(Offset(-g * 2, -g), Offset(-g * 0.7, -g * 0.55), stroke);
      canvas.drawLine(Offset(-g * 2, g), Offset(-g * 0.7, g * 0.55), stroke);
      canvas.drawLine(Offset(g * 0.9, 0), Offset(g * 2, 0), stroke);
      canvas.drawCircle(Offset.zero, g * 0.9, stroke);
      drawText(canvas, 'X*Y', Offset.zero, colors.accentAmber, 9);

    case CompKind.voltageReg:
      _drawIcBox(canvas, c, doc, colors, stroke, '78xx', drawText);

    case CompKind.vco || CompKind.sampleHold:
      _drawIcBox(canvas, c, doc, colors, stroke, c.kind == CompKind.vco ? 'VCO' : 'S&H', drawText);

    case CompKind.npnBjt || CompKind.pnpBjt:
      canvas.drawLine(Offset(-g * 2, 0), const Offset(-6, 0), stroke);
      canvas.drawLine(const Offset(-6, -16), const Offset(-6, 16), stroke);
      canvas.drawLine(const Offset(-6, -8), Offset(g, -g * 2), stroke);
      canvas.drawLine(const Offset(-6, 8), Offset(g, g * 2), stroke);
      final ap = Paint()..color = colors.accentAmber;
      if (c.kind == CompKind.npnBjt) {
        _drawArrowHead(canvas, Offset(g * 0.65, g * 1.45), const Offset(1, 1.4), 7, ap);
      } else {
        _drawArrowHead(canvas, Offset(g * 0.15, g * 0.8), const Offset(-1, -1.23), 7, ap);
      }

    case CompKind.nmos || CompKind.pmos:
      canvas.drawLine(Offset(-g * 2, 0), const Offset(-10, 0), stroke);
      canvas.drawLine(const Offset(-10, -14), const Offset(-10, 14), stroke);
      canvas.drawLine(const Offset(-5, -14), const Offset(-5, -6), stroke);
      canvas.drawLine(const Offset(-5, -4), const Offset(-5, 4), stroke);
      canvas.drawLine(const Offset(-5, 6), const Offset(-5, 14), stroke);
      canvas.drawLine(const Offset(-5, -10), Offset(g, -10), stroke);
      canvas.drawLine(Offset(g, -10), Offset(g, -g * 2), stroke);
      canvas.drawLine(const Offset(-5, 10), Offset(g, 10), stroke);
      canvas.drawLine(Offset(g, 10), Offset(g, g * 2), stroke);
      canvas.drawLine(const Offset(-5, 0), Offset(g, 0), stroke);
      canvas.drawLine(Offset(g, 0), Offset(g, 10), stroke);
      final ap = Paint()..color = colors.accentAmber;
      if (c.kind == CompKind.nmos) {
        _drawArrowHead(canvas, const Offset(-4, 0), const Offset(-1, 0), 6, ap);
      } else {
        _drawArrowHead(canvas, const Offset(8, 0), const Offset(1, 0), 6, ap);
      }

    case CompKind.njfet || CompKind.pjfet:
      canvas.drawLine(Offset(-g * 2, 0), const Offset(-6, 0), stroke);
      canvas.drawLine(const Offset(-6, -12), const Offset(-6, 12), stroke);
      canvas.drawLine(Offset(g, -g * 2), Offset(g, -10), stroke);
      canvas.drawLine(Offset(g, -10), const Offset(-6, -10), stroke);
      canvas.drawLine(Offset(g, g * 2), Offset(g, 10), stroke);
      canvas.drawLine(Offset(g, 10), const Offset(-6, 10), stroke);
      final ap = Paint()..color = colors.accentAmber;
      if (c.kind == CompKind.njfet) {
        _drawArrowHead(canvas, const Offset(-7, 0), const Offset(1, 0), 6, ap);
      } else {
        _drawArrowHead(canvas, const Offset(-16, 0), const Offset(-1, 0), 6, ap);
      }

    case CompKind.scr:
      canvas.drawLine(Offset(-g * 2, 0), const Offset(-10, 0), stroke);
      canvas.drawLine(const Offset(10, 0), Offset(g * 2, 0), stroke);
      final tri = Path()
        ..moveTo(-10, -11)
        ..lineTo(-10, 11)
        ..lineTo(10, 0)
        ..close();
      canvas.drawPath(tri, stroke);
      canvas.drawLine(const Offset(10, -11), const Offset(10, 11), stroke);
      canvas.drawLine(const Offset(10, 8), const Offset(0, 18), stroke);
      canvas.drawLine(const Offset(0, 18), Offset(0, g * 2), stroke);

    case CompKind.triac:
      canvas.drawLine(Offset(-g * 2, 0), const Offset(-10, 0), stroke);
      canvas.drawLine(const Offset(10, 0), Offset(g * 2, 0), stroke);
      final t1 = Path()..moveTo(-10, -12)..lineTo(-10, 0)..lineTo(10, -6)..close();
      final t2 = Path()..moveTo(10, 0)..lineTo(10, 12)..lineTo(-10, 6)..close();
      canvas.drawPath(t1, stroke);
      canvas.drawPath(t2, stroke);
      canvas.drawLine(const Offset(10, 9), const Offset(0, 18), stroke);
      canvas.drawLine(const Offset(0, 18), Offset(0, g * 2), stroke);

    case CompKind.diac:
      canvas.drawLine(Offset(-g * 2, 0), const Offset(-10, 0), stroke);
      canvas.drawLine(const Offset(10, 0), Offset(g * 2, 0), stroke);
      final t1 = Path()..moveTo(-10, -12)..lineTo(-10, 0)..lineTo(10, -6)..close();
      final t2 = Path()..moveTo(10, 0)..lineTo(10, 12)..lineTo(-10, 6)..close();
      canvas.drawPath(t1, stroke);
      canvas.drawPath(t2, stroke);
      canvas.drawLine(const Offset(-10, -12), const Offset(-10, 12), stroke);
      canvas.drawLine(const Offset(10, -12), const Offset(10, 12), stroke);

    case CompKind.igbt:
      canvas.drawLine(Offset(-g * 2, 0), const Offset(-11, 0), stroke);
      canvas.drawLine(const Offset(-11, -14), const Offset(-11, 14), stroke);
      canvas.drawLine(const Offset(-6, -15), const Offset(-6, 15), stroke);
      canvas.drawLine(const Offset(-6, -8), Offset(g, -g * 2), stroke);
      canvas.drawLine(const Offset(-6, 8), Offset(g, g * 2), stroke);
      _drawArrowHead(canvas, Offset(g * 0.65, g * 1.45), const Offset(1, 1.4), 7, Paint()..color = colors.accentAmber);

    case CompKind.vcvs || CompKind.vccs || CompKind.cccs || CompKind.ccvs:
      canvas.drawLine(Offset(-g * 2, -g), Offset(-g, -g), stroke);
      canvas.drawLine(Offset(-g * 2, g), Offset(-g, g), stroke);
      canvas.drawLine(Offset(g, -g), Offset(g * 2, -g), stroke);
      canvas.drawLine(Offset(g, g), Offset(g * 2, g), stroke);
      final diamond = Path()
        ..moveTo(0, -g * 1.2)
        ..lineTo(g, 0)
        ..lineTo(0, g * 1.2)
        ..lineTo(-g, 0)
        ..close();
      canvas.drawPath(diamond, stroke);
      final srcTag = switch (c.kind) {
        CompKind.vcvs => 'E',
        CompKind.vccs => 'G',
        CompKind.cccs => 'F',
        _ => 'H',
      };
      drawText(canvas, srcTag, Offset.zero, colors.accentAmber, 11);

    case CompKind.transformer || CompKind.coupledInductor:
      canvas.drawLine(Offset(-g * 2, -g), Offset(-g * 0.5, -g), stroke);
      canvas.drawLine(Offset(-g * 2, g), Offset(-g * 0.5, g), stroke);
      canvas.drawLine(Offset(g * 0.5, -g), Offset(g * 2, -g), stroke);
      canvas.drawLine(Offset(g * 0.5, g), Offset(g * 2, g), stroke);
      for (var i = 0; i < 3; i++) {
        final cy = -g * 0.65 + i * g * 0.65;
        canvas.drawArc(Rect.fromCenter(center: Offset(-g * 0.5, cy), width: 12, height: g * 0.65), -math.pi * 0.5, math.pi, false, stroke);
        canvas.drawArc(Rect.fromCenter(center: Offset(g * 0.5, cy), width: 12, height: g * 0.65), math.pi * 0.5, math.pi, false, stroke);
      }
      canvas.drawLine(Offset(-2, -g), Offset(-2, g), stroke);
      canvas.drawLine(Offset(2, -g), Offset(2, g), stroke);
      if (c.kind == CompKind.coupledInductor) {
        canvas.drawCircle(Offset(-g * 0.9, -g * 0.7), 2.5, Paint()..color = colors.accentAmber);
        canvas.drawCircle(Offset(g * 0.9, -g * 0.7), 2.5, Paint()..color = colors.accentAmber);
      }

    case CompKind.centerTapTransformer:
      canvas.drawLine(Offset(-g * 2, -g), Offset(-g * 0.5, -g), stroke);
      canvas.drawLine(Offset(-g * 2, g), Offset(-g * 0.5, g), stroke);
      canvas.drawLine(Offset(g * 0.5, -g), Offset(g * 2, -g), stroke);
      canvas.drawLine(Offset(g * 0.5, 0), Offset(g * 2, 0), stroke);
      canvas.drawLine(Offset(g * 0.5, g), Offset(g * 2, g), stroke);
      for (var i = 0; i < 4; i++) {
        final cy = -g * 0.75 + i * g * 0.5;
        canvas.drawArc(Rect.fromCenter(center: Offset(-g * 0.5, cy), width: 11, height: g * 0.5), -math.pi * 0.5, math.pi, false, stroke);
        canvas.drawArc(Rect.fromCenter(center: Offset(g * 0.5, cy), width: 11, height: g * 0.5), math.pi * 0.5, math.pi, false, stroke);
      }
      canvas.drawLine(Offset(-2, -g), Offset(-2, g), stroke);
      canvas.drawLine(Offset(2, -g), Offset(2, g), stroke);

    case CompKind.notGate || CompKind.bufferGate || CompKind.triStateBuffer:
      canvas.drawLine(Offset(-g * 2, 0), Offset(-g * 0.85, 0), stroke);
      final tri = Path()
        ..moveTo(-g * 0.85, -g * 0.9)
        ..lineTo(-g * 0.85, g * 0.9)
        ..lineTo(g * 0.75, 0)
        ..close();
      canvas.drawPath(tri, stroke);
      if (c.kind == CompKind.notGate) {
        canvas.drawCircle(Offset(g * 0.75 + 4, 0), 4, stroke);
        canvas.drawLine(Offset(g * 0.75 + 8, 0), Offset(g * 2, 0), stroke);
      } else {
        canvas.drawLine(Offset(g * 0.75, 0), Offset(g * 2, 0), stroke);
        if (c.kind == CompKind.triStateBuffer) {
          canvas.drawLine(Offset(0, -g * 2), Offset(0, -g * 0.44), stroke);
        }
      }

    case CompKind.andGate || CompKind.nandGate || CompKind.and3Gate || CompKind.nand4Gate:
      _drawAndGateShape(canvas, c, g, stroke, inverted: c.kind == CompKind.nandGate || c.kind == CompKind.nand4Gate);

    case CompKind.orGate || CompKind.norGate || CompKind.xorGate || CompKind.xnorGate || CompKind.or3Gate:
      _drawOrGateShape(
        canvas,
        c,
        g,
        stroke,
        inverted: c.kind == CompKind.norGate || c.kind == CompKind.xnorGate,
        xor: c.kind == CompKind.xorGate || c.kind == CompKind.xnorGate,
      );

    case CompKind.dFlipFlop:
      canvas.drawLine(Offset(-g * 2, -g), Offset(-g, -g), stroke);
      canvas.drawLine(Offset(-g * 2, g), Offset(-g, g), stroke);
      canvas.drawLine(Offset(g, -g), Offset(g * 2, -g), stroke);
      canvas.drawLine(Offset(g, g), Offset(g * 2, g), stroke);
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: g * 2, height: g * 2.6), stroke);
      canvas.drawLine(Offset(-g, g - 5), Offset(-g + 6, g), stroke);
      canvas.drawLine(Offset(-g, g + 5), Offset(-g + 6, g), stroke);
      drawText(canvas, 'D', Offset(-g + 8, -g), colors.componentStroke, 9);
      drawText(canvas, 'Q', Offset(g - 8, -g), colors.accentAmber, 9);
      drawText(canvas, '!Q', Offset(g - 10, g), colors.componentStroke, 9);
      drawText(canvas, 'DFF', Offset.zero, colors.accentAmber, 9);

    case CompKind.logicProbe:
      canvas.drawLine(Offset(-g, 0), Offset(-g * 0.4, 0), stroke);
      final nodeId = doc.resolvedNodes[PinRef(c.id, 0)] ?? 0;
      final v = nodeVoltages[nodeId] ?? 0.0;
      final (tag, bg, fg) = v >= 2.5
          ? ('HI', colors.accentAmber, Colors.black)
          : (v <= 1.2
              ? ('LO', colors.panelSurface, colors.componentStroke)
              : ('?', colors.dangerRed.withAlpha(200), Colors.black));
      final box = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(g * 0.45, 0), width: g * 1.7, height: g * 1.05), const Radius.circular(6));
      canvas.drawRRect(box, Paint()..color = bg);
      canvas.drawRRect(box, stroke);
      drawText(canvas, tag, Offset(g * 0.45, 0), fg, 10);

    case CompKind.logicIndicator:
      final v = nodeVoltages[doc.resolvedNodes[PinRef(c.id, 0)] ?? 0] ?? 0.0;
      final col = v >= 2.5 ? colors.accentAmber : (v <= 1.2 ? colors.gridMajor : colors.dangerRed);
      canvas.drawLine(Offset(-g, 0), Offset.zero, stroke);
      canvas.drawCircle(const Offset(10, 0), 11, Paint()..color = col);
      canvas.drawCircle(const Offset(10, 0), 11, stroke);
      drawText(canvas, v >= 2.5 ? '1' : (v <= 1.2 ? '0' : '?'), const Offset(10, 0), v >= 2.5 ? Colors.black : colors.componentStroke, 10);

    case CompKind.timer555:
      canvas.drawLine(Offset(-g * 2, -g), Offset(-g, -g), stroke);
      canvas.drawLine(Offset(-g * 2, g), Offset(-g, g), stroke);
      canvas.drawLine(Offset(g, -g), Offset(g * 2, -g), stroke);
      canvas.drawLine(Offset(g, g), Offset(g * 2, g), stroke);
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: g * 2, height: g * 2.6), stroke);
      drawText(canvas, 'TR', Offset(-g + 9, -g), colors.componentStroke, 8);
      drawText(canvas, 'TH', Offset(-g + 9, g), colors.componentStroke, 8);
      drawText(canvas, 'DIS', Offset(g - 11, -g), colors.componentStroke, 8);
      drawText(canvas, 'OUT', Offset(g - 11, g), colors.accentAmber, 8);
      drawText(canvas, '555', Offset.zero, colors.accentAmber, 10);

    case CompKind.sevenSeg:
      for (var p = 0; p < 4; p++) {
        final py = (-2 + p) * g;
        canvas.drawLine(Offset(-g * 2, py), Offset(-g * 0.7, py), stroke);
      }
      final box = RRect.fromRectAndRadius(Rect.fromLTRB(-g * 0.7, -g * 2.2, g * 1.4, g * 1.4), const Radius.circular(4));
      canvas.drawRRect(box, Paint()..color = colors.canvasBackground);
      canvas.drawRRect(box, stroke);
      var hex = 0;
      for (var p = 0; p < 4; p++) {
        final v = nodeVoltages[doc.resolvedNodes[PinRef(c.id, p)] ?? 0] ?? 0.0;
        if (v >= 2.5) hex |= (1 << (3 - p));
      }
      const segMask = [0x7E, 0x30, 0x6D, 0x79, 0x33, 0x5B, 0x5F, 0x70, 0x7F, 0x7B, 0x77, 0x1F, 0x4E, 0x3D, 0x4F, 0x47];
      final m = segMask[hex];
      final l = -g * 0.25, r = g * 0.95, top = -g * 1.65, mid = -g * 0.4, bot = g * 0.85;
      final segs = [
        (Offset(l, top), Offset(r, top)),
        (Offset(r, top), Offset(r, mid)),
        (Offset(r, mid), Offset(r, bot)),
        (Offset(l, bot), Offset(r, bot)),
        (Offset(l, mid), Offset(l, bot)),
        (Offset(l, top), Offset(l, mid)),
        (Offset(l, mid), Offset(r, mid)),
      ];
      for (var s = 0; s < 7; s++) {
        final on = ((m >> (6 - s)) & 1) == 1;
        canvas.drawLine(
          segs[s].$1,
          segs[s].$2,
          Paint()
            ..color = on ? colors.accentAmber : colors.gridMajor
            ..strokeWidth = 3.0
            ..strokeCap = StrokeCap.round,
        );
      }

    case CompKind.wordGen:
      for (var p = 0; p < 4; p++) {
        final py = (-2 + p) * g;
        canvas.drawLine(Offset(g * 0.7, py), Offset(g * 2, py), stroke);
      }
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(-g * 1.3, -g * 2.2, g * 0.7, g * 1.4), const Radius.circular(4)), stroke);
      drawText(canvas, 'WG', Offset(-g * 0.3, -g * 0.4), colors.accentAmber, 11);

    case CompKind.schmittTrigger:
      canvas.drawLine(Offset(-g * 2, -g), Offset(-g, -g), stroke);
      canvas.drawLine(Offset(-g * 2, g), Offset(-g, g), stroke);
      canvas.drawLine(Offset(g, 0), Offset(g * 2, 0), stroke);
      final tri = Path()..moveTo(-g, -g * 1.4)..lineTo(-g, g * 1.4)..lineTo(g, 0)..close();
      canvas.drawPath(tri, stroke);
      drawText(canvas, 'ST', Offset(-g * 0.25, 0), colors.accentAmber, 10);

    case CompKind.counter4Bit:
      canvas.drawLine(Offset(-g * 2, 0), Offset(-g, 0), stroke);
      for (final py in [-g, 0.0, g]) {
        canvas.drawLine(Offset(g, py), Offset(g * 2, py), stroke);
      }
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: g * 2, height: g * 2.6), stroke);
      drawText(canvas, 'CLK', Offset(-g + 10, 0), colors.componentStroke, 7);
      drawText(canvas, 'CNT', Offset(3, 0), colors.accentAmber, 9);

    case CompKind.voltmeter || CompKind.ammeter || CompKind.wattmeter:
      final label = c.kind == CompKind.voltmeter ? 'V' : (c.kind == CompKind.ammeter ? 'A' : 'W');
      final valText = switch (c.kind) {
        CompKind.voltmeter =>
          '${((nodeVoltages[doc.resolvedNodes[PinRef(c.id, 0)] ?? 0] ?? 0.0) - (nodeVoltages[doc.resolvedNodes[PinRef(c.id, 1)] ?? 0] ?? 0.0)).toStringAsFixed(2)}V',
        CompKind.ammeter => '${(iMag * 1000).toStringAsFixed(1)}mA',
        _ =>
          '${((((nodeVoltages[doc.resolvedNodes[PinRef(c.id, 2)] ?? 0] ?? 0.0) - (nodeVoltages[doc.resolvedNodes[PinRef(c.id, 3)] ?? 0] ?? 0.0)) * (compCurrents[c.id] ?? 0.0)).abs() * 1000).toStringAsFixed(1)}mW',
      };
      if (c.kind == CompKind.wattmeter) {
        _drawIcBox(canvas, c, doc, colors, stroke, valText, drawText, cacheText: false);
      } else {
        canvas.drawLine(Offset(-g * 2, 0), Offset(-g * 0.9, 0), stroke);
        canvas.drawLine(Offset(g * 0.9, 0), Offset(g * 2, 0), stroke);
        canvas.drawCircle(Offset.zero, g * 0.9, stroke);
        drawText(canvas, label, const Offset(0, -6), colors.accentAmber, 10);
        drawText(canvas, valText, const Offset(0, 7), colors.componentStroke, 8, cache: false);
      }

    case CompKind.relayDpdt ||
        CompKind.srLatch ||
        CompKind.jkFlipFlop ||
        CompKind.tFlipFlop ||
        CompKind.dFlipFlopAsync ||
        CompKind.counter4BitFull ||
        CompKind.shiftReg4Bit ||
        CompKind.mux4To1 ||
        CompKind.demux1To4 ||
        CompKind.decoder2To4 ||
        CompKind.fullAdder ||
        CompKind.magComparator ||
        CompKind.alu2Bit ||
        CompKind.adc4Bit ||
        CompKind.dac4Bit ||
        CompKind.hexKeypad ||
        CompKind.dipSwitch4 ||
        CompKind.subcircuit:
      final title = switch (c.kind) {
        CompKind.relayDpdt => 'DPDT',
        CompKind.srLatch => 'SR',
        CompKind.jkFlipFlop => 'JK',
        CompKind.tFlipFlop => 'T-FF',
        CompKind.dFlipFlopAsync => 'DFF+',
        CompKind.counter4BitFull => 'CNT4',
        CompKind.shiftReg4Bit => 'SHFT',
        CompKind.mux4To1 => 'MUX4',
        CompKind.demux1To4 => 'DMUX',
        CompKind.decoder2To4 => 'DEC',
        CompKind.fullAdder => 'ADD',
        CompKind.magComparator => 'CMP2',
        CompKind.alu2Bit => 'ALU',
        CompKind.adc4Bit => 'ADC4',
        CompKind.dac4Bit => 'DAC4',
        CompKind.hexKeypad => 'KEY',
        CompKind.dipSwitch4 => 'DIP4',
        CompKind.subcircuit => c.subcircuitName ?? 'SUB',
        _ => 'IC',
      };
      _drawIcBox(canvas, c, doc, colors, stroke, title, drawText);
  }
}

void _drawCoilWindings(Canvas canvas, double x, double topY, double botY, Paint stroke) {
  final h = botY - topY;
  final step = h / 3;
  for (var i = 0; i < 3; i++) {
    final cy = topY + (i + 0.5) * step;
    canvas.drawArc(Rect.fromCenter(center: Offset(x, cy), width: 10, height: step), -math.pi * 0.5, math.pi, false, stroke);
  }
}

void _drawAndGateShape(Canvas canvas, PlacedComponent c, double g, Paint stroke, {required bool inverted}) {
  var minY = -g * 1.15;
  var maxY = g * 1.15;
  for (var i = 0; i < c.pinOffsets.length - 1; i++) {
    final py = c.pinOffsets[i].dy * g;
    if (py - 8 < minY) minY = py - 8;
    if (py + 8 > maxY) maxY = py + 8;
    canvas.drawLine(Offset(-g * 2, py), Offset(-g * 0.9, py), stroke);
  }
  final tipX = g * 0.85;
  final path = Path()
    ..moveTo(-g * 0.9, minY)
    ..lineTo(tipX - 15, minY)
    ..cubicTo(tipX + 5, minY, tipX + 5, maxY, tipX - 15, maxY)
    ..lineTo(-g * 0.9, maxY)
    ..close();
  canvas.drawPath(path, stroke);
  if (inverted) {
    canvas.drawCircle(Offset(tipX + 4, 0), 4, stroke);
    canvas.drawLine(Offset(tipX + 8, 0), Offset(g * 2, 0), stroke);
  } else {
    canvas.drawLine(Offset(tipX, 0), Offset(g * 2, 0), stroke);
  }
}

void _drawOrGateShape(Canvas canvas, PlacedComponent c, double g, Paint stroke, {required bool inverted, required bool xor}) {
  const topY = -28.0;
  const botY = 28.0;
  final backX = xor ? -g * 0.65 : -g * 0.9;
  for (var i = 0; i < c.pinOffsets.length - 1; i++) {
    final py = c.pinOffsets[i].dy * g;
    canvas.drawLine(Offset(-g * 2, py), Offset(backX + 4, py), stroke);
  }
  final path = Path()
    ..moveTo(backX, topY)
    ..quadraticBezierTo(g * 0.25, topY, g * 0.85, 0)
    ..quadraticBezierTo(g * 0.25, botY, backX, botY)
    ..quadraticBezierTo(backX + 10, 0, backX, topY)
    ..close();
  canvas.drawPath(path, stroke);
  if (xor) {
    final xorArc = Path()
      ..moveTo(backX - 6, topY)
      ..quadraticBezierTo(backX + 4, 0, backX - 6, botY);
    canvas.drawPath(xorArc, stroke);
  }
  if (inverted) {
    canvas.drawCircle(Offset(g * 0.85 + 4, 0), 4, stroke);
    canvas.drawLine(Offset(g * 0.85 + 8, 0), Offset(g * 2, 0), stroke);
  } else {
    canvas.drawLine(Offset(g * 0.85, 0), Offset(g * 2, 0), stroke);
  }
}

void _drawIcBox(
  Canvas canvas,
  PlacedComponent c,
  CircuitDoc doc,
  CircuitColors colors,
  Paint stroke,
  String title,
  DrawTextFn drawText, {
  bool cacheText = true,
}) {
  final g = kGridStep;
  // Compute vertical bounds strictly from left/right pins so top/bottom pins do not swallow the box frame.
  var minHy = -g;
  var maxHy = g;
  for (final o in c.pinOffsets) {
    if (o.dx != 0) {
      final py = o.dy * g;
      if (py < minHy) minHy = py;
      if (py > maxHy) maxHy = py;
    }
  }
  final topEdge = minHy - 6;
  final botEdge = maxHy + 6;
  final halfW = c.pinOffsets.length >= 6 ? g * 1.25 : g * 1.1;
  final leftEdge = -halfW;
  final rightEdge = halfW;

  for (var i = 0; i < c.pinOffsets.length; i++) {
    final o = c.pinOffsets[i];
    final px = o.dx * g;
    final py = o.dy * g;
    final sx = o.dx > 0 ? rightEdge : (o.dx < 0 ? leftEdge : 0.0);
    final sy = o.dx == 0 ? (o.dy > 0 ? botEdge : topEdge) : py;
    canvas.drawLine(Offset(px, py), Offset(sx, sy), stroke);
    if (c.pinOffsets.length >= 3 && title.isNotEmpty) {
      final lbl = pinLabelFor(c, i, doc);
      final shortLbl = lbl.length > 4 ? lbl.substring(0, 4) : lbl;
      final labelOffset = o.dx < 0
          ? Offset(leftEdge + 11, py)
          : (o.dx > 0
              ? Offset(rightEdge - 11, py)
              : Offset(0, o.dy < 0 ? topEdge + 8 : botEdge - 8));
      drawText(canvas, shortLbl, labelOffset, colors.componentStroke.withAlpha(200), 7, cache: true);
    }
  }

  canvas.drawRRect(
    RRect.fromRectAndRadius(Rect.fromLTRB(leftEdge, topEdge, rightEdge, botEdge), const Radius.circular(4)),
    stroke,
  );
  if (title.isNotEmpty) {
    drawText(canvas, title, Offset.zero, colors.accentAmber, 10, cache: cacheText);
  }
}
