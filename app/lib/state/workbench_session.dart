import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'circuit_doc.dart';
import 'subcircuits.dart';

class WorkspaceTab {
  final CircuitDoc doc;
  String title;
  int savedRevision;
  int? selectedCompId;
  Set<int> selectedCompIds = {};

  WorkspaceTab(this.doc, {required this.title, int? savedRevision})
      : savedRevision = savedRevision ?? doc.revision;

  bool get isDirty => doc.revision != savedRevision;
}

/// Manages non-UI workbench session state: open sheet tabs, selection, clipboard, recents, and autosave.
class WorkbenchSession {
  final List<WorkspaceTab> tabs = [WorkspaceTab(CircuitDoc(), title: 'Sheet 1')];
  int activeTabIdx = 0;
  int? selectedCompId;
  final Set<int> selectedCompIds = {};
  List<PlacedComponent> _clipboardComps = const [];
  List<WireLink> _clipboardWires = const [];
  Map<String, SubcircuitDef> _clipboardSubcircuits = const {};
  int _pasteCount = 0;
  final List<(String title, String json)> recentCircuits = [];

  Timer? _autoSaveTimer;
  bool _pendingAutoSave = false;
  bool _disposed = false;
  int _saveSeq = 0;

  CircuitDoc get doc => tabs[activeTabIdx].doc;
  WorkspaceTab get activeTab => tabs[activeTabIdx];
  Set<int> get effectiveSelection => {?selectedCompId, ...selectedCompIds};
  bool get hasClipboard => _clipboardComps.isNotEmpty;

  void switchTab(int idx) {
    if (idx < 0 || idx >= tabs.length || idx == activeTabIdx) return;
    tabs[activeTabIdx]
      ..selectedCompId = selectedCompId
      ..selectedCompIds = Set<int>.from(selectedCompIds);
    activeTabIdx = idx;
    selectedCompId = tabs[idx].selectedCompId;
    selectedCompIds
      ..clear()
      ..addAll(tabs[idx].selectedCompIds);
  }

  void addNewTab() {
    tabs[activeTabIdx]
      ..selectedCompId = selectedCompId
      ..selectedCompIds = Set<int>.from(selectedCompIds);
    final newDoc = CircuitDoc();
    tabs.add(WorkspaceTab(newDoc, title: 'Sheet ${tabs.length + 1}', savedRevision: newDoc.revision));
    activeTabIdx = tabs.length - 1;
    selectedCompId = null;
    selectedCompIds.clear();
  }

  void closeTab(int idx) {
    if (idx < 0 || idx >= tabs.length || tabs.length <= 1) return;
    final closingActive = idx == activeTabIdx;
    tabs.removeAt(idx);
    if (idx < activeTabIdx) {
      activeTabIdx--;
    } else if (activeTabIdx >= tabs.length) {
      activeTabIdx = tabs.length - 1;
    }
    if (closingActive) {
      selectedCompId = tabs[activeTabIdx].selectedCompId;
      selectedCompIds
        ..clear()
        ..addAll(tabs[activeTabIdx].selectedCompIds);
    }
  }

  void pruneSelection() {
    selectedCompIds.removeWhere((id) => !doc.components.any((c) => c.id == id));
    if (selectedCompId != null && !doc.components.any((c) => c.id == selectedCompId)) {
      selectedCompId = null;
    }
  }

  void clearSelection() {
    selectedCompId = null;
    selectedCompIds.clear();
  }

  void copySelection() {
    final sel = effectiveSelection;
    if (sel.isEmpty) return;
    _clipboardComps = doc.components
        .where((c) => sel.contains(c.id))
        .map((c) => c.copyWith(params: List<double>.from(c.params)))
        .toList();
    _clipboardWires = doc.wires
        .where((w) => sel.contains(w.from.compId) && sel.contains(w.to.compId))
        .toList();
    final subs = <String, SubcircuitDef>{};
    void collectSub(String? name) {
      if (name == null || subs.containsKey(name)) return;
      final def = doc.subcircuits[name];
      if (def == null) return;
      subs[name] = def;
      for (final ic in def.components) {
        if (ic.kind == CompKind.subcircuit) collectSub(ic.subcircuitName);
      }
    }
    for (final c in _clipboardComps) {
      if (c.kind == CompKind.subcircuit) collectSub(c.subcircuitName);
    }
    _clipboardSubcircuits = subs;
    _pasteCount = 0;
  }

