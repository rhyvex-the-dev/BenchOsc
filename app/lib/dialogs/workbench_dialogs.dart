import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../state/circuit_doc.dart';
import '../state/circuit_exports.dart';

void showWorkbenchHelpDialog(BuildContext context, AppLocalizations l10n) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Keyboard Shortcuts & Tips'),
      content: const SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Space — Run / Pause simulation'),
              Text('R — Rotate selected component 90°'),
              Text('F — Flip selected component horizontally'),
              Text('Del / Backspace — Delete selected components'),
              Text('Ctrl+Z / Ctrl+Y — Undo / Redo'),
              Text('Ctrl+C / Ctrl+V / Ctrl+D — Copy / Paste / Duplicate'),
              Text('Esc — Cancel active tool or selection'),
              SizedBox(height: 8),
              Text('Wire Tool: click pin or click wire segment for a T-junction.'),
              Text('Palette: drag components directly onto the canvas or tap to place.'),
              Text('Scopes: tap/drag C1 & C2 cursors; double-tap to clear.'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.closeButton)),
      ],
    ),
  );
}

void showWorkbenchIoDialog({
  required BuildContext context,
  required CircuitDoc doc,
  required String cirExportText,
  required List<double> ch1Times,
  required Float64List ch1,
  required Float64List ch2,
  required List<(String title, String json)> recentCircuits,
  required AppLocalizations l10n,
  required bool importMode,
  required void Function(String title) onImported,
}) {
  final messenger = ScaffoldMessenger.of(context);
  final jsonCtrl = TextEditingController(text: importMode ? '' : doc.toJsonString());
  final cirCtrl = TextEditingController(text: importMode ? '' : cirExportText);
  final csvCtrl = TextEditingController(text: doc.toBomCsv(ch1Times, ch1, ch2));
  final jsonPathCtrl = TextEditingController(text: 'circuit.json');
  final cirPathCtrl = TextEditingController(text: 'circuit.cir');
  final csvPathCtrl = TextEditingController(text: 'circuit_export.csv');

  showDialog<void>(
    context: context,
    builder: (ctx) => DefaultTabController(
      length: importMode ? 2 : 3,
      child: AlertDialog(
        title: Text(importMode ? l10n.importAction : l10n.exportAction),
        content: SizedBox(
          width: 540,
          height: 410,
          child: Column(
            children: [
              if (importMode && recentCircuits.isNotEmpty)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      const Text('Recent: ', style: TextStyle(fontSize: 11)),
                      for (final (title, rawJson) in recentCircuits)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: ActionChip(
                            visualDensity: VisualDensity.compact,
                            label: Text(title, style: const TextStyle(fontSize: 11)),
                            onPressed: () {
                              doc.loadJsonString(rawJson);
                              onImported(title);
                              Navigator.pop(ctx);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              TabBar(tabs: [
                Tab(text: l10n.jsonTab),
                Tab(text: l10n.spiceCirTab),
                if (!importMode) Tab(text: l10n.bomCsvTab),
              ]),
              const SizedBox(height: 8),
              Expanded(
                child: TabBarView(
                  children: [
                    _ioTab(
                      doc: doc,
                      ctrl: jsonCtrl,
                      pathCtrl: jsonPathCtrl,
                      l10n: l10n,
                      isJson: true,
                      importMode: importMode,
                      ctx: ctx,
                      messenger: messenger,
                      onImported: onImported,
                    ),
                    _ioTab(
                      doc: doc,
                      ctrl: cirCtrl,
                      pathCtrl: cirPathCtrl,
                      l10n: l10n,
                      isJson: false,
                      importMode: importMode,
                      ctx: ctx,
                      messenger: messenger,
                      onImported: onImported,
                    ),
                    if (!importMode)
                      _ioTab(
                        doc: doc,
                        ctrl: csvCtrl,
                        pathCtrl: csvPathCtrl,
                        l10n: l10n,
                        isJson: null,
                        importMode: false,
                        ctx: ctx,
                        messenger: messenger,
                        onImported: onImported,
                      ),
                  ],
                ),
              ),
              if (!importMode) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _exportAssetButton(
                      context: ctx,
                      icon: Icons.image,
                      label: 'Export SVG',
                      suggestedName: 'circuit.svg',
                      messenger: messenger,
                      onWriteAsync: (file) => file.writeAsString(exportSchematicSvg(doc)),
                    ),
                    _exportAssetButton(
                      context: ctx,
                      icon: Icons.photo,
                      label: 'Export PNG',
                      suggestedName: 'circuit.png',
                      messenger: messenger,
                      onPrepareBytes: () => renderSchematicPng(doc),
                    ),
                    _exportAssetButton(
                      context: ctx,
                      icon: Icons.audiotrack,
                      label: 'Export WAV',
                      suggestedName: 'ch1.wav',
                      messenger: messenger,
                      enabled: ch1.isNotEmpty,
                      onWriteAsync: (file) => file.writeAsBytes(encodeWav16Pcm(ch1, times: ch1Times)),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.closeButton)),
        ],
      ),
    ),
  ).whenComplete(() {
    jsonCtrl.dispose();
    cirCtrl.dispose();
    csvCtrl.dispose();
    jsonPathCtrl.dispose();
    cirPathCtrl.dispose();
    csvPathCtrl.dispose();
  });
}

Widget _exportAssetButton({
  required BuildContext context,
  required IconData icon,
  required String label,
  required String suggestedName,
  required ScaffoldMessengerState messenger,
  bool enabled = true,
  Future<void> Function(File file)? onWriteAsync,
  Future<Uint8List?> Function()? onPrepareBytes,
}) {
  return OutlinedButton.icon(
    icon: Icon(icon, size: 15),
    label: Text(label, style: const TextStyle(fontSize: 11)),
    onPressed: !enabled
        ? null
        : () async {
            final bytes = onPrepareBytes != null ? await onPrepareBytes() : null;
            if (onPrepareBytes != null && bytes == null) return;
            final picked = await pickNativeFileResult(save: true, suggestedName: suggestedName);
            var path = picked.path;
            if (!picked.available && path == null && context.mounted) {
              final ctrl = TextEditingController(
                text: '${Directory.systemTemp.path}/$suggestedName',
              );
              path = await showDialog<String>(
                context: context,
                builder: (dCtx) => AlertDialog(
                  title: Text(label),
                  content: TextField(
                    controller: ctrl,
                    decoration: const InputDecoration(border: OutlineInputBorder()),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dCtx),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(dCtx, ctrl.text.trim()),
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ).whenComplete(ctrl.dispose);
            }
            if (path == null || path.isEmpty) {
              messenger.showSnackBar(
                const SnackBar(content: Text('Export cancelled')),
              );
              return;
            }
            try {
              final file = File(path);
              if (bytes != null) {
                await file.writeAsBytes(bytes);
              } else {
                await onWriteAsync!(file);
              }
              messenger.showSnackBar(SnackBar(content: Text('Saved $path')));
            } catch (e) {
              messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
            }
          },
  );
}

Widget _ioTab({
  required CircuitDoc doc,
  required TextEditingController ctrl,
  required TextEditingController pathCtrl,
  required AppLocalizations l10n,
  required bool? isJson,
  required bool importMode,
  required BuildContext ctx,
  required ScaffoldMessengerState messenger,
  required void Function(String title) onImported,
}) {
  void loadText() {
    try {
      if (isJson!) {
        doc.loadJsonString(ctrl.text);
      } else {
        doc.loadSpiceCir(ctrl.text);
      }
      onImported(pathCtrl.text.trim().isEmpty ? 'Imported' : pathCtrl.text.trim());
      Navigator.pop(ctx);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errInvalidImport)));
    }
  }

  return Column(
    children: [
      Expanded(
        child: TextField(
          controller: ctrl,
          readOnly: isJson == null,
          maxLines: null,
          expands: true,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: importMode ? l10n.pasteOrOpenHint : null,
          ),
        ),
      ),
      const SizedBox(height: 6),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: pathCtrl,
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                hintText: l10n.filePathHint,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Browse OS file picker',
            icon: const Icon(Icons.drive_folder_upload, size: 18),
            onPressed: () async {
              final picked = await pickNativeFile(
                save: !importMode,
                suggestedName: pathCtrl.text.trim(),
              );
              if (picked != null && ctx.mounted) pathCtrl.text = picked;
            },
          ),
          const SizedBox(width: 4),
          if (!importMode)
            TextButton(
              onPressed: () async {
                final savePath = pathCtrl.text.trim();
                if (savePath.isEmpty) return;
                try {
                  await File(savePath).writeAsString(ctrl.text);
                  messenger.showSnackBar(SnackBar(content: Text('Saved $savePath')));
                } catch (e) {
                  messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
                }
              },
              child: Text(l10n.saveFileButton),
            ),
          if (isJson != null)
            TextButton(
              onPressed: () async {
                try {
                  final content = await File(pathCtrl.text.trim()).readAsString();
                  if (!ctx.mounted) return;
                  ctrl.text = content;
                  loadText();
                } catch (_) {
                  messenger.showSnackBar(SnackBar(content: Text(l10n.errInvalidImport)));
                }
              },
              child: Text(l10n.loadFileButton),
            ),
        ],
      ),
      const SizedBox(height: 4),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (!importMode)
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: ctrl.text)),
              child: Text(l10n.copyButton),
            ),
          if (isJson != null) ...[
            const SizedBox(width: 8),
            FilledButton(
              onPressed: loadText,
              child: Text(l10n.loadButton),
            ),
          ],
        ],
      ),
    ],
  );
}

