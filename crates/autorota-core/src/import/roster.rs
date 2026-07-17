//! Parse a roster payload (CSV / JSON / XLSX) and diff against the existing
//! employee table.

use std::collections::HashMap;
use std::io::Cursor;

use calamine::{Data, Reader, Xlsx};
use serde::Deserialize;
use sqlx::SqlitePool;

use super::{ImportSummary, MergeStrategy, ParsedEmployeeRow, ParsedRoster};
use crate::db::queries;
use crate::models::availability::Availability;
use crate::models::employee::Employee;
use crate::models::validation::{ValidationError, validate_employee};

#[derive(Debug, thiserror::Error)]
pub enum ImportError {
    #[error("unsupported format: {0}")]
    UnsupportedFormat(String),
    #[error("parse error: {0}")]
    Parse(String),
    #[error("db error: {0}")]
    Db(#[from] sqlx::Error),
    #[error("row {row}: {error}")]
    Validation { row: usize, error: ValidationError },
}

/// Pick a parser based on the format hint ("csv" | "json" | "xlsx"). Falls
/// back to extension-style strings ("text/csv", "application/json", etc.).
pub async fn parse_roster(
    pool: &SqlitePool,
    bytes: &[u8],
    format_hint: &str,
    strategy: MergeStrategy,
) -> Result<ParsedRoster, ImportError> {
    let normalized = format_hint.to_lowercase();
    let fmt = if normalized.contains("csv") {
        "csv"
    } else if normalized.contains("json") {
        "json"
    } else if normalized.contains("xlsx") || normalized.contains("sheet") {
        "xlsx"
    } else {
        return Err(ImportError::UnsupportedFormat(format_hint.to_string()));
    };

    let mut parsed = match fmt {
        "csv" => parse_csv(bytes)?,
        "json" => parse_json(bytes)?,
        "xlsx" => parse_xlsx(bytes)?,
        // Defensive: fmt is set from the if/else above which only emits the
        // three branches, but a future edit could break that invariant.
        other => return Err(ImportError::UnsupportedFormat(other.to_string())),
    };

    let existing = queries::list_all_employees(pool).await?;
    resolve_diffs(&mut parsed.rows, &existing, strategy, &mut parsed.warnings);
    Ok(parsed)
}

/// Apply the rows the caller opted in to. Runs inside a single transaction:
/// if any row fails the whole batch rolls back.
pub async fn apply_import(
    pool: &SqlitePool,
    rows: &[ParsedEmployeeRow],
) -> Result<ImportSummary, ImportError> {
    let mut inserted = 0u32;
    let mut updated = 0u32;
    let mut skipped = 0u32;

    let mut tx = pool.begin().await?;
    for (i, row) in rows.iter().enumerate() {
        if !row.include {
            skipped += 1;
            continue;
        }
        match row.match_existing_id {
            Some(id) => {
                let existing = queries::get_employee(&mut *tx, id).await?;
                let Some(mut emp) = existing else {
                    skipped += 1;
                    continue;
                };
                merge_into_employee(&mut emp, row);
                validate_employee(&emp)
                    .map_err(|error| ImportError::Validation { row: i, error })?;
                queries::update_employee(&mut *tx, &emp).await?;
                updated += 1;
            }
            None => {
                let emp = row_to_new_employee(row);
                validate_employee(&emp)
                    .map_err(|error| ImportError::Validation { row: i, error })?;
                queries::insert_employee(&mut *tx, &emp).await?;
                inserted += 1;
            }
        }
    }
    tx.commit().await?;

    Ok(ImportSummary {
        inserted,
        updated,
        skipped,
    })
}

// ── Format-specific parsing ─────────────────────────────────────────────────

fn parse_csv(bytes: &[u8]) -> Result<ParsedRoster, ImportError> {
    // Strip optional UTF-8 BOM — Excel writes one.
    let trimmed: &[u8] = if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        &bytes[3..]
    } else {
        bytes
    };

