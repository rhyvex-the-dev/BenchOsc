import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/circuit_theme.dart';

enum LogicProtocol { off, spi, i2c, uart }

/// Decodes SPI (SCK=D0, MOSI=D1, optional MISO=D2, optional active-low CS=D3) across Modes 0..3.
String decodeSpiProtocol(
  List<bool> Function(int ch) hiFn,
  int n, {
  int mode = 0,
  bool hasMiso = false,
  bool hasCs = false,
}) {
  if (n < 4) return 'SPI: waiting';
  final cpol = (mode >> 1) & 1;
  final cpha = mode & 1;
  // Trailing vs leading edge depends on CPOL ^ CPHA.
  final sampleRising = (cpol ^ cpha) == 0;
  var mosiByte = 0, misoByte = 0, bits = 0;
  final out = <String>[];
  final sck = hiFn(0), mosi = hiFn(1);
  final len = math.min(n, math.min(sck.length, mosi.length));
  if (len < 2) return 'SPI: need ≥2 samples on CH1(SCK)/CH2(MOSI)';
  final miso = hasMiso ? hiFn(2) : const <bool>[];
  final cs = hasCs ? hiFn(3) : const <bool>[];
  for (var i = 1; i < len && out.length < 6; i++) {
    if (hasCs && i < cs.length && cs[i]) {
      mosiByte = 0;
      misoByte = 0;
      bits = 0;
      continue;
    }
    final isRising = !sck[i - 1] && sck[i];
    final isFalling = sck[i - 1] && !sck[i];
    if ((sampleRising && isRising) || (!sampleRising && isFalling)) {
      mosiByte = (mosiByte << 1) | (mosi[i] ? 1 : 0);
      if (hasMiso && i < miso.length) {
        misoByte = (misoByte << 1) | (miso[i] ? 1 : 0);
      }
      if (++bits == 8) {
        final hx = '0x${mosiByte.toRadixString(16).toUpperCase().padLeft(2, '0')}';
        if (hasMiso) {
          final mx = '0x${misoByte.toRadixString(16).toUpperCase().padLeft(2, '0')}';
          out.add('$hx/$mx');
        } else {
          out.add(hx);
        }
        mosiByte = 0;
        misoByte = 0;
        bits = 0;
      }
    }
  }
  return out.isEmpty ? 'SPI M$mode: idle' : 'SPI M$mode: ${out.join(' ')}';
}

/// Decodes I2C START/STOP framing, 7-bit address + R/W direction bit, data bytes, and ACK/NACK.
String decodeI2cProtocol(List<bool> scl, List<bool> sda) {
  final n = math.min(scl.length, sda.length);
  if (n < 4) return 'I2C: waiting';
  final out = <String>[];
  var active = false;
  var firstByte = true;
  var byte = 0, bits = 0;
  for (var i = 1; i < n && out.length < 8; i++) {
    if (scl[i - 1] && scl[i] && sda[i - 1] && !sda[i]) {
      out.add('S');
      active = true;
      firstByte = true;
      byte = 0;
      bits = 0;
    } else if (scl[i - 1] && scl[i] && !sda[i - 1] && sda[i]) {
      if (active) out.add('P');
      active = false;
      bits = 0;
    } else if (active && !scl[i - 1] && scl[i]) {
      if (bits < 8) {
        byte = (byte << 1) | (sda[i] ? 1 : 0);
        bits++;
      } else {
        final ack = sda[i] ? 'N' : 'A';
        if (firstByte) {
          final addr = (byte >> 1).toRadixString(16).toUpperCase().padLeft(2, '0');
          final rw = (byte & 1) == 1 ? 'R' : 'W';
          out.add('0x$addr($rw)$ack');
          firstByte = false;
        } else {
          out.add('0x${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}$ack');
        }
        byte = 0;
        bits = 0;
      }
    }
  }
  return out.isEmpty ? 'I2C: idle' : 'I2C: ${out.join(' ')}';
}

