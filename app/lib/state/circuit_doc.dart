import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import '../ffi/sim_ffi.dart';
import '../ffi/sim_isolate.dart';
import '../l10n/app_localizations.dart';
import 'parts_library.dart';
import 'subcircuits.dart';

part 'comp_catalog.dart';
part 'spice_codec.dart';

class PinRef {
  final int compId;
  final int pinIdx;
  const PinRef(this.compId, this.pinIdx);

  @override
  bool operator ==(Object other) =>
      other is PinRef && other.compId == compId && other.pinIdx == pinIdx;

  @override
  int get hashCode => Object.hash(compId, pinIdx);

  Map<String, dynamic> toJson() => {'c': compId, 'p': pinIdx};
  factory PinRef.fromJson(Map<String, dynamic> j) => PinRef(j['c'] as int, j['p'] as int);
}

class PlacedComponent {
  static const Object _unset = Object();

  final int id;
  final CompKind kind;
  final int gridX;
  final int gridY;
  final int rotation; // 0, 1, 2, 3 (* 90 deg)
  final bool flipX;
  final bool flipY;
  final List<double> params;
  final FaultType fault;
  final String? hexPattern;
  final String? subcircuitName;
  final int customPinCount;
  final String? hotkey;

  PlacedComponent({
    required this.id,
    required this.kind,
    required this.gridX,
    required this.gridY,
    this.rotation = 0,
    this.flipX = false,
    this.flipY = false,
    required this.params,
    this.fault = FaultType.none,
    this.hexPattern,
    this.subcircuitName,
    this.customPinCount = 0,
    this.hotkey,
  });

  CompMeta get meta => kCompMeta[kind]!;

  List<Offset> get pinOffsets {
    if (kind != CompKind.subcircuit || customPinCount <= 0) {
      return meta.pinOffsets;
    }
    final n = customPinCount.clamp(1, 8);
    final left = (n + 1) ~/ 2;
    final right = n - left;
    return [
      for (var i = 0; i < n; i++)
        i < left
            ? Offset(-2, (i - (left ~/ 2)).toDouble())
            : Offset(2, ((i - left) - (right ~/ 2)).toDouble()),
    ];
  }

  Offset pinGridPos(int pinIdx) {
    final base = pinOffsets[pinIdx];
    final fx = flipX ? -base.dx : base.dx;
    final fy = flipY ? -base.dy : base.dy;
    final rot = rotation % 4;
    final rotated = switch (rot) {
      1 => Offset(-fy, fx),
      2 => Offset(-fx, -fy),
      3 => Offset(fy, -fx),
      _ => Offset(fx, fy),
    };
    return Offset(gridX + rotated.dx, gridY + rotated.dy);
  }

  PlacedComponent copyWith({
    int? gridX,
    int? gridY,
    int? rotation,
    bool? flipX,
    bool? flipY,
    List<double>? params,
    FaultType? fault,
    String? hexPattern,
    String? subcircuitName,
    int? customPinCount,
    Object? hotkey = _unset,
  }) {
    return PlacedComponent(
      id: id,
      kind: kind,
      gridX: gridX ?? this.gridX,
      gridY: gridY ?? this.gridY,
      rotation: rotation ?? this.rotation,
      flipX: flipX ?? this.flipX,
      flipY: flipY ?? this.flipY,
      params: params ?? List<double>.from(this.params),
      fault: fault ?? this.fault,
      hexPattern: hexPattern ?? this.hexPattern,
      subcircuitName: subcircuitName ?? this.subcircuitName,
      customPinCount: customPinCount ?? this.customPinCount,
      hotkey: identical(hotkey, _unset) ? this.hotkey : hotkey as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'x': gridX,
        'y': gridY,
        'rot': rotation,
        if (flipX) 'fx': true,
        if (flipY) 'fy': true,
        'params': [for (final v in params) v.isFinite ? v : null],
        'fault': fault.name,
        if (hexPattern != null) 'hex': hexPattern,
        if (subcircuitName != null) 'sub': subcircuitName,
        if (customPinCount > 0) 'pins': customPinCount,
        if (hotkey != null && hotkey!.isNotEmpty) 'hotkey': hotkey,
      };

  factory PlacedComponent.fromJson(Map<String, dynamic> j) {
    final kind = CompKind.values.firstWhere((e) => e.name == j['kind']);
    final fault = FaultType.values.firstWhere(
      (e) => e.name == (j['fault'] ?? 'none'),
      orElse: () => FaultType.none,
    );
    final rawX = j['x'];
    final rawY = j['y'];
    if (rawX is! int || rawY is! int) {
      throw const FormatException('Invalid component coordinates');
    }
    final defaults = kCompMeta[kind]!.defaults;
    final rawParams = (j['params'] as List<dynamic>?) ?? const [];
    final params = <double>[
      for (var i = 0; i < defaults.length || i < rawParams.length; i++)
        if (i < rawParams.length && rawParams[i] is num)
          ((rawParams[i] as num).toDouble().isFinite
              ? (rawParams[i] as num).toDouble()
              : (i < defaults.length ? defaults[i] : 0.0))
        else
          (i < defaults.length ? defaults[i] : 0.0),
    ];
    final rawKey = j['hotkey'] as String?;
    return PlacedComponent(
      id: j['id'] as int,
      kind: kind,
      gridX: rawX.clamp(-500, 500),
      gridY: rawY.clamp(-500, 500),
      rotation: ((j['rot'] as int?) ?? 0) % 4,
      flipX: (j['fx'] as bool?) ?? false,
      flipY: (j['fy'] as bool?) ?? false,
      params: params,
      fault: fault,
      hexPattern: j['hex'] as String?,
      subcircuitName: j['sub'] as String?,
      customPinCount: ((j['pins'] as int?) ?? 0).clamp(0, 8),
      hotkey: (rawKey != null && rawKey.trim().isNotEmpty) ? rawKey.trim().toUpperCase()[0] : null,
    );
  }
}

class SchematicNote {
  final int id;
  final int gridX;
  final int gridY;
  final String text;
  const SchematicNote({
    required this.id,
    required this.gridX,
    required this.gridY,
    required this.text,
  });

  Map<String, dynamic> toJson() => {'id': id, 'x': gridX, 'y': gridY, 'text': text};
  factory SchematicNote.fromJson(Map<String, dynamic> j) => SchematicNote(
        id: j['id'] as int,
        gridX: (j['x'] as int).clamp(-500, 500),
        gridY: (j['y'] as int).clamp(-500, 500),
        text: (j['text'] as String).trim(),
      );
}

class WireLink {
  final PinRef from;
  final PinRef to;
  final int? bendX;
  const WireLink(this.from, this.to, {this.bendX});

  Map<String, dynamic> toJson() => {
        'from': from.toJson(),
        'to': to.toJson(),
        if (bendX != null) 'bendX': bendX,
      };
  factory WireLink.fromJson(Map<String, dynamic> j) => WireLink(
        PinRef.fromJson(j['from'] as Map<String, dynamic>),
        PinRef.fromJson(j['to'] as Map<String, dynamic>),
        bendX: j['bendX'] as int?,
      );
}

class _Snapshot {
  final List<PlacedComponent> components;
  final List<WireLink> wires;
  final List<SchematicNote> notes;
  final Map<String, SubcircuitDef> subcircuits;
  final PinRef? ch1;
  final PinRef? ch2;
  final PinRef? ch3;
  final PinRef? ch4;
  final int nextId;
  _Snapshot(
    this.components,
    this.wires,
    this.notes,
    this.subcircuits,
    this.ch1,
    this.ch2,
    this.ch3,
    this.ch4,
    this.nextId,
  );
}

class CircuitDoc {
  List<PlacedComponent> components = [];
  List<WireLink> wires = [];
  List<SchematicNote> notes = [];
  final Map<String, SubcircuitDef> subcircuits = {};
  PinRef? probeCh1;
  PinRef? probeCh2;
  PinRef? probeCh3;
  PinRef? probeCh4;
  int _nextId = 1;
  int revision = 0;
  int _maxNode = 1;