    let mut rdr = csv::ReaderBuilder::new()
        .has_headers(true)
        .flexible(true)
        .from_reader(trimmed);

    let headers = rdr
        .headers()
        .map_err(|e| ImportError::Parse(e.to_string()))?
        .clone();
    let header_strs: Vec<&str> = headers.iter().collect();
    let header_map = HeaderMap::new(&header_strs);

    let mut rows = Vec::new();
    let mut warnings = Vec::new();
    for (i, result) in rdr.records().enumerate() {
        let rec = match result {
            Ok(r) => r,
            Err(e) => {
                warnings.push(format!("row {}: {}", i + 2, e));
                continue;
            }
        };
        let cells: Vec<String> = rec.iter().map(|s| s.to_string()).collect();
        match header_map.row_from_cells(&cells) {
            Ok(row) => rows.push(row),
            Err(msg) => warnings.push(format!("row {}: {msg}", i + 2)),
        }
    }

    Ok(ParsedRoster { rows, warnings })
}

fn parse_json(bytes: &[u8]) -> Result<ParsedRoster, ImportError> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Payload {
        Array(Vec<RawEmployee>),
        Wrapped { employees: Vec<RawEmployee> },
    }

    #[derive(Deserialize)]
    struct RawEmployee {
        #[serde(default)]
        first_name: String,
        #[serde(default)]
        last_name: String,
        #[serde(default)]
        nickname: Option<String>,
        #[serde(default)]
        phone: Option<String>,
        #[serde(default)]
        email: Option<String>,
        #[serde(default)]
        preferred_contact: Option<String>,
        #[serde(default)]
        roles: Vec<String>,
        #[serde(default)]
        target_weekly_hours: Option<f32>,
        #[serde(default)]
        weekly_hours_deviation: Option<f32>,
        #[serde(default)]
        max_daily_hours: Option<f32>,
        #[serde(default)]
        hourly_wage: Option<f32>,
        #[serde(default)]
        wage_currency: Option<String>,
        #[serde(default)]
        notes: Option<String>,
        #[serde(default)]
        bank_details: Option<String>,
    }

    let payload: Payload =
        serde_json::from_slice(bytes).map_err(|e| ImportError::Parse(e.to_string()))?;
    let raw = match payload {
        Payload::Array(v) => v,
        Payload::Wrapped { employees } => employees,
    };

    let rows: Vec<ParsedEmployeeRow> = raw
        .into_iter()
        .map(|r| ParsedEmployeeRow {
            first_name: r.first_name,
            last_name: r.last_name,
            nickname: blank_to_none(r.nickname),
            phone: blank_to_none(r.phone),
            email: blank_to_none(r.email),
            preferred_contact: normalise_contact(r.preferred_contact),
            roles: r.roles,
            target_weekly_hours: r.target_weekly_hours,
            weekly_hours_deviation: r.weekly_hours_deviation,
            max_daily_hours: r.max_daily_hours,
            hourly_wage: r.hourly_wage,
            wage_currency: blank_to_none(r.wage_currency),
            notes: blank_to_none(r.notes),
            bank_details: blank_to_none(r.bank_details),
            match_existing_id: None,
            diff_summary: String::new(),
            include: true,
        })
        .collect();

    Ok(ParsedRoster {
        rows,
        warnings: Vec::new(),
    })
}

