import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

typedef _CreateNative = Pointer<Void> Function();
typedef _CreateDart = Pointer<Void> Function();

typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _DestroyDart = void Function(Pointer<Void>);

typedef _ClearNative = Int32 Function(Pointer<Void>);
typedef _ClearDart = int Function(Pointer<Void>);

typedef _SetProbeNative = Int32 Function(Pointer<Void>, Uint32, Int32);
typedef _SetProbeDart = int Function(Pointer<Void>, int, int);

typedef _SolveDcNative = Int32 Function(Pointer<Void>);
typedef _SolveDcDart = int Function(Pointer<Void>);

typedef _SetWordGenPatNative = Int32 Function(Pointer<Void>, Uint32, Uint64);
typedef _SetWordGenPatDart = int Function(Pointer<Void>, int, int);

typedef _StepFrameNative = Int32 Function(Pointer<Void>, Double, Uint32, Pointer<Double>);
typedef _StepFrameDart = int Function(Pointer<Void>, double, int, Pointer<Double>);

typedef _SetControlNative = Int32 Function(Pointer<Void>, Uint32, Uint32, Double);
typedef _SetControlDart = int Function(Pointer<Void>, int, int, double);

typedef _SetFaultNative = Int32 Function(Pointer<Void>, Uint32, Int32);
typedef _SetFaultDart = int Function(Pointer<Void>, int, int);

typedef _GetNodeVNative = Double Function(Pointer<Void>, Uint32);
typedef _GetNodeVDart = double Function(Pointer<Void>, int);

typedef _GetCompINative = Double Function(Pointer<Void>, Uint32);
typedef _GetCompIDart = double Function(Pointer<Void>, int);

typedef _ChanStatsNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Double>,
  Pointer<Double>,
  Pointer<Double>,
  Pointer<Double>,
);
typedef _ChanStatsDart = int Function(
  Pointer<Void>,
  int,
  Pointer<Double>,
  Pointer<Double>,
  Pointer<Double>,
  Pointer<Double>,
);

typedef _ScopeFftNative = Size Function(
  Pointer<Void>,
  Uint32,
  Pointer<Double>,
  Size,
);
typedef _ScopeFftDart = int Function(
  Pointer<Void>,
  int,
  Pointer<Double>,
  int,
);

typedef _AcSweepNative = Int32 Function(
  Pointer<Void>,
  Double,
  Double,
  Uint32,
  Uint32,
  Uint32,
  Pointer<Double>,
  Pointer<Double>,
  Pointer<Double>,
  Size,
);
typedef _AcSweepDart = int Function(
  Pointer<Void>,
  double,
  double,
  int,
  int,
  int,
  Pointer<Double>,
  Pointer<Double>,
  Pointer<Double>,
  int,
);

typedef _LogicMinNative = Size Function(Uint32, Uint64, Pointer<Uint8>, Size);
typedef _LogicMinDart = int Function(int, int, Pointer<Uint8>, int);

typedef _LastErrNative = Int32 Function(Pointer<Void>);
typedef _LastErrDart = int Function(Pointer<Void>);

typedef _AddCompExNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Int32,
  Pointer<Uint32>,
  Uint32,
  Pointer<Double>,
  Uint32,
);
typedef _AddCompExDart = int Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Uint32>,
  int,
  Pointer<Double>,
  int,
);

typedef _CompOverloadNative = Int32 Function(Pointer<Void>, Uint32);
typedef _CompOverloadDart = int Function(Pointer<Void>, int);


typedef _MonteCarloNative = Int32 Function(
  Pointer<Void>,
  Double,
  Uint32,
  Uint32,
  Pointer<Double>,
  Pointer<Double>,
  Pointer<Double>,
  Pointer<Double>,
);
typedef _MonteCarloDart = int Function(
  Pointer<Void>,
  double,
  int,
  int,
  Pointer<Double>,
  Pointer<Double>,
  Pointer<Double>,
  Pointer<Double>,
);

typedef _TransferFnNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Uint32,
  Pointer<Double>,
  Pointer<Double>,
  Pointer<Double>,
);
typedef _TransferFnDart = int Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Double>,
  Pointer<Double>,
  Pointer<Double>,
);

typedef _ExportCirNative = Size Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _ExportCirDart = int Function(Pointer<Void>, Pointer<Uint8>, int);

