import 'package:flutter/material.dart';

import '../canvas/schematic_canvas.dart';
import '../l10n/app_localizations.dart';
import '../theme/circuit_theme.dart';

class WorkspaceTabItem {
  final String title;
  final bool isDirty;
  const WorkspaceTabItem({required this.title, required this.isDirty});
}

class WorkbenchTabStrip extends StatelessWidget {
  final List<WorkspaceTabItem> tabs;
  final int activeIndex;
  final ValueChanged<int> onSwitchTab;
  final ValueChanged<int> onCloseTab;
  final VoidCallback onAddTab;

  const WorkbenchTabStrip({
    super.key,
    required this.tabs,
    required this.activeIndex,
    required this.onSwitchTab,
    required this.onCloseTab,
    required this.onAddTab,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CircuitColors>()!;
    return Container(
      height: 28,
      color: colors.canvasBackground,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (var i = 0; i < tabs.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 4, top: 2, bottom: 2),
                    child: InkWell(
                      onTap: () => onSwitchTab(i),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: i == activeIndex ? colors.panelSurface : colors.canvasBackground,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: i == activeIndex ? colors.accentAmber : colors.panelBorder,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${tabs[i].title}${tabs[i].isDirty ? " *" : ""}',
                              style: TextStyle(
                                fontSize: 11,
                                color: i == activeIndex ? colors.accentAmber : colors.componentStroke,
                              ),
                            ),
                            if (tabs.length > 1) ...[
                              const SizedBox(width: 4),
                              GestureDetector(
                                onTap: () => onCloseTab(i),
                                child: Icon(Icons.close, size: 12, color: colors.componentStroke),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: 'New Tab',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  icon: Icon(Icons.add, size: 15, color: colors.accentAmber),
                  onPressed: onAddTab,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class WorkbenchToolBar extends StatelessWidget {
  final CanvasTool tool;
  final bool showLabels;
  final bool showNodeVoltages;
  final bool showFlow;
  final bool coarseGridSnap;
  final double canvasScale;
  final bool isPhone;
  final bool canUndo;
  final bool canRedo;
  final int selectionCount;
  final ValueChanged<CanvasTool> onSelectTool;
  final ValueChanged<bool> onToggleLabels;
  final ValueChanged<bool> onToggleNodeVoltages;
  final ValueChanged<bool> onToggleFlow;
  final ValueChanged<bool> onToggleCoarseSnap;
  final VoidCallback onFitView;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomReset;
  final VoidCallback onZoomIn;
  final VoidCallback onAddNote;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onImport;
  final VoidCallback onExport;
  final VoidCallback onShowHelp;
  final VoidCallback onDuplicate;
  final VoidCallback onAlignH;
  final VoidCallback onAlignV;
  final VoidCallback onMakeSubcircuit;
  final VoidCallback onRotate;
  final VoidCallback onFlipH;
  final VoidCallback onFlipV;

  const WorkbenchToolBar({
    super.key,
    required this.tool,
    required this.showLabels,
    required this.showNodeVoltages,
    required this.showFlow,
    required this.coarseGridSnap,
    required this.canvasScale,
    required this.isPhone,
    required this.canUndo,
    required this.canRedo,
    required this.selectionCount,
    required this.onSelectTool,
    required this.onToggleLabels,
    required this.onToggleNodeVoltages,
    required this.onToggleFlow,
    required this.onToggleCoarseSnap,
    required this.onFitView,
    required this.onZoomOut,
    required this.onZoomReset,
    required this.onZoomIn,
    required this.onAddNote,
    required this.onUndo,
    required this.onRedo,
    required this.onImport,
    required this.onExport,
    required this.onShowHelp,
    required this.onDuplicate,
    required this.onAlignH,
    required this.onAlignV,
    required this.onMakeSubcircuit,
    required this.onRotate,
    required this.onFlipH,
    required this.onFlipV,
  });

  Widget _toolChip(CanvasTool target, IconData icon, String label, CircuitColors colors) {
    final selected = tool == target;
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      child: ChoiceChip(
        selected: selected,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
        avatar: Icon(icon, size: 15, color: selected ? Colors.black : colors.accentAmber),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selectedColor: colors.accentAmber,
        labelStyle: TextStyle(color: selected ? Colors.black : colors.componentStroke),
        onSelected: (_) => onSelectTool(target),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).extension<CircuitColors>()!;
    return Container(
      color: colors.panelSurface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _toolChip(CanvasTool.select, Icons.near_me, l10n.selectTool, colors),
            const SizedBox(width: 4),
            _toolChip(CanvasTool.boxSelect, Icons.select_all, l10n.boxSelectTool, colors),
            const SizedBox(width: 4),
            _toolChip(CanvasTool.wire, Icons.timeline, l10n.wireTool, colors),
            const SizedBox(width: 4),
            _toolChip(CanvasTool.probeCh1, Icons.looks_one, l10n.probeCh1, colors),
            const SizedBox(width: 4),
            _toolChip(CanvasTool.probeCh2, Icons.looks_two, l10n.probeCh2, colors),
            const SizedBox(width: 4),
            _toolChip(CanvasTool.probeCh3, Icons.looks_3, l10n.probeCh3, colors),
            const SizedBox(width: 4),
            _toolChip(CanvasTool.probeCh4, Icons.looks_4, l10n.probeCh4, colors),
            const SizedBox(width: 4),
            _toolChip(CanvasTool.delete, Icons.delete_outline, l10n.deleteTool, colors),
            const SizedBox(width: 6),
            FilterChip(
              selected: showLabels,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              labelPadding: const EdgeInsets.symmetric(horizontal: 4),
              label: Text(l10n.showValuesLabel, style: const TextStyle(fontSize: 11)),
              selectedColor: colors.accentAmber.withAlpha(70),
              onSelected: onToggleLabels,
            ),
            const SizedBox(width: 4),
            FilterChip(
              selected: showNodeVoltages,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              labelPadding: const EdgeInsets.symmetric(horizontal: 4),
              label: Text(l10n.showVoltagesLabel, style: const TextStyle(fontSize: 11)),
              selectedColor: colors.accentAmber.withAlpha(70),
              onSelected: onToggleNodeVoltages,
            ),
            const SizedBox(width: 4),
            FilterChip(
              selected: showFlow,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              labelPadding: const EdgeInsets.symmetric(horizontal: 4),
              label: Text(l10n.showFlowLabel, style: const TextStyle(fontSize: 11)),
              selectedColor: colors.accentAmber.withAlpha(70),
              onSelected: onToggleFlow,
            ),
            const SizedBox(width: 4),
            ActionChip(
              visualDensity: VisualDensity.compact,
              labelPadding: const EdgeInsets.symmetric(horizontal: 4),
              avatar: Icon(Icons.fit_screen, size: 14, color: colors.accentAmber),
              label: Text(l10n.fitViewAction, style: const TextStyle(fontSize: 11)),
              onPressed: onFitView,
            ),
            const SizedBox(width: 4),
            ActionChip(
              visualDensity: VisualDensity.compact,
              labelPadding: const EdgeInsets.symmetric(horizontal: 3),
              label: const Text('-', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              onPressed: onZoomOut,
            ),
            const SizedBox(width: 2),
            ActionChip(
              visualDensity: VisualDensity.compact,
              labelPadding: const EdgeInsets.symmetric(horizontal: 4),
              label: Text('${(canvasScale * 100).round()}%', style: const TextStyle(fontSize: 11)),
              onPressed: onZoomReset,
            ),
            const SizedBox(width: 2),
            ActionChip(
              visualDensity: VisualDensity.compact,
              labelPadding: const EdgeInsets.symmetric(horizontal: 3),
              label: const Text('+', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              onPressed: onZoomIn,
            ),
            const SizedBox(width: 4),
            FilterChip(
              selected: !coarseGridSnap,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              labelPadding: const EdgeInsets.symmetric(horizontal: 4),
              label: Text(coarseGridSnap ? 'Snap 2x' : 'Snap 1x', style: const TextStyle(fontSize: 11)),
              selectedColor: colors.accentAmber.withAlpha(70),
              onSelected: (v) => onToggleCoarseSnap(!v),
            ),
            const SizedBox(width: 4),
            ActionChip(
              visualDensity: VisualDensity.compact,
              labelPadding: const EdgeInsets.symmetric(horizontal: 4),
              avatar: Icon(Icons.sticky_note_2_outlined, size: 14, color: colors.accentAmber),
              label: Text(l10n.noteLabel, style: const TextStyle(fontSize: 11)),
              onPressed: onAddNote,
            ),
            if (isPhone) ...[
              const SizedBox(width: 4),
              ActionChip(
                avatar: const Icon(Icons.undo, size: 15),
                label: Text(l10n.undoAction, style: const TextStyle(fontSize: 12)),
                onPressed: canUndo ? onUndo : null,
              ),
              const SizedBox(width: 4),
              ActionChip(
                avatar: const Icon(Icons.redo, size: 15),
                label: Text(l10n.redoAction, style: const TextStyle(fontSize: 12)),
                onPressed: canRedo ? onRedo : null,
              ),
              const SizedBox(width: 4),
              ActionChip(
                avatar: const Icon(Icons.folder_open, size: 15),
                label: Text(l10n.importAction, style: const TextStyle(fontSize: 12)),
                onPressed: onImport,
              ),
              const SizedBox(width: 4),
              ActionChip(
                avatar: const Icon(Icons.save_alt, size: 15),
                label: Text(l10n.exportAction, style: const TextStyle(fontSize: 12)),
                onPressed: onExport,
              ),
              const SizedBox(width: 4),
              ActionChip(
                avatar: const Icon(Icons.help_outline, size: 15),
                label: const Text('?', style: TextStyle(fontSize: 12)),
                onPressed: onShowHelp,
              ),
            ],
            if (selectionCount > 0) ...[
              const SizedBox(width: 6),
              ActionChip(
                avatar: Icon(Icons.copy_all, size: 16, color: colors.accentAmber),
                label: Text(l10n.duplicateAction),
                onPressed: onDuplicate,
              ),
              if (selectionCount >= 2) ...[
                const SizedBox(width: 4),
                ActionChip(
                  avatar: Icon(Icons.align_vertical_center, size: 16, color: colors.accentAmber),
                  label: Text(l10n.alignHAction, style: const TextStyle(fontSize: 11)),
                  onPressed: onAlignH,
                ),
                const SizedBox(width: 4),
                ActionChip(
                  avatar: Icon(Icons.align_horizontal_center, size: 16, color: colors.accentAmber),
                  label: Text(l10n.alignVAction, style: const TextStyle(fontSize: 11)),
                  onPressed: onAlignV,
                ),
                const SizedBox(width: 4),
                ActionChip(
                  avatar: Icon(Icons.memory, size: 16, color: colors.accentAmber),
                  label: Text(l10n.makeSubcircuitAction),
                  onPressed: onMakeSubcircuit,
                ),
              ],
              const SizedBox(width: 4),
              ActionChip(
                avatar: Icon(Icons.rotate_right, size: 16, color: colors.accentAmber),
                label: Text(l10n.rotateAction),
                onPressed: onRotate,
              ),
              const SizedBox(width: 4),
              ActionChip(
                avatar: Icon(Icons.flip, size: 16, color: colors.accentAmber),
                label: Text(l10n.flipHAction, style: const TextStyle(fontSize: 11)),
                onPressed: onFlipH,
              ),
              const SizedBox(width: 4),
              ActionChip(
                avatar: Icon(Icons.flip_camera_android, size: 15, color: colors.accentAmber),
                label: Text(l10n.flipVAction, style: const TextStyle(fontSize: 11)),
                onPressed: onFlipV,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