fn parse_xlsx(bytes: &[u8]) -> Result<ParsedRoster, ImportError> {
    let mut wb: Xlsx<_> = calamine::open_workbook_from_rs(Cursor::new(bytes.to_vec()))
        .map_err(|e: calamine::XlsxError| ImportError::Parse(e.to_string()))?;
    let sheet_name = wb
        .sheet_names()
        .first()
        .cloned()
        .ok_or_else(|| ImportError::Parse("no sheets in workbook".into()))?;
    let range = wb
        .worksheet_range(&sheet_name)
        .map_err(|e| ImportError::Parse(e.to_string()))?;

    let mut iter = range.rows();
    let Some(header_row) = iter.next() else {
        return Ok(ParsedRoster {
            rows: Vec::new(),
            warnings: vec!["empty sheet".into()],
        });
    };
    let headers: Vec<String> = header_row.iter().map(cell_to_string).collect();
    let header_map = HeaderMap::new(&headers);

    let mut rows = Vec::new();
    let mut warnings = Vec::new();
    for (i, r) in iter.enumerate() {
        let cells: Vec<String> = r.iter().map(cell_to_string).collect();
        if cells.iter().all(|c| c.trim().is_empty()) {
            continue;
        }
        match header_map.row_from_cells(&cells) {
            Ok(row) => rows.push(row),
            Err(msg) => warnings.push(format!("row {}: {msg}", i + 2)),
        }
    }

    Ok(ParsedRoster { rows, warnings })
}

fn cell_to_string(c: &Data) -> String {
    match c {
        Data::Empty => String::new(),
        Data::String(s) => s.clone(),
        Data::Float(f) => {
            if f.fract() == 0.0 && f.abs() < 1e15 {
                format!("{:.0}", f)
            } else {
                f.to_string()
            }
        }
        Data::Int(i) => i.to_string(),
        Data::Bool(b) => b.to_string(),
        Data::DateTime(d) => d.to_string(),
        Data::DateTimeIso(s) => s.clone(),
        Data::DurationIso(s) => s.clone(),
        Data::Error(e) => format!("{:?}", e),
    }
}

// ── Header mapping (CSV + XLSX share this) ──────────────────────────────────

struct HeaderMap {
    first_name: Option<usize>,
    last_name: Option<usize>,
    nickname: Option<usize>,
    phone: Option<usize>,
    email: Option<usize>,
    preferred_contact: Option<usize>,
    roles: Option<usize>,
    target_weekly_hours: Option<usize>,
    weekly_hours_deviation: Option<usize>,
    max_daily_hours: Option<usize>,
    hourly_wage: Option<usize>,
    wage_currency: Option<usize>,
    notes: Option<usize>,
    bank_details: Option<usize>,
    name: Option<usize>,
}

impl HeaderMap {
    fn new<S: AsRef<str>>(headers: &[S]) -> Self {
        let find = |aliases: &[&str]| -> Option<usize> {
            for (i, h) in headers.iter().enumerate() {
                let norm = h
                    .as_ref()
                    .trim()
                    .to_lowercase()
                    .replace(['_', '-', ' '], "");
                if aliases
                    .iter()
                    .any(|a| a.to_lowercase().replace(['_', '-', ' '], "") == norm)
                {
                    return Some(i);
                }
            }
            None
        };

        Self {
            first_name: find(&["first_name", "firstname", "first"]),
            last_name: find(&["last_name", "lastname", "last", "surname"]),
            nickname: find(&["nickname", "display_name", "preferred"]),
            phone: find(&["phone", "mobile", "tel"]),
            email: find(&["email", "e_mail", "mail"]),
            preferred_contact: find(&[
                "preferred_contact",
                "contact_method",
                "preferred",
                "contact",
            ]),
            roles: find(&["roles", "role", "skills"]),
            target_weekly_hours: find(&["target_weekly_hours", "weekly_hours", "hours_per_week"]),
            weekly_hours_deviation: find(&[
                "weekly_hours_deviation",
                "hours_deviation",
                "deviation",
            ]),
            max_daily_hours: find(&["max_daily_hours", "daily_max"]),
            hourly_wage: find(&["hourly_wage", "wage", "rate", "pay_rate"]),
            wage_currency: find(&["wage_currency", "currency"]),
            notes: find(&["notes", "comment", "comments"]),
            bank_details: find(&["bank_details", "bank"]),
            name: find(&["name", "full_name"]),
        }
    }

