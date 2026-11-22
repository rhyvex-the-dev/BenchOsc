part of 'circuit_doc.dart';

enum CompCategory { sources, passive, semiconductors, digital, meters }

enum CompKind {
  ground,
  dcSource,
  dcCurrent,
  acSource,
  acCurrent,
  funcGen,
  pulseVoltage,
  pwlSource,
  clock,
  powerRail,
  netPort,
  resistor,
  potentiometer,
  capacitor,
  polarizedCapacitor,
  varCapacitor,
  inductor,
  varInductor,
  coupledInductor,
  crystal,
  switchSpst,
  switchSpdt,
  pushbutton,
  vControlledSwitch,
  iControlledSwitch,
  relay,
  relaySpdt,
  relayDpdt,
  lamp,
  fuse,
  buzzer,
  dcMotor,
  diode,
  zener,
  schottkyDiode,
  varactorDiode,
  led,
  rgbLed,
  barGraphLed,
  bridgeRectifier,
  optocoupler,
  opAmp,
  comparatorOc,
  instAmp,
  voltageReg,
  vco,
  analogMultiplier,
  sampleHold,
  npnBjt,
  pnpBjt,
  nmos,
  pmos,
  njfet,
  pjfet,
  scr,
  triac,
  diac,
  igbt,
  vcvs,
  vccs,
  cccs,
  ccvs,
  transformer,
  centerTapTransformer,
  andGate,
  orGate,
  notGate,
  bufferGate,
  triStateBuffer,
  nandGate,
  norGate,
  xorGate,
  xnorGate,
  and3Gate,
  or3Gate,
  nand4Gate,
  srLatch,
  dFlipFlop,
  dFlipFlopAsync,
  jkFlipFlop,
  tFlipFlop,
  logicProbe,
  timer555,
  sevenSeg,
  wordGen,
  schmittTrigger,
  counter4Bit,
  counter4BitFull,
  shiftReg4Bit,
  mux4To1,
  demux1To4,
  decoder2To4,
  fullAdder,
  magComparator,
  alu2Bit,
  adc4Bit,
  dac4Bit,
  hexKeypad,
  dipSwitch4,
  voltmeter,
  ammeter,
  wattmeter,
  logicIndicator,
  subcircuit,
}

enum FaultType { none, open, short, leaky }

enum PresetKind {
  rcFilter,
  rectifier,
  opAmp,
  bjtSwitch,
  digitalXor,
  dffDivider,
  timer555Astable,
  wordGenCounter,
  optocouplerIso,
  schmittCounter,
}

enum ParamKey {
  volts,
  amps,
  ampPeak,
  freqHz,
  period,
  phaseDeg,
  shape,
  dcOffset,
  duty,
  vHigh,
  ohms,
  wiper,
  farads,
  henrys,
  switchState,
  maxCurrent,
  zenerVolts,
  gain,
  gm,
  rm,
  ratio,
  beta,
  vth,
}

class ParamSpec {
  final int paramIndex;
  final ParamKey key;
  final double min;
  final double max;
  final bool logScale;
  const ParamSpec(this.paramIndex, this.key, this.min, this.max, {this.logScale = false});
}

class CompMeta {
  final CompCategory category;
  final int ffiType;
  final List<Offset> pinOffsets;
  final List<double> defaults;
  final List<ParamSpec> paramSpecs;

  const CompMeta({
    required this.category,
    required this.ffiType,
    required this.pinOffsets,
    required this.defaults,
    required this.paramSpecs,
  });
}

