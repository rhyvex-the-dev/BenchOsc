use crate::mna::devices::{eval_diode_vt, node_v};
use crate::mna::solver::DenseSystem;
use crate::netlist::{CompiledTopology, Component, ComponentKind};

#[derive(Debug, Clone, Default)]
pub struct Phase2State {
    pub latch_bits: Vec<u8>,
    pub clk_prev: Vec<bool>,
    pub aux_a: Vec<f64>,
    pub aux_b: Vec<f64>,
    pub aux_c: Vec<f64>,
    pub aux_d: Vec<f64>,
    pub aux_e: Vec<f64>,
    pub use_trap: bool,
}

impl Phase2State {
    pub fn with_len(n: usize) -> Self {
        Self {
            latch_bits: vec![0; n],
            clk_prev: vec![false; n],
            aux_a: vec![0.0; n],
            aux_b: vec![0.0; n],
            aux_c: vec![0.0; n],
            aux_d: vec![0.0; n],
            aux_e: vec![0.0; n],
            use_trap: false,
        }
    }
}

pub fn init_phase2_after_dc(
    components: &[Component],
    solution: &[f64],
    topo: &CompiledTopology,
    p2: &mut Phase2State,
) -> bool {
    let mut need_dc_resolve = false;
    for (idx, comp) in components.iter().enumerate() {
        let clk_info = match comp.kind {
            ComponentKind::JkFlipFlop { v_high, .. }
            | ComponentKind::TFlipFlop { v_high, .. }
            | ComponentKind::DFlipFlopAsync { v_high, .. }
            | ComponentKind::SampleHold { v_high, .. }
            | ComponentKind::ShiftReg4Bit { v_high, .. } => Some((comp.nodes[1], v_high)),
            ComponentKind::Counter4BitFull { v_high, .. } => Some((comp.nodes[0], v_high)),
            _ => None,
        };
        if let Some((clk_pin, v_high)) = clk_info {
            p2.clk_prev[idx] = node_v(solution, topo, clk_pin) >= 0.5 * v_high;
        }
        match comp.kind {
            ComponentKind::CoupledInductor { .. } => {
                if let Some(b1) = topo.branch_of_comp.get(idx).copied().flatten() {
                    p2.aux_a[idx] = solution[b1];
                    p2.aux_b[idx] = solution[b1 + 1];
                }
            }
            ComponentKind::Crystal { .. } => {
                let v_dc =
                    node_v(solution, topo, comp.nodes[0]) - node_v(solution, topo, comp.nodes[1]);
                p2.aux_a[idx] = v_dc;
                p2.aux_c[idx] = v_dc;
            }
            ComponentKind::VControlledSwitch { v_on, .. } => {
                let vc =
                    node_v(solution, topo, comp.nodes[2]) - node_v(solution, topo, comp.nodes[3]);
                p2.latch_bits[idx] = u8::from(vc >= v_on);
            }
            ComponentKind::IControlledSwitch { i_on, .. } => {
                let is = topo
                    .branch_of_comp
                    .get(idx)
                    .copied()
                    .flatten()
                    .map_or(0.0, |b| solution[b]);
                p2.latch_bits[idx] = u8::from(is >= i_on);
            }
            ComponentKind::Scr { .. } => {
                let va = node_v(solution, topo, comp.nodes[0]);
                let vk = node_v(solution, topo, comp.nodes[1]);
                let vg = node_v(solution, topo, comp.nodes[2]);
                let on = u8::from((va - vk) > 0.7 && (vg - vk) > 0.7);
                if on != p2.latch_bits[idx] {
                    p2.latch_bits[idx] = on;
                    need_dc_resolve = true;
                }
            }
            ComponentKind::Triac { .. } => {
                let vmt = (node_v(solution, topo, comp.nodes[0])
                    - node_v(solution, topo, comp.nodes[1]))
                .abs();
                let vgt = (node_v(solution, topo, comp.nodes[2])
                    - node_v(solution, topo, comp.nodes[1]))
                .abs();
                let on = u8::from(vmt > 0.7 && vgt > 0.7);
                if on != p2.latch_bits[idx] {
                    p2.latch_bits[idx] = on;
                    need_dc_resolve = true;
                }
            }
            ComponentKind::SrLatch { v_high, .. } => {
                let s = node_v(solution, topo, comp.nodes[0]) >= 0.5 * v_high;
                let r = node_v(solution, topo, comp.nodes[1]) >= 0.5 * v_high;
                if s && !r {
                    p2.latch_bits[idx] = 1;
                    need_dc_resolve = true;
                }
            }
            ComponentKind::DFlipFlopAsync { v_high, .. } => {
                let set = node_v(solution, topo, comp.nodes[2]) >= 0.5 * v_high;
                let rst = node_v(solution, topo, comp.nodes[3]) >= 0.5 * v_high;
                if set && !rst {
                    p2.latch_bits[idx] = 1;
                    need_dc_resolve = true;
                }
            }
            _ => {}
        }
    }
    need_dc_resolve
}

#[inline]
fn drive_v(sys: &mut DenseSystem, topo: &CompiledTopology, pin: u32, v_target: f64, r_out: f64) {
    let g_out = 1.0 / r_out.max(1.0);
    if let Some(o) = topo.idx(pin) {
        sys.add_a(o, o, g_out);
        sys.add_b(o, v_target * g_out);
    }
}

#[inline]
fn drive_bool(
    sys: &mut DenseSystem,
    topo: &CompiledTopology,
    pin: u32,
    high: bool,
    v_high: f64,
    r_out: f64,
) {
    drive_v(sys, topo, pin, if high { v_high } else { 0.0 }, r_out);
}

#[inline]
fn drive_msb_bus(
    sys: &mut DenseSystem,
    topo: &CompiledTopology,
    pins: &[u32],
    val: u8,
    bits: usize,
    v_high: f64,
    r_out: f64,
) {
    for b in 0..bits {
        let high = ((val >> (bits - 1 - b)) & 1) == 1;
        if let Some(&pin) = pins.get(b) {
            drive_bool(sys, topo, pin, high, v_high, r_out);
        }
    }
}

#[inline]
fn read_in_hi(
    sys: &mut DenseSystem,
    x: &[f64],
    topo: &CompiledTopology,
    pin: u32,
    v_high: f64,
) -> bool {
    if let Some(p) = topo.idx(pin) {
        sys.add_a(p, p, 1e-7);
    }
    node_v(x, topo, pin) >= 0.5 * v_high
}