    fn row_from_cells(&self, cells: &[String]) -> Result<ParsedEmployeeRow, String> {
        let g = |idx: Option<usize>| -> String {
            idx.and_then(|i| cells.get(i)).cloned().unwrap_or_default()
        };
        let (first_name, last_name) = match (self.first_name, self.last_name, self.name) {
            (Some(_), _, _) | (_, Some(_), _) => (
                g(self.first_name).trim().to_string(),
                g(self.last_name).trim().to_string(),
            ),
            (None, None, Some(_)) => split_full_name(&g(self.name)),
            _ => return Err("no name columns found".into()),
        };
        if first_name.is_empty() && last_name.is_empty() {
            return Err("empty name".into());
        }

        let roles_raw = g(self.roles);
        let roles = if roles_raw.is_empty() {
            Vec::new()
        } else {
            roles_raw
                .split([',', ';', '|'])
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect()
        };

        Ok(ParsedEmployeeRow {
            first_name,
            last_name,
            nickname: blank_to_none(Some(g(self.nickname))),
            phone: blank_to_none(Some(g(self.phone))),
            email: blank_to_none(Some(g(self.email))),
            preferred_contact: normalise_contact(Some(g(self.preferred_contact))),
            roles,
            target_weekly_hours: parse_float(&g(self.target_weekly_hours)),
            weekly_hours_deviation: parse_float(&g(self.weekly_hours_deviation)),
            max_daily_hours: parse_float(&g(self.max_daily_hours)),
            hourly_wage: parse_float(&g(self.hourly_wage)),
            wage_currency: blank_to_none(Some(g(self.wage_currency).to_lowercase())),
            notes: blank_to_none(Some(g(self.notes))),
            bank_details: blank_to_none(Some(g(self.bank_details))),
            match_existing_id: None,
            diff_summary: String::new(),
            include: true,
        })
    }
}

fn split_full_name(full: &str) -> (String, String) {
    let parts: Vec<&str> = full.split_whitespace().collect();
    match parts.len() {
        0 => (String::new(), String::new()),
        1 => (parts[0].to_string(), String::new()),
        _ => (parts[0].to_string(), parts[1..].join(" ")),
    }
}

fn parse_float(s: &str) -> Option<f32> {
    let t = s.trim().replace(['£', '$', '€', ',', ' '], "");
    if t.is_empty() {
        return None;
    }
    t.parse::<f32>().ok()
}

fn blank_to_none(s: Option<String>) -> Option<String> {
    match s {
        Some(v) if !v.trim().is_empty() => Some(v.trim().to_string()),
        _ => None,
    }
}

/// Map free-form contact method strings to the canonical `"imessage"` /
/// `"whatsapp"` tokens. Anything unrecognised becomes `None`.
fn normalise_contact(s: Option<String>) -> Option<String> {
    let v = s?.trim().to_lowercase();
    match v.as_str() {
        "" => None,
        "imessage" | "messages" | "sms" | "text" | "apple" => Some("imessage".into()),
        "whatsapp" | "wa" | "whats app" => Some("whatsapp".into()),
        _ => None,
    }
}

// ── Diff resolution ─────────────────────────────────────────────────────────

fn resolve_diffs(
    rows: &mut [ParsedEmployeeRow],
    existing: &[Employee],
    strategy: MergeStrategy,
    warnings: &mut Vec<String>,
) {
    match strategy {
        MergeStrategy::InsertOnly => {
            for r in rows {
                r.match_existing_id = None;
                r.diff_summary = "NEW".into();
            }
        }
        MergeStrategy::Name => {
            let mut by_name: HashMap<String, Vec<&Employee>> = HashMap::new();
            for e in existing {
                by_name
                    .entry(name_key(&e.first_name, &e.last_name, e.nickname.as_deref()))
                    .or_default()
                    .push(e);
            }
            for r in rows {
                let key = name_key(&r.first_name, &r.last_name, r.nickname.as_deref());
                let matches = by_name.get(&key).cloned().unwrap_or_default();
                match matches.len() {
                    0 => {
                        r.match_existing_id = None;
                        r.diff_summary = "NEW".into();
                    }
                    1 => {
                        let emp = matches[0];
                        r.match_existing_id = Some(emp.id);
                        r.diff_summary = build_diff(emp, r);
                        if r.diff_summary == "NO CHANGE" {
                            r.include = false;
                        }
                    }
                    _ => {
                        r.match_existing_id = None;
                        r.diff_summary = "AMBIGUOUS — requires manual review".into();
                        r.include = false;
                        warnings.push(format!(
                            "{} {} matches {} existing employees",
                            r.first_name,
                            r.last_name,
                            matches.len()
                        ));
                    }
                }
            }
        }
    }
}

