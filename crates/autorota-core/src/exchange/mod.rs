//! Data bundle exchange: full-fidelity JSON export/import of the reference
//! data managed on the Employees and Shifts pages — roles, employees (with
//! weekly availability), employee availability exceptions, shift templates
//! (with role requirements), and shift template exceptions.
//!
//! Any subset of sections can be exported; a bundle file simply omits the
//! sections it doesn't carry. Import applies whatever sections are present,
//! matching records by name (employees: first+last+nickname, templates and
//! roles: name) and upserting — existing rows are updated, new rows inserted,
//! nothing is ever deleted. Roles referenced by employees or templates are
//! auto-created. Exceptions referencing an unknown employee/template are
//! skipped with a warning.

use std::collections::HashMap;

use chrono::{NaiveDate, NaiveTime, Weekday};
use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;

use crate::db::queries;
use crate::export::config::ExportResult;
use crate::models::availability::Availability;
use crate::models::employee::Employee;
use crate::models::overrides::{
    DayAvailability, EmployeeAvailabilityOverride, OverrideSource, ShiftTemplateOverride,
};
use crate::models::shift::{RoleRequirement, ShiftTemplate};
use crate::models::validation::{ValidationError, validate_employee, validate_shift_template};

/// Highest bundle format version this build can read.
pub const BUNDLE_VERSION: u32 = 1;

#[derive(Debug, thiserror::Error)]
pub enum ExchangeError {
    #[error("parse error: {0}")]
    Parse(String),
    #[error("unsupported bundle version {0} (this app reads up to {BUNDLE_VERSION})")]
    UnsupportedVersion(u32),
    #[error("db error: {0}")]
    Db(#[from] sqlx::Error),
    #[error("{context}: {error}")]
    Validation {
        context: String,
        error: ValidationError,
    },
}

/// Which bundle sections to include in an export.
#[derive(Debug, Clone, Copy, Default)]
pub struct BundleSections {
    pub roles: bool,
    pub employees: bool,
    pub employee_exceptions: bool,
    pub shift_templates: bool,
    pub shift_exceptions: bool,
}

impl BundleSections {
    pub fn all() -> Self {
        Self {
            roles: true,
            employees: true,
            employee_exceptions: true,
            shift_templates: true,
            shift_exceptions: true,
        }
    }

    /// Short slug describing the enabled sections, used in export filenames.
    fn slug(&self) -> String {
        let all = self.roles
            && self.employees
            && self.employee_exceptions
            && self.shift_templates
            && self.shift_exceptions;
        if all {
            return "all".into();
        }
        let mut parts = Vec::new();
        if self.roles {
            parts.push("roles");
        }
        if self.employees {
            parts.push("employees");
        }
        if self.employee_exceptions {
            parts.push("employee-exceptions");
        }
        if self.shift_templates {
            parts.push("shifts");
        }
        if self.shift_exceptions {
            parts.push("shift-exceptions");
        }
        if parts.is_empty() {
            "empty".into()
        } else {
            parts.join("+")
        }
    }
}

// ── Bundle format ────────────────────────────────────────────────────────────

/// The serialized bundle. Sections are optional: an absent section means "not
/// carried by this file" and is ignored on import.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DataBundle {
    pub version: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub roles: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub employees: Option<Vec<BundleEmployee>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub employee_exceptions: Option<Vec<BundleEmployeeException>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shift_templates: Option<Vec<BundleShiftTemplate>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shift_exceptions: Option<Vec<BundleShiftException>>,
}

/// One employee with every field the Employees page manages, including the
/// default weekly availability grid. No database id — import matches by name.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BundleEmployee {
    pub first_name: String,
    #[serde(default)]
    pub last_name: String,
    #[serde(default)]
    pub nickname: Option<String>,
    #[serde(default)]
    pub roles: Vec<String>,
    #[serde(default)]
    pub start_date: Option<NaiveDate>,
    #[serde(default)]
    pub target_weekly_hours: f32,
    #[serde(default)]
    pub weekly_hours_deviation: f32,
    #[serde(default = "default_max_daily_hours")]
    pub max_daily_hours: f32,
    #[serde(default)]
    pub notes: Option<String>,
    #[serde(default)]
    pub bank_details: Option<String>,
    #[serde(default)]
    pub phone: Option<String>,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub preferred_contact: Option<String>,
    #[serde(default)]
    pub hourly_wage: Option<f32>,
    #[serde(default)]
    pub wage_currency: Option<String>,
    #[serde(default)]
    pub default_availability: Availability,
}

