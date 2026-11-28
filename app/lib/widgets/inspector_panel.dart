import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../state/circuit_doc.dart';
import '../theme/circuit_theme.dart';

class InspectorPanel extends StatelessWidget {
  final PlacedComponent? selected;
  final VoidCallback onRotate;
  final VoidCallback onDelete;
  final VoidCallback onEditHex;
  final VoidCallback onRecordUndo;
  final VoidCallback? onUngroupSubcircuit;
  final ValueChanged<String?>? onHotkeyChanged;
  final void Function(FaultType fault) onFaultChanged;
  final void Function(int compId, double value, {bool recordUndo}) onBinarySwitch;
  final void Function(PlacedComponent comp, int paramIdx, double value) onParamChanged;
  final void Function(PlacedComponent comp, ParamSpec spec, double current, String label)
      onEditParamNumeric;

  const InspectorPanel({
    super.key,
    required this.selected,
    required this.onRotate,
    required this.onDelete,
    required this.onEditHex,
    required this.onRecordUndo,
    this.onUngroupSubcircuit,
    this.onHotkeyChanged,
    required this.onFaultChanged,
    required this.onBinarySwitch,
    required this.onParamChanged,
    required this.onEditParamNumeric,
  });

  static bool _supportsHotkey(CompKind kind) =>
      kind == CompKind.switchSpst ||
      kind == CompKind.switchSpdt ||
      kind == CompKind.pushbutton ||
      kind == CompKind.potentiometer ||
      kind == CompKind.hexKeypad ||
      kind == CompKind.dipSwitch4;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).extension<CircuitColors>()!;
    final sel = selected;

    return Material(
      color: colors.panelSurface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: colors.panelBorder),
            bottom: BorderSide(color: colors.panelBorder),
          ),
        ),
        padding: const EdgeInsets.all(10),
      child: sel == null
          ? Center(
              child: Text(
                l10n.selectHint,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.componentStroke.withAlpha(180), fontSize: 12),
              ),
            )
          : ListView(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        sel.kind == CompKind.subcircuit && sel.subcircuitName != null
                            ? '${sel.subcircuitName} #${sel.id}'
                            : '${localizedCompName(l10n, sel.kind)} #${sel.id}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.accentAmber, fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.rotateAction,
                      icon: const Icon(Icons.rotate_right, size: 18),
                      onPressed: onRotate,
                    ),
                    IconButton(
                      tooltip: l10n.deleteAction,
                      icon: Icon(Icons.delete_outline, size: 18, color: colors.dangerRed),
                      onPressed: onDelete,
                    ),
                  ],
                ),
                if (sel.kind == CompKind.subcircuit && onUngroupSubcircuit != null) ...[
                  const SizedBox(height: 4),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.call_split, size: 15),
                    label: const Text('Ungroup Subcircuit', style: TextStyle(fontSize: 11)),
                    onPressed: onUngroupSubcircuit,
                  ),
                ],
                for (var i = 0; i < sel.meta.paramSpecs.length; i++)
                  _paramControl(context, sel, i, colors, l10n),
                if (sel.kind == CompKind.wordGen || sel.kind == CompKind.netPort) ...[
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: onEditHex,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        border: Border.all(color: colors.panelBorder),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              sel.kind == CompKind.wordGen
                                  ? 'HEX: ${sel.hexPattern ?? "FEDCBA9876543210"}'
                                  : 'NET: ${sel.hexPattern ?? "NET"}',
                              style: TextStyle(
                                color: colors.accentAmber,
                                fontFamily: 'monospace',
                                fontSize: 11,
                              ),
                            ),
                          ),
                          Icon(Icons.edit, size: 12, color: colors.accentAmber),
                        ],
                      ),
                    ),
                  ),
                ],
                if (_supportsHotkey(sel.kind) && onHotkeyChanged != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text('Hotkey:', style: TextStyle(color: colors.componentStroke, fontSize: 12)),
                      const SizedBox(width: 8),
                      DropdownButton<String?>(
                        value: kAllowedHotkeys.contains(sel.hotkey) ? sel.hotkey : null,
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('None', style: TextStyle(fontSize: 11)),
                          ),
                          for (final k in kAllowedHotkeys)
                            DropdownMenuItem<String?>(
                              value: k,
                              child: Text(k, style: const TextStyle(fontSize: 11)),
                            ),
                        ],
                        onChanged: onHotkeyChanged,
                      ),
                    ],
                  ),
                ],
                if (sel.kind != CompKind.ground &&
                    sel.kind != CompKind.netPort &&
                    sel.kind != CompKind.subcircuit) ...[
                  const SizedBox(height: 6),
                  Text(l10n.faultLabel, style: TextStyle(color: colors.componentStroke, fontSize: 12)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    children: FaultType.values.map((f) {
                      final label = switch (f) {
                        FaultType.none => l10n.faultNone,
                        FaultType.open => l10n.faultOpen,
                        FaultType.short => l10n.faultShort,
                        FaultType.leaky => l10n.faultLeaky,
                      };
                      final active = sel.fault == f;
                      return ChoiceChip(
                        selected: active,
                        label: Text(label, style: const TextStyle(fontSize: 11)),
                        selectedColor: f == FaultType.none ? colors.accentAmber : colors.dangerRed,
                        labelStyle: TextStyle(color: active ? Colors.black : colors.componentStroke),
                        onSelected: (_) => onFaultChanged(f),
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
      ),
    );
  }

  Widget _paramControl(
    BuildContext context,
    PlacedComponent c,
    int idx,
    CircuitColors colors,
    AppLocalizations l10n,
  ) {
    final spec = c.meta.paramSpecs[idx];
    final pIdx = spec.paramIndex;
    final label = localizedParamLabel(l10n, spec.key);
    if ((c.kind == CompKind.switchSpst ||
            c.kind == CompKind.switchSpdt ||
            c.kind == CompKind.pushbutton) &&
        pIdx == 0) {
      final closed = c.params[0] >= 0.5;
      return SwitchListTile(
        dense: true,
        title: Text(label, style: const TextStyle(fontSize: 12)),
        activeThumbColor: colors.accentAmber,
        value: closed,
        onChanged: (on) => onBinarySwitch(c.id, on ? 1.0 : 0.0, recordUndo: true),
      );
    }

    if (c.kind == CompKind.funcGen && spec.key == ParamKey.shape) {
      final cur = c.params[pIdx].round().clamp(0, 2);
      const shapes = [(0, 'Sine'), (1, 'Square'), (2, 'Tri')];
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Wrap(
          spacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('$label: ', style: TextStyle(color: colors.componentStroke, fontSize: 12)),
            for (final (v, name) in shapes)
              ChoiceChip(
                selected: cur == v,
                visualDensity: VisualDensity.compact,
                label: Text(name, style: const TextStyle(fontSize: 11)),
                selectedColor: colors.accentAmber,
                labelStyle: TextStyle(color: cur == v ? Colors.black : colors.componentStroke),
                onSelected: (_) {
                  onRecordUndo();
                  onParamChanged(c, pIdx, v.toDouble());
                },
              ),
          ],
        ),
      );
    }

    if (c.kind == CompKind.hexKeypad && pIdx == 0) {
      final cur = c.params[pIdx].round().clamp(0, 15);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Key: 0x${cur.toRadixString(16).toUpperCase()}',
              style: TextStyle(color: colors.accentAmber, fontSize: 12, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 3,
              runSpacing: 3,
              children: [
                for (var v = 0; v < 16; v++)
                  SizedBox(
                    width: 30,
                    height: 26,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        backgroundColor: cur == v ? colors.accentAmber : colors.canvasBackground,
                        foregroundColor: cur == v ? Colors.black : colors.componentStroke,
                      ),
                      onPressed: () {
                        onRecordUndo();
                        onParamChanged(c, pIdx, v.toDouble());
                      },
                      child: Text(v.toRadixString(16).toUpperCase(), style: const TextStyle(fontSize: 11)),
                    ),
                  ),
              ],
            ),
          ],
        ),
      );
    }

    if (c.kind == CompKind.dipSwitch4 && pIdx == 0) {
      final mask = c.params[pIdx].round().clamp(0, 15);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Wrap(
          spacing: 4,
          children: [
            for (var b = 0; b < 4; b++)
              FilterChip(
                selected: ((mask >> b) & 1) == 1,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                selectedColor: colors.accentAmber,
                label: Text(
                  'SW${b + 1}',
                  style: TextStyle(
                    fontSize: 11,
                    color: (((mask >> b) & 1) == 1) ? Colors.black : colors.componentStroke,
                  ),
                ),
                onSelected: (on) {
                  onRecordUndo();
                  final nextMask = on ? (mask | (1 << b)) : (mask & ~(1 << b));
                  onParamChanged(c, pIdx, nextMask.toDouble());
                },
              ),
          ],
        ),
      );
    }

    final rawVal = c.params[pIdx];
    final canLog = spec.logScale && rawVal > 0 && spec.min > 0;
    final effMin = math.min(spec.min, canLog ? rawVal : (spec.logScale ? spec.min : rawVal));
    final effMax = math.max(spec.max, rawVal);
    final span = effMax - effMin;
    final sliderVal = canLog
        ? (math.log(rawVal) - math.log(effMin)) /
            math.max(1e-9, math.log(effMax) - math.log(effMin))
        : (span > 1e-12 ? (rawVal - effMin) / span : 0.5);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => onEditParamNumeric(c, spec, rawVal, label),
          child: Row(
            children: [
              Text(
                '$label: ${formatEngValue(rawVal)}',
                style: TextStyle(color: colors.componentStroke, fontSize: 12),
              ),
              const SizedBox(width: 4),
              Icon(Icons.edit, size: 12, color: colors.accentAmber),
            ],
          ),
        ),
        Slider(
          value: sliderVal.clamp(0.0, 1.0),
          activeColor: colors.accentAmber,
          onChangeStart: (_) => onRecordUndo(),
          onChanged: (t) {
            final next = canLog
                ? math.exp(math.log(effMin) + t * (math.log(effMax) - math.log(effMin)))
                : effMin + t * (effMax - effMin);
            onParamChanged(c, pIdx, next);
          },
        ),
      ],
    );
  }
}