fn stamp_vsource_branch(
    sys: &mut DenseSystem,
    topo: &CompiledTopology,
    pa: u32,
    pb: u32,
    b: usize,
    val: f64,
) {
    if let Some(i) = topo.idx(pa) {
        sys.add_a(i, b, 1.0);
        sys.add_a(b, i, 1.0);
    }
    if let Some(j) = topo.idx(pb) {
        sys.add_a(j, b, -1.0);
        sys.add_a(b, j, -1.0);
    }
    sys.add_b(b, val);
}

#[allow(clippy::too_many_arguments)]
pub fn eval_pulse(t: f64, v1: f64, v2: f64, td: f64, tr: f64, tf: f64, pw: f64, per: f64) -> f64 {
    if t < td {
        return v1;
    }
    let period = per.max(1e-9);
    let cyc = (t - td).rem_euclid(period);
    let r = tr.max(1e-9);
    let f = tf.max(1e-9);
    let w = pw.max(0.0);
    if cyc < r {
        v1 + (v2 - v1) * (cyc / r)
    } else if cyc < r + w {
        v2
    } else if cyc < r + w + f {
        v2 + (v1 - v2) * ((cyc - r - w) / f)
    } else {
        v1
    }
}

pub fn eval_pwl(t: f64, pts: &[[f64; 2]; 4], count: u8) -> f64 {
    let n = (count as usize).clamp(1, 4);
    if t <= pts[0][0] || n == 1 {
        return pts[0][1];
    }
    for i in 1..n {
        if t <= pts[i][0] {
            let dt = (pts[i][0] - pts[i - 1][0]).max(1e-12);
            return pts[i - 1][1] + (pts[i][1] - pts[i - 1][1]) * ((t - pts[i - 1][0]) / dt);
        }
    }
    pts[n - 1][1]
}

#[allow(clippy::too_many_arguments)]
fn stamp_jfet(
    sys: &mut DenseSystem,
    topo: &CompiledTopology,
    pins: &[u32],
    x_prev: &[f64],
    beta: f64,
    vto: f64,
    lambda: f64,
    pol: f64,
    gmin: f64,
    vt: f64,
) {
    let vd = node_v(x_prev, topo, pins[0]);
    let vg = node_v(x_prev, topo, pins[1]);
    let vs = node_v(x_prev, topo, pins[2]);
    // Gate-source and gate-drain p-n diode junctions.
    for &(j_pin, jv) in &[(pins[2], vs), (pins[0], vd)] {
        let v_pn = pol * (vg - jv);
        let (ij, gj) = eval_diode_vt(v_pn, 1e-14, 1.0, f64::INFINITY, gmin, vt);
        let pg = topo.idx(pins[1]);
        let pj = topo.idx(j_pin);
        sys.stamp_conductance(pg, pj, gj);
        let i_eq_j = pol * (ij - gj * v_pn);
        sys.stamp_current(pg, pj, i_eq_j);
    }

    let vds_raw = pol * (vd - vs);
    let (vgs, vds, eff_d, eff_s) = if vds_raw < 0.0 {
        (pol * (vg - vd), -vds_raw, pins[2], pins[0])
    } else {
        (pol * (vg - vs), vds_raw, pins[0], pins[2])
    };
    let vov = vgs - vto;
    let (id_mag, gm, gds) = if vov <= 0.0 {
        (gmin * vds, 0.0, gmin)
    } else if vds < vov {
        let mod_e = 1.0 + lambda * vds;
        let id = beta * (2.0 * vov * vds - vds * vds) * mod_e + gmin * vds;
        let gm = 2.0 * beta * vds * mod_e;
        let gds = (2.0 * beta * (vov - vds) * mod_e
            + beta * lambda * (2.0 * vov * vds - vds * vds)
            + gmin)
            .max(gmin);
        (id, gm, gds)
    } else {
        let mod_e = 1.0 + lambda * vds;
        let id = beta * vov * vov * mod_e + gmin * vds;
        let gm = 2.0 * beta * vov * mod_e;
        let gds = (beta * vov * vov * lambda + gmin).max(gmin);
        (id, gm, gds)
    };
    let pd = topo.idx(eff_d);
    let pg = topo.idx(pins[1]);
    let ps = topo.idx(eff_s);
    let vd_eff = node_v(x_prev, topo, eff_d);
    let vs_eff = node_v(x_prev, topo, eff_s);
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
    let i_eq = pol * id_mag - gm * (vg - vs_eff) - gds * (vd_eff - vs_eff);
    sys.stamp_current(pd, ps, i_eq);
}

