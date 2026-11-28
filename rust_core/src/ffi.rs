use crate::digital::{minimize_truth_table_dc, GateKind};
use crate::error::{SimError, SimErrorCode};
use crate::instruments::compute_fft_magnitudes;
use crate::mna::engine::SimEngine;
use crate::netlist::{Component, ComponentKind, FaultKind, WaveShape};

/// Opaque handle exposed to Flutter `dart:ffi`.
pub struct SimHandle {
    engine: SimEngine,
    last_error: SimError,
}

impl SimHandle {
    fn set_err(&mut self, err: SimError) -> i32 {
        self.last_error = err;
        err.code as i32
    }

    fn clear_err(&mut self) -> i32 {
        self.last_error = SimError::new(SimErrorCode::Ok, 0);
        0
    }
}

/// Executes an FFI closure inside `catch_unwind` so Rust panics never unwind across `extern "C"`.
fn ffi_guard<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(fallback)
}

fn is_optional_nan_param(comp_type: i32, idx: usize) -> bool {
    matches!((comp_type, idx), (3 | 4, 1) | (22 | 63, 1 | 2))
}

#[no_mangle]
pub extern "C" fn ob_sim_create() -> *mut SimHandle {
    ffi_guard(std::ptr::null_mut(), || {
        Box::into_raw(Box::new(SimHandle {
            engine: SimEngine::new(),
            last_error: SimError::new(SimErrorCode::Ok, 0),
        }))
    })
}

/// # Safety
/// Caller must pass a pointer returned by `ob_sim_create` (at most once) or null.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_destroy(ptr: *mut SimHandle) {
    ffi_guard((), || {
        if !ptr.is_null() {
            drop(Box::from_raw(ptr));
        }
    });
}

/// # Safety
/// `ptr` must be null or a valid handle returned by `ob_sim_create`.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_clear(ptr: *mut SimHandle) -> i32 {
    ffi_guard(SimErrorCode::InvalidParameter as i32, || {
        let Some(handle) = ptr.as_mut() else {
            return SimErrorCode::NullHandle as i32;
        };
        handle.engine.clear();
        handle.clear_err()
    })
}

/// # Safety
/// `ptr` must be null or a valid handle returned by `ob_sim_create`.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_add_component_ex(
    ptr: *mut SimHandle,
    id: u32,
    comp_type: i32,
    pins: *const u32,
    pin_count: u32,
    params: *const f64,
    param_count: u32,
) -> i32 {
    ffi_guard(SimErrorCode::InvalidParameter as i32, || {
        let Some(handle) = ptr.as_mut() else {
            return SimErrorCode::NullHandle as i32;
        };
        if pin_count > 8
            || param_count > 32
            || (pin_count > 0 && pins.is_null())
            || (param_count > 0 && params.is_null())
        {
            return handle.set_err(SimError::new(SimErrorCode::InvalidParameter, 0));
        }
        let mut pin_buf = [0u32; 8];
        for (i, slot) in pin_buf.iter_mut().take(pin_count as usize).enumerate() {
            *slot = std::ptr::read_unaligned(pins.add(i));
        }
        let mut param_buf = [0.0f64; 32];
        for (i, slot) in param_buf.iter_mut().take(param_count as usize).enumerate() {
            *slot = std::ptr::read_unaligned(params.add(i));
        }
        add_component_inner(
            handle,
            id,
            comp_type,
            &pin_buf[..pin_count as usize],
            &param_buf[..param_count as usize],
        )
    })
}

