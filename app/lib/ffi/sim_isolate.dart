import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'sim_ffi.dart';

export 'sim_ffi.dart' show AcSweepData, ChannelStats;

/// Computes Total Harmonic Distortion (%) directly from FFT magnitude bins.
double computeThdFromFftBins(Float64List mags) {
  if (mags.length < 4) return 0.0;
  var fundBin = 1;
  var fundMag = mags[1];
  for (var i = 2; i < mags.length; i++) {
    if (mags[i] > fundMag) {
      fundMag = mags[i];
      fundBin = i;
    }
  }
  if (fundMag <= 1e-12) return 0.0;
  final fLo = math.max(1, fundBin - 1);
  final fHi = math.min(mags.length - 1, fundBin + 1);
  var fundSq = 0.0;
  for (var i = fLo; i <= fHi; i++) {
    fundSq += mags[i] * mags[i];
  }
  final fundRss = math.sqrt(fundSq);
  var harmSq = 0.0;
  final minHarmBin = fundBin + 2;
  for (var k = 2; k <= 10; k++) {
    final center = fundBin * k;
    if (center >= mags.length) break;
    final lo = math.max(minHarmBin, center - 1);
    final hi = math.min(mags.length - 1, center + 1);
    if (lo > hi) continue;
    for (var i = lo; i <= hi; i++) {
      harmSq += mags[i] * mags[i];
    }
  }
  return 100.0 * math.sqrt(harmSq) / math.max(fundRss, fundMag);
}

class IsolateCompSpec {
  final int id;
  final int ffiType;
  final List<int> nodes;
  final List<double> params;
  final int? wordGenBits;
  final int faultIndex;

  const IsolateCompSpec({
    required this.id,
    required this.ffiType,
    required this.nodes,
    required this.params,
    this.wordGenBits,
    this.faultIndex = 0,
  });
}

class SimSnapshot {
  final int errCode;
  final int errDetail;
  final double tSim;
  final Map<int, double> nodeVoltages;
  final Map<int, double> compCurrents;
  final Map<int, double> compPowers;
  final Set<int> overloadedIds;
  final Set<int> blownFuseIds;
  final Float64List ch1Times;
  final Float64List ch1;
  final Float64List ch2;
  final Float64List ch3;
  final Float64List ch4;
  final Float64List fft;
  final double ch1Thd;
  final Float64List spectrumFft;
  final double spectrumThd;
  final double fftDt;
  final bool scopeTriggered;
  final Float64List logicTimes;
  final Uint16List logicMasks;
  final ChannelStats ch1Stats;
  final ChannelStats ch2Stats;
  final ChannelStats ch3Stats;
  final ChannelStats ch4Stats;

  SimSnapshot({
    required this.errCode,
    required this.errDetail,
    required this.tSim,
    required this.nodeVoltages,
    required this.compCurrents,
    required this.compPowers,
    required this.overloadedIds,
    this.blownFuseIds = const {},
    required this.ch1Times,
    required this.ch1,
    required this.ch2,
    required this.ch3,
    required this.ch4,
    required this.fft,
    required this.ch1Thd,
    Float64List? spectrumFft,
    double? spectrumThd,
    this.fftDt = 0.0,
    this.scopeTriggered = true,
    Float64List? logicTimes,
    Uint16List? logicMasks,
    required this.ch1Stats,
    required this.ch2Stats,
    this.ch3Stats = const ChannelStats(0, 0, 0, 0),
    this.ch4Stats = const ChannelStats(0, 0, 0, 0),
  })  : spectrumFft = spectrumFft ?? fft,
        spectrumThd = spectrumThd ?? ch1Thd,
        logicTimes = logicTimes ?? Float64List(0),
        logicMasks = logicMasks ?? Uint16List(0);
}

/// Runs `SimFfi` simulation steps, sweeps, and Monte Carlo off the Flutter UI thread.
class SimRunnerIsolate {
  Isolate? _isolate;
  SendPort? _workerPort;
  final ReceivePort _rx = ReceivePort();
  final ReceivePort _errRx = ReceivePort();
  final ReceivePort _exitRx = ReceivePort();
  final Completer<void> _ready = Completer<void>();
  Future<void>? _startFuture;
  int _nextReqId = 1;
  final Map<int, Completer<dynamic>> _pending = {};
  bool _disposed = false;
  bool _workerDead = false;

