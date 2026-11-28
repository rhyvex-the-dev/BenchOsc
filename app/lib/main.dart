import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'audio/buzzer_audio.dart';
import 'canvas/schematic_canvas.dart';
import 'dialogs/workbench_dialogs.dart';
import 'instruments/bode_plotter_view.dart';
import 'instruments/dc_sweep_view.dart';
import 'instruments/logic_analyzer_view.dart';
import 'instruments/logic_converter_view.dart';
import 'instruments/multimeter_view.dart';
import 'instruments/oscilloscope_view.dart';
import 'instruments/spectrum_analyzer_view.dart';
import 'instruments/word_gen_panel.dart';
import 'l10n/app_localizations.dart';
import 'state/circuit_doc.dart';
import 'state/parts_library.dart';
import 'state/sim_controller.dart';
import 'state/workbench_session.dart';
import 'theme/circuit_theme.dart';
import 'widgets/component_palette.dart';
import 'widgets/inspector_panel.dart';
import 'widgets/workbench_toolbar.dart';

part 'workbench_actions.dart';
part 'workbench_instruments.dart';

String formatSimError(AppLocalizations l10n, int code, int detail, {bool emptyCircuit = false}) {
  return switch (code) {
    1 => l10n.errMissingGround,
    2 => l10n.errFloatingNode(detail),
    3 => l10n.errSingularMatrix,
    4 => l10n.errConvergenceFailed,
    5 => l10n.errInvalidParam,
    6 => l10n.errUnknownComponent,
    7 => emptyCircuit ? l10n.errEmptyCircuit : l10n.errInvalidNetlist,
    8 => l10n.errNullHandle,
    _ => l10n.errGeneric(code),
  };
}

void main() {
  runApp(const BenchOscApp());
}

class BenchOscApp extends StatefulWidget {
  const BenchOscApp({super.key});

  @override
  State<BenchOscApp> createState() => _BenchOscAppState();
}

class _BenchOscAppState extends State<BenchOscApp> {
  bool _isLight = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (ctx) => AppLocalizations.of(ctx)!.appTitle,
      debugShowCheckedModeBanner: false,
      theme: _isLight ? AppTheme.lightBench() : AppTheme.darkAmber(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: WorkbenchHome(
        isLightMode: _isLight,
        onToggleTheme: () => setState(() => _isLight = !_isLight),
      ),
    );
  }
}

class WorkbenchHome extends StatefulWidget {
  final bool isLightMode;
  final VoidCallback? onToggleTheme;

  const WorkbenchHome({
    super.key,
    this.isLightMode = false,
    this.onToggleTheme,
  });

  @override
  State<WorkbenchHome> createState() => _WorkbenchHomeState();
}

class _WorkbenchHomeState extends State<WorkbenchHome> with SingleTickerProviderStateMixin {
  final SimController _simCtrl = SimController();
  final BuzzerAudio _buzzer = BuzzerAudio();
  final WorkbenchSession _session = WorkbenchSession();
  late final Ticker _ticker;
  List<WorkspaceTab> get _tabs => _session.tabs;
  int get _activeTabIdx => _session.activeTabIdx;
  CircuitDoc get _doc => _session.doc;
  int? get _selectedCompId => _session.selectedCompId;
  set _selectedCompId(int? v) => _session.selectedCompId = v;
  Set<int> get _selectedCompIds => _session.selectedCompIds;
  List<(String title, String json)> get _recentCircuits => _session.recentCircuits;

  bool _running = true;
  bool _showLabels = true;
  bool _showNodeVoltages = false;
  bool _showFlow = true;
  bool _coarseGridSnap = false;
  double _timeScale = 0.25;
  CanvasTool _tool = CanvasTool.select;
  CompKind? _placingKind;
  String? _placingSubcircuitName;
  PartPreset? _placingPartPreset;
  final Set<int> _hotkeyHeldPushbuttons = {};
  final Map<PhysicalKeyboardKey, Set<int>> _hotkeyHeldByPhysical = {};
  PinRef? _pendingWirePin;
  int? _pendingSplitJunctionId;
  int? _pendingSplitRevision;

  int _activeInstTab = 0;
  int _secondaryInstTab = 1;
  bool _splitInstruments = false;
  bool _scopeInFftMode = false;
  bool _dcSweepIvMode = false;
  double _rightPanelWidth = 340.0;
  bool _showDesktopPalette = false;
  bool _showDesktopInspector = false;
  bool _showDesktopInstruments = false;
  bool _isPhoneLayout = false;
  int _phoneDrawerTab = -1; // -1 = collapsed canvas-first on phone
  String _paletteQuery = '';
  final Set<CompKind> _favorites = {};

