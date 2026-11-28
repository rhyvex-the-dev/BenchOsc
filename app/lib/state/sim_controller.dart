import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import '../audio/buzzer_audio.dart';
import '../ffi/sim_isolate.dart';
import '../instruments/dc_sweep_view.dart' show DcSweepData;
import 'circuit_doc.dart';

/// Immutable simulation snapshot exposed via [SimController.telemetry] to scope 60 FPS rebuilds.
class SimTelemetry {
  final int epoch;
  final int errCode;
  final int errDetail;
  final double tSim;
  final double animPhase;
  final int measuredFps;
  final Float64List ch1Times;
  final Float64List ch1;
  final Float64List ch2;
  final Float64List ch3;
  final Float64List ch4;
  final Float64List fft;
  final Float64List spectrumFft;
  final bool scopeTriggered;
  final Float64List logicTimes;
  final Uint16List logicMasks;
  final ChannelStats ch1Stats;
  final ChannelStats ch2Stats;
  final ChannelStats ch3Stats;
  final ChannelStats ch4Stats;
  final double ch1Thd;
  final double spectrumThd;
  final double fftDt;
  final Map<int, double> nodeVoltages;
  final Map<int, double> compCurrents;
  final Map<int, double> compPowers;
  final Set<int> overloadedIds;
  final Set<int> blownFuseIds;
  final AcSweepData? bodeData;
  final DcSweepData? dcSweepData;
  final List<(String label, DcSweepData data)>? dcFamilyCurves;

  SimTelemetry({
    required this.epoch,
    required this.errCode,
    required this.errDetail,
    required this.tSim,
    required this.animPhase,
    required this.measuredFps,
    required this.ch1Times,
    required this.ch1,
    required this.ch2,
    required this.ch3,
    required this.ch4,
    required this.fft,
    Float64List? spectrumFft,
    required this.scopeTriggered,
    required this.logicTimes,
    required this.logicMasks,
    required this.ch1Stats,
    required this.ch2Stats,
    required this.ch3Stats,
    required this.ch4Stats,
    required this.ch1Thd,
    double? spectrumThd,
    this.fftDt = 0.0,
    required this.nodeVoltages,
    required this.compCurrents,
    required this.compPowers,
    required this.overloadedIds,
    required this.blownFuseIds,
    this.bodeData,
    this.dcSweepData,
    this.dcFamilyCurves,
  })  : spectrumFft = spectrumFft ?? fft,
        spectrumThd = spectrumThd ?? ch1Thd;

  static final SimTelemetry empty = SimTelemetry(
    epoch: 0,
    errCode: 0,
    errDetail: 0,
    tSim: 0.0,
    animPhase: 0.0,
    measuredFps: 60,
    ch1Times: Float64List(0),
    ch1: Float64List(0),
    ch2: Float64List(0),
    ch3: Float64List(0),
    ch4: Float64List(0),
    fft: Float64List(0),
    scopeTriggered: true,
    logicTimes: Float64List(0),
    logicMasks: Uint16List(0),
    ch1Stats: const ChannelStats(0, 0, 0, 0),
    ch2Stats: const ChannelStats(0, 0, 0, 0),
    ch3Stats: const ChannelStats(0, 0, 0, 0),
    ch4Stats: const ChannelStats(0, 0, 0, 0),
    ch1Thd: 0.0,
    nodeVoltages: const {},
    compCurrents: const {},
    compPowers: const {},
    overloadedIds: const {},
    blownFuseIds: const {},
  );

