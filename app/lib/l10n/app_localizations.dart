import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'BenchOsc'**
  String get appTitle;

  /// No description provided for @runSimulation.
  ///
  /// In en, this message translates to:
  /// **'Run'**
  String get runSimulation;

  /// No description provided for @pauseSimulation.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pauseSimulation;

  /// No description provided for @resetSimulation.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get resetSimulation;

  /// No description provided for @componentsTab.
  ///
  /// In en, this message translates to:
  /// **'Components'**
  String get componentsTab;

  /// No description provided for @wireTool.
  ///
  /// In en, this message translates to:
  /// **'Wire'**
  String get wireTool;

  /// No description provided for @selectTool.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get selectTool;

  /// No description provided for @deleteTool.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get deleteTool;

  /// No description provided for @probeCh1.
  ///
  /// In en, this message translates to:
  /// **'Probe CH1'**
  String get probeCh1;

  /// No description provided for @probeCh2.
  ///
  /// In en, this message translates to:
  /// **'Probe CH2'**
  String get probeCh2;

  /// No description provided for @rotateAction.
  ///
  /// In en, this message translates to:
  /// **'Rotate'**
  String get rotateAction;

  /// No description provided for @oscilloscopeTitle.
  ///
  /// In en, this message translates to:
  /// **'Oscilloscope'**
  String get oscilloscopeTitle;

  /// No description provided for @fftTitle.
  ///
  /// In en, this message translates to:
  /// **'FFT Spectrum'**
  String get fftTitle;

  /// No description provided for @xyMode.
  ///
  /// In en, this message translates to:
  /// **'X-Y Mode'**
  String get xyMode;

  /// No description provided for @timeDomainMode.
  ///
  /// In en, this message translates to:
  /// **'Time'**
  String get timeDomainMode;

  /// No description provided for @multimeterTitle.
  ///
  /// In en, this message translates to:
  /// **'Multimeter'**
  String get multimeterTitle;

  /// No description provided for @bodePlotterTitle.
  ///
  /// In en, this message translates to:
  /// **'Bode Plotter'**
  String get bodePlotterTitle;

  /// No description provided for @logicConverterTitle.
  ///
  /// In en, this message translates to:
  /// **'Logic Converter'**
  String get logicConverterTitle;

  /// No description provided for @logicAnalyzerTitle.
  ///
  /// In en, this message translates to:
  /// **'Logic Analyzer'**
  String get logicAnalyzerTitle;

  /// No description provided for @propertiesTitle.
  ///
  /// In en, this message translates to:
  /// **'Properties'**
  String get propertiesTitle;

  /// No description provided for @instrumentsTab.
  ///
  /// In en, this message translates to:
  /// **'Instruments'**
  String get instrumentsTab;

  /// No description provided for @undoAction.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undoAction;

  /// No description provided for @redoAction.
  ///
  /// In en, this message translates to:
  /// **'Redo'**
  String get redoAction;

  /// No description provided for @deleteAction.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get deleteAction;

  /// No description provided for @importAction.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get importAction;

  /// No description provided for @exportAction.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get exportAction;

  /// No description provided for @exportCir.
  ///
  /// In en, this message translates to:
  /// **'Import / Export'**
  String get exportCir;

  /// No description provided for @pasteOrOpenHint.
  ///
  /// In en, this message translates to:
  /// **'Paste text below or open a file, then press Load.'**
  String get pasteOrOpenHint;

  /// No description provided for @jsonTab.
  ///
  /// In en, this message translates to:
  /// **'JSON'**
  String get jsonTab;

  /// No description provided for @spiceCirTab.
  ///
  /// In en, this message translates to:
  /// **'SPICE .cir'**
  String get spiceCirTab;

  /// No description provided for @bomCsvTab.
  ///
  /// In en, this message translates to:
  /// **'BOM / CSV'**
  String get bomCsvTab;

  /// No description provided for @boxSelectTool.
  ///
  /// In en, this message translates to:
  /// **'Box'**
  String get boxSelectTool;

  /// No description provided for @fitViewAction.
  ///
  /// In en, this message translates to:
  /// **'Fit'**
  String get fitViewAction;

  /// No description provided for @loadButton.
  ///
  /// In en, this message translates to:
  /// **'Load'**
  String get loadButton;

  /// No description provided for @saveFileButton.
  ///
  /// In en, this message translates to:
  /// **'Save File'**
  String get saveFileButton;

  /// No description provided for @loadFileButton.
  ///
  /// In en, this message translates to:
  /// **'Open File'**
  String get loadFileButton;

  /// No description provided for @filePathHint.
  ///
  /// In en, this message translates to:
  /// **'File path (.json / .cir / .csv)'**
  String get filePathHint;

  /// No description provided for @copyButton.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copyButton;

  /// No description provided for @closeButton.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get closeButton;

  /// No description provided for @catPowerSources.
  ///
  /// In en, this message translates to:
  /// **'Power & Sources'**
  String get catPowerSources;

  /// No description provided for @catPassives.
  ///
  /// In en, this message translates to:
  /// **'Passives'**
  String get catPassives;

  /// No description provided for @catSwitchesLoads.
  ///
  /// In en, this message translates to:
  /// **'Switches & Loads'**
  String get catSwitchesLoads;

  /// No description provided for @catDiodesLeds.
  ///
  /// In en, this message translates to:
  /// **'Diodes & LEDs'**
  String get catDiodesLeds;

  /// No description provided for @catTransistors.
  ///
  /// In en, this message translates to:
  /// **'Transistors'**
  String get catTransistors;

  /// No description provided for @catAnalogIcs.
  ///
  /// In en, this message translates to:
  /// **'Analog ICs'**
  String get catAnalogIcs;

  /// No description provided for @catLogicGates.
  ///
  /// In en, this message translates to:
  /// **'Logic Gates'**
  String get catLogicGates;

  /// No description provided for @catDigitalIcs.
  ///
  /// In en, this message translates to:
  /// **'Digital ICs'**
  String get catDigitalIcs;

  /// No description provided for @catMetersIo.
  ///
  /// In en, this message translates to:
  /// **'Meters & I/O'**
  String get catMetersIo;

  /// No description provided for @makeSubcircuitAction.
  ///
  /// In en, this message translates to:
  /// **'Make IC'**
  String get makeSubcircuitAction;

  /// No description provided for @buzzerAudioTooltip.
  ///
  /// In en, this message translates to:
  /// **'Toggle Buzzer Audio'**
  String get buzzerAudioTooltip;

  /// No description provided for @compResistor.
  ///
  /// In en, this message translates to:
  /// **'Resistor'**
  String get compResistor;

  /// No description provided for @compCapacitor.
  ///
  /// In en, this message translates to:
  /// **'Capacitor'**
  String get compCapacitor;

  /// No description provided for @compInductor.
  ///
  /// In en, this message translates to:
  /// **'Inductor'**
  String get compInductor;

  /// No description provided for @compPotentiometer.
  ///
  /// In en, this message translates to:
  /// **'Potentiometer'**
  String get compPotentiometer;

  /// No description provided for @compSwitch.
  ///
  /// In en, this message translates to:
  /// **'SPST Switch'**
  String get compSwitch;

  /// No description provided for @compSwitchSpdt.
  ///
  /// In en, this message translates to:
  /// **'SPDT Switch'**
  String get compSwitchSpdt;

  /// No description provided for @compPushbutton.
  ///
  /// In en, this message translates to:
  /// **'Pushbutton'**
  String get compPushbutton;

  /// No description provided for @compRelay.
  ///
  /// In en, this message translates to:
  /// **'Relay (NO)'**
  String get compRelay;

  /// No description provided for @compLamp.
  ///
  /// In en, this message translates to:
  /// **'Lamp'**
  String get compLamp;

  /// No description provided for @compFuse.
  ///
  /// In en, this message translates to:
  /// **'Fuse'**
  String get compFuse;

  /// No description provided for @compDcSource.
  ///
  /// In en, this message translates to:
  /// **'DC Voltage'**
  String get compDcSource;

  /// No description provided for @compDcCurrent.
  ///
  /// In en, this message translates to:
  /// **'DC Current'**
  String get compDcCurrent;

  /// No description provided for @compAcSource.
  ///
  /// In en, this message translates to:
  /// **'AC Voltage'**
  String get compAcSource;

  /// No description provided for @compFuncGen.
  ///
  /// In en, this message translates to:
  /// **'Function Gen'**
  String get compFuncGen;

  /// No description provided for @compGround.
  ///
  /// In en, this message translates to:
  /// **'Ground'**
  String get compGround;

  /// No description provided for @compDiode.
  ///
  /// In en, this message translates to:
  /// **'Diode'**
  String get compDiode;

  /// No description provided for @compZener.
  ///
  /// In en, this message translates to:
  /// **'Zener Diode'**
  String get compZener;

  /// No description provided for @compLed.
  ///
  /// In en, this message translates to:
  /// **'LED'**
  String get compLed;

  /// No description provided for @compOpAmp.
  ///
  /// In en, this message translates to:
  /// **'Op-Amp'**
  String get compOpAmp;

  /// No description provided for @compNpnBjt.
  ///
  /// In en, this message translates to:
  /// **'NPN BJT'**
  String get compNpnBjt;

  /// No description provided for @compPnpBjt.
  ///
  /// In en, this message translates to:
  /// **'PNP BJT'**
  String get compPnpBjt;

  /// No description provided for @compNmos.
  ///
  /// In en, this message translates to:
  /// **'NMOSFET'**
  String get compNmos;

  /// No description provided for @compPmos.
  ///
  /// In en, this message translates to:
  /// **'PMOSFET'**
  String get compPmos;

  /// No description provided for @compVcvs.
  ///
  /// In en, this message translates to:
  /// **'VCVS'**
  String get compVcvs;

  /// No description provided for @compVccs.
  ///
  /// In en, this message translates to:
  /// **'VCCS'**
  String get compVccs;

  /// No description provided for @compCccs.
  ///
  /// In en, this message translates to:
  /// **'CCCS'**
  String get compCccs;

  /// No description provided for @compCcvs.
  ///
  /// In en, this message translates to:
  /// **'CCVS'**
  String get compCcvs;

  /// No description provided for @compTransformer.
  ///
  /// In en, this message translates to:
  /// **'Transformer'**
  String get compTransformer;

  /// No description provided for @compAndGate.
  ///
  /// In en, this message translates to:
  /// **'AND Gate'**
  String get compAndGate;

  /// No description provided for @compOrGate.
  ///
  /// In en, this message translates to:
  /// **'OR Gate'**
  String get compOrGate;

  /// No description provided for @compNotGate.
  ///
  /// In en, this message translates to:
  /// **'NOT Gate'**
  String get compNotGate;

  /// No description provided for @compNandGate.
  ///
  /// In en, this message translates to:
  /// **'NAND Gate'**
  String get compNandGate;

  /// No description provided for @compNorGate.
  ///
  /// In en, this message translates to:
  /// **'NOR Gate'**
  String get compNorGate;

  /// No description provided for @compXorGate.
  ///
  /// In en, this message translates to:
  /// **'XOR Gate'**
  String get compXorGate;

  /// No description provided for @compXnorGate.
  ///
  /// In en, this message translates to:
  /// **'XNOR Gate'**
  String get compXnorGate;

  /// No description provided for @compDFlipFlop.
  ///
  /// In en, this message translates to:
  /// **'D Flip-Flop'**
  String get compDFlipFlop;

  /// No description provided for @compLogicProbe.
  ///
  /// In en, this message translates to:
  /// **'Logic Probe'**
  String get compLogicProbe;

  /// No description provided for @compTimer555.
  ///
  /// In en, this message translates to:
  /// **'555 Timer'**
  String get compTimer555;

  /// No description provided for @compSevenSeg.
  ///
  /// In en, this message translates to:
  /// **'7-Seg Display'**
  String get compSevenSeg;

  /// No description provided for @compWordGen.
  ///
  /// In en, this message translates to:
  /// **'Word Gen'**
  String get compWordGen;

  /// No description provided for @compClock.
  ///
  /// In en, this message translates to:
  /// **'Clock'**
  String get compClock;

  /// No description provided for @faultLabel.
  ///
  /// In en, this message translates to:
  /// **'Fault Injection'**
  String get faultLabel;

  /// No description provided for @faultNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get faultNone;

  /// No description provided for @faultOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get faultOpen;

  /// No description provided for @faultShort.
  ///
  /// In en, this message translates to:
  /// **'Short'**
  String get faultShort;

  /// No description provided for @faultLeaky.
  ///
  /// In en, this message translates to:
  /// **'Leaky'**
  String get faultLeaky;

  /// No description provided for @presetLabel.
  ///
  /// In en, this message translates to:
  /// **'Presets'**
  String get presetLabel;

  /// No description provided for @presetRcFilter.
  ///
  /// In en, this message translates to:
  /// **'RC Low-Pass'**
  String get presetRcFilter;

  /// No description provided for @presetRectifier.
  ///
  /// In en, this message translates to:
  /// **'Diode Rectifier'**
  String get presetRectifier;

  /// No description provided for @presetOpAmp.
  ///
  /// In en, this message translates to:
  /// **'Inverting Op-Amp'**
  String get presetOpAmp;

  /// No description provided for @presetBjtSwitch.
  ///
  /// In en, this message translates to:
  /// **'BJT LED Switch'**
  String get presetBjtSwitch;

  /// No description provided for @presetDigitalXor.
  ///
  /// In en, this message translates to:
  /// **'Digital XOR'**
  String get presetDigitalXor;

  /// No description provided for @presetDffDivider.
  ///
  /// In en, this message translates to:
  /// **'D-FF Freq Divider'**
  String get presetDffDivider;

  /// No description provided for @presetTimer555.
  ///
  /// In en, this message translates to:
  /// **'555 Astable Blinker'**
  String get presetTimer555;

  /// No description provided for @presetWordGen.
  ///
  /// In en, this message translates to:
  /// **'4-Bit Hex Counter'**
  String get presetWordGen;

  /// No description provided for @compOptocoupler.
  ///
  /// In en, this message translates to:
  /// **'Optocoupler'**
  String get compOptocoupler;

  /// No description provided for @presetOptocoupler.
  ///
  /// In en, this message translates to:
  /// **'Optocoupler Isolation'**
  String get presetOptocoupler;

  /// No description provided for @compSchmittTrigger.
  ///
  /// In en, this message translates to:
  /// **'Schmitt Trigger'**
  String get compSchmittTrigger;

  /// No description provided for @compCounter4Bit.
  ///
  /// In en, this message translates to:
  /// **'Binary Counter'**
  String get compCounter4Bit;

  /// No description provided for @presetSchmittCounter.
  ///
  /// In en, this message translates to:
  /// **'Schmitt Trigger Counter'**
  String get presetSchmittCounter;

  /// No description provided for @dcSweepTitle.
  ///
  /// In en, this message translates to:
  /// **'DC Sweep'**
  String get dcSweepTitle;

  /// No description provided for @runDcSweep.
  ///
  /// In en, this message translates to:
  /// **'Run DC Sweep'**
  String get runDcSweep;

  /// No description provided for @probeCh3.
  ///
  /// In en, this message translates to:
  /// **'CH3'**
  String get probeCh3;

  /// No description provided for @probeCh4.
  ///
  /// In en, this message translates to:
  /// **'CH4'**
  String get probeCh4;

  /// No description provided for @themeToggleTooltip.
  ///
  /// In en, this message translates to:
  /// **'Toggle Light/Dark Theme'**
  String get themeToggleTooltip;

  /// No description provided for @duplicateAction.
  ///
  /// In en, this message translates to:
  /// **'Duplicate'**
  String get duplicateAction;

  /// No description provided for @showValuesLabel.
  ///
  /// In en, this message translates to:
  /// **'Labels'**
  String get showValuesLabel;

  /// No description provided for @showVoltagesLabel.
  ///
  /// In en, this message translates to:
  /// **'Node V'**
  String get showVoltagesLabel;

  /// No description provided for @showFlowLabel.
  ///
  /// In en, this message translates to:
  /// **'Flow'**
  String get showFlowLabel;

  /// No description provided for @runAcSweep.
  ///
  /// In en, this message translates to:
  /// **'Run AC Sweep'**
  String get runAcSweep;

  /// No description provided for @buildCircuitButton.
  ///
  /// In en, this message translates to:
  /// **'Build Circuit'**
  String get buildCircuitButton;

  /// No description provided for @powerLabel.
  ///
  /// In en, this message translates to:
  /// **'Power'**
  String get powerLabel;

  /// No description provided for @voltageDropLabel.
  ///
  /// In en, this message translates to:
  /// **'Comp ΔV'**
  String get voltageDropLabel;

  /// No description provided for @cutoffFreqLabel.
  ///
  /// In en, this message translates to:
  /// **'f(-3dB)'**
  String get cutoffFreqLabel;

  /// No description provided for @variablesLabel.
  ///
  /// In en, this message translates to:
  /// **'Inputs'**
  String get variablesLabel;

  /// No description provided for @booleanExprLabel.
  ///
  /// In en, this message translates to:
  /// **'Simplified SOP'**
  String get booleanExprLabel;

  /// No description provided for @dcVoltsLabel.
  ///
  /// In en, this message translates to:
  /// **'DC V'**
  String get dcVoltsLabel;

  /// No description provided for @acRmsLabel.
  ///
  /// In en, this message translates to:
  /// **'AC RMS'**
  String get acRmsLabel;

  /// No description provided for @minMaxLabel.
  ///
  /// In en, this message translates to:
  /// **'Min / Max'**
  String get minMaxLabel;

  /// No description provided for @currentLabel.
  ///
  /// In en, this message translates to:
  /// **'Current'**
  String get currentLabel;

  /// No description provided for @magnitudeDbLabel.
  ///
  /// In en, this message translates to:
  /// **'Magnitude (dB)'**
  String get magnitudeDbLabel;

  /// No description provided for @phaseDegLabel.
  ///
  /// In en, this message translates to:
  /// **'Phase (deg)'**
  String get phaseDegLabel;

  /// No description provided for @triggerLevelLabel.
  ///
  /// In en, this message translates to:
  /// **'Trigger'**
  String get triggerLevelLabel;

  /// No description provided for @selectHint.
  ///
  /// In en, this message translates to:
  /// **'Tap a component on canvas to edit properties.'**
  String get selectHint;

  /// No description provided for @paramVolts.
  ///
  /// In en, this message translates to:
  /// **'V'**
  String get paramVolts;

  /// No description provided for @paramAmps.
  ///
  /// In en, this message translates to:
  /// **'I (A)'**
  String get paramAmps;

  /// No description provided for @paramAmpPeak.
  ///
  /// In en, this message translates to:
  /// **'Vp'**
  String get paramAmpPeak;

  /// No description provided for @paramFreqHz.
  ///
  /// In en, this message translates to:
  /// **'Hz'**
  String get paramFreqHz;

  /// No description provided for @paramShape.
  ///
  /// In en, this message translates to:
  /// **'Shape'**
  String get paramShape;

  /// No description provided for @paramDcOffset.
  ///
  /// In en, this message translates to:
  /// **'DC'**
  String get paramDcOffset;

  /// No description provided for @paramVHigh.
  ///
  /// In en, this message translates to:
  /// **'Vhi'**
  String get paramVHigh;

  /// No description provided for @paramOhms.
  ///
  /// In en, this message translates to:
  /// **'Ohm'**
  String get paramOhms;

  /// No description provided for @paramWiper.
  ///
  /// In en, this message translates to:
  /// **'Wiper'**
  String get paramWiper;

  /// No description provided for @paramFarads.
  ///
  /// In en, this message translates to:
  /// **'F'**
  String get paramFarads;

  /// No description provided for @paramHenrys.
  ///
  /// In en, this message translates to:
  /// **'H'**
  String get paramHenrys;

  /// No description provided for @paramSwitchState.
  ///
  /// In en, this message translates to:
  /// **'State'**
  String get paramSwitchState;

  /// No description provided for @paramMaxCurrent.
  ///
  /// In en, this message translates to:
  /// **'Imax'**
  String get paramMaxCurrent;

  /// No description provided for @paramZenerVolts.
  ///
  /// In en, this message translates to:
  /// **'Vz'**
  String get paramZenerVolts;

  /// No description provided for @paramGain.
  ///
  /// In en, this message translates to:
  /// **'Gain'**
  String get paramGain;

  /// No description provided for @paramBeta.
  ///
  /// In en, this message translates to:
  /// **'Beta'**
  String get paramBeta;

  /// No description provided for @paramVth.
  ///
  /// In en, this message translates to:
  /// **'Vth'**
  String get paramVth;

  /// No description provided for @paramPhaseDeg.
  ///
  /// In en, this message translates to:
  /// **'Phase'**
  String get paramPhaseDeg;

  /// No description provided for @paramDuty.
  ///
  /// In en, this message translates to:
  /// **'Duty'**
  String get paramDuty;

  /// No description provided for @paramGm.
  ///
  /// In en, this message translates to:
  /// **'gm (S)'**
  String get paramGm;

  /// No description provided for @paramRatio.
  ///
  /// In en, this message translates to:
  /// **'Turns n'**
  String get paramRatio;

  /// No description provided for @paramRm.
  ///
  /// In en, this message translates to:
  /// **'rm (Ohm)'**
  String get paramRm;

  /// No description provided for @wordGenPatternLabel.
  ///
  /// In en, this message translates to:
  /// **'Hex Pattern (16 hex, step 0 = LSB)'**
  String get wordGenPatternLabel;

  /// No description provided for @errInvalidImport.
  ///
  /// In en, this message translates to:
  /// **'Invalid circuit text could not be loaded.'**
  String get errInvalidImport;

  /// No description provided for @vPerDivLabel.
  ///
  /// In en, this message translates to:
  /// **'{v} V/div'**
  String vPerDivLabel(String v);

  /// No description provided for @errMissingGround.
  ///
  /// In en, this message translates to:
  /// **'Circuit requires at least one Ground (GND) node.'**
  String get errMissingGround;

  /// No description provided for @errFloatingNode.
  ///
  /// In en, this message translates to:
  /// **'Floating node detected (Node {nodeId}).'**
  String errFloatingNode(int nodeId);

  /// No description provided for @errSingularMatrix.
  ///
  /// In en, this message translates to:
  /// **'Singular circuit matrix (check voltage source loops).'**
  String get errSingularMatrix;

  /// No description provided for @errConvergenceFailed.
  ///
  /// In en, this message translates to:
  /// **'Simulation failed to converge.'**
  String get errConvergenceFailed;

  /// No description provided for @errGeneric.
  ///
  /// In en, this message translates to:
  /// **'Simulation error ({code}).'**
  String errGeneric(int code);

  /// No description provided for @errInvalidParam.
  ///
  /// In en, this message translates to:
  /// **'Invalid component parameter value.'**
  String get errInvalidParam;

  /// No description provided for @errUnknownComponent.
  ///
  /// In en, this message translates to:
  /// **'Unknown component reference in simulation.'**
  String get errUnknownComponent;

  /// No description provided for @errInvalidNetlist.
  ///
  /// In en, this message translates to:
  /// **'Invalid circuit netlist.'**
  String get errInvalidNetlist;

  /// No description provided for @errNullHandle.
  ///
  /// In en, this message translates to:
  /// **'Simulation engine handle is unavailable.'**
  String get errNullHandle;

  /// No description provided for @errEmptyCircuit.
  ///
  /// In en, this message translates to:
  /// **'Add components to simulate.'**
  String get errEmptyCircuit;

  /// No description provided for @newCanvasAction.
  ///
  /// In en, this message translates to:
  /// **'New / Clear Canvas'**
  String get newCanvasAction;

  /// No description provided for @splitInstrumentsAction.
  ///
  /// In en, this message translates to:
  /// **'Split Instruments'**
  String get splitInstrumentsAction;

  /// No description provided for @filterComponentsHint.
  ///
  /// In en, this message translates to:
  /// **'Filter components...'**
  String get filterComponentsHint;

  /// No description provided for @partsLibraryTitle.
  ///
  /// In en, this message translates to:
  /// **'Parts Library'**
  String get partsLibraryTitle;

  /// No description provided for @subcircuitsTitle.
  ///
  /// In en, this message translates to:
  /// **'Subcircuits'**
  String get subcircuitsTitle;

  /// No description provided for @unsavedChangesTitle.
  ///
  /// In en, this message translates to:
  /// **'Unsaved Changes'**
  String get unsavedChangesTitle;

  /// No description provided for @discardAction.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get discardAction;

  /// No description provided for @cancelAction.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancelAction;

  /// No description provided for @addNoteAction.
  ///
  /// In en, this message translates to:
  /// **'Add Schematic Note'**
  String get addNoteAction;

  /// No description provided for @editNoteAction.
  ///
  /// In en, this message translates to:
  /// **'Edit Note'**
  String get editNoteAction;

  /// No description provided for @restoreAutoSaveAction.
  ///
  /// In en, this message translates to:
  /// **'Restore Auto-Save'**
  String get restoreAutoSaveAction;

  /// No description provided for @spectrumTitle.
  ///
  /// In en, this message translates to:
  /// **'Spectrum'**
  String get spectrumTitle;

  /// No description provided for @wordGenShortTitle.
  ///
  /// In en, this message translates to:
  /// **'Word Gen'**
  String get wordGenShortTitle;

  /// No description provided for @noteLabel.
  ///
  /// In en, this message translates to:
  /// **'Note'**
  String get noteLabel;

  /// No description provided for @alignHAction.
  ///
  /// In en, this message translates to:
  /// **'Align H'**
  String get alignHAction;

  /// No description provided for @alignVAction.
  ///
  /// In en, this message translates to:
  /// **'Align V'**
  String get alignVAction;

  /// No description provided for @flipHAction.
  ///
  /// In en, this message translates to:
  /// **'Flip H'**
  String get flipHAction;

  /// No description provided for @flipVAction.
  ///
  /// In en, this message translates to:
  /// **'Flip V'**
  String get flipVAction;

  /// No description provided for @singleStepAction.
  ///
  /// In en, this message translates to:
  /// **'Single Step'**
  String get singleStepAction;

  /// No description provided for @helpShortcutsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Help & Shortcuts (?)'**
  String get helpShortcutsTooltip;

  /// No description provided for @fpsLabel.
  ///
  /// In en, this message translates to:
  /// **'{fps} Hz'**
  String fpsLabel(int fps);

  /// No description provided for @ivCurveAction.
  ///
  /// In en, this message translates to:
  /// **'I-V Curve'**
  String get ivCurveAction;

  /// No description provided for @ivCurveNoDcSource.
  ///
  /// In en, this message translates to:
  /// **'Add a DC source to plot an I-V curve.'**
  String get ivCurveNoDcSource;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
