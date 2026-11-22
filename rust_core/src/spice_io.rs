use std::collections::BTreeMap;
use std::fmt::Write;

use crate::netlist::{Circuit, ComponentKind, WaveShape};

fn intern_model(
    models: &mut BTreeMap<String, String>,
    base: &str,
    id: u32,
    spec: String,
) -> String {
    let base_card = format!(".model {base} {spec}");
    match models.get(base) {
        None => {
            models.insert(base.to_string(), base_card);
            base.to_string()
        }
        Some(existing) if existing == &base_card => base.to_string(),
        Some(_) => {
            let alt = format!("{base}{id}");
            models.insert(alt.clone(), format!(".model {alt} {spec}"));
            alt
        }
    }
}

/// Exports a `Circuit` to a clean SPICE `.cir` netlist with `.model` cards for interoperability.
pub fn export_cir(title: &str, circuit: &Circuit) -> String {
    let mut out = String::new();
    let mut models: BTreeMap<String, String> = BTreeMap::new();
    let _ = writeln!(out, "* {title}");
    for comp in &circuit.components {
        let p = &comp.nodes;
        match comp.kind {
            ComponentKind::Resistor { r } => {
                let _ = writeln!(out, "R{} {} {} {}", comp.id, p[0], p[1], r);
            }
            ComponentKind::Potentiometer { r_total, wiper } => {
                let w = wiper.clamp(0.001, 0.999);
                let _ = writeln!(
                    out,
                    "R{}a {} {} {}",
                    comp.id,
                    p[0],
                    p[2],
                    r_total * (1.0 - w)
                );
                let _ = writeln!(out, "R{}b {} {} {}", comp.id, p[2], p[1], r_total * w);
            }
            ComponentKind::Capacitor { c, ic } => {
                if let Some(ic_val) = ic {
                    let _ = writeln!(out, "C{} {} {} {} IC={}", comp.id, p[0], p[1], c, ic_val);
                } else {
                    let _ = writeln!(out, "C{} {} {} {}", comp.id, p[0], p[1], c);
                }
            }
            ComponentKind::Inductor { l, ic } => {
                if let Some(ic_val) = ic {
                    let _ = writeln!(out, "L{} {} {} {} IC={}", comp.id, p[0], p[1], l, ic_val);
                } else {
                    let _ = writeln!(out, "L{} {} {} {}", comp.id, p[0], p[1], l);
                }
            }
            ComponentKind::SwitchSpst {
                closed,
                r_on,
                r_off,
            } => {
                let r = if closed { r_on } else { r_off };
                let _ = writeln!(out, "Rsw{} {} {} {}", comp.id, p[0], p[1], r);
            }
            ComponentKind::SwitchSpdt {
                throw_b,
                r_on,
                r_off,
            } => {
                let (ra, rb) = if throw_b {
                    (r_off, r_on)
                } else {
                    (r_on, r_off)
                };
                let _ = writeln!(out, "Rsw{}a {} {} {}", comp.id, p[0], p[1], ra);
                let _ = writeln!(out, "Rsw{}b {} {} {}", comp.id, p[0], p[2], rb);
            }
            ComponentKind::Fuse { r_on, blown, .. } => {
                let r = if blown || comp.fault == crate::netlist::FaultKind::Open {
                    1e9
                } else {
                    r_on
                };
                let _ = writeln!(out, "Rfuse{} {} {} {}", comp.id, p[0], p[1], r);
            }
            ComponentKind::DcVoltage { v } => {
                let _ = writeln!(out, "V{} {} {} DC {}", comp.id, p[0], p[1], v);
            }
            ComponentKind::AcVoltage {
                amp,
                freq,
                phase_deg,
                offset,
            } => {
                let _ = writeln!(
                    out,
                    "V{} {} {} SIN({} {} {} 0 0 {})",
                    comp.id, p[0], p[1], offset, amp, freq, phase_deg
                );
            }
            ComponentKind::FunctionGen {
                shape,
                amp,
                freq,
                offset,
                duty,
            } => match shape {
                WaveShape::Sine => {
                    let _ = writeln!(
                        out,
                        "V{} {} {} SIN({} {} {})",
                        comp.id, p[0], p[1], offset, amp, freq
                    );
                }
                WaveShape::Square => {
                    let period = if freq > 0.0 { 1.0 / freq } else { 1.0 };
                    let pw = period * duty.clamp(0.01, 0.99);
                    let _ = writeln!(
                        out,
                        "V{} {} {} PULSE({} {} 0 1n 1n {} {})",
                        comp.id,
                        p[0],
                        p[1],
                        offset - amp,
                        offset + amp,
                        pw,
                        period
                    );
                }
                WaveShape::Triangle => {
                    let period = if freq > 0.0 { 1.0 / freq } else { 1.0 };
                    let half = 0.5 * period;
                    let _ = writeln!(
                        out,
                        "V{} {} {} PULSE({} {} 0 {} {} 0 {})",
                        comp.id,
                        p[0],
                        p[1],
                        offset - amp,
                        offset + amp,
                        half,
                        half,
                        period
                    );
                }
            },
            ComponentKind::DcCurrent { i } => {
                let _ = writeln!(out, "I{} {} {} DC {}", comp.id, p[0], p[1], i);
            }
            ComponentKind::AcCurrent {
                amp,
                freq,
                phase_deg,
                offset,
            } => {
                let _ = writeln!(
                    out,
                    "I{} {} {} SIN({} {} {} 0 0 {})",
                    comp.id, p[0], p[1], offset, amp, freq, phase_deg
                );
            }
            ComponentKind::PulseVoltage {
                v1,
                v2,
                td,
                tr,
                tf,
                pw,
                per,
            } => {
                let _ = writeln!(
                    out,
                    "V{} {} {} PULSE({} {} {} {} {} {} {})",
                    comp.id, p[0], p[1], v1, v2, td, tr, tf, pw, per
                );
            }
            ComponentKind::PwlSource { pts, count } => {
                let n = (count as usize).min(pts.len());
                let segs: Vec<String> = pts[..n]
                    .iter()
                    .map(|pair| format!("{} {}", pair[0], pair[1]))
                    .collect();
                let _ = writeln!(
                    out,
                    "V{} {} {} PWL({})",
                    comp.id,
                    p[0],
                    p[1],
                    segs.join(" ")
                );
            }
            ComponentKind::Vcvs { gain } => {
                let _ = writeln!(
                    out,
                    "E{} {} {} {} {} {}",
                    comp.id, p[0], p[1], p[2], p[3], gain
                );
            }
            ComponentKind::Vccs { gm } => {
                let _ = writeln!(
                    out,
                    "G{} {} {} {} {} {}",
                    comp.id, p[0], p[1], p[2], p[3], gm
                );
            }
            ComponentKind::Cccs { gain } => {
                let _ = writeln!(
                    out,
                    "* CCCS F{} out=({},{}) sense=({},{}) gain={}",
                    comp.id, p[0], p[1], p[2], p[3], gain
                );
            }
            ComponentKind::Ccvs { rm } => {
                let _ = writeln!(
                    out,
                    "* CCVS H{} out=({},{}) sense=({},{}) rm={}",
                    comp.id, p[0], p[1], p[2], p[3], rm
                );
            }
            ComponentKind::VControlledSwitch {
                v_on,
                v_off,
                r_on,
                r_off,
            } => {
                let mname = format!("SW{}", comp.id);
                let vt = 0.5 * (v_on + v_off);
                let vh = 0.5 * (v_on - v_off).abs();
                models.insert(
                    mname.clone(),
                    format!(".model {mname} SW(VT={vt} VH={vh} RON={r_on} ROFF={r_off})"),
                );
                let _ = writeln!(
                    out,
                    "S{} {} {} {} {} {}",
                    comp.id, p[0], p[1], p[2], p[3], mname
                );
            }
            ComponentKind::Diode { is_sat, n, bv } => {
                if bv.is_finite() && bv > 0.0 {
                    let mname = format!("DZ{}", comp.id);
                    models.insert(
                        mname.clone(),
                        format!(".model {mname} D(IS={is_sat} N={n} BV={bv})"),
                    );
                    let _ = writeln!(out, "D{} {} {} {}", comp.id, p[0], p[1], mname);
                } else {
                    let mname = intern_model(
                        &mut models,
                        "DMOD",
                        comp.id,
                        format!("D(IS={is_sat} N={n})"),
                    );
                    let _ = writeln!(out, "D{} {} {} {}", comp.id, p[0], p[1], mname);
                }
            }
            ComponentKind::VaractorDiode { cj0, vj, m, is_sat } => {
                let mname = format!("DVAR{}", comp.id);
                models.insert(
                    mname.clone(),
                    format!(".model {mname} D(IS={is_sat} CJO={cj0} VJ={vj} M={m})"),
                );
                let _ = writeln!(out, "D{} {} {} {}", comp.id, p[0], p[1], mname);
            }
            ComponentKind::Led { is_sat, n, .. } => {
                let mname = intern_model(
                    &mut models,
                    "DLED",
                    comp.id,
                    format!("D(IS={is_sat} N={n})"),
                );
                let _ = writeln!(out, "D{} {} {} {}", comp.id, p[0], p[1], mname);
            }
            ComponentKind::BridgeRectifier { is_sat, n } => {
                let mname = intern_model(
                    &mut models,
                    "DBRG",
                    comp.id,
                    format!("D(IS={is_sat} N={n})"),
                );
                let _ = writeln!(out, "D{}a {} {} {}", comp.id, p[0], p[2], mname);
                let _ = writeln!(out, "D{}b {} {} {}", comp.id, p[1], p[2], mname);
                let _ = writeln!(out, "D{}c {} {} {}", comp.id, p[3], p[0], mname);
                let _ = writeln!(out, "D{}d {} {} {}", comp.id, p[3], p[1], mname);
            }
            ComponentKind::OpAmp { gain, .. } => {
                let _ = writeln!(out, "Eop{} {} 0 {} {} {}", comp.id, p[2], p[0], p[1], gain);
            }
            ComponentKind::ComparatorOc { v_high, r_pu } => {
                let _ = writeln!(
                    out,
                    "* ComparatorOC U{} in=({},{}) out={} vhi={} rpu={}",
                    comp.id, p[0], p[1], p[2], v_high, r_pu
                );
            }
            ComponentKind::InstAmp { gain, .. } => {
                let _ = writeln!(out, "Eina{} {} 0 {} {} {}", comp.id, p[2], p[0], p[1], gain);
            }
            ComponentKind::VoltageReg { v_out, r_out } => {
                let _ = writeln!(
                    out,
                    "* VoltageReg U{} in={} gnd={} out={} VOUT={} ROUT={}",
                    comp.id, p[0], p[1], p[2], v_out, r_out
                );
            }
            ComponentKind::NpnBjt { is_sat, bf, .. } => {
                let mname = format!("QNPN{}", comp.id);
                models.insert(
                    mname.clone(),
                    format!(".model {mname} NPN(IS={is_sat} BF={bf})"),
                );
                let _ = writeln!(out, "Q{} {} {} {} {}", comp.id, p[0], p[1], p[2], mname);
            }
            ComponentKind::PnpBjt { is_sat, bf, .. } => {
                let mname = format!("QPNP{}", comp.id);
                models.insert(
                    mname.clone(),
                    format!(".model {mname} PNP(IS={is_sat} BF={bf})"),
                );
                let _ = writeln!(out, "Q{} {} {} {} {}", comp.id, p[0], p[1], p[2], mname);
            }
            ComponentKind::Nmos { kp, vth, lambda } => {
                let mname = format!("NMOS{}", comp.id);
                models.insert(
                    mname.clone(),
                    format!(".model {mname} NMOS(KP={kp} VTO={vth} LAMBDA={lambda})"),
                );
                let _ = writeln!(
                    out,
                    "M{} {} {} {} {} {}",
                    comp.id, p[0], p[1], p[2], p[2], mname
                );
            }
            ComponentKind::Pmos { kp, vth, lambda } => {
                let mname = format!("PMOS{}", comp.id);
                models.insert(
                    mname.clone(),
                    format!(".model {mname} PMOS(KP={kp} VTO={vth} LAMBDA={lambda})"),
                );
                let _ = writeln!(
                    out,
                    "M{} {} {} {} {} {}",
                    comp.id, p[0], p[1], p[2], p[2], mname
                );
            }
            ComponentKind::Njfet { beta, vto, lambda } => {
                let mname = format!("NJF{}", comp.id);
                models.insert(
                    mname.clone(),
                    format!(".model {mname} NJF(BETA={beta} VTO={vto} LAMBDA={lambda})"),
                );
                let _ = writeln!(out, "J{} {} {} {} {}", comp.id, p[0], p[1], p[2], mname);
            }
            ComponentKind::Pjfet { beta, vto, lambda } => {
                let mname = format!("PJF{}", comp.id);
                models.insert(
                    mname.clone(),
                    format!(".model {mname} PJF(BETA={beta} VTO={vto} LAMBDA={lambda})"),
                );
                let _ = writeln!(out, "J{} {} {} {} {}", comp.id, p[0], p[1], p[2], mname);
            }
            ComponentKind::CoupledInductor { l1, l2, k } => {
                let _ = writeln!(out, "L{}a {} {} {}", comp.id, p[0], p[1], l1);
                let _ = writeln!(out, "L{}b {} {} {}", comp.id, p[2], p[3], l2);
                let _ = writeln!(out, "K{} L{}a L{}b {}", comp.id, comp.id, comp.id, k);
            }
            ComponentKind::Crystal { rm, lm, cm, c0 } => {
                let mid1 = 900_000 + comp.id * 2;
                let mid2 = mid1 + 1;
                let _ = writeln!(out, "Rm{} {} {} {}", comp.id, p[0], mid1, rm);
                let _ = writeln!(out, "Lm{} {} {} {}", comp.id, mid1, mid2, lm);
                let _ = writeln!(out, "Cm{} {} {} {}", comp.id, mid2, p[1], cm);
                let _ = writeln!(out, "C0_{} {} {} {}", comp.id, p[0], p[1], c0);
            }
            ComponentKind::DcMotor { r_a, ke, .. } => {
                let _ = writeln!(out, "Rmot{} {} {} {} * ke={}", comp.id, p[0], p[1], r_a, ke);
            }
            ComponentKind::DipSwitch4 { mask, r_on, r_off } => {
                for bit in 0..4 {
                    let r = if (mask >> (3 - bit)) & 1 == 1 {
                        r_on
                    } else {
                        r_off
                    };
                    let _ = writeln!(
                        out,
                        "Rdip{}_{} {} {} {}",
                        comp.id,
                        bit,
                        p[bit * 2],
                        p[bit * 2 + 1],
                        r
                    );
                }
            }
            ComponentKind::Scr { i_hold, v_bo, .. } | ComponentKind::Triac { i_hold, v_bo, .. } => {
                let tag = if matches!(comp.kind, ComponentKind::Scr { .. }) {
                    "SCR"
                } else {
                    "TRIAC"
                };
                let _ = writeln!(
                    out,
                    "* {tag} X{} a={} k={} g={} ihold={} vbo={}",
                    comp.id, p[0], p[1], p[2], i_hold, v_bo
                );
            }
            ComponentKind::Diac { v_bo, r_on, r_off } => {
                let _ = writeln!(
                    out,
                    "* DIAC X{} {} {} vbo={} ron={} roff={}",
                    comp.id, p[0], p[1], v_bo, r_on, r_off
                );
            }
            ComponentKind::Igbt { kp, vth, r_on } => {
                let _ = writeln!(
                    out,
                    "* IGBT Q{} c={} g={} e={} kp={} vth={} ron={}",
                    comp.id, p[0], p[1], p[2], kp, vth, r_on
                );
            }
            ComponentKind::DigitalGate { kind, .. } => {
                let _ = writeln!(
                    out,
                    "* Digital {:?} U{} pins={:?}",
                    kind,
                    comp.id,
                    &p[..comp.pin_count as usize]
                );
            }
            ComponentKind::ClockSource { freq, v_high, .. } => {
                let period = if freq > 0.0 { 1.0 / freq } else { 1.0 };
                let _ = writeln!(
                    out,
                    "Vclk{} {} {} PULSE(0 {} 0 1n 1n {} {})",
                    comp.id,
                    p[0],
                    p[1],
                    v_high,
                    0.5 * period,
                    period
                );
            }
            ComponentKind::DFlipFlop { .. } => {
                let _ = writeln!(out, "* Digital DFF U{} pins={:?}", comp.id, &p[..4]);
            }
            ComponentKind::LogicProbe { .. } => {
                let _ = writeln!(out, "* LogicProbe U{} node={}", comp.id, p[0]);
            }
            ComponentKind::Timer555 { .. } => {
                let _ = writeln!(out, "* Timer555 U{} pins={:?}", comp.id, &p[..4]);
            }
            ComponentKind::SevenSeg { .. } => {
                let _ = writeln!(out, "* SevenSeg U{} pins={:?}", comp.id, &p[..4]);
            }
            ComponentKind::Transformer { ratio } => {
                let _ = writeln!(
                    out,
                    "* Transformer X{} prim=({},{}) sec=({},{}) n={}",
                    comp.id, p[0], p[1], p[2], p[3], ratio
                );
            }
            ComponentKind::Relay { r_coil, v_pull, .. } => {
                let _ = writeln!(
                    out,
                    "* Relay K{} coil=({},{}) sw=({},{}) r_coil={} v_pull={}",
                    comp.id, p[0], p[1], p[2], p[3], r_coil, v_pull
                );
            }
            ComponentKind::WordGen { freq, pattern, .. } => {
                let _ = writeln!(
                    out,
                    "* WordGen U{} pins={:?} freq={} pattern=0x{:X}",
                    comp.id,
                    &p[..4],
                    freq,
                    pattern
                );
            }
            ComponentKind::Optocoupler { ctr, .. } => {
                let _ = writeln!(
                    out,
                    "* Optocoupler U{} led=({},{}) out=({},{}) ctr={}",
                    comp.id, p[0], p[1], p[2], p[3], ctr
                );
            }
            ComponentKind::SchmittTrigger { v_hyst, v_high, .. } => {
                let _ = writeln!(
                    out,
                    "* SchmittTrigger U{} in=({},{}) out={} hyst={} vhi={}",
                    comp.id, p[0], p[1], p[2], v_hyst, v_high
                );
            }
            ComponentKind::Counter4Bit { v_high, .. } => {
                let _ = writeln!(
                    out,
                    "* Counter4Bit U{} clk={} q=({},{},{}) vhi={}",
                    comp.id, p[0], p[1], p[2], p[3], v_high
                );
            }
            _ => {
                let _ = writeln!(
                    out,
                    "* {} U{} pins={:?}",
                    comp.name,
                    comp.id,
                    comp.active_nodes()
                );
            }
        }
    }
    for card in models.values() {
        let _ = writeln!(out, "{card}");
    }
    let _ = writeln!(out, ".end");
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::netlist::{Circuit, Component, FaultKind};

    fn make_comp(id: u32, name: &str, kind: ComponentKind, pins: &[u32]) -> Component {
        let mut nodes = [0u32; 8];
        for (i, &n) in pins.iter().enumerate().take(8) {
            nodes[i] = n;
        }
        Component {
            id,
            name: name.to_string(),
            kind,
            nodes,
            pin_count: pins.len() as u8,
            fault: FaultKind::None,
        }
    }

    #[test]
    fn export_cir_emits_models_and_extended_devices() {
        let mut c = Circuit::default();
        c.components.push(make_comp(
            1,
            "Z",
            ComponentKind::Diode {
                is_sat: 1e-12,
                n: 1.5,
                bv: 5.1,
            },
            &[1, 0],
        ));
        c.components.push(make_comp(
            2,
            "J",
            ComponentKind::Njfet {
                beta: 2e-3,
                vto: -1.5,
                lambda: 0.01,
            },
            &[2, 1, 0],
        ));
        c.components.push(make_comp(
            3,
            "K",
            ComponentKind::CoupledInductor {
                l1: 1e-3,
                l2: 2e-3,
                k: 0.95,
            },
            &[1, 0, 2, 0],
        ));
        c.components.push(make_comp(
            4,
            "D1",
            ComponentKind::Diode {
                is_sat: 2.5e-9,
                n: 1.75,
                bv: f64::INFINITY,
            },
            &[1, 0],
        ));
        c.components.push(make_comp(
            5,
            "D2",
            ComponentKind::Diode {
                is_sat: 1.0e-6,
                n: 1.1,
                bv: f64::INFINITY,
            },
            &[2, 0],
        ));
        let cir = export_cir("Test Models", &c);
        assert!(cir.contains(".model DZ1 D("));
        assert!(cir.contains("BV=5.1"));
        assert!(cir.contains(".model NJF2 NJF("));
        assert!(cir.contains("K3 L3a L3b 0.95"));
        assert!(cir.contains(".model DMOD D(IS=0.0000000025 N=1.75)"));
        assert!(cir.contains(".model DMOD5 D(IS=0.000001 N=1.1)"));
        assert!(cir.trim_end().ends_with(".end"));
    }
}