fn add_component_inner(
    handle: &mut SimHandle,
    id: u32,
    comp_type: i32,
    pins: &[u32],
    params: &[f64],
) -> i32 {
    if params
        .iter()
        .enumerate()
        .any(|(i, v)| !v.is_finite() && !is_optional_nan_param(comp_type, i))
    {
        return handle.set_err(SimError::new(SimErrorCode::InvalidParameter, id as i32));
    }
    let p_opt = |idx: usize| params.get(idx).copied().filter(|v| v.is_finite());
    let p = |idx: usize| p_opt(idx).unwrap_or(0.0);
    let p0 = p(0);
    let p1 = p(1);
    let p2 = p(2);
    let p3 = p(3);
    let p4 = p(4);

    let (kind, pin_count) = match comp_type {
        1 => (ComponentKind::Resistor { r: p0 }, 2),
        2 => (
            ComponentKind::Potentiometer {
                r_total: p0,
                wiper: p1,
            },
            3,
        ),
        3 => (
            ComponentKind::Capacitor {
                c: p0,
                ic: p_opt(1),
            },
            2,
        ),
        4 => (
            ComponentKind::Inductor {
                l: p0,
                ic: p_opt(1),
            },
            2,
        ),
        5 => (
            ComponentKind::SwitchSpst {
                closed: p0 >= 0.5,
                r_on: if p1 > 0.0 { p1 } else { 1e-3 },
                r_off: if p2 > 0.0 { p2 } else { 1e9 },
            },
            2,
        ),
        6 => (
            ComponentKind::Fuse {
                i_max: p0,
                r_on: if p1 > 0.0 { p1 } else { 0.05 },
                blown: false,
            },
            2,
        ),
        7 => (
            ComponentKind::SwitchSpdt {
                throw_b: p0 >= 0.5,
                r_on: if p1 > 0.0 { p1 } else { 1e-3 },
                r_off: if p2 > 0.0 { p2 } else { 1e9 },
            },
            3,
        ),
        10 => (ComponentKind::DcVoltage { v: p0 }, 2),
        11 => (
            ComponentKind::AcVoltage {
                amp: p0,
                freq: p1,
                phase_deg: p2,
                offset: p3,
            },
            2,
        ),
        12 => {
            let shape = match p0 as i32 {
                1 => WaveShape::Square,
                2 => WaveShape::Triangle,
                _ => WaveShape::Sine,
            };
            (
                ComponentKind::FunctionGen {
                    shape,
                    amp: p1,
                    freq: p2,
                    offset: p3,
                    duty: if p4 > 0.0 { p4 } else { 0.5 },
                },
                2,
            )
        }
        13 => (ComponentKind::DcCurrent { i: p0 }, 2),
        14 => (ComponentKind::Vcvs { gain: p0 }, 4),
        15 => (ComponentKind::Vccs { gm: p0 }, 4),
        16 => (ComponentKind::Cccs { gain: p0 }, 4),
        17 => (ComponentKind::Ccvs { rm: p0 }, 4),
        20 => (
            ComponentKind::Diode {
                is_sat: if p0 > 0.0 { p0 } else { 1e-12 },
                n: if p1 > 0.0 { p1 } else { 1.5 },
                bv: if p2 > 0.0 { p2 } else { f64::INFINITY },
            },
            2,
        ),
        21 => (
            ComponentKind::Led {
                is_sat: if p0 > 0.0 { p0 } else { 1e-18 },
                n: if p1 > 0.0 { p1 } else { 2.0 },
            },
            2,
        ),
        22 => (
            ComponentKind::OpAmp {
                gain: if p0 > 0.0 { p0 } else { 1e5 },
                v_sat_pos: p_opt(1).unwrap_or(15.0),
                v_sat_neg: p_opt(2).unwrap_or(-15.0),
                r_out: if p3 > 0.0 { p3 } else { 50.0 },
            },
            3,
        ),
        23 => (
            ComponentKind::NpnBjt {
                is_sat: if p0 > 0.0 { p0 } else { 1e-14 },
                bf: if p1 > 0.0 { p1 } else { 100.0 },
                br: if p2 > 0.0 { p2 } else { 1.0 },
            },
            3,
        ),
        24 => (
            ComponentKind::PnpBjt {
                is_sat: if p0 > 0.0 { p0 } else { 1e-14 },
                bf: if p1 > 0.0 { p1 } else { 100.0 },
                br: if p2 > 0.0 { p2 } else { 1.0 },
            },
            3,
        ),
        25 => (
            ComponentKind::Nmos {
                kp: if p0 > 0.0 { p0 } else { 2e-3 },
                vth: p1,
                lambda: p2.max(0.0),
            },
            3,
        ),
        26 => (
            ComponentKind::Pmos {
                kp: if p0 > 0.0 { p0 } else { 2e-3 },
                vth: p1,
                lambda: p2.max(0.0),
            },
            3,
        ),
        30..=35 | 37 => {
            let gate = match comp_type {
                30 => GateKind::And,
                31 => GateKind::Or,
                32 => GateKind::Not,
                33 => GateKind::Nand,
                34 => GateKind::Nor,
                37 => GateKind::Xnor,
                _ => GateKind::Xor,
            };
            let pins = if gate == GateKind::Not { 2 } else { 3 };
            (
                ComponentKind::DigitalGate {
                    kind: gate,
                    v_high: if p0 > 0.0 { p0 } else { 5.0 },
                    r_out: if p1 > 0.0 { p1 } else { 50.0 },
                },
                pins,
            )
        }
        36 => (
            ComponentKind::ClockSource {
                freq: p0.max(0.0),
                v_high: if p1 > 0.0 { p1 } else { 5.0 },
                r_out: if p2 > 0.0 { p2 } else { 50.0 },
            },
            2,
        ),
        38 => (
            ComponentKind::DFlipFlop {
                v_high: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            4,
        ),
        39 => (
            ComponentKind::LogicProbe {
                r_in: if p0 > 0.0 { p0 } else { 1e7 },
            },
            1,
        ),
        40 => (
            ComponentKind::Timer555 {
                v_cc: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            4,
        ),
        41 => (
            ComponentKind::SevenSeg {
                r_in: if p0 > 0.0 { p0 } else { 1e7 },
            },
            4,
        ),
        42 => (
            ComponentKind::Transformer {
                ratio: if p0 != 0.0 { p0 } else { 1.0 },
            },
            4,
        ),
        43 => (
            ComponentKind::Relay {
                r_coil: if p0 > 0.0 { p0 } else { 100.0 },
                v_pull: if p1 > 0.0 { p1 } else { 3.0 },
                r_on: if p2 > 0.0 { p2 } else { 1e-3 },
                r_off: if p3 > 0.0 { p3 } else { 1e9 },
            },
            4,
        ),
        44 => (
            ComponentKind::Resistor {
                r: if p0 > 0.0 { p0 } else { 50.0 },
            },
            2,
        ),
        45 => (
            ComponentKind::SwitchSpst {
                closed: p0 >= 0.5,
                r_on: if p1 > 0.0 { p1 } else { 1e-3 },
                r_off: if p2 > 0.0 { p2 } else { 1e9 },
            },
            2,
        ),
        46 => (
            ComponentKind::WordGen {
                freq: p0.max(0.0),
                pattern: if p1 > 0.0 {
                    p1 as u64
                } else {
                    0xFEDC_BA98_7654_3210
                },
                v_high: if p2 > 0.0 { p2 } else { 5.0 },
                r_out: if p3 > 0.0 { p3 } else { 50.0 },
            },
            4,
        ),
        47 => (
            ComponentKind::Optocoupler {
                ctr: if p0 > 0.0 { p0 } else { 1.0 },
                is_sat: if p1 > 0.0 { p1 } else { 1e-16 },
                n: if p2 > 0.0 { p2 } else { 1.8 },
            },
            4,
        ),
        48 => (
            ComponentKind::SchmittTrigger {
                v_hyst: if p0 >= 0.0 { p0 } else { 0.5 },
                v_high: if p1 > 0.0 { p1 } else { 5.0 },
                r_out: if p2 > 0.0 { p2 } else { 50.0 },
            },
            3,
        ),
        49 => (
            ComponentKind::Counter4Bit {
                v_high: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            4,
        ),
        50 => (
            ComponentKind::AcCurrent {
                amp: p0,
                freq: p1.max(0.0),
                phase_deg: p2,
                offset: p3,
            },
            2,
        ),
        51 => (
            ComponentKind::PulseVoltage {
                v1: p0,
                v2: if params.len() > 1 { p1 } else { 5.0 },
                td: p2.max(0.0),
                tr: if p3 > 0.0 { p3 } else { 1e-6 },
                tf: if p4 > 0.0 { p4 } else { 1e-6 },
                pw: if p(5) > 0.0 { p(5) } else { 0.5e-3 },
                per: if p(6) > 0.0 { p(6) } else { 1e-3 },
            },
            2,
        ),
        52 => (
            ComponentKind::VControlledSwitch {
                v_on: p_opt(0).unwrap_or(2.5),
                v_off: p1,
                r_on: if p2 > 0.0 { p2 } else { 1e-2 },
                r_off: if p3 > 0.0 { p3 } else { 1e9 },
            },
            4,
        ),
        53 => (
            ComponentKind::IControlledSwitch {
                i_on: p_opt(0).unwrap_or(0.01),
                i_off: p1,
                r_on: if p2 > 0.0 { p2 } else { 1e-2 },
                r_off: if p3 > 0.0 { p3 } else { 1e9 },
            },
            4,
        ),
        54 => (
            ComponentKind::BridgeRectifier {
                is_sat: if p0 > 0.0 { p0 } else { 1e-12 },
                n: if p1 > 0.0 { p1 } else { 1.5 },
            },
            4,
        ),
        55 | 56 => {
            let beta = if p0 > 0.0 { p0 } else { 1e-3 };
            let vto = p_opt(1).unwrap_or(-2.0);
            let lambda = p2.max(0.0);
            if comp_type == 55 {
                (ComponentKind::Njfet { beta, vto, lambda }, 3)
            } else {
                (ComponentKind::Pjfet { beta, vto, lambda }, 3)
            }
        }
        57 => (
            ComponentKind::Scr {
                i_hold: if p0 > 0.0 { p0 } else { 0.005 },
                v_bo: if p1 > 0.0 { p1 } else { 100.0 },
                r_on: if p2 > 0.0 { p2 } else { 0.2 },
                r_off: if p3 > 0.0 { p3 } else { 1e8 },
            },
            3,
        ),
        58 => (
            ComponentKind::Triac {
                i_hold: if p0 > 0.0 { p0 } else { 0.005 },
                v_bo: if p1 > 0.0 { p1 } else { 100.0 },
                r_on: if p2 > 0.0 { p2 } else { 0.2 },
                r_off: if p3 > 0.0 { p3 } else { 1e8 },
            },
            3,
        ),
        59 => (
            ComponentKind::Diac {
                v_bo: if p0 > 0.0 { p0 } else { 30.0 },
                r_on: if p1 > 0.0 { p1 } else { 2.0 },
                r_off: if p2 > 0.0 { p2 } else { 1e8 },
            },
            2,
        ),
        60 => (
            ComponentKind::Igbt {
                kp: if p0 > 0.0 { p0 } else { 2.0 },
                vth: if p1 > 0.0 { p1 } else { 4.0 },
                r_on: if p2 > 0.0 { p2 } else { 0.2 },
            },
            3,
        ),
        61 => (
            ComponentKind::VoltageReg {
                v_out: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 0.2 },
            },
            3,
        ),
        62 => (
            ComponentKind::ComparatorOc {
                r_ol: if p1 > 0.0 { p1 } else { 25.0 },
            },
            3,
        ),
        63 => (
            ComponentKind::InstAmp {
                gain: if p0 != 0.0 { p0 } else { 10.0 },
                v_sat_pos: p_opt(1).unwrap_or(15.0),
                v_sat_neg: p_opt(2).unwrap_or(-15.0),
                r_out: if p3 > 0.0 { p3 } else { 50.0 },
            },
            3,
        ),
        64 => (
            ComponentKind::Vco {
                f0: if p0 >= 0.0 { p0 } else { 100.0 },
                df_dv: p_opt(1).unwrap_or(50.0),
                v_high: if p2 > 0.0 { p2 } else { 5.0 },
                r_out: if p3 > 0.0 { p3 } else { 50.0 },
            },
            2,
        ),
        65 => (
            ComponentKind::AnalogMultiplier {
                gain: p_opt(0).unwrap_or(0.1),
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            3,
        ),
        66 => (
            ComponentKind::SampleHold {
                v_high: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            3,
        ),
        67 => (
            ComponentKind::TriStateBuffer {
                v_high: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            if pins.len() <= 2 { 2 } else { 3 },
        ),
        68 => {
            let gk = match p0.round() as i32 {
                0 => GateKind::And,
                1 => GateKind::Or,
                2 => GateKind::Not,
                3 => GateKind::Nand,
                4 => GateKind::Nor,
                5 => GateKind::Xnor,
                _ => GateKind::Xor,
            };
            let n_in = (p1.round() as u8).clamp(2, 4);
            (
                ComponentKind::DigitalGateMulti {
                    kind: gk,
                    v_high: if p2 > 0.0 { p2 } else { 5.0 },
                    r_out: if p3 > 0.0 { p3 } else { 50.0 },
                },
                n_in + 1,
            )
        }
        69 => (
            ComponentKind::SrLatch {
                v_high: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            4,
        ),
        70 => (
            ComponentKind::JkFlipFlop {
                v_high: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            5,
        ),
        71 => (
            ComponentKind::TFlipFlop {
                v_high: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            4,
        ),
        72 => (
            ComponentKind::DFlipFlopAsync {
                v_high: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            6,
        ),
        73 => (
            ComponentKind::Counter4BitFull {
                v_high: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            8,
        ),
        74 => (
            ComponentKind::ShiftReg4Bit {
                v_high: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            7,
        ),
        75 => (
            ComponentKind::Mux4To1 {
                v_high: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            7,
        ),
        76 => (
            ComponentKind::Demux1To4 {
                v_high: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            7,
        ),
        77 => (
            ComponentKind::Decoder2To4 {
                v_high: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            7,
        ),
        78 => (
            ComponentKind::FullAdder {
                v_high: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            5,
        ),
        79 => (
            ComponentKind::MagComparator {
                v_high: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            7,
        ),
        80 => (
            ComponentKind::Alu2Bit {
                v_high: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            8,
        ),
        81 => (
            ComponentKind::Adc4Bit {
                v_ref: if p0 > 0.0 { p0 } else { 5.0 },
                v_high: if p1 > 0.0 { p1 } else { 5.0 },
                r_out: if p2 > 0.0 { p2 } else { 50.0 },
            },
            6,
        ),
        82 => (
            ComponentKind::Dac4Bit {
                v_ref: if p0 > 0.0 { p0 } else { 5.0 },
                r_out: if p1 > 0.0 { p1 } else { 50.0 },
            },
            6,
        ),
        83 => (
            ComponentKind::HexKeypad {
                nibble: (p0.round() as i32).clamp(0, 15) as u8,
                v_high: if p1 > 0.0 { p1 } else { 5.0 },
                r_out: if p2 > 0.0 { p2 } else { 50.0 },
            },
            4,
        ),
        84 => (
            ComponentKind::DipSwitch4 {
                mask: (p0.round() as i32).clamp(0, 15) as u8,
                r_on: if p1 > 0.0 { p1 } else { 1e-3 },
                r_off: if p2 > 0.0 { p2 } else { 1e9 },
            },
            8,
        ),
        85 => (
            ComponentKind::CoupledInductor {
                l1: if p0 > 0.0 { p0 } else { 1e-2 },
                l2: if p1 > 0.0 { p1 } else { 1e-2 },
                k: p_opt(2).unwrap_or(0.9).clamp(-0.999, 0.999),
            },
            4,
        ),
        86 => (
            ComponentKind::CenterTapTransformer {
                ratio: if p0.abs() > 1e-4 { p0 } else { 2.0 },
            },
            5,
        ),
        87 => (
            ComponentKind::RelayDpdt {
                r_coil: if p0 > 0.0 { p0 } else { 100.0 },
                v_pull: if p1 > 0.0 { p1 } else { 3.0 },
                r_on: if p2 > 0.0 { p2 } else { 1e-3 },
                r_off: if p3 > 0.0 { p3 } else { 1e9 },
            },
            if pins.len() <= 5 { 5 } else { 8 },
        ),
        88 => (
            ComponentKind::Crystal {
                rm: if p0 > 0.0 { p0 } else { 50.0 },
                lm: if p1 > 0.0 { p1 } else { 1e-2 },
                cm: if p2 > 0.0 { p2 } else { 1e-13 },
                c0: if p3 > 0.0 { p3 } else { 5e-12 },
            },
            2,
        ),
        89 => (
            ComponentKind::DcMotor {
                r_a: if p0 > 0.0 { p0 } else { 5.0 },
                ke: if p1 >= 0.0 { p1 } else { 0.1 },
            },
            2,
        ),
        90 => (
            ComponentKind::Wattmeter {
                r_shunt: if p0 > 0.0 { p0 } else { 1e-3 },
            },
            4,
        ),
        91 => (
            ComponentKind::PwlSource {
                pts: [[p0, p1], [p2, p3], [p4, p(5)], [p(6), p(7)]],
                count: (params.len() / 2).clamp(1, 4) as u8,
            },
            2,
        ),
        92 => (
            ComponentKind::BarGraphLed {
                is_sat: if p0 > 0.0 { p0 } else { 1e-18 },
                n: if p1 > 0.0 { p1 } else { 2.0 },
            },
            5,
        ),
        93 => (
            ComponentKind::RgbLed {
                is_sat: if p0 > 0.0 { p0 } else { 1e-18 },
                n: if p1 > 0.0 { p1 } else { 2.0 },
            },
            4,
        ),
        94 => (
            ComponentKind::VaractorDiode {
                cj0: if p0 > 0.0 { p0 } else { 30e-12 },
                vj: if p1 > 0.0 { p1 } else { 0.7 },
                m: if p2 > 0.0 { p2 } else { 0.5 },
                is_sat: if p3 > 0.0 { p3 } else { 1e-12 },
            },
            2,
        ),
        _ => return handle.set_err(SimError::new(SimErrorCode::UnknownComponent, comp_type)),
    };

    let mut nodes = [0u32; 8];
    let copy_n = pins.len().min(8);
    nodes[..copy_n].copy_from_slice(&pins[..copy_n]);
    let comp = Component {
        id,
        name: format!("C{id}"),
        kind,
        nodes,
        pin_count,
        fault: FaultKind::None,
    };

    match handle.engine.circuit.add(comp) {
        Ok(()) => {
            handle.engine.topo = None;
            handle.clear_err()
        }
        Err(e) => handle.set_err(e),
    }
}

/// # Safety
/// `ptr` must be null or a valid handle returned by `ob_sim_create`.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_set_scope_probe(ptr: *mut SimHandle, ch: u32, node_id: i32) -> i32 {
    ffi_guard(SimErrorCode::InvalidParameter as i32, || {
        let Some(handle) = ptr.as_mut() else {
            return SimErrorCode::NullHandle as i32;
        };
        if ch >= 4 {
            return handle.set_err(SimError::new(SimErrorCode::InvalidParameter, ch as i32));
        }
        handle.engine.scope_nodes[ch as usize] = if node_id < 0 {
            None
        } else {
            Some(node_id as u32)
        };
        handle.clear_err()
    })
}

/// # Safety
/// `ptr` must be null or a valid handle returned by `ob_sim_create`.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_solve_dc(ptr: *mut SimHandle) -> i32 {
    ffi_guard(SimErrorCode::InvalidParameter as i32, || {
        let Some(handle) = ptr.as_mut() else {
            return SimErrorCode::NullHandle as i32;
        };
        match handle.engine.compile_and_dc() {
            Ok(()) => handle.clear_err(),
            Err(e) => handle.set_err(e),
        }
    })
}

/// # Safety
/// `ptr` must be null or a valid handle returned by `ob_sim_create`.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_solve_dc_op(ptr: *mut SimHandle) -> i32 {
    ffi_guard(SimErrorCode::InvalidParameter as i32, || {
        let Some(handle) = ptr.as_mut() else {
            return SimErrorCode::NullHandle as i32;
        };
        match handle.engine.solve_dc_op() {
            Ok(()) => handle.clear_err(),
            Err(e) => handle.set_err(e),
        }
    })
}

/// # Safety
/// `ptr` must be null or a valid handle returned by `ob_sim_create`.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_set_wordgen_pattern(
    ptr: *mut SimHandle,
    comp_id: u32,
    pattern: u64,
) -> i32 {
    ffi_guard(SimErrorCode::InvalidParameter as i32, || {
        let Some(handle) = ptr.as_mut() else {
            return SimErrorCode::NullHandle as i32;
        };
        match handle.engine.set_wordgen_pattern(comp_id, pattern) {
            Ok(()) => handle.clear_err(),
            Err(e) => handle.set_err(e),
        }
    })
}

/// # Safety
/// `ptr` must be null or a valid handle; `out_time` must be null or writable.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_step_frame(
    ptr: *mut SimHandle,
    sim_dt: f64,
    max_substeps: u32,
    out_time: *mut f64,
) -> i32 {
    ffi_guard(SimErrorCode::InvalidParameter as i32, || {
        let Some(handle) = ptr.as_mut() else {
            return SimErrorCode::NullHandle as i32;
        };
        match handle.engine.run_for_frame(sim_dt, max_substeps as usize) {
            Ok(()) => {
                if !out_time.is_null() {
                    *out_time = handle.engine.t_sim;
                }
                handle.clear_err()
            }
            Err(e) => handle.set_err(e),
        }
    })
}

/// # Safety
/// `ptr` must be null or a valid handle returned by `ob_sim_create`.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_set_control(
    ptr: *mut SimHandle,
    comp_id: u32,
    param_idx: u32,
    value: f64,
) -> i32 {
    ffi_guard(SimErrorCode::InvalidParameter as i32, || {
        let Some(handle) = ptr.as_mut() else {
            return SimErrorCode::NullHandle as i32;
        };
        match handle.engine.set_control(comp_id, param_idx, value) {
            Ok(()) => handle.clear_err(),
            Err(e) => handle.set_err(e),
        }
    })
}

/// # Safety
/// `ptr` must be null or a valid handle returned by `ob_sim_create`.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_get_node_voltage(ptr: *mut SimHandle, node_id: u32) -> f64 {
    ffi_guard(0.0, || {
        let Some(handle) = ptr.as_ref() else {
            return 0.0;
        };
        handle.engine.node_voltage(node_id)
    })
}

/// # Safety
/// `ptr` must be null or a valid handle returned by `ob_sim_create`.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_get_component_current(ptr: *mut SimHandle, comp_id: u32) -> f64 {
    ffi_guard(0.0, || {
        let Some(handle) = ptr.as_ref() else {
            return 0.0;
        };
        handle.engine.component_current(comp_id)
    })
}

/// # Safety
/// `ptr` must be null or a valid handle returned by `ob_sim_create`.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_last_error_code(ptr: *mut SimHandle) -> i32 {
    ffi_guard(SimErrorCode::InvalidParameter as i32, || {
        let Some(handle) = ptr.as_ref() else {
            return SimErrorCode::NullHandle as i32;
        };
        handle.last_error.code as i32
    })
}

/// # Safety
/// `ptr` must be null or a valid handle returned by `ob_sim_create`.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_last_error_detail(ptr: *mut SimHandle) -> i32 {
    ffi_guard(0, || {
        let Some(handle) = ptr.as_ref() else {
            return 0;
        };
        handle.last_error.detail_id
    })
}

/// # Safety
/// `ptr` must be null or a valid handle returned by `ob_sim_create`.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_set_fault(
    ptr: *mut SimHandle,
    comp_id: u32,
    fault_code: i32,
) -> i32 {
    ffi_guard(SimErrorCode::InvalidParameter as i32, || {
        let Some(handle) = ptr.as_mut() else {
            return SimErrorCode::NullHandle as i32;
        };
        let fault = match fault_code {
            0 => FaultKind::None,
            1 => FaultKind::Open,
            2 => FaultKind::Short,
            3 => FaultKind::Leaky,
            _ => return handle.set_err(SimError::new(SimErrorCode::InvalidParameter, fault_code)),
        };
        match handle.engine.set_fault(comp_id, fault) {
            Ok(()) => handle.clear_err(),
            Err(e) => handle.set_err(e),
        }
    })
}

/// # Safety
/// `ptr` must be null or a valid handle; non-null output pointers must be writable.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_channel_stats(
    ptr: *const SimHandle,
    ch: u32,
    out_dc: *mut f64,
    out_rms: *mut f64,
    out_min: *mut f64,
    out_max: *mut f64,
) -> i32 {
    ffi_guard(SimErrorCode::InvalidParameter as i32, || {
        let Some(handle) = ptr.as_ref() else {
            return SimErrorCode::NullHandle as i32;
        };
        if ch >= 4 {
            return SimErrorCode::InvalidParameter as i32;
        }
        let (dc, rms, min_v, max_v) = handle.engine.scope.channel_stats(ch as usize);
        if !out_dc.is_null() {
            *out_dc = dc;
        }
        if !out_rms.is_null() {
            *out_rms = rms;
        }
        if !out_min.is_null() {
            *out_min = min_v;
        }
        if !out_max.is_null() {
            *out_max = max_v;
        }
        SimErrorCode::Ok as i32
    })
}

/// # Safety
/// `ptr` must be null or a valid handle; `out_mags` must hold `max_bins` doubles.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_scope_fft(
    ptr: *const SimHandle,
    ch: u32,
    out_mags: *mut f64,
    max_bins: usize,
) -> usize {
    ffi_guard(0, || {
        let Some(handle) = ptr.as_ref() else {
            return 0;
        };
        if ch >= 4 || out_mags.is_null() || max_bins == 0 {
            return 0;
        }
        let uniform = handle.engine.scope.resample_uniform(ch as usize, 512);
        if uniform.len() < 4 {
            return 0;
        }
        let mags = compute_fft_magnitudes(&uniform);
        let count = mags.len().min(max_bins);
        for (i, &m) in mags.iter().take(count).enumerate() {
            *out_mags.add(i) = m;
        }
        count
    })
}

/// # Safety
/// `ptr` must be null or a valid handle returned by `ob_sim_create`.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_scope_fft_dt(ptr: *const SimHandle) -> f64 {
    ffi_guard(0.0, || {
        let Some(handle) = ptr.as_ref() else {
            return 0.0;
        };
        handle.engine.scope.resample_uniform_dt(512)
    })
}

fn resolve_scope_window(
    scope: &crate::instruments::ScopeBuffer,
    trig_ch: i32,
    trig_level: f64,
    rising: bool,
    require_trig: bool,
    max_len: usize,
) -> Option<(usize, usize)> {
    let samples = &scope.samples;
    if samples.is_empty() || max_len == 0 {
        return None;
    }
    let count = samples.len().min(max_len);
    let mut skip = samples.len() - count;
    if trig_ch >= 0 {
        let tch = trig_ch as usize;
        if tch >= 4 {
            return None;
        }
        let pre = count / 4;
        let post = count.saturating_sub(pre);
        let search_end = samples.len().saturating_sub(post).max(1);
        let mut trig_idx = (1..search_end).rev().find(|&i| {
            let prev = samples[i - 1].ch[tch];
            let curr = samples[i].ch[tch];
            (rising && prev < trig_level && curr >= trig_level)
                || (!rising && prev > trig_level && curr <= trig_level)
        });
        if trig_idx.is_none() {
            trig_idx = scope.find_trigger_index(tch, trig_level, rising);
        }
        match trig_idx {
            Some(t_idx) if samples.len() > count => {
                skip = t_idx.saturating_sub(pre).min(samples.len() - count);
            }
            None if require_trig => return None,
            _ => {}
        }
    }
    Some((skip, count))
}

/// Reads all 4 oscilloscope channels in a single trigger-resolved pass.
///
/// # Safety
/// `ptr` must be null or a valid handle; any non-null output buffer must hold `max_len` doubles.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ob_sim_read_scope_4ch(
    ptr: *const SimHandle,
    trig_ch: i32,
    trig_level: f64,
    rising: i32,
    require_trig: i32,
    out_times: *mut f64,
    out_ch0: *mut f64,
    out_ch1: *mut f64,
    out_ch2: *mut f64,
    out_ch3: *mut f64,
    max_len: usize,
) -> usize {
    ffi_guard(0, || {
        let Some(handle) = ptr.as_ref() else {
            return 0;
        };
        let Some((skip, count)) = resolve_scope_window(
            &handle.engine.scope,
            trig_ch,
            trig_level,
            rising != 0,
            require_trig != 0,
            max_len,
        ) else {
            return 0;
        };
        for (i, s) in handle
            .engine
            .scope
            .samples
            .iter()
            .skip(skip)
            .take(count)
            .enumerate()
        {
            if !out_times.is_null() {
                *out_times.add(i) = s.t;
            }
            if !out_ch0.is_null() {
                *out_ch0.add(i) = s.ch[0];
            }
            if !out_ch1.is_null() {
                *out_ch1.add(i) = s.ch[1];
            }
            if !out_ch2.is_null() {
                *out_ch2.add(i) = s.ch[2];
            }
            if !out_ch3.is_null() {
                *out_ch3.add(i) = s.ch[3];
            }
        }
        count
    })
}

/// Quine-McCluskey minimization supporting 1..=8 variables and Don't-Care (`2`) outputs.
///
/// # Safety
/// `outputs` must hold `outputs_len` bytes; `out_utf8` must be null or hold `max_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn ob_logic_minimize_ex(
    var_count: u32,
    outputs: *const u8,
    outputs_len: usize,
    out_utf8: *mut u8,
    max_len: usize,
) -> usize {
    ffi_guard(0, || {
        if !(1..=8).contains(&var_count) || outputs.is_null() {
            return 0;
        }
        let rows = 1usize << var_count;
        if outputs_len < rows {
            return 0;
        }
        let slice = std::slice::from_raw_parts(outputs, rows);
        let expr = minimize_truth_table_dc(var_count as usize, slice);
        let bytes = expr.as_bytes();
        if !out_utf8.is_null() && max_len > 0 {
            let count = bytes.len().min(max_len);
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_utf8, count);
        }
        bytes.len()
    })
}

