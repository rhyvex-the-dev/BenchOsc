use crate::error::{SimError, SimErrorCode};
use crate::instruments::ScopeBuffer;
use crate::mna::devices::{
    eval_source_at, limit_junction_voltage, node_v, stamp_nonlinear_vt, thermal_voltage,
};
use crate::mna::phase2::{
    init_phase2_after_dc, stamp_phase2_component, update_phase2_events, update_phase2_reactive,
    Phase2State,
};
use crate::mna::solver::DenseSystem;
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
pub(super) struct ReactiveState {
    pub(super) cap_v_prev: Vec<f64>,
    pub(super) cap_v_prev2: Vec<f64>,
    pub(super) cap_i_prev: Vec<f64>,
    pub(super) ind_i_prev: Vec<f64>,
    pub(super) ind_i_prev2: Vec<f64>,
    pub(super) ind_v_prev: Vec<f64>,
    pub(super) prev_dt: f64,
    pub(super) have_prev2: bool,
    pub(super) discontinuity: bool,
    pub(super) dff_q: Vec<bool>,
    pub(super) dff_clk_prev: Vec<bool>,
    pub(super) timer_out_high: Vec<bool>,
    pub(super) counter_val: Vec<u8>,
}

impl ReactiveState {
    pub(super) fn copy_from(&mut self, other: &Self) {
        self.cap_v_prev.clone_from(&other.cap_v_prev);
        self.cap_v_prev2.clone_from(&other.cap_v_prev2);
        self.cap_i_prev.clone_from(&other.cap_i_prev);
        self.ind_i_prev.clone_from(&other.ind_i_prev);
        self.ind_i_prev2.clone_from(&other.ind_i_prev2);
        self.ind_v_prev.clone_from(&other.ind_v_prev);
        self.prev_dt = other.prev_dt;
        self.have_prev2 = other.have_prev2;
        self.discontinuity = other.discontinuity;
        self.dff_q.clone_from(&other.dff_q);
        self.dff_clk_prev.clone_from(&other.dff_clk_prev);
        self.timer_out_high.clone_from(&other.timer_out_high);
        self.counter_val.clone_from(&other.counter_val);
    }
}

/// Uses `cores - 2` worker threads when the host has > 4 logical cores, else 1.
pub(crate) fn sim_worker_count(work_items: usize) -> usize {
    if work_items < 2 {
        return 1;
    }
    let cores = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1);
    let budget = if cores > 4 { cores - 2 } else { 1 };
    budget.min(work_items)
}