fn default_max_daily_hours() -> f32 {
    8.0
}

/// A date-specific availability override, keyed to its employee by name.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BundleEmployeeException {
    pub first_name: String,
    #[serde(default)]
    pub last_name: String,
    #[serde(default)]
    pub nickname: Option<String>,
    pub date: NaiveDate,
    #[serde(default)]
    pub availability: DayAvailability,
    #[serde(default)]
    pub notes: Option<String>,
    #[serde(default)]
    pub source: OverrideSource,
}

/// One shift template with its role requirements. No database id — import
/// matches by template name.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BundleShiftTemplate {
    pub name: String,
    #[serde(default)]
    pub weekdays: Vec<Weekday>,
    pub start_time: NaiveTime,
    pub end_time: NaiveTime,
    #[serde(default)]
    pub required_role: String,
    #[serde(default = "default_headcount")]
    pub min_employees: u32,
    #[serde(default = "default_headcount")]
    pub max_employees: u32,
    #[serde(default)]
    pub role_requirements: Vec<RoleRequirement>,
}

fn default_headcount() -> u32 {
    1
}

/// A date-specific template override, keyed to its template by name.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BundleShiftException {
    pub template_name: String,
    pub date: NaiveDate,
    #[serde(default)]
    pub cancelled: bool,
    #[serde(default)]
    pub start_time: Option<NaiveTime>,
    #[serde(default)]
    pub end_time: Option<NaiveTime>,
    #[serde(default)]
    pub min_employees: Option<u32>,
    #[serde(default)]
    pub max_employees: Option<u32>,
    #[serde(default)]
    pub notes: Option<String>,
}

/// Per-section record counts for a parsed bundle (import preview).
#[derive(Debug, Clone, Copy, Default)]
pub struct BundleInfo {
    pub version: u32,
    pub roles: u32,
    pub employees: u32,
    pub employee_exceptions: u32,
    pub shift_templates: u32,
    pub shift_exceptions: u32,
}

/// What an import actually did, plus warnings for skipped records.
#[derive(Debug, Clone, Default)]
pub struct BundleImportSummary {
    pub roles_added: u32,
    pub employees_added: u32,
    pub employees_updated: u32,
    pub employee_exceptions_applied: u32,
    pub shift_templates_added: u32,
    pub shift_templates_updated: u32,
    pub shift_exceptions_applied: u32,
    pub warnings: Vec<String>,
}

// ── Export ───────────────────────────────────────────────────────────────────

