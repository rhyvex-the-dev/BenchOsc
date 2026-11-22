import 'dart:async';
import 'dart:io';
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
import 'theme/circuit_theme.dart';
import 'widgets/component_palette.dart';
import 'widgets/inspector_panel.dart';
import 'widgets/workbench_toolbar.dart';

void main() {
  runApp(const OpenBenchApp());
}

class OpenBenchApp extends StatefulWidget {
  const OpenBenchApp({super.key});

  @override
  State<OpenBenchApp> createState() => _OpenBenchAppState();
}

class _OpenBenchAppState extends State<OpenBenchApp> {
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

class _WorkspaceTab {
  final CircuitDoc doc;
  String title;
  int savedRevision;
  int? selectedCompId;
  Set<int> selectedCompIds = {};

  _WorkspaceTab(this.doc, {required this.title, int? savedRevision})
      : savedRevision = savedRevision ?? doc.revision;

  bool get isDirty => doc.revision != savedRevision;
}

class _WorkbenchHomeState extends State<WorkbenchHome> with SingleTickerProviderStateMixin {
  final SimController _simCtrl = SimController();
  final BuzzerAudio _buzzer = BuzzerAudio();
  late final Ticker _ticker;
  final List<_WorkspaceTab> _tabs = [_WorkspaceTab(CircuitDoc(), title: 'Sheet 1')];
  int _activeTabIdx = 0;
  CircuitDoc get _doc => _tabs[_activeTabIdx].doc;
  Timer? _autoSaveTimer;

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
  int? _selectedCompId;
  final Set<int> _selectedCompIds = {};
  final Set<int> _hotkeyHeldPushbuttons = {};
  List<PlacedComponent> _clipboardComps = const [];
  List<WireLink> _clipboardWires = const [];
  int _pasteCount = 0;
  PinRef? _pendingWirePin;
  int? _pendingSplitJunctionId;

  int _activeInstTab = 0;
  int _secondaryInstTab = 1;
  bool _splitInstruments = false;
  bool _scopeInFftMode = false;
  double _rightPanelWidth = 340.0;
  int _phoneDrawerTab = -1; // -1 = collapsed canvas-first on phone
  String _paletteQuery = '';
  final Set<CompKind> _favorites = {};
  final List<(String title, String json)> _recentCircuits = [];

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

  bool get _needsFft =>
      (_isInstVisible(0) && _scopeInFftMode) || _isInstVisible(7) || _isInstVisible(1);

  void _updateFftSubscription() {
    _simCtrl.setScopeConfig(fftCh: _spectrumCh, needFft: _needsFft);
  }

  File _autoSaveFile() {
    String dir;
    try {
      if (Platform.isWindows) {
        final base = Platform.environment['APPDATA'];
        final root = (base != null && base.isNotEmpty) ? base : Directory.systemTemp.path;
        dir = '$root/open_bench';
      } else {
        final xdg = Platform.environment['XDG_CONFIG_HOME'];
        final base = (xdg != null && xdg.isNotEmpty)
            ? xdg
            : '${Platform.environment['HOME'] ?? Directory.systemTemp.path}/.config';
        dir = '$base/open_bench';
      }
      Directory(dir).createSync(recursive: true);
    } catch (_) {
      dir = Directory.systemTemp.path;
    }
    return File('$dir/open_bench_autosave.json');
  }

  void _scheduleAutoSave() {
    _autoSaveTimer?.cancel();
    final json = _doc.toJsonString();
    _autoSaveTimer = Timer(const Duration(seconds: 2), () async {
      try {
        await _autoSaveFile().writeAsString(json);
      } catch (_) {}
    });
  }

