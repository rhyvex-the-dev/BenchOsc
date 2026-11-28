import 'dart:math' as math;
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:benchosc/canvas/schematic_canvas.dart';
import 'package:benchosc/ffi/sim_ffi.dart';
import 'package:benchosc/ffi/sim_isolate.dart'
    show IsolateCompSpec, SimRunnerIsolate, computeThdFromFftBins;
import 'package:benchosc/instruments/bode_plotter_view.dart';
import 'package:benchosc/instruments/dc_sweep_view.dart';
import 'package:benchosc/instruments/logic_analyzer_view.dart';
import 'package:benchosc/instruments/logic_converter_view.dart';
import 'package:benchosc/instruments/multimeter_view.dart';
import 'package:benchosc/instruments/oscilloscope_view.dart';
import 'package:benchosc/instruments/spectrum_analyzer_view.dart';
import 'package:benchosc/instruments/word_gen_panel.dart';
import 'package:benchosc/l10n/app_localizations.dart';
import 'package:benchosc/l10n/app_localizations_en.dart';
import 'package:benchosc/main.dart' show formatSimError;
import 'package:benchosc/state/circuit_doc.dart';
import 'package:benchosc/state/circuit_exports.dart';
import 'package:benchosc/state/sim_controller.dart';
import 'package:benchosc/state/workbench_session.dart';
import 'package:benchosc/theme/circuit_theme.dart';
import 'package:benchosc/widgets/inspector_panel.dart';
import 'package:benchosc/widgets/workbench_toolbar.dart';

Widget _wrapTestWidget(Widget child, {double width = 520, double height = 380}) {
  return MaterialApp(
    theme: AppTheme.darkAmber(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(
        child: SizedBox(width: width, height: height, child: child),
      ),
    ),
  );
}