  SimTelemetry copyWith({
    int? epoch,
    int? errCode,
    int? errDetail,
    double? tSim,
    double? animPhase,
    int? measuredFps,
    Float64List? ch1Times,
    Float64List? ch1,
    Float64List? ch2,
    Float64List? ch3,
    Float64List? ch4,
    Float64List? fft,
    Float64List? spectrumFft,
    bool? scopeTriggered,
    Float64List? logicTimes,
    Uint16List? logicMasks,
    ChannelStats? ch1Stats,
    ChannelStats? ch2Stats,
    ChannelStats? ch3Stats,
    ChannelStats? ch4Stats,
    double? ch1Thd,
    double? spectrumThd,
    double? fftDt,
    Map<int, double>? nodeVoltages,
    Map<int, double>? compCurrents,
    Map<int, double>? compPowers,
    Set<int>? overloadedIds,
    Set<int>? blownFuseIds,
    AcSweepData? bodeData,
    bool clearBode = false,
    DcSweepData? dcSweepData,
    List<(String label, DcSweepData data)>? dcFamilyCurves,
    bool clearDcSweep = false,
  }) {
    return SimTelemetry(
      epoch: epoch ?? this.epoch,
      errCode: errCode ?? this.errCode,
      errDetail: errDetail ?? this.errDetail,
      tSim: tSim ?? this.tSim,
      animPhase: animPhase ?? this.animPhase,
      measuredFps: measuredFps ?? this.measuredFps,
      ch1Times: ch1Times ?? this.ch1Times,
      ch1: ch1 ?? this.ch1,
      ch2: ch2 ?? this.ch2,
      ch3: ch3 ?? this.ch3,
      ch4: ch4 ?? this.ch4,
      fft: fft ?? this.fft,
      spectrumFft: spectrumFft ?? this.spectrumFft,
      scopeTriggered: scopeTriggered ?? this.scopeTriggered,
      logicTimes: logicTimes ?? this.logicTimes,
      logicMasks: logicMasks ?? this.logicMasks,
      ch1Stats: ch1Stats ?? this.ch1Stats,
      ch2Stats: ch2Stats ?? this.ch2Stats,
      ch3Stats: ch3Stats ?? this.ch3Stats,
      ch4Stats: ch4Stats ?? this.ch4Stats,
      ch1Thd: ch1Thd ?? this.ch1Thd,
      spectrumThd: spectrumThd ?? this.spectrumThd,
      fftDt: fftDt ?? this.fftDt,
      nodeVoltages: nodeVoltages ?? this.nodeVoltages,
      compCurrents: compCurrents ?? this.compCurrents,
      compPowers: compPowers ?? this.compPowers,
      overloadedIds: overloadedIds ?? this.overloadedIds,
      blownFuseIds: blownFuseIds ?? this.blownFuseIds,
      bodeData: clearBode ? null : (bodeData ?? this.bodeData),
      dcSweepData: clearDcSweep ? null : (dcSweepData ?? this.dcSweepData),
      dcFamilyCurves: clearDcSweep ? null : (dcFamilyCurves ?? this.dcFamilyCurves),
    );
  }
}

/// Owns the single background [SimRunnerIsolate] simulation worker and publishes throttled telemetry.
class SimController {
  final SimRunnerIsolate _isolate = SimRunnerIsolate();
  final ValueNotifier<SimTelemetry> telemetry = ValueNotifier<SimTelemetry>(SimTelemetry.empty);

  int _epoch = 0;
  bool _synced = false;
  Completer<void>? _activeOp;
  bool _disposed = false;
  bool _needFft = false;
  int _trigCh = 0;
  double _trigLevel = 0.0;
  bool _trigRising = true;
  bool _trigRequire = false;
  int _fftCh = 0;

  int get epoch => _epoch;

