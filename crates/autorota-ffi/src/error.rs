/// Typed error returned across the FFI boundary.
/// Swift receives a `FfiError` enum that can be pattern-matched in do/catch.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiError {
    #[error("database error: {msg}")]
    Db { msg: String },

    #[error("not found: {msg}")]
    NotFound { msg: String },

    #[error("invalid argument: {msg}")]
    InvalidArgument { msg: String },

    #[error("already finalized")]
    AlreadyFinalized,
}

impl From<sqlx::Error> for FfiError {
    fn from(e: sqlx::Error) -> Self {
        FfiError::Db { msg: e.to_string() }
    }
}