  final List<_Snapshot> _undo = [];
  final List<_Snapshot> _redo = [];

  /// Resolved electrical node id (`0` = GND) for each `(compId, pinIdx)` after `syncToSim`.
  final Map<PinRef, int> resolvedNodes = {};

  /// Maps synthetic FFI component ids inside expanded subcircuits back to their top-level subcircuit component id.
  final Map<int, int> subcircuitChildParent = {};

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  _Snapshot _capture() => _Snapshot(
        components.map((c) => c.copyWith()).toList(),
        List<WireLink>.from(wires),
        List<SchematicNote>.from(notes),
        Map<String, SubcircuitDef>.from(subcircuits),
        probeCh1,
        probeCh2,
        probeCh3,
        probeCh4,
        _nextId,
      );

  void _restore(_Snapshot snap) {
    components = snap.components;
    wires = snap.wires;
    notes = snap.notes;
    subcircuits
      ..clear()
      ..addAll(snap.subcircuits);
    probeCh1 = snap.ch1;
    probeCh2 = snap.ch2;
    probeCh3 = snap.ch3;
    probeCh4 = snap.ch4;
    _nextId = snap.nextId;
    revision++;
  }

  void _pushUndo() {
    revision++;
    _undo.add(_capture());
    if (_undo.length > 50) _undo.removeAt(0);
    _redo.clear();
  }