/// Time-based 8N1 UART decoder using exact sample timestamps (supports configured or auto-inferred baud).
String decodeUartProtocol(List<bool> rx, Float64List? times, {int baudHz = 0}) {
  final n = rx.length;
  if (n < 8) return 'UART: waiting';
  if (times == null || times.length != n) return 'UART: no timebase';
  double bitDur;
  if (baudHz > 0) {
    bitDur = 1.0 / baudHz;
  } else {
    var minDur = double.infinity;
    double? prevEdgeT;
    for (var i = 1; i < n; i++) {
      if (rx[i] != rx[i - 1]) {
        if (prevEdgeT != null) {
          final d = times[i] - prevEdgeT;
          if (d > 1e-7 && d < minDur) minDur = d;
        }
        prevEdgeT = times[i];
      }
    }
    if (!minDur.isFinite) return 'UART: idle';
    bitDur = minDur;
  }

  int sampleAt(double tTarget, int startHint) {
    var j = startHint;
    while (j + 1 < n && times[j + 1] <= tTarget) {
      j++;
    }
    return j;
  }

  final out = <String>[];
  var i = 1;
  while (i < n && out.length < 6) {
    if (rx[i - 1] && !rx[i]) {
      final tStart = times[i];
      if (tStart + 9.0 * bitDur > times.last + 1e-12) break;
      var val = 0;
      for (var k = 0; k < 8; k++) {
        final sIdx = sampleAt(tStart + (k + 1.5) * bitDur, i);
        if (rx[sIdx]) val |= (1 << k);
      }
      final stopIdx = sampleAt(tStart + 9.5 * bitDur, i);
      if (rx[stopIdx]) {
        out.add('0x${val.toRadixString(16).toUpperCase().padLeft(2, '0')}');
        i = stopIdx + 1;
      } else {
        i++;
      }
    } else {
      i++;
    }
  }
  return out.isEmpty ? 'UART: idle' : 'UART: ${out.join(' ')}';
}

class LogicAnalyzerView extends StatefulWidget {
  final Float64List ch1;
  final Float64List ch2;
  final Float64List ch3;
  final Float64List ch4;
  final Float64List? times;
  final Float64List? logicTimes;
  final Uint16List? logicMasks;
  final List<String> channelLabels;
  final void Function(List<int> nodes, double threshold)? onConfigChanged;

  const LogicAnalyzerView({
    super.key,
    required this.ch1,
    required this.ch2,
    required this.ch3,
    required this.ch4,
    this.times,
    this.logicTimes,
    this.logicMasks,
    this.channelLabels = const [],
    this.onConfigChanged,
  });

  @override
  State<LogicAnalyzerView> createState() => _LogicAnalyzerViewState();
}

class _LogicAnalyzerViewState extends State<LogicAnalyzerView> {
  int _zoom = 1;
  double _panFrac = 0.0;
  bool _hold = false;
  double _threshold = 1.5; // 0.9=1.8V, 1.5=3.3V, 2.5=5V
  int _activeCursor = 1;
  double? _c1Frac;
  double? _c2Frac;
  LogicProtocol _protocol = LogicProtocol.off;
  int _spiMode = 0;
  bool _spiUseMiso = false;
  bool _spiUseCs = false;
  int _uartBaud = 0; // 0 = Auto
  final Map<String, TextPainter> _labelCache = {};
  String _cachedProtoText = '';
  LogicProtocol? _cachedProto;
  int _cachedProtoNumCh = -1;
  int _cachedProtoMaxLen = -1;
  bool? _cachedProtoUseDigital;
  int _cachedSpiMode = -1;
  bool? _cachedSpiMiso;
  bool? _cachedSpiCs;
  int _cachedUartBaud = -1;
  double _cachedProtoThresh = double.nan;
  Uint16List? _cachedLMasks;
  Float64List? _cachedTimes;
  Float64List? _cachedAna0;
  Float64List? _cachedAna1;
  Float64List? _cachedAna2;
  Float64List? _cachedAna3;

  @override
  void dispose() {
    for (final tp in _labelCache.values) {
      tp.dispose();
    }
    _labelCache.clear();
    super.dispose();
  }

