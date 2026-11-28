use crate::mna::solver::{Complex64, ComplexSystem, DenseSystem};
use crate::netlist::{CompiledTopology, ComponentKind, WaveShape};

#[inline]
pub fn thermal_voltage(temp_k: f64) -> f64 {
    1.380_649e-23 * temp_k.max(1.0) / 1.602_176_634e-19
}

/// SPICE-style `pnjlim` junction voltage limiting to prevent Newton-Raphson overflow.
pub fn limit_junction_voltage(v_new: f64, v_old: f64, n_vt: f64, i_sat: f64) -> f64 {
    let v_crit = n_vt
        * (n_vt / (std::f64::consts::SQRT_2 * i_sat.max(1e-18)))
            .ln()
            .max(0.1);
    if v_new > v_crit && (v_new - v_old).abs() > 2.0 * n_vt {
        if v_old > 0.0 {
            let arg = 1.0 + (v_new - v_old) / n_vt;
            if arg > 0.0 {
                v_old + n_vt * arg.ln()
            } else {
                v_crit
            }
        } else {
            n_vt * (v_new / n_vt).max(1e-6).ln()
        }
    } else {
        v_new
    }
}

pub fn eval_diode_vt(v_d: f64, is_sat: f64, n: f64, bv: f64, gmin: f64, vt: f64) -> (f64, f64) {
    let n_vt = n * vt;
    let raw_arg = v_d / n_vt;
    // SPICE linear continuation above 40*n*Vt preserves exact tangent g_d = dI/dV.
    let (mut i_d, mut g_d) = if raw_arg > 40.0 {
        let exp40 = 40.0_f64.exp();
        let g_max = (is_sat / n_vt) * exp40;
        let i_max = is_sat * (exp40 - 1.0);
        (
            i_max + g_max * (v_d - 40.0 * n_vt) + gmin * v_d,
            g_max + gmin,
        )
    } else {
        let exp_f = raw_arg.max(-80.0).exp();
        (
            is_sat * (exp_f - 1.0) + gmin * v_d,
            (is_sat / n_vt) * exp_f + gmin,
        )
    };

    if bv.is_finite() && v_d < 0.0 {
        let rev_raw = (-v_d - bv) / n_vt;
        if rev_raw > 40.0 {
            let exp40 = 40.0_f64.exp();
            let g_r = (is_sat / n_vt) * exp40;
            let i_r = is_sat * exp40 + g_r * ((-v_d - bv) - 40.0 * n_vt);
            i_d -= i_r;
            g_d += g_r;
        } else {
            let exp_r = rev_raw.max(-80.0).exp();
            i_d -= is_sat * exp_r;
            g_d += (is_sat / n_vt) * exp_r;
        }
    }
    (i_d, g_d)
}

pub fn eval_source_at(kind: &ComponentKind, t: f64) -> f64 {
    match kind {
        ComponentKind::DcVoltage { v } => *v,
        ComponentKind::AcVoltage {
            amp,
            freq,
            phase_deg,
            offset,
        } => offset + amp * (2.0 * std::f64::consts::PI * freq * t + phase_deg.to_radians()).sin(),
        ComponentKind::FunctionGen {
            shape,
            amp,
            freq,
            offset,
            duty,
        } => {
            if *freq <= 0.0 {
                return *offset;
            }
            let phase = (t * freq).rem_euclid(1.0);
            let wave = match shape {
                WaveShape::Sine => (2.0 * std::f64::consts::PI * phase).sin(),
                WaveShape::Square => {
                    let d = duty.clamp(0.01, 0.99);
                    if phase < d {
                        1.0
                    } else {
                        -1.0
                    }
                }
                WaveShape::Triangle => {
                    if phase < 0.5 {
                        4.0 * phase - 1.0
                    } else {
                        3.0 - 4.0 * phase
                    }
                }
            };
            offset + amp * wave
        }
        _ => 0.0,
    }
}

/// Shared soft-saturating tanh amplifier evaluation: returns `(v_target, gm)`.
#[inline]
pub fn eval_tanh_amp(v_diff: f64, gain: f64, v_sat_pos: f64, v_sat_neg: f64) -> (f64, f64) {
    let v_mid = 0.5 * (v_sat_pos + v_sat_neg);
    let v_half = (0.5 * (v_sat_pos - v_sat_neg)).max(0.1);
    let th = (gain * v_diff / v_half).clamp(-20.0, 20.0).tanh();
    (v_mid + v_half * th, gain * (1.0 - th * th))
}

#[inline]
pub fn node_v(x: &[f64], topo: &CompiledTopology, node_id: u32) -> f64 {
    topo.idx(node_id).map_or(0.0, |i| x[i])
}

