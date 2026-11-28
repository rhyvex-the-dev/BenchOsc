import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../ffi/sim_ffi.dart';
import '../l10n/app_localizations.dart';
import '../state/circuit_doc.dart';
import '../theme/circuit_theme.dart';

/// Unwraps wrapped `±180°` phase steps continuously for clean Bode plotting & margin detection.
Float64List unwrapPhaseDeg(Float64List wrapped) {
  final out = Float64List(wrapped.length);
  if (wrapped.isEmpty) return out;
  out[0] = wrapped[0];
  var offset = 0.0;
  for (var i = 1; i < wrapped.length; i++) {
    final diff = wrapped[i] - wrapped[i - 1];
    if (diff > 180.0) {
      offset -= 360.0;
    } else if (diff < -180.0) {
      offset += 360.0;
    }
    out[i] = wrapped[i] + offset;
  }
  return out;
}

class BodePlotterView extends StatefulWidget {
  final AcSweepData? sweepData;
  final VoidCallback onRunSweep;
  final void Function({
    required double fStart,
    required double fStop,
    required int ptsPerDecade,
    int? acSourceId,
    int inNode,
    int? outNode,
  })? onRunSweepConfig;
  final List<(int id, String label)> acSources;
  final List<(int nodeId, String label)> probeNodes;

  const BodePlotterView({
    super.key,
    required this.sweepData,
    required this.onRunSweep,
    this.onRunSweepConfig,
    this.acSources = const [],
    this.probeNodes = const [],
  });

  @override
  State<BodePlotterView> createState() => _BodePlotterViewState();
}

class _BodePlotterViewState extends State<BodePlotterView> {
  double? _cursorFrac;
  double _fStart = 10.0;
  double _fStop = 100000.0;
  int _ptsPerDecade = 20;
  int? _selectedSrcId;
  int _inNode = -1; // -1 = absolute Vout (relative to 1V AC source)
  int? _outNode;
  AcSweepData? _cachedSweepData;
  Float64List? _unwrappedPhase;
  (double?, double?, double?, double?) _bandMetricsCache = (null, null, null, null);
  (double?, double?) _marginsCache = (null, null);

  @override
  void initState() {
    super.initState();
    _syncSweepCache();
  }

