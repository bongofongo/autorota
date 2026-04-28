//! Shared test infrastructure for autorota-core.
//!
//! Available to both inline `#[cfg(test)]` modules and integration tests via
//! `use autorota_core::testutil::*;`

pub mod assertions;
pub mod builders;
pub mod corpus;
pub mod db;

pub use assertions::*;
pub use builders::*;
pub use db::*;

use chrono::{NaiveDate, NaiveTime};

/// Creates a `NaiveDate` in March 2026 (23=Mon, 24=Tue, 25=Wed, ...).
pub fn date(d: u32) -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 3, d).unwrap()
}

/// Creates a `NaiveTime` at the given hour with minute 0.
pub fn time(h: u32) -> NaiveTime {
    NaiveTime::from_hms_opt(h, 0, 0).unwrap()
}

/// Creates a `NaiveTime` with the given hour and minute.
pub fn hm(h: u32, m: u32) -> NaiveTime {
    NaiveTime::from_hms_opt(h, m, 0).unwrap()
}

/// Returns Monday 2026-03-23 — a convenient week start for tests.
pub fn week_start() -> NaiveDate {
    date(23)
}