/// Configures up to 16 digital logic analyzer probes (`< 0` clears a channel).
///
/// # Safety
/// `ptr` must be null or a valid handle; `nodes` must be writable/readable for `count` i32s if `count > 0`.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_set_logic_probes(
    ptr: *mut SimHandle,
    nodes: *const i32,
    count: u32,
    threshold: f64,
) -> i32 {
    ffi_guard(SimErrorCode::InvalidParameter as i32, || {
        let Some(handle) = ptr.as_mut() else {
            return SimErrorCode::NullHandle as i32;
        };
        if count > 16 || (count > 0 && nodes.is_null()) {
            return handle.set_err(SimError::new(SimErrorCode::InvalidParameter, count as i32));
        }
        if threshold.is_finite() && threshold > 0.0 {
            handle.engine.logic_threshold = threshold;
        }
        handle.engine.logic_nodes.fill(None);
        for (i, slot) in handle
            .engine
            .logic_nodes
            .iter_mut()
            .take(count as usize)
            .enumerate()
        {
            let n = std::ptr::read_unaligned(nodes.add(i));
            *slot = if n < 0 { None } else { Some(n as u32) };
        }
        handle.clear_err()
    })
}

/// Reads buffered 16-channel logic analyzer timestamps and bitmasks.
///
/// # Safety
/// `ptr` must be null or a valid handle; `out_times` and `out_masks` must hold `max_len` entries.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_read_logic(
    ptr: *const SimHandle,
    out_times: *mut f64,
    out_masks: *mut u16,
    max_len: usize,
) -> usize {
    ffi_guard(0, || {
        let Some(handle) = ptr.as_ref() else {
            return 0;
        };
        if out_times.is_null() || out_masks.is_null() || max_len == 0 {
            return 0;
        }
        let samples = &handle.engine.logic_samples;
        let count = samples.len().min(max_len);
        let skip = samples.len() - count;
        for (i, &(t, mask)) in samples.iter().skip(skip).take(count).enumerate() {
            *out_times.add(i) = t;
            *out_masks.add(i) = mask;
        }
        count
    })
}

