// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'BenchOsc';

  @override
  String get runSimulation => 'Run';

  @override
  String get pauseSimulation => 'Pause';

  @override
  String get resetSimulation => 'Reset';

  @override
  String get componentsTab => 'Components';

  @override
  String get wireTool => 'Wire';

  @override
  String get selectTool => 'Select';

  @override
  String get deleteTool => 'Delete';

  @override
  String get probeCh1 => 'Probe CH1';

  @override
  String get probeCh2 => 'Probe CH2';

  @override
  String get rotateAction => 'Rotate';

  @override
  String get oscilloscopeTitle => 'Oscilloscope';

  @override
  String get fftTitle => 'FFT Spectrum';

  @override
  String get xyMode => 'X-Y Mode';

  @override
  String get timeDomainMode => 'Time';

  @override
  String get multimeterTitle => 'Multimeter';

  @override
  String get bodePlotterTitle => 'Bode Plotter';

  @override
  String get logicConverterTitle => 'Logic Converter';

  @override
  String get logicAnalyzerTitle => 'Logic Analyzer';

  @override
  String get propertiesTitle => 'Properties';

  @override
  String get instrumentsTab => 'Instruments';

  @override
  String get undoAction => 'Undo';

  @override
  String get redoAction => 'Redo';

  @override
  String get deleteAction => 'Delete';

  @override
  String get importAction => 'Import';

  @override
  String get exportAction => 'Export';

  @override
  String get exportCir => 'Import / Export';

  @override
  String get pasteOrOpenHint =>
      'Paste text below or open a file, then press Load.';

  @override
  String get jsonTab => 'JSON';

  @override
  String get spiceCirTab => 'SPICE .cir';

  @override
  String get bomCsvTab => 'BOM / CSV';

  @override
  String get boxSelectTool => 'Box';

  @override
  String get fitViewAction => 'Fit';

  @override
  String get loadButton => 'Load';

  @override
  String get saveFileButton => 'Save File';

  @override
  String get loadFileButton => 'Open File';

  @override
  String get filePathHint => 'File path (.json / .cir / .csv)';

  @override
  String get copyButton => 'Copy';

  @override
  String get closeButton => 'Close';

  @override
  String get catPowerSources => 'Power & Sources';

  @override
  String get catPassives => 'Passives';

  @override
  String get catSwitchesLoads => 'Switches & Loads';

  @override
  String get catDiodesLeds => 'Diodes & LEDs';

  @override
  String get catTransistors => 'Transistors';

  @override
  String get catAnalogIcs => 'Analog ICs';

  @override
  String get catLogicGates => 'Logic Gates';

  @override
  String get catDigitalIcs => 'Digital ICs';

  @override
  String get catMetersIo => 'Meters & I/O';

  @override
  String get makeSubcircuitAction => 'Make IC';

  @override
  String get buzzerAudioTooltip => 'Toggle Buzzer Audio';

  @override
  String get compResistor => 'Resistor';

  @override
  String get compCapacitor => 'Capacitor';

  @override
  String get compInductor => 'Inductor';

  @override
  String get compPotentiometer => 'Potentiometer';

  @override
  String get compSwitch => 'SPST Switch';

  @override
  String get compSwitchSpdt => 'SPDT Switch';

  @override
  String get compPushbutton => 'Pushbutton';

  @override
  String get compRelay => 'Relay (NO)';

  @override
  String get compLamp => 'Lamp';

  @override
  String get compFuse => 'Fuse';

  @override
  String get compDcSource => 'DC Voltage';

  @override
  String get compDcCurrent => 'DC Current';

  @override
  String get compAcSource => 'AC Voltage';

  @override
  String get compFuncGen => 'Function Gen';

  @override
  String get compGround => 'Ground';

  @override
  String get compDiode => 'Diode';

  @override
  String get compZener => 'Zener Diode';

  @override
  String get compLed => 'LED';

  @override
  String get compOpAmp => 'Op-Amp';

  @override
  String get compNpnBjt => 'NPN BJT';

  @override
  String get compPnpBjt => 'PNP BJT';

  @override
  String get compNmos => 'NMOSFET';

  @override
  String get compPmos => 'PMOSFET';

  @override
  String get compVcvs => 'VCVS';

  @override
  String get compVccs => 'VCCS';

  @override
  String get compCccs => 'CCCS';

  @override
  String get compCcvs => 'CCVS';

  @override
  String get compTransformer => 'Transformer';

  @override
  String get compAndGate => 'AND Gate';

  @override
  String get compOrGate => 'OR Gate';

  @override
  String get compNotGate => 'NOT Gate';

  @override
  String get compNandGate => 'NAND Gate';

  @override
  String get compNorGate => 'NOR Gate';

  @override
  String get compXorGate => 'XOR Gate';

  @override
  String get compXnorGate => 'XNOR Gate';

  @override
  String get compDFlipFlop => 'D Flip-Flop';

  @override
  String get compLogicProbe => 'Logic Probe';

  @override
  String get compTimer555 => '555 Timer';

  @override
  String get compSevenSeg => '7-Seg Display';

  @override
  String get compWordGen => 'Word Gen';

  @override
  String get compClock => 'Clock';

  @override
  String get faultLabel => 'Fault Injection';

  @override
  String get faultNone => 'None';

  @override
  String get faultOpen => 'Open';

  @override
  String get faultShort => 'Short';

  @override
  String get faultLeaky => 'Leaky';

  @override
  String get presetLabel => 'Presets';

  @override
  String get presetRcFilter => 'RC Low-Pass';

  @override
  String get presetRectifier => 'Diode Rectifier';

  @override
  String get presetOpAmp => 'Inverting Op-Amp';

  @override
  String get presetBjtSwitch => 'BJT LED Switch';

  @override
  String get presetDigitalXor => 'Digital XOR';

  @override
  String get presetDffDivider => 'D-FF Freq Divider';

  @override
  String get presetTimer555 => '555 Astable Blinker';

  @override
  String get presetWordGen => '4-Bit Hex Counter';

  @override
  String get compOptocoupler => 'Optocoupler';

  @override
  String get presetOptocoupler => 'Optocoupler Isolation';

  @override
  String get compSchmittTrigger => 'Schmitt Trigger';

  @override
  String get compCounter4Bit => 'Binary Counter';

  @override
  String get presetSchmittCounter => 'Schmitt Trigger Counter';

  @override
  String get dcSweepTitle => 'DC Sweep';

  @override
  String get runDcSweep => 'Run DC Sweep';

  @override
  String get probeCh3 => 'CH3';

  @override
  String get probeCh4 => 'CH4';

  @override
  String get themeToggleTooltip => 'Toggle Light/Dark Theme';

  @override
  String get duplicateAction => 'Duplicate';

  @override
  String get showValuesLabel => 'Labels';

  @override
  String get showVoltagesLabel => 'Node V';

  @override
  String get showFlowLabel => 'Flow';

  @override
  String get runAcSweep => 'Run AC Sweep';

  @override
  String get buildCircuitButton => 'Build Circuit';

  @override
  String get powerLabel => 'Power';

  @override
  String get voltageDropLabel => 'Comp ΔV';

  @override
  String get cutoffFreqLabel => 'f(-3dB)';

  @override
  String get variablesLabel => 'Inputs';

  @override
  String get booleanExprLabel => 'Simplified SOP';

  @override
  String get dcVoltsLabel => 'DC V';

  @override
  String get acRmsLabel => 'AC RMS';

  @override
  String get minMaxLabel => 'Min / Max';

  @override
  String get currentLabel => 'Current';

  @override
  String get magnitudeDbLabel => 'Magnitude (dB)';

  @override
  String get phaseDegLabel => 'Phase (deg)';

  @override
  String get triggerLevelLabel => 'Trigger';

  @override
  String get selectHint => 'Tap a component on canvas to edit properties.';

  @override
  String get paramVolts => 'V';

  @override
  String get paramAmps => 'I (A)';

  @override
  String get paramAmpPeak => 'Vp';

  @override
  String get paramFreqHz => 'Hz';

  @override
  String get paramShape => 'Shape';

  @override
  String get paramDcOffset => 'DC';

  @override
  String get paramVHigh => 'Vhi';

  @override
  String get paramOhms => 'Ohm';

  @override
  String get paramWiper => 'Wiper';

  @override
  String get paramFarads => 'F';

  @override
  String get paramHenrys => 'H';

  @override
  String get paramSwitchState => 'State';

  @override
  String get paramMaxCurrent => 'Imax';

  @override
  String get paramZenerVolts => 'Vz';

  @override
  String get paramGain => 'Gain';

  @override
  String get paramBeta => 'Beta';

  @override
  String get paramVth => 'Vth';

  @override
  String get paramPhaseDeg => 'Phase';

  @override
  String get paramDuty => 'Duty';

  @override
  String get paramGm => 'gm (S)';

  @override
  String get paramRatio => 'Turns n';

  @override
  String get paramRm => 'rm (Ohm)';

  @override
  String get wordGenPatternLabel => 'Hex Pattern (16 hex, step 0 = LSB)';

  @override
  String get errInvalidImport => 'Invalid circuit text could not be loaded.';

  @override
  String vPerDivLabel(String v) {
    return '$v V/div';
  }

  @override
  String get errMissingGround =>
      'Circuit requires at least one Ground (GND) node.';

  @override
  String errFloatingNode(int nodeId) {
    return 'Floating node detected (Node $nodeId).';
  }

  @override
  String get errSingularMatrix =>
      'Singular circuit matrix (check voltage source loops).';

  @override
  String get errConvergenceFailed => 'Simulation failed to converge.';

  @override
  String errGeneric(int code) {
    return 'Simulation error ($code).';
  }

  @override
  String get errInvalidParam => 'Invalid component parameter value.';

  @override
  String get errUnknownComponent =>
      'Unknown component reference in simulation.';

  @override
  String get errInvalidNetlist => 'Invalid circuit netlist.';

  @override
  String get errNullHandle => 'Simulation engine handle is unavailable.';

  @override
  String get errEmptyCircuit => 'Add components to simulate.';

  @override
  String get newCanvasAction => 'New / Clear Canvas';

  @override
  String get splitInstrumentsAction => 'Split Instruments';

  @override
  String get filterComponentsHint => 'Filter components...';

  @override
  String get partsLibraryTitle => 'Parts Library';

  @override
  String get subcircuitsTitle => 'Subcircuits';

  @override
  String get unsavedChangesTitle => 'Unsaved Changes';

  @override
  String get discardAction => 'Discard';

  @override
  String get cancelAction => 'Cancel';

  @override
  String get addNoteAction => 'Add Schematic Note';

  @override
  String get editNoteAction => 'Edit Note';

  @override
  String get restoreAutoSaveAction => 'Restore Auto-Save';

  @override
  String get spectrumTitle => 'Spectrum';

  @override
  String get wordGenShortTitle => 'Word Gen';

  @override
  String get noteLabel => 'Note';

  @override
  String get alignHAction => 'Align H';

  @override
  String get alignVAction => 'Align V';

  @override
  String get flipHAction => 'Flip H';

  @override
  String get flipVAction => 'Flip V';

  @override
  String get singleStepAction => 'Single Step';

  @override
  String get helpShortcutsTooltip => 'Help & Shortcuts (?)';

  @override
  String fpsLabel(int fps) {
    return '$fps Hz';
  }

  @override
  String get ivCurveAction => 'I-V Curve';

  @override
  String get ivCurveNoDcSource => 'Add a DC source to plot an I-V curve.';
}
