use crate::error::{SimError, SimErrorCode};
use crate::instruments::ScopeBuffer;
use crate::mna::devices::{
    eval_diode_vt, eval_source_at, limit_junction_voltage, node_v, stamp_ac_component,
    stamp_nonlinear_vt, thermal_voltage, AcStampCtx,
};
use crate::mna::phase2::{
    init_phase2_after_dc, stamp_phase2_component, update_phase2_events, update_phase2_reactive,
    Phase2State,
};
use crate::mna::solver::{Complex64, ComplexSystem, DenseSystem};
use crate::netlist::{Circuit, CompiledTopology, ComponentKind, FaultKind};

const DEFAULT_GMIN: f64 = 1e-12;
const NR_MAX_ITERS: usize = 150;
const NR_ABSTOL: f64 = 1e-7;
const NR_RELTOL: f64 = 1e-4;

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum IntegratorKind {
    BackwardEuler = 0,
    #[default]
    Trapezoidal = 1,
    Gear2 = 2,
}

#[derive(Debug, Clone, Copy)]
pub struct SimConfig {
    pub temp_k: f64,
    pub integrator: IntegratorKind,
    pub uic: bool,
    pub reltol: f64,
    pub abstol: f64,
    pub gmin: f64,
}

impl Default for SimConfig {
    fn default() -> Self {
        Self {
            temp_k: 300.0,
            integrator: IntegratorKind::Trapezoidal,
            uic: false,
            reltol: NR_RELTOL,
            abstol: NR_ABSTOL,
            gmin: DEFAULT_GMIN,
        }
    }
}

impl SimConfig {
    #[inline]
    pub fn vt(&self) -> f64 {
        thermal_voltage(self.temp_k)
    }
}

#[derive(Debug, Clone, Copy)]
pub struct AcPoint {
    pub freq_hz: f64,
    pub mag_db: f64,
    pub phase_deg: f64,
}

#[derive(Debug, Clone, Default)]
struct ReactiveState {
    cap_v_prev: Vec<f64>,
    cap_v_prev2: Vec<f64>,
    cap_i_prev: Vec<f64>,
    ind_i_prev: Vec<f64>,
    ind_i_prev2: Vec<f64>,
    ind_v_prev: Vec<f64>,
    prev_dt: f64,
    have_prev2: bool,
    discontinuity: bool,
    dff_q: Vec<bool>,
    dff_clk_prev: Vec<bool>,
    timer_out_high: Vec<bool>,
    counter_val: Vec<u8>,
}

pub struct SimEngine {
    pub circuit: Circuit,
    pub config: SimConfig,
    pub topo: Option<CompiledTopology>,
    pub solution: Vec<f64>,
    pub t_sim: f64,
    pub default_dt: f64,
    pub scope_nodes: [Option<u32>; 4],
    pub scope: ScopeBuffer,
    pub logic_nodes: Vec<Option<u32>>,
    pub logic_samples: std::collections::VecDeque<(f64, u16)>,
    pub logic_threshold: f64,
    reactive: ReactiveState,
    phase2: Phase2State,
    dc_source_scale: f64,
}

impl Default for SimEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl SimEngine {
    pub fn new() -> Self {
        Self {
            circuit: Circuit::new(),
            config: SimConfig::default(),
            topo: None,
            solution: Vec::new(),
            t_sim: 0.0,
            default_dt: 1e-4,
            scope_nodes: [None; 4],
            scope: ScopeBuffer::new(4096),
            logic_nodes: vec![None; 16],
            logic_samples: std::collections::VecDeque::with_capacity(4096),
            logic_threshold: 1.5,
            reactive: ReactiveState::default(),
            phase2: Phase2State::default(),
            dc_source_scale: 1.0,
        }
    }

    pub fn clear(&mut self) {
        self.circuit.clear();
        self.topo = None;
        self.solution.clear();
        self.t_sim = 0.0;
        self.scope_nodes = [None; 4];
        self.scope.clear();
        self.logic_nodes.fill(None);
        self.logic_samples.clear();
        self.reactive = ReactiveState::default();
        self.phase2 = Phase2State::default();
        self.dc_source_scale = 1.0;
    }

    pub fn compile_and_dc(&mut self) -> Result<(), SimError> {
        for comp in &mut self.circuit.components {
            if let ComponentKind::Fuse { blown, .. } = &mut comp.kind {
                *blown = false;
            }
        }
        let topo = self.circuit.compile()?;
        let n = topo.matrix_size();
        let count = self.circuit.components.len();
        self.solution = vec![0.0; n];
        self.t_sim = 0.0;
        self.scope.clear();
        self.logic_samples.clear();
        self.dc_source_scale = 1.0;
        self.reactive = ReactiveState {
            cap_v_prev: vec![0.0; count],
            cap_v_prev2: vec![0.0; count],
            cap_i_prev: vec![0.0; count],
            ind_i_prev: vec![0.0; count],
            ind_i_prev2: vec![0.0; count],
            ind_v_prev: vec![0.0; count],
            prev_dt: 0.0,
            have_prev2: false,
            discontinuity: true,
            dff_q: vec![false; count],
            dff_clk_prev: vec![false; count],
            timer_out_high: vec![true; count],
            counter_val: vec![0; count],
        };
        self.phase2 = Phase2State::with_len(count);
        self.topo = Some(topo);

        if !self.config.uic {
            self.solve_dc()?;
        }

        // Initialize capacitor/inductor/flip-flop/timer history from DC OP (or explicit IC if set).
        let mut timer_changed = false;
        let need_dc_resolve = if let Some(topo) = &self.topo {
            for (idx, comp) in self.circuit.components.iter().enumerate() {
                let next_high = match comp.kind {
                    ComponentKind::Timer555 { v_cc, .. } => {
                        let v_trig = node_v(&self.solution, topo, comp.nodes[0]);
                        let v_thrs = node_v(&self.solution, topo, comp.nodes[1]);
                        if v_trig < v_cc / 3.0 {
                            true
                        } else {
                            v_thrs <= 2.0 * v_cc / 3.0
                        }
                    }
                    ComponentKind::SchmittTrigger { .. } => {
                        let v_diff = node_v(&self.solution, topo, comp.nodes[0])
                            - node_v(&self.solution, topo, comp.nodes[1]);
                        v_diff >= 0.0
                    }
                    _ => continue,
                };
                if self.reactive.timer_out_high[idx] != next_high {
                    self.reactive.timer_out_high[idx] = next_high;
                    timer_changed = true;
                }
            }
            init_phase2_after_dc(
                &self.circuit.components,
                &self.solution,
                topo,
                &mut self.phase2,
            )
        } else {
            false
        };
        if (need_dc_resolve || timer_changed) && !self.config.uic {
            self.solve_dc()?;
        }
        if let Some(topo) = &self.topo {
            for (idx, comp) in self.circuit.components.iter().enumerate() {
                match comp.kind {
                    ComponentKind::Capacitor { ic, .. } => {
                        let v_dc = if self.config.uic {
                            0.0
                        } else {
                            node_v(&self.solution, topo, comp.nodes[0])
                                - node_v(&self.solution, topo, comp.nodes[1])
                        };
                        let v0 = ic.unwrap_or(v_dc);
                        self.reactive.cap_v_prev[idx] = v0;
                        self.reactive.cap_v_prev2[idx] = v0;
                    }
                    ComponentKind::VaractorDiode { .. } => {
                        let v_dc = if self.config.uic {
                            0.0
                        } else {
                            node_v(&self.solution, topo, comp.nodes[0])
                                - node_v(&self.solution, topo, comp.nodes[1])
                        };
                        self.reactive.cap_v_prev[idx] = v_dc;
                        self.reactive.cap_v_prev2[idx] = v_dc;
                    }
                    ComponentKind::Inductor { ic, .. } => {
                        let i_dc = if self.config.uic {
                            0.0
                        } else {
                            topo.branch_of_comp[idx].map_or(0.0, |b| self.solution[b])
                        };
                        let i0 = ic.unwrap_or(i_dc);
                        self.reactive.ind_i_prev[idx] = i0;
                        self.reactive.ind_i_prev2[idx] = i0;
                    }
                    ComponentKind::DFlipFlop { v_high, .. } => {
                        let vclk = node_v(&self.solution, topo, comp.nodes[1]);
                        self.reactive.dff_clk_prev[idx] = vclk >= 0.5 * v_high;
                    }
                    ComponentKind::Timer555 { v_cc, .. } => {
                        let v_trig = node_v(&self.solution, topo, comp.nodes[0]);
                        let v_thrs = node_v(&self.solution, topo, comp.nodes[1]);
                        self.reactive.timer_out_high[idx] = if v_trig < v_cc / 3.0 {
                            true
                        } else {
                            v_thrs <= 2.0 * v_cc / 3.0
                        };
                    }
                    ComponentKind::SchmittTrigger { .. } => {
                        let v_diff = node_v(&self.solution, topo, comp.nodes[0])
                            - node_v(&self.solution, topo, comp.nodes[1]);
                        self.reactive.timer_out_high[idx] = v_diff >= 0.0;
                    }
                    ComponentKind::Counter4Bit { v_high, .. } => {
                        self.reactive.dff_clk_prev[idx] =
                            node_v(&self.solution, topo, comp.nodes[0]) >= 0.5 * v_high;
                    }
                    _ => {}
                }
            }
        }
        Ok(())
    }

    pub fn solve_dc(&mut self) -> Result<(), SimError> {
        let gmin = self.config.gmin;
        self.dc_source_scale = 1.0;
        // 1. Direct Newton-Raphson at configured Gmin
        if self.solve_newton_step(0.0, false, gmin).is_ok() {
            return Ok(());
        }
        // 2. Gmin-stepping down from 1e-4 to configured gmin
        let mut cur = 1e-4;
        let mut gmin_ok = true;
        for _ in 0..8 {
            if self.solve_newton_step(0.0, false, cur).is_err() {
                gmin_ok = false;
                break;
            }
            cur = (cur * 0.1).max(gmin);
        }
        if gmin_ok && self.solve_newton_step(0.0, false, gmin).is_ok() {
            return Ok(());
        }
        // 3. Source-stepping fallback (ramps independent sources from 0.1 -> 1.0)
        self.solution.fill(0.0);
        for &scale in &[0.05, 0.15, 0.3, 0.5, 0.75, 1.0] {
            self.dc_source_scale = scale;
            if let Err(err) = self.solve_newton_step(0.0, false, gmin) {
                self.dc_source_scale = 1.0;
                return Err(err);
            }
        }
        self.dc_source_scale = 1.0;
        Ok(())
    }

    /// Solves DC operating point in place without resetting transient time, scope, fuses, or latches.
    pub fn solve_dc_op(&mut self) -> Result<(), SimError> {
        if self.topo.is_none() {
            self.compile_and_dc()
        } else {
            self.solve_dc()
        }
    }

    /// Updates a 64-bit WordGen bit-pattern losslessly without f64 mantissa truncation.
    pub fn set_wordgen_pattern(&mut self, comp_id: u32, pattern: u64) -> Result<(), SimError> {
        let comp = self
            .circuit
            .components
            .iter_mut()
            .find(|c| c.id == comp_id)
            .ok_or_else(|| SimError::new(SimErrorCode::UnknownComponent, comp_id as i32))?;
        match &mut comp.kind {
            ComponentKind::WordGen { pattern: p, .. } => {
                *p = pattern;
                Ok(())
            }
            _ => Err(SimError::new(
                SimErrorCode::InvalidParameter,
                comp_id as i32,
            )),
        }
    }

    /// Computes companion `(eq_conductance_or_resistance, history_rhs)` for C or L.
    fn reactive_companion(&self, idx: usize, val: f64, is_cap: bool, dt: f64) -> (f64, f64) {
        let (y1, y2, y_dot1) = if is_cap {
            (
                self.reactive.cap_v_prev[idx],
                self.reactive.cap_v_prev2[idx],
                self.reactive.cap_i_prev[idx],
            )
        } else {
            (
                self.reactive.ind_i_prev[idx],
                self.reactive.ind_i_prev2[idx],
                self.reactive.ind_v_prev[idx],
            )
        };
        let mode = if self.reactive.discontinuity || !self.reactive.have_prev2 {
            // Standard SPICE discontinuity restart: take one Backward-Euler step to avoid ringing without cross-edge BDF2 distortion.
            IntegratorKind::BackwardEuler
        } else {
            self.config.integrator
        };
        match mode {
            IntegratorKind::BackwardEuler => {
                let eq = val / dt;
                (eq, eq * y1)
            }
            IntegratorKind::Trapezoidal => {
                let eq = 2.0 * val / dt;
                (eq, eq * y1 + y_dot1)
            }
            IntegratorKind::Gear2 => {
                let r = (dt / self.reactive.prev_dt.max(1e-15)).clamp(0.05, 10.0);
                let c0 = (1.0 + 2.0 * r) / (1.0 + r);
                let c1 = -(1.0 + r);
                let c2 = (r * r) / (1.0 + r);
                let eq = val * c0 / dt;
                let hist = -val * (c1 * y1 + c2 * y2) / dt;
                (eq, hist)
            }
        }
    }

    pub fn step_transient(&mut self, dt: f64) -> Result<(), SimError> {
        self.step_transient_depth(dt, 0)
    }

