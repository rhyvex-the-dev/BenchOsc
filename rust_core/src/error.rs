/// Structured error codes returned across FFI so the UI can localize messages
/// via `AppLocalizations` without hardcoded English prose in Rust.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SimErrorCode {
    Ok = 0,
    MissingGround = 1,
    FloatingNode = 2,
    SingularMatrix = 3,
    ConvergenceFailed = 4,
    InvalidParameter = 5,
    UnknownComponent = 6,
    InvalidNetlist = 7,
    NullHandle = 8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SimError {
    pub code: SimErrorCode,
    /// Offending node id, component id, or 1-based line number (0 when unused).
    pub detail_id: i32,
}

impl SimError {
    pub const fn new(code: SimErrorCode, detail_id: i32) -> Self {
        Self { code, detail_id }
    }
}
