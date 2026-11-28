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
              Text('Ctrl+1 / Ctrl+2 / Ctrl+3 — Toggle Components / Properties / Instruments'),
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
  showDialog<void>(
    context: context,
    builder: (ctx) => _WorkbenchIoDialog(
      doc: doc,
      cirExportText: cirExportText,
      ch1Times: ch1Times,
      ch1: ch1,
      ch2: ch2,
      recentCircuits: recentCircuits,
      l10n: l10n,
      importMode: importMode,
      messenger: messenger,
      onImported: onImported,
    ),
  );
}

class _WorkbenchIoDialog extends StatefulWidget {
  final CircuitDoc doc;
  final String cirExportText;
  final List<double> ch1Times;
  final Float64List ch1;
  final Float64List ch2;
  final List<(String title, String json)> recentCircuits;
  final AppLocalizations l10n;
  final bool importMode;
  final ScaffoldMessengerState messenger;
  final void Function(String title) onImported;

  const _WorkbenchIoDialog({
    required this.doc,
    required this.cirExportText,
    required this.ch1Times,
    required this.ch1,
    required this.ch2,
    required this.recentCircuits,
    required this.l10n,
    required this.importMode,
    required this.messenger,
    required this.onImported,
  });

  @override
  State<_WorkbenchIoDialog> createState() => _WorkbenchIoDialogState();
}

class _WorkbenchIoDialogState extends State<_WorkbenchIoDialog> {
  late final TextEditingController _jsonCtrl =
      TextEditingController(text: widget.importMode ? '' : widget.doc.toJsonString());
  late final TextEditingController _cirCtrl =
      TextEditingController(text: widget.importMode ? '' : widget.cirExportText);
  late final TextEditingController _csvCtrl =
      TextEditingController(text: widget.doc.toBomCsv(widget.ch1Times, widget.ch1, widget.ch2));
  final TextEditingController _jsonPathCtrl = TextEditingController(text: 'circuit.json');
  final TextEditingController _cirPathCtrl = TextEditingController(text: 'circuit.cir');
  final TextEditingController _csvPathCtrl = TextEditingController(text: 'circuit_export.csv');

