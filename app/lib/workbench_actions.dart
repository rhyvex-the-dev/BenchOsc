part of 'main.dart';

extension _WorkbenchActions on _WorkbenchHomeState {
  Future<bool> _confirmDiscardIfDirty(
    AppLocalizations l10n, {
    bool allTabs = false,
  }) async {
    final dirtyTabs = allTabs
        ? _tabs.where((t) => t.isDirty).toList()
        : (_session.activeTab.isDirty ? [_session.activeTab] : <WorkspaceTab>[]);
    if (dirtyTabs.isEmpty) return true;
    final label = dirtyTabs.length == 1
        ? '"${dirtyTabs.first.title}"'
        : '${dirtyTabs.length} unsaved tabs';
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.unsavedChangesTitle),
        content: Text('${l10n.discardAction} $label?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.cancelAction)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.discardAction)),
        ],
      ),
    );
    return res ?? false;
  }

  void _releaseHeldPushbuttons() {
    if (_hotkeyHeldPushbuttons.isEmpty) return;
    for (final id in _hotkeyHeldPushbuttons.toList()) {
      if (_doc.components.any((c) => c.id == id && c.kind == CompKind.pushbutton)) {
        _setBinarySwitch(id, 0.0);
      }
    }
    _hotkeyHeldPushbuttons.clear();
    _hotkeyHeldByPhysical.clear();
  }

  void _resetTabInteraction() {
    _releaseHeldPushbuttons();
    _pendingWirePin = null;
    _pendingSplitJunctionId = null;
    _pendingSplitRevision = null;
  }

  void _switchTab(int idx) {
    if (idx < 0 || idx >= _tabs.length || idx == _activeTabIdx) return;
    _resetTabInteraction();
    _session.switchTab(idx);
    _syncCircuit(scheduleSave: false);
  }

  void _addNewTab() {
    _resetTabInteraction();
    _session.addNewTab();
    _syncCircuit(scheduleSave: false);
  }

  Future<void> _closeTab(int idx, AppLocalizations l10n) async {
    if (!mounted || idx < 0 || idx >= _tabs.length || _tabs.length <= 1) return;
    if (_tabs[idx].isDirty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.unsavedChangesTitle),
          content: Text('${l10n.discardAction} "${_tabs[idx].title}"?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.cancelAction)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.discardAction)),
          ],
        ),
      );
      if (ok != true) return;
      if (!mounted || idx < 0 || idx >= _tabs.length || _tabs.length <= 1) return;
    }
    _resetTabInteraction();
    _session.closeTab(idx);
    _syncCircuit(scheduleSave: false);
  }

  Future<void> _openIoDialog(AppLocalizations l10n, {bool importMode = false}) async {
    final cir = importMode ? '' : await _simCtrl.exportCir(_doc);
    if (!mounted) return;
    showWorkbenchIoDialog(
      context: context,
      doc: _doc,
      cirExportText: cir,
      ch1Times: _simCtrl.telemetry.value.ch1Times,
      ch1: _simCtrl.telemetry.value.ch1,
      ch2: _simCtrl.telemetry.value.ch2,
      recentCircuits: _recentCircuits,
      l10n: l10n,
      importMode: importMode,
      onImported: (title) {
        _recordRecent(title);
        _tabs[_activeTabIdx]
          ..title = title
          ..savedRevision = _doc.revision;
        _selectedCompId = null;
        _selectedCompIds.clear();
        _resetTabInteraction();
        _syncCircuit();
      },
    );
  }

  bool _isEditingText() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _cancelPendingWire() {
    if (_pendingSplitJunctionId != null) {
      if (_doc.revision == _pendingSplitRevision) {
        _doc.undo();
      }
      _pendingSplitJunctionId = null;
      _pendingSplitRevision = null;
      _pendingWirePin = null;
      _syncCircuit();
      return;
    }
    if (_pendingWirePin != null) {
      _refresh(() => _pendingWirePin = null);
    }
  }

  void _copySelection() => _session.copySelection();

  void _pasteClipboard() {
    if (_session.pasteClipboard().isEmpty) return;
    _syncCircuit();
  }

  bool _triggerHotkey(
    String rawChar, {
    required bool isDown,
    required bool shift,
    PhysicalKeyboardKey? physicalKey,
  }) {
    final ch = rawChar.toUpperCase();
    if (!RegExp(r'^[A-Z0-9]$').hasMatch(ch)) return false;
    var handled = false;
    for (final c in _doc.components.toList()) {
      if (c.hotkey != ch) continue;
      if (c.kind == CompKind.pushbutton) {
        if (isDown && !_hotkeyHeldPushbuttons.contains(c.id)) {
          _hotkeyHeldPushbuttons.add(c.id);
          if (physicalKey != null) {
            (_hotkeyHeldByPhysical[physicalKey] ??= {}).add(c.id);
          }
          _setBinarySwitch(c.id, 1.0);
          handled = true;
        } else if (!isDown && _hotkeyHeldPushbuttons.remove(c.id)) {
          _setBinarySwitch(c.id, 0.0);
          handled = true;
        }
      } else if (isDown) {
        if (c.kind == CompKind.switchSpst || c.kind == CompKind.switchSpdt) {
          _setBinarySwitch(c.id, c.params[0] >= 0.5 ? 0.0 : 1.0, recordUndo: true);
          handled = true;
        } else if (c.kind == CompKind.potentiometer && c.params.length > 1) {
          final nextW = (c.params[1] + (shift ? -0.1 : 0.1)).clamp(0.05, 0.95);
          _doc.recordUndoSnapshot();
          _applyParamChange(c, 1, nextW);
          handled = true;
        } else if (c.kind == CompKind.hexKeypad && c.params.isNotEmpty) {
          final nextHex = (c.params[0].round() + (shift ? 15 : 1)) & 0xF;
          _doc.recordUndoSnapshot();
          _applyParamChange(c, 0, nextHex.toDouble());
          handled = true;
        } else if (c.kind == CompKind.dipSwitch4 && c.params.isNotEmpty) {
          final nextMask = c.params[0].round() ^ 0x1;
          _doc.recordUndoSnapshot();
          _applyParamChange(c, 0, nextMask.toDouble());
          handled = true;
        }
      }
    }
    return handled;
  }

  KeyEventResult _handleGlobalKey(FocusNode node, KeyEvent event, AppLocalizations l10n) {
    final kb = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (event is KeyUpEvent && _hotkeyHeldPushbuttons.isNotEmpty) {
      final heldByPhys = _hotkeyHeldByPhysical.remove(event.physicalKey);
      if (heldByPhys != null && heldByPhys.isNotEmpty) {
        for (final id in heldByPhys) {
          if (_hotkeyHeldPushbuttons.remove(id)) {
            _setBinarySwitch(id, 0.0);
          }
        }
        return KeyEventResult.handled;
      }
      final label = key.keyLabel;
      if (label.length == 1 && _triggerHotkey(label, isDown: false, shift: kb.isShiftPressed)) {
        return KeyEventResult.handled;
      }
    }
    if (_isEditingText()) return KeyEventResult.ignored;
    final primaryMod = kb.isControlPressed || kb.isMetaPressed;

    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (!primaryMod) {
      final label = key.keyLabel;
      if (label.length == 1 &&
          label != 'R' &&
          label != 'F' &&
          _triggerHotkey(label, isDown: true, shift: kb.isShiftPressed, physicalKey: event.physicalKey)) {
        return KeyEventResult.handled;
      }
    }

    if (primaryMod) {
      if (key == LogicalKeyboardKey.keyZ) {
        if (kb.isShiftPressed) {
          if (_doc.canRedo) {
            _pendingWirePin = null;
            _pendingSplitJunctionId = null;
            _pendingSplitRevision = null;
            _doc.redo();
            _syncCircuit();
          }
        } else if (_doc.canUndo) {
          _pendingWirePin = null;
          _pendingSplitJunctionId = null;
          _pendingSplitRevision = null;
          _doc.undo();
          _syncCircuit();
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyY) {
        if (_doc.canRedo) {
          _pendingWirePin = null;
          _pendingSplitJunctionId = null;
          _pendingSplitRevision = null;
          _doc.redo();
          _syncCircuit();
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyC) {
        _copySelection();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyV) {
        _pasteClipboard();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyD) {
        _duplicateIds(_effectiveSelection);
        return KeyEventResult.handled;
      }
      if (!_isPhoneLayout) {
        if (key == LogicalKeyboardKey.digit1) {
          _refresh(() => _showDesktopPalette = !_showDesktopPalette);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.digit2) {
          _refresh(() => _showDesktopInspector = !_showDesktopInspector);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.digit3) {
          _refresh(() => _showDesktopInstruments = !_showDesktopInstruments);
          _updateFftSubscription();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.space) {
      _refresh(() => _running = !_running);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyR && _effectiveSelection.isNotEmpty) {
      _doc.rotateComponents(_effectiveSelection);
      _syncCircuit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF && _effectiveSelection.isNotEmpty) {
      _doc.flipComponents(_effectiveSelection);
      _syncCircuit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.slash && kb.isShiftPressed) {
      showWorkbenchHelpDialog(context, l10n);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) {
      _deleteSelected();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _cancelPendingWire();
      _refresh(() {
        _placingKind = null;
        _placingSubcircuitName = null;
        _placingPartPreset = null;
        _selectedCompId = null;
        _selectedCompIds.clear();
        if (_tool == CanvasTool.place) _tool = CanvasTool.select;
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _duplicateIds(Set<int> ids) {
    final newIds = _doc.duplicateComponents(ids);
    if (newIds.isEmpty) return;
    _selectedCompIds
      ..clear()
      ..addAll(newIds);
    _selectedCompId = newIds.last;
    _syncCircuit();
  }

  void _deleteSelected() {
    final sel = _effectiveSelection;
    if (sel.isEmpty) return;
    _doc.deleteComponents(sel);
    _selectedCompId = null;
    _selectedCompIds.clear();
    _syncCircuit();
  }

  Widget _presetMenu(AppLocalizations l10n, CircuitColors colors) {
    return PopupMenuButton<String>(
      tooltip: l10n.presetLabel,
      icon: Icon(Icons.auto_awesome_mosaic, color: colors.accentAmber, size: 20),
      onSelected: (key) async {
        if (key == 'restore_autosave') {
          try {
            final f = _session.autoSaveFile();
            if (f == null || !await f.exists()) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('No autosave file found.')),
                );
              }
              return;
            }
            final raw = await f.readAsString();
            if (!mounted) return;
            if (!await _confirmDiscardIfDirty(l10n, allTabs: true) || !mounted) return;
            _resetTabInteraction();
            _session.loadAutosaveJson(raw);
            _selectedCompId = null;
            _selectedCompIds.clear();
            _syncCircuit(scheduleSave: false);
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Failed to restore autosave: $e')),
              );
            }
          }
          return;
        }
        final preset = PresetKind.values.where((p) => p.name == key).firstOrNull;
        if (preset == null) return;
        if (!mounted) return;
        if (!await _confirmDiscardIfDirty(l10n) || !mounted) return;
        _resetTabInteraction();
        _doc.loadPreset(preset);
        if (_activeTabIdx >= 0 && _activeTabIdx < _tabs.length) {
          _tabs[_activeTabIdx]
            ..title = preset.name
            ..savedRevision = _doc.revision;
        }
        _selectedCompId = null;
        _selectedCompIds.clear();
        _syncCircuit(scheduleSave: false);
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'restore_autosave', child: Text(l10n.restoreAutoSaveAction)),
        const PopupMenuDivider(),
        PopupMenuItem(value: PresetKind.rcFilter.name, child: Text(l10n.presetRcFilter)),
        PopupMenuItem(value: PresetKind.rectifier.name, child: Text(l10n.presetRectifier)),
        PopupMenuItem(value: PresetKind.opAmp.name, child: Text(l10n.presetOpAmp)),
        PopupMenuItem(value: PresetKind.bjtSwitch.name, child: Text(l10n.presetBjtSwitch)),
        PopupMenuItem(value: PresetKind.digitalXor.name, child: Text(l10n.presetDigitalXor)),
        PopupMenuItem(value: PresetKind.dffDivider.name, child: Text(l10n.presetDffDivider)),
        PopupMenuItem(value: PresetKind.timer555Astable.name, child: Text(l10n.presetTimer555)),
        PopupMenuItem(value: PresetKind.wordGenCounter.name, child: Text(l10n.presetWordGen)),
        PopupMenuItem(value: PresetKind.optocouplerIso.name, child: Text(l10n.presetOptocoupler)),
        PopupMenuItem(value: PresetKind.schmittCounter.name, child: Text(l10n.presetSchmittCounter)),
      ],
    );
  }

  Future<void> _showCanvasContextMenu(
    int? compId,
    int? wireIdx,
    int? noteId,
    Offset globalPos,
    int gx,
    int gy,
    AppLocalizations l10n,
  ) async {
    final pos = RelativeRect.fromLTRB(globalPos.dx, globalPos.dy, globalPos.dx + 1, globalPos.dy + 1);
    final items = <PopupMenuEntry<String>>[];
    if (compId != null) {
      if (!_effectiveSelection.contains(compId)) {
        _refresh(() {
          _selectedCompIds.clear();
          _selectedCompId = compId;
        });
      }
      final comp = _doc.components.where((c) => c.id == compId).firstOrNull;
      items.addAll([
        PopupMenuItem(value: 'rot', child: Text(l10n.rotateAction)),
        PopupMenuItem(value: 'flipH', child: Text(l10n.flipHAction)),
        PopupMenuItem(value: 'flipV', child: Text(l10n.flipVAction)),
        PopupMenuItem(value: 'dup', child: Text(l10n.duplicateAction)),
        if (comp?.kind == CompKind.subcircuit)
          const PopupMenuItem(value: 'ungroup', child: Text('Ungroup Subcircuit')),
        PopupMenuItem(value: 'delComp', child: Text(l10n.deleteAction)),
      ]);
    } else if (wireIdx != null) {
      items.add(const PopupMenuItem(value: 'delWire', child: Text('Delete Wire')));
    } else if (noteId != null) {
      items.addAll([
        PopupMenuItem(value: 'editNote', child: Text(l10n.editNoteAction)),
        PopupMenuItem(value: 'delNote', child: Text(l10n.deleteAction)),
      ]);
    } else {
      items.addAll([
        PopupMenuItem(value: 'addNote', child: Text(l10n.addNoteAction)),
        if (_session.hasClipboard) const PopupMenuItem(value: 'paste', child: Text('Paste')),
        PopupMenuItem(value: 'fit', child: Text(l10n.fitViewAction)),
      ]);
    }
    if (items.isEmpty) return;
    final choice = await showMenu<String>(context: context, position: pos, items: items);
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'rot':
        _doc.rotateComponents(_effectiveSelection);
        _syncCircuit();
      case 'flipH':
        _doc.flipComponents(_effectiveSelection);
        _syncCircuit();
      case 'flipV':
        _doc.flipComponents(_effectiveSelection, vertical: true);
        _syncCircuit();
      case 'dup':
        _duplicateIds(_effectiveSelection);
      case 'ungroup':
        if (compId != null && _doc.ungroupSubcircuit(compId)) {
          _selectedCompId = null;
          _selectedCompIds.clear();
          _syncCircuit();
        }
      case 'delComp':
        _deleteSelected();
      case 'delWire':
        if (wireIdx != null) {
          _doc.deleteWireAt(wireIdx);
          _syncCircuit();
        }
      case 'editNote':
        if (noteId != null) {
          showEditNoteDialog(context, noteId, l10n, _doc, () {
            _scheduleAutoSave();
            _refresh();
          });
        }
      case 'delNote':
        if (noteId != null) {
          _doc.deleteNote(noteId);
          _scheduleAutoSave();
          _refresh();
        }
      case 'addNote':
        showAddNoteDialog(context, l10n, _doc, () {
          _scheduleAutoSave();
          _refresh();
        }, gx: gx, gy: gy);
      case 'paste':
        _pasteClipboard();
      case 'fit':
        _refresh(() => _fitTrigger++);
    }
  }
}