  /// Captures an undo snapshot before interactive slider drags or dialog parameter edits.
  void recordUndoSnapshot() => _pushUndo();

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_capture());
    _restore(_undo.removeLast());
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_capture());
    _restore(_redo.removeLast());
  }

  PlacedComponent addComponent(CompKind kind, int gridX, int gridY, {bool recordUndo = true}) {
    if (recordUndo) _pushUndo();
    final meta = kCompMeta[kind]!;
    final c = PlacedComponent(
      id: _nextId++,
      kind: kind,
      gridX: gridX,
      gridY: gridY,
      params: List<double>.from(meta.defaults),
    );
    components.add(c);
    return c;
  }

  void moveComponent(int compId, int gridX, int gridY, {bool recordUndo = false}) {
    final idx = components.indexWhere((c) => c.id == compId);
    if (idx < 0) return;
    if (recordUndo) _pushUndo();
    components[idx] = components[idx].copyWith(gridX: gridX, gridY: gridY);
    revision++;
  }

  void rotateComponent(int compId) => rotateComponents({compId});

  void rotateComponents(Set<int> ids) {
    if (ids.isEmpty || !components.any((c) => ids.contains(c.id))) return;
    _pushUndo();
    for (var i = 0; i < components.length; i++) {
      if (ids.contains(components[i].id)) {
        components[i] = components[i].copyWith(rotation: (components[i].rotation + 1) % 4);
      }
    }
  }

  void flipComponent(int compId, {bool vertical = false}) =>
      flipComponents({compId}, vertical: vertical);

  void flipComponents(Set<int> ids, {bool vertical = false}) {
    if (ids.isEmpty || !components.any((c) => ids.contains(c.id))) return;
    _pushUndo();
    for (var i = 0; i < components.length; i++) {
      final c = components[i];
      if (ids.contains(c.id)) {
        components[i] = c.copyWith(
          flipX: vertical ? c.flipX : !c.flipX,
          flipY: vertical ? !c.flipY : c.flipY,
        );
      }
    }
  }

  PlacedComponent addPartPreset(PartPreset part, int gx, int gy) {
    final c = addComponent(part.kind, gx, gy);
    final nextParams = List<double>.from(c.params);
    part.paramOverrides.forEach((idx, val) {
      if (idx >= 0 && idx < nextParams.length) nextParams[idx] = val;
    });
    final idx = components.indexWhere((e) => e.id == c.id);
    if (idx >= 0) {
      components[idx] = components[idx].copyWith(params: nextParams);
      return components[idx];
    }
    return c;
  }

  PlacedComponent? placeSubcircuit(String name, int gx, int gy, {bool recordUndo = true}) {
    final def = subcircuits[name];
    if (def == null) return null;
    if (recordUndo) _pushUndo();
    final c = PlacedComponent(
      id: _nextId++,
      kind: CompKind.subcircuit,
      gridX: gx,
      gridY: gy,
      params: const [],
      subcircuitName: name,
      customPinCount: def.externalPins.length,
    );
    components.add(c);
    revision++;
    return c;
  }

  bool ungroupSubcircuit(int subCompId) {
    final idx = components.indexWhere((c) => c.id == subCompId);
    if (idx < 0) return false;
    final subComp = components[idx];
    if (subComp.kind != CompKind.subcircuit) return false;
    final def = subcircuits[subComp.subcircuitName];
    if (def == null || def.components.isEmpty) return false;

    _pushUndo();
    final cx = (def.components.fold<int>(0, (s, c) => s + c.gridX) / def.components.length).round();
    final cy = (def.components.fold<int>(0, (s, c) => s + c.gridY) / def.components.length).round();
    final dx = subComp.gridX - cx;
    final dy = subComp.gridY - cy;

    components.removeAt(idx);
    final (idMap, _) = _cloneSubgraph(def.components, def.wires, dx, dy);

    PinRef? remapBoundary(PinRef r) {
      if (r.compId != subCompId) return r;
      if (r.pinIdx < 0 || r.pinIdx >= def.externalPins.length) return null;
      final inner = def.externalPins[r.pinIdx];
      final nid = idMap[inner.compId];
      return nid != null ? PinRef(nid, inner.pinIdx) : null;
    }

    final nextWires = <WireLink>[];
    for (final w in wires) {
      final f = remapBoundary(w.from);
      final t = remapBoundary(w.to);
      if (f != null && t != null) {
        nextWires.add(WireLink(f, t, bendX: w.bendX));
      }
    }
    wires = nextWires;
    if (probeCh1 != null) probeCh1 = remapBoundary(probeCh1!);
    if (probeCh2 != null) probeCh2 = remapBoundary(probeCh2!);
    if (probeCh3 != null) probeCh3 = remapBoundary(probeCh3!);
    if (probeCh4 != null) probeCh4 = remapBoundary(probeCh4!);
    revision++;
    return true;
  }

  void clearCanvas({bool keepSubcircuits = true}) {
    _pushUndo();
    components.clear();
    wires.clear();
    notes.clear();
    if (!keepSubcircuits) subcircuits.clear();
    probeCh1 = null;
    probeCh2 = null;
    probeCh3 = null;
    probeCh4 = null;
    revision++;
  }

  void setComponentHotkey(int compId, String? rawKey) {
    final idx = components.indexWhere((c) => c.id == compId);
    if (idx < 0) return;
    final clean = (rawKey ?? '').trim().toUpperCase();
    final key = clean.isEmpty ? null : (RegExp(r'^[A-Z0-9]$').hasMatch(clean[0]) ? clean[0] : null);
    if (components[idx].hotkey == key) return;
    _pushUndo();
    components[idx] = components[idx].copyWith(hotkey: key);
  }

  void alignComponents(Set<int> ids, {bool horizontalAxis = true}) {
    final sel = components.where((c) => ids.contains(c.id)).toList();
    if (sel.length < 2) return;
    _pushUndo();
    final avg = (sel.fold<int>(0, (s, c) => s + (horizontalAxis ? c.gridY : c.gridX)) / sel.length).round();
    for (var i = 0; i < components.length; i++) {
      if (ids.contains(components[i].id)) {
        components[i] = horizontalAxis
            ? components[i].copyWith(gridY: avg)
            : components[i].copyWith(gridX: avg);
      }
    }
  }

  PinRef? splitWireAtGrid(int wireIdx, int gx, int gy, {bool recordUndo = true}) {
    if (wireIdx < 0 || wireIdx >= wires.length) return null;
    if (recordUndo) _pushUndo();
    final orig = wires.removeAt(wireIdx);
    final jId = _nextId++;
    components.add(PlacedComponent(
      id: jId,
      kind: CompKind.netPort,
      gridX: gx + 1,
      gridY: gy,
      params: const [],
      hexPattern: 'J$jId',
    ));
    final jPin = PinRef(jId, 0);
    wires.add(WireLink(orig.from, jPin));
    wires.add(WireLink(jPin, orig.to));
    revision++;
    return jPin;
  }

  void addNote(int gx, int gy, String text) {
    final clean = text.trim();
    if (clean.isEmpty) return;
    _pushUndo();
    notes.add(SchematicNote(id: _nextId++, gridX: gx, gridY: gy, text: clean));
  }

  void updateNote(int noteId, String text) {
    final clean = text.trim();
    if (clean.isEmpty) {
      deleteNote(noteId);
      return;
    }
    final idx = notes.indexWhere((n) => n.id == noteId);
    if (idx < 0) return;
    _pushUndo();
    final old = notes[idx];
    notes[idx] = SchematicNote(id: old.id, gridX: old.gridX, gridY: old.gridY, text: clean);
  }

  void moveNote(int noteId, int gx, int gy, {bool recordUndo = false}) {
    final idx = notes.indexWhere((n) => n.id == noteId);
    if (idx < 0) return;
    if (recordUndo) _pushUndo();
    final old = notes[idx];
    notes[idx] = SchematicNote(id: old.id, gridX: gx, gridY: gy, text: old.text);
    revision++;
  }

  void deleteNote(int noteId) {
    if (!notes.any((n) => n.id == noteId)) return;
    _pushUndo();
    notes.removeWhere((n) => n.id == noteId);
    revision++;
  }

  void deleteComponent(int compId) => deleteComponents({compId});

  void deleteComponents(Set<int> ids) {
    if (ids.isEmpty) return;
    _pushUndo();
    components.removeWhere((c) => ids.contains(c.id));
    wires.removeWhere((w) => ids.contains(w.from.compId) || ids.contains(w.to.compId));
    if (probeCh1 != null && ids.contains(probeCh1!.compId)) probeCh1 = null;
    if (probeCh2 != null && ids.contains(probeCh2!.compId)) probeCh2 = null;
    if (probeCh3 != null && ids.contains(probeCh3!.compId)) probeCh3 = null;
    if (probeCh4 != null && ids.contains(probeCh4!.compId)) probeCh4 = null;
  }

  (Map<int, int>, List<int>) _cloneSubgraph(
    Iterable<PlacedComponent> srcComps,
    Iterable<WireLink> srcWires,
    int dx,
    int dy,
  ) {
    final idMap = <int, int>{};
    final newIds = <int>[];
    for (final src in srcComps) {
      final newId = _nextId++;
      idMap[src.id] = newId;
      newIds.add(newId);
      final isAutoJunction =
          src.kind == CompKind.netPort && (src.hexPattern ?? '').startsWith('J');
      components.add(PlacedComponent(
        id: newId,
        kind: src.kind,
        gridX: src.gridX + dx,
        gridY: src.gridY + dy,
        rotation: src.rotation,
        flipX: src.flipX,
        flipY: src.flipY,
        params: List<double>.from(src.params),
        fault: src.fault,
        hexPattern: isAutoJunction ? 'J$newId' : src.hexPattern,
        subcircuitName: src.subcircuitName,
        customPinCount: src.customPinCount,
        hotkey: src.hotkey,
      ));
    }
    for (final w in srcWires) {
      final newFrom = idMap[w.from.compId];
      final newTo = idMap[w.to.compId];
      if (newFrom != null && newTo != null) {
        wires.add(WireLink(
          PinRef(newFrom, w.from.pinIdx),
          PinRef(newTo, w.to.pinIdx),
        ));
      }
    }
    return (idMap, newIds);
  }

  List<int> duplicateComponents(Set<int> ids, {int dx = 2, int dy = 2}) {
    final sources = components.where((c) => ids.contains(c.id)).toList();
    if (sources.isEmpty) return [];
    _pushUndo();
    return _cloneSubgraph(sources, wires.toList(), dx, dy).$2;
  }

  /// Packages selected components & internal wires into a reusable subcircuit block.
  SubcircuitDef? createSubcircuitFromSelection(Set<int> ids, String rawName) {
    final name = rawName.trim();
    if (ids.length < 2 || name.isEmpty) return null;
    final selected = components.where((c) => ids.contains(c.id)).toList();
    if (selected.length < 2) return null;

    _pushUndo();
    final innerWires = <WireLink>[];
    final extPins = <PinRef>[];
    final boundaryWires = <(WireLink wire, bool fromInside)>[];

    for (final w in wires) {
      final fIn = ids.contains(w.from.compId);
      final tIn = ids.contains(w.to.compId);
      if (fIn && tIn) {
        innerWires.add(w);
      } else if (fIn != tIn) {
        final insidePin = fIn ? w.from : w.to;
        if (!extPins.contains(insidePin) && extPins.length < 8) {
          extPins.add(insidePin);
        }
        boundaryWires.add((w, fIn));
      }
    }
    if (extPins.isEmpty) {
      for (final c in selected) {
        for (var p = 0; p < c.pinOffsets.length && extPins.length < 8; p++) {
          extPins.add(PinRef(c.id, p));
        }
      }
    }

    final def = SubcircuitDef(
      name: name,
      components: selected.map((c) => c.copyWith()).toList(),
      wires: innerWires,
      externalPins: extPins,
      pinLabels: [for (var i = 0; i < extPins.length; i++) 'P${i + 1}'],
    );
    subcircuits[name] = def;

    final cx = (selected.map((c) => c.gridX).reduce((a, b) => a + b) / selected.length).round();
    final cy = (selected.map((c) => c.gridY).reduce((a, b) => a + b) / selected.length).round();
    components.removeWhere((c) => ids.contains(c.id));
    wires.removeWhere((w) => ids.contains(w.from.compId) || ids.contains(w.to.compId));

    final subComp = PlacedComponent(
      id: _nextId++,
      kind: CompKind.subcircuit,
      gridX: cx,
      gridY: cy,
      params: const [],
      subcircuitName: name,
      customPinCount: extPins.length,
    );
    components.add(subComp);

    for (final (w, fromInside) in boundaryWires) {
      final insidePin = fromInside ? w.from : w.to;
      final extIdx = extPins.indexOf(insidePin);
      if (extIdx >= 0) {
        final newPin = PinRef(subComp.id, extIdx);
        wires.add(WireLink(
          fromInside ? newPin : w.from,
          fromInside ? w.to : newPin,
          bendX: w.bendX,
        ));
      }
    }
    revision++;
    return def;
  }

  void addWire(PinRef a, PinRef b, {bool recordUndo = true}) {
    if (a == b) return;
    final exists = wires.any((w) => (w.from == a && w.to == b) || (w.from == b && w.to == a));
    if (exists) return;
    if (recordUndo) _pushUndo();
    wires.add(WireLink(a, b));
    revision++;
  }

  /// Pastes a deep snapshot of components and internal wires at offset `(dx, dy)`.
  List<int> pasteSnapshot(
    List<PlacedComponent> comps,
    List<WireLink> internalWires, {
    int dx = 2,
    int dy = 2,
  }) {
    if (comps.isEmpty) return [];
    _pushUndo();
    final (_, newIds) = _cloneSubgraph(comps, internalWires, dx, dy);
    revision++;
    return newIds;
  }

  void deleteWireAt(int index) {
    if (index < 0 || index >= wires.length) return;
    _pushUndo();
    wires.removeAt(index);
  }

  void moveWireBend(int index, int bendX, {bool recordUndo = false}) {
    if (index < 0 || index >= wires.length) return;
    if (recordUndo) _pushUndo();
    wires[index] = WireLink(wires[index].from, wires[index].to, bendX: bendX);
    revision++;
  }

  void updateParam(int compId, int paramIdx, double value) {
    final idx = components.indexWhere((c) => c.id == compId);
    if (idx < 0) return;
    final params = List<double>.from(components[idx].params);
    if (paramIdx < params.length) {
      params[paramIdx] = value;
      components[idx] = components[idx].copyWith(params: params);
      revision++;
    }
  }

  static int? parseHexPattern64(String? hex) {
    final clean = (hex ?? '').trim().replaceFirst(RegExp(r'^0x', caseSensitive: false), '');
    if (clean.isEmpty || clean.length > 16) return null;
    final bi = BigInt.tryParse(clean, radix: 16);
    if (bi == null) return null;
    return bi.toUnsigned(64).toSigned(64).toInt();
  }

  bool updateWordGenHex(int compId, String hex) {
    final clean = hex.trim().replaceFirst(RegExp(r'^0x', caseSensitive: false), '').toUpperCase();
    if (parseHexPattern64(clean) == null) return false;
    final idx = components.indexWhere((c) => c.id == compId);
    if (idx < 0) return false;
    _pushUndo();
    components[idx] = components[idx].copyWith(hexPattern: clean);
    revision++;
    return true;
  }

  bool updateNetPortLabel(int compId, String rawLabel) {
    final clean = rawLabel.trim().replaceAll(RegExp(r'\s+'), '_').toUpperCase();
    if (clean.isEmpty) return false;
    final idx = components.indexWhere((c) => c.id == compId);
    if (idx < 0 || components[idx].kind != CompKind.netPort) return false;
    _pushUndo();
    components[idx] = components[idx].copyWith(hexPattern: clean);
    revision++;
    return true;
  }

  void updateFault(int compId, FaultType fault) {
    final idx = components.indexWhere((c) => c.id == compId);
    if (idx < 0) return;
    _pushUndo();
    components[idx] = components[idx].copyWith(fault: fault);
  }

  /// Finds the primary AC/FunctionGen source id and CH2 node id for AC sweep Bode plots.
  (int?, int?) findAcSweepTarget() {
    int? acId;
    for (final c in components) {
      if (c.kind == CompKind.acSource || c.kind == CompKind.funcGen) {
        acId = c.id;
        break;
      }
    }
    final outNode = probeCh2 != null ? resolvedNodes[probeCh2!] : null;
    return (acId, outNode);
  }

  /// Finds the preferred or first sweepable DC source/control component id.
  int? findDcSweepSource({int? preferredId}) {
    bool isSweepable(PlacedComponent c) =>
        c.kind == CompKind.dcSource ||
        c.kind == CompKind.dcCurrent ||
        c.kind == CompKind.potentiometer ||
        c.kind == CompKind.powerRail;
    if (preferredId != null && components.any((c) => c.id == preferredId && isSweepable(c))) {
      return preferredId;
    }
    return components.where((c) => c.kind == CompKind.dcSource).firstOrNull?.id ??
        components.where(isSweepable).firstOrNull?.id;
  }

  /// Resolves electrical connectivity nets (`0` = GND) across components, wires, and named NetPorts.
  void resolveNets() {
    resolvedNodes.clear();

    final parent = <PinRef, PinRef>{};
    final posMap = <String, PinRef>{};
    final netPortMap = <String, PinRef>{};

    PinRef find(PinRef x) {
      var cur = x;
      while (parent[cur] != cur) {
        parent[cur] = parent[parent[cur]!]!;
        cur = parent[cur]!;
      }
      return cur;
    }

    void union(PinRef a, PinRef b) {
      final ra = find(a);
      final rb = find(b);
      if (ra != rb) parent[rb] = ra;
    }

    for (final c in components) {
      for (var p = 0; p < c.pinOffsets.length; p++) {
        final ref = PinRef(c.id, p);
        parent[ref] = ref;
        final pos = c.pinGridPos(p);
        final key = '${pos.dx.round()},${pos.dy.round()}';
        final existing = posMap[key];
        if (existing != null) {
          union(existing, ref);
        } else {
          posMap[key] = ref;
        }
      }
      if (c.kind == CompKind.netPort && c.pinOffsets.isNotEmpty) {
        final label = (c.hexPattern ?? 'NET').trim().toUpperCase();
        final ref = PinRef(c.id, 0);
        final first = netPortMap[label];
        if (first != null) {
          union(first, ref);
        } else {
          netPortMap[label] = ref;
        }
      }
    }

    for (final w in wires) {
      if (parent.containsKey(w.from) && parent.containsKey(w.to)) {
        union(w.from, w.to);
      }
    }

    final gndRoots = <PinRef>{};
    for (final c in components) {
      if (c.kind == CompKind.ground) {
        gndRoots.add(find(PinRef(c.id, 0)));
      } else if (c.kind == CompKind.netPort) {
        final lbl = (c.hexPattern ?? '').trim().toUpperCase();
        if (lbl == 'GND' || lbl == '0') gndRoots.add(find(PinRef(c.id, 0)));
      }
    }

    final rootToNode = <PinRef, int>{};
    var nextNode = 1;
    for (final c in components) {
      for (var p = 0; p < c.pinOffsets.length; p++) {
        final ref = PinRef(c.id, p);
        final root = find(ref);
        final nodeId = gndRoots.contains(root)
            ? 0
            : rootToNode.putIfAbsent(root, () => nextNode++);
        resolvedNodes[ref] = nodeId;
      }
    }
    _maxNode = nextNode;
  }

  (Map<PinRef, int>, int, List<(int, int)>) _resolveSubcircuitNodes(
    SubcircuitDef def,
    List<int> extPinNodes,
    int startInternalNode,
  ) {
    final subParent = <PinRef, PinRef>{};
    PinRef sFind(PinRef x) {
      var cur = x;
      while (subParent[cur] != cur) {
        subParent[cur] = subParent[subParent[cur]!]!;
        cur = subParent[cur]!;
      }
      return cur;
    }

    void sUnion(PinRef a, PinRef b) {
      final ra = sFind(a);
      final rb = sFind(b);
      if (ra != rb) subParent[rb] = ra;
    }

    final subPos = <String, PinRef>{};
    final subNetPorts = <String, PinRef>{};
    for (final ic in def.components) {
      for (var p = 0; p < ic.pinOffsets.length; p++) {
        final r = PinRef(ic.id, p);
        subParent[r] = r;
        final pt = ic.pinGridPos(p);
        final k = '${pt.dx.round()},${pt.dy.round()}';
        final ex = subPos[k];
        if (ex != null) {
          sUnion(ex, r);
        } else {
          subPos[k] = r;
        }
      }
      if (ic.kind == CompKind.netPort && ic.pinOffsets.isNotEmpty) {
        final label = (ic.hexPattern ?? 'NET').trim().toUpperCase();
        final nr = PinRef(ic.id, 0);
        final first = subNetPorts[label];
        if (first != null) {
          sUnion(first, nr);
        } else {
          subNetPorts[label] = nr;
        }
      }
    }
    for (final w in def.wires) {
      if (subParent.containsKey(w.from) && subParent.containsKey(w.to)) {
        sUnion(w.from, w.to);
      }
    }
    final extRootNode = <PinRef, int>{};
    final tiePairs = <(int, int)>[];
    for (var k = 0; k < def.externalPins.length; k++) {
      final innerPin = def.externalPins[k];
      if (subParent.containsKey(innerPin)) {
        final root = sFind(innerPin);
        final extN = k < extPinNodes.length ? extPinNodes[k] : 0;
        final prev = extRootNode[root];
        if (prev == null) {
          extRootNode[root] = extN;
        } else if (prev != extN) {
          tiePairs.add((prev, extN));
        }
      }
    }
    for (final ic in def.components) {
      if (ic.kind == CompKind.ground) {
        final root = sFind(PinRef(ic.id, 0));
        final prev = extRootNode[root];
        if (prev != null && prev != 0) tiePairs.add((prev, 0));
        extRootNode[root] = 0;
      } else if (ic.kind == CompKind.netPort) {
        final lbl = (ic.hexPattern ?? '').trim().toUpperCase();
        if (lbl == 'GND' || lbl == '0') {
          final root = sFind(PinRef(ic.id, 0));
          final prev = extRootNode[root];
          if (prev != null && prev != 0) tiePairs.add((prev, 0));
          extRootNode[root] = 0;
        }
      }
    }
    final subNodes = <PinRef, int>{};
    var nextInternal = startInternalNode;
    for (final ic in def.components) {
      for (var p = 0; p < ic.pinOffsets.length; p++) {
        final r = PinRef(ic.id, p);
        final root = sFind(r);
        subNodes[r] = extRootNode.putIfAbsent(root, () => nextInternal++);
      }
    }
    return (subNodes, nextInternal, tiePairs);
  }

  List<IsolateCompSpec> _buildFfiSpecs() {
    final specs = <IsolateCompSpec>[];
    subcircuitChildParent.clear();
    var nextSubNode = _maxNode + 1000;
    var nextSubId = 100000;

    void emitComponent(
      PlacedComponent c,
      Map<PinRef, int> nodeLookup,
      int idOverride, {
      int? rootOwnerId,
      Set<String> activeSubs = const {},
      int depth = 0,
    }) {
      if (c.kind == CompKind.ground || c.kind == CompKind.netPort) return;
      if (rootOwnerId != null && c.kind != CompKind.subcircuit) {
        subcircuitChildParent[idOverride] = rootOwnerId;
      }
      if (c.kind == CompKind.powerRail) {
        specs.add(IsolateCompSpec(
          id: idOverride,
          ffiType: 10,
          nodes: [nodeLookup[PinRef(c.id, 0)] ?? 0, 0],
          params: List<double>.from(c.params),
          faultIndex: c.fault.index,
        ));
        return;
      }
      if (c.kind == CompKind.subcircuit) {
        if (depth >= 8 || c.subcircuitName == null || activeSubs.contains(c.subcircuitName)) {
          return;
        }
        final def = subcircuits[c.subcircuitName];
        if (def == null) return;
        final owner = rootOwnerId ?? c.id;
        final extNodes = [
          for (var k = 0; k < def.externalPins.length; k++) nodeLookup[PinRef(c.id, k)] ?? 0,
        ];
        final (subNodes, updatedNext, tiePairs) = _resolveSubcircuitNodes(def, extNodes, nextSubNode);
        nextSubNode = updatedNext;
        for (final (na, nb) in tiePairs) {
          final tieId = nextSubId++;
          subcircuitChildParent[tieId] = owner;
          specs.add(IsolateCompSpec(id: tieId, ffiType: 1, nodes: [na, nb], params: const [1e-3]));
        }
        final nextActiveSubs = {...activeSubs, def.name};
        for (final ic in def.components) {
          emitComponent(
            ic,
            subNodes,
            nextSubId++,
            rootOwnerId: owner,
            activeSubs: nextActiveSubs,
            depth: depth + 1,
          );
        }
        return;
      }

      final pins = <int>[
        for (var p = 0; p < c.pinOffsets.length; p++) nodeLookup[PinRef(c.id, p)] ?? 0,
      ];
      final wgBits =
          c.kind == CompKind.wordGen && c.hexPattern != null ? parseHexPattern64(c.hexPattern) : null;
      specs.add(IsolateCompSpec(
        id: idOverride,
        ffiType: c.meta.ffiType,
        nodes: pins,
        params: List<double>.from(c.params),
        wordGenBits: wgBits,
        faultIndex: c.fault.index,
      ));
    }

    for (final c in components) {
      emitComponent(c, resolvedNodes, c.id);
    }
    return specs;
  }

  (List<IsolateCompSpec>, List<int>, List<int>) buildIsolatePayload() {
    resolveNets();
    final specs = _buildFfiSpecs();
    final probes = <int>[
      probeCh1 != null ? (resolvedNodes[probeCh1!] ?? -1) : -1,
      probeCh2 != null ? (resolvedNodes[probeCh2!] ?? -1) : -1,
      probeCh3 != null ? (resolvedNodes[probeCh3!] ?? -1) : -1,
      probeCh4 != null ? (resolvedNodes[probeCh4!] ?? -1) : -1,
    ];
    return (specs, probes, resolvedNodes.values.toSet().toList());
  }

  /// Compiles schematic pins & wires via Union-Find and loads them into `SimFfi`.
  (int, int) syncToSim(SimFfi sim) {
    sim.clear();
    resolveNets();

    for (final spec in _buildFfiSpecs()) {
      final rc = sim.addComponentEx(
        id: spec.id,
        type: spec.ffiType,
        pins: spec.nodes,
        params: spec.params,
      );
      if (rc != 0) return sim.lastError();
      if (spec.wordGenBits != null) {
        sim.setWordGenPattern(spec.id, spec.wordGenBits!);
      }
      if (spec.faultIndex != 0) {
        sim.setFault(spec.id, spec.faultIndex);
      }
    }

    sim.setScopeProbe(0, probeCh1 != null ? (resolvedNodes[probeCh1!] ?? -1) : -1);
    sim.setScopeProbe(1, probeCh2 != null ? (resolvedNodes[probeCh2!] ?? -1) : -1);
    sim.setScopeProbe(2, probeCh3 != null ? (resolvedNodes[probeCh3!] ?? -1) : -1);
    sim.setScopeProbe(3, probeCh4 != null ? (resolvedNodes[probeCh4!] ?? -1) : -1);

    final dcErr = sim.solveDc();
    if (dcErr != 0) return sim.lastError();
    return (0, 0);
  }

  void loadPreset(PresetKind preset) {
    _undo.clear();
    _redo.clear();
    components.clear();
    wires.clear();
    notes.clear();
    subcircuits.clear();
    probeCh3 = null;
    probeCh4 = null;
    _nextId = 1;

    switch (preset) {
      case PresetKind.rcFilter:
        final fg = addComponent(CompKind.funcGen, 4, 6); // id 1: pin0=top, pin1=bot
        final g1 = addComponent(CompKind.ground, 4, 9); // id 2
        final pot = addComponent(CompKind.potentiometer, 9, 4); // id 3
        final g2 = addComponent(CompKind.ground, 9, 7); // id 4
        final cap = addComponent(CompKind.capacitor, 14, 4); // id 5
        final g3 = addComponent(CompKind.ground, 16, 5); // id 6
        wires.addAll([
          WireLink(PinRef(fg.id, 1), PinRef(g1.id, 0)),
          WireLink(PinRef(fg.id, 0), PinRef(pot.id, 0)),
          WireLink(PinRef(pot.id, 1), PinRef(g2.id, 0)),
          WireLink(PinRef(pot.id, 2), PinRef(cap.id, 0)),
          WireLink(PinRef(cap.id, 1), PinRef(g3.id, 0)),
        ]);
        probeCh1 = PinRef(fg.id, 0);
        probeCh2 = PinRef(cap.id, 0);
      case PresetKind.rectifier:
        final ac = addComponent(CompKind.acSource, 4, 6);
        final g1 = addComponent(CompKind.ground, 4, 9);
        final d = addComponent(CompKind.diode, 9, 4);
        final r = addComponent(CompKind.resistor, 14, 4);
        final c = addComponent(CompKind.capacitor, 14, 7);
        final g2 = addComponent(CompKind.ground, 16, 9);
        wires.addAll([
          WireLink(PinRef(ac.id, 1), PinRef(g1.id, 0)),
          WireLink(PinRef(ac.id, 0), PinRef(d.id, 0)),
          WireLink(PinRef(d.id, 1), PinRef(r.id, 0)),
          WireLink(PinRef(d.id, 1), PinRef(c.id, 0)),
          WireLink(PinRef(r.id, 1), PinRef(g2.id, 0)),
          WireLink(PinRef(c.id, 1), PinRef(g2.id, 0)),
        ]);
        probeCh1 = PinRef(ac.id, 0);
        probeCh2 = PinRef(d.id, 1);
      case PresetKind.opAmp:
        final fg = addComponent(CompKind.funcGen, 3, 6);
        final g1 = addComponent(CompKind.ground, 3, 9);
        final rin = addComponent(CompKind.resistor, 7, 4);
        final op = addComponent(CompKind.opAmp, 12, 5);
        final g2 = addComponent(CompKind.ground, 10, 8);
        final rf = addComponent(CompKind.resistor, 12, 2);
        // OpAmp pins: 0=in+, 1=in-, 2=out
        // Note: in- is (10, 6), in+ is (10, 4). Tie in+ to GND and in- to Rin/Rf.
        wires.addAll([
          WireLink(PinRef(fg.id, 1), PinRef(g1.id, 0)),
          WireLink(PinRef(fg.id, 0), PinRef(rin.id, 0)),
          WireLink(PinRef(rin.id, 1), PinRef(op.id, 1)),
          WireLink(PinRef(op.id, 0), PinRef(g2.id, 0)),
          WireLink(PinRef(op.id, 1), PinRef(rf.id, 0)),
          WireLink(PinRef(rf.id, 1), PinRef(op.id, 2)),
        ]);
        // Reduce input amplitude to 2V for clean inverting -4V output
        updateParam(fg.id, 1, 2.0);
        updateParam(rf.id, 0, 2000.0);
        probeCh1 = PinRef(fg.id, 0);
        probeCh2 = PinRef(op.id, 2);
      case PresetKind.bjtSwitch:
        final vcc = addComponent(CompKind.dcSource, 3, 6);
        final g1 = addComponent(CompKind.ground, 3, 9);
        final sw = addComponent(CompKind.switchSpst, 7, 4);
        final rb = addComponent(CompKind.resistor, 7, 7);
        updateParam(rb.id, 0, 10000.0);
        final q = addComponent(CompKind.npnBjt, 12, 7);
        final g2 = addComponent(CompKind.ground, 13, 10);
        final led = addComponent(CompKind.led, 13, 3);
        final rc = addComponent(CompKind.resistor, 16, 3);
        updateParam(rc.id, 0, 330.0);
        wires.addAll([
          WireLink(PinRef(vcc.id, 1), PinRef(g1.id, 0)),
          WireLink(PinRef(vcc.id, 0), PinRef(sw.id, 0)),
          WireLink(PinRef(sw.id, 1), PinRef(rb.id, 0)),
          WireLink(PinRef(rb.id, 1), PinRef(q.id, 1)), // base
          WireLink(PinRef(q.id, 2), PinRef(g2.id, 0)), // emitter
          WireLink(PinRef(vcc.id, 0), PinRef(led.id, 0)),
          WireLink(PinRef(led.id, 1), PinRef(rc.id, 0)),
          WireLink(PinRef(rc.id, 1), PinRef(q.id, 0)), // collector
        ]);
        probeCh1 = PinRef(q.id, 1);
        probeCh2 = PinRef(q.id, 0);
      case PresetKind.digitalXor:
        final clk = addComponent(CompKind.clock, 4, 4);
        final g1 = addComponent(CompKind.ground, 4, 7);
        final dc = addComponent(CompKind.dcSource, 4, 10);
        final sw = addComponent(CompKind.switchSpst, 8, 8);
        final xor = addComponent(CompKind.xorGate, 13, 6);
        final r = addComponent(CompKind.resistor, 17, 6);
        final g2 = addComponent(CompKind.ground, 19, 7);
        wires.addAll([
          WireLink(PinRef(clk.id, 1), PinRef(g1.id, 0)),
          WireLink(PinRef(dc.id, 1), PinRef(g1.id, 0)),
          WireLink(PinRef(clk.id, 0), PinRef(xor.id, 0)),
          WireLink(PinRef(dc.id, 0), PinRef(sw.id, 0)),
          WireLink(PinRef(sw.id, 1), PinRef(xor.id, 1)),
          WireLink(PinRef(xor.id, 2), PinRef(r.id, 0)),
          WireLink(PinRef(r.id, 1), PinRef(g2.id, 0)),
        ]);
        probeCh1 = PinRef(clk.id, 0);
        probeCh2 = PinRef(xor.id, 2);
      case PresetKind.dffDivider:
        final clk = addComponent(CompKind.clock, 4, 6);
        final g1 = addComponent(CompKind.ground, 4, 9);
        final dff = addComponent(CompKind.dFlipFlop, 10, 6);
        final pClk = addComponent(CompKind.logicProbe, 8, 3);
        final pQ = addComponent(CompKind.logicProbe, 15, 5);
        final pQn = addComponent(CompKind.logicProbe, 15, 7);
        wires.addAll([
          WireLink(PinRef(clk.id, 1), PinRef(g1.id, 0)),
          WireLink(PinRef(clk.id, 0), PinRef(dff.id, 1)), // CLK
          WireLink(PinRef(dff.id, 3), PinRef(dff.id, 0)), // Qn -> D toggle
          WireLink(PinRef(clk.id, 0), PinRef(pClk.id, 0)),
          WireLink(PinRef(dff.id, 2), PinRef(pQ.id, 0)),
          WireLink(PinRef(dff.id, 3), PinRef(pQn.id, 0)),
        ]);
        probeCh1 = PinRef(clk.id, 0);
        probeCh2 = PinRef(dff.id, 2);
      case PresetKind.timer555Astable:
        final vcc = addComponent(CompKind.dcSource, 3, 4);
        final g1 = addComponent(CompKind.ground, 3, 8);
        final ra = addComponent(CompKind.resistor, 7, 2);
        final rb = addComponent(CompKind.resistor, 7, 5);
        updateParam(rb.id, 0, 10000.0);
        final cap = addComponent(CompKind.capacitor, 7, 8);
        final g2 = addComponent(CompKind.ground, 9, 11);
        final t555 = addComponent(CompKind.timer555, 14, 5);
        final rLed = addComponent(CompKind.resistor, 20, 6);
        updateParam(rLed.id, 0, 330.0);
        final led = addComponent(CompKind.led, 20, 9);
        wires.addAll([
          WireLink(PinRef(vcc.id, 1), PinRef(g1.id, 0)),
          WireLink(PinRef(vcc.id, 0), PinRef(ra.id, 0)),
          WireLink(PinRef(ra.id, 1), PinRef(t555.id, 2)), // DISCH
          WireLink(PinRef(ra.id, 1), PinRef(rb.id, 0)),
          WireLink(PinRef(rb.id, 1), PinRef(t555.id, 1)), // THRS
          WireLink(PinRef(t555.id, 1), PinRef(t555.id, 0)), // THRS -> TRIG
          WireLink(PinRef(rb.id, 1), PinRef(cap.id, 0)),
          WireLink(PinRef(cap.id, 1), PinRef(g2.id, 0)),
          WireLink(PinRef(t555.id, 3), PinRef(rLed.id, 0)), // OUT
          WireLink(PinRef(rLed.id, 1), PinRef(led.id, 0)),
          WireLink(PinRef(led.id, 1), PinRef(g2.id, 0)),
        ]);
        probeCh1 = PinRef(cap.id, 0);
        probeCh2 = PinRef(t555.id, 3);
      case PresetKind.wordGenCounter:
        final wg = addComponent(CompKind.wordGen, 4, 6);
        final seg = addComponent(CompKind.sevenSeg, 14, 6);
        final rRef = addComponent(CompKind.resistor, 9, 10);
        updateParam(rRef.id, 0, 10000.0);
        final g1 = addComponent(CompKind.ground, 13, 11);
        wires.addAll([
          for (var k = 0; k < 4; k++) WireLink(PinRef(wg.id, k), PinRef(seg.id, k)),
          WireLink(PinRef(wg.id, 3), PinRef(rRef.id, 0)),
          WireLink(PinRef(rRef.id, 1), PinRef(g1.id, 0)),
        ]);
        probeCh1 = PinRef(wg.id, 0);
        probeCh2 = PinRef(wg.id, 1);
        probeCh3 = PinRef(wg.id, 2);
        probeCh4 = PinRef(wg.id, 3);
      case PresetKind.optocouplerIso:
        final clk = addComponent(CompKind.clock, 3, 5);
        final g1 = addComponent(CompKind.ground, 3, 9);
        final rLed = addComponent(CompKind.resistor, 8, 5);
        updateParam(rLed.id, 0, 330.0);
        final oc = addComponent(CompKind.optocoupler, 13, 6);
        final vcc = addComponent(CompKind.dcSource, 20, 4);
        final rPull = addComponent(CompKind.resistor, 17, 3);
        final g2 = addComponent(CompKind.ground, 17, 9);
        wires.addAll([
          WireLink(PinRef(clk.id, 1), PinRef(g1.id, 0)),
          WireLink(PinRef(clk.id, 0), PinRef(rLed.id, 0)),
          WireLink(PinRef(rLed.id, 1), PinRef(oc.id, 0)), // LED anode
          WireLink(PinRef(oc.id, 1), PinRef(g1.id, 0)), // LED cathode
          WireLink(PinRef(vcc.id, 1), PinRef(g2.id, 0)),
          WireLink(PinRef(vcc.id, 0), PinRef(rPull.id, 1)),
          WireLink(PinRef(rPull.id, 0), PinRef(oc.id, 2)), // Collector
          WireLink(PinRef(oc.id, 3), PinRef(g2.id, 0)), // Emitter
        ]);
        probeCh1 = PinRef(clk.id, 0);
        probeCh2 = PinRef(oc.id, 2);
      case PresetKind.schmittCounter:
        final fg = addComponent(CompKind.funcGen, 3, 5);
        final vRef = addComponent(CompKind.dcSource, 7, 7);
        updateParam(vRef.id, 0, 1.0);
        final st = addComponent(CompKind.schmittTrigger, 11, 5);
        final cnt = addComponent(CompKind.counter4Bit, 17, 5);
        final seg = addComponent(CompKind.sevenSeg, 23, 6);
        final g1 = addComponent(CompKind.ground, 5, 10);
        wires.addAll([
          WireLink(PinRef(fg.id, 1), PinRef(g1.id, 0)),
          WireLink(PinRef(vRef.id, 1), PinRef(g1.id, 0)),
          WireLink(PinRef(fg.id, 0), PinRef(st.id, 0)),
          WireLink(PinRef(vRef.id, 0), PinRef(st.id, 1)),
          WireLink(PinRef(st.id, 2), PinRef(cnt.id, 0)),
          WireLink(PinRef(g1.id, 0), PinRef(seg.id, 0)),
          WireLink(PinRef(cnt.id, 1), PinRef(seg.id, 1)),
          WireLink(PinRef(cnt.id, 2), PinRef(seg.id, 2)),
          WireLink(PinRef(cnt.id, 3), PinRef(seg.id, 3)),
        ]);
        probeCh1 = PinRef(fg.id, 0);
        probeCh2 = PinRef(st.id, 2);
        probeCh3 = PinRef(cnt.id, 2);
        probeCh4 = PinRef(cnt.id, 3);
    }
    revision++;
    _undo.clear();
  }

  String toJsonString() {
    return const JsonEncoder.withIndent('  ').convert({
      'version': 2,
      'nextId': _nextId,
      'components': components.map((c) => c.toJson()).toList(),
      'wires': wires.map((w) => w.toJson()).toList(),
      if (notes.isNotEmpty) 'notes': notes.map((n) => n.toJson()).toList(),
      if (subcircuits.isNotEmpty)
        'subcircuits': subcircuits.map((k, v) => MapEntry(k, v.toJson())),
      'ch1': probeCh1?.toJson(),
      'ch2': probeCh2?.toJson(),
      'ch3': probeCh3?.toJson(),
      'ch4': probeCh4?.toJson(),
    });
  }

  void loadJsonString(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Circuit JSON must be an object');
    }
    final rawComps = decoded['components'];
    final rawWires = decoded['wires'];
    if (rawComps is! List || rawWires is! List) {
      throw const FormatException('Missing components or wires array');
    }
    final nextComps = rawComps
        .map((e) => PlacedComponent.fromJson(e as Map<String, dynamic>))
        .toList();
    final nextWires = rawWires
        .map((e) => WireLink.fromJson(e as Map<String, dynamic>))
        .toList();
    final nextNotes = (decoded['notes'] as List<dynamic>?)
            ?.map((e) => SchematicNote.fromJson(e as Map<String, dynamic>))
            .toList() ??
        <SchematicNote>[];
    final nextSubs = <String, SubcircuitDef>{};
    final rawSubs = decoded['subcircuits'] as Map<String, dynamic>?;
    if (rawSubs != null) {
      for (final entry in rawSubs.entries) {
        nextSubs[entry.key] = SubcircuitDef.fromJson(entry.value as Map<String, dynamic>);
      }
    }

    final nextCh1 = decoded['ch1'] != null
        ? PinRef.fromJson(decoded['ch1'] as Map<String, dynamic>)
        : null;
    final nextCh2 = decoded['ch2'] != null
        ? PinRef.fromJson(decoded['ch2'] as Map<String, dynamic>)
        : null;
    final nextCh3 = decoded['ch3'] != null
        ? PinRef.fromJson(decoded['ch3'] as Map<String, dynamic>)
        : null;
    final nextCh4 = decoded['ch4'] != null
        ? PinRef.fromJson(decoded['ch4'] as Map<String, dynamic>)
        : null;

    _pushUndo();
    subcircuits
      ..clear()
      ..addAll(nextSubs);
    components = nextComps;
    wires = nextWires;
    notes = nextNotes;
    probeCh1 = nextCh1;
    probeCh2 = nextCh2;
    probeCh3 = nextCh3;
    probeCh4 = nextCh4;
    var maxId = 0;
    for (final c in components) {
      if (c.id > maxId) maxId = c.id;
    }
    for (final n in notes) {
      if (n.id > maxId) maxId = n.id;
    }
    final savedNextId = (decoded['nextId'] as int?) ?? 0;
    _nextId = savedNextId > maxId ? savedNextId : maxId + 1;
  }

  /// Parses a SPICE numeric token supporting optional wrappers and SI unit suffixes.
  static double? parseSpiceValue(String token) => _parseSpiceToken(token);

  /// Synthesizes a minimized SOP Boolean expression into placed & wired gates (`clearCanvas: false` inserts non-destructively).
  void synthesizeLogicToCanvas(
    int varCount,
    String sopExpr, {
    bool nandOnly = false,
    bool clearCanvas = true,
  }) {
    final vars = varCount.clamp(1, 8);
    _pushUndo();
    var baseY = 4;
    if (clearCanvas) {
      components.clear();
      wires.clear();
      notes.clear();
      subcircuits.clear();
      probeCh3 = null;
      probeCh4 = null;
      _nextId = 1;
    } else if (components.isNotEmpty) {
      var maxY = 0;
      for (final c in components) {
        if (c.gridY > maxY) maxY = c.gridY;
      }
      baseY = maxY + 6;
    }

    final gnd = (!clearCanvas ? components.where((c) => c.kind == CompKind.ground).firstOrNull : null) ??
        addComponent(CompKind.ground, 2, baseY + vars * 4, recordUndo: false);
    final posPin = <int, PinRef>{};
    for (var i = 0; i < vars; i++) {
      final y = baseY + i * 4;
      final clk = addComponent(CompKind.clock, 4, y, recordUndo: false);
      updateParam(clk.id, 0, 50.0 * (1 << math.min(i, 6)));
      wires.add(WireLink(PinRef(clk.id, 1), PinRef(gnd.id, 0)));
      final inProbe = addComponent(CompKind.logicProbe, 7, y - 2, recordUndo: false);
      wires.add(WireLink(PinRef(clk.id, 0), PinRef(inProbe.id, 0)));
      posPin[i] = PinRef(clk.id, 0);
    }

    final trimmed = sopExpr.trim();
    if (trimmed == '0' || trimmed == '1') {
      final dc = addComponent(CompKind.dcSource, 12, baseY + 2, recordUndo: false);
      updateParam(dc.id, 0, trimmed == '1' ? 5.0 : 0.0);
      wires.add(WireLink(PinRef(dc.id, 1), PinRef(gnd.id, 0)));
      final outProbe = addComponent(CompKind.logicProbe, 17, baseY, recordUndo: false);
      wires.add(WireLink(PinRef(dc.id, 0), PinRef(outProbe.id, 0)));
      probeCh1 = posPin[0];
      probeCh2 = PinRef(dc.id, 0);
      revision++;
      return;
    }

    final negPin = <int, PinRef>{};
    var invExtraX = 10;
    PinRef nandInv(PinRef a, int gx, int gy) {
      final g = addComponent(CompKind.nandGate, gx, gy, recordUndo: false);
      wires.add(WireLink(a, PinRef(g.id, 0)));
      wires.add(WireLink(a, PinRef(g.id, 1)));
      return PinRef(g.id, 2);
    }

    PinRef getNeg(int idx) {
      return negPin.putIfAbsent(idx, () {
        if (nandOnly) return nandInv(posPin[idx]!, 10, baseY + idx * 4);
        final inv = addComponent(CompKind.notGate, 10, baseY + idx * 4, recordUndo: false);
        wires.add(WireLink(posPin[idx]!, PinRef(inv.id, 0)));
        return PinRef(inv.id, 1);
      });
    }

    final terms = trimmed.split('+').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    final litRe = RegExp(r"([A-Z])('?)");
    final termLits = <List<PinRef>>[];
    var maxLits = 1;
    for (final term in terms) {
      final lits = <PinRef>[];
      for (final m in litRe.allMatches(term)) {
        final vIdx = m.group(1)!.codeUnitAt(0) - 65;
        if (vIdx < 0 || vIdx >= vars) continue;
        lits.add(m.group(2) == "'" ? getNeg(vIdx) : posPin[vIdx]!);
      }
      if (lits.isNotEmpty) {
        if (lits.length > maxLits) maxLits = lits.length;
        termLits.add(lits);
      }
    }

    if (termLits.isEmpty) {
      probeCh1 = posPin[0];
      probeCh2 = posPin[0];
      revision++;
      return;
    }

    late final PinRef finalOut;
    final outBaseX = 16 + math.max(1, maxLits) * 6;
    if (nandOnly) {
      if (termLits.length == 1) {
        final lits = termLits[0];
        var cur = lits[0];
        for (var k = 1; k < lits.length; k++) {
          final n = addComponent(CompKind.nandGate, 16 + (k - 1) * 6, baseY, recordUndo: false);
          wires.add(WireLink(cur, PinRef(n.id, 0)));
          wires.add(WireLink(lits[k], PinRef(n.id, 1)));
          cur = nandInv(PinRef(n.id, 2), 19 + (k - 1) * 6, baseY);
        }
        finalOut = cur;
      } else {
        // 2-level NAND-NAND: each term becomes inverted term `(T_i)'`, then NAND combined.
        final invTerms = <PinRef>[];
        for (var tIdx = 0; tIdx < termLits.length; tIdx++) {
          final lits = termLits[tIdx];
          final gy = baseY + tIdx * 4;
          if (lits.length == 1) {
            invTerms.add(nandInv(lits[0], 16, gy));
          } else {
            var cur = lits[0];
            for (var k = 1; k < lits.length - 1; k++) {
              final n = addComponent(CompKind.nandGate, 16 + (k - 1) * 6, gy, recordUndo: false);
              wires.add(WireLink(cur, PinRef(n.id, 0)));
              wires.add(WireLink(lits[k], PinRef(n.id, 1)));
              cur = nandInv(PinRef(n.id, 2), 19 + (k - 1) * 6, gy);
            }
            final lastN = addComponent(CompKind.nandGate, 16 + (lits.length - 2) * 6, gy, recordUndo: false);
            wires.add(WireLink(cur, PinRef(lastN.id, 0)));
            wires.add(WireLink(lits.last, PinRef(lastN.id, 1)));
            invTerms.add(PinRef(lastN.id, 2));
          }
        }
        final combine = addComponent(CompKind.nandGate, outBaseX, baseY, recordUndo: false);
        wires.add(WireLink(invTerms[0], PinRef(combine.id, 0)));
        wires.add(WireLink(invTerms[1], PinRef(combine.id, 1)));
        var cur = PinRef(combine.id, 2);
        for (var t = 2; t < invTerms.length; t++) {
          final invPrev = nandInv(cur, outBaseX + (t - 1) * 6, baseY + (t - 1) * 4);
          final nextOr = addComponent(CompKind.nandGate, outBaseX + (t - 1) * 6 + 3, baseY + (t - 1) * 4, recordUndo: false);
          wires.add(WireLink(invPrev, PinRef(nextOr.id, 0)));
          wires.add(WireLink(invTerms[t], PinRef(nextOr.id, 1)));
          cur = PinRef(nextOr.id, 2);
        }
        invExtraX = outBaseX + termLits.length * 6;
        finalOut = cur;
      }
    } else {
      final termOuts = <PinRef>[];
      for (var tIdx = 0; tIdx < termLits.length; tIdx++) {
        final lits = termLits[tIdx];
        var cur = lits[0];
        for (var k = 1; k < lits.length; k++) {
          final gate = addComponent(CompKind.andGate, 16 + (k - 1) * 5, baseY + tIdx * 4, recordUndo: false);
          wires.add(WireLink(cur, PinRef(gate.id, 0)));
          wires.add(WireLink(lits[k], PinRef(gate.id, 1)));
          cur = PinRef(gate.id, 2);
        }
        termOuts.add(cur);
      }
      var cur = termOuts[0];
      for (var t = 1; t < termOuts.length; t++) {
        final orGate = addComponent(CompKind.orGate, outBaseX + (t - 1) * 5, baseY + (t - 1) * 4, recordUndo: false);
        wires.add(WireLink(cur, PinRef(orGate.id, 0)));
        wires.add(WireLink(termOuts[t], PinRef(orGate.id, 1)));
        cur = PinRef(orGate.id, 2);
      }
      invExtraX = outBaseX + (termOuts.length > 1 ? (termOuts.length - 1) * 5 : 0) + 4;
      finalOut = cur;
    }

    final outProbe = addComponent(CompKind.logicProbe, math.max(outBaseX + 6, invExtraX), baseY, recordUndo: false);
    wires.add(WireLink(finalOut, PinRef(outProbe.id, 0)));
    probeCh1 = posPin[0];
    probeCh2 = finalOut;
    revision++;
  }

  String toBomCsv(List<double> times, List<double> ch1, List<double> ch2) {
    final buf = StringBuffer('# Bill of Materials\ndesignator,kind,primary_param,fault\n');
    for (final c in components) {
      final val = c.params.isNotEmpty ? formatEngValue(c.params[0]) : '';
      buf.writeln('${formatComponentBadge(c).split(' ').first},${c.kind.name},$val,${c.fault.name}');
    }
    buf.writeln('\n# Oscilloscope Samples\nt_s,ch1_v,ch2_v');
    final n = times.length < ch1.length ? times.length : ch1.length;
    for (var i = 0; i < n; i++) {
      final v2 = i < ch2.length ? ch2[i] : 0.0;
      buf.writeln('${times[i].toStringAsExponential(6)},${ch1[i].toStringAsFixed(5)},${v2.toStringAsFixed(5)}');
    }
    return buf.toString();
  }
}