  @override
  void dispose() {
    _jsonCtrl.dispose();
    _cirCtrl.dispose();
    _csvCtrl.dispose();
    _jsonPathCtrl.dispose();
    _cirPathCtrl.dispose();
    _csvPathCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final doc = widget.doc;
    final importMode = widget.importMode;
    final messenger = widget.messenger;
    return DefaultTabController(
      length: importMode ? 2 : 3,
      child: AlertDialog(
        title: Text(importMode ? l10n.importAction : l10n.exportAction),
        content: SizedBox(
          width: 540,
          height: 410,
          child: Column(
            children: [
              if (importMode && widget.recentCircuits.isNotEmpty)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      const Text('Recent: ', style: TextStyle(fontSize: 11)),
                      for (final (title, rawJson) in widget.recentCircuits)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: ActionChip(
                            visualDensity: VisualDensity.compact,
                            label: Text(title, style: const TextStyle(fontSize: 11)),
                            onPressed: () {
                              try {
                                doc.loadJsonString(rawJson);
                                widget.onImported(title);
                                Navigator.pop(context);
                              } catch (e) {
                                messenger.showSnackBar(
                                  SnackBar(content: Text('Failed to load recent circuit: $e')),
                                );
                              }
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
                      ctrl: _jsonCtrl,
                      pathCtrl: _jsonPathCtrl,
                      l10n: l10n,
                      isJson: true,
                      importMode: importMode,
                      ctx: context,
                      messenger: messenger,
                      onImported: widget.onImported,
                    ),
                    _ioTab(
                      doc: doc,
                      ctrl: _cirCtrl,
                      pathCtrl: _cirPathCtrl,
                      l10n: l10n,
                      isJson: false,
                      importMode: importMode,
                      ctx: context,
                      messenger: messenger,
                      onImported: widget.onImported,
                    ),
                    if (!importMode)
                      _ioTab(
                        doc: doc,
                        ctrl: _csvCtrl,
                        pathCtrl: _csvPathCtrl,
                        l10n: l10n,
                        isJson: null,
                        importMode: false,
                        ctx: context,
                        messenger: messenger,
                        onImported: widget.onImported,
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
                      context: context,
                      icon: Icons.image,
                      label: 'Export SVG',
                      suggestedName: 'circuit.svg',
                      messenger: messenger,
                      onWriteAsync: (file) => file.writeAsString(exportSchematicSvg(doc)),
                    ),
                    _exportAssetButton(
                      context: context,
                      icon: Icons.photo,
                      label: 'Export PNG',
                      suggestedName: 'circuit.png',
                      messenger: messenger,
                      onPrepareBytes: () => renderSchematicPng(doc),
                    ),
                    _exportAssetButton(
                      context: context,
                      icon: Icons.audiotrack,
                      label: 'Export WAV',
                      suggestedName: 'ch1.wav',
                      messenger: messenger,
                      enabled: widget.ch1.isNotEmpty,
                      onWriteAsync: (file) =>
                          file.writeAsBytes(encodeWav16Pcm(widget.ch1, times: widget.ch1Times)),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.closeButton)),
        ],
      ),
    );
  }
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
              var pickedPath = '';
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (_) => _ValidatedTextDialog(
                  title: label,
                  initialText: '${Directory.systemTemp.path}/$suggestedName',
                  hintText: '',
                  confirmLabel: 'Save',
                  cancelLabel: 'Cancel',
                  outlined: true,
                  onSubmit: (text) {
                    pickedPath = text.trim();
                    return null;
                  },
                ),
              );
              path = confirmed == true ? pickedPath : null;
            }
            if (path == null || path.isEmpty) {
              messenger.showSnackBar(
                const SnackBar(content: Text('Export cancelled')),
              );
              return;
            }
            final tmp = File('$path.tmp');
            try {
              final file = File(path);
              if (bytes != null) {
                await tmp.writeAsBytes(bytes);
              } else {
                await onWriteAsync!(tmp);
              }
              await tmp.rename(file.path);
              messenger.showSnackBar(SnackBar(content: Text('Saved $path')));
            } catch (e) {
              try {
                if (await tmp.exists()) await tmp.delete();
              } catch (_) {}
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
              final picked = (await pickNativeFileResult(
                save: !importMode,
                suggestedName: pathCtrl.text.trim(),
              ))
                  .path;
              if (picked != null && ctx.mounted) pathCtrl.text = picked;
            },
          ),
          const SizedBox(width: 4),
          if (!importMode)
            TextButton(
              onPressed: () async {
                final savePath = pathCtrl.text.trim();
                if (savePath.isEmpty) return;
                final tmp = File('$savePath.tmp');
                try {
                  await tmp.writeAsString(ctrl.text);
                  await tmp.rename(savePath);
                  messenger.showSnackBar(SnackBar(content: Text('Saved $savePath')));
                } catch (e) {
                  try {
                    if (await tmp.exists()) await tmp.delete();
                  } catch (_) {}
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
  showDialog<void>(
    context: context,
    builder: (_) => _ValidatedTextDialog(
      title: l10n.addNoteAction,
      initialText: '',
      hintText: 'e.g. Vout Stage 1',
      outlined: true,
      l10n: l10n,
      onSubmit: (text) {
        doc.addNote(gx ?? 8, gy ?? (3 + doc.notes.length * 2), text);
        onChanged();
        return null;
      },
    ),
  );
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
  showDialog<void>(
    context: context,
    builder: (ctx) => _ValidatedTextDialog(
      title: l10n.editNoteAction,
      initialText: note.text,
      hintText: '',
      outlined: true,
      l10n: l10n,
      leadingAction: TextButton(
        onPressed: () {
          doc.deleteNote(noteId);
          onChanged();
          Navigator.pop(ctx);
        },
        child: Text(l10n.deleteAction),
      ),
      onSubmit: (text) {
        doc.updateNote(noteId, text);
        onChanged();
        return null;
      },
    ),
  );
}

class _ValidatedTextDialog extends StatefulWidget {
  final String title;
  final String initialText;
  final String hintText;
  final AppLocalizations? l10n;
  final String? confirmLabel;
  final String? cancelLabel;
  final bool monospace;
  final bool outlined;
  final Widget? leadingAction;
  final String? Function(String text) onSubmit;

  const _ValidatedTextDialog({
    required this.title,
    required this.initialText,
    required this.hintText,
    this.l10n,
    this.confirmLabel,
    this.cancelLabel,
    this.monospace = false,
    this.outlined = false,
    this.leadingAction,
    required this.onSubmit,
  });

  @override
  State<_ValidatedTextDialog> createState() => _ValidatedTextDialogState();
}

class _ValidatedTextDialogState extends State<_ValidatedTextDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initialText);
  String? _errorText;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final err = widget.onSubmit(_ctrl.text);
    if (err == null) {
      Navigator.pop(context, true);
    } else {
      setState(() => _errorText = err);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        style: widget.monospace ? const TextStyle(fontFamily: 'monospace') : null,
        decoration: InputDecoration(
          hintText: widget.hintText.isEmpty ? null : widget.hintText,
          errorText: _errorText,
          border: widget.outlined ? const OutlineInputBorder() : null,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        if (widget.leadingAction != null) widget.leadingAction!,
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(widget.cancelLabel ?? widget.l10n!.closeButton),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel ?? widget.l10n!.loadButton),
        ),
      ],
    );
  }
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
) {
  final mustBePositive = spec.logScale ||
      spec.min > 0 ||
      spec.key == ParamKey.ohms ||
      spec.key == ParamKey.farads ||
      spec.key == ParamKey.henrys ||
      spec.key == ParamKey.maxCurrent ||
      spec.key == ParamKey.zenerVolts ||
      spec.key == ParamKey.beta ||
      (spec.key == ParamKey.ratio && spec.min > 0) ||
      spec.key == ParamKey.vHigh;
  return showDialog<void>(
    context: context,
    builder: (_) => _ValidatedTextDialog(
      title: label,
      initialText: formatEngValue(current),
      hintText: 'e.g. 4.7k, 10p, 1M, 100',
      l10n: l10n,
      onSubmit: (text) {
        final parsed = CircuitDoc.parseSpiceValue(text);
        if (parsed == null || !parsed.isFinite || (mustBePositive && parsed <= 0)) {
          return mustBePositive ? 'Enter a value > 0' : 'Enter a valid number';
        }
        final bounded = spec.key == ParamKey.wiper ||
            spec.key == ParamKey.duty ||
            (spec.key == ParamKey.ratio && spec.max <= 1.0);
        final nextVal = bounded ? parsed.clamp(spec.min, spec.max).toDouble() : parsed;
        doc.recordUndoSnapshot();
        onApply(spec.paramIndex, nextVal);
        return null;
      },
    ),
  );
}