void showAddNoteDialog(
  BuildContext context,
  AppLocalizations l10n,
  CircuitDoc doc,
  VoidCallback onChanged, {
  int? gx,
  int? gy,
}) {
  final ctrl = TextEditingController();
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.addNoteAction),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'e.g. Vout Stage 1', border: OutlineInputBorder()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.closeButton)),
        FilledButton(
          onPressed: () {
            doc.addNote(gx ?? 8, gy ?? (3 + doc.notes.length * 2), ctrl.text);
            onChanged();
            Navigator.pop(ctx);
          },
          child: Text(l10n.loadButton),
        ),
      ],
    ),
  ).whenComplete(ctrl.dispose);
}

void showEditNoteDialog(
  BuildContext context,
  int noteId,
  AppLocalizations l10n,
  CircuitDoc doc,
  VoidCallback onChanged,
) {
  final note = doc.notes.where((n) => n.id == noteId).firstOrNull;
  if (note == null) return;
  final ctrl = TextEditingController(text: note.text);
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.editNoteAction),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
      actions: [
        TextButton(
          onPressed: () {
            doc.deleteNote(noteId);
            onChanged();
            Navigator.pop(ctx);
          },
          child: Text(l10n.deleteAction),
        ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.closeButton)),
        FilledButton(
          onPressed: () {
            doc.updateNote(noteId, ctrl.text);
            onChanged();
            Navigator.pop(ctx);
          },
          child: Text(l10n.loadButton),
        ),
      ],
    ),
  ).whenComplete(ctrl.dispose);
}

