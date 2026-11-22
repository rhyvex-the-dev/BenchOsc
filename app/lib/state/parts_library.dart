import 'circuit_doc.dart';

/// Curated real-world electronic component model with tuned physics parameters.
class PartPreset {
  final String name;
  final String family;
  final CompKind kind;
  final String summary;
  final Map<int, double> paramOverrides;

  const PartPreset({
    required this.name,
    required this.family,
    required this.kind,
    required this.summary,
    this.paramOverrides = const {},
  });
}

const List<PartPreset> kPartsLibrary = [
  PartPreset(
    name: '1N4148',
    family: 'Diodes',
    kind: CompKind.diode,
    summary: 'Fast switching signal diode',
    paramOverrides: {0: 2.5e-9, 1: 1.75},
  ),
  PartPreset(
    name: '1N4007',
    family: 'Diodes',
    kind: CompKind.diode,
    summary: '1kV 1A rectifier diode',
    paramOverrides: {0: 7.0e-9, 1: 1.6},
  ),
  PartPreset(
    name: '1N5819',
    family: 'Diodes',
    kind: CompKind.schottkyDiode,
    summary: 'Low-Vf 40V Schottky diode',
    paramOverrides: {0: 1.0e-6, 1: 1.1},
  ),
  PartPreset(
    name: '2N2222',
    family: 'Transistors',
    kind: CompKind.npnBjt,
    summary: 'General NPN BJT (hFE 200)',
    paramOverrides: {0: 1e-14, 1: 200.0},
  ),
  PartPreset(
    name: '2N3904',
    family: 'Transistors',
    kind: CompKind.npnBjt,
    summary: 'Small-signal NPN (hFE 150)',
    paramOverrides: {0: 6.7e-15, 1: 150.0},
  ),
  PartPreset(
    name: '2N3906',
    family: 'Transistors',
    kind: CompKind.pnpBjt,
    summary: 'Complement PNP (hFE 140)',
    paramOverrides: {0: 1e-14, 1: 140.0},
  ),
  PartPreset(
    name: 'IRF540',
    family: 'Transistors',
    kind: CompKind.nmos,
    summary: 'Power NMOS (Vth 3.5V)',
    paramOverrides: {0: 0.4, 1: 3.5},
  ),
  PartPreset(
    name: '2N7000',
    family: 'Transistors',
    kind: CompKind.nmos,
    summary: 'Small-signal NMOS (Vth 2.0V)',
    paramOverrides: {0: 0.05, 1: 2.0},
  ),
  PartPreset(
    name: '2N5457',
    family: 'Transistors',
    kind: CompKind.njfet,
    summary: 'N-Channel JFET (Vp -1.5V)',
    paramOverrides: {0: 2e-3, 1: -1.5},
  ),
  PartPreset(
    name: 'LM741',
    family: 'Analog ICs',
    kind: CompKind.opAmp,
    summary: 'Classic dual-rail op-amp',
    paramOverrides: {0: 2e5, 1: 15.0, 2: -15.0},
  ),
  PartPreset(
    name: 'TL072',
    family: 'Analog ICs',
    kind: CompKind.opAmp,
    summary: 'Low-noise JFET op-amp',
    paramOverrides: {0: 2e5, 1: 12.0, 2: -12.0},
  ),
  PartPreset(
    name: 'LM358',
    family: 'Analog ICs',
    kind: CompKind.opAmp,
    summary: 'Single-supply op-amp (0..5V)',
    paramOverrides: {0: 1e5, 1: 5.0, 2: 0.0},
  ),
  PartPreset(
    name: 'LM7805',
    family: 'Analog ICs',
    kind: CompKind.voltageReg,
    summary: '+5.0V linear LDO regulator',
    paramOverrides: {0: 5.0},
  ),
  PartPreset(
    name: 'LM7812',
    family: 'Analog ICs',
    kind: CompKind.voltageReg,
    summary: '+12.0V linear regulator',
    paramOverrides: {0: 12.0},
  ),
  PartPreset(
    name: 'NE555',
    family: 'Analog ICs',
    kind: CompKind.timer555,
    summary: 'Precision timer / oscillator',
  ),
  PartPreset(
    name: '74HC00',
    family: 'CMOS Logic',
    kind: CompKind.nandGate,
    summary: 'Quad 2-input NAND gate (5V)',
    paramOverrides: {0: 5.0},
  ),
  PartPreset(
    name: '74HC04',
    family: 'CMOS Logic',
    kind: CompKind.notGate,
    summary: 'Hex inverter (5V)',
    paramOverrides: {0: 5.0},
  ),
  PartPreset(
    name: '74HC08',
    family: 'CMOS Logic',
    kind: CompKind.andGate,
    summary: 'Quad 2-input AND gate (5V)',
    paramOverrides: {0: 5.0},
  ),
  PartPreset(
    name: '74HC32',
    family: 'CMOS Logic',
    kind: CompKind.orGate,
    summary: 'Quad 2-input OR gate (5V)',
    paramOverrides: {0: 5.0},
  ),
  PartPreset(
    name: '74HC86',
    family: 'CMOS Logic',
    kind: CompKind.xorGate,
    summary: 'Quad 2-input XOR gate (5V)',
    paramOverrides: {0: 5.0},
  ),
];
