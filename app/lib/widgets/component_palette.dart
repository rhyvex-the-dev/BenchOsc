import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../canvas/comp_symbols.dart';
import '../canvas/wire_router.dart';
import '../l10n/app_localizations.dart';
import '../state/circuit_doc.dart';
import '../state/parts_library.dart';
import '../state/subcircuits.dart';
import '../theme/circuit_theme.dart';

class ComponentPalette extends StatefulWidget {
  final String query;
  final Set<CompKind> favorites;
  final CompKind? placingKind;
  final String? placingSubcircuitName;
  final String? placingPartName;
  final Map<String, SubcircuitDef> subcircuits;
  final bool isPlacing;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<CompKind> onToggleFavorite;
  final ValueChanged<CompKind> onSelectKind;
  final ValueChanged<String>? onSelectSubcircuit;
  final ValueChanged<PartPreset>? onSelectPartPreset;

  const ComponentPalette({
    super.key,
    required this.query,
    required this.favorites,
    required this.placingKind,
    this.placingSubcircuitName,
    this.placingPartName,
    this.subcircuits = const {},
    required this.isPlacing,
    required this.onQueryChanged,
    required this.onToggleFavorite,
    required this.onSelectKind,
    this.onSelectSubcircuit,
    this.onSelectPartPreset,
  });

  @override
  State<ComponentPalette> createState() => _ComponentPaletteState();
}

class _ComponentPaletteState extends State<ComponentPalette> {
  late final TextEditingController _searchCtrl = TextEditingController(text: widget.query);
  final Set<String> _expandedSections = {'__favorites__', '__subcircuits__'};

  bool _isExpanded(String key, bool searching) => searching || _expandedSections.contains(key);

  void _toggleSection(String key) {
    setState(() {
      if (!_expandedSections.remove(key)) _expandedSections.add(key);
    });
  }

  @override
  void didUpdateWidget(covariant ComponentPalette oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query != _searchCtrl.text) {
      _searchCtrl.text = widget.query;
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).extension<CircuitColors>()!;

    String catLabel(CompCategory cat) => switch (cat) {
          CompCategory.powerSources => l10n.catPowerSources,
          CompCategory.passives => l10n.catPassives,
          CompCategory.switchesLoads => l10n.catSwitchesLoads,
          CompCategory.diodesLeds => l10n.catDiodesLeds,
          CompCategory.transistors => l10n.catTransistors,
          CompCategory.analogIcs => l10n.catAnalogIcs,
          CompCategory.logicGates => l10n.catLogicGates,
          CompCategory.digitalIcs => l10n.catDigitalIcs,
          CompCategory.metersIo => l10n.catMetersIo,
        };

    final q = widget.query.trim().toLowerCase();
    bool matches(CompKind kind) =>
        q.isEmpty || localizedCompName(l10n, kind).toLowerCase().contains(q);

    final favList = widget.favorites.where(matches).toList();
    final matchedSubs = widget.subcircuits.values
        .where((s) => q.isEmpty || s.name.toLowerCase().contains(q))
        .toList();
    final matchedParts = kPartsLibrary
        .where((p) =>
            q.isEmpty ||
            p.name.toLowerCase().contains(q) ||
            p.summary.toLowerCase().contains(q) ||
            p.family.toLowerCase().contains(q))
        .toList();

    final groups = <(String, String, List<CompKind>)>[
      if (favList.isNotEmpty) ('__favorites__', 'Favorites ★', favList),
      for (final cat in CompCategory.values)
        (
          cat.name,
          catLabel(cat),
          CompKind.values
              .where((k) => kCompMeta[k]!.category == cat && k != CompKind.subcircuit && matches(k))
              .toList(),
        ),
    ];

    final searching = q.isNotEmpty;