/// Build a JSON bundle containing the requested sections.
pub async fn export_data_bundle(
    pool: &SqlitePool,
    sections: BundleSections,
) -> Result<ExportResult, ExchangeError> {
    let mut bundle = DataBundle {
        version: BUNDLE_VERSION,
        roles: None,
        employees: None,
        employee_exceptions: None,
        shift_templates: None,
        shift_exceptions: None,
    };

    if sections.roles {
        let roles = queries::list_roles(pool).await?;
        bundle.roles = Some(roles.into_iter().map(|r| r.name).collect());
    }

    if sections.employees || sections.employee_exceptions {
        let employees = queries::list_employees(pool).await?;
        if sections.employees {
            bundle.employees = Some(employees.iter().map(employee_to_bundle).collect());
        }
        if sections.employee_exceptions {
            let by_id: HashMap<i64, &Employee> = employees.iter().map(|e| (e.id, e)).collect();
            let overrides = queries::list_all_employee_availability_overrides(pool).await?;
            bundle.employee_exceptions = Some(
                overrides
                    .into_iter()
                    .filter_map(|o| {
                        // Overrides for soft-deleted employees aren't visible
                        // anywhere in the UI; leave them out of the bundle.
                        let emp = by_id.get(&o.employee_id)?;
                        Some(BundleEmployeeException {
                            first_name: emp.first_name.clone(),
                            last_name: emp.last_name.clone(),
                            nickname: emp.nickname.clone(),
                            date: o.date,
                            availability: o.availability,
                            notes: o.notes,
                            source: o.source,
                        })
                    })
                    .collect(),
            );
        }
    }

    if sections.shift_templates || sections.shift_exceptions {
        let templates = queries::list_shift_templates(pool).await?;
        if sections.shift_templates {
            bundle.shift_templates = Some(templates.iter().map(template_to_bundle).collect());
        }
        if sections.shift_exceptions {
            let by_id: HashMap<i64, &ShiftTemplate> = templates.iter().map(|t| (t.id, t)).collect();
            let overrides = queries::list_all_shift_template_overrides(pool).await?;
            bundle.shift_exceptions = Some(
                overrides
                    .into_iter()
                    .filter_map(|o| {
                        let tmpl = by_id.get(&o.template_id)?;
                        Some(BundleShiftException {
                            template_name: tmpl.name.clone(),
                            date: o.date,
                            cancelled: o.cancelled,
                            start_time: o.start_time,
                            end_time: o.end_time,
                            min_employees: o.min_employees,
                            max_employees: o.max_employees,
                            notes: o.notes,
                        })
                    })
                    .collect(),
            );
        }
    }

    let data =
        serde_json::to_string_pretty(&bundle).map_err(|e| ExchangeError::Parse(e.to_string()))?;
    let date = chrono::Utc::now().date_naive();
    Ok(ExportResult {
        data,
        filename: format!("autorota-{}-{date}.json", sections.slug()),
        mime_type: "application/json".into(),
    })
}

fn employee_to_bundle(e: &Employee) -> BundleEmployee {
    BundleEmployee {
        first_name: e.first_name.clone(),
        last_name: e.last_name.clone(),
        nickname: e.nickname.clone(),
        roles: e.roles.clone(),
        start_date: Some(e.start_date),
        target_weekly_hours: e.target_weekly_hours,
        weekly_hours_deviation: e.weekly_hours_deviation,
        max_daily_hours: e.max_daily_hours,
        notes: e.notes.clone(),
        bank_details: e.bank_details.clone(),
        phone: e.phone.clone(),
        email: e.email.clone(),
        preferred_contact: e.preferred_contact.clone(),
        hourly_wage: e.hourly_wage,
        wage_currency: e.wage_currency.clone(),
        default_availability: e.default_availability.clone(),
    }
}

fn template_to_bundle(t: &ShiftTemplate) -> BundleShiftTemplate {
    BundleShiftTemplate {
        name: t.name.clone(),
        weekdays: t.weekdays.clone(),
        start_time: t.start_time,
        end_time: t.end_time,
        required_role: t.required_role.clone(),
        min_employees: t.min_employees,
        max_employees: t.max_employees,
        role_requirements: t.role_requirements.clone(),
    }
}

// ── Inspect ──────────────────────────────────────────────────────────────────

fn parse_bundle(bytes: &[u8]) -> Result<DataBundle, ExchangeError> {
    let bundle: DataBundle =
        serde_json::from_slice(bytes).map_err(|e| ExchangeError::Parse(e.to_string()))?;
    if bundle.version > BUNDLE_VERSION {
        return Err(ExchangeError::UnsupportedVersion(bundle.version));
    }
    Ok(bundle)
}

/// Parse a bundle and report per-section counts without touching the database.
/// Used by the UI to show a confirmation step before applying an import.
pub fn inspect_data_bundle(bytes: &[u8]) -> Result<BundleInfo, ExchangeError> {
    let bundle = parse_bundle(bytes)?;
    let count = |n: usize| n as u32;
    Ok(BundleInfo {
        version: bundle.version,
        roles: count(bundle.roles.as_ref().map_or(0, Vec::len)),
        employees: count(bundle.employees.as_ref().map_or(0, Vec::len)),
        employee_exceptions: count(bundle.employee_exceptions.as_ref().map_or(0, Vec::len)),
        shift_templates: count(bundle.shift_templates.as_ref().map_or(0, Vec::len)),
        shift_exceptions: count(bundle.shift_exceptions.as_ref().map_or(0, Vec::len)),
    })
}