  int _frameCount = 0;
  int _fitTrigger = 0;
  int _zoomInTrigger = 0;
  int _zoomOutTrigger = 0;
  int _zoomResetTrigger = 0;
  double _canvasScale = 1.0;
  Duration _lastFpsSample = Duration.zero;
  Duration _lastTick = Duration.zero;

  double _logicThresh = 1.5;
  int _spectrumCh = 0;
  int? _selectedWordGenId;

  @override
  void initState() {
    super.initState();
    _doc.loadPreset(PresetKind.rcFilter);
    _tabs[_activeTabIdx].savedRevision = _doc.revision;
    _syncCircuit(scheduleSave: false, rebuildUi: false);
    _ticker = createTicker(_onTick)..start();
  }

  bool _isInstVisible(int tabIdx) =>
      _activeInstTab == tabIdx || (_splitInstruments && _secondaryInstTab == tabIdx);

  bool get _needsFft {
    final instVisible = _isPhoneLayout ? _phoneDrawerTab == 2 : _showDesktopInstruments;
    return instVisible &&
        ((_isInstVisible(0) && _scopeInFftMode) || _isInstVisible(7) || _isInstVisible(1));
  }

  void _updateFftSubscription() {
    _simCtrl.setScopeConfig(fftCh: _spectrumCh, needFft: _needsFft);
  }

  void _refresh([VoidCallback? fn]) => setState(fn ?? () {});

  void _scheduleAutoSave() => _session.scheduleAutoSave();

  List<(int, String)> _cachedLogicNodes = const [];
  List<int> _cachedLogicNodeIds = const [];
  bool _logicNodesCached = false;

  List<(int nodeId, String label)> _scanLogicNodes() {
    final seen = <int>{};
    final out = <(int, String)>[];
    void addPin(PinRef? p, String tag) {
      if (p == null || out.length >= 16) return;
      final nid = _doc.resolvedNodes[p];
      if (nid != null && nid > 0 && seen.add(nid)) {
        out.add((nid, '$tag:N$nid'));
      }
    }

    addPin(_doc.probeCh1, 'CH1');
    addPin(_doc.probeCh2, 'CH2');
    addPin(_doc.probeCh3, 'CH3');
    addPin(_doc.probeCh4, 'CH4');
    for (final c in _doc.components) {
      if (out.length >= 16) break;
      if (c.kind == CompKind.logicProbe) {
        addPin(PinRef(c.id, 0), 'PR${c.id}');
      } else if (c.kind == CompKind.wordGen || c.kind == CompKind.counter4Bit || c.kind == CompKind.sevenSeg) {
        for (var k = 0; k < c.pinOffsets.length; k++) {
          addPin(PinRef(c.id, k), 'U${c.id}.$k');
        }
      }
    }
    return out;
  }

  List<(int nodeId, String label)> _collectLogicNodes() {
    if (!_logicNodesCached) {
      _cachedLogicNodes = _scanLogicNodes();
      _cachedLogicNodeIds = _cachedLogicNodes.map((e) => e.$1).toList();
      _logicNodesCached = true;
    }
    return _cachedLogicNodes;
  }

  List<int> _logicNodeIds() {
    if (!_logicNodesCached) {
      _collectLogicNodes();
    }
    return _cachedLogicNodeIds;
  }

  void _syncCircuit({bool scheduleSave = true, bool rebuildUi = true}) {
    if (scheduleSave && _tabs[_activeTabIdx].isDirty) {
      _scheduleAutoSave();
    }
    _session.pruneSelection();
    if (_pendingWirePin != null &&
        !_doc.components.any((c) => c.id == _pendingWirePin!.compId)) {
      _pendingWirePin = null;
    }
    if (_doc.probeCh3 == null && _doc.probeCh4 == null) {
      final busComp = _doc.components
          .where((c) => c.kind == CompKind.wordGen || c.kind == CompKind.sevenSeg)
          .firstOrNull;
      if (busComp != null) {
        _doc.probeCh3 = PinRef(busComp.id, 2);
        _doc.probeCh4 = PinRef(busComp.id, 3);
      }
    }
    _doc.resolveNets();
    _cachedLogicNodes = _scanLogicNodes();
    _cachedLogicNodeIds = _cachedLogicNodes.map((e) => e.$1).toList();
    _logicNodesCached = true;
    _simCtrl.syncCircuit(
      _doc,
      logicNodes: _logicNodeIds(),
      logicThreshold: _logicThresh,
      fftCh: _spectrumCh,
      needFft: _needsFft,
    );
    if (rebuildUi) setState(() {});
  }

