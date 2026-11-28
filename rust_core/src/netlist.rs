use std::collections::{HashMap, HashSet};

use crate::error::{SimError, SimErrorCode};

pub const GND: u32 = 0;

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum FaultKind {
    #[default]
    None = 0,
    Open = 1,
    Short = 2,
    Leaky = 3,
}

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WaveShape {
    Sine = 0,
    Square = 1,
    Triangle = 2,
}

#[derive(Debug, Clone)]
pub enum ComponentKind {
    Resistor {
        r: f64,
    },
    /// 3-terminal potentiometer: nodes = [top, bottom, wiper].
    Potentiometer {
        r_total: f64,
        wiper: f64,
    },
    Capacitor {
        c: f64,
        ic: Option<f64>,
    },
    Inductor {
        l: f64,
        ic: Option<f64>,
    },
    SwitchSpst {
        closed: bool,
        r_on: f64,
        r_off: f64,
    },
    /// 3-terminal SPDT switch: nodes = [common, throw_a, throw_b].
    SwitchSpdt {
        throw_b: bool,
        r_on: f64,
        r_off: f64,
    },
    Fuse {
        i_max: f64,
        r_on: f64,
        blown: bool,
    },
    DcVoltage {
        v: f64,
    },
    AcVoltage {
        amp: f64,
        freq: f64,
        phase_deg: f64,
        offset: f64,
    },
    FunctionGen {
        shape: WaveShape,
        amp: f64,
        freq: f64,
        offset: f64,
        duty: f64,
    },
    DcCurrent {
        i: f64,
    },
    /// Voltage-Controlled Voltage Source: nodes = [out_p, out_n, ctrl_p, ctrl_n].
    Vcvs {
        gain: f64,
    },
    /// Voltage-Controlled Current Source: nodes = [out_p, out_n, ctrl_p, ctrl_n].
    Vccs {
        gm: f64,
    },
    /// Current-Controlled Current Source: nodes = [out_p, out_n, sense_p, sense_n].
    Cccs {
        gain: f64,
    },
    /// Current-Controlled Voltage Source: nodes = [out_p, out_n, sense_p, sense_n].
    Ccvs {
        rm: f64,
    },
    /// Standard or Zener diode: nodes = [anode, cathode]. Set `bv` finite for Zener breakdown.
    Diode {
        is_sat: f64,
        n: f64,
        bv: f64,
    },
    Led {
        is_sat: f64,
        n: f64,
    },
    /// Soft-saturating op-amp referenced to GND: nodes = [in_p, in_n, out].
    OpAmp {
        gain: f64,
        v_sat_pos: f64,
        v_sat_neg: f64,
        r_out: f64,
    },
    /// Ebers-Moll NPN: nodes = [collector, base, emitter].
    NpnBjt {
        is_sat: f64,
        bf: f64,
        br: f64,
    },
    /// Ebers-Moll PNP: nodes = [collector, base, emitter].
    PnpBjt {
        is_sat: f64,
        bf: f64,
        br: f64,
    },
    /// Level-1 Shichman-Hodges NMOS: nodes = [drain, gate, source].
    Nmos {
        kp: f64,
        vth: f64,
        lambda: f64,
    },
    /// Level-1 Shichman-Hodges PMOS: nodes = [drain, gate, source].
    Pmos {
        kp: f64,
        vth: f64,
        lambda: f64,
    },
    /// Mixed-signal digital gate: pins = [in_a, in_b, out] (or [in_a, out] for Not/Buffer).
    DigitalGate {
        kind: crate::digital::GateKind,
        v_high: f64,
        r_out: f64,
    },
    /// Digital clock square source: pins = [out, gnd].
    ClockSource {
        freq: f64,
        v_high: f64,
        r_out: f64,
    },
    /// Positive-edge D flip-flop: pins = [d, clk, q, qn].
    DFlipFlop {
        v_high: f64,
        r_out: f64,
    },
    /// High-impedance digital logic probe referenced to GND: pins = [input].
    LogicProbe {
        r_in: f64,
    },
    /// Behavioral 555 Timer IC: pins = [trig, thrs, disch, out].
    Timer555 {
        v_cc: f64,
        r_out: f64,
    },
    /// 4-bit Hex 7-Segment Display referenced to GND: pins = [d3, d2, d1, d0].
    SevenSeg {
        r_in: f64,
    },
    /// Ideal transformer: pins = [p_pos, p_neg, s_pos, s_neg].
    Transformer {
        ratio: f64,
    },
    /// Electromechanical SPST-NO relay: pins = [coil_p, coil_n, com, no].
    Relay {
        r_coil: f64,
        v_pull: f64,
        r_on: f64,
        r_off: f64,
    },
    /// 4-bit 16-step digital word generator: pins = [b3, b2, b1, b0].
    WordGen {
        freq: f64,
        pattern: u64,
        v_high: f64,
        r_out: f64,
    },
    /// 4-pin Optocoupler (LED + Phototransistor): pins = [anode, cathode, collector, emitter].
    Optocoupler {
        ctr: f64,
        is_sat: f64,
        n: f64,
    },
    /// 3-pin Hysteresis Comparator / Schmitt Trigger: pins = [in_p, in_n, out].
    SchmittTrigger {
        v_hyst: f64,
        v_high: f64,
        r_out: f64,
    },
    /// 4-pin Edge-Triggered Binary Counter: pins = [clk, q2, q1, q0].
    Counter4Bit {
        v_high: f64,
        r_out: f64,
    },
    AcCurrent {
        amp: f64,
        freq: f64,
        phase_deg: f64,
        offset: f64,
    },
    PulseVoltage {
        v1: f64,
        v2: f64,
        td: f64,
        tr: f64,
        tf: f64,
        pw: f64,
        per: f64,
    },
    PwlSource {
        pts: [[f64; 2]; 4],
        count: u8,
    },
    VControlledSwitch {
        v_on: f64,
        v_off: f64,
        r_on: f64,
        r_off: f64,
    },
    IControlledSwitch {
        i_on: f64,
        i_off: f64,
        r_on: f64,
        r_off: f64,
    },
    BridgeRectifier {
        is_sat: f64,
        n: f64,
    },
    Njfet {
        beta: f64,
        vto: f64,
        lambda: f64,
    },
    Pjfet {
        beta: f64,
        vto: f64,
        lambda: f64,
    },
    Scr {
        i_hold: f64,
        v_bo: f64,
        r_on: f64,
        r_off: f64,
    },
    Triac {
        i_hold: f64,
        v_bo: f64,
        r_on: f64,
        r_off: f64,
    },
    Diac {
        v_bo: f64,
        r_on: f64,
        r_off: f64,
    },
    Igbt {
        kp: f64,
        vth: f64,
        r_on: f64,
    },
    VoltageReg {
        v_out: f64,
        r_out: f64,
    },
    ComparatorOc {
        r_ol: f64,
    },
    InstAmp {
        gain: f64,
        v_sat_pos: f64,
        v_sat_neg: f64,
        r_out: f64,
    },
    Vco {
        f0: f64,
        df_dv: f64,
        v_high: f64,
        r_out: f64,
    },
    AnalogMultiplier {
        gain: f64,
        r_out: f64,
    },
    SampleHold {
        v_high: f64,
        r_out: f64,
    },
    TriStateBuffer {
        v_high: f64,
        r_out: f64,
    },
    DigitalGateMulti {
        kind: crate::digital::GateKind,
        v_high: f64,
        r_out: f64,
    },
    SrLatch {
        v_high: f64,
        r_out: f64,
    },
    JkFlipFlop {
        v_high: f64,
        r_out: f64,
    },
    TFlipFlop {
        v_high: f64,
        r_out: f64,
    },
    DFlipFlopAsync {
        v_high: f64,
        r_out: f64,
    },
    Counter4BitFull {
        v_high: f64,
        r_out: f64,
    },
    ShiftReg4Bit {
        v_high: f64,
        r_out: f64,
    },
    Mux4To1 {
        v_high: f64,
        r_out: f64,
    },
    Demux1To4 {
        v_high: f64,
        r_out: f64,
    },
    Decoder2To4 {
        v_high: f64,
        r_out: f64,
    },
    FullAdder {
        v_high: f64,
        r_out: f64,
    },
    MagComparator {
        v_high: f64,
        r_out: f64,
    },
    Alu2Bit {
        v_high: f64,
        r_out: f64,
    },
    Adc4Bit {
        v_ref: f64,
        v_high: f64,
        r_out: f64,
    },
    Dac4Bit {
        v_ref: f64,
        r_out: f64,
    },
    HexKeypad {
        nibble: u8,
        v_high: f64,
        r_out: f64,
    },
    DipSwitch4 {
        mask: u8,
        r_on: f64,
        r_off: f64,
    },
    CoupledInductor {
        l1: f64,
        l2: f64,
        k: f64,
    },
    CenterTapTransformer {
        ratio: f64,
    },
    RelayDpdt {
        r_coil: f64,
        v_pull: f64,
        r_on: f64,
        r_off: f64,
    },
    Crystal {
        rm: f64,
        lm: f64,
        cm: f64,
        c0: f64,
    },
    DcMotor {
        r_a: f64,
        ke: f64,
    },
    Wattmeter {
        r_shunt: f64,
    },
    BarGraphLed {
        is_sat: f64,
        n: f64,
    },
    RgbLed {
        is_sat: f64,
        n: f64,
    },
    /// Voltage-controlled varactor diode: nodes = [anode, cathode].
    VaractorDiode {
        cj0: f64,
        vj: f64,
        m: f64,
        is_sat: f64,
    },
}

