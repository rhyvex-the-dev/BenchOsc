import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../state/circuit_doc.dart';
import '../theme/circuit_theme.dart';
import 'spectrum_analyzer_view.dart' show fftMagToRmsDbv;

enum ScopeDisplayMode { time, xy, fft }
enum ScopeCoupling { dc, ac, gnd }
enum ScopeMathMode { off, diff, sum }
enum ScopeTriggerMode { auto, normal, single }

const _kMathColor = Color(0xFFFF7043);

class _ChConfig {
  double vPerDiv = 2.0;
  double offsetDiv = 0.0;
  ScopeCoupling coupling = ScopeCoupling.dc;
}

String _fmtSec(double s) {
  final a = s.abs();
  if (a < 1e-6) return '${(s * 1e9).toStringAsFixed(1)}ns';
  if (a < 1e-3) return '${(s * 1e6).toStringAsFixed(1)}µs';
  if (a < 1.0) return '${(s * 1e3).toStringAsFixed(2)}ms';
  return '${s.toStringAsFixed(2)}s';
}

double? _measureDutyPercent(Float64List vals, Float64List? times) {
  if (vals.length < 4 || times == null || times.length != vals.length) return null;
  var minV = double.infinity;
  var maxV = double.negativeInfinity;
  for (var i = 0; i < vals.length; i++) {
    final v = vals[i];
    if (!v.isFinite) continue;
    if (v < minV) minV = v;
    if (v > maxV) maxV = v;
  }
  if (!minV.isFinite || !maxV.isFinite || maxV - minV <= 1e-3) return null;
  final mid = 0.5 * (minV + maxV);
  var totalDt = 0.0, hiDt = 0.0;
  for (var i = 1; i < vals.length; i++) {
    if (!vals[i - 1].isFinite || !vals[i].isFinite || !times[i - 1].isFinite || !times[i].isFinite) {
      continue;
    }
    final dt = times[i] - times[i - 1];
    if (dt <= 0) continue;
    totalDt += dt;
    if (0.5 * (vals[i - 1] + vals[i]) >= mid) hiDt += dt;
  }
  return totalDt > 1e-12 ? (100.0 * hiDt / totalDt) : null;
}

class OscilloscopeView extends StatefulWidget {
  final Float64List ch1Values;
  final Float64List ch2Values;
  final Float64List? ch3Values;
  final Float64List? ch4Values;
  final Float64List? ch1Times;
  final Float64List fftBins;
  final double ch1Dc;
  final double ch2Dc;
  final double ch3Dc;
  final double ch4Dc;
  final double thdPercent;
  final bool triggered;
  final bool ch3Probed;
  final bool ch4Probed;
  final void Function(int trigCh, double level, bool rising, bool requireTrigger)? onTriggerConfigChanged;
  final ValueChanged<bool>? onFftModeChanged;
  final String title;

  const OscilloscopeView({
    super.key,
    required this.ch1Values,
    required this.ch2Values,
    this.ch3Values,
    this.ch4Values,
    this.ch1Times,
    required this.fftBins,
    this.ch1Dc = 0,
    this.ch2Dc = 0,
    this.ch3Dc = 0,
    this.ch4Dc = 0,
    this.thdPercent = 0,
    this.triggered = true,
    this.ch3Probed = false,
    this.ch4Probed = false,
    this.onTriggerConfigChanged,
    this.onFftModeChanged,
    required this.title,
  });

  @override
  State<OscilloscopeView> createState() => _OscilloscopeViewState();
}

int _findTriggerStart(Float64List vals, double level, {required bool rising}) {
  if (vals.length < 4) return 0;
  final limit = vals.length ~/ 2;
  for (var i = 1; i < limit; i++) {
    final hit = rising
        ? (vals[i - 1] < level && vals[i] >= level)
        : (vals[i - 1] > level && vals[i] <= level);
    if (hit) return i;
  }
  return 0;
}

