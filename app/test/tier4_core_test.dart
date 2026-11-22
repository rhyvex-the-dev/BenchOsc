import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_bench/canvas/wire_router.dart';
import 'package:open_bench/ffi/sim_ffi.dart';
import 'package:open_bench/ffi/sim_isolate.dart'
    show IsolateCompSpec, SimRunnerIsolate, computeThdFromFftBins;
import 'package:open_bench/instruments/bode_plotter_view.dart';
import 'package:open_bench/instruments/dc_sweep_view.dart';
import 'package:open_bench/instruments/logic_analyzer_view.dart';
import 'package:open_bench/instruments/logic_converter_view.dart';
import 'package:open_bench/instruments/oscilloscope_view.dart';
import 'package:open_bench/instruments/spectrum_analyzer_view.dart';
import 'package:open_bench/l10n/app_localizations.dart';
import 'package:open_bench/state/circuit_doc.dart';
import 'package:open_bench/state/circuit_exports.dart';
import 'package:open_bench/state/sim_controller.dart';
import 'package:open_bench/theme/circuit_theme.dart';

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
        varComps: const [(2, 1e-10), (3, 1e-10)],
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
      expect(cir, contains('Rmot2 1 0 4.5 * ke=0.75'));
      expect(cir, contains('K3 L3a L3b 0.42'));
    } finally {
      sim.dispose();
    }
  });
}