fn name_key(first: &str, last: &str, nick: Option<&str>) -> String {
    format!(
        "{}|{}|{}",
        first.trim().to_lowercase(),
        last.trim().to_lowercase(),
        nick.unwrap_or("").trim().to_lowercase()
    )
}

fn build_diff(emp: &Employee, row: &ParsedEmployeeRow) -> String {
    let mut changes = Vec::new();
    fn diff_opt_str(
        label: &str,
        old: &Option<String>,
        new: &Option<String>,
        out: &mut Vec<String>,
    ) {
        if new.is_some() && new != old {
            out.push(format!(
                "{label} {}→{}",
                old.as_deref().unwrap_or("∅"),
                new.as_deref().unwrap_or("∅")
            ));
        }
    }
    fn diff_opt_f32(label: &str, old: Option<f32>, new: Option<f32>, out: &mut Vec<String>) {
        if let Some(n) = new {
            let o = old.unwrap_or(0.0);
            if (o - n).abs() > f32::EPSILON {
                out.push(format!("{label} {o}→{n}"));
            }
        }
    }

    diff_opt_str("phone", &emp.phone, &row.phone, &mut changes);
    diff_opt_str("email", &emp.email, &row.email, &mut changes);
    diff_opt_str(
        "preferred_contact",
        &emp.preferred_contact,
        &row.preferred_contact,
        &mut changes,
    );
    diff_opt_str("notes", &emp.notes, &row.notes, &mut changes);
    diff_opt_str("bank", &emp.bank_details, &row.bank_details, &mut changes);
    diff_opt_f32("wage", emp.hourly_wage, row.hourly_wage, &mut changes);
    diff_opt_f32(
        "target_hrs",
        Some(emp.target_weekly_hours),
        row.target_weekly_hours,
        &mut changes,
    );
    diff_opt_f32(
        "daily_max",
        Some(emp.max_daily_hours),
        row.max_daily_hours,
        &mut changes,
    );

    if !row.roles.is_empty() && row.roles != emp.roles {
        changes.push(format!("roles {:?}→{:?}", emp.roles, row.roles));
    }

    if changes.is_empty() {
        "NO CHANGE".into()
    } else {
        format!("UPDATE: {}", changes.join(", "))
    }
}

// ── Apply helpers ──────────────────────────────────────────────────────────

fn merge_into_employee(emp: &mut Employee, row: &ParsedEmployeeRow) {
    if !row.first_name.trim().is_empty() {
        emp.first_name = row.first_name.clone();
    }
    if !row.last_name.trim().is_empty() {
        emp.last_name = row.last_name.clone();
    }
    if row.nickname.is_some() {
        emp.nickname = row.nickname.clone();
    }
    if row.phone.is_some() {
        emp.phone = row.phone.clone();
    }
    if row.email.is_some() {
        emp.email = row.email.clone();
    }
    if row.preferred_contact.is_some() {
        emp.preferred_contact = row.preferred_contact.clone();
    }
    if !row.roles.is_empty() {
        emp.roles = row.roles.clone();
    }
    if let Some(h) = row.target_weekly_hours {
        emp.target_weekly_hours = h;
    }
    if let Some(d) = row.weekly_hours_deviation {
        emp.weekly_hours_deviation = d;
    }
    if let Some(m) = row.max_daily_hours {
        emp.max_daily_hours = m;
    }
    if row.hourly_wage.is_some() {
        emp.hourly_wage = row.hourly_wage;
    }
    if row.wage_currency.is_some() {
        emp.wage_currency = row.wage_currency.clone();
    }
    if row.notes.is_some() {
        emp.notes = row.notes.clone();
    }
    if row.bank_details.is_some() {
        emp.bank_details = row.bank_details.clone();
    }
}