// ── Import ───────────────────────────────────────────────────────────────────

/// Apply every section present in the bundle. Records match by name; matched
/// rows are updated, unmatched rows inserted. Roles referenced anywhere are
/// auto-created. Never deletes anything.
pub async fn import_data_bundle(
    pool: &SqlitePool,
    bytes: &[u8],
) -> Result<BundleImportSummary, ExchangeError> {
    let bundle = parse_bundle(bytes)?;
    let mut summary = BundleImportSummary::default();

    // Existing role names, lowercase → original. Sections below add to it as
    // they auto-create roles.
    let mut role_names: HashMap<String, String> = queries::list_roles(pool)
        .await?
        .into_iter()
        .map(|r| (r.name.trim().to_lowercase(), r.name))
        .collect();

    if let Some(roles) = &bundle.roles {
        for name in roles {
            ensure_role(pool, name, &mut role_names, &mut summary.roles_added).await?;
        }
    }

    if let Some(employees) = &bundle.employees {
        import_employees(pool, employees, &mut role_names, &mut summary).await?;
    }

    if let Some(exceptions) = &bundle.employee_exceptions {
        import_employee_exceptions(pool, exceptions, &mut summary).await?;
    }

    if let Some(templates) = &bundle.shift_templates {
        import_shift_templates(pool, templates, &mut role_names, &mut summary).await?;
    }

    if let Some(exceptions) = &bundle.shift_exceptions {
        import_shift_exceptions(pool, exceptions, &mut summary).await?;
    }

    Ok(summary)
}

/// Insert the role if no existing role matches case-insensitively.
async fn ensure_role(
    pool: &SqlitePool,
    name: &str,
    role_names: &mut HashMap<String, String>,
    added: &mut u32,
) -> Result<(), ExchangeError> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Ok(());
    }
    let key = trimmed.to_lowercase();
    if role_names.contains_key(&key) {
        return Ok(());
    }
    queries::insert_role(pool, trimmed).await?;
    role_names.insert(key, trimmed.to_string());
    *added += 1;
    Ok(())
}

fn name_key(first: &str, last: &str, nick: Option<&str>) -> String {
    format!(
        "{}|{}|{}",
        first.trim().to_lowercase(),
        last.trim().to_lowercase(),
        nick.unwrap_or("").trim().to_lowercase()
    )
}

async fn import_employees(
    pool: &SqlitePool,
    employees: &[BundleEmployee],
    role_names: &mut HashMap<String, String>,
    summary: &mut BundleImportSummary,
) -> Result<(), ExchangeError> {
    let existing = queries::list_employees(pool).await?;
    let mut by_name: HashMap<String, Vec<&Employee>> = HashMap::new();
    for e in &existing {
        by_name
            .entry(name_key(&e.first_name, &e.last_name, e.nickname.as_deref()))
            .or_default()
            .push(e);
    }

    for be in employees {
        for role in &be.roles {
            ensure_role(pool, role, role_names, &mut summary.roles_added).await?;
        }

        let key = name_key(&be.first_name, &be.last_name, be.nickname.as_deref());
        let matches = by_name.get(&key).map(Vec::as_slice).unwrap_or(&[]);
        match matches {
            [] => {
                let emp = bundle_to_new_employee(be);
                validate_employee(&emp).map_err(|error| ExchangeError::Validation {
                    context: format!("employee {} {}", be.first_name, be.last_name),
                    error,
                })?;
                queries::insert_employee(pool, &emp).await?;
                summary.employees_added += 1;
            }
            [existing_emp] => {
                let mut emp = (*existing_emp).clone();
                apply_bundle_to_employee(&mut emp, be);
                validate_employee(&emp).map_err(|error| ExchangeError::Validation {
                    context: format!("employee {} {}", be.first_name, be.last_name),
                    error,
                })?;
                queries::update_employee(pool, &emp).await?;
                summary.employees_updated += 1;
            }
            many => {
                summary.warnings.push(format!(
                    "employee \"{} {}\" matches {} existing employees — skipped",
                    be.first_name,
                    be.last_name,
                    many.len()
                ));
            }
        }
    }
    Ok(())
}

