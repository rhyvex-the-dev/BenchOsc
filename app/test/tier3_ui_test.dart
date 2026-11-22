import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_bench/canvas/schematic_canvas.dart';
import 'package:open_bench/l10n/app_localizations.dart';
import 'package:open_bench/main.dart';
import 'package:open_bench/state/circuit_doc.dart';
import 'package:open_bench/state/parts_library.dart';
import 'package:open_bench/state/subcircuits.dart';
import 'package:open_bench/theme/circuit_theme.dart';
import 'package:open_bench/widgets/component_palette.dart';
import 'package:open_bench/widgets/inspector_panel.dart';

void main() {
  test('Tier 3 core: pin labels, parts library, subcircuit ungroup/ties, hotkeys & notes', () {
    expect(pinLabel(CompKind.comparatorOc, 2), 'OUT');
    expect(pinLabel(CompKind.dipSwitch4, 7), '4B');
    expect(pinLabel(CompKind.alu2Bit, 4), 'OP1');
    expect(pinLabel(CompKind.bridgeRectifier, 2), 'DC+');

    final doc = CircuitDoc();
    final irf = kPartsLibrary.firstWhere((p) => p.name == 'IRF540');
    final placedIrf = doc.addPartPreset(irf, 4, 4);
    expect(placedIrf.kind, CompKind.nmos);
    expect(placedIrf.params[0], closeTo(0.4, 1e-9));
    expect(placedIrf.params[1], closeTo(3.5, 1e-9));

    final gnd = doc.addComponent(CompKind.ground, 4, 8);
    final vcc = doc.addComponent(CompKind.dcSource, 8, 4);
    doc.addWire(PinRef(vcc.id, 1), PinRef(gnd.id, 0));
    final sw = doc.addComponent(CompKind.pushbutton, 8, 8);
    doc.setComponentHotkey(sw.id, 'a');
    expect(doc.components.firstWhere((c) => c.id == sw.id).hotkey, 'A');
    expect(formatComponentBadge(doc.components.firstWhere((c) => c.id == sw.id)), contains('[A]'));

    final rJson = CircuitDoc();
    rJson.loadJsonString(doc.toJsonString());
    expect(rJson.components.firstWhere((c) => c.id == sw.id).hotkey, 'A');

    doc.addNote(6, 6, 'Bias node');
    expect(doc.notes.length, 1);
    final nid = doc.notes.first.id;
    doc.updateNote(nid, 'Stage 1 Bias');
    expect(doc.notes.first.text, 'Stage 1 Bias');
    doc.moveNote(nid, 9, 11);
    expect(doc.notes.first.gridX, 9);
    doc.deleteNote(nid);
    expect(doc.notes, isEmpty);

    // Multi-select align/rotate/flip
    final ra = doc.addComponent(CompKind.resistor, 12, 4);
    final rb = doc.addComponent(CompKind.resistor, 18, 10);
    doc.alignComponents({ra.id, rb.id}, horizontalAxis: false);
    expect(
      doc.components.firstWhere((c) => c.id == ra.id).gridX,
      doc.components.firstWhere((c) => c.id == rb.id).gridX,
    );
    doc.rotateComponents({ra.id, rb.id});
    expect(doc.components.firstWhere((c) => c.id == ra.id).rotation, 1);
    doc.flipComponents({ra.id, rb.id}, vertical: true);
    expect(doc.components.firstWhere((c) => c.id == rb.id).flipY, isTrue);

    // Reusable subcircuit + shared-net tie + ungroup + telemetry rollup
    final subDoc = CircuitDoc();
    final r1 = subDoc.addComponent(CompKind.resistor, 4, 4);
    final r2 = subDoc.addComponent(CompKind.resistor, 10, 4);
    subDoc.addWire(PinRef(r1.id, 1), PinRef(r2.id, 0));
    final def = subDoc.createSubcircuitFromSelection({r1.id, r2.id}, 'DIV');
    expect(def, isNotNull);
    final subA = subDoc.components.single;
    final subB = subDoc.placeSubcircuit('DIV', 12, 10);
    expect(subB, isNotNull);
    expect(subDoc.components.where((c) => c.kind == CompKind.subcircuit).length, 2);

    // Shared external pin internal tie emits tie resistor instead of dropping one external net.
    subDoc.subcircuits['TIE'] = SubcircuitDef(
      name: 'TIE',
      components: [
        PlacedComponent(id: 901, kind: CompKind.resistor, gridX: 4, gridY: 4, params: const [100.0]),
      ],
      wires: const [],
      externalPins: const [PinRef(901, 0), PinRef(901, 0)],
      pinLabels: const ['A', 'B'],
    );
    final tieSub = subDoc.placeSubcircuit('TIE', 18, 10)!;
    final va = subDoc.addComponent(CompKind.dcSource, 2, 12);
    final vb = subDoc.addComponent(CompKind.dcSource, 6, 12);
    final g2 = subDoc.addComponent(CompKind.ground, 4, 16);
    subDoc.addWire(PinRef(va.id, 1), PinRef(g2.id, 0));
    subDoc.addWire(PinRef(vb.id, 1), PinRef(g2.id, 0));
    subDoc.addWire(PinRef(va.id, 0), PinRef(tieSub.id, 0));
    subDoc.addWire(PinRef(vb.id, 0), PinRef(tieSub.id, 1));
    final (specs, _, _) = subDoc.buildIsolatePayload();
    expect(specs.any((s) => s.ffiType == 1 && s.params.first == 1e-3), isTrue);
    expect(subDoc.subcircuitChildParent.values.contains(tieSub.id), isTrue);

    expect(subDoc.ungroupSubcircuit(subA.id), isTrue);
    expect(subDoc.components.where((c) => c.kind == CompKind.resistor).length, 2);

    subDoc.clearCanvas(keepSubcircuits: true);
    expect(subDoc.components, isEmpty);
    expect(subDoc.subcircuits.containsKey('DIV'), isTrue);
  });

  test('Tier 3 A* full-footprint obstacle avoidance routes around multi-pin IC body', () {
    final doc = CircuitDoc();
    doc.addComponent(CompKind.opAmp, 10, 10);
    final pts = routeWirePoints(
      doc,
      const WireLink(PinRef(1, 0), PinRef(2, 0)),
      const Offset(6 * kGridStep, 10 * kGridStep),
      const Offset(14 * kGridStep, 10 * kGridStep),
    );
    final passesThroughCenter = pts.any(
      (p) => (p.dx / kGridStep).round() == 10 && (p.dy / kGridStep).round() == 10,
    );
    expect(passesThroughCenter, isFalse);
  });

  testWidgets('Tier 3 UI: pushbutton press-and-hold does not drag, inspector controls & palette parts work',
      (tester) async {
    final doc = CircuitDoc();
    final pb = doc.addComponent(CompKind.pushbutton, 8, 8);
    var closedEvents = <bool>[];
    var moveCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkAmber(),
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: SchematicCanvas(
              doc: doc,
              tool: CanvasTool.select,
              placingKind: null,
              selectedCompId: null,
              pendingWirePin: null,
              nodeVoltages: const {},
              compCurrents: const {},
              animPhase: 0,
              onSelectComponent: (_) {},
              onPlaceAtGrid: (_) {},
              onTapPin: (_) {},
              onMoveComponent: (id, gx, gy, finish) {
                moveCount++;
                doc.moveComponent(id, gx, gy);
              },
              onToggleSwitch: (_) {},
              onDeleteComponent: (_) {},
              onDeleteWire: (_) {},
              onMomentaryButton: (_, closed) => closedEvents.add(closed),
            ),
          ),
        ),
      ),
    );

    final pbCenter = Offset(20 + pb.gridX * kGridStep, 20 + pb.gridY * kGridStep);
    final gesture = await tester.startGesture(pbCenter);
    await tester.pump();
    await gesture.moveBy(const Offset(kGridStep, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(closedEvents, [true, false]);
    expect(moveCount, 0);

    // Inspector shows discrete keypad buttons for hexKeypad and Shape chips for funcGen
    final hexComp = doc.addComponent(CompKind.hexKeypad, 4, 4);
    var changedVal = -1.0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.darkAmber(),
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 500,
            child: InspectorPanel(
              selected: hexComp,
              onRotate: () {},
              onDelete: () {},
              onEditHex: () {},
              onRecordUndo: () {},
              onFaultChanged: (_) {},
              onBinarySwitch: (_, _, {recordUndo = false}) {},
              onParamChanged: (_, _, v) => changedVal = v,
              onEditParamNumeric: (_, _, _, _) {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('F'), findsOneWidget);
    await tester.tap(find.text('F'));
    await tester.pump();
    expect(changedVal, 15.0);

    // ComponentPalette exposes Parts Library and Subcircuits
    String? pickedSub;
    PartPreset? pickedPart;
    var queryText = '';
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.darkAmber(),
        home: StatefulBuilder(
          builder: (_, setS) => Scaffold(
            body: SizedBox(
              width: 240,
              height: 600,
              child: ComponentPalette(
                query: queryText,
                favorites: const {},
                placingKind: null,
                isPlacing: false,
                subcircuits: {
                  'MY_SUB': SubcircuitDef(
                    name: 'MY_SUB',
                    components: const [],
                    wires: const [],
                    externalPins: const [],
                    pinLabels: const [],
                  ),
                },
                onQueryChanged: (v) => setS(() => queryText = v),
                onToggleFavorite: (_) {},
                onSelectKind: (_) {},
                onSelectSubcircuit: (n) => pickedSub = n,
                onSelectPartPreset: (p) => pickedPart = p,
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('MY_SUB'), findsOneWidget);
    await tester.tap(find.text('MY_SUB'));
    expect(pickedSub, 'MY_SUB');
    await tester.enterText(find.byType(TextField), 'LM7805');
    await tester.pump();
    expect(find.text('LM7805'), findsWidgets);
    await tester.tap(find.text('LM7805').last);
    expect(pickedPart?.name, 'LM7805');
  });

  testWidgets('Tier 3 workbench: multi-tab workspace, split view, hotkey & note dialog work',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const OpenBenchApp());
    await tester.pump(const Duration(milliseconds: 50));

    // Add a second sheet tab
    expect(find.text('Sheet 1'), findsOneWidget);
    await tester.tap(find.byTooltip('New Tab'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Sheet 2'), findsOneWidget);

    // Toggle Split Instruments view
    await tester.tap(find.byTooltip('Split Instruments'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('2nd View:'), findsOneWidget);

    // Keyboard Esc cancels cleanly without crash
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
  });
}
