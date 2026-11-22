import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/circuit_theme.dart';

class DcSweepData {
  final Float64List vin;
  final Float64List ch1;
  final Float64List ch2;

  const DcSweepData(this.vin, this.ch1, this.ch2);
}

class DcSweepView extends StatefulWidget {
  final DcSweepData? sweepData;
  final List<(String label, DcSweepData data)>? familyCurves;
  final void Function(double vStart, double vStop) onRunSweep;
  final void Function({
    int? srcId,
    int? secSrcId,
    required double vStart,
    required double vStop,
    required int steps,
    required bool family,
    required bool ivCurve,
  })? onRunSweepConfig;
  final List<(int id, String label)> sweepSources;
  final int circuitRevision;
  final Future<(double min, double max, double mean, double std)?> Function()? onRunMonteCarlo;
  final Future<(double min, double max, double mean, double std, Float64List samples)?> Function({
    required double tol,
    required int runs,
    required bool gaussian,
  })? onRunMonteCarloEx;

  const DcSweepView({
    super.key,
    required this.sweepData,
    this.familyCurves,
    required this.onRunSweep,
    this.onRunSweepConfig,
    this.sweepSources = const [],
    this.circuitRevision = 0,
    this.onRunMonteCarlo,
    this.onRunMonteCarloEx,
  });

  @override
  State<DcSweepView> createState() => _DcSweepViewState();
}

class _DcSweepViewState extends State<DcSweepView> {
  double _vStart = 0.0;
  double _vStop = 5.0;
  int _steps = 25;
  int? _srcId;
  int? _secSrcId;
  double? _cursorFrac;
  bool _familyMode = false;
  bool _ivMode = false;
  double _mcTol = 0.05;
  int _mcRuns = 50;
  bool _mcGaussian = false;
  (double min, double max, double mean, double std)? _mcStats;
  Float64List? _mcSamples;

