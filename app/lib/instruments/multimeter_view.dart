import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../ffi/sim_ffi.dart';
import '../l10n/app_localizations.dart';
import '../state/circuit_doc.dart';
import '../theme/circuit_theme.dart';

enum DmmMode { voltageCurrent, resistance, continuity, diode }

class MultimeterView extends StatefulWidget {
  final ChannelStats ch1Stats;
  final ChannelStats ch2Stats;
  final ChannelStats? ch3Stats;
  final ChannelStats? ch4Stats;
  final Float64List? ch1Values;
  final Float64List? ch2Values;
  final Float64List? ch1Times;
  final double selectedCurrentAmps;
  final double selectedVoltageDrop;
  final double? selectedPowerWatts;
  final double ch1ThdPercent;
  final bool ch3Probed;
  final bool ch4Probed;
  final double? ch1DcFallback;
  final double? ch2DcFallback;
  final List<(int nodeId, String label)> availableNodes;
  final Future<double?> Function(int nodeA, int nodeB, bool diodeMode)? onMeasureTwoTerminal;

  const MultimeterView({
    super.key,
    required this.ch1Stats,
    required this.ch2Stats,
    this.ch3Stats,
    this.ch4Stats,
    this.ch1Values,
    this.ch2Values,
    this.ch1Times,
    required this.selectedCurrentAmps,
    this.selectedVoltageDrop = 0.0,
    this.selectedPowerWatts,
    this.ch1ThdPercent = 0.0,
    this.ch3Probed = false,
    this.ch4Probed = false,
    this.ch1DcFallback,
    this.ch2DcFallback,
    this.availableNodes = const [(1, 'N1'), (0, 'GND')],
    this.onMeasureTwoTerminal,
  });

  @override
  State<MultimeterView> createState() => _MultimeterViewState();
}

class _MultimeterViewState extends State<MultimeterView> {
  DmmMode _mode = DmmMode.voltageCurrent;
  int _nodeA = 1;
  int _nodeB = 0;
  double? _measuredOhms;
  double? _measuredDiodeV;
  bool _measuring = false;

  @override
  void initState() {
    super.initState();
    _syncNodeDefaults();
  }

  @override
  void didUpdateWidget(covariant MultimeterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncNodeDefaults();
  }

  void _syncNodeDefaults() {
    final ids = widget.availableNodes.map((n) => n.$1).toSet();
    if (!ids.contains(_nodeA) && widget.availableNodes.isNotEmpty) {
      _nodeA = widget.availableNodes.first.$1;
    }
    if (!ids.contains(_nodeB)) {
      _nodeB = ids.contains(0) ? 0 : (widget.availableNodes.length > 1 ? widget.availableNodes[1].$1 : _nodeA);
    }
  }

  Future<void> _runTwoTerminal(bool diode) async {
    if (widget.onMeasureTwoTerminal == null || _measuring) return;
    setState(() => _measuring = true);
    try {
      final res = await widget.onMeasureTwoTerminal!(_nodeA, _nodeB, diode);
      if (!mounted) return;
      setState(() {
        _measuring = false;
        if (diode) {
          _measuredDiodeV = res;
        } else {
          _measuredOhms = res;
        }
      });
    } finally {
      if (mounted && _measuring) setState(() => _measuring = false);
    }
  }

  String _dbv(double rms) {
    if (rms <= 1e-9) return '-inf dBV';
    final db = 20.0 * math.log(rms) / math.ln10;
    return '${db.toStringAsFixed(1)} dBV';
  }

  String _dbm(double trueRms) {
    if (trueRms <= 1e-9) return '-inf dBm';
    // Referenced to 600 ohm standard telecommunications load (1 mW = 0.7746 Vrms)
    final pMw = (trueRms * trueRms) / 600.0 * 1000.0;
    if (pMw <= 1e-12) return '-inf dBm';
    return '${(10.0 * math.log(pMw) / math.ln10).toStringAsFixed(1)} dBm';
  }

