/// 4-state digital logic level used by gates, flip-flops, logic analyzer, and ADC/DAC bridges.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogicLevel {
    Low = 0,
    High = 1,
    Unknown = 2,
    HighZ = 3,
}

impl LogicLevel {
    pub fn invert(self) -> Self {
        match self {
            Self::Low => Self::High,
            Self::High => Self::Low,
            Self::Unknown | Self::HighZ => Self::Unknown,
        }
    }

    pub fn from_analog(v: f64, v_il: f64, v_ih: f64) -> Self {
        if v <= v_il {
            Self::Low
        } else if v >= v_ih {
            Self::High
        } else {
            Self::Unknown
        }
    }

    pub fn to_analog(self, v_low: f64, v_high: f64) -> Option<f64> {
        match self {
            Self::Low => Some(v_low),
            Self::High => Some(v_high),
            Self::Unknown => Some(0.5 * (v_low + v_high)),
            Self::HighZ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GateKind {
    And,
    Or,
    Not,
    Nand,
    Nor,
    Xor,
    Xnor,
}

/// Smooth C-infinity gate output wrt normalized sigmoid scores so NR does not chatter across threshold.
pub fn eval_soft_gate(kind: GateKind, inputs_v: &[f64], v_high: f64) -> f64 {
    let dv = (0.04 * v_high).max(1e-3);
    let mid = 0.5 * v_high;
    let sig = |v: f64| -> f64 { 0.5 + 0.5 * ((v - mid) / dv).clamp(-20.0, 20.0).tanh() };
    let mut prod = 1.0;
    let mut inv_prod = 1.0;
    let mut parity = 0.0;
    for &v in inputs_v {
        let s = sig(v);
        prod *= s;
        inv_prod *= 1.0 - s;
        parity = parity * (1.0 - s) + (1.0 - parity) * s;
    }
    let out = match kind {
        GateKind::Not => inputs_v.first().map_or(0.5, |&v| 1.0 - sig(v)),
        GateKind::And => prod,
        GateKind::Nand => 1.0 - prod,
        GateKind::Or => 1.0 - inv_prod,
        GateKind::Nor => inv_prod,
        GateKind::Xor => parity,
        GateKind::Xnor => 1.0 - parity,
    };
    out * v_high
}

pub fn eval_gate(kind: GateKind, inputs: &[LogicLevel]) -> LogicLevel {
    match kind {
        GateKind::Not => inputs
            .first()
            .copied()
            .unwrap_or(LogicLevel::Unknown)
            .invert(),
        GateKind::And | GateKind::Nand => {
            let mut has_unknown = false;
            for &v in inputs {
                if v == LogicLevel::Low {
                    return if kind == GateKind::And {
                        LogicLevel::Low
                    } else {
                        LogicLevel::High
                    };
                }
                if matches!(v, LogicLevel::Unknown | LogicLevel::HighZ) {
                    has_unknown = true;
                }
            }
            let out = if has_unknown {
                LogicLevel::Unknown
            } else {
                LogicLevel::High
            };
            if kind == GateKind::Nand {
                out.invert()
            } else {
                out
            }
        }
        GateKind::Or | GateKind::Nor => {
            let mut has_unknown = false;
            for &v in inputs {
                if v == LogicLevel::High {
                    return if kind == GateKind::Or {
                        LogicLevel::High
                    } else {
                        LogicLevel::Low
                    };
                }
                if matches!(v, LogicLevel::Unknown | LogicLevel::HighZ) {
                    has_unknown = true;
                }
            }
            let out = if has_unknown {
                LogicLevel::Unknown
            } else {
                LogicLevel::Low
            };
            if kind == GateKind::Nor {
                out.invert()
            } else {
                out
            }
        }
        GateKind::Xor | GateKind::Xnor => {
            let mut ones = 0usize;
            for &v in inputs {
                match v {
                    LogicLevel::High => ones += 1,
                    LogicLevel::Low => {}
                    LogicLevel::Unknown | LogicLevel::HighZ => return LogicLevel::Unknown,
                }
            }
            let parity = if ones % 2 == 1 {
                LogicLevel::High
            } else {
                LogicLevel::Low
            };
            if kind == GateKind::Xnor {
                parity.invert()
            } else {
                parity
            }
        }
    }
}

/// Quine-McCluskey implicant for the EWB-style Logic Converter tool (supports up to 8 variables).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct Implicant {
    bits: u16,
    mask: u16, // 1 = don't-care bit
}

impl Implicant {
    fn covers(&self, minterm: u16) -> bool {
        ((self.bits ^ minterm) & !self.mask) == 0
    }

    fn combine(&self, other: &Self) -> Option<Self> {
        if self.mask != other.mask {
            return None;
        }
        let diff = (self.bits ^ other.bits) & !self.mask;
        if diff.count_ones() == 1 {
            Some(Self {
                bits: self.bits & !diff,
                mask: self.mask | diff,
            })
        } else {
            None
        }
    }

    fn to_term(&self, var_count: usize) -> String {
        let mut s = String::new();
        for i in 0..var_count {
            let bit = 1u16 << (var_count - 1 - i);
            if (self.mask & bit) != 0 {
                continue;
            }
            let name = (b'A' + i as u8) as char;
            s.push(name);
            if (self.bits & bit) == 0 {
                s.push('\'');
            }
        }
        if s.is_empty() {
            "1".to_string()
        } else {
            s
        }
    }
}

/// Minimizes a truth table (`outputs.len() == 1 << var_count`, `0=false, 1=true, 2=don't-care X`) into SOP.
pub fn minimize_truth_table_dc(var_count: usize, outputs: &[u8]) -> String {
    if var_count == 0 || var_count > 8 || outputs.len() != (1 << var_count) {
        return "0".to_string();
    }
    let minterms: Vec<u16> = outputs
        .iter()
        .enumerate()
        .filter_map(|(i, &v)| if v == 1 { Some(i as u16) } else { None })
        .collect();
    if minterms.is_empty() {
        return "0".to_string();
    }
    if outputs.iter().all(|&v| v != 0) {
        return "1".to_string();
    }

    let mut current: Vec<Implicant> = outputs
        .iter()
        .enumerate()
        .filter_map(|(i, &v)| {
            if v != 0 {
                Some(Implicant {
                    bits: i as u16,
                    mask: 0,
                })
            } else {
                None
            }
        })
        .collect();
    let mut primes: Vec<Implicant> = Vec::new();

    while !current.is_empty() {
        let mut used = vec![false; current.len()];
        let mut next: Vec<Implicant> = Vec::new();
        let mut next_set: std::collections::HashSet<Implicant> = std::collections::HashSet::new();
        for i in 0..current.len() {
            for j in (i + 1)..current.len() {
                if let Some(merged) = current[i].combine(&current[j]) {
                    used[i] = true;
                    used[j] = true;
                    if next_set.insert(merged.clone()) {
                        next.push(merged);
                    }
                }
            }
        }
        for (i, imp) in current.into_iter().enumerate() {
            if !used[i] && !primes.contains(&imp) {
                primes.push(imp);
            }
        }
        current = next;
    }

    // Greedy prime implicant cover (essential primes on true minterms first, then largest cover).
    let mut uncovered = minterms;
    let mut selected: Vec<Implicant> = Vec::new();

    while !uncovered.is_empty() {
        let mut essential: Option<usize> = None;
        for &m in &uncovered {
            let mut owners = primes.iter().enumerate().filter(|(_, p)| p.covers(m));
            if let (Some((idx, _)), None) = (owners.next(), owners.next()) {
                essential = Some(idx);
                break;
            }
        }
        let chosen = essential.unwrap_or_else(|| {
            primes
                .iter()
                .enumerate()
                .max_by_key(|(_, p)| uncovered.iter().filter(|&&m| p.covers(m)).count())
                .map(|(idx, _)| idx)
                .unwrap_or(0)
        });
        let imp = primes.remove(chosen);
        uncovered.retain(|&m| !imp.covers(m));
        selected.push(imp);
    }

    selected
        .into_iter()
        .map(|p| p.to_term(var_count))
        .collect::<Vec<_>>()
        .join(" + ")
}

/// Minimizes a truth table (`outputs.len() == 1 << var_count`) into a SOP Boolean expression.
pub fn minimize_truth_table(var_count: usize, outputs: &[bool]) -> String {
    let encoded: Vec<u8> = outputs.iter().map(|&on| u8::from(on)).collect();
    minimize_truth_table_dc(var_count, &encoded)
}
