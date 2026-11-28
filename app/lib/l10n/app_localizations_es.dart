// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'BenchOsc';

  @override
  String get runSimulation => 'Ejecutar';

  @override
  String get pauseSimulation => 'Pausa';

  @override
  String get resetSimulation => 'Reiniciar';

  @override
  String get componentsTab => 'Componentes';

  @override
  String get wireTool => 'Cable';

  @override
  String get selectTool => 'Seleccionar';

  @override
  String get deleteTool => 'Eliminar';

  @override
  String get probeCh1 => 'Sonda CH1';

  @override
  String get probeCh2 => 'Sonda CH2';

  @override
  String get rotateAction => 'Rotar';

  @override
  String get oscilloscopeTitle => 'Osciloscopio';

  @override
  String get fftTitle => 'Espectro FFT';

  @override
  String get xyMode => 'Modo X-Y';

  @override
  String get timeDomainMode => 'Tiempo';

  @override
  String get multimeterTitle => 'Multímetro';

  @override
  String get bodePlotterTitle => 'Trazador de Bode';

  @override
  String get logicConverterTitle => 'Conversor Lógico';

  @override
  String get logicAnalyzerTitle => 'Analizador Lógico';

  @override
  String get propertiesTitle => 'Propiedades';

  @override
  String get instrumentsTab => 'Instrumentos';

  @override
  String get undoAction => 'Deshacer';

  @override
  String get redoAction => 'Rehacer';

  @override
  String get deleteAction => 'Eliminar';

  @override
  String get importAction => 'Importar';

  @override
  String get exportAction => 'Exportar';

  @override
  String get exportCir => 'Importar / Exportar';

  @override
  String get pasteOrOpenHint =>
      'Pega el texto abajo o abre un archivo y pulsa Cargar.';

  @override
  String get jsonTab => 'JSON';

  @override
  String get spiceCirTab => 'SPICE .cir';

  @override
  String get bomCsvTab => 'BOM / CSV';

  @override
  String get boxSelectTool => 'Caja';

  @override
  String get fitViewAction => 'Ajustar';

  @override
  String get loadButton => 'Cargar';

  @override
  String get saveFileButton => 'Guardar Archivo';

  @override
  String get loadFileButton => 'Abrir Archivo';

  @override
  String get filePathHint => 'Ruta del archivo (.json / .cir / .csv)';

  @override
  String get copyButton => 'Copiar';

  @override
  String get closeButton => 'Cerrar';

  @override
  String get catPowerSources => 'Energía y Fuentes';

  @override
  String get catPassives => 'Pasivos';

  @override
  String get catSwitchesLoads => 'Interruptores y Cargas';

  @override
  String get catDiodesLeds => 'Diodos y LEDs';

  @override
  String get catTransistors => 'Transistores';

  @override
  String get catAnalogIcs => 'CI Analógicos';

  @override
  String get catLogicGates => 'Puertas Lógicas';

  @override
  String get catDigitalIcs => 'CI Digitales';

  @override
  String get catMetersIo => 'Medidores y E/S';

  @override
  String get makeSubcircuitAction => 'Crear IC';

  @override
  String get buzzerAudioTooltip => 'Audio del Zumbador';

  @override
  String get compResistor => 'Resistencia';

  @override
  String get compCapacitor => 'Condensador';

  @override
  String get compInductor => 'Bobina';

  @override
  String get compPotentiometer => 'Potenciómetro';

  @override
  String get compSwitch => 'Interruptor SPST';

  @override
  String get compSwitchSpdt => 'Conmutador SPDT';

  @override
  String get compPushbutton => 'Pulsador';

  @override
  String get compRelay => 'Relé (NA)';

  @override
  String get compLamp => 'Lámpara';

  @override
  String get compFuse => 'Fusible';

  @override
  String get compDcSource => 'Voltaje DC';

  @override
  String get compDcCurrent => 'Corriente DC';

  @override
  String get compAcSource => 'Voltaje AC';

  @override
  String get compFuncGen => 'Generador de Funciones';

  @override
  String get compGround => 'Tierra';

  @override
  String get compDiode => 'Diodo';

  @override
  String get compZener => 'Diodo Zener';

  @override
  String get compLed => 'LED';

  @override
  String get compOpAmp => 'Amplificador Op.';

  @override
  String get compNpnBjt => 'BJT NPN';

  @override
  String get compPnpBjt => 'BJT PNP';

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
  String get compTransformer => 'Transformador';

  @override
  String get compAndGate => 'Puerta AND';

  @override
  String get compOrGate => 'Puerta OR';

  @override
  String get compNotGate => 'Puerta NOT';

  @override
  String get compNandGate => 'Puerta NAND';

  @override
  String get compNorGate => 'Puerta NOR';

  @override
  String get compXorGate => 'Puerta XOR';

  @override
  String get compXnorGate => 'Puerta XNOR';

  @override
  String get compDFlipFlop => 'Biestable D';

  @override
  String get compLogicProbe => 'Sonda Lógica';

  @override
  String get compTimer555 => 'Temporizador 555';

  @override
  String get compSevenSeg => 'Display 7 Seg';

  @override
  String get compWordGen => 'Generador de Palabras';

  @override
  String get compClock => 'Reloj';

  @override
  String get faultLabel => 'Inyección de Fallos';

  @override
  String get faultNone => 'Ninguno';

  @override
  String get faultOpen => 'Abierto';

  @override
  String get faultShort => 'Corto';

  @override
  String get faultLeaky => 'Fuga';

  @override
  String get presetLabel => 'Preajustes';

  @override
  String get presetRcFilter => 'Filtro Paso Bajo RC';

  @override
  String get presetRectifier => 'Rectificador de Diodo';

  @override
  String get presetOpAmp => 'Op-Amp Inversor';

  @override
  String get presetBjtSwitch => 'Interruptor LED BJT';

  @override
  String get presetDigitalXor => 'XOR Digital';

  @override
  String get presetDffDivider => 'Divisor de Frec. D-FF';

  @override
  String get presetTimer555 => 'Astable 555';

  @override
  String get presetWordGen => 'Contador Hex 4 Bits';

  @override
  String get compOptocoupler => 'Optoacoplador';

  @override
  String get presetOptocoupler => 'Aislamiento Optoacoplador';

  @override
  String get compSchmittTrigger => 'Disparador Schmitt';

  @override
  String get compCounter4Bit => 'Contador Binario';

  @override
  String get presetSchmittCounter => 'Contador Schmitt Trigger';

  @override
  String get dcSweepTitle => 'Barrido DC';

  @override
  String get runDcSweep => 'Ejecutar Barrido DC';

  @override
  String get probeCh3 => 'CH3';

  @override
  String get probeCh4 => 'CH4';

  @override
  String get themeToggleTooltip => 'Cambiar Tema Claro/Oscuro';

  @override
  String get duplicateAction => 'Duplicar';

  @override
  String get showValuesLabel => 'Etiquetas';

  @override
  String get showVoltagesLabel => 'Nodo V';

  @override
  String get showFlowLabel => 'Flujo';

  @override
  String get runAcSweep => 'Ejecutar Barrido AC';

  @override
  String get buildCircuitButton => 'Construir Circuito';

  @override
  String get powerLabel => 'Potencia';

  @override
  String get voltageDropLabel => 'Comp ΔV';

  @override
  String get cutoffFreqLabel => 'f(-3dB)';

  @override
  String get variablesLabel => 'Entradas';

  @override
  String get booleanExprLabel => 'SOP Simplificado';

  @override
  String get dcVoltsLabel => 'DC V';

  @override
  String get acRmsLabel => 'AC RMS';

  @override
  String get minMaxLabel => 'Mín / Máx';

  @override
  String get currentLabel => 'Corriente';

  @override
  String get magnitudeDbLabel => 'Magnitud (dB)';

  @override
  String get phaseDegLabel => 'Fase (deg)';

  @override
  String get triggerLevelLabel => 'Disparo';

  @override
  String get selectHint =>
      'Toca un componente en el lienzo para editar propiedades.';

  @override
  String get paramVolts => 'V';

  @override
  String get paramAmps => 'I (A)';

  @override
  String get paramAmpPeak => 'Vp';

  @override
  String get paramFreqHz => 'Hz';

  @override
  String get paramShape => 'Forma';

  @override
  String get paramDcOffset => 'DC';

  @override
  String get paramVHigh => 'Valto';

  @override
  String get paramOhms => 'Ohm';

  @override
  String get paramWiper => 'Cursor';

  @override
  String get paramFarads => 'F';

  @override
  String get paramHenrys => 'H';

  @override
  String get paramSwitchState => 'Estado';

  @override
  String get paramMaxCurrent => 'Imáx';

  @override
  String get paramZenerVolts => 'Vz';

  @override
  String get paramGain => 'Ganancia';

  @override
  String get paramBeta => 'Beta';

  @override
  String get paramVth => 'Vth';

  @override
  String get paramPhaseDeg => 'Fase';

  @override
  String get paramDuty => 'Ciclo';

  @override
  String get paramGm => 'gm (S)';

  @override
  String get paramRatio => 'Relación n';

  @override
  String get paramRm => 'rm (Ohm)';

  @override
  String get wordGenPatternLabel => 'Patrón Hex (16 hex, paso 0 = LSB)';

  @override
  String get errInvalidImport => 'No se pudo cargar el texto del circuito.';

  @override
  String vPerDivLabel(String v) {
    return '$v V/div';
  }

  @override
  String get errMissingGround =>
      'El circuito requiere al menos un nodo Tierra (GND).';

  @override
  String errFloatingNode(int nodeId) {
    return 'Nodo flotante detectado (Nodo $nodeId).';
  }

  @override
  String get errSingularMatrix =>
      'Matriz de circuito singular (revisa lazos de fuentes de tensión).';

  @override
  String get errConvergenceFailed => 'La simulación no convergió.';

  @override
  String errGeneric(int code) {
    return 'Error de simulación ($code).';
  }

  @override
  String get errInvalidParam => 'Valor de parámetro de componente no válido.';

  @override
  String get errUnknownComponent =>
      'Referencia a componente desconocida en la simulación.';

  @override
  String get errInvalidNetlist => 'Lista de conexiones del circuito no válida.';

  @override
  String get errNullHandle => 'El motor de simulación no está disponible.';

  @override
  String get errEmptyCircuit => 'Añade componentes para simular.';

  @override
  String get newCanvasAction => 'Nuevo / Limpiar lienzo';

  @override
  String get splitInstrumentsAction => 'Dividir instrumentos';

  @override
  String get filterComponentsHint => 'Filtrar componentes...';

  @override
  String get partsLibraryTitle => 'Biblioteca de piezas';

  @override
  String get subcircuitsTitle => 'Subcircuitos';

  @override
  String get unsavedChangesTitle => 'Cambios sin guardar';

  @override
  String get discardAction => 'Descartar';

  @override
  String get cancelAction => 'Cancelar';

  @override
  String get addNoteAction => 'Añadir nota esquemática';

  @override
  String get editNoteAction => 'Editar nota';

  @override
  String get restoreAutoSaveAction => 'Restaurar autoguardado';

  @override
  String get spectrumTitle => 'Espectro';

  @override
  String get wordGenShortTitle => 'Gen. Palabras';

  @override
  String get noteLabel => 'Nota';

  @override
  String get alignHAction => 'Alinear H';

  @override
  String get alignVAction => 'Alinear V';

  @override
  String get flipHAction => 'Voltear H';

  @override
  String get flipVAction => 'Voltear V';

  @override
  String get singleStepAction => 'Paso único';

  @override
  String get helpShortcutsTooltip => 'Ayuda y atajos (?)';

  @override
  String fpsLabel(int fps) {
    return '$fps Hz';
  }

  @override
  String get ivCurveAction => 'Curva I-V';

  @override
  String get ivCurveNoDcSource =>
      'Añade una fuente DC para trazar una curva I-V.';
}
