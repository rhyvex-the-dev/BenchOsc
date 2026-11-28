use crate::error::{SimError, SimErrorCode};
use crate::mna::devices::{stamp_ac_component, AcStampCtx};
use crate::mna::engine::{run_parallel_chunks, sim_worker_count, splitmix64, AcPoint, SimEngine};
use crate::mna::solver::{Complex64, ComplexSystem, DenseSystem};
use crate::netlist::{Component, ComponentKind, FaultKind};

impl SimEngine {
    pub fn solve_ac_sweep(
        &mut self,
        f_start: f64,
        f_stop: f64,
        points_per_decade: usize,
        ac_source_id: u32,
        out_node: u32,
    ) -> Result<Vec<AcPoint>, SimError> {
        self.solve_ac_sweep_transfer(
            f_start,
            f_stop,
            points_per_decade,
            ac_source_id,
            None,
            out_node,
        )
    }

    /// Single-pass parallel small-signal AC sweep computing `V(out_node)` or `V(out_node)/V(in_node)`.
    pub fn solve_ac_sweep_transfer(
        &mut self,
        f_start: f64,
        f_stop: f64,
        points_per_decade: usize,
        ac_source_id: u32,
        in_node: Option<u32>,
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
        let saved_transient = self.last_was_transient;
        let had_topo = self.topo.is_some();
        let dc_res = if had_topo {
            self.solve_dc()
        } else {
            self.compile_and_dc().and_then(|_| {
                if self.config.uic {
                    self.solve_dc()
                } else {
                    Ok(())
                }
            })
        };
        if let Err(e) = dc_res {
            if had_topo {
                self.solution = saved_sol;
                self.reactive = saved_react;
                self.phase2 = saved_p2;
                self.last_was_transient = saved_transient;
            }
            return Err(e);
        }

        let topo = self.topo.as_ref().unwrap();
        let total_pts = (pts_f.ceil() as usize).clamp(2, 100_000);
        let n_pts = total_pts + 1;

        if in_node == Some(out_node) {
            let results = (0..n_pts)
                .map(|k| {
                    let frac = k as f64 / total_pts as f64;
                    AcPoint {
                        freq_hz: f_start * (f_stop / f_start).powf(frac),
                        mag_db: 0.0,
                        phase_deg: 0.0,
                    }
                })
                .collect();
            if had_topo {
                self.solution = saved_sol;
                self.reactive = saved_react;
                self.phase2 = saved_p2;
                self.last_was_transient = saved_transient;
            }
            return Ok(results);
        }

        let x_dc = &self.solution;
        let phase2 = &self.phase2;
        let components = &self.circuit.components;
        let ac_vt = self.config.vt();
        let ac_gmin = self.config.gmin;
        let workers = sim_worker_count(n_pts);

        let solve_range = |start: usize, end: usize| -> Result<Vec<AcPoint>, SimError> {
            let mut local = Vec::with_capacity(end - start);
            let mut ac_scratch = DenseSystem::new(topo.matrix_size());
            let mut sys = ComplexSystem::new(topo.matrix_size());
            for k in start..end {
                if k > start {
                    sys.clear();
                }
                let frac = k as f64 / total_pts as f64;
                let freq = f_start * (f_stop / f_start).powf(frac);
                let omega = 2.0 * std::f64::consts::PI * freq;

                // Gmin on every node prevents isolated capacitive nodes from producing singular AC matrices at low omega.
                for idx in 0..topo.node_count {
                    let d_gmin = if topo.node_degree[idx] <= 1 {
                        ac_gmin.max(1e-12)
                    } else {
                        ac_gmin
                    };
                    sys.add_a(idx, idx, Complex64::new(d_gmin, 0.0));
                }

                let ac_ctx = AcStampCtx {
                    topo,
                    x_dc,
                    phase2,
                    omega,
                    ac_source_id,
                    gmin: ac_gmin,
                    vt: ac_vt,
                };
                for (idx, comp) in components.iter().enumerate() {
                    Self::stamp_ac_with_fault(&mut sys, comp, idx, &ac_ctx, &mut ac_scratch);
                }

                let sol = sys.solve()?;
                let v_out = topo.idx(out_node).map_or(Complex64::ZERO, |i| sol[i]);
                let resp = match in_node {
                    Some(in_n) => {
                        let v_in = topo.idx(in_n).map_or(Complex64::ZERO, |i| sol[i]);
                        if v_in.abs() > 1e-15 {
                            v_out / v_in
                        } else {
                            v_out
                        }
                    }
                    None => v_out,
                };
                let mag = resp.abs().max(1e-15);
                local.push(AcPoint {
                    freq_hz: freq,
                    mag_db: 20.0 * mag.log10(),
                    phase_deg: resp.arg_deg(),
                });
            }
            Ok(local)
        };

        let sweep_res = run_parallel_chunks(n_pts, workers, &solve_range);

        if had_topo {
            self.solution = saved_sol;
            self.reactive = saved_react;
            self.phase2 = saved_p2;
            self.last_was_transient = saved_transient;
        }
        sweep_res
    }

