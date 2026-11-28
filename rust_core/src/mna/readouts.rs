use crate::error::{SimError, SimErrorCode};
use crate::mna::devices::{eval_diode_vt, eval_mosfet_channel, eval_tanh_amp, node_v};
use crate::mna::engine::SimEngine;
use crate::mna::phase2::{diac_conductance_and_current, eval_jfet_channel};
use crate::netlist::{Component, ComponentKind, FaultKind};

impl SimEngine {
    /// Updates a 64-bit WordGen bit-pattern losslessly without f64 mantissa truncation.
    pub fn set_wordgen_pattern(&mut self, comp_id: u32, pattern: u64) -> Result<(), SimError> {
        let (_, comp) = self
            .comp_by_id_mut(comp_id)
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
        let (_, comp) = self
            .comp_by_id_mut(comp_id)
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
            ComponentKind::ComparatorOc { r_ol } => match param_idx {
                0 | 1 => *r_ol = value.max(1.0),
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

    pub(super) fn comp_by_id(&self, comp_id: u32) -> Option<(usize, &Component)> {
        if let Some(topo) = &self.topo {
            let &idx = topo.comp_map.get(&comp_id)?;
            return self.circuit.components.get(idx).map(|c| (idx, c));
        }
        self.circuit
            .components
            .iter()
            .enumerate()
            .find(|(_, c)| c.id == comp_id)
    }

    pub(super) fn comp_by_id_mut(&mut self, comp_id: u32) -> Option<(usize, &mut Component)> {
        if let Some(topo) = &self.topo {
            let &idx = topo.comp_map.get(&comp_id)?;
            return self.circuit.components.get_mut(idx).map(|c| (idx, c));
        }
        self.circuit
            .components
            .iter_mut()
            .enumerate()
            .find(|(_, c)| c.id == comp_id)
    }

    pub fn is_fuse_blown(&self, comp_id: u32) -> bool {
        self.comp_by_id(comp_id)
            .is_some_and(|(_, c)| matches!(c.kind, ComponentKind::Fuse { blown: true, .. }))
    }

    pub fn set_fault(&mut self, comp_id: u32, fault: FaultKind) -> Result<(), SimError> {
        let (_, comp) = self
            .comp_by_id_mut(comp_id)
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
        let Some((idx, comp)) = self.comp_by_id(comp_id) else {
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
                        self.solution[b]
                            + if self.last_was_transient {
                                self.phase2.aux_d.get(idx).copied().unwrap_or(0.0)
                            } else {
                                0.0
                            }
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
                if self.last_was_transient {
                    self.reactive.cap_i_prev.get(idx).copied().unwrap_or(0.0)
                } else {
                    0.0
                }
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
                i_d + if self.last_was_transient {
                    self.reactive.cap_i_prev.get(idx).copied().unwrap_or(0.0)
                } else {
                    0.0
                }
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
                let (v_target, _) = eval_tanh_amp(va - vb, gain, v_sat_pos, v_sat_neg);
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
                let (mag, _, _, rev) = eval_mosfet_channel(va, vb, vs, kp, vth, lambda, pol, gmin);
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
                let vt = if self.last_was_transient
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
                let step_idx = if self.last_was_transient && freq > 0.0 {
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
                let t = if self.last_was_transient {
                    self.t_sim
                } else {
                    0.0
                };
                offset
                    + amp * (2.0 * std::f64::consts::PI * freq * t + phase_deg.to_radians()).sin()
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
                let (mag, _, _, rev) = eval_jfet_channel(va, vg, vs, beta, vto, lambda, pol, gmin);
                let i_gd = eval_diode_vt(pol * (vg - va), 1e-14, 1.0, f64::INFINITY, gmin, vt).0;
                pol * (if rev { -mag } else { mag } - i_gd)
            }
            ComponentKind::Scr { r_on, r_off, .. } => {
                let latched = self.phase2.latch_bits.get(idx).copied().unwrap_or(0) != 0;
                let conduct = latched && (va - vb) >= -0.05;
                (va - vb)
                    / if conduct {
                        r_on.max(1e-3)
                    } else {
                        r_off.max(1.0)
                    }
            }
            ComponentKind::Triac { r_on, r_off, .. } => {
                let latched = self.phase2.latch_bits.get(idx).copied().unwrap_or(0) != 0;
                (va - vb)
                    / if latched {
                        r_on.max(1e-3)
                    } else {
                        r_off.max(1.0)
                    }
            }
            ComponentKind::Diac { v_bo, r_on, r_off } => {
                let v = va - vb;
                let latch_state = if self.last_was_transient {
                    self.phase2.latch_bits.get(idx).copied().unwrap_or(0)
                } else {
                    0
                };
                diac_conductance_and_current(v, v_bo, r_on, r_off, latch_state).1
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
            ComponentKind::ComparatorOc { r_ol } => {
                let vo = node_v(&self.solution, topo, comp.nodes[2]);
                let s = 0.5 * (1.0 - ((va - vb) / 0.005).clamp(-20.0, 20.0).tanh());
                -vo * ((1.0 / r_ol.max(1.0)) * s + gmin)
            }
            ComponentKind::InstAmp {
                gain,
                v_sat_pos,
                v_sat_neg,
                r_out,
            } => {
                let vo = node_v(&self.solution, topo, comp.nodes[2]);
                let (v_target, _) = eval_tanh_amp(va - vb, gain, v_sat_pos, v_sat_neg);
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
                let in_len = pins.len().saturating_sub(1).min(7);
                let mut inputs_v = [0.0; 7];
                for (slot, &p) in inputs_v[..in_len].iter_mut().zip(&pins[..in_len]) {
                    *slot = node_v(&self.solution, topo, p);
                }
                let vt_out = crate::digital::eval_soft_gate(kind, &inputs_v[..in_len], v_high);
                (vt_out - node_v(&self.solution, topo, pins[pins.len() - 1])) / r_out.max(1.0)
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
                let vref = if topo.is_connected_node(comp.nodes[4]) {
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
                let vref = if topo.is_connected_node(comp.nodes[1]) {
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

    /// Instantaneous power dissipation (Watts; positive = absorbed, negative = delivered).
    pub fn component_power(&self, comp_id: u32) -> f64 {
        let Some(topo) = &self.topo else {
            return 0.0;
        };
        let Some((idx_c, comp)) = self.comp_by_id(comp_id) else {
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
                if let Some(b1) = topo.branch_of_comp[idx_c] {
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
                let step_idx = if self.last_was_transient && freq > 0.0 {
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
                if let Some(b) = topo.branch_of_comp[idx_c] {
                    let vs = node_v(&self.solution, topo, comp.nodes[2])
                        - node_v(&self.solution, topo, comp.nodes[3]);
                    vs * self.solution[b]
                } else {
                    0.0
                }
            }
            ComponentKind::ClockSource { .. } => -(va - vb) * self.component_current(comp_id),
            ComponentKind::DigitalGate { .. }
            | ComponentKind::DigitalGateMulti { .. }
            | ComponentKind::ComparatorOc { .. }
            | ComponentKind::SchmittTrigger { .. }
            | ComponentKind::SampleHold { .. }
            | ComponentKind::TriStateBuffer { .. } => {
                let pins = comp.active_nodes();
                let vo = node_v(&self.solution, topo, pins[pins.len() - 1]);
                -vo * self.component_current(comp_id)
            }
            ComponentKind::Vco { .. } => {
                -node_v(&self.solution, topo, comp.nodes[1]) * self.component_current(comp_id)
            }
            ComponentKind::DFlipFlop { .. } => {
                -node_v(&self.solution, topo, comp.nodes[2]) * self.component_current(comp_id)
            }
            ComponentKind::Timer555 { .. } => {
                -node_v(&self.solution, topo, comp.nodes[3]) * self.component_current(comp_id)
            }
            ComponentKind::Dac4Bit { .. } => {
                -node_v(&self.solution, topo, comp.nodes[5]) * self.component_current(comp_id)
            }
            ComponentKind::Mux4To1 { .. } => {
                -node_v(&self.solution, topo, comp.nodes[6]) * self.component_current(comp_id)
            }
            ComponentKind::SrLatch { .. }
            | ComponentKind::JkFlipFlop { .. }
            | ComponentKind::TFlipFlop { .. }
            | ComponentKind::DFlipFlopAsync { .. }
            | ComponentKind::Counter4Bit { .. }
            | ComponentKind::Counter4BitFull { .. }
            | ComponentKind::ShiftReg4Bit { .. }
            | ComponentKind::Demux1To4 { .. }
            | ComponentKind::Decoder2To4 { .. }
            | ComponentKind::FullAdder { .. }
            | ComponentKind::MagComparator { .. }
            | ComponentKind::Alu2Bit { .. }
            | ComponentKind::Adc4Bit { .. }
            | ComponentKind::HexKeypad { .. }
            | ComponentKind::SevenSeg { .. } => 0.0,
            _ => (va - vb) * self.component_current(comp_id),
        }
    }

    /// True if fuse blown or passive/semiconductor power exceeds conservative 0.5 W dissipation limit.
    pub fn component_overloaded(&self, comp_id: u32) -> bool {
        let Some((_, comp)) = self.comp_by_id(comp_id) else {
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
}
