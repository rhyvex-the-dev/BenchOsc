import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../state/circuit_doc.dart';
import '../theme/circuit_theme.dart';

/// Dedicated FFT Spectrum Analyzer with dBV log-magnitude floor, harmonic markers, and THD readout.
class SpectrumAnalyzerView extends StatefulWidget {
  final Float64List fftBins;
  final Float64List? ch1Times;
  final double thdPercent;
  final int activeCh;
  final ValueChanged<int>? onChannelChanged;

  const SpectrumAnalyzerView({
    super.key,
    required this.fftBins,
    this.ch1Times,
    this.thdPercent = 0.0,
    this.activeCh = 0,
    this.onChannelChanged,
  });

  @override
  State<SpectrumAnalyzerView> createState() => _SpectrumAnalyzerViewState();
}

class _SpectrumAnalyzerViewState extends State<SpectrumAnalyzerView> {
  double? _refDbvOverride; // null = Auto ceiling above 0 dBV
  double? _cursorFrac;

  double? _binWidthHz() {
    final t = widget.ch1Times;
    if (t == null || t.length < 4) return null;
    final dt = (t.last - t.first) / (t.length - 1);
    if (dt <= 1e-12) return null;
    final nSamples = widget.fftBins.length * 2;
    return nSamples > 0 ? 1.0 / (nSamples * dt) : null;
  }