unsafe fn measure_two_terminal_ffi(
    ptr: *mut SimHandle,
    node_a: u32,
    node_b: u32,
    diode_mode: bool,
    out_val: *mut f64,
) -> i32 {
    ffi_guard(SimErrorCode::InvalidParameter as i32, || {
        let Some(handle) = ptr.as_mut() else {
            return SimErrorCode::NullHandle as i32;
        };
        if out_val.is_null() {
            return handle.set_err(SimError::new(SimErrorCode::InvalidParameter, 0));
        }
        match handle
            .engine
            .measure_two_terminal(node_a, node_b, diode_mode)
        {
            Ok(v) => {
                *out_val = v;
                handle.clear_err()
            }
            Err(e) => handle.set_err(e),
        }
    })
}

/// Measures unpowered DC resistance between `node_a` and `node_b` in Ohms.
///
/// # Safety
/// `ptr` must be null or a valid handle; `out_ohms` must be writable.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_measure_resistance(
    ptr: *mut SimHandle,
    node_a: u32,
    node_b: u32,
    out_ohms: *mut f64,
) -> i32 {
    measure_two_terminal_ffi(ptr, node_a, node_b, false, out_ohms)
}

/// Measures forward diode junction drop (V) at 1 mA between `node_a` and `node_b`.
///
/// # Safety
/// `ptr` must be null or a valid handle; `out_volts` must be writable.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_measure_diode(
    ptr: *mut SimHandle,
    node_a: u32,
    node_b: u32,
    out_volts: *mut f64,
) -> i32 {
    measure_two_terminal_ffi(ptr, node_a, node_b, true, out_volts)
}