#[allow(clippy::too_many_arguments)]
pub fn stamp_phase2_component(
    sys: &mut DenseSystem,
    topo: &CompiledTopology,
    comp: &Component,
    idx: usize,
    branch: Option<usize>,
    x_cur: &[f64],
    p2: &Phase2State,
    t_sim: f64,
    dt: f64,
    is_transient: bool,
    gmin: f64,
    vt: f64,
) -> bool {
    let pins = comp.active_nodes();
    let t_eval = if is_transient { t_sim } else { 0.0 };
    match &comp.kind {
        ComponentKind::AcCurrent {
            amp,
            freq,
            phase_deg,
            offset,
        } => {
            let val = *offset
                + *amp
                    * (2.0 * std::f64::consts::PI * *freq * t_eval + phase_deg.to_radians()).sin();
            sys.stamp_current(topo.idx(pins[0]), topo.idx(pins[1]), val);
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
            if let Some(b) = branch {
                let v = eval_pulse(t_eval, *v1, *v2, *td, *tr, *tf, *pw, *per);
                stamp_vsource_branch(sys, topo, pins[0], pins[1], b, v);
            }
        }
        ComponentKind::PwlSource { pts, count } => {
            if let Some(b) = branch {
                stamp_vsource_branch(
                    sys,
                    topo,
                    pins[0],
                    pins[1],
                    b,
                    eval_pwl(t_eval, pts, *count),
                );
            }
        }
        ComponentKind::VControlledSwitch {
            v_on,
            v_off,
            r_on,
            r_off,
        } => {
            let vc = node_v(x_cur, topo, pins[2]) - node_v(x_cur, topo, pins[3]);
            let prev_on = p2.latch_bits.get(idx).copied().unwrap_or(0) != 0;
            let v_th = if *v_on <= *v_off {
                0.5 * (*v_on + *v_off)
            } else if prev_on {
                *v_off
            } else {
                *v_on
            };
            let dv = (0.01 * (*v_on - *v_off).abs()).max(1e-3);
            let g = crate::mna::devices::smooth_switch_g(vc, v_th, dv, *r_on, *r_off);
            sys.stamp_conductance(topo.idx(pins[0]), topo.idx(pins[1]), g);
        }
        ComponentKind::IControlledSwitch {
            i_on,
            i_off,
            r_on,
            r_off,
        } => {
            if let Some(b) = branch {
                if let Some(sp) = topo.idx(pins[2]) {
                    sys.add_a(sp, b, 1.0);
                    sys.add_a(b, sp, 1.0);
                }
                if let Some(sn) = topo.idx(pins[3]) {
                    sys.add_a(sn, b, -1.0);
                    sys.add_a(b, sn, -1.0);
                }
            }
            let is = branch.and_then(|b| x_cur.get(b)).copied().unwrap_or(0.0);
            let prev_on = p2.latch_bits.get(idx).copied().unwrap_or(0) != 0;
            let closed = if is >= *i_on {
                true
            } else if is <= *i_off {
                false
            } else {
                prev_on
            };
            sys.stamp_conductance(
                topo.idx(pins[0]),
                topo.idx(pins[1]),
                1.0 / if closed { *r_on } else { *r_off },
            );
        }
        ComponentKind::BridgeRectifier { is_sat, n } => {
            // 4 diodes: [ac1->dc+, ac2->dc+, dc- -> ac1, dc- -> ac2]
            let pairs = [
                (pins[0], pins[2]),
                (pins[1], pins[2]),
                (pins[3], pins[0]),
                (pins[3], pins[1]),
            ];
            for (pa_pin, pc_pin) in pairs {
                let va = node_v(x_cur, topo, pa_pin);
                let vc = node_v(x_cur, topo, pc_pin);
                let (id, gd) = eval_diode_vt(va - vc, *is_sat, *n, f64::INFINITY, gmin, vt);
                let pa = topo.idx(pa_pin);
                let pc = topo.idx(pc_pin);
                sys.stamp_conductance(pa, pc, gd);
                sys.stamp_current(pa, pc, id - gd * (va - vc));
            }
        }
        ComponentKind::Njfet { beta, vto, lambda } => {
            stamp_jfet(sys, topo, pins, x_cur, *beta, *vto, *lambda, 1.0, gmin, vt);
        }
        ComponentKind::Pjfet { beta, vto, lambda } => {
            stamp_jfet(sys, topo, pins, x_cur, *beta, *vto, *lambda, -1.0, gmin, vt);
        }
        ComponentKind::Scr { r_on, r_off, .. } => {
            let on = p2.latch_bits.get(idx).copied().unwrap_or(0) != 0;
            let vak = node_v(x_cur, topo, pins[0]) - node_v(x_cur, topo, pins[1]);
            let conduct = on && vak >= -0.05;
            sys.stamp_conductance(
                topo.idx(pins[0]),
                topo.idx(pins[1]),
                1.0 / if conduct { *r_on } else { *r_off },
            );
            sys.stamp_conductance(topo.idx(pins[2]), topo.idx(pins[1]), 1e-3);
        }
        ComponentKind::Triac { r_on, r_off, .. } => {
            let on = p2.latch_bits.get(idx).copied().unwrap_or(0) != 0;
            sys.stamp_conductance(
                topo.idx(pins[0]),
                topo.idx(pins[1]),
                1.0 / if on { *r_on } else { *r_off },
            );
            sys.stamp_conductance(topo.idx(pins[2]), topo.idx(pins[1]), 1e-3);
        }
        ComponentKind::Diac { v_bo, r_on, r_off } => {
            let vd = node_v(x_cur, topo, pins[0]) - node_v(x_cur, topo, pins[1]);
            let pa = topo.idx(pins[0]);
            let pc = topo.idx(pins[1]);
            let latch_state = if is_transient {
                p2.latch_bits.get(idx).copied().unwrap_or(0)
            } else {
                0
            };
            if latch_state != 0 || vd.abs() >= *v_bo {
                let r = r_on.max(1e-6);
                let g = 1.0 / r;
                let (sign, v_drop) = match latch_state {
                    1 => (1.0, 0.35 * *v_bo),
                    2 => (-1.0, 0.35 * *v_bo),
                    _ => (if vd >= 0.0 { 1.0 } else { -1.0 }, *v_bo),
                };
                sys.stamp_conductance(pa, pc, g);
                sys.stamp_current(pa, pc, -sign * v_drop * g);
            } else {
                sys.stamp_conductance(pa, pc, 1.0 / r_off.max(1.0));
            }
        }
        ComponentKind::Igbt { kp, vth, r_on } => {
            let vc = node_v(x_cur, topo, pins[0]);
            let vg = node_v(x_cur, topo, pins[1]);
            let ve = node_v(x_cur, topo, pins[2]);
            let vge = vg - ve;
            let vce = vc - ve;
            let v_pn = 0.7;
            let (ic, gm, gce) = if vge <= *vth || vce <= v_pn {
                (gmin * vce, 0.0, gmin)
            } else {
                let vov = vge - *vth;
                let max_i = *kp * vov * vov;
                let g_sat = 1.0 / r_on.max(0.05);
                let i_lin = g_sat * (vce - v_pn);
                if i_lin <= max_i {
                    (i_lin, 0.0, g_sat)
                } else {
                    (max_i + gmin * vce, 2.0 * *kp * vov, gmin)
                }
            };
            let pc = topo.idx(pins[0]);
            let pg = topo.idx(pins[1]);
            let pe = topo.idx(pins[2]);
            sys.stamp_conductance(pc, pe, gce);
            if gm != 0.0 {
                if let Some(c) = pc {
                    if let Some(g) = pg {
                        sys.add_a(c, g, gm);
                    }
                    if let Some(e) = pe {
                        sys.add_a(c, e, -gm);
                    }
                }
                if let Some(e) = pe {
                    if let Some(g) = pg {
                        sys.add_a(e, g, -gm);
                    }
                    sys.add_a(e, e, gm);
                }
            }
            sys.stamp_current(pc, pe, ic - gce * vce - gm * vge);
        }
        ComponentKind::VoltageReg { v_out, r_out } => {
            let va = node_v(x_cur, topo, pins[0]);
            let vg_v = node_v(x_cur, topo, pins[1]);
            let vo_v = node_v(x_cur, topo, pins[2]);
            let vin = va - vg_v;
            let vout_diff = vo_v - vg_v;
            let v_reg = (vin - 1.5).clamp(0.0, *v_out);
            let dvreg_dvin = if vin > 1.5 && vin < *v_out + 1.5 {
                1.0
            } else {
                0.0
            };
            let pi = topo.idx(pins[0]);
            let pg = topo.idx(pins[1]);
            let po = topo.idx(pins[2]);
            let g_out = 1.0 / r_out.max(0.05);
            let rhs_v = v_reg - dvreg_dvin * vin;
            // Output stage: I_out_leaving = g_out * (vout_diff - v_reg)
            if let Some(o) = po {
                sys.add_a(o, o, g_out);
                if let Some(i) = pi {
                    sys.add_a(o, i, -g_out * dvreg_dvin);
                }
                if let Some(g) = pg {
                    sys.add_a(o, g, -g_out * (1.0 - dvreg_dvin));
                }
                sys.add_b(o, rhs_v * g_out);
            }
            // Input stage: draws matching load current from Vin -> GND when sourcing load
            if v_reg >= vout_diff {
                if let Some(i) = pi {
                    sys.add_a(i, i, g_out * dvreg_dvin);
                    if let Some(o) = po {
                        sys.add_a(i, o, -g_out);
                    }
                    if let Some(g) = pg {
                        sys.add_a(i, g, g_out * (1.0 - dvreg_dvin));
                    }
                    sys.add_b(i, -rhs_v * g_out);
                }
            } else if let Some(g) = pg {
                if let Some(o) = po {
                    sys.add_a(g, o, -g_out);
                }
                sys.add_a(g, g, g_out * (1.0 - dvreg_dvin));
                if let Some(i) = pi {
                    sys.add_a(g, i, g_out * dvreg_dvin);
                }
                sys.add_b(g, -rhs_v * g_out);
            }
        }
        ComponentKind::ComparatorOc { r_pu, .. } => {
            let vp = node_v(x_cur, topo, pins[0]);
            let vn = node_v(x_cur, topo, pins[1]);
            // Open-collector: High-Z (gmin only) when vp >= vn, smooth pull-down to GND when vp < vn.
            let s = 0.5 * (1.0 - ((vp - vn) / 0.005).clamp(-20.0, 20.0).tanh());
            let g_pull = (1.0 / r_pu.clamp(10.0, 50.0)) * s + gmin;
            if let Some(o) = topo.idx(pins[2]) {
                sys.add_a(o, o, g_pull);
            }
        }
        ComponentKind::InstAmp {
            gain,
            v_sat_pos,
            v_sat_neg,
            r_out,
        } => {
            let vp = node_v(x_cur, topo, pins[0]);
            let vn = node_v(x_cur, topo, pins[1]);
            let v_mid = 0.5 * (*v_sat_pos + *v_sat_neg);
            let v_half = (0.5 * (*v_sat_pos - *v_sat_neg)).max(0.1);
            let u = (*gain * (vp - vn) / v_half).clamp(-20.0, 20.0);
            let t = u.tanh();
            let v_target = v_mid + v_half * t;
            let gm = *gain * (1.0 - t * t);
            let g_out = 1.0 / r_out.max(1e-3);
            if let Some(o) = topo.idx(pins[2]) {
                sys.add_a(o, o, g_out);
                if let Some(ip) = topo.idx(pins[0]) {
                    sys.add_a(o, ip, -gm * g_out);
                }
                if let Some(inn) = topo.idx(pins[1]) {
                    sys.add_a(o, inn, gm * g_out);
                }
                sys.add_b(o, (v_target - gm * (vp - vn)) * g_out);
            }
        }
        ComponentKind::Vco { v_high, r_out, .. } => {
            let phase = p2.aux_a.get(idx).copied().unwrap_or(0.0);
            drive_bool(sys, topo, pins[1], phase < 0.5, *v_high, *r_out);
        }
        ComponentKind::AnalogMultiplier { gain, r_out } => {
            let vx = node_v(x_cur, topo, pins[0]);
            let vy = node_v(x_cur, topo, pins[1]);
            let g_out = 1.0 / r_out.max(1.0);
            if let Some(o) = topo.idx(pins[2]) {
                sys.add_a(o, o, g_out);
                if let Some(px) = topo.idx(pins[0]) {
                    sys.add_a(o, px, -(*gain * vy) * g_out);
                }
                if let Some(py) = topo.idx(pins[1]) {
                    sys.add_a(o, py, -(*gain * vx) * g_out);
                }
                sys.add_b(o, -(*gain * vx * vy) * g_out);
            }
        }
        ComponentKind::SampleHold { r_out, .. } => {
            let held = p2.aux_a.get(idx).copied().unwrap_or(0.0);
            drive_v(sys, topo, pins[2], held, *r_out);
        }
        ComponentKind::TriStateBuffer { v_high, r_out } => {
            let inp = read_in_hi(sys, x_cur, topo, pins[0], *v_high);
            if pins.len() == 2 {
                drive_bool(sys, topo, pins[1], inp, *v_high, *r_out);
            } else {
                let en = read_in_hi(sys, x_cur, topo, pins[1], *v_high);
                if en {
                    drive_bool(sys, topo, pins[2], inp, *v_high, *r_out);
                } else if let Some(o) = topo.idx(pins[2]) {
                    sys.add_a(o, o, gmin);
                }
            }
        }
        ComponentKind::DigitalGateMulti {
            kind,
            v_high,
            r_out,
        } => {
            let in_len = pins.len().saturating_sub(1).min(4);
            let mut in_v = [0.0f64; 4];
            for (slot, &pin) in in_v[..in_len].iter_mut().zip(&pins[..in_len]) {
                *slot = node_v(x_cur, topo, pin);
            }
            crate::mna::devices::stamp_soft_digital(
                sys,
                topo,
                *kind,
                pins[in_len],
                &in_v[..in_len],
                *v_high,
                *r_out,
            );
        }
        ComponentKind::SrLatch { v_high, r_out } => {
            let q = p2.latch_bits.get(idx).copied().unwrap_or(0) != 0;
            let s = read_in_hi(sys, x_cur, topo, pins[0], *v_high);
            let r = read_in_hi(sys, x_cur, topo, pins[1], *v_high);
            let nq = if s && !r {
                true
            } else if r && !s {
                false
            } else {
                q
            };
            drive_bool(sys, topo, pins[2], nq, *v_high, *r_out);
            drive_bool(sys, topo, pins[3], !nq, *v_high, *r_out);
        }
        ComponentKind::JkFlipFlop { v_high, r_out }
        | ComponentKind::TFlipFlop { v_high, r_out } => {
            let q = p2.latch_bits.get(idx).copied().unwrap_or(0) != 0;
            let q_pin = pins.len() - 2;
            drive_bool(sys, topo, pins[q_pin], q, *v_high, *r_out);
            drive_bool(sys, topo, pins[q_pin + 1], !q, *v_high, *r_out);
        }
        ComponentKind::DFlipFlopAsync { v_high, r_out } => {
            let q = p2.latch_bits.get(idx).copied().unwrap_or(0) != 0;
            drive_bool(sys, topo, pins[4], q, *v_high, *r_out);
            drive_bool(sys, topo, pins[5], !q, *v_high, *r_out);
        }
        ComponentKind::Counter4BitFull { v_high, r_out } => {
            let val = p2.latch_bits.get(idx).copied().unwrap_or(0) & 0xF;
            drive_msb_bus(sys, topo, &pins[3..7], val, 4, *v_high, *r_out);
            let en = read_in_hi(sys, x_cur, topo, pins[2], *v_high);
            drive_bool(sys, topo, pins[7], val == 15 && en, *v_high, *r_out);
        }
        ComponentKind::ShiftReg4Bit { v_high, r_out } => {
            let val = p2.latch_bits.get(idx).copied().unwrap_or(0) & 0xF;
            drive_msb_bus(sys, topo, &pins[3..7], val, 4, *v_high, *r_out);
        }
        ComponentKind::Mux4To1 { v_high, r_out } => {
            let s1 = read_in_hi(sys, x_cur, topo, pins[4], *v_high);
            let s0 = read_in_hi(sys, x_cur, topo, pins[5], *v_high);
            let sel = (usize::from(s1) << 1) | usize::from(s0);
            let y = read_in_hi(sys, x_cur, topo, pins[sel], *v_high);
            drive_bool(sys, topo, pins[6], y, *v_high, *r_out);
        }
        ComponentKind::Demux1To4 { v_high, r_out } => {
            let d = read_in_hi(sys, x_cur, topo, pins[0], *v_high);
            let s1 = read_in_hi(sys, x_cur, topo, pins[1], *v_high);
            let s0 = read_in_hi(sys, x_cur, topo, pins[2], *v_high);
            let sel = (usize::from(s1) << 1) | usize::from(s0);
            for (i, &pin) in pins[3..7].iter().enumerate() {
                drive_bool(sys, topo, pin, d && i == sel, *v_high, *r_out);
            }
        }
        ComponentKind::Decoder2To4 { v_high, r_out } => {
            let a1 = read_in_hi(sys, x_cur, topo, pins[0], *v_high);
            let a0 = read_in_hi(sys, x_cur, topo, pins[1], *v_high);
            let en = read_in_hi(sys, x_cur, topo, pins[2], *v_high);
            let sel = (usize::from(a1) << 1) | usize::from(a0);
            for (i, &pin) in pins[3..7].iter().enumerate() {
                drive_bool(sys, topo, pin, en && i == sel, *v_high, *r_out);
            }
        }
        ComponentKind::FullAdder { v_high, r_out } => {
            let a = u8::from(read_in_hi(sys, x_cur, topo, pins[0], *v_high));
            let b = u8::from(read_in_hi(sys, x_cur, topo, pins[1], *v_high));
            let cin = u8::from(read_in_hi(sys, x_cur, topo, pins[2], *v_high));
            let sum = a + b + cin;
            drive_bool(sys, topo, pins[3], (sum & 1) == 1, *v_high, *r_out);
            drive_bool(sys, topo, pins[4], sum >= 2, *v_high, *r_out);
        }
        ComponentKind::MagComparator { v_high, r_out } => {
            let a = (u8::from(read_in_hi(sys, x_cur, topo, pins[0], *v_high)) << 1)
                | u8::from(read_in_hi(sys, x_cur, topo, pins[1], *v_high));
            let b = (u8::from(read_in_hi(sys, x_cur, topo, pins[2], *v_high)) << 1)
                | u8::from(read_in_hi(sys, x_cur, topo, pins[3], *v_high));
            drive_bool(sys, topo, pins[4], a > b, *v_high, *r_out);
            drive_bool(sys, topo, pins[5], a == b, *v_high, *r_out);
            drive_bool(sys, topo, pins[6], a < b, *v_high, *r_out);
        }
        ComponentKind::Alu2Bit { v_high, r_out } => {
            let a = (u8::from(read_in_hi(sys, x_cur, topo, pins[0], *v_high)) << 1)
                | u8::from(read_in_hi(sys, x_cur, topo, pins[1], *v_high));
            let b = (u8::from(read_in_hi(sys, x_cur, topo, pins[2], *v_high)) << 1)
                | u8::from(read_in_hi(sys, x_cur, topo, pins[3], *v_high));
            let op = (u8::from(read_in_hi(sys, x_cur, topo, pins[4], *v_high)) << 1)
                | u8::from(read_in_hi(sys, x_cur, topo, pins[5], *v_high));
            let res = match op {
                0 => (a + b) & 3,
                1 => a.wrapping_sub(b) & 3,
                2 => a & b,
                _ => a ^ b,
            };
            drive_msb_bus(sys, topo, &pins[6..8], res, 2, *v_high, *r_out);
        }
        ComponentKind::Adc4Bit {
            v_ref,
            v_high,
            r_out,
        } => {
            let vin = node_v(x_cur, topo, pins[0]);
            let vref = if pins[1] != 0 {
                node_v(x_cur, topo, pins[1]).max(0.1)
            } else {
                v_ref.max(0.1)
            };
            let code = ((vin / vref) * 16.0).floor().clamp(0.0, 15.0) as u8;
            drive_msb_bus(sys, topo, &pins[2..6], code, 4, *v_high, *r_out);
        }
        ComponentKind::Dac4Bit { v_ref, r_out } => {
            let vref = if pins[4] != 0 {
                node_v(x_cur, topo, pins[4]).max(0.1)
            } else {
                v_ref.max(0.1)
            };
            let th = 1.5;
            let mut code = 0u8;
            for (b, &pin) in pins.iter().enumerate().take(4) {
                if node_v(x_cur, topo, pin) >= th {
                    code |= 1 << (3 - b);
                }
            }
            drive_v(sys, topo, pins[5], vref * (code as f64 / 16.0), *r_out);
        }
        ComponentKind::HexKeypad {
            nibble,
            v_high,
            r_out,
        } => {
            drive_msb_bus(sys, topo, &pins[..4], *nibble & 0xF, 4, *v_high, *r_out);
        }
        ComponentKind::DipSwitch4 { mask, r_on, r_off } => {
            for b in 0..4 {
                let closed = ((*mask >> b) & 1) == 1;
                sys.stamp_conductance(
                    topo.idx(pins[2 * b]),
                    topo.idx(pins[2 * b + 1]),
                    1.0 / if closed { *r_on } else { *r_off },
                );
            }
        }
        ComponentKind::CoupledInductor { l1, l2, k } => {
            if let Some(b1) = branch {
                let b2 = b1 + 1;
                let pa1 = topo.idx(pins[0]);
                let pb1 = topo.idx(pins[1]);
                let pa2 = topo.idx(pins[2]);
                let pb2 = topo.idx(pins[3]);
                for &(pa, pb, b) in &[(pa1, pb1, b1), (pa2, pb2, b2)] {
                    if let Some(i) = pa {
                        sys.add_a(i, b, 1.0);
                        sys.add_a(b, i, 1.0);
                    }
                    if let Some(j) = pb {
                        sys.add_a(j, b, -1.0);
                        sys.add_a(b, j, -1.0);
                    }
                }
                if is_transient {
                    let m = k.clamp(-0.999, 0.999) * (*l1 * *l2).sqrt();
                    let k_dt = if p2.use_trap { 2.0 / dt } else { 1.0 / dt };
                    let r1 = *l1 * k_dt;
                    let r2 = *l2 * k_dt;
                    let rm = m * k_dt;
                    let i1p = p2.aux_a.get(idx).copied().unwrap_or(0.0);
                    let i2p = p2.aux_b.get(idx).copied().unwrap_or(0.0);
                    let v1p = if p2.use_trap {
                        p2.aux_d.get(idx).copied().unwrap_or(0.0)
                    } else {
                        0.0
                    };
                    let v2p = if p2.use_trap {
                        p2.aux_e.get(idx).copied().unwrap_or(0.0)
                    } else {
                        0.0
                    };
                    sys.add_a(b1, b1, -r1);
                    sys.add_a(b1, b2, -rm);
                    sys.add_b(b1, -(r1 * i1p + rm * i2p + v1p));
                    sys.add_a(b2, b1, -rm);
                    sys.add_a(b2, b2, -r2);
                    sys.add_b(b2, -(rm * i1p + r2 * i2p + v2p));
                }
            }
        }
        ComponentKind::CenterTapTransformer { ratio } => {
            // 2 secondary halves: V(S+, CT) = (ratio/2)*Vp, V(CT, S-) = (ratio/2)*Vp
            if let Some(b1) = branch {
                let b2 = b1 + 1;
                let n = *ratio * 0.5;
                let pp = topo.idx(pins[0]);
                let pn = topo.idx(pins[1]);
                let sp = topo.idx(pins[2]);
                let ct = topo.idx(pins[3]);
                let sn = topo.idx(pins[4]);
                for &(b, sa, sb) in &[(b1, sp, ct), (b2, ct, sn)] {
                    if let Some(i) = pp {
                        sys.add_a(i, b, -n);
                        sys.add_a(b, i, -n);
                    }
                    if let Some(j) = pn {
                        sys.add_a(j, b, n);
                        sys.add_a(b, j, n);
                    }
                    if let Some(i) = sa {
                        sys.add_a(i, b, 1.0);
                        sys.add_a(b, i, 1.0);
                    }
                    if let Some(j) = sb {
                        sys.add_a(j, b, -1.0);
                        sys.add_a(b, j, -1.0);
                    }
                }
            }
        }
        ComponentKind::RelayDpdt {
            r_coil,
            v_pull,
            r_on,
            r_off,
        } => {
            sys.stamp_conductance(topo.idx(pins[0]), topo.idx(pins[1]), 1.0 / *r_coil);
            let vc = (node_v(x_cur, topo, pins[0]) - node_v(x_cur, topo, pins[1])).abs();
            let g_no =
                crate::mna::devices::smooth_switch_g(vc, *v_pull, 0.02 * *v_pull, *r_on, *r_off);
            let g_nc =
                crate::mna::devices::smooth_switch_g(vc, *v_pull, 0.02 * *v_pull, *r_off, *r_on);
            sys.stamp_conductance(topo.idx(pins[2]), topo.idx(pins[3]), g_nc);
            sys.stamp_conductance(topo.idx(pins[2]), topo.idx(pins[4]), g_no);
            if pins.len() >= 8 {
                sys.stamp_conductance(topo.idx(pins[5]), topo.idx(pins[6]), g_nc);
                sys.stamp_conductance(topo.idx(pins[5]), topo.idx(pins[7]), g_no);
            }
        }
        ComponentKind::Crystal { rm, lm, cm, c0 } => {
            // Butterworth-Van Dyke resonator using branch current b for motional arm
            let pa = topo.idx(pins[0]);
            let pb = topo.idx(pins[1]);
            let trap = p2.use_trap;
            if is_transient {
                let g0 = if trap { 2.0 * *c0 / dt } else { *c0 / dt };
                let v_prev = p2.aux_a.get(idx).copied().unwrap_or(0.0);
                let i_c0_prev = if trap {
                    p2.aux_d.get(idx).copied().unwrap_or(0.0)
                } else {
                    0.0
                };
                sys.stamp_conductance(pa, pb, g0);
                sys.stamp_current(pb, pa, g0 * v_prev + i_c0_prev);
            }
            if let Some(b) = branch {
                if let Some(i) = pa {
                    sys.add_a(i, b, 1.0);
                    sys.add_a(b, i, 1.0);
                }
                if let Some(j) = pb {
                    sys.add_a(j, b, -1.0);
                    sys.add_a(b, j, -1.0);
                }
                let (r_lm, r_cm) = if is_transient {
                    if trap {
                        (2.0 * *lm / dt, dt / (2.0 * (*cm).max(1e-18)))
                    } else {
                        (*lm / dt, dt / (*cm).max(1e-18))
                    }
                } else {
                    (1e9, 0.0)
                };
                let r_mot = *rm + r_lm + r_cm;
                let veq = if is_transient {
                    let i_p = p2.aux_b.get(idx).copied().unwrap_or(0.0);
                    let v_cm_p = p2.aux_c.get(idx).copied().unwrap_or(0.0);
                    let v_lm_p = if trap {
                        p2.aux_e.get(idx).copied().unwrap_or(0.0)
                    } else {
                        0.0
                    };
                    let v_cm_eq = v_cm_p + if trap { r_cm * i_p } else { 0.0 };
                    (r_lm * i_p + v_lm_p) - v_cm_eq
                } else {
                    0.0
                };
                sys.add_a(b, b, -r_mot);
                sys.add_b(b, -veq);
            }
        }
        ComponentKind::DcMotor { r_a, ke, .. } => {
            let emf = *ke * p2.aux_a.get(idx).copied().unwrap_or(0.0);
            let pa = topo.idx(pins[0]);
            let pb = topo.idx(pins[1]);
            let g = 1.0 / r_a.max(0.1);
            sys.stamp_conductance(pa, pb, g);
            sys.stamp_current(pb, pa, emf * g);
        }
        ComponentKind::Wattmeter { r_shunt } => {
            sys.stamp_conductance(
                topo.idx(pins[0]),
                topo.idx(pins[1]),
                1.0 / r_shunt.max(1e-4),
            );
            sys.stamp_conductance(topo.idx(pins[2]), topo.idx(pins[3]), 1e-8);
        }
        ComponentKind::BarGraphLed { is_sat, n } | ComponentKind::RgbLed { is_sat, n } => {
            let cath = pins.last().copied().unwrap_or(0);
            let vc = node_v(x_cur, topo, cath);
            let pc = topo.idx(cath);
            for &anode in &pins[..pins.len().saturating_sub(1)] {
                let va = node_v(x_cur, topo, anode);
                let (id, gd) = eval_diode_vt(va - vc, *is_sat, *n, f64::INFINITY, gmin, vt);
                let pa = topo.idx(anode);
                sys.stamp_conductance(pa, pc, gd);
                sys.stamp_current(pa, pc, id - gd * (va - vc));
            }
        }
        _ => return false,
    }
    true
}