/// Smooth log-conductance interpolation between `r_off` and `r_on` over transition half-width `dv`.
pub fn smooth_switch_g(v: f64, v_th: f64, dv: f64, r_on: f64, r_off: f64) -> f64 {
    let g_on = 1.0 / r_on.max(1e-6);
    let g_off = 1.0 / r_off.max(1e-6);
    let u = ((v - v_th) / dv.max(1e-4)).clamp(-20.0, 20.0);
    let s = 0.5 + 0.5 * u.tanh();
    (g_off.ln() + s * (g_on.ln() - g_off.ln())).exp()
}

/// Stamps a smooth C-infinity digital gate output driver (`DigitalGate` / `DigitalGateMulti`).
pub fn stamp_soft_digital(
    sys: &mut DenseSystem,
    topo: &CompiledTopology,
    kind: crate::digital::GateKind,
    out_pin: u32,
    inputs_v: &[f64],
    v_high: f64,
    r_out: f64,
) {
    let v_target = crate::digital::eval_soft_gate(kind, inputs_v, v_high);
    let g_out = 1.0 / r_out.max(1.0);
    if let Some(o) = topo.idx(out_pin) {
        sys.add_a(o, o, g_out);
        sys.add_b(o, v_target * g_out);
    }
}

/// Stamps a nonlinear device using thermal voltage `vt` and previous state `x_prev`.
pub fn stamp_nonlinear_vt(
    sys: &mut DenseSystem,
    topo: &CompiledTopology,
    kind: &ComponentKind,
    pins: &[u32],
    x_prev: &[f64],
    gmin: f64,
    vt: f64,
) {
    match kind {
        ComponentKind::Diode { is_sat, n, bv } => {
            let va = node_v(x_prev, topo, pins[0]);
            let vc = node_v(x_prev, topo, pins[1]);
            let (i_d, g_d) = eval_diode_vt(va - vc, *is_sat, *n, *bv, gmin, vt);
            let i_eq = i_d - g_d * (va - vc);
            let pa = topo.idx(pins[0]);
            let pc = topo.idx(pins[1]);
            sys.stamp_conductance(pa, pc, g_d);
            sys.stamp_current(pa, pc, i_eq);
        }
        ComponentKind::VaractorDiode { is_sat, .. } => {
            let va = node_v(x_prev, topo, pins[0]);
            let vc = node_v(x_prev, topo, pins[1]);
            let (i_d, g_d) = eval_diode_vt(va - vc, *is_sat, 1.2, f64::INFINITY, gmin, vt);
            let i_eq = i_d - g_d * (va - vc);
            let pa = topo.idx(pins[0]);
            let pc = topo.idx(pins[1]);
            sys.stamp_conductance(pa, pc, g_d);
            sys.stamp_current(pa, pc, i_eq);
        }
        ComponentKind::Led { is_sat, n, .. } => {
            let va = node_v(x_prev, topo, pins[0]);
            let vc = node_v(x_prev, topo, pins[1]);
            let (i_d, g_d) = eval_diode_vt(va - vc, *is_sat, *n, f64::INFINITY, gmin, vt);
            let i_eq = i_d - g_d * (va - vc);
            let pa = topo.idx(pins[0]);
            let pc = topo.idx(pins[1]);
            sys.stamp_conductance(pa, pc, g_d);
            sys.stamp_current(pa, pc, i_eq);
        }
        ComponentKind::OpAmp {
            gain,
            v_sat_pos,
            v_sat_neg,
            r_out,
        } => {
            let v_diff = node_v(x_prev, topo, pins[0]) - node_v(x_prev, topo, pins[1]);
            let (v_target, gm) = eval_tanh_amp(v_diff, *gain, *v_sat_pos, *v_sat_neg);
            let g_out = 1.0 / r_out.max(1e-3);

            let pp = topo.idx(pins[0]);
            let pn = topo.idx(pins[1]);
            let po = topo.idx(pins[2]);
            if let Some(o) = po {
                sys.add_a(o, o, g_out);
                if let Some(ip) = pp {
                    sys.add_a(o, ip, -gm * g_out);
                }
                if let Some(inn) = pn {
                    sys.add_a(o, inn, gm * g_out);
                }
                let rhs = (v_target - gm * v_diff) * g_out;
                sys.add_b(o, rhs);
            }
        }
        ComponentKind::NpnBjt { is_sat, bf, br } => {
            stamp_bjt(sys, topo, pins, x_prev, *is_sat, *bf, *br, 1.0, gmin, vt);
        }
        ComponentKind::PnpBjt { is_sat, bf, br } => {
            stamp_bjt(sys, topo, pins, x_prev, *is_sat, *bf, *br, -1.0, gmin, vt);
        }
        ComponentKind::Nmos { kp, vth, lambda } => {
            stamp_mosfet(sys, topo, pins, x_prev, *kp, *vth, *lambda, 1.0, gmin);
        }
        ComponentKind::Pmos { kp, vth, lambda } => {
            stamp_mosfet(sys, topo, pins, x_prev, *kp, *vth, *lambda, -1.0, gmin);
        }
        ComponentKind::DigitalGate {
            kind,
            v_high,
            r_out,
        } => {
            if pins.len() == 2 {
                let v0 = node_v(x_prev, topo, pins[0]);
                stamp_soft_digital(sys, topo, *kind, pins[1], &[v0], *v_high, *r_out);
            } else {
                let v0 = node_v(x_prev, topo, pins[0]);
                let v1 = node_v(x_prev, topo, pins[1]);
                stamp_soft_digital(sys, topo, *kind, pins[2], &[v0, v1], *v_high, *r_out);
            }
        }
        ComponentKind::Relay {
            r_coil,
            v_pull,
            r_on,
            r_off,
        } => {
            sys.stamp_conductance(topo.idx(pins[0]), topo.idx(pins[1]), 1.0 / *r_coil);
            let v_coil = (node_v(x_prev, topo, pins[0]) - node_v(x_prev, topo, pins[1])).abs();
            let g_contact = smooth_switch_g(v_coil, *v_pull, 0.02 * *v_pull, *r_on, *r_off);
            sys.stamp_conductance(topo.idx(pins[2]), topo.idx(pins[3]), g_contact);
        }
        ComponentKind::Optocoupler { ctr, is_sat, n } => {
            let va = node_v(x_prev, topo, pins[0]);
            let vk = node_v(x_prev, topo, pins[1]);
            let vc = node_v(x_prev, topo, pins[2]);
            let ve = node_v(x_prev, topo, pins[3]);

            let (i_led, g_led) = eval_diode_vt(va - vk, *is_sat, *n, f64::INFINITY, gmin, vt);
            let pa = topo.idx(pins[0]);
            let pk = topo.idx(pins[1]);
            sys.stamp_conductance(pa, pk, g_led);
            sys.stamp_current(pa, pk, i_led - g_led * (va - vk));

            let vce = vc - ve;
            let vak = va - vk;
            let i_fwd = i_led.max(0.0);
            let g_fwd = if i_led > 0.0 { g_led } else { 0.0 };
            let u = (vce / 0.1).clamp(-20.0, 20.0);
            let sat = if vce > 0.0 { u.tanh() } else { 0.0 };
            let dsat_dvce = if vce > 0.0 {
                (1.0 - sat * sat) / 0.1
            } else {
                0.0
            };
            let i_c = *ctr * i_fwd * sat + gmin * vce;
            let g_ce = *ctr * i_fwd * dsat_dvce + gmin;
            let gm_ak = *ctr * g_fwd * sat;

            let pc = topo.idx(pins[2]);
            let pe = topo.idx(pins[3]);
            sys.stamp_conductance(pc, pe, g_ce);
            if let Some(c) = pc {
                if let Some(a) = pa {
                    sys.add_a(c, a, gm_ak);
                }
                if let Some(k) = pk {
                    sys.add_a(c, k, -gm_ak);
                }
            }
            if let Some(e) = pe {
                if let Some(a) = pa {
                    sys.add_a(e, a, -gm_ak);
                }
                if let Some(k) = pk {
                    sys.add_a(e, k, gm_ak);
                }
            }
            let i_eq_c = i_c - g_ce * vce - gm_ak * vak;
            sys.stamp_current(pc, pe, i_eq_c);
        }
        _ => {}
    }
}