void main() {
  test('SPICE suffix parsing, + continuation, .model round-trip & extended devices', () {
    expect(CircuitDoc.parseSpiceValue('1M'), closeTo(1e6, 1e-3));
    expect(CircuitDoc.parseSpiceValue('1m'), closeTo(1e-3, 1e-12));
    expect(CircuitDoc.parseSpiceValue('1meg'), closeTo(1e6, 1e-3));
    expect(CircuitDoc.parseSpiceValue('10F'), closeTo(10.0, 1e-12));
    expect(CircuitDoc.parseSpiceValue('10f'), closeTo(1e-14, 1e-22));
    expect(CircuitDoc.parseSpiceValue('4.7k'), closeTo(4700.0, 1e-6));
    expect(CircuitDoc.parseSpiceValue('100u'), closeTo(1e-4, 1e-12));
    expect(CircuitDoc.parseSpiceValue('22p'), closeTo(22e-12, 1e-20));
    expect(CircuitDoc.parseSpiceValue('1n'), closeTo(1e-9, 1e-18));
    expect(CircuitDoc.parseSpiceValue('2.2G'), closeTo(2.2e9, 1.0));

    final doc = CircuitDoc();
    doc.loadSpiceCir('''
* Tier 4 SPICE round-trip test
V1 vdd 0
+ DC 12
I1 0 n1 SIN(0 0.02 500)
D1 vdd n1 DZ68
D2 n1 0 DSTD
D3 n2 0 DSTD
Q1 vdd n1 n2 QN
M1 vdd n1 0 MN
J1 vdd n1 0 J1
J2 0 n1 n2 J2
Eop1 out 0 n1 n2 50000
R1 out 0 1k
.model DZ68 D(BV=6.8 IS=1e-13)
.model DSTD D(IS=1e-12 N=1.4)
.model QN NPN(BF=250 IS=2e-14)
.model MN NMOS(KP=0.2 VTO=3.5)
.model J1 NJF(BETA=2e-3 VTO=-1.5)
.model J2 PJF(BETA=1.5e-3 VTO=1.2)
.end
''');

    final v1 = doc.components.firstWhere((c) => c.kind == CompKind.dcSource);
    expect(v1.params[0], closeTo(12.0, 1e-9));

    final iac = doc.components.firstWhere((c) => c.kind == CompKind.acCurrent);
    expect(iac.params[0], closeTo(0.02, 1e-9));
    expect(iac.params[1], closeTo(500.0, 1e-6));

    final zener = doc.components.firstWhere((c) => c.kind == CompKind.zener);
    expect(zener.params[2], closeTo(6.8, 1e-9));

    final q = doc.components.firstWhere((c) => c.kind == CompKind.npnBjt);
    expect(q.params[1], closeTo(250.0, 1e-6));

    final m = doc.components.firstWhere((c) => c.kind == CompKind.nmos);
    expect(m.params[0], closeTo(0.2, 1e-9));
    expect(m.params[1], closeTo(3.5, 1e-9));

    final nj = doc.components.firstWhere((c) => c.kind == CompKind.njfet);
    expect(nj.params[0], closeTo(2e-3, 1e-9));
    expect(nj.params[1], closeTo(-1.5, 1e-9));

    expect(doc.components.any((c) => c.kind == CompKind.pjfet), isTrue);

    final op = doc.components.firstWhere((c) => c.kind == CompKind.opAmp);
    expect(op.params[0], closeTo(50000.0, 1e-3));

    final dartCir = doc.toSpiceCir();
    expect('.model DMOD'.allMatches(dartCir).length, 1);
    expect(dartCir, contains('.model DZ'));
    expect(dartCir, contains('.model QNPN'));
    expect(dartCir, contains('.model NMOS'));
    expect(dartCir, contains('.model NJF'));
    expect(dartCir, contains('.model PJF'));

    final sim = SimFfi();
    try {
      final (err, _) = doc.syncToSim(sim);
      expect(err, 0);
      final rustCir = doc.toSpiceCir(sim: sim);
      expect('.model DMOD'.allMatches(rustCir).length, 1);
      expect(rustCir, contains('.model QNPN'));
      expect(rustCir, contains('.model NJF'));
    } finally {
      sim.dispose();
    }
  });

  testWidgets('SVG & PNG exports render rotated/flipped real symbols and notes', (tester) async {
    final doc = CircuitDoc()..loadPreset(PresetKind.rectifier);
    final res = doc.components.firstWhere((c) => c.kind == CompKind.resistor);
    doc.rotateComponent(res.id);
    doc.flipComponent(res.id);
    doc.addNote(6, 3, 'Stage 1');

    final svg = exportSchematicSvg(doc);
    expect(svg, contains('<path'));
    expect(svg, contains('<circle'));
    expect(svg, contains('translate('));
    expect(svg, contains('rotate(90) scale(-1,1)'));
    expect(svg, contains('Stage 1'));

    final png = await tester.runAsync(() => renderSchematicPng(doc));
    expect(png, isNotNull);
    expect(png!.length, greaterThan(100));
    expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
  });

  testWidgets('BodePlotterView computes unwrapped phase, PM/GM, and avoids tight overflow',
      (tester) async {
    final unwrapped = unwrapPhaseDeg(Float64List.fromList([-90.0, -170.0, 170.0, 90.0]));
    expect(unwrapped[2], closeTo(-190.0, 1e-6));
    expect(unwrapped[3], closeTo(-270.0, 1e-6));

    // Synthetic curve: 0 dB at 100 Hz (phase -120° -> PM = +60°), -180° at 1 kHz (mag -6 dB -> GM = +6 dB).
    final sweep = AcSweepData(
      Float64List.fromList([10.0, 100.0, 1000.0, 10000.0]),
      Float64List.fromList([12.0, 0.0, -6.0, -24.0]),
      Float64List.fromList([-45.0, -120.0, 180.0, 120.0]),
    );

    for (final h in const [244.0, 140.0]) {
      await tester.pumpWidget(
        _wrapTestWidget(
          BodePlotterView(sweepData: sweep, onRunSweep: () {}),
          width: 309,
          height: h,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('PM: 60.0°'), findsOneWidget);
      expect(find.text('GM: 6.0dB'), findsOneWidget);
    }
  });

  testWidgets('OscilloscopeView supports Hold freeze, dual cursors, and FFT callback',
      (tester) async {
    const n = 200;
    final times = Float64List.fromList([for (var i = 0; i < n; i++) i * 2e-4]);
    Float64List makeWave(double amp) => Float64List.fromList([
          for (var i = 0; i < n; i++) amp * math.sin(2 * math.pi * 125.0 * times[i]),
        ]);

    bool? lastFftMode;
    Widget buildScope(Float64List ch1) => _wrapTestWidget(
          OscilloscopeView(
            title: 'Oscilloscope',
            ch1Values: ch1,
            ch2Values: Float64List(n),
            ch1Times: times,
            fftBins: Float64List(32),
            onFftModeChanged: (v) => lastFftMode = v,
          ),
          width: 560,
          height: 360,
        );

    await tester.pumpWidget(buildScope(makeWave(5.0)));
    expect(find.textContaining('CH1 Vpp: 10.00V'), findsOneWidget);

    // Activate Hold -> pumping larger 12Vpk signal keeps frozen 10.00Vpp.
    await tester.tap(find.text('Hold'));
    await tester.pump();
    await tester.pumpWidget(buildScope(makeWave(12.0)));
    expect(find.textContaining('CH1 Vpp: 10.00V'), findsOneWidget);

    // Unhold resumes live 24.00Vpp tracking.
    await tester.tap(find.text('Hold'));
    await tester.pump();
    expect(find.textContaining('CH1 Vpp: 24.00V'), findsOneWidget);

    // Place C1 and C2 cursors across the plot area (pump past kDoubleTapTimeout/kPressTimeout).
    final plotBox = tester.getRect(
      find.descendant(of: find.byType(OscilloscopeView), matching: find.byType(ClipRRect)),
    );
    await tester.ensureVisible(find.text('C1'));
    await tester.tap(find.text('C1'));
    await tester.pump();
    await tester.tapAt(Offset(plotBox.left + plotBox.width * 0.25, plotBox.center.dy));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.ensureVisible(find.text('C2'));
    await tester.tap(find.text('C2'));
    await tester.pump();
    await tester.tapAt(Offset(plotBox.left + plotBox.width * 0.65, plotBox.center.dy));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.textContaining('Δt='), findsOneWidget);
    expect(find.textContaining('ΔV='), findsOneWidget);

    // Toggle FFT Spectrum & back to Time.
    await tester.tap(find.text('FFT Spectrum'));
    await tester.pump();
    expect(lastFftMode, isTrue);
    await tester.tap(find.text('Time'));
    await tester.pump();
    expect(lastFftMode, isFalse);
  });

  testWidgets('SpectrumAnalyzer, DcSweep, and LogicConverter fit 309x140 split layout',
      (tester) async {
    int? switchedCh;
    final bins = Float64List.fromList([0.0, 2.0, 0.4, 0.2, 0.01, 0.01, 0.01, 0.01]);
    final times = Float64List.fromList([for (var i = 0; i < 16; i++) i * 0.001]);

    await tester.pumpWidget(
      _wrapTestWidget(
        SpectrumAnalyzerView(
          fftBins: bins,
          ch1Times: times,
          thdPercent: 22.36,
          activeCh: 0,
          onChannelChanged: (c) => switchedCh = c,
        ),
        width: 309,
        height: 140,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Peak:'), findsOneWidget);
    expect(find.textContaining('THD: 22.36%'), findsOneWidget);
    await tester.tap(find.text('CH1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CH2').last);
    await tester.pump();
    expect(switchedCh, 1);

    final dcData = DcSweepData(
      Float64List.fromList([0.0, 2.5, 5.0]),
      Float64List.fromList([0.0, 2.5, 5.0]),
      Float64List.fromList([0.0, 1.25, 2.5]),
    );
    await tester.pumpWidget(
      _wrapTestWidget(
        DcSweepView(
          sweepData: dcData,
          familyCurves: [('0.5x', dcData), ('1.0x', dcData)],
          onRunSweep: (_, _) {},
          onRunMonteCarloEx: ({required tol, required runs, required gaussian}) async =>
              (2.3, 2.7, 2.5, 0.08, Float64List.fromList([2.4, 2.5, 2.6])),
        ),
        width: 309,
        height: 140,
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('MC 5%'));
    await tester.tap(find.text('MC 5%'));
    await tester.pumpAndSettle();
    expect(find.textContaining('MC: 2.30..2.70V'), findsOneWidget);

    await tester.pumpWidget(
      _wrapTestWidget(
        const LogicConverterView(),
        width: 309,
        height: 140,
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('SOP'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('NAND-only:'), findsOneWidget);
  });

  testWidgets('LogicAnalyzer SPI, I2C, and UART decoders handle protocol streams', (tester) async {
    // 1. UART 8N1 0x55 (LSB first: 1,0,1,0,1,0,1,0) at 100 us per bit.
    final uartBits = <bool>[true, true, false, true, false, true, false, true, false, true, false, true, true];
    final uartTimes = Float64List.fromList([for (var i = 0; i < uartBits.length; i++) i * 1e-4]);
    expect(decodeUartProtocol(uartBits, uartTimes), 'UART: 0x55');

    // 2. SPI Mode 0 MSB-first 0xA5 (10100101).
    const spiByte = [1, 0, 1, 0, 0, 1, 0, 1];
    final sck = <bool>[];
    final mosi = <bool>[];
    for (final b in spiByte) {
      sck.add(false);
      mosi.add(b == 1);
      sck.add(true);
      mosi.add(b == 1);
    }
    expect(decodeSpiProtocol((ch) => ch == 0 ? sck : mosi, sck.length), 'SPI M0: 0xA5');

    // 3. I2C START + 7-bit addr 0x50 Write (0xA0) + ACK + STOP.
    final scl = <bool>[true, true];
    final sda = <bool>[true, false]; // START while SCL high
    const addrRw = [1, 0, 1, 0, 0, 0, 0, 0, 0]; // 0x50 W + ACK(0)
    for (final b in addrRw) {
      scl.add(false);
      sda.add(b == 1);
      scl.add(true);
      sda.add(b == 1);
    }
    scl.add(false);
    sda.add(false);
    scl.add(true);
    sda.add(false);
    scl.add(true);
    sda.add(true); // STOP while SCL high
    expect(decodeI2cProtocol(scl, sda), 'I2C: S 0x50(W)A P');

    // UI switch into UART mode decodes 0x55.
    await tester.pumpWidget(
      _wrapTestWidget(
        LogicAnalyzerView(
          ch1: Float64List.fromList([for (final b in uartBits) b ? 5.0 : 0.0]),
          ch2: Float64List(uartBits.length),
          ch3: Float64List(uartBits.length),
          ch4: Float64List(uartBits.length),
          times: uartTimes,
        ),
      ),
    );
    await tester.tap(find.text('Proto:Off'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('UART').last);
    await tester.pump();
    expect(find.text('UART: 0x55'), findsOneWidget);
  });

  test('SimController steps isolate, gates FFT calculation, and runs Bode sweep', () async {
    final doc = CircuitDoc()..loadPreset(PresetKind.rcFilter);
    final ctrl = SimController();
    try {
      await ctrl.syncCircuit(doc, logicNodes: const [], logicThreshold: 1.5);
      expect(ctrl.telemetry.value.errCode, 0);

      await ctrl.setScopeConfig(needFft: false);
      await ctrl.stepFrame(
        doc,
        dtSec: 0.016,
        simDt: 0.002,
        logicNodes: const [],
        logicThreshold: 1.5,
      );
      expect(ctrl.telemetry.value.tSim, greaterThan(0.0));
      expect(ctrl.telemetry.value.fft, isEmpty);

      await ctrl.setScopeConfig(needFft: true);
      await ctrl.stepFrame(
        doc,
        dtSec: 0.016,
        simDt: 0.002,
        logicNodes: const [],
        logicThreshold: 1.5,
      );
      expect(ctrl.telemetry.value.fft, isNotEmpty);

      await ctrl.runBodeSweep(doc, logicNodes: const [], logicThreshold: 1.5);
      expect(ctrl.telemetry.value.bodeData, isNotNull);
      expect(ctrl.telemetry.value.bodeData!.freqs, isNotEmpty);
    } finally {
      ctrl.dispose();
    }
  });

  test('Audit regressions: dialog filename, THD helper, A* coords, SPICE rollback/models, MC clamp & setControl',
      () async {
    // 1. Filename sanitization strips paths, control chars, and leading option dashes.
    expect(sanitizeDialogFilename('../../--evil\nname\x00.cir'), 'evilname.cir');
    expect(sanitizeDialogFilename('dir/--name.cir'), 'name.cir');
    expect(sanitizeDialogFilename('---'), 'circuit');

    // 2. computeThdFromFftBins matches expected harmonic RSS without redundant FFI FFT.
    expect(
      computeThdFromFftBins(Float64List.fromList([0.0, 0.0, 2.0, 0.0, 0.3, 0.0, 0.4, 0.0, 0.0])),
      closeTo(25.0, 1e-9),
    );
    expect(computeThdFromFftBins(Float64List.fromList([5.0, 0.0, 0.0, 0.0, 0.0])), 0.0);
    expect(computeThdFromFftBins(Float64List.fromList([0.0, 0.0, 2.0, 0.0, 0.0, 0.0])), 0.0);

    // 3. A* router handles deeply negative grid coordinates without sign bit-packing collisions.
    final negDoc = CircuitDoc();
    final nr1 = negDoc.addComponent(CompKind.resistor, -2000, -2000);
    final nr2 = negDoc.addComponent(CompKind.resistor, -1996, -1998);
    final wire = WireLink(PinRef(nr1.id, 1), PinRef(nr2.id, 0));
    final pts = routeWirePoints(
      negDoc,
      wire,
      Offset(nr1.pinGridPos(1).dx * kGridStep, nr1.pinGridPos(1).dy * kGridStep),
      Offset(nr2.pinGridPos(0).dx * kGridStep, nr2.pinGridPos(0).dy * kGridStep),
    );
    expect(pts.first, Offset(nr1.pinGridPos(1).dx * kGridStep, nr1.pinGridPos(1).dy * kGridStep));
    expect(pts.last, Offset(nr2.pinGridPos(0).dx * kGridStep, nr2.pinGridPos(0).dy * kGridStep));

    // 4. Malformed SPICE import restores doc.revision cleanly, and unparenthesized .model parses.
    final spDoc = CircuitDoc();
    final revBefore = spDoc.revision;
    expect(() => spDoc.loadSpiceCir('invalid line'), throwsFormatException);
    expect(spDoc.revision, revBefore);

    spDoc.loadSpiceCir(
      'D1 1 0 DPLAIN\nD2 1 0 D2MOD\n.model DPLAIN D IS=1e-12 BV=5.1\n.model D2MOD D(IS=1e-6 N=1.1)\nR1 1 0 1k\n.end',
    );
    final z = spDoc.components.firstWhere((c) => c.kind == CompKind.zener);
    expect(z.params[2], closeTo(5.1, 1e-9));
    final diffDioCir = spDoc.toSpiceCir();
    final spDoc2 = CircuitDoc()
      ..loadSpiceCir('D1 1 0 DA\nD2 1 0 DB\n.model DA D(IS=2.5e-9 N=1.75)\n.model DB D(IS=1e-6 N=1.1)\nR1 1 0 1k\n.end');
    final distinctCir = spDoc2.toSpiceCir();
    expect(distinctCir, contains('.model DMOD D(IS=2.5e-9 N=1.75)'));
    expect(distinctCir, contains('.model DMOD'));
    expect('.model '.allMatches(distinctCir).length, 2);
    expect(diffDioCir, contains('.model DZ'));

    // 5. Sub-nF Monte Carlo clamp (1e-15 floor) and DcMotor/CoupledInductor secondary setControl indices.
    final iso = SimRunnerIsolate();
    try {
      await iso.sync(
        comps: const [
          IsolateCompSpec(id: 1, ffiType: 10, nodes: [1, 0], params: [5.0]),
          IsolateCompSpec(id: 2, ffiType: 1, nodes: [1, 2], params: [1e-10]),
          IsolateCompSpec(id: 3, ffiType: 1, nodes: [2, 0], params: [1e-10]),
        ],
        probes: const [1, 2, -1, -1],
        nodeIds: const [1, 2],
      );
      final mc = await iso.monteCarloEx(
        tol: 0.05,
        runs: 20,
        outNode: 2,
        gaussian: false,
      );
      expect(mc, isNotNull);
      expect(mc!.$2 - mc.$1, greaterThan(0.05));
    } finally {
      iso.dispose();
    }

    final sim = SimFfi();
    try {
      sim.addComponentEx(id: 1, type: 10, pins: [1, 0], params: [5.0]);
      sim.addComponentEx(id: 2, type: 89, pins: [1, 0], params: [4.5, 0.2, 1e9]);
      sim.addComponentEx(id: 3, type: 85, pins: [1, 0, 2, 0], params: [1e-3, 2e-3, 0.8]);
      sim.addComponentEx(id: 4, type: 1, pins: [2, 0], params: [100.0]);
      expect(sim.setControl(2, 1, 0.75), 0);
      expect(sim.setControl(3, 2, 0.42), 0);
      final cir = sim.exportCir();
      expect(cir, contains('Rmot2 1 0 4.5 ; ke=0.75'));
      expect(cir, contains('K3 L3a L3b 0.42'));
    } finally {
      sim.dispose();
    }
  });

  test('Ponytail audit regressions: CSV/subcircuit/JSON/SPICE/UART/NaN/liveFfiParamIdx', () {
    // 1. Filename leading-whitespace + dash sanitization.
    expect(sanitizeDialogFilename('  --foo.cir'), 'foo.cir');

    // 2. Subcircuit name sanitization, probe remapping, and CSV RFC-4180 quoting.
    final gDoc = CircuitDoc();
    final r1 = gDoc.addComponent(CompKind.resistor, 0, 0);
    final r2 = gDoc.addComponent(CompKind.resistor, 4, 0);
    final gnd = gDoc.addComponent(CompKind.ground, 8, 0);
    gDoc.addWire(PinRef(r1.id, 1), PinRef(r2.id, 0));
    gDoc.addWire(PinRef(r2.id, 1), PinRef(gnd.id, 0));
    gDoc.probeCh2 = PinRef(r2.id, 1);
    final def = gDoc.createSubcircuitFromSelection({r1.id, r2.id}, 'AMP, 1');
    expect(def, isNotNull);
    expect(def!.name, 'AMP_1');
    expect(gDoc.probeCh2, isNotNull);
    expect(gDoc.probeCh2!.compId, isNot(r2.id));
    final csv = gDoc.toBomCsv(const [], const [], const []);
    expect(csv, contains('AMP_1'));

    // 3. J* user NetPort label preserved on duplicate while auto-junction J<id> is renumbered.
    final jDoc = CircuitDoc();
    final jtag = jDoc.addComponent(CompKind.netPort, 0, 0);
    jDoc.updateNetPortLabel(jtag.id, 'JTAG');
    final jAuto = jDoc.addComponent(CompKind.netPort, 2, 0);
    jDoc.updateNetPortLabel(jAuto.id, 'J${jAuto.id}');
    final dupIds = jDoc.duplicateComponents({jtag.id, jAuto.id});
    final dupTag = jDoc.components.firstWhere((c) => c.id == dupIds[0]);
    final dupAuto = jDoc.components.firstWhere((c) => c.id == dupIds[1]);
    expect(dupTag.hexPattern, 'JTAG');
    expect(dupAuto.hexPattern, 'J${dupAuto.id}');

    // 4. Malformed JSON rejects negative pinIdx & duplicate component IDs.
    expect(
      () => CircuitDoc().loadJsonString(
        '{"components":[{"id":1,"kind":"resistor","x":0,"y":0,"params":[100]}],'
        '"wires":[{"from":{"c":1,"p":-1},"to":{"c":1,"p":0}}]}',
      ),
      throwsFormatException,
    );
    expect(
      () => CircuitDoc().loadJsonString(
        '{"components":[{"id":1,"kind":"resistor","x":0,"y":0,"params":[100]},'
        '{"id":1,"kind":"resistor","x":2,"y":0,"params":[200]}],"wires":[]}',
      ),
      throwsFormatException,
    );

    // 5. SPICE import: PWL, MOSFET with W/L, I with DC+AC, nested .SUBCKT; export tiePairs & models.
    final sp = CircuitDoc()
      ..loadSpiceCir(
        '.SUBCKT INNER a b\nR1 a b 1k\nQ1 a b 0 QMOD\n.model QMOD NPN(IS=1e-14 BF=250)\n.ENDS INNER\n'
        '.SUBCKT OUTER a b\nX1 a b INNER\n.ENDS OUTER\n'
        'V1 1 0 PWL(0 0 1m 5 2m 5 3m 0)\n'
        'I1 2 0 DC 10m AC 1\n'
        'M1 3 2 0 0 PMOS1 W=10u L=1u\n'
        'Q2 3 2 0 QTOP\n.model QTOP NPN(IS=1e-14 BF=100)\n'
        'X2 1 3 OUTER\n.end',
      );
    final pwl = sp.components.firstWhere((c) => c.kind == CompKind.pwlSource);
    expect(pwl.params[2], closeTo(1e-3, 1e-9));
    expect(pwl.params[3], closeTo(5.0, 1e-9));
    final cur = sp.components.firstWhere((c) => c.kind == CompKind.dcCurrent);
    expect(cur.params[0], closeTo(0.01, 1e-9));
    expect(sp.components.any((c) => c.kind == CompKind.pmos), isTrue);
    expect(sp.subcircuits['OUTER']!.components.any((c) => c.subcircuitName == 'INNER'), isTrue);
    final exported = sp.toSpiceCir();
    expect(exported, contains('INNER_QNPN'));
    expect(exported, contains('QNPN'));

    // 6. NaN / Infinity safety in formatEngValue & measureWaveform.
    expect(formatEngValue(double.nan), '--');
    expect(formatEngValue(double.infinity), '--');
    final (vpp, freq) = measureWaveform([double.nan, 1.0, 3.0], [0.0, 0.5, 1.0]);
    expect(vpp, closeTo(2.0, 1e-9));
    expect(freq, isNull);

    // 7. UART decoder rejects truncated frame missing stop bit & recovers after glitch.
    final truncRx = [true, false, true, false, true, false, true, false, true, true];
    final truncT = Float64List.fromList([
      0.0,
      0.001,
      0.002,
      0.003,
      0.004,
      0.005,
      0.006,
      0.007,
      0.008,
      0.0096, // stops before 9.5*bit after tStart=0.001 (0.0105)
    ]);
    expect(decodeUartProtocol(truncRx, truncT, baudHz: 1000), 'UART: idle');
    final glitchAndValidRx = [
      true, false, true, true, // single-sample false glitch then back high
      false, // real start bit at t = 0.004
      true, false, true, false, true, false, true, false, // 0x55 LSB-first
      true, true, // stop bit covering t = 0.013..0.014
    ];
    final gvT = Float64List.fromList([
      0.0, 0.001, 0.0011, 0.003,
      0.004,
      0.005, 0.006, 0.007, 0.008, 0.009, 0.010, 0.011, 0.012,
      0.013, 0.014,
    ]);
    expect(decodeUartProtocol(glitchAndValidRx, gvT, baudHz: 1000), contains('0x55'));

    // 8. SimController.liveFfiParamIdx mapping.
    expect(SimController.liveFfiParamIdx(CompKind.potentiometer, 1), 0);
    expect(SimController.liveFfiParamIdx(CompKind.funcGen, 2), 0);
    expect(SimController.liveFfiParamIdx(CompKind.resistor, 0), 0);
    expect(SimController.liveFfiParamIdx(CompKind.resistor, 1), isNull);
  });

  testWidgets('Toolbar I-V Curve button and DcSweepView ivMode sync', (tester) async {
    var ivClicks = 0;
    await tester.pumpWidget(
      _wrapTestWidget(
        WorkbenchToolBar(
          tool: CanvasTool.select,
          showLabels: true,
          showNodeVoltages: false,
          showFlow: true,
          coarseGridSnap: false,
          canvasScale: 1.0,
          isPhone: false,
          canUndo: false,
          canRedo: false,
          selectionCount: 0,
          onSelectTool: (_) {},
          onToggleLabels: (_) {},
          onToggleNodeVoltages: (_) {},
          onToggleFlow: (_) {},
          onToggleCoarseSnap: (_) {},
          onFitView: () {},
          onZoomOut: () {},
          onZoomReset: () {},
          onZoomIn: () {},
          onAddNote: () {},
          onOpenIvCurve: () => ivClicks++,
          onUndo: () {},
          onRedo: () {},
          onImport: () {},
          onExport: () {},
          onShowHelp: () {},
          onDuplicate: () {},
          onAlignH: () {},
          onAlignV: () {},
          onMakeSubcircuit: () {},
          onRotate: () {},
          onFlipH: () {},
          onFlipV: () {},
        ),
        width: 1400,
        height: 80,
      ),
    );
    await tester.ensureVisible(find.text('I-V Curve'));
    await tester.tap(find.text('I-V Curve'));
    expect(ivClicks, 1);

    // DcSweepView initializes in I-V mode, reports toggle-off, and syncs back on parent update.
    bool? lastIvReported;
    var lastRunIv = false;
    Widget buildSweep(bool iv) => _wrapTestWidget(
          DcSweepView(
            sweepData: DcSweepData(
              Float64List.fromList([0.0, 5.0]),
              Float64List.fromList([0.0, 5.0]),
              Float64List.fromList([0.0, 0.005]),
            ),
            ivMode: iv,
            onIvModeChanged: (v) => lastIvReported = v,
            onRunSweep: (_, _) {},
            onRunSweepConfig: ({
              int? srcId,
              int? secSrcId,
              required double vStart,
              required double vStop,
              required int steps,
              required bool family,
              required bool ivCurve,
            }) =>
                lastRunIv = ivCurve,
          ),
        );

    await tester.pumpWidget(buildSweep(true));
    expect(find.text('I(A)'), findsOneWidget);

    await tester.tap(find.text('I-V'));
    await tester.pump();
    expect(lastIvReported, isFalse);
    expect(lastRunIv, isFalse);
    expect(find.text('CH2'), findsOneWidget);

    // Parent toggles ivMode false -> true (as toolbar button does after user turned I-V off).
    await tester.pumpWidget(buildSweep(false));
    await tester.pumpWidget(buildSweep(true));
    expect(find.text('I(A)'), findsOneWidget);
  });

  testWidgets('Unlisted hotkey is sanitized and InspectorPanel does not crash', (tester) async {
    final fromJson = PlacedComponent.fromJson({
      'id': 1,
      'kind': 'switchSpst',
      'x': 4,
      'y': 4,
      'hotkey': 'B',
    });
    expect(fromJson.hotkey, isNull);

    final forcedUnlisted = PlacedComponent(
      id: 2,
      kind: CompKind.potentiometer,
      gridX: 4,
      gridY: 4,
      params: const [2000.0, 0.5],
      hotkey: 'B',
    );
    await tester.pumpWidget(
      _wrapTestWidget(
        InspectorPanel(
          selected: forcedUnlisted,
          onRotate: () {},
          onDelete: () {},
          onEditHex: () {},
          onRecordUndo: () {},
          onHotkeyChanged: (_) {},
          onFaultChanged: (_) {},
          onBinarySwitch: (_, _, {bool recordUndo = false}) {},
          onParamChanged: (_, _, _) {},
          onEditParamNumeric: (_, _, _, _) {},
        ),
        width: 320,
        height: 420,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('None'), findsWidgets);
  });

  test('SimController clears stale logic probes when syncing empty logicNodes', () async {
    final ctrl = SimController();
    addTearDown(ctrl.dispose);

    final digital = CircuitDoc();
    final clk = digital.addComponent(CompKind.clock, 2, 2);
    final gnd1 = digital.addComponent(CompKind.ground, 2, 5);
    digital.addWire(PinRef(clk.id, 1), PinRef(gnd1.id, 0));
    digital.resolveNets();
    final clkNode = digital.resolvedNodes[PinRef(clk.id, 0)]!;

    await ctrl.syncCircuit(digital, logicNodes: [clkNode], logicThreshold: 1.5);
    await ctrl.stepFrame(
      digital,
      dtSec: 0.016,
      simDt: 0.001,
      logicNodes: [clkNode],
      logicThreshold: 1.5,
    );
    expect(ctrl.telemetry.value.logicMasks, isNotEmpty);

    final analog = CircuitDoc();
    final vdc = analog.addComponent(CompKind.dcSource, 2, 2);
    final r1 = analog.addComponent(CompKind.resistor, 6, 2);
    final gnd2 = analog.addComponent(CompKind.ground, 2, 5);
    analog.addWire(PinRef(vdc.id, 1), PinRef(gnd2.id, 0));
    analog.addWire(PinRef(vdc.id, 0), PinRef(r1.id, 0));
    analog.addWire(PinRef(r1.id, 1), PinRef(gnd2.id, 0));

    await ctrl.syncCircuit(analog, logicNodes: const [], logicThreshold: 1.5);
    await ctrl.stepFrame(
      analog,
      dtSec: 0.016,
      simDt: 0.001,
      logicNodes: const [],
      logicThreshold: 1.5,
    );
    expect(ctrl.telemetry.value.logicMasks, isEmpty);
  });

  test('WorkbenchSession preserves per-tab selection and copy/paste offsets', () {
    final session = WorkbenchSession();
    addTearDown(session.dispose);

    final r1 = session.doc.addComponent(CompKind.resistor, 4, 4);
    session.selectedCompId = r1.id;
    session.copySelection();
    final pasted = session.pasteClipboard();
    expect(pasted.length, 1);
    expect(session.doc.components.length, 2);
    expect(session.doc.components.last.gridX, 6);

    session.addNewTab();
    expect(session.tabs.length, 2);
    expect(session.activeTabIdx, 1);
    expect(session.selectedCompId, isNull);

    session.switchTab(0);
    expect(session.selectedCompId, pasted.single);
    session.closeTab(1);
    expect(session.tabs.length, 1);
  });

  testWidgets('Audit #2 regression: switch/DIP inspector, DMM 0V DC, LogicConverter, WordGen, SPICE', (tester) async {
    // 1 & 2. InspectorPanel renders switchSpst without Material assertion and DIP SW1 toggles bit 0.
    final sw = PlacedComponent(
      id: 10,
      kind: CompKind.switchSpst,
      gridX: 4,
      gridY: 4,
      params: const [0.0, 1e-3, 1e9],
    );
    await tester.pumpWidget(
      _wrapTestWidget(
        InspectorPanel(
          selected: sw,
          onRotate: () {},
          onDelete: () {},
          onEditHex: () {},
          onRecordUndo: () {},
          onFaultChanged: (_) {},
          onBinarySwitch: (_, _, {bool recordUndo = false}) {},
          onParamChanged: (_, _, _) {},
          onEditParamNumeric: (_, _, _, _) {},
        ),
        width: 320,
        height: 420,
      ),
    );
    expect(tester.takeException(), isNull);

    double? dipVal;
    final dip = PlacedComponent(
      id: 11,
      kind: CompKind.dipSwitch4,
      gridX: 4,
      gridY: 4,
      params: const [0.0, 1e-3, 1e9],
    );
    await tester.pumpWidget(
      _wrapTestWidget(
        InspectorPanel(
          selected: dip,
          onRotate: () {},
          onDelete: () {},
          onEditHex: () {},
          onRecordUndo: () {},
          onFaultChanged: (_) {},
          onBinarySwitch: (_, _, {bool recordUndo = false}) {},
          onParamChanged: (_, _, v) => dipVal = v,
          onEditParamNumeric: (_, _, _, _) {},
        ),
        width: 320,
        height: 420,
      ),
    );
    await tester.tap(find.text('SW1'));
    await tester.pump();
    expect(dipVal, 1.0);

    // 4. MultimeterView keeps 0.00V DC for symmetric AC waveforms instead of using instantaneous fallback.
    await tester.pumpWidget(
      _wrapTestWidget(
        const MultimeterView(
          ch1Stats: ChannelStats(0.0, 3.5, -5.0, 5.0),
          ch2Stats: ChannelStats(0.0, 0.0, 0.0, 0.0),
          selectedCurrentAmps: 0.0,
          ch1DcFallback: 4.2,
        ),
      ),
    );
    expect(find.textContaining('4.20'), findsNothing);
    expect(find.textContaining('0.000 V'), findsWidgets);

    // 5. LogicConverterView catches minimizer errors and computes offline truth table expressions.
    await tester.pumpWidget(
      _wrapTestWidget(
        LogicConverterView(
          onMinimizeAsync: (_, _) async => throw StateError('boom'),
        ),
        width: 340,
        height: 360,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Minimization failed'), findsOneWidget);

    await tester.pumpWidget(
      _wrapTestWidget(const LogicConverterView(), width: 340, height: 360),
    );
    await tester.tap(find.text('0').first);
    await tester.pump();
    expect(find.textContaining("A'B'"), findsWidgets);

    // 10. WordGenPanel pushes manual step immediately when entering Step mode.
    String? steppedHex;
    await tester.pumpWidget(
      _wrapTestWidget(
        WordGenPanel(
          wordGenId: 1,
          hexPattern: 'FEDCBA9876543215',
          onChangeHex: (_) {},
          onStepHex: (h) => steppedHex = h,
        ),
      ),
    );
    await tester.tap(find.text('Cycle'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Step').last);
    await tester.pumpAndSettle();
    expect(steppedHex, '5555555555555555');

    // 6. loadSpiceCir rejects non-positive R/C/L and sanitizes .SUBCKT names.
    final sp = CircuitDoc();
    expect(() => sp.loadSpiceCir('R1 1 0 -10\n.end'), throwsFormatException);
    sp.loadSpiceCir('V1 1 0 DC 5\nR1 1 0 -10\n.end');
    expect(sp.components.where((c) => c.kind == CompKind.resistor), isEmpty);
    sp.loadSpiceCir('.SUBCKT Bad!Name A B\nR1 A B 1k\n.ENDS\nX1 1 0 Bad!Name\nV1 1 0 DC 5\n.end');
    expect(sp.subcircuits.values.first.name, 'BadName');
  });

  testWidgets('Audit pass 3 regressions: error codes, decoder pins, SPICE subckt, tabs, instruments, MC pot',
      (tester) async {
    // 1. formatSimError maps codes 5..8 to SimErrorCode and emptyCircuit on code 7.
    final en = AppLocalizationsEn();
    expect(formatSimError(en, 5, 0), en.errInvalidParam);
    expect(formatSimError(en, 6, 0), en.errUnknownComponent);
    expect(formatSimError(en, 7, 0), en.errInvalidNetlist);
    expect(formatSimError(en, 7, 0, emptyCircuit: true), en.errEmptyCircuit);
    expect(formatSimError(en, 8, 0), en.errNullHandle);

    // 2. decoder2To4 UI pin labels match Rust's [A1, A0, EN, Y0..Y3] order.
    expect([pinLabel(CompKind.decoder2To4, 0), pinLabel(CompKind.decoder2To4, 1), pinLabel(CompKind.decoder2To4, 2)],
        ['A1', 'A0', 'EN']);
    final decSim = SimFfi();
    addTearDown(decSim.dispose);
    decSim.addComponentEx(id: 1, type: 10, pins: [3, 0], params: [5.0]); // EN = 5V
    decSim.addComponentEx(id: 2, type: 77, pins: [0, 0, 3, 4, 5, 6, 7], params: [5.0]); // A1=0, A0=0, EN=5V
    expect(decSim.solveDc(), 0);
    expect(decSim.getNodeVoltage(4), greaterThan(4.0));
    decSim.setControl(1, 0, 0.0); // EN = 0V
    expect(decSim.solveDc(), 0);
    expect(decSim.getNodeVoltage(4), lessThan(0.5));

    // 3. SPICE .SUBCKT with punctuation instantiates X subcircuit instead of dropping it.
    final sp = CircuitDoc();
    sp.loadSpiceCir('.SUBCKT MY.FILTER A B\nR1 A B 1k\n.ENDS\nX1 1 0 MY.FILTER\nV1 1 0 DC 5\n.end');
    expect(sp.components.where((c) => c.kind == CompKind.subcircuit).map((c) => c.subcircuitName), contains('MYFILTER'));

    // 4. isAutoJunctionComp distinguishes auto junctions from JTAG/J1_IN net ports.
    final j1 = PlacedComponent(id: 1, kind: CompKind.netPort, gridX: 0, gridY: 0, params: const [], hexPattern: 'J1');
    final jtag = PlacedComponent(id: 2, kind: CompKind.netPort, gridX: 0, gridY: 0, params: const [], hexPattern: 'JTAG');
    final j1In = PlacedComponent(id: 3, kind: CompKind.netPort, gridX: 0, gridY: 0, params: const [], hexPattern: 'J1_IN');
    expect(isAutoJunctionComp(j1), isTrue);
    expect(isAutoJunctionComp(jtag), isFalse);
    expect(isAutoJunctionComp(j1In), isFalse);

    // 5. Closing inactive sheet tab preserves active tab selection.
    final sess = WorkbenchSession();
    sess.addNewTab();
    final comp = sess.doc.addComponent(CompKind.resistor, 2, 2);
    sess.selectedCompId = comp.id;
    sess.selectedCompIds.add(comp.id);
    sess.closeTab(0);
    expect(sess.activeTabIdx, 0);
    expect(sess.selectedCompId, comp.id);
    expect(sess.selectedCompIds, contains(comp.id));

    // 6. DcSweepView & BodePlotterView clear stale source IDs when source is deleted.
    int? sweptSrc = 99;
    await tester.pumpWidget(_wrapTestWidget(DcSweepView(
      sweepData: null,
      sweepSources: const [(1, 'V1')],
      onRunSweep: (_, _) {},
      onRunSweepConfig: ({srcId, secSrcId, required vStart, required vStop, required steps, required family, required ivCurve}) {
        sweptSrc = srcId;
      },
    )));
    await tester.tap(find.text('Src:Auto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('V1').last);
    await tester.pumpAndSettle();
    expect(sweptSrc, 1);
    await tester.pumpWidget(_wrapTestWidget(DcSweepView(
      sweepData: null,
      sweepSources: const [(2, 'V2')],
      onRunSweep: (_, _) {},
      onRunSweepConfig: ({srcId, secSrcId, required vStart, required vStop, required steps, required family, required ivCurve}) {
        sweptSrc = srcId;
      },
    )));
    await tester.tap(find.text('Run DC Sweep'));
    await tester.pump();
    expect(sweptSrc, isNull);

    int? bodeSrc = 99;
    await tester.pumpWidget(_wrapTestWidget(BodePlotterView(
      sweepData: null,
      acSources: const [(1, 'AC1')],
      onRunSweep: () {},
      onRunSweepConfig: ({required fStart, required fStop, required ptsPerDecade, acSourceId, inNode = -1, outNode}) {
        bodeSrc = acSourceId;
      },
    )));
    await tester.tap(find.text('Src:Auto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AC1').last);
    await tester.pumpAndSettle();
    expect(bodeSrc, 1);
    await tester.pumpWidget(_wrapTestWidget(BodePlotterView(
      sweepData: null,
      acSources: const [(2, 'AC2')],
      onRunSweep: () {},
      onRunSweepConfig: ({required fStart, required fStop, required ptsPerDecade, acSourceId, inNode = -1, outNode}) {
        bodeSrc = acSourceId;
      },
    )));
    await tester.tap(find.text('Run AC Sweep'));
    await tester.pump();
    expect(bodeSrc, isNull);

    // 7. WordGenPanel preset chips stay in manual Step mode.
    String? steppedHex;
    await tester.pumpWidget(_wrapTestWidget(WordGenPanel(
      wordGenId: 1,
      hexPattern: 'FEDCBA9876543210',
      onChangeHex: (_) {},
      onStepHex: (h) => steppedHex = h,
    )));
    await tester.tap(find.text('Cycle'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Step').last);
    await tester.pumpAndSettle();
    steppedHex = null;
    await tester.tap(find.text('Alt'));
    await tester.pump();
    expect(steppedHex, '5555555555555555');

    // 8. Monte Carlo perturbs potentiometer r_total alongside resistor.
    await tester.runAsync(() async {
      final mcDoc = CircuitDoc();
      final v = mcDoc.addComponent(CompKind.dcSource, 0, 2);
      final pot = mcDoc.addComponent(CompKind.potentiometer, 4, 2);
      final r = mcDoc.addComponent(CompKind.resistor, 8, 2);
      final gnd = mcDoc.addComponent(CompKind.ground, 0, 6);
      mcDoc.wires.addAll([
        WireLink(PinRef(v.id, 0), PinRef(pot.id, 0)),
        WireLink(PinRef(pot.id, 1), PinRef(gnd.id, 0)),
        WireLink(PinRef(pot.id, 2), PinRef(r.id, 0)),
        WireLink(PinRef(r.id, 1), PinRef(gnd.id, 0)),
        WireLink(PinRef(v.id, 1), PinRef(gnd.id, 0)),
      ]);
      mcDoc.probeCh2 = PinRef(pot.id, 2);
      final mcCtrl = SimController();
      try {
        await mcCtrl.syncCircuit(mcDoc, logicNodes: const [], logicThreshold: 1.5);
        final res = await mcCtrl.runMonteCarloEx(
          mcDoc,
          logicNodes: const [],
          logicThreshold: 1.5,
          tol: 0.1,
          runs: 20,
          gaussian: false,
        );
        expect(res, isNotNull);
        expect(res!.$4, greaterThan(0.0));
      } finally {
        mcCtrl.dispose();
      }
    });
  });

  testWidgets('Audit pass 4 regressions: SPICE PWL/S/ammeter/phase, I-V fallback, Bode self-ratio, PowerRail sign',
      (tester) async {
    // 1. Short SPICE PWL pads remaining points with final value; SIN with phase imports as acSource; S switch imports.
    final sp = CircuitDoc();
    sp.loadSpiceCir('''
V1 1 0 PWL(0 0 10m 5)
V2 2 0 SIN(0 5 100 0 0 90)
S1 2 3 1 0 SW1
.model SW1 SW(VT=2.0 VH=0.5 RON=0.05 ROFF=1e8)
.end
''');
    final pwl = sp.components.firstWhere((c) => c.kind == CompKind.pwlSource);
    expect(pwl.params, [0.0, 0.0, 10e-3, 5.0, 10e-3, 5.0, 10e-3, 5.0]);
    final ac = sp.components.firstWhere((c) => c.kind == CompKind.acSource);
    expect(ac.params[2], 90.0);
    final sw = sp.components.firstWhere((c) => c.kind == CompKind.vControlledSwitch);
    expect(sw.params, [2.5, 1.5, 0.05, 1e8]);

    // 2. Ammeter in subcircuit schematic exports as resistor instead of comment.
    final amDoc = CircuitDoc();
    final r1 = amDoc.addComponent(CompKind.resistor, 2, 2);
    final r2 = amDoc.addComponent(CompKind.resistor, 6, 2);
    amDoc.wires.add(WireLink(PinRef(r1.id, 1), PinRef(r2.id, 0)));
    amDoc.createSubcircuitFromSelection({r1.id, r2.id}, 'PAIR');
    final am = amDoc.addComponent(CompKind.ammeter, 10, 2);
    expect(amDoc.toSpiceCir(), contains('R${am.id} '));

    // 3. Negative PowerRail badge omits leading '+'.
    final rail = PlacedComponent(id: 9, kind: CompKind.powerRail, gridX: 0, gridY: 0, params: const [-5.0]);
    expect(formatComponentBadge(rail), '-5V');

    // 4. I-V Curve with Ground selected falls back to srcId, and Bode same-node transfer returns 0 dB / 0 deg.
    await tester.runAsync(() async {
      final ivDoc = CircuitDoc();
      final v = ivDoc.addComponent(CompKind.dcSource, 0, 2);
      final acSrc = ivDoc.addComponent(CompKind.acSource, 4, 2);
      final r = ivDoc.addComponent(CompKind.resistor, 8, 2);
      final gnd = ivDoc.addComponent(CompKind.ground, 0, 6);
      ivDoc.wires.addAll([
        WireLink(PinRef(v.id, 0), PinRef(acSrc.id, 1)),
        WireLink(PinRef(acSrc.id, 0), PinRef(r.id, 0)),
        WireLink(PinRef(r.id, 1), PinRef(gnd.id, 0)),
        WireLink(PinRef(v.id, 1), PinRef(gnd.id, 0)),
      ]);
      ivDoc.probeCh1 = PinRef(v.id, 0);
      ivDoc.probeCh2 = PinRef(r.id, 0);
      final ctrl = SimController();
      try {
        await ctrl.runDcSweep(
          ivDoc,
          logicNodes: const [],
          logicThreshold: 1.5,
          vStart: 1.0,
          vStop: 5.0,
          steps: 5,
          ivCurve: true,
          selectedCompId: gnd.id,
        );
        expect(ctrl.telemetry.value.dcSweepData, isNotNull);
        expect(ctrl.telemetry.value.dcSweepData!.ch2.last.abs(), greaterThan(1e-4));

        final outNode = ivDoc.resolvedNodes[PinRef(r.id, 0)]!;
        await ctrl.runBodeSweep(
          ivDoc,
          logicNodes: const [],
          logicThreshold: 1.5,
          acSourceId: acSrc.id,
          inNode: outNode,
          outNodeOverride: outNode,
        );
        expect(ctrl.telemetry.value.bodeData, isNotNull);
        expect(ctrl.telemetry.value.bodeData!.magDb.every((m) => m == 0.0), isTrue);
        expect(ctrl.telemetry.value.bodeData!.phaseDeg.every((p) => p == 0.0), isTrue);
      } finally {
        ctrl.dispose();
      }
    });
  });

  test('exportSchematicSvg renders netPort, auto-junction, and powerRail without fallback IC boxes', () {
    final doc = CircuitDoc();
    final rail = doc.addComponent(CompKind.powerRail, 0, 0);
    rail.params[0] = -5.0;
    final port = doc.addComponent(CompKind.netPort, 4, 0);
    doc.components[doc.components.indexOf(port)] = port.copyWith(hexPattern: 'VCC');
    final junc = doc.addComponent(CompKind.netPort, 8, 0);
    doc.components[doc.components.indexOf(junc)] = junc.copyWith(hexPattern: 'J1');

    final svg = exportSchematicSvg(doc);
    expect(svg, contains('VCC'));
    expect(svg, contains('-5'));
    expect(svg, isNot(contains('>N${port.id}<')));
    expect(svg, isNot(contains('>N${junc.id}<')));
    expect(svg, isNot(contains('>P${rail.id}<')));
  });

  test('Phase 1: CompCategory has 9 EE groups and all CompKinds are mapped', () {
    expect(CompCategory.values.length, 9);
    for (final cat in CompCategory.values) {
      final hasMember = CompKind.values.any(
        (k) => k != CompKind.subcircuit && kCompMeta[k]!.category == cat,
      );
      expect(hasMember, isTrue, reason: '$cat has no components');
    }
    expect(kCompMeta[CompKind.clock]!.category, CompCategory.powerSources);
    expect(kCompMeta[CompKind.relay]!.category, CompCategory.switchesLoads);
    expect(kCompMeta[CompKind.led]!.category, CompCategory.diodesLeds);
    expect(kCompMeta[CompKind.npnBjt]!.category, CompCategory.transistors);
    expect(kCompMeta[CompKind.timer555]!.category, CompCategory.analogIcs);
    expect(kCompMeta[CompKind.schmittTrigger]!.category, CompCategory.logicGates);
    expect(kCompMeta[CompKind.alu2Bit]!.category, CompCategory.digitalIcs);
    expect(kCompMeta[CompKind.sevenSeg]!.category, CompCategory.metersIo);
  });

  test('SimFfi readFrameState buffer growth and Gaussian monteCarloDcEx work cleanly', () {
    final sim = SimFfi();
    try {
      sim.addComponentEx(id: 1, type: 10, pins: [1, 0], params: [10.0]);
      sim.addComponentEx(id: 2, type: 1, pins: [1, 2], params: [1000.0]);
      sim.addComponentEx(id: 3, type: 1, pins: [2, 0], params: [1000.0]);
      expect(sim.solveDc(), 0);

      final empty = sim.readFrameState(const [], const []);
      expect(empty.$1, isEmpty);
      expect(empty.$2, isEmpty);

      final small = sim.readFrameState(const [1], const [2]);
      expect(small.$1[1], closeTo(10.0, 1e-6));
      expect(small.$2[2]!.abs(), closeTo(0.005, 1e-6));

      final grown = sim.readFrameState(const [1, 2], const [1, 2, 3]);
      expect(grown.$1[2], closeTo(5.0, 1e-6));
      expect(grown.$3[3]!.abs(), closeTo(0.025, 1e-4));

      final mc = sim.monteCarloDcEx(tol: 0.05, runs: 30, outNode: 2, gaussian: true);
      expect(mc, isNotNull);
      expect(mc!.$5.length, 30);
      expect(mc.$1 <= mc.$3 && mc.$3 <= mc.$2, isTrue);
    } finally {
      sim.dispose();
    }
  });

  test('Audit 11 regressions: paused FFT update, Normal hold, PMOS VTO sign, buzzer/lamp overload, and setControl sync race', () async {
    // #3: PMOS SPICE import/export VTO sign.
    final pmosDoc = CircuitDoc()
      ..loadSpiceCir('.model IRF9540 PMOS(KP=5m VTO=-3.5 LAMBDA=0.02)\nM1 2 1 0 0 IRF9540\n.end');
    final pmos = pmosDoc.components.firstWhere((c) => c.kind == CompKind.pmos);
    expect(pmos.params[1], closeTo(3.5, 1e-9));
    expect(pmosDoc.toSpiceCir(), contains('VTO=-3.5'));

    // #1, #4, #9: SimController paused setScopeConfig, buzzer/lamp overload filter, setControl during sync.
    final doc = CircuitDoc();
    final gnd = doc.addComponent(CompKind.ground, 0, 20);
    final vdc = doc.addComponent(CompKind.dcSource, 0, 0)..params[0] = 5.0;
    final sw = doc.addComponent(CompKind.switchSpst, 10, 0)..params[0] = 0.0;
    final buz = doc.addComponent(CompKind.buzzer, 20, 0); // 32 ohm => 0.78W at 5V (healthy)
    final lamp = doc.addComponent(CompKind.lamp, 30, 0); // 50 ohm => 0.50W
    final hotR = doc.addComponent(CompKind.resistor, 40, 0)..params[0] = 10.0; // 2.5W => HOT
    void wirePins(PlacedComponent a, int pa, PlacedComponent b, int pb) {
      doc.addWire(PinRef(a.id, pa), PinRef(b.id, pb));
    }

    wirePins(vdc, 1, gnd, 0);
    wirePins(buz, 1, gnd, 0);
    wirePins(lamp, 1, gnd, 0);
    wirePins(hotR, 1, gnd, 0);
    wirePins(vdc, 0, sw, 0);
    wirePins(sw, 1, buz, 0);
    wirePins(sw, 1, lamp, 0);
    wirePins(sw, 1, hotR, 0);
    doc.probeCh1 = PinRef(sw.id, 1);
    doc.resolveNets();

    final ctrl = SimController();
    try {
      // #9: setControl right after syncCircuit must wait and apply rather than drop.
      final syncFuture = ctrl.syncCircuit(doc, logicNodes: const [], logicThreshold: 1.5);
      doc.updateParam(sw.id, 0, 1.0);
      await Future.wait([
        syncFuture,
        ctrl.setControl(doc, sw.id, 0, 1.0, solveDc: true),
      ]);
      // #4: 10 ohm resistor at 5V (2.5W) is overloaded, buzzer (0.78W) and lamp (0.5W) are not.
      expect(ctrl.telemetry.value.overloadedIds.contains(hotR.id), isTrue);
      expect(ctrl.telemetry.value.overloadedIds.contains(buz.id), isFalse);
      expect(ctrl.telemetry.value.overloadedIds.contains(lamp.id), isFalse);

      // #1: Paused setScopeConfig updates telemetry FFT without stepFrame.
      await ctrl.stepFrame(
        doc,
        dtSec: 0.016,
        simDt: 0.002,
        logicNodes: const [],
        logicThreshold: 1.5,
      );
      await ctrl.setScopeConfig(needFft: false);
      expect(ctrl.telemetry.value.fft, isEmpty);
      await ctrl.setScopeConfig(needFft: true);
      expect(ctrl.telemetry.value.fft, isNotEmpty);
    } finally {
      ctrl.dispose();
    }
  });

  testWidgets('OscilloscopeView Normal trigger mode holds last capture when untriggered', (tester) async {
    Widget buildScope(bool triggered, Float64List vals, Float64List times) => MaterialApp(
          theme: ThemeData.dark().copyWith(extensions: const [CircuitColors.darkAmber]),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: OscilloscopeView(
                title: 'Scope',
                ch1Values: vals,
                ch2Values: Float64List(vals.length),
                ch1Times: times,
                fftBins: Float64List(0),
                ch1Dc: 2.5,
                ch2Dc: 0.0,
                thdPercent: 0.0,
                triggered: triggered,
                onTriggerConfigChanged: (_, _, _, _) {},
              ),
            ),
          ),
        );

    final times = Float64List.fromList([0.0, 0.001, 0.002, 0.003]);
    final wave = Float64List.fromList([0.0, 3.0, 1.0, 2.0]);
    await tester.pumpWidget(buildScope(true, wave, times));
    await tester.pumpAndSettle();

    // Switch to Normal mode.
    await tester.tap(find.text('Auto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Normal').last);
    await tester.pumpAndSettle();

    // Deliver a triggered frame, then an untriggered empty frame.
    await tester.pumpWidget(buildScope(true, wave, times));
    await tester.pump();
    await tester.pumpWidget(buildScope(false, Float64List(0), Float64List(0)));
    await tester.pump();

    expect(find.textContaining('Vpp:'), findsOneWidget);
  });

  test('Ponytail audit regressions: SPICE V0/AC/;/K, multi-tab autosave/copy, FFT DC, probe undo, 8-var synth', () {
    // 1. SPICE negative supply (pin 0 = 0), bare AC, inline ';', and K coupled inductor.
    final sp = CircuitDoc();
    sp.loadSpiceCir('''
V1 0 vneg DC 5 ; negative rail
R1 vneg 0 1k
V2 2 0 5 AC 1
L1 3 0 10m
L2 4 0 20m
K1 L1 L2 0.9
.end
''');
    sp.resolveNets();
    final v1 = sp.components.firstWhere((c) => c.kind == CompKind.dcSource);
    expect(sp.resolvedNodes[PinRef(v1.id, 0)], 0);
    expect(sp.resolvedNodes[PinRef(v1.id, 1)], isNot(0));
    final v2 = sp.components.where((c) => c.kind == CompKind.dcSource).last;
    expect(v2.params[0], closeTo(5.0, 1e-9));
    final kComp = sp.components.firstWhere((c) => c.kind == CompKind.coupledInductor);
    expect(kComp.params, [0.01, 0.02, 0.9]);

    // 2. Multi-tab autosave v2 round-trip + legacy v1 fallback + cross-tab subcircuit copy/paste.
    final sess = WorkbenchSession();
    final rA = sess.doc.addComponent(CompKind.resistor, 4, 4);
    final rB = sess.doc.addComponent(CompKind.resistor, 8, 4);
    sess.doc.addWire(PinRef(rA.id, 1), PinRef(rB.id, 0));
    sess.doc.createSubcircuitFromSelection({rA.id, rB.id}, 'DIV');
    final subInst = sess.doc.components.firstWhere((c) => c.kind == CompKind.subcircuit);
    sess.selectedCompId = subInst.id;
    sess.copySelection();
    sess.addNewTab();
    expect(sess.pasteClipboard(), isNotEmpty);
    expect(sess.doc.subcircuits.containsKey('DIV'), isTrue);

    final v2Json = sess.toAutosaveJson();
    final restored = WorkbenchSession();
    restored.loadAutosaveJson(v2Json);
    expect(restored.tabs.length, 2);
    expect(restored.tabs[1].doc.subcircuits.containsKey('DIV'), isTrue);

    final legacyJson = sess.tabs[0].doc.toJsonString();
    restored.loadAutosaveJson(legacyJson);
    expect(restored.activeTab.title, 'Recovered');

    // 3. Overwriting subcircuit updates existing instance customPinCount.
    final d = CircuitDoc();
    final r1 = d.addComponent(CompKind.resistor, 0, 0);
    final r2 = d.addComponent(CompKind.resistor, 4, 0);
    final r3 = d.addComponent(CompKind.resistor, 12, 0);
    d.addWire(PinRef(r1.id, 1), PinRef(r2.id, 0));
    d.createSubcircuitFromSelection({r1.id, r2.id}, 'BLK');
    final inst = d.components.firstWhere((c) => c.kind == CompKind.subcircuit);
    expect(inst.customPinCount, 4);
    final r4 = d.addComponent(CompKind.resistor, 16, 0);
    final r5 = d.addComponent(CompKind.resistor, 20, 0);
    d.addWire(PinRef(r3.id, 0), PinRef(r4.id, 0));
    d.addWire(PinRef(r3.id, 1), PinRef(r5.id, 0));
    d.createSubcircuitFromSelection({r4.id, r5.id}, 'BLK');
    final updated = d.components.firstWhere((c) => c.id == inst.id);
    expect(updated.customPinCount, 2);

    // 4. FFT DC bin-0 is 0.0 dBV for 1.0 V DC, probe undo works, 8-var synth has distinct G/H clocks.
    expect(fftMagToRmsDbv(1.0, isDc: true), closeTo(0.0, 1e-6));
    expect(fftMagToRmsDbv(1.0), closeTo(-3.0103, 1e-3));

    final pDoc = CircuitDoc();
    final pr = pDoc.addComponent(CompKind.resistor, 0, 0);
    final rev0 = pDoc.revision;
    pDoc.setProbe(1, PinRef(pr.id, 0));
    expect(pDoc.revision, greaterThan(rev0));
    expect(pDoc.probeCh1, PinRef(pr.id, 0));
    pDoc.undo();
    expect(pDoc.probeCh1, isNull);

    final synthDoc = CircuitDoc();
    synthDoc.synthesizeLogicToCanvas(8, 'A & H');
    final freqs = synthDoc.components
        .where((c) => c.kind == CompKind.clock)
        .map((c) => c.params[0])
        .toList();
    expect(freqs.length, 8);
    expect(freqs[7], greaterThan(freqs[6]));
  });

  test('Ponytail audit2 regressions: K-card anchors, paused Spectrum, hotkey, >8 pin subckt, SPI/I2C/SVG', () async {
    // 1. SPICE K-card remaps nodeAnchor/wires when L1/L2 share nets with R1.
    final kDoc = CircuitDoc();
    kDoc.loadSpiceCir('V1 1 0 DC 5\nL1 1 0 10m\nL2 2 0 20m\nR1 2 0 1k\nK1 L1 L2 0.9\n.end');
    kDoc.resolveNets();
    final kComp = kDoc.components.firstWhere((c) => c.kind == CompKind.coupledInductor);
    final r1Comp = kDoc.components.firstWhere((c) => c.kind == CompKind.resistor);
    expect(kDoc.resolvedNodes[PinRef(kComp.id, 2)], kDoc.resolvedNodes[PinRef(r1Comp.id, 0)]);

    // 2. Paused SimController.setScopeConfig updates spectrumFft & fftDt.
    final sc = SimController();
    addTearDown(sc.dispose);
    final scDoc = CircuitDoc();
    final vg = scDoc.addComponent(CompKind.acSource, 0, 0)..params[0] = 5.0;
    final rg = scDoc.addComponent(CompKind.resistor, 4, 0)..params[0] = 1000.0;
    final gnd = scDoc.addComponent(CompKind.ground, 0, 4);
    scDoc.addWire(PinRef(vg.id, 0), PinRef(rg.id, 0));
    scDoc.addWire(PinRef(vg.id, 1), PinRef(gnd.id, 0));
    scDoc.addWire(PinRef(rg.id, 1), PinRef(gnd.id, 0));
    scDoc.probeCh1 = PinRef(vg.id, 0);
    scDoc.probeCh2 = PinRef(rg.id, 1);
    await sc.syncCircuit(scDoc, logicNodes: const [], logicThreshold: 1.5);
    await sc.stepFrame(scDoc, dtSec: 1 / 60, simDt: 0.02, logicNodes: const [], logicThreshold: 1.5);
    await sc.setScopeConfig(fftCh: 1, needFft: true);
    expect(sc.telemetry.value.fftDt, greaterThan(0.0));
    expect(sc.telemetry.value.spectrumFft, isNotEmpty);

    // 3. setComponentHotkey rejects keys outside kAllowedHotkeys; >8 pin subcircuit returns null without mutating.
    final hkDoc = CircuitDoc();
    final sw = hkDoc.addComponent(CompKind.switchSpst, 0, 0);
    hkDoc.setComponentHotkey(sw.id, 'X');
    expect(hkDoc.components.first.hotkey, isNull);
    hkDoc.setComponentHotkey(sw.id, 'A');
    expect(hkDoc.components.first.hotkey, 'A');

    final big = CircuitDoc();
    final comps = [for (var i = 0; i < 9; i++) big.addComponent(CompKind.resistor, i * 6, 0)];
    final ext = big.addComponent(CompKind.resistor, 0, 10);
    for (final c in comps) {
      big.addWire(PinRef(c.id, 0), PinRef(ext.id, 0));
    }
    final revBefore = big.revision;
    expect(big.createSubcircuitFromSelection({for (final c in comps) c.id}, 'TOO_BIG'), isNull);
    expect(big.revision, revBefore);

    // 4. Cross-tab paste undo removes extraSubcircuits and aligns customPinCount.
    final s1 = WorkbenchSession();
    final a1 = s1.doc.addComponent(CompKind.resistor, 0, 0);
    final a2 = s1.doc.addComponent(CompKind.resistor, 4, 0);
    s1.doc.addWire(PinRef(a1.id, 1), PinRef(a2.id, 0));
    s1.doc.createSubcircuitFromSelection({a1.id, a2.id}, 'SBLK');
    s1.selectedCompId = s1.doc.components.firstWhere((c) => c.kind == CompKind.subcircuit).id;
    s1.copySelection();
    s1.addNewTab();
    expect(s1.pasteClipboard(), isNotEmpty);
    expect(s1.doc.subcircuits.containsKey('SBLK'), isTrue);
    s1.doc.undo();
    expect(s1.doc.subcircuits.containsKey('SBLK'), isFalse);

    // 5. SVG exports real symbols for potentiometer, lamp, transformer, and newer parts; SPI Mode 1 & I2C Read/NACK decode.
    final svgDoc = CircuitDoc();
    svgDoc.addComponent(CompKind.potentiometer, 0, 0);
    svgDoc.addComponent(CompKind.lamp, 6, 0);
    svgDoc.addComponent(CompKind.transformer, 12, 0);
    svgDoc.addComponent(CompKind.bridgeRectifier, 18, 0);
    svgDoc.addComponent(CompKind.optocoupler, 24, 0);
    svgDoc.addComponent(CompKind.crystal, 30, 0);
    svgDoc.addComponent(CompKind.buzzer, 36, 0);
    svgDoc.addComponent(CompKind.dcMotor, 42, 0);
    svgDoc.addComponent(CompKind.ammeter, 48, 0);
    svgDoc.addComponent(CompKind.voltmeter, 54, 0);
    final svg = exportSchematicSvg(svgDoc);
    expect(svg, contains('<circle cx="0" cy="0" r="14"'));
    expect(svg, contains('>OC<'));
    expect(svg, contains('>BZ<'));
    expect(svg, contains('>M<'));
    expect(svg, contains('>A<'));
    expect(svg, contains('>V<'));
    expect(svg, contains('<polygon points="0,'));

    // SPI Mode 1 (CPOL=0, CPHA=1): sample on falling clock edge. MSB 0xA5 = 10100101.
    final spiClk = <bool>[];
    final spiMosi = <bool>[];
    final spiMiso = <bool>[];
    final spiCs = <bool>[];
    const byteVal = 0xA5;
    for (var b = 7; b >= 0; b--) {
      final bit = ((byteVal >> b) & 1) == 1;
      spiClk.addAll([true, false]);
      spiMosi.addAll([bit, bit]);
      spiMiso.addAll([!bit, !bit]);
      spiCs.addAll([false, false]);
    }
    final spiOut = decodeSpiProtocol(
      (c) => switch (c) { 0 => spiClk, 1 => spiMosi, 2 => spiMiso, _ => spiCs },
      spiClk.length,
      mode: 1,
      hasMiso: true,
      hasCs: true,
    );
    expect(spiOut, contains('A5'));

    // I2C Read + NACK: START -> 7-bit addr 0x24 + R(1) + ACK(0) -> data 0x3C + NACK(1) -> STOP
    final scl = <bool>[];
    final sda = <bool>[];
    void bit(bool d) {
      scl.addAll([false, true, false]);
      sda.addAll([d, d, d]);
    }
    scl.addAll([true, true]);
    sda.addAll([true, false]); // START
    for (var b = 6; b >= 0; b--) {
      bit(((0x24 >> b) & 1) == 1);
    }
    bit(true); // R
    bit(false); // ACK
    for (var b = 7; b >= 0; b--) {
      bit(((0x3C >> b) & 1) == 1);
    }
    bit(true); // NACK
    scl.addAll([false, true, true]);
    sda.addAll([false, false, true]); // STOP
    expect(decodeI2cProtocol(scl, sda), contains('0x24(R)'));

    // 6. SimController.extractTruthTable on a 2-input AND gate + Dart SPICE fallback parity.
    final ttDoc = CircuitDoc();
    final gndTt = ttDoc.addComponent(CompKind.ground, 0, 14);
    final inA = ttDoc.addComponent(CompKind.dcSource, 0, 0);
    final inB = ttDoc.addComponent(CompKind.dcSource, 0, 8);
    final andG = ttDoc.addComponent(CompKind.andGate, 8, 4);
    final probe = ttDoc.addComponent(CompKind.logicProbe, 16, 4);
    ttDoc.addWire(PinRef(inA.id, 1), PinRef(gndTt.id, 0));
    ttDoc.addWire(PinRef(inB.id, 1), PinRef(gndTt.id, 0));
    ttDoc.addWire(PinRef(inA.id, 0), PinRef(andG.id, 0));
    ttDoc.addWire(PinRef(inB.id, 0), PinRef(andG.id, 1));
    ttDoc.addWire(PinRef(andG.id, 2), PinRef(probe.id, 0));
    final ttCtrl = SimController();
    final tt = await ttCtrl.extractTruthTable(ttDoc);
    expect(tt, isNotNull);
    expect(tt!.$1, 2);
    expect(tt.$2, const [0, 0, 0, 1]);
    ttCtrl.dispose();

    final sp3 = CircuitDoc();
    final fgSq = sp3.addComponent(CompKind.funcGen, 0, 0);
    sp3.updateParam(fgSq.id, 0, 1.0);
    sp3.updateParam(fgSq.id, 1, 5.0);
    sp3.updateParam(fgSq.id, 2, 1000.0);
    sp3.updateParam(fgSq.id, 3, 2.5);
    final fgDc = sp3.addComponent(CompKind.funcGen, 0, 6);
    sp3.updateParam(fgDc.id, 0, 1.0);
    sp3.updateParam(fgDc.id, 2, 0.0);
    sp3.updateParam(fgDc.id, 3, 1.25);
    final clkDc = sp3.addComponent(CompKind.clock, 0, 12);
    sp3.updateParam(clkDc.id, 0, 0.0);
    final brg = sp3.addComponent(CompKind.bridgeRectifier, 6, 0);
    final xtal = sp3.addComponent(CompKind.crystal, 6, 6);
    final mot = sp3.addComponent(CompKind.dcMotor, 6, 12);
    final cir3 = sp3.toSpiceCir();
    expect(cir3, contains('V${fgSq.id} '));
    expect(cir3, contains('PULSE(-2.5 7.5 0 1e-9 1e-9'));
    expect(cir3, contains('V${fgDc.id} '));
    expect(cir3, contains('DC 1.25'));
    expect(cir3, contains('Vclk${clkDc.id} '));
    expect(cir3, contains('D${brg.id}a '));
    expect(cir3, contains('.model DBRG '));
    expect(cir3, contains('Rm${xtal.id} '));
    expect(cir3, contains('C0_${xtal.id} '));
    expect(cir3, contains('Rmot${mot.id} '));

    // 7. Nested subcircuit rename on JSON import + .SUBCKT K-card SPICE round-trip.
    final nestedJson = jsonEncode({
      'version': 2,
      'nextId': 10,
      'subcircuits': {
        'my block!': {
          'name': 'my block!',
          'components': [
            {'id': 1, 'kind': 'resistor', 'x': 0, 'y': 0, 'rot': 0, 'params': [1000.0], 'fault': 'none'},
          ],
          'wires': [],
          'externalPins': [{'c': 1, 'p': 0}, {'c': 1, 'p': 1}],
          'pinLabels': ['P1', 'P2'],
        },
        'OUTER': {
          'name': 'OUTER',
          'components': [
            {'id': 2, 'kind': 'subcircuit', 'x': 0, 'y': 0, 'rot': 0, 'params': [], 'fault': 'none', 'sub': 'my block!', 'pins': 2},
          ],
          'wires': [],
          'externalPins': [{'c': 2, 'p': 0}, {'c': 2, 'p': 1}],
          'pinLabels': ['P1', 'P2'],
        },
      },
      'components': [
        {'id': 3, 'kind': 'ground', 'x': 0, 'y': 4, 'rot': 0, 'params': [], 'fault': 'none'},
        {'id': 4, 'kind': 'dcSource', 'x': 0, 'y': 0, 'rot': 0, 'params': [5.0], 'fault': 'none'},
        {'id': 5, 'kind': 'subcircuit', 'x': 4, 'y': 0, 'rot': 0, 'params': [], 'fault': 'none', 'sub': 'OUTER', 'pins': 2},
      ],
      'wires': [
        {'from': {'c': 4, 'p': 1}, 'to': {'c': 3, 'p': 0}},
        {'from': {'c': 4, 'p': 0}, 'to': {'c': 5, 'p': 0}},
        {'from': {'c': 5, 'p': 1}, 'to': {'c': 3, 'p': 0}},
      ],
    });
    final nestDoc = CircuitDoc()..loadJsonString(nestedJson);
    expect(nestDoc.subcircuits['OUTER']!.components.first.subcircuitName, 'my_block');
    final (nestSpecs, _, _) = nestDoc.buildIsolatePayload();
    expect(nestSpecs.any((s) => s.ffiType == 1), isTrue);

    final kSubDoc = CircuitDoc();
    final cpl = kSubDoc.addComponent(CompKind.coupledInductor, 4, 4);
    kSubDoc.updateParam(cpl.id, 0, 15e-3);
    kSubDoc.updateParam(cpl.id, 1, 25e-3);
    kSubDoc.updateParam(cpl.id, 2, 0.85);
    final rDummy = kSubDoc.addComponent(CompKind.resistor, 10, 4);
    kSubDoc.addWire(PinRef(cpl.id, 2), PinRef(rDummy.id, 0));
    kSubDoc.createSubcircuitFromSelection({cpl.id, rDummy.id}, 'XFMR_SUB');
    final exportedSubCir = kSubDoc.toSpiceCir();
    final reimported = CircuitDoc()..loadSpiceCir(exportedSubCir);
    final subComps = reimported.subcircuits['XFMR_SUB']!.components;
    expect(subComps.where((c) => c.kind == CompKind.inductor), isEmpty);
    final reCoupled = subComps.where((c) => c.kind == CompKind.coupledInductor).single;
    expect(reCoupled.params[0], closeTo(15e-3, 1e-6));
    expect(reCoupled.params[1], closeTo(25e-3, 1e-6));
    expect(reCoupled.params[2], closeTo(0.85, 1e-6));

    // 8. addWire rejects deleted component IDs; setScopeConfig waits for in-flight sync.
    final wDoc = CircuitDoc();
    final wr = wDoc.addComponent(CompKind.resistor, 0, 0);
    wDoc.addWire(PinRef(wr.id, 0), const PinRef(99999, 0));
    expect(wDoc.wires, isEmpty);

    final ctrl = SimController();
    addTearDown(ctrl.dispose);
    final syncFut = ctrl.syncCircuit(sp3, logicNodes: const [], logicThreshold: 2.5, fftCh: 0, needFft: false);
    await ctrl.setScopeConfig(needFft: true);
    await syncFut;
  });
}