  List<Float64List> _heldAna = List.generate(4, (_) => Float64List(0));
  Float64List? _heldTimes;
  Float64List _heldLogicTimes = Float64List(0);
  Uint16List _heldLogicMasks = Uint16List(0);

  void _toggleHold() {
    setState(() {
      _hold = !_hold;
      if (_hold) {
        _heldAna = [
          Float64List.fromList(widget.ch1),
          Float64List.fromList(widget.ch2),
          Float64List.fromList(widget.ch3),
          Float64List.fromList(widget.ch4),
        ];
        _heldTimes = widget.times != null ? Float64List.fromList(widget.times!) : null;
        _heldLogicTimes = Float64List.fromList(widget.logicTimes ?? Float64List(0));
        _heldLogicMasks = Uint16List.fromList(widget.logicMasks ?? Uint16List(0));
      }
    });
  }

  String _decodeProtocol({
    required int numCh,
    required int maxLen,
    required bool useDigital,
    required Uint16List lMasks,
    required List<Float64List> anaCh,
    required Float64List? times,
  }) {
    if (_protocol == LogicProtocol.off || numCh == 0) return '';
    final a0 = anaCh.isNotEmpty ? anaCh[0] : null;
    final a1 = anaCh.length > 1 ? anaCh[1] : null;
    final a2 = anaCh.length > 2 ? anaCh[2] : null;
    final a3 = anaCh.length > 3 ? anaCh[3] : null;
    if (_cachedProto == _protocol &&
        _cachedProtoNumCh == numCh &&
        _cachedProtoMaxLen == maxLen &&
        _cachedProtoUseDigital == useDigital &&
        _cachedSpiMode == _spiMode &&
        _cachedSpiMiso == _spiUseMiso &&
        _cachedSpiCs == _spiUseCs &&
        _cachedUartBaud == _uartBaud &&
        _cachedProtoThresh == _threshold &&
        identical(_cachedLMasks, lMasks) &&
        identical(_cachedTimes, times) &&
        identical(_cachedAna0, a0) &&
        identical(_cachedAna1, a1) &&
        identical(_cachedAna2, a2) &&
        identical(_cachedAna3, a3)) {
      return _cachedProtoText;
    }
    final n = useDigital ? maxLen : anaCh[0].length;
    String decoded;
    if (n < 4) {
      decoded = '${_protocol.name.toUpperCase()}: waiting';
    } else {
      List<bool> extractCh(int ch) {
        if (ch >= numCh) return const [];
        if (useDigital) {
          return List<bool>.generate(maxLen, (i) => ((lMasks[i] >> ch) & 1) == 1);
        }
        final arr = anaCh[ch];
        return List<bool>.generate(arr.length, (i) => arr[i] >= _threshold);
      }

      if (_protocol == LogicProtocol.spi) {
        final hasMiso = _spiUseMiso && numCh > 2;
        final hasCs = _spiUseCs && numCh > 3;
        final chCache = <int, List<bool>>{};
        List<bool> getCh(int c) => chCache.putIfAbsent(c, () => extractCh(c));
        decoded = decodeSpiProtocol(
          getCh,
          n,
          mode: _spiMode,
          hasMiso: hasMiso,
          hasCs: hasCs,
        );
      } else if (_protocol == LogicProtocol.i2c) {
        decoded = decodeI2cProtocol(extractCh(0), extractCh(1));
      } else {
        decoded = decodeUartProtocol(extractCh(0), times, baudHz: _uartBaud);
      }
    }
    _cachedProto = _protocol;
    _cachedProtoNumCh = numCh;
    _cachedProtoMaxLen = maxLen;
    _cachedProtoUseDigital = useDigital;
    _cachedSpiMode = _spiMode;
    _cachedSpiMiso = _spiUseMiso;
    _cachedSpiCs = _spiUseCs;
    _cachedUartBaud = _uartBaud;
    _cachedProtoThresh = _threshold;
    _cachedLMasks = lMasks;
    _cachedTimes = times;
    _cachedAna0 = a0;
    _cachedAna1 = a1;
    _cachedAna2 = a2;
    _cachedAna3 = a3;
    _cachedProtoText = decoded;
    return decoded;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CircuitColors>()!;
    final l10n = AppLocalizations.of(context)!;
    final lMasks = _hold ? _heldLogicMasks : (widget.logicMasks ?? Uint16List(0));
    final lTimes = _hold ? _heldLogicTimes : (widget.logicTimes ?? Float64List(0));
    final anaCh = _hold ? _heldAna : [widget.ch1, widget.ch2, widget.ch3, widget.ch4];
    final useDigital = lMasks.isNotEmpty && lMasks.length == lTimes.length;
    final numCh = useDigital ? math.min(16, math.max(8, widget.channelLabels.length)) : 4;

    final maxLen = useDigital
        ? lMasks.length
        : anaCh.fold<int>(0, (m, c) => c.length > m ? c.length : m);

    final times = useDigital ? lTimes : (_hold ? _heldTimes : widget.times);
    final visLen = maxLen == 0 ? 0 : math.max(2, (maxLen / _zoom).round()).clamp(2, maxLen);
    final startIdx = maxLen <= visLen ? 0 : (_panFrac * (maxLen - visLen)).round().clamp(0, maxLen - visLen);

    int? idxFor(double? frac) => (visLen == 0 || frac == null)
        ? null
        : (startIdx + (frac * (visLen - 1)).round()).clamp(0, maxLen - 1);

    final sampleIdx = idxFor(_c1Frac) ?? (maxLen == 0 ? null : (startIdx + visLen - 1).clamp(0, maxLen - 1));
    final c2Idx = idxFor(_c2Frac);

    var wordVal = 0;
    final bits = List.filled(numCh, 0);
    if (sampleIdx != null) {
      for (var k = 0; k < numCh; k++) {
        final high = useDigital
            ? ((lMasks[sampleIdx] >> k) & 1) == 1
            : (sampleIdx < anaCh[k].length && anaCh[k][sampleIdx] >= _threshold);
        final b = high ? 1 : 0;
        bits[k] = b;
        wordVal |= (b << k);
      }
    }
    final hexStr = wordVal.toRadixString(16).toUpperCase();
    final tPart = (sampleIdx != null && times != null && sampleIdx < times.length)
        ? 't=${(times[sampleIdx] * 1000).toStringAsFixed(2)}ms · '
        : '';
    var dtPart = '';
    if (sampleIdx != null && c2Idx != null && times != null && sampleIdx < times.length && c2Idx < times.length) {
      final dt = (times[c2Idx] - times[sampleIdx]).abs();
      final fStr = dt > 1e-9 ? ' (${(1.0 / dt).toStringAsFixed(1)}Hz)' : '';
      dtPart = ' · Δt=${(dt * 1000).toStringAsFixed(2)}ms$fStr';
    }
    final protoText = _decodeProtocol(
      numCh: numCh,
      maxLen: maxLen,
      useDigital: useDigital,
      lMasks: lMasks,
      anaCh: anaCh,
      times: times,
    );

    return Container(
      decoration: BoxDecoration(
        color: colors.panelSurface,
        border: Border.all(color: colors.panelBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.view_stream, size: 16, color: colors.accentAmber),
                  const SizedBox(width: 4),
                  Text(
                    l10n.logicAnalyzerTitle,
                    style: TextStyle(color: colors.componentStroke, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ],
              ),
              Wrap(
                spacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<double>(
                    value: _threshold,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: 0.9, child: Text('1.8V', style: TextStyle(fontSize: 10))),
                      DropdownMenuItem(value: 1.5, child: Text('3.3V', style: TextStyle(fontSize: 10))),
                      DropdownMenuItem(value: 2.5, child: Text('5.0V', style: TextStyle(fontSize: 10))),
                    ],
                    onChanged: (th) {
                      if (th == null) return;
                      setState(() => _threshold = th);
                      widget.onConfigChanged?.call(const [], th);
                    },
                  ),
                  DropdownButton<int>(
                    value: _zoom,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    items: const [1, 2, 4, 8]
                        .map((z) => DropdownMenuItem(value: z, child: Text('${z}x', style: const TextStyle(fontSize: 11))))
                        .toList(),
                    onChanged: (z) {
                      if (z != null) setState(() => _zoom = z);
                    },
                  ),
                  DropdownButton<LogicProtocol>(
                    value: _protocol,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: LogicProtocol.off, child: Text('Proto:Off', style: TextStyle(fontSize: 11))),
                      DropdownMenuItem(value: LogicProtocol.spi, child: Text('SPI', style: TextStyle(fontSize: 11))),
                      DropdownMenuItem(value: LogicProtocol.i2c, child: Text('I2C', style: TextStyle(fontSize: 11))),
                      DropdownMenuItem(value: LogicProtocol.uart, child: Text('UART', style: TextStyle(fontSize: 11))),
                    ],
                    onChanged: (p) {
                      if (p != null) setState(() => _protocol = p);
                    },
                  ),
                  if (_protocol == LogicProtocol.spi) ...[
                    DropdownButton<int>(
                      value: _spiMode,
                      isDense: true,
                      underline: const SizedBox.shrink(),
                      items: const [0, 1, 2, 3]
                          .map((m) => DropdownMenuItem(value: m, child: Text('M$m', style: const TextStyle(fontSize: 10))))
                          .toList(),
                      onChanged: (m) {
                        if (m != null) setState(() => _spiMode = m);
                      },
                    ),
                    if (numCh > 2)
                      FilterChip(
                        selected: _spiUseMiso,
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                        label: const Text('MISO', style: TextStyle(fontSize: 10)),
                        onSelected: (v) => setState(() => _spiUseMiso = v),
                      ),
                    if (numCh > 3)
                      FilterChip(
                        selected: _spiUseCs,
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                        label: const Text('CS', style: TextStyle(fontSize: 10)),
                        onSelected: (v) => setState(() => _spiUseCs = v),
                      ),
                  ],
                  if (_protocol == LogicProtocol.uart)
                    DropdownButton<int>(
                      value: _uartBaud,
                      isDense: true,
                      underline: const SizedBox.shrink(),
                      items: const [0, 9600, 19200, 57600, 115200]
                          .map((b) => DropdownMenuItem(
                                value: b,
                                child: Text(b == 0 ? 'Auto' : '$b', style: const TextStyle(fontSize: 10)),
                              ))
                          .toList(),
                      onChanged: (b) {
                        if (b != null) setState(() => _uartBaud = b);
                      },
                    ),
                  FilterChip(
                    selected: _hold,
                    showCheckmark: false,
                    selectedColor: colors.dangerRed.withAlpha(70),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                    label: Text('Hold', style: TextStyle(fontSize: 10, color: _hold ? colors.dangerRed : colors.componentStroke)),
                    onSelected: (_) => _toggleHold(),
                  ),
                  ChoiceChip(
                    selected: _activeCursor == 1,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                    label: Text('C1', style: TextStyle(fontSize: 10, color: colors.componentStroke)),
                    onSelected: (_) => setState(() => _activeCursor = 1),
                  ),
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
              Text(
                '${tPart}0b${bits.reversed.join()} (0x$hexStr)$dtPart',
                style: TextStyle(
                  color: colors.accentAmber,
                  fontFamily: 'monospace',
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          if (_zoom > 1)
            SizedBox(
              height: 20,
              child: Slider(
                value: _panFrac,
                onChanged: (v) => setState(() => _panFrac = v),
              ),
            ),
          if (protoText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                protoText,
                style: TextStyle(color: colors.scopeCh2, fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          const SizedBox(height: 4),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxHeight < 20 || constraints.maxWidth < 20) {
                  return const SizedBox.shrink();
                }
                void updateCursor(double dx) {
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
                      painter: _LogicAnalyzerPainter(
                        numCh: numCh,
                        useDigital: useDigital,
                        lMasks: lMasks,
                        anaCh: anaCh,
                        threshold: _threshold,
                        labelCache: _labelCache,
                        labels: [
                          for (var i = 0; i < numCh; i++)
                            i < widget.channelLabels.length ? widget.channelLabels[i] : 'D$i',
                        ],
                        startIdx: startIdx,
                        visLen: visLen,
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
        ],
      ),
    );
  }
}

class _LogicAnalyzerPainter extends CustomPainter {
  final int numCh;
  final bool useDigital;
  final Uint16List lMasks;
  final List<Float64List> anaCh;
  final double threshold;
  final Map<String, TextPainter> labelCache;
  final List<String> labels;
  final int startIdx;
  final int visLen;
  final double? c1Frac;
  final double? c2Frac;
  final CircuitColors colors;