class _OscilloscopeViewState extends State<OscilloscopeView> {
  static final Float64List _emptyTrace = Float64List(0);
  ScopeDisplayMode _mode = ScopeDisplayMode.time;
  ScopeMathMode _mathMode = ScopeMathMode.off;
  ScopeTriggerMode _trigMode = ScopeTriggerMode.auto;
  final List<_ChConfig> _chCfg = List.generate(4, (_) => _ChConfig());
  int _selectedCh = 0; // Active channel for V/div, offset, coupling, & measure/cursor
  int _trigCh = 0;
  double _triggerLevel = 0.0;
  bool _risingEdge = true;
  bool _hold = false;
  bool _singleArmed = false;
  bool _singleArmedPending = false;
  double _secPerDiv = 5e-3;
  bool _en1 = true;
  bool _en2 = true;
  bool _en3 = false;
  bool _en4 = false;
  int _activeCursor = 1; // 1 = C1, 2 = C2
  double? _c1Frac;
  double? _c2Frac;
  bool _fftDbv = true;

  Float64List _heldCh1 = Float64List(0);
  Float64List _heldCh2 = Float64List(0);
  Float64List _heldCh3 = Float64List(0);
  Float64List _heldCh4 = Float64List(0);
  Float64List? _heldTimes;
  Float64List _heldFft = Float64List(0);
  double _heldDc1 = 0, _heldDc2 = 0, _heldDc3 = 0, _heldDc4 = 0, _heldThd = 0;

  Float64List? _lastRaw1, _lastRaw2, _lastRaw3, _lastRaw4, _lastTimes;
  final List<ScopeCoupling> _lastCouplings = List.filled(4, ScopeCoupling.dc);
  List<Float64List> _cachedCh = const [];
  ScopeMathMode? _lastMathMode;
  Float64List _cachedMath = Float64List(0);
  int _lastMeasCh = -1;
  (double, double?) _cachedMeas = (0.0, null);
  double? _cachedDuty;

  @override
  void initState() {
    super.initState();
    _en3 = widget.ch3Probed;
    _en4 = widget.ch4Probed;
  }