fn bundle_to_new_employee(be: &BundleEmployee) -> Employee {
    Employee {
        id: 0,
        first_name: be.first_name.clone(),
        last_name: be.last_name.clone(),
        nickname: be.nickname.clone(),
        roles: be.roles.clone(),
        start_date: be
            .start_date
            .unwrap_or_else(|| chrono::Utc::now().date_naive()),
        target_weekly_hours: be.target_weekly_hours,
        weekly_hours_deviation: be.weekly_hours_deviation,
        max_daily_hours: be.max_daily_hours,
        notes: be.notes.clone(),
        bank_details: be.bank_details.clone(),
        phone: be.phone.clone(),
        email: be.email.clone(),
        preferred_contact: be.preferred_contact.clone(),
        hourly_wage: be.hourly_wage,
        wage_currency: be.wage_currency.clone(),
        default_availability: be.default_availability.clone(),
        availability: be.default_availability.clone(),
        deleted: false,
    }
}

/// Overwrite the matched employee with the bundle's values. The bundle is a
/// full snapshot, so this replaces every exported field (unlike the roster
/// import's fill-in-the-blanks merge).
fn apply_bundle_to_employee(emp: &mut Employee, be: &BundleEmployee) {
    emp.first_name = be.first_name.clone();
    emp.last_name = be.last_name.clone();
    emp.nickname = be.nickname.clone();
    emp.roles = be.roles.clone();
    if let Some(d) = be.start_date {
        emp.start_date = d;
    }
    emp.target_weekly_hours = be.target_weekly_hours;
    emp.weekly_hours_deviation = be.weekly_hours_deviation;
    emp.max_daily_hours = be.max_daily_hours;
    emp.notes = be.notes.clone();
    emp.bank_details = be.bank_details.clone();
    emp.phone = be.phone.clone();
    emp.email = be.email.clone();
    emp.preferred_contact = be.preferred_contact.clone();
    emp.hourly_wage = be.hourly_wage;
    emp.wage_currency = be.wage_currency.clone();
    emp.default_availability = be.default_availability.clone();
    emp.availability = be.default_availability.clone();
}

async fn import_employee_exceptions(
    pool: &SqlitePool,
    exceptions: &[BundleEmployeeException],
    summary: &mut BundleImportSummary,
) -> Result<(), ExchangeError> {
    // Reload so exceptions can attach to employees inserted by this bundle.
    let employees = queries::list_employees(pool).await?;
    let mut by_name: HashMap<String, Vec<i64>> = HashMap::new();
    for e in &employees {
        by_name
            .entry(name_key(&e.first_name, &e.last_name, e.nickname.as_deref()))
            .or_default()
            .push(e.id);
    }

    for ex in exceptions {
        let key = name_key(&ex.first_name, &ex.last_name, ex.nickname.as_deref());
        match by_name.get(&key).map(Vec::as_slice) {
            Some([id]) => {
                let ovr = EmployeeAvailabilityOverride {
                    id: 0,
                    employee_id: *id,
                    date: ex.date,
                    availability: ex.availability.clone(),
                    notes: ex.notes.clone(),
                    source: ex.source,
                };
                queries::upsert_employee_availability_override(pool, &ovr).await?;
                summary.employee_exceptions_applied += 1;
            }
            Some(many) => summary.warnings.push(format!(
                "exception for \"{} {}\" on {} matches {} employees — skipped",
                ex.first_name,
                ex.last_name,
                ex.date,
                many.len()
            )),
            None => summary.warnings.push(format!(
                "exception for unknown employee \"{} {}\" on {} — skipped",
                ex.first_name, ex.last_name, ex.date
            )),
        }
    }
    Ok(())
}