/// # Safety
/// `ptr` must be null or a valid handle; `out_utf8` must be null (size query) or writable for `max_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn ob_sim_export_cir(
    ptr: *const SimHandle,
    out_utf8: *mut u8,
    max_len: usize,
) -> usize {
    ffi_guard(0, || {
        let Some(handle) = ptr.as_ref() else {
            return 0;
        };
        let cir = crate::spice_io::export_cir("BenchOsc Schematic", &handle.engine.circuit);
        let bytes = cir.as_bytes();
        if !out_utf8.is_null() && max_len > 0 {
            let count = bytes.len().min(max_len);
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_utf8, count);
        }
        bytes.len()
    })
}

/// Single-pass parallel AC sweep returning `V(out_node)` or `V(out_node)/V(in_node)` when `in_node > 0`.
///
/// # Safety
/// `ptr` must be null or a valid handle; `out_freqs`, `out_mag_db`, `out_phase_deg` must hold `max_len` doubles.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ob_sim_ac_sweep_transfer(
    ptr: *mut SimHandle,
    f_start: f64,
    f_stop: f64,
    pts_per_dec: u32,
    ac_src_id: u32,
    in_node: i32,
    out_node: u32,
    out_freqs: *mut f64,
    out_mag_db: *mut f64,
    out_phase_deg: *mut f64,
    max_len: usize,
) -> i32 {
    ffi_guard(-(SimErrorCode::InvalidParameter as i32), || {
        let Some(handle) = ptr.as_mut() else {
            return -(SimErrorCode::NullHandle as i32);
        };
        if out_freqs.is_null() || out_mag_db.is_null() || out_phase_deg.is_null() || max_len == 0 {
            return -handle.set_err(SimError::new(SimErrorCode::InvalidParameter, 0));
        }
        let in_opt = if in_node > 0 {
            Some(in_node as u32)
        } else {
            None
        };
        match handle.engine.solve_ac_sweep_transfer(
            f_start,
            f_stop,
            pts_per_dec as usize,
            ac_src_id,
            in_opt,
            out_node,
        ) {
            Ok(pts) => {
                let count = pts.len().min(max_len);
                for (i, pt) in pts.iter().take(count).enumerate() {
                    *out_freqs.add(i) = pt.freq_hz;
                    *out_mag_db.add(i) = pt.mag_db;
                    *out_phase_deg.add(i) = pt.phase_deg;
                }
                handle.clear_err();
                count.min(i32::MAX as usize) as i32
            }
            Err(e) => -handle.set_err(e),
        }
    })
}