const Map<CompKind, CompMeta> kCompMeta = {
  CompKind.ground: CompMeta(
    category: CompCategory.sources,
    ffiType: 0,
    pinOffsets: [Offset(0, -1)],
    defaults: [],
    paramSpecs: [],
  ),
  CompKind.dcSource: CompMeta(
    category: CompCategory.sources,
    ffiType: 10,
    pinOffsets: [Offset(0, -2), Offset(0, 2)],
    defaults: [5.0],
    paramSpecs: [ParamSpec(0, ParamKey.volts, -250, 250)],
  ),
  CompKind.dcCurrent: CompMeta(
    category: CompCategory.sources,
    ffiType: 13,
    pinOffsets: [Offset(0, -2), Offset(0, 2)],
    defaults: [0.01],
    paramSpecs: [ParamSpec(0, ParamKey.amps, -50, 50)],
  ),
  CompKind.acSource: CompMeta(
    category: CompCategory.sources,
    ffiType: 11,
    pinOffsets: [Offset(0, -2), Offset(0, 2)],
    defaults: [5.0, 100.0, 0.0, 0.0],
    paramSpecs: [
      ParamSpec(0, ParamKey.ampPeak, 0.01, 250, logScale: true),
      ParamSpec(1, ParamKey.freqHz, 0.1, 1e6, logScale: true),
      ParamSpec(2, ParamKey.phaseDeg, -180, 180),
      ParamSpec(3, ParamKey.dcOffset, -100, 100),
    ],
  ),
  CompKind.funcGen: CompMeta(
    category: CompCategory.sources,
    ffiType: 12,
    pinOffsets: [Offset(0, -2), Offset(0, 2)],
    defaults: [0.0, 5.0, 120.0, 0.0, 0.5], // shape, amp, freq, offset, duty
    paramSpecs: [
      ParamSpec(0, ParamKey.shape, 0, 2),
      ParamSpec(1, ParamKey.ampPeak, 0.01, 250, logScale: true),
      ParamSpec(2, ParamKey.freqHz, 0.1, 1e6, logScale: true),
      ParamSpec(3, ParamKey.dcOffset, -100, 100),
      ParamSpec(4, ParamKey.duty, 0.05, 0.95),
    ],
  ),
  CompKind.clock: CompMeta(
    category: CompCategory.digital,
    ffiType: 36,
    pinOffsets: [Offset(2, 0), Offset(0, 2)],
    defaults: [100.0, 5.0, 50.0],
    paramSpecs: [
      ParamSpec(0, ParamKey.freqHz, 0.1, 1e6, logScale: true),
      ParamSpec(1, ParamKey.vHigh, 1.0, 24.0),
    ],
  ),
  CompKind.resistor: CompMeta(
    category: CompCategory.passive,
    ffiType: 1,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [1000.0],
    paramSpecs: [ParamSpec(0, ParamKey.ohms, 0.01, 1e8, logScale: true)],
  ),
  CompKind.potentiometer: CompMeta(
    category: CompCategory.passive,
    ffiType: 2,
    pinOffsets: [Offset(0, -2), Offset(0, 2), Offset(2, 0)],
    defaults: [2000.0, 0.5],
    paramSpecs: [
      ParamSpec(0, ParamKey.ohms, 1, 1e7, logScale: true),
      ParamSpec(1, ParamKey.wiper, 0.001, 0.999),
    ],
  ),
  CompKind.capacitor: CompMeta(
    category: CompCategory.passive,
    ffiType: 3,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [1e-6, double.nan],
    paramSpecs: [ParamSpec(0, ParamKey.farads, 1e-12, 10.0, logScale: true)],
  ),
  CompKind.inductor: CompMeta(
    category: CompCategory.passive,
    ffiType: 4,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [1e-2, double.nan],
    paramSpecs: [ParamSpec(0, ParamKey.henrys, 1e-7, 100.0, logScale: true)],
  ),
  CompKind.switchSpst: CompMeta(
    category: CompCategory.passive,
    ffiType: 5,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [1.0, 1e-3, 1e9],
    paramSpecs: [ParamSpec(0, ParamKey.switchState, 0, 1)],
  ),
  CompKind.switchSpdt: CompMeta(
    category: CompCategory.passive,
    ffiType: 7,
    pinOffsets: [Offset(-2, 0), Offset(2, -1), Offset(2, 1)], // common, throwA, throwB
    defaults: [0.0, 1e-3, 1e9],
    paramSpecs: [ParamSpec(0, ParamKey.switchState, 0, 1)],
  ),
  CompKind.pushbutton: CompMeta(
    category: CompCategory.passive,
    ffiType: 45,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [0.0, 1e-3, 1e9],
    paramSpecs: [ParamSpec(0, ParamKey.switchState, 0, 1)],
  ),
  CompKind.relay: CompMeta(
    category: CompCategory.passive,
    ffiType: 43,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, -1), Offset(2, 1)],
    defaults: [100.0, 3.0, 1e-3, 1e9],
    paramSpecs: [
      ParamSpec(0, ParamKey.ohms, 1, 1e5, logScale: true),
      ParamSpec(1, ParamKey.volts, 0.5, 240.0),
    ],
  ),
  CompKind.lamp: CompMeta(
    category: CompCategory.passive,
    ffiType: 44,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [50.0],
    paramSpecs: [ParamSpec(0, ParamKey.ohms, 0.5, 1e5, logScale: true)],
  ),
  CompKind.fuse: CompMeta(
    category: CompCategory.passive,
    ffiType: 6,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [0.5, 0.05],
    paramSpecs: [ParamSpec(0, ParamKey.maxCurrent, 0.001, 100.0, logScale: true)],
  ),
  CompKind.diode: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 20,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [1e-12, 1.5, 0.0],
    paramSpecs: [],
  ),
  CompKind.zener: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 20,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [1e-12, 1.5, 5.1],
    paramSpecs: [ParamSpec(2, ParamKey.zenerVolts, 1.2, 200.0)],
  ),
  CompKind.led: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 21,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [1e-18, 2.0, 0.02],
    paramSpecs: [],
  ),
  CompKind.optocoupler: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 47,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, -1), Offset(2, 1)], // A, K, C, E
    defaults: [1.0, 1e-16, 1.8],
    paramSpecs: [ParamSpec(0, ParamKey.gain, 0.05, 50.0, logScale: true)],
  ),
  CompKind.opAmp: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 22,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, 0)],
    defaults: [1e5, 15.0, -15.0, 50.0],
    paramSpecs: [ParamSpec(0, ParamKey.gain, 10, 1e7, logScale: true)],
  ),
  CompKind.npnBjt: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 23,
    pinOffsets: [Offset(1, -2), Offset(-2, 0), Offset(1, 2)], // C, B, E
    defaults: [1e-14, 100.0, 1.0],
    paramSpecs: [ParamSpec(1, ParamKey.beta, 5, 2000, logScale: true)],
  ),
  CompKind.pnpBjt: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 24,
    pinOffsets: [Offset(1, -2), Offset(-2, 0), Offset(1, 2)], // C, B, E
    defaults: [1e-14, 100.0, 1.0],
    paramSpecs: [ParamSpec(1, ParamKey.beta, 5, 2000, logScale: true)],
  ),
  CompKind.nmos: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 25,
    pinOffsets: [Offset(1, -2), Offset(-2, 0), Offset(1, 2)], // D, G, S
    defaults: [2e-3, 1.0, 0.0],
    paramSpecs: [ParamSpec(1, ParamKey.vth, 0.1, 20.0)],
  ),
  CompKind.pmos: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 26,
    pinOffsets: [Offset(1, -2), Offset(-2, 0), Offset(1, 2)], // D, G, S
    defaults: [2e-3, 1.0, 0.0],
    paramSpecs: [ParamSpec(1, ParamKey.vth, 0.1, 20.0)],
  ),
  CompKind.vcvs: CompMeta(
    category: CompCategory.sources,
    ffiType: 14,
    pinOffsets: [Offset(2, -1), Offset(2, 1), Offset(-2, -1), Offset(-2, 1)],
    defaults: [2.0],
    paramSpecs: [ParamSpec(0, ParamKey.gain, -1000, 1000)],
  ),
  CompKind.vccs: CompMeta(
    category: CompCategory.sources,
    ffiType: 15,
    pinOffsets: [Offset(2, -1), Offset(2, 1), Offset(-2, -1), Offset(-2, 1)],
    defaults: [0.002],
    paramSpecs: [ParamSpec(0, ParamKey.gm, -10.0, 10.0)],
  ),
  CompKind.cccs: CompMeta(
    category: CompCategory.sources,
    ffiType: 16,
    pinOffsets: [Offset(2, -1), Offset(2, 1), Offset(-2, -1), Offset(-2, 1)],
    defaults: [2.0],
    paramSpecs: [ParamSpec(0, ParamKey.gain, -1000, 1000)],
  ),
  CompKind.ccvs: CompMeta(
    category: CompCategory.sources,
    ffiType: 17,
    pinOffsets: [Offset(2, -1), Offset(2, 1), Offset(-2, -1), Offset(-2, 1)],
    defaults: [1000.0],
    paramSpecs: [ParamSpec(0, ParamKey.rm, -1e6, 1e6)],
  ),
  CompKind.transformer: CompMeta(
    category: CompCategory.passive,
    ffiType: 42,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, -1), Offset(2, 1)],
    defaults: [2.0],
    paramSpecs: [ParamSpec(0, ParamKey.ratio, 0.01, 100.0, logScale: true)],
  ),
  CompKind.andGate: CompMeta(
    category: CompCategory.digital,
    ffiType: 30,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, 0)],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.orGate: CompMeta(
    category: CompCategory.digital,
    ffiType: 31,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, 0)],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.notGate: CompMeta(
    category: CompCategory.digital,
    ffiType: 32,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.nandGate: CompMeta(
    category: CompCategory.digital,
    ffiType: 33,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, 0)],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.norGate: CompMeta(
    category: CompCategory.digital,
    ffiType: 34,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, 0)],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.xorGate: CompMeta(
    category: CompCategory.digital,
    ffiType: 35,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, 0)],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.xnorGate: CompMeta(
    category: CompCategory.digital,
    ffiType: 37,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, 0)],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.dFlipFlop: CompMeta(
    category: CompCategory.digital,
    ffiType: 38,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, -1), Offset(2, 1)], // D, CLK, Q, Qn
    defaults: [5.0, 50.0],
    paramSpecs: [ParamSpec(0, ParamKey.vHigh, 1.0, 24.0)],
  ),
  CompKind.logicProbe: CompMeta(
    category: CompCategory.digital,
    ffiType: 39,
    pinOffsets: [Offset(-1, 0)],
    defaults: [1e7],
    paramSpecs: [],
  ),
  CompKind.timer555: CompMeta(
    category: CompCategory.digital,
    ffiType: 40,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, -1), Offset(2, 1)], // TRIG, THRS, DISCH, OUT
    defaults: [5.0, 50.0],
    paramSpecs: [ParamSpec(0, ParamKey.vHigh, 1.0, 24.0)],
  ),
  CompKind.sevenSeg: CompMeta(
    category: CompCategory.digital,
    ffiType: 41,
    pinOffsets: [Offset(-2, -2), Offset(-2, -1), Offset(-2, 0), Offset(-2, 1)], // D3..D0
    defaults: [1e7],
    paramSpecs: [],
  ),
  CompKind.wordGen: CompMeta(
    category: CompCategory.digital,
    ffiType: 46,
    pinOffsets: [Offset(2, -2), Offset(2, -1), Offset(2, 0), Offset(2, 1)], // B3..B0
    defaults: [50.0, 0.0, 5.0, 50.0],
    paramSpecs: [
      ParamSpec(0, ParamKey.freqHz, 0.1, 1e6, logScale: true),
      ParamSpec(2, ParamKey.vHigh, 1.0, 24.0),
    ],
  ),
  CompKind.schmittTrigger: CompMeta(
    category: CompCategory.digital,
    ffiType: 48,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, 0)], // in+, in-, out
    defaults: [0.5, 5.0, 50.0],
    paramSpecs: [
      ParamSpec(0, ParamKey.vth, 0.01, 12.0),
      ParamSpec(1, ParamKey.vHigh, 1.0, 24.0),
    ],
  ),
  CompKind.counter4Bit: CompMeta(
    category: CompCategory.digital,
    ffiType: 49,
    pinOffsets: [Offset(-2, 0), Offset(2, -1), Offset(2, 0), Offset(2, 1)], // clk, q2, q1, q0
    defaults: [5.0, 50.0],
    paramSpecs: [ParamSpec(0, ParamKey.vHigh, 1.0, 24.0)],
  ),
  CompKind.acCurrent: CompMeta(
    category: CompCategory.sources,
    ffiType: 50,
    pinOffsets: [Offset(0, -2), Offset(0, 2)],
    defaults: [0.01, 100.0, 0.0, 0.0],
    paramSpecs: [
      ParamSpec(0, ParamKey.amps, -50, 50),
      ParamSpec(1, ParamKey.freqHz, 0.1, 1e6, logScale: true),
      ParamSpec(2, ParamKey.phaseDeg, -180, 180),
      ParamSpec(3, ParamKey.dcOffset, -50, 50),
    ],
  ),
  CompKind.pulseVoltage: CompMeta(
    category: CompCategory.sources,
    ffiType: 51,
    pinOffsets: [Offset(0, -2), Offset(0, 2)],
    defaults: [0.0, 5.0, 0.0, 1e-6, 1e-6, 5e-4, 1e-3],
    paramSpecs: [
      ParamSpec(0, ParamKey.volts, -250, 250),
      ParamSpec(1, ParamKey.vHigh, 0.1, 250),
      ParamSpec(6, ParamKey.period, 1e-6, 1.0, logScale: true),
    ],
  ),
  CompKind.pwlSource: CompMeta(
    category: CompCategory.sources,
    ffiType: 91,
    pinOffsets: [Offset(0, -2), Offset(0, 2)],
    defaults: [0.0, 0.0, 1e-3, 5.0, 2e-3, 5.0, 3e-3, 0.0],
    paramSpecs: [ParamSpec(3, ParamKey.vHigh, 0.1, 250)],
  ),
  CompKind.powerRail: CompMeta(
    category: CompCategory.sources,
    ffiType: 10,
    pinOffsets: [Offset(0, 1)],
    defaults: [5.0],
    paramSpecs: [ParamSpec(0, ParamKey.volts, -250, 250)],
  ),
  CompKind.netPort: CompMeta(
    category: CompCategory.sources,
    ffiType: -2,
    pinOffsets: [Offset(-1, 0)],
    defaults: [],
    paramSpecs: [],
  ),
  CompKind.vControlledSwitch: CompMeta(
    category: CompCategory.passive,
    ffiType: 52,
    pinOffsets: [Offset(-2, -1), Offset(2, -1), Offset(-2, 1), Offset(2, 1)],
    defaults: [2.5, 1.0, 1e-2, 1e9],
    paramSpecs: [ParamSpec(0, ParamKey.vth, -50, 50)],
  ),
  CompKind.iControlledSwitch: CompMeta(
    category: CompCategory.passive,
    ffiType: 53,
    pinOffsets: [Offset(-2, -1), Offset(2, -1), Offset(-2, 1), Offset(2, 1)],
    defaults: [0.01, 0.002, 1e-2, 1e9],
    paramSpecs: [ParamSpec(0, ParamKey.maxCurrent, 1e-4, 50, logScale: true)],
  ),
  CompKind.polarizedCapacitor: CompMeta(
    category: CompCategory.passive,
    ffiType: 3,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [1e-5, double.nan],
    paramSpecs: [ParamSpec(0, ParamKey.farads, 1e-12, 10.0, logScale: true)],
  ),
  CompKind.varCapacitor: CompMeta(
    category: CompCategory.passive,
    ffiType: 3,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [1e-9, double.nan],
    paramSpecs: [ParamSpec(0, ParamKey.farads, 1e-12, 1.0, logScale: true)],
  ),
  CompKind.varInductor: CompMeta(
    category: CompCategory.passive,
    ffiType: 4,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [1e-3, double.nan],
    paramSpecs: [ParamSpec(0, ParamKey.henrys, 1e-7, 100.0, logScale: true)],
  ),
  CompKind.coupledInductor: CompMeta(
    category: CompCategory.passive,
    ffiType: 85,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, -1), Offset(2, 1)],
    defaults: [1e-2, 1e-2, 0.9],
    paramSpecs: [
      ParamSpec(0, ParamKey.henrys, 1e-7, 100.0, logScale: true),
      ParamSpec(2, ParamKey.ratio, -0.999, 0.999),
    ],
  ),
  CompKind.crystal: CompMeta(
    category: CompCategory.passive,
    ffiType: 88,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [50.0, 1e-2, 1e-13, 5e-12],
    paramSpecs: [ParamSpec(0, ParamKey.ohms, 1, 5000, logScale: true)],
  ),
  CompKind.centerTapTransformer: CompMeta(
    category: CompCategory.passive,
    ffiType: 86,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, -1), Offset(2, 0), Offset(2, 1)],
    defaults: [2.0],
    paramSpecs: [ParamSpec(0, ParamKey.ratio, 0.01, 100.0, logScale: true)],
  ),
  CompKind.relaySpdt: CompMeta(
    category: CompCategory.passive,
    ffiType: 87,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, 0), Offset(2, -1), Offset(2, 1)],
    defaults: [100.0, 3.0, 1e-3, 1e9],
    paramSpecs: [
      ParamSpec(0, ParamKey.ohms, 1, 1e5, logScale: true),
      ParamSpec(1, ParamKey.volts, 0.5, 240.0),
    ],
  ),
  CompKind.relayDpdt: CompMeta(
    category: CompCategory.passive,
    ffiType: 87,
    pinOffsets: [
      Offset(-2, -2), Offset(-2, -1),
      Offset(2, -2), Offset(2, -1), Offset(2, 0),
      Offset(-2, 1), Offset(2, 1), Offset(2, 2),
    ],
    defaults: [100.0, 3.0, 1e-3, 1e9],
    paramSpecs: [
      ParamSpec(0, ParamKey.ohms, 1, 1e5, logScale: true),
      ParamSpec(1, ParamKey.volts, 0.5, 240.0),
    ],
  ),
  CompKind.buzzer: CompMeta(
    category: CompCategory.passive,
    ffiType: 1,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [32.0, 1000.0],
    paramSpecs: [
      ParamSpec(0, ParamKey.ohms, 4, 1000, logScale: true),
      ParamSpec(1, ParamKey.freqHz, 120, 4000, logScale: true),
    ],
  ),
  CompKind.dcMotor: CompMeta(
    category: CompCategory.passive,
    ffiType: 89,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [5.0, 0.1, 1e9],
    paramSpecs: [
      ParamSpec(0, ParamKey.ohms, 0.2, 500, logScale: true),
      ParamSpec(1, ParamKey.gain, 0.0, 5.0),
    ],
  ),
  CompKind.schottkyDiode: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 20,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [1e-7, 1.1, 0.0],
    paramSpecs: [],
  ),
  CompKind.varactorDiode: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 94,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [30e-12, 0.7, 0.5, 1e-12],
    paramSpecs: [ParamSpec(0, ParamKey.farads, 1e-12, 1e-8, logScale: true)],
  ),
  CompKind.rgbLed: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 93,
    pinOffsets: [Offset(-2, -1), Offset(-2, 0), Offset(-2, 1), Offset(2, 0)],
    defaults: [1e-18, 2.0],
    paramSpecs: [],
  ),
  CompKind.barGraphLed: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 92,
    pinOffsets: [Offset(-2, -2), Offset(-2, -1), Offset(-2, 0), Offset(-2, 1), Offset(2, 0)],
    defaults: [1e-18, 2.0],
    paramSpecs: [],
  ),
  CompKind.bridgeRectifier: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 54,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, -1), Offset(2, 1)],
    defaults: [1e-12, 1.5],
    paramSpecs: [],
  ),
  CompKind.njfet: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 55,
    pinOffsets: [Offset(1, -2), Offset(-2, 0), Offset(1, 2)],
    defaults: [1e-3, -2.0, 0.01],
    paramSpecs: [ParamSpec(1, ParamKey.vth, -10.0, -0.2)],
  ),
  CompKind.pjfet: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 56,
    pinOffsets: [Offset(1, -2), Offset(-2, 0), Offset(1, 2)],
    defaults: [1e-3, -2.0, 0.01],
    paramSpecs: [ParamSpec(1, ParamKey.vth, -10.0, -0.2)],
  ),
  CompKind.scr: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 57,
    pinOffsets: [Offset(-2, 0), Offset(2, 0), Offset(0, 2)],
    defaults: [0.005, 100.0, 0.2, 1e8],
    paramSpecs: [],
  ),
  CompKind.triac: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 58,
    pinOffsets: [Offset(-2, 0), Offset(2, 0), Offset(0, 2)],
    defaults: [0.005, 100.0, 0.2, 1e8],
    paramSpecs: [],
  ),
  CompKind.diac: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 59,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [30.0, 2.0, 1e8],
    paramSpecs: [],
  ),
  CompKind.igbt: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 60,
    pinOffsets: [Offset(1, -2), Offset(-2, 0), Offset(1, 2)],
    defaults: [2.0, 4.0, 0.2],
    paramSpecs: [ParamSpec(1, ParamKey.vth, 0.5, 15.0)],
  ),
  CompKind.voltageReg: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 61,
    pinOffsets: [Offset(-2, 0), Offset(0, 2), Offset(2, 0)],
    defaults: [5.0, 0.2],
    paramSpecs: [ParamSpec(0, ParamKey.volts, 1.25, 48.0)],
  ),
  CompKind.comparatorOc: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 62,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, 0)],
    defaults: [5.0, 1000.0],
    paramSpecs: [ParamSpec(0, ParamKey.vHigh, 1.8, 36.0)],
  ),
  CompKind.instAmp: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 63,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, 0)],
    defaults: [10.0, 15.0, -15.0, 50.0],
    paramSpecs: [ParamSpec(0, ParamKey.gain, 1.0, 10000.0, logScale: true)],
  ),
  CompKind.vco: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 64,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [100.0, 50.0, 5.0, 50.0],
    paramSpecs: [
      ParamSpec(0, ParamKey.freqHz, 0.1, 1e5, logScale: true),
      ParamSpec(1, ParamKey.gain, 0.0, 1000.0),
    ],
  ),
  CompKind.analogMultiplier: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 65,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, 0)],
    defaults: [0.1, 50.0],
    paramSpecs: [ParamSpec(0, ParamKey.gain, -10.0, 10.0)],
  ),
  CompKind.sampleHold: CompMeta(
    category: CompCategory.semiconductors,
    ffiType: 66,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, 0)],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.bufferGate: CompMeta(
    category: CompCategory.digital,
    ffiType: 67,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.triStateBuffer: CompMeta(
    category: CompCategory.digital,
    ffiType: 67,
    pinOffsets: [Offset(-2, 0), Offset(0, -2), Offset(2, 0)],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.and3Gate: CompMeta(
    category: CompCategory.digital,
    ffiType: 68,
    pinOffsets: [Offset(-2, -1), Offset(-2, 0), Offset(-2, 1), Offset(2, 0)],
    defaults: [0.0, 3.0, 5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.or3Gate: CompMeta(
    category: CompCategory.digital,
    ffiType: 68,
    pinOffsets: [Offset(-2, -1), Offset(-2, 0), Offset(-2, 1), Offset(2, 0)],
    defaults: [1.0, 3.0, 5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.nand4Gate: CompMeta(
    category: CompCategory.digital,
    ffiType: 68,
    pinOffsets: [Offset(-2, -2), Offset(-2, -1), Offset(-2, 0), Offset(-2, 1), Offset(2, 0)],
    defaults: [3.0, 4.0, 5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.srLatch: CompMeta(
    category: CompCategory.digital,
    ffiType: 69,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, -1), Offset(2, 1)],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.jkFlipFlop: CompMeta(
    category: CompCategory.digital,
    ffiType: 70,
    pinOffsets: [Offset(-2, -1), Offset(-2, 0), Offset(-2, 1), Offset(2, -1), Offset(2, 1)],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.tFlipFlop: CompMeta(
    category: CompCategory.digital,
    ffiType: 71,
    pinOffsets: [Offset(-2, -1), Offset(-2, 1), Offset(2, -1), Offset(2, 1)],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.dFlipFlopAsync: CompMeta(
    category: CompCategory.digital,
    ffiType: 72,
    pinOffsets: [
      Offset(-2, -2), Offset(-2, -1), Offset(-2, 0), Offset(-2, 1),
      Offset(2, -1), Offset(2, 1),
    ],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.counter4BitFull: CompMeta(
    category: CompCategory.digital,
    ffiType: 73,
    pinOffsets: [
      Offset(-2, -1), Offset(-2, 0), Offset(-2, 1),
      Offset(2, -2), Offset(2, -1), Offset(2, 0), Offset(2, 1), Offset(2, 2),
    ],
    defaults: [5.0, 50.0],
    paramSpecs: [ParamSpec(0, ParamKey.vHigh, 1.0, 24.0)],
  ),
  CompKind.shiftReg4Bit: CompMeta(
    category: CompCategory.digital,
    ffiType: 74,
    pinOffsets: [
      Offset(-2, -1), Offset(-2, 0), Offset(-2, 1),
      Offset(2, -2), Offset(2, -1), Offset(2, 0), Offset(2, 1),
    ],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.mux4To1: CompMeta(
    category: CompCategory.digital,
    ffiType: 75,
    pinOffsets: [
      Offset(-2, -2), Offset(-2, -1), Offset(-2, 0), Offset(-2, 1),
      Offset(2, -1), Offset(2, 0), Offset(2, 1),
    ],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.demux1To4: CompMeta(
    category: CompCategory.digital,
    ffiType: 76,
    pinOffsets: [
      Offset(-2, -1), Offset(-2, 0), Offset(-2, 1),
      Offset(2, -2), Offset(2, -1), Offset(2, 0), Offset(2, 1),
    ],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.decoder2To4: CompMeta(
    category: CompCategory.digital,
    ffiType: 77,
    pinOffsets: [
      Offset(-2, -1), Offset(-2, 0), Offset(-2, 1),
      Offset(2, -2), Offset(2, -1), Offset(2, 0), Offset(2, 1),
    ],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.fullAdder: CompMeta(
    category: CompCategory.digital,
    ffiType: 78,
    pinOffsets: [Offset(-2, -1), Offset(-2, 0), Offset(-2, 1), Offset(2, -1), Offset(2, 1)],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.magComparator: CompMeta(
    category: CompCategory.digital,
    ffiType: 79,
    pinOffsets: [
      Offset(-2, -2), Offset(-2, -1), Offset(-2, 0), Offset(-2, 1),
      Offset(2, -1), Offset(2, 0), Offset(2, 1),
    ],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.alu2Bit: CompMeta(
    category: CompCategory.digital,
    ffiType: 80,
    pinOffsets: [
      Offset(-2, -2), Offset(-2, -1), Offset(-2, 0), Offset(-2, 1),
      Offset(2, -2), Offset(2, -1), Offset(2, 0), Offset(2, 1),
    ],
    defaults: [5.0, 50.0],
    paramSpecs: [],
  ),
  CompKind.adc4Bit: CompMeta(
    category: CompCategory.digital,
    ffiType: 81,
    pinOffsets: [
      Offset(-2, -1), Offset(-2, 1),
      Offset(2, -2), Offset(2, -1), Offset(2, 0), Offset(2, 1),
    ],
    defaults: [5.0, 5.0, 50.0],
    paramSpecs: [ParamSpec(0, ParamKey.volts, 1.0, 24.0)],
  ),
  CompKind.dac4Bit: CompMeta(
    category: CompCategory.digital,
    ffiType: 82,
    pinOffsets: [
      Offset(-2, -2), Offset(-2, -1), Offset(-2, 0), Offset(-2, 1),
      Offset(2, -1), Offset(2, 1),
    ],
    defaults: [5.0, 50.0],
    paramSpecs: [ParamSpec(0, ParamKey.volts, 1.0, 24.0)],
  ),
  CompKind.hexKeypad: CompMeta(
    category: CompCategory.digital,
    ffiType: 83,
    pinOffsets: [Offset(2, -2), Offset(2, -1), Offset(2, 0), Offset(2, 1)],
    defaults: [5.0, 5.0, 50.0],
    paramSpecs: [ParamSpec(0, ParamKey.shape, 0, 15)],
  ),
  CompKind.dipSwitch4: CompMeta(
    category: CompCategory.digital,
    ffiType: 84,
    pinOffsets: [
      Offset(-2, -2), Offset(2, -2),
      Offset(-2, -1), Offset(2, -1),
      Offset(-2, 0), Offset(2, 0),
      Offset(-2, 1), Offset(2, 1),
    ],
    defaults: [0.0, 1e-3, 1e9],
    paramSpecs: [ParamSpec(0, ParamKey.shape, 0, 15)],
  ),
  CompKind.voltmeter: CompMeta(
    category: CompCategory.meters,
    ffiType: 1,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [1e9],
    paramSpecs: [],
  ),
  CompKind.ammeter: CompMeta(
    category: CompCategory.meters,
    ffiType: 1,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [1e-3],
    paramSpecs: [],
  ),
  CompKind.wattmeter: CompMeta(
    category: CompCategory.meters,
    ffiType: 90,
    pinOffsets: [Offset(-2, -1), Offset(2, -1), Offset(-2, 1), Offset(2, 1)],
    defaults: [1e-3],
    paramSpecs: [],
  ),
  CompKind.logicIndicator: CompMeta(
    category: CompCategory.meters,
    ffiType: 39,
    pinOffsets: [Offset(-1, 0)],
    defaults: [1e7],
    paramSpecs: [],
  ),
  CompKind.subcircuit: CompMeta(
    category: CompCategory.meters,
    ffiType: -3,
    pinOffsets: [Offset(-2, 0), Offset(2, 0)],
    defaults: [],
    paramSpecs: [],
  ),
};

String localizedCompName(AppLocalizations l10n, CompKind kind) {
  return switch (kind) {
    CompKind.ground => l10n.compGround,
    CompKind.dcSource => l10n.compDcSource,
    CompKind.dcCurrent => l10n.compDcCurrent,
    CompKind.acSource => l10n.compAcSource,
    CompKind.funcGen => l10n.compFuncGen,
    CompKind.clock => l10n.compClock,
    CompKind.resistor => l10n.compResistor,
    CompKind.potentiometer => l10n.compPotentiometer,
    CompKind.capacitor => l10n.compCapacitor,
    CompKind.inductor => l10n.compInductor,
    CompKind.switchSpst => l10n.compSwitch,
    CompKind.switchSpdt => l10n.compSwitchSpdt,
    CompKind.pushbutton => l10n.compPushbutton,
    CompKind.relay => l10n.compRelay,
    CompKind.lamp => l10n.compLamp,
    CompKind.fuse => l10n.compFuse,
    CompKind.diode => l10n.compDiode,
    CompKind.zener => l10n.compZener,
    CompKind.led => l10n.compLed,
    CompKind.optocoupler => l10n.compOptocoupler,
    CompKind.opAmp => l10n.compOpAmp,
    CompKind.npnBjt => l10n.compNpnBjt,
    CompKind.pnpBjt => l10n.compPnpBjt,
    CompKind.nmos => l10n.compNmos,
    CompKind.pmos => l10n.compPmos,
    CompKind.vcvs => l10n.compVcvs,
    CompKind.vccs => l10n.compVccs,
    CompKind.cccs => l10n.compCccs,
    CompKind.ccvs => l10n.compCcvs,
    CompKind.transformer => l10n.compTransformer,
    CompKind.andGate => l10n.compAndGate,
    CompKind.orGate => l10n.compOrGate,
    CompKind.notGate => l10n.compNotGate,
    CompKind.nandGate => l10n.compNandGate,
    CompKind.norGate => l10n.compNorGate,
    CompKind.xorGate => l10n.compXorGate,
    CompKind.xnorGate => l10n.compXnorGate,
    CompKind.dFlipFlop => l10n.compDFlipFlop,
    CompKind.logicProbe => l10n.compLogicProbe,
    CompKind.timer555 => l10n.compTimer555,
    CompKind.sevenSeg => l10n.compSevenSeg,
    CompKind.wordGen => l10n.compWordGen,
    CompKind.schmittTrigger => l10n.compSchmittTrigger,
    CompKind.counter4Bit => l10n.compCounter4Bit,
    CompKind.acCurrent => 'AC Current',
    CompKind.pulseVoltage => 'Pulse Voltage',
    CompKind.pwlSource => 'PWL Source',
    CompKind.powerRail => 'Power Rail',
    CompKind.netPort => 'Net Port',
    CompKind.vControlledSwitch => 'V-Ctrl Switch',
    CompKind.iControlledSwitch => 'I-Ctrl Switch',
    CompKind.polarizedCapacitor => 'Electrolytic Cap',
    CompKind.varCapacitor => 'Var Capacitor',
    CompKind.varInductor => 'Var Inductor',
    CompKind.coupledInductor => 'Coupled Inductor',
    CompKind.crystal => 'Crystal',
    CompKind.centerTapTransformer => 'Center-Tap Tx',
    CompKind.relaySpdt => 'Relay (SPDT)',
    CompKind.relayDpdt => 'Relay (DPDT)',
    CompKind.buzzer => 'Buzzer',
    CompKind.dcMotor => 'DC Motor',
    CompKind.schottkyDiode => 'Schottky Diode',
    CompKind.varactorDiode => 'Varactor Diode',
    CompKind.rgbLed => 'RGB LED',
    CompKind.barGraphLed => 'Bar Graph LED',
    CompKind.bridgeRectifier => 'Bridge Rectifier',
    CompKind.njfet => 'N-JFET',
    CompKind.pjfet => 'P-JFET',
    CompKind.scr => 'SCR Thyristor',
    CompKind.triac => 'TRIAC',
    CompKind.diac => 'DIAC',
    CompKind.igbt => 'IGBT',
    CompKind.voltageReg => 'Voltage Reg',
    CompKind.comparatorOc => 'Comparator (OC)',
    CompKind.instAmp => 'Inst. Amp',
    CompKind.vco => 'VCO',
    CompKind.analogMultiplier => 'Multiplier',
    CompKind.sampleHold => 'Sample & Hold',
    CompKind.bufferGate => 'Buffer',
    CompKind.triStateBuffer => 'Tri-State Buf',
    CompKind.and3Gate => '3-In AND',
    CompKind.or3Gate => '3-In OR',
    CompKind.nand4Gate => '4-In NAND',
    CompKind.srLatch => 'SR Latch',
    CompKind.jkFlipFlop => 'JK Flip-Flop',
    CompKind.tFlipFlop => 'T Flip-Flop',
    CompKind.dFlipFlopAsync => 'D-FF (Set/Rst)',
    CompKind.counter4BitFull => '4-Bit Counter+',
    CompKind.shiftReg4Bit => '4-Bit Shift Reg',
    CompKind.mux4To1 => '4:1 MUX',
    CompKind.demux1To4 => '1:4 DEMUX',
    CompKind.decoder2To4 => '2:4 Decoder',
    CompKind.fullAdder => 'Full Adder',
    CompKind.magComparator => '2-Bit Compare',
    CompKind.alu2Bit => '2-Bit ALU',
    CompKind.adc4Bit => '4-Bit ADC',
    CompKind.dac4Bit => '4-Bit DAC',
    CompKind.hexKeypad => 'Hex Keypad',
    CompKind.dipSwitch4 => '4-Bit DIP Sw',
    CompKind.voltmeter => 'Voltmeter',
    CompKind.ammeter => 'Ammeter',
    CompKind.wattmeter => 'Wattmeter',
    CompKind.logicIndicator => 'Logic LED',
    CompKind.subcircuit => 'Subcircuit IC',
  };
}

String localizedParamLabel(AppLocalizations l10n, ParamKey key) {
  return switch (key) {
    ParamKey.volts => l10n.paramVolts,
    ParamKey.amps => l10n.paramAmps,
    ParamKey.ampPeak => l10n.paramAmpPeak,
    ParamKey.freqHz => l10n.paramFreqHz,
    ParamKey.period => 'Period (s)',
    ParamKey.phaseDeg => l10n.paramPhaseDeg,
    ParamKey.shape => l10n.paramShape,
    ParamKey.dcOffset => l10n.paramDcOffset,
    ParamKey.duty => l10n.paramDuty,
    ParamKey.vHigh => l10n.paramVHigh,
    ParamKey.ohms => l10n.paramOhms,
    ParamKey.wiper => l10n.paramWiper,
    ParamKey.farads => l10n.paramFarads,
    ParamKey.henrys => l10n.paramHenrys,
    ParamKey.switchState => l10n.paramSwitchState,
    ParamKey.maxCurrent => l10n.paramMaxCurrent,
    ParamKey.zenerVolts => l10n.paramZenerVolts,
    ParamKey.gain => l10n.paramGain,
    ParamKey.gm => l10n.paramGm,
    ParamKey.rm => l10n.paramRm,
    ParamKey.ratio => l10n.paramRatio,
    ParamKey.beta => l10n.paramBeta,
    ParamKey.vth => l10n.paramVth,
  };
}

String formatEngValue(double v) {
  final abs = v.abs();
  if (abs == 0) return '0';
  if (abs >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';
  if (abs >= 1e3) return '${(v / 1e3).toStringAsFixed(2)}k';
  if (abs >= 1) return v.toStringAsFixed(2);
  if (abs >= 1e-3) return '${(v * 1e3).toStringAsFixed(2)}m';
  if (abs >= 1e-6) return '${(v * 1e6).toStringAsFixed(2)}u';
  if (abs >= 1e-9) return '${(v * 1e9).toStringAsFixed(2)}n';
  if (abs >= 1e-12) return '${(v * 1e12).toStringAsFixed(2)}p';
  return '${(v * 1e15).toStringAsFixed(2)}f';
}

/// Estimates peak-to-peak amplitude and midpoint rising-edge frequency from scope samples.
(double vpp, double? freqHz) measureWaveform(List<double> vals, List<double>? times) {
  if (vals.length < 2) return (0.0, null);
  var minV = vals[0];
  var maxV = vals[0];
  for (var i = 1; i < vals.length; i++) {
    if (vals[i] < minV) minV = vals[i];
    if (vals[i] > maxV) maxV = vals[i];
  }
  final vpp = maxV - minV;
  if (vpp <= 1e-3 || times == null || times.length != vals.length) {
    return (vpp, null);
  }
  final mid = 0.5 * (minV + maxV);
  double? firstT;
  var lastT = 0.0;
  var crossings = 0;
  for (var i = 1; i < vals.length; i++) {
    if (vals[i - 1] < mid && vals[i] >= mid) {
      final dv = vals[i] - vals[i - 1];
      final frac = dv > 1e-12 ? (mid - vals[i - 1]) / dv : 0.0;
      final tCross = times[i - 1] + frac * (times[i] - times[i - 1]);
      firstT ??= tCross;
      lastT = tCross;
      crossings++;
    }
  }
  if (crossings < 2 || firstT == null || lastT <= firstT) {
    return (vpp, null);
  }
  final period = (lastT - firstT) / (crossings - 1);
  return (vpp, period > 1e-9 ? 1.0 / period : null);
}

String _shortVal(double v) {
  final s = formatEngValue(v);
  return s.replaceFirst(RegExp(r'\.00(?=[a-zA-Z]?$)'), '');
}

String formatComponentBadge(PlacedComponent c) {
  final base = switch (c.kind) {
    CompKind.resistor => 'R${c.id} ${_shortVal(c.params[0])}Ω',
    CompKind.potentiometer => 'P${c.id} ${_shortVal(c.params[0])}Ω',
    CompKind.capacitor => 'C${c.id} ${_shortVal(c.params[0])}F',
    CompKind.inductor => 'L${c.id} ${_shortVal(c.params[0])}H',
    CompKind.dcSource => 'V${c.id} ${_shortVal(c.params[0])}V',
    CompKind.dcCurrent => 'I${c.id} ${_shortVal(c.params[0])}A',
    CompKind.acSource => 'V${c.id} ${_shortVal(c.params[0])}Vp',
    CompKind.funcGen => 'FG${c.id} ${_shortVal(c.params[2])}Hz',
    CompKind.pulseVoltage => 'PLS${c.id}',
    CompKind.pwlSource => 'PWL${c.id}',
    CompKind.clock => 'CLK${c.id} ${_shortVal(c.params[0])}Hz',
    CompKind.switchSpst || CompKind.switchSpdt || CompKind.pushbutton => 'SW${c.id}',
    CompKind.relay || CompKind.relaySpdt || CompKind.relayDpdt => 'K${c.id} ${_shortVal(c.params.length > 1 ? c.params[1] : 5.0)}V',
    CompKind.lamp => 'LP${c.id} ${_shortVal(c.params[0])}Ω',
    CompKind.fuse => 'F${c.id} ${_shortVal(c.params[0])}A',
    CompKind.diode || CompKind.led => 'D${c.id}',
    CompKind.optocoupler => 'OC${c.id} x${_shortVal(c.params[0])}',
    CompKind.zener => 'DZ${c.id} ${_shortVal(c.params[2])}V',
    CompKind.opAmp => 'U${c.id}',
    CompKind.npnBjt || CompKind.pnpBjt => 'Q${c.id}',
    CompKind.nmos || CompKind.pmos => 'M${c.id}',
    CompKind.vcvs => 'E${c.id} x${_shortVal(c.params[0])}',
    CompKind.vccs => 'G${c.id} ${_shortVal(c.params[0])}S',
    CompKind.cccs => 'F${c.id} x${_shortVal(c.params[0])}',
    CompKind.ccvs => 'H${c.id} ${_shortVal(c.params[0])}Ω',
    CompKind.transformer => 'T${c.id} 1:${_shortVal(c.params[0])}',
    CompKind.dFlipFlop => 'DFF${c.id}',
    CompKind.timer555 => '555 #${c.id}',
    CompKind.sevenSeg => 'HEX${c.id}',
    CompKind.wordGen => 'WG${c.id} ${_shortVal(c.params[0])}Hz',
    CompKind.schmittTrigger => 'ST${c.id}',
    CompKind.counter4Bit || CompKind.counter4BitFull => 'CNT${c.id}',
    CompKind.powerRail => '+${_shortVal(c.params[0])}V',
    CompKind.netPort => c.hexPattern ?? 'NET',
    CompKind.polarizedCapacitor || CompKind.varCapacitor => 'C${c.id} ${_shortVal(c.params[0])}F',
    CompKind.varInductor => 'L${c.id} ${_shortVal(c.params[0])}H',
    CompKind.crystal => 'X${c.id}',
    CompKind.buzzer => 'BZ${c.id}',
    CompKind.dcMotor => 'M${c.id}',
    CompKind.voltageReg => 'REG ${_shortVal(c.params[0])}V',
    CompKind.voltmeter => 'VM${c.id}',
    CompKind.ammeter => 'AM${c.id}',
    CompKind.wattmeter => 'WM${c.id}',
    CompKind.subcircuit => c.subcircuitName ?? 'SUB${c.id}',
    _ => 'U${c.id}',
  };
  return (c.hotkey != null && c.hotkey!.isNotEmpty) ? '$base [${c.hotkey}]' : base;
}
