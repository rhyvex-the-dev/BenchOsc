import 'package:flutter/material.dart';

import '../theme/circuit_theme.dart';

enum WordGenPlayMode { cycle, burst, step }

/// Interactive 16-step (4-bit) Word Generator front panel synced with an active WordGen component.
class WordGenPanel extends StatefulWidget {
  final int? wordGenId;
  final List<(int id, String label, String hex, double freqHz)> wordGens;
  final ValueChanged<int>? onSelectWordGen;
  final String hexPattern;
  final double freqHz;
  final double tSim;
  final void Function(String hex)? onChangeHex;
  final void Function(String hex)? onStepHex;
  final void Function(double freqHz)? onChangeFreq;
  final VoidCallback? onAddWordGen;

  const WordGenPanel({
    super.key,
    required this.wordGenId,
    this.wordGens = const [],
    this.onSelectWordGen,
    this.hexPattern = 'FEDCBA9876543210',
    this.freqHz = 50.0,
    this.tSim = 0.0,
    this.onChangeHex,
    this.onStepHex,
    this.onChangeFreq,
    this.onAddWordGen,
  });

  @override
  State<WordGenPanel> createState() => _WordGenPanelState();
}

class _WordGenPanelState extends State<WordGenPanel> {
  WordGenPlayMode _mode = WordGenPlayMode.cycle;
  int _manualStep = 0;