async fn import_shift_templates(
    pool: &SqlitePool,
    templates: &[BundleShiftTemplate],
    role_names: &mut HashMap<String, String>,
    summary: &mut BundleImportSummary,
) -> Result<(), ExchangeError> {
    let existing = queries::list_shift_templates(pool).await?;
    let mut by_name: HashMap<String, Vec<&ShiftTemplate>> = HashMap::new();
    for t in &existing {
        by_name
            .entry(t.name.trim().to_lowercase())
            .or_default()
            .push(t);
    }

    for bt in templates {
        ensure_role(
            pool,
            &bt.required_role,
            role_names,
            &mut summary.roles_added,
        )
        .await?;
        for req in &bt.role_requirements {
            ensure_role(pool, &req.role, role_names, &mut summary.roles_added).await?;
        }

        let key = bt.name.trim().to_lowercase();
        let matches = by_name.get(&key).map(Vec::as_slice).unwrap_or(&[]);
        match matches {
            [] => {
                let tmpl = bundle_to_template(bt, 0);
                validate_shift_template(&tmpl).map_err(|error| ExchangeError::Validation {
                    context: format!("shift template \"{}\"", bt.name),
                    error,
                })?;
                queries::insert_shift_template(pool, &tmpl).await?;
                summary.shift_templates_added += 1;
            }
            [existing_tmpl] => {
                let tmpl = bundle_to_template(bt, existing_tmpl.id);
                validate_shift_template(&tmpl).map_err(|error| ExchangeError::Validation {
                    context: format!("shift template \"{}\"", bt.name),
                    error,
                })?;
                queries::update_shift_template(pool, &tmpl).await?;
                summary.shift_templates_updated += 1;
            }
            many => {
                summary.warnings.push(format!(
                    "shift template \"{}\" matches {} existing templates — skipped",
                    bt.name,
                    many.len()
                ));
            }
        }
    }
    Ok(())
}

fn bundle_to_template(bt: &BundleShiftTemplate, id: i64) -> ShiftTemplate {
    ShiftTemplate {
        id,
        name: bt.name.clone(),
        weekdays: bt.weekdays.clone(),
        start_time: bt.start_time,
        end_time: bt.end_time,
        required_role: bt.required_role.clone(),
        min_employees: bt.min_employees,
        max_employees: bt.max_employees,
        role_requirements: bt.role_requirements.clone(),
        deleted: false,
    }
}