  @override
  void didUpdateWidget(covariant BodePlotterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sweepData != _cachedSweepData) {
      _syncSweepCache();
    }
  }

  void _syncSweepCache() {
    final d = widget.sweepData;
    _cachedSweepData = d;
    _unwrappedPhase = d != null ? unwrapPhaseDeg(d.phaseDeg) : null;
    _bandMetricsCache = _bandMetrics(d);
    _marginsCache = _margins(d, _unwrappedPhase);
  }

  int? get _validSrc => widget.acSources.any((s) => s.$1 == _selectedSrcId) ? _selectedSrcId : null;
  int? get _validOut => widget.probeNodes.any((n) => n.$1 == _outNode) ? _outNode : null;
  int get _validIn => (_inNode > 0 && widget.probeNodes.any((n) => n.$1 == _inNode)) ? _inNode : -1;

  void _triggerSweep() {
    if (widget.onRunSweepConfig != null) {
      widget.onRunSweepConfig!(
        fStart: _fStart,
        fStop: _fStop,
        ptsPerDecade: _ptsPerDecade,
        acSourceId: _validSrc,
        inNode: _validIn,
        outNode: _validOut,
      );
    } else {
      widget.onRunSweep();
    }
  }

  (double? fl, double? fh, double? bw, double? q) _bandMetrics(AcSweepData? d) {
    if (d == null || d.freqs.length < 2) return (null, null, null, null);
    var peakIdx = 0;
    for (var i = 1; i < d.magDb.length; i++) {
      if (d.magDb[i] > d.magDb[peakIdx]) peakIdx = i;
    }
    final target = d.magDb[peakIdx] - 3.0;
    double? fl;
    double? fh;
    for (var i = peakIdx + 1; i < d.magDb.length; i++) {
      if (d.magDb[i] <= target) {
        final prev = d.magDb[i - 1], cur = d.magDb[i];
        final frac = (prev - cur).abs() > 1e-6 ? ((prev - target) / (prev - cur)).clamp(0.0, 1.0) : 0.0;
        fh = d.freqs[i - 1] + frac * (d.freqs[i] - d.freqs[i - 1]);
        break;
      }
    }
    for (var i = peakIdx - 1; i >= 0; i--) {
      if (d.magDb[i] <= target) {
        final next = d.magDb[i + 1], cur = d.magDb[i];
        final frac = (next - cur).abs() > 1e-6 ? ((next - target) / (next - cur)).clamp(0.0, 1.0) : 0.0;
        fl = d.freqs[i + 1] - frac * (d.freqs[i + 1] - d.freqs[i]);
        break;
      }
    }
    if (fl != null && fh != null && fh > fl) {
      final bw = fh - fl;
      final fcMid = math.sqrt(fl * fh);
      return (fl, fh, bw, fcMid / bw);
    }
    return (fl, fh, null, null);
  }

  (double? pmDeg, double? gmDb) _margins(AcSweepData? d, Float64List? unwrappedPhase) {
    if (d == null || unwrappedPhase == null || d.freqs.length < 2) return (null, null);
    double? pm;
    double? gm;
    for (var i = 1; i < d.freqs.length; i++) {
      final m0 = d.magDb[i - 1], m1 = d.magDb[i];
      if (pm == null && ((m0 >= 0 && m1 <= 0) || (m0 <= 0 && m1 >= 0)) && (m0 - m1).abs() > 1e-6) {
        final t = ((0.0 - m0) / (m1 - m0)).clamp(0.0, 1.0);
        final phaseAt0 = unwrappedPhase[i - 1] + t * (unwrappedPhase[i] - unwrappedPhase[i - 1]);
        pm = 180.0 + phaseAt0;
      }
      final p0 = unwrappedPhase[i - 1], p1 = unwrappedPhase[i];
      if (gm == null && p0 > -180.0 && p1 <= -180.0 && (p0 - p1).abs() > 1e-6) {
        final t = ((-180.0 - p0) / (p1 - p0)).clamp(0.0, 1.0);
        gm = -(m0 + t * (m1 - m0));
      }
    }
    return (pm, gm);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CircuitColors>()!;
    final l10n = AppLocalizations.of(context)!;
    final d = widget.sweepData;
    final unwrapped = _unwrappedPhase;
    final (fl, fh, bw, qFactor) = _bandMetricsCache;
    final fc = fh ?? fl;
    final (pmDeg, gmDb) = _marginsCache;
    final cursorIdx = (d != null && d.freqs.isNotEmpty && _cursorFrac != null)
        ? (_cursorFrac! * (d.freqs.length - 1)).round().clamp(0, d.freqs.length - 1)
        : null;

    final validSrc = _validSrc;
    final validOut = _validOut;
    final validIn = _validIn;

    return Container(
      decoration: BoxDecoration(
        color: colors.panelSurface,
        border: Border.all(color: colors.panelBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(8),
      child: LayoutBuilder(
        builder: (context, box) {
          final header = Wrap(
            spacing: 6,
            runSpacing: 4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.ssid_chart, size: 16, color: colors.accentAmber),
                  const SizedBox(width: 4),
                  Text(
                    l10n.bodePlotterTitle,
                    style: TextStyle(color: colors.componentStroke, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              Wrap(
                spacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<double>(
                    value: _fStart,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    items: const [0.1, 1.0, 10.0, 100.0, 1000.0]
                        .map((f) => DropdownMenuItem(value: f, child: Text('${formatEngValue(f)}Hz', style: const TextStyle(fontSize: 11))))
                        .toList(),
                    onChanged: (v) {
                      if (v == null || v >= _fStop) return;
                      setState(() => _fStart = v);
                      _triggerSweep();
                    },
                  ),
                  Text('-', style: TextStyle(color: colors.componentStroke, fontSize: 11)),
                  DropdownButton<double>(
                    value: _fStop,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    items: const [1000.0, 10000.0, 100000.0, 1000000.0, 10000000.0]
                        .map((f) => DropdownMenuItem(
                              value: f,
                              child: Text('${formatEngValue(f)}Hz', style: const TextStyle(fontSize: 11)),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v == null || v <= _fStart) return;
                      setState(() => _fStop = v);
                      _triggerSweep();
                    },
                  ),
                  DropdownButton<int>(
                    value: _ptsPerDecade,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    items: const [10, 20, 40]
                        .map((p) => DropdownMenuItem(value: p, child: Text('$p/dec', style: const TextStyle(fontSize: 10))))
                        .toList(),
                    onChanged: (p) {
                      if (p == null) return;
                      setState(() => _ptsPerDecade = p);
                      _triggerSweep();
                    },
                  ),
                ],
              ),
              if (widget.acSources.isNotEmpty)
                DropdownButton<int?>(
                  value: validSrc,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('Src:Auto', style: TextStyle(fontSize: 10))),
                    for (final s in widget.acSources)
                      DropdownMenuItem<int?>(value: s.$1, child: Text(s.$2, style: const TextStyle(fontSize: 10))),
                  ],
                  onChanged: (v) {
                    setState(() => _selectedSrcId = v);
                    _triggerSweep();
                  },
                ),
              if (widget.probeNodes.isNotEmpty) ...[
                DropdownButton<int>(
                  value: validIn,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem(value: -1, child: Text('IN:Src', style: TextStyle(fontSize: 10))),
                    for (final n in widget.probeNodes)
                      DropdownMenuItem(value: n.$1, child: Text('IN:${n.$2}', style: const TextStyle(fontSize: 10))),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _inNode = v);
                    _triggerSweep();
                  },
                ),
                DropdownButton<int?>(
                  value: validOut,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('OUT:CH2', style: TextStyle(fontSize: 10))),
                    for (final n in widget.probeNodes)
                      DropdownMenuItem<int?>(value: n.$1, child: Text('OUT:${n.$2}', style: const TextStyle(fontSize: 10))),
                  ],
                  onChanged: (v) {
                    setState(() => _outNode = v);
                    _triggerSweep();
                  },
                ),
              ],
              FilledButton.tonal(
                onPressed: _triggerSweep,
                child: Text(l10n.runAcSweep),
              ),
            ],
          );
          final plotArea = LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxHeight < 20 || constraints.maxWidth < 20) {
                return const SizedBox.shrink();
              }
              void updateCursor(double dx) {
                setState(() => _cursorFrac = (dx / constraints.maxWidth).clamp(0.0, 1.0));
              }

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (e) => updateCursor(e.localPosition.dx),
                onHorizontalDragUpdate: (e) => updateCursor(e.localPosition.dx),
                onDoubleTap: () => setState(() => _cursorFrac = null),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: CustomPaint(
                    painter: _BodePainter(
                      data: d,
                      unwrappedPhase: unwrapped,
                      cursorFrac: _cursorFrac,
                      colors: colors,
                    ),
                    size: Size.infinite,
                  ),
                ),
              );
            },
          );
          final footer = Wrap(
            spacing: 10,
            runSpacing: 2,
            children: [
              Text(l10n.magnitudeDbLabel, style: TextStyle(color: colors.scopeCh1, fontSize: 11)),
              Text(l10n.phaseDegLabel, style: TextStyle(color: colors.scopeCh2, fontSize: 11)),
              Text(
                '${formatEngValue(_fStart)}Hz - ${formatEngValue(_fStop)}Hz',
                style: TextStyle(color: colors.componentStroke, fontSize: 11),
              ),
              if (fc != null && bw == null)
                Text(
                  '${l10n.cutoffFreqLabel}: ${formatEngValue(fc)}Hz',
                  style: TextStyle(color: colors.accentAmber, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              if (bw != null)
                Text(
                  'fL:${formatEngValue(fl!)}Hz fH:${formatEngValue(fh!)}Hz BW:${formatEngValue(bw)}Hz Q:${qFactor!.toStringAsFixed(2)}',
                  style: TextStyle(color: colors.accentAmber, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              if (pmDeg != null)
                Text(
                  'PM: ${pmDeg.toStringAsFixed(1)}°',
                  style: TextStyle(color: colors.scopeCh2, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              if (gmDb != null)
                Text(
                  'GM: ${gmDb.toStringAsFixed(1)}dB',
                  style: TextStyle(color: colors.scopeCh1, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              if (cursorIdx != null && d != null && unwrapped != null)
                Text(
                  '${formatEngValue(d.freqs[cursorIdx])}Hz · ${d.magDb[cursorIdx].toStringAsFixed(1)}dB · ${unwrapped[cursorIdx].toStringAsFixed(1)}°',
                  style: TextStyle(color: colors.accentAmber, fontSize: 11, fontWeight: FontWeight.w600),
                ),
            ],
          );
          if (box.maxHeight < 260) {
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  const SizedBox(height: 6),
                  SizedBox(height: 120, child: plotArea),
                  const SizedBox(height: 4),
                  footer,
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const SizedBox(height: 6),
              Expanded(child: plotArea),
              const SizedBox(height: 4),
              footer,
            ],
          );
        },
      ),
    );
  }
}

class _BodePainter extends CustomPainter {
  final AcSweepData? data;
  final Float64List? unwrappedPhase;
  final double? cursorFrac;
  final CircuitColors colors;

  _BodePainter({
    required this.data,
    required this.unwrappedPhase,
    required this.cursorFrac,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.canvasBackground);
    final grid = Paint()
      ..color = colors.gridMinor
      ..strokeWidth = 1;
    final d = data;
    final ph = unwrappedPhase;
    if (d != null && d.freqs.length >= 2 && d.freqs.first.isFinite && d.freqs.last.isFinite) {
      final fMin = math.max(1e-3, d.freqs.first);
      final fMax = math.max(fMin * 1.1, d.freqs.last);
      final logMin = math.log(fMin) / math.ln10;
      final logMax = math.log(fMax) / math.ln10;
      final logSpan = math.max(1e-6, logMax - logMin);
      for (var exp = logMin.ceil(); exp <= logMax.floor(); exp++) {
        final fx = ((exp - logMin) / logSpan) * size.width;
        canvas.drawLine(
          Offset(fx, 0),
          Offset(fx, size.height),
          Paint()..color = colors.gridMajor..strokeWidth = 1.0,
        );
        final hz = math.pow(10.0, exp).toDouble();
        final lbl = '${formatEngValue(hz)}Hz';
        final tp = TextPainter(
          text: TextSpan(text: lbl, style: TextStyle(color: colors.componentStroke.withAlpha(150), fontSize: 9)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset((fx + 2).clamp(2.0, math.max(2.0, size.width - tp.width - 2)), size.height - tp.height - 2));
        tp.dispose();
      }
    } else {
      for (var i = 1; i < 4; i++) {
        final x = size.width * i / 4;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      }
    }
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        i == 1 ? (Paint()..color = colors.gridMajor..strokeWidth = 1.2) : grid,
      );
    }

    if (d == null || ph == null || d.freqs.length < 2) {
      final tp = TextPainter(
        text: TextSpan(
          text: 'Need AC/FuncGen source & OUT probe — press Run AC Sweep',
          style: TextStyle(color: colors.componentStroke.withAlpha(140), fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(60, size.width - 16));
      tp.paint(canvas, Offset((size.width - tp.width) * 0.5, (size.height - tp.height) * 0.5));
      tp.dispose();
      return;
    }

    var minMag = double.infinity, maxMag = double.negativeInfinity;
    var minPh = double.infinity, maxPh = double.negativeInfinity;
    for (var i = 0; i < d.freqs.length; i++) {
      final m = d.magDb[i];
      if (m.isFinite) {
        if (m < minMag) minMag = m;
        if (m > maxMag) maxMag = m;
      }
      final p = ph[i];
      if (p.isFinite) {
        if (p < minPh) minPh = p;
        if (p > maxPh) maxPh = p;
      }
    }
    if (!minMag.isFinite || !maxMag.isFinite) {
      minMag = -40.0;
      maxMag = 0.0;
    }
    if (!minPh.isFinite || !maxPh.isFinite) {
      minPh = -180.0;
      maxPh = 45.0;
    }
    final magTop = (maxMag / 10.0).ceil() * 10.0 + 5.0;
    final magBot = math.min(magTop - 40.0, (minMag / 10.0).floor() * 10.0 - 5.0);
    final magSpan = math.max(10.0, magTop - magBot);
    final phTop = math.max(45.0, (maxPh / 45.0).ceil() * 45.0);
    final phBot = math.min(-180.0, (minPh / 45.0).floor() * 45.0);
    final phSpan = math.max(90.0, phTop - phBot);

    for (var i = 0; i <= 4; i++) {
      final dbTick = magTop - i * (magSpan / 4);
      final phTick = phTop - i * (phSpan / 4);
      final y = (i / 4.0) * (size.height - 14) + 2;
      final tMag = TextPainter(
        text: TextSpan(text: '${dbTick.round()}dB', style: TextStyle(color: colors.scopeCh1.withAlpha(180), fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      tMag.paint(canvas, Offset(2, y));
      tMag.dispose();
      final tPh = TextPainter(
        text: TextSpan(text: '${phTick.round()}°', style: TextStyle(color: colors.scopeCh2.withAlpha(180), fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      tPh.paint(canvas, Offset(size.width - tPh.width - 2, y));
      tPh.dispose();
    }

    final magPath = Path();
    final phasePath = Path();
    double magY(int idx) {
      final v = d.magDb[idx];
      if (!v.isFinite) return (size.height * 0.5).clamp(0.0, size.height);
      return (size.height * (magTop - v) / magSpan).clamp(0.0, size.height);
    }
    double phaseY(int idx) {
      final v = ph[idx];
      if (!v.isFinite) return (size.height * 0.5).clamp(0.0, size.height);
      return (size.height * (phTop - v) / phSpan).clamp(0.0, size.height);
    }

    for (var i = 0; i < d.freqs.length; i++) {
      final x = (i / (d.freqs.length - 1)) * size.width;
      final my = magY(i);
      final py = phaseY(i);
      if (i == 0) {
        magPath.moveTo(x, my);
        phasePath.moveTo(x, py);
      } else {
        magPath.lineTo(x, my);
        phasePath.lineTo(x, py);
      }
    }
    canvas.drawPath(
      magPath,
      Paint()
        ..color = colors.scopeCh1
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );
    canvas.drawPath(
      phasePath,
      Paint()
        ..color = colors.scopeCh2
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );

    if (cursorFrac != null) {
      final cIdx = (cursorFrac! * (d.freqs.length - 1)).round().clamp(0, d.freqs.length - 1);
      final cx = (cIdx / (d.freqs.length - 1)) * size.width;
      canvas.drawLine(
        Offset(cx, 0),
        Offset(cx, size.height),
        Paint()
          ..color = colors.accentAmber.withAlpha(170)
          ..strokeWidth = 1.2,
      );
      canvas.drawCircle(Offset(cx, magY(cIdx)), 3.5, Paint()..color = colors.scopeCh1);
      canvas.drawCircle(Offset(cx, phaseY(cIdx)), 3.5, Paint()..color = colors.scopeCh2);
    }
  }

  @override
  bool shouldRepaint(covariant _BodePainter old) =>
      old.data != data || old.unwrappedPhase != unwrappedPhase || old.cursorFrac != cursorFrac || old.colors != colors;
}