  void _syncLogicProbes(double threshold) {
    _logicThresh = threshold;
    _simCtrl.setLogicProbes(_doc, _logicNodeIds(), threshold: threshold);
  }

  double _maxActiveFreq() {
    var maxF = 0.0;
    for (final c in _doc.components) {
      final f = switch (c.kind) {
        CompKind.acSource || CompKind.acCurrent => c.params.length > 1 ? c.params[1] : 0.0,
        CompKind.funcGen => c.params.length > 2 ? c.params[2] : 0.0,
        CompKind.clock || CompKind.wordGen || CompKind.vco =>
          c.params.isNotEmpty ? c.params[0] : 0.0,
        CompKind.pulseVoltage =>
          c.params.length > 6 && c.params[6] > 0 ? 1.0 / c.params[6] : 0.0,
        _ => 0.0,
      };
      if (f > maxF) maxF = f;
    }
    return maxF;
  }

  void _onTick(Duration elapsed) {
    if (_lastTick == Duration.zero) {
      _lastTick = elapsed;
      _lastFpsSample = elapsed;
      return;
    }
    final dtSec = ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.001, 0.05);
    _lastTick = elapsed;

    _frameCount++;
    final fpsWindow = elapsed - _lastFpsSample;
    if (fpsWindow.inMilliseconds >= 500) {
      final fps = (_frameCount * 1000 / fpsWindow.inMilliseconds).round();
      _frameCount = 0;
      _lastFpsSample = elapsed;
      _simCtrl.updateFps(fps);
    }

