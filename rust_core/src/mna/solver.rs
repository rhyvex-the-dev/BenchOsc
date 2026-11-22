use crate::error::{SimError, SimErrorCode};

const PIVOT_EPS: f64 = 1e-18;

/// Minimal complex scalar for small-signal AC MNA (`Y(jw) * V = I`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Complex64 {
    pub re: f64,
    pub im: f64,
}

impl Complex64 {
    pub const ZERO: Self = Self { re: 0.0, im: 0.0 };

    pub const fn new(re: f64, im: f64) -> Self {
        Self { re, im }
    }

    pub fn abs(self) -> f64 {
        self.re.hypot(self.im)
    }

    pub fn arg_deg(self) -> f64 {
        self.im.atan2(self.re).to_degrees()
    }
}

trait ScalarAbs: Copy {
    fn scalar_abs(self) -> f64;
    fn is_zero(self) -> bool;
}

impl ScalarAbs for f64 {
    #[inline]
    fn scalar_abs(self) -> f64 {
        self.abs()
    }
    #[inline]
    fn is_zero(self) -> bool {
        self == 0.0
    }
}

impl ScalarAbs for Complex64 {
    #[inline]
    fn scalar_abs(self) -> f64 {
        self.abs()
    }
    #[inline]
    fn is_zero(self) -> bool {
        self.re == 0.0 && self.im == 0.0
    }
}

impl std::ops::Neg for Complex64 {
    type Output = Self;
    fn neg(self) -> Self {
        Self::new(-self.re, -self.im)
    }
}

impl std::ops::Add for Complex64 {
    type Output = Self;
    fn add(self, rhs: Self) -> Self {
        Self::new(self.re + rhs.re, self.im + rhs.im)
    }
}

impl std::ops::AddAssign for Complex64 {
    fn add_assign(&mut self, rhs: Self) {
        self.re += rhs.re;
        self.im += rhs.im;
    }
}

impl std::ops::Sub for Complex64 {
    type Output = Self;
    fn sub(self, rhs: Self) -> Self {
        Self::new(self.re - rhs.re, self.im - rhs.im)
    }
}

impl std::ops::SubAssign for Complex64 {
    fn sub_assign(&mut self, rhs: Self) {
        self.re -= rhs.re;
        self.im -= rhs.im;
    }
}

impl std::ops::Mul for Complex64 {
    type Output = Self;
    fn mul(self, rhs: Self) -> Self {
        Self::new(
            self.re * rhs.re - self.im * rhs.im,
            self.re * rhs.im + self.im * rhs.re,
        )
    }
}

impl std::ops::Div for Complex64 {
    type Output = Self;
    fn div(self, rhs: Self) -> Self {
        // Smith scaling prevents overflow/underflow for large or tiny complex denominators.
        if rhs.re.abs() >= rhs.im.abs() {
            let r = rhs.im / rhs.re;
            let d = rhs.re + rhs.im * r;
            Self::new((self.re + self.im * r) / d, (self.im - self.re * r) / d)
        } else {
            let r = rhs.re / rhs.im;
            let d = rhs.re * r + rhs.im;
            Self::new((self.re * r + self.im) / d, (self.im * r - self.re) / d)
        }
    }
}

const SPARSE_THRESHOLD: usize = 48;

/// Hybrid linear system `A * x = b`: dense fast-path for small circuits (`n <= 48`)
/// and pure-Rust Sparse LU with partial pivoting for large schematics (`n > 48`).
pub struct DenseSystem {
    pub n: usize,
    sparse: bool,
    pub a: Vec<f64>,
    rows: Vec<Vec<(usize, f64)>>,
    pub b: Vec<f64>,
    touched: Vec<usize>,
    touched_gen: Vec<u32>,
    stamp_gen: u32,
}

impl DenseSystem {
    pub fn new(n: usize) -> Self {
        let sparse = n > SPARSE_THRESHOLD;
        Self {
            n,
            sparse,
            a: if sparse { Vec::new() } else { vec![0.0; n * n] },
            rows: if sparse {
                vec![Vec::new(); n]
            } else {
                Vec::new()
            },
            b: vec![0.0; n],
            touched: Vec::new(),
            touched_gen: if sparse { Vec::new() } else { vec![0; n * n] },
            stamp_gen: 1,
        }
    }