  @override
  void didUpdateWidget(covariant OscilloscopeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ch3Probed && !oldWidget.ch3Probed) _en3 = true;
    if (widget.ch4Probed && !oldWidget.ch4Probed) _en4 = true;
    if (_singleArmedPending) {
      _singleArmedPending = false;
    } else if (_singleArmed && widget.triggered) {
      final trigSamples = switch (_trigCh) {
        1 => widget.ch2Values,
        2 => widget.ch3Values ?? Float64List(0),
        3 => widget.ch4Values ?? Float64List(0),
        _ => widget.ch1Values,
      };
      if (trigSamples.isNotEmpty) {
        _latchHoldFromWidget();
        _singleArmed = false;
        _hold = true;
      }
    } else if (_trigMode == ScopeTriggerMode.normal &&
        widget.triggered &&
        widget.ch1Values.isNotEmpty) {
      _latchHoldFromWidget();
    }
  }

  void _pushTrigConfig() {
    widget.onTriggerConfigChanged?.call(
      _trigCh,
      _triggerLevel,
      _risingEdge,
      _trigMode != ScopeTriggerMode.auto,
    );
  }

  void _clearHeld() {
    _heldCh1 = Float64List(0);
    _heldCh2 = Float64List(0);
    _heldCh3 = Float64List(0);
    _heldCh4 = Float64List(0);
    _heldTimes = null;
    _heldFft = Float64List(0);
    _heldDc1 = 0;
    _heldDc2 = 0;
    _heldDc3 = 0;
    _heldDc4 = 0;
    _heldThd = 0;
  }

  void _latchHoldFromWidget() {
    _heldCh1 = Float64List.fromList(widget.ch1Values);
    _heldCh2 = Float64List.fromList(widget.ch2Values);
    _heldCh3 = Float64List.fromList(widget.ch3Values ?? Float64List(0));
    _heldCh4 = Float64List.fromList(widget.ch4Values ?? Float64List(0));
    _heldTimes = widget.ch1Times != null ? Float64List.fromList(widget.ch1Times!) : null;
    _heldFft = Float64List.fromList(widget.fftBins);
    _heldDc1 = widget.ch1Dc;
    _heldDc2 = widget.ch2Dc;
    _heldDc3 = widget.ch3Dc;
    _heldDc4 = widget.ch4Dc;
    _heldThd = widget.thdPercent;
  }

  Float64List _applyCoupling(Float64List raw, ScopeCoupling c) {
    if (raw.isEmpty || c == ScopeCoupling.dc) return raw;
    final out = Float64List(raw.length);
    if (c == ScopeCoupling.gnd) return out;
    var mean = 0.0;
    for (var i = 0; i < raw.length; i++) {
      mean += raw[i];
    }
    mean /= raw.length;
    for (var i = 0; i < raw.length; i++) {
      out[i] = raw[i] - mean;
    }
    return out;
  }

  Float64List _buildMath(Float64List a, Float64List b) {
    if (_mathMode == ScopeMathMode.off) return Float64List(0);
    final n = math.min(a.length, b.length);
    final out = Float64List(n);
    final sign = _mathMode == ScopeMathMode.diff ? -1.0 : 1.0;
    for (var i = 0; i < n; i++) {
      out[i] = a[i] + sign * b[i];
    }
    return out;
  }

  void _toggleHold() {
    setState(() {
      _hold = !_hold;
      _singleArmed = false;
      _singleArmedPending = false;
      if (_hold && !(_trigMode == ScopeTriggerMode.normal && !widget.triggered)) {
        _latchHoldFromWidget();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CircuitColors>()!;
    final l10n = AppLocalizations.of(context)!;
    final useHeld = _hold || (_trigMode == ScopeTriggerMode.normal && !widget.triggered);
    final raw1 = useHeld ? _heldCh1 : widget.ch1Values;
    final raw2 = useHeld ? _heldCh2 : widget.ch2Values;
    final raw3 = useHeld ? _heldCh3 : (widget.ch3Values ?? _emptyTrace);
    final raw4 = useHeld ? _heldCh4 : (widget.ch4Values ?? _emptyTrace);
    final times = useHeld ? _heldTimes : widget.ch1Times;
    final fft = useHeld ? _heldFft : widget.fftBins;
    final dc1 = useHeld ? _heldDc1 : widget.ch1Dc;
    final dc2 = useHeld ? _heldDc2 : widget.ch2Dc;
    final dc3 = useHeld ? _heldDc3 : widget.ch3Dc;
    final dc4 = useHeld ? _heldDc4 : widget.ch4Dc;
    final thd = useHeld ? _heldThd : widget.thdPercent;

    final tracesChanged = !identical(raw1, _lastRaw1) ||
        !identical(raw2, _lastRaw2) ||
        !identical(raw3, _lastRaw3) ||
        !identical(raw4, _lastRaw4) ||
        _lastCouplings[0] != _chCfg[0].coupling ||
        _lastCouplings[1] != _chCfg[1].coupling ||
        _lastCouplings[2] != _chCfg[2].coupling ||
        _lastCouplings[3] != _chCfg[3].coupling;
    if (tracesChanged) {
      _lastRaw1 = raw1;
      _lastRaw2 = raw2;
      _lastRaw3 = raw3;
      _lastRaw4 = raw4;
      for (var i = 0; i < 4; i++) {
        _lastCouplings[i] = _chCfg[i].coupling;
      }
      _cachedCh = [
        _applyCoupling(raw1, _chCfg[0].coupling),
        _applyCoupling(raw2, _chCfg[1].coupling),
        _applyCoupling(raw3, _chCfg[2].coupling),
        _applyCoupling(raw4, _chCfg[3].coupling),
      ];
    }
    final chList = _cachedCh;
    final ch1 = chList[0];
    final ch2 = chList[1];
    final ch3 = chList[2];
    final ch4 = chList[3];
    if (tracesChanged || _lastMathMode != _mathMode) {
      _lastMathMode = _mathMode;
      _cachedMath = _buildMath(ch1, ch2);
    }
    final mathCh = _cachedMath;

    // When Rust backend runs ob_sim_read_scope_4ch (onTriggerConfigChanged wired), traces are pre-triggered.
    final trigTrace = chList[_trigCh.clamp(0, 3)];
    final startIdx = (_mode == ScopeDisplayMode.time && widget.onTriggerConfigChanged == null)
        ? _findTriggerStart(trigTrace, _triggerLevel, rising: _risingEdge)
        : 0;
    final measTrace = chList[_selectedCh];
    if (tracesChanged || !identical(times, _lastTimes) || _lastMeasCh != _selectedCh) {
      _lastTimes = times;
      _lastMeasCh = _selectedCh;
      _cachedMeas = measureWaveform(measTrace, times);
      _cachedDuty = _measureDutyPercent(measTrace, times);
    }
    final (vpp, freqHz) = _cachedMeas;
    final dutyPct = _cachedDuty;
    final activeCfg = _chCfg[_selectedCh];
    final trigSpanV = _chCfg[_trigCh].vPerDiv * 4.0;
    final clampedTrig = _triggerLevel.clamp(-trigSpanV, trigSpanV);

    final totalSpanS = _secPerDiv * 8.0;
    String? cursorText;
    if (_mode == ScopeDisplayMode.time && measTrace.length - startIdx >= 2 && (_c1Frac != null || _c2Frac != null)) {
      final hasTime = times != null && times.length == measTrace.length && startIdx < times.length;
      final useCalibratedX = hasTime && (times.last - times[startIdx]) > 1e-12;
      int idxForFrac(double f) {
        if (useCalibratedX) {
          final targetT = times[startIdx] + f * totalSpanS;
          var lo = startIdx;
          var hi = times.length - 1;
          while (lo < hi) {
            final mid = (lo + hi) >> 1;
            if (times[mid] < targetT) {
              lo = mid + 1;
            } else {
              hi = mid;
            }
          }
          if (lo > startIdx && (targetT - times[lo - 1]).abs() < (times[lo] - targetT).abs()) {
            return lo - 1;
          }
          return lo;
        }
        final visLen = measTrace.length - startIdx;
        return (startIdx + (f * (visLen - 1)).round()).clamp(0, measTrace.length - 1);
      }

      final parts = <String>[];
      final chTag = 'CH${_selectedCh + 1}';
      final i1 = _c1Frac != null ? idxForFrac(_c1Frac!) : null;
      final i2 = _c2Frac != null ? idxForFrac(_c2Frac!) : null;
      if (i1 != null) {
        final t1 = (times != null && i1 < times.length) ? 't1=${_fmtSec(times[i1])} ' : '';
        parts.add('C1: $t1$chTag=${measTrace[i1].toStringAsFixed(2)}V');
      }
      if (i2 != null) {
        parts.add('C2: $chTag=${measTrace[i2].toStringAsFixed(2)}V');
      }
      if (i1 != null && i2 != null) {
        final dv = (measTrace[i2] - measTrace[i1]).abs();
        var dtStr = '';
        if (times != null && i1 < times.length && i2 < times.length) {
          final dt = (times[i2] - times[i1]).abs();
          final inv = dt > 1e-11 ? ' (${formatEngValue(1.0 / dt)}Hz)' : '';
          dtStr = 'Δt=${_fmtSec(dt)}$inv · ';
        }
        parts.add('$dtStr' 'ΔV=${dv.toStringAsFixed(2)}V');
      }
      cursorText = parts.join(' · ');
    }

    Widget chChip(String label, bool active, Color color, ValueChanged<bool> onChanged) =>
        FilterChip(
          selected: active,
          showCheckmark: false,
          selectedColor: color.withAlpha(70),
          side: BorderSide(color: active ? color : colors.panelBorder),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          labelPadding: const EdgeInsets.symmetric(horizontal: 4),
          label: Text(label, style: TextStyle(fontSize: 10, color: active ? color : colors.componentStroke)),
          onSelected: onChanged,
        );

    return Container(
      decoration: BoxDecoration(
        color: colors.panelSurface,
        border: Border.all(color: colors.panelBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(6),
      child: LayoutBuilder(
        builder: (context, box) {
          final compact = box.maxHeight < 210;
          final headerItems = <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.show_chart, size: 16, color: colors.accentAmber),
                const SizedBox(width: 4),
                Text(
                  widget.title,
                  style: TextStyle(
                    color: colors.componentStroke,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            SegmentedButton<ScopeDisplayMode>(
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 8)),
              ),
              segments: [
                ButtonSegment(value: ScopeDisplayMode.time, label: Text(l10n.timeDomainMode)),
                ButtonSegment(value: ScopeDisplayMode.xy, label: Text(l10n.xyMode)),
                ButtonSegment(value: ScopeDisplayMode.fft, label: Text(l10n.fftTitle)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) {
                setState(() => _mode = s.first);
                widget.onFftModeChanged?.call(_mode == ScopeDisplayMode.fft);
              },
            ),
            DropdownButton<int>(
              value: _selectedCh,
              isDense: true,
              underline: const SizedBox.shrink(),
              items: List.generate(
                4,
                (i) => DropdownMenuItem(value: i, child: Text('CH${i + 1}', style: const TextStyle(fontSize: 11))),
              ),
              onChanged: (c) {
                if (c != null) setState(() => _selectedCh = c);
              },
            ),
            DropdownButton<double>(
              value: activeCfg.vPerDiv,
              isDense: true,
              underline: const SizedBox.shrink(),
              items: const [0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0]
                  .map((v) => DropdownMenuItem(value: v, child: Text(l10n.vPerDivLabel('$v'))))
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => activeCfg.vPerDiv = v);
              },
            ),
            if (_mode == ScopeDisplayMode.time) ...[
              DropdownButton<double>(
                value: _secPerDiv,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [5e-5, 1e-4, 2e-4, 5e-4, 1e-3, 2e-3, 5e-3, 10e-3, 20e-3, 50e-3]
                    .map((s) => DropdownMenuItem(value: s, child: Text('${_fmtSec(s)}/d', style: const TextStyle(fontSize: 11))))
                    .toList(),
                onChanged: (s) {
                  if (s != null) setState(() => _secPerDiv = s);
                },
              ),
              DropdownButton<ScopeCoupling>(
                value: activeCfg.coupling,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: ScopeCoupling.dc, child: Text('DC', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: ScopeCoupling.ac, child: Text('AC', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: ScopeCoupling.gnd, child: Text('GND', style: TextStyle(fontSize: 11))),
                ],
                onChanged: (c) {
                  if (c != null) setState(() => activeCfg.coupling = c);
                },
              ),
              DropdownButton<ScopeMathMode>(
                value: _mathMode,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: ScopeMathMode.off, child: Text('Math:Off', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: ScopeMathMode.diff, child: Text('CH1-CH2', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: ScopeMathMode.sum, child: Text('CH1+CH2', style: TextStyle(fontSize: 11))),
                ],
                onChanged: (m) {
                  if (m != null) setState(() => _mathMode = m);
                },
              ),
            ],
            if (_mode == ScopeDisplayMode.fft)
              FilterChip(
                selected: _fftDbv,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                label: Text('dBV', style: TextStyle(fontSize: 10, color: colors.componentStroke)),
                onSelected: (v) => setState(() => _fftDbv = v),
              ),
            chChip('Hold', _hold, colors.dangerRed, (_) => _toggleHold()),
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (compact)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final w in headerItems) Padding(padding: const EdgeInsets.only(right: 6), child: w),
                    ],
                  ),
                )
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: headerItems,
                ),
              if (_mode == ScopeDisplayMode.time && !compact) ...[
                const SizedBox(height: 4),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      chChip('CH1', _en1, colors.scopeCh1, (v) => setState(() => _en1 = v)),
                      const SizedBox(width: 4),
                      chChip('CH2', _en2, colors.scopeCh2, (v) => setState(() => _en2 = v)),
                      const SizedBox(width: 4),
                      chChip('CH3', _en3, colors.scopeCh3, (v) => setState(() => _en3 = v)),
                      const SizedBox(width: 4),
                      chChip('CH4', _en4, colors.scopeCh4, (v) => setState(() => _en4 = v)),
                      const SizedBox(width: 6),
                      DropdownButton<int>(
                        value: _trigCh,
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        items: List.generate(
                          4,
                          (i) => DropdownMenuItem(value: i, child: Text('Trig CH${i + 1}', style: const TextStyle(fontSize: 10))),
                        ),
                        onChanged: (c) {
                          if (c == null) return;
                          setState(() => _trigCh = c);
                          _pushTrigConfig();
                        },
                      ),
                      const SizedBox(width: 4),
                      DropdownButton<ScopeTriggerMode>(
                        value: _trigMode,
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(value: ScopeTriggerMode.auto, child: Text('Auto', style: TextStyle(fontSize: 10))),
                          DropdownMenuItem(value: ScopeTriggerMode.normal, child: Text('Normal', style: TextStyle(fontSize: 10))),
                          DropdownMenuItem(value: ScopeTriggerMode.single, child: Text('Single', style: TextStyle(fontSize: 10))),
                        ],
                        onChanged: (m) {
                          if (m == null) return;
                          setState(() {
                            _trigMode = m;
                            _hold = false;
                            if (m == ScopeTriggerMode.normal) _clearHeld();
                            _singleArmed = m == ScopeTriggerMode.single;
                            _singleArmedPending =
                                _singleArmed && widget.onTriggerConfigChanged != null;
                          });
                          _pushTrigConfig();
                        },
                      ),
                      const SizedBox(width: 4),
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                        label: Text(_risingEdge ? 'Trig ↑' : 'Trig ↓', style: TextStyle(fontSize: 10, color: colors.accentAmber)),
                        onPressed: () {
                          setState(() => _risingEdge = !_risingEdge);
                          _pushTrigConfig();
                        },
                      ),
                      const SizedBox(width: 4),
                      ChoiceChip(
                        selected: _activeCursor == 1,
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                        label: Text('C1', style: TextStyle(fontSize: 10, color: colors.componentStroke)),
                        onSelected: (_) => setState(() => _activeCursor = 1),
                      ),
                      const SizedBox(width: 4),
                      ChoiceChip(
                        selected: _activeCursor == 2,
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                        label: Text('C2', style: TextStyle(fontSize: 10, color: colors.componentStroke)),
                        onSelected: (_) => setState(() => _activeCursor = 2),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxHeight < 20 || constraints.maxWidth < 20) {
                      return const SizedBox.shrink();
                    }
                    void updateCursor(double dx) {
                      if (_mode != ScopeDisplayMode.time) return;
                      final frac = (dx / constraints.maxWidth).clamp(0.0, 1.0);
                      setState(() {
                        if (_activeCursor == 1) {
                          _c1Frac = frac;
                        } else {
                          _c2Frac = frac;
                        }
                      });
                    }

                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (e) => updateCursor(e.localPosition.dx),
                      onHorizontalDragUpdate: (e) => updateCursor(e.localPosition.dx),
                      onDoubleTap: () => setState(() {
                        _c1Frac = null;
                        _c2Frac = null;
                      }),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: CustomPaint(
                          painter: _ScopePainter(
                            mode: _mode,
                            ch1: _en1 ? ch1 : Float64List(0),
                            ch2: _en2 ? ch2 : Float64List(0),
                            ch3: _en3 ? ch3 : Float64List(0),
                            ch4: _en4 ? ch4 : Float64List(0),
                            mathCh: mathCh,
                            times: times,
                            fft: fft,
                            fftDbv: _fftDbv,
                            vPerDiv: [for (final c in _chCfg) c.vPerDiv],
                            offsetDiv: [for (final c in _chCfg) c.offsetDiv],
                            trigCh: _trigCh,
                            triggerLevel: clampedTrig,
                            startIdx: startIdx,
                            secPerDiv: _secPerDiv,
                            c1Frac: _c1Frac,
                            c2Frac: _c2Frac,
                            colors: colors,
                          ),
                          size: Size.infinite,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 4),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    Text(
                      'CH1: ${dc1.toStringAsFixed(2)}V',
                      style: TextStyle(color: colors.scopeCh1, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'CH2: ${dc2.toStringAsFixed(2)}V',
                      style: TextStyle(color: colors.scopeCh2, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                    if (_en3) ...[
                      const SizedBox(width: 8),
                      Text('CH3: ${dc3.toStringAsFixed(2)}V', style: TextStyle(color: colors.scopeCh3, fontSize: 11)),
                    ],
                    if (_en4) ...[
                      const SizedBox(width: 8),
                      Text('CH4: ${dc4.toStringAsFixed(2)}V', style: TextStyle(color: colors.scopeCh4, fontSize: 11)),
                    ],
                    const SizedBox(width: 8),
                    Text(
                      'CH${_selectedCh + 1} Vpp: ${vpp.toStringAsFixed(2)}V',
                      style: TextStyle(color: colors.componentStroke, fontSize: 11),
                    ),
                    if (freqHz != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        'f: ${formatEngValue(freqHz)}Hz (${_fmtSec(1.0 / freqHz)})',
                        style: TextStyle(color: colors.accentAmber, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ],
                    if (dutyPct != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        'D: ${dutyPct.toStringAsFixed(1)}%',
                        style: TextStyle(color: colors.componentStroke, fontSize: 11),
                      ),
                    ],
                    if (_mode == ScopeDisplayMode.fft) ...[
                      const SizedBox(width: 8),
                      Text(
                        'THD: ${thd.toStringAsFixed(2)}%',
                        style: TextStyle(color: colors.accentAmber, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ],
                    if (cursorText != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        cursorText,
                        style: TextStyle(color: colors.accentAmber, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ],
                    if (_mode == ScopeDisplayMode.time && !compact) ...[
                      const SizedBox(width: 8),
                      Text('${l10n.triggerLevelLabel}: ${_triggerLevel.toStringAsFixed(1)}V', style: TextStyle(color: colors.componentStroke, fontSize: 11)),
                      SizedBox(
                        width: 74,
                        height: 24,
                        child: Slider(
                          value: clampedTrig,
                          min: -trigSpanV,
                          max: trigSpanV,
                          activeColor: colors.accentAmber,
                          onChanged: (v) {
                            setState(() => _triggerLevel = v);
                            _pushTrigConfig();
                          },
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text('CH${_selectedCh + 1} Off:', style: TextStyle(color: colors.componentStroke, fontSize: 10)),
                      SizedBox(
                        width: 60,
                        height: 24,
                        child: Slider(
                          value: activeCfg.offsetDiv,
                          min: -2.0,
                          max: 2.0,
                          activeColor: colors.scopeCh2,
                          onChanged: (v) => setState(() => activeCfg.offsetDiv = v),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ScopePainter extends CustomPainter {
  final ScopeDisplayMode mode;
  final Float64List ch1;
  final Float64List ch2;
  final Float64List ch3;
  final Float64List ch4;
  final Float64List mathCh;
  final Float64List? times;
  final Float64List fft;
  final bool fftDbv;
  final List<double> vPerDiv;
  final List<double> offsetDiv;
  final int trigCh;
  final double triggerLevel;
  final int startIdx;
  final double secPerDiv;
  final double? c1Frac;
  final double? c2Frac;
  final CircuitColors colors;

  _ScopePainter({
    required this.mode,
    required this.ch1,
    required this.ch2,
    required this.ch3,
    required this.ch4,
    required this.mathCh,
    this.times,
    required this.fft,
    required this.fftDbv,
    required this.vPerDiv,
    required this.offsetDiv,
    required this.trigCh,
    required this.triggerLevel,
    required this.startIdx,
    required this.secPerDiv,
    required this.c1Frac,
    required this.c2Frac,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.canvasBackground);

    final gridPaint = Paint()
      ..color = colors.gridMinor
      ..strokeWidth = 1;
    for (var i = 1; i < 8; i++) {
      final x = size.width * i / 8;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var i = 1; i < 6; i++) {
      final y = size.height * i / 6;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        i == 3 ? (Paint()..color = colors.gridMajor..strokeWidth = 1.2) : gridPaint,
      );
    }

    switch (mode) {
      case ScopeDisplayMode.time:
        final divH = size.height / 6.0;
        final tOff = offsetDiv[trigCh] * divH;
        final trigY = (size.height * 0.5 - tOff - triggerLevel * divH / vPerDiv[trigCh])
            .clamp(0.0, size.height);
        canvas.drawLine(
          Offset(0, trigY),
          Offset(size.width, trigY),
          Paint()
            ..color = colors.accentAmberDim.withAlpha(140)
            ..strokeWidth = 1,
        );
        _drawTrace(canvas, size, ch1, colors.scopeCh1, 0);
        _drawTrace(canvas, size, ch2, colors.scopeCh2, 1);
        _drawTrace(canvas, size, ch3, colors.scopeCh3, 2);
        _drawTrace(canvas, size, ch4, colors.scopeCh4, 3);
        _drawTrace(canvas, size, mathCh, _kMathColor, 0);
        if (c1Frac != null) {
          final cx = c1Frac! * size.width;
          canvas.drawLine(
            Offset(cx, 0),
            Offset(cx, size.height),
            Paint()
              ..color = colors.accentAmber.withAlpha(200)
              ..strokeWidth = 1.2,
          );
        }
        if (c2Frac != null) {
          final cx = c2Frac! * size.width;
          canvas.drawLine(
            Offset(cx, 0),
            Offset(cx, size.height),
            Paint()
              ..color = colors.scopeCh2.withAlpha(200)
              ..strokeWidth = 1.2,
          );
        }
      case ScopeDisplayMode.xy:
        _drawXy(canvas, size);
      case ScopeDisplayMode.fft:
        _drawFft(canvas, size);
    }
  }

  void _drawTrace(Canvas canvas, Size size, Float64List vals, Color color, int chIdx) {
    final avail = vals.length - startIdx;
    if (avail < 2) return;
    final path = Path();
    final divH = size.height / 6.0;
    final midY = size.height * 0.5 - offsetDiv[chIdx] * divH;
    final pxPerVolt = divH / vPerDiv[chIdx];
    final hasCalibratedTime = times != null && times!.length == vals.length && startIdx < times!.length;
    final t0 = hasCalibratedTime ? times![startIdx] : 0.0;
    final totalSpanS = secPerDiv * 8.0;
    // Anchor at newest/window tail if total time duration <= totalSpanS, else plot fixed calibrated s/div from t0
    final rawSpan = hasCalibratedTime ? (times!.last - t0) : 0.0;
    final useCalibratedX = hasCalibratedTime && rawSpan > 1e-12;

    var started = false;
    for (var i = 0; i < avail; i++) {
      final idx = startIdx + i;
      final x = useCalibratedX
          ? ((times![idx] - t0) / totalSpanS) * size.width
          : (i / (avail - 1)) * size.width;
      if (useCalibratedX && x > size.width + 2.0) break;
      final v = vals[idx];
      if (!v.isFinite || !x.isFinite) continue;
      final y = (midY - v * pxPerVolt).clamp(0.0, size.height);
      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round,
    );
  }

  void _drawXy(Canvas canvas, Size size) {
    final len = math.min(ch1.length, ch2.length);
    if (len < 2) return;
    final path = Path();
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    final scaleX = (size.width / 8.0) / vPerDiv[0];
    final scaleY = (size.height / 6.0) / vPerDiv[1];
    var started = false;
    for (var i = 0; i < len; i++) {
      final v1 = ch1[i];
      final v2 = ch2[i];
      if (!v1.isFinite || !v2.isFinite) continue;
      final x = (cx + v1 * scaleX).clamp(0.0, size.width);
      final y = (cy - v2 * scaleY).clamp(0.0, size.height);
      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = colors.accentAmber
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );
  }

  void _drawFft(Canvas canvas, Size size) {
    if (fft.isEmpty) return;
    final barW = size.width / fft.length;
    var maxMag = 1e-6;
    for (final v in fft) {
      if (v.isFinite && v > maxMag) maxMag = v;
    }
    final paint = Paint()..color = colors.accentAmber;
    for (var i = 0; i < fft.length; i++) {
      final v = fft[i];
      final frac = !v.isFinite
          ? 0.0
          : fftDbv
              ? ((fftMagToRmsDbv(v, isDc: i == 0) + 80.0) / 100.0).clamp(0.0, 1.0)
              : (v / maxMag).clamp(0.0, 1.0);
      final h = frac * size.height * 0.92;
      canvas.drawRect(
        Rect.fromLTWH(i * barW, size.height - h, math.max(1.5, barW - 1), h),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ScopePainter old) {
    if (old.mode != mode ||
        old.ch1 != ch1 ||
        old.ch2 != ch2 ||
        old.ch3 != ch3 ||
        old.ch4 != ch4 ||
        old.mathCh != mathCh ||
        old.times != times ||
        old.fft != fft ||
        old.fftDbv != fftDbv ||
        old.trigCh != trigCh ||
        old.triggerLevel != triggerLevel ||
        old.startIdx != startIdx ||
        old.secPerDiv != secPerDiv ||
        old.c1Frac != c1Frac ||
        old.c2Frac != c2Frac ||
        old.colors != colors) {
      return true;
    }
    for (var i = 0; i < 4; i++) {
      if (old.vPerDiv[i] != vPerDiv[i] || old.offsetDiv[i] != offsetDiv[i]) return true;
    }
    return false;
  }
}