pub fn update_phase2_events(
    components: &[Component],
    solution: &[f64],
    topo: &CompiledTopology,
    p2: &mut Phase2State,
) -> bool {
    let mut changed = false;
    for (idx, comp) in components.iter().enumerate() {
        if comp.fault != crate::netlist::FaultKind::None {
            continue;
        }
        let pins = comp.active_nodes();
        match comp.kind {
            ComponentKind::VControlledSwitch { v_on, v_off, .. } => {
                let vc = node_v(solution, topo, pins[2]) - node_v(solution, topo, pins[3]);
                let prev = p2.latch_bits[idx] != 0;
                let next = if vc >= v_on {
                    true
                } else if vc <= v_off {
                    false
                } else {
                    prev
                };
                if next != prev {
                    p2.latch_bits[idx] = u8::from(next);
                    changed = true;
                }
            }
            ComponentKind::IControlledSwitch { i_on, i_off, .. } => {
                if let Some(b) = topo.branch_of_comp[idx] {
                    let is = solution[b];
                    let prev = p2.latch_bits[idx] != 0;
                    let next = if is >= i_on {
                        true
                    } else if is <= i_off {
                        false
                    } else {
                        prev
                    };
                    if next != prev {
                        p2.latch_bits[idx] = u8::from(next);
                        changed = true;
                    }
                }
            }
            ComponentKind::Scr {
                i_hold, v_bo, r_on, ..
            } => {
                let va = node_v(solution, topo, pins[0]);
                let vk = node_v(solution, topo, pins[1]);
                let vg = node_v(solution, topo, pins[2]);
                let ia = (va - vk) / r_on.max(1e-3);
                let prev = p2.latch_bits[idx] != 0;
                let next = if prev {
                    ia > i_hold
                } else {
                    (va - vk) > 0.7 && ((vg - vk) > 0.7 || (va - vk) >= v_bo)
                };
                if next != prev {
                    p2.latch_bits[idx] = u8::from(next);
                    changed = true;
                }
            }
            ComponentKind::Triac {
                i_hold, v_bo, r_on, ..
            } => {
                let vmt = node_v(solution, topo, pins[0]) - node_v(solution, topo, pins[1]);
                let vgt = node_v(solution, topo, pins[2]) - node_v(solution, topo, pins[1]);
                let i_mt = (vmt / r_on.max(1e-3)).abs();
                let prev = p2.latch_bits[idx] != 0;
                let next = if prev {
                    i_mt > i_hold
                } else {
                    vmt.abs() > 0.7 && (vgt.abs() > 0.7 || vmt.abs() >= v_bo)
                };
                if next != prev {
                    p2.latch_bits[idx] = u8::from(next);
                    changed = true;
                }
            }
            ComponentKind::Diac { v_bo, r_on, .. } => {
                let vd = node_v(solution, topo, pins[0]) - node_v(solution, topo, pins[1]);
                let r = r_on.max(1e-6);
                let prev = p2.latch_bits[idx];
                let next = match prev {
                    1 => {
                        if ((vd - 0.35 * v_bo) / r) >= 1e-3 {
                            1
                        } else if vd <= -v_bo {
                            2
                        } else {
                            0
                        }
                    }
                    2 => {
                        if ((-vd - 0.35 * v_bo) / r) >= 1e-3 {
                            2
                        } else if vd >= v_bo {
                            1
                        } else {
                            0
                        }
                    }
                    _ => {
                        if vd >= v_bo {
                            1
                        } else if vd <= -v_bo {
                            2
                        } else {
                            0
                        }
                    }
                };
                if next != prev {
                    p2.latch_bits[idx] = next;
                    changed = true;
                }
            }
            ComponentKind::SampleHold { v_high, .. } => {
                let clk = node_v(solution, topo, pins[1]) >= 0.5 * v_high;
                if clk && !p2.clk_prev[idx] {
                    p2.aux_a[idx] = node_v(solution, topo, pins[0]);
                    changed = true;
                }
                p2.clk_prev[idx] = clk;
            }
            ComponentKind::SrLatch { v_high, .. } => {
                let s = node_v(solution, topo, pins[0]) >= 0.5 * v_high;
                let r = node_v(solution, topo, pins[1]) >= 0.5 * v_high;
                let next = if s && !r {
                    1
                } else if r && !s {
                    0
                } else {
                    p2.latch_bits[idx]
                };
                if next != p2.latch_bits[idx] {
                    p2.latch_bits[idx] = next;
                    changed = true;
                }
            }
            ComponentKind::JkFlipFlop { v_high, .. } => {
                let clk = node_v(solution, topo, pins[1]) >= 0.5 * v_high;
                if clk && !p2.clk_prev[idx] {
                    let j = node_v(solution, topo, pins[0]) >= 0.5 * v_high;
                    let k = node_v(solution, topo, pins[2]) >= 0.5 * v_high;
                    let q = p2.latch_bits[idx] != 0;
                    let next = match (j, k) {
                        (false, false) => q,
                        (false, true) => false,
                        (true, false) => true,
                        (true, true) => !q,
                    };
                    p2.latch_bits[idx] = u8::from(next);
                    changed = true;
                }
                p2.clk_prev[idx] = clk;
            }
            ComponentKind::TFlipFlop { v_high, .. } => {
                let clk = node_v(solution, topo, pins[1]) >= 0.5 * v_high;
                if clk && !p2.clk_prev[idx] {
                    let t_in = node_v(solution, topo, pins[0]) >= 0.5 * v_high;
                    if t_in {
                        p2.latch_bits[idx] ^= 1;
                        changed = true;
                    }
                }
                p2.clk_prev[idx] = clk;
            }
            ComponentKind::DFlipFlopAsync { v_high, .. } => {
                let set = node_v(solution, topo, pins[2]) >= 0.5 * v_high;
                let rst = node_v(solution, topo, pins[3]) >= 0.5 * v_high;
                let clk = node_v(solution, topo, pins[1]) >= 0.5 * v_high;
                let prev = p2.latch_bits[idx];
                if rst && !set {
                    p2.latch_bits[idx] = 0;
                } else if set && !rst {
                    p2.latch_bits[idx] = 1;
                } else if clk && !p2.clk_prev[idx] {
                    p2.latch_bits[idx] = u8::from(node_v(solution, topo, pins[0]) >= 0.5 * v_high);
                }
                if p2.latch_bits[idx] != prev {
                    changed = true;
                }
                p2.clk_prev[idx] = clk;
            }
            ComponentKind::Counter4BitFull { v_high, .. } => {
                let rst = node_v(solution, topo, pins[1]) >= 0.5 * v_high;
                let en = node_v(solution, topo, pins[2]) >= 0.5 * v_high;
                let clk = node_v(solution, topo, pins[0]) >= 0.5 * v_high;
                let prev = p2.latch_bits[idx];
                if rst {
                    p2.latch_bits[idx] = 0;
                } else if en && clk && !p2.clk_prev[idx] {
                    p2.latch_bits[idx] = (p2.latch_bits[idx] + 1) & 0xF;
                }
                if p2.latch_bits[idx] != prev {
                    changed = true;
                }
                p2.clk_prev[idx] = clk;
            }
            ComponentKind::ShiftReg4Bit { v_high, .. } => {
                let rst = node_v(solution, topo, pins[2]) >= 0.5 * v_high;
                let clk = node_v(solution, topo, pins[1]) >= 0.5 * v_high;
                let prev = p2.latch_bits[idx];
                if rst {
                    p2.latch_bits[idx] = 0;
                } else if clk && !p2.clk_prev[idx] {
                    let d = u8::from(node_v(solution, topo, pins[0]) >= 0.5 * v_high);
                    p2.latch_bits[idx] = ((p2.latch_bits[idx] >> 1) | (d << 3)) & 0xF;
                }
                if p2.latch_bits[idx] != prev {
                    changed = true;
                }
                p2.clk_prev[idx] = clk;
            }
            _ => {}
        }
    }
    changed
}