    pub fn clear(&mut self) {
        if self.sparse {
            for r in &mut self.rows {
                r.clear();
            }
        } else {
            self.a.fill(0.0);
            self.touched.clear();
            self.stamp_gen = self.stamp_gen.wrapping_add(1);
            if self.stamp_gen == 0 {
                self.touched_gen.fill(0);
                self.stamp_gen = 1;
            }
        }
        self.b.fill(0.0);
    }

    pub fn clear_touched(&mut self) {
        if self.sparse {
            for r in &mut self.rows {
                r.clear();
            }
        } else {
            for idx in self.touched.drain(..) {
                self.a[idx] = 0.0;
            }
            self.stamp_gen = self.stamp_gen.wrapping_add(1);
            if self.stamp_gen == 0 {
                self.touched_gen.fill(0);
                self.stamp_gen = 1;
            }
        }
        self.b.fill(0.0);
    }

    #[inline]
    pub fn add_a(&mut self, r: usize, c: usize, val: f64) {
        if val == 0.0 {
            return;
        }
        if self.sparse {
            self.rows[r].push((c, val));
        } else {
            let idx = r * self.n + c;
            self.a[idx] += val;
            if self.touched_gen[idx] != self.stamp_gen {
                self.touched_gen[idx] = self.stamp_gen;
                self.touched.push(idx);
            }
        }
    }

    pub fn for_each_nonzero(&self, mut f: impl FnMut(usize, usize, f64)) {
        if self.sparse {
            for (r, row) in self.rows.iter().enumerate() {
                for &(c, v) in row {
                    if v != 0.0 {
                        f(r, c, v);
                    }
                }
            }
        } else {
            for &idx in &self.touched {
                let v = self.a[idx];
                if v != 0.0 {
                    f(idx / self.n, idx % self.n, v);
                }
            }
        }
    }

    #[inline]
    pub fn add_b(&mut self, r: usize, val: f64) {
        self.b[r] += val;
    }

    /// Stamps a two-terminal conductance `g` between matrix indices `p` and `q` (`None` = GND).
    pub fn stamp_conductance(&mut self, p: Option<usize>, q: Option<usize>, g: f64) {
        if let Some(i) = p {
            self.add_a(i, i, g);
        }
        if let Some(j) = q {
            self.add_a(j, j, g);
        }
        if let (Some(i), Some(j)) = (p, q) {
            self.add_a(i, j, -g);
            self.add_a(j, i, -g);
        }
    }

    /// Stamps an independent current source `i_val` flowing from `p` to `q`.
    pub fn stamp_current(&mut self, p: Option<usize>, q: Option<usize>, i_val: f64) {
        if let Some(i) = p {
            self.add_b(i, -i_val);
        }
        if let Some(j) = q {
            self.add_b(j, i_val);
        }
    }

    /// Solves `A * x = b` in-place via dense partial-pivoting GE (`n <= 48`) or sparse LU (`n > 48`).
    pub fn solve(&mut self) -> Result<Vec<f64>, SimError> {
        let n = self.n;
        if n == 0 {
            return Ok(Vec::new());
        }
        if self.sparse {
            return self.solve_sparse();
        }
        solve_dense(n, &mut self.a, &mut self.b)
    }

    fn solve_sparse(&mut self) -> Result<Vec<f64>, SimError> {
        solve_sparse_rows(&mut self.rows, &mut self.b)
    }
}

