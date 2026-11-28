part of 'main.dart';

extension _WorkbenchInstruments on _WorkbenchHomeState {
  Future<void> _triggerBode({
    double fStart = 10.0,
    double fStop = 100000.0,
    int ptsPerDecade = 20,
    int? acSourceId,
    int inNode = -1,
    int? outNodeOverride,
  }) =>
      _simCtrl.runBodeSweep(
        _doc,
        logicNodes: _logicNodeIds(),
        logicThreshold: _logicThresh,
        fStart: fStart,
        fStop: fStop,
        ptsPerDecade: ptsPerDecade,
        acSourceId: acSourceId,
        inNode: inNode,
        outNodeOverride: outNodeOverride,
      );

  void _openIvCurve(AppLocalizations l10n, {required bool isPhone}) {
    _refresh(() {
      _dcSweepIvMode = true;
      if (!(_splitInstruments && _secondaryInstTab == 5)) {
        _activeInstTab = 5;
      }
      if (isPhone) {
        _phoneDrawerTab = 2;
      } else {
        _showDesktopInstruments = true;
      }
    });
    _updateFftSubscription();
    if (_doc.findDcSweepSource(preferredId: _selectedCompId) == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.ivCurveNoDcSource)));
      return;
    }
    _triggerDcSweep(ivCurve: true);
  }

  Future<void> _triggerDcSweep({
    int? sweepSrcId,
    int? secSrcId,
    double vStart = 0.0,
    double vStop = 5.0,
    int steps = 25,
    bool family = false,
    bool ivCurve = false,
  }) =>
      _simCtrl.runDcSweep(
        _doc,
        logicNodes: _logicNodeIds(),
        logicThreshold: _logicThresh,
        sweepSrcId: sweepSrcId,
        secSrcId: secSrcId,
        vStart: vStart,
        vStop: vStop,
        steps: steps,
        family: family,
        ivCurve: ivCurve,
        selectedCompId: _selectedCompId,
      );

  Widget _buildSingleInstrument(
    int instTab,
    AppLocalizations l10n,
    SimTelemetry tel,
  ) {
    final selectedCurrent =
        _selectedCompId != null ? (tel.compCurrents[_selectedCompId!] ?? 0.0) : 0.0;
    var selectedVoltageDrop = 0.0;
    if (_selectedCompId != null) {
      final sel = _doc.components.where((c) => c.id == _selectedCompId).firstOrNull;
      if (sel != null && sel.pinOffsets.isNotEmpty) {
        final v0 = tel.nodeVoltages[_doc.resolvedNodes[PinRef(sel.id, 0)] ?? 0] ?? 0.0;
        final v1 = sel.pinOffsets.length >= 2
            ? (tel.nodeVoltages[_doc.resolvedNodes[PinRef(sel.id, 1)] ?? 0] ?? 0.0)
            : 0.0;
        selectedVoltageDrop = v0 - v1;
      }
    }
    return switch (instTab) {
      0 => OscilloscopeView(
          title: l10n.oscilloscopeTitle,
          ch1Values: tel.ch1,
          ch2Values: tel.ch2,
          ch3Values: tel.ch3,
          ch4Values: tel.ch4,
          ch1Times: tel.ch1Times,
          fftBins: tel.fft,
          ch1Dc: tel.ch1Stats.dc,
          ch2Dc: tel.ch2Stats.dc,
          ch3Dc: tel.ch3Stats.dc,
          ch4Dc: tel.ch4Stats.dc,
          thdPercent: tel.ch1Thd,
          triggered: tel.scopeTriggered,
          ch3Probed: _doc.probeCh3 != null,
          ch4Probed: _doc.probeCh4 != null,
          onFftModeChanged: (fftOn) {
            _scopeInFftMode = fftOn;
            _updateFftSubscription();
          },
          onTriggerConfigChanged: (trigCh, level, rising, require) {
            _simCtrl.setScopeConfig(
              trigCh: trigCh,
              trigLevel: level,
              rising: rising,
              requireTrigger: require,
              fftCh: _spectrumCh,
              needFft: _needsFft,
            );
          },
        ),
      1 => MultimeterView(
          ch1Stats: tel.ch1Stats,
          ch2Stats: tel.ch2Stats,
          ch3Stats: tel.ch3Stats,
          ch4Stats: tel.ch4Stats,
          ch1Values: tel.ch1,
          ch2Values: tel.ch2,
          ch1Times: tel.ch1Times,
          selectedCurrentAmps: selectedCurrent,
          selectedVoltageDrop: selectedVoltageDrop,
          selectedPowerWatts:
              _selectedCompId != null ? tel.compPowers[_selectedCompId!] : null,
          ch1ThdPercent: tel.ch1Thd,
          ch3Probed: _doc.probeCh3 != null,
          ch4Probed: _doc.probeCh4 != null,
          ch1DcFallback: _doc.probeCh1 != null
              ? (tel.nodeVoltages[_doc.resolvedNodes[_doc.probeCh1!] ?? 0] ?? 0.0)
              : null,
          ch2DcFallback: _doc.probeCh2 != null
              ? (tel.nodeVoltages[_doc.resolvedNodes[_doc.probeCh2!] ?? 0] ?? 0.0)
              : null,
          availableNodes: [
            for (final nid in _doc.resolvedNodes.values.toSet().toList()..sort())
              (nid, nid == 0 ? 'GND' : 'N$nid'),
          ],
          onMeasureTwoTerminal: (a, b, diode) => _simCtrl.measureTwoTerminal(
            _doc,
            a,
            b,
            diode,
            logicNodes: _logicNodeIds(),
            logicThreshold: _logicThresh,
          ),
        ),
      2 => BodePlotterView(
          sweepData: tel.bodeData,
          onRunSweep: _triggerBode,
          onRunSweepConfig: ({
            required double fStart,
            required double fStop,
            required int ptsPerDecade,
            int? acSourceId,
            int inNode = -1,
            int? outNode,
          }) =>
              _triggerBode(
            fStart: fStart,
            fStop: fStop,
            ptsPerDecade: ptsPerDecade,
            acSourceId: acSourceId,
            inNode: inNode,
            outNodeOverride: outNode,
          ),
          acSources: [
            for (final c in _doc.components)
              if (c.kind == CompKind.acSource || c.kind == CompKind.funcGen)
                (c.id, formatComponentBadge(c)),
          ],
          probeNodes: [
            for (final nid in _doc.resolvedNodes.values.toSet().toList()..sort())
              if (nid > 0) (nid, 'N$nid'),
          ],
        ),
      3 => LogicConverterView(
          onMinimizeAsync: _simCtrl.minimizeLogicEx,
          onExtractFromCircuit: () => _simCtrl.extractTruthTable(_doc),
          onBuildCircuit: (vars, expr, {bool nandOnly = false}) {
            _doc.synthesizeLogicToCanvas(vars, expr, nandOnly: nandOnly, clearCanvas: false);
            _selectedCompId = null;
            _selectedCompIds.clear();
            _pendingWirePin = null;
            _pendingSplitJunctionId = null;
            _syncCircuit();
          },
        ),
      4 => LogicAnalyzerView(
          ch1: tel.ch1,
          ch2: tel.ch2,
          ch3: tel.ch3,
          ch4: tel.ch4,
          times: tel.ch1Times,
          logicTimes: tel.logicTimes,
          logicMasks: tel.logicMasks,
          channelLabels: _collectLogicNodes().map((e) => e.$2).toList(),
          onConfigChanged: (_, threshold) => _syncLogicProbes(threshold),
        ),
      5 => DcSweepView(
          sweepData: tel.dcSweepData,
          familyCurves: tel.dcFamilyCurves,
          circuitRevision: tel.epoch,
          ivMode: _dcSweepIvMode,
          onIvModeChanged: (v) => _dcSweepIvMode = v,
          onRunSweep: (vStart, vStop) => _triggerDcSweep(vStart: vStart, vStop: vStop),
          onRunSweepConfig: ({
            int? srcId,
            int? secSrcId,
            required double vStart,
            required double vStop,
            required int steps,
            required bool family,
            required bool ivCurve,
          }) =>
              _triggerDcSweep(
            sweepSrcId: srcId,
            secSrcId: secSrcId,
            vStart: vStart,
            vStop: vStop,
            steps: steps,
            family: family,
            ivCurve: ivCurve,
          ),
          sweepSources: [
            for (final c in _doc.components)
              if (c.kind == CompKind.dcSource ||
                  c.kind == CompKind.dcCurrent ||
                  c.kind == CompKind.potentiometer ||
                  c.kind == CompKind.powerRail)
                (c.id, formatComponentBadge(c)),
          ],
          onRunMonteCarloEx: ({required tol, required runs, required gaussian}) =>
              _simCtrl.runMonteCarloEx(
            _doc,
            logicNodes: _logicNodeIds(),
            logicThreshold: _logicThresh,
            tol: tol,
            runs: runs,
            gaussian: gaussian,
          ),
        ),
      6 => () {
          final wgs = _doc.components.where((c) => c.kind == CompKind.wordGen).toList();
          final wg = wgs.where((w) => w.id == _selectedWordGenId).firstOrNull ?? wgs.firstOrNull;
          return WordGenPanel(
            wordGenId: wg?.id,
            wordGens: [
              for (final w in wgs)
                (
                  w.id,
                  'WG${w.id}',
                  w.hexPattern ?? 'FEDCBA9876543210',
                  w.params.isNotEmpty ? w.params[0] : 50.0,
                ),
            ],
            onSelectWordGen: (id) => _refresh(() => _selectedWordGenId = id),
            hexPattern: wg?.hexPattern ?? 'FEDCBA9876543210',
            freqHz: wg != null && wg.params.isNotEmpty ? wg.params[0] : 50.0,
            tSim: tel.tSim,
            onChangeHex: wg == null
                ? null
                : (hex) {
                    if (_doc.updateWordGenHex(wg.id, hex)) {
                      final bits = CircuitDoc.parseHexPattern64(hex);
                      if (bits != null) _simCtrl.setWordGenPattern(wg.id, bits);
                      _scheduleAutoSave();
                      _refresh();
                    }
                  },
            onStepHex: wg == null
                ? null
                : (hex) {
                    final bits = CircuitDoc.parseHexPattern64(hex);
                    if (bits != null) _simCtrl.setWordGenPattern(wg.id, bits);
                  },
            onChangeFreq: wg == null
                ? null
                : (hz) {
                    _doc.recordUndoSnapshot();
                    _applyParamChange(wg, 0, hz);
                  },
            onAddWordGen: () {
              final added = _doc.addComponent(CompKind.wordGen, 4, 4);
              _selectedWordGenId = added.id;
              _syncCircuit();
            },
          );
        }(),
      _ => SpectrumAnalyzerView(
          fftBins: tel.spectrumFft,
          ch1Times: tel.ch1Times,
          fftDt: tel.fftDt,
          thdPercent: tel.spectrumThd,
          activeCh: _spectrumCh,
          onChannelChanged: (ch) {
            _refresh(() => _spectrumCh = ch);
            _updateFftSubscription();
          },
        ),
    };
  }

  Widget _buildInstrumentRack(AppLocalizations l10n, CircuitColors colors) {
    final instEntries = [
      (0, l10n.oscilloscopeTitle),
      (1, l10n.multimeterTitle),
      (2, l10n.bodePlotterTitle),
      (3, l10n.logicConverterTitle),
      (4, l10n.logicAnalyzerTitle),
      (5, l10n.dcSweepTitle),
      (6, l10n.wordGenShortTitle),
      (7, l10n.spectrumTitle),
    ];
    return Semantics(
      label: 'Virtual instruments panel',
      child: Container(
        decoration: BoxDecoration(
          color: colors.panelSurface,
          border: Border(left: BorderSide(color: colors.panelBorder)),
        ),
        padding: const EdgeInsets.all(6),
        child: LayoutBuilder(
          builder: (context, box) {
            final tabs = [
              for (final (idx, label) in instEntries)
                ChoiceChip(
                  selected: _activeInstTab == idx,
                  selectedColor: colors.accentAmber,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                  label: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color: _activeInstTab == idx ? Colors.black : colors.componentStroke,
                    ),
                  ),
                  onSelected: (_) {
                    _refresh(() => _activeInstTab = idx);
                    _updateFftSubscription();
                    if (idx == 2 && _simCtrl.telemetry.value.bodeData == null) _triggerBode();
                    if (idx == 5 && _simCtrl.telemetry.value.dcSweepData == null) {
                      _triggerDcSweep(ivCurve: _dcSweepIvMode);
                    }
                  },
                ),
            ];
            return Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: box.maxHeight < 360
                          ? SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (final chip in tabs)
                                    Padding(padding: const EdgeInsets.only(right: 4), child: chip),
                                ],
                              ),
                            )
                          : Wrap(spacing: 4, runSpacing: 4, children: tabs),
                    ),
                    if (box.maxHeight >= 360)
                      IconButton(
                        tooltip: l10n.splitInstrumentsAction,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        icon: Icon(
                          Icons.splitscreen,
                          size: 16,
                          color: _splitInstruments ? colors.accentAmber : colors.componentStroke,
                        ),
                        onPressed: () {
                          _refresh(() => _splitInstruments = !_splitInstruments);
                          _updateFftSubscription();
                          if (_splitInstruments &&
                              _secondaryInstTab == 2 &&
                              _simCtrl.telemetry.value.bodeData == null) {
                            _triggerBode();
                          }
                          if (_splitInstruments &&
                              _secondaryInstTab == 5 &&
                              _simCtrl.telemetry.value.dcSweepData == null) {
                            _triggerDcSweep();
                          }
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: (!_splitInstruments && _activeInstTab == 3)
                      ? _buildSingleInstrument(3, l10n, _simCtrl.telemetry.value)
                      : ValueListenableBuilder<SimTelemetry>(
                          valueListenable: _simCtrl.telemetry,
                          builder: (_, tel, _) => Column(
                            children: [
                              Expanded(child: _buildSingleInstrument(_activeInstTab, l10n, tel)),
                              if (_splitInstruments && box.maxHeight >= 360) ...[
                                const Divider(height: 8),
                                Row(
                                  children: [
                                    Text('2nd View:', style: TextStyle(color: colors.accentAmber, fontSize: 11)),
                                    const SizedBox(width: 6),
                                    DropdownButton<int>(
                                      value: _secondaryInstTab,
                                      isDense: true,
                                      underline: const SizedBox.shrink(),
                                      items: [
                                        for (final (idx, label) in instEntries)
                                          DropdownMenuItem(
                                            value: idx,
                                            child: Text(label, style: const TextStyle(fontSize: 11)),
                                          ),
                                      ],
                                      onChanged: (idx) {
                                        if (idx == null) return;
                                        _refresh(() => _secondaryInstTab = idx);
                                        _updateFftSubscription();
                                        if (idx == 2 && tel.bodeData == null) _triggerBode();
                                        if (idx == 5 && tel.dcSweepData == null) _triggerDcSweep();
                                      },
                                    ),
                                  ],
                                ),
                                Expanded(child: _buildSingleInstrument(_secondaryInstTab, l10n, tel)),
                              ],
                            ],
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
