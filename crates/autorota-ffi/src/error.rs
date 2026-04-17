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
}

impl From<sqlx::Error> for FfiError {
    fn from(e: sqlx::Error) -> Self {
        let msg = match &e {
            sqlx::Error::RowNotFound => {
                "A referenced record no longer exists. It may have been deleted.".to_string()
            }
            sqlx::Error::Database(db_err) => {
                format!("Database error: {}", db_err.message())
            }
            _ => e.to_string(),
        };
        FfiError::Db { msg }
    }
}