/// Shared partial-pivoted Sparse LU solver for both real and complex systems (`n > 48`).
/// Uses row-length tie-breaking (Markowitz-style sparse pivot) and reuses a single `piv_tail` buffer.
fn solve_sparse_rows<T>(rows: &mut [Vec<(usize, T)>], b: &mut [T]) -> Result<Vec<T>, SimError>
where
    T: Copy
        + ScalarAbs
        + std::ops::Add<Output = T>
        + std::ops::AddAssign
        + std::ops::Sub<Output = T>
        + std::ops::SubAssign
        + std::ops::Mul<Output = T>
        + std::ops::Div<Output = T>
        + std::ops::Neg<Output = T>
        + Default,
{
    let n = rows.len();
    for row in rows.iter_mut() {
        row.sort_unstable_by_key(|&(c, _)| c);
        let mut w = 0usize;
        for idx in 0..row.len() {
            let (c, v) = row[idx];
            if w > 0 && row[w - 1].0 == c {
                row[w - 1].1 += v;
            } else {
                row[w] = (c, v);
                w += 1;
            }
        }
        row.truncate(w);
        row.retain(|&(_, v)| !v.is_zero());
    }

    let mut piv_tail: Vec<(usize, T)> = Vec::new();
    let mut merged: Vec<(usize, T)> = Vec::new();
    for k in 0..n {
        let mut pivot_row = k;
        let mut max_val = 0.0_f64;
        let mut min_nnz = usize::MAX;
        for (r, row) in rows.iter().enumerate().skip(k) {
            if let Ok(pos) = row.binary_search_by_key(&k, |&(c, _)| c) {
                let av = row[pos].1.scalar_abs();
                let nnz = row.len();
                if av > max_val * 0.5
                    && (av > max_val * 2.0 || nnz < min_nnz || (nnz == min_nnz && av > max_val))
                {
                    max_val = max_val.max(av);
                    min_nnz = nnz;
                    pivot_row = r;
                } else if av > max_val && max_val < PIVOT_EPS {
                    max_val = av;
                    min_nnz = nnz;
                    pivot_row = r;
                }
            }
        }
        if !max_val.is_finite() || max_val < PIVOT_EPS {
            return Err(SimError::new(SimErrorCode::SingularMatrix, (k + 1) as i32));
        }
        if pivot_row != k {
            rows.swap(k, pivot_row);
            b.swap(k, pivot_row);
        }

        let piv_pos = rows[k]
            .binary_search_by_key(&k, |&(c, _)| c)
            .map_err(|_| SimError::new(SimErrorCode::SingularMatrix, (k + 1) as i32))?;
        let pivot = rows[k][piv_pos].1;
        if !pivot.scalar_abs().is_finite() || pivot.scalar_abs() < PIVOT_EPS {
            return Err(SimError::new(SimErrorCode::SingularMatrix, (k + 1) as i32));
        }
        piv_tail.clear();
        piv_tail.extend_from_slice(&rows[k][piv_pos + 1..]);
        let bk = b[k];

        for r in (k + 1)..n {
            let Ok(r_k_pos) = rows[r].binary_search_by_key(&k, |&(c, _)| c) else {
                continue;
            };
            let factor = rows[r][r_k_pos].1 / pivot;
            if factor.is_zero() {
                continue;
            }
            b[r] -= factor * bk;

            merged.clear();
            let r_tail = &rows[r][r_k_pos + 1..];
            let mut i = 0usize;
            let mut j = 0usize;
            while i < r_tail.len() && j < piv_tail.len() {
                let (cr, vr) = r_tail[i];
                let (cp, vp) = piv_tail[j];
                if cr < cp {
                    merged.push((cr, vr));
                    i += 1;
                } else if cp < cr {
                    let nv = -(factor * vp);
                    if !nv.is_zero() {
                        merged.push((cp, nv));
                    }
                    j += 1;
                } else {
                    let nv = vr - factor * vp;
                    if !nv.is_zero() {
                        merged.push((cr, nv));
                    }
                    i += 1;
                    j += 1;
                }
            }
            merged.extend_from_slice(&r_tail[i..]);
            for &(cp, vp) in &piv_tail[j..] {
                let nv = -(factor * vp);
                if !nv.is_zero() {
                    merged.push((cp, nv));
                }
            }
            rows[r].truncate(r_k_pos);
            rows[r].extend_from_slice(&merged);
        }
    }

    let mut x = vec![T::default(); n];
    for r in (0..n).rev() {
        let mut sum = b[r];
        let mut diag = T::default();
        for &(c, v) in &rows[r] {
            if c == r {
                diag = v;
            } else if c > r {
                sum -= v * x[c];
            }
        }
        let d_abs = diag.scalar_abs();
        if !d_abs.is_finite() || d_abs < PIVOT_EPS {
            return Err(SimError::new(SimErrorCode::SingularMatrix, (r + 1) as i32));
        }
        x[r] = sum / diag;
        if !x[r].scalar_abs().is_finite() {
            return Err(SimError::new(SimErrorCode::SingularMatrix, (r + 1) as i32));
        }
    }
    Ok(x)
}

impl Default for Complex64 {
    fn default() -> Self {
        Self::ZERO
    }
}