  static double _magToRmsDbv(double mag) {
    final rms = mag / math.sqrt2;
    return rms > 1e-6 ? 20.0 * math.log(rms) / math.ln10 : -120.0;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CircuitColors>()!;
    final bins = widget.fftBins;
    var peakBin = bins.length > 1 ? 1 : 0;
    var peakVal = (bins.isNotEmpty && bins[peakBin].isFinite) ? bins[peakBin] : -1.0;
    for (var i = 2; i < bins.length; i++) {
      final v = bins[i];
      if (v.isFinite && v > peakVal) {
        peakVal = v;
        peakBin = i;
      }
    }
    // Preserve 0Hz readout when signal is purely DC (all non-DC bins negligible).
    if (bins.length > 1 && peakVal <= 1e-6 && bins[0].isFinite && bins[0] > 1e-6) {
      peakBin = 0;
    }

    var maxAllDbv = -80.0;
    for (final m in bins) {
      if (!m.isFinite) continue;
      final db = _magToRmsDbv(m);
      if (db.isFinite && db > maxAllDbv) maxAllDbv = db;
    }
    final rawCeil = maxAllDbv.isFinite ? (maxAllDbv / 10.0).ceil() * 10.0 : 0.0;
    final ceilDbv = _refDbvOverride ?? math.max(0.0, rawCeil);
    final floorDbv = ceilDbv - 80.0;

    final df = _binWidthHz();
    final peakMag = bins.isNotEmpty ? bins[peakBin] : 0.0;
    final peakDbv = _magToRmsDbv(peakMag);
    final peakFreqText = df != null ? '${formatEngValue(peakBin * df)}Hz' : 'Bin $peakBin';

    final cBin = (bins.isNotEmpty && _cursorFrac != null)
        ? (_cursorFrac! * (bins.length - 1)).round().clamp(0, bins.length - 1)
        : null;

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
            spacing: 8,
            runSpacing: 4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.equalizer, size: 16, color: colors.accentAmber),
                  const SizedBox(width: 4),
                  Text(
                    'Spectrum Analyzer',
                    style: TextStyle(color: colors.componentStroke, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ],
              ),
              if (widget.onChannelChanged != null)
                DropdownButton<int>(
                  value: widget.activeCh.clamp(0, 3),
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: List.generate(
                    4,
                    (i) => DropdownMenuItem(value: i, child: Text('CH${i + 1}', style: const TextStyle(fontSize: 11))),
                  ),
                  onChanged: (c) {
                    if (c != null) widget.onChannelChanged!(c);
                  },
                ),
              DropdownButton<double?>(
                value: _refDbvOverride,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem<double?>(value: null, child: Text('Ref:Auto', style: TextStyle(fontSize: 10))),
                  DropdownMenuItem<double?>(value: 0.0, child: Text('0 dBV', style: TextStyle(fontSize: 10))),
                  DropdownMenuItem<double?>(value: 20.0, child: Text('+20 dBV', style: TextStyle(fontSize: 10))),
                  DropdownMenuItem<double?>(value: 40.0, child: Text('+40 dBV', style: TextStyle(fontSize: 10))),
                ],
                onChanged: (v) => setState(() => _refDbvOverride = v),
              ),
              Text(
                'Peak: $peakFreqText (${peakDbv.toStringAsFixed(1)} dBV)',
                style: TextStyle(color: colors.scopeCh2, fontSize: 11, fontWeight: FontWeight.w600),
              ),
              Text(
                'THD: ${widget.thdPercent.toStringAsFixed(2)}%',
                style: TextStyle(color: colors.accentAmber, fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ],
          );
          final plotArea = LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxHeight < 20 || constraints.maxWidth < 20) {
                return const SizedBox.shrink();
              }
              void updateCursor(double dx) {
                if (constraints.maxWidth <= 0) return;
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
                    painter: _SpectrumPainter(
                      fftBins: bins,
                      peakBin: peakBin,
                      ceilDbv: ceilDbv,
                      floorDbv: floorDbv,
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
            children: [
              Text(
                'Scale: ${ceilDbv.toInt()}..${floorDbv.toInt()} dBV',
                style: TextStyle(color: colors.componentStroke, fontSize: 11),
              ),
              if (df != null)
                Text('Span: ${formatEngValue(df * bins.length)}Hz', style: TextStyle(color: colors.scopeCh1, fontSize: 11)),
              if (cBin != null)
                Text(
                  'Marker: ${df != null ? "${formatEngValue(cBin * df)}Hz" : "Bin $cBin"} (${_magToRmsDbv(bins[cBin]).toStringAsFixed(1)} dBV)',
                  style: TextStyle(color: colors.accentAmber, fontSize: 11, fontWeight: FontWeight.w600),
                ),
            ],
          );
          if (box.maxHeight < 220) {
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

class _SpectrumPainter extends CustomPainter {
  final Float64List fftBins;
  final int peakBin;
  final double ceilDbv;
  final double floorDbv;
  final double? cursorFrac;
  final CircuitColors colors;

  _SpectrumPainter({
    required this.fftBins,
    required this.peakBin,
    required this.ceilDbv,
    required this.floorDbv,
    this.cursorFrac,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.canvasBackground);
    final grid = Paint()
      ..color = colors.gridMinor
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (fftBins.isEmpty) return;

    final spanDb = math.max(10.0, ceilDbv - floorDbv);
    final barW = size.width / fftBins.length;
    final normPaint = Paint()..color = colors.scopeCh1;
    final harmPaint = Paint()..color = colors.scopeCh2;
    final fundPaint = Paint()..color = colors.accentAmber;
    final path = Path();
    for (var i = 0; i < fftBins.length; i++) {
      final mag = fftBins[i].isFinite ? fftBins[i] : 0.0;
      final rms = math.max(mag / math.sqrt2, 1e-6);
      final dbv = 20.0 * math.log(rms) / math.ln10;
      final frac = ((dbv - floorDbv) / spanDb).clamp(0.0, 1.0);
      final h = frac * size.height * 0.92;
      final x = i * barW;
      final y = size.height - h;
      final isFund = i == peakBin;
      final isHarmonic = peakBin > 0 && i >= peakBin * 2 && (i % peakBin == 0) && (i ~/ peakBin <= 5);
      canvas.drawRect(
        Rect.fromLTWH(x, y, math.max(1.2, barW - 0.8), h),
        isFund ? fundPaint : (isHarmonic ? harmPaint : normPaint),
      );
      if (i == 0) {
        path.moveTo(x + barW * 0.5, y);
      } else {
        path.lineTo(x + barW * 0.5, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = colors.accentAmber.withAlpha(160)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    if (cursorFrac != null) {
      final cx = cursorFrac! * size.width;
      canvas.drawLine(
        Offset(cx, 0),
        Offset(cx, size.height),
        Paint()
          ..color = colors.accentAmber.withAlpha(200)
          ..strokeWidth = 1.2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter old) =>
      old.fftBins != fftBins ||
      old.peakBin != peakBin ||
      old.ceilDbv != ceilDbv ||
      old.floorDbv != floorDbv ||
      old.cursorFrac != cursorFrac ||
      old.colors != colors;
}