fn row_to_new_employee(row: &ParsedEmployeeRow) -> Employee {
    Employee {
        id: 0,
        first_name: row.first_name.clone(),
        last_name: row.last_name.clone(),
        nickname: row.nickname.clone(),
        roles: row.roles.clone(),
        start_date: chrono::Utc::now().date_naive(),
        target_weekly_hours: row.target_weekly_hours.unwrap_or(0.0),
        weekly_hours_deviation: row.weekly_hours_deviation.unwrap_or(0.0),
        max_daily_hours: row.max_daily_hours.unwrap_or(8.0),
        notes: row.notes.clone(),
        bank_details: row.bank_details.clone(),
        phone: row.phone.clone(),
        email: row.email.clone(),
        preferred_contact: row.preferred_contact.clone(),
        hourly_wage: row.hourly_wage,
        wage_currency: row.wage_currency.clone(),
        default_availability: Availability::default(),
        availability: Availability::default(),
        deleted: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn csv_parses_minimal_roster() {
        let csv = b"first_name,last_name,phone,roles\nAlice,Smith,555-1111,Barista\nBob,Lee,,Barista;Cashier\n";
        let parsed = parse_csv(csv).unwrap();
        assert_eq!(parsed.rows.len(), 2);
        assert_eq!(parsed.rows[0].first_name, "Alice");
        assert_eq!(parsed.rows[0].phone.as_deref(), Some("555-1111"));
        assert_eq!(parsed.rows[1].roles, vec!["Barista", "Cashier"]);
    }

    #[test]
    fn csv_strips_utf8_bom() {
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(b"first_name,last_name\nAlice,Smith\n");
        let parsed = parse_csv(&bytes).unwrap();
        assert_eq!(parsed.rows.len(), 1);
        assert_eq!(parsed.rows[0].first_name, "Alice");
    }

    #[test]
    fn csv_falls_back_to_single_name_column() {
        let csv = b"name,roles\nAlice Smith,Barista\nCher,\n";
        let parsed = parse_csv(csv).unwrap();
        assert_eq!(parsed.rows[0].first_name, "Alice");
        assert_eq!(parsed.rows[0].last_name, "Smith");
        assert_eq!(parsed.rows[1].first_name, "Cher");
        assert_eq!(parsed.rows[1].last_name, "");
    }

    #[test]
    fn json_accepts_array_and_wrapped_forms() {
        let arr = br#"[{"first_name":"Alice","last_name":"S"}]"#;
        let wrp = br#"{"employees":[{"first_name":"Bob","last_name":"L"}]}"#;
        assert_eq!(parse_json(arr).unwrap().rows.len(), 1);
        assert_eq!(parse_json(wrp).unwrap().rows[0].first_name, "Bob");
    }

    #[test]
    fn merge_strategy_insert_only_never_matches() {
        let mut rows = vec![ParsedEmployeeRow {
            first_name: "Alice".into(),
            last_name: "Smith".into(),
            nickname: None,
            phone: None,
            email: None,
            preferred_contact: None,
            roles: vec![],
            target_weekly_hours: None,
            weekly_hours_deviation: None,
            max_daily_hours: None,
            hourly_wage: None,
            wage_currency: None,
            notes: None,
            bank_details: None,
            match_existing_id: None,
            diff_summary: String::new(),
            include: true,
        }];
        let existing = vec![Employee {
            id: 1,
            first_name: "Alice".into(),
            last_name: "Smith".into(),
            nickname: None,
            roles: vec![],
            start_date: chrono::Utc::now().date_naive(),
            target_weekly_hours: 0.0,
            weekly_hours_deviation: 0.0,
            max_daily_hours: 0.0,
            notes: None,
            bank_details: None,
            phone: None,
            email: None,
            preferred_contact: None,
            hourly_wage: None,
            wage_currency: None,
            default_availability: Availability::default(),
            availability: Availability::default(),
            deleted: false,
        }];
        let mut warnings = vec![];
        resolve_diffs(
            &mut rows,
            &existing,
            MergeStrategy::InsertOnly,
            &mut warnings,
        );
        assert_eq!(rows[0].match_existing_id, None);
        assert_eq!(rows[0].diff_summary, "NEW");
    }

    #[test]
    fn merge_by_name_matches_single_and_builds_diff() {
        let mut rows = vec![ParsedEmployeeRow {
            first_name: "Alice".into(),
            last_name: "Smith".into(),
            nickname: None,
            phone: Some("555".into()),
            email: None,
            preferred_contact: None,
            roles: vec![],
            target_weekly_hours: None,
            weekly_hours_deviation: None,
            max_daily_hours: None,
            hourly_wage: None,
            wage_currency: None,
            notes: None,
            bank_details: None,
            match_existing_id: None,
            diff_summary: String::new(),
            include: true,
        }];
        let existing = vec![Employee {
            id: 42,
            first_name: "alice".into(),
            last_name: "smith".into(),
            nickname: None,
            roles: vec![],
            start_date: chrono::Utc::now().date_naive(),
            target_weekly_hours: 0.0,
            weekly_hours_deviation: 0.0,
            max_daily_hours: 0.0,
            notes: None,
            bank_details: None,
            phone: None,
            email: None,
            preferred_contact: None,
            hourly_wage: None,
            wage_currency: None,
            default_availability: Availability::default(),
            availability: Availability::default(),
            deleted: false,
        }];
        let mut warnings = vec![];
        resolve_diffs(&mut rows, &existing, MergeStrategy::Name, &mut warnings);
        assert_eq!(rows[0].match_existing_id, Some(42));
        assert!(rows[0].diff_summary.starts_with("UPDATE"));
        assert!(rows[0].diff_summary.contains("phone"));
    }

    #[test]
    fn merge_by_name_flags_ambiguous() {
        let mut rows = vec![ParsedEmployeeRow {
            first_name: "Alice".into(),
            last_name: "Smith".into(),
            nickname: None,
            phone: None,
            email: None,
            preferred_contact: None,
            roles: vec![],
            target_weekly_hours: None,
            weekly_hours_deviation: None,
            max_daily_hours: None,
            hourly_wage: None,
            wage_currency: None,
            notes: None,
            bank_details: None,
            match_existing_id: None,
            diff_summary: String::new(),
            include: true,
        }];
        let mk = |id: i64| Employee {
            id,
            first_name: "Alice".into(),
            last_name: "Smith".into(),
            nickname: None,
            roles: vec![],
            start_date: chrono::Utc::now().date_naive(),
            target_weekly_hours: 0.0,
            weekly_hours_deviation: 0.0,
            max_daily_hours: 0.0,
            notes: None,
            bank_details: None,
            phone: None,
            email: None,
            preferred_contact: None,
            hourly_wage: None,
            wage_currency: None,
            default_availability: Availability::default(),
            availability: Availability::default(),
            deleted: false,
        };
        let existing = vec![mk(1), mk(2)];
        let mut warnings = vec![];
        resolve_diffs(&mut rows, &existing, MergeStrategy::Name, &mut warnings);
        assert_eq!(rows[0].match_existing_id, None);
        assert!(rows[0].diff_summary.contains("AMBIGUOUS"));
        assert!(!rows[0].include);
        assert_eq!(warnings.len(), 1);
    }
}