typedef _ReadScopeExNative = Size Function(
  Pointer<Void>,
  Uint32,
  Int32,
  Double,
  Int32,
  Int32,
  Pointer<Double>,
  Pointer<Double>,
  Size,
);
typedef _ReadScopeExDart = int Function(
  Pointer<Void>,
  int,
  int,
  double,
  int,
  int,
  Pointer<Double>,
  Pointer<Double>,
  int,
);

typedef _LogicMinExNative = Size Function(Uint32, Pointer<Uint8>, Size, Pointer<Uint8>, Size);
typedef _LogicMinExDart = int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int);

typedef _SetLogicProbesNative = Int32 Function(Pointer<Void>, Pointer<Int32>, Uint32, Double);
typedef _SetLogicProbesDart = int Function(Pointer<Void>, Pointer<Int32>, int, double);

typedef _ReadLogicNative = Size Function(Pointer<Void>, Pointer<Double>, Pointer<Uint16>, Size);
typedef _ReadLogicDart = int Function(Pointer<Void>, Pointer<Double>, Pointer<Uint16>, int);

typedef _MeasureTwoTermNative = Int32 Function(Pointer<Void>, Uint32, Uint32, Pointer<Double>);
typedef _MeasureTwoTermDart = int Function(Pointer<Void>, int, int, Pointer<Double>);

typedef _IsFuseBlownNative = Int32 Function(Pointer<Void>, Uint32);
typedef _IsFuseBlownDart = int Function(Pointer<Void>, int);

class ChannelStats {
  final double dc;
  final double acRms;
  final double minV;
  final double maxV;
  const ChannelStats(this.dc, this.acRms, this.minV, this.maxV);
}

class AcSweepData {
  final Float64List freqs;
  final Float64List magDb;
  final Float64List phaseDeg;
  const AcSweepData(this.freqs, this.magDb, this.phaseDeg);
}