  Future<bool> _confirmDiscardIfDirty(AppLocalizations l10n) async {
    final tab = _tabs[_activeTabIdx];
    if (!tab.isDirty) return true;
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.unsavedChangesTitle),
        content: Text('${l10n.discardAction} "${tab.title}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.cancelAction)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.discardAction)),
        ],
      ),
    );
    return res ?? false;
  }

  void _switchTab(int idx) {
    if (idx < 0 || idx >= _tabs.length || idx == _activeTabIdx) return;
    _tabs[_activeTabIdx]
      ..selectedCompId = _selectedCompId
      ..selectedCompIds = Set<int>.from(_selectedCompIds);
    _activeTabIdx = idx;
    _selectedCompId = _tabs[idx].selectedCompId;
    _selectedCompIds
      ..clear()
      ..addAll(_tabs[idx].selectedCompIds);
    _pendingWirePin = null;
    _pendingSplitJunctionId = null;
    _syncCircuit(scheduleSave: false);
  }

  void _addNewTab() {
    _tabs[_activeTabIdx]
      ..selectedCompId = _selectedCompId
      ..selectedCompIds = Set<int>.from(_selectedCompIds);
    final doc = CircuitDoc();
    _tabs.add(_WorkspaceTab(doc, title: 'Sheet ${_tabs.length + 1}', savedRevision: doc.revision));
    _activeTabIdx = _tabs.length - 1;
    _selectedCompId = null;
    _selectedCompIds.clear();
    _pendingWirePin = null;
    _syncCircuit(scheduleSave: false);
  }

  Future<void> _closeTab(int idx, AppLocalizations l10n) async {
    if (!mounted || idx < 0 || idx >= _tabs.length || _tabs.length <= 1) return;
    if (_tabs[idx].isDirty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.unsavedChangesTitle),
          content: Text('${l10n.discardAction} "${_tabs[idx].title}"?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.cancelAction)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.discardAction)),
          ],
        ),
      );
      if (ok != true) return;
      if (!mounted || idx < 0 || idx >= _tabs.length || _tabs.length <= 1) return;
    }
    _tabs.removeAt(idx);
    if (_activeTabIdx >= _tabs.length) {
      _activeTabIdx = _tabs.length - 1;
    }
    _selectedCompId = _tabs[_activeTabIdx].selectedCompId;
    _selectedCompIds
      ..clear()
      ..addAll(_tabs[_activeTabIdx].selectedCompIds);
    _pendingWirePin = null;
    _syncCircuit(scheduleSave: false);
  }

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
    _selectedCompIds.removeWhere((id) => !_doc.components.any((c) => c.id == id));
    if (_selectedCompId != null && !_doc.components.any((c) => c.id == _selectedCompId)) {
      _selectedCompId = null;
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
    _simCtrl.setScopeConfig(fftCh: _spectrumCh, needFft: _needsFft);
    _simCtrl.syncCircuit(
      _doc,
      logicNodes: _logicNodeIds(),
      logicThreshold: _logicThresh,
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
        CompKind.acSource => c.params.length > 1 ? c.params[1] : 0.0,
        CompKind.funcGen => c.params.length > 2 ? c.params[2] : 0.0,
        CompKind.clock || CompKind.wordGen => c.params.isNotEmpty ? c.params[0] : 0.0,
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

  String _formatError(AppLocalizations l10n, int code, int detail) {
    return switch (code) {
      1 => l10n.errMissingGround,
      2 => l10n.errFloatingNode(detail),
      3 => l10n.errSingularMatrix,
      4 => l10n.errConvergenceFailed,
      5 => l10n.errStepUnderflow,
      6 => l10n.errMaxIterations,
      7 => l10n.errInvalidParam,
      8 => l10n.errCapacityExceeded,
      _ => l10n.errGeneric(code),
    };
  }

  void _recordRecent(String title) {
    final json = _doc.toJsonString();
    _recentCircuits.removeWhere((e) => e.$1 == title);
    _recentCircuits.insert(0, (title, json));
    if (_recentCircuits.length > 5) _recentCircuits.removeLast();
  }

  Future<void> _openIoDialog(AppLocalizations l10n, {bool importMode = false}) async {
    final cir = importMode ? '' : await _simCtrl.exportCir(_doc);
    if (!mounted) return;
    showWorkbenchIoDialog(
      context: context,
      doc: _doc,
      cirExportText: cir,
      ch1Times: _simCtrl.telemetry.value.ch1Times,
      ch1: _simCtrl.telemetry.value.ch1,
      ch2: _simCtrl.telemetry.value.ch2,
      recentCircuits: _recentCircuits,
      l10n: l10n,
      importMode: importMode,
      onImported: (title) {
        _recordRecent(title);
        _tabs[_activeTabIdx]
          ..title = title
          ..savedRevision = _doc.revision;
        _selectedCompId = null;
        _selectedCompIds.clear();
        _syncCircuit();
      },
    );
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _ticker.dispose();
    _simCtrl.dispose();
    super.dispose();
  }

  bool _isEditingText() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _cancelPendingWire() {
    if (_pendingSplitJunctionId != null) {
      _doc.undo();
      _pendingSplitJunctionId = null;
      _pendingWirePin = null;
      _syncCircuit();
      return;
    }
    if (_pendingWirePin != null) {
      setState(() => _pendingWirePin = null);
    }
  }

  void _copySelection() {
    final sel = _effectiveSelection;
    if (sel.isEmpty) return;
    _clipboardComps = _doc.components
        .where((c) => sel.contains(c.id))
        .map((c) => c.copyWith(params: List<double>.from(c.params)))
        .toList();
    _clipboardWires = _doc.wires
        .where((w) => sel.contains(w.from.compId) && sel.contains(w.to.compId))
        .toList();
    _pasteCount = 0;
  }

  void _pasteClipboard() {
    if (_clipboardComps.isEmpty) return;
    _pasteCount++;
    final off = 2 * _pasteCount;
    final newIds = _doc.pasteSnapshot(_clipboardComps, _clipboardWires, dx: off, dy: off);
    if (newIds.isEmpty) return;
    _selectedCompIds
      ..clear()
      ..addAll(newIds);
    _selectedCompId = newIds.last;
    _syncCircuit();
  }

  bool _triggerHotkey(String rawChar, {required bool isDown, required bool shift}) {
    final ch = rawChar.toUpperCase();
    if (!RegExp(r'^[A-Z0-9]$').hasMatch(ch)) return false;
    var handled = false;
    for (final c in _doc.components.toList()) {
      if (c.hotkey != ch) continue;
      if (c.kind == CompKind.pushbutton) {
        if (isDown && !_hotkeyHeldPushbuttons.contains(c.id)) {
          _hotkeyHeldPushbuttons.add(c.id);
          _setBinarySwitch(c.id, 1.0);
          handled = true;
        } else if (!isDown && _hotkeyHeldPushbuttons.remove(c.id)) {
          _setBinarySwitch(c.id, 0.0);
          handled = true;
        }
      } else if (isDown) {
        if (c.kind == CompKind.switchSpst || c.kind == CompKind.switchSpdt) {
          _setBinarySwitch(c.id, c.params[0] >= 0.5 ? 0.0 : 1.0, recordUndo: true);
          handled = true;
        } else if (c.kind == CompKind.potentiometer && c.params.length > 1) {
          final nextW = (c.params[1] + (shift ? -0.1 : 0.1)).clamp(0.05, 0.95);
          _doc.recordUndoSnapshot();
          _applyParamChange(c, 1, nextW);
          handled = true;
        } else if (c.kind == CompKind.hexKeypad && c.params.isNotEmpty) {
          final nextHex = (c.params[0].round() + (shift ? 15 : 1)) & 0xF;
          _doc.recordUndoSnapshot();
          _applyParamChange(c, 0, nextHex.toDouble());
          handled = true;
        } else if (c.kind == CompKind.dipSwitch4 && c.params.isNotEmpty) {
          final nextMask = c.params[0].round() ^ 0x8;
          _doc.recordUndoSnapshot();
          _applyParamChange(c, 0, nextMask.toDouble());
          handled = true;
        }
      }
    }
    return handled;
  }

  KeyEventResult _handleGlobalKey(FocusNode node, KeyEvent event, AppLocalizations l10n) {
    if (_isEditingText()) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    final primaryMod = kb.isControlPressed || kb.isMetaPressed;
    final key = event.logicalKey;

    if (event is KeyUpEvent && !primaryMod) {
      final label = key.keyLabel;
      if (label.length == 1 && _triggerHotkey(label, isDown: false, shift: kb.isShiftPressed)) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (!primaryMod) {
      final label = key.keyLabel;
      if (label.length == 1 &&
          label != 'R' &&
          label != 'F' &&
          _triggerHotkey(label, isDown: true, shift: kb.isShiftPressed)) {
        return KeyEventResult.handled;
      }
    }

    if (primaryMod) {
      if (key == LogicalKeyboardKey.keyZ) {
        if (kb.isShiftPressed) {
          if (_doc.canRedo) {
            _doc.redo();
            _syncCircuit();
          }
        } else if (_doc.canUndo) {
          _doc.undo();
          _syncCircuit();
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyY) {
        if (_doc.canRedo) {
          _doc.redo();
          _syncCircuit();
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyC) {
        _copySelection();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyV) {
        _pasteClipboard();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyD) {
        _duplicateIds(_effectiveSelection);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.space) {
      setState(() => _running = !_running);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyR && _effectiveSelection.isNotEmpty) {
      _doc.rotateComponents(_effectiveSelection);
      _syncCircuit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF && _effectiveSelection.isNotEmpty) {
      _doc.flipComponents(_effectiveSelection);
      _syncCircuit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.slash && kb.isShiftPressed) {
      showWorkbenchHelpDialog(context, l10n);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) {
      _deleteSelected();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _cancelPendingWire();
      setState(() {
        _placingKind = null;
        _placingSubcircuitName = null;
        _placingPartPreset = null;
        _selectedCompIds.clear();
        if (_tool == CanvasTool.place) _tool = CanvasTool.select;
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Set<int> get _effectiveSelection => {
        ?_selectedCompId,
        ..._selectedCompIds,
      };

  void _duplicateIds(Set<int> ids) {
    final newIds = _doc.duplicateComponents(ids);
    if (newIds.isEmpty) return;
    _selectedCompIds
      ..clear()
      ..addAll(newIds);
    _selectedCompId = newIds.last;
    _syncCircuit();
  }

  void _deleteSelected() {
    final sel = _effectiveSelection;
    if (sel.isEmpty) return;
    _doc.deleteComponents(sel);
    _selectedCompId = null;
    _selectedCompIds.clear();
    _syncCircuit();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).extension<CircuitColors>()!;
    final isPhone = MediaQuery.sizeOf(context).width < 720;

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) => _handleGlobalKey(node, event, l10n),
      child: Scaffold(
        appBar: AppBar(
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
                tooltip: l10n.newCanvasAction,
                icon: const Icon(Icons.note_add_outlined, size: 20),
                onPressed: () async {
                  if (!await _confirmDiscardIfDirty(l10n) || !mounted) return;
                  _doc.clearCanvas();
                  if (_activeTabIdx >= 0 && _activeTabIdx < _tabs.length) {
                    _tabs[_activeTabIdx].savedRevision = _doc.revision;
                  }
                  _selectedCompId = null;
                  _selectedCompIds.clear();
                  _pendingWirePin = null;
                  _syncCircuit(scheduleSave: false);
                },
              ),
              IconButton(
                tooltip: l10n.undoAction,
                icon: const Icon(Icons.undo, size: 20),
                onPressed: _doc.canUndo
                    ? () {
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
        body: isPhone ? _buildPhoneBody(l10n, colors) : _buildDesktopBody(l10n, colors),
      ),
    );
  }

  Widget _presetMenu(AppLocalizations l10n, CircuitColors colors) {
    return PopupMenuButton<String>(
      tooltip: l10n.presetLabel,
      icon: Icon(Icons.auto_awesome_mosaic, color: colors.accentAmber, size: 20),
      onSelected: (key) async {
        if (key == 'restore_autosave') {
          try {
            var f = _autoSaveFile();
            if (!await f.exists()) {
              f = File('${Directory.systemTemp.path}/open_bench_autosave.json');
            }
            if (!await f.exists()) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('No autosave file found.')),
                );
              }
              return;
            }
            final raw = await f.readAsString();
            if (!mounted) return;
            if (!await _confirmDiscardIfDirty(l10n) || !mounted) return;
            _doc.loadJsonString(raw);
            if (_activeTabIdx >= 0 && _activeTabIdx < _tabs.length) {
              _tabs[_activeTabIdx]
                ..title = 'Recovered'
                ..savedRevision = _doc.revision;
            }
            _selectedCompId = null;
            _selectedCompIds.clear();
            _pendingWirePin = null;
            _syncCircuit(scheduleSave: false);
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Failed to restore autosave: $e')),
              );
            }
          }
          return;
        }
        final preset = PresetKind.values.where((p) => p.name == key).firstOrNull;
        if (preset == null) return;
        if (!mounted) return;
        if (!await _confirmDiscardIfDirty(l10n) || !mounted) return;
        _doc.loadPreset(preset);
        if (_activeTabIdx >= 0 && _activeTabIdx < _tabs.length) {
          _tabs[_activeTabIdx]
            ..title = preset.name
            ..savedRevision = _doc.revision;
        }
        _selectedCompId = null;
        _selectedCompIds.clear();
        _pendingWirePin = null;
        _syncCircuit(scheduleSave: false);
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'restore_autosave', child: Text(l10n.restoreAutoSaveAction)),
        const PopupMenuDivider(),
        PopupMenuItem(value: PresetKind.rcFilter.name, child: Text(l10n.presetRcFilter)),
        PopupMenuItem(value: PresetKind.rectifier.name, child: Text(l10n.presetRectifier)),
        PopupMenuItem(value: PresetKind.opAmp.name, child: Text(l10n.presetOpAmp)),
        PopupMenuItem(value: PresetKind.bjtSwitch.name, child: Text(l10n.presetBjtSwitch)),
        PopupMenuItem(value: PresetKind.digitalXor.name, child: Text(l10n.presetDigitalXor)),
        PopupMenuItem(value: PresetKind.dffDivider.name, child: Text(l10n.presetDffDivider)),
        PopupMenuItem(value: PresetKind.timer555Astable.name, child: Text(l10n.presetTimer555)),
        PopupMenuItem(value: PresetKind.wordGenCounter.name, child: Text(l10n.presetWordGen)),
        PopupMenuItem(value: PresetKind.optocouplerIso.name, child: Text(l10n.presetOptocoupler)),
        PopupMenuItem(value: PresetKind.schmittCounter.name, child: Text(l10n.presetSchmittCounter)),
      ],
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
        onUndo: () {
          _doc.undo();
          _syncCircuit();
        },
        onRedo: () {
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
                  _formatError(l10n, tel.errCode, tel.errDetail),
                  style: TextStyle(color: colors.dangerRed, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            Expanded(child: _buildCanvas(l10n, tel)),
          ],
        ),
      );

  Widget _buildDesktopBody(AppLocalizations l10n, CircuitColors colors) {
    return Row(
      children: [
        SizedBox(width: 205, child: _paletteWidget()),
        Expanded(
          child: Column(
            children: [
              _toolBarWidget(l10n, isPhone: false),
              _tabStripWidget(l10n),
              Expanded(child: _canvasArea(l10n, colors)),
            ],
          ),
        ),
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
          child: Column(
            children: [
              SizedBox(height: 230, child: _buildInspector(l10n, colors)),
              Expanded(child: _buildInstrumentRack(l10n, colors)),
            ],
          ),
        ),
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
        onTap: () => setState(() => _phoneDrawerTab = active ? -1 : idx),
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

  Future<void> _showCanvasContextMenu(
    int? compId,
    int? wireIdx,
    int? noteId,
    Offset globalPos,
    int gx,
    int gy,
    AppLocalizations l10n,
  ) async {
    final pos = RelativeRect.fromLTRB(globalPos.dx, globalPos.dy, globalPos.dx + 1, globalPos.dy + 1);
    final items = <PopupMenuEntry<String>>[];
    if (compId != null) {
      if (!_effectiveSelection.contains(compId)) {
        setState(() {
          _selectedCompIds.clear();
          _selectedCompId = compId;
        });
      }
      final comp = _doc.components.where((c) => c.id == compId).firstOrNull;
      items.addAll([
        PopupMenuItem(value: 'rot', child: Text(l10n.rotateAction)),
        PopupMenuItem(value: 'flipH', child: Text(l10n.flipHAction)),
        PopupMenuItem(value: 'flipV', child: Text(l10n.flipVAction)),
        PopupMenuItem(value: 'dup', child: Text(l10n.duplicateAction)),
        if (comp?.kind == CompKind.subcircuit)
          const PopupMenuItem(value: 'ungroup', child: Text('Ungroup Subcircuit')),
        PopupMenuItem(value: 'delComp', child: Text(l10n.deleteAction)),
      ]);
    } else if (wireIdx != null) {
      items.add(const PopupMenuItem(value: 'delWire', child: Text('Delete Wire')));
    } else if (noteId != null) {
      items.addAll([
        PopupMenuItem(value: 'editNote', child: Text(l10n.editNoteAction)),
        PopupMenuItem(value: 'delNote', child: Text(l10n.deleteAction)),
      ]);
    } else {
      items.addAll([
        PopupMenuItem(value: 'addNote', child: Text(l10n.addNoteAction)),
        if (_clipboardComps.isNotEmpty) const PopupMenuItem(value: 'paste', child: Text('Paste')),
        PopupMenuItem(value: 'fit', child: Text(l10n.fitViewAction)),
      ]);
    }
    if (items.isEmpty) return;
    final choice = await showMenu<String>(context: context, position: pos, items: items);
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'rot':
        _doc.rotateComponents(_effectiveSelection);
        _syncCircuit();
      case 'flipH':
        _doc.flipComponents(_effectiveSelection);
        _syncCircuit();
      case 'flipV':
        _doc.flipComponents(_effectiveSelection, vertical: true);
        _syncCircuit();
      case 'dup':
        _duplicateIds(_effectiveSelection);
      case 'ungroup':
        if (compId != null && _doc.ungroupSubcircuit(compId)) {
          _selectedCompId = null;
          _selectedCompIds.clear();
          _syncCircuit();
        }
      case 'delComp':
        _deleteSelected();
      case 'delWire':
        if (wireIdx != null) {
          _doc.deleteWireAt(wireIdx);
          _syncCircuit();
        }
      case 'editNote':
        if (noteId != null) {
          showEditNoteDialog(context, noteId, l10n, _doc, () {
            _scheduleAutoSave();
            setState(() {});
          });
        }
      case 'delNote':
        if (noteId != null) {
          _doc.deleteNote(noteId);
          _scheduleAutoSave();
          setState(() {});
        }
      case 'addNote':
        showAddNoteDialog(context, l10n, _doc, () {
          _scheduleAutoSave();
          setState(() {});
        }, gx: gx, gy: gy);
      case 'paste':
        _pasteClipboard();
      case 'fit':
        setState(() => _fitTrigger++);
    }
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
          });
        } else {
          _doc.addWire(_pendingWirePin!, jPin, recordUndo: _pendingSplitJunctionId == null);
          _pendingWirePin = null;
          _pendingSplitJunctionId = null;
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
          if (_tool == CanvasTool.probeCh1) _doc.probeCh1 = pin;
          if (_tool == CanvasTool.probeCh2) _doc.probeCh2 = pin;
          if (_tool == CanvasTool.probeCh3) _doc.probeCh3 = pin;
          if (_tool == CanvasTool.probeCh4) _doc.probeCh4 = pin;
          _syncCircuit();
          return;
        }
        if (_pendingWirePin == null) {
          setState(() => _pendingWirePin = pin);
        } else {
          _doc.addWire(_pendingWirePin!, pin, recordUndo: _pendingSplitJunctionId == null);
          _pendingWirePin = null;
          _pendingSplitJunctionId = null;
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
        _setBinarySwitch(id, c.params[0] >= 0.5 ? 0.0 : 1.0);
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
        if (!finish) _doc.moveWireBend(idx, bx);
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
    setState(() {});
  }

  void _applyParamChange(PlacedComponent c, int pIdx, double next) {
    _doc.updateParam(c.id, pIdx, next);
    final canLive = c.kind == CompKind.potentiometer ||
        (c.kind == CompKind.dcSource && pIdx == 0) ||
        (c.kind == CompKind.powerRail && pIdx == 0) ||
        (c.kind == CompKind.dcCurrent && pIdx == 0) ||
        ((c.kind == CompKind.acSource || c.kind == CompKind.acCurrent) && pIdx <= 3) ||
        ((c.kind == CompKind.resistor ||
                c.kind == CompKind.lamp ||
                c.kind == CompKind.buzzer ||
                c.kind == CompKind.capacitor ||
                c.kind == CompKind.polarizedCapacitor ||
                c.kind == CompKind.varCapacitor ||
                c.kind == CompKind.inductor ||
                c.kind == CompKind.varInductor ||
                c.kind == CompKind.fuse ||
                c.kind == CompKind.transformer ||
                c.kind == CompKind.centerTapTransformer ||
                c.kind == CompKind.vcvs ||
                c.kind == CompKind.vccs ||
                c.kind == CompKind.cccs ||
                c.kind == CompKind.ccvs ||
                c.kind == CompKind.voltageReg ||
                c.kind == CompKind.instAmp ||
                c.kind == CompKind.analogMultiplier ||
                c.kind == CompKind.hexKeypad ||
                c.kind == CompKind.dipSwitch4 ||
                c.kind == CompKind.opAmp) &&
            pIdx == 0) ||
        (c.kind == CompKind.dcMotor && pIdx == 1) ||
        (c.kind == CompKind.coupledInductor && pIdx == 2) ||
        (c.kind == CompKind.vco && pIdx <= 1) ||
        (c.kind == CompKind.zener && pIdx == 2) ||
        ((c.kind == CompKind.npnBjt || c.kind == CompKind.pnpBjt) && pIdx == 1) ||
        ((c.kind == CompKind.nmos || c.kind == CompKind.pmos) && pIdx == 1) ||
        (c.kind == CompKind.optocoupler && pIdx == 0) ||
        ((c.kind == CompKind.relay || c.kind == CompKind.relaySpdt || c.kind == CompKind.relayDpdt) &&
            pIdx <= 1) ||
        (c.kind == CompKind.clock && pIdx <= 1) ||
        (c.kind == CompKind.schmittTrigger && pIdx <= 1) ||
        ((c.kind == CompKind.counter4Bit || c.kind == CompKind.counter4BitFull) && pIdx == 0) ||
        (c.kind == CompKind.wordGen && (pIdx == 0 || pIdx == 2)) ||
        (c.kind == CompKind.funcGen && pIdx >= 1 && pIdx <= 4);
    if (canLive) {
      final ffiParamIdx = switch (c.kind) {
        CompKind.potentiometer => pIdx == 1 ? 0 : 1,
        CompKind.fuse => 1,
        CompKind.funcGen => switch (pIdx) { 2 => 0, 1 => 1, 3 => 2, _ => 3 },
        CompKind.acSource ||
        CompKind.acCurrent ||
        CompKind.relay ||
        CompKind.relaySpdt ||
        CompKind.relayDpdt ||
        CompKind.clock ||
        CompKind.vco ||
        CompKind.schmittTrigger ||
        CompKind.counter4Bit ||
        CompKind.counter4BitFull ||
        CompKind.dcMotor ||
        CompKind.coupledInductor =>
          pIdx,
        CompKind.nmos || CompKind.pmos => 1,
        CompKind.wordGen => pIdx == 0 ? 0 : 1,
        _ => 0,
      };
      _simCtrl.setControl(_doc, c.id, ffiParamIdx, next, solveDc: !_running);
      setState(() {});
    } else {
      _syncCircuit();
    }
  }

  Future<void> _triggerBode({
    double fStart = 10.0,
    double fStop = 100000.0,
    int ptsPerDecade = 20,
    int? acSourceId,
    int inNode = -1,
    int? outNodeOverride,
  }) =>
      _simCtrl.runBodeSweep(
        _doc,
        logicNodes: _logicNodeIds(),
        logicThreshold: _logicThresh,
        fStart: fStart,
        fStop: fStop,
        ptsPerDecade: ptsPerDecade,
        acSourceId: acSourceId,
        inNode: inNode,
        outNodeOverride: outNodeOverride,
      );

  Future<void> _triggerDcSweep({
    int? sweepSrcId,
    int? secSrcId,
    double vStart = 0.0,
    double vStop = 5.0,
    int steps = 25,
    bool family = false,
    bool ivCurve = false,
  }) =>
      _simCtrl.runDcSweep(
        _doc,
        logicNodes: _logicNodeIds(),
        logicThreshold: _logicThresh,
        sweepSrcId: sweepSrcId,
        secSrcId: secSrcId,
        vStart: vStart,
        vStop: vStop,
        steps: steps,
        family: family,
        ivCurve: ivCurve,
        selectedCompId: _selectedCompId,
      );

  Widget _buildSingleInstrument(
    int instTab,
    AppLocalizations l10n,
    SimTelemetry tel,
  ) {
    final selectedCurrent =
        _selectedCompId != null ? (tel.compCurrents[_selectedCompId!] ?? 0.0) : 0.0;
    var selectedVoltageDrop = 0.0;
    if (_selectedCompId != null) {
      final sel = _doc.components.where((c) => c.id == _selectedCompId).firstOrNull;
      if (sel != null && sel.pinOffsets.isNotEmpty) {
        final v0 = tel.nodeVoltages[_doc.resolvedNodes[PinRef(sel.id, 0)] ?? 0] ?? 0.0;
        final v1 = sel.pinOffsets.length >= 2
            ? (tel.nodeVoltages[_doc.resolvedNodes[PinRef(sel.id, 1)] ?? 0] ?? 0.0)
            : 0.0;
        selectedVoltageDrop = v0 - v1;
      }
    }
    return switch (instTab) {
      0 => OscilloscopeView(
          title: l10n.oscilloscopeTitle,
          ch1Values: tel.ch1,
          ch2Values: tel.ch2,
          ch3Values: tel.ch3,
          ch4Values: tel.ch4,
          ch1Times: tel.ch1Times,
          fftBins: tel.fft,
          ch1Dc: tel.ch1Stats.dc,
          ch2Dc: tel.ch2Stats.dc,
          ch3Dc: tel.ch3Stats.dc,
          ch4Dc: tel.ch4Stats.dc,
          thdPercent: tel.ch1Thd,
          triggered: tel.scopeTriggered,
          ch3Probed: _doc.probeCh3 != null,
          ch4Probed: _doc.probeCh4 != null,
          onFftModeChanged: (fftOn) {
            _scopeInFftMode = fftOn;
            _updateFftSubscription();
          },
          onTriggerConfigChanged: (trigCh, level, rising, require) {
            _simCtrl.setScopeConfig(
              trigCh: trigCh,
              trigLevel: level,
              rising: rising,
              requireTrigger: require,
              fftCh: _spectrumCh,
              needFft: _needsFft,
            );
          },
        ),
      1 => MultimeterView(
          ch1Stats: tel.ch1Stats,
          ch2Stats: tel.ch2Stats,
          ch3Stats: tel.ch3Stats,
          ch4Stats: tel.ch4Stats,
          ch1Values: tel.ch1,
          ch2Values: tel.ch2,
          ch1Times: tel.ch1Times,
          selectedCurrentAmps: selectedCurrent,
          selectedVoltageDrop: selectedVoltageDrop,
          selectedPowerWatts:
              _selectedCompId != null ? tel.compPowers[_selectedCompId!] : null,
          ch1ThdPercent: tel.ch1Thd,
          ch3Probed: _doc.probeCh3 != null,
          ch4Probed: _doc.probeCh4 != null,
          ch1DcFallback: _doc.probeCh1 != null
              ? (tel.nodeVoltages[_doc.resolvedNodes[_doc.probeCh1!] ?? 0] ?? 0.0)
              : null,
          ch2DcFallback: _doc.probeCh2 != null
              ? (tel.nodeVoltages[_doc.resolvedNodes[_doc.probeCh2!] ?? 0] ?? 0.0)
              : null,
          availableNodes: [
            for (final nid in _doc.resolvedNodes.values.toSet().toList()..sort())
              (nid, nid == 0 ? 'GND' : 'N$nid'),
          ],
          onMeasureTwoTerminal: (a, b, diode) => _simCtrl.measureTwoTerminal(
            _doc,
            a,
            b,
            diode,
            logicNodes: _logicNodeIds(),
            logicThreshold: _logicThresh,
          ),
        ),
      2 => BodePlotterView(
          sweepData: tel.bodeData,
          onRunSweep: _triggerBode,
          onRunSweepConfig: ({
            required double fStart,
            required double fStop,
            required int ptsPerDecade,
            int? acSourceId,
            int inNode = -1,
            int? outNode,
          }) =>
              _triggerBode(
            fStart: fStart,
            fStop: fStop,
            ptsPerDecade: ptsPerDecade,
            acSourceId: acSourceId,
            inNode: inNode,
            outNodeOverride: outNode,
          ),
          acSources: [
            for (final c in _doc.components)
              if (c.kind == CompKind.acSource || c.kind == CompKind.funcGen)
                (c.id, formatComponentBadge(c)),
          ],
          probeNodes: [
            for (final nid in _doc.resolvedNodes.values.toSet().toList()..sort())
              if (nid > 0) (nid, 'N$nid'),
          ],
        ),
      3 => LogicConverterView(
          onMinimizeAsync: _simCtrl.minimizeLogicEx,
          onExtractFromCircuit: () => _simCtrl.extractTruthTable(_doc),
          onBuildCircuit: (vars, expr, {bool nandOnly = false}) {
            _doc.synthesizeLogicToCanvas(vars, expr, nandOnly: nandOnly, clearCanvas: false);
            _selectedCompId = null;
            _selectedCompIds.clear();
            _pendingWirePin = null;
            _syncCircuit();
          },
        ),
      4 => LogicAnalyzerView(
          ch1: tel.ch1,
          ch2: tel.ch2,
          ch3: tel.ch3,
          ch4: tel.ch4,
          times: tel.ch1Times,
          logicTimes: tel.logicTimes,
          logicMasks: tel.logicMasks,
          channelLabels: _collectLogicNodes().map((e) => e.$2).toList(),
          onConfigChanged: (_, threshold) => _syncLogicProbes(threshold),
        ),
      5 => DcSweepView(
          sweepData: tel.dcSweepData,
          familyCurves: tel.dcFamilyCurves,
          circuitRevision: tel.epoch,
          onRunSweep: (vStart, vStop) => _triggerDcSweep(vStart: vStart, vStop: vStop),
          onRunSweepConfig: ({
            int? srcId,
            int? secSrcId,
            required double vStart,
            required double vStop,
            required int steps,
            required bool family,
            required bool ivCurve,
          }) =>
              _triggerDcSweep(
            sweepSrcId: srcId,
            secSrcId: secSrcId,
            vStart: vStart,
            vStop: vStop,
            steps: steps,
            family: family,
            ivCurve: ivCurve,
          ),
          sweepSources: [
            for (final c in _doc.components)
              if (c.kind == CompKind.dcSource ||
                  c.kind == CompKind.dcCurrent ||
                  c.kind == CompKind.potentiometer ||
                  c.kind == CompKind.powerRail)
                (c.id, formatComponentBadge(c)),
          ],
          onRunMonteCarloEx: ({required tol, required runs, required gaussian}) =>
              _simCtrl.runMonteCarloEx(
            _doc,
            logicNodes: _logicNodeIds(),
            logicThreshold: _logicThresh,
            tol: tol,
            runs: runs,
            gaussian: gaussian,
          ),
        ),
      6 => () {
          final wgs = _doc.components.where((c) => c.kind == CompKind.wordGen).toList();
          final wg = wgs.where((w) => w.id == _selectedWordGenId).firstOrNull ?? wgs.firstOrNull;
          return WordGenPanel(
            wordGenId: wg?.id,
            wordGens: [
              for (final w in wgs)
                (
                  w.id,
                  'WG${w.id}',
                  w.hexPattern ?? 'FEDCBA9876543210',
                  w.params.isNotEmpty ? w.params[0] : 50.0,
                ),
            ],
            onSelectWordGen: (id) => setState(() => _selectedWordGenId = id),
            hexPattern: wg?.hexPattern ?? 'FEDCBA9876543210',
            freqHz: wg != null && wg.params.isNotEmpty ? wg.params[0] : 50.0,
            tSim: tel.tSim,
            onChangeHex: wg == null
                ? null
                : (hex) {
                    if (_doc.updateWordGenHex(wg.id, hex)) {
                      final bits = CircuitDoc.parseHexPattern64(hex);
                      if (bits != null) _simCtrl.setWordGenPattern(wg.id, bits);
                      setState(() {});
                    }
                  },
            onStepHex: wg == null
                ? null
                : (hex) {
                    final bits = CircuitDoc.parseHexPattern64(hex);
                    if (bits != null) _simCtrl.setWordGenPattern(wg.id, bits);
                  },
            onChangeFreq: wg == null
                ? null
                : (hz) {
                    _doc.recordUndoSnapshot();
                    _applyParamChange(wg, 0, hz);
                  },
            onAddWordGen: () {
              final added = _doc.addComponent(CompKind.wordGen, 4, 4);
              _selectedWordGenId = added.id;
              _syncCircuit();
            },
          );
        }(),
      _ => SpectrumAnalyzerView(
          fftBins: tel.fft,
          ch1Times: tel.ch1Times,
          thdPercent: tel.ch1Thd,
          activeCh: _spectrumCh,
          onChannelChanged: (ch) {
            setState(() => _spectrumCh = ch);
            _updateFftSubscription();
          },
        ),
    };
  }

  Widget _buildInstrumentRack(AppLocalizations l10n, CircuitColors colors) {
    final instEntries = [
      (0, l10n.oscilloscopeTitle),
      (1, l10n.multimeterTitle),
      (2, l10n.bodePlotterTitle),
      (3, l10n.logicConverterTitle),
      (4, l10n.logicAnalyzerTitle),
      (5, l10n.dcSweepTitle),
      (6, l10n.wordGenShortTitle),
      (7, l10n.spectrumTitle),
    ];
    return Semantics(
      label: 'Virtual instruments panel',
      child: Container(
        decoration: BoxDecoration(
          color: colors.panelSurface,
          border: Border(left: BorderSide(color: colors.panelBorder)),
        ),
        padding: const EdgeInsets.all(6),
        child: LayoutBuilder(
          builder: (context, box) {
            final tabs = [
              for (final (idx, label) in instEntries)
                ChoiceChip(
                  selected: _activeInstTab == idx,
                  selectedColor: colors.accentAmber,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                  label: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color: _activeInstTab == idx ? Colors.black : colors.componentStroke,
                    ),
                  ),
                  onSelected: (_) {
                    setState(() => _activeInstTab = idx);
                    _updateFftSubscription();
                    if (idx == 2 && _simCtrl.telemetry.value.bodeData == null) _triggerBode();
                    if (idx == 5 && _simCtrl.telemetry.value.dcSweepData == null) _triggerDcSweep();
                  },
                ),
            ];
            return Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: box.maxHeight < 360
                          ? SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (final chip in tabs)
                                    Padding(padding: const EdgeInsets.only(right: 4), child: chip),
                                ],
                              ),
                            )
                          : Wrap(spacing: 4, runSpacing: 4, children: tabs),
                    ),
                    if (box.maxHeight >= 360)
                      IconButton(
                        tooltip: l10n.splitInstrumentsAction,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        icon: Icon(
                          Icons.splitscreen,
                          size: 16,
                          color: _splitInstruments ? colors.accentAmber : colors.componentStroke,
                        ),
                        onPressed: () {
                          setState(() => _splitInstruments = !_splitInstruments);
                          _updateFftSubscription();
                          if (_splitInstruments &&
                              _secondaryInstTab == 2 &&
                              _simCtrl.telemetry.value.bodeData == null) {
                            _triggerBode();
                          }
                          if (_splitInstruments &&
                              _secondaryInstTab == 5 &&
                              _simCtrl.telemetry.value.dcSweepData == null) {
                            _triggerDcSweep();
                          }
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: (!_splitInstruments && _activeInstTab == 3)
                      ? _buildSingleInstrument(3, l10n, _simCtrl.telemetry.value)
                      : ValueListenableBuilder<SimTelemetry>(
                          valueListenable: _simCtrl.telemetry,
                          builder: (_, tel, _) => Column(
                            children: [
                              Expanded(child: _buildSingleInstrument(_activeInstTab, l10n, tel)),
                              if (_splitInstruments && box.maxHeight >= 360) ...[
                                const Divider(height: 8),
                                Row(
                                  children: [
                                    Text('2nd View:', style: TextStyle(color: colors.accentAmber, fontSize: 11)),
                                    const SizedBox(width: 6),
                                    DropdownButton<int>(
                                      value: _secondaryInstTab,
                                      isDense: true,
                                      underline: const SizedBox.shrink(),
                                      items: [
                                        for (final (idx, label) in instEntries)
                                          DropdownMenuItem(
                                            value: idx,
                                            child: Text(label, style: const TextStyle(fontSize: 11)),
                                          ),
                                      ],
                                      onChanged: (idx) {
                                        if (idx == null) return;
                                        setState(() => _secondaryInstTab = idx);
                                        _updateFftSubscription();
                                        if (idx == 2 && tel.bodeData == null) _triggerBode();
                                        if (idx == 5 && tel.dcSweepData == null) _triggerDcSweep();
                                      },
                                    ),
                                  ],
                                ),
                                Expanded(child: _buildSingleInstrument(_secondaryInstTab, l10n, tel)),
                              ],
                            ],
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
