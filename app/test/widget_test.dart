import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:benchosc/canvas/schematic_canvas.dart';
import 'package:benchosc/ffi/sim_ffi.dart';
import 'package:benchosc/ffi/sim_isolate.dart';
import 'package:benchosc/instruments/bode_plotter_view.dart';
import 'package:benchosc/instruments/dc_sweep_view.dart';
import 'package:benchosc/instruments/logic_analyzer_view.dart';
import 'package:benchosc/instruments/logic_converter_view.dart';
import 'package:benchosc/instruments/multimeter_view.dart';
import 'package:benchosc/instruments/oscilloscope_view.dart';
import 'package:benchosc/instruments/spectrum_analyzer_view.dart';
import 'package:benchosc/instruments/word_gen_panel.dart';
import 'package:benchosc/l10n/app_localizations.dart';
import 'package:benchosc/main.dart';
import 'package:benchosc/state/circuit_doc.dart';
import 'package:benchosc/state/circuit_exports.dart';
import 'package:benchosc/theme/circuit_theme.dart';

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
}

void main() {
  testWidgets('Desktop layout renders Dark Amber theme, instruments, and zero overflow',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const BenchOscApp());
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('BenchOsc'), findsOneWidget);
    expect(find.text('Oscilloscope'), findsNothing);
    expect(find.byTooltip('Components (Ctrl+1)'), findsOneWidget);
    expect(find.byTooltip('Properties (Ctrl+2)'), findsOneWidget);
    expect(find.byTooltip('Instruments (Ctrl+3)'), findsOneWidget);

    await tester.tap(find.byTooltip('Instruments (Ctrl+3)'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Oscilloscope'), findsWidgets);
    expect(find.textContaining('Vpp:'), findsOneWidget);
    expect(find.text('5.00ms/d'), findsOneWidget);

    final ctx = tester.element(find.byType(Scaffold));
    final colors = Theme.of(ctx).extension<CircuitColors>();
    expect(colors, isNotNull);
    expect(colors!.accentAmber, const Color(0xFFFFB300));

    // Switch through instrument tabs (Multimeter, Bode Plotter, Logic Converter)
    await tester.tap(find.text('Multimeter'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Current'), findsOneWidget);
    expect(find.textContaining('Power:'), findsOneWidget);
    expect(find.textContaining('Comp ΔV:'), findsOneWidget);

    await tester.tap(find.text('Bode Plotter'));
    await tester.pump(const Duration(milliseconds: 50));
    await _pumpUntilFound(tester, find.textContaining('f(-3dB):'));
    expect(find.text('Run AC Sweep'), findsOneWidget);
    expect(find.textContaining('f(-3dB):'), findsOneWidget);

    await tester.tap(find.text('Logic Converter'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Simplified SOP'), findsOneWidget);
    expect(find.text('Build Circuit'), findsOneWidget);
    await tester.tap(find.text('Build Circuit'));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Logic Analyzer'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('0b'), findsOneWidget);

    await tester.tap(find.text('DC Sweep'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Run DC Sweep'), findsOneWidget);

    // Toggle schematic overlay FilterChips & verify Box / Fit controls
    expect(find.text('Box'), findsOneWidget);
    expect(find.text('Fit'), findsOneWidget);
    await tester.ensureVisible(find.text('Fit'));
    await tester.tap(find.text('Fit'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Labels'), findsOneWidget);
    expect(find.text('Node V'), findsOneWidget);
    await tester.ensureVisible(find.text('Node V'));
    await tester.tap(find.text('Node V'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.ensureVisible(find.text('Labels'));
    await tester.tap(find.text('Labels'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('CH3'), findsOneWidget);
    expect(find.text('CH4'), findsOneWidget);
    await tester.tap(find.byTooltip('Toggle Light/Dark Theme'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final lightColors = Theme.of(tester.element(find.byType(Scaffold))).extension<CircuitColors>()!;
    expect(lightColors.accentAmber, CircuitColors.lightBench.accentAmber);
  });

  testWidgets('Phone layout (390x844) renders without overflow and opens drawers',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const BenchOscApp());
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Components'), findsOneWidget);
    expect(find.text('Properties'), findsOneWidget);
    expect(find.text('Instruments'), findsOneWidget);

    await tester.tap(find.text('Instruments'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Oscilloscope'), findsWidgets);

    await tester.tap(find.text('Components'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Resistor'), findsNothing);
    await tester.tap(find.text('Passives'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Resistor'), findsOneWidget);
  });

  testWidgets('Compact phone layout (360x640) renders without overflow', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const BenchOscApp());
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('BenchOsc'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
  });

  test('CircuitDoc presets, undo/redo, JSON round-trip and SPICE .cir export/import', () {
    final doc = CircuitDoc();
    doc.loadPreset(PresetKind.opAmp);
    expect(doc.components.length, 6);

    final json = doc.toJsonString();
    final copy = CircuitDoc();
    copy.loadJsonString(json);
    expect(copy.components.length, doc.components.length);
    expect(copy.wires.length, doc.wires.length);

    final cir = doc.toSpiceCir();
    expect(cir, contains('.end'));

    // Round-trip SIN(...) + SI suffixes via loadSpiceCir
    final imported = CircuitDoc();
    imported.loadSpiceCir('* Test\nV1 1 0 SIN(0.0 5.0 120.0)\nR1 1 2 10k\nC1 2 0 1u\n.end');
    final fg = imported.components.firstWhere((c) => c.kind == CompKind.funcGen);
    final res = imported.components.firstWhere((c) => c.kind == CompKind.resistor);
    final cap = imported.components.firstWhere((c) => c.kind == CompKind.capacitor);
    expect(fg.params[1], closeTo(5.0, 1e-6));
    expect(fg.params[2], closeTo(120.0, 1e-6));
    expect(res.params[0], closeTo(10000.0, 1e-6));
    expect(cap.params[0], closeTo(1e-6, 1e-12));

    // Delete individual wire
    final wireCount = imported.wires.length;
    imported.deleteWireAt(0);
    expect(imported.wires.length, wireCount - 1);

    // Undo / Redo test
    final added = copy.addComponent(CompKind.resistor, 5, 5);
    expect(copy.components.any((c) => c.id == added.id), isTrue);
    expect(copy.canUndo, isTrue);
    copy.undo();
    expect(copy.components.any((c) => c.id == added.id), isFalse);
    copy.redo();
    expect(copy.components.any((c) => c.id == added.id), isTrue);

    // Iteration 1 components, D-FF divider preset, badge formatting, and VCCS SPICE import
    final dffDoc = CircuitDoc();
    dffDoc.loadPreset(PresetKind.dffDivider);
    expect(dffDoc.components.any((c) => c.kind == CompKind.dFlipFlop), isTrue);
    expect(dffDoc.components.where((c) => c.kind == CompKind.logicProbe).length, 3);

    final vccsDoc = CircuitDoc();
    vccsDoc.loadSpiceCir('* VCCS\nV1 1 0 DC 5\nG1 0 2 1 0 2m\nR1 2 0 1k\n.end');
    final g = vccsDoc.components.firstWhere((c) => c.kind == CompKind.vccs);
    expect(g.params[0], closeTo(0.002, 1e-9));
    expect(formatComponentBadge(g), startsWith('G${g.id}'));
    expect(vccsDoc.toSpiceCir(), contains('G${g.id} '));

    for (final kind in [
      CompKind.switchSpdt,
      CompKind.xnorGate,
      CompKind.dFlipFlop,
      CompKind.logicProbe,
    ]) {
      final c = vccsDoc.addComponent(kind, 2, 2);
      expect(kCompMeta[kind]!.ffiType, greaterThan(0));
      expect(formatComponentBadge(c), isNotEmpty);
    }

    // Iteration 2: Logic Converter SOP synthesis compiles and simulates cleanly via SimFfi
    final sim = SimFfi();
    try {
      for (final (vars, expr) in [
        (2, "A'B + AB'"),
        (3, "A'BC + AB'C'"),
        (2, '0'),
        (2, '1'),
      ]) {
        vccsDoc.synthesizeLogicToCanvas(vars, expr);
        final (code, detail) = vccsDoc.syncToSim(sim);
        expect(code, 0, reason: 'Failed for $expr (detail=$detail)');
      }

      // Iteration 3: 555 Astable Blinker preset + new components + multi-select duplicate/delete
      final tDoc = CircuitDoc();
      tDoc.loadPreset(PresetKind.timer555Astable);
      expect(tDoc.syncToSim(sim), (0, 0));
      for (final kind in [
        CompKind.cccs,
        CompKind.ccvs,
        CompKind.transformer,
        CompKind.timer555,
        CompKind.sevenSeg,
      ]) {
        final c = tDoc.addComponent(kind, 2, 2);
        expect(kCompMeta[kind]!.ffiType, greaterThan(0));
        expect(formatComponentBadge(c), isNotEmpty);
      }

      final beforeComps = tDoc.components.length;
      final beforeWires = tDoc.wires.length;
      final pairIds = tDoc.components.take(2).map((c) => c.id).toSet();
      final dupIds = tDoc.duplicateComponents(pairIds);
      expect(dupIds.length, 2);
      expect(tDoc.components.length, beforeComps + 2);
      tDoc.deleteComponents(dupIds.toSet());
      expect(tDoc.components.length, beforeComps);
      expect(tDoc.wires.length, beforeWires);

      // Iteration 4: Relay + Pushbutton + Lamp simulation & BOM/CSV export
      final rDoc = CircuitDoc();
      final vCoil = rDoc.addComponent(CompKind.dcSource, 2, 4);
      final g1 = rDoc.addComponent(CompKind.ground, 2, 8);
      final pb = rDoc.addComponent(CompKind.pushbutton, 6, 2);
      final vLoad = rDoc.addComponent(CompKind.dcSource, 2, 12);
      rDoc.updateParam(vLoad.id, 0, 12.0);
      final relay = rDoc.addComponent(CompKind.relay, 10, 6);
      final lamp = rDoc.addComponent(CompKind.lamp, 14, 10);
      rDoc.wires.addAll([
        WireLink(PinRef(vCoil.id, 1), PinRef(g1.id, 0)),
        WireLink(PinRef(vLoad.id, 1), PinRef(g1.id, 0)),
        WireLink(PinRef(vCoil.id, 0), PinRef(pb.id, 0)),
        WireLink(PinRef(pb.id, 1), PinRef(relay.id, 0)),
        WireLink(PinRef(relay.id, 1), PinRef(g1.id, 0)),
        WireLink(PinRef(vLoad.id, 0), PinRef(relay.id, 2)),
        WireLink(PinRef(relay.id, 3), PinRef(lamp.id, 0)),
        WireLink(PinRef(lamp.id, 1), PinRef(g1.id, 0)),
      ]);
      expect(rDoc.syncToSim(sim), (0, 0));
      expect(sim.getComponentCurrent(lamp.id).abs(), lessThan(1e-4));

      // Press pushbutton -> relay closes -> lamp draws ~240 mA
      rDoc.updateParam(pb.id, 0, 1.0);
      expect(rDoc.syncToSim(sim), (0, 0));
      expect(sim.getComponentCurrent(lamp.id), closeTo(0.24, 0.01));

      final csv = rDoc.toBomCsv([0.0, 0.001], [0.0, 5.0], [0.0, 12.0]);
      expect(csv, contains('# Bill of Materials'));
      expect(csv, contains('relay'));
      expect(csv, contains('lamp'));
      expect(csv, contains('pushbutton'));
      expect(csv, contains('# Oscilloscope Samples'));

      // Iteration 5: 4-bit WordGen preset + metadata + wire bend waypoint
      final wgDoc = CircuitDoc();
      wgDoc.loadPreset(PresetKind.wordGenCounter);
      expect(wgDoc.syncToSim(sim), (0, 0));
      expect(kCompMeta[CompKind.wordGen]!.ffiType, 46);
      final wgComp = wgDoc.components.firstWhere((c) => c.kind == CompKind.wordGen);
      expect(formatComponentBadge(wgComp), isNotEmpty);
      wgDoc.moveWireBend(0, 8, recordUndo: true);
      expect(wgDoc.wires[0].bendX, 8);
      final wgRoundTrip = CircuitDoc();
      wgRoundTrip.loadJsonString(wgDoc.toJsonString());
      expect(wgRoundTrip.wires[0].bendX, 8);

      // Iteration 6: Optocoupler isolation preset & live CTR control
      final ocDoc = CircuitDoc();
      ocDoc.loadPreset(PresetKind.optocouplerIso);
      expect(ocDoc.syncToSim(sim), (0, 0));
      expect(kCompMeta[CompKind.optocoupler]!.ffiType, 47);
      final oc = ocDoc.components.firstWhere((c) => c.kind == CompKind.optocoupler);
      expect(formatComponentBadge(oc), startsWith('OC${oc.id}'));
      sim.setControl(oc.id, 0, 2.0);

      // Iteration 7: Schmitt Trigger + Binary Counter preset & component metadata
      final stDoc = CircuitDoc();
      stDoc.loadPreset(PresetKind.schmittCounter);
      expect(stDoc.syncToSim(sim), (0, 0));
      for (final kind in [CompKind.schmittTrigger, CompKind.counter4Bit]) {
        expect(kCompMeta[kind]!.ffiType, greaterThanOrEqualTo(48));
        final c = stDoc.components.firstWhere((e) => e.kind == kind);
        expect(formatComponentBadge(c), isNotEmpty);
      }

      // Phase 0: DC Current source, widened limits, WordGen 64-bit hex, and SPICE I round-trip
      expect(kCompMeta[CompKind.dcSource]!.paramSpecs.first.max, greaterThanOrEqualTo(250));
      expect(kCompMeta[CompKind.resistor]!.paramSpecs.first.max, greaterThanOrEqualTo(1e8));
      expect(kCompMeta[CompKind.capacitor]!.paramSpecs.first.min, lessThanOrEqualTo(1e-12));

      final p0Doc = CircuitDoc();
      final iSrc = p0Doc.addComponent(CompKind.dcCurrent, 4, 4);
      final rLoad = p0Doc.addComponent(CompKind.resistor, 8, 4);
      final g0 = p0Doc.addComponent(CompKind.ground, 8, 8);
      p0Doc.wires.addAll([
        WireLink(PinRef(iSrc.id, 1), PinRef(rLoad.id, 0)),
        WireLink(PinRef(iSrc.id, 0), PinRef(g0.id, 0)),
        WireLink(PinRef(rLoad.id, 1), PinRef(g0.id, 0)),
      ]);
      expect(p0Doc.syncToSim(sim), (0, 0));
      final rNode = p0Doc.resolvedNodes[PinRef(rLoad.id, 0)]!;
      expect(sim.getNodeVoltage(rNode), closeTo(10.0, 1e-3));
      expect(p0Doc.toSpiceCir(), contains('I${iSrc.id} '));

      final wgP0 = p0Doc.addComponent(CompKind.wordGen, 14, 4);
      expect(p0Doc.updateWordGenHex(wgP0.id, 'A000000000000005'), isTrue);
      expect(p0Doc.components.last.hexPattern, 'A000000000000005');
      p0Doc.recordUndoSnapshot();
      p0Doc.updateParam(iSrc.id, 0, 0.05);
      expect(p0Doc.components.first.params[0], 0.05);
      p0Doc.undo();
      expect(p0Doc.components.first.params[0], 0.01);
    } finally {
      sim.dispose();
    }
  });

  testWidgets('Phase 0 UI shows Import, Export, and Flow controls', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const BenchOscApp());
    await tester.pump();

    expect(find.byTooltip('Import'), findsOneWidget);
    expect(find.byTooltip('Export'), findsOneWidget);
    expect(find.byTooltip('Toggle Buzzer Audio'), findsOneWidget);
    expect(find.text('Flow'), findsOneWidget);
  });

  test('Phase 2: NetPort, PowerRail, Inline Meters, Buzzer, and Subcircuit Macro simulation', () {
    final sim = SimFfi();
    try {
      final doc = CircuitDoc();
      final pwr = doc.addComponent(CompKind.powerRail, 2, 2);
      doc.updateParam(pwr.id, 0, 10.0);
      final npA = doc.addComponent(CompKind.netPort, 2, 4);
      final npB = doc.addComponent(CompKind.netPort, 8, 2);
      final r1 = doc.addComponent(CompKind.resistor, 10, 4);
      final r2 = doc.addComponent(CompKind.resistor, 14, 4);
      final gnd = doc.addComponent(CompKind.ground, 14, 8);
      final vm = doc.addComponent(CompKind.voltmeter, 14, 2);
      doc.wires.addAll([
        WireLink(PinRef(pwr.id, 0), PinRef(npA.id, 0)),
        WireLink(PinRef(npB.id, 0), PinRef(r1.id, 0)),
        WireLink(PinRef(r1.id, 1), PinRef(r2.id, 0)),
        WireLink(PinRef(r2.id, 1), PinRef(gnd.id, 0)),
        WireLink(PinRef(vm.id, 0), PinRef(r2.id, 0)),
        WireLink(PinRef(vm.id, 1), PinRef(gnd.id, 0)),
      ]);
      expect(doc.syncToSim(sim), (0, 0));
      final vMid = doc.resolvedNodes[PinRef(r2.id, 0)]!;
      expect(sim.getNodeVoltage(vMid), closeTo(5.0, 1e-3));

      // Package {r1, r2} into a Subcircuit IC block and re-simulate + JSON round-trip + SPICE .SUBCKT
      final sub = doc.createSubcircuitFromSelection({r1.id, r2.id}, 'DIV2');
      expect(sub, isNotNull);
      expect(doc.syncToSim(sim), (0, 0));
      final vmNode = doc.resolvedNodes[PinRef(vm.id, 0)]!;
      expect(sim.getNodeVoltage(vmNode), closeTo(5.0, 1e-3));
      final cir = doc.toSpiceCir();
      expect(cir, contains('.SUBCKT DIV2'));
      expect(cir, contains('R${r1.id} '));
      expect(cir, contains('DIV2'));

      // Round-trip .SUBCKT + X call via loadSpiceCir and verify undo restores subcircuits.
      final subRt = CircuitDoc();
      subRt.loadSpiceCir(cir);
      expect(subRt.subcircuits.containsKey('DIV2'), isTrue);
      expect(subRt.syncToSim(sim), (0, 0));

      // Editing after sync still re-resolves nets on toSpiceCir() export.
      final extraR = doc.addComponent(CompKind.resistor, 20, 4);
      doc.addWire(PinRef(extraR.id, 0), PinRef(vm.id, 0));
      final updatedCir = doc.toSpiceCir();
      final vmNet = doc.resolvedNodes[PinRef(vm.id, 0)]!;
      final rOther = doc.resolvedNodes[PinRef(extraR.id, 1)]!;
      expect(vmNet, greaterThan(0));
      expect(rOther, greaterThan(0));
      expect(updatedCir, contains('R${extraR.id} $vmNet $rOther '));

      // .SUBCKT with an unused middle (NC) port keeps header port order aligned.
      final ncDoc = CircuitDoc();
      ncDoc.loadSpiceCir(
        '.SUBCKT DIV_NC in1 nc out\nR1 in1 m 1k\nR2 m out 1k\n.ENDS DIV_NC\nV1 1 0 DC 10\nX1 1 99 0 DIV_NC\n.end',
      );
      final divNc = ncDoc.subcircuits['DIV_NC']!;
      expect(divNc.externalPins.length, 3);
      expect(divNc.pinLabels, ['in1', 'nc', 'out']);
      expect(ncDoc.syncToSim(sim), (0, 0));

      // Undo after loadSpiceCir restores subcircuits.
      doc.loadSpiceCir('V1 1 0 DC 5\nR1 1 0 1k\n.end');
      expect(doc.subcircuits, isEmpty);
      doc.undo();
      expect(doc.subcircuits.containsKey('DIV2'), isTrue);

      final doc2 = CircuitDoc();
      doc2.loadJsonString(doc.toJsonString());
      expect(doc2.subcircuits.containsKey('DIV2'), isTrue);
      expect(doc2.syncToSim(sim), (0, 0));

      // Loading a preset clears custom subcircuits from the previous schematic.
      doc.loadPreset(PresetKind.rcFilter);
      expect(doc.subcircuits, isEmpty);
    } finally {
      sim.dispose();
    }
  });

  test('Phase 1: SimRunnerIsolate, power/overload, Monte Carlo, and Transfer Function', () async {
    final doc = CircuitDoc();
    doc.loadPreset(PresetKind.rcFilter);
    final (specs, probes, nodes) = doc.buildIsolatePayload();

    final iso = SimRunnerIsolate();
    try {
      final snap0 = await iso.sync(comps: specs, probes: probes, nodeIds: nodes);
      expect(snap0.errCode, 0);
      final snap1 = await iso.step(0.002, maxSubsteps: 100);
      expect(snap1.tSim, greaterThan(0.001));
      expect(snap1.ch1, isNotEmpty);

      final sweep = await iso.acSweepTransfer(
        fStart: 10,
        fStop: 10000,
        ptsPerDecade: 10,
        acSourceId: specs.first.id,
        outNode: nodes.last,
      );
      expect(sweep, isNotNull);

      final mc = await iso.monteCarloEx(tol: 0.05, runs: 16, outNode: nodes.last);
      expect(mc, isNotNull);
    } finally {
      iso.dispose();
    }

    final sim = SimFfi();
    try {
      sim.addComponentEx(id: 1, type: 10, pins: [1, 0], params: [10.0]);
      sim.addComponentEx(id: 2, type: 1, pins: [1, 0], params: [100.0]); // 100 Ohm @ 10V = 1.0W > 0.5W
      expect(sim.solveDc(), 0);
      final (_, _, cp, over, _) = sim.readFrameState([1], [2]);
      expect(cp[2], closeTo(1.0, 1e-3));
      expect(over.contains(2), isTrue);
    } finally {
      sim.dispose();
    }
  });

  testWidgets('Phase 3: Upgraded instruments, Word Gen panel, and Spectrum Analyzer',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const BenchOscApp());
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byTooltip('Instruments (Ctrl+3)'));
    await tester.pump(const Duration(milliseconds: 50));

    // Oscilloscope Phase 3 controls: 4ch chips, coupling, Hold, Math, C1/C2
    expect(find.text('Hold'), findsOneWidget);
    expect(find.text('C1'), findsOneWidget);
    expect(find.text('C2'), findsOneWidget);
    await tester.tap(find.text('Hold'));
    await tester.pump(const Duration(milliseconds: 50));

    // Multimeter Pro: differential CH1-CH2, Ohmmeter, CH3/CH4 cards
    await tester.tap(find.text('Multimeter'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('V(CH1-CH2):'), findsOneWidget);
    expect(find.textContaining('Ω:'), findsOneWidget);

    // Logic Analyzer Pro: protocol selector + zoom + dual cursors
    await tester.tap(find.text('Logic Analyzer'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Proto:Off'), findsOneWidget);
    expect(find.text('C1'), findsOneWidget);
    expect(find.text('C2'), findsOneWidget);

    // Logic Converter: Boolean expression input + NAND toggle
    await tester.tap(find.text('Logic Converter'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(
      find.descendant(of: find.byType(LogicConverterView), matching: find.byType(TextField)),
      'A*B',
    );
    await tester.tap(find.text('Apply'));
    await tester.pump(const Duration(milliseconds: 50));
    await _pumpUntilFound(tester, find.text('Simplified SOP: AB'));
    expect(find.textContaining('AB'), findsWidgets);
    await tester.tap(find.text('SOP'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('NAND-only:'), findsOneWidget);

    // DC Sweep: Family & MC 5% buttons
    await tester.tap(find.text('DC Sweep'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('MC 5%'), findsOneWidget);
    await tester.tap(find.text('Family'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('MC 5%'));
    await tester.pump(const Duration(milliseconds: 50));

    // Word Gen tab: insert WordGen non-destructively & inspect step rows
    await tester.tap(find.text('Word Gen'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Add WordGen'), findsOneWidget);
    await tester.tap(find.text('Add WordGen'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('S0'), findsOneWidget);
    expect(find.text('0x0'), findsOneWidget);

    // Spectrum Analyzer tab
    await tester.tap(find.text('Spectrum'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Spectrum Analyzer'), findsOneWidget);
    expect(find.textContaining('dBV'), findsWidgets);

    // Phase 4 UI: Zoom 100%, Snap toggle, Note button, Pause -> Single Step, Help dialog
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('Snap 1x'), findsOneWidget);
    await tester.tap(find.byTooltip('Help & Shortcuts (?)'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Keyboard Shortcuts & Tips'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pump(const Duration(milliseconds: 50));
  });

  test('Phase 4: Single-source SPICE, named nets, flip/align/junction, WAV/SVG exports & A* router', () {
    final doc = CircuitDoc();
    doc.loadSpiceCir('V1 vcc gnd DC 5\nR1 vcc out 1k\nR2 out gnd 1k\n.end');
    final sim = SimFfi();
    try {
      expect(doc.syncToSim(sim), (0, 0));
      final rustCir = doc.toSpiceCir(sim: sim);
      expect(rustCir, contains('.end'));
      expect(rustCir, contains('R3 1 2 1000'));
      expect(rustCir, contains('R4 2 0 1000'));
    } finally {
      sim.dispose();
    }

    // Reject malformed JSON without mutating document
    expect(() => doc.loadJsonString('{"components":"bad"}'), throwsFormatException);

    // Flip, Align, Note, T-junction wire split
    final r1 = doc.components.firstWhere((c) => c.kind == CompKind.resistor);
    final p0Before = r1.pinGridPos(0);
    doc.flipComponent(r1.id);
    expect(doc.components.firstWhere((c) => c.id == r1.id).pinGridPos(0), isNot(p0Before));
    doc.addNote(6, 4, 'Stage 1');
    expect(doc.notes.length, 1);

    // SVG & WAV export formatting
    final svg = exportSchematicSvg(doc);
    expect(svg, contains('<svg'));
    expect(svg, contains('Stage 1'));
    final wav = encodeWav16Pcm([0.0, 2.5, 5.0, -2.5]);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(wav.length, 44 + 8);

    // A* router detours around intermediate obstacle component
    final dRoute = CircuitDoc();
    final aComp = dRoute.addComponent(CompKind.resistor, 2, 5);
    final bComp = dRoute.addComponent(CompKind.resistor, 10, 5);
    dRoute.addComponent(CompKind.capacitor, 6, 5); // center obstacle on y=5
    final w = WireLink(PinRef(aComp.id, 1), PinRef(bComp.id, 0));
    final pts = routeWirePoints(
      dRoute,
      w,
      aComp.pinGridPos(1) * kGridStep,
      bComp.pinGridPos(0) * kGridStep,
    );
    expect(pts.any((p) => (p.dy - 5 * kGridStep).abs() >= kGridStep * 0.5), isTrue);
  });

  test('CircuitDoc JSON round-trips all presets, pads short params, and clamps nextId', () {
    final doc = CircuitDoc();
    for (final preset in PresetKind.values) {
      doc.loadPreset(preset);
      final json = doc.toJsonString();
      final restored = CircuitDoc()..loadJsonString(json);
      expect(restored.components.length, doc.components.length, reason: 'preset $preset');
      expect(restored.wires.length, doc.wires.length, reason: 'preset $preset');
    }

    doc.loadJsonString(
      '{"components":[{"id":42,"kind":"${CompKind.acSource.name}","x":2,"y":2,"params":[5.0]}],"wires":[]}',
    );
    expect(doc.components.single.params.length, 4);
    final added = doc.addComponent(CompKind.resistor, 4, 4);
    expect(added.id, greaterThan(42));
  });

  test('SimFfi handles long 6-variable minimizeLogic and >512-byte exportCir reallocation', () {
    final sim = SimFfi();
    addTearDown(sim.dispose);
    // 6-variable parity/checkerboard (32 uncombinable minterms) produces ~381-byte SOP string.
    final minimized = sim.minimizeLogicEx(
      6,
      [for (var i = 0; i < 64; i++) (0x6996966996696996 >> i) & 1],
    );
    expect(minimized.length, greaterThan(300));

    // >512-byte netlist forces _readUtf8Call to allocate and free a temporary native buffer.
    sim.addComponentEx(id: 1, type: 10, pins: [1, 0], params: [5.0]);
    for (var i = 1; i <= 45; i++) {
      sim.addComponentEx(id: i + 1, type: 1, pins: [1, 0], params: [1000.0]);
    }
    final longCir = sim.exportCir();
    expect(longCir.length, greaterThan(512));
    expect(longCir, endsWith('.end\n'));
  });

  test('SimRunnerIsolate.dispose completes cleanly', () {
    final iso = SimRunnerIsolate();
    iso.dispose();
  });

  testWidgets('SpectrumAnalyzerView renders 0Hz for DC-dominated bin-0 peak', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(extensions: const [CircuitColors.darkAmber]),
        home: Scaffold(
          body: SpectrumAnalyzerView(
            fftBins: Float64List.fromList([1.0, 0.0, 0.0, 0.0]),
            ch1Times: Float64List.fromList([0.0, 0.001, 0.002, 0.003]),
          ),
        ),
      ),
    );
    expect(find.textContaining('Peak: 0Hz'), findsOneWidget);
  });

  testWidgets('Audit regressions: drag undo, SPICE CH3/CH4 clear, subcircuit NetPort, measureWaveform',
      (tester) async {
    // 1. SPICE import clears stale CH3/CH4 and preserves them on invalid import rollback.
    final doc = CircuitDoc()..loadPreset(PresetKind.wordGenCounter);
    expect(doc.probeCh3, isNotNull);
    expect(doc.probeCh4, isNotNull);
    expect(() => doc.loadSpiceCir('not valid spice'), throwsFormatException);
    expect(doc.probeCh3, isNotNull);
    expect(doc.probeCh4, isNotNull);
    doc.loadSpiceCir('V1 1 0 DC 5\nR1 1 0 1k\n.end');
    expect(doc.probeCh3, isNull);
    expect(doc.probeCh4, isNull);

    // 2. Named NetPort inside a subcircuit connects matching labels.
    final subDoc = CircuitDoc();
    final r1 = subDoc.addComponent(CompKind.resistor, 4, 4);
    final np1 = subDoc.addComponent(CompKind.netPort, 10, 4);
    final npIdx1 = subDoc.components.indexWhere((e) => e.id == np1.id);
    subDoc.components[npIdx1] = subDoc.components[npIdx1].copyWith(hexPattern: 'RAIL');
    final np2 = subDoc.addComponent(CompKind.netPort, 16, 4);
    final npIdx2 = subDoc.components.indexWhere((e) => e.id == np2.id);
    subDoc.components[npIdx2] = subDoc.components[npIdx2].copyWith(hexPattern: 'RAIL');
    final r2 = subDoc.addComponent(CompKind.resistor, 20, 4);
    subDoc.addWire(PinRef(r1.id, 1), PinRef(np1.id, 0));
    subDoc.addWire(PinRef(np2.id, 0), PinRef(r2.id, 0));
    final def = subDoc.createSubcircuitFromSelection(
      {np1.id, np2.id, r2.id},
      'NET_SUB',
    );
    expect(def, isNotNull);
    subDoc.resolveNets();
    final vdd = subDoc.addComponent(CompKind.dcSource, 2, 10);
    final gnd = subDoc.addComponent(CompKind.ground, 2, 14);
    final subInst = subDoc.components.firstWhere((c) => c.kind == CompKind.subcircuit);
    subDoc.addWire(PinRef(vdd.id, 0), PinRef(r1.id, 0));
    subDoc.addWire(PinRef(vdd.id, 1), PinRef(gnd.id, 0));
    subDoc.addWire(PinRef(subInst.id, 1), PinRef(gnd.id, 0));
    final sim = SimFfi();
    addTearDown(sim.dispose);
    // Internal NetPort RAIL bridges r1->subInst->r2->gnd; if unmerged, node is floating.
    expect(subDoc.syncToSim(sim), (0, 0));

    // 3. Shared measureWaveform helper matches 100Hz sine.
    final t = Float64List.fromList([for (var i = 0; i <= 100; i++) i * 0.0002]);
    final v = Float64List.fromList([
      for (var i = 0; i <= 100; i++) 2.5 * (i % 50 < 25 ? 1.0 : -1.0),
    ]);
    final (vpp, freq) = measureWaveform(v, t);
    expect(vpp, closeTo(5.0, 1e-6));
    expect(freq, closeTo(100.0, 5.0));

    // 4. SchematicCanvas drag captures pre-drag state so undo restores original position.
    final dragDoc = CircuitDoc()..loadPreset(PresetKind.rcFilter);
    final compId = dragDoc.components.first.id;
    final origX = dragDoc.components.first.gridX;
    final origY = dragDoc.components.first.gridY;
    dragDoc.resolveNets();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(extensions: const [CircuitColors.darkAmber]),
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: StatefulBuilder(
              builder: (ctx, setS) => SchematicCanvas(
                doc: dragDoc,
                tool: CanvasTool.select,
                placingKind: null,
                selectedCompId: compId,
                pendingWirePin: null,
                nodeVoltages: const {},
                compCurrents: const {},
                animPhase: 0,
                onSelectComponent: (_) {},
                onPlaceAtGrid: (_) {},
                onTapPin: (_) {},
                onDragStart: dragDoc.recordUndoSnapshot,
                onMoveComponent: (id, gx, gy, finish) {
                  if (!finish) dragDoc.moveComponent(id, gx, gy);
                  setS(() {});
                },
                onToggleSwitch: (_) {},
                onDeleteComponent: (_) {},
                onDeleteWire: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    final startPos = Offset(20 + origX * kGridStep, 20 + origY * kGridStep);
    await tester.dragFrom(startPos, const Offset(kGridStep * 2, 0));
    await tester.pump();
    final moved = dragDoc.components.firstWhere((c) => c.id == compId);
    expect(moved.gridX, greaterThan(origX));
    dragDoc.undo();
    final restored = dragDoc.components.firstWhere((c) => c.id == compId);
    expect(restored.gridX, origX);
    expect(restored.gridY, origY);

    // 5. Multi-select drag keeps selection intact instead of clearing selectedCompIds.
    final c2Id = dragDoc.components[1].id;
    var selectCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(extensions: const [CircuitColors.darkAmber]),
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: SchematicCanvas(
              doc: dragDoc,
              tool: CanvasTool.select,
              placingKind: null,
              selectedCompId: c2Id,
              selectedCompIds: {compId, c2Id},
              pendingWirePin: null,
              nodeVoltages: const {},
              compCurrents: const {},
              animPhase: 0,
              onSelectComponent: (_) => selectCalls++,
              onPlaceAtGrid: (_) {},
              onTapPin: (_) {},
              onMoveComponent: (_, _, _, _) {},
              onToggleSwitch: (_) {},
              onDeleteComponent: (_) {},
              onDeleteWire: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.dragFrom(
      Offset(20 + restored.gridX * kGridStep, 20 + restored.gridY * kGridStep),
      const Offset(kGridStep * 2, 0),
    );
    await tester.pump();
    expect(selectCalls, 0);

    // 6. DcSweepView displays Monte Carlo (min, max, mean, std) in the right slots.
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData.dark().copyWith(extensions: const [CircuitColors.darkAmber]),
        home: Scaffold(
          body: DcSweepView(
            sweepData: null,
            onRunSweep: (_, _) {},
            onRunMonteCarloEx: ({required tol, required runs, required gaussian}) async =>
                (4.75, 5.25, 5.00, 0.125, Float64List.fromList([4.8, 5.0, 5.2])),
          ),
        ),
      ),
    );
    await tester.tap(find.text('MC 5%'));
    await tester.pumpAndSettle();
    expect(find.text('MC: 4.75..5.25V (μ=5.00, σ=0.125)'), findsOneWidget);

    // 7. Dense AC sweep (>256 points) does not truncate before fStop.
    final acSim = SimFfi();
    addTearDown(acSim.dispose);
    acSim.addComponentEx(id: 1, type: 11, pins: [1, 0], params: [1.0, 1000.0, 0.0, 0.0]);
    acSim.addComponentEx(id: 2, type: 1, pins: [1, 2], params: [1000.0]);
    acSim.addComponentEx(id: 3, type: 3, pins: [2, 0], params: [1e-6, double.nan]);
    final denseAc = acSim.runAcSweepTransfer(
      fStart: 1.0,
      fStop: 1e6,
      ptsPerDecade: 60,
      acSourceId: 1,
      outNode: 2,
    );
    expect(denseAc, isNotNull);
    expect(denseAc!.freqs.length, greaterThan(300));
    expect(denseAc.freqs.last, closeTo(1e6, 1.0));

    // 8. Malformed probe field in JSON leaves existing document untouched.
    final beforeCount = dragDoc.components.length;
    expect(
      () => dragDoc.loadJsonString('{"components":[],"wires":[],"ch1":123}'),
      throwsA(isA<TypeError>()),
    );
    expect(dragDoc.components.length, beforeCount);

    // 9. Tier 1: 1M parses as 1e6 (not 1m=1e-3), 1pF formats cleanly, T-junction duplicate isolated, NetPort editable.
    expect(CircuitDoc.parseSpiceValue(formatEngValue(1e6)), closeTo(1e6, 1e-3));
    expect(CircuitDoc.parseSpiceValue('1M'), closeTo(1e6, 1e-3));
    expect(CircuitDoc.parseSpiceValue('1m'), closeTo(1e-3, 1e-9));
    expect(CircuitDoc.parseSpiceValue('4.7kOhm'), closeTo(4700.0, 1e-3));
    expect(CircuitDoc.parseSpiceValue(formatEngValue(1e-12)), closeTo(1e-12, 1e-15));
    expect(CircuitDoc.parseSpiceValue('10F'), closeTo(10.0, 1e-9));
    expect(CircuitDoc.parseSpiceValue('10f'), closeTo(1e-14, 1e-18));
    expect(CircuitDoc.parseSpiceValue('10fF'), closeTo(1e-14, 1e-18));
    expect(CircuitDoc.parseSpiceValue('10foo'), isNull);

    final tjDoc = CircuitDoc();
    final tjV = tjDoc.addComponent(CompKind.dcSource, 2, 2);
    final tjR = tjDoc.addComponent(CompKind.resistor, 8, 2);
    tjDoc.addWire(PinRef(tjV.id, 0), PinRef(tjR.id, 0));
    final jPin = tjDoc.splitWireAtGrid(0, 5, 2);
    expect(jPin, isNotNull);
    final dupIds = tjDoc.duplicateComponents({tjV.id, tjR.id, jPin!.compId});
    final dupJ = tjDoc.components.firstWhere((c) => dupIds.contains(c.id) && c.kind == CompKind.netPort);
    expect(dupJ.hexPattern, 'J${dupJ.id}');
    tjDoc.resolveNets();
    expect(tjDoc.resolvedNodes[PinRef(tjV.id, 0)], isNot(tjDoc.resolvedNodes[PinRef(dupIds[0], 0)]));

    final np = tjDoc.addComponent(CompKind.netPort, 12, 4);
    expect(tjDoc.updateNetPortLabel(np.id, ' vcc main '), isTrue);
    expect(tjDoc.components.firstWhere((c) => c.id == np.id).hexPattern, 'VCC_MAIN');
  });

  testWidgets('Tier 1 UI: Palette search text input is not hijacked by R/F/Space shortcuts', (tester) async {
    await tester.pumpWidget(const BenchOscApp());
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byTooltip('Components (Ctrl+1)'));
    await tester.pump();

    final searchField = find.widgetWithText(TextField, 'Filter components...');
    expect(searchField, findsOneWidget);
    await tester.tap(searchField);
    await tester.enterText(searchField, 'rf ');
    await tester.pump();
    expect(find.text('rf '), findsOneWidget);
  });

  testWidgets('Desktop drawers start hidden and toggle independently via AppBar and Ctrl+1/2/3',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const BenchOscApp());
    await tester.pump(const Duration(milliseconds: 50));

    // All three drawers start hidden
    expect(find.widgetWithText(TextField, 'Filter components...'), findsNothing);
    expect(find.textContaining('Tap a component'), findsNothing);
    expect(find.text('Oscilloscope'), findsNothing);

    // Toggle Properties only via Ctrl+2
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.textContaining('Tap a component'), findsOneWidget);
    expect(find.text('Oscilloscope'), findsNothing);

    // Toggle Components via Ctrl+1 and Instruments via Ctrl+3
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.widgetWithText(TextField, 'Filter components...'), findsOneWidget);
    expect(find.textContaining('Tap a component'), findsOneWidget);
    expect(find.text('Oscilloscope'), findsWidgets);

    // Close Properties via AppBar button leaving Instruments-only
    await tester.tap(find.byTooltip('Properties (Ctrl+2)'));
    await tester.pump();
    expect(find.textContaining('Tap a component'), findsNothing);
    expect(find.text('Oscilloscope'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Desktop narrow 720px paused AppBar has no overflow and I-V Curve opens Instruments',
      (tester) async {
    tester.view.physicalSize = const Size(720, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const BenchOscApp());
    await tester.pump(const Duration(milliseconds: 50));

    // Pause simulation so Single Step icon appears in narrow 720px desktop AppBar
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(find.byTooltip('Single Step'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Clicking I-V Curve on desktop opens Instruments drawer showing DC Sweep
    await tester.ensureVisible(find.text('I-V Curve'));
    await tester.tap(find.text('I-V Curve'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Run DC Sweep'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Tier 2B: Upgraded Virtual Instruments accuracy & decoders', (tester) async {
    // 1. Bode phase unwrapping + GM/PM/BW/Q
    final wrapped = Float64List.fromList([-90.0, -175.0, 175.0, 120.0]);
    final unwrapped = unwrapPhaseDeg(wrapped);
    expect(unwrapped[2], closeTo(-185.0, 1e-6));
    expect(unwrapped[3], closeTo(-240.0, 1e-6));

    final bpData = AcSweepData(
      Float64List.fromList([10, 100, 1000, 10000, 100000]),
      Float64List.fromList([-10, 0.0, 6.0, 0.0, -12.0]),
      Float64List.fromList([45, 0.0, -170.0, 170.0, 140.0]),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkAmber(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: BodePlotterView(sweepData: bpData, onRunSweep: () {}),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('GM:'), findsOneWidget);
    expect(find.textContaining('BW:'), findsOneWidget);
    expect(find.textContaining('Q:'), findsOneWidget);

    // 2. Oscilloscope Hold freezes DC readout & Vpp when props change
    final t1 = Float64List.fromList([0.0, 0.001, 0.002, 0.003]);
    final v1 = Float64List.fromList([0.0, 5.0, 0.0, 5.0]);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkAmber(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: OscilloscopeView(
            title: 'Scope',
            ch1Values: v1,
            ch2Values: v1,
            ch1Times: t1,
            fftBins: Float64List(8),
            ch1Dc: 2.50,
            ch2Dc: 2.50,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Hold'));
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkAmber(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: OscilloscopeView(
            title: 'Scope',
            ch1Values: Float64List.fromList([0, 0, 0, 0]),
            ch2Values: Float64List.fromList([0, 0, 0, 0]),
            ch1Times: t1,
            fftBins: Float64List(8),
            ch1Dc: 0.00,
            ch2Dc: 0.00,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('CH1: 2.50V'), findsOneWidget);

    // 3. Spectrum skips DC bin 0 when bin 4 has signal & uses >0 dBV Auto ceiling
    final acBins = Float64List(32);
    acBins[0] = 10.0; // Large DC offset
    acBins[4] = 5.0; // 5Vpk AC -> ~10.97 dBV RMS
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkAmber(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SpectrumAnalyzerView(fftBins: acBins),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Peak: Bin 4'), findsOneWidget);
    expect(find.textContaining('Scale: 20..'), findsOneWidget);

    // 4. Protocol decoders: I2C 7-bit addr + W + ACK + data, time-based UART, SPI Mode 0
    // I2C write 0x3C ('W') -> bits 0,1,1,1,1,0,0,0 -> 0x78
    final scl = <bool>[];
    final sda = <bool>[];
    void pushSample(bool c, bool d) {
      scl.add(c);
      sda.add(d);
    }
    pushSample(true, true); // Idle
    pushSample(true, false); // START
    for (final b in [false, true, true, true, true, false, false, false, false]) {
      // 8 bits (0x78 = 0x3C write) + ACK (0)
      pushSample(false, b);
      pushSample(true, b);
    }
    pushSample(false, false);
    pushSample(true, false); // hold low
    pushSample(true, true); // STOP
    final i2cText = decodeI2cProtocol(scl, sda);
    expect(i2cText, contains('S'));
    expect(i2cText, contains('0x3C(W)A'));
    expect(i2cText, contains('P'));

    // UART 0x55 @ 1000 baud (bit = 1ms): start(0), LSB-first 1,0,1,0,1,0,1,0, stop(1)
    final uartBits = <bool>[];
    final uartTimes = <double>[];
    final frame = [true, false, true, false, true, false, true, false, true, false, true];
    for (var f = 0; f < frame.length; f++) {
      uartBits.add(frame[f]);
      uartTimes.add(f * 0.001);
    }
    expect(decodeUartProtocol(uartBits, Float64List.fromList(uartTimes), baudHz: 1000), contains('0x55'));

    // 5. Logic Converter XOR, 3-state Don't-Care, POS, NAND non-destructive build
    final xorOuts = evalBooleanExprList('A ^ B', 2);
    expect(xorOuts, [0, 1, 1, 0]);
    final lcDoc = CircuitDoc();
    final origR = lcDoc.addComponent(CompKind.resistor, 2, 2);
    lcDoc.synthesizeLogicToCanvas(2, "A'B + AB'", nandOnly: true, clearCanvas: false);
    expect(lcDoc.components.any((c) => c.id == origR.id), isTrue);
    expect(lcDoc.components.any((c) => c.kind == CompKind.nandGate), isTrue);

    // 6. WordGen multi-unit + Multimeter 2-terminal callback
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkAmber(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: MultimeterView(
                  ch1Stats: const ChannelStats(0, 0, 0, 0),
                  ch2Stats: const ChannelStats(0, 0, 0, 0),
                  selectedCurrentAmps: 0.0,
                  ch1DcFallback: 5.0,
                  onMeasureTwoTerminal: (_, _, _) async => 470.0,
                ),
              ),
              Expanded(
                child: WordGenPanel(
                  wordGenId: 2,
                  wordGens: const [(2, 'WG2', 'FEDCBA9876543210', 50.0), (5, 'WG5', '0000000000000000', 100.0)],
                  onSelectWordGen: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('5.00V'), findsWidgets);
    expect(find.text('WG2'), findsOneWidget);
  });
}