  List<int> _nibbles(String hex) {
    final clean = hex.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '').toUpperCase().padLeft(16, '0');
    final padded = clean.substring(clean.length - 16);
    // Step 0 is LSB (rightmost hex character), step 15 is MSB (leftmost).
    return List.generate(16, (s) => int.parse(padded[15 - s], radix: 16));
  }

  void _setNibble(int step, int value) {
    if (widget.onChangeHex == null) return;
    final nibbles = _nibbles(widget.hexPattern);
    nibbles[step] = value & 0xF;
    final hex = List.generate(16, (i) => nibbles[15 - i].toRadixString(16).toUpperCase()).join();
    widget.onChangeHex!(hex);
  }

  int _activeStep() {
    if (_mode == WordGenPlayMode.step) return _manualStep & 0xF;
    final raw = widget.freqHz > 0 ? (widget.tSim * widget.freqHz).floor() : 0;
    if (_mode == WordGenPlayMode.burst) return raw.clamp(0, 15);
    return raw & 0xF;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CircuitColors>()!;
    if (widget.wordGenId == null) {
      return Container(
        decoration: BoxDecoration(
          color: colors.panelSurface,
          border: Border.all(color: colors.panelBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.all(12),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.grid_view, size: 24, color: colors.accentAmber),
              const SizedBox(height: 8),
              Text(
                'No Word Generator in circuit',
                style: TextStyle(color: colors.componentStroke, fontSize: 13),
              ),
              if (widget.onAddWordGen != null) ...[
                const SizedBox(height: 8),
                FilledButton.tonal(
                  onPressed: widget.onAddWordGen,
                  child: const Text('Add WordGen'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final nibbles = _nibbles(widget.hexPattern);
    final activeStep = _activeStep();
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
                  Icon(Icons.grid_view, size: 16, color: colors.accentAmber),
                  const SizedBox(width: 4),
                  if (widget.wordGens.length > 1 && widget.onSelectWordGen != null)
                    DropdownButton<int>(
                      value: widget.wordGenId,
                      isDense: true,
                      underline: const SizedBox.shrink(),
                      items: [
                        for (final w in widget.wordGens)
                          DropdownMenuItem(value: w.$1, child: Text(w.$2, style: const TextStyle(fontSize: 12))),
                      ],
                      onChanged: (id) {
                        if (id != null) widget.onSelectWordGen!(id);
                      },
                    )
                  else
                    Text(
                      'Word Gen WG${widget.wordGenId}',
                      style: TextStyle(color: colors.componentStroke, fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                ],
              ),
              DropdownButton<WordGenPlayMode>(
                value: _mode,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: WordGenPlayMode.cycle, child: Text('Cycle', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: WordGenPlayMode.burst, child: Text('Burst', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: WordGenPlayMode.step, child: Text('Step', style: TextStyle(fontSize: 11))),
                ],
                onChanged: (m) {
                  if (m == null) return;
                  final wasStep = _mode == WordGenPlayMode.step;
                  setState(() => _mode = m);
                  if (wasStep && m != WordGenPlayMode.step) {
                    widget.onStepHex?.call(widget.hexPattern);
                  }
                },
              ),
              if (_mode == WordGenPlayMode.step)
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                  label: Text('Step +1', style: TextStyle(fontSize: 10, color: colors.accentAmber)),
                  onPressed: () {
                    setState(() => _manualStep = (_manualStep + 1) & 0xF);
                    final val = nibbles[_manualStep];
                    final fillHex = List.filled(16, val.toRadixString(16).toUpperCase()).join();
                    (widget.onStepHex ?? widget.onChangeHex)?.call(fillHex);
                  },
                ),
              DropdownButton<double>(
                value: const [1.0, 10.0, 50.0, 100.0, 500.0, 1000.0, 10000.0].contains(widget.freqHz)
                    ? widget.freqHz
                    : null,
                hint: Text('${widget.freqHz.toStringAsFixed(0)}Hz', style: const TextStyle(fontSize: 11)),
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [1.0, 10.0, 50.0, 100.0, 500.0, 1000.0, 10000.0]
                    .map((f) => DropdownMenuItem(value: f, child: Text('${f.toInt()}Hz', style: const TextStyle(fontSize: 11))))
                    .toList(),
                onChanged: (f) {
                  if (f != null) widget.onChangeFreq?.call(f);
                },
              ),
              Wrap(
                spacing: 4,
                children: [
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                    label: Text('Up', style: TextStyle(fontSize: 10, color: colors.componentStroke)),
                    onPressed: () => widget.onChangeHex?.call('FEDCBA9876543210'),
                  ),
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                    label: Text('Alt', style: TextStyle(fontSize: 10, color: colors.componentStroke)),
                    onPressed: () => widget.onChangeHex?.call('A5A5A5A5A5A5A5A5'),
                  ),
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                    label: Text('Clr', style: TextStyle(fontSize: 10, color: colors.componentStroke)),
                    onPressed: () => widget.onChangeHex?.call('0000000000000000'),
                  ),
                ],
              ),
            ],
          );
          final colsHeader = Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              children: [
                SizedBox(width: 28, child: Text('Stp', style: TextStyle(color: colors.componentStroke, fontSize: 10))),
                for (final lbl in const ['B3', 'B2', 'B1', 'B0'])
                  SizedBox(width: 26, child: Text(lbl, textAlign: TextAlign.center, style: TextStyle(color: colors.componentStroke, fontSize: 10))),
                const Spacer(),
                Text('Hex', style: TextStyle(color: colors.componentStroke, fontSize: 10)),
              ],
            ),
          );
          final stepList = ListView.builder(
            itemCount: 16,
            itemBuilder: (context, step) {
              final val = nibbles[step];
              final isActive = step == activeStep;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: isActive ? colors.accentAmber.withAlpha(32) : null,
                  border: Border(bottom: BorderSide(color: colors.panelBorder)),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 28,
                      child: Text(
                        'S${step.toRadixString(16).toUpperCase()}',
                        style: TextStyle(
                          color: colors.accentAmber,
                          fontFamily: 'monospace',
                          fontSize: 11,
                          fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                    for (var bit = 3; bit >= 0; bit--)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: InkWell(
                          onTap: () => _setNibble(step, val ^ (1 << bit)),
                          child: Container(
                            width: 22,
                            height: 20,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: ((val >> bit) & 1) == 1 ? colors.accentAmber : colors.canvasBackground,
                              borderRadius: BorderRadius.circular(3),
                              border: Border.all(color: colors.panelBorder),
                            ),
                            child: Text(
                              '${(val >> bit) & 1}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: ((val >> bit) & 1) == 1 ? Colors.black : colors.componentStroke,
                              ),
                            ),
                          ),
                        ),
                      ),
                    const Spacer(),
                    Text(
                      '0x${val.toRadixString(16).toUpperCase()}',
                      style: TextStyle(color: colors.scopeCh2, fontFamily: 'monospace', fontSize: 12),
                    ),
                  ],
                ),
              );
            },
          );
          if (box.maxHeight < 220) {
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  const SizedBox(height: 4),
                  colsHeader,
                  SizedBox(height: 120, child: stepList),
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const SizedBox(height: 4),
              colsHeader,
              Expanded(child: stepList),
            ],
          );
        },
      ),
    );
  }
}