    Widget tileCard({
      required double width,
      required bool active,
      required Widget icon,
      required String label,
      bool monospace = false,
      required VoidCallback onTap,
      VoidCallback? onLongPress,
    }) {
      return SizedBox(
        width: width,
        height: 74,
        child: Material(
          color: active ? colors.accentAmber : colors.canvasBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: BorderSide(color: active ? colors.accentAmber : colors.panelBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  icon,
                  const SizedBox(height: 3),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.1,
                      fontFamily: monospace ? 'monospace' : null,
                      color: active ? Colors.black : colors.componentStroke,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    Widget paletteTile(CompKind kind, double width) {
      final active = widget.isPlacing &&
          widget.placingKind == kind &&
          widget.placingSubcircuitName == null &&
          widget.placingPartName == null;
      final labelText = localizedCompName(l10n, kind);
      return Draggable<CompKind>(
        data: kind,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Transform.translate(
          offset: const Offset(-48, -32),
          child: Material(
            color: Colors.transparent,
            child: tileCard(
              width: 96,
              active: true,
              icon: CompSymbolIcon(kind: kind, active: true, size: const Size(48, 34)),
              label: labelText,
              onTap: () {},
            ),
          ),
        ),
        child: tileCard(
          width: width,
          active: active,
          icon: CompSymbolIcon(kind: kind, active: active, size: const Size(48, 34)),
          label: labelText,
          onTap: () => widget.onSelectKind(kind),
          onLongPress: () => widget.onToggleFavorite(kind),
        ),
      );
    }

    Widget subcircuitTile(SubcircuitDef def, double width) {
      final active = widget.isPlacing && widget.placingSubcircuitName == def.name;
      return tileCard(
        width: width,
        active: active,
        icon: Icon(Icons.memory, size: 24, color: active ? Colors.black : colors.accentAmber),
        label: def.name,
        onTap: () => widget.onSelectSubcircuit?.call(def.name),
      );
    }

    Widget partTile(PartPreset part, double width) {
      final active = widget.isPlacing && widget.placingPartName == part.name;
      return Tooltip(
        message: '${part.family}: ${part.summary}',
        child: tileCard(
          width: width,
          active: active,
          icon: CompSymbolIcon(kind: part.kind, active: active, size: const Size(48, 34)),
          label: part.name,
          monospace: true,
          onTap: () => widget.onSelectPartPreset?.call(part),
        ),
      );
    }

    Widget sectionHeader(String key, String title, int count, bool expanded) {
      return InkWell(
        onTap: () => _toggleSection(key),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Row(
            children: [
              Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 16,
                color: colors.accentAmber,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.accentAmber,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              Text(
                '($count)',
                style: TextStyle(
                  color: colors.componentStroke.withAlpha(150),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget tileGrid(List<Widget> children) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Wrap(spacing: 6, runSpacing: 6, children: children),
        );

    return Container(
      decoration: BoxDecoration(
        color: colors.panelSurface,
        border: Border(right: BorderSide(color: colors.panelBorder)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
            child: TextField(
              controller: _searchCtrl,
              style: TextStyle(color: colors.componentStroke, fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 16),
                suffixIcon: widget.query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 14),
                        onPressed: () {
                          _searchCtrl.clear();
                          widget.onQueryChanged('');
                        },
                      )
                    : null,
                hintText: l10n.filterComponentsHint,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              ),
              onChanged: widget.onQueryChanged,
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (_, constraints) {
                final tileW = math.max(96.0, (constraints.maxWidth - 16 - 6) / 2);
                final subsExpanded = _isExpanded('__subcircuits__', searching);
                final partsExpanded = _isExpanded('__parts__', searching);
                return ListView(
                  padding: const EdgeInsets.all(8),
                  children: [
                    if (matchedSubs.isNotEmpty) ...[
                      sectionHeader('__subcircuits__', l10n.subcircuitsTitle, matchedSubs.length, subsExpanded),
                      if (subsExpanded)
                        tileGrid([for (final s in matchedSubs) subcircuitTile(s, tileW)]),
                    ],
                    for (final (key, catTitle, items) in groups)
                      if (items.isNotEmpty) ...[
                        Builder(
                          builder: (_) {
                            final expanded = _isExpanded(key, searching);
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                sectionHeader(key, catTitle, items.length, expanded),
                                if (expanded)
                                  tileGrid([for (final k in items) paletteTile(k, tileW)]),
                              ],
                            );
                          },
                        ),
                      ],
                    if (matchedParts.isNotEmpty && widget.onSelectPartPreset != null) ...[
                      sectionHeader('__parts__', l10n.partsLibraryTitle, matchedParts.length, partsExpanded),
                      if (partsExpanded)
                        tileGrid([for (final p in matchedParts) partTile(p, tileW)]),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Miniature schematic symbol preview reusing [paintComponentSymbol].
class CompSymbolIcon extends StatelessWidget {
  final CompKind kind;
  final bool active;
  final Size size;

  const CompSymbolIcon({
    super.key,
    required this.kind,
    this.active = false,
    this.size = const Size(20, 18),
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CircuitColors>()!;
    Widget icon = SizedBox(
      width: size.width,
      height: size.height,
      child: ClipRect(
        child: CustomPaint(
          painter: _CompSymbolPainter(kind: kind, colors: colors),
          size: size,
        ),
      ),
    );
    if (active) {
      icon = ColorFiltered(
        colorFilter: const ColorFilter.mode(Colors.black, BlendMode.srcIn),
        child: icon,
      );
    }
    return icon;
  }
}

class _CompSymbolPainter extends CustomPainter {
  static final CircuitDoc _emptyDoc = CircuitDoc();
  static final Map<CompKind, PlacedComponent> _dummyCache = {};

  final CompKind kind;
  final CircuitColors colors;

  _CompSymbolPainter({required this.kind, required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final comp = _dummyCache.putIfAbsent(
      kind,
      () => PlacedComponent(
        id: 0,
        kind: kind,
        gridX: 0,
        gridY: 0,
        params: kCompMeta[kind]!.defaults,
      ),
    );
    var minX = -kGridStep * 1.1;
    var maxX = kGridStep * 1.1;
    var minY = -kGridStep * 1.1;
    var maxY = kGridStep * 1.1;
    for (final p in comp.pinOffsets) {
      final px = p.dx * kGridStep;
      final py = p.dy * kGridStep;
      if (px < minX) minX = px;
      if (px > maxX) maxX = px;
      if (py < minY) minY = py;
      if (py > maxY) maxY = py;
    }
    final spanW = (maxX - minX) + kGridStep * 0.4;
    final spanH = (maxY - minY) + kGridStep * 0.4;
    final scale = math.min(size.width / spanW, size.height / spanH);

    final stroke = Paint()
      ..color = colors.componentStroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = (1.5 / scale).clamp(1.6, 4.0)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.save();
    canvas.translate(size.width * 0.5, size.height * 0.5);
    canvas.scale(scale, scale);
    canvas.translate(-0.5 * (minX + maxX), -0.5 * (minY + maxY));
    paintComponentSymbol(
      canvas: canvas,
      c: comp,
      doc: _emptyDoc,
      colors: colors,
      stroke: stroke,
      nodeVoltages: const {},
      compCurrents: const {},
      drawText: (c, text, center, color, fontSize, {bool cache = true}) {
        final tp = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(color: color, fontSize: fontSize, fontWeight: FontWeight.w600),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(c, center - Offset(tp.width * 0.5, tp.height * 0.5));
        tp.dispose();
      },
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CompSymbolPainter old) =>
      old.kind != kind || old.colors != colors;
}