  double? _diffAcRms() {
    final a = widget.ch1Values;
    final b = widget.ch2Values;
    if (a == null || b == null) return null;
    final n = math.min(a.length, b.length);
    if (n < 2) return null;
    var mean = 0.0;
    for (var i = 0; i < n; i++) {
      mean += a[i] - b[i];
    }
    mean /= n;
    var sq = 0.0;
    for (var i = 0; i < n; i++) {
      final d = (a[i] - b[i]) - mean;
      sq += d * d;
    }
    return math.sqrt(sq / n);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CircuitColors>()!;
    final l10n = AppLocalizations.of(context)!;
    final dc1 = widget.ch1Stats.dc.abs() > 1e-12 ? widget.ch1Stats.dc : (widget.ch1DcFallback ?? 0.0);
    final dc2 = widget.ch2Stats.dc.abs() > 1e-12 ? widget.ch2Stats.dc : (widget.ch2DcFallback ?? 0.0);
    final effCh1 = ChannelStats(dc1, widget.ch1Stats.acRms, widget.ch1Stats.minV, widget.ch1Stats.maxV);
    final effCh2 = ChannelStats(dc2, widget.ch2Stats.acRms, widget.ch2Stats.minV, widget.ch2Stats.maxV);
    final diffDc = dc1 - dc2;
    final diffAc = _diffAcRms();
    final freqHz = widget.ch1Values != null ? measureWaveform(widget.ch1Values!, widget.ch1Times).$2 : null;
    final continuity = _measuredOhms != null && _measuredOhms! < 50.0;
    final showCh3 = widget.ch3Stats != null && (widget.ch3Probed || widget.ch3Stats!.dc.abs() > 1e-6 || widget.ch3Stats!.acRms > 1e-6);
    final showCh4 = widget.ch4Stats != null && (widget.ch4Probed || widget.ch4Stats!.dc.abs() > 1e-6 || widget.ch4Stats!.acRms > 1e-6);
    final powerW = widget.selectedPowerWatts ?? (widget.selectedVoltageDrop * widget.selectedCurrentAmps).abs();

    final omegaText = _measuredOhms == null
        ? 'Ω: Open'
        : (!_measuredOhms!.isFinite || _measuredOhms! >= 1e9)
            ? 'Ω: Open (>1GΩ)'
            : 'Ω: ${formatEngValue(_measuredOhms!)}Ω';

    return Container(
      decoration: BoxDecoration(
        color: colors.panelSurface,
        border: Border.all(color: colors.panelBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(10),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.speed, size: 16, color: colors.accentAmber),
                    const SizedBox(width: 6),
                    Text(
                      l10n.multimeterTitle,
                      style: TextStyle(color: colors.componentStroke, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                DropdownButton<DmmMode>(
                  value: _mode,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: DmmMode.voltageCurrent, child: Text('V/I/W/dBm', style: TextStyle(fontSize: 11))),
                    DropdownMenuItem(value: DmmMode.resistance, child: Text('Ω Probe', style: TextStyle(fontSize: 11))),
                    DropdownMenuItem(value: DmmMode.continuity, child: Text('Continuity', style: TextStyle(fontSize: 11))),
                    DropdownMenuItem(value: DmmMode.diode, child: Text('Diode Vf', style: TextStyle(fontSize: 11))),
                  ],
                  onChanged: (m) {
                    if (m == null) return;
                    setState(() => _mode = m);
                    if (m == DmmMode.resistance || m == DmmMode.continuity) _runTwoTerminal(false);
                    if (m == DmmMode.diode) _runTwoTerminal(true);
                  },
                ),
                if (freqHz != null)
                  Text(
                    'f: ${formatEngValue(freqHz)}Hz',
                    style: TextStyle(color: colors.accentAmber, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
              ],
            ),
            if (_mode != DmmMode.voltageCurrent && widget.availableNodes.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<int>(
                    value: _nodeA,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    items: widget.availableNodes
                        .map((n) => DropdownMenuItem(value: n.$1, child: Text('+ ${n.$2}', style: const TextStyle(fontSize: 11))))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _nodeA = v);
                    },
                  ),
                  DropdownButton<int>(
                    value: _nodeB,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    items: widget.availableNodes
                        .map((n) => DropdownMenuItem(value: n.$1, child: Text('- ${n.$2}', style: const TextStyle(fontSize: 11))))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _nodeB = v);
                    },
                  ),
                  FilledButton.tonal(
                    style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: _measuring ? null : () => _runTwoTerminal(_mode == DmmMode.diode),
                    child: Text(_mode == DmmMode.diode ? 'Measure Vf' : 'Measure Ω', style: const TextStyle(fontSize: 11)),
                  ),
                  if (_mode == DmmMode.diode)
                    Text(
                      _measuredDiodeV != null ? 'Vf: ${_measuredDiodeV!.toStringAsFixed(3)} V' : 'Vf: Open',
                      style: TextStyle(color: colors.accentAmber, fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            _channelCard('CH1', effCh1, colors.scopeCh1, colors, l10n),
            const SizedBox(height: 6),
            _channelCard('CH2', effCh2, colors.scopeCh2, colors, l10n),
            if (showCh3) ...[
              const SizedBox(height: 6),
              _channelCard('CH3', widget.ch3Stats!, colors.scopeCh3, colors, l10n),
            ],
            if (showCh4) ...[
              const SizedBox(height: 6),
              _channelCard('CH4', widget.ch4Stats!, colors.scopeCh4, colors, l10n),
            ],
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.canvasBackground,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.panelBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(l10n.currentLabel, style: TextStyle(color: colors.componentStroke)),
                      Text(
                        '${formatEngValue(widget.selectedCurrentAmps)}A',
                        style: TextStyle(
                          color: colors.accentAmber,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 12,
                    runSpacing: 2,
                    children: [
                      Text(
                        '${l10n.voltageDropLabel}: ${formatEngValue(widget.selectedVoltageDrop)}V',
                        style: TextStyle(color: colors.componentStroke, fontSize: 12),
                      ),
                      Text(
                        'V(CH1-CH2): ${diffDc.toStringAsFixed(3)} V${diffAc != null ? " (${diffAc.toStringAsFixed(3)} Vac)" : ""}',
                        style: TextStyle(color: colors.scopeCh2, fontSize: 12),
                      ),
                      Text(
                        '${l10n.powerLabel}: ${formatEngValue(powerW)}W',
                        style: TextStyle(color: colors.scopeCh1, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        'THD: ${widget.ch1ThdPercent.toStringAsFixed(2)}%',
                        style: TextStyle(color: colors.accentAmber, fontSize: 12),
                      ),
                      Text(
                        omegaText,
                        style: TextStyle(color: colors.componentStroke, fontSize: 12),
                      ),
                      if (continuity)
                        Text(
                          'CONT (<50Ω)',
                          style: TextStyle(color: colors.accentAmber, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _channelCard(
    String tag,
    ChannelStats s,
    Color accent,
    CircuitColors colors,
    AppLocalizations l10n,
  ) {
    final trueRms = math.sqrt(s.dc * s.dc + s.acRms * s.acRms);
    final minText = s.minV.isFinite ? s.minV.toStringAsFixed(2) : '0.00';
    final maxText = s.maxV.isFinite ? s.maxV.toStringAsFixed(2) : '0.00';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.canvasBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(tag, style: TextStyle(color: accent, fontWeight: FontWeight.bold)),
              const Spacer(),
              Text(
                '${_dbv(trueRms)} · ${_dbm(trueRms)}',
                style: TextStyle(color: colors.componentStroke, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 2,
            children: [
              Text('${l10n.dcVoltsLabel}: ${formatEngValue(s.dc)}V',
                  style: TextStyle(color: accent, fontWeight: FontWeight.w600, fontSize: 13)),
              Text('${l10n.acRmsLabel}: ${formatEngValue(s.acRms)}V',
                  style: TextStyle(color: colors.componentStroke, fontSize: 13)),
              Text('TRMS: ${formatEngValue(trueRms)}V',
                  style: TextStyle(color: colors.accentAmber, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${l10n.minMaxLabel}: $minText V / $maxText V',
            style: TextStyle(color: colors.componentStroke.withAlpha(180), fontSize: 11),
          ),
        ],
      ),
    );
  }
}