/// Ebers-Moll BJT stamp (`pol = +1.0` for NPN, `-1.0` for PNP). Pins: [C, B, E].
#[allow(clippy::too_many_arguments)]
fn stamp_bjt(
    sys: &mut DenseSystem,
    topo: &CompiledTopology,
    pins: &[u32],
    x_prev: &[f64],
    is_sat: f64,
    bf: f64,
    br: f64,
    pol: f64,
    gmin: f64,
    vt: f64,
) {
    let vc = node_v(x_prev, topo, pins[0]);
    let vb = node_v(x_prev, topo, pins[1]);
    let ve = node_v(x_prev, topo, pins[2]);
    let vbe = pol * (vb - ve);
    let vbc = pol * (vb - vc);

    let (i_f, g_f) = eval_diode_vt(vbe, is_sat, 1.0, f64::INFINITY, gmin, vt);
    let (i_r, g_r) = eval_diode_vt(vbc, is_sat, 1.0, f64::INFINITY, gmin, vt);

    let alpha_f = bf / (bf + 1.0);
    let alpha_r = br / (br + 1.0);

    // Terminal currents (NPN convention, multiplied by `pol` for node KCL).
    let ic = pol * (i_f - i_r / alpha_r);
    let ie = pol * (-i_f / alpha_f + i_r);
    let ib = -(ic + ie);

    // Partial derivatives wrt (Vb, Vc, Ve)
    let dic_dvbe = g_f;
    let dic_dvbc = -g_r / alpha_r;
    let die_dvbe = -g_f / alpha_f;
    let die_dvbc = g_r;

    let pc = topo.idx(pins[0]);
    let pb = topo.idx(pins[1]);
    let pe = topo.idx(pins[2]);

    // Conductance Jacobian entries (independent of `pol` signs because pol^2 = 1):
    let g_cc = -dic_dvbc;
    let g_ce = -dic_dvbe;
    let g_cb = dic_dvbe + dic_dvbc;

    let g_ec = -die_dvbc;
    let g_ee = -die_dvbe;
    let g_eb = die_dvbe + die_dvbc;

    let g_bc = -(g_cc + g_ec);
    let g_be = -(g_ce + g_ee);
    let g_bb = -(g_cb + g_eb);

    let mat = [
        (pc, g_cc, g_cb, g_ce),
        (pb, g_bc, g_bb, g_be),
        (pe, g_ec, g_eb, g_ee),
    ];
    for (row_opt, jc, jb, je) in mat {
        if let Some(r) = row_opt {
            if let Some(c) = pc {
                sys.add_a(r, c, jc);
            }
            if let Some(b) = pb {
                sys.add_a(r, b, jb);
            }
            if let Some(e) = pe {
                sys.add_a(r, e, je);
            }
        }
    }

    // Equivalent current sources: I_eq = I(v0) - J * v0
    let i_c_lin = g_cc * vc + g_cb * vb + g_ce * ve;
    let i_b_lin = g_bc * vc + g_bb * vb + g_be * ve;
    let i_e_lin = g_ec * vc + g_eb * vb + g_ee * ve;

    if let Some(c) = pc {
        sys.add_b(c, i_c_lin - ic);
    }
    if let Some(b) = pb {
        sys.add_b(b, i_b_lin - ib);
    }
    if let Some(e) = pe {
        sys.add_b(e, i_e_lin - ie);
    }
}