    if (_running) {
      final maxF = _maxActiveFreq();
      var frameSimDt = dtSec * _timeScale;
      if (maxF > 60.0) {
        frameSimDt = math.min(frameSimDt, 2.5 / maxF);
      }
      _simCtrl.stepFrame(
        _doc,
        dtSec: dtSec,
        simDt: frameSimDt,
        logicNodes: _logicNodeIds(),
        logicThreshold: _logicThresh,
        buzzer: _buzzer,
        playBuzzer: _running,
      );
    }
  }

  Future<void> _stepOnce() async {
    await _simCtrl.stepFrame(
      _doc,
      dtSec: 0.016,
      simDt: 0.001 * (_timeScale / 0.25),
      logicNodes: _logicNodeIds(),
      logicThreshold: _logicThresh,
      maxSubsteps: 120,
    );
  }

  void _recordRecent(String title) => _session.recordRecent(title);

  @override
  void dispose() {
    _session.dispose();
    _buzzer.dispose();
    _ticker.dispose();
    _simCtrl.dispose();
    super.dispose();
  }

  Set<int> get _effectiveSelection => _session.effectiveSelection;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).extension<CircuitColors>()!;
    final isPhone = MediaQuery.sizeOf(context).width < 720;
    final layoutChanged = _isPhoneLayout != isPhone;
    _isPhoneLayout = isPhone;
    if (layoutChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateFftSubscription();
      });
    }

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) => _handleGlobalKey(node, event, l10n),
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: IconButtonTheme(
            data: IconButtonThemeData(
              style: IconButton.styleFrom(
                padding: const EdgeInsets.all(4),
                minimumSize: const Size(28, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            child: AppBar(
              titleSpacing: 6,
              title: Text(l10n.appTitle, overflow: TextOverflow.ellipsis),
          actions: [
            _presetMenu(l10n, colors),
            IconButton(
              tooltip: l10n.buzzerAudioTooltip,
              icon: Icon(
                _buzzer.enabled ? Icons.volume_up : Icons.volume_off,
                size: 20,
                color: _buzzer.enabled ? colors.accentAmber : null,
              ),
              onPressed: () => setState(() => _buzzer.enabled = !_buzzer.enabled),
            ),
            IconButton(
              tooltip: l10n.themeToggleTooltip,
              icon: Icon(widget.isLightMode ? Icons.dark_mode : Icons.light_mode, size: 20),
              onPressed: widget.onToggleTheme,
            ),
            if (!isPhone) ...[
              IconButton(
                tooltip: '${l10n.componentsTab} (Ctrl+1)',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 36),
                icon: Icon(
                  Icons.grid_view,
                  size: 19,
                  color: _showDesktopPalette ? colors.accentAmber : null,
                ),
                onPressed: () => setState(() => _showDesktopPalette = !_showDesktopPalette),
              ),
              IconButton(
                tooltip: '${l10n.propertiesTitle} (Ctrl+2)',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 36),
                icon: Icon(
                  Icons.tune,
                  size: 19,
                  color: _showDesktopInspector ? colors.accentAmber : null,
                ),
                onPressed: () => setState(() => _showDesktopInspector = !_showDesktopInspector),
              ),
              IconButton(
                tooltip: '${l10n.instrumentsTab} (Ctrl+3)',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 36),
                icon: Icon(
                  Icons.show_chart,
                  size: 19,
                  color: _showDesktopInstruments ? colors.accentAmber : null,
                ),
                onPressed: () {
                  setState(() => _showDesktopInstruments = !_showDesktopInstruments);
                  _updateFftSubscription();
                },
              ),
              IconButton(
                tooltip: l10n.newCanvasAction,
                icon: const Icon(Icons.note_add_outlined, size: 20),
                onPressed: () async {
                  if (!await _confirmDiscardIfDirty(l10n) || !mounted) return;
                  _resetTabInteraction();
                  _doc.clearCanvas();
                  if (_activeTabIdx >= 0 && _activeTabIdx < _tabs.length) {
                    _tabs[_activeTabIdx].savedRevision = _doc.revision;
                  }
                  _selectedCompId = null;
                  _selectedCompIds.clear();
                  _syncCircuit(scheduleSave: false);
                },
              ),
              IconButton(
                tooltip: l10n.undoAction,
                icon: const Icon(Icons.undo, size: 20),
                onPressed: _doc.canUndo
                    ? () {
                        _pendingWirePin = null;
                        _pendingSplitJunctionId = null;
                        _pendingSplitRevision = null;
                        _doc.undo();
                        _syncCircuit();
                      }
                    : null,
              ),
              IconButton(
                tooltip: l10n.redoAction,
                icon: const Icon(Icons.redo, size: 20),
                onPressed: _doc.canRedo
                    ? () {
                        _pendingWirePin = null;
                        _pendingSplitJunctionId = null;
                        _pendingSplitRevision = null;
                        _doc.redo();
                        _syncCircuit();
                      }
                    : null,
              ),
              IconButton(
                tooltip: l10n.importAction,
                icon: const Icon(Icons.folder_open, size: 20),
                onPressed: () => _openIoDialog(l10n, importMode: true),
              ),
              IconButton(
                tooltip: l10n.exportAction,
                icon: const Icon(Icons.save_alt, size: 20),
                onPressed: () => _openIoDialog(l10n, importMode: false),
              ),
            ],
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: ValueListenableBuilder<SimTelemetry>(
                  valueListenable: _simCtrl.telemetry,
                  builder: (_, tel, _) => Text(
                    l10n.fpsLabel(tel.measuredFps),
                    style: TextStyle(color: colors.accentAmber, fontWeight: FontWeight.w600, fontSize: 12),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: _running ? l10n.pauseSimulation : l10n.runSimulation,
              icon: Icon(_running ? Icons.pause : Icons.play_arrow, color: colors.accentAmber),
              onPressed: () => setState(() => _running = !_running),
            ),
            if (!_running)
              IconButton(
                tooltip: l10n.singleStepAction,
                icon: Icon(Icons.skip_next, size: 20, color: colors.accentAmber),
                onPressed: _stepOnce,
              ),
            if (!isPhone) ...[
              DropdownButton<double>(
                value: _timeScale,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 0.05, child: Text('0.05x', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: 0.25, child: Text('0.25x', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: 1.0, child: Text('1.0x', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: 2.0, child: Text('2.0x', style: TextStyle(fontSize: 11))),
                ],
                onChanged: (s) {
                  if (s != null) setState(() => _timeScale = s);
                },
              ),
              IconButton(
                tooltip: l10n.helpShortcutsTooltip,
                icon: const Icon(Icons.help_outline, size: 19),
                onPressed: () => showWorkbenchHelpDialog(context, l10n),
              ),
            ],
            IconButton(
              tooltip: l10n.resetSimulation,
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: _syncCircuit,
            ),
          ],
        ),
        ),
        ),
        body: isPhone ? _buildPhoneBody(l10n, colors) : _buildDesktopBody(l10n, colors),
      ),
    );
  }

  Widget _paletteWidget() => ComponentPalette(
        query: _paletteQuery,
        favorites: _favorites,
        placingKind: _placingKind,
        placingSubcircuitName: _placingSubcircuitName,
        placingPartName: _placingPartPreset?.name,
        subcircuits: _doc.subcircuits,
        isPlacing: _tool == CanvasTool.place,
        onQueryChanged: (v) => setState(() => _paletteQuery = v),
        onToggleFavorite: (k) => setState(() {
          if (!_favorites.remove(k)) _favorites.add(k);
        }),
        onSelectKind: (k) => setState(() {
          _placingKind = k;
          _placingSubcircuitName = null;
          _placingPartPreset = null;
          _tool = CanvasTool.place;
          _phoneDrawerTab = -1;
        }),
        onSelectSubcircuit: (name) => setState(() {
          _placingKind = CompKind.subcircuit;
          _placingSubcircuitName = name;
          _placingPartPreset = null;
          _tool = CanvasTool.place;
          _phoneDrawerTab = -1;
        }),
        onSelectPartPreset: (part) => setState(() {
          _placingKind = part.kind;
          _placingPartPreset = part;
          _placingSubcircuitName = null;
          _tool = CanvasTool.place;
          _phoneDrawerTab = -1;
        }),
      );

  Widget _toolBarWidget(AppLocalizations l10n, {required bool isPhone}) => WorkbenchToolBar(
        tool: _tool,
        showLabels: _showLabels,
        showNodeVoltages: _showNodeVoltages,
        showFlow: _showFlow,
        coarseGridSnap: _coarseGridSnap,
        canvasScale: _canvasScale,
        isPhone: isPhone,
        canUndo: _doc.canUndo,
        canRedo: _doc.canRedo,
        selectionCount: _effectiveSelection.length,
        onSelectTool: (t) {
          if (t != CanvasTool.wire) _cancelPendingWire();
          setState(() => _tool = t);
        },
        onToggleLabels: (v) => setState(() => _showLabels = v),
        onToggleNodeVoltages: (v) => setState(() => _showNodeVoltages = v),
        onToggleFlow: (v) => setState(() => _showFlow = v),
        onToggleCoarseSnap: (v) => setState(() => _coarseGridSnap = v),
        onFitView: () => setState(() => _fitTrigger++),
        onZoomOut: () => setState(() => _zoomOutTrigger++),
        onZoomReset: () => setState(() => _zoomResetTrigger++),
        onZoomIn: () => setState(() => _zoomInTrigger++),
        onAddNote: () => showAddNoteDialog(context, l10n, _doc, () {
          _scheduleAutoSave();
          setState(() {});
        }),
        onOpenIvCurve: () => _openIvCurve(l10n, isPhone: isPhone),
        onUndo: () {
          _pendingWirePin = null;
          _pendingSplitJunctionId = null;
          _pendingSplitRevision = null;
          _doc.undo();
          _syncCircuit();
        },
        onRedo: () {
          _pendingWirePin = null;
          _pendingSplitJunctionId = null;
          _pendingSplitRevision = null;
          _doc.redo();
          _syncCircuit();
        },
        onImport: () => _openIoDialog(l10n, importMode: true),
        onExport: () => _openIoDialog(l10n, importMode: false),
        onShowHelp: () => showWorkbenchHelpDialog(context, l10n),
        onDuplicate: () => _duplicateIds(_effectiveSelection),
        onAlignH: () {
          _doc.alignComponents(_effectiveSelection, horizontalAxis: true);
          _syncCircuit();
        },
        onAlignV: () {
          _doc.alignComponents(_effectiveSelection, horizontalAxis: false);
          _syncCircuit();
        },
        onMakeSubcircuit: () => showCreateSubcircuitDialog(
          context,
          l10n,
          _doc,
          _effectiveSelection,
          (newCompId) {
            _selectedCompIds.clear();
            _selectedCompId = newCompId;
            _syncCircuit();
          },
        ),
        onRotate: () {
          _doc.rotateComponents(_effectiveSelection);
          _syncCircuit();
        },
        onFlipH: () {
          _doc.flipComponents(_effectiveSelection);
          _syncCircuit();
        },
        onFlipV: () {
          _doc.flipComponents(_effectiveSelection, vertical: true);
          _syncCircuit();
        },
      );

  Widget _tabStripWidget(AppLocalizations l10n) => WorkbenchTabStrip(
        tabs: [for (final t in _tabs) WorkspaceTabItem(title: t.title, isDirty: t.isDirty)],
        activeIndex: _activeTabIdx,
        onSwitchTab: _switchTab,
        onCloseTab: (idx) => _closeTab(idx, l10n),
        onAddTab: _addNewTab,
      );

  Widget _canvasArea(AppLocalizations l10n, CircuitColors colors) => ValueListenableBuilder<SimTelemetry>(
        valueListenable: _simCtrl.telemetry,
        builder: (_, tel, _) => Column(
          children: [
            if (tel.errCode != 0)
              Container(
                width: double.infinity,
                color: colors.dangerRed.withAlpha(40),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  formatSimError(l10n, tel.errCode, tel.errDetail, emptyCircuit: _doc.components.isEmpty),
                  style: TextStyle(color: colors.dangerRed, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            Expanded(child: _buildCanvas(l10n, tel)),
          ],
        ),
      );

  Widget _buildDesktopBody(AppLocalizations l10n, CircuitColors colors) {
    final showRight = _showDesktopInspector || _showDesktopInstruments;
    return Row(
      children: [
        if (_showDesktopPalette) SizedBox(width: 256, child: _paletteWidget()),
        Expanded(
          child: Column(
            children: [
              _toolBarWidget(l10n, isPhone: false),
              _tabStripWidget(l10n),
              Expanded(child: _canvasArea(l10n, colors)),
            ],
          ),
        ),
        if (showRight) ...[
          MouseRegion(
            cursor: SystemMouseCursors.resizeLeftRight,
            child: GestureDetector(
              onHorizontalDragUpdate: (d) {
                setState(() {
                  _rightPanelWidth = (_rightPanelWidth - d.delta.dx).clamp(260.0, 640.0);
                });
              },
              child: Container(width: 5, color: colors.panelBorder),
            ),
          ),
          SizedBox(
            width: _rightPanelWidth,
            child: _showDesktopInspector && _showDesktopInstruments
                ? Column(
                    children: [
                      SizedBox(height: 230, child: _buildInspector(l10n, colors)),
                      Expanded(child: _buildInstrumentRack(l10n, colors)),
                    ],
                  )
                : (_showDesktopInspector
                    ? _buildInspector(l10n, colors)
                    : _buildInstrumentRack(l10n, colors)),
          ),
        ],
      ],
    );
  }

  Widget _buildPhoneBody(AppLocalizations l10n, CircuitColors colors) {
    return Column(
      children: [
        _toolBarWidget(l10n, isPhone: true),
        if (_tabs.length > 1) _tabStripWidget(l10n),
        Expanded(child: _canvasArea(l10n, colors)),
        if (_phoneDrawerTab >= 0)
          SizedBox(
            height: 330,
            child: switch (_phoneDrawerTab) {
              0 => _paletteWidget(),
              1 => _buildInspector(l10n, colors),
              _ => _buildInstrumentRack(l10n, colors),
            },
          ),
        Container(
          color: colors.panelSurface,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              Expanded(child: _drawerBtn(0, Icons.grid_view, l10n.componentsTab, colors)),
              Expanded(child: _drawerBtn(1, Icons.tune, l10n.propertiesTitle, colors)),
              Expanded(child: _drawerBtn(2, Icons.show_chart, l10n.instrumentsTab, colors)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _drawerBtn(int idx, IconData icon, String label, CircuitColors colors) {
    final active = _phoneDrawerTab == idx;
    return Semantics(
      label: label,
      button: true,
      selected: active,
      child: InkWell(
        onTap: () {
          setState(() => _phoneDrawerTab = active ? -1 : idx);
          _updateFftSubscription();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: active ? colors.accentAmber : colors.componentStroke),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: active ? colors.accentAmber : colors.componentStroke, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCanvas(AppLocalizations l10n, SimTelemetry tel) {
    return SchematicCanvas(
      doc: _doc,
      tool: _tool,
      placingKind: _placingKind,
      selectedCompId: _selectedCompId,
      selectedCompIds: _selectedCompIds,
      pendingWirePin: _pendingWirePin,
      nodeVoltages: tel.nodeVoltages,
      compCurrents: tel.compCurrents,
      animPhase: tel.animPhase,
      showLabels: _showLabels,
      showNodeVoltages: _showNodeVoltages,
      showFlow: _showFlow,
      overloadedIds: tel.overloadedIds,
      blownFuseIds: tel.blownFuseIds,
      errCode: tel.errCode,
      errDetail: tel.errDetail,
      fitTrigger: _fitTrigger,
      zoomInTrigger: _zoomInTrigger,
      zoomOutTrigger: _zoomOutTrigger,
      zoomResetTrigger: _zoomResetTrigger,
      coarseGridSnap: _coarseGridSnap,
      onZoomChanged: (s) => setState(() => _canvasScale = s),
      onContextMenu: (cId, wIdx, nId, gPos, gx, gy) =>
          _showCanvasContextMenu(cId, wIdx, nId, gPos, gx, gy, l10n),
      onEditNote: (noteId) => showEditNoteDialog(context, noteId, l10n, _doc, () {
        _scheduleAutoSave();
        setState(() {});
      }),
      onMoveNote: (noteId, gx, gy, finish) {
        _doc.moveNote(noteId, gx, gy);
        if (finish) _scheduleAutoSave();
        setState(() {});
      },
      onSplitWireJunction: (wireIdx, gx, gy) {
        final jPin = _doc.splitWireAtGrid(wireIdx, gx, gy);
        if (jPin == null) return;
        if (_pendingWirePin == null) {
          setState(() {
            _pendingWirePin = jPin;
            _pendingSplitJunctionId = jPin.compId;
            _pendingSplitRevision = _doc.revision;
          });
        } else {
          _doc.addWire(_pendingWirePin!, jPin, recordUndo: _pendingSplitJunctionId == null);
          _pendingWirePin = null;
          _pendingSplitJunctionId = null;
          _pendingSplitRevision = null;
          _syncCircuit();
        }
      },
      onDropCompFromPalette: (kind, gx, gy) {
        final c = _doc.addComponent(kind, gx, gy);
        _selectedCompId = c.id;
        _tool = CanvasTool.select;
        _syncCircuit();
      },
      onBoxSelect: (ids) => setState(() {
        _selectedCompIds
          ..clear()
          ..addAll(ids);
        _selectedCompId = ids.isNotEmpty ? ids.last : null;
        _tool = CanvasTool.select;
      }),
      onMomentaryButton: (id, closed) => _setBinarySwitch(id, closed ? 1.0 : 0.0),
      onSelectComponent: (id) => setState(() {
        if (HardwareKeyboard.instance.isShiftPressed && id != null) {
          if (_selectedCompId != null) _selectedCompIds.add(_selectedCompId!);
          if (!_selectedCompIds.remove(id)) _selectedCompIds.add(id);
          _selectedCompId = _selectedCompIds.contains(id) ? id : _selectedCompIds.lastOrNull;
        } else {
          _selectedCompIds.clear();
          _selectedCompId = id;
        }
      }),
      onPlaceAtGrid: (pt) {
        final gx = pt.dx.round();
        final gy = pt.dy.round();
        PlacedComponent? placed;
        if (_placingSubcircuitName != null) {
          placed = _doc.placeSubcircuit(_placingSubcircuitName!, gx, gy);
        } else if (_placingPartPreset != null) {
          placed = _doc.addPartPreset(_placingPartPreset!, gx, gy);
        } else if (_placingKind != null) {
          placed = _doc.addComponent(_placingKind!, gx, gy);
        }
        if (placed == null) return;
        _selectedCompId = placed.id;
        _placingSubcircuitName = null;
        _placingPartPreset = null;
        _tool = CanvasTool.select;
        _syncCircuit();
      },
      onTapPin: (pin) {
        if (_tool == CanvasTool.probeCh1 ||
            _tool == CanvasTool.probeCh2 ||
            _tool == CanvasTool.probeCh3 ||
            _tool == CanvasTool.probeCh4) {
          final ch = switch (_tool) {
            CanvasTool.probeCh1 => 1,
            CanvasTool.probeCh2 => 2,
            CanvasTool.probeCh3 => 3,
            _ => 4,
          };
          _doc.setProbe(ch, pin);
          _syncCircuit();
          return;
        }
        if (_pendingWirePin == null) {
          setState(() => _pendingWirePin = pin);
        } else {
          _doc.addWire(_pendingWirePin!, pin, recordUndo: _pendingSplitJunctionId == null);
          _pendingWirePin = null;
          _pendingSplitJunctionId = null;
          _pendingSplitRevision = null;
          _syncCircuit();
        }
      },
      onDragStart: _doc.recordUndoSnapshot,
      onMoveComponent: (id, gx, gy, finish) {
        if (!finish) {
          final cur = _doc.components.where((c) => c.id == id).firstOrNull;
          if (cur != null && _selectedCompIds.length > 1 && _selectedCompIds.contains(id)) {
            final dx = gx - cur.gridX;
            final dy = gy - cur.gridY;
            for (final sid in _selectedCompIds) {
              final sc = _doc.components.where((c) => c.id == sid).firstOrNull;
              if (sc != null) _doc.moveComponent(sid, sc.gridX + dx, sc.gridY + dy);
            }
          } else {
            _doc.moveComponent(id, gx, gy);
          }
        }
        if (finish) {
          _syncCircuit();
        } else {
          setState(() {});
        }
      },
      onToggleSwitch: (id) {
        final c = _doc.components.firstWhere((e) => e.id == id);
        _setBinarySwitch(id, c.params[0] >= 0.5 ? 0.0 : 1.0, recordUndo: true);
      },
      onDeleteComponent: (id) {
        _doc.deleteComponent(id);
        if (_selectedCompId == id) _selectedCompId = null;
        _syncCircuit();
      },
      onDeleteWire: (idx) {
        _doc.deleteWireAt(idx);
        _syncCircuit();
      },
      onMoveWireBend: (idx, bx, finish) {
        if (finish) {
          _scheduleAutoSave();
        } else {
          _doc.moveWireBend(idx, bx);
        }
        setState(() {});
      },
    );
  }

  Widget _buildInspector(AppLocalizations l10n, CircuitColors colors) {
    final selected = _doc.components.where((c) => c.id == _selectedCompId).firstOrNull;
    return InspectorPanel(
      selected: selected,
      onRotate: () {
        if (selected == null) return;
        _doc.rotateComponent(selected.id);
        _syncCircuit();
      },
      onDelete: () {
        if (selected == null) return;
        _doc.deleteComponent(selected.id);
        _selectedCompId = null;
        _syncCircuit();
      },
      onUngroupSubcircuit: selected?.kind == CompKind.subcircuit
          ? () {
              if (_doc.ungroupSubcircuit(selected!.id)) {
                _selectedCompId = null;
                _selectedCompIds.clear();
                _syncCircuit();
              }
            }
          : null,
      onHotkeyChanged: selected == null
          ? null
          : (key) {
              _doc.setComponentHotkey(selected.id, key);
              _scheduleAutoSave();
              setState(() {});
            },
      onEditHex: () {
        if (selected == null) return;
        if (selected.kind == CompKind.netPort) {
          showEditNetPortLabelDialog(context, selected, l10n, _doc, _syncCircuit);
        } else {
          showEditWordGenHexDialog(
            context,
            selected,
            l10n,
            _doc,
            _simCtrl.setWordGenPattern,
            _syncCircuit,
          );
        }
      },
      onRecordUndo: _doc.recordUndoSnapshot,
      onFaultChanged: (f) {
        if (selected == null) return;
        _doc.updateFault(selected.id, f);
        _simCtrl.setFault(_doc, selected.id, f.index, solveDc: !_running);
        _scheduleAutoSave();
        setState(() {});
      },
      onBinarySwitch: _setBinarySwitch,
      onParamChanged: _applyParamChange,
      onEditParamNumeric: (c, spec, cur, label) => showEditParamNumericDialog(
        context,
        c,
        spec,
        cur,
        label,
        l10n,
        _doc,
        (paramIdx, val) => _applyParamChange(c, paramIdx, val),
      ),
    );
  }

  void _setBinarySwitch(int compId, double value, {bool recordUndo = false}) {
    if (recordUndo) _doc.recordUndoSnapshot();
    _doc.updateParam(compId, 0, value);
    _simCtrl.setControl(_doc, compId, 0, value, solveDc: !_running);
    _scheduleAutoSave();
    if (mounted) setState(() {});
  }

  void _applyParamChange(PlacedComponent c, int pIdx, double next) {
    _doc.updateParam(c.id, pIdx, next);
    final ffiParamIdx = SimController.liveFfiParamIdx(c.kind, pIdx);
    if (ffiParamIdx != null) {
      _simCtrl.setControl(_doc, c.id, ffiParamIdx, next, solveDc: !_running);
      _scheduleAutoSave();
      setState(() {});
    } else {
      _syncCircuit();
    }
  }

}