async fn import_shift_exceptions(
    pool: &SqlitePool,
    exceptions: &[BundleShiftException],
    summary: &mut BundleImportSummary,
) -> Result<(), ExchangeError> {
    // Reload so exceptions can attach to templates inserted by this bundle.
    let templates = queries::list_shift_templates(pool).await?;
    let mut by_name: HashMap<String, Vec<i64>> = HashMap::new();
    for t in &templates {
        by_name
            .entry(t.name.trim().to_lowercase())
            .or_default()
            .push(t.id);
    }

    for ex in exceptions {
        let key = ex.template_name.trim().to_lowercase();
        match by_name.get(&key).map(Vec::as_slice) {
            Some([id]) => {
                let ovr = ShiftTemplateOverride {
                    id: 0,
                    template_id: *id,
                    date: ex.date,
                    cancelled: ex.cancelled,
                    start_time: ex.start_time,
                    end_time: ex.end_time,
                    min_employees: ex.min_employees,
                    max_employees: ex.max_employees,
                    notes: ex.notes.clone(),
                };
                queries::upsert_shift_template_override(pool, &ovr).await?;
                summary.shift_exceptions_applied += 1;
            }
            Some(many) => summary.warnings.push(format!(
                "shift change for \"{}\" on {} matches {} templates — skipped",
                ex.template_name,
                ex.date,
                many.len()
            )),
            None => summary.warnings.push(format!(
                "shift change for unknown template \"{}\" on {} — skipped",
                ex.template_name, ex.date
            )),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::availability::AvailabilityState;
    use crate::testutil::{EmployeeBuilder, test_pool};

    fn sample_template(name: &str) -> ShiftTemplate {
        ShiftTemplate {
            id: 0,
            name: name.into(),
            weekdays: vec![Weekday::Mon, Weekday::Wed],
            start_time: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
            end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
            required_role: "Barista".into(),
            min_employees: 1,
            max_employees: 3,
            role_requirements: vec![RoleRequirement {
                role: "Barista".into(),
                min_count: 1,
            }],
            deleted: false,
        }
    }

    #[tokio::test]
    async fn export_import_roundtrip_into_empty_db() {
        let src = test_pool().await;
        queries::insert_role(&src, "Barista").await.unwrap();

        let mut emp = EmployeeBuilder::new("Alice")
            .last_name("Smith")
            .roles(&["Barista"])
            .hours(30.0)
            .build();
        emp.hourly_wage = Some(12.5);
        emp.wage_currency = Some("gbp".into());
        emp.default_availability
            .set(Weekday::Mon, 8, AvailabilityState::Yes);
        let emp_id = queries::insert_employee(&src, &emp).await.unwrap();

        let tmpl_id = queries::insert_shift_template(&src, &sample_template("Morning"))
            .await
            .unwrap();

        let mut day = DayAvailability::default();
        day.set(9, AvailabilityState::No);
        queries::upsert_employee_availability_override(
            &src,
            &EmployeeAvailabilityOverride {
                id: 0,
                employee_id: emp_id,
                date: NaiveDate::from_ymd_opt(2026, 6, 15).unwrap(),
                availability: day,
                notes: Some("dentist".into()),
                source: OverrideSource::Exception,
            },
        )
        .await
        .unwrap();

        queries::upsert_shift_template_override(
            &src,
            &ShiftTemplateOverride {
                id: 0,
                template_id: tmpl_id,
                date: NaiveDate::from_ymd_opt(2026, 6, 15).unwrap(),
                cancelled: true,
                start_time: None,
                end_time: None,
                min_employees: None,
                max_employees: None,
                notes: Some("holiday".into()),
            },
        )
        .await
        .unwrap();

        let exported = export_data_bundle(&src, BundleSections::all())
            .await
            .unwrap();
        assert_eq!(exported.mime_type, "application/json");

        let info = inspect_data_bundle(exported.data.as_bytes()).unwrap();
        assert_eq!(info.roles, 1);
        assert_eq!(info.employees, 1);
        assert_eq!(info.employee_exceptions, 1);
        assert_eq!(info.shift_templates, 1);
        assert_eq!(info.shift_exceptions, 1);

        let dst = test_pool().await;
        let summary = import_data_bundle(&dst, exported.data.as_bytes())
            .await
            .unwrap();
        assert_eq!(summary.roles_added, 1);
        assert_eq!(summary.employees_added, 1);
        assert_eq!(summary.employee_exceptions_applied, 1);
        assert_eq!(summary.shift_templates_added, 1);
        assert_eq!(summary.shift_exceptions_applied, 1);
        assert!(summary.warnings.is_empty());

        let employees = queries::list_employees(&dst).await.unwrap();
        assert_eq!(employees.len(), 1);
        let alice = &employees[0];
        assert_eq!(alice.first_name, "Alice");
        assert_eq!(alice.hourly_wage, Some(12.5));
        assert_eq!(
            alice.default_availability.get(Weekday::Mon, 8),
            AvailabilityState::Yes
        );

        let templates = queries::list_shift_templates(&dst).await.unwrap();
        assert_eq!(templates.len(), 1);
        assert_eq!(templates[0].name, "Morning");
        assert_eq!(templates[0].role_requirements.len(), 1);

        let ex = queries::list_all_employee_availability_overrides(&dst)
            .await
            .unwrap();
        assert_eq!(ex.len(), 1);
        assert_eq!(ex[0].employee_id, employees[0].id);
        assert_eq!(ex[0].availability.get(9), AvailabilityState::No);

        let sx = queries::list_all_shift_template_overrides(&dst)
            .await
            .unwrap();
        assert_eq!(sx.len(), 1);
        assert!(sx[0].cancelled);
    }

    #[tokio::test]
    async fn import_updates_existing_by_name() {
        let pool = test_pool().await;
        let emp = EmployeeBuilder::new("Alice")
            .last_name("Smith")
            .hours(20.0)
            .build();
        queries::insert_employee(&pool, &emp).await.unwrap();
        queries::insert_shift_template(&pool, &sample_template("Morning"))
            .await
            .unwrap();

        let bundle = DataBundle {
            version: BUNDLE_VERSION,
            roles: None,
            employees: Some(vec![BundleEmployee {
                first_name: "Alice".into(),
                last_name: "Smith".into(),
                nickname: None,
                roles: vec!["Cashier".into()],
                start_date: None,
                target_weekly_hours: 35.0,
                weekly_hours_deviation: 5.0,
                max_daily_hours: 8.0,
                notes: None,
                bank_details: None,
                phone: Some("555".into()),
                email: None,
                preferred_contact: None,
                hourly_wage: None,
                wage_currency: None,
                default_availability: Availability::default(),
            }]),
            employee_exceptions: None,
            shift_templates: Some(vec![BundleShiftTemplate {
                name: "Morning".into(),
                weekdays: vec![Weekday::Fri],
                start_time: NaiveTime::from_hms_opt(8, 0, 0).unwrap(),
                end_time: NaiveTime::from_hms_opt(13, 0, 0).unwrap(),
                required_role: "Barista".into(),
                min_employees: 2,
                max_employees: 4,
                role_requirements: vec![],
            }]),
            shift_exceptions: None,
        };
        let bytes = serde_json::to_vec(&bundle).unwrap();
        let summary = import_data_bundle(&pool, &bytes).await.unwrap();

        assert_eq!(summary.employees_added, 0);
        assert_eq!(summary.employees_updated, 1);
        assert_eq!(summary.shift_templates_updated, 1);
        // "Cashier" from the employee plus "Barista" from the template.
        assert_eq!(summary.roles_added, 2);

        let employees = queries::list_employees(&pool).await.unwrap();
        assert_eq!(employees.len(), 1);
        assert_eq!(employees[0].target_weekly_hours, 35.0);
        assert_eq!(employees[0].phone.as_deref(), Some("555"));

        let templates = queries::list_shift_templates(&pool).await.unwrap();
        assert_eq!(templates.len(), 1);
        assert_eq!(templates[0].min_employees, 2);
        assert_eq!(templates[0].weekdays, vec![Weekday::Fri]);
    }

    #[tokio::test]
    async fn import_warns_on_unknown_references() {
        let pool = test_pool().await;
        let bundle = DataBundle {
            version: BUNDLE_VERSION,
            roles: None,
            employees: None,
            employee_exceptions: Some(vec![BundleEmployeeException {
                first_name: "Ghost".into(),
                last_name: "Nobody".into(),
                nickname: None,
                date: NaiveDate::from_ymd_opt(2026, 6, 15).unwrap(),
                availability: DayAvailability::default(),
                notes: None,
                source: OverrideSource::Exception,
            }]),
            shift_templates: None,
            shift_exceptions: Some(vec![BundleShiftException {
                template_name: "Nonexistent".into(),
                date: NaiveDate::from_ymd_opt(2026, 6, 15).unwrap(),
                cancelled: true,
                start_time: None,
                end_time: None,
                min_employees: None,
                max_employees: None,
                notes: None,
            }]),
        };
        let bytes = serde_json::to_vec(&bundle).unwrap();
        let summary = import_data_bundle(&pool, &bytes).await.unwrap();
        assert_eq!(summary.employee_exceptions_applied, 0);
        assert_eq!(summary.shift_exceptions_applied, 0);
        assert_eq!(summary.warnings.len(), 2);
    }

    #[tokio::test]
    async fn export_respects_section_flags() {
        let pool = test_pool().await;
        queries::insert_role(&pool, "Barista").await.unwrap();
        let emp = EmployeeBuilder::new("Alice").build();
        queries::insert_employee(&pool, &emp).await.unwrap();

        let exported = export_data_bundle(
            &pool,
            BundleSections {
                roles: true,
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let info = inspect_data_bundle(exported.data.as_bytes()).unwrap();
        assert_eq!(info.roles, 1);
        assert_eq!(info.employees, 0);
        assert!(exported.filename.contains("roles"));

        let parsed: DataBundle = serde_json::from_str(&exported.data).unwrap();
        assert!(parsed.employees.is_none());
        assert!(parsed.roles.is_some());
    }

    #[test]
    fn inspect_rejects_future_version() {
        let json = format!("{{\"version\":{}}}", BUNDLE_VERSION + 1);
        let err = inspect_data_bundle(json.as_bytes()).unwrap_err();
        assert!(matches!(err, ExchangeError::UnsupportedVersion(_)));
    }

    #[test]
    fn inspect_rejects_garbage() {
        assert!(inspect_data_bundle(b"not json").is_err());
    }
}