  _LogicAnalyzerPainter({
    required this.numCh,
    required this.useDigital,
    required this.lMasks,
    required this.anaCh,
    required this.threshold,
    required this.labelCache,
    required this.labels,
    required this.startIdx,
    required this.visLen,
    required this.c1Frac,
    required this.c2Frac,
    required this.colors,
  });

  TextPainter _labelPainter(String text, Color color) {
    final key = '$text|${color.toARGB32()}';
    return labelCache.putIfAbsent(key, () {
      if (labelCache.length > 64) {
        for (final tp in labelCache.values) {
          tp.dispose();
        }
        labelCache.clear();
      }
      return TextPainter(
        text: TextSpan(text: text, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.canvasBackground);
    final palette = [
      colors.scopeCh1,
      colors.scopeCh2,
      colors.scopeCh3,
      colors.scopeCh4,
    ];
    if (numCh == 0) return;
    final laneH = size.height / numCh;
    final grid = Paint()
      ..color = colors.gridMinor
      ..strokeWidth = 1;

    for (var ch = 0; ch < numCh; ch++) {
      final top = ch * laneH;
      if (ch > 0) {
        canvas.drawLine(Offset(0, top), Offset(size.width, top), grid);
      }
      final laneCol = palette[ch % palette.length];
      _labelPainter(labels[ch], laneCol).paint(canvas, Offset(3, top + 2));

      final len = useDigital ? lMasks.length : anaCh[ch].length;
      if (visLen < 2 || startIdx >= len) continue;
      final endIdx = math.min(len, startIdx + visLen);
      final count = endIdx - startIdx;
      if (count < 2) continue;

      final yHi = top + laneH * 0.22;
      final yLo = top + laneH * 0.80;
      final path = Path();
      bool bitAt(int idx) => useDigital
          ? ((lMasks[idx] >> ch) & 1) == 1
          : anaCh[ch][idx] >= threshold;
      var prevHi = bitAt(startIdx);
      path.moveTo(0, prevHi ? yHi : yLo);
      for (var i = 1; i < count; i++) {
        final x = (i / (count - 1)) * size.width;
        final hi = bitAt(startIdx + i);
        if (hi != prevHi) {
          path.lineTo(x, prevHi ? yHi : yLo);
          path.lineTo(x, hi ? yHi : yLo);
          prevHi = hi;
        } else {
          path.lineTo(x, hi ? yHi : yLo);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = laneCol
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }

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
  }

  @override
  bool shouldRepaint(covariant _LogicAnalyzerPainter old) {
    if (old.numCh != numCh ||
        old.useDigital != useDigital ||
        old.lMasks != lMasks ||
        old.threshold != threshold ||
        old.startIdx != startIdx ||
        old.visLen != visLen ||
        old.c1Frac != c1Frac ||
        old.c2Frac != c2Frac ||
        old.colors != colors ||
        old.labels.length != labels.length ||
        old.anaCh.length != anaCh.length) {
      return true;
    }
    for (var i = 0; i < labels.length; i++) {
      if (old.labels[i] != labels[i]) return true;
    }
    for (var i = 0; i < anaCh.length; i++) {
      if (old.anaCh[i] != anaCh[i]) return true;
    }
    return false;
  }
}