/// Level-1 Shichman-Hodges MOSFET stamp (`pol = +1.0` NMOS, `-1.0` PMOS). Pins: [D, G, S].
/// Evaluates MOSFET channel current & small-signal conductances: `(id_mag, gm, gds, rev)`.
#[allow(clippy::too_many_arguments)]
pub fn eval_mosfet_channel(
    vd: f64,
    vg: f64,
    vs: f64,
    kp: f64,
    vth: f64,
    lambda: f64,
    pol: f64,
    gmin: f64,
) -> (f64, f64, f64, bool) {
    let vds_raw = pol * (vd - vs);
    let rev = vds_raw < 0.0;
    let (vgs, vds) = if rev {
        (pol * (vg - vd), -vds_raw)
    } else {
        (pol * (vg - vs), vds_raw)
    };
    let vov = vgs - vth;
    if vov <= 0.0 {
        (gmin * vds, 0.0, gmin, rev)
    } else if vds < vov {
        let mod_early = 1.0 + lambda * vds;
        let id = kp * (vov * vds - 0.5 * vds * vds) * mod_early + gmin * vds;
        let gm = kp * vds * mod_early;
        let gds = kp * ((vov - vds) * mod_early + lambda * (vov * vds - 0.5 * vds * vds)) + gmin;
        (id, gm, gds.max(gmin), rev)
    } else {
        let mod_early = 1.0 + lambda * vds;
        let base = 0.5 * kp * vov * vov;
        let id = base * mod_early + gmin * vds;
        let gm = kp * vov * mod_early;
        let gds = (base * lambda + gmin).max(gmin);
        (id, gm, gds, rev)
    }
}

#[allow(clippy::too_many_arguments)]
fn stamp_mosfet(
    sys: &mut DenseSystem,
    topo: &CompiledTopology,
    pins: &[u32],
    x_prev: &[f64],
    kp: f64,
    vth: f64,
    lambda: f64,
    pol: f64,
    gmin: f64,
) {
    let vd = node_v(x_prev, topo, pins[0]);
    let vg = node_v(x_prev, topo, pins[1]);
    let vs = node_v(x_prev, topo, pins[2]);
    let (id_mag, gm, gds, rev) = eval_mosfet_channel(vd, vg, vs, kp, vth, lambda, pol, gmin);
    let (eff_d, eff_s) = if rev {
        (pins[2], pins[0])
    } else {
        (pins[0], pins[2])
    };

    let id = pol * id_mag;
    let pd = topo.idx(eff_d);
    let pg = topo.idx(pins[1]);
    let ps = topo.idx(eff_s);
    let vd_eff = node_v(x_prev, topo, eff_d);
    let vs_eff = node_v(x_prev, topo, eff_s);

    // KCL at eff_d: +Id; KCL at eff_s: -Id
    sys.stamp_conductance(pd, ps, gds);
    if let Some(d) = pd {
        if let Some(g) = pg {
            sys.add_a(d, g, gm);
        }
        if let Some(s) = ps {
            sys.add_a(d, s, -gm);
        }
    }
    if let Some(s) = ps {
        if let Some(g) = pg {
            sys.add_a(s, g, -gm);
        }
        sys.add_a(s, s, gm);
    }

    let i_eq = id - gm * (vg - vs_eff) - gds * (vd_eff - vs_eff);
    sys.stamp_current(pd, ps, i_eq);
}