/// Hybrid dense/sparse complex linear system for small-signal AC sweep (`n > 48` uses sparse LU).
pub struct ComplexSystem {
    pub n: usize,
    sparse: bool,
    pub a: Vec<Complex64>,
    rows: Vec<Vec<(usize, Complex64)>>,
    pub b: Vec<Complex64>,
}

impl ComplexSystem {
    pub fn new(n: usize) -> Self {
        let sparse = n > SPARSE_THRESHOLD;
        Self {
            n,
            sparse,
            a: if sparse {
                Vec::new()
            } else {
                vec![Complex64::ZERO; n * n]
            },
            rows: if sparse {
                vec![Vec::new(); n]
            } else {
                Vec::new()
            },
            b: vec![Complex64::ZERO; n],
        }
    }

    pub fn clear(&mut self) {
        if self.sparse {
            for r in &mut self.rows {
                r.clear();
            }
        } else {
            self.a.fill(Complex64::ZERO);
        }
        self.b.fill(Complex64::ZERO);
    }

    #[inline]
    pub fn add_a(&mut self, r: usize, c: usize, val: Complex64) {
        if val.is_zero() {
            return;
        }
        if self.sparse {
            self.rows[r].push((c, val));
        } else {
            self.a[r * self.n + c] += val;
        }
    }

    #[inline]
    pub fn add_b(&mut self, r: usize, val: Complex64) {
        self.b[r] += val;
    }

    pub fn stamp_admittance(&mut self, p: Option<usize>, q: Option<usize>, y: Complex64) {
        if let Some(i) = p {
            self.add_a(i, i, y);
        }
        if let Some(j) = q {
            self.add_a(j, j, y);
        }
        if let (Some(i), Some(j)) = (p, q) {
            let neg = Complex64::ZERO - y;
            self.add_a(i, j, neg);
            self.add_a(j, i, neg);
        }
    }

    pub fn solve(&mut self) -> Result<Vec<Complex64>, SimError> {
        let n = self.n;
        if n == 0 {
            return Ok(Vec::new());
        }
        if self.sparse {
            return solve_sparse_rows(&mut self.rows, &mut self.b);
        }
        solve_dense(n, &mut self.a, &mut self.b)
    }
}

/// Shared partial-pivoted dense Gaussian elimination solver for both real and complex systems.
fn solve_dense<T>(n: usize, a: &mut [T], b: &mut [T]) -> Result<Vec<T>, SimError>
where
    T: Copy
        + Default
        + ScalarAbs
        + std::ops::SubAssign
        + std::ops::Mul<Output = T>
        + std::ops::Div<Output = T>,
{
    for k in 0..n {
        let mut pivot_row = k;
        let mut max_val = a[k * n + k].scalar_abs();
        for r in (k + 1)..n {
            let v = a[r * n + k].scalar_abs();
            if v > max_val {
                max_val = v;
                pivot_row = r;
            }
        }
        if !max_val.is_finite() || max_val < PIVOT_EPS {
            return Err(SimError::new(SimErrorCode::SingularMatrix, (k + 1) as i32));
        }
        if pivot_row != k {
            for c in k..n {
                a.swap(k * n + c, pivot_row * n + c);
            }
            b.swap(k, pivot_row);
        }
        let pivot = a[k * n + k];
        for r in (k + 1)..n {
            let factor = a[r * n + k] / pivot;
            if factor.is_zero() {
                continue;
            }
            for c in k..n {
                let v = a[k * n + c];
                a[r * n + c] -= factor * v;
            }
            let bk = b[k];
            b[r] -= factor * bk;
        }
    }
    let mut x = vec![T::default(); n];
    for r in (0..n).rev() {
        let mut sum = b[r];
        for (&aij, &xj) in a[r * n + r + 1..r * n + n].iter().zip(&x[r + 1..n]) {
            sum -= aij * xj;
        }
        let diag = a[r * n + r];
        let d_abs = diag.scalar_abs();
        if !d_abs.is_finite() || d_abs < PIVOT_EPS {
            return Err(SimError::new(SimErrorCode::SingularMatrix, (r + 1) as i32));
        }
        x[r] = sum / diag;
        if !x[r].scalar_abs().is_finite() {
            return Err(SimError::new(SimErrorCode::SingularMatrix, (r + 1) as i32));
        }
    }
    Ok(x)
}