Future<void> showEditParamNumericDialog(
  BuildContext context,
  PlacedComponent c,
  ParamSpec spec,
  double current,
  String label,
  AppLocalizations l10n,
  CircuitDoc doc,
  void Function(int paramIndex, double val) onApply,
) async {
  final ctrl = TextEditingController(text: formatEngValue(current));
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      void submit() {
        final parsed = CircuitDoc.parseSpiceValue(ctrl.text);
        final mustBePositive = spec.logScale ||
            spec.key == ParamKey.ohms ||
            spec.key == ParamKey.farads ||
            spec.key == ParamKey.henrys ||
            spec.key == ParamKey.maxCurrent ||
            spec.key == ParamKey.zenerVolts ||
            spec.key == ParamKey.beta ||
            (spec.key == ParamKey.ratio && spec.min > 0) ||
            spec.key == ParamKey.vHigh;
        if (parsed != null && parsed.isFinite && (!mustBePositive || parsed > 0)) {
          doc.recordUndoSnapshot();
          onApply(spec.paramIndex, parsed);
        }
        Navigator.pop(ctx);
      }

      return AlertDialog(
        title: Text(label),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. 4.7k, 10p, 1M, 100'),
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.closeButton)),
          FilledButton(onPressed: submit, child: Text(l10n.loadButton)),
        ],
      );
    },
  );
  ctrl.dispose();
}

Future<void> showEditNetPortLabelDialog(
  BuildContext context,
  PlacedComponent c,
  AppLocalizations l10n,
  CircuitDoc doc,
  VoidCallback onSync,
) async {
  final ctrl = TextEditingController(text: c.hexPattern ?? 'NET');
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      void submit() {
        if (doc.updateNetPortLabel(c.id, ctrl.text)) {
          onSync();
          Navigator.pop(ctx);
        }
      }

      return AlertDialog(
        title: const Text('Net Label'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. VCC, OUT, CLK'),
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.closeButton)),
          FilledButton(onPressed: submit, child: Text(l10n.loadButton)),
        ],
      );
    },
  );
  ctrl.dispose();
}

Future<void> showEditWordGenHexDialog(
  BuildContext context,
  PlacedComponent c,
  AppLocalizations l10n,
  CircuitDoc doc,
  void Function(int compId, int bits) onPatternChanged,
  VoidCallback onSync,
) async {
  final ctrl = TextEditingController(text: c.hexPattern ?? 'FEDCBA9876543210');
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      void submit() {
        if (doc.updateWordGenHex(c.id, ctrl.text)) {
          final bits = CircuitDoc.parseHexPattern64(ctrl.text);
          if (bits != null) onPatternChanged(c.id, bits);
          onSync();
          Navigator.pop(ctx);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.errInvalidImport)),
          );
        }
      }

      return AlertDialog(
        title: Text(l10n.wordGenPatternLabel),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: const InputDecoration(hintText: 'FEDCBA9876543210'),
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.closeButton)),
          FilledButton(onPressed: submit, child: Text(l10n.loadButton)),
        ],
      );
    },
  );
  ctrl.dispose();
}

Future<void> showCreateSubcircuitDialog(
  BuildContext context,
  AppLocalizations l10n,
  CircuitDoc doc,
  Set<int> selection,
  void Function(int newCompId) onCreated,
) async {
  final ctrl = TextEditingController(text: 'IC${doc.subcircuits.length + 1}');
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      void submit() {
        final def = doc.createSubcircuitFromSelection(selection, ctrl.text);
        if (def != null) {
          onCreated(doc.components.last.id);
        }
        Navigator.pop(ctx);
      }

      return AlertDialog(
        title: Text(l10n.makeSubcircuitAction),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. HALF_ADDER, FILTER1'),
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.closeButton)),
          FilledButton(onPressed: submit, child: Text(l10n.loadButton)),
        ],
      );
    },
  );
  ctrl.dispose();
}