/// Thin `dart:ffi` binding to `open_bench_sim` (pure Rust).
class SimFfi {
  static DynamicLibrary _openLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libopen_bench_sim.so');
    }
    if (Platform.isIOS) {
      return DynamicLibrary.process();
    }
    if (Platform.isLinux) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final bundled = '$exeDir/lib/libopen_bench_sim.so';
      if (File(bundled).existsSync()) {
        return DynamicLibrary.open(bundled);
      }
      final local = '../rust_core/target/release/libopen_bench_sim.so';
      if (File(local).existsSync()) {
        return DynamicLibrary.open(local);
      }
      return DynamicLibrary.open('libopen_bench_sim.so');
    }
    if (Platform.isMacOS) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final bundled = '$exeDir/../Frameworks/libopen_bench_sim.dylib';
      if (File(bundled).existsSync()) {
        return DynamicLibrary.open(bundled);
      }
      final local = '../rust_core/target/release/libopen_bench_sim.dylib';
      if (File(local).existsSync()) {
        return DynamicLibrary.open(local);
      }
      return DynamicLibrary.open('libopen_bench_sim.dylib');
    }
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final bundled = '$exeDir\\open_bench_sim.dll';
      if (File(bundled).existsSync()) {
        return DynamicLibrary.open(bundled);
      }
      final local = '..\\rust_core\\target\\release\\open_bench_sim.dll';
      if (File(local).existsSync()) {
        return DynamicLibrary.open(local);
      }
      return DynamicLibrary.open('open_bench_sim.dll');
    }
    throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  }

  final DynamicLibrary _lib;
  late final _CreateDart _create;
  late final _DestroyDart _destroy;
  late final _ClearDart _clear;
  late final _SetProbeDart _setProbe;
  late final _SolveDcDart _solveDc;
  late final _SolveDcDart _solveDcOp;
  late final _SetWordGenPatDart _setWordGenPat;
  late final _StepFrameDart _stepFrame;
  late final _SetControlDart _setControl;
  late final _SetFaultDart _setFault;
  late final _GetNodeVDart _getNodeV;
  late final _GetCompIDart _getCompI;
  late final _ReadScopeExDart _readScopeEx;
  late final _ChanStatsDart _chanStats;
  late final _ScopeFftDart _scopeFft;
  late final _AcSweepDart _acSweep;
  late final _LogicMinDart _logicMin;
  late final _LastErrDart _lastErrCode;
  late final _LastErrDart _lastErrDetail;
  late final _AddCompExDart _addCompEx;
  late final _GetCompIDart _getCompPower;
  late final _CompOverloadDart _isOverloaded;
  late final _MonteCarloDart _monteCarlo;
  late final _TransferFnDart _transferFn;
  late final _ExportCirDart _exportCir;

  late final _LogicMinExDart _logicMinEx;
  late final _SetLogicProbesDart _setLogicProbes;
  late final _ReadLogicDart _readLogic;
  late final _MeasureTwoTermDart _measureResistance;
  late final _MeasureTwoTermDart _measureDiode;
  late final _IsFuseBlownDart _isFuseBlown;

  Pointer<Void> _handle = nullptr;
  bool _buffersAllocated = false;

  late final Pointer<Double> _timeOut;
  late final Pointer<Double> _scopeTimes;
  late final Pointer<Double> _scopeVals;
  late final Pointer<Double> _statOut;
  late final Pointer<Double> _fftOut;
  late final Pointer<Double> _acFreqs;
  late final Pointer<Double> _acMags;
  late final Pointer<Double> _acPhases;
  late final Pointer<Uint8> _utf8Scratch;
  late final Pointer<Uint32> _exPins;
  late final Pointer<Double> _exParams;
  late final Pointer<Int32> _logicProbes;
  late final Pointer<Double> _logicTimes;
  late final Pointer<Uint16> _logicMasks;
  late final Pointer<Uint8> _logicMinIn;

  static Pointer<Void> _callocChecked(int count, int size) {
    final p = _libcCalloc(count, size);
    if (p == nullptr) throw StateError('Out of native memory');
    return p;
  }

  static Pointer<Double> _allocDouble(int count) =>
      _callocChecked(count, sizeOf<Double>()).cast<Double>();

  static final DynamicLibrary _libc = Platform.isWindows
      ? DynamicLibrary.open('msvcrt.dll')
      : DynamicLibrary.process();
  static final Pointer<Void> Function(int, int) _libcCalloc = _libc
      .lookup<NativeFunction<Pointer<Void> Function(Size, Size)>>('calloc')
      .asFunction();
  static final void Function(Pointer<Void>) _libcFree = _libc
      .lookup<NativeFunction<Void Function(Pointer<Void>)>>('free')
      .asFunction();

  SimFfi() : _lib = _openLibrary() {
    _create = _lib.lookupFunction<_CreateNative, _CreateDart>('ob_sim_create');
    _destroy = _lib.lookupFunction<_DestroyNative, _DestroyDart>('ob_sim_destroy');
    _clear = _lib.lookupFunction<_ClearNative, _ClearDart>('ob_sim_clear');
    _setProbe = _lib.lookupFunction<_SetProbeNative, _SetProbeDart>('ob_sim_set_scope_probe');
    _solveDc = _lib.lookupFunction<_SolveDcNative, _SolveDcDart>('ob_sim_solve_dc');
    _solveDcOp = _lib.lookupFunction<_SolveDcNative, _SolveDcDart>('ob_sim_solve_dc_op');
    _setWordGenPat = _lib.lookupFunction<_SetWordGenPatNative, _SetWordGenPatDart>(
      'ob_sim_set_wordgen_pattern',
    );
    _stepFrame = _lib.lookupFunction<_StepFrameNative, _StepFrameDart>('ob_sim_step_frame');
    _setControl = _lib.lookupFunction<_SetControlNative, _SetControlDart>('ob_sim_set_control');
    _setFault = _lib.lookupFunction<_SetFaultNative, _SetFaultDart>('ob_sim_set_fault');
    _getNodeV = _lib.lookupFunction<_GetNodeVNative, _GetNodeVDart>('ob_sim_get_node_voltage');
    _getCompI = _lib.lookupFunction<_GetCompINative, _GetCompIDart>('ob_sim_get_component_current');
    _chanStats = _lib.lookupFunction<_ChanStatsNative, _ChanStatsDart>('ob_sim_channel_stats');
    _scopeFft = _lib.lookupFunction<_ScopeFftNative, _ScopeFftDart>('ob_sim_scope_fft');
    _acSweep = _lib.lookupFunction<_AcSweepNative, _AcSweepDart>('ob_sim_ac_sweep');
    _logicMin = _lib.lookupFunction<_LogicMinNative, _LogicMinDart>('ob_logic_minimize');
    _lastErrCode = _lib.lookupFunction<_LastErrNative, _LastErrDart>('ob_sim_last_error_code');
    _lastErrDetail = _lib.lookupFunction<_LastErrNative, _LastErrDart>('ob_sim_last_error_detail');
    _addCompEx = _lib.lookupFunction<_AddCompExNative, _AddCompExDart>('ob_sim_add_component_ex');
    _getCompPower = _lib.lookupFunction<_GetCompINative, _GetCompIDart>(
      'ob_sim_get_component_power',
    );
    _isOverloaded = _lib.lookupFunction<_CompOverloadNative, _CompOverloadDart>(
      'ob_sim_is_component_overloaded',
    );
    _monteCarlo = _lib.lookupFunction<_MonteCarloNative, _MonteCarloDart>(
      'ob_sim_monte_carlo_dc',
    );
    _transferFn = _lib.lookupFunction<_TransferFnNative, _TransferFnDart>(
      'ob_sim_transfer_function',
    );
    _exportCir = _lib.lookupFunction<_ExportCirNative, _ExportCirDart>(
      'ob_sim_export_cir',
    );
    _readScopeEx = _lib.lookupFunction<_ReadScopeExNative, _ReadScopeExDart>(
      'ob_sim_read_scope_ex',
    );
    _logicMinEx = _lib.lookupFunction<_LogicMinExNative, _LogicMinExDart>('ob_logic_minimize_ex');
    _setLogicProbes = _lib.lookupFunction<_SetLogicProbesNative, _SetLogicProbesDart>(
      'ob_sim_set_logic_probes',
    );
    _readLogic = _lib.lookupFunction<_ReadLogicNative, _ReadLogicDart>('ob_sim_read_logic');
    _measureResistance = _lib.lookupFunction<_MeasureTwoTermNative, _MeasureTwoTermDart>(
      'ob_sim_measure_resistance',
    );
    _measureDiode = _lib.lookupFunction<_MeasureTwoTermNative, _MeasureTwoTermDart>(
      'ob_sim_measure_diode',
    );
    _isFuseBlown = _lib.lookupFunction<_IsFuseBlownNative, _IsFuseBlownDart>(
      'ob_sim_is_fuse_blown',
    );

    _handle = _create();
    if (_handle == nullptr) {
      throw StateError('Failed to create native simulation context');
    }
    _timeOut = _allocDouble(1);
    _scopeTimes = _allocDouble(1024);
    _scopeVals = _allocDouble(1024);
    _statOut = _allocDouble(4);
    _fftOut = _allocDouble(256);
    _acFreqs = _allocDouble(256);
    _acMags = _allocDouble(256);
    _acPhases = _allocDouble(256);
    _utf8Scratch = _callocChecked(512, 1).cast<Uint8>();
    _exPins = _callocChecked(8, sizeOf<Uint32>()).cast<Uint32>();
    _exParams = _allocDouble(32);
    _logicProbes = _callocChecked(16, sizeOf<Int32>()).cast<Int32>();
    _logicTimes = _allocDouble(1024);
    _logicMasks = _callocChecked(1024, sizeOf<Uint16>()).cast<Uint16>();
    _logicMinIn = _callocChecked(256, 1).cast<Uint8>();
    _buffersAllocated = true;
  }

  void _ensureOpen() {
    if (!_buffersAllocated || _handle == nullptr) {
      throw StateError('SimFfi has been disposed');
    }
  }

  int clear() {
    _ensureOpen();
    return _clear(_handle);
  }

  int addComponentEx({
    required int id,
    required int type,
    required List<int> pins,
    required List<double> params,
  }) {
    _ensureOpen();
    final pinCount = pins.length.clamp(0, 8);
    for (var i = 0; i < pinCount; i++) {
      _exPins[i] = pins[i];
    }
    final paramCount = params.length.clamp(0, 32);
    for (var i = 0; i < paramCount; i++) {
      _exParams[i] = params[i];
    }
    return _addCompEx(_handle, id, type, _exPins, pinCount, _exParams, paramCount);
  }

  int setScopeProbe(int ch, int nodeId) {
    _ensureOpen();
    return _setProbe(_handle, ch, nodeId);
  }

  int solveDc() {
    _ensureOpen();
    return _solveDc(_handle);
  }

  int solveDcOp() {
    _ensureOpen();
    return _solveDcOp(_handle);
  }

  int setWordGenPattern(int compId, int patternBits) {
    _ensureOpen();
    return _setWordGenPat(_handle, compId, patternBits);
  }

  (int, double) stepFrame(double simDt, {int maxSubsteps = 250}) {
    _ensureOpen();
    final err = _stepFrame(_handle, simDt, maxSubsteps, _timeOut);
    return (err, _timeOut.value);
  }

  int setControl(int compId, int paramIdx, double value) {
    _ensureOpen();
    return _setControl(_handle, compId, paramIdx, value);
  }

  int setFault(int compId, int faultCode) {
    _ensureOpen();
    return _setFault(_handle, compId, faultCode);
  }

  double getNodeVoltage(int nodeId) {
    _ensureOpen();
    return _getNodeV(_handle, nodeId);
  }

  double getComponentCurrent(int compId) {
    _ensureOpen();
    return _getCompI(_handle, compId);
  }

  double getComponentPower(int compId) {
    _ensureOpen();
    return _getCompPower(_handle, compId);
  }

  bool isComponentOverloaded(int compId) {
    _ensureOpen();
    return _isOverloaded(_handle, compId) != 0;
  }

  (double, double, double, double)? monteCarloDc({
    double tol = 0.05,
    int runs = 50,
    required int outNode,
  }) {
    _ensureOpen();
    final rc = _monteCarlo(
      _handle,
      tol,
      runs,
      outNode,
      _statOut,
      Pointer.fromAddress(_statOut.address + sizeOf<Double>()),
      Pointer.fromAddress(_statOut.address + 2 * sizeOf<Double>()),
      Pointer.fromAddress(_statOut.address + 3 * sizeOf<Double>()),
    );
    if (rc != 0) return null;
    return (_statOut[0], _statOut[1], _statOut[2], _statOut[3]);
  }

  (double, double, double)? transferFunction({required int srcId, required int outNode}) {
    _ensureOpen();
    final rc = _transferFn(
      _handle,
      srcId,
      outNode,
      _statOut,
      Pointer.fromAddress(_statOut.address + sizeOf<Double>()),
      Pointer.fromAddress(_statOut.address + 2 * sizeOf<Double>()),
    );
    if (rc != 0) return null;
    return (_statOut[0], _statOut[1], _statOut[2]);
  }

  ChannelStats channelStats(int ch) {
    _ensureOpen();
    final rc = _chanStats(
      _handle,
      ch,
      _statOut,
      Pointer.fromAddress(_statOut.address + sizeOf<Double>()),
      Pointer.fromAddress(_statOut.address + 2 * sizeOf<Double>()),
      Pointer.fromAddress(_statOut.address + 3 * sizeOf<Double>()),
    );
    if (rc != 0) return const ChannelStats(0, 0, 0, 0);
    return ChannelStats(_statOut[0], _statOut[1], _statOut[2], _statOut[3]);
  }

  Float64List readFft(int ch, {int maxBins = 256}) {
    _ensureOpen();
    final cap = maxBins.clamp(1, 256);
    final count = _scopeFft(_handle, ch, _fftOut, cap);
    return Float64List.fromList(_fftOut.asTypedList(count));
  }

  AcSweepData? runAcSweep({
    required double fStart,
    required double fStop,
    required int ptsPerDecade,
    required int acSourceId,
    required int outNode,
  }) {
    _ensureOpen();
    if (!fStart.isFinite || !fStop.isFinite || fStart <= 0 || fStop <= fStart || ptsPerDecade <= 0) {
      return null;
    }
    final decades = math.log(fStop / fStart) / math.ln10;
    final need = ((decades * ptsPerDecade).ceil() + 2).clamp(256, 100002);
    final useTmp = need > 256;
    Pointer<Double> fPtr = useTmp ? nullptr : _acFreqs;
    Pointer<Double> mPtr = useTmp ? nullptr : _acMags;
    Pointer<Double> pPtr = useTmp ? nullptr : _acPhases;
    try {
      if (useTmp) {
        fPtr = _allocDouble(need);
        mPtr = _allocDouble(need);
        pPtr = _allocDouble(need);
      }
      final count = _acSweep(
        _handle,
        fStart,
        fStop,
        ptsPerDecade,
        acSourceId,
        outNode,
        fPtr,
        mPtr,
        pPtr,
        need,
      );
      if (count <= 0) return null;
      final freqs = Float64List(count);
      final mags = Float64List(count);
      final phases = Float64List(count);
      for (var i = 0; i < count; i++) {
        freqs[i] = fPtr[i];
        mags[i] = mPtr[i];
        phases[i] = pPtr[i];
      }
      return AcSweepData(freqs, mags, phases);
    } finally {
      if (useTmp) {
        if (fPtr != nullptr) _libcFree(fPtr.cast());
        if (mPtr != nullptr) _libcFree(mPtr.cast());
        if (pPtr != nullptr) _libcFree(pPtr.cast());
      }
    }
  }

  String _readUtf8Call(int Function(Pointer<Uint8> buf, int cap) fn, String emptyFallback) {
    final need = fn(_utf8Scratch, 512);
    if (need <= 0) return emptyFallback;
    if (need <= 512) {
      return utf8.decode(_utf8Scratch.asTypedList(need), allowMalformed: true);
    }
    final tmp = _callocChecked(need, 1).cast<Uint8>();
    try {
      final got = fn(tmp, need);
      return utf8.decode(tmp.asTypedList(got.clamp(0, need)), allowMalformed: true);
    } finally {
      _libcFree(tmp.cast());
    }
  }

  String minimizeLogic(int varCount, int truthBits) {
    _ensureOpen();
    return _readUtf8Call((buf, cap) => _logicMin(varCount, truthBits, buf, cap), '0');
  }

  (Float64List, Float64List) readScopeEx(
    int ch, {
    int triggerCh = 0,
    double triggerLevel = 0.0,
    bool rising = true,
    bool requireTrigger = false,
    int maxLen = 1024,
    bool includeTimes = true,
  }) {
    _ensureOpen();
    final len = maxLen.clamp(1, 1024);
    final count = _readScopeEx(
      _handle,
      ch,
      triggerCh,
      triggerLevel,
      rising ? 1 : 0,
      requireTrigger ? 1 : 0,
      _scopeTimes,
      _scopeVals,
      len,
    );
    final times = includeTimes ? Float64List.fromList(_scopeTimes.asTypedList(count)) : Float64List(0);
    final vals = Float64List.fromList(_scopeVals.asTypedList(count));
    return (times, vals);
  }

  String minimizeLogicEx(int varCount, List<int> outputs) {
    _ensureOpen();
    final vc = varCount.clamp(1, 8);
    final rows = 1 << vc;
    for (var i = 0; i < rows; i++) {
      _logicMinIn[i] = i < outputs.length ? outputs[i].clamp(0, 2) : 0;
    }
    return _readUtf8Call((buf, cap) => _logicMinEx(vc, _logicMinIn, rows, buf, cap), '0');
  }

  int setLogicProbes(List<int> nodes, {double threshold = 1.5}) {
    _ensureOpen();
    final count = nodes.length.clamp(0, 16);
    for (var i = 0; i < count; i++) {
      _logicProbes[i] = nodes[i];
    }
    return _setLogicProbes(_handle, _logicProbes, count, threshold);
  }

  (Float64List, Uint16List) readLogicSamples({int maxLen = 1024}) {
    _ensureOpen();
    final len = maxLen.clamp(1, 1024);
    final count = _readLogic(_handle, _logicTimes, _logicMasks, len);
    return (
      Float64List.fromList(_logicTimes.asTypedList(count)),
      Uint16List.fromList(_logicMasks.asTypedList(count)),
    );
  }

  double? measureResistance(int nodeA, int nodeB) {
    _ensureOpen();
    return _measureResistance(_handle, nodeA, nodeB, _statOut) == 0 ? _statOut[0] : null;
  }

  double? measureDiode(int nodeA, int nodeB) {
    _ensureOpen();
    return _measureDiode(_handle, nodeA, nodeB, _statOut) == 0 ? _statOut[0] : null;
  }

  bool isFuseBlown(int compId) {
    _ensureOpen();
    return _isFuseBlown(_handle, compId) != 0;
  }

  /// Exports the compiled circuit via Rust's canonical `spice_io::export_cir`.
  String exportCir() {
    _ensureOpen();
    return _readUtf8Call((buf, cap) => _exportCir(_handle, buf, cap), '* Empty circuit\n.end\n');
  }

  (int, int) lastError() {
    _ensureOpen();
    return (_lastErrCode(_handle), _lastErrDetail(_handle));
  }

  void dispose() {
    if (_handle != nullptr) {
      _destroy(_handle);
      _handle = nullptr;
    }
    if (_buffersAllocated) {
      _libcFree(_timeOut.cast());
      _libcFree(_scopeTimes.cast());
      _libcFree(_scopeVals.cast());
      _libcFree(_statOut.cast());
      _libcFree(_fftOut.cast());
      _libcFree(_acFreqs.cast());
      _libcFree(_acMags.cast());
      _libcFree(_acPhases.cast());
      _libcFree(_utf8Scratch.cast());
      _libcFree(_exPins.cast());
      _libcFree(_exParams.cast());
      _libcFree(_logicProbes.cast());
      _libcFree(_logicTimes.cast());
      _libcFree(_logicMasks.cast());
      _libcFree(_logicMinIn.cast());
      _buffersAllocated = false;
    }
  }
}
