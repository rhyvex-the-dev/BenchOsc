pub mod digital;
pub mod error;
pub mod ffi;
pub mod instruments;
pub mod mna;
pub mod netlist;
pub mod spice_io;

#[cfg(test)]
mod tests {
    use crate::digital::{eval_soft_gate, minimize_truth_table_dc, GateKind};
    use crate::error::SimErrorCode;
    use crate::ffi::{
        ob_logic_minimize_ex, ob_sim_ac_sweep_transfer, ob_sim_add_component_ex,
        ob_sim_channel_stats, ob_sim_create, ob_sim_destroy, ob_sim_get_component_current,
        ob_sim_get_node_voltage, ob_sim_read_frame_state, ob_sim_read_scope_4ch, ob_sim_scope_fft,
        ob_sim_set_fault, ob_sim_set_scope_probe, ob_sim_solve_dc, ob_sim_step_frame, SimHandle,
    };
    use crate::instruments::compute_fft_magnitudes;
    use crate::mna::engine::SimEngine;
    use crate::netlist::{Component, ComponentKind, FaultKind, GND};
    use crate::spice_io::export_cir;

    #[allow(clippy::too_many_arguments)]
    unsafe fn ob_sim_add_component(
        ptr: *mut SimHandle,
        id: u32,
        comp_type: i32,
        n0: u32,
        n1: u32,
        n2: u32,
        n3: u32,
        p0: f64,
        p1: f64,
        p2: f64,
        p3: f64,
        p4: f64,
    ) -> i32 {
        let pins = [n0, n1, n2, n3];
        let params = [p0, p1, p2, p3, p4];
        ob_sim_add_component_ex(ptr, id, comp_type, pins.as_ptr(), 4, params.as_ptr(), 5)
    }

    unsafe fn ob_sim_read_scope(
        ptr: *mut SimHandle,
        ch: u32,
        out_times: *mut f64,
        out_values: *mut f64,
        max_len: usize,
    ) -> usize {
        let mut slots = [std::ptr::null_mut(); 4];
        if (ch as usize) < 4 {
            slots[ch as usize] = out_values;
        }
        ob_sim_read_scope_4ch(
            ptr, 0, 0.0, 1, 0, out_times, slots[0], slots[1], slots[2], slots[3], max_len,
        )
    }

    fn minimize_truth_table(var_count: usize, outputs: &[bool]) -> String {
        let encoded: Vec<u8> = outputs.iter().map(|&on| u8::from(on)).collect();
        minimize_truth_table_dc(var_count, &encoded)
    }

    fn comp(id: u32, kind: ComponentKind, nodes: &[u32]) -> Component {
        let mut arr = [0u32; 8];
        arr[..nodes.len()].copy_from_slice(nodes);
        Component {
            id,
            name: format!("C{id}"),
            kind,
            nodes: arr,
            pin_count: nodes.len() as u8,
            fault: FaultKind::None,
        }
    }