  void _failAllPending(Object error) {
    if (!_ready.isCompleted) {
      _ready.future.ignore();
      _ready.completeError(error);
    }
    final stateErr = error is StateError ? error : StateError(error.toString());
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(stateErr);
    }
    _pending.clear();
  }

  Future<void> ensureStarted() => _startFuture ??= () async {
        if (_disposed) throw StateError('SimRunnerIsolate disposed');
        if (_workerDead) throw StateError('SimRunnerIsolate worker terminated');
        _errRx.listen((_) {
          if (!_disposed) {
            _workerDead = true;
            _workerPort = null;
            _failAllPending('SimRunnerIsolate worker terminated');
          }
        });
        _exitRx.listen((_) {
          if (!_disposed) {
            _workerDead = true;
            _workerPort = null;
            _failAllPending('SimRunnerIsolate worker terminated');
          }
        });
        _rx.listen((msg) {
          if (msg is SendPort) {
            if (_disposed) {
              msg.send({'id': -1, 'op': 'dispose'});
              return;
            }
            _workerPort = msg;
            if (!_ready.isCompleted) _ready.complete();
            return;
          }
          if (msg is List && msg.length >= 2) {
            final id = msg[0] as int;
            final c = _pending.remove(id);
            if (msg.length >= 3 && msg[2] != null) {
              c?.completeError(StateError(msg[2].toString()));
            } else {
              c?.complete(msg[1]);
            }
          }
        });
        final Isolate spawned;
        try {
          spawned = await Isolate.spawn(
            _workerEntry,
            _rx.sendPort,
            onError: _errRx.sendPort,
            onExit: _exitRx.sendPort,
          );
        } catch (e) {
          _failAllPending(e);
          _errRx.close();
          _exitRx.close();
          _rx.close();
          rethrow;
        }
        _isolate = spawned;
        if (_disposed) {
          spawned.kill(priority: Isolate.immediate);
          _errRx.close();
          _exitRx.close();
          _rx.close();
          throw StateError('SimRunnerIsolate disposed');
        }
        return _ready.future;
      }();

  Future<T> _call<T>(String op, [Map<String, dynamic> args = const {}]) async {
    if (_disposed) throw StateError('SimRunnerIsolate disposed');
    if (_workerDead) throw StateError('SimRunnerIsolate worker terminated');
    await ensureStarted();
    if (_disposed) throw StateError('SimRunnerIsolate disposed');
    if (_workerDead) throw StateError('SimRunnerIsolate worker terminated');
    final port = _workerPort;
    if (port == null) throw StateError('SimRunnerIsolate worker terminated');
    final id = _nextReqId++;
    final completer = Completer<T>();
    _pending[id] = completer;
    port.send({'id': id, 'op': op, ...args});
    return completer.future;
  }

  Future<SimSnapshot> sync({
    required List<IsolateCompSpec> comps,
    required List<int> probes,
    required List<int> nodeIds,
    int? trigCh,
    double? trigLevel,
    bool? rising,
    bool? requireTrigger,
    int? fftCh,
    bool? needFft,
    List<int>? logicNodes,
    double? logicThreshold,
  }) =>
      _call<SimSnapshot>('sync', {
        'comps': comps,
        'probes': probes,
        'nodeIds': nodeIds,
        'trigCh': ?trigCh,
        'trigLevel': ?trigLevel,
        'rising': ?rising,
        'require': ?requireTrigger,
        'fftCh': ?fftCh,
        'needFft': ?needFft,
        'logicNodes': ?logicNodes,
        'logicThresh': ?logicThreshold,
      });

  Future<SimSnapshot> step(double simDt, {int maxSubsteps = 250}) =>
      _call<SimSnapshot>('step', {'dt': simDt, 'max': maxSubsteps});

  Future<SimSnapshot> setControl(int compId, int paramIdx, double value, {bool solveDc = true}) =>
      _call<SimSnapshot>('control', {
        'compId': compId,
        'paramIdx': paramIdx,
        'value': value,
        'solveDc': solveDc,
      });

  Future<SimSnapshot> setFault(int compId, int faultCode, {bool solveDc = true}) =>
      _call<SimSnapshot>('fault', {
        'compId': compId,
        'faultCode': faultCode,
        'solveDc': solveDc,
      });

  Future<SimSnapshot> setScopeConfig({
    int trigCh = 0,
    double trigLevel = 0.0,
    bool rising = true,
    bool requireTrigger = false,
    int fftCh = 0,
    bool needFft = true,
  }) =>
      _call<SimSnapshot>('scopeConfig', {
        'trigCh': trigCh,
        'trigLevel': trigLevel,
        'rising': rising,
        'require': requireTrigger,
        'fftCh': fftCh,
        'needFft': needFft,
      });

  Future<SimSnapshot> setLogicProbes(List<int> nodes, {double threshold = 1.5}) =>
      _call<SimSnapshot>('logicProbes', {'nodes': nodes, 'threshold': threshold});

  Future<void> setWordGenPattern(int compId, int patternBits) =>
      _call<void>('wordGenPat', {'compId': compId, 'pattern': patternBits});

  Future<double?> measureTwoTerminal(int nodeA, int nodeB, {bool diodeMode = false}) =>
      _call<double?>('measureTwoTerm', {'nodeA': nodeA, 'nodeB': nodeB, 'diode': diodeMode});

  Future<String> minimizeLogicEx(int varCount, List<int> outputs) =>
      _call<String>('minimizeLogicEx', {'vars': varCount, 'outputs': outputs});

  Future<String> exportCir() => _call<String>('exportCir');

  Future<AcSweepData?> acSweepTransfer({
    required double fStart,
    required double fStop,
    required int ptsPerDecade,
    required int acSourceId,
    required int outNode,
    int inNode = -1,
  }) =>
      _call<AcSweepData?>('acSweepEx', {
        'fStart': fStart,
        'fStop': fStop,
        'pts': ptsPerDecade,
        'srcId': acSourceId,
        'inNode': inNode,
        'outNode': outNode,
      });

  Future<(Float64List, Float64List, Float64List)> dcSweepEx({
    required int srcId,
    int paramIdx = 0,
    required double origVal,
    required double vStart,
    required double vStop,
    required int ch1Node,
    required int ch2Node,
    int? currentCompId,
    int steps = 25,
  }) =>
      _call<(Float64List, Float64List, Float64List)>('dcSweepEx', {
        'srcId': srcId,
        'paramIdx': paramIdx,
        'origVal': origVal,
        'vStart': vStart,
        'vStop': vStop,
        'ch1Node': ch1Node,
        'ch2Node': ch2Node,
        'curCompId': currentCompId,
        'steps': steps,
      });

  Future<(double min, double max, double mean, double std, Float64List samples)?> monteCarloEx({
    double tol = 0.05,
    int runs = 50,
    required int outNode,
    bool gaussian = false,
  }) =>
      _call<(double, double, double, double, Float64List)?>('monteCarloEx', {
        'tol': tol,
        'runs': runs,
        'outNode': outNode,
        'gaussian': gaussian,
      });

  Future<List<int>?> extractTruthTable({
    required List<IsolateCompSpec> comps,
    required List<int> inputNodes,
    required int outputNode,
    double vHigh = 5.0,
  }) =>
      _call<List<int>?>('extractTt', {
        'comps': comps,
        'inNodes': inputNodes,
        'outNode': outputNode,
        'vHigh': vHigh,
      });

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_workerPort != null) {
      _workerPort!.send({'id': -1, 'op': 'dispose'});
    } else {
      _isolate?.kill(priority: Isolate.immediate);
    }
    _failAllPending(StateError('SimRunnerIsolate disposed'));
    _errRx.close();
    _exitRx.close();
    _rx.close();
  }

  static void _workerEntry(SendPort mainPort) {
    final rx = ReceivePort();
    final sim = SimFfi();
    mainPort.send(rx.sendPort);
    var nodeIds = <int>[];
    var compIds = <int>[];
    var errCode = 0;
    var errDetail = 0;
    var tSim = 0.0;
    var trigCh = 0;
    var trigLevel = 0.0;
    var trigRising = true;
    var trigRequire = false;
    var fftCh = 0;
    var needFft = true;
    var logicNodes = <int>[];
    var logicThresh = 1.5;

    SimSnapshot buildSnapshot() {
      final (nv, ci, cp, over, blown) = errCode == 0
          ? sim.readFrameState(nodeIds, compIds)
          : (<int, double>{}, <int, double>{}, <int, double>{}, <int>{}, <int>{});
      final (t1, v1, v2, v3, v4) = sim.readScope4Ch(
        triggerCh: trigCh,
        triggerLevel: trigLevel,
        rising: trigRising,
        requireTrigger: trigRequire,
        maxLen: 1024,
      );
      final triggered = !trigRequire || t1.isNotEmpty;
      final (lt, lm) = logicNodes.isNotEmpty
          ? sim.readLogicSamples(maxLen: 1024)
          : (Float64List(0), Uint16List(0));
      final ch1Fft = needFft ? sim.readFft(0, maxBins: 256) : Float64List(0);
      final ch1Thd = needFft ? computeThdFromFftBins(ch1Fft) : 0.0;
      final specFft = !needFft
          ? Float64List(0)
          : (fftCh == 0 ? ch1Fft : sim.readFft(fftCh, maxBins: 256));
      final specThd = !needFft
          ? 0.0
          : (fftCh == 0 ? ch1Thd : computeThdFromFftBins(specFft));
      return SimSnapshot(
        errCode: errCode,
        errDetail: errDetail,
        tSim: tSim,
        nodeVoltages: nv,
        compCurrents: ci,
        compPowers: cp,
        overloadedIds: over,
        blownFuseIds: blown,
        ch1Times: t1,
        ch1: v1,
        ch2: v2,
        ch3: v3,
        ch4: v4,
        fft: ch1Fft,
        ch1Thd: ch1Thd,
        spectrumFft: specFft,
        spectrumThd: specThd,
        fftDt: needFft ? sim.scopeFftDt() : 0.0,
        scopeTriggered: triggered,
        logicTimes: lt,
        logicMasks: lm,
        ch1Stats: sim.channelStats(0),
        ch2Stats: sim.channelStats(1),
        ch3Stats: sim.channelStats(2),
        ch4Stats: sim.channelStats(3),
      );
    }

    rx.listen((msg) {
      if (msg is! Map) return;
      final id = msg['id'] as int;
      final op = msg['op'] as String;
      if (op == 'dispose') {
        sim.dispose();
        rx.close();
        return;
      }
      try {
      switch (op) {
        case 'sync':
          sim.clear();
          if (msg.containsKey('trigCh')) trigCh = msg['trigCh'] as int;
          if (msg.containsKey('trigLevel')) trigLevel = msg['trigLevel'] as double;
          if (msg.containsKey('rising')) trigRising = msg['rising'] as bool;
          if (msg.containsKey('require')) trigRequire = msg['require'] as bool;
          if (msg.containsKey('fftCh')) fftCh = msg['fftCh'] as int;
          if (msg.containsKey('needFft')) needFft = msg['needFft'] as bool;
          if (msg.containsKey('logicNodes')) {
            logicNodes = List<int>.from(msg['logicNodes'] as List);
          }
          if (msg.containsKey('logicThresh')) {
            logicThresh = msg['logicThresh'] as double;
          }
          final comps = msg['comps'] as List<IsolateCompSpec>;
          final probes = msg['probes'] as List<int>;
          nodeIds = msg['nodeIds'] as List<int>;
          compIds = [for (final c in comps) c.id];
          errCode = 0;
          errDetail = 0;
          tSim = 0.0;
          for (final c in comps) {
            final rc = sim.addComponentEx(
              id: c.id,
              type: c.ffiType,
              pins: c.nodes,
              params: c.params,
            );
            if (rc != 0) {
              (errCode, errDetail) = sim.lastError();
              break;
            }
            if (c.wordGenBits != null) {
              sim.setWordGenPattern(c.id, c.wordGenBits!);
            }
            if (c.faultIndex != 0) {
              sim.setFault(c.id, c.faultIndex);
            }
          }
          if (errCode == 0) {
            for (var ch = 0; ch < 4; ch++) {
              sim.setScopeProbe(ch, ch < probes.length ? probes[ch] : -1);
            }
            if (logicNodes.isNotEmpty) {
              sim.setLogicProbes(logicNodes, threshold: logicThresh);
            }
            final dcErr = sim.solveDc();
            if (dcErr != 0) (errCode, errDetail) = sim.lastError();
          }
          mainPort.send([id, buildSnapshot()]);
        case 'step':
          if (errCode == 0) {
            final dt = msg['dt'] as double;
            final maxSub = msg['max'] as int;
            final (err, t) = sim.stepFrame(dt, maxSubsteps: maxSub);
            if (err != 0) {
              (errCode, errDetail) = sim.lastError();
            } else {
              tSim = t;
            }
          }
          mainPort.send([id, buildSnapshot()]);
        case 'scopeConfig':
          trigCh = msg['trigCh'] as int;
          trigLevel = msg['trigLevel'] as double;
          trigRising = msg['rising'] as bool;
          trigRequire = msg['require'] as bool;
          fftCh = msg['fftCh'] as int;
          needFft = msg['needFft'] as bool;
          mainPort.send([id, buildSnapshot()]);
        case 'logicProbes':
          logicNodes = List<int>.from(msg['nodes'] as List);
          logicThresh = msg['threshold'] as double;
          sim.setLogicProbes(logicNodes, threshold: logicThresh);
          mainPort.send([id, buildSnapshot()]);
        case 'wordGenPat':
          sim.setWordGenPattern(msg['compId'] as int, msg['pattern'] as int);
          mainPort.send([id, null]);
        case 'measureTwoTerm':
          final na = msg['nodeA'] as int;
          final nb = msg['nodeB'] as int;
          final dio = msg['diode'] as bool;
          mainPort.send([id, dio ? sim.measureDiode(na, nb) : sim.measureResistance(na, nb)]);
        case 'minimizeLogicEx':
          final vars = msg['vars'] as int;
          final outs = List<int>.from(msg['outputs'] as List);
          mainPort.send([id, sim.minimizeLogicEx(vars, outs)]);
        case 'exportCir':
          mainPort.send([id, sim.exportCir()]);
        case 'control':
          sim.setControl(msg['compId'] as int, msg['paramIdx'] as int, msg['value'] as double);
          if (msg['solveDc'] as bool) {
            final dcErr = sim.solveDcOp();
            if (dcErr != 0) {
              (errCode, errDetail) = sim.lastError();
            } else {
              errCode = 0;
              errDetail = 0;
            }
          }
          mainPort.send([id, buildSnapshot()]);
        case 'fault':
          sim.setFault(msg['compId'] as int, msg['faultCode'] as int);
          if (msg['solveDc'] as bool) {
            final dcErr = sim.solveDcOp();
            if (dcErr != 0) {
              (errCode, errDetail) = sim.lastError();
            } else {
              errCode = 0;
              errDetail = 0;
            }
          }
          mainPort.send([id, buildSnapshot()]);
        case 'acSweepEx':
          final fStart = msg['fStart'] as double;
          final fStop = msg['fStop'] as double;
          final pts = msg['pts'] as int;
          final srcId = msg['srcId'] as int;
          final inNode = msg['inNode'] as int;
          final outNode = msg['outNode'] as int;
          final outData = sim.runAcSweepTransfer(
            fStart: fStart,
            fStop: fStop,
            ptsPerDecade: pts,
            acSourceId: srcId,
            inNode: inNode,
            outNode: outNode,
          );
          mainPort.send([id, outData]);
        case 'dcSweepEx':
          final srcId = msg['srcId'] as int;
          final pIdx = msg['paramIdx'] as int;
          final origV = msg['origVal'] as double;
          final vStart = msg['vStart'] as double;
          final vStop = msg['vStop'] as double;
          final ch1N = msg['ch1Node'] as int;
          final ch2N = msg['ch2Node'] as int;
          final curId = msg['curCompId'] as int?;
          final steps = (msg['steps'] as int).clamp(2, 200);
          final vin = Float64List(steps);
          final ch1 = Float64List(steps);
          final ch2 = Float64List(steps);
          for (var i = 0; i < steps; i++) {
            final v = vStart + (vStop - vStart) * (i / (steps - 1));
            vin[i] = v;
            sim.setControl(srcId, pIdx, v);
            if (sim.solveDcOp() == 0) {
              ch1[i] = sim.getNodeVoltage(ch1N);
              ch2[i] = curId != null ? sim.getComponentCurrent(curId) : sim.getNodeVoltage(ch2N);
            } else {
              ch1[i] = double.nan;
              ch2[i] = double.nan;
            }
          }
          sim.setControl(srcId, pIdx, origV);
          sim.solveDcOp();
          mainPort.send([id, (vin, ch1, ch2)]);
        case 'monteCarloEx':
          final tol = (msg['tol'] as double).clamp(0.001, 0.5);
          final runs = (msg['runs'] as int).clamp(2, 400);
          final outNode = msg['outNode'] as int;
          final gaussian = msg['gaussian'] as bool;
          mainPort.send([
            id,
            sim.monteCarloDcEx(tol: tol, runs: runs, outNode: outNode, gaussian: gaussian),
          ]);
        case 'extractTt':
          final comps = msg['comps'] as List<IsolateCompSpec>;
          final inNodes = List<int>.from(msg['inNodes'] as List);
          final outNode = msg['outNode'] as int;
          final vHigh = msg['vHigh'] as double;
          if (inNodes.isEmpty || inNodes.length > 6 || outNode <= 0) {
            mainPort.send([id, null]);
          } else {
            final tmp = SimFfi();
            try {
              final inSet = inNodes.toSet();
              var maxId = 0;
              for (final c in comps) {
                if (c.id > maxId) maxId = c.id;
                final isVsrcDrivingIn = (c.ffiType == 10 || c.ffiType == 36) &&
                    c.nodes.isNotEmpty &&
                    inSet.contains(c.nodes[0]);
                if (isVsrcDrivingIn) continue;
                tmp.addComponentEx(
                  id: c.id,
                  type: c.ffiType,
                  pins: c.nodes,
                  params: c.params,
                );
                if (c.wordGenBits != null) {
                  tmp.setWordGenPattern(c.id, c.wordGenBits!);
                }
                if (c.faultIndex != 0) {
                  tmp.setFault(c.id, c.faultIndex);
                }
              }
              final baseId = maxId + 1;
              for (var k = 0; k < inNodes.length; k++) {
                tmp.addComponentEx(
                  id: baseId + k,
                  type: 10,
                  pins: [inNodes[k], 0],
                  params: [0.0],
                );
              }
              final rows = 1 << inNodes.length;
              final out = List<int>.filled(rows, 0);
              var ok = tmp.solveDc() == 0;
              if (ok) {
                for (var r = 0; r < rows; r++) {
                  for (var k = 0; k < inNodes.length; k++) {
                    final bit = (r >> (inNodes.length - 1 - k)) & 1;
                    tmp.setControl(baseId + k, 0, bit == 1 ? vHigh : 0.0);
                  }
                  if (tmp.solveDcOp() == 0) {
                    out[r] = tmp.getNodeVoltage(outNode) >= 0.5 * vHigh ? 1 : 0;
                  } else {
                    ok = false;
                    break;
                  }
                }
              }
              mainPort.send([id, ok ? out : null]);
            } finally {
              tmp.dispose();
            }
          }
      }
      } catch (e) {
        mainPort.send([id, null, e.toString()]);
      }
    });
  }
}