impl ComponentKind {
    /// Minimum number of connected pins required by this component's stamping/netlist logic.
    pub fn min_pins(&self) -> u8 {
        match self {
            Self::LogicProbe { .. } => 1,
            Self::Resistor { .. }
            | Self::Capacitor { .. }
            | Self::Inductor { .. }
            | Self::SwitchSpst { .. }
            | Self::Fuse { .. }
            | Self::DcVoltage { .. }
            | Self::AcVoltage { .. }
            | Self::FunctionGen { .. }
            | Self::DcCurrent { .. }
            | Self::AcCurrent { .. }
            | Self::PulseVoltage { .. }
            | Self::PwlSource { .. }
            | Self::Diode { .. }
            | Self::Led { .. }
            | Self::VaractorDiode { .. }
            | Self::ClockSource { .. }
            | Self::Diac { .. }
            | Self::Vco { .. }
            | Self::TriStateBuffer { .. }
            | Self::Crystal { .. }
            | Self::DcMotor { .. }
            | Self::BarGraphLed { .. }
            | Self::RgbLed { .. } => 2,
            Self::DigitalGate { kind, .. } => {
                if *kind == crate::digital::GateKind::Not {
                    2
                } else {
                    3
                }
            }
            Self::Potentiometer { .. }
            | Self::SwitchSpdt { .. }
            | Self::OpAmp { .. }
            | Self::NpnBjt { .. }
            | Self::PnpBjt { .. }
            | Self::Nmos { .. }
            | Self::Pmos { .. }
            | Self::Njfet { .. }
            | Self::Pjfet { .. }
            | Self::Scr { .. }
            | Self::Triac { .. }
            | Self::Igbt { .. }
            | Self::VoltageReg { .. }
            | Self::ComparatorOc { .. }
            | Self::InstAmp { .. }
            | Self::AnalogMultiplier { .. }
            | Self::SampleHold { .. }
            | Self::SchmittTrigger { .. }
            | Self::DigitalGateMulti { .. } => 3,
            Self::Vcvs { .. }
            | Self::Vccs { .. }
            | Self::Cccs { .. }
            | Self::Ccvs { .. }
            | Self::DFlipFlop { .. }
            | Self::Timer555 { .. }
            | Self::SevenSeg { .. }
            | Self::Transformer { .. }
            | Self::Relay { .. }
            | Self::WordGen { .. }
            | Self::Optocoupler { .. }
            | Self::Counter4Bit { .. }
            | Self::VControlledSwitch { .. }
            | Self::IControlledSwitch { .. }
            | Self::BridgeRectifier { .. }
            | Self::SrLatch { .. }
            | Self::TFlipFlop { .. }
            | Self::HexKeypad { .. }
            | Self::CoupledInductor { .. }
            | Self::Wattmeter { .. } => 4,
            Self::JkFlipFlop { .. }
            | Self::FullAdder { .. }
            | Self::CenterTapTransformer { .. }
            | Self::RelayDpdt { .. } => 5,
            Self::DFlipFlopAsync { .. } | Self::Adc4Bit { .. } | Self::Dac4Bit { .. } => 6,
            Self::ShiftReg4Bit { .. }
            | Self::Mux4To1 { .. }
            | Self::Demux1To4 { .. }
            | Self::Decoder2To4 { .. }
            | Self::MagComparator { .. } => 7,
            Self::Counter4BitFull { .. } | Self::Alu2Bit { .. } | Self::DipSwitch4 { .. } => 8,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Component {
    pub id: u32,
    pub name: String,
    pub kind: ComponentKind,
    /// Pin connections by user node id (`0` = GND). Supports up to 8 pins.
    pub nodes: [u32; 8],
    pub pin_count: u8,
    pub fault: FaultKind,
}

impl Component {
    pub fn active_nodes(&self) -> &[u32] {
        &self.nodes[..self.pin_count as usize]
    }

    pub fn branch_var_count(&self) -> usize {
        match self.kind {
            ComponentKind::Ccvs { .. }
            | ComponentKind::CoupledInductor { .. }
            | ComponentKind::CenterTapTransformer { .. } => 2,
            ComponentKind::Inductor { .. }
            | ComponentKind::DcVoltage { .. }
            | ComponentKind::AcVoltage { .. }
            | ComponentKind::FunctionGen { .. }
            | ComponentKind::PulseVoltage { .. }
            | ComponentKind::PwlSource { .. }
            | ComponentKind::Vcvs { .. }
            | ComponentKind::Cccs { .. }
            | ComponentKind::Transformer { .. }
            | ComponentKind::IControlledSwitch { .. }
            | ComponentKind::Crystal { .. } => 1,
            _ => 0,
        }
    }

    pub fn is_nonlinear(&self) -> bool {
        matches!(
            self.kind,
            ComponentKind::Diode { .. }
                | ComponentKind::VaractorDiode { .. }
                | ComponentKind::Led { .. }
                | ComponentKind::OpAmp { .. }
                | ComponentKind::NpnBjt { .. }
                | ComponentKind::PnpBjt { .. }
                | ComponentKind::Nmos { .. }
                | ComponentKind::Pmos { .. }
                | ComponentKind::DigitalGate { .. }
                | ComponentKind::Relay { .. }
                | ComponentKind::Optocoupler { .. }
                | ComponentKind::VControlledSwitch { .. }
                | ComponentKind::IControlledSwitch { .. }
                | ComponentKind::BridgeRectifier { .. }
                | ComponentKind::Njfet { .. }
                | ComponentKind::Pjfet { .. }
                | ComponentKind::Scr { .. }
                | ComponentKind::Triac { .. }
                | ComponentKind::Diac { .. }
                | ComponentKind::Igbt { .. }
                | ComponentKind::VoltageReg { .. }
                | ComponentKind::ComparatorOc { .. }
                | ComponentKind::InstAmp { .. }
                | ComponentKind::AnalogMultiplier { .. }
                | ComponentKind::DigitalGateMulti { .. }
                | ComponentKind::TriStateBuffer { .. }
                | ComponentKind::SrLatch { .. }
                | ComponentKind::Mux4To1 { .. }
                | ComponentKind::Demux1To4 { .. }
                | ComponentKind::Decoder2To4 { .. }
                | ComponentKind::FullAdder { .. }
                | ComponentKind::MagComparator { .. }
                | ComponentKind::Alu2Bit { .. }
                | ComponentKind::Adc4Bit { .. }
                | ComponentKind::Dac4Bit { .. }
                | ComponentKind::RelayDpdt { .. }
                | ComponentKind::BarGraphLed { .. }
                | ComponentKind::RgbLed { .. }
                | ComponentKind::SchmittTrigger { .. }
                | ComponentKind::Counter4BitFull { .. }
        )
    }
}

#[derive(Debug, Default, Clone)]
pub struct Circuit {
    pub components: Vec<Component>,
}

/// Dense compiled topology ready for MNA stamping.
#[derive(Debug, Clone)]
pub struct CompiledTopology {
    pub node_map: HashMap<u32, usize>,
    pub comp_map: HashMap<u32, usize>,
    pub node_count: usize,
    pub branch_count: usize,
    /// Maps component index in `Circuit::components` -> MNA branch index (`node_count + b`).
    pub branch_of_comp: Vec<Option<usize>>,
    /// True if matrix node index is driven by an ideal voltage source branch.
    pub vsrc_nodes: Vec<bool>,
    /// Number of pin occurrences per matrix node index (degree <= 1 means unwired).
    pub node_degree: Vec<u16>,
}

impl CompiledTopology {
    pub fn matrix_size(&self) -> usize {
        self.node_count + self.branch_count
    }

    #[inline]
    pub fn idx(&self, node_id: u32) -> Option<usize> {
        if node_id == GND {
            None
        } else {
            self.node_map.get(&node_id).copied()
        }
    }

    #[inline]
    pub fn is_connected_node(&self, node_id: u32) -> bool {
        node_id != GND
            && self
                .idx(node_id)
                .is_some_and(|i| self.node_degree.get(i).copied().unwrap_or(0) > 1)
    }
}

impl Circuit {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn clear(&mut self) {
        self.components.clear();
    }

    pub fn add(&mut self, comp: Component) -> Result<(), SimError> {
        let err = || {
            Err(SimError::new(
                SimErrorCode::InvalidParameter,
                comp.id as i32,
            ))
        };
        if self.components.iter().any(|c| c.id == comp.id) {
            return err();
        }
        if comp.pin_count < comp.kind.min_pins() || comp.pin_count > 8 {
            return err();
        }
        let pos_fin = |x: f64| x.is_finite() && x > 0.0;
        let nonneg_fin = |x: f64| x.is_finite() && x >= 0.0;
        let valid = match &comp.kind {
            ComponentKind::Resistor { r } | ComponentKind::Wattmeter { r_shunt: r } => pos_fin(*r),
            ComponentKind::Potentiometer { r_total, wiper } => {
                pos_fin(*r_total) && wiper.is_finite()
            }
            ComponentKind::Capacitor { c, ic } => pos_fin(*c) && ic.is_none_or(f64::is_finite),
            ComponentKind::Inductor { l, ic } => pos_fin(*l) && ic.is_none_or(f64::is_finite),
            ComponentKind::SwitchSpst { r_on, r_off, .. }
            | ComponentKind::SwitchSpdt { r_on, r_off, .. }
            | ComponentKind::DipSwitch4 { r_on, r_off, .. } => pos_fin(*r_on) && pos_fin(*r_off),
            ComponentKind::Fuse { i_max, r_on, .. } => pos_fin(*i_max) && pos_fin(*r_on),
            ComponentKind::DcVoltage { v } => v.is_finite(),
            ComponentKind::DcCurrent { i } => i.is_finite(),
            ComponentKind::AcVoltage {
                amp,
                freq,
                phase_deg,
                offset,
            }
            | ComponentKind::AcCurrent {
                amp,
                freq,
                phase_deg,
                offset,
            } => {
                amp.is_finite() && nonneg_fin(*freq) && phase_deg.is_finite() && offset.is_finite()
            }
            ComponentKind::FunctionGen {
                amp,
                freq,
                offset,
                duty,
                ..
            } => amp.is_finite() && nonneg_fin(*freq) && offset.is_finite() && pos_fin(*duty),
            ComponentKind::PulseVoltage {
                v1,
                v2,
                td,
                tr,
                tf,
                pw,
                per,
            } => {
                v1.is_finite()
                    && v2.is_finite()
                    && nonneg_fin(*td)
                    && pos_fin(*tr)
                    && pos_fin(*tf)
                    && nonneg_fin(*pw)
                    && pos_fin(*per)
            }
            ComponentKind::PwlSource { pts, count } => {
                *count >= 1
                    && *count <= 4
                    && pts
                        .iter()
                        .take(*count as usize)
                        .all(|p| nonneg_fin(p[0]) && p[1].is_finite())
            }
            ComponentKind::Vcvs { gain }
            | ComponentKind::Vccs { gm: gain }
            | ComponentKind::Cccs { gain }
            | ComponentKind::Ccvs { rm: gain } => gain.is_finite(),
            ComponentKind::Diode { is_sat, n, bv } => {
                pos_fin(*is_sat) && pos_fin(*n) && !bv.is_nan() && *bv > 0.0
            }
            ComponentKind::Led { is_sat, n } => pos_fin(*is_sat) && pos_fin(*n),
            ComponentKind::BridgeRectifier { is_sat, n }
            | ComponentKind::BarGraphLed { is_sat, n }
            | ComponentKind::RgbLed { is_sat, n } => pos_fin(*is_sat) && pos_fin(*n),
            ComponentKind::OpAmp {
                gain,
                v_sat_pos,
                v_sat_neg,
                r_out,
            }
            | ComponentKind::InstAmp {
                gain,
                v_sat_pos,
                v_sat_neg,
                r_out,
            } => {
                gain.is_finite()
                    && *gain != 0.0
                    && v_sat_pos.is_finite()
                    && v_sat_neg.is_finite()
                    && *v_sat_pos > *v_sat_neg
                    && pos_fin(*r_out)
            }
            ComponentKind::NpnBjt { is_sat, bf, br } | ComponentKind::PnpBjt { is_sat, bf, br } => {
                pos_fin(*is_sat) && pos_fin(*bf) && pos_fin(*br)
            }
            ComponentKind::Nmos { kp, vth, lambda } | ComponentKind::Pmos { kp, vth, lambda } => {
                pos_fin(*kp) && vth.is_finite() && nonneg_fin(*lambda)
            }
            ComponentKind::Njfet { beta, vto, lambda }
            | ComponentKind::Pjfet { beta, vto, lambda } => {
                pos_fin(*beta) && vto.is_finite() && nonneg_fin(*lambda)
            }
            ComponentKind::Igbt { kp, vth, r_on } => {
                pos_fin(*kp) && vth.is_finite() && pos_fin(*r_on)
            }
            ComponentKind::ClockSource {
                freq,
                v_high,
                r_out,
            }
            | ComponentKind::WordGen {
                freq,
                v_high,
                r_out,
                ..
            } => nonneg_fin(*freq) && pos_fin(*v_high) && pos_fin(*r_out),
            ComponentKind::DigitalGate { v_high, r_out, .. }
            | ComponentKind::DigitalGateMulti { v_high, r_out, .. }
            | ComponentKind::DFlipFlop { v_high, r_out }
            | ComponentKind::Timer555 {
                v_cc: v_high,
                r_out,
            }
            | ComponentKind::SampleHold { v_high, r_out }
            | ComponentKind::TriStateBuffer { v_high, r_out }
            | ComponentKind::SrLatch { v_high, r_out }
            | ComponentKind::JkFlipFlop { v_high, r_out }
            | ComponentKind::TFlipFlop { v_high, r_out }
            | ComponentKind::DFlipFlopAsync { v_high, r_out }
            | ComponentKind::Counter4Bit { v_high, r_out }
            | ComponentKind::Counter4BitFull { v_high, r_out }
            | ComponentKind::ShiftReg4Bit { v_high, r_out }
            | ComponentKind::Mux4To1 { v_high, r_out }
            | ComponentKind::Demux1To4 { v_high, r_out }
            | ComponentKind::Decoder2To4 { v_high, r_out }
            | ComponentKind::FullAdder { v_high, r_out }
            | ComponentKind::MagComparator { v_high, r_out }
            | ComponentKind::Alu2Bit { v_high, r_out }
            | ComponentKind::HexKeypad { v_high, r_out, .. } => pos_fin(*v_high) && pos_fin(*r_out),
            ComponentKind::LogicProbe { r_in } | ComponentKind::SevenSeg { r_in } => pos_fin(*r_in),
            ComponentKind::Transformer { ratio }
            | ComponentKind::CenterTapTransformer { ratio } => ratio.is_finite() && *ratio != 0.0,
            ComponentKind::Relay {
                r_coil,
                v_pull,
                r_on,
                r_off,
            }
            | ComponentKind::RelayDpdt {
                r_coil,
                v_pull,
                r_on,
                r_off,
            } => pos_fin(*r_coil) && pos_fin(*v_pull) && pos_fin(*r_on) && pos_fin(*r_off),
            ComponentKind::VControlledSwitch {
                v_on,
                v_off,
                r_on,
                r_off,
            } => v_on.is_finite() && v_off.is_finite() && pos_fin(*r_on) && pos_fin(*r_off),
            ComponentKind::IControlledSwitch {
                i_on,
                i_off,
                r_on,
                r_off,
            } => i_on.is_finite() && i_off.is_finite() && pos_fin(*r_on) && pos_fin(*r_off),
            ComponentKind::Optocoupler { ctr, is_sat, n } => {
                pos_fin(*ctr) && pos_fin(*is_sat) && pos_fin(*n)
            }
            ComponentKind::SchmittTrigger {
                v_hyst,
                v_high,
                r_out,
            } => nonneg_fin(*v_hyst) && pos_fin(*v_high) && pos_fin(*r_out),
            ComponentKind::Scr {
                i_hold,
                v_bo,
                r_on,
                r_off,
            }
            | ComponentKind::Triac {
                i_hold,
                v_bo,
                r_on,
                r_off,
            } => pos_fin(*i_hold) && pos_fin(*v_bo) && pos_fin(*r_on) && pos_fin(*r_off),
            ComponentKind::Diac { v_bo, r_on, r_off } => {
                pos_fin(*v_bo) && pos_fin(*r_on) && pos_fin(*r_off)
            }
            ComponentKind::VoltageReg { v_out, r_out } => pos_fin(*v_out) && pos_fin(*r_out),
            ComponentKind::ComparatorOc { r_ol } => pos_fin(*r_ol),
            ComponentKind::Vco {
                f0,
                df_dv,
                v_high,
                r_out,
            } => nonneg_fin(*f0) && df_dv.is_finite() && pos_fin(*v_high) && pos_fin(*r_out),
            ComponentKind::AnalogMultiplier { gain, r_out } => gain.is_finite() && pos_fin(*r_out),
            ComponentKind::Adc4Bit {
                v_ref,
                v_high,
                r_out,
            } => pos_fin(*v_ref) && pos_fin(*v_high) && pos_fin(*r_out),
            ComponentKind::Dac4Bit { v_ref, r_out } => pos_fin(*v_ref) && pos_fin(*r_out),
            ComponentKind::CoupledInductor { l1, l2, k } => {
                pos_fin(*l1) && pos_fin(*l2) && k.is_finite() && k.abs() < 1.0
            }
            ComponentKind::Crystal { rm, lm, cm, c0 } => {
                pos_fin(*rm) && pos_fin(*lm) && pos_fin(*cm) && pos_fin(*c0)
            }
            ComponentKind::DcMotor { r_a, ke } => pos_fin(*r_a) && nonneg_fin(*ke),
            ComponentKind::VaractorDiode { cj0, vj, m, is_sat } => {
                pos_fin(*cj0) && pos_fin(*vj) && pos_fin(*m) && pos_fin(*is_sat)
            }
        };
        if !valid {
            return err();
        }
        self.components.push(comp);
        Ok(())
    }

    /// Validates ground presence and floating islands, and compacts node/branch indices.
    pub fn compile(&self) -> Result<CompiledTopology, SimError> {
        if self.components.is_empty() {
            return Err(SimError::new(SimErrorCode::InvalidNetlist, 0));
        }

        let mut has_ground = false;
        let mut adj: HashMap<u32, Vec<u32>> = HashMap::new();
        let mut all_nodes: Vec<u32> = Vec::new();
        let mut seen_nodes: HashSet<u32> = HashSet::new();

        let mut node_use_count: HashMap<u32, usize> = HashMap::new();
        for comp in &self.components {
            for &n in comp.active_nodes() {
                *node_use_count.entry(n).or_insert(0) += 1;
            }
        }

        // Detect ideal voltage-source loops (KVL cycle among active zero-impedance voltage sources).
        fn find_root(parent: &HashMap<u32, u32>, mut x: u32) -> u32 {
            while let Some(&p) = parent.get(&x) {
                if p == x {
                    break;
                }
                x = p;
            }
            x
        }
        let mut v_parent: HashMap<u32, u32> = HashMap::new();
        for comp in &self.components {
            if comp.fault != FaultKind::None {
                continue;
            }
            let is_ideal_vsrc = matches!(
                comp.kind,
                ComponentKind::DcVoltage { .. }
                    | ComponentKind::AcVoltage { .. }
                    | ComponentKind::FunctionGen { .. }
                    | ComponentKind::PulseVoltage { .. }
                    | ComponentKind::PwlSource { .. }
            );
            if is_ideal_vsrc && comp.pin_count >= 2 {
                let ra = find_root(&v_parent, comp.nodes[0]);
                let rb = find_root(&v_parent, comp.nodes[1]);
                if ra == rb {
                    return Err(SimError::new(SimErrorCode::SingularMatrix, comp.id as i32));
                }
                v_parent.insert(ra, rb);
            }
        }

        let mut non_isrc_adj: HashMap<u32, Vec<u32>> = HashMap::new();

        for comp in &self.components {
            let pins = comp.active_nodes();
            for &n in pins {
                if n == GND {
                    has_ground = true;
                } else if seen_nodes.insert(n) {
                    all_nodes.push(n);
                }
            }
            // Ground-referenced active ICs/probes: tie their ground-referenced output/load pins to GND
            // (and completely unwired single-occurrence pins on multi-pin digital ICs), without masking
            // floating external subcircuits wired to analog inputs or across galvanic isolation.
            let is_gnd_ref_ic = matches!(
                comp.kind,
                ComponentKind::LogicProbe { .. }
                    | ComponentKind::SevenSeg { .. }
                    | ComponentKind::WordGen { .. }
                    | ComponentKind::SchmittTrigger { .. }
                    | ComponentKind::Counter4Bit { .. }
                    | ComponentKind::ComparatorOc { .. }
                    | ComponentKind::InstAmp { .. }
                    | ComponentKind::Vco { .. }
                    | ComponentKind::AnalogMultiplier { .. }
                    | ComponentKind::SampleHold { .. }
                    | ComponentKind::TriStateBuffer { .. }
                    | ComponentKind::DigitalGateMulti { .. }
                    | ComponentKind::SrLatch { .. }
                    | ComponentKind::JkFlipFlop { .. }
                    | ComponentKind::TFlipFlop { .. }
                    | ComponentKind::DFlipFlopAsync { .. }
                    | ComponentKind::Counter4BitFull { .. }
                    | ComponentKind::ShiftReg4Bit { .. }
                    | ComponentKind::Mux4To1 { .. }
                    | ComponentKind::Demux1To4 { .. }
                    | ComponentKind::Decoder2To4 { .. }
                    | ComponentKind::FullAdder { .. }
                    | ComponentKind::MagComparator { .. }
                    | ComponentKind::Alu2Bit { .. }
                    | ComponentKind::Adc4Bit { .. }
                    | ComponentKind::Dac4Bit { .. }
                    | ComponentKind::HexKeypad { .. }
                    | ComponentKind::DFlipFlop { .. }
                    | ComponentKind::DigitalGate { .. }
                    | ComponentKind::Timer555 { .. }
                    | ComponentKind::OpAmp { .. }
            );
            if is_gnd_ref_ic {
                let gnd_pins: &[u32] = match comp.kind {
                    ComponentKind::LogicProbe { .. }
                    | ComponentKind::SevenSeg { .. }
                    | ComponentKind::WordGen { .. }
                    | ComponentKind::HexKeypad { .. } => pins,
                    ComponentKind::DFlipFlop { .. } | ComponentKind::SrLatch { .. } => &pins[2..],
                    ComponentKind::FullAdder { .. } => &pins[3..],
                    ComponentKind::JkFlipFlop { .. } => &pins[3..],
                    ComponentKind::TFlipFlop { .. } => &pins[2..],
                    ComponentKind::DFlipFlopAsync { .. } => &pins[4..],
                    ComponentKind::Counter4Bit { .. } => &pins[1..],
                    ComponentKind::Counter4BitFull { .. }
                    | ComponentKind::ShiftReg4Bit { .. }
                    | ComponentKind::Demux1To4 { .. }
                    | ComponentKind::Decoder2To4 { .. } => &pins[3..],
                    ComponentKind::Mux4To1 { .. } => &pins[6..],
                    ComponentKind::MagComparator { .. } => &pins[4..],
                    ComponentKind::Alu2Bit { .. } => &pins[6..],
                    ComponentKind::Adc4Bit { .. } => &pins[2..],
                    ComponentKind::Dac4Bit { .. } => &pins[5..],
                    ComponentKind::Timer555 { .. } => &pins[3..],
                    ComponentKind::DigitalGate { .. } | ComponentKind::DigitalGateMulti { .. } => {
                        &pins[pins.len() - 1..]
                    }
                    ComponentKind::OpAmp { .. }
                    | ComponentKind::InstAmp { .. }
                    | ComponentKind::ComparatorOc { .. }
                    | ComponentKind::AnalogMultiplier { .. }
                    | ComponentKind::SampleHold { .. }
                    | ComponentKind::SchmittTrigger { .. } => &pins[2..],
                    ComponentKind::TriStateBuffer { .. } => &pins[pins.len() - 1..],
                    ComponentKind::Vco { .. } => &pins[1..],
                    _ => &[],
                };
                for &n in gnd_pins {
                    if n != GND {
                        adj.entry(n).or_default().push(GND);
                        adj.entry(GND).or_default().push(n);
                        non_isrc_adj.entry(n).or_default().push(GND);
                        non_isrc_adj.entry(GND).or_default().push(n);
                    }
                }
                for &n in pins {
                    if n != GND && node_use_count.get(&n).copied().unwrap_or(0) <= 1 {
                        adj.entry(n).or_default().push(GND);
                        adj.entry(GND).or_default().push(n);
                        non_isrc_adj.entry(n).or_default().push(GND);
                        non_isrc_adj.entry(GND).or_default().push(n);
                    }
                }
                continue;
            }
            let is_cur_src = matches!(
                comp.kind,
                ComponentKind::DcCurrent { .. } | ComponentKind::AcCurrent { .. }
            );
            let connect_group = |adj: &mut HashMap<u32, Vec<u32>>,
                                 non_isrc: &mut HashMap<u32, Vec<u32>>,
                                 grp: &[u32]| {
                for i in 0..grp.len() {
                    for j in (i + 1)..grp.len() {
                        adj.entry(grp[i]).or_default().push(grp[j]);
                        adj.entry(grp[j]).or_default().push(grp[i]);
                        if !is_cur_src {
                            non_isrc.entry(grp[i]).or_default().push(grp[j]);
                            non_isrc.entry(grp[j]).or_default().push(grp[i]);
                        }
                    }
                }
            };
            match comp.kind {
                ComponentKind::DipSwitch4 { .. } => {
                    for b in 0..4 {
                        connect_group(&mut adj, &mut non_isrc_adj, &pins[2 * b..2 * b + 2]);
                    }
                }
                ComponentKind::Transformer { .. }
                | ComponentKind::CoupledInductor { .. }
                | ComponentKind::Optocoupler { .. }
                | ComponentKind::Relay { .. }
                | ComponentKind::VControlledSwitch { .. }
                | ComponentKind::IControlledSwitch { .. }
                | ComponentKind::Vcvs { .. }
                | ComponentKind::Vccs { .. }
                | ComponentKind::Cccs { .. }
                | ComponentKind::Ccvs { .. }
                | ComponentKind::Wattmeter { .. } => {
                    connect_group(&mut adj, &mut non_isrc_adj, &pins[..2]);
                    connect_group(&mut adj, &mut non_isrc_adj, &pins[2..4]);
                }
                ComponentKind::CenterTapTransformer { .. } => {
                    connect_group(&mut adj, &mut non_isrc_adj, &pins[..2]);
                    connect_group(&mut adj, &mut non_isrc_adj, &pins[2..5]);
                }
                ComponentKind::RelayDpdt { .. } => {
                    connect_group(&mut adj, &mut non_isrc_adj, &pins[..2]);
                    connect_group(&mut adj, &mut non_isrc_adj, &pins[2..5]);
                    if pins.len() >= 8 {
                        connect_group(&mut adj, &mut non_isrc_adj, &pins[5..8]);
                    }
                }
                ComponentKind::VoltageReg { .. } => {
                    connect_group(&mut adj, &mut non_isrc_adj, &[pins[0], pins[2]]);
                }
                _ => connect_group(&mut adj, &mut non_isrc_adj, pins),
            }
            // Unused throw/contact pins on passive switches/relays should not flag FloatingNode.
            let switch_pins = match comp.kind {
                ComponentKind::DipSwitch4 { .. } | ComponentKind::SwitchSpdt { .. } => Some(pins),
                ComponentKind::Relay { .. } | ComponentKind::RelayDpdt { .. } => Some(&pins[2..]),
                _ => None,
            };
            if let Some(sp) = switch_pins {
                for &n in sp {
                    if n != GND && node_use_count.get(&n).copied().unwrap_or(0) <= 1 {
                        connect_group(&mut adj, &mut non_isrc_adj, &[n, GND]);
                    }
                }
            }
        }

        if !has_ground {
            return Err(SimError::new(SimErrorCode::MissingGround, 0));
        }

        fn bfs_from_gnd(graph: &HashMap<u32, Vec<u32>>) -> HashSet<u32> {
            let mut visited: HashSet<u32> = HashSet::new();
            let mut stack = vec![GND];
            visited.insert(GND);
            while let Some(cur) = stack.pop() {
                if let Some(neighbors) = graph.get(&cur) {
                    for &nxt in neighbors {
                        if visited.insert(nxt) {
                            stack.push(nxt);
                        }
                    }
                }
            }
            visited
        }

        // BFS from GND to detect disconnected floating subcircuits and current-source cutsets.
        let reachable = bfs_from_gnd(&adj);
        all_nodes.sort_unstable();
        for &n in &all_nodes {
            if !reachable.contains(&n) {
                return Err(SimError::new(SimErrorCode::FloatingNode, n as i32));
            }
        }
        let non_isrc_reachable = bfs_from_gnd(&non_isrc_adj);
        for &n in &all_nodes {
            if !non_isrc_reachable.contains(&n) {
                return Err(SimError::new(SimErrorCode::SingularMatrix, n as i32));
            }
        }

        let mut node_map = HashMap::with_capacity(all_nodes.len());
        for (idx, &node_id) in all_nodes.iter().enumerate() {
            node_map.insert(node_id, idx);
        }
        let mut comp_map = HashMap::with_capacity(self.components.len());
        for (idx, comp) in self.components.iter().enumerate() {
            comp_map.insert(comp.id, idx);
        }

        let node_count = all_nodes.len();
        let mut branch_count = 0usize;
        let mut branch_of_comp = Vec::with_capacity(self.components.len());
        for comp in &self.components {
            let bv = comp.branch_var_count();
            if bv > 0 {
                branch_of_comp.push(Some(node_count + branch_count));
                branch_count += bv;
            } else {
                branch_of_comp.push(None);
            }
        }

        let mut vsrc_nodes = vec![false; node_count];
        for comp in &self.components {
            if comp.fault != FaultKind::None {
                continue;
            }
            if matches!(
                comp.kind,
                ComponentKind::DcVoltage { .. }
                    | ComponentKind::AcVoltage { .. }
                    | ComponentKind::FunctionGen { .. }
                    | ComponentKind::PulseVoltage { .. }
                    | ComponentKind::PwlSource { .. }
                    | ComponentKind::Vcvs { .. }
                    | ComponentKind::Ccvs { .. }
            ) {
                for &n in &comp.nodes[..2] {
                    if n != GND {
                        if let Some(&idx) = node_map.get(&n) {
                            vsrc_nodes[idx] = true;
                        }
                    }
                }
            }
        }

        let node_degree: Vec<u16> = all_nodes
            .iter()
            .map(|n| {
                node_use_count
                    .get(n)
                    .copied()
                    .unwrap_or(0)
                    .min(u16::MAX as usize) as u16
            })
            .collect();

        Ok(CompiledTopology {
            node_map,
            comp_map,
            node_count,
            branch_count,
            branch_of_comp,
            vsrc_nodes,
            node_degree,
        })
    }
}
