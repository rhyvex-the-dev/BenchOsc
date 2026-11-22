import 'package:flutter/material.dart';

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
          CompCategory.sources => l10n.catSources,
          CompCategory.passive => l10n.catPassive,
          CompCategory.semiconductors => l10n.catSemiconductors,
          CompCategory.digital => l10n.catDigital,
          CompCategory.meters => l10n.catMeters,
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

    final groups = <(String, List<CompKind>)>[
      if (favList.isNotEmpty) ('Favorites ★', favList),
      for (final cat in CompCategory.values)
        (
          catLabel(cat),
          CompKind.values
              .where((k) => kCompMeta[k]!.category == cat && k != CompKind.subcircuit && matches(k))
              .toList(),
        ),
    ];

    Widget paletteChip(CompKind kind) {
      final active = widget.isPlacing &&
          widget.placingKind == kind &&
          widget.placingSubcircuitName == null &&
          widget.placingPartName == null;
      final labelText = localizedCompName(l10n, kind);
      final chip = GestureDetector(
        onLongPress: () => widget.onToggleFavorite(kind),
        child: ActionChip(
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          labelPadding: const EdgeInsets.symmetric(horizontal: 4),
          backgroundColor: active ? colors.accentAmber : colors.canvasBackground,
          label: Text(
            labelText,
            style: TextStyle(
              fontSize: 11,
              color: active ? Colors.black : colors.componentStroke,
            ),
          ),
          onPressed: () => widget.onSelectKind(kind),
        ),
      );
      return Draggable<CompKind>(
        data: kind,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Transform.translate(
          offset: const Offset(-40, -16),
          child: Material(
            color: Colors.transparent,
            child: Chip(
              label: Text(labelText, style: const TextStyle(fontSize: 11, color: Colors.black)),
              backgroundColor: colors.accentAmber,
            ),
          ),
        ),
        child: chip,
      );
    }

    Widget subcircuitChip(SubcircuitDef def) {
      final active = widget.isPlacing && widget.placingSubcircuitName == def.name;
      return ActionChip(
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
        avatar: Icon(Icons.memory, size: 13, color: active ? Colors.black : colors.accentAmber),
        backgroundColor: active ? colors.accentAmber : colors.canvasBackground,
        label: Text(
          def.name,
          style: TextStyle(fontSize: 11, color: active ? Colors.black : colors.componentStroke),
        ),
        onPressed: () => widget.onSelectSubcircuit?.call(def.name),
      );
    }

    Widget partChip(PartPreset part) {
      final active = widget.isPlacing && widget.placingPartName == part.name;
      return Tooltip(
        message: '${part.family}: ${part.summary}',
        child: ActionChip(
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          labelPadding: const EdgeInsets.symmetric(horizontal: 4),
          backgroundColor: active ? colors.accentAmber : colors.canvasBackground,
          label: Text(
            part.name,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: active ? Colors.black : colors.componentStroke,
            ),
          ),
          onPressed: () => widget.onSelectPartPreset?.call(part),
        ),
      );
    }

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
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                if (matchedSubs.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                    child: Text(
                      '${l10n.subcircuitsTitle} (${matchedSubs.length})',
                      style: TextStyle(
                        color: colors.accentAmber,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: matchedSubs.map(subcircuitChip).toList(),
                  ),
                ],
                for (final (catTitle, items) in groups)
                  if (items.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                      child: Text(
                        catTitle,
                        style: TextStyle(
                          color: colors.accentAmber,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: items.map(paletteChip).toList(),
                    ),
                  ],
                if (matchedParts.isNotEmpty && widget.onSelectPartPreset != null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                    child: Text(
                      l10n.partsLibraryTitle,
                      style: TextStyle(
                        color: colors.accentAmber,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: matchedParts.map(partChip).toList(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