  @override
  void didUpdateWidget(covariant DcSweepView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.circuitRevision != oldWidget.circuitRevision) {
      _mcStats = null;
      _mcSamples = null;
    }
  }

  void _trigger() {
    if (widget.onRunSweepConfig != null) {
      widget.onRunSweepConfig!(
        srcId: _srcId,
        secSrcId: _secSrcId,
        vStart: _vStart,
        vStop: _vStop,
        steps: _steps,
        family: _familyMode,
        ivCurve: _ivMode,
      );
    } else {
      widget.onRunSweep(_vStart, _vStop);
    }
  }

  Future<void> _triggerMc() async {
    if (widget.onRunMonteCarloEx != null) {
      final res = await widget.onRunMonteCarloEx!(
        tol: _mcTol,
        runs: _mcRuns,
        gaussian: _mcGaussian,
      );
      if (mounted) {
        setState(() {
          _mcStats = res == null ? null : (res.$1, res.$2, res.$3, res.$4);
          _mcSamples = res?.$5;
        });
      }
      return;
    }
    if (widget.onRunMonteCarlo == null) return;
    final res = await widget.onRunMonteCarlo!();
    if (mounted) {
      setState(() {
        _mcStats = res;
        _mcSamples = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CircuitColors>()!;
    final l10n = AppLocalizations.of(context)!;
    final d = widget.sweepData;
    final cIdx = (d != null && d.vin.isNotEmpty && _cursorFrac != null)
        ? (_cursorFrac! * (d.vin.length - 1)).round().clamp(0, d.vin.length - 1)
        : null;
    final validSrc = widget.sweepSources.any((s) => s.$1 == _srcId) ? _srcId : null;
    final validSec = widget.sweepSources.any((s) => s.$1 == _secSrcId && s.$1 != validSrc) ? _secSrcId : null;

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
                  Icon(Icons.trending_up, size: 16, color: colors.accentAmber),
                  const SizedBox(width: 4),
                  Text(
                    l10n.dcSweepTitle,
                    style: TextStyle(color: colors.componentStroke, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              if (widget.sweepSources.isNotEmpty)
                DropdownButton<int?>(
                  value: validSrc,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('Src:Auto', style: TextStyle(fontSize: 10))),
                    for (final s in widget.sweepSources)
                      DropdownMenuItem<int?>(value: s.$1, child: Text(s.$2, style: const TextStyle(fontSize: 10))),
                  ],
                  onChanged: (v) {
                    setState(() => _srcId = v);
                    _trigger();
                  },
                ),
              if (widget.sweepSources.length > 1)
                DropdownButton<int?>(
                  value: validSec,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('2nd:Auto', style: TextStyle(fontSize: 10))),
                    for (final s in widget.sweepSources.where((s) => s.$1 != validSrc))
                      DropdownMenuItem<int?>(value: s.$1, child: Text(s.$2, style: const TextStyle(fontSize: 10))),
                  ],
                  onChanged: (v) {
                    setState(() => _secSrcId = v);
                    if (_familyMode) _trigger();
                  },
                ),
              Wrap(
                spacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<double>(
                    value: _vStart,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    items: const [-12.0, -5.0, 0.0, 1.0]
                        .map((v) => DropdownMenuItem(value: v, child: Text('${v.toStringAsFixed(0)}V', style: const TextStyle(fontSize: 11))))
                        .toList(),
                    onChanged: (v) {
                      if (v == null || v >= _vStop) return;
                      setState(() => _vStart = v);
                      _trigger();
                    },
                  ),
                  Text('..', style: TextStyle(color: colors.componentStroke, fontSize: 11)),
                  DropdownButton<double>(
                    value: _vStop,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    items: const [2.0, 5.0, 10.0, 12.0, 24.0]
                        .map((v) => DropdownMenuItem(value: v, child: Text('${v.toStringAsFixed(0)}V', style: const TextStyle(fontSize: 11))))
                        .toList(),
                    onChanged: (v) {
                      if (v == null || v <= _vStart) return;
                      setState(() => _vStop = v);
                      _trigger();
                    },
                  ),
                  DropdownButton<int>(
                    value: _steps,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    items: const [15, 25, 50, 100]
                        .map((n) => DropdownMenuItem(value: n, child: Text('$n pt', style: const TextStyle(fontSize: 10))))
                        .toList(),
                    onChanged: (n) {
                      if (n == null) return;
                      setState(() => _steps = n);
                      _trigger();
                    },
                  ),
                ],
              ),
              if (widget.onRunSweepConfig != null)
                FilterChip(
                  selected: _familyMode,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                  label: Text('Family', style: TextStyle(fontSize: 10, color: colors.componentStroke)),
                  onSelected: (v) {
                    setState(() => _familyMode = v);
                    _trigger();
                  },
                ),
              if (widget.onRunSweepConfig != null)
                FilterChip(
                  selected: _ivMode,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                  label: Text('I-V', style: TextStyle(fontSize: 10, color: colors.componentStroke)),
                  onSelected: (v) {
                    setState(() => _ivMode = v);
                    _trigger();
                  },
                ),
              FilledButton.tonal(
                onPressed: _trigger,
                child: Text(l10n.runDcSweep),
              ),
              if (widget.onRunMonteCarlo != null || widget.onRunMonteCarloEx != null) ...[
                DropdownButton<double>(
                  value: _mcTol,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: const [0.01, 0.02, 0.05, 0.10]
                      .map((t) => DropdownMenuItem(value: t, child: Text('±${(t * 100).round()}%', style: const TextStyle(fontSize: 10))))
                      .toList(),
                  onChanged: (t) {
                    if (t != null) setState(() => _mcTol = t);
                  },
                ),
                DropdownButton<int>(
                  value: _mcRuns,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: const [20, 50, 100]
                      .map((r) => DropdownMenuItem(value: r, child: Text('${r}x', style: const TextStyle(fontSize: 10))))
                      .toList(),
                  onChanged: (r) {
                    if (r != null) setState(() => _mcRuns = r);
                  },
                ),
                FilterChip(
                  selected: _mcGaussian,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                  label: Text(_mcGaussian ? 'Gauss' : 'Unif', style: TextStyle(fontSize: 10, color: colors.componentStroke)),
                  onSelected: (v) => setState(() => _mcGaussian = v),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: _triggerMc,
                  child: Text('MC ${(_mcTol * 100).round()}%', style: const TextStyle(fontSize: 11)),
                ),
              ],
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
                    painter: _DcSweepPainter(
                      data: d,
                      familyCurves: widget.familyCurves,
                      mcSamples: _mcSamples,
                      ivMode: _ivMode,
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
              Text('CH1', style: TextStyle(color: colors.scopeCh1, fontSize: 11)),
              Text(_ivMode ? 'I(A)' : 'CH2', style: TextStyle(color: colors.scopeCh2, fontSize: 11)),
              Text(
                '${_vStart.toStringAsFixed(0)}..${_vStop.toStringAsFixed(0)}V',
                style: TextStyle(color: colors.componentStroke, fontSize: 11),
              ),
              if (widget.familyCurves != null && widget.familyCurves!.isNotEmpty)
                Text(
                  widget.familyCurves!.map((e) => e.$1).join(' / '),
                  style: TextStyle(color: colors.scopeCh2, fontSize: 11),
                ),
              if (_mcStats != null)
                Text(
                  'MC: ${_mcStats!.$1.toStringAsFixed(2)}..${_mcStats!.$2.toStringAsFixed(2)}V (μ=${_mcStats!.$3.toStringAsFixed(2)}, σ=${_mcStats!.$4.toStringAsFixed(3)})',
                  style: TextStyle(color: colors.accentAmber, fontSize: 11),
                ),
              if (cIdx != null && d != null)
                Text(
                  'X=${d.vin[cIdx].toStringAsFixed(2)} · CH1=${d.ch1[cIdx].toStringAsFixed(2)}V · ${_ivMode ? "I=${(d.ch2[cIdx] * 1000).toStringAsFixed(2)}mA" : "CH2=${d.ch2[cIdx].toStringAsFixed(2)}V"}',
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

class _DcSweepPainter extends CustomPainter {
  final DcSweepData? data;
  final List<(String label, DcSweepData data)>? familyCurves;
  final Float64List? mcSamples;
  final bool ivMode;
  final double? cursorFrac;
  final CircuitColors colors;

  _DcSweepPainter({
    required this.data,
    this.familyCurves,
    this.mcSamples,
    this.ivMode = false,
    required this.cursorFrac,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.canvasBackground);
    final grid = Paint()
      ..color = colors.gridMinor
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final mc = mcSamples;
    if (mc != null && mc.length >= 2) {
      var minS = double.infinity, maxS = double.negativeInfinity;
      for (final s in mc) {
        if (!s.isFinite) continue;
        if (s < minS) minS = s;
        if (s > maxS) maxS = s;
      }
      if (minS.isFinite && maxS.isFinite) {
        final spanS = maxS - minS;
        const bins = 12;
        final counts = List<int>.filled(bins, 0);
        if (spanS > 1e-9) {
          for (final s in mc) {
            if (!s.isFinite) continue;
            final b = (((s - minS) / spanS) * (bins - 1)).floor().clamp(0, bins - 1);
            counts[b]++;
          }
        } else {
          counts[bins ~/ 2] = mc.length;
        }
        final maxCnt = counts.reduce(math.max).clamp(1, mc.length);
        final bw = (size.width * 0.32) / bins;
        final bx0 = size.width * 0.66;
        final histH = size.height * 0.34;
        final hp = Paint()..color = colors.accentAmber.withAlpha(110);
      for (var b = 0; b < bins; b++) {
        final h = (counts[b] / maxCnt) * histH;
        canvas.drawRect(Rect.fromLTWH(bx0 + b * bw, size.height - h - 2, math.max(1.5, bw - 1), h), hp);
      }
      }
    }

    final d = data;
    final fam = familyCurves;
    if (d == null || d.vin.length < 2) return;

    var minY = double.infinity, maxY = double.negativeInfinity;
    void scan(DcSweepData s) {
      for (var i = 0; i < s.vin.length; i++) {
        if (!ivMode) {
          final v1 = s.ch1[i];
          if (v1.isFinite) {
            minY = math.min(minY, v1);
            maxY = math.max(maxY, v1);
          }
          final v2 = s.ch2[i];
          if (v2.isFinite) {
            minY = math.min(minY, v2);
            maxY = math.max(maxY, v2);
          }
        } else {
          final v2 = s.ch2[i];
          if (v2.isFinite) {
            minY = math.min(minY, v2);
            maxY = math.max(maxY, v2);
          }
        }
      }
    }
    scan(d);
    if (fam != null) {
      for (final item in fam) {
        scan(item.$2);
      }
    }
    if (!minY.isFinite || !maxY.isFinite) {
      minY = -1.0;
      maxY = 1.0;
    }
    final minSpan = ivMode ? 1e-4 : 1.0;
    if (maxY - minY < minSpan) {
      final mid = 0.5 * (minY + maxY);
      minY = mid - 0.5 * minSpan;
      maxY = mid + 0.5 * minSpan;
    }
    double mapY(double v) {
      if (!v.isFinite) return (size.height * 0.5).clamp(2.0, size.height - 2.0);
      return (size.height * (1.0 - (v - minY) / (maxY - minY))).clamp(2.0, size.height - 2.0);
    }

    // Axis ticks for Y (left) & X (bottom)
    for (final (yFrac, val) in [(0.02, maxY), (0.5, 0.5 * (maxY + minY)), (0.90, minY)]) {
      final lbl = ivMode ? '${(val * 1000).toStringAsFixed(1)}mA' : '${val.toStringAsFixed(1)}V';
      final tp = TextPainter(
        text: TextSpan(text: lbl, style: TextStyle(color: colors.componentStroke.withAlpha(170), fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(2, (yFrac * (size.height - tp.height)).clamp(2.0, size.height - tp.height)));
      tp.dispose();
    }
    for (final (xFrac, val) in [(0.05, d.vin.first), (0.90, d.vin.last)]) {
      final tp = TextPainter(
        text: TextSpan(text: '${val.toStringAsFixed(1)}V', style: TextStyle(color: colors.componentStroke.withAlpha(170), fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset((xFrac * (size.width - tp.width)).clamp(2.0, size.width - tp.width - 2), size.height - tp.height - 2));
      tp.dispose();
    }

    if (fam != null && fam.isNotEmpty) {
      const famColors = [Color(0xFF66BB6A), Color(0xFFFFB300), Color(0xFFCE93D8)];
      for (var k = 0; k < fam.length; k++) {
        final s = fam[k].$2;
        if (s.vin.length < 2) continue;
        final fp = Path();
        for (var i = 0; i < s.vin.length; i++) {
          final x = (i / (s.vin.length - 1)) * size.width;
          final y = mapY(s.ch2[i]);
          if (i == 0) {
            fp.moveTo(x, y);
          } else {
            fp.lineTo(x, y);
          }
        }
        canvas.drawPath(
          fp,
          Paint()
            ..color = famColors[k % famColors.length].withAlpha(200)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }

    final p1 = Path();
    final p2 = Path();
    for (var i = 0; i < d.vin.length; i++) {
      final x = (i / (d.vin.length - 1)) * size.width;
      final y1 = mapY(d.ch1[i]);
      final y2 = mapY(d.ch2[i]);
      if (i == 0) {
        p1.moveTo(x, y1);
        p2.moveTo(x, y2);
      } else {
        p1.lineTo(x, y1);
        p2.lineTo(x, y2);
      }
    }
    if (!ivMode) {
      canvas.drawPath(
        p1,
        Paint()
          ..color = colors.scopeCh1
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
    }
    canvas.drawPath(
      p2,
      Paint()
        ..color = colors.scopeCh2
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    if (cursorFrac != null) {
      final cIdx = (cursorFrac! * (d.vin.length - 1)).round().clamp(0, d.vin.length - 1);
      final cx = (cIdx / (d.vin.length - 1)) * size.width;
      canvas.drawLine(
        Offset(cx, 0),
        Offset(cx, size.height),
        Paint()
          ..color = colors.accentAmber.withAlpha(170)
          ..strokeWidth = 1.2,
      );
      if (!ivMode) canvas.drawCircle(Offset(cx, mapY(d.ch1[cIdx])), 3.5, Paint()..color = colors.scopeCh1);
      canvas.drawCircle(Offset(cx, mapY(d.ch2[cIdx])), 3.5, Paint()..color = colors.scopeCh2);
    }
  }

  @override
  bool shouldRepaint(covariant _DcSweepPainter old) =>
      old.data != data ||
      old.familyCurves != familyCurves ||
      old.mcSamples != mcSamples ||
      old.ivMode != ivMode ||
      old.cursorFrac != cursorFrac ||
      old.colors != colors;
}
