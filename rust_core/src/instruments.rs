use std::collections::VecDeque;

use crate::mna::solver::Complex64;

#[derive(Debug, Clone, Copy)]
pub struct ScopeSample {
    pub t: f64,
    pub ch: [f64; 4],
}

/// Bounded ring buffer decoupling high-rate simulation steps from 60Hz/120Hz display vsync.
pub struct ScopeBuffer {
    pub capacity: usize,
    pub samples: VecDeque<ScopeSample>,
}

impl ScopeBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity: capacity.max(64),
            samples: VecDeque::new(),
        }
    }

    pub fn clear(&mut self) {
        self.samples.clear();
    }

    pub fn push(&mut self, t: f64, ch: [f64; 4]) {
        if self.samples.len() >= self.capacity {
            self.samples.pop_front();
        }
        self.samples.push_back(ScopeSample { t, ch });
    }

    /// Computes time-weighted DC average and AC RMS for a channel over the buffered window.
    pub fn channel_stats(&self, ch: usize) -> (f64, f64, f64, f64) {
        if self.samples.is_empty() || ch >= 4 {
            return (0.0, 0.0, 0.0, 0.0);
        }
        if self.samples.len() == 1 {
            let v = self.samples[0].ch[ch];
            return (v, 0.0, v, v);
        }
        let mut min_v = f64::INFINITY;
        let mut max_v = f64::NEG_INFINITY;
        let mut sum_dt = 0.0;
        let mut area = 0.0;
        for i in 0..self.samples.len() {
            let v = self.samples[i].ch[ch];
            min_v = min_v.min(v);
            max_v = max_v.max(v);
            if i + 1 < self.samples.len() {
                let dt = (self.samples[i + 1].t - self.samples[i].t).max(0.0);
                sum_dt += dt;
                area += 0.5 * (v + self.samples[i + 1].ch[ch]) * dt;
            }
        }
        if sum_dt <= 1e-18 {
            let n = self.samples.len() as f64;
            let dc = self.samples.iter().map(|s| s.ch[ch]).sum::<f64>() / n;
            let ac_rms = (self
                .samples
                .iter()
                .map(|s| {
                    let d = s.ch[ch] - dc;
                    d * d
                })
                .sum::<f64>()
                / n)
                .sqrt();
            return (dc, ac_rms, min_v, max_v);
        }
        let dc = area / sum_dt;
        let mut sq_area = 0.0;
        for i in 0..(self.samples.len() - 1) {
            let dt = (self.samples[i + 1].t - self.samples[i].t).max(0.0);
            let a = self.samples[i].ch[ch] - dc;
            let b = self.samples[i + 1].ch[ch] - dc;
            sq_area += (a * a + a * b + b * b) * (dt / 3.0);
        }
        (dc, (sq_area / sum_dt).max(0.0).sqrt(), min_v, max_v)
    }

    /// Resamples the newest `max_len` window linearly onto uniform timestamps for distortion-free FFT/THD.
    pub fn resample_uniform(&self, ch: usize, max_len: usize) -> Vec<f64> {
        if ch >= 4 || self.samples.len() < 2 || max_len < 2 {
            return Vec::new();
        }
        let take = self.samples.len().min(max_len);
        let start = self.samples.len() - take;
        let t0 = self.samples[start].t;
        let t1 = self.samples[self.samples.len() - 1].t;
        if (t1 - t0) <= 1e-18 {
            return self.samples.iter().skip(start).map(|s| s.ch[ch]).collect();
        }
        let mut out = Vec::with_capacity(take);
        let mut cursor = start;
        let last_idx = self.samples.len() - 1;
        for i in 0..take {
            let t = t0 + (t1 - t0) * (i as f64 / (take - 1) as f64);
            while cursor + 1 < last_idx && self.samples[cursor + 1].t < t {
                cursor += 1;
            }
            let s0 = self.samples[cursor];
            let s1 = self.samples[(cursor + 1).min(last_idx)];
            let dt = s1.t - s0.t;
            let v = if dt > 1e-18 {
                let frac = ((t - s0.t) / dt).clamp(0.0, 1.0);
                s0.ch[ch] + (s1.ch[ch] - s0.ch[ch]) * frac
            } else {
                s0.ch[ch]
            };
            out.push(v);
        }
        out
    }

    /// Returns the uniform sample spacing `dt` used by `resample_uniform(_, max_len)` (`0.0` if <2 samples).
    pub fn resample_uniform_dt(&self, max_len: usize) -> f64 {
        if self.samples.len() < 2 || max_len < 2 {
            return 0.0;
        }
        let take = self.samples.len().min(max_len);
        let start = self.samples.len() - take;
        let span = self.samples[self.samples.len() - 1].t - self.samples[start].t;
        if span > 1e-18 {
            span / (take - 1) as f64
        } else {
            0.0
        }
    }

    /// Finds the most recent rising (or falling) edge crossing `level` for stable scope triggering.
    pub fn find_trigger_index(&self, ch: usize, level: f64, rising: bool) -> Option<usize> {
        if self.samples.len() < 2 || ch >= 4 {
            return None;
        }
        for i in (1..self.samples.len()).rev() {
            let prev = self.samples[i - 1].ch[ch];
            let curr = self.samples[i].ch[ch];
            if rising && prev < level && curr >= level {
                return Some(i);
            }
            if !rising && prev > level && curr <= level {
                return Some(i);
            }
        }
        None
    }
}

/// In-place radix-2 Cooley-Tukey FFT returning Hann-windowed magnitude spectrum (first N/2 bins).
/// Input length is sliced from the newest samples to the nearest power of 2 <= `samples.len()`.
pub fn compute_fft_magnitudes(samples: &[f64]) -> Vec<f64> {
    if samples.len() < 2 {
        return Vec::new();
    }
    let n = samples.len().next_power_of_two()
        >> if samples.len().is_power_of_two() {
            0
        } else {
            1
        };
    if n < 2 {
        return Vec::new();
    }
    let slice = &samples[samples.len() - n..];
    let dc_mean = slice.iter().sum::<f64>() / n as f64;
    let denom = n as f64;
    let mut buf: Vec<Complex64> = slice
        .iter()
        .enumerate()
        .map(|(i, &v)| {
            let w = 0.5 * (1.0 - (2.0 * std::f64::consts::PI * i as f64 / denom).cos());
            Complex64::new((v - dc_mean) * w, 0.0)
        })
        .collect();

    // Bit-reversal permutation
    let mut j = 0usize;
    for i in 1..n {
        let mut bit = n >> 1;
        while (j & bit) != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if i < j {
            buf.swap(i, j);
        }
    }

    let mut len = 2usize;
    while len <= n {
        let ang = -2.0 * std::f64::consts::PI / (len as f64);
        let wlen = Complex64::new(ang.cos(), ang.sin());
        for i in (0..n).step_by(len) {
            let mut w = Complex64::new(1.0, 0.0);
            for k in 0..(len / 2) {
                let u = buf[i + k];
                let v = buf[i + k + len / 2] * w;
                buf[i + k] = u + v;
                buf[i + k + len / 2] = u - v;
                w = w * wlen;
            }
        }
        len <<= 1;
    }

    let half = n / 2;
    (0..half)
        .map(|i| {
            // Coherent gain of periodic Hann window is 0.5; bin 0 retains original mean DC magnitude.
            if i == 0 {
                dc_mean.abs()
            } else {
                buf[i].abs() * (4.0 / n as f64)
            }
        })
        .collect()
}