    #[test]
    fn dc_voltage_divider_and_potentiometer() {
        let mut sim = SimEngine::new();
        // 10V source between node 1 and GND; 1k + 1k divider to node 2
        sim.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 10.0 }, &[1, GND]))
            .unwrap();
        sim.circuit
            .add(comp(
                2,
                ComponentKind::Potentiometer {
                    r_total: 2000.0,
                    wiper: 0.25,
                },
                &[1, GND, 2],
            ))
            .unwrap();
        sim.compile_and_dc().unwrap();
        assert!((sim.node_voltage(2) - 2.5).abs() < 1e-6);

        // Live move wiper to 75%
        sim.set_control(2, 0, 0.75).unwrap();
        sim.solve_dc().unwrap();
        assert!((sim.node_voltage(2) - 7.5).abs() < 1e-6);
        assert!(sim.component_current(2).abs() > 1e-3);
    }

    #[test]
    fn missing_ground_and_floating_node_detected() {
        let mut sim = SimEngine::new();
        sim.circuit
            .add(comp(1, ComponentKind::Resistor { r: 1000.0 }, &[1, 2]))
            .unwrap();
        let err = sim.compile_and_dc().unwrap_err();
        assert_eq!(err.code, SimErrorCode::MissingGround);

        sim.circuit
            .add(comp(2, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        sim.circuit
            .add(comp(3, ComponentKind::Resistor { r: 100.0 }, &[5, 6]))
            .unwrap();
        let err = sim.compile_and_dc().unwrap_err();
        assert_eq!(err.code, SimErrorCode::FloatingNode);
        assert_eq!(err.detail_id, 5);
    }

    #[test]
    fn rc_step_transient_matches_analytical_exponential() {
        let mut sim = SimEngine::new();
        let r = 1_000.0;
        let c = 1e-6; // tau = 1 ms
        sim.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        sim.circuit
            .add(comp(2, ComponentKind::Resistor { r }, &[1, 2]))
            .unwrap();
        sim.circuit
            .add(comp(3, ComponentKind::Capacitor { c, ic: None }, &[2, GND]))
            .unwrap();
        sim.compile_and_dc().unwrap();
        // Force capacitor initial voltage = 0V (as if switched on at t=0)
        // Use a SwitchSpst closed after DC OP or explicit IC via a switched source:
        sim.clear();
        sim.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        sim.circuit
            .add(comp(
                2,
                ComponentKind::SwitchSpst {
                    closed: false,
                    r_on: 1e-3,
                    r_off: 1e12,
                },
                &[1, 3],
            ))
            .unwrap();
        sim.circuit
            .add(comp(3, ComponentKind::Resistor { r }, &[3, 2]))
            .unwrap();
        sim.circuit
            .add(comp(
                4,
                ComponentKind::Capacitor { c, ic: Some(0.0) },
                &[2, GND],
            ))
            .unwrap();
        // Realistic 10 MOhm scope probe input impedance holds uncharged cap near 0V while switch is open.
        sim.circuit
            .add(comp(
                5,
                ComponentKind::Resistor { r: 10_000_000.0 },
                &[2, GND],
            ))
            .unwrap();
        sim.compile_and_dc().unwrap();
        assert!(sim.node_voltage(2).abs() < 1e-4);

        // Close switch and advance 1 ms (= 1 * tau)
        sim.set_control(2, 0, 1.0).unwrap();
        sim.default_dt = 1e-5;
        sim.run_for_frame(1e-3, 500).unwrap();

        let expected = 5.0 * (1.0 - (-1.0_f64).exp()); // ~3.1606 V
        let actual = sim.node_voltage(2);
        assert!(
            (actual - expected).abs() < 0.03,
            "actual={actual}, expected={expected}"
        );
    }

    #[test]
    fn diode_forward_drop_and_opamp_inverting_gain() {
        // Diode + 1k resistor from 5V
        let mut sim = SimEngine::new();
        sim.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        sim.circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, 2]))
            .unwrap();
        sim.circuit
            .add(comp(
                3,
                ComponentKind::Diode {
                    is_sat: 1e-12,
                    n: 1.5,
                    bv: f64::INFINITY,
                },
                &[2, GND],
            ))
            .unwrap();
        sim.compile_and_dc().unwrap();
        let vd = sim.node_voltage(2);
        assert!(vd > 0.55 && vd < 0.90, "unexpected diode drop {vd}");

        // Inverting op-amp: Vin = 1.5V, Rin = 1k, Rf = 2k -> Vout = -3.0V
        let mut op = SimEngine::new();
        op.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 1.5 }, &[1, GND]))
            .unwrap();
        op.circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, 2]))
            .unwrap();
        op.circuit
            .add(comp(3, ComponentKind::Resistor { r: 2000.0 }, &[2, 3]))
            .unwrap();
        op.circuit
            .add(comp(
                4,
                ComponentKind::OpAmp {
                    gain: 1e5,
                    v_sat_pos: 15.0,
                    v_sat_neg: -15.0,
                    r_out: 50.0,
                },
                &[GND, 2, 3],
            ))
            .unwrap();
        op.compile_and_dc().unwrap();
        assert!(
            (op.node_voltage(3) - (-3.0)).abs() < 1e-3,
            "vout={}",
            op.node_voltage(3)
        );
    }

    #[test]
    fn npn_bjt_common_emitter_bias_and_nmos_saturation() {
        // NPN: Vcc=10V, Rc=1k (1->2), Rb=100k (1->3), emitter GND
        let mut sim = SimEngine::new();
        sim.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 10.0 }, &[1, GND]))
            .unwrap();
        sim.circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, 2]))
            .unwrap();
        sim.circuit
            .add(comp(3, ComponentKind::Resistor { r: 100_000.0 }, &[1, 3]))
            .unwrap();
        sim.circuit
            .add(comp(
                4,
                ComponentKind::NpnBjt {
                    is_sat: 1e-14,
                    bf: 100.0,
                    br: 1.0,
                },
                &[2, 3, GND],
            ))
            .unwrap();
        sim.compile_and_dc().unwrap();
        let vb = sim.node_voltage(3);
        let vc = sim.node_voltage(2);
        assert!(vb > 0.6 && vb < 0.85, "vb={vb}");
        assert!(vc > 0.1 && vc < 2.0, "vc={vc}");
        assert!(sim.component_current(4) > 1e-3);

        // NMOS Triode: Vdd=5V, Rd=1k, Vg=3V, kp=2e-3, Vth=1V -> Vd = (5 - sqrt(5))/2 ~= 1.381966 V
        let mut mos = SimEngine::new();
        mos.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        mos.circuit
            .add(comp(2, ComponentKind::DcVoltage { v: 3.0 }, &[2, GND]))
            .unwrap();
        mos.circuit
            .add(comp(3, ComponentKind::Resistor { r: 1000.0 }, &[1, 3]))
            .unwrap();
        mos.circuit
            .add(comp(
                4,
                ComponentKind::Nmos {
                    kp: 2e-3,
                    vth: 1.0,
                    lambda: 0.0,
                },
                &[3, 2, GND],
            ))
            .unwrap();
        mos.compile_and_dc().unwrap();
        let expected_triode = (5.0 - 5.0_f64.sqrt()) * 0.5;
        assert!(
            (mos.node_voltage(3) - expected_triode).abs() < 1e-6,
            "vd={}",
            mos.node_voltage(3)
        );

        // NMOS Saturation: Rd=500 -> Id = 4mA -> Vd = 3.0V > Vov (2.0V)
        mos.set_control(3, 0, 500.0).unwrap();
        mos.solve_dc().unwrap();
        assert!(
            (mos.node_voltage(3) - 3.0).abs() < 1e-6,
            "vd_sat={}",
            mos.node_voltage(3)
        );
    }

    #[test]
    fn ac_sweep_rc_lowpass_cutoff() {
        // R = 1k, C = 159.155 nF -> fc = 1000 Hz (-3.01 dB, -45 deg)
        let mut sim = SimEngine::new();
        sim.circuit
            .add(comp(
                1,
                ComponentKind::AcVoltage {
                    amp: 1.0,
                    freq: 1000.0,
                    phase_deg: 0.0,
                    offset: 0.0,
                },
                &[1, GND],
            ))
            .unwrap();
        sim.circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, 2]))
            .unwrap();
        sim.circuit
            .add(comp(
                3,
                ComponentKind::Capacitor {
                    c: 159.154943e-9,
                    ic: None,
                },
                &[2, GND],
            ))
            .unwrap();
        let sweep = sim.solve_ac_sweep(100.0, 10_000.0, 20, 1, 2).unwrap();
        let near_fc = sweep
            .iter()
            .min_by(|a, b| {
                (a.freq_hz - 1000.0)
                    .abs()
                    .partial_cmp(&(b.freq_hz - 1000.0).abs())
                    .unwrap()
            })
            .unwrap();
        assert!(
            (near_fc.mag_db - (-3.01)).abs() < 0.35,
            "mag_db={}",
            near_fc.mag_db
        );
        assert!(
            (near_fc.phase_deg - (-45.0)).abs() < 2.0,
            "phase={}",
            near_fc.phase_deg
        );
    }

    #[test]
    fn fuse_trips_on_overcurrent() {
        let mut sim = SimEngine::new();
        sim.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 10.0 }, &[1, GND]))
            .unwrap();
        sim.circuit
            .add(comp(
                2,
                ComponentKind::Fuse {
                    i_max: 0.5,
                    r_on: 0.1,
                    blown: false,
                },
                &[1, 2],
            ))
            .unwrap();
        sim.circuit
            .add(comp(3, ComponentKind::Resistor { r: 5.0 }, &[2, GND]))
            .unwrap(); // ~1.96 A > 0.5 A
        sim.compile_and_dc().unwrap();
        sim.step_transient(1e-4).unwrap();
        sim.step_transient(1e-4).unwrap();
        assert!(
            sim.node_voltage(2) < 1e-4,
            "expected blown fuse open, v2={}",
            sim.node_voltage(2)
        );

        // Open-faulted fuse must not blow across steps, and compile_and_dc resets blown state.
        sim.set_fault(2, FaultKind::Open).unwrap();
        sim.compile_and_dc().unwrap();
        sim.step_transient(1e-4).unwrap();
        assert!(matches!(
            sim.circuit.components[1].kind,
            ComponentKind::Fuse { blown: false, .. }
        ));
    }

    #[test]
    fn digital_gates_logic_converter_fft_and_cir_export() {
        assert!(eval_soft_gate(GateKind::Xor, &[5.0, 0.0], 5.0) > 4.5);
        assert!(eval_soft_gate(GateKind::Nand, &[5.0, 5.0], 5.0) < 0.5);

        // 2-var XOR truth table: 0, 1, 1, 0 -> A'B + AB'
        let expr = minimize_truth_table(2, &[false, true, true, false]);
        assert!(expr.contains("A'B") && expr.contains("AB'"), "expr={expr}");

        // Pure 100Hz tone over 64 samples at 640Hz sample rate -> peak at bin 10
        let samples: Vec<f64> = (0..64)
            .map(|i| (2.0 * std::f64::consts::PI * 10.0 * (i as f64) / 64.0).sin())
            .collect();
        let mags = compute_fft_magnitudes(&samples);
        let peak_bin = mags
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
            .unwrap()
            .0;
        assert_eq!(peak_bin, 10);

        let mut c = crate::netlist::Circuit::new();
        c.add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        c.add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, GND]))
            .unwrap();
        let cir = export_cir("Test", &c);
        assert!(cir.contains("V1 1 0 DC 5") && cir.contains("R2 1 0 1000"));
    }

    #[test]
    fn ffi_decoupled_60hz_and_120hz_frame_stepping_match_time() {
        unsafe {
            let h60 = ob_sim_create();
            let h120 = ob_sim_create();
            for h in [h60, h120] {
                assert_eq!(
                    ob_sim_add_component(h, 1, 11, 1, 0, 0, 0, 5.0, 100.0, 0.0, 0.0, 0.0),
                    0
                );
                assert_eq!(
                    ob_sim_add_component(h, 2, 1, 1, 2, 0, 0, 1000.0, 0.0, 0.0, 0.0, 0.0),
                    0
                );
                assert_eq!(
                    ob_sim_add_component(h, 3, 1, 2, 0, 0, 0, 1000.0, 0.0, 0.0, 0.0, 0.0),
                    0
                );
                assert_eq!(ob_sim_set_scope_probe(h, 0, 2), 0);
                assert_eq!(ob_sim_solve_dc(h), 0);
            }

            let mut t60 = 0.0;
            for _ in 0..6 {
                assert_eq!(ob_sim_step_frame(h60, 1.0 / 60.0, 200, &mut t60), 0);
            }
            let mut t120 = 0.0;
            for _ in 0..12 {
                assert_eq!(ob_sim_step_frame(h120, 1.0 / 120.0, 200, &mut t120), 0);
            }

            assert!((t60 - 0.1).abs() < 1e-9);
            assert!((t120 - 0.1).abs() < 1e-9);
            let v60 = ob_sim_get_node_voltage(h60, 2);
            let v120 = ob_sim_get_node_voltage(h120, 2);
            assert!((v60 - v120).abs() < 1e-6, "v60={v60}, v120={v120}");

            let mut times = vec![0.0; 128];
            let mut vals = vec![0.0; 128];
            let count = ob_sim_read_scope(h120, 0, times.as_mut_ptr(), vals.as_mut_ptr(), 128);
            assert!(count > 0);

            ob_sim_destroy(h60);
            ob_sim_destroy(h120);
        }
    }

    #[test]
    fn mixed_signal_gates_faults_and_advanced_ffi() {
        unsafe {
            let h = ob_sim_create();
            // Node 1 = Clock 100Hz, Node 2 = 5V DC, Node 3 = XOR(1, 2), 1k load on Node 3
            assert_eq!(
                ob_sim_add_component(h, 1, 36, 1, 0, 0, 0, 100.0, 5.0, 50.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 2, 10, 2, 0, 0, 0, 5.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 3, 35, 1, 2, 3, 0, 5.0, 50.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 4, 1, 3, 0, 0, 0, 1000.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(ob_sim_set_scope_probe(h, 0, 3), 0);
            assert_eq!(ob_sim_solve_dc(h), 0);

            // At DC OP, clock is 0V and DC is 5V -> XOR output ~ 5V (loaded by 50 / 1000 divider)
            assert!(ob_sim_get_node_voltage(h, 3) > 4.5);

            // Step 2ms (t=0.002s, phase=0.2 < 0.5 -> clock is 5V -> XOR(5V, 5V) = 0V)
            let mut t = 0.0;
            assert_eq!(ob_sim_step_frame(h, 0.002, 50, &mut t), 0);
            assert!(ob_sim_get_node_voltage(h, 3) < 0.2);

            // Fault injection: Open load resistor (comp 4) + Short DC source (comp 2) -> clock stays 5V -> XOR(5,0) = 5V
            assert_eq!(ob_sim_set_fault(h, 4, 1), 0);
            assert_eq!(ob_sim_set_fault(h, 2, 2), 0);
            assert_eq!(ob_sim_solve_dc(h), 0);
            assert!(ob_sim_get_node_voltage(h, 2).abs() < 1e-4);
            assert!(ob_sim_get_component_current(h, 4).abs() < 1e-9);

            // Channel stats & FFT on stepped waveform
            assert_eq!(ob_sim_set_fault(h, 2, 0), 0);
            assert_eq!(ob_sim_set_fault(h, 4, 0), 0);
            assert_eq!(ob_sim_solve_dc(h), 0);
            for _ in 0..8 {
                assert_eq!(ob_sim_step_frame(h, 0.002, 32, &mut t), 0);
            }
            let (mut dc, mut rms, mut min_v, mut max_v) = (0.0, 0.0, 0.0, 0.0);
            assert_eq!(
                ob_sim_channel_stats(h, 0, &mut dc, &mut rms, &mut min_v, &mut max_v),
                0
            );
            assert!(max_v > 4.0 && min_v < 0.5 && rms > 0.5);

            let mut fft_bins = vec![0.0; 128];
            let bin_count = ob_sim_scope_fft(h, 0, fft_bins.as_mut_ptr(), 128);
            assert!(bin_count >= 16);

            ob_sim_destroy(h);

            // AC sweep via FFI on RC low-pass
            let hac = ob_sim_create();
            assert_eq!(
                ob_sim_add_component(hac, 1, 11, 1, 0, 0, 0, 1.0, 1000.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(hac, 2, 1, 1, 2, 0, 0, 1000.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(hac, 3, 3, 2, 0, 0, 0, 159.154943e-9, 0.0, 0.0, 0.0, 0.0),
                0
            );
            let mut freqs = vec![0.0; 64];
            let mut mags = vec![0.0; 64];
            let mut phases = vec![0.0; 64];
            let pts = ob_sim_ac_sweep_transfer(
                hac,
                100.0,
                10000.0,
                10,
                1,
                -1,
                2,
                freqs.as_mut_ptr(),
                mags.as_mut_ptr(),
                phases.as_mut_ptr(),
                64,
            );
            assert!(pts > 10);
            ob_sim_destroy(hac);

            // Logic minimizer via FFI: XOR truth table [0, 1, 1, 0]
            let mut utf8 = vec![0u8; 64];
            let outs = [0u8, 1, 1, 0];
            let len = ob_logic_minimize_ex(2, outs.as_ptr(), outs.len(), utf8.as_mut_ptr(), 64);
            let s = std::str::from_utf8(&utf8[..len]).unwrap();
            assert!(s.contains("A'B") && s.contains("AB'"), "logic={s}");
        }
    }

    #[test]
    fn ewb_iteration1_spdt_vccs_xnor_and_dff_divider() {
        unsafe {
            // 1. SPDT Switch + VCCS + LogicProbe via FFI
            let h = ob_sim_create();
            assert_eq!(
                ob_sim_add_component(h, 1, 10, 1, 0, 0, 0, 5.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 2, 10, 2, 0, 0, 0, 1.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            // SPDT: common=3, throwA=1 (5V), throwB=2 (1V), default throwA
            assert_eq!(
                ob_sim_add_component(h, 3, 7, 3, 1, 2, 0, 0.0, 1e-3, 1e9, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 4, 1, 3, 0, 0, 0, 10_000.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            // VCCS: out_p=0 (GND), out_n=4, ctrl_p=3, ctrl_n=0, gm=0.002 -> I flows into node 4 across 1k -> V4 = 0.002 * V3 * 1000 = 2 * V3
            assert_eq!(
                ob_sim_add_component(h, 5, 15, 0, 4, 3, 0, 0.002, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 6, 1, 4, 0, 0, 0, 1000.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 7, 39, 3, 0, 0, 0, 1e7, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(ob_sim_solve_dc(h), 0);
            assert!((ob_sim_get_node_voltage(h, 3) - 5.0).abs() < 1e-3);
            assert!((ob_sim_get_node_voltage(h, 4) - 10.0).abs() < 1e-2);

            // Toggle SPDT to throw B (1V)
            assert_eq!(crate::ffi::ob_sim_set_control(h, 3, 0, 1.0), 0);
            assert_eq!(ob_sim_solve_dc(h), 0);
            assert!((ob_sim_get_node_voltage(h, 3) - 1.0).abs() < 1e-3);
            assert!((ob_sim_get_node_voltage(h, 4) - 2.0).abs() < 1e-2);
            ob_sim_destroy(h);

            // 2. XNOR gate: High + High -> High, High + Low -> Low
            let hx = ob_sim_create();
            assert_eq!(
                ob_sim_add_component(hx, 1, 10, 1, 0, 0, 0, 5.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(hx, 2, 10, 2, 0, 0, 0, 5.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(hx, 3, 37, 1, 2, 3, 0, 5.0, 50.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(hx, 4, 39, 3, 0, 0, 0, 1e7, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(ob_sim_solve_dc(hx), 0);
            assert!(ob_sim_get_node_voltage(hx, 3) > 4.9);
            assert_eq!(crate::ffi::ob_sim_set_control(hx, 2, 0, 0.0), 0);
            assert_eq!(ob_sim_solve_dc(hx), 0);
            assert!(ob_sim_get_node_voltage(hx, 3) < 0.1);
            ob_sim_destroy(hx);

            // 3. D Flip-Flop divide-by-2 toggle (Qn -> D) driven by 100Hz clock
            let hd = ob_sim_create();
            assert_eq!(
                ob_sim_add_component(hd, 1, 36, 1, 0, 0, 0, 100.0, 5.0, 50.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(hd, 2, 38, 3, 1, 2, 3, 5.0, 50.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(hd, 3, 39, 2, 0, 0, 0, 1e7, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(ob_sim_solve_dc(hd), 0);
            assert!(ob_sim_get_node_voltage(hd, 2) < 0.1);
            assert!(ob_sim_get_node_voltage(hd, 3) > 4.9);

            let mut t = 0.0;
            // First rising edge at t > 0 -> Q becomes 5V
            assert_eq!(ob_sim_step_frame(hd, 0.002, 50, &mut t), 0);
            assert!(
                ob_sim_get_node_voltage(hd, 2) > 4.9,
                "q={}",
                ob_sim_get_node_voltage(hd, 2)
            );
            // Fall through 0.006s (CLK low) -> Q stays 5V
            assert_eq!(ob_sim_step_frame(hd, 0.005, 50, &mut t), 0);
            assert!(ob_sim_get_node_voltage(hd, 2) > 4.9);
            // Second rising edge past 0.010s -> Q toggles back to 0V
            assert_eq!(ob_sim_step_frame(hd, 0.005, 50, &mut t), 0);
            assert!(
                ob_sim_get_node_voltage(hd, 2) < 0.1,
                "q={}",
                ob_sim_get_node_voltage(hd, 2)
            );
            ob_sim_destroy(hd);
        }
    }

    #[test]
    fn ewb_iteration3_timer555_transformer_cccs_ccvs_and_seven_seg() {
        unsafe {
            // 1. Transformer + CCCS + CCVS + SevenSeg
            let h = ob_sim_create();
            assert_eq!(
                ob_sim_add_component(h, 1, 10, 1, 0, 0, 0, 5.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 2, 42, 1, 0, 2, 0, 3.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 3, 1, 2, 0, 0, 0, 1000.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            // Sense loop: 5V -> 1k (1->3) -> CCCS sense (3->4) -> CCVS sense (4->0) -> Isense ≈ 5mA
            assert_eq!(
                ob_sim_add_component(h, 4, 1, 1, 3, 0, 0, 1000.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 5, 16, 0, 5, 3, 4, 4.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 6, 1, 5, 0, 0, 0, 1000.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 7, 17, 6, 0, 4, 0, 2000.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 8, 41, 1, 0, 1, 0, 1e7, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(ob_sim_solve_dc(h), 0);
            assert!(
                (ob_sim_get_node_voltage(h, 2) - 15.0).abs() < 1e-2,
                "tx_v={}",
                ob_sim_get_node_voltage(h, 2)
            );
            assert!(
                (ob_sim_get_node_voltage(h, 5) - 20.0).abs() < 0.1,
                "cccs_v={}",
                ob_sim_get_node_voltage(h, 5)
            );
            assert!((ob_sim_get_component_current(h, 5) - 0.02).abs() < 1e-3);
            assert!(
                (ob_sim_get_node_voltage(h, 6) - 10.0).abs() < 0.1,
                "ccvs_v={}",
                ob_sim_get_node_voltage(h, 6)
            );
            ob_sim_destroy(h);

            // 2. 555 Timer astable oscillator: Ra=1k, Rb=1k, C=1uF (ic=0V), Vcc=5V
            let ht = ob_sim_create();
            assert_eq!(
                ob_sim_add_component(ht, 1, 10, 1, 0, 0, 0, 5.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(ht, 2, 1, 1, 2, 0, 0, 1000.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(ht, 3, 1, 2, 3, 0, 0, 1000.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(ht, 4, 3, 3, 0, 0, 0, 1e-6, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(ht, 5, 40, 3, 3, 2, 4, 5.0, 50.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(ob_sim_solve_dc(ht), 0);

            let mut saw_high = false;
            let mut saw_low = false;
            let mut t = 0.0;
            for _ in 0..50 {
                assert_eq!(ob_sim_step_frame(ht, 0.0002, 10, &mut t), 0);
                let v_out = ob_sim_get_node_voltage(ht, 4);
                if v_out > 4.5 {
                    saw_high = true;
                }
                if v_out < 0.5 {
                    saw_low = true;
                }
            }
            assert!(
                saw_high && saw_low,
                "555 did not oscillate: high={saw_high}, low={saw_low}"
            );
            ob_sim_destroy(ht);
        }
    }

    #[test]
    fn ewb_iteration4_relay_lamp_and_pushbutton() {
        unsafe {
            let h = ob_sim_create();
            // 5V coil drive through momentary pushbutton (45) to Relay (43) coil (node 2 -> 0)
            // Relay NO contact switches 12V (node 3) onto 50-ohm Lamp (44) (node 4 -> 0)
            assert_eq!(
                ob_sim_add_component(h, 1, 10, 1, 0, 0, 0, 5.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 2, 45, 1, 2, 0, 0, 0.0, 1e-3, 1e9, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 3, 10, 3, 0, 0, 0, 12.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 4, 43, 2, 0, 3, 4, 100.0, 3.0, 1e-3, 1e9, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 5, 44, 4, 0, 0, 0, 50.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(ob_sim_solve_dc(h), 0);

            // Initially pushbutton is open -> coil ~0V -> contact open -> lamp ~0V
            assert!(ob_sim_get_node_voltage(h, 2) < 0.1);
            assert!(ob_sim_get_node_voltage(h, 4) < 0.1);

            // Press pushbutton -> coil 5V >= 3V pull-in -> contact closes -> lamp ~12V (240 mA)
            assert_eq!(crate::ffi::ob_sim_set_control(h, 2, 0, 1.0), 0);
            assert_eq!(ob_sim_solve_dc(h), 0);
            assert!((ob_sim_get_node_voltage(h, 2) - 5.0).abs() < 1e-2);
            assert!((ob_sim_get_node_voltage(h, 4) - 12.0).abs() < 0.05);
            assert!((ob_sim_get_component_current(h, 5) - 0.24).abs() < 1e-2);

            // Release pushbutton -> coil drops out -> lamp off
            assert_eq!(crate::ffi::ob_sim_set_control(h, 2, 0, 0.0), 0);
            assert_eq!(ob_sim_solve_dc(h), 0);
            assert!(ob_sim_get_node_voltage(h, 4) < 0.1);
            ob_sim_destroy(h);
        }
    }

    #[test]
    fn ewb_iteration5_word_gen_and_four_channel_scope() {
        unsafe {
            let h = ob_sim_create();
            // WordGen (46) at 100Hz counting 0..F across nodes 1..4, load R on node 4 -> GND
            assert_eq!(
                ob_sim_add_component(h, 1, 46, 1, 2, 3, 4, 100.0, 0.0, 5.0, 50.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 2, 1, 4, 0, 0, 0, 10_000.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            for ch in 0..4 {
                assert_eq!(ob_sim_set_scope_probe(h, ch, (ch + 1) as i32), 0);
            }
            assert_eq!(ob_sim_solve_dc(h), 0);

            // Step to t = 0.105s -> step_idx = floor(10.5) = 10 -> 0xA = 1010b -> b3=5V, b2=0V, b1=5V, b0=0V
            let mut t = 0.0;
            for _ in 0..21 {
                assert_eq!(ob_sim_step_frame(h, 0.005, 50, &mut t), 0);
            }
            assert!(ob_sim_get_node_voltage(h, 1) > 4.8);
            assert!(ob_sim_get_node_voltage(h, 2) < 0.2);
            assert!(ob_sim_get_node_voltage(h, 3) > 4.8);
            assert!(ob_sim_get_node_voltage(h, 4) < 0.2);

            let mut times = vec![0.0; 64];
            let mut ch3_vals = vec![0.0; 64];
            let count = ob_sim_read_scope(h, 2, times.as_mut_ptr(), ch3_vals.as_mut_ptr(), 64);
            assert!(count > 0);
            ob_sim_destroy(h);
        }
    }

    #[test]
    fn ewb_iteration6_optocoupler_isolated_transfer() {
        unsafe {
            let h = ob_sim_create();
            // Input LED side: V1 (node 1) -> R330 (node 1->2) -> Optocoupler LED (2->0)
            // Output side: 5V (node 3) -> R1k (node 3->4) -> Optocoupler C-E (4->0)
            assert_eq!(
                ob_sim_add_component(h, 1, 10, 1, 0, 0, 0, 0.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 2, 1, 1, 2, 0, 0, 330.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 3, 10, 3, 0, 0, 0, 5.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 4, 1, 3, 4, 0, 0, 1000.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 5, 47, 2, 0, 4, 0, 1.0, 1e-16, 1.8, 0.0, 0.0),
                0
            );
            assert_eq!(ob_sim_solve_dc(h), 0);

            // LED off -> collector stays pulled up to ~5V
            assert!((ob_sim_get_node_voltage(h, 4) - 5.0).abs() < 0.05);

            // Drive LED with 5V -> phototransistor saturates low (< 0.3V), Ic > 4 mA
            assert_eq!(crate::ffi::ob_sim_set_control(h, 1, 0, 5.0), 0);
            assert_eq!(ob_sim_solve_dc(h), 0);
            assert!(ob_sim_get_node_voltage(h, 4) < 0.3);
            assert!(ob_sim_get_component_current(h, 5) > 0.004);

            // Adjust CTR live -> lower CTR reduces collector pull-down current
            assert_eq!(crate::ffi::ob_sim_set_control(h, 5, 0, 0.2), 0);
            assert_eq!(ob_sim_solve_dc(h), 0);
            assert!(ob_sim_get_node_voltage(h, 4) > 2.0);
            ob_sim_destroy(h);
        }
    }

    #[test]
    fn ewb_iteration7_schmitt_trigger_and_binary_counter() {
        unsafe {
            let h = ob_sim_create();
            // SchmittTrigger (48): in+ (node 1), in- (node 2 = 2V ref), out (node 3), v_hyst=0.5V
            assert_eq!(
                ob_sim_add_component(h, 1, 10, 1, 0, 0, 0, 3.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 2, 10, 2, 0, 0, 0, 2.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 3, 48, 1, 2, 3, 0, 0.5, 5.0, 50.0, 0.0, 0.0),
                0
            );
            // Clock (36) at 100Hz driving 3-bit Binary Counter (49) on node 10 -> q2..q0 (nodes 11..13)
            assert_eq!(
                ob_sim_add_component(h, 4, 36, 10, 0, 0, 0, 100.0, 5.0, 50.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 5, 49, 10, 11, 12, 13, 5.0, 50.0, 0.0, 0.0, 0.0),
                0
            );

            let mut t = 0.0;
            // Start with v_diff = +1.0V >= +0.5V -> HIGH
            assert_eq!(ob_sim_step_frame(h, 0.002, 20, &mut t), 0);
            assert!(ob_sim_get_node_voltage(h, 3) > 4.8);

            // Drop inside hysteresis band (v_diff = +0.2V) -> remains HIGH
            assert_eq!(crate::ffi::ob_sim_set_control(h, 1, 0, 2.2), 0);
            assert_eq!(ob_sim_step_frame(h, 0.002, 20, &mut t), 0);
            assert!(ob_sim_get_node_voltage(h, 3) > 4.8);

            // Drop below -0.5V (v_diff = -0.8V) -> switches LOW
            assert_eq!(crate::ffi::ob_sim_set_control(h, 1, 0, 1.2), 0);
            assert_eq!(ob_sim_step_frame(h, 0.002, 20, &mut t), 0);
            assert!(ob_sim_get_node_voltage(h, 3) < 0.2);

            // Raise inside band (v_diff = -0.2V) -> remains LOW
            assert_eq!(crate::ffi::ob_sim_set_control(h, 1, 0, 1.8), 0);
            assert_eq!(ob_sim_step_frame(h, 0.002, 20, &mut t), 0);
            assert!(ob_sim_get_node_voltage(h, 3) < 0.2);

            // t = 0.008s so far (1 edge); advance to t = 0.024s -> 3 rising edges => 0b011 (q2=0, q1=5V, q0=5V)
            for _ in 0..8 {
                assert_eq!(ob_sim_step_frame(h, 0.002, 20, &mut t), 0);
            }
            assert!(ob_sim_get_node_voltage(h, 11) < 0.2);
            assert!(ob_sim_get_node_voltage(h, 12) > 4.8);
            assert!(ob_sim_get_node_voltage(h, 13) > 4.8);
            ob_sim_destroy(h);
        }
    }

    #[test]
    fn phase0_dc_op_scope_align_and_wordgen_u64() {
        unsafe {
            let h = ob_sim_create();
            assert_eq!(
                ob_sim_add_component(h, 1, 10, 1, 0, 0, 0, 5.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 2, 1, 1, 2, 0, 0, 1000.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 3, 1, 2, 0, 0, 0, 1000.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 4, 46, 10, 11, 12, 13, 100.0, 0.0, 5.0, 50.0, 0.0),
                0
            );
            // Step 0 (t=0..10ms) reads nibble 0 => high bits can test 64-bit MSB nibbles cleanly at step 15.
            assert_eq!(
                crate::ffi::ob_sim_set_wordgen_pattern(h, 4, 0xA000_0000_0000_0005),
                0
            );
            assert_eq!(crate::ffi::ob_sim_set_scope_probe(h, 0, 1), 0);
            assert_eq!(crate::ffi::ob_sim_set_scope_probe(h, 1, 2), 0);

            let mut t = 0.0;
            for _ in 0..10 {
                assert_eq!(ob_sim_step_frame(h, 0.001, 20, &mut t), 0);
            }
            let t_before = t;
            // Changing DC source and calling ob_sim_solve_dc_op preserves t_sim while updating V(2).
            assert_eq!(crate::ffi::ob_sim_set_control(h, 1, 0, 10.0), 0);
            assert_eq!(crate::ffi::ob_sim_solve_dc_op(h), 0);
            assert!((ob_sim_get_node_voltage(h, 2) - 5.0).abs() < 1e-3);
            let mut t_after = t_before;
            assert_eq!(ob_sim_step_frame(h, 0.001, 20, &mut t_after), 0);
            assert!(t_after > t_before);

            // Step 15 (t >= 0.15s) outputs top nibble 0xA = 0b1010 (MSB set without f64 truncation).
            for _ in 0..145 {
                assert_eq!(ob_sim_step_frame(h, 0.001, 20, &mut t_after), 0);
            }
            assert!(ob_sim_get_node_voltage(h, 10) > 4.5);
            assert!(ob_sim_get_node_voltage(h, 11) < 0.5);
            assert!(ob_sim_get_node_voltage(h, 12) > 4.5);
            assert!(ob_sim_get_node_voltage(h, 13) < 0.5);

            // Scope read across ch0 & ch1 returns matching sample timestamps.
            let mut t0 = vec![0.0_f64; 64];
            let mut v0 = vec![0.0_f64; 64];
            let mut t1 = vec![0.0_f64; 64];
            let mut v1 = vec![0.0_f64; 64];
            let n0 = ob_sim_read_scope(h, 0, t0.as_mut_ptr(), v0.as_mut_ptr(), 64);
            let n1 = ob_sim_read_scope(h, 1, t1.as_mut_ptr(), v1.as_mut_ptr(), 64);
            assert_eq!(n0, 64);
            assert_eq!(n1, 64);
            assert_eq!(t0, t1);
            ob_sim_destroy(h);
        }
    }

    #[test]
    fn phase1_sparse_lu_integrators_2branch_ccvs_and_analysis() {
        // 1. Sparse LU (> 48 nodes): 64-step resistor divider ladder from 10V -> linear drop
        let mut ladder = SimEngine::new();
        ladder.config.gmin = 0.0;
        ladder
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 10.0 }, &[1, GND]))
            .unwrap();
        for i in 1..=64u32 {
            let n_next = if i == 64 { GND } else { i + 1 };
            ladder
                .circuit
                .add(comp(
                    i + 1,
                    ComponentKind::Resistor { r: 100.0 },
                    &[i, n_next],
                ))
                .unwrap();
        }
        ladder.compile_and_dc().unwrap();
        assert!(
            (ladder.node_voltage(33) - 5.0).abs() < 1e-9,
            "v33={}",
            ladder.node_voltage(33)
        );

        // 2. Trapezoidal LC tank energy conservation & Gear-2 stability + UIC
        let mut lc = SimEngine::new();
        lc.config.integrator = crate::mna::engine::IntegratorKind::Trapezoidal;
        lc.config.uic = true;
        lc.circuit
            .add(comp(
                1,
                ComponentKind::Inductor {
                    l: 1e-3,
                    ic: Some(0.0),
                },
                &[1, GND],
            ))
            .unwrap();
        lc.circuit
            .add(comp(
                2,
                ComponentKind::Capacitor {
                    c: 1e-6,
                    ic: Some(5.0),
                },
                &[1, GND],
            ))
            .unwrap();
        lc.compile_and_dc().unwrap();
        for _ in 0..200 {
            lc.step_transient(1e-6).unwrap();
        }
        let v_peak_approx = lc.solution[0].abs();
        let i_ind = lc.component_current(1);
        // Normalized tank energy: C*V^2 + L*I^2 == C*(5V)^2 = 25 uJ (conserved by Trapezoidal!)
        let e_now = 1e-6 * v_peak_approx * v_peak_approx + 1e-3 * i_ind * i_ind;
        assert!((e_now - 25e-6).abs() < 1e-6, "LC energy drift: {e_now}");

        // Gear-2 on RC step
        let mut g2 = SimEngine::new();
        g2.config.integrator = crate::mna::engine::IntegratorKind::Gear2;
        g2.config.uic = true;
        g2.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        g2.circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, 2]))
            .unwrap();
        g2.circuit
            .add(comp(
                3,
                ComponentKind::Capacitor {
                    c: 1e-6,
                    ic: Some(0.0),
                },
                &[2, GND],
            ))
            .unwrap();
        g2.compile_and_dc().unwrap();
        for _ in 0..100 {
            g2.step_transient(1e-5).unwrap();
        }
        let expected = 5.0 * (1.0 - (-1.0_f64).exp());
        assert!(
            (g2.node_voltage(2) - expected).abs() < 0.015,
            "g2={}",
            g2.node_voltage(2)
        );

        // 3. True 2-branch CCVS (zero sense drop) + Monte Carlo + Transfer Function + Power + THD + 8-pin ex
        unsafe {
            let h = ob_sim_create();
            let pins1 = [1u32, 0];
            let p1 = [10.0_f64];
            assert_eq!(
                crate::ffi::ob_sim_add_component_ex(h, 1, 10, pins1.as_ptr(), 2, p1.as_ptr(), 1),
                0
            );
            let pins2 = [1u32, 2];
            let p2 = [500.0_f64]; // overload: 10V across 100Ohm? Wait: 10mA across 1000? Let's do 20mA -> 500Ohm = 0.2W, or 2 branch CCVS:
            assert_eq!(
                crate::ffi::ob_sim_add_component_ex(h, 2, 1, pins2.as_ptr(), 2, p2.as_ptr(), 1),
                0
            );
            // Ideal 0V CCVS sense on 2->0 (Rm=250): V(2) MUST be exact 0.0V (no 1mOhm error!), V(3) = 5.0V
            let pins3 = [3u32, 0, 2, 0];
            let p3 = [250.0_f64];
            assert_eq!(
                crate::ffi::ob_sim_add_component_ex(h, 3, 17, pins3.as_ptr(), 4, p3.as_ptr(), 1),
                0
            );
            assert_eq!(ob_sim_solve_dc(h), 0);
            assert!(
                ob_sim_get_node_voltage(h, 2).abs() < 1e-12,
                "non-ideal sense drop!"
            );
            assert!((ob_sim_get_node_voltage(h, 3) - 5.0).abs() < 1e-10);
            let cid = 2u32;
            let (mut ci, mut cp, mut cflags) = (0.0, 0.0, 0u8);
            assert_eq!(
                ob_sim_read_frame_state(
                    h,
                    std::ptr::null(),
                    0,
                    std::ptr::null_mut(),
                    &cid,
                    1,
                    &mut ci,
                    &mut cp,
                    &mut cflags,
                ),
                0
            );
            assert!((cp - 0.2).abs() < 1e-6);

            let (mut mn, mut mx, mut mean, mut std) = (0.0, 0.0, 0.0, 0.0);
            let mut samples = [0.0_f64; 32];
            assert_eq!(
                crate::ffi::ob_sim_monte_carlo_dc_ex(
                    h,
                    0.05,
                    32,
                    3,
                    0,
                    &mut mn,
                    &mut mx,
                    &mut mean,
                    &mut std,
                    samples.as_mut_ptr(),
                    samples.len(),
                ),
                32
            );
            assert!(mn <= mean && mean <= mx && std > 0.0);

            // Hann FFT on pure sine wave (fundamental bin dominates harmonics)
            let sine: Vec<f64> = (0..128)
                .map(|i| (2.0 * std::f64::consts::PI * 8.0 * i as f64 / 128.0).sin())
                .collect();
            let mags = compute_fft_magnitudes(&sine);
            assert!(
                mags[8] > 0.8 && mags[16] < 0.05,
                "mags[8]={} mags[16]={}",
                mags[8],
                mags[16]
            );

            ob_sim_destroy(h);
        }
    }

    #[test]
    fn phase2_devices_and_8pin_ics() {
        unsafe {
            let h = ob_sim_create();
            let add = |id: u32, t: i32, pins: &[u32], params: &[f64]| {
                assert_eq!(
                    crate::ffi::ob_sim_add_component_ex(
                        h,
                        id,
                        t,
                        pins.as_ptr(),
                        pins.len() as u32,
                        params.as_ptr(),
                        params.len() as u32,
                    ),
                    0
                );
            };

            // 1. Bridge rectifier + 7805 Voltage Regulator
            add(1, 10, &[1, 0], &[12.0]);
            add(2, 54, &[1, 0, 2, 0], &[1e-12, 1.5]); // ac1=12V, ac2=0V -> dc+ (~10.5V), dc-=GND
            add(3, 61, &[2, 0, 3], &[5.0, 0.2]); // 7805 out -> 5.0V
            add(4, 1, &[3, 0], &[100.0]);

            // 2. 8-pin Full Counter4Bit (73): CLK(node10), RST(0), EN(node11=5V), Q3..Q0(12..15), RCO(16)
            add(5, 36, &[10, 0], &[100.0, 5.0, 50.0]);
            add(6, 10, &[11, 0], &[5.0]);
            add(7, 73, &[10, 0, 11, 12, 13, 14, 15, 16], &[5.0, 50.0]);

            // 3. CenterTapTransformer (86): pri=(1,0), sec=(20,0,21), ratio=2 -> +12V / -12V
            add(8, 86, &[1, 0, 20, 0, 21], &[2.0]);
            add(9, 1, &[20, 0], &[1000.0]);
            add(10, 1, &[21, 0], &[1000.0]);

            // 4. 6-pin ADC4Bit (81) -> 6-pin DAC4Bit (82): 2.5V / 5.0V -> code 8 -> 2.5V out!
            add(11, 10, &[30, 0], &[2.5]);
            add(12, 81, &[30, 11, 31, 32, 33, 34], &[5.0, 5.0, 50.0]);
            add(13, 82, &[31, 32, 33, 34, 11, 35], &[5.0, 50.0]);

            assert_eq!(ob_sim_solve_dc(h), 0);
            assert!(
                (ob_sim_get_node_voltage(h, 3) - 5.0).abs() < 0.05,
                "vreg={}",
                ob_sim_get_node_voltage(h, 3)
            );
            assert!((ob_sim_get_node_voltage(h, 20) - 12.0).abs() < 0.05);
            assert!((ob_sim_get_node_voltage(h, 21) - (-12.0)).abs() < 0.05);
            assert!(
                (ob_sim_get_node_voltage(h, 35) - 2.5).abs() < 0.1,
                "dac={}",
                ob_sim_get_node_voltage(h, 35)
            );

            // Advance 8-pin Counter4Bit to t = 44ms (rising edges at 0, 10, 20, 30, 40ms -> 0b0101)
            let mut t = 0.0;
            for _ in 0..22 {
                assert_eq!(ob_sim_step_frame(h, 0.002, 20, &mut t), 0);
            }
            assert!(ob_sim_get_node_voltage(h, 12) < 0.5);
            assert!(ob_sim_get_node_voltage(h, 13) > 4.5);
            assert!(ob_sim_get_node_voltage(h, 14) < 0.5);
            assert!(ob_sim_get_node_voltage(h, 15) > 4.5);

            ob_sim_destroy(h);
        }
    }

    #[test]
    fn phase4_ffi_export_cir_matches_spice_io() {
        unsafe {
            let h = ob_sim_create();
            assert_eq!(
                ob_sim_add_component(h, 1, 10, 1, 0, 0, 0, 5.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            assert_eq!(
                ob_sim_add_component(h, 2, 1, 1, 0, 0, 0, 1000.0, 0.0, 0.0, 0.0, 0.0),
                0
            );
            let need = crate::ffi::ob_sim_export_cir(h, std::ptr::null_mut(), 0);
            assert!(need > 10);
            let mut buf = vec![0u8; need];
            let got = crate::ffi::ob_sim_export_cir(h, buf.as_mut_ptr(), buf.len());
            assert_eq!(got, need);
            let text = String::from_utf8(buf).unwrap();
            assert!(text.contains("V1 1 0 DC 5"));
            assert!(text.contains("R2 1 0 1000"));
            assert!(text.contains(".end"));
            ob_sim_destroy(h);
        }
    }

    #[test]
    fn phase2_ac_controls_currents_reachability_and_logic_min_len() {
        // 1. AC sweep with CoupledInductor + BridgeRectifier
        let mut eng = SimEngine::new();
        eng.circuit
            .add(comp(
                1,
                ComponentKind::AcVoltage {
                    amp: 10.0,
                    freq: 1000.0,
                    phase_deg: 0.0,
                    offset: 0.0,
                },
                &[1, GND],
            ))
            .unwrap();
        eng.circuit
            .add(comp(2, ComponentKind::Resistor { r: 100.0 }, &[1, 2]))
            .unwrap();
        eng.circuit
            .add(comp(
                3,
                ComponentKind::CoupledInductor {
                    l1: 1e-3,
                    l2: 1e-3,
                    k: 0.9,
                },
                &[2, GND, 3, GND],
            ))
            .unwrap();
        eng.circuit
            .add(comp(
                4,
                ComponentKind::BridgeRectifier {
                    is_sat: 1e-14,
                    n: 1.0,
                },
                &[3, GND, 4, GND],
            ))
            .unwrap();
        eng.circuit
            .add(comp(5, ComponentKind::Resistor { r: 1000.0 }, &[4, GND]))
            .unwrap();
        let ac = eng.solve_ac_sweep(100.0, 10_000.0, 3, 1, 4).unwrap();
        assert!(!ac.is_empty());
        assert!(ac.iter().all(|p| p.mag_db.is_finite()));

        // 2. Counter4BitFull set_control + GND-referenced DFlipFlop without extra load resistor
        let mut dff_eng = SimEngine::new();
        dff_eng
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        dff_eng
            .circuit
            .add(comp(
                2,
                ComponentKind::DFlipFlop {
                    v_high: 5.0,
                    r_out: 100.0,
                },
                &[1, 1, 2, 3],
            ))
            .unwrap();
        dff_eng
            .circuit
            .add(comp(
                3,
                ComponentKind::Counter4BitFull {
                    v_high: 5.0,
                    r_out: 100.0,
                },
                &[1, GND, 4, 5, 6, 7, 8, 9],
            ))
            .unwrap();
        dff_eng.compile_and_dc().unwrap();
        dff_eng.set_control(3, 0, 3.3).unwrap();
        dff_eng.set_control(3, 1, 50.0).unwrap();

        // 3. Phase 2 component_current (VoltageReg)
        let mut reg_eng = SimEngine::new();
        reg_eng
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 12.0 }, &[1, GND]))
            .unwrap();
        reg_eng
            .circuit
            .add(comp(
                2,
                ComponentKind::VoltageReg {
                    v_out: 5.0,
                    r_out: 0.1,
                },
                &[1, GND, 2],
            ))
            .unwrap();
        reg_eng
            .circuit
            .add(comp(3, ComponentKind::Resistor { r: 100.0 }, &[2, GND]))
            .unwrap();
        reg_eng.compile_and_dc().unwrap();
        let i_reg = reg_eng.component_current(2);
        assert!(i_reg > 0.04 && i_reg < 0.06, "i_reg={i_reg}");
        let p_reg = reg_eng.component_power(2);
        assert!(p_reg > 0.30 && p_reg < 0.40, "p_reg={p_reg}");

        // 4. VControlledSwitch + IControlledSwitch AC sweep & InstAmp / RelayDpdt currents
        let mut sw_eng = SimEngine::new();
        sw_eng
            .circuit
            .add(comp(
                1,
                ComponentKind::AcVoltage {
                    amp: 1.0,
                    freq: 100.0,
                    phase_deg: 0.0,
                    offset: 5.0,
                },
                &[1, GND],
            ))
            .unwrap();
        sw_eng
            .circuit
            .add(comp(
                2,
                ComponentKind::VControlledSwitch {
                    v_on: 2.0,
                    v_off: 1.0,
                    r_on: 10.0,
                    r_off: 1e6,
                },
                &[1, 2, 1, GND],
            ))
            .unwrap();
        sw_eng
            .circuit
            .add(comp(
                3,
                ComponentKind::IControlledSwitch {
                    i_on: 0.01,
                    i_off: 0.005,
                    r_on: 10.0,
                    r_off: 1e6,
                },
                &[2, 3, 1, 4],
            ))
            .unwrap();
        sw_eng
            .circuit
            .add(comp(4, ComponentKind::Resistor { r: 100.0 }, &[3, GND]))
            .unwrap();
        sw_eng
            .circuit
            .add(comp(5, ComponentKind::Resistor { r: 100.0 }, &[4, GND]))
            .unwrap();
        let sw_ac = sw_eng.solve_ac_sweep(10.0, 1000.0, 3, 1, 3).unwrap();
        assert!(!sw_ac.is_empty());
        assert!(sw_ac.iter().all(|p| p.mag_db.is_finite()));
        // Contact current (~5/(10+10+100) = 0.0417A), not sense loop current (0.05A)
        let i_sw = sw_eng.component_current(3);
        assert!(i_sw > 0.039 && i_sw < 0.044, "i_sw={i_sw}");

        // Hysteresis VControlledSwitch retains ON latch into (v_off, v_on) for AC sweep
        sw_eng.set_control(1, 3, 1.5).unwrap(); // DC offset = 1.5V in [1.0, 2.0]
        let sw_ac_hold = sw_eng.solve_ac_sweep(10.0, 1000.0, 3, 1, 3).unwrap();
        assert!(sw_ac_hold.last().unwrap().mag_db > -10.0);

        let mut dip_eng = SimEngine::new();
        dip_eng
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        dip_eng
            .circuit
            .add(comp(
                2,
                ComponentKind::DipSwitch4 {
                    mask: 0b0001,
                    r_on: 10.0,
                    r_off: 1e9,
                },
                &[1, 2, 1, 3, 1, 4, 1, 5],
            ))
            .unwrap();
        for (idx, n) in [(3, 2), (4, 3), (5, 4), (6, 5)] {
            dip_eng
                .circuit
                .add(comp(idx, ComponentKind::Resistor { r: 90.0 }, &[n, GND]))
                .unwrap();
        }
        dip_eng.compile_and_dc().unwrap();
        let i_dip = dip_eng.component_current(2);
        assert!((i_dip - 0.05).abs() < 1e-3, "i_dip={i_dip}");
        // Only switch 0 conducts (I=0.05A across 10 Ohm -> 0.025W), not 5V * 0.05A
        let p_dip = dip_eng.component_power(2);
        assert!((p_dip - 0.025).abs() < 1e-3, "p_dip={p_dip}");

        let mut ia_eng = SimEngine::new();
        ia_eng
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 1.0 }, &[1, GND]))
            .unwrap();
        ia_eng
            .circuit
            .add(comp(
                2,
                ComponentKind::InstAmp {
                    gain: 2.0,
                    v_sat_pos: 15.0,
                    v_sat_neg: -15.0,
                    r_out: 50.0,
                },
                &[1, GND, 2, GND],
            ))
            .unwrap();
        ia_eng
            .circuit
            .add(comp(3, ComponentKind::Resistor { r: 1000.0 }, &[2, GND]))
            .unwrap();
        ia_eng.compile_and_dc().unwrap();
        let vo_ia = ia_eng.node_voltage(2);
        let i_ia = ia_eng.component_current(2);
        assert!(
            (i_ia - vo_ia / 1000.0).abs() < 1e-4,
            "i_ia={i_ia}, vo/R={}",
            vo_ia / 1000.0
        );

        let mut dpdt_eng = SimEngine::new();
        dpdt_eng
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        dpdt_eng
            .circuit
            .add(comp(
                2,
                ComponentKind::RelayDpdt {
                    r_coil: 100.0,
                    v_pull: 3.0,
                    r_on: 1.0,
                    r_off: 1e9,
                },
                &[1, GND, 2, 3, 4, 1, 5, 6],
            ))
            .unwrap();
        dpdt_eng
            .circuit
            .add(comp(3, ComponentKind::Resistor { r: 10.0 }, &[6, GND]))
            .unwrap();
        dpdt_eng.compile_and_dc().unwrap();
        let i_dpdt = dpdt_eng.component_current(2);
        // Coil (5/100 = 0.05A) + pole-2 NO contact (5/(1+10) ≈ 0.4545A)
        assert!(i_dpdt > 0.45 && i_dpdt < 0.55, "i_dpdt={i_dpdt}");
        let p_dpdt = dpdt_eng.component_power(2);
        let exp_dpdt = 0.25 + (5.0 / 11.0_f64).powi(2) * 1.0;
        assert!(
            (p_dpdt - exp_dpdt).abs() < 1e-3,
            "p_dpdt={p_dpdt}, exp={exp_dpdt}"
        );

        let mut br_eng = SimEngine::new();
        br_eng
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 10.0 }, &[1, GND]))
            .unwrap();
        br_eng
            .circuit
            .add(comp(
                2,
                ComponentKind::BridgeRectifier {
                    is_sat: 1e-14,
                    n: 1.0,
                },
                &[1, GND, 2, 3],
            ))
            .unwrap();
        br_eng
            .circuit
            .add(comp(3, ComponentKind::Resistor { r: 1000.0 }, &[2, 3]))
            .unwrap();
        br_eng.compile_and_dc().unwrap();
        let p_br = br_eng.component_power(2);
        assert!(p_br > 0.008 && p_br < 0.025, "p_br={p_br}");

        // 5. ob_logic_minimize_ex overflow length query
        unsafe {
            let outs = [0u8, 1, 1, 0];
            let need = ob_logic_minimize_ex(2, outs.as_ptr(), outs.len(), std::ptr::null_mut(), 0);
            assert!(need >= 3, "need={need}");
            let mut small = [0u8; 1];
            let full = ob_logic_minimize_ex(
                2,
                outs.as_ptr(),
                outs.len(),
                small.as_mut_ptr(),
                small.len(),
            );
            assert_eq!(full, need);
        }
    }

    #[test]
    fn phase2_untested_devices_and_tf_fault() {
        // 1. Diac current matches MNA conductance stamp
        let mut diac_eng = SimEngine::new();
        diac_eng
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 50.0 }, &[1, GND]))
            .unwrap();
        diac_eng
            .circuit
            .add(comp(
                2,
                ComponentKind::Diac {
                    v_bo: 30.0,
                    r_on: 10.0,
                    r_off: 1e8,
                },
                &[1, 2],
            ))
            .unwrap();
        diac_eng
            .circuit
            .add(comp(3, ComponentKind::Resistor { r: 90.0 }, &[2, GND]))
            .unwrap();
        diac_eng.compile_and_dc().unwrap();
        assert!((diac_eng.node_voltage(2) - 18.0).abs() < 1e-3);
        assert!(
            (diac_eng.component_current(2) - 0.2).abs() < 1e-3,
            "i_diac={}",
            diac_eng.component_current(2)
        );

        // 3. SCR, Triac, PulseVoltage, PwlSource, Crystal, DcMotor, Vco, SampleHold, DigitalGateMulti
        let mut p2 = SimEngine::new();
        p2.circuit
            .add(comp(
                1,
                ComponentKind::PulseVoltage {
                    v1: 0.0,
                    v2: 5.0,
                    td: 0.0,
                    tr: 1e-6,
                    tf: 1e-6,
                    pw: 5e-4,
                    per: 1e-3,
                },
                &[1, GND],
            ))
            .unwrap();
        p2.circuit
            .add(comp(
                2,
                ComponentKind::PwlSource {
                    pts: [[0.0, 0.0], [1e-3, 4.0], [2e-3, 4.0], [3e-3, 0.0]],
                    count: 2,
                },
                &[2, GND],
            ))
            .unwrap();
        p2.circuit
            .add(comp(3, ComponentKind::DcVoltage { v: 12.0 }, &[3, GND]))
            .unwrap();
        p2.circuit
            .add(comp(
                4,
                ComponentKind::Scr {
                    i_hold: 0.005,
                    v_bo: 100.0,
                    r_on: 0.2,
                    r_off: 1e8,
                },
                &[3, 4, 1],
            ))
            .unwrap();
        p2.circuit
            .add(comp(5, ComponentKind::Resistor { r: 100.0 }, &[4, GND]))
            .unwrap();
        p2.circuit
            .add(comp(
                6,
                ComponentKind::Triac {
                    i_hold: 0.005,
                    v_bo: 100.0,
                    r_on: 0.2,
                    r_off: 1e8,
                },
                &[3, 5, 1],
            ))
            .unwrap();
        p2.circuit
            .add(comp(7, ComponentKind::Resistor { r: 100.0 }, &[5, GND]))
            .unwrap();
        p2.circuit
            .add(comp(
                8,
                ComponentKind::SampleHold {
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[2, 1, 6],
            ))
            .unwrap();
        p2.circuit
            .add(comp(
                9,
                ComponentKind::Vco {
                    f0: 500.0,
                    df_dv: 100.0,
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[2, 7],
            ))
            .unwrap();
        p2.circuit
            .add(comp(
                10,
                ComponentKind::Crystal {
                    rm: 50.0,
                    lm: 1e-2,
                    cm: 1e-13,
                    c0: 5e-12,
                },
                &[1, 8],
            ))
            .unwrap();
        p2.circuit
            .add(comp(11, ComponentKind::Resistor { r: 1000.0 }, &[8, GND]))
            .unwrap();
        p2.circuit
            .add(comp(
                12,
                ComponentKind::DcMotor { r_a: 5.0, ke: 0.1 },
                &[3, GND],
            ))
            .unwrap();
        p2.circuit
            .add(comp(
                13,
                ComponentKind::DigitalGateMulti {
                    kind: GateKind::And,
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, 1, 3, 9],
            ))
            .unwrap();
        p2.compile_and_dc().unwrap();
        for _ in 0..10 {
            p2.step_transient(2.5e-5).unwrap();
        }
        assert!(p2.node_voltage(1) > 4.5, "pulse v={}", p2.node_voltage(1));
        assert!(p2.node_voltage(2) > 0.5, "pwl v={}", p2.node_voltage(2));
        assert!(p2.node_voltage(4) > 10.0, "scr v={}", p2.node_voltage(4));
        assert!(p2.node_voltage(5) > 10.0, "triac v={}", p2.node_voltage(5));
        assert!(p2.node_voltage(9) > 4.5, "gate3 v={}", p2.node_voltage(9));
        assert!(p2.node_voltage(8).is_finite());
        assert!(p2.component_current(12) > 0.5);
        assert!(p2.node_voltage(7) >= 0.0);
        assert!(p2.node_voltage(6).is_finite());
    }

    #[test]
    fn audit_fixes_2branch_faults_pjfet_current_and_schmitt_dc() {
        // 1. Open and Short faults on 2-branch components must not produce SingularMatrix.
        for kind in [
            ComponentKind::Ccvs { rm: 100.0 },
            ComponentKind::CoupledInductor {
                l1: 1e-3,
                l2: 1e-3,
                k: 0.9,
            },
            ComponentKind::CenterTapTransformer { ratio: 2.0 },
        ] {
            let mut eng = SimEngine::new();
            eng.circuit
                .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
                .unwrap();
            eng.circuit
                .add(comp(4, ComponentKind::Resistor { r: 100.0 }, &[1, 10]))
                .unwrap();
            let pins: &[u32] = if matches!(kind, ComponentKind::CenterTapTransformer { .. }) {
                &[10, GND, 2, 3, GND]
            } else {
                &[10, GND, 2, GND]
            };
            eng.circuit.add(comp(2, kind, pins)).unwrap();
            eng.circuit
                .add(comp(3, ComponentKind::Resistor { r: 1000.0 }, &[2, GND]))
                .unwrap();
            if pins.len() == 5 {
                eng.circuit
                    .add(comp(5, ComponentKind::Resistor { r: 1000.0 }, &[3, GND]))
                    .unwrap();
            }
            for fault in [FaultKind::Open, FaultKind::Short] {
                eng.set_fault(2, fault).unwrap();
                eng.compile_and_dc().unwrap();
                eng.step_transient(1e-4).unwrap();
                let ac = eng.solve_ac_sweep(100.0, 1000.0, 2, 1, 2).unwrap();
                assert!(!ac.is_empty());
            }
        }

        // 2. P-JFET component_current agrees with MNA drain current for depletion vto < 0.
        let mut pj = SimEngine::new();
        pj.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        pj.circuit
            .add(comp(
                2,
                ComponentKind::Pjfet {
                    beta: 1e-3,
                    vto: -2.0,
                    lambda: 0.0,
                },
                &[2, 1, 1],
            ))
            .unwrap();
        pj.circuit
            .add(comp(3, ComponentKind::Resistor { r: 100.0 }, &[2, GND]))
            .unwrap();
        pj.compile_and_dc().unwrap();
        let i_load = pj.node_voltage(2) / 100.0;
        let i_pj = pj.component_current(2);
        assert!(i_load > 1e-3, "expected P-JFET conducting, i_load={i_load}");
        assert!(
            (i_pj.abs() - i_load).abs() < 1e-3,
            "i_pj={i_pj}, i_load={i_load}"
        );

        // 3. SchmittTrigger DC OP honors negative input below -v_hyst.
        let mut st = SimEngine::new();
        st.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: -5.0 }, &[1, GND]))
            .unwrap();
        st.circuit
            .add(comp(
                2,
                ComponentKind::SchmittTrigger {
                    v_hyst: 0.5,
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, GND, 2],
            ))
            .unwrap();
        st.compile_and_dc().unwrap();
        assert!(
            st.node_voltage(2) < 0.1,
            "expected Schmitt output low on -5V input, got {}",
            st.node_voltage(2)
        );

        // 4. IGBT component_current matches MNA load current in conduction.
        let mut ig = SimEngine::new();
        ig.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 10.0 }, &[1, GND]))
            .unwrap();
        ig.circuit
            .add(comp(2, ComponentKind::DcVoltage { v: 6.0 }, &[2, GND]))
            .unwrap();
        ig.circuit
            .add(comp(
                3,
                ComponentKind::Igbt {
                    kp: 2.0,
                    vth: 4.0,
                    r_on: 0.2,
                },
                &[3, 2, GND],
            ))
            .unwrap();
        ig.circuit
            .add(comp(4, ComponentKind::Resistor { r: 1.8 }, &[1, 3]))
            .unwrap();
        ig.compile_and_dc().unwrap();
        let i_ig_load = (10.0 - ig.node_voltage(3)) / 1.8;
        let i_ig = ig.component_current(3);
        assert!(
            (i_ig - i_ig_load).abs() < 1e-3,
            "i_ig={i_ig}, i_ig_load={i_ig_load}"
        );
    }

    #[test]
    fn tier1_reactive_single_step_ac_guard_and_ffi_params() {
        // 1. Reactive history advances by 1*dt (not 2*dt) on digital toggle steps.
        let mut sim = SimEngine::new();
        sim.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        sim.circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, 2]))
            .unwrap();
        sim.circuit
            .add(comp(
                3,
                ComponentKind::Capacitor {
                    c: 1e-6,
                    ic: Some(0.0),
                },
                &[2, GND],
            ))
            .unwrap();
        sim.circuit
            .add(comp(
                4,
                ComponentKind::ClockSource {
                    freq: 500.0,
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[3, GND],
            ))
            .unwrap();
        sim.circuit
            .add(comp(
                5,
                ComponentKind::DFlipFlop {
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, 3, 4, 5],
            ))
            .unwrap();
        sim.compile_and_dc().unwrap();
        sim.step_transient(1e-4).unwrap();
        let v_c = sim.node_voltage(2);
        // Expected 1-step Backward Euler: 5 * (dt / (RC + dt)) = 5 * (0.1/1.1) ~= 0.4545V (double-step would give ~0.868V)
        assert!(
            (v_c - 5.0 * (1e-4 / 1.1e-3)).abs() < 0.05,
            "expected single-step RC voltage ~0.455V on DFF edge, got {v_c}"
        );

        // 2. Non-finite AC stop frequency returns InvalidParameter instead of OOM/panic.
        let err = sim
            .solve_ac_sweep(10.0, f64::INFINITY, 20, 1, 2)
            .unwrap_err();
        assert_eq!(err.code, SimErrorCode::InvalidParameter);

        // 3. Single-supply OpAmp preserves v_sat_neg=0.0 and Capacitor omits ic when only 1 param passed.
        unsafe {
            let h = ob_sim_create();
            let p_dc = [1u32, 0];
            let v_dc = [-5.0f64];
            assert_eq!(
                crate::ffi::ob_sim_add_component_ex(h, 1, 10, p_dc.as_ptr(), 2, v_dc.as_ptr(), 1),
                0
            );
            let p_r1 = [1u32, 2];
            let v_r1 = [1000.0f64];
            assert_eq!(
                crate::ffi::ob_sim_add_component_ex(h, 2, 1, p_r1.as_ptr(), 2, v_r1.as_ptr(), 1),
                0
            );
            let p_r2 = [2u32, 3];
            assert_eq!(
                crate::ffi::ob_sim_add_component_ex(h, 3, 1, p_r2.as_ptr(), 2, v_r1.as_ptr(), 1),
                0
            );
            // Single-supply OpAmp (0..5V) inverting +5V input tries to swing positive -> rails at +5V,
            // while +5V input clamping negative tries to go below 0V -> must clamp at 0.0V (not -15V).
            let p_op = [0u32, 2, 3];
            let v_op = [1e5, 5.0, 0.0, 50.0];
            assert_eq!(
                crate::ffi::ob_sim_add_component_ex(h, 4, 22, p_op.as_ptr(), 3, v_op.as_ptr(), 4),
                0
            );
            // Flip input source to +5V so inverting output hits negative rail (0.0V)
            assert_eq!(crate::ffi::ob_sim_set_control(h, 1, 0, 5.0), 0);
            assert_eq!(ob_sim_solve_dc(h), 0);
            let v_out = ob_sim_get_node_voltage(h, 3);
            let expected_clamp = 5.0 * 50.0 / 2050.0;
            assert!(
                (v_out - expected_clamp).abs() < 1e-4,
                "expected single-supply 0V clamp (~{expected_clamp}V with 50ohm r_out), got {v_out}"
            );

            // Capacitor with 1 param keeps DC OP voltage on first transient step (ic = None).
            let hc = ob_sim_create();
            let pv = [1u32, 0];
            let vv = [5.0f64];
            assert_eq!(
                crate::ffi::ob_sim_add_component_ex(hc, 1, 10, pv.as_ptr(), 2, vv.as_ptr(), 1),
                0
            );
            let pr = [1u32, 2];
            assert_eq!(
                crate::ffi::ob_sim_add_component_ex(hc, 2, 1, pr.as_ptr(), 2, v_r1.as_ptr(), 1),
                0
            );
            let pc = [2u32, 0];
            let vc = [1e-6f64];
            assert_eq!(
                crate::ffi::ob_sim_add_component_ex(hc, 3, 3, pc.as_ptr(), 2, vc.as_ptr(), 1),
                0
            );
            assert_eq!(ob_sim_solve_dc(hc), 0);
            let mut t = 0.0;
            assert_eq!(ob_sim_step_frame(hc, 1e-4, 10, &mut t), 0);
            assert!((ob_sim_get_node_voltage(hc, 2) - 5.0).abs() < 1e-6);

            ob_sim_destroy(h);
            ob_sim_destroy(hc);
        }
    }

    #[test]
    fn tier2a_physics_jacobians_topology_and_dsp() {
        use crate::ffi::{
            ob_logic_minimize_ex, ob_sim_add_component_ex, ob_sim_measure_diode,
            ob_sim_measure_resistance, ob_sim_read_frame_state, ob_sim_read_logic,
            ob_sim_set_logic_probes,
        };
        use crate::instruments::ScopeBuffer;

        // 1. VoltageReg Vin load draw KCL + dropout
        let mut reg = SimEngine::new();
        reg.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 9.0 }, &[1, GND]))
            .unwrap();
        reg.circuit
            .add(comp(
                2,
                ComponentKind::VoltageReg {
                    v_out: 5.0,
                    r_out: 0.1,
                },
                &[1, GND, 2],
            ))
            .unwrap();
        reg.circuit
            .add(comp(3, ComponentKind::Resistor { r: 100.0 }, &[2, GND]))
            .unwrap();
        reg.compile_and_dc().unwrap();
        let i_vin = reg.component_current(1);
        let i_load = reg.component_current(3);
        assert!(
            i_vin.abs() > 0.04 && (i_vin.abs() - i_load.abs()).abs() < 0.01,
            "i_vin={i_vin}, i_load={i_load}"
        );

        // 1b. VoltageReg with ungrounded GND pin must fail with FloatingNode
        let mut reg_float = SimEngine::new();
        reg_float
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 9.0 }, &[1, GND]))
            .unwrap();
        reg_float
            .circuit
            .add(comp(
                2,
                ComponentKind::VoltageReg {
                    v_out: 5.0,
                    r_out: 0.1,
                },
                &[1, 99, 2],
            ))
            .unwrap();
        reg_float
            .circuit
            .add(comp(3, ComponentKind::Resistor { r: 100.0 }, &[2, GND]))
            .unwrap();
        let err = reg_float.compile_and_dc().unwrap_err();
        assert_eq!(err.code, crate::error::SimErrorCode::FloatingNode);
        assert_eq!(err.detail_id, 99);

        // 2. Igbt + AnalogMultiplier AC gain + ComparatorOc High-Z pull-up
        let mut ac_dev = SimEngine::new();
        ac_dev
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 12.0 }, &[1, GND]))
            .unwrap();
        ac_dev
            .circuit
            .add(comp(2, ComponentKind::DcVoltage { v: 3.5 }, &[2, GND]))
            .unwrap();
        ac_dev
            .circuit
            .add(comp(3, ComponentKind::Resistor { r: 10.0 }, &[1, 3]))
            .unwrap();
        ac_dev
            .circuit
            .add(comp(
                4,
                ComponentKind::Igbt {
                    kp: 1.0,
                    vth: 3.0,
                    r_on: 0.2,
                },
                &[3, 2, GND],
            ))
            .unwrap();
        ac_dev.compile_and_dc().unwrap();
        let ac_igbt = ac_dev.solve_ac_sweep(100.0, 1000.0, 2, 2, 3).unwrap();
        assert!(
            ac_igbt[0].mag_db > 0.0,
            "igbt AC gain {}",
            ac_igbt[0].mag_db
        );

        let mut mul = SimEngine::new();
        mul.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 2.0 }, &[1, GND]))
            .unwrap();
        mul.circuit
            .add(comp(2, ComponentKind::DcVoltage { v: 3.0 }, &[2, GND]))
            .unwrap();
        mul.circuit
            .add(comp(
                3,
                ComponentKind::AnalogMultiplier {
                    gain: 0.5,
                    r_out: 10.0,
                },
                &[1, 2, 3],
            ))
            .unwrap();
        mul.circuit
            .add(comp(4, ComponentKind::Resistor { r: 1e4 }, &[3, GND]))
            .unwrap();
        mul.compile_and_dc().unwrap();
        let ac_mul = mul.solve_ac_sweep(100.0, 1000.0, 2, 1, 3).unwrap();
        // v_y = 3, gain = 0.5 => dv_out/dv_x = 1.5 (~+3.5 dB)
        assert!(
            ac_mul[0].mag_db > 0.0,
            "multiplier AC gain {}",
            ac_mul[0].mag_db
        );

        let mut cmp = SimEngine::new();
        cmp.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 3.0 }, &[1, GND]))
            .unwrap();
        cmp.circuit
            .add(comp(2, ComponentKind::DcVoltage { v: 1.0 }, &[2, GND]))
            .unwrap();
        cmp.circuit
            .add(comp(3, ComponentKind::DcVoltage { v: 10.0 }, &[4, GND]))
            .unwrap();
        cmp.circuit
            .add(comp(4, ComponentKind::Resistor { r: 1000.0 }, &[4, 3]))
            .unwrap();
        cmp.circuit
            .add(comp(
                5,
                ComponentKind::ComparatorOc { r_ol: 1000.0 },
                &[1, 2, 3],
            ))
            .unwrap();
        cmp.compile_and_dc().unwrap();
        // Open-collector HIGH is true High-Z, so 10V pull-up holds pin 3 at ~10V (not 5V!).
        assert!(
            cmp.node_voltage(3) > 9.5,
            "oc high should be pulled to 10V, got {}",
            cmp.node_voltage(3)
        );

        // 3. VaractorDiode C(V) dependence via FFI 94
        unsafe {
            let hv1 = ob_sim_create();
            let hv2 = ob_sim_create();
            for (h, vb) in [(hv1, -0.5), (hv2, -8.0)] {
                let ps = [1u32, 0];
                let vs = [vb];
                assert_eq!(
                    ob_sim_add_component_ex(h, 1, 10, ps.as_ptr(), 2, vs.as_ptr(), 1),
                    0
                );
                let pr = [1u32, 2];
                let vr = [1000.0];
                assert_eq!(
                    ob_sim_add_component_ex(h, 2, 1, pr.as_ptr(), 2, vr.as_ptr(), 1),
                    0
                );
                let pv = [2u32, 0];
                let vv = [100e-12, 0.7, 0.5, 1e-12];
                assert_eq!(
                    ob_sim_add_component_ex(h, 3, 94, pv.as_ptr(), 2, vv.as_ptr(), 4),
                    0
                );
                assert_eq!(ob_sim_solve_dc(h), 0);
            }
            let mut f1 = [0.0; 4];
            let mut m1 = [0.0; 4];
            let mut p1 = [0.0; 4];
            let mut f2 = [0.0; 4];
            let mut m2 = [0.0; 4];
            let mut p2 = [0.0; 4];
            assert!(
                ob_sim_ac_sweep_transfer(
                    hv1,
                    1e6,
                    2e6,
                    2,
                    1,
                    -1,
                    2,
                    f1.as_mut_ptr(),
                    m1.as_mut_ptr(),
                    p1.as_mut_ptr(),
                    4
                ) >= 1
            );
            assert!(
                ob_sim_ac_sweep_transfer(
                    hv2,
                    1e6,
                    2e6,
                    2,
                    1,
                    -1,
                    2,
                    f2.as_mut_ptr(),
                    m2.as_mut_ptr(),
                    p2.as_mut_ptr(),
                    4
                ) >= 1
            );
            // Larger reverse bias (-8V) yields lower Cj -> higher magnitude (less attenuation) at 1 MHz.
            assert!(
                m2[0] > m1[0] + 0.5,
                "varactor m2(-8V)={} should exceed m1(-0.5V)={}",
                m2[0],
                m1[0]
            );
            ob_sim_destroy(hv1);
            ob_sim_destroy(hv2);
        }

        // 4. eval_diode_vt high-current linear continuation + 1.8V DigitalGate + Crystal Trap + SCR DC latch
        let mut hd = SimEngine::new();
        hd.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 100.0 }, &[1, GND]))
            .unwrap();
        hd.circuit
            .add(comp(2, ComponentKind::Resistor { r: 10.0 }, &[1, 2]))
            .unwrap();
        hd.circuit
            .add(comp(
                3,
                ComponentKind::Diode {
                    is_sat: 1e-14,
                    n: 1.0,
                    bv: f64::INFINITY,
                },
                &[2, GND],
            ))
            .unwrap();
        hd.compile_and_dc().unwrap();
        assert!(hd.node_voltage(2).is_finite() && hd.component_current(3) > 5.0);

        let mut lv = SimEngine::new();
        lv.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 1.4 }, &[1, GND]))
            .unwrap();
        lv.circuit
            .add(comp(
                2,
                ComponentKind::DigitalGate {
                    kind: GateKind::Not,
                    v_high: 1.8,
                    r_out: 50.0,
                },
                &[1, 2],
            ))
            .unwrap();
        lv.compile_and_dc().unwrap();
        assert!(
            lv.node_voltage(2) < 0.2,
            "1.8V gate failed 1.4V HIGH input: {}",
            lv.node_voltage(2)
        );

        let mut xt = SimEngine::new();
        xt.circuit
            .add(comp(
                1,
                ComponentKind::AcVoltage {
                    amp: 1.0,
                    freq: 1000.0,
                    phase_deg: 0.0,
                    offset: 0.0,
                },
                &[1, GND],
            ))
            .unwrap();
        xt.circuit
            .add(comp(2, ComponentKind::Resistor { r: 100.0 }, &[1, 2]))
            .unwrap();
        xt.circuit
            .add(comp(
                3,
                ComponentKind::Crystal {
                    rm: 20.0,
                    lm: 0.1,
                    cm: 1e-7,
                    c0: 1e-9,
                },
                &[2, GND],
            ))
            .unwrap();
        xt.compile_and_dc().unwrap();
        xt.step_transient(1e-5).unwrap();
        assert!(xt.node_voltage(2).is_finite());

        let mut scr = SimEngine::new();
        scr.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 10.0 }, &[1, GND]))
            .unwrap();
        scr.circuit
            .add(comp(2, ComponentKind::Resistor { r: 100.0 }, &[1, 2]))
            .unwrap();
        scr.circuit
            .add(comp(3, ComponentKind::DcVoltage { v: 3.0 }, &[3, GND]))
            .unwrap();
        scr.circuit
            .add(comp(4, ComponentKind::Resistor { r: 100.0 }, &[3, 4]))
            .unwrap();
        scr.circuit
            .add(comp(
                5,
                ComponentKind::Scr {
                    i_hold: 0.005,
                    v_bo: 50.0,
                    r_on: 0.5,
                    r_off: 1e8,
                },
                &[2, GND, 4],
            ))
            .unwrap();
        scr.compile_and_dc().unwrap();
        assert!(
            scr.node_voltage(2) < 0.5,
            "SCR should latch ON at DC OP: {}",
            scr.node_voltage(2)
        );

        // 5. Adc4Bit / Dac4Bit external 2.5V Vref
        let mut adc_dac = SimEngine::new();
        adc_dac
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 1.25 }, &[1, GND]))
            .unwrap();
        adc_dac
            .circuit
            .add(comp(2, ComponentKind::DcVoltage { v: 2.5 }, &[2, GND]))
            .unwrap();
        adc_dac
            .circuit
            .add(comp(
                3,
                ComponentKind::Adc4Bit {
                    v_ref: 5.0,
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, 2, 10, 11, 12, 13],
            ))
            .unwrap();
        adc_dac
            .circuit
            .add(comp(
                4,
                ComponentKind::Dac4Bit {
                    v_ref: 5.0,
                    r_out: 50.0,
                },
                &[10, 11, 12, 13, 2, 3],
            ))
            .unwrap();
        adc_dac.compile_and_dc().unwrap();
        assert!(
            (adc_dac.node_voltage(3) - 1.333).abs() < 0.25,
            "external Vref DAC={}",
            adc_dac.node_voltage(3)
        );

        // 6. THD bin-1 pure sine < 1% & uniform-dt resampling + solve_ac_sweep preserves state
        let mut sb = ScopeBuffer::new(512);
        let n_samp = 256;
        for i in 0..n_samp {
            // Non-uniform jittery dt sampling of a pure bin-4 sinewave
            let t = i as f64 * 1e-4 + if i % 2 == 0 { 0.0 } else { 2e-5 };
            let s = (2.0 * std::f64::consts::PI * 4.0 * (t / (n_samp as f64 * 1e-4))).sin();
            sb.push(t, [s, 0.0, 0.0, 0.0]);
        }
        let uni = sb.resample_uniform(0, 256);
        let mags = compute_fft_magnitudes(&uni);
        assert!(mags[4] > 0.8 && mags[8] < 0.05, "mags[4]={}", mags[4]);

        let bin1: Vec<f64> = (0..128)
            .map(|i| (2.0 * std::f64::consts::PI * i as f64 / 128.0).sin())
            .collect();
        let m_bin1 = compute_fft_magnitudes(&bin1);
        assert!(
            m_bin1[1] > 0.8 && m_bin1[3] < 0.1,
            "m_bin1[1]={} m_bin1[3]={}",
            m_bin1[1],
            m_bin1[3]
        );

        // 7. Topology checks: isolated secondary FloatingNode + V-loop + I-cutset
        let mut iso = SimEngine::new();
        iso.circuit
            .add(comp(
                1,
                ComponentKind::AcVoltage {
                    amp: 5.0,
                    freq: 50.0,
                    phase_deg: 0.0,
                    offset: 0.0,
                },
                &[1, GND],
            ))
            .unwrap();
        iso.circuit
            .add(comp(
                2,
                ComponentKind::Transformer { ratio: 1.0 },
                &[1, GND, 2, 3],
            ))
            .unwrap();
        iso.circuit
            .add(comp(3, ComponentKind::Resistor { r: 100.0 }, &[2, 3]))
            .unwrap();
        assert_eq!(
            iso.compile_and_dc().unwrap_err().code,
            SimErrorCode::FloatingNode
        );

        let mut vloop = SimEngine::new();
        vloop
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        vloop
            .circuit
            .add(comp(2, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        assert_eq!(
            vloop.compile_and_dc().unwrap_err().code,
            SimErrorCode::SingularMatrix
        );

        let mut icut = SimEngine::new();
        icut.circuit
            .add(comp(1, ComponentKind::DcCurrent { i: 0.1 }, &[1, GND]))
            .unwrap();
        icut.circuit
            .add(comp(2, ComponentKind::DcCurrent { i: 0.1 }, &[1, 2]))
            .unwrap();
        icut.circuit
            .add(comp(3, ComponentKind::Resistor { r: 100.0 }, &[2, GND]))
            .unwrap();
        assert_eq!(
            icut.compile_and_dc().unwrap_err().code,
            SimErrorCode::SingularMatrix
        );

        // 8. Ohmmeter, Diode tester, 8-var Don't-Care minimizer, logic probes, config, fuse check
        unsafe {
            let hm = ob_sim_create();
            let pr1 = [1u32, 0];
            let vr = [1000.0];
            assert_eq!(
                ob_sim_add_component_ex(hm, 1, 1, pr1.as_ptr(), 2, vr.as_ptr(), 1),
                0
            );
            assert_eq!(
                ob_sim_add_component_ex(hm, 2, 1, pr1.as_ptr(), 2, vr.as_ptr(), 1),
                0
            );
            let mut ohms = 0.0;
            assert_eq!(ob_sim_measure_resistance(hm, 1, 0, &mut ohms), 0);
            assert!((ohms - 500.0).abs() < 1.0, "parallel 1k||1k={ohms}");
            ob_sim_destroy(hm);

            let hdio = ob_sim_create();
            let pv = [2u32, 0];
            let vv = [5.0];
            assert_eq!(
                ob_sim_add_component_ex(hdio, 1, 10, pv.as_ptr(), 2, vv.as_ptr(), 1),
                0
            );
            let pd = [1u32, 0];
            let vd = [1e-14, 1.0];
            assert_eq!(
                ob_sim_add_component_ex(hdio, 2, 20, pd.as_ptr(), 2, vd.as_ptr(), 2),
                0
            );
            let mut vf = 0.0;
            assert_eq!(ob_sim_measure_diode(hdio, 1, 0, &mut vf), 0);
            assert!(vf > 0.5 && vf < 0.8, "diode forward drop={vf}");
            assert_eq!(ob_sim_measure_diode(hdio, 0, 1, &mut vf), 0);
            assert!(
                vf.is_infinite(),
                "reverse diode should report Open/inf, got {vf}"
            );
            let lp = [1i32, 2];
            assert_eq!(ob_sim_set_logic_probes(hdio, lp.as_ptr(), 2, 1.8), 0);
            let mut t = 0.0;
            assert_eq!(ob_sim_step_frame(hdio, 1e-4, 4, &mut t), 0);
            let mut lt = [0.0f64; 8];
            let mut lm = [0u16; 8];
            assert!(ob_sim_read_logic(hdio, lt.as_mut_ptr(), lm.as_mut_ptr(), 8) >= 1);
            let cids = [99u32];
            let (mut ci, mut cp, mut cflags) = ([0.0f64], [0.0f64], [0u8]);
            assert_eq!(
                ob_sim_read_frame_state(
                    hdio,
                    std::ptr::null(),
                    0,
                    std::ptr::null_mut(),
                    cids.as_ptr(),
                    1,
                    ci.as_mut_ptr(),
                    cp.as_mut_ptr(),
                    cflags.as_mut_ptr(),
                ),
                0
            );
            assert_eq!(cflags[0] & 2, 0);
            ob_sim_destroy(hdio);

            // 8-var Don't-Care minimizer: minterms with bit7=1, Don't-Care on bit6=1
            let mut tt = [0u8; 256];
            for (idx, cell) in tt.iter_mut().enumerate() {
                *cell = if idx >= 128 {
                    1
                } else if idx >= 64 {
                    2
                } else {
                    0
                };
            }
            let mut buf = [0u8; 128];
            let len = ob_logic_minimize_ex(8, tt.as_ptr(), 256, buf.as_mut_ptr(), 128);
            assert!(len > 0);
            let expr = std::str::from_utf8(&buf[..len.min(128)]).unwrap();
            assert!(!expr.is_empty() && expr != "0", "8-var expr={expr}");
        }
    }

    #[test]
    fn ac_sweep_sparse_lu_over_48_nodes() {
        let mut sim = SimEngine::new();
        let mut id = 1u32;
        sim.circuit
            .add(comp(
                id,
                ComponentKind::AcVoltage {
                    amp: 1.0,
                    freq: 100.0,
                    phase_deg: 0.0,
                    offset: 0.0,
                },
                &[1, GND],
            ))
            .unwrap();
        id += 1;
        for node in 1u32..=51 {
            sim.circuit
                .add(comp(
                    id,
                    ComponentKind::Resistor { r: 100.0 },
                    &[node, node + 1],
                ))
                .unwrap();
            id += 1;
            sim.circuit
                .add(comp(
                    id,
                    ComponentKind::Capacitor { c: 1e-6, ic: None },
                    &[node + 1, GND],
                ))
                .unwrap();
            id += 1;
        }
        sim.compile_and_dc().unwrap();
        let ac = sim.solve_ac_sweep(10.0, 10000.0, 2, 1, 52).unwrap();
        assert_eq!(ac.len(), 7);
        assert!(ac.iter().all(|p| p.mag_db.is_finite()));
        let last = ac.last().unwrap().mag_db;
        assert!(
            last < ac[0].mag_db,
            "expected low-pass attenuation: f_low={} f_high={last}",
            ac[0].mag_db,
        );
    }

    #[test]
    fn zener_breakdown_pnp_pmos_njfet_and_diac_ac_zero_crossing() {
        // Zener reverse breakdown (bv = 5.1)
        let mut zener = SimEngine::new();
        zener
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: -10.0 }, &[1, GND]))
            .unwrap();
        zener
            .circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, 2]))
            .unwrap();
        zener
            .circuit
            .add(comp(
                3,
                ComponentKind::Diode {
                    is_sat: 1e-14,
                    n: 1.0,
                    bv: 5.1,
                },
                &[2, GND],
            ))
            .unwrap();
        zener.compile_and_dc().unwrap();
        let vz = zener.node_voltage(2);
        assert!((vz + 5.1).abs() < 1.0, "zener clamp={vz}");

        // PNP BJT
        let mut pnp = SimEngine::new();
        pnp.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        pnp.circuit
            .add(comp(2, ComponentKind::Resistor { r: 10_000.0 }, &[3, GND]))
            .unwrap();
        pnp.circuit
            .add(comp(3, ComponentKind::Resistor { r: 1000.0 }, &[2, GND]))
            .unwrap();
        pnp.circuit
            .add(comp(
                4,
                ComponentKind::PnpBjt {
                    is_sat: 1e-14,
                    bf: 100.0,
                    br: 1.0,
                },
                &[2, 3, 1],
            ))
            .unwrap();
        pnp.compile_and_dc().unwrap();
        assert!(pnp.node_voltage(2) > 0.1, "PNP should conduct");

        // PMOS
        let mut pmos = SimEngine::new();
        pmos.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        pmos.circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[2, GND]))
            .unwrap();
        pmos.circuit
            .add(comp(
                3,
                ComponentKind::Pmos {
                    kp: 1e-3,
                    vth: -1.5,
                    lambda: 0.01,
                },
                &[2, GND, 1],
            ))
            .unwrap();
        pmos.compile_and_dc().unwrap();
        assert!(pmos.node_voltage(2) > 0.1, "PMOS should conduct");
        let pmos_cir = crate::spice_io::export_cir("pmos", &pmos.circuit);
        assert!(pmos_cir.contains("PMOS") && pmos_cir.contains("VTO=1.5"));

        // NJFET
        let mut njfet = SimEngine::new();
        njfet
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        njfet
            .circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, 3]))
            .unwrap();
        njfet
            .circuit
            .add(comp(3, ComponentKind::Resistor { r: 100.0 }, &[2, GND]))
            .unwrap();
        njfet
            .circuit
            .add(comp(
                4,
                ComponentKind::Njfet {
                    beta: 1e-3,
                    vto: -2.0,
                    lambda: 0.01,
                },
                &[3, GND, 2],
            ))
            .unwrap();
        njfet.compile_and_dc().unwrap();
        assert!(njfet.node_voltage(2) > 0.01, "NJFET should conduct");

        // DIAC AC zero-crossing (>25 ms)
        let mut diac = SimEngine::new();
        diac.circuit
            .add(comp(
                1,
                ComponentKind::AcVoltage {
                    amp: 50.0,
                    freq: 50.0,
                    phase_deg: 0.0,
                    offset: 0.0,
                },
                &[1, GND],
            ))
            .unwrap();
        diac.circuit
            .add(comp(
                2,
                ComponentKind::Diac {
                    v_bo: 30.0,
                    r_on: 10.0,
                    r_off: 1e6,
                },
                &[1, 2],
            ))
            .unwrap();
        diac.circuit
            .add(comp(3, ComponentKind::Resistor { r: 100.0 }, &[2, GND]))
            .unwrap();
        diac.compile_and_dc().unwrap();
        for _ in 0..60 {
            diac.step_transient(5e-4).unwrap();
        }
        assert!(diac.node_voltage(2).is_finite());
    }

    #[test]
    fn phase2_all_remaining_digital_and_mixed_devices() {
        let mut sim = SimEngine::new();
        sim.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        // 1 kHz clock on node 40 (5V, period = 1 ms) to clock sequential devices.
        sim.circuit
            .add(comp(
                99,
                ComponentKind::ClockSource {
                    freq: 1000.0,
                    v_high: 5.0,
                    r_out: 10.0,
                },
                &[40, GND],
            ))
            .unwrap();
        let devices: &[(ComponentKind, &[u32])] = &[
            (
                ComponentKind::SrLatch {
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, GND, 2, 3], // S=5, R=0 -> Q(2)=5, Qn(3)=0
            ),
            (
                ComponentKind::JkFlipFlop {
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, 40, GND, 4, 5], // J=5, CLK=40, K=0 -> Q(4) goes 5 on rising edge
            ),
            (
                ComponentKind::TFlipFlop {
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, 40, 6, 7], // T=5, CLK=40 -> Q(6) toggles 0->5 on rising edge
            ),
            (
                ComponentKind::DFlipFlopAsync {
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, 40, GND, GND, 8, 9], // D=5, CLK=40 -> Q(8) goes 5 on rising edge
            ),
            (
                ComponentKind::ShiftReg4Bit {
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, 40, GND, 10, 11, 12, 13], // SI=5, CLK=40 -> Q0(13)=5 after 1st edge
            ),
            (
                ComponentKind::Mux4To1 {
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[GND, 1, GND, GND, GND, 1, 14], // S=01 -> D1(1)=5V -> Y(14)=5
            ),
            (
                ComponentKind::Demux1To4 {
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, GND, 1, 15, 16, 17, 18], // D=5, S=01 -> Y1(16)=5, Y0(15)=0
            ),
            (
                ComponentKind::Decoder2To4 {
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, GND, 1, 19, 20, 21, 22], // A=10, EN=1 -> Y2(21)=5, Y0(19)=0
            ),
            (
                ComponentKind::FullAdder {
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, 1, GND, 23, 24], // 1+1+0 -> SUM(23)=0, COUT(24)=5
            ),
            (
                ComponentKind::MagComparator {
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, GND, 1, GND, 25, 26, 27], // A=2, B=2 -> EQ(26)=5, GT(25)=0, LT(27)=0
            ),
            (
                ComponentKind::Alu2Bit {
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, GND, 1, GND, GND, GND, 28, 29], // 2+2 mod 4 = 0 -> Y1(28)=0, Y0(29)=0
            ),
            (
                ComponentKind::TriStateBuffer {
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, 1, 30], // IN=5, EN=5 -> OUT(30)=5
            ),
            (
                ComponentKind::HexKeypad {
                    nibble: 0xA,
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[31, 32, 33, 34], // 0xA = 1010 -> 5, 0, 5, 0
            ),
            (
                ComponentKind::Wattmeter { r_shunt: 0.01 },
                &[1, 35, 35, GND],
            ),
            (
                ComponentKind::BarGraphLed {
                    is_sat: 1e-14,
                    n: 2.0,
                },
                &[1, GND],
            ),
            (
                ComponentKind::RgbLed {
                    is_sat: 1e-14,
                    n: 2.0,
                },
                &[1, GND, 1, GND],
            ),
            (
                ComponentKind::AcCurrent {
                    amp: 0.01,
                    freq: 50.0,
                    phase_deg: 0.0,
                    offset: 0.0,
                },
                &[1, GND],
            ),
        ];
        for (idx, (kind, nodes)) in devices.iter().enumerate() {
            sim.circuit
                .add(comp((idx + 2) as u32, kind.clone(), nodes))
                .unwrap();
        }
        // Load on Wattmeter output node 35 so current flows cleanly.
        sim.circuit
            .add(comp(98, ComponentKind::Resistor { r: 100.0 }, &[35, GND]))
            .unwrap();
        sim.compile_and_dc().unwrap();

        // Combinational outputs at DC
        assert!(sim.node_voltage(14) > 4.5, "Mux4To1 Y");
        assert!(
            sim.node_voltage(16) > 4.5 && sim.node_voltage(15) < 0.5,
            "Demux1To4"
        );
        assert!(
            sim.node_voltage(21) > 4.5 && sim.node_voltage(19) < 0.5,
            "Decoder2To4"
        );
        assert!(
            sim.node_voltage(23) < 0.5 && sim.node_voltage(24) > 4.5,
            "FullAdder"
        );
        assert!(
            sim.node_voltage(26) > 4.5 && sim.node_voltage(25) < 0.5,
            "MagComparator"
        );
        assert!(
            sim.node_voltage(28) < 0.5 && sim.node_voltage(29) < 0.5,
            "Alu2Bit"
        );
        assert!(sim.node_voltage(30) > 4.5, "TriStateBuffer");
        assert!(
            sim.node_voltage(31) > 4.5 && sim.node_voltage(32) < 0.5,
            "HexKeypad"
        );
        assert!(sim.component_power(15) > 0.2, "Wattmeter power");

        // Step past the first rising clock edge at t = 0..0.2 ms (ClockSource starts HIGH at t > 0)
        sim.step_transient(1e-4).unwrap();
        assert!(
            sim.node_voltage(2) > 4.5 && sim.node_voltage(3) < 0.5,
            "SrLatch Q"
        );
        assert!(
            sim.node_voltage(4) > 4.5 && sim.node_voltage(5) < 0.5,
            "JkFlipFlop Q"
        );
        assert!(
            sim.node_voltage(6) > 4.5 && sim.node_voltage(7) < 0.5,
            "TFlipFlop Q"
        );
        assert!(
            sim.node_voltage(8) > 4.5 && sim.node_voltage(9) < 0.5,
            "DFlipFlopAsync Q"
        );
        assert!(sim.node_voltage(10) > 4.5, "ShiftReg4Bit MSB");
    }

    #[test]
    fn audit_regression_tests() {
        // 1. Faulted Open Diode across 100V divider & Short IGBT must still converge cleanly.
        let mut fsim = SimEngine::new();
        fsim.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 100.0 }, &[1, GND]))
            .unwrap();
        fsim.circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, 2]))
            .unwrap();
        fsim.circuit
            .add(comp(
                3,
                ComponentKind::Diode {
                    is_sat: 1e-12,
                    n: 1.5,
                    bv: f64::INFINITY,
                },
                &[2, GND],
            ))
            .unwrap();
        fsim.set_fault(3, FaultKind::Open).unwrap();
        fsim.compile_and_dc().unwrap();
        assert!((fsim.node_voltage(2) - 100.0).abs() < 1e-2);

        let mut isim = SimEngine::new();
        isim.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 12.0 }, &[1, GND]))
            .unwrap();
        isim.circuit
            .add(comp(2, ComponentKind::Resistor { r: 100.0 }, &[1, 2]))
            .unwrap();
        isim.circuit
            .add(comp(
                3,
                ComponentKind::Igbt {
                    kp: 2.0,
                    vth: 4.0,
                    r_on: 0.2,
                },
                &[2, 1, GND],
            ))
            .unwrap();
        isim.compile_and_dc().unwrap();
        isim.set_fault(3, FaultKind::Short).unwrap();
        isim.solve_dc_op().unwrap();
        assert!(isim.node_voltage(2).is_finite());

        // 2. DipSwitch4 SPICE export bit order & title newline sanitization.
        let mut dc = crate::netlist::Circuit::new();
        dc.add(comp(
            1,
            ComponentKind::DipSwitch4 {
                mask: 0b0001,
                r_on: 0.001,
                r_off: 1e9,
            },
            &[1, 2, 3, 4, 5, 6, 7, 8],
        ))
        .unwrap();
        let cir = export_cir("My\nR99 1 0 1", &dc);
        assert!(cir.starts_with("* My R99 1 0 1\n"));
        assert!(cir.contains("Rdip1_0 1 2 0.001"));
        assert!(cir.contains("Rdip1_3 7 8 1000000000"));

        // 3. Circuit::add rejects too few pins.
        assert_eq!(
            dc.add(comp(2, ComponentKind::Resistor { r: 100.0 }, &[1]))
                .unwrap_err()
                .code,
            SimErrorCode::InvalidParameter
        );

        // 4. measure_two_terminal ohm & diode mode + minimize_truth_table_dc (incl. 8-var popcount bucketing).
        let mut meas = SimEngine::new();
        meas.circuit
            .add(comp(1, ComponentKind::Resistor { r: 470.0 }, &[1, 2]))
            .unwrap();
        let r_val = meas.measure_two_terminal(1, 2, false).unwrap();
        assert!((r_val - 470.0).abs() < 1.0, "r_val={r_val}");
        let mut dmeas = SimEngine::new();
        dmeas
            .circuit
            .add(comp(
                1,
                ComponentKind::Diode {
                    is_sat: 1e-12,
                    n: 1.5,
                    bv: f64::INFINITY,
                },
                &[1, 2],
            ))
            .unwrap();
        let vf = dmeas.measure_two_terminal(1, 2, true).unwrap();
        assert!(vf > 0.5 && vf < 1.0, "vf={vf}");
        assert_eq!(minimize_truth_table_dc(2, &[0, 1, 2, 1]), "B");

        // 6. measure_two_terminal zeroes ClockSource and WordGen without bias.
        let mut mixed_meas = SimEngine::new();
        mixed_meas
            .circuit
            .add(comp(1, ComponentKind::Resistor { r: 100.0 }, &[1, GND]))
            .unwrap();
        mixed_meas
            .circuit
            .add(comp(
                2,
                ComponentKind::ClockSource {
                    freq: 100.0,
                    v_high: 5.0,
                    r_out: 100.0,
                },
                &[1, GND],
            ))
            .unwrap();
        mixed_meas
            .circuit
            .add(Component {
                id: 3,
                name: "WG".into(),
                kind: ComponentKind::WordGen {
                    freq: 100.0,
                    pattern: 0x0000_0000_0000_000F,
                    v_high: 5.0,
                    r_out: 100.0,
                },
                nodes: [1, 2, 3, 4, 0, 0, 0, 0],
                pin_count: 4,
                fault: FaultKind::None,
            })
            .unwrap();
        let r_mixed = mixed_meas.measure_two_terminal(1, GND, false).unwrap();
        // 100 || 100 || 100 = 33.333... ohm with zero voltage bias.
        assert!((r_mixed - (100.0 / 3.0)).abs() < 0.1, "r_mixed={r_mixed}");

        // 7. 8-variable popcount-bucketed minimizer.
        let tt8: Vec<u8> = (0..256).map(|i| if (i & 1) == 1 { 1 } else { 0 }).collect();
        assert_eq!(minimize_truth_table_dc(8, &tt8), "H");
        let tt8_two: Vec<u8> = (0..256)
            .map(|i| {
                if (i & 0b1000_0001) == 0b1000_0001 || (i & 0b0100_0010) == 0b0100_0010 {
                    1
                } else {
                    0
                }
            })
            .collect();
        let expr8 = minimize_truth_table_dc(8, &tt8_two);
        assert!(
            expr8.contains("AH") && expr8.contains("BG"),
            "expr8={expr8}"
        );

        // 8. RelayDpdt NC contact keeps r_on (~1 mOhm) when unenergized, and faulted SCR does not latch in DC init.
        let mut rly = SimEngine::new();
        rly.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        rly.circuit
            .add(comp(2, ComponentKind::Resistor { r: 10.0 }, &[1, 2]))
            .unwrap();
        rly.circuit
            .add(Component {
                id: 3,
                name: "K1".into(),
                kind: ComponentKind::RelayDpdt {
                    r_coil: 100.0,
                    v_pull: 3.0,
                    r_on: 1e-3,
                    r_off: 1e9,
                },
                nodes: [GND, GND, 2, GND, 3, GND, 4, 5],
                pin_count: 8,
                fault: FaultKind::None,
            })
            .unwrap();
        rly.compile_and_dc().unwrap();
        assert!(
            rly.node_voltage(2).abs() < 0.01,
            "NC v2={}",
            rly.node_voltage(2)
        );

        let mut fscr = SimEngine::new();
        fscr.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        fscr.circuit
            .add(Component {
                id: 2,
                name: "SCR1".into(),
                kind: ComponentKind::Scr {
                    i_hold: 0.01,
                    v_bo: 30.0,
                    r_on: 0.1,
                    r_off: 1e7,
                },
                nodes: [1, GND, 1, 0, 0, 0, 0, 0],
                pin_count: 3,
                fault: FaultKind::Open,
            })
            .unwrap();
        fscr.compile_and_dc().unwrap();
        let topo = fscr.circuit.compile().unwrap();
        let mut p2 = crate::mna::phase2::Phase2State::with_len(fscr.circuit.components.len());
        let need_resolve = crate::mna::phase2::init_phase2_after_dc(
            &fscr.circuit.components,
            &[5.0, 0.0],
            &topo,
            &mut p2,
        );
        assert!(!need_resolve);
        assert_eq!(p2.latch_bits[1], 0);

        // PulseVoltage honors dc_scale during DC source-stepping.
        let mut pcirc = crate::netlist::Circuit::new();
        pcirc
            .add(comp(
                1,
                ComponentKind::PulseVoltage {
                    v1: 10.0,
                    v2: 0.0,
                    td: 0.0,
                    tr: 1e-6,
                    tf: 1e-6,
                    pw: 1e-3,
                    per: 2e-3,
                },
                &[1, GND],
            ))
            .unwrap();
        pcirc
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, GND]))
            .unwrap();
        let ptopo = pcirc.compile().unwrap();
        let pp2 = crate::mna::phase2::Phase2State::with_len(pcirc.components.len());
        let mut sys = crate::mna::solver::DenseSystem::new(ptopo.matrix_size());
        let x0 = vec![0.0; ptopo.matrix_size()];
        crate::mna::phase2::stamp_phase2_component(
            &mut sys,
            &ptopo,
            &pcirc.components[0],
            0,
            ptopo.branch_of_comp[0],
            &x0,
            &pp2,
            0.0,
            1e-4,
            false,
            0.2,
            1e-12,
            0.025,
        );
        let b_idx = ptopo.branch_of_comp[0].unwrap();
        assert!((sys.b[b_idx] - 2.0).abs() < 1e-9);
    }

    #[test]
    fn phase4_parallel_sweeps_and_batched_frame_ffi() {
        use crate::mna::engine::sim_worker_count;
        assert_eq!(sim_worker_count(0), 1);
        assert_eq!(sim_worker_count(1), 1);
        let w2 = sim_worker_count(2);
        assert!((1..=2).contains(&w2));
        let w64 = sim_worker_count(64);
        assert!((1..=64).contains(&w64));

        // Single-pass AC transfer sweep on RC low-pass (fc = 1/(2*pi*1k*1u) ~= 159.155 Hz)
        let mut rc = SimEngine::new();
        rc.circuit
            .add(comp(
                1,
                ComponentKind::AcVoltage {
                    amp: 5.0,
                    freq: 100.0,
                    phase_deg: 0.0,
                    offset: 0.0,
                },
                &[1, GND],
            ))
            .unwrap();
        rc.circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, 2]))
            .unwrap();
        rc.circuit
            .add(comp(
                3,
                ComponentKind::Capacitor { c: 1e-6, ic: None },
                &[2, GND],
            ))
            .unwrap();
        let pts = rc
            .solve_ac_sweep_transfer(10.0, 10_000.0, 20, 1, Some(1), 2)
            .unwrap();
        assert!(pts.len() > 20);
        assert!(pts.first().unwrap().mag_db > -0.1);
        assert!(pts.last().unwrap().mag_db < -30.0);
        let self_pts = rc
            .solve_ac_sweep_transfer(10.0, 1000.0, 10, 1, Some(2), 2)
            .unwrap();
        assert!(self_pts
            .iter()
            .all(|p| p.mag_db == 0.0 && p.phase_deg == 0.0));

        // Deterministic Monte Carlo (uniform & Gaussian)
        let mut div = SimEngine::new();
        div.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 10.0 }, &[1, GND]))
            .unwrap();
        div.circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, 2]))
            .unwrap();
        div.circuit
            .add(comp(3, ComponentKind::Resistor { r: 1000.0 }, &[2, GND]))
            .unwrap();
        let u1 = div.monte_carlo_dc_ex(0.05, 40, 2, false).unwrap();
        let u2 = div.monte_carlo_dc_ex(0.05, 40, 2, false).unwrap();
        assert_eq!(u1.4, u2.4);
        assert!(u1.0 <= u1.2 && u1.2 <= u1.1);
        let g1 = div.monte_carlo_dc_ex(0.05, 40, 2, true).unwrap();
        let g2 = div.monte_carlo_dc_ex(0.05, 40, 2, true).unwrap();
        assert_eq!(g1.4, g2.4);
        assert!((g1.2 - 5.0).abs() < 0.25);

        // Batched FFI frame state read matches individual getters
        unsafe {
            let h = crate::ffi::ob_sim_create();
            assert!(!h.is_null());
            let pins1 = [1u32, GND];
            let p1 = [10.0f64];
            assert_eq!(
                crate::ffi::ob_sim_add_component_ex(h, 1, 10, pins1.as_ptr(), 2, p1.as_ptr(), 1),
                0
            );
            let pins2 = [1u32, GND];
            let p2 = [100.0f64];
            assert_eq!(
                crate::ffi::ob_sim_add_component_ex(h, 2, 1, pins2.as_ptr(), 2, p2.as_ptr(), 1),
                0
            );
            assert_eq!(crate::ffi::ob_sim_solve_dc(h), 0);

            let nids = [1u32];
            let mut nv = [0.0f64];
            let cids = [1u32, 2u32];
            let mut ci = [0.0f64; 2];
            let mut cp = [0.0f64; 2];
            let mut flags = [0u8; 2];
            let rc = crate::ffi::ob_sim_read_frame_state(
                h,
                nids.as_ptr(),
                1,
                nv.as_mut_ptr(),
                cids.as_ptr(),
                2,
                ci.as_mut_ptr(),
                cp.as_mut_ptr(),
                flags.as_mut_ptr(),
            );
            assert_eq!(rc, 0);
            assert!((nv[0] - 10.0).abs() < 1e-6);
            assert!((ci[1] - 0.1).abs() < 1e-6);
            assert!((cp[1] - 1.0).abs() < 1e-4);
            assert_eq!(flags[1] & 1, 1); // 1W > 0.5W overload threshold
            crate::ffi::ob_sim_destroy(h);
        }
    }

    #[test]
    fn ponytail_audit_fixes() {
        // 1. Timer555 monostable DC startup stays LOW on first transient step when TRIG is idle HIGH.
        let mut t555 = SimEngine::new();
        t555.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        t555.circuit
            .add(comp(2, ComponentKind::Resistor { r: 10_000.0 }, &[1, 2]))
            .unwrap();
        t555.circuit
            .add(comp(
                3,
                ComponentKind::Capacitor { c: 1e-6, ic: None },
                &[2, GND],
            ))
            .unwrap();
        t555.circuit
            .add(comp(
                4,
                ComponentKind::Timer555 {
                    v_cc: 5.0,
                    r_out: 50.0,
                },
                &[1, 2, 2, 3], // TRIG=5V, THRS=node2, DISCH=node2, OUT=node3
            ))
            .unwrap();
        t555.compile_and_dc().unwrap();
        assert!(t555.node_voltage(3) < 0.5, "555 DC OUT should be LOW");
        t555.step_transient(1e-5).unwrap();
        assert!(
            t555.node_voltage(3) < 0.5,
            "555 OUT must not false-fire on first step: {}",
            t555.node_voltage(3)
        );

        // 2. Adding a component after ob_sim_solve_dc invalidates topo instead of panicking.
        unsafe {
            let h = crate::ffi::ob_sim_create();
            let p1 = [1u32, 0];
            let v1 = [5.0];
            assert_eq!(
                crate::ffi::ob_sim_add_component_ex(h, 1, 10, p1.as_ptr(), 2, v1.as_ptr(), 1),
                0
            );
            assert_eq!(
                crate::ffi::ob_sim_add_component_ex(h, 2, 1, p1.as_ptr(), 2, [1000.0].as_ptr(), 1),
                0
            );
            assert_eq!(crate::ffi::ob_sim_solve_dc(h), 0);
            let p2 = [1u32, 2];
            assert_eq!(
                crate::ffi::ob_sim_add_component_ex(h, 3, 1, p2.as_ptr(), 2, [1000.0].as_ptr(), 1),
                0
            );
            let p3 = [2u32, 0];
            assert_eq!(
                crate::ffi::ob_sim_add_component_ex(h, 4, 1, p3.as_ptr(), 2, [1000.0].as_ptr(), 1),
                0
            );
            let mut t_out = 0.0;
            assert_eq!(crate::ffi::ob_sim_step_frame(h, 1e-4, 10, &mut t_out), 0);
            assert!((crate::ffi::ob_sim_get_node_voltage(h, 2) - 2.5).abs() < 1e-6);
            crate::ffi::ob_sim_destroy(h);
        }

        // 3. run_for_frame with 1 kHz clock reaches full sim_duration.
        let mut frm = SimEngine::new();
        frm.default_dt = 1e-3;
        frm.circuit
            .add(comp(
                1,
                ComponentKind::ClockSource {
                    freq: 1000.0,
                    v_high: 5.0,
                    r_out: 10.0,
                },
                &[1, GND],
            ))
            .unwrap();
        frm.run_for_frame(0.01, 10).unwrap();
        assert!((frm.t_sim - 0.01).abs() < 1e-9, "t_sim={}", frm.t_sim);

        // 4. SPICE export: DcMotor uses ';', FunctionGen Square starts HIGH and freq=0 emits DC.
        let mut sp = SimEngine::new();
        sp.circuit
            .add(comp(
                1,
                ComponentKind::DcMotor { r_a: 5.0, ke: 0.1 },
                &[1, GND],
            ))
            .unwrap();
        sp.circuit
            .add(comp(
                2,
                ComponentKind::FunctionGen {
                    shape: crate::netlist::WaveShape::Square,
                    amp: 5.0,
                    freq: 100.0,
                    offset: 0.0,
                    duty: 0.5,
                },
                &[1, GND],
            ))
            .unwrap();
        sp.circuit
            .add(comp(
                3,
                ComponentKind::FunctionGen {
                    shape: crate::netlist::WaveShape::Square,
                    amp: 5.0,
                    freq: 0.0,
                    offset: 2.5,
                    duty: 0.5,
                },
                &[2, GND],
            ))
            .unwrap();
        let cir = crate::spice_io::export_cir("test", &sp.circuit);
        assert!(cir.contains("Rmot1 1 0 5 ; ke=0.1"), "{cir}");
        assert!(cir.contains("PULSE(-5 5 0 "), "{cir}");
        assert!(cir.contains("V3 2 0 DC 2.5"), "{cir}");

        // 5. Unwired Adc4Bit VREF uses v_ref parameter; ClockSource power is negative when delivering.
        let mut adc = SimEngine::new();
        adc.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 2.5 }, &[1, GND]))
            .unwrap();
        adc.circuit
            .add(comp(
                2,
                ComponentKind::Adc4Bit {
                    v_ref: 5.0,
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, 99, 2, 3, 4, 5], // VREF pin (99) is unwired -> should use 5.0V, code = 8 (1000)
            ))
            .unwrap();
        adc.compile_and_dc().unwrap();
        assert!(
            adc.node_voltage(2) > 4.5 && adc.node_voltage(3) < 0.5,
            "Adc4Bit 2.5V/5V -> 1000"
        );

        let mut clk_p = SimEngine::new();
        clk_p
            .circuit
            .add(comp(
                1,
                ComponentKind::ClockSource {
                    freq: 100.0,
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, GND],
            ))
            .unwrap();
        clk_p
            .circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, GND]))
            .unwrap();
        clk_p.compile_and_dc().unwrap();
        clk_p.step_transient(1e-4).unwrap();
        assert!(
            clk_p.component_power(1) < 0.0,
            "delivering source power must be negative"
        );

        // 6. Nonlinear sparse circuit (n > 48) solves cleanly with reused SparseScratch.
        let mut sp_nl = SimEngine::new();
        sp_nl
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        for i in 1..=52u32 {
            sp_nl
                .circuit
                .add(comp(
                    i + 1,
                    ComponentKind::Resistor { r: 100.0 },
                    &[i, i + 1],
                ))
                .unwrap();
        }
        sp_nl
            .circuit
            .add(comp(
                100,
                ComponentKind::Diode {
                    is_sat: 1e-12,
                    n: 1.0,
                    bv: f64::INFINITY,
                },
                &[53, GND],
            ))
            .unwrap();
        sp_nl.compile_and_dc().unwrap();
        sp_nl.step_transient(1e-4).unwrap();
        assert!(sp_nl.node_voltage(53) > 0.3 && sp_nl.node_voltage(53) < 1.2);
    }

    #[test]
    fn ponytail_audit2_fixes() {
        // 1. uic=true still computes DC bias for AC sweep & measure_two_terminal.
        let mut uic_sim = SimEngine::new();
        uic_sim.config.uic = true;
        uic_sim
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 10.0 }, &[1, GND]))
            .unwrap();
        uic_sim
            .circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, 2]))
            .unwrap();
        uic_sim
            .circuit
            .add(comp(
                3,
                ComponentKind::Diode {
                    is_sat: 1e-12,
                    n: 1.0,
                    bv: f64::INFINITY,
                },
                &[2, GND],
            ))
            .unwrap();
        let ac = uic_sim
            .solve_ac_sweep_transfer(100.0, 1000.0, 2, 1, None, 2)
            .unwrap();
        assert!(
            ac[0].mag_db < -15.0,
            "forward-biased diode should attenuate AC: {:?}",
            ac[0]
        );
        let r_meas = uic_sim.measure_two_terminal(1, 2, false).unwrap();
        assert!((r_meas - 1000.0).abs() < 20.0, "ohmmeter r_meas={r_meas}");

        // 2. Duplicate component ID is rejected by Circuit::add.
        let mut dup = SimEngine::new();
        dup.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        assert!(dup
            .circuit
            .add(comp(1, ComponentKind::Resistor { r: 100.0 }, &[1, GND]))
            .is_err());

        // 3. DigitalGateMulti with 6 pins drives pins[5] (not pins[4]).
        let mut g6 = SimEngine::new();
        g6.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        g6.circuit
            .add(comp(
                2,
                ComponentKind::DigitalGateMulti {
                    kind: crate::digital::GateKind::And,
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, 1, 1, 1, 1, 2],
            ))
            .unwrap();
        g6.compile_and_dc().unwrap();
        assert!(g6.node_voltage(2) > 4.5);

        // 4. gmin == 0.0 on unwired Phase-2 IC input + NaN run_for_frame + u32::MAX ohmmeter.
        let mut g0 = SimEngine::new();
        g0.config.gmin = 0.0;
        g0.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        g0.circuit
            .add(comp(
                u32::MAX,
                ComponentKind::ShiftReg4Bit {
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, 2, 3, 4, 5, 6, 7], // CLK/RST unwired
            ))
            .unwrap();
        g0.compile_and_dc().unwrap();
        assert!(g0.run_for_frame(f64::NAN, 10).is_err());
        assert!(g0.measure_two_terminal(1, GND, false).is_ok());

        // 5. ClockSource component_current returns 0 A after solve_dc_op following transient.
        let mut clk = SimEngine::new();
        clk.circuit
            .add(comp(
                1,
                ComponentKind::ClockSource {
                    freq: 100.0,
                    v_high: 5.0,
                    r_out: 50.0,
                },
                &[1, GND],
            ))
            .unwrap();
        clk.circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, GND]))
            .unwrap();
        clk.compile_and_dc().unwrap();
        clk.step_transient(1e-4).unwrap();
        assert!(clk.component_current(1).abs() > 1e-3);
        clk.solve_dc_op().unwrap();
        assert!(clk.component_current(1).abs() < 1e-6);

        // 6. Gear2 variable-dt inductor + FaultKind::Leaky + CoupledInductor + Crystal AC resonance.
        let mut g2 = SimEngine::new();
        g2.config.integrator = crate::mna::engine::IntegratorKind::Gear2;
        g2.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        g2.circuit
            .add(comp(2, ComponentKind::Resistor { r: 100.0 }, &[1, 2]))
            .unwrap();
        g2.circuit
            .add(comp(
                3,
                ComponentKind::Inductor {
                    l: 1e-2,
                    ic: Some(0.0),
                },
                &[2, GND],
            ))
            .unwrap();
        g2.compile_and_dc().unwrap();
        g2.step_transient(1e-5).unwrap();
        g2.step_transient(2e-5).unwrap();
        assert!(g2.node_voltage(2).is_finite());

        let mut lky = SimEngine::new();
        lky.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 10.0 }, &[1, GND]))
            .unwrap();
        lky.circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, 2]))
            .unwrap();
        lky.circuit
            .add(comp(3, ComponentKind::Resistor { r: 1000.0 }, &[2, GND]))
            .unwrap();
        lky.set_fault(2, FaultKind::Leaky).unwrap();
        lky.compile_and_dc().unwrap();
        assert!(lky.node_voltage(2) > 6.0);

        let mut xtal = SimEngine::new();
        xtal.circuit
            .add(comp(
                1,
                ComponentKind::AcVoltage {
                    amp: 1.0,
                    freq: 1000.0,
                    phase_deg: 0.0,
                    offset: 0.0,
                },
                &[1, GND],
            ))
            .unwrap();
        xtal.circuit
            .add(comp(
                2,
                ComponentKind::Crystal {
                    rm: 20.0,
                    lm: 1e-3,
                    cm: 1e-9,
                    c0: 5e-12,
                },
                &[1, 2],
            ))
            .unwrap();
        xtal.circuit
            .add(comp(3, ComponentKind::Resistor { r: 50.0 }, &[2, GND]))
            .unwrap();
        let xtal_ac = xtal
            .solve_ac_sweep_transfer(1e5, 1e6, 20, 1, None, 2)
            .unwrap();
        assert!(xtal_ac.iter().any(|p| p.mag_db > -5.0));
    }

    #[test]
    fn coupled_inductor_transient_mutual_induction() {
        let run = |k: f64| -> f64 {
            let mut eng = SimEngine::new();
            eng.circuit
                .add(comp(
                    1,
                    ComponentKind::PulseVoltage {
                        v1: 0.0,
                        v2: 10.0,
                        td: 0.0,
                        tr: 1e-5,
                        tf: 1e-5,
                        pw: 5e-4,
                        per: 1e-3,
                    },
                    &[1, GND],
                ))
                .unwrap();
            eng.circuit
                .add(comp(2, ComponentKind::Resistor { r: 100.0 }, &[1, 2]))
                .unwrap();
            eng.circuit
                .add(comp(
                    3,
                    ComponentKind::CoupledInductor {
                        l1: 10e-3,
                        l2: 10e-3,
                        k,
                    },
                    &[2, GND, 3, GND],
                ))
                .unwrap();
            eng.circuit
                .add(comp(4, ComponentKind::Resistor { r: 1000.0 }, &[3, GND]))
                .unwrap();
            eng.compile_and_dc().unwrap();
            let mut max_vsec = 0.0_f64;
            for _ in 0..20 {
                eng.step_transient(1e-5).unwrap();
                max_vsec = max_vsec.max(eng.node_voltage(3).abs());
            }
            max_vsec
        };
        assert!(run(0.9) > 0.5);
        assert!(run(0.0) < 1e-6);
    }

    #[test]
    fn dc_op_hard_nonlinear_converges() {
        let mut eng = SimEngine::new();
        eng.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 500.0 }, &[1, GND]))
            .unwrap();
        eng.circuit
            .add(comp(2, ComponentKind::Resistor { r: 100.0 }, &[1, 2]))
            .unwrap();
        eng.circuit
            .add(comp(
                3,
                ComponentKind::Diode {
                    is_sat: 1e-12,
                    n: 1.5,
                    bv: f64::INFINITY,
                },
                &[2, GND],
            ))
            .unwrap();
        eng.compile_and_dc().unwrap();
        let vd = eng.node_voltage(2);
        assert!(vd > 0.5 && vd < 1.5, "unexpected diode voltage {vd}");
        let i_r = (500.0 - vd) / 100.0;
        let i_d = eng.component_current(3);
        assert!((i_r - i_d).abs() < 1e-4);
    }

    #[test]
    fn scope_buffer_single_sample_per_step_and_full_buffer_rollback() {
        let mut eng = SimEngine::new();
        eng.circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        eng.circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, 2]))
            .unwrap();
        eng.circuit
            .add(comp(
                3,
                ComponentKind::Capacitor { c: 1e-6, ic: None },
                &[2, GND],
            ))
            .unwrap();
        eng.scope_nodes[0] = Some(2);
        eng.compile_and_dc().unwrap();
        for _ in 0..4100 {
            eng.step_transient(1e-5).unwrap();
        }
        assert_eq!(eng.scope.samples.len(), 4096);
        let last_t = eng.scope.samples.back().unwrap().t;
        assert!(eng.step_transient(-1.0).is_err());
        assert_eq!(eng.scope.samples.len(), 4096);
        assert_eq!(eng.scope.samples.back().unwrap().t, last_t);
        for w in eng.scope.samples.iter().collect::<Vec<_>>().windows(2) {
            assert!(w[1].t > w[0].t);
        }
    }

    #[test]
    fn audit5_readouts_ac_sweep_resync_and_step_halved_rollback() {
        // #4: Capacitor, VaractorDiode, Crystal return 0 reactive current after solve_dc().
        let mut cap_eng = SimEngine::new();
        cap_eng
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 10.0 }, &[1, GND]))
            .unwrap();
        cap_eng
            .circuit
            .add(comp(2, ComponentKind::Resistor { r: 10.0 }, &[1, 2]))
            .unwrap();
        cap_eng
            .circuit
            .add(comp(
                3,
                ComponentKind::Capacitor { c: 1e-4, ic: None },
                &[2, GND],
            ))
            .unwrap();
        cap_eng.compile_and_dc().unwrap();
        cap_eng.circuit.components[0].kind = ComponentKind::DcVoltage { v: 5.0 };
        cap_eng.step_transient(1e-5).unwrap();
        assert!(cap_eng.component_current(3).abs() > 0.1);
        cap_eng.solve_dc().unwrap();
        assert_eq!(cap_eng.component_current(3), 0.0);

        // #5: solve_ac_sweep_transfer preserves last_was_transient and handles gmin == 0.0.
        let mut ac_eng = SimEngine::new();
        ac_eng.config.gmin = 0.0;
        ac_eng
            .circuit
            .add(comp(
                1,
                ComponentKind::ClockSource {
                    freq: 100.0,
                    v_high: 5.0,
                    r_out: 10.0,
                },
                &[1, GND],
            ))
            .unwrap();
        ac_eng
            .circuit
            .add(comp(2, ComponentKind::Resistor { r: 1000.0 }, &[1, GND]))
            .unwrap();
        ac_eng
            .circuit
            .add(comp(
                3,
                ComponentKind::ShiftReg4Bit {
                    v_high: 5.0,
                    r_out: 10.0,
                },
                &[99, 98, 97, 2, 3, 4, 5],
            ))
            .unwrap();
        ac_eng.compile_and_dc().unwrap();
        ac_eng.step_transient(1e-4).unwrap();
        let i_trans = ac_eng.component_current(1);
        assert!(i_trans.abs() > 1e-4);
        let bode = ac_eng
            .solve_ac_sweep_transfer(10.0, 1000.0, 1, 1, None, 1)
            .unwrap();
        assert!(!bode.is_empty());
        assert!((ac_eng.component_current(1) - i_trans).abs() < 1e-12);

        // #6: SrLatch re-solve re-syncs Phase-2 Crystal state (no step-1 c0 spike).
        let mut lat_eng = SimEngine::new();
        lat_eng
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 5.0 }, &[1, GND]))
            .unwrap();
        lat_eng
            .circuit
            .add(comp(
                2,
                ComponentKind::SrLatch {
                    v_high: 5.0,
                    r_out: 10.0,
                },
                &[1, GND, 2, 3],
            ))
            .unwrap();
        lat_eng
            .circuit
            .add(comp(
                3,
                ComponentKind::Crystal {
                    rm: 50.0,
                    lm: 1e-3,
                    cm: 25e-12,
                    c0: 5e-12,
                },
                &[2, GND],
            ))
            .unwrap();
        lat_eng.compile_and_dc().unwrap();
        lat_eng.step_transient(1e-8).unwrap();
        assert!(lat_eng.component_current(3).abs() < 1e-4);

        // #7: AcCurrent DC current includes phase_deg sine term.
        let mut aci_eng = SimEngine::new();
        aci_eng
            .circuit
            .add(comp(
                1,
                ComponentKind::AcCurrent {
                    amp: 1.0,
                    freq: 60.0,
                    phase_deg: 90.0,
                    offset: 0.0,
                },
                &[1, GND],
            ))
            .unwrap();
        aci_eng
            .circuit
            .add(comp(2, ComponentKind::Resistor { r: 10.0 }, &[1, GND]))
            .unwrap();
        aci_eng.compile_and_dc().unwrap();
        assert!((aci_eng.component_current(1) - 1.0).abs() < 1e-6);

        // #8: ComparatorOc power is positive when sinking current.
        let mut cmp_eng = SimEngine::new();
        cmp_eng
            .circuit
            .add(comp(1, ComponentKind::DcVoltage { v: 2.5 }, &[1, GND]))
            .unwrap();
        cmp_eng
            .circuit
            .add(comp(2, ComponentKind::DcVoltage { v: 5.0 }, &[2, GND]))
            .unwrap();
        cmp_eng
            .circuit
            .add(comp(3, ComponentKind::Resistor { r: 25.0 }, &[2, 3]))
            .unwrap();
        cmp_eng
            .circuit
            .add(comp(
                4,
                ComponentKind::ComparatorOc { r_ol: 25.0 },
                &[GND, 1, 3],
            ))
            .unwrap();
        cmp_eng.compile_and_dc().unwrap();
        assert!(cmp_eng.component_power(4) > 0.2);

        // #14: step_halved rolls back blown fuse and t_sim when convergence fails.
        let mut rb_eng = SimEngine::new();
        rb_eng
            .circuit
            .add(comp(
                1,
                ComponentKind::AcVoltage {
                    amp: 10.0,
                    freq: 100.0,
                    phase_deg: 0.0,
                    offset: 0.0,
                },
                &[1, GND],
            ))
            .unwrap();
        rb_eng
            .circuit
            .add(comp(
                2,
                ComponentKind::Fuse {
                    i_max: 0.05,
                    r_on: 0.1,
                    blown: false,
                },
                &[1, 2],
            ))
            .unwrap();
        rb_eng
            .circuit
            .add(comp(
                3,
                ComponentKind::Diode {
                    is_sat: 1e-12,
                    n: 1.5,
                    bv: f64::INFINITY,
                },
                &[2, GND],
            ))
            .unwrap();
        rb_eng.compile_and_dc().unwrap();
        rb_eng.config.reltol = 1e-30;
        rb_eng.config.abstol = 1e-30;
        let t_before = rb_eng.t_sim;
        let _ = rb_eng.step_transient(1e-3);
        if rb_eng.t_sim == t_before {
            assert!(matches!(
                rb_eng.circuit.components[1].kind,
                ComponentKind::Fuse { blown: false, .. }
            ));
        }
    }
}