/// Parallel Monte Carlo DC sweep supporting Uniform (`gaussian == 0`) and Gaussian (`gaussian != 0`).
/// Returns sample count written to `out_samples` (`>= 0`) or a negative error code.
///
/// # Safety
/// `ptr` must be null or a valid handle; non-null output pointers must be writable (`out_samples` must hold `max_samples` doubles if non-null).
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ob_sim_monte_carlo_dc_ex(
    ptr: *mut SimHandle,
    tol: f64,
    runs: u32,
    out_node: u32,
    gaussian: i32,
    out_min: *mut f64,
    out_max: *mut f64,
    out_mean: *mut f64,
    out_std: *mut f64,
    out_samples: *mut f64,
    max_samples: usize,
) -> i32 {
    ffi_guard(-(SimErrorCode::InvalidParameter as i32), || {
        let Some(handle) = ptr.as_mut() else {
            return -(SimErrorCode::NullHandle as i32);
        };
        match handle
            .engine
            .monte_carlo_dc_ex(tol, runs as usize, out_node, gaussian != 0)
        {
            Ok((min_v, max_v, mean_v, std_v, samples)) => {
                if !out_min.is_null() {
                    *out_min = min_v;
                }
                if !out_max.is_null() {
                    *out_max = max_v;
                }
                if !out_mean.is_null() {
                    *out_mean = mean_v;
                }
                if !out_std.is_null() {
                    *out_std = std_v;
                }
                let written = if !out_samples.is_null() && max_samples > 0 {
                    let count = samples.len().min(max_samples);
                    std::ptr::copy_nonoverlapping(samples.as_ptr(), out_samples, count);
                    count
                } else {
                    0
                };
                handle.clear_err();
                written.min(i32::MAX as usize) as i32
            }
            Err(e) => -handle.set_err(e),
        }
    })
}