Future<void> showEditNetPortLabelDialog(
  BuildContext context,
  PlacedComponent c,
  AppLocalizations l10n,
  CircuitDoc doc,
  VoidCallback onSync,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ValidatedTextDialog(
      title: 'Net Label',
      initialText: c.hexPattern ?? 'NET',
      hintText: 'e.g. VCC, OUT, CLK',
      l10n: l10n,
      onSubmit: (text) {
        if (!doc.updateNetPortLabel(c.id, text)) {
          return 'Enter a valid net label';
        }
        onSync();
        return null;
      },
    ),
  );
}

Future<void> showEditWordGenHexDialog(
  BuildContext context,
  PlacedComponent c,
  AppLocalizations l10n,
  CircuitDoc doc,
  void Function(int compId, int bits) onPatternChanged,
  VoidCallback onSync,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ValidatedTextDialog(
      title: l10n.wordGenPatternLabel,
      initialText: c.hexPattern ?? 'FEDCBA9876543210',
      hintText: 'FEDCBA9876543210',
      monospace: true,
      l10n: l10n,
      onSubmit: (text) {
        if (!doc.updateWordGenHex(c.id, text)) {
          return l10n.errInvalidImport;
        }
        final bits = CircuitDoc.parseHexPattern64(text);
        if (bits != null) onPatternChanged(c.id, bits);
        onSync();
        return null;
      },
    ),
  );
}

Future<void> showCreateSubcircuitDialog(
  BuildContext context,
  AppLocalizations l10n,
  CircuitDoc doc,
  Set<int> selection,
  void Function(int newCompId) onCreated,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ValidatedTextDialog(
      title: l10n.makeSubcircuitAction,
      initialText: 'IC${doc.subcircuits.length + 1}',
      hintText: 'e.g. HALF_ADDER, FILTER1',
      l10n: l10n,
      onSubmit: (text) {
        final def = doc.createSubcircuitFromSelection(selection, text);
        if (def == null) {
          return 'Select 2+ parts (max 8 external pins)';
        }
        onCreated(doc.components.last.id);
        return null;
      },
    ),
  );
}