    /// Parallel deterministic Monte Carlo DC sweep supporting Uniform and Gaussian (±3σ) spread.
    pub fn monte_carlo_dc_ex(
        &self,
        tol: f64,
        runs: usize,
        out_node: u32,
        gaussian: bool,
    ) -> Result<(f64, f64, f64, f64, Vec<f64>), SimError> {
        if !tol.is_finite() || tol < 0.0 || runs == 0 || runs > 10_000 {
            return Err(SimError::new(SimErrorCode::InvalidParameter, 0));
        }
        let base_circuit = &self.circuit;
        let base_config = self.config;
        let workers = if runs >= 16 {
            sim_worker_count(runs)
        } else {
            1
        };

        let run_range = |start: usize, end: usize| -> Result<Vec<f64>, SimError> {
            let mut local = Vec::with_capacity(end - start);
            let mut trial = SimEngine::new();
            trial.config = base_config;
            trial.circuit = base_circuit.clone();
            trial.compile_and_dc()?;
            let base_sol = trial.solution.clone();
            let base_react = trial.reactive.clone();
            let base_p2 = trial.phase2.clone();

            for trial_idx in start..end {
                trial.solution.clone_from(&base_sol);
                trial.reactive.copy_from(&base_react);
                trial.phase2.copy_from(&base_p2);
                let mut rng = 0x9E37_79B9_7F4A_7C15u64
                    ^ ((trial_idx as u64)
                        .wrapping_add(1)
                        .wrapping_mul(0xBF58_476D_1CE4_E5B9));
                for (c_dst, c_src) in trial
                    .circuit
                    .components
                    .iter_mut()
                    .zip(base_circuit.components.iter())
                {
                    let delta = if gaussian {
                        let u1 = ((splitmix64(&mut rng) >> 11) as f64 / ((1u64 << 53) as f64))
                            .clamp(1e-6, 1.0);
                        let u2 = (splitmix64(&mut rng) >> 11) as f64 / ((1u64 << 53) as f64);
                        let z = (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos();
                        (z * (tol / 3.0)).clamp(-0.9, 0.9)
                    } else {
                        let u = ((splitmix64(&mut rng) >> 11) as f64 / ((1u64 << 53) as f64)) * 2.0
                            - 1.0;
                        tol * u
                    };
                    let scale = (1.0 + delta).max(1e-3);
                    match (&mut c_dst.kind, &c_src.kind) {
                        (ComponentKind::Resistor { r }, ComponentKind::Resistor { r: r0 }) => {
                            *r = (r0 * scale).max(1e-15);
                        }
                        (
                            ComponentKind::Potentiometer { r_total, .. },
                            ComponentKind::Potentiometer { r_total: r0, .. },
                        ) => {
                            *r_total = (r0 * scale).max(1e-15);
                        }
                        (
                            ComponentKind::Capacitor { c, .. },
                            ComponentKind::Capacitor { c: c0, .. },
                        ) => {
                            *c = (c0 * scale).max(1e-15);
                        }
                        (
                            ComponentKind::Inductor { l, .. },
                            ComponentKind::Inductor { l: l0, .. },
                        ) => {
                            *l = (l0 * scale).max(1e-15);
                        }
                        _ => {}
                    }
                }
                trial.solve_dc_op()?;
                local.push(trial.node_voltage(out_node));
            }
            Ok(local)
        };

        let vals = run_parallel_chunks(runs, workers, &run_range)?;

        let mut min_v = f64::INFINITY;
        let mut max_v = f64::NEG_INFINITY;
        let mut sum = 0.0;
        for &v in &vals {
            min_v = min_v.min(v);
            max_v = max_v.max(v);
            sum += v;
        }
        let mean = sum / vals.len() as f64;
        let var = vals.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / vals.len() as f64;
        Ok((min_v, max_v, mean, var.sqrt(), vals))
    }

    fn stamp_ac_with_fault(
        sys: &mut ComplexSystem,
        comp: &Component,
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
        probe.config.uic = false;
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
                ComponentKind::ClockSource { v_high, .. }
                | ComponentKind::WordGen { v_high, .. } => {
                    *v_high = 0.0;
                }
                _ => {}
            }
        }
        // Temporarily reference node_b to GND via 1e12 ohm + test current so isolated parts compile cleanly.
        let next_probe_id = |exclude: Option<u32>| -> u32 {
            let mut candidate = probe
                .circuit
                .components
                .iter()
                .map(|c| c.id)
                .max()
                .unwrap_or(0)
                .wrapping_add(1);
            loop {
                if candidate != 0
                    && Some(candidate) != exclude
                    && !probe.circuit.components.iter().any(|c| c.id == candidate)
                {
                    return candidate;
                }
                candidate = candidate.wrapping_add(1);
            }
        };
        let ref_id = next_probe_id(None);
        let test_id = next_probe_id(Some(ref_id));
        let i_test = if diode_mode { 1e-3 } else { 1e-4 };
        if node_b != 0 {
            probe.circuit.add(Component {
                id: ref_id,
                name: "M_REF".into(),
                kind: ComponentKind::Resistor { r: 1e12 },
                nodes: [node_b, 0, 0, 0, 0, 0, 0, 0],
                pin_count: 2,
                fault: FaultKind::None,
            })?;
        }
        probe.circuit.add(Component {
            id: test_id,
            name: "M_TEST".into(),
            kind: ComponentKind::DcCurrent { i: -i_test },
            nodes: [node_a, node_b, 0, 0, 0, 0, 0, 0],
            pin_count: 2,
            fault: FaultKind::None,
        })?;
        probe.compile_and_dc()?;
        let dv = probe.node_voltage(node_a) - probe.node_voltage(node_b);
        if diode_mode {
            Ok(if !dv.is_finite() || dv.abs() > 10.0 {
                f64::INFINITY
            } else {
                dv
            })
        } else {
            let r = (dv / i_test).abs();
            Ok(if r > 5e8 { f64::INFINITY } else { r })
        }
    }
}