/// Batches per-frame node voltage and component current/power/overload/blown-fuse reads into one FFI call.
/// `out_comp_flags` bits: bit 0 = overloaded, bit 1 = fuse blown.
///
/// # Safety
/// `ptr` must be null or a valid handle; buffers must be non-null and writable for their respective counts when count > 0.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ob_sim_read_frame_state(
    ptr: *const SimHandle,
    node_ids: *const u32,
    node_count: usize,
    out_node_v: *mut f64,
    comp_ids: *const u32,
    comp_count: usize,
    out_comp_i: *mut f64,
    out_comp_p: *mut f64,
    out_comp_flags: *mut u8,
) -> i32 {
    ffi_guard(SimErrorCode::InvalidParameter as i32, || {
        let Some(handle) = ptr.as_ref() else {
            return SimErrorCode::NullHandle as i32;
        };
        if node_count > 0 && (node_ids.is_null() || out_node_v.is_null()) {
            return SimErrorCode::InvalidParameter as i32;
        }
        if comp_count > 0
            && (comp_ids.is_null()
                || out_comp_i.is_null()
                || out_comp_p.is_null()
                || out_comp_flags.is_null())
        {
            return SimErrorCode::InvalidParameter as i32;
        }
        for i in 0..node_count {
            *out_node_v.add(i) = handle.engine.node_voltage(*node_ids.add(i));
        }
        for i in 0..comp_count {
            let cid = *comp_ids.add(i);
            *out_comp_i.add(i) = handle.engine.component_current(cid);
            *out_comp_p.add(i) = handle.engine.component_power(cid);
            let flags = u8::from(handle.engine.component_overloaded(cid))
                | (u8::from(handle.engine.is_fuse_blown(cid)) << 1);
            *out_comp_flags.add(i) = flags;
        }
        SimErrorCode::Ok as i32
    })
}
