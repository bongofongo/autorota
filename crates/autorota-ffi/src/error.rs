use autorota_core::i18n;

/// Stable error code surfaced to callers. The variant carries no data so it
/// can be transported across the FFI boundary cheaply and used as a key into
/// the Fluent translation bundle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ErrorCode {
    DbConnectionFailed,
    DbRowNotFound,
    DbGeneric,
    NotFoundEmployee,
    NotFoundSchedule,
    NotFoundGeneric,
    InvalidDate,
    InvalidSaveTag,
    InvalidPdf,
    InvalidImport,
    InvalidGeneric,
    SeedAlreadyExists,
}

impl ErrorCode {
    pub fn fluent_id(self) -> &'static str {
        match self {
            ErrorCode::DbConnectionFailed => "err-db-connection-failed",
            ErrorCode::DbRowNotFound => "err-db-row-not-found",
            ErrorCode::DbGeneric => "err-db-generic",
            ErrorCode::NotFoundEmployee => "err-not-found-employee",
            ErrorCode::NotFoundSchedule => "err-not-found-schedule",
            ErrorCode::NotFoundGeneric => "err-not-found-generic",
            ErrorCode::InvalidDate => "err-invalid-date",
            ErrorCode::InvalidSaveTag => "err-invalid-save-tag",
            ErrorCode::InvalidPdf => "err-invalid-pdf",
            ErrorCode::InvalidImport => "err-invalid-import",
            ErrorCode::InvalidGeneric => "err-invalid-generic",
            ErrorCode::SeedAlreadyExists => "err-seed-already-exists",
        }
    }
}

/// Typed error returned across the FFI boundary.
/// Swift receives a `FfiError` enum that can be pattern-matched in do/catch.
///
/// `code` is the stable, locale-agnostic key for translation lookup.
/// `msg` is an English developer-oriented detail used for logs / debugging,
/// not for direct user display — call `localizeError` to produce user copy.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiError {
    #[error("database error [{code:?}]: {msg}")]
    Db { code: ErrorCode, msg: String },

    #[error("not found [{code:?}]: {msg}")]
    NotFound { code: ErrorCode, msg: String },

    #[error("invalid argument [{code:?}]: {msg}")]
    InvalidArgument { code: ErrorCode, msg: String },
}

impl FfiError {
    pub fn db<S: Into<String>>(code: ErrorCode, msg: S) -> Self {
        FfiError::Db {
            code,
            msg: msg.into(),
        }
    }
    pub fn not_found<S: Into<String>>(code: ErrorCode, msg: S) -> Self {
        FfiError::NotFound {
            code,
            msg: msg.into(),
        }
    }
    pub fn invalid<S: Into<String>>(code: ErrorCode, msg: S) -> Self {
        FfiError::InvalidArgument {
            code,
            msg: msg.into(),
        }
    }

    pub fn code(&self) -> ErrorCode {
        match self {
            FfiError::Db { code, .. }
            | FfiError::NotFound { code, .. }
            | FfiError::InvalidArgument { code, .. } => *code,
        }
    }
}

impl From<sqlx::Error> for FfiError {
    fn from(e: sqlx::Error) -> Self {
        match &e {
            sqlx::Error::RowNotFound => FfiError::NotFound {
                code: ErrorCode::DbRowNotFound,
                msg: "A referenced record no longer exists. It may have been deleted.".to_string(),
            },
            sqlx::Error::Database(db_err) => FfiError::Db {
                code: ErrorCode::DbGeneric,
                msg: format!("Database error: {}", db_err.message()),
            },
            _ => FfiError::Db {
                code: ErrorCode::DbGeneric,
                msg: e.to_string(),
            },
        }
    }
}

/// Look up the localized user-facing message for a given error code.
/// Exposed via UniFFI so Swift / Kotlin callers can render translated alerts.
#[uniffi::export]
pub fn localize_error(code: ErrorCode, locale_id: String) -> String {
    i18n::localize(code.fluent_id(), &locale_id)
}