  List<int> pasteClipboard() {
    if (_clipboardComps.isEmpty) return const [];
    _pasteCount++;
    final off = 2 * _pasteCount;
    final newIds = doc.pasteSnapshot(
      _clipboardComps,
      _clipboardWires,
      dx: off,
      dy: off,
      extraSubcircuits: _clipboardSubcircuits,
    );
    if (newIds.isEmpty) return const [];
    selectedCompIds
      ..clear()
      ..addAll(newIds);
    selectedCompId = newIds.last;
    return newIds;
  }

  void recordRecent(String title) {
    final json = doc.toJsonString();
    recentCircuits.removeWhere((e) => e.$1 == title);
    recentCircuits.insert(0, (title, json));
    if (recentCircuits.length > 5) recentCircuits.removeLast();
  }

  File? autoSaveFile() {
    try {
      String? dir;
      if (Platform.isWindows) {
        final base = Platform.environment['APPDATA'];
        if (base != null && base.isNotEmpty) dir = '$base/benchosc';
      } else {
        final xdg = Platform.environment['XDG_CONFIG_HOME'];
        final home = Platform.environment['HOME'];
        final base = (xdg != null && xdg.isNotEmpty)
            ? xdg
            : ((home != null && home.isNotEmpty) ? '$home/.config' : null);
        if (base != null) dir = '$base/benchosc';
      }
      // shortcut: uses systemTemp when HOME is unset on mobile; switch to path_provider on connected build.
      dir ??= '${Directory.systemTemp.path}/benchosc';
      Directory(dir).createSync(recursive: true);
      return File('$dir/benchosc_autosave.json');
    } catch (_) {
      return null;
    }
  }

  String toAutosaveJson() => jsonEncode({
        'version': 2,
        'activeTab': activeTabIdx,
        'tabs': [
          for (final t in tabs) {'title': t.title, 'doc': jsonDecode(t.doc.toJsonString())},
        ],
      });

  void loadAutosaveJson(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic> &&
        decoded['version'] == 2 &&
        decoded['tabs'] is List &&
        (decoded['tabs'] as List).isNotEmpty) {
      final loaded = <WorkspaceTab>[];
      for (final entry in decoded['tabs'] as List) {
        if (entry is! Map) continue;
        final d = CircuitDoc()..loadJsonString(jsonEncode(entry['doc']));
        final title = (entry['title'] as String?) ?? 'Sheet ${loaded.length + 1}';
        loaded.add(WorkspaceTab(d, title: title, savedRevision: d.revision));
      }
      if (loaded.isEmpty) throw const FormatException('Empty autosave tabs');
      tabs
        ..clear()
        ..addAll(loaded);
      final idx = (decoded['activeTab'] as num?)?.toInt() ?? 0;
      activeTabIdx = idx.clamp(0, tabs.length - 1);
      selectedCompId = null;
      selectedCompIds.clear();
      return;
    }
    doc.loadJsonString(raw);
    activeTab
      ..title = 'Recovered'
      ..savedRevision = doc.revision;
    clearSelection();
  }

  Future<void> _writeAutoSaveAtomic(String json, int seq) async {
    final file = autoSaveFile();
    if (file == null) return;
    final tmp = File('${file.path}.async.tmp');
    try {
      await tmp.writeAsString(json);
      if (seq != _saveSeq || _disposed) {
        if (await tmp.exists()) await tmp.delete();
        return;
      }
      await tmp.rename(file.path);
    } catch (_) {}
  }

  void flushPendingAutoSaveSync() {
    if (!_pendingAutoSave) return;
    _pendingAutoSave = false;
    final seq = ++_saveSeq;
    final file = autoSaveFile();
    if (file == null) return;
    try {
      final tmp = File('${file.path}.sync.tmp');
      tmp.writeAsStringSync(toAutosaveJson());
      if (seq == _saveSeq) tmp.renameSync(file.path);
    } catch (_) {}
  }

  void scheduleAutoSave() {
    _pendingAutoSave = true;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 2), () async {
      if (_disposed) return;
      _pendingAutoSave = false;
      final seq = ++_saveSeq;
      await _writeAutoSaveAtomic(toAutosaveJson(), seq);
    });
  }

  void dispose() {
    _disposed = true;
    _autoSaveTimer?.cancel();
    flushPendingAutoSaveSync();
  }
}