pub struct AcStampCtx<'a> {
    pub topo: &'a CompiledTopology,
    pub x_dc: &'a [f64],
    pub phase2: &'a super::phase2::Phase2State,
    pub omega: f64,
    pub ac_source_id: u32,
    pub gmin: f64,
    pub vt: f64,
}

/// Stamps linearized AC admittance for small-signal AC sweeps around DC operating point `x_dc`.
pub fn stamp_ac_component(
    sys: &mut ComplexSystem,
    comp: &crate::netlist::Component,
    comp_idx: usize,
    branch_idx: Option<usize>,
    ctx: &AcStampCtx<'_>,
    scratch: &mut DenseSystem,
) {
    let pins = comp.active_nodes();
    let kind = &comp.kind;
    let comp_id = comp.id;
    let &AcStampCtx {
        topo,
        x_dc,
        phase2,
        omega,
        ac_source_id,
        gmin,
        vt,
    } = ctx;
    match kind {
        ComponentKind::Resistor { r } => {
            sys.stamp_admittance(
                topo.idx(pins[0]),
                topo.idx(pins[1]),
                Complex64::new(1.0 / r, 0.0),
            );
        }
        ComponentKind::Potentiometer { r_total, wiper } => {
            let w = wiper.clamp(0.001, 0.999);
            let pt = topo.idx(pins[0]);
            let pb = topo.idx(pins[1]);
            let pw = topo.idx(pins[2]);
            sys.stamp_admittance(pt, pw, Complex64::new(1.0 / (r_total * (1.0 - w)), 0.0));
            sys.stamp_admittance(pw, pb, Complex64::new(1.0 / (r_total * w), 0.0));
        }
        ComponentKind::Capacitor { c, .. } => {
            sys.stamp_admittance(
                topo.idx(pins[0]),
                topo.idx(pins[1]),
                Complex64::new(0.0, omega * c),
            );
        }
        ComponentKind::Inductor { l, .. } => {
            if let Some(b) = branch_idx {
                let p = topo.idx(pins[0]);
                let q = topo.idx(pins[1]);
                if let Some(i) = p {
                    sys.add_a(i, b, Complex64::new(1.0, 0.0));
                    sys.add_a(b, i, Complex64::new(1.0, 0.0));
                }
                if let Some(j) = q {
                    sys.add_a(j, b, Complex64::new(-1.0, 0.0));
                    sys.add_a(b, j, Complex64::new(-1.0, 0.0));
                }
                sys.add_a(b, b, Complex64::new(0.0, -omega * l));
            }
        }
        ComponentKind::SwitchSpst {
            closed,
            r_on,
            r_off,
        } => {
            let r = if *closed { *r_on } else { *r_off };
            sys.stamp_admittance(
                topo.idx(pins[0]),
                topo.idx(pins[1]),
                Complex64::new(1.0 / r, 0.0),
            );
        }
        ComponentKind::SwitchSpdt {
            throw_b,
            r_on,
            r_off,
        } => {
            let r_a = if *throw_b { *r_off } else { *r_on };
            let r_b = if *throw_b { *r_on } else { *r_off };
            sys.stamp_admittance(
                topo.idx(pins[0]),
                topo.idx(pins[1]),
                Complex64::new(1.0 / r_a, 0.0),
            );
            sys.stamp_admittance(
                topo.idx(pins[0]),
                topo.idx(pins[2]),
                Complex64::new(1.0 / r_b, 0.0),
            );
        }
        ComponentKind::Fuse { r_on, blown, .. } => {
            let r = if *blown { 1e9 } else { *r_on };
            sys.stamp_admittance(
                topo.idx(pins[0]),
                topo.idx(pins[1]),
                Complex64::new(1.0 / r, 0.0),
            );
        }
        ComponentKind::DcVoltage { .. }
        | ComponentKind::AcVoltage { .. }
        | ComponentKind::FunctionGen { .. } => {
            if let Some(b) = branch_idx {
                let p = topo.idx(pins[0]);
                let q = topo.idx(pins[1]);
                if let Some(i) = p {
                    sys.add_a(i, b, Complex64::new(1.0, 0.0));
                    sys.add_a(b, i, Complex64::new(1.0, 0.0));
                }
                if let Some(j) = q {
                    sys.add_a(j, b, Complex64::new(-1.0, 0.0));
                    sys.add_a(b, j, Complex64::new(-1.0, 0.0));
                }
                if comp_id == ac_source_id {
                    sys.add_b(b, Complex64::new(1.0, 0.0));
                }
            }
        }
        ComponentKind::Vcvs { gain } => {
            if let Some(b) = branch_idx {
                if let Some(i) = topo.idx(pins[0]) {
                    sys.add_a(i, b, Complex64::new(1.0, 0.0));
                    sys.add_a(b, i, Complex64::new(1.0, 0.0));
                }
                if let Some(j) = topo.idx(pins[1]) {
                    sys.add_a(j, b, Complex64::new(-1.0, 0.0));
                    sys.add_a(b, j, Complex64::new(-1.0, 0.0));
                }
                if let Some(cp) = topo.idx(pins[2]) {
                    sys.add_a(b, cp, Complex64::new(-*gain, 0.0));
                }
                if let Some(cn) = topo.idx(pins[3]) {
                    sys.add_a(b, cn, Complex64::new(*gain, 0.0));
                }
            }
        }
        ComponentKind::Vccs { gm } => {
            let op = topo.idx(pins[0]);
            let on = topo.idx(pins[1]);
            let cp = topo.idx(pins[2]);
            let cn = topo.idx(pins[3]);
            if let Some(r) = op {
                if let Some(c) = cp {
                    sys.add_a(r, c, Complex64::new(*gm, 0.0));
                }
                if let Some(c) = cn {
                    sys.add_a(r, c, Complex64::new(-*gm, 0.0));
                }
            }
            if let Some(r) = on {
                if let Some(c) = cp {
                    sys.add_a(r, c, Complex64::new(-*gm, 0.0));
                }
                if let Some(c) = cn {
                    sys.add_a(r, c, Complex64::new(*gm, 0.0));
                }
            }
        }
        ComponentKind::Cccs { gain } => {
            if let Some(b) = branch_idx {
                if let Some(sp) = topo.idx(pins[2]) {
                    sys.add_a(sp, b, Complex64::new(1.0, 0.0));
                    sys.add_a(b, sp, Complex64::new(1.0, 0.0));
                }
                if let Some(sn) = topo.idx(pins[3]) {
                    sys.add_a(sn, b, Complex64::new(-1.0, 0.0));
                    sys.add_a(b, sn, Complex64::new(-1.0, 0.0));
                }
                sys.add_a(b, b, Complex64::new(-1e-9, 0.0));
                if let Some(op) = topo.idx(pins[0]) {
                    sys.add_a(op, b, Complex64::new(*gain, 0.0));
                }
                if let Some(on) = topo.idx(pins[1]) {
                    sys.add_a(on, b, Complex64::new(-*gain, 0.0));
                }
            }
        }
        ComponentKind::Ccvs { rm } => {
            if let Some(b) = branch_idx {
                let bs = b + 1;
                if let Some(i) = topo.idx(pins[0]) {
                    sys.add_a(i, b, Complex64::new(1.0, 0.0));
                    sys.add_a(b, i, Complex64::new(1.0, 0.0));
                }
                if let Some(j) = topo.idx(pins[1]) {
                    sys.add_a(j, b, Complex64::new(-1.0, 0.0));
                    sys.add_a(b, j, Complex64::new(-1.0, 0.0));
                }
                if let Some(sp) = topo.idx(pins[2]) {
                    sys.add_a(sp, bs, Complex64::new(1.0, 0.0));
                    sys.add_a(bs, sp, Complex64::new(1.0, 0.0));
                }
                if let Some(sn) = topo.idx(pins[3]) {
                    sys.add_a(sn, bs, Complex64::new(-1.0, 0.0));
                    sys.add_a(bs, sn, Complex64::new(-1.0, 0.0));
                }
                sys.add_a(b, bs, Complex64::new(-*rm, 0.0));
            }
        }
        ComponentKind::Transformer { ratio } => {
            if let Some(b) = branch_idx {
                if let Some(pp) = topo.idx(pins[0]) {
                    sys.add_a(pp, b, Complex64::new(-*ratio, 0.0));
                    sys.add_a(b, pp, Complex64::new(-*ratio, 0.0));
                }
                if let Some(pn) = topo.idx(pins[1]) {
                    sys.add_a(pn, b, Complex64::new(*ratio, 0.0));
                    sys.add_a(b, pn, Complex64::new(*ratio, 0.0));
                }
                if let Some(sp) = topo.idx(pins[2]) {
                    sys.add_a(sp, b, Complex64::new(1.0, 0.0));
                    sys.add_a(b, sp, Complex64::new(1.0, 0.0));
                }
                if let Some(sn) = topo.idx(pins[3]) {
                    sys.add_a(sn, b, Complex64::new(-1.0, 0.0));
                    sys.add_a(b, sn, Complex64::new(-1.0, 0.0));
                }
                sys.add_a(b, b, Complex64::new(-1e-6, 0.0));
            }
        }
        ComponentKind::Diode { is_sat, n, bv } => {
            let va = node_v(x_dc, topo, pins[0]);
            let vc = node_v(x_dc, topo, pins[1]);
            let (_, g_d) = eval_diode_vt(va - vc, *is_sat, *n, *bv, gmin, vt);
            sys.stamp_admittance(
                topo.idx(pins[0]),
                topo.idx(pins[1]),
                Complex64::new(g_d, 0.0),
            );
        }
        ComponentKind::VaractorDiode { cj0, vj, m, is_sat } => {
            let va = node_v(x_dc, topo, pins[0]);
            let vc = node_v(x_dc, topo, pins[1]);
            let vd = va - vc;
            let (_, g_d) = eval_diode_vt(vd, *is_sat, 1.2, f64::INFINITY, gmin, vt);
            let vr = (-vd).max(0.0);
            let cj = *cj0 / (1.0 + vr / vj.max(0.1)).powf(*m);
            sys.stamp_admittance(
                topo.idx(pins[0]),
                topo.idx(pins[1]),
                Complex64::new(g_d, omega * cj),
            );
        }
        ComponentKind::Led { is_sat, n, .. } => {
            let va = node_v(x_dc, topo, pins[0]);
            let vc = node_v(x_dc, topo, pins[1]);
            let (_, g_d) = eval_diode_vt(va - vc, *is_sat, *n, f64::INFINITY, gmin, vt);
            sys.stamp_admittance(
                topo.idx(pins[0]),
                topo.idx(pins[1]),
                Complex64::new(g_d, 0.0),
            );
        }
        ComponentKind::OpAmp {
            gain,
            v_sat_pos,
            v_sat_neg,
            r_out,
        } => {
            let v_diff = node_v(x_dc, topo, pins[0]) - node_v(x_dc, topo, pins[1]);
            let (_, gm) = eval_tanh_amp(v_diff, *gain, *v_sat_pos, *v_sat_neg);
            let g_out = 1.0 / r_out.max(1e-3);
            if let Some(o) = topo.idx(pins[2]) {
                sys.add_a(o, o, Complex64::new(g_out, 0.0));
                if let Some(ip) = topo.idx(pins[0]) {
                    sys.add_a(o, ip, Complex64::new(-gm * g_out, 0.0));
                }
                if let Some(inn) = topo.idx(pins[1]) {
                    sys.add_a(o, inn, Complex64::new(gm * g_out, 0.0));
                }
            }
        }
        ComponentKind::DcCurrent { .. } => {
            if comp_id == ac_source_id {
                if let Some(i) = topo.idx(pins[0]) {
                    sys.add_b(i, Complex64::new(-1.0, 0.0));
                }
                if let Some(j) = topo.idx(pins[1]) {
                    sys.add_b(j, Complex64::new(1.0, 0.0));
                }
            }
        }
        ComponentKind::Relay { .. }
        | ComponentKind::Optocoupler { .. }
        | ComponentKind::NpnBjt { .. }
        | ComponentKind::PnpBjt { .. }
        | ComponentKind::Nmos { .. }
        | ComponentKind::Pmos { .. } => {
            scratch.clear_a_touched();
            stamp_nonlinear_vt(scratch, topo, kind, pins, x_dc, gmin, vt);
            scratch.for_each_nonzero(|r, c, v| {
                sys.add_a(r, c, Complex64::new(v, 0.0));
            });
        }
        ComponentKind::DigitalGate { r_out, .. } => {
            let out_pin = if pins.len() == 2 { pins[1] } else { pins[2] };
            if let Some(o) = topo.idx(out_pin) {
                sys.add_a(o, o, Complex64::new(1.0 / r_out.max(1.0), 0.0));
            }
        }
        ComponentKind::ClockSource { r_out, .. } => {
            sys.stamp_admittance(
                topo.idx(pins[0]),
                topo.idx(pins[1]),
                Complex64::new(1.0 / r_out.max(1.0), 0.0),
            );
        }
        ComponentKind::DFlipFlop { r_out, .. } => {
            let g_out = Complex64::new(1.0 / r_out.max(1.0), 0.0);
            if let Some(q) = topo.idx(pins[2]) {
                sys.add_a(q, q, g_out);
            }
            if let Some(qn) = topo.idx(pins[3]) {
                sys.add_a(qn, qn, g_out);
            }
        }
        ComponentKind::LogicProbe { r_in } => {
            if let Some(p) = topo.idx(pins[0]) {
                sys.add_a(p, p, Complex64::new(1.0 / r_in.max(1.0), 0.0));
            }
        }
        ComponentKind::Timer555 { r_out, .. } => {
            if let Some(o) = topo.idx(pins[3]) {
                sys.add_a(o, o, Complex64::new(1.0 / r_out.max(1.0), 0.0));
            }
        }
        ComponentKind::SevenSeg { r_in } => {
            let g_in = Complex64::new(1.0 / r_in.max(1e3), 0.0);
            for &pin in pins {
                if let Some(p) = topo.idx(pin) {
                    sys.add_a(p, p, g_in);
                }
            }
        }
        ComponentKind::WordGen { r_out, .. } => {
            let g_out = Complex64::new(1.0 / r_out.max(1.0), 0.0);
            for &pin in pins {
                if let Some(p) = topo.idx(pin) {
                    sys.add_a(p, p, g_out);
                }
            }
        }
        ComponentKind::SchmittTrigger { r_out, .. } => {
            if let Some(o) = topo.idx(pins[2]) {
                sys.add_a(o, o, Complex64::new(1.0 / r_out.max(1.0), 0.0));
            }
        }
        ComponentKind::Counter4Bit { r_out, .. } => {
            let g_out = Complex64::new(1.0 / r_out.max(1.0), 0.0);
            for &pin in pins.iter().skip(1).take(3) {
                if let Some(p) = topo.idx(pin) {
                    sys.add_a(p, p, g_out);
                }
            }
        }
        ComponentKind::Crystal { rm, lm, cm, c0 } => {
            sys.stamp_admittance(
                topo.idx(pins[0]),
                topo.idx(pins[1]),
                Complex64::new(0.0, omega * c0),
            );
            if let Some(b) = branch_idx {
                if let Some(i) = topo.idx(pins[0]) {
                    sys.add_a(i, b, Complex64::new(1.0, 0.0));
                    sys.add_a(b, i, Complex64::new(1.0, 0.0));
                }
                if let Some(j) = topo.idx(pins[1]) {
                    sys.add_a(j, b, Complex64::new(-1.0, 0.0));
                    sys.add_a(b, j, Complex64::new(-1.0, 0.0));
                }
                let x = omega * lm - 1.0 / (omega * cm).max(1e-18);
                sys.add_a(b, b, Complex64::new(-*rm, -x));
            }
        }
        ComponentKind::AcCurrent { .. } => {
            if comp_id == ac_source_id {
                if let Some(i) = topo.idx(pins[0]) {
                    sys.add_b(i, Complex64::new(-1.0, 0.0));
                }
                if let Some(j) = topo.idx(pins[1]) {
                    sys.add_b(j, Complex64::new(1.0, 0.0));
                }
            }
        }
        ComponentKind::PulseVoltage { .. } | ComponentKind::PwlSource { .. } => {
            if let Some(b) = branch_idx {
                if let Some(i) = topo.idx(pins[0]) {
                    sys.add_a(i, b, Complex64::new(1.0, 0.0));
                    sys.add_a(b, i, Complex64::new(1.0, 0.0));
                }
                if let Some(j) = topo.idx(pins[1]) {
                    sys.add_a(j, b, Complex64::new(-1.0, 0.0));
                    sys.add_a(b, j, Complex64::new(-1.0, 0.0));
                }
                if comp_id == ac_source_id {
                    sys.add_b(b, Complex64::new(1.0, 0.0));
                }
            }
        }
        ComponentKind::CoupledInductor { l1, l2, k } => {
            if let Some(b1) = branch_idx {
                let b2 = b1 + 1;
                let pa1 = topo.idx(pins[0]);
                let pb1 = topo.idx(pins[1]);
                let pa2 = topo.idx(pins[2]);
                let pb2 = topo.idx(pins[3]);
                for &(pa, pb, b) in &[(pa1, pb1, b1), (pa2, pb2, b2)] {
                    if let Some(i) = pa {
                        sys.add_a(i, b, Complex64::new(1.0, 0.0));
                        sys.add_a(b, i, Complex64::new(1.0, 0.0));
                    }
                    if let Some(j) = pb {
                        sys.add_a(j, b, Complex64::new(-1.0, 0.0));
                        sys.add_a(b, j, Complex64::new(-1.0, 0.0));
                    }
                }
                let m = k.clamp(-0.999, 0.999) * (*l1 * *l2).sqrt();
                sys.add_a(b1, b1, Complex64::new(0.0, -omega * *l1));
                sys.add_a(b1, b2, Complex64::new(0.0, -omega * m));
                sys.add_a(b2, b1, Complex64::new(0.0, -omega * m));
                sys.add_a(b2, b2, Complex64::new(0.0, -omega * *l2));
            }
        }
        _ => {
            scratch.clear_a_touched();
            if super::phase2::stamp_phase2_component(
                scratch, topo, comp, comp_idx, branch_idx, x_dc, phase2, 0.0, 1.0, false, 1.0,
                gmin, vt,
            ) {
                scratch.for_each_nonzero(|r, c, v| {
                    sys.add_a(r, c, Complex64::new(v, 0.0));
                });
            } else if pins.len() >= 2 {
                sys.stamp_admittance(
                    topo.idx(pins[0]),
                    topo.idx(pins[1]),
                    Complex64::new(gmin, 0.0),
                );
            }
        }
    }
}