#[inline]
pub(super) fn splitmix64(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = *state;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

pub(super) fn run_parallel_chunks<T: Send>(
    total: usize,
    workers: usize,
    run_range: &(impl Fn(usize, usize) -> Result<Vec<T>, SimError> + Sync),
) -> Result<Vec<T>, SimError> {
    if workers <= 1 {
        return run_range(0, total);
    }
    let chunk = total.div_ceil(workers);
    std::thread::scope(|s| {
        let mut handles = Vec::with_capacity(workers);
        for w in 0..workers {
            let start = w * chunk;
            if start >= total {
                break;
            }
            let end = ((w + 1) * chunk).min(total);
            handles.push(s.spawn(move || run_range(start, end)));
        }
        let mut merged = Vec::with_capacity(total);
        for h in handles {
            let part = h
                .join()
                .map_err(|_| SimError::new(SimErrorCode::ConvergenceFailed, 0))??;
            merged.extend(part);
        }
        Ok(merged)
    })
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
    pub(super) reactive: ReactiveState,
    pub(super) phase2: Phase2State,
    dc_source_scale: f64,
    pub(super) last_was_transient: bool,
    scratch_sys: DenseSystem,
    scratch_x: Vec<f64>,
    scratch_sol_prev: Vec<f64>,
    scratch_reactive: ReactiveState,
    scratch_phase2: Phase2State,
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
            logic_samples: std::collections::VecDeque::new(),
            logic_threshold: 1.5,
            reactive: ReactiveState::default(),
            phase2: Phase2State::default(),
            dc_source_scale: 1.0,
            last_was_transient: false,
            scratch_sys: DenseSystem::new(0),
            scratch_x: Vec::new(),
            scratch_sol_prev: Vec::new(),
            scratch_reactive: ReactiveState::default(),
            scratch_phase2: Phase2State::default(),
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
        self.last_was_transient = false;
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
            if let Some(topo) = &self.topo {
                let _ = init_phase2_after_dc(
                    &self.circuit.components,
                    &self.solution,
                    topo,
                    &mut self.phase2,
                );
            }
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
        self.last_was_transient = false;
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
            return self.compile_and_dc();
        }
        self.solve_dc()?;
        let mut latch_flipped = false;
        if let Some(topo) = &self.topo {
            for (idx, comp) in self.circuit.components.iter().enumerate() {
                if comp.fault != FaultKind::None {
                    continue;
                }
                match &comp.kind {
                    ComponentKind::SchmittTrigger { v_hyst, .. } => {
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
                            latch_flipped = true;
                        }
                    }
                    ComponentKind::SrLatch { v_high, .. } => {
                        let s = node_v(&self.solution, topo, comp.nodes[0]) >= 0.5 * *v_high;
                        let r = node_v(&self.solution, topo, comp.nodes[1]) >= 0.5 * *v_high;
                        let prev = self.phase2.latch_bits[idx];
                        let next = if s && !r {
                            1
                        } else if r && !s {
                            0
                        } else {
                            prev
                        };
                        if next != prev {
                            self.phase2.latch_bits[idx] = next;
                            latch_flipped = true;
                        }
                    }
                    _ => {}
                }
            }
        }
        if latch_flipped {
            self.solve_dc()?;
        }
        Ok(())
    }

    /// Computes companion `(eq_conductance_or_resistance, history_rhs)` for C or L.
    fn reactive_companion(&self, idx: usize, val: f64, is_cap: bool, dt: f64) -> (f64, f64) {
        Self::reactive_companion_state(&self.reactive, &self.config, idx, val, is_cap, dt)
    }

    fn reactive_companion_state(
        reactive: &ReactiveState,
        config: &SimConfig,
        idx: usize,
        val: f64,
        is_cap: bool,
        dt: f64,
    ) -> (f64, f64) {
        let (y1, y2, y_dot1) = if is_cap {
            (
                reactive.cap_v_prev[idx],
                reactive.cap_v_prev2[idx],
                reactive.cap_i_prev[idx],
            )
        } else {
            (
                reactive.ind_i_prev[idx],
                reactive.ind_i_prev2[idx],
                reactive.ind_v_prev[idx],
            )
        };
        let mode = if reactive.discontinuity || !reactive.have_prev2 {
            // Standard SPICE discontinuity restart: take one Backward-Euler step to avoid ringing without cross-edge BDF2 distortion.
            IntegratorKind::BackwardEuler
        } else {
            config.integrator
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
                let r = (dt / reactive.prev_dt.max(1e-15)).clamp(0.05, 10.0);
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
        self.step_transient_depth(dt, 0)?;
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
        self.last_was_transient = true;
        Ok(())
    }

    fn step_halved(&mut self, half: f64, depth: u8) -> Result<(), SimError> {
        if depth > 0 {
            self.step_transient_depth(half, depth + 1)?;
            return self.step_transient_depth(half, depth + 1);
        }
        let saved_t = self.t_sim;
        let saved_sol = self.solution.clone();
        let saved_react = self.reactive.clone();
        let saved_p2 = self.phase2.clone();
        let saved_blown: Vec<(usize, bool)> = self
            .circuit
            .components
            .iter()
            .enumerate()
            .filter_map(|(i, c)| match c.kind {
                ComponentKind::Fuse { blown, .. } => Some((i, blown)),
                _ => None,
            })
            .collect();
        let res = (|| {
            self.step_transient_depth(half, depth + 1)?;
            self.step_transient_depth(half, depth + 1)
        })();
        if res.is_err() {
            self.t_sim = saved_t;
            self.solution = saved_sol;
            self.reactive = saved_react;
            self.phase2 = saved_p2;
            for (i, was_blown) in saved_blown {
                if let ComponentKind::Fuse { blown, .. } = &mut self.circuit.components[i].kind {
                    *blown = was_blown;
                }
            }
        }
        res
    }

    fn step_transient_depth(&mut self, dt: f64, depth: u8) -> Result<(), SimError> {
        if dt <= 0.0 || !dt.is_finite() {
            return Err(SimError::new(SimErrorCode::InvalidParameter, 0));
        }
        if self.topo.is_none() {
            self.compile_and_dc()?;
        }

        let t_prev = self.t_sim;
        let local_sol_prev = if depth == 0 {
            self.scratch_sol_prev.clone_from(&self.solution);
            Vec::new()
        } else {
            self.solution.clone()
        };
        self.phase2.use_trap = !self.reactive.discontinuity
            && matches!(
                self.config.integrator,
                IntegratorKind::Trapezoidal | IntegratorKind::Gear2
            );
        self.t_sim += dt;
        if let Err(err) = self.solve_newton_step(dt, true, self.config.gmin) {
            self.t_sim = t_prev;
            if depth == 0 {
                self.solution.clone_from(&self.scratch_sol_prev);
            } else {
                self.solution = local_sol_prev;
            }
            if depth < 2 {
                return self.step_halved(dt * 0.5, depth);
            }
            return Err(err);
        }

        // Evaluate edge-triggered/latching updates and fuses BEFORE mutating reactive history so any re-solve uses t_prev states.
        let (local_react_prev, local_p2_prev) = if depth == 0 {
            self.scratch_reactive.copy_from(&self.reactive);
            self.scratch_phase2.copy_from(&self.phase2);
            (ReactiveState::default(), Phase2State::default())
        } else {
            (self.reactive.clone(), self.phase2.clone())
        };
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
                if depth == 0 {
                    self.solution.clone_from(&self.scratch_sol_prev);
                    self.reactive.copy_from(&self.scratch_reactive);
                    self.phase2.copy_from(&self.scratch_phase2);
                } else {
                    self.solution = local_sol_prev;
                    self.reactive = local_react_prev;
                    self.phase2 = local_p2_prev;
                }
                if depth < 2 {
                    return self.step_halved(dt * 0.5, depth);
                }
                return Err(err);
            }
        }

        // Advance reactive history once from the final converged solution using t_prev state.
        {
            let topo = self.topo.as_ref().unwrap();
            let base_react = if depth == 0 {
                &self.scratch_reactive
            } else {
                &local_react_prev
            };
            for (idx, comp) in self.circuit.components.iter().enumerate() {
                match comp.kind {
                    ComponentKind::Capacitor { c, .. } => {
                        let va = node_v(&self.solution, topo, comp.nodes[0]);
                        let vb = node_v(&self.solution, topo, comp.nodes[1]);
                        let vc = va - vb;
                        let (geq, ieq) = Self::reactive_companion_state(
                            base_react,
                            &self.config,
                            idx,
                            c,
                            true,
                            dt,
                        );
                        self.reactive.cap_v_prev2[idx] = self.reactive.cap_v_prev[idx];
                        self.reactive.cap_v_prev[idx] = vc;
                        self.reactive.cap_i_prev[idx] = geq * vc - ieq;
                    }
                    ComponentKind::VaractorDiode { cj0, vj, m, .. } => {
                        let va = node_v(&self.solution, topo, comp.nodes[0]);
                        let vb = node_v(&self.solution, topo, comp.nodes[1]);
                        let vc = va - vb;
                        let vr = (-vc).max(0.0);
                        let cj = cj0 / (1.0 + vr / vj.max(0.1)).powf(m);
                        let (geq, ieq) = Self::reactive_companion_state(
                            base_react,
                            &self.config,
                            idx,
                            cj,
                            true,
                            dt,
                        );
                        self.reactive.cap_v_prev2[idx] = self.reactive.cap_v_prev[idx];
                        self.reactive.cap_v_prev[idx] = vc;
                        self.reactive.cap_i_prev[idx] = geq * vc - ieq;
                    }
                    ComponentKind::Inductor { .. } => {
                        let va = node_v(&self.solution, topo, comp.nodes[0]);
                        let vb = node_v(&self.solution, topo, comp.nodes[1]);
                        self.reactive.ind_i_prev2[idx] = self.reactive.ind_i_prev[idx];
                        self.reactive.ind_i_prev[idx] =
                            topo.branch_of_comp[idx].map_or(0.0, |b| self.solution[b]);
                        self.reactive.ind_v_prev[idx] = va - vb;
                    }
                    _ => {}
                }
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
        if !sim_duration.is_finite() {
            return Err(SimError::new(SimErrorCode::InvalidParameter, 0));
        }
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
            let dt = if steps_done + 1 == budget {
                rem
            } else {
                self.next_breakpoint_dt(self.t_sim, rem.min(cur_dt))
                    .min(rem)
            };
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

        let mut x_cur = std::mem::take(&mut self.scratch_x);
        x_cur.clear();
        x_cur.extend_from_slice(&self.solution);
        x_cur.resize(n, 0.0);

        let mut x_next = Vec::with_capacity(n);
        let mut sys = std::mem::replace(&mut self.scratch_sys, DenseSystem::new(0));
        sys.reset_or_clear(n);

        let mut outcome = Err(SimError::new(SimErrorCode::ConvergenceFailed, 0));
        'nr: for iter in 0..max_iters {
            if iter > 0 {
                sys.clear();
            }
            for i in 0..topo.node_count {
                let d_gmin = if topo.node_degree.get(i).copied().unwrap_or(0) <= 1 {
                    gmin.max(1e-12)
                } else {
                    gmin
                };
                sys.add_a(i, i, d_gmin);
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
                            self.dc_source_scale,
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

            if let Err(e) = sys.solve_into(&mut x_next) {
                outcome = Err(e);
                break 'nr;
            }
            if !has_nonlinear {
                std::mem::swap(&mut self.solution, &mut x_next);
                outcome = Ok(());
                break 'nr;
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
                if comp.fault != FaultKind::None {
                    continue;
                }
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
                    outcome = Err(SimError::new(SimErrorCode::ConvergenceFailed, 0));
                    break 'nr;
                }
                let diff = (x_next[i] - x_cur[i]).abs();
                let tol =
                    self.config.abstol + self.config.reltol * x_next[i].abs().max(x_cur[i].abs());
                if !diff.is_finite() || diff > tol {
                    converged = false;
                    break;
                }
            }
            std::mem::swap(&mut x_cur, &mut x_next);
            if converged && !any_clamped && iter > 0 {
                std::mem::swap(&mut self.solution, &mut x_cur);
                outcome = Ok(());
                break 'nr;
            }
        }

        self.scratch_sys = sys;
        self.scratch_x = x_cur;
        outcome
    }
}