pub fn update_phase2_reactive(
    components: &[Component],
    solution: &[f64],
    topo: &CompiledTopology,
    p2: &mut Phase2State,
    dt: f64,
) {
    for (idx, comp) in components.iter().enumerate() {
        if comp.fault != crate::netlist::FaultKind::None {
            continue;
        }
        let pins = comp.active_nodes();
        match comp.kind {
            ComponentKind::Vco { f0, df_dv, .. } => {
                let f = (f0 + df_dv * node_v(solution, topo, pins[0])).max(0.0);
                p2.aux_a[idx] = (p2.aux_a[idx] + f * dt).rem_euclid(1.0);
            }
            ComponentKind::CoupledInductor { .. } => {
                if let Some(b1) = topo.branch_of_comp[idx] {
                    p2.aux_a[idx] = solution[b1];
                    p2.aux_b[idx] = solution[b1 + 1];
                    p2.aux_d[idx] =
                        node_v(solution, topo, pins[0]) - node_v(solution, topo, pins[1]);
                    p2.aux_e[idx] =
                        node_v(solution, topo, pins[2]) - node_v(solution, topo, pins[3]);
                }
            }
            ComponentKind::Crystal { rm, cm, c0, .. } => {
                let v_now = node_v(solution, topo, pins[0]) - node_v(solution, topo, pins[1]);
                let i_c0_now = if p2.use_trap {
                    let g0 = 2.0 * c0 / dt;
                    g0 * (v_now - p2.aux_a[idx]) - p2.aux_d[idx]
                } else {
                    (c0 / dt) * (v_now - p2.aux_a[idx])
                };
                p2.aux_a[idx] = v_now;
                p2.aux_d[idx] = i_c0_now;
                if let Some(b) = topo.branch_of_comp[idx] {
                    let im = solution[b];
                    let v_cm_now = if p2.use_trap {
                        p2.aux_c[idx] + 0.5 * (dt / cm.max(1e-18)) * (p2.aux_b[idx] + im)
                    } else {
                        p2.aux_c[idx] + (dt / cm.max(1e-18)) * im
                    };
                    p2.aux_b[idx] = im;
                    p2.aux_c[idx] = v_cm_now;
                    p2.aux_e[idx] = v_now - im * rm - v_cm_now;
                }
            }
            ComponentKind::DcMotor { r_a, ke, .. } => {
                let va = node_v(solution, topo, pins[0]) - node_v(solution, topo, pins[1]);
                let ra = r_a.max(0.1);
                let k = 20.0 * dt;
                let omega = p2.aux_a[idx];
                p2.aux_a[idx] = ((omega + k * (ke * va / ra)) / (1.0 + k * (ke * ke / ra + 0.02)))
                    .clamp(-500.0, 500.0);
            }
            _ => {}
        }
    }
}