    fn step_transient_depth(&mut self, dt: f64, depth: u8) -> Result<(), SimError> {
        if dt <= 0.0 || !dt.is_finite() {
            return Err(SimError::new(SimErrorCode::InvalidParameter, 0));
        }
        if self.topo.is_none() {
            self.compile_and_dc()?;
        }

        let t_prev = self.t_sim;
        let sol_prev = self.solution.clone();
        self.phase2.use_trap = !self.reactive.discontinuity
            && matches!(
                self.config.integrator,
                IntegratorKind::Trapezoidal | IntegratorKind::Gear2
            );
        self.t_sim += dt;
        if let Err(err) = self.solve_newton_step(dt, true, self.config.gmin) {
            self.t_sim = t_prev;
            self.solution = sol_prev;
            if depth < 2 {
                let half = dt * 0.5;
                self.step_transient_depth(half, depth + 1)?;
                return self.step_transient_depth(half, depth + 1);
            }
            return Err(err);
        }

        // Evaluate edge-triggered/latching updates and fuses BEFORE mutating reactive history so any re-solve uses t_prev states.
        let reactive_prev = self.reactive.clone();
        let phase2_prev = self.phase2.clone();
        let mut dff_changed = false;
        let mut tripped_fuses = Vec::new();
        {
            let topo = self.topo.as_ref().unwrap();
            for (idx, comp) in self.circuit.components.iter().enumerate() {
                let fault = comp.fault;
                match &comp.kind {
                    ComponentKind::Fuse { i_max, r_on, blown }
                        if !*blown && fault == FaultKind::None =>
                    {
                        let va = node_v(&self.solution, topo, comp.nodes[0]);
                        let vb = node_v(&self.solution, topo, comp.nodes[1]);
                        let current = ((va - vb) / *r_on).abs();
                        if current > *i_max {
                            tripped_fuses.push(idx);
                        }
                    }
                    ComponentKind::DFlipFlop { v_high, .. } if fault == FaultKind::None => {
                        let vd = node_v(&self.solution, topo, comp.nodes[0]);
                        let vclk = node_v(&self.solution, topo, comp.nodes[1]);
                        let thresh = 0.5 * *v_high;
                        let clk_high = vclk >= thresh;
                        if clk_high && !self.reactive.dff_clk_prev[idx] {
                            self.reactive.dff_q[idx] = vd >= thresh;
                            dff_changed = true;
                        }
                        self.reactive.dff_clk_prev[idx] = clk_high;
                    }
                    ComponentKind::Timer555 { v_cc, .. } if fault == FaultKind::None => {
                        let v_trig = node_v(&self.solution, topo, comp.nodes[0]);
                        let v_thrs = node_v(&self.solution, topo, comp.nodes[1]);
                        let prev = self.reactive.timer_out_high[idx];
                        let next = if v_trig < *v_cc / 3.0 {
                            true
                        } else if v_thrs > 2.0 * *v_cc / 3.0 {
                            false
                        } else {
                            prev
                        };
                        if next != prev {
                            self.reactive.timer_out_high[idx] = next;
                            dff_changed = true;
                        }
                    }
                    ComponentKind::SchmittTrigger { v_hyst, .. } if fault == FaultKind::None => {
                        let v_diff = node_v(&self.solution, topo, comp.nodes[0])
                            - node_v(&self.solution, topo, comp.nodes[1]);
                        let prev = self.reactive.timer_out_high[idx];
                        let next = if v_diff >= *v_hyst {
                            true
                        } else if v_diff <= -*v_hyst {
                            false
                        } else {
                            prev
                        };
                        if next != prev {
                            self.reactive.timer_out_high[idx] = next;
                            dff_changed = true;
                        }
                    }
                    ComponentKind::Counter4Bit { v_high, .. } if fault == FaultKind::None => {
                        let vclk = node_v(&self.solution, topo, comp.nodes[0]);
                        let clk_high = vclk >= 0.5 * *v_high;
                        if clk_high && !self.reactive.dff_clk_prev[idx] {
                            self.reactive.counter_val[idx] =
                                (self.reactive.counter_val[idx] + 1) & 0x7;
                            dff_changed = true;
                        }
                        self.reactive.dff_clk_prev[idx] = clk_high;
                    }
                    _ => {}
                }
            }
        }
        {
            let topo = self.topo.as_ref().unwrap();
            if update_phase2_events(
                &self.circuit.components,
                &self.solution,
                topo,
                &mut self.phase2,
            ) {
                dff_changed = true;
            }
        }
        if dff_changed {
            if let Err(err) = self.solve_newton_step(dt, true, self.config.gmin) {
                self.t_sim = t_prev;
                self.solution = sol_prev;
                self.reactive = reactive_prev;
                self.phase2 = phase2_prev;
                if depth < 2 {
                    let half = dt * 0.5;
                    self.step_transient_depth(half, depth + 1)?;
                    return self.step_transient_depth(half, depth + 1);
                }
                return Err(err);
            }
        }

        // Advance reactive history once from the final converged solution using t_prev state.
        let mut next_cap_i = vec![0.0; self.circuit.components.len()];
        let mut next_cap_v = vec![0.0; self.circuit.components.len()];
        let mut next_ind_i = vec![0.0; self.circuit.components.len()];
        let mut next_ind_v = vec![0.0; self.circuit.components.len()];
        {
            let topo = self.topo.as_ref().unwrap();
            for (idx, comp) in self.circuit.components.iter().enumerate() {
                match comp.kind {
                    ComponentKind::Capacitor { c, .. } => {
                        let va = node_v(&self.solution, topo, comp.nodes[0]);
                        let vb = node_v(&self.solution, topo, comp.nodes[1]);
                        let vc = va - vb;
                        let (geq, ieq) = self.reactive_companion(idx, c, true, dt);
                        next_cap_v[idx] = vc;
                        next_cap_i[idx] = geq * vc - ieq;
                    }
                    ComponentKind::VaractorDiode { cj0, vj, m, .. } => {
                        let va = node_v(&self.solution, topo, comp.nodes[0]);
                        let vb = node_v(&self.solution, topo, comp.nodes[1]);
                        let vc = va - vb;
                        let vr = (-vc).max(0.0);
                        let cj = cj0 / (1.0 + vr / vj.max(0.1)).powf(m);
                        let (geq, ieq) = self.reactive_companion(idx, cj, true, dt);
                        next_cap_v[idx] = vc;
                        next_cap_i[idx] = geq * vc - ieq;
                    }
                    ComponentKind::Inductor { .. } => {
                        let va = node_v(&self.solution, topo, comp.nodes[0]);
                        let vb = node_v(&self.solution, topo, comp.nodes[1]);
                        next_ind_v[idx] = va - vb;
                        if let Some(b) = topo.branch_of_comp[idx] {
                            next_ind_i[idx] = self.solution[b];
                        }
                    }
                    _ => {}
                }
            }
        }
        for idx in 0..self.circuit.components.len() {
            match self.circuit.components[idx].kind {
                ComponentKind::Capacitor { .. } | ComponentKind::VaractorDiode { .. } => {
                    self.reactive.cap_v_prev2[idx] = self.reactive.cap_v_prev[idx];
                    self.reactive.cap_v_prev[idx] = next_cap_v[idx];
                    self.reactive.cap_i_prev[idx] = next_cap_i[idx];
                }
                ComponentKind::Inductor { .. } => {
                    self.reactive.ind_i_prev2[idx] = self.reactive.ind_i_prev[idx];
                    self.reactive.ind_i_prev[idx] = next_ind_i[idx];
                    self.reactive.ind_v_prev[idx] = next_ind_v[idx];
                }
                _ => {}
            }
        }
        {
            let topo = self.topo.as_ref().unwrap();
            update_phase2_reactive(
                &self.circuit.components,
                &self.solution,
                topo,
                &mut self.phase2,
                dt,
            );
        }
        let any_trip = !tripped_fuses.is_empty();
        for idx in tripped_fuses {
            if let ComponentKind::Fuse { blown, .. } = &mut self.circuit.components[idx].kind {
                *blown = true;
            }
        }
        self.reactive.prev_dt = dt;
        self.reactive.have_prev2 = !dff_changed && !any_trip;
        self.reactive.discontinuity = dff_changed || any_trip;

        let topo = self.topo.as_ref().unwrap();
        let mut frame = [0.0_f64; 4];
        for (ch, node_opt) in self.scope_nodes.iter().enumerate() {
            if let Some(nid) = node_opt {
                frame[ch] = node_v(&self.solution, topo, *nid);
            }
        }
        self.scope.push(self.t_sim, frame);
        let mut logic_mask = 0u16;
        for (ch, node_opt) in self.logic_nodes.iter().enumerate().take(16) {
            if let Some(nid) = node_opt {
                if node_v(&self.solution, topo, *nid) >= self.logic_threshold {
                    logic_mask |= 1u16 << ch;
                }
            }
        }
        if self.logic_samples.len() >= 4096 {
            self.logic_samples.pop_front();
        }
        self.logic_samples.push_back((self.t_sim, logic_mask));
        Ok(())
    }

    /// Returns the time interval to the next sharp source transition after `t_now`, if any.
    fn next_breakpoint_dt(&self, t_now: f64, max_dt: f64) -> f64 {
        let mut best = max_dt;
        let eps = 1e-11;
        for comp in &self.circuit.components {
            match comp.kind {
                ComponentKind::ClockSource { freq, .. } if freq > 0.0 => {
                    let half = 0.5 / freq;
                    let phase = (t_now / half).fract();
                    let rem = (1.0 - phase) * half;
                    if rem > eps && rem < best {
                        best = rem;
                    }
                }
                ComponentKind::WordGen { freq, .. } if freq > 0.0 => {
                    let step_p = 1.0 / freq;
                    let rem = (1.0 - (t_now / step_p).fract()) * step_p;
                    if rem > eps && rem < best {
                        best = rem;
                    }
                }
                ComponentKind::PulseVoltage {
                    td,
                    tr,
                    pw,
                    tf,
                    per,
                    ..
                } if per > 0.0 => {
                    if t_now < td {
                        let rem = td - t_now;
                        if rem > eps && rem < best {
                            best = rem;
                        }
                    } else {
                        let cyc = (t_now - td).rem_euclid(per);
                        for &edge in &[tr, tr + pw, tr + pw + tf, per] {
                            let rem = edge - cyc;
                            if rem > eps && rem < best {
                                best = rem;
                            }
                        }
                    }
                }
                ComponentKind::PwlSource { pts, count } => {
                    for &[t_k, _] in pts.iter().take((count as usize).min(4)) {
                        let rem = t_k - t_now;
                        if rem > eps && rem < best {
                            best = rem;
                        }
                    }
                }
                _ => {}
            }
        }
        best.max(max_dt * 0.05)
    }

    fn max_reactive_curvature(&self) -> f64 {
        if !self.reactive.have_prev2 {
            return 0.0;
        }
        let mut max_ratio = 0.0f64;
        for (idx, comp) in self.circuit.components.iter().enumerate() {
            if matches!(
                comp.kind,
                ComponentKind::Capacitor { .. } | ComponentKind::VaractorDiode { .. }
            ) {
                let v0 = self.reactive.cap_v_prev[idx];
                let v1 = self.reactive.cap_v_prev2[idx];
                let tol = self.config.abstol + self.config.reltol * v0.abs().max(1.0);
                let ratio = (v0 - v1).abs() / tol;
                if ratio > max_ratio {
                    max_ratio = ratio;
                }
            }
        }
        max_ratio
    }

    /// Advances simulation by `sim_duration` seconds regardless of caller display FPS (60Hz or 120Hz).
    pub fn run_for_frame(&mut self, sim_duration: f64, max_steps: usize) -> Result<(), SimError> {
        if sim_duration <= 0.0 {
            return Ok(());
        }
        if self.topo.is_none() {
            self.compile_and_dc()?;
        }
        let max_freq = self.max_source_freq();
        let target_dt = if max_freq > 0.0 {
            (1.0 / (max_freq * 40.0)).min(self.default_dt)
        } else {
            self.default_dt
        };
        let t_target = self.t_sim + sim_duration;
        let budget = max_steps.max(1);
        let base_dt = (sim_duration / budget as f64).max(target_dt.min(sim_duration));
        let min_dt = base_dt * 0.1;
        let mut cur_dt = base_dt;
        let mut steps_done = 0usize;
        while self.t_sim + 1e-13 < t_target && steps_done < budget {
            let rem = t_target - self.t_sim;
            let raw_dt = if steps_done + 1 == budget {
                rem
            } else {
                rem.min(cur_dt)
            };
            let dt = self.next_breakpoint_dt(self.t_sim, raw_dt).min(rem);
            self.step_transient(dt)?;
            steps_done += 1;
            // Lightweight LTE step control based on reactive slew relative to reltol
            let slew = self.max_reactive_curvature();
            if slew > 120.0 && cur_dt > min_dt {
                cur_dt = (cur_dt * 0.5).max(min_dt);
            } else if slew < 30.0 && cur_dt < base_dt {
                cur_dt = (cur_dt * 1.25).min(base_dt);
            }
        }
        Ok(())
    }