  /// Returns the Rust `ob_sim_set_control` parameter index if [pIdx] can update live without recompile.
  static int? liveFfiParamIdx(CompKind kind, int pIdx) {
    final canLive = kind == CompKind.potentiometer ||
        (kind == CompKind.dcSource && pIdx == 0) ||
        (kind == CompKind.powerRail && pIdx == 0) ||
        (kind == CompKind.dcCurrent && pIdx == 0) ||
        ((kind == CompKind.acSource || kind == CompKind.acCurrent) && pIdx <= 3) ||
        ((kind == CompKind.resistor ||
                kind == CompKind.lamp ||
                kind == CompKind.buzzer ||
                kind == CompKind.capacitor ||
                kind == CompKind.polarizedCapacitor ||
                kind == CompKind.varCapacitor ||
                kind == CompKind.inductor ||
                kind == CompKind.varInductor ||
                kind == CompKind.fuse ||
                kind == CompKind.transformer ||
                kind == CompKind.centerTapTransformer ||
                kind == CompKind.vcvs ||
                kind == CompKind.vccs ||
                kind == CompKind.cccs ||
                kind == CompKind.ccvs ||
                kind == CompKind.voltageReg ||
                kind == CompKind.instAmp ||
                kind == CompKind.analogMultiplier ||
                kind == CompKind.hexKeypad ||
                kind == CompKind.dipSwitch4 ||
                kind == CompKind.opAmp) &&
            pIdx == 0) ||
        (kind == CompKind.dcMotor && pIdx == 1) ||
        (kind == CompKind.coupledInductor && pIdx == 2) ||
        (kind == CompKind.vco && pIdx <= 1) ||
        (kind == CompKind.zener && pIdx == 2) ||
        ((kind == CompKind.npnBjt || kind == CompKind.pnpBjt) && pIdx == 1) ||
        ((kind == CompKind.nmos || kind == CompKind.pmos) && pIdx == 1) ||
        (kind == CompKind.optocoupler && pIdx == 0) ||
        ((kind == CompKind.relay || kind == CompKind.relaySpdt || kind == CompKind.relayDpdt) &&
            pIdx <= 1) ||
        (kind == CompKind.clock && pIdx <= 1) ||
        (kind == CompKind.schmittTrigger && pIdx <= 1) ||
        ((kind == CompKind.counter4Bit || kind == CompKind.counter4BitFull) && pIdx == 0) ||
        (kind == CompKind.wordGen && (pIdx == 0 || pIdx == 2)) ||
        (kind == CompKind.funcGen && pIdx >= 1 && pIdx <= 4);
    if (!canLive) return null;
    return switch (kind) {
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
  }

  Set<int> _remapSubcircuitIds(CircuitDoc doc, Set<int> raw) {
    if (doc.subcircuitChildParent.isEmpty || raw.isEmpty) return raw;
    return {for (final id in raw) doc.subcircuitChildParent[id] ?? id};
  }

  Set<int> _filterOverloadedIds(CircuitDoc doc, Set<int> raw, Map<int, double> powers) {
    if (raw.isEmpty) return raw;
    final byId = {for (final c in doc.components) c.id: c.kind};
    return {
      for (final id in raw)
        if (switch (byId[id]) {
          CompKind.ammeter || CompKind.voltmeter => false,
          CompKind.buzzer => (powers[id]?.abs() ?? 0.0) > 2.0,
          CompKind.lamp => (powers[id]?.abs() ?? 0.0) > 5.0,
          _ => true,
        })
          id,
    };
  }

  void _applySnapshot(CircuitDoc doc, SimSnapshot snap, {double dtAnim = 0.0}) {
    if (_disposed) return;
    final cur = telemetry.value;
    telemetry.value = cur.copyWith(
      epoch: _epoch,
      errCode: snap.errCode,
      errDetail: snap.errDetail,
      tSim: snap.tSim,
      animPhase: dtAnim > 0 ? (cur.animPhase + dtAnim * 1.4) % 1.0 : cur.animPhase,
      scopeTriggered: snap.scopeTriggered,
      ch1Times: snap.ch1Times,
      ch1: snap.ch1,
      ch2: snap.ch2,
      ch3: snap.ch3,
      ch4: snap.ch4,
      fft: snap.fft,
      spectrumFft: snap.spectrumFft,
      logicTimes: snap.logicTimes,
      logicMasks: snap.logicMasks,
      ch1Thd: snap.ch1Thd,
      spectrumThd: snap.spectrumThd,
      fftDt: snap.fftDt,
      ch1Stats: snap.ch1Stats,
      ch2Stats: snap.ch2Stats,
      ch3Stats: snap.ch3Stats,
      ch4Stats: snap.ch4Stats,
      nodeVoltages: snap.nodeVoltages,
      compCurrents: snap.compCurrents,
      compPowers: snap.compPowers,
      overloadedIds: _remapSubcircuitIds(
        doc,
        _filterOverloadedIds(doc, snap.overloadedIds, snap.compPowers),
      ),
      blownFuseIds: _remapSubcircuitIds(doc, snap.blownFuseIds),
    );
  }

  Future<void> _ensureSynced(
    CircuitDoc doc,
    int epoch,
    List<int> logicNodes,
    double logicThreshold,
  ) async {
    if (_synced || _disposed) return;
    final (specs, probes, nodeIds) = doc.buildIsolatePayload();
    final freshSnap = await _isolate.sync(
      comps: specs,
      probes: probes,
      nodeIds: nodeIds,
      trigCh: _trigCh,
      trigLevel: _trigLevel,
      rising: _trigRising,
      requireTrigger: _trigRequire,
      fftCh: _fftCh,
      needFft: _needFft,
      logicNodes: logicNodes,
      logicThreshold: logicThreshold,
    );
    if (_disposed || epoch != _epoch) return;
    _synced = true;
    _applySnapshot(doc, freshSnap);
  }

  Future<void> syncCircuit(
    CircuitDoc doc, {
    required List<int> logicNodes,
    required double logicThreshold,
    int? fftCh,
    bool? needFft,
  }) async {
    _fftCh = fftCh ?? _fftCh;
    _needFft = needFft ?? _needFft;
    _epoch++;
    _synced = false;
    final prev = _activeOp;
    if (prev != null && !prev.isCompleted) prev.complete();
    final op = Completer<void>();
    _activeOp = op;
    final myEpoch = _epoch;
    telemetry.value = telemetry.value.copyWith(
      epoch: _epoch,
      errCode: 0,
      errDetail: 0,
      tSim: 0.0,
      logicTimes: Float64List(0),
      logicMasks: Uint16List(0),
      clearBode: true,
      clearDcSweep: true,
    );
    try {
      await _ensureSynced(doc, myEpoch, logicNodes, logicThreshold);
    } catch (_) {
      if (!_disposed && myEpoch == _epoch) {
        telemetry.value = telemetry.value.copyWith(epoch: _epoch, errCode: 8, errDetail: 0);
      }
    } finally {
      if (identical(_activeOp, op)) _activeOp = null;
      if (!op.isCompleted) op.complete();
    }
  }

  Future<void> stepFrame(
    CircuitDoc doc, {
    required double dtSec,
    required double simDt,
    required List<int> logicNodes,
    required double logicThreshold,
    int maxSubsteps = 480,
    BuzzerAudio? buzzer,
    bool playBuzzer = false,
  }) async {
    if (_activeOp != null || _disposed || telemetry.value.errCode != 0) return;
    final op = Completer<void>();
    _activeOp = op;
    final myEpoch = _epoch;
    try {
      await _ensureSynced(doc, myEpoch, logicNodes, logicThreshold);
      if (_disposed || myEpoch != _epoch || telemetry.value.errCode != 0) return;
      final snap = await _isolate.step(simDt, maxSubsteps: maxSubsteps);
      if (!_disposed && myEpoch == _epoch) {
        _applySnapshot(doc, snap, dtAnim: dtSec);
        if (playBuzzer && buzzer != null && buzzer.enabled) {
          for (final c in doc.components) {
            if (c.kind == CompKind.buzzer && (snap.compPowers[c.id]?.abs() ?? 0.0) > 1e-3) {
              buzzer.triggerIfActive(c.params.length > 1 ? c.params[1] : 1000.0);
              break;
            }
          }
        }
      }
    } catch (_) {
      if (!_disposed && myEpoch == _epoch) {
        telemetry.value = telemetry.value.copyWith(epoch: _epoch, errCode: 8, errDetail: 0);
      }
    } finally {
      if (identical(_activeOp, op)) _activeOp = null;
      if (!op.isCompleted) op.complete();
    }
  }

  void updateFps(int fps) {
    if (_disposed || telemetry.value.measuredFps == fps) return;
    telemetry.value = telemetry.value.copyWith(measuredFps: fps);
  }

  Future<T?> _withLock<T>(
    CircuitDoc doc,
    List<int> logicNodes,
    double logicThreshold,
    Future<T?> Function() action,
  ) async {
    final myEpoch = _epoch;
    while (_activeOp != null && !_disposed && myEpoch == _epoch) {
      await _activeOp!.future;
    }
    if (_disposed || myEpoch != _epoch) return null;
    final op = Completer<void>();
    _activeOp = op;
    try {
      await _ensureSynced(doc, myEpoch, logicNodes, logicThreshold);
      if (_disposed || myEpoch != _epoch) return null;
      final res = await action();
      return (!_disposed && myEpoch == _epoch) ? res : null;
    } catch (_) {
      return null;
    } finally {
      if (identical(_activeOp, op)) _activeOp = null;
      if (!op.isCompleted) op.complete();
    }
  }

  Future<void> setScopeConfig({
    int? trigCh,
    double? trigLevel,
    bool? rising,
    bool? requireTrigger,
    int? fftCh,
    bool? needFft,
  }) async {
    _trigCh = trigCh ?? _trigCh;
    _trigLevel = trigLevel ?? _trigLevel;
    _trigRising = rising ?? _trigRising;
    _trigRequire = requireTrigger ?? _trigRequire;
    _fftCh = fftCh ?? _fftCh;
    _needFft = needFft ?? _needFft;
    if (_disposed) return;
    final myEpoch = _epoch;
    while (_activeOp != null && !_disposed && myEpoch == _epoch) {
      await _activeOp!.future;
    }
    if (!_synced || _disposed || myEpoch != _epoch) return;
    try {
      final snap = await _isolate.setScopeConfig(
        trigCh: _trigCh,
        trigLevel: _trigLevel,
        rising: _trigRising,
        requireTrigger: _trigRequire,
        fftCh: _fftCh,
        needFft: _needFft,
      );
      if (!_disposed && myEpoch == _epoch) {
        telemetry.value = telemetry.value.copyWith(
          scopeTriggered: snap.scopeTriggered,
          ch1Times: snap.ch1Times,
          ch1: snap.ch1,
          ch2: snap.ch2,
          ch3: snap.ch3,
          ch4: snap.ch4,
          fft: snap.fft,
          spectrumFft: snap.spectrumFft,
          ch1Thd: snap.ch1Thd,
          spectrumThd: snap.spectrumThd,
          fftDt: snap.fftDt,
          ch1Stats: snap.ch1Stats,
          ch2Stats: snap.ch2Stats,
          ch3Stats: snap.ch3Stats,
          ch4Stats: snap.ch4Stats,
        );
      }
    } catch (_) {}
  }

  Future<void> setLogicProbes(
    CircuitDoc doc,
    List<int> nodes, {
    required double threshold,
  }) async {
    if (_disposed) return;
    final myEpoch = _epoch;
    while (_activeOp != null && !_disposed && myEpoch == _epoch) {
      await _activeOp!.future;
    }
    if (!_synced || _disposed || myEpoch != _epoch) return;
    try {
      final snap = await _isolate.setLogicProbes(nodes, threshold: threshold);
      if (!_disposed && myEpoch == _epoch) _applySnapshot(doc, snap);
    } catch (_) {}
  }

  Future<void> setControl(
    CircuitDoc doc,
    int compId,
    int paramIdx,
    double val, {
    required bool solveDc,
  }) async {
    if (_disposed) return;
    final myEpoch = _epoch;
    while (_activeOp != null && !_disposed && myEpoch == _epoch) {
      await _activeOp!.future;
    }
    if (!_synced || _disposed || myEpoch != _epoch) return;
    try {
      final snap = await _isolate.setControl(compId, paramIdx, val, solveDc: solveDc);
      if (solveDc && !_disposed && myEpoch == _epoch) _applySnapshot(doc, snap);
    } catch (_) {}
  }

  Future<void> setFault(
    CircuitDoc doc,
    int compId,
    int faultIdx, {
    required bool solveDc,
  }) async {
    if (_disposed) return;
    final myEpoch = _epoch;
    while (_activeOp != null && !_disposed && myEpoch == _epoch) {
      await _activeOp!.future;
    }
    if (!_synced || _disposed || myEpoch != _epoch) return;
    try {
      final snap = await _isolate.setFault(compId, faultIdx, solveDc: solveDc);
      if (solveDc && !_disposed && myEpoch == _epoch) _applySnapshot(doc, snap);
    } catch (_) {}
  }

  Future<void> setWordGenPattern(int compId, int patternBits) async {
    if (_disposed) return;
    final myEpoch = _epoch;
    while (_activeOp != null && !_disposed && myEpoch == _epoch) {
      await _activeOp!.future;
    }
    if (!_synced || _disposed || myEpoch != _epoch) return;
    try {
      await _isolate.setWordGenPattern(compId, patternBits);
    } catch (_) {}
  }

  Future<void> runBodeSweep(
    CircuitDoc doc, {
    required List<int> logicNodes,
    required double logicThreshold,
    double fStart = 10.0,
    double fStop = 100000.0,
    int ptsPerDecade = 20,
    int? acSourceId,
    int inNode = -1,
    int? outNodeOverride,
  }) async {
    final (defSrc, defOut) = doc.findAcSweepTarget();
    final srcId = acSourceId ?? defSrc;
    final outNode = outNodeOverride ?? defOut;
    if (srcId == null || outNode == null || outNode <= 0) return;
    final data = await _withLock(
      doc,
      logicNodes,
      logicThreshold,
      () => _isolate.acSweepTransfer(
        fStart: fStart,
        fStop: fStop,
        ptsPerDecade: ptsPerDecade,
        acSourceId: srcId,
        inNode: inNode,
        outNode: outNode,
      ),
    );
    if (data != null && !_disposed) {
      telemetry.value = telemetry.value.copyWith(bodeData: data);
    }
  }

  Future<void> runDcSweep(
    CircuitDoc doc, {
    required List<int> logicNodes,
    required double logicThreshold,
    int? sweepSrcId,
    int? secSrcId,
    double vStart = 0.0,
    double vStop = 5.0,
    int steps = 25,
    bool family = false,
    bool ivCurve = false,
    int? selectedCompId,
  }) async {
    final srcId = sweepSrcId ?? doc.findDcSweepSource(preferredId: selectedCompId);
    if (srcId == null) return;
    final src = doc.components.where((c) => c.id == srcId).firstOrNull;
    if (src == null) return;
    final origV = src.kind == CompKind.potentiometer && src.params.length > 1
        ? src.params[1]
        : (src.params.isNotEmpty ? src.params[0] : 5.0);
    final sStart = src.kind == CompKind.potentiometer ? 0.05 : vStart;
    final sStop = src.kind == CompKind.potentiometer ? 0.95 : vStop;
    final ch1Node = doc.probeCh1 != null ? (doc.resolvedNodes[doc.probeCh1!] ?? 0) : 0;
    final ch2Node = doc.probeCh2 != null ? (doc.resolvedNodes[doc.probeCh2!] ?? 0) : 0;
    final selComp = selectedCompId != null
        ? doc.components.where((c) => c.id == selectedCompId).firstOrNull
        : null;
    final canMeasureSel = selComp != null &&
        selComp.kind != CompKind.ground &&
        selComp.kind != CompKind.netPort &&
        selComp.kind != CompKind.subcircuit;
    final curId = ivCurve ? (canMeasureSel ? selComp.id : srcId) : null;
    final aux = family
        ? doc.components
            .where((c) =>
                c.id != srcId &&
                (secSrcId != null
                    ? c.id == secSrcId
                    : (c.kind == CompKind.resistor || c.kind == CompKind.dcSource)))
            .firstOrNull
        : null;

    Future<DcSweepData> sweepOne() async {
      final (vin, ch1, ch2) = await _isolate.dcSweepEx(
        srcId: srcId,
        paramIdx: 0,
        origVal: origV,
        vStart: sStart,
        vStop: sStop,
        ch1Node: ch1Node,
        ch2Node: ch2Node,
        currentCompId: curId,
        steps: steps,
      );
      return DcSweepData(vin, ch1, ch2);
    }

    final result = await _withLock(doc, logicNodes, logicThreshold, () async {
      final sweepEpoch = _epoch;
      final primary = await sweepOne();
      if (_disposed || _epoch != sweepEpoch) return null;
      List<(String, DcSweepData)>? famCurves;
      if (aux != null && aux.params.isNotEmpty) {
        famCurves = [];
        if (aux.kind == CompKind.potentiometer) {
          final base = (aux.params.length > 1 ? aux.params[1] : 0.5).clamp(0.001, 0.999);
          for (final (val, label) in [
            ((base - 0.25).clamp(0.001, 0.999), '-25%'),
            (base, 'base'),
            ((base + 0.25).clamp(0.001, 0.999), '+25%'),
          ]) {
            if (_disposed || _epoch != sweepEpoch) return null;
            await _isolate.setControl(aux.id, 0, val, solveDc: false);
            if (_disposed || _epoch != sweepEpoch) return null;
            famCurves.add((label, await sweepOne()));
          }
          if (_disposed || _epoch != sweepEpoch) return null;
          await _isolate.setControl(aux.id, 0, base, solveDc: true);
        } else {
          final base = aux.params[0];
          for (final scale in const [0.5, 1.0, 2.0]) {
            final val = (aux.kind == CompKind.dcSource || aux.kind == CompKind.powerRail)
                ? (base * scale).clamp(-250.0, 250.0)
                : (aux.kind == CompKind.dcCurrent
                    ? (base * scale).clamp(-50.0, 50.0)
                    : (base * scale).clamp(1e-3, 1e9));
            if (_disposed || _epoch != sweepEpoch) return null;
            await _isolate.setControl(aux.id, 0, val, solveDc: false);
            if (_disposed || _epoch != sweepEpoch) return null;
            famCurves.add(('${scale}x', await sweepOne()));
          }
          if (_disposed || _epoch != sweepEpoch) return null;
          await _isolate.setControl(aux.id, 0, base, solveDc: true);
        }
      }
      return (primary, famCurves);
    });
    if (result != null && !_disposed) {
      telemetry.value = telemetry.value.copyWith(
        dcSweepData: result.$1,
        dcFamilyCurves: result.$2,
      );
    }
  }

  Future<(double, double, double, double, Float64List)?> runMonteCarloEx(
    CircuitDoc doc, {
    required List<int> logicNodes,
    required double logicThreshold,
    required double tol,
    required int runs,
    required bool gaussian,
  }) {
    final probe = doc.probeCh2 ?? doc.probeCh1;
    final outNode = probe != null ? (doc.resolvedNodes[probe] ?? 0) : 0;
    return _withLock(
      doc,
      logicNodes,
      logicThreshold,
      () => _isolate.monteCarloEx(
        tol: tol,
        runs: runs,
        outNode: outNode,
        gaussian: gaussian,
      ),
    );
  }

  Future<double?> measureTwoTerminal(
    CircuitDoc doc,
    int nodeA,
    int nodeB,
    bool diode, {
    required List<int> logicNodes,
    required double logicThreshold,
  }) =>
      _withLock(
        doc,
        logicNodes,
        logicThreshold,
        () => _isolate.measureTwoTerminal(nodeA, nodeB, diodeMode: diode),
      );

  Future<String> minimizeLogicEx(int vars, List<int> outs) async {
    if (_disposed) return '';
    try {
      return await _isolate.minimizeLogicEx(vars, outs);
    } catch (_) {
      return '';
    }
  }

  Future<(int, List<int>)?> extractTruthTable(CircuitDoc doc) async {
    if (_disposed) return null;
    final (specs, _, _) = doc.buildIsolatePayload();
    final inputs = <int>[];
    for (final c in doc.components) {
      if (inputs.length >= 6) break;
      if ((c.kind == CompKind.clock || c.kind == CompKind.dcSource) && c.pinOffsets.isNotEmpty) {
        final nid = doc.resolvedNodes[PinRef(c.id, 0)];
        if (nid != null && nid > 0 && !inputs.contains(nid)) inputs.add(nid);
      }
    }
    final outRef = doc.probeCh2 ??
        (doc.components.where((c) => c.kind == CompKind.logicProbe).lastOrNull != null
            ? PinRef(doc.components.where((c) => c.kind == CompKind.logicProbe).last.id, 0)
            : null);
    final outNode = outRef != null ? (doc.resolvedNodes[outRef] ?? 0) : 0;
    if (inputs.isEmpty || outNode <= 0) return null;
    try {
      final outs = await _isolate.extractTruthTable(
        comps: specs,
        inputNodes: inputs,
        outputNode: outNode,
      );
      if (outs == null) return null;
      return (inputs.length, outs);
    } catch (_) {
      return null;
    }
  }

  Future<String> exportCir(CircuitDoc doc) async {
    if (_synced && doc.subcircuits.isEmpty) {
      try {
        return await _isolate.exportCir();
      } catch (_) {}
    }
    return doc.toSpiceCir();
  }

  void dispose() {
    _disposed = true;
    final op = _activeOp;
    _activeOp = null;
    if (op != null && !op.isCompleted) op.complete();
    _isolate.dispose();
    telemetry.dispose();
  }
}