    /// Updates interactive controls live without tearing down transient history.
    pub fn set_control(
        &mut self,
        comp_id: u32,
        param_idx: u32,
        value: f64,
    ) -> Result<(), SimError> {
        if !value.is_finite() {
            return Err(SimError::new(
                SimErrorCode::InvalidParameter,
                comp_id as i32,
            ));
        }
        let comp = self
            .circuit
            .components
            .iter_mut()
            .find(|c| c.id == comp_id)
            .ok_or_else(|| SimError::new(SimErrorCode::UnknownComponent, comp_id as i32))?;

        match &mut comp.kind {
            ComponentKind::Potentiometer { r_total, wiper } => match param_idx {
                0 => *wiper = value.clamp(0.001, 0.999),
                1 => {
                    if value <= 0.0 {
                        return Err(SimError::new(
                            SimErrorCode::InvalidParameter,
                            comp_id as i32,
                        ));
                    }
                    *r_total = value;
                }
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::SwitchSpst { closed, .. } => *closed = value >= 0.5,
            ComponentKind::SwitchSpdt { throw_b, .. } => *throw_b = value >= 0.5,
            ComponentKind::Vccs { gm } => *gm = value,
            ComponentKind::Vcvs { gain } | ComponentKind::Cccs { gain } => *gain = value,
            ComponentKind::Ccvs { rm } => *rm = value,
            ComponentKind::DcCurrent { i } => *i = value,
            ComponentKind::Transformer { ratio } => {
                if value.abs() < 1e-6 {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        comp_id as i32,
                    ));
                }
                *ratio = value;
            }
            ComponentKind::Fuse { i_max, blown, .. } => match param_idx {
                0 => *blown = value >= 0.5,
                1 => {
                    if value <= 0.0 {
                        return Err(SimError::new(
                            SimErrorCode::InvalidParameter,
                            comp_id as i32,
                        ));
                    }
                    *i_max = value;
                }
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::DcVoltage { v } => *v = value,
            ComponentKind::AcVoltage {
                amp,
                freq,
                phase_deg,
                offset,
            } => match param_idx {
                0 => *amp = value,
                1 => *freq = value.max(0.0),
                2 => *phase_deg = value,
                3 => *offset = value,
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::FunctionGen {
                amp,
                freq,
                offset,
                duty,
                ..
            } => match param_idx {
                0 => *freq = value.max(0.0),
                1 => *amp = value,
                2 => *offset = value,
                3 => *duty = value.clamp(0.01, 0.99),
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::Resistor { r } => {
                if value <= 0.0 {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        comp_id as i32,
                    ));
                }
                *r = value;
            }
            ComponentKind::Capacitor { c, .. } => {
                if value <= 0.0 {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        comp_id as i32,
                    ));
                }
                *c = value;
            }
            ComponentKind::Inductor { l, .. } => {
                if value <= 0.0 {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        comp_id as i32,
                    ));
                }
                *l = value;
            }
            ComponentKind::Diode { bv, .. } => {
                *bv = if value > 0.0 { value } else { f64::INFINITY };
            }
            ComponentKind::NpnBjt { bf, .. } | ComponentKind::PnpBjt { bf, .. } => {
                if value <= 0.0 {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        comp_id as i32,
                    ));
                }
                *bf = value;
            }
            ComponentKind::Nmos { kp, vth, .. } | ComponentKind::Pmos { kp, vth, .. } => {
                match param_idx {
                    0 => {
                        if value <= 0.0 {
                            return Err(SimError::new(
                                SimErrorCode::InvalidParameter,
                                comp_id as i32,
                            ));
                        }
                        *kp = value;
                    }
                    1 => *vth = value,
                    _ => {
                        return Err(SimError::new(
                            SimErrorCode::InvalidParameter,
                            param_idx as i32,
                        ))
                    }
                }
            }
            ComponentKind::OpAmp {
                gain,
                v_sat_pos,
                v_sat_neg,
                ..
            } => match param_idx {
                0 => *gain = value.max(1.0),
                1 => *v_sat_pos = value,
                2 => *v_sat_neg = value,
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::Relay { r_coil, v_pull, .. } => match param_idx {
                0 => *r_coil = value.max(1.0),
                1 => *v_pull = value.max(0.1),
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::ClockSource { freq, v_high, .. }
            | ComponentKind::WordGen { freq, v_high, .. } => match param_idx {
                0 => *freq = value.max(0.0),
                1 => *v_high = value.max(0.1),
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::Optocoupler { ctr, .. } => {
                if value <= 0.0 {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        comp_id as i32,
                    ));
                }
                *ctr = value;
            }
            ComponentKind::SchmittTrigger { v_hyst, v_high, .. } => match param_idx {
                0 => *v_hyst = value.max(0.0),
                1 => *v_high = value.max(0.1),
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::Counter4Bit { v_high, r_out } => match param_idx {
                0 => *v_high = value.max(0.1),
                1 => *r_out = value.max(1.0),
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::AcCurrent {
                amp,
                freq,
                phase_deg,
                offset,
            } => match param_idx {
                0 => *amp = value,
                1 => *freq = value.max(0.0),
                2 => *phase_deg = value,
                3 => *offset = value,
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::PulseVoltage { v1, v2, per, .. } => match param_idx {
                0 => *v1 = value,
                1 => *v2 = value,
                2 => *per = value.max(1e-6),
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::VoltageReg { v_out, .. } => *v_out = value.max(0.1),
            ComponentKind::InstAmp { gain, .. } | ComponentKind::AnalogMultiplier { gain, .. } => {
                *gain = value;
            }
            ComponentKind::Vco { f0, df_dv, .. } => match param_idx {
                0 => *f0 = value.max(0.0),
                1 => *df_dv = value,
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::HexKeypad { nibble, .. } => {
                *nibble = (value.round() as i32).clamp(0, 15) as u8
            }
            ComponentKind::DipSwitch4 { mask, .. } => {
                *mask = (value.round() as i32).clamp(0, 15) as u8
            }
            ComponentKind::RelayDpdt { r_coil, v_pull, .. } => match param_idx {
                0 => *r_coil = value.max(1.0),
                1 => *v_pull = value.max(0.1),
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::CenterTapTransformer { ratio } => {
                if value.abs() < 1e-6 {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        comp_id as i32,
                    ));
                }
                *ratio = value;
            }
            ComponentKind::CoupledInductor { l1, l2, k } => match param_idx {
                0 => *l1 = value.max(1e-12),
                1 => *l2 = value.max(1e-12),
                _ => *k = value.clamp(-0.999, 0.999),
            },
            ComponentKind::DcMotor { r_a, ke, .. } => match param_idx {
                0 => *r_a = value.max(0.05),
                _ => *ke = value.max(0.0),
            },
            ComponentKind::Counter4BitFull { v_high, r_out }
            | ComponentKind::DFlipFlop { v_high, r_out }
            | ComponentKind::SrLatch { v_high, r_out }
            | ComponentKind::JkFlipFlop { v_high, r_out }
            | ComponentKind::TFlipFlop { v_high, r_out }
            | ComponentKind::DFlipFlopAsync { v_high, r_out }
            | ComponentKind::ShiftReg4Bit { v_high, r_out }
            | ComponentKind::Mux4To1 { v_high, r_out }
            | ComponentKind::Demux1To4 { v_high, r_out }
            | ComponentKind::Decoder2To4 { v_high, r_out }
            | ComponentKind::FullAdder { v_high, r_out }
            | ComponentKind::MagComparator { v_high, r_out }
            | ComponentKind::Alu2Bit { v_high, r_out }
            | ComponentKind::TriStateBuffer { v_high, r_out }
            | ComponentKind::DigitalGate { v_high, r_out, .. }
            | ComponentKind::DigitalGateMulti { v_high, r_out, .. }
            | ComponentKind::SampleHold { v_high, r_out } => match param_idx {
                0 => *v_high = value.max(0.1),
                1 => *r_out = value.max(1.0),
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::Timer555 { v_cc, r_out } => match param_idx {
                0 => *v_cc = value.max(0.5),
                1 => *r_out = value.max(1.0),
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::PwlSource { pts, count } => {
                let idx_p = (param_idx as usize) / 2;
                let coord = (param_idx as usize) % 2;
                if idx_p >= (*count as usize).min(4) {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ));
                }
                pts[idx_p][coord] = if coord == 0 { value.max(0.0) } else { value };
            }
            ComponentKind::VControlledSwitch { v_on, v_off, .. } => match param_idx {
                0 => *v_on = value,
                1 => *v_off = value,
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::IControlledSwitch { i_on, i_off, .. } => match param_idx {
                0 => *i_on = value,
                1 => *i_off = value,
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::Njfet { beta, vto, .. } | ComponentKind::Pjfet { beta, vto, .. } => {
                match param_idx {
                    0 => *beta = value.max(1e-9),
                    1 => *vto = value,
                    _ => {
                        return Err(SimError::new(
                            SimErrorCode::InvalidParameter,
                            param_idx as i32,
                        ))
                    }
                }
            }
            ComponentKind::Igbt { kp, vth, .. } => match param_idx {
                0 => *kp = value.max(1e-6),
                1 => *vth = value,
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::ComparatorOc { v_high, r_pu } => match param_idx {
                0 => *v_high = value.max(0.1),
                1 => *r_pu = value.max(10.0),
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::Crystal { rm, lm, cm, c0 } => match param_idx {
                0 => *rm = value.max(1e-3),
                1 => *lm = value.max(1e-12),
                2 => *cm = value.max(1e-18),
                3 => *c0 = value.max(1e-18),
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::Adc4Bit { v_ref, v_high, .. } => match param_idx {
                0 => *v_ref = value.max(0.1),
                1 => *v_high = value.max(0.1),
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::Dac4Bit { v_ref, .. } => *v_ref = value.max(0.1),
            ComponentKind::VaractorDiode { cj0, vj, m, .. } => match param_idx {
                0 => *cj0 = value.max(1e-15),
                1 => *vj = value.max(0.1),
                2 => *m = value.max(0.05),
                _ => {
                    return Err(SimError::new(
                        SimErrorCode::InvalidParameter,
                        param_idx as i32,
                    ))
                }
            },
            ComponentKind::Scr { i_hold, v_bo, .. } | ComponentKind::Triac { i_hold, v_bo, .. } => {
                match param_idx {
                    0 => *i_hold = value.max(1e-6),
                    1 => *v_bo = value.max(1.0),
                    _ => {
                        return Err(SimError::new(
                            SimErrorCode::InvalidParameter,
                            param_idx as i32,
                        ))
                    }
                }
            }
            ComponentKind::Diac { v_bo, .. } => *v_bo = value.max(1.0),
            ComponentKind::BridgeRectifier { n, .. }
            | ComponentKind::BarGraphLed { n, .. }
            | ComponentKind::RgbLed { n, .. }
            | ComponentKind::Led { n, .. } => *n = value.max(0.1),
            ComponentKind::LogicProbe { r_in } | ComponentKind::SevenSeg { r_in } => {
                *r_in = value.max(1.0);
            }
            ComponentKind::Wattmeter { r_shunt } => *r_shunt = value.max(1e-4),
        }
        self.reactive.discontinuity = true;
        Ok(())
    }

    pub fn is_fuse_blown(&self, comp_id: u32) -> bool {
        self.circuit
            .components
            .iter()
            .find(|c| c.id == comp_id)
            .is_some_and(|c| matches!(c.kind, ComponentKind::Fuse { blown: true, .. }))
    }

    pub fn set_fault(&mut self, comp_id: u32, fault: FaultKind) -> Result<(), SimError> {
        let comp = self
            .circuit
            .components
            .iter_mut()
            .find(|c| c.id == comp_id)
            .ok_or_else(|| SimError::new(SimErrorCode::UnknownComponent, comp_id as i32))?;
        comp.fault = fault;
        self.reactive.discontinuity = true;
        Ok(())
    }

    pub fn node_voltage(&self, node_id: u32) -> f64 {
        match &self.topo {
            Some(topo) => node_v(&self.solution, topo, node_id),
            None => 0.0,
        }
    }

    pub fn component_current(&self, comp_id: u32) -> f64 {
        let Some(topo) = &self.topo else {
            return 0.0;
        };
        let Some((idx, comp)) = self
            .circuit
            .components
            .iter()
            .enumerate()
            .find(|(_, c)| c.id == comp_id)
        else {
            return 0.0;
        };
        let va = node_v(&self.solution, topo, comp.nodes[0]);
        let vb = node_v(&self.solution, topo, comp.nodes[1]);
        if comp.fault == FaultKind::Open {
            return (va - vb) * 1e-12;
        }
        if let Some(b) = topo.branch_of_comp[idx] {
            if comp.fault == FaultKind::Short {
                return self.solution[b];
            }
            if !matches!(comp.kind, ComponentKind::IControlledSwitch { .. }) {
                let i = match comp.kind {
                    ComponentKind::Cccs { gain } => gain * self.solution[b],
                    ComponentKind::Crystal { .. } => {
                        self.solution[b] + self.phase2.aux_d.get(idx).copied().unwrap_or(0.0)
                    }
                    _ => self.solution[b],
                };
                return if comp.fault == FaultKind::Leaky {
                    i + (va - vb) / 500.0
                } else {
                    i
                };
            }
        }
        if comp.fault == FaultKind::Short {
            return (va - vb) * 1000.0;
        }
        let vt = self.config.vt();
        let gmin = self.config.gmin;
        let base_i = match comp.kind {
            ComponentKind::Resistor { r } => (va - vb) / r,
            ComponentKind::Potentiometer { r_total, wiper } => {
                let w = wiper.clamp(0.001, 0.999);
                let vw = node_v(&self.solution, topo, comp.nodes[2]);
                (va - vw) / (r_total * (1.0 - w))
            }
            ComponentKind::Capacitor { .. } => {
                self.reactive.cap_i_prev.get(idx).copied().unwrap_or(0.0)
            }
            ComponentKind::SwitchSpst {
                closed,
                r_on,
                r_off,
            } => (va - vb) / if closed { r_on } else { r_off },
            ComponentKind::SwitchSpdt {
                throw_b,
                r_on,
                r_off,
            } => {
                let vc = node_v(&self.solution, topo, comp.nodes[2]);
                let (ra, rb) = if throw_b {
                    (r_off, r_on)
                } else {
                    (r_on, r_off)
                };
                (va - vb) / ra + (va - vc) / rb
            }
            ComponentKind::Vccs { gm } => {
                let vcp = node_v(&self.solution, topo, comp.nodes[2]);
                let vcn = node_v(&self.solution, topo, comp.nodes[3]);
                gm * (vcp - vcn)
            }
            ComponentKind::Fuse { r_on, blown, .. } => (va - vb) / if blown { 1e9 } else { r_on },
            ComponentKind::DcCurrent { i } => i,
            ComponentKind::Diode { is_sat, n, bv } => {
                eval_diode_vt(va - vb, is_sat, n, bv, gmin, vt).0
            }
            ComponentKind::VaractorDiode { is_sat, .. } => {
                let i_d = eval_diode_vt(va - vb, is_sat, 1.2, f64::INFINITY, gmin, vt).0;
                i_d + self.reactive.cap_i_prev.get(idx).copied().unwrap_or(0.0)
            }
            ComponentKind::Led { is_sat, n, .. } => {
                eval_diode_vt(va - vb, is_sat, n, f64::INFINITY, gmin, vt).0
            }
            ComponentKind::OpAmp {
                gain,
                v_sat_pos,
                v_sat_neg,
                r_out,
            } => {
                let v_diff = va - vb;
                let v_mid = 0.5 * (v_sat_pos + v_sat_neg);
                let v_half = (0.5 * (v_sat_pos - v_sat_neg)).max(0.1);
                let v_target = v_mid + v_half * (gain * v_diff / v_half).clamp(-20.0, 20.0).tanh();
                let vo = node_v(&self.solution, topo, comp.nodes[2]);
                (v_target - vo) / r_out.max(1e-3)
            }
            ComponentKind::NpnBjt { is_sat, bf, br } | ComponentKind::PnpBjt { is_sat, bf, br } => {
                let pol = if matches!(comp.kind, ComponentKind::NpnBjt { .. }) {
                    1.0
                } else {
                    -1.0
                };
                let vc = va;
                let vb_n = vb;
                let ve = node_v(&self.solution, topo, comp.nodes[2]);
                let i_f = eval_diode_vt(pol * (vb_n - ve), is_sat, 1.0, f64::INFINITY, gmin, vt).0;
                let i_r = eval_diode_vt(pol * (vb_n - vc), is_sat, 1.0, f64::INFINITY, gmin, vt).0;
                let alpha_r = br / (br + 1.0);
                let _ = bf;
                pol * (i_f - i_r / alpha_r)
            }
            ComponentKind::Nmos { kp, vth, lambda } | ComponentKind::Pmos { kp, vth, lambda } => {
                let pol = if matches!(comp.kind, ComponentKind::Nmos { .. }) {
                    1.0
                } else {
                    -1.0
                };
                let vs = node_v(&self.solution, topo, comp.nodes[2]);
                let vds_raw = pol * (va - vs);
                let rev = vds_raw < 0.0;
                let (vgs, vds) = if rev {
                    (pol * (vb - va), -vds_raw)
                } else {
                    (pol * (vb - vs), vds_raw)
                };
                let vov = vgs - vth;
                let mag = if vov <= 0.0 {
                    0.0
                } else if vds < vov {
                    kp * (vov * vds - 0.5 * vds * vds) * (1.0 + lambda * vds)
                } else {
                    0.5 * kp * vov * vov * (1.0 + lambda * vds)
                };
                pol * if rev { -mag } else { mag }
            }
            ComponentKind::DigitalGate {
                kind,
                v_high,
                r_out,
            } => {
                let (out_pin, v_tgt) = if comp.pin_count == 2 {
                    (
                        comp.nodes[1],
                        crate::digital::eval_soft_gate(kind, &[va], v_high),
                    )
                } else {
                    (
                        comp.nodes[2],
                        crate::digital::eval_soft_gate(kind, &[va, vb], v_high),
                    )
                };
                let vo = node_v(&self.solution, topo, out_pin);
                (v_tgt - vo) / r_out.max(1.0)
            }
            ComponentKind::ClockSource {
                freq,
                v_high,
                r_out,
            } => {
                let vt = if self.t_sim > 0.0
                    && freq > 0.0
                    && (self.t_sim * freq).rem_euclid(1.0) < 0.5
                {
                    v_high
                } else {
                    0.0
                };
                (vt - (va - vb)) / r_out.max(1.0)
            }
            ComponentKind::DFlipFlop { v_high, r_out } => {
                let q_high = self.reactive.dff_q.get(idx).copied().unwrap_or(false);
                let vq = if q_high { v_high } else { 0.0 };
                (vq - node_v(&self.solution, topo, comp.nodes[2])) / r_out.max(1.0)
            }
            ComponentKind::LogicProbe { r_in } => va / r_in.max(1.0),
            ComponentKind::Timer555 { v_cc, r_out } => {
                let out_high = self
                    .reactive
                    .timer_out_high
                    .get(idx)
                    .copied()
                    .unwrap_or(true);
                let v_target = if out_high { v_cc } else { 0.0 };
                (v_target - node_v(&self.solution, topo, comp.nodes[3])) / r_out.max(1.0)
            }
            ComponentKind::SevenSeg { r_in } => {
                let g = 1.0 / r_in.max(1e3);
                (0..4)
                    .map(|k| node_v(&self.solution, topo, comp.nodes[k]) * g)
                    .sum()
            }
            ComponentKind::Relay { r_coil, .. } => (va - vb) / r_coil,
            ComponentKind::WordGen {
                freq,
                pattern,
                v_high,
                r_out,
            } => {
                let step_idx = if self.t_sim > 0.0 && freq > 0.0 {
                    ((self.t_sim * freq).floor() as usize) & 0xF
                } else {
                    0
                };
                let nib = ((pattern >> (step_idx * 4)) & 0xF) as u8;
                let g_out = 1.0 / r_out.max(1.0);
                (0..4)
                    .map(|k| {
                        let vt = if ((nib >> (3 - k)) & 1) == 1 {
                            v_high
                        } else {
                            0.0
                        };
                        (vt - node_v(&self.solution, topo, comp.nodes[k])) * g_out
                    })
                    .sum()
            }
            ComponentKind::Optocoupler { ctr, is_sat, n } => {
                let vc = node_v(&self.solution, topo, comp.nodes[2]);
                let ve = node_v(&self.solution, topo, comp.nodes[3]);
                let i_led = eval_diode_vt(va - vb, is_sat, n, f64::INFINITY, gmin, vt).0;
                let vce = vc - ve;
                let sat = if vce > 0.0 {
                    (vce / 0.1).clamp(-20.0, 20.0).tanh()
                } else {
                    0.0
                };
                ctr * i_led.max(0.0) * sat + gmin * vce
            }
            ComponentKind::SchmittTrigger { v_high, r_out, .. } => {
                let out_high = self
                    .reactive
                    .timer_out_high
                    .get(idx)
                    .copied()
                    .unwrap_or(false);
                let v_target = if out_high { v_high } else { 0.0 };
                (v_target - node_v(&self.solution, topo, comp.nodes[2])) / r_out.max(1.0)
            }
            ComponentKind::Counter4Bit { v_high, r_out } => {
                let val = self.reactive.counter_val.get(idx).copied().unwrap_or(0);
                let g = 1.0 / r_out.max(1.0);
                (0..3)
                    .map(|b| {
                        let vt = if ((val >> (2 - b)) & 1) == 1 {
                            v_high
                        } else {
                            0.0
                        };
                        (vt - node_v(&self.solution, topo, comp.nodes[1 + b])) * g
                    })
                    .sum()
            }
            ComponentKind::Wattmeter { r_shunt } => (va - vb) / r_shunt.max(1e-4),
            ComponentKind::AcCurrent {
                amp,
                freq,
                phase_deg,
                offset,
            } => {
                offset
                    + amp
                        * (2.0 * std::f64::consts::PI * freq * self.t_sim + phase_deg.to_radians())
                            .sin()
            }
            ComponentKind::DcMotor { r_a, ke, .. } => {
                ((va - vb) - ke * self.phase2.aux_a.get(idx).copied().unwrap_or(0.0)) / r_a.max(0.1)
            }
            ComponentKind::VControlledSwitch {
                v_on,
                v_off,
                r_on,
                r_off,
            } => {
                let vc = node_v(&self.solution, topo, comp.nodes[2])
                    - node_v(&self.solution, topo, comp.nodes[3]);
                let prev = self.phase2.latch_bits.get(idx).copied().unwrap_or(0) != 0;
                let closed = if vc >= v_on {
                    true
                } else if vc <= v_off {
                    false
                } else {
                    prev
                };
                (va - vb) / if closed { r_on } else { r_off }.max(1e-6)
            }
            ComponentKind::IControlledSwitch {
                i_on,
                i_off,
                r_on,
                r_off,
            } => {
                let is = topo.branch_of_comp[idx].map_or(0.0, |b| self.solution[b]);
                let prev = self.phase2.latch_bits.get(idx).copied().unwrap_or(0) != 0;
                let closed = if is >= i_on {
                    true
                } else if is <= i_off {
                    false
                } else {
                    prev
                };
                (va - vb) / if closed { r_on } else { r_off }.max(1e-6)
            }
            ComponentKind::BridgeRectifier { is_sat, n } => {
                let vp = node_v(&self.solution, topo, comp.nodes[2]);
                let vn = node_v(&self.solution, topo, comp.nodes[3]);
                let (i_dp, _) = eval_diode_vt(va - vp, is_sat, n, f64::INFINITY, gmin, vt);
                let (i_dn, _) = eval_diode_vt(vn - va, is_sat, n, f64::INFINITY, gmin, vt);
                i_dp - i_dn
            }
            ComponentKind::Njfet { beta, vto, lambda }
            | ComponentKind::Pjfet { beta, vto, lambda } => {
                let pol = if matches!(comp.kind, ComponentKind::Njfet { .. }) {
                    1.0
                } else {
                    -1.0
                };
                let vg = node_v(&self.solution, topo, comp.nodes[1]);
                let vs = node_v(&self.solution, topo, comp.nodes[2]);
                let vds_raw = pol * (va - vs);
                let rev = vds_raw < 0.0;
                let (vgs, vds) = if rev {
                    (pol * (vg - va), -vds_raw)
                } else {
                    (pol * (vg - vs), vds_raw)
                };
                let vov = vgs - vto;
                let mag = if vov <= 0.0 {
                    0.0
                } else if vds < vov {
                    beta * (2.0 * vov * vds - vds * vds) * (1.0 + lambda * vds)
                } else {
                    beta * vov * vov * (1.0 + lambda * vds)
                };
                pol * if rev { -mag } else { mag }
            }
            ComponentKind::Scr { r_on, r_off, .. } => {
                let latched = self.phase2.latch_bits.get(idx).copied().unwrap_or(0) != 0;
                let conduct = latched && (va - vb) >= -0.05;
                (va - vb) / if conduct { r_on } else { r_off }.max(1e-6)
            }
            ComponentKind::Triac { r_on, r_off, .. } => {
                let latched = self.phase2.latch_bits.get(idx).copied().unwrap_or(0) != 0;
                (va - vb) / if latched { r_on } else { r_off }.max(1e-6)
            }
            ComponentKind::Diac { v_bo, r_on, r_off } => {
                let v = va - vb;
                let latched =
                    self.t_sim > 0.0 && self.phase2.latch_bits.get(idx).copied().unwrap_or(0) != 0;
                if v.abs() >= v_bo || latched {
                    let v_drop = if latched { 0.35 * v_bo } else { v_bo };
                    (v - v.signum() * v_drop) / r_on.max(1e-6)
                } else {
                    v / r_off.max(1.0)
                }
            }
            ComponentKind::Igbt { kp, vth, r_on } => {
                let vg = node_v(&self.solution, topo, comp.nodes[1]);
                let ve = node_v(&self.solution, topo, comp.nodes[2]);
                let vge = vg - ve;
                let vce = va - ve;
                let v_pn = 0.7;
                if vge <= vth || vce <= v_pn {
                    0.0
                } else {
                    ((vce - v_pn) / r_on.max(0.05)).min(kp * (vge - vth).powi(2))
                }
            }
            ComponentKind::VoltageReg { v_out, r_out } => {
                let vo = node_v(&self.solution, topo, comp.nodes[2]);
                let v_reg = ((va - vb) - 1.5).clamp(0.0, v_out);
                (v_reg - (vo - vb)) / r_out.max(0.05)
            }
            ComponentKind::ComparatorOc { r_pu, .. } => {
                let vo = node_v(&self.solution, topo, comp.nodes[2]);
                let s = 0.5 * (1.0 - ((va - vb) / 0.005).clamp(-20.0, 20.0).tanh());
                -vo * ((1.0 / r_pu.clamp(10.0, 50.0)) * s + gmin)
            }
            ComponentKind::InstAmp {
                gain,
                v_sat_pos,
                v_sat_neg,
                r_out,
            } => {
                let vo = node_v(&self.solution, topo, comp.nodes[2]);
                let v_mid = 0.5 * (v_sat_pos + v_sat_neg);
                let v_half = (0.5 * (v_sat_pos - v_sat_neg)).max(0.1);
                let u = (gain * (va - vb) / v_half).clamp(-20.0, 20.0);
                let v_target = v_mid + v_half * u.tanh();
                (v_target - vo) / r_out.max(1e-3)
            }
            ComponentKind::AnalogMultiplier { gain, r_out } => {
                let vo = node_v(&self.solution, topo, comp.nodes[2]);
                let v_target = gain * va * vb;
                (v_target - vo) / r_out.max(1.0)
            }
            ComponentKind::RelayDpdt {
                r_coil,
                v_pull,
                r_on,
                r_off,
            } => {
                let pull = (va - vb).abs() >= v_pull;
                let (r_nc, r_no) = if pull { (r_off, r_on) } else { (r_on, r_off) };
                let v = |p: usize| node_v(&self.solution, topo, comp.nodes[p]);
                let i_coil = (va - vb) / r_coil.max(1.0);
                let i_p1 = (v(2) - v(3)) / r_nc + (v(2) - v(4)) / r_no;
                let i_p2 = if comp.pin_count >= 8 {
                    (v(5) - v(6)) / r_nc + (v(5) - v(7)) / r_no
                } else {
                    0.0
                };
                i_coil + i_p1 + i_p2
            }
            ComponentKind::BarGraphLed { is_sat, n } | ComponentKind::RgbLed { is_sat, n } => {
                let pins = comp.active_nodes();
                let cath = pins.last().copied().unwrap_or(0);
                let vc = node_v(&self.solution, topo, cath);
                pins[..pins.len().saturating_sub(1)]
                    .iter()
                    .map(|&a| {
                        let vd = node_v(&self.solution, topo, a) - vc;
                        eval_diode_vt(vd, is_sat, n, f64::INFINITY, gmin, vt).0
                    })
                    .sum()
            }
            ComponentKind::DipSwitch4 { mask, r_on, r_off } => (0..4)
                .map(|b| {
                    let closed = ((mask >> b) & 1) == 1;
                    let vp = node_v(&self.solution, topo, comp.nodes[2 * b]);
                    let vn = node_v(&self.solution, topo, comp.nodes[2 * b + 1]);
                    (vp - vn) / if closed { r_on } else { r_off }.max(1e-6)
                })
                .sum(),
            ComponentKind::TriStateBuffer { v_high, r_out } => {
                let pins = comp.active_nodes();
                let inp = node_v(&self.solution, topo, pins[0]) >= 0.5 * v_high;
                if pins.len() == 2 || node_v(&self.solution, topo, pins[1]) >= 0.5 * v_high {
                    let out_pin = pins[pins.len() - 1];
                    let vt_out = if inp { v_high } else { 0.0 };
                    (vt_out - node_v(&self.solution, topo, out_pin)) / r_out.max(1.0)
                } else {
                    0.0
                }
            }
            ComponentKind::DigitalGateMulti {
                kind,
                v_high,
                r_out,
            } => {
                let pins = comp.active_nodes();
                let in_len = pins.len().saturating_sub(1).min(4);
                let mut inputs_v = [0.0; 4];
                for (slot, &p) in inputs_v[..in_len].iter_mut().zip(&pins[..in_len]) {
                    *slot = node_v(&self.solution, topo, p);
                }
                let vt_out = crate::digital::eval_soft_gate(kind, &inputs_v[..in_len], v_high);
                (vt_out - node_v(&self.solution, topo, pins[in_len])) / r_out.max(1.0)
            }
            ComponentKind::Vco { v_high, r_out, .. } => {
                let vt_out = if self.phase2.aux_a.get(idx).copied().unwrap_or(0.0) < 0.5 {
                    v_high
                } else {
                    0.0
                };
                (vt_out - vb) / r_out.max(1.0)
            }
            ComponentKind::SampleHold { r_out, .. } => {
                let held = self.phase2.aux_a.get(idx).copied().unwrap_or(0.0);
                (held - node_v(&self.solution, topo, comp.nodes[2])) / r_out.max(1.0)
            }
            ComponentKind::Dac4Bit { v_ref, r_out } => {
                let vref = if comp.nodes[4] != 0 {
                    node_v(&self.solution, topo, comp.nodes[4]).max(0.1)
                } else {
                    v_ref.max(0.1)
                };
                let mut code = 0u8;
                for (b, &node) in comp.nodes.iter().take(4).enumerate() {
                    if node_v(&self.solution, topo, node) >= 1.5 {
                        code |= 1 << (3 - b);
                    }
                }
                let vt_out = vref * (code as f64 / 16.0);
                (vt_out - node_v(&self.solution, topo, comp.nodes[5])) / r_out.max(1.0)
            }
            ComponentKind::SrLatch { v_high, r_out }
            | ComponentKind::JkFlipFlop { v_high, r_out }
            | ComponentKind::TFlipFlop { v_high, r_out }
            | ComponentKind::DFlipFlopAsync { v_high, r_out } => {
                let q_pin = match comp.kind {
                    ComponentKind::SrLatch { .. } => comp.nodes[2],
                    ComponentKind::DFlipFlopAsync { .. } => comp.nodes[4],
                    _ => comp.nodes[comp.pin_count.saturating_sub(2) as usize],
                };
                let q = self.phase2.latch_bits.get(idx).copied().unwrap_or(0) != 0;
                ((if q { v_high } else { 0.0 }) - node_v(&self.solution, topo, q_pin))
                    / r_out.max(1.0)
            }
            ComponentKind::Counter4BitFull { v_high, r_out }
            | ComponentKind::ShiftReg4Bit { v_high, r_out }
            | ComponentKind::HexKeypad { v_high, r_out, .. } => {
                let (pins, val) = match comp.kind {
                    ComponentKind::HexKeypad { nibble, .. } => (&comp.nodes[0..4], nibble & 0xF),
                    _ => (
                        &comp.nodes[3..7],
                        self.phase2.latch_bits.get(idx).copied().unwrap_or(0) & 0xF,
                    ),
                };
                let g = 1.0 / r_out.max(1.0);
                (0..4)
                    .map(|b| {
                        let vt_out = if ((val >> (3 - b)) & 1) == 1 {
                            v_high
                        } else {
                            0.0
                        };
                        (vt_out - node_v(&self.solution, topo, pins[b])) * g
                    })
                    .sum()
            }
            ComponentKind::Mux4To1 { v_high, r_out } => {
                let s1 = node_v(&self.solution, topo, comp.nodes[4]) >= 0.5 * v_high;
                let s0 = node_v(&self.solution, topo, comp.nodes[5]) >= 0.5 * v_high;
                let sel = (usize::from(s1) << 1) | usize::from(s0);
                let hi = node_v(&self.solution, topo, comp.nodes[sel]) >= 0.5 * v_high;
                ((if hi { v_high } else { 0.0 }) - node_v(&self.solution, topo, comp.nodes[6]))
                    / r_out.max(1.0)
            }
            ComponentKind::Demux1To4 { v_high, r_out }
            | ComponentKind::Decoder2To4 { v_high, r_out } => {
                let a = node_v(&self.solution, topo, comp.nodes[1]) >= 0.5 * v_high;
                let b = node_v(&self.solution, topo, comp.nodes[2]) >= 0.5 * v_high;
                let (sel, en) = match comp.kind {
                    ComponentKind::Demux1To4 { .. } => {
                        (((usize::from(a) << 1) | usize::from(b)), va >= 0.5 * v_high)
                    }
                    _ => (((usize::from(va >= 0.5 * v_high) << 1) | usize::from(a)), b),
                };
                let g = 1.0 / r_out.max(1.0);
                (0..4)
                    .map(|k| {
                        let vt_out = if en && k == sel { v_high } else { 0.0 };
                        (vt_out - node_v(&self.solution, topo, comp.nodes[3 + k])) * g
                    })
                    .sum()
            }
            ComponentKind::FullAdder { v_high, r_out } => {
                let s = u8::from(va >= 0.5 * v_high)
                    + u8::from(vb >= 0.5 * v_high)
                    + u8::from(node_v(&self.solution, topo, comp.nodes[2]) >= 0.5 * v_high);
                let g = 1.0 / r_out.max(1.0);
                let v_sum = if (s & 1) == 1 { v_high } else { 0.0 };
                let v_c = if s >= 2 { v_high } else { 0.0 };
                (v_sum - node_v(&self.solution, topo, comp.nodes[3])) * g
                    + (v_c - node_v(&self.solution, topo, comp.nodes[4])) * g
            }
            ComponentKind::MagComparator { v_high, r_out } => {
                let a = (u8::from(va >= 0.5 * v_high) << 1) | u8::from(vb >= 0.5 * v_high);
                let b = (u8::from(node_v(&self.solution, topo, comp.nodes[2]) >= 0.5 * v_high)
                    << 1)
                    | u8::from(node_v(&self.solution, topo, comp.nodes[3]) >= 0.5 * v_high);
                let g = 1.0 / r_out.max(1.0);
                let targets = [a > b, a == b, a < b];
                (0..3)
                    .map(|k| {
                        ((if targets[k] { v_high } else { 0.0 })
                            - node_v(&self.solution, topo, comp.nodes[4 + k]))
                            * g
                    })
                    .sum()
            }
            ComponentKind::Alu2Bit { v_high, r_out } => {
                let a = (u8::from(va >= 0.5 * v_high) << 1) | u8::from(vb >= 0.5 * v_high);
                let b = (u8::from(node_v(&self.solution, topo, comp.nodes[2]) >= 0.5 * v_high)
                    << 1)
                    | u8::from(node_v(&self.solution, topo, comp.nodes[3]) >= 0.5 * v_high);
                let op = (u8::from(node_v(&self.solution, topo, comp.nodes[4]) >= 0.5 * v_high)
                    << 1)
                    | u8::from(node_v(&self.solution, topo, comp.nodes[5]) >= 0.5 * v_high);
                let res = match op {
                    0 => (a + b) & 3,
                    1 => a.wrapping_sub(b) & 3,
                    2 => a & b,
                    _ => a ^ b,
                };
                let g = 1.0 / r_out.max(1.0);
                (0..2)
                    .map(|k| {
                        let vt = if ((res >> (1 - k)) & 1) == 1 {
                            v_high
                        } else {
                            0.0
                        };
                        (vt - node_v(&self.solution, topo, comp.nodes[6 + k])) * g
                    })
                    .sum()
            }
            ComponentKind::Adc4Bit {
                v_ref,
                v_high,
                r_out,
            } => {
                let vref = if comp.nodes[1] != 0 {
                    vb.max(0.1)
                } else {
                    v_ref.max(0.1)
                };
                let code = ((va / vref) * 16.0).floor().clamp(0.0, 15.0) as u8;
                let g = 1.0 / r_out.max(1.0);
                (0..4)
                    .map(|k| {
                        let vt_out = if ((code >> (3 - k)) & 1) == 1 {
                            v_high
                        } else {
                            0.0
                        };
                        (vt_out - node_v(&self.solution, topo, comp.nodes[2 + k])) * g
                    })
                    .sum()
            }
            _ => 0.0,
        };
        if comp.fault == FaultKind::Leaky {
            base_i + (va - vb) / 500.0
        } else {
            base_i
        }
    }

    pub fn solve_ac_sweep(
        &mut self,
        f_start: f64,
        f_stop: f64,
        points_per_decade: usize,
        ac_source_id: u32,
        out_node: u32,
    ) -> Result<Vec<AcPoint>, SimError> {
        if !f_start.is_finite()
            || !f_stop.is_finite()
            || f_start <= 0.0
            || f_stop <= f_start
            || points_per_decade == 0
            || points_per_decade > 1000
        {
            return Err(SimError::new(SimErrorCode::InvalidParameter, 0));
        }
        let decades = (f_stop / f_start).log10();
        let pts_f = decades * points_per_decade as f64;
        if !pts_f.is_finite() || pts_f > 100_000.0 {
            return Err(SimError::new(SimErrorCode::InvalidParameter, 0));
        }
        let saved_sol = self.solution.clone();
        let saved_react = self.reactive.clone();
        let saved_p2 = self.phase2.clone();
        let had_topo = self.topo.is_some();
        let dc_res = if had_topo {
            self.solve_dc()
        } else {
            self.compile_and_dc()
        };
        if let Err(e) = dc_res {
            if had_topo {
                self.solution = saved_sol;
                self.reactive = saved_react;
                self.phase2 = saved_p2;
            }
            return Err(e);
        }

        let topo = self.topo.as_ref().unwrap();
        let total_pts = (pts_f.ceil() as usize).clamp(2, 100_000);
        let mut results = Vec::with_capacity(total_pts + 1);
        let mut ac_scratch = DenseSystem::new(topo.matrix_size());
        let mut sys = ComplexSystem::new(topo.matrix_size());
        let ac_vt = self.config.vt();
        let ac_gmin = self.config.gmin;

        for k in 0..=total_pts {
            if k > 0 {
                sys.clear();
            }
            let frac = k as f64 / total_pts as f64;
            let freq = f_start * (f_stop / f_start).powf(frac);
            let omega = 2.0 * std::f64::consts::PI * freq;

            // Gmin on every node prevents isolated capacitive nodes from producing singular AC matrices at low omega.
            for idx in 0..topo.node_count {
                sys.add_a(idx, idx, crate::mna::solver::Complex64::new(ac_gmin, 0.0));
            }

            let ac_ctx = AcStampCtx {
                topo,
                x_dc: &self.solution,
                phase2: &self.phase2,
                omega,
                ac_source_id,
                gmin: ac_gmin,
                vt: ac_vt,
            };
            for (idx, comp) in self.circuit.components.iter().enumerate() {
                Self::stamp_ac_with_fault(&mut sys, comp, idx, &ac_ctx, &mut ac_scratch);
            }

            let sol = match sys.solve() {
                Ok(s) => s,
                Err(e) => {
                    if had_topo {
                        self.solution = saved_sol;
                        self.reactive = saved_react;
                        self.phase2 = saved_p2;
                    }
                    return Err(e);
                }
            };
            let v_out = topo
                .idx(out_node)
                .map_or(crate::mna::solver::Complex64::ZERO, |i| sol[i]);
            let mag = v_out.abs().max(1e-15);
            results.push(AcPoint {
                freq_hz: freq,
                mag_db: 20.0 * mag.log10(),
                phase_deg: v_out.arg_deg(),
            });
        }
        if had_topo {
            self.solution = saved_sol;
            self.reactive = saved_react;
            self.phase2 = saved_p2;
        }
        Ok(results)
    }

    fn max_source_freq(&self) -> f64 {
        let topo = self.topo.as_ref();
        self.circuit
            .components
            .iter()
            .filter_map(|c| match c.kind {
                ComponentKind::AcVoltage { freq, .. }
                | ComponentKind::AcCurrent { freq, .. }
                | ComponentKind::FunctionGen { freq, .. }
                | ComponentKind::ClockSource { freq, .. }
                | ComponentKind::WordGen { freq, .. } => Some(freq),
                ComponentKind::PulseVoltage { per, .. } if per > 0.0 => Some(1.0 / per),
                ComponentKind::Vco { f0, df_dv, .. } => {
                    let v_ctrl = topo.map_or(0.0, |t| node_v(&self.solution, t, c.nodes[0]));
                    Some((f0 + df_dv * v_ctrl).abs().max(f0))
                }
                _ => None,
            })
            .fold(0.0_f64, f64::max)
    }

    fn solve_newton_step(
        &mut self,
        dt: f64,
        is_transient: bool,
        gmin: f64,
    ) -> Result<(), SimError> {
        let topo = self
            .topo
            .as_ref()
            .ok_or_else(|| SimError::new(SimErrorCode::InvalidNetlist, 0))?;
        let n = topo.matrix_size();
        let has_nonlinear = self.circuit.components.iter().any(|c| c.is_nonlinear());
        let max_iters = if has_nonlinear { NR_MAX_ITERS } else { 1 };

        let mut x_cur = self.solution.clone();
        if x_cur.len() != n {
            x_cur.resize(n, 0.0);
        }

        let mut sys = DenseSystem::new(n);
        for iter in 0..max_iters {
            if iter > 0 {
                sys.clear();
            }
            for i in 0..topo.node_count {
                sys.add_a(i, i, gmin);
            }

            for (idx, comp) in self.circuit.components.iter().enumerate() {
                let pins = comp.active_nodes();
                let p1 = pins.get(1).copied().unwrap_or(0);
                match comp.fault {
                    FaultKind::Open => {
                        if let Some(b) = topo.branch_of_comp[idx] {
                            for off in 0..comp.branch_var_count() {
                                sys.add_a(b + off, b + off, 1.0);
                            }
                        }
                        sys.stamp_conductance(topo.idx(pins[0]), topo.idx(p1), 1e-12);
                        continue;
                    }
                    FaultKind::Short => {
                        if let Some(b) = topo.branch_of_comp[idx] {
                            if let Some(i) = topo.idx(pins[0]) {
                                sys.add_a(i, b, 1.0);
                                sys.add_a(b, i, 1.0);
                            }
                            if let Some(j) = topo.idx(p1) {
                                sys.add_a(j, b, -1.0);
                                sys.add_a(b, j, -1.0);
                            }
                            for off in 1..comp.branch_var_count() {
                                sys.add_a(b + off, b + off, 1.0);
                            }
                        } else {
                            sys.stamp_conductance(topo.idx(pins[0]), topo.idx(p1), 1000.0);
                        }
                        continue;
                    }
                    FaultKind::Leaky => {
                        sys.stamp_conductance(topo.idx(pins[0]), topo.idx(p1), 1.0 / 500.0);
                    }
                    FaultKind::None => {}
                }
                match &comp.kind {
                    ComponentKind::Resistor { r } => {
                        sys.stamp_conductance(topo.idx(pins[0]), topo.idx(pins[1]), 1.0 / *r);
                    }
                    ComponentKind::Potentiometer { r_total, wiper } => {
                        let w = wiper.clamp(0.001, 0.999);
                        let pt = topo.idx(pins[0]);
                        let pb = topo.idx(pins[1]);
                        let pw = topo.idx(pins[2]);
                        sys.stamp_conductance(pt, pw, 1.0 / (r_total * (1.0 - w)));
                        sys.stamp_conductance(pw, pb, 1.0 / (r_total * w));
                    }
                    ComponentKind::Capacitor { c, .. } => {
                        if is_transient {
                            let (geq, ieq) = self.reactive_companion(idx, *c, true, dt);
                            let pa = topo.idx(pins[0]);
                            let pb = topo.idx(pins[1]);
                            sys.stamp_conductance(pa, pb, geq);
                            sys.stamp_current(pb, pa, ieq);
                        }
                    }
                    ComponentKind::VaractorDiode { cj0, vj, m, .. } => {
                        if is_transient {
                            let va_c =
                                node_v(&x_cur, topo, pins[0]) - node_v(&x_cur, topo, pins[1]);
                            let vr = (-va_c).max(0.0);
                            let cj = *cj0 / (1.0 + vr / vj.max(0.1)).powf(*m);
                            let (geq, ieq) = self.reactive_companion(idx, cj, true, dt);
                            let pa = topo.idx(pins[0]);
                            let pb = topo.idx(pins[1]);
                            sys.stamp_conductance(pa, pb, geq);
                            sys.stamp_current(pb, pa, ieq);
                        }
                        stamp_nonlinear_vt(
                            &mut sys,
                            topo,
                            &comp.kind,
                            pins,
                            &x_cur,
                            gmin,
                            self.config.vt(),
                        );
                    }
                    ComponentKind::Inductor { l, .. } => {
                        if let Some(b) = topo.branch_of_comp[idx] {
                            let pa = topo.idx(pins[0]);
                            let pb = topo.idx(pins[1]);
                            if let Some(i) = pa {
                                sys.add_a(i, b, 1.0);
                                sys.add_a(b, i, 1.0);
                            }
                            if let Some(j) = pb {
                                sys.add_a(j, b, -1.0);
                                sys.add_a(b, j, -1.0);
                            }
                            if is_transient {
                                let (req, veq) = self.reactive_companion(idx, *l, false, dt);
                                sys.add_a(b, b, -req);
                                sys.add_b(b, -veq);
                            }
                        }
                    }
                    ComponentKind::SwitchSpst {
                        closed,
                        r_on,
                        r_off,
                    } => {
                        let r = if *closed { *r_on } else { *r_off };
                        sys.stamp_conductance(topo.idx(pins[0]), topo.idx(pins[1]), 1.0 / r);
                    }
                    ComponentKind::SwitchSpdt {
                        throw_b,
                        r_on,
                        r_off,
                    } => {
                        let r_a = if *throw_b { *r_off } else { *r_on };
                        let r_b = if *throw_b { *r_on } else { *r_off };
                        sys.stamp_conductance(topo.idx(pins[0]), topo.idx(pins[1]), 1.0 / r_a);
                        sys.stamp_conductance(topo.idx(pins[0]), topo.idx(pins[2]), 1.0 / r_b);
                    }
                    ComponentKind::Fuse { r_on, blown, .. } => {
                        let r = if *blown { 1e9 } else { *r_on };
                        sys.stamp_conductance(topo.idx(pins[0]), topo.idx(pins[1]), 1.0 / r);
                    }
                    ComponentKind::DcVoltage { .. }
                    | ComponentKind::AcVoltage { .. }
                    | ComponentKind::FunctionGen { .. } => {
                        if let Some(b) = topo.branch_of_comp[idx] {
                            let pa = topo.idx(pins[0]);
                            let pb = topo.idx(pins[1]);
                            if let Some(i) = pa {
                                sys.add_a(i, b, 1.0);
                                sys.add_a(b, i, 1.0);
                            }
                            if let Some(j) = pb {
                                sys.add_a(j, b, -1.0);
                                sys.add_a(b, j, -1.0);
                            }
                            let raw_val = if is_transient {
                                eval_source_at(&comp.kind, self.t_sim)
                            } else {
                                eval_source_at(&comp.kind, 0.0) * self.dc_source_scale
                            };
                            sys.add_b(b, raw_val);
                        }
                    }
                    ComponentKind::DcCurrent { i } => {
                        let scale = if is_transient {
                            1.0
                        } else {
                            self.dc_source_scale
                        };
                        sys.stamp_current(topo.idx(pins[0]), topo.idx(pins[1]), *i * scale);
                    }
                    ComponentKind::Vcvs { gain } => {
                        if let Some(b) = topo.branch_of_comp[idx] {
                            if let Some(i) = topo.idx(pins[0]) {
                                sys.add_a(i, b, 1.0);
                                sys.add_a(b, i, 1.0);
                            }
                            if let Some(j) = topo.idx(pins[1]) {
                                sys.add_a(j, b, -1.0);
                                sys.add_a(b, j, -1.0);
                            }
                            if let Some(cp) = topo.idx(pins[2]) {
                                sys.add_a(b, cp, -*gain);
                            }
                            if let Some(cn) = topo.idx(pins[3]) {
                                sys.add_a(b, cn, *gain);
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
                                sys.add_a(r, c, *gm);
                            }
                            if let Some(c) = cn {
                                sys.add_a(r, c, -*gm);
                            }
                        }
                        if let Some(r) = on {
                            if let Some(c) = cp {
                                sys.add_a(r, c, -*gm);
                            }
                            if let Some(c) = cn {
                                sys.add_a(r, c, *gm);
                            }
                        }
                    }
                    ComponentKind::ClockSource {
                        freq,
                        v_high,
                        r_out,
                    } => {
                        let v_target = if is_transient && *freq > 0.0 {
                            let phase = (self.t_sim * *freq).rem_euclid(1.0);
                            if phase < 0.5 {
                                *v_high
                            } else {
                                0.0
                            }
                        } else {
                            0.0
                        };
                        let g_out = 1.0 / r_out.max(1.0);
                        let po = topo.idx(pins[0]);
                        let pr = topo.idx(pins[1]);
                        sys.stamp_conductance(po, pr, g_out);
                        sys.stamp_current(pr, po, v_target * g_out);
                    }
                    ComponentKind::DFlipFlop { v_high, r_out } => {
                        let q_high = self.reactive.dff_q.get(idx).copied().unwrap_or(false);
                        let v_q = if q_high { *v_high } else { 0.0 };
                        let v_qn = if q_high { 0.0 } else { *v_high };
                        let g_out = 1.0 / r_out.max(1.0);
                        if let Some(q_idx) = topo.idx(pins[2]) {
                            sys.add_a(q_idx, q_idx, g_out);
                            sys.add_b(q_idx, v_q * g_out);
                        }
                        if let Some(qn_idx) = topo.idx(pins[3]) {
                            sys.add_a(qn_idx, qn_idx, g_out);
                            sys.add_b(qn_idx, v_qn * g_out);
                        }
                        if let Some(d_idx) = topo.idx(pins[0]) {
                            sys.add_a(d_idx, d_idx, 1e-7);
                        }
                        if let Some(clk_idx) = topo.idx(pins[1]) {
                            sys.add_a(clk_idx, clk_idx, 1e-7);
                        }
                    }
                    ComponentKind::LogicProbe { r_in } => {
                        if let Some(p) = topo.idx(pins[0]) {
                            sys.add_a(p, p, 1.0 / r_in.max(1.0));
                        }
                    }
                    ComponentKind::Cccs { gain } => {
                        if let Some(b) = topo.branch_of_comp[idx] {
                            if let Some(sp) = topo.idx(pins[2]) {
                                sys.add_a(sp, b, 1.0);
                                sys.add_a(b, sp, 1.0);
                            }
                            if let Some(sn) = topo.idx(pins[3]) {
                                sys.add_a(sn, b, -1.0);
                                sys.add_a(b, sn, -1.0);
                            }
                            sys.add_a(b, b, -1e-9);
                            if let Some(op) = topo.idx(pins[0]) {
                                sys.add_a(op, b, *gain);
                            }
                            if let Some(on) = topo.idx(pins[1]) {
                                sys.add_a(on, b, -*gain);
                            }
                        }
                    }
                    ComponentKind::Ccvs { rm } => {
                        if let Some(b) = topo.branch_of_comp[idx] {
                            let bs = b + 1;
                            if let Some(i) = topo.idx(pins[0]) {
                                sys.add_a(i, b, 1.0);
                                sys.add_a(b, i, 1.0);
                            }
                            if let Some(j) = topo.idx(pins[1]) {
                                sys.add_a(j, b, -1.0);
                                sys.add_a(b, j, -1.0);
                            }
                            if let Some(sp) = topo.idx(pins[2]) {
                                sys.add_a(sp, bs, 1.0);
                                sys.add_a(bs, sp, 1.0);
                            }
                            if let Some(sn) = topo.idx(pins[3]) {
                                sys.add_a(sn, bs, -1.0);
                                sys.add_a(bs, sn, -1.0);
                            }
                            sys.add_a(b, bs, -*rm);
                        }
                    }
                    ComponentKind::Transformer { ratio } => {
                        if let Some(b) = topo.branch_of_comp[idx] {
                            if let Some(pp) = topo.idx(pins[0]) {
                                sys.add_a(pp, b, -*ratio);
                                sys.add_a(b, pp, -*ratio);
                            }
                            if let Some(pn) = topo.idx(pins[1]) {
                                sys.add_a(pn, b, *ratio);
                                sys.add_a(b, pn, *ratio);
                            }
                            if let Some(sp) = topo.idx(pins[2]) {
                                sys.add_a(sp, b, 1.0);
                                sys.add_a(b, sp, 1.0);
                            }
                            if let Some(sn) = topo.idx(pins[3]) {
                                sys.add_a(sn, b, -1.0);
                                sys.add_a(b, sn, -1.0);
                            }
                            sys.add_a(b, b, -1e-6);
                        }
                    }
                    ComponentKind::Timer555 { v_cc, r_out } => {
                        let out_high = self
                            .reactive
                            .timer_out_high
                            .get(idx)
                            .copied()
                            .unwrap_or(true);
                        if let Some(t) = topo.idx(pins[0]) {
                            sys.add_a(t, t, 1e-7);
                        }
                        if let Some(th) = topo.idx(pins[1]) {
                            sys.add_a(th, th, 1e-7);
                        }
                        if let Some(d) = topo.idx(pins[2]) {
                            sys.add_a(d, d, if out_high { 1e-7 } else { 0.1 });
                        }
                        if let Some(o) = topo.idx(pins[3]) {
                            let g_out = 1.0 / r_out.max(1.0);
                            let v_target = if out_high { *v_cc } else { 0.0 };
                            sys.add_a(o, o, g_out);
                            sys.add_b(o, v_target * g_out);
                        }
                    }
                    ComponentKind::SevenSeg { r_in } => {
                        let g_in = 1.0 / r_in.max(1e3);
                        for &pin in pins {
                            if let Some(p) = topo.idx(pin) {
                                sys.add_a(p, p, g_in);
                            }
                        }
                    }
                    ComponentKind::WordGen {
                        freq,
                        pattern,
                        v_high,
                        r_out,
                    } => {
                        let step_idx = if is_transient && *freq > 0.0 {
                            ((self.t_sim * *freq).floor() as usize) & 0xF
                        } else {
                            0
                        };
                        let nib = ((*pattern >> (step_idx * 4)) & 0xF) as u8;
                        let g_out = 1.0 / r_out.max(1.0);
                        for (k, &pin) in pins.iter().take(4).enumerate() {
                            let v_target = if ((nib >> (3 - k)) & 1) == 1 {
                                *v_high
                            } else {
                                0.0
                            };
                            if let Some(p) = topo.idx(pin) {
                                sys.add_a(p, p, g_out);
                                sys.add_b(p, v_target * g_out);
                            }
                        }
                    }
                    ComponentKind::SchmittTrigger {
                        v_hyst,
                        v_high,
                        r_out,
                    } => {
                        let v_diff = node_v(&x_cur, topo, pins[0]) - node_v(&x_cur, topo, pins[1]);
                        let latched = self
                            .reactive
                            .timer_out_high
                            .get(idx)
                            .copied()
                            .unwrap_or(false);
                        let out_high = if v_diff >= *v_hyst {
                            true
                        } else if v_diff <= -*v_hyst {
                            false
                        } else {
                            latched
                        };
                        if let Some(ip) = topo.idx(pins[0]) {
                            sys.add_a(ip, ip, 1e-7);
                        }
                        if let Some(inn) = topo.idx(pins[1]) {
                            sys.add_a(inn, inn, 1e-7);
                        }
                        if let Some(o) = topo.idx(pins[2]) {
                            let g_out = 1.0 / r_out.max(1.0);
                            let v_target = if out_high { *v_high } else { 0.0 };
                            sys.add_a(o, o, g_out);
                            sys.add_b(o, v_target * g_out);
                        }
                    }
                    ComponentKind::Counter4Bit { v_high, r_out } => {
                        if let Some(clk) = topo.idx(pins[0]) {
                            sys.add_a(clk, clk, 1e-7);
                        }
                        let val = self.reactive.counter_val.get(idx).copied().unwrap_or(0);
                        let g_out = 1.0 / r_out.max(1.0);
                        for b in 0..3 {
                            let v_target = if ((val >> (2 - b)) & 1) == 1 {
                                *v_high
                            } else {
                                0.0
                            };
                            if let Some(p) = topo.idx(pins[1 + b]) {
                                sys.add_a(p, p, g_out);
                                sys.add_b(p, v_target * g_out);
                            }
                        }
                    }
                    _ => {
                        if !stamp_phase2_component(
                            &mut sys,
                            topo,
                            comp,
                            idx,
                            topo.branch_of_comp[idx],
                            &x_cur,
                            &self.phase2,
                            self.t_sim,
                            dt,
                            is_transient,
                            gmin,
                            self.config.vt(),
                        ) {
                            stamp_nonlinear_vt(
                                &mut sys,
                                topo,
                                &comp.kind,
                                pins,
                                &x_cur,
                                gmin,
                                self.config.vt(),
                            );
                        }
                    }
                }
            }

            let mut x_next = sys.solve()?;
            if !has_nonlinear {
                self.solution = x_next;
                return Ok(());
            }

            let vt = self.config.vt();
            let can_write =
                |pin: u32| -> Option<usize> { topo.idx(pin).filter(|&idx| !topo.vsrc_nodes[idx]) };
            let mut any_clamped = false;
            let clamp_diode_pair =
                |x_next: &mut Vec<f64>, a_pin: u32, c_pin: u32, n_vt: f64, is_sat: f64| -> bool {
                    let va_old = node_v(&x_cur, topo, a_pin);
                    let vc_old = node_v(&x_cur, topo, c_pin);
                    let va_new = node_v(x_next, topo, a_pin);
                    let vc_new = node_v(x_next, topo, c_pin);
                    let vd_old = va_old - vc_old;
                    let vd_new = va_new - vc_new;
                    let vd_lim = limit_junction_voltage(vd_new, vd_old, n_vt, is_sat);
                    if (vd_lim - vd_new).abs() > 1e-12 {
                        if let Some(ia) = can_write(a_pin) {
                            x_next[ia] = vc_new + vd_lim;
                            return true;
                        } else if let Some(ic) = can_write(c_pin) {
                            x_next[ic] = va_new - vd_lim;
                            return true;
                        }
                    }
                    false
                };
            let clamp_vce_collapse = |x_next: &mut Vec<f64>, c_pin: u32, e_pin: u32| -> bool {
                let vc_old = node_v(&x_cur, topo, c_pin);
                let ve_old = node_v(&x_cur, topo, e_pin);
                let vc_new = node_v(x_next, topo, c_pin);
                let ve_new = node_v(x_next, topo, e_pin);
                let vce_old = vc_old - ve_old;
                let vce_new = vc_new - ve_new;
                if vce_old > 1e-4 && vce_new <= 1e-4 {
                    let target_vce = (0.2 * vce_old).max(1e-3);
                    if let Some(ic) = can_write(c_pin) {
                        x_next[ic] = ve_new + target_vce;
                        return true;
                    } else if let Some(ie) = can_write(e_pin) {
                        x_next[ie] = vc_new - target_vce;
                        return true;
                    }
                }
                false
            };
            // Apply SPICE-style pnjlim damping on diode/LED/BJT junctions to keep Newton-Raphson bounded.
            for comp in &self.circuit.components {
                match comp.kind {
                    ComponentKind::VaractorDiode { is_sat, .. } => {
                        any_clamped |= clamp_diode_pair(
                            &mut x_next,
                            comp.nodes[0],
                            comp.nodes[1],
                            1.2 * vt,
                            is_sat,
                        );
                    }
                    ComponentKind::Diode {
                        is_sat,
                        n: n_ideality,
                        ..
                    }
                    | ComponentKind::Led {
                        is_sat,
                        n: n_ideality,
                        ..
                    }
                    | ComponentKind::Optocoupler {
                        is_sat,
                        n: n_ideality,
                        ..
                    } => {
                        any_clamped |= clamp_diode_pair(
                            &mut x_next,
                            comp.nodes[0],
                            comp.nodes[1],
                            n_ideality * vt,
                            is_sat,
                        );
                        if matches!(comp.kind, ComponentKind::Optocoupler { .. }) {
                            any_clamped |=
                                clamp_vce_collapse(&mut x_next, comp.nodes[2], comp.nodes[3]);
                        }
                    }
                    ComponentKind::Igbt { .. } => {
                        any_clamped |=
                            clamp_vce_collapse(&mut x_next, comp.nodes[0], comp.nodes[2]);
                    }
                    ComponentKind::BridgeRectifier {
                        is_sat,
                        n: n_ideality,
                    } => {
                        let pins = comp.active_nodes();
                        let n_vt = n_ideality * vt;
                        for &(pa, pc) in &[
                            (pins[0], pins[2]),
                            (pins[1], pins[2]),
                            (pins[3], pins[0]),
                            (pins[3], pins[1]),
                        ] {
                            any_clamped |= clamp_diode_pair(&mut x_next, pa, pc, n_vt, is_sat);
                        }
                    }
                    ComponentKind::BarGraphLed {
                        is_sat,
                        n: n_ideality,
                    }
                    | ComponentKind::RgbLed {
                        is_sat,
                        n: n_ideality,
                    } => {
                        let pins = comp.active_nodes();
                        let cath = pins.last().copied().unwrap_or(0);
                        let n_vt = n_ideality * vt;
                        for &pa in &pins[..pins.len().saturating_sub(1)] {
                            any_clamped |= clamp_diode_pair(&mut x_next, pa, cath, n_vt, is_sat);
                        }
                    }
                    ComponentKind::NpnBjt { is_sat, .. } | ComponentKind::PnpBjt { is_sat, .. } => {
                        let pol = if matches!(comp.kind, ComponentKind::NpnBjt { .. }) {
                            1.0
                        } else {
                            -1.0
                        };
                        let vc_old = node_v(&x_cur, topo, comp.nodes[0]);
                        let vb_old = node_v(&x_cur, topo, comp.nodes[1]);
                        let ve_old = node_v(&x_cur, topo, comp.nodes[2]);
                        let vc_new = node_v(&x_next, topo, comp.nodes[0]);
                        let mut vb_new = node_v(&x_next, topo, comp.nodes[1]);
                        let ve_new = node_v(&x_next, topo, comp.nodes[2]);

                        let vbe_old = pol * (vb_old - ve_old);
                        let vbe_new = pol * (vb_new - ve_new);
                        let vbe_lim = limit_junction_voltage(vbe_new, vbe_old, vt, is_sat);
                        if (vbe_lim - vbe_new).abs() > 1e-12 {
                            if let Some(ib) = can_write(comp.nodes[1]) {
                                vb_new = ve_new + pol * vbe_lim;
                                x_next[ib] = vb_new;
                                any_clamped = true;
                            } else if let Some(ie) = can_write(comp.nodes[2]) {
                                x_next[ie] = vb_new - pol * vbe_lim;
                                any_clamped = true;
                            }
                        }

                        let vbc_old = pol * (vb_old - vc_old);
                        let vbc_new = pol * (vb_new - vc_new);
                        let vbc_lim = limit_junction_voltage(vbc_new, vbc_old, vt, is_sat);
                        if (vbc_lim - vbc_new).abs() > 1e-12 {
                            if let Some(ic) = can_write(comp.nodes[0]) {
                                x_next[ic] = vb_new - pol * vbc_lim;
                                any_clamped = true;
                            }
                        }
                    }
                    _ => {}
                }
            }

            let mut converged = true;
            for i in 0..n {
                if !x_next[i].is_finite() {
                    return Err(SimError::new(SimErrorCode::ConvergenceFailed, 0));
                }
                let diff = (x_next[i] - x_cur[i]).abs();
                let tol =
                    self.config.abstol + self.config.reltol * x_next[i].abs().max(x_cur[i].abs());
                if !diff.is_finite() || diff > tol {
                    converged = false;
                    break;
                }
            }
            x_cur = x_next;
            if converged && !any_clamped && iter > 0 {
                self.solution = x_cur;
                return Ok(());
            }
        }

        Err(SimError::new(SimErrorCode::ConvergenceFailed, 0))
    }

    /// Instantaneous power dissipation (Watts; positive = absorbed, negative = delivered).
    pub fn component_power(&self, comp_id: u32) -> f64 {
        let Some(topo) = &self.topo else {
            return 0.0;
        };
        let Some(comp) = self.circuit.components.iter().find(|c| c.id == comp_id) else {
            return 0.0;
        };
        let va = node_v(&self.solution, topo, comp.nodes[0]);
        let vb = node_v(&self.solution, topo, comp.nodes[1]);
        if matches!(comp.fault, FaultKind::Open | FaultKind::Short) {
            return 0.0;
        }
        match comp.kind {
            ComponentKind::Potentiometer { r_total, wiper } => {
                let w = wiper.clamp(0.001, 0.999);
                let vw = node_v(&self.solution, topo, comp.nodes[2]);
                (va - vw).powi(2) / (r_total * (1.0 - w)) + (vw - vb).powi(2) / (r_total * w)
            }
            ComponentKind::NpnBjt { .. } | ComponentKind::PnpBjt { .. } => {
                let vc = va;
                let ve = node_v(&self.solution, topo, comp.nodes[2]);
                (vc - ve) * self.component_current(comp_id)
            }
            ComponentKind::Nmos { .. }
            | ComponentKind::Pmos { .. }
            | ComponentKind::Njfet { .. }
            | ComponentKind::Pjfet { .. }
            | ComponentKind::Igbt { .. } => {
                let vd = va;
                let vs = node_v(&self.solution, topo, comp.nodes[2]);
                (vd - vs) * self.component_current(comp_id)
            }
            ComponentKind::VoltageReg { .. } => {
                let vo = node_v(&self.solution, topo, comp.nodes[2]);
                (va - vo) * self.component_current(comp_id)
            }
            ComponentKind::OpAmp { r_out, .. }
            | ComponentKind::InstAmp { r_out, .. }
            | ComponentKind::AnalogMultiplier { r_out, .. } => {
                let i = self.component_current(comp_id);
                i * i * r_out.max(1e-3)
            }
            ComponentKind::Wattmeter { .. } => {
                let vp = node_v(&self.solution, topo, comp.nodes[2]);
                let vn = node_v(&self.solution, topo, comp.nodes[3]);
                (vp - vn) * self.component_current(comp_id)
            }
            ComponentKind::DipSwitch4 { mask, r_on, r_off } => (0..4)
                .map(|b| {
                    let closed = ((mask >> b) & 1) == 1;
                    let r = if closed { r_on } else { r_off }.max(1e-6);
                    let dv = node_v(&self.solution, topo, comp.nodes[2 * b])
                        - node_v(&self.solution, topo, comp.nodes[2 * b + 1]);
                    dv * dv / r
                })
                .sum(),
            ComponentKind::RelayDpdt {
                r_coil,
                v_pull,
                r_on,
                r_off,
            } => {
                let pull = (va - vb).abs() >= v_pull;
                let (r_nc, r_no) = if pull { (r_off, r_on) } else { (r_on, r_off) };
                let r_nc = r_nc.max(1e-6);
                let r_no = r_no.max(1e-6);
                let v = |p: usize| node_v(&self.solution, topo, comp.nodes[p]);
                let p_coil = (va - vb).powi(2) / r_coil.max(1.0);
                let p_p1 = (v(2) - v(3)).powi(2) / r_nc + (v(2) - v(4)).powi(2) / r_no;
                let p_p2 = if comp.pin_count >= 8 {
                    (v(5) - v(6)).powi(2) / r_nc + (v(5) - v(7)).powi(2) / r_no
                } else {
                    0.0
                };
                p_coil + p_p1 + p_p2
            }
            ComponentKind::BridgeRectifier { is_sat, n } => {
                let pairs = [
                    (comp.nodes[0], comp.nodes[2]),
                    (comp.nodes[1], comp.nodes[2]),
                    (comp.nodes[3], comp.nodes[0]),
                    (comp.nodes[3], comp.nodes[1]),
                ];
                let vt = self.config.vt();
                let gmin = self.config.gmin;
                pairs
                    .into_iter()
                    .map(|(a, c)| {
                        let vd = node_v(&self.solution, topo, a) - node_v(&self.solution, topo, c);
                        let id = eval_diode_vt(vd, is_sat, n, f64::INFINITY, gmin, vt).0;
                        vd * id
                    })
                    .sum()
            }
            ComponentKind::BarGraphLed { is_sat, n } | ComponentKind::RgbLed { is_sat, n } => {
                let pins = comp.active_nodes();
                let cath = pins.last().copied().unwrap_or(0);
                let vc = node_v(&self.solution, topo, cath);
                let vt = self.config.vt();
                let gmin = self.config.gmin;
                pins[..pins.len().saturating_sub(1)]
                    .iter()
                    .map(|&a| {
                        let vd = node_v(&self.solution, topo, a) - vc;
                        let id = eval_diode_vt(vd, is_sat, n, f64::INFINITY, gmin, vt).0;
                        vd * id
                    })
                    .sum()
            }
            ComponentKind::Optocoupler { ctr, is_sat, n } => {
                let vt = self.config.vt();
                let gmin = self.config.gmin;
                let vc = node_v(&self.solution, topo, comp.nodes[2]);
                let ve = node_v(&self.solution, topo, comp.nodes[3]);
                let vd_led = va - vb;
                let i_led = eval_diode_vt(vd_led, is_sat, n, f64::INFINITY, gmin, vt).0;
                let vce = vc - ve;
                let sat = if vce > 0.0 {
                    (vce / 0.1).clamp(-20.0, 20.0).tanh()
                } else {
                    0.0
                };
                let ic = ctr * i_led.max(0.0) * sat + gmin * vce;
                vd_led * i_led + vce * ic
            }
            ComponentKind::SwitchSpdt {
                throw_b,
                r_on,
                r_off,
            } => {
                let vc = node_v(&self.solution, topo, comp.nodes[2]);
                let (ra, rb) = if throw_b {
                    (r_off, r_on)
                } else {
                    (r_on, r_off)
                };
                (va - vb).powi(2) / ra + (va - vc).powi(2) / rb
            }
            ComponentKind::CoupledInductor { .. } | ComponentKind::CenterTapTransformer { .. } => {
                let idx_c = self.circuit.components.iter().position(|c| c.id == comp_id);
                if let Some(b1) = idx_c.and_then(|i| topo.branch_of_comp[i]) {
                    let b2 = b1 + 1;
                    let (v1, v2) = match comp.kind {
                        ComponentKind::CoupledInductor { .. } => (
                            va - vb,
                            node_v(&self.solution, topo, comp.nodes[2])
                                - node_v(&self.solution, topo, comp.nodes[3]),
                        ),
                        _ => {
                            let sp = node_v(&self.solution, topo, comp.nodes[2]);
                            let ct = node_v(&self.solution, topo, comp.nodes[3]);
                            let sn = node_v(&self.solution, topo, comp.nodes[4]);
                            (sp - ct, ct - sn)
                        }
                    };
                    v1 * self.solution[b1] + v2 * self.solution[b2]
                } else {
                    0.0
                }
            }
            ComponentKind::WordGen {
                freq,
                pattern,
                v_high,
                r_out,
            } => {
                let step_idx = if self.t_sim > 0.0 && freq > 0.0 {
                    ((self.t_sim * freq).floor() as usize) & 0xF
                } else {
                    0
                };
                let nib = ((pattern >> (step_idx * 4)) & 0xF) as u8;
                let g_out = 1.0 / r_out.max(1.0);
                (0..4)
                    .map(|k| {
                        let vt_out = if ((nib >> (3 - k)) & 1) == 1 {
                            v_high
                        } else {
                            0.0
                        };
                        let vp = node_v(&self.solution, topo, comp.nodes[k]);
                        (vt_out - vp) * (vt_out - vp) * g_out
                    })
                    .sum()
            }
            ComponentKind::Transformer { .. } => {
                let idx_c = self.circuit.components.iter().position(|c| c.id == comp_id);
                if let Some(b) = idx_c.and_then(|i| topo.branch_of_comp[i]) {
                    let vs = node_v(&self.solution, topo, comp.nodes[2])
                        - node_v(&self.solution, topo, comp.nodes[3]);
                    vs * self.solution[b]
                } else {
                    0.0
                }
            }
            _ => (va - vb) * self.component_current(comp_id),
        }
    }

    /// True if fuse blown or passive/semiconductor power exceeds conservative 0.5 W dissipation limit.
    pub fn component_overloaded(&self, comp_id: u32) -> bool {
        let Some(comp) = self.circuit.components.iter().find(|c| c.id == comp_id) else {
            return false;
        };
        match comp.kind {
            ComponentKind::Fuse { blown, .. } => blown,
            ComponentKind::Resistor { .. }
            | ComponentKind::Potentiometer { .. }
            | ComponentKind::Diode { .. }
            | ComponentKind::VaractorDiode { .. }
            | ComponentKind::Led { .. }
            | ComponentKind::NpnBjt { .. }
            | ComponentKind::PnpBjt { .. }
            | ComponentKind::Nmos { .. }
            | ComponentKind::Pmos { .. }
            | ComponentKind::BridgeRectifier { .. }
            | ComponentKind::Njfet { .. }
            | ComponentKind::Pjfet { .. }
            | ComponentKind::Scr { .. }
            | ComponentKind::Triac { .. }
            | ComponentKind::Diac { .. }
            | ComponentKind::Igbt { .. }
            | ComponentKind::VoltageReg { .. }
            | ComponentKind::Optocoupler { .. }
            | ComponentKind::BarGraphLed { .. }
            | ComponentKind::RgbLed { .. } => self.component_power(comp_id).abs() > 0.5,
            _ => false,
        }
    }

    /// Runs `runs` Monte Carlo DC trials with ±`tol` uniform passive component spread.
    pub fn monte_carlo_dc(
        &self,
        tol: f64,
        runs: usize,
        out_node: u32,
    ) -> Result<(f64, f64, f64, f64), SimError> {
        if !tol.is_finite() || tol < 0.0 || runs == 0 || runs > 10_000 {
            return Err(SimError::new(SimErrorCode::InvalidParameter, 0));
        }
        let mut min_v = f64::INFINITY;
        let mut max_v = f64::NEG_INFINITY;
        let mut vals = Vec::with_capacity(runs);
        let mut rng: u64 = 0x9E37_79B9_7F4A_7C15;

        for _ in 0..runs {
            let mut trial = SimEngine::new();
            trial.config = self.config;
            trial.circuit = self.circuit.clone();
            for c in &mut trial.circuit.components {
                rng ^= rng << 13;
                rng ^= rng >> 7;
                rng ^= rng << 17;
                let u = ((rng >> 11) as f64) / ((1u64 << 53) as f64) * 2.0 - 1.0;
                let scale = (1.0 + tol * u).max(1e-3);
                match &mut c.kind {
                    ComponentKind::Resistor { r } => *r *= scale,
                    ComponentKind::Potentiometer { r_total, .. } => *r_total *= scale,
                    ComponentKind::Capacitor { c: cap, .. } => *cap *= scale,
                    ComponentKind::Inductor { l, .. } => *l *= scale,
                    _ => {}
                }
            }
            trial.compile_and_dc()?;
            let v = trial.node_voltage(out_node);
            min_v = min_v.min(v);
            max_v = max_v.max(v);
            vals.push(v);
        }
        let mean = vals.iter().sum::<f64>() / vals.len() as f64;
        let var = vals.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / vals.len() as f64;
        Ok((min_v, max_v, mean, var.sqrt()))
    }

    fn stamp_ac_with_fault(
        sys: &mut ComplexSystem,
        comp: &crate::netlist::Component,
        idx: usize,
        ac_ctx: &AcStampCtx<'_>,
        scratch: &mut DenseSystem,
    ) {
        let topo = ac_ctx.topo;
        let pins = comp.active_nodes();
        let p1 = pins.get(1).copied().unwrap_or(0);
        match comp.fault {
            FaultKind::Open => {
                if let Some(b) = topo.branch_of_comp[idx] {
                    for off in 0..comp.branch_var_count() {
                        sys.add_a(b + off, b + off, Complex64::new(1.0, 0.0));
                    }
                }
                return;
            }
            FaultKind::Short => {
                if let Some(b) = topo.branch_of_comp[idx] {
                    if let Some(i) = topo.idx(pins[0]) {
                        sys.add_a(i, b, Complex64::new(1.0, 0.0));
                        sys.add_a(b, i, Complex64::new(1.0, 0.0));
                    }
                    if let Some(j) = topo.idx(p1) {
                        sys.add_a(j, b, Complex64::new(-1.0, 0.0));
                        sys.add_a(b, j, Complex64::new(-1.0, 0.0));
                    }
                    for off in 1..comp.branch_var_count() {
                        sys.add_a(b + off, b + off, Complex64::new(1.0, 0.0));
                    }
                } else {
                    sys.stamp_admittance(
                        topo.idx(pins[0]),
                        topo.idx(p1),
                        Complex64::new(1000.0, 0.0),
                    );
                }
                return;
            }
            FaultKind::Leaky => {
                sys.stamp_admittance(
                    topo.idx(pins[0]),
                    topo.idx(p1),
                    Complex64::new(1.0 / 500.0, 0.0),
                );
            }
            FaultKind::None => {}
        }
        stamp_ac_component(sys, comp, idx, topo.branch_of_comp[idx], ac_ctx, scratch);
    }

    /// Computes small-signal `(gain_vv, z_in, z_out)` around the DC OP at low frequency.
    pub fn small_signal_tf(
        &mut self,
        src_id: u32,
        out_node: u32,
    ) -> Result<(f64, f64, f64), SimError> {
        self.solve_dc_op()?;
        let topo = self.topo.as_ref().unwrap();
        let n = topo.matrix_size();
        let mut ac_scratch = DenseSystem::new(n);
        let ac_ctx = AcStampCtx {
            topo,
            x_dc: &self.solution,
            phase2: &self.phase2,
            omega: 1e-6,
            ac_source_id: src_id,
            gmin: self.config.gmin,
            vt: self.config.vt(),
        };
        let mut sys = ComplexSystem::new(n);
        for idx in 0..topo.node_count {
            sys.add_a(idx, idx, Complex64::new(self.config.gmin, 0.0));
        }
        let mut src_branch = None;
        let mut src_pins = (0u32, 0u32);
        let mut is_current_src = false;
        for (idx, comp) in self.circuit.components.iter().enumerate() {
            if comp.id == src_id {
                src_branch = topo.branch_of_comp[idx];
                src_pins = (comp.nodes[0], comp.nodes[1]);
                is_current_src = matches!(
                    comp.kind,
                    ComponentKind::DcCurrent { .. } | ComponentKind::AcCurrent { .. }
                );
            }
            Self::stamp_ac_with_fault(&mut sys, comp, idx, &ac_ctx, &mut ac_scratch);
        }
        let sol = sys.solve()?;
        let v_out_c = topo.idx(out_node).map_or(Complex64::ZERO, |i| sol[i]);
        let v_out = if v_out_c.re.abs() >= v_out_c.im.abs() {
            v_out_c.re
        } else {
            v_out_c.abs()
        };
        let z_in = if is_current_src {
            let vp = topo.idx(src_pins.0).map_or(Complex64::ZERO, |i| sol[i]);
            let vn = topo.idx(src_pins.1).map_or(Complex64::ZERO, |i| sol[i]);
            (vp - vn).abs()
        } else {
            src_branch
                .map(|b| 1.0 / sol[b].abs().max(1e-15))
                .unwrap_or(1e12)
        };

        // Compute small-signal output impedance by killing all sources and injecting 1A into out_node.
        let mut sys_out = ComplexSystem::new(n);
        for idx in 0..topo.node_count {
            sys_out.add_a(idx, idx, Complex64::new(self.config.gmin, 0.0));
        }
        let ac_zero = AcStampCtx {
            ac_source_id: u32::MAX,
            ..ac_ctx
        };
        for (idx, comp) in self.circuit.components.iter().enumerate() {
            Self::stamp_ac_with_fault(&mut sys_out, comp, idx, &ac_zero, &mut ac_scratch);
        }
        if let Some(o) = topo.idx(out_node) {
            sys_out.add_b(o, Complex64::new(1.0, 0.0));
        }
        let sol_out = sys_out.solve()?;
        let z_out = topo.idx(out_node).map_or(0.0, |i| sol_out[i].abs());
        Ok((v_out, z_in, z_out))
    }

    /// Probes two-terminal resistance (ohms) or diode forward drop (volts) on a non-destructive clone
    /// with independent sources zeroed and a 1 mA DC test current injected between `node_a` and `node_b`.
    pub fn measure_two_terminal(
        &self,
        node_a: u32,
        node_b: u32,
        diode_mode: bool,
    ) -> Result<f64, SimError> {
        if node_a == node_b {
            return Ok(0.0);
        }
        let mut probe = SimEngine::new();
        probe.config = self.config;
        probe.circuit = self.circuit.clone();
        for c in &mut probe.circuit.components {
            match &mut c.kind {
                ComponentKind::DcVoltage { v } => *v = 0.0,
                ComponentKind::AcVoltage { amp, offset, .. }
                | ComponentKind::FunctionGen { amp, offset, .. } => {
                    *amp = 0.0;
                    *offset = 0.0;
                }
                ComponentKind::PulseVoltage { v1, v2, .. } => {
                    *v1 = 0.0;
                    *v2 = 0.0;
                }
                ComponentKind::PwlSource { pts, .. } => {
                    for p in pts.iter_mut() {
                        p[1] = 0.0;
                    }
                }
                ComponentKind::DcCurrent { i } => *i = 0.0,
                ComponentKind::AcCurrent { amp, offset, .. } => {
                    *amp = 0.0;
                    *offset = 0.0;
                }
                ComponentKind::ClockSource { v_high, .. } => *v_high = 0.1,
                _ => {}
            }
        }
        // Temporarily reference node_b to GND via 1e12 ohm + test current so isolated parts compile cleanly.
        let base_id = probe
            .circuit
            .components
            .iter()
            .map(|c| c.id)
            .max()
            .unwrap_or(0)
            + 1;
        let i_test = if diode_mode { 1e-3 } else { 1e-4 };
        if node_b != 0 {
            probe.circuit.add(crate::netlist::Component {
                id: base_id,
                name: "M_REF".into(),
                kind: ComponentKind::Resistor { r: 1e12 },
                nodes: [node_b, 0, 0, 0, 0, 0, 0, 0],
                pin_count: 2,
                fault: FaultKind::None,
            })?;
        }
        probe.circuit.add(crate::netlist::Component {
            id: base_id + 1,
            name: "M_TEST".into(),
            kind: ComponentKind::DcCurrent { i: -i_test },
            nodes: [node_a, node_b, 0, 0, 0, 0, 0, 0],
            pin_count: 2,
            fault: FaultKind::None,
        })?;
        probe.compile_and_dc()?;
        let dv = probe.node_voltage(node_a) - probe.node_voltage(node_b);
        if diode_mode {
            Ok(dv)
        } else {
            let r = (dv / i_test).abs();
            Ok(if r > 5e8 { f64::INFINITY } else { r })
        }
    }
}
