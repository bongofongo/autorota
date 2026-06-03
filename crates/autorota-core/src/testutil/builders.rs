//! Fluent builder APIs for constructing test fixtures.
//!
//! Each builder has sensible defaults and auto-incrementing IDs. Override any
//! field with chained setter calls, then call `.build()` to produce the struct.

use std::sync::atomic::{AtomicI64, Ordering};

use chrono::{NaiveDate, NaiveTime, Weekday};

use crate::models::assignment::{Assignment, AssignmentStatus};
use crate::models::availability::{Availability, AvailabilityState};
use crate::models::employee::Employee;
use crate::models::overrides::{
    DayAvailability, EmployeeAvailabilityOverride, OverrideSource, ShiftTemplateOverride,
};
use crate::models::rota::Rota;
use crate::models::shift::{RoleRequirement, Shift, ShiftTemplate};
use crate::models::shift_history::EmployeeShiftRecord;

static NEXT_EMPLOYEE_ID: AtomicI64 = AtomicI64::new(1000);
static NEXT_SHIFT_ID: AtomicI64 = AtomicI64::new(1000);
static NEXT_TEMPLATE_ID: AtomicI64 = AtomicI64::new(1000);
static NEXT_ASSIGNMENT_ID: AtomicI64 = AtomicI64::new(1000);
static NEXT_ROTA_ID: AtomicI64 = AtomicI64::new(1000);
static NEXT_OVERRIDE_ID: AtomicI64 = AtomicI64::new(1000);

fn next_id(counter: &AtomicI64) -> i64 {
    counter.fetch_add(1, Ordering::Relaxed)
}

// ── Employee ────────────────────────────────────────────────────────────────

pub struct EmployeeBuilder {
    inner: Employee,
}

impl EmployeeBuilder {
    /// Create an employee builder with the given first name.
    ///
    /// Defaults: role=barista, 40h target, 6h deviation, 8h max daily,
    /// all-Maybe availability.
    pub fn new(first_name: &str) -> Self {
        Self {
            inner: Employee {
                id: next_id(&NEXT_EMPLOYEE_ID),
                first_name: first_name.to_string(),
                last_name: String::new(),
                nickname: None,
                roles: vec!["barista".to_string()],
                start_date: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
                target_weekly_hours: 40.0,
                weekly_hours_deviation: 6.0,
                max_daily_hours: 8.0,
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
            },
        }
    }

    pub fn id(mut self, id: i64) -> Self {
        self.inner.id = id;
        self
    }

    pub fn last_name(mut self, v: &str) -> Self {
        self.inner.last_name = v.to_string();
        self
    }

    pub fn nickname(mut self, n: &str) -> Self {
        self.inner.nickname = Some(n.to_string());
        self
    }

    /// Set a single role (replaces default).
    pub fn role(mut self, role: &str) -> Self {
        self.inner.roles = vec![role.to_string()];
        self
    }

    /// Set multiple roles (replaces default).
    pub fn roles(mut self, roles: &[&str]) -> Self {
        self.inner.roles = roles.iter().map(|r| r.to_string()).collect();
        self
    }

    /// Set target weekly hours.
    pub fn hours(mut self, target: f32) -> Self {
        self.inner.target_weekly_hours = target;
        self
    }

    pub fn deviation(mut self, d: f32) -> Self {
        self.inner.weekly_hours_deviation = d;
        self
    }

    pub fn max_daily(mut self, h: f32) -> Self {
        self.inner.max_daily_hours = h;
        self
    }

    pub fn wage(mut self, rate: f32, currency: &str) -> Self {
        self.inner.hourly_wage = Some(rate);
        self.inner.wage_currency = Some(currency.to_string());
        self
    }

    pub fn start_date(mut self, d: NaiveDate) -> Self {
        self.inner.start_date = d;
        self
    }

    /// Set uniform availability for weekdays (Mon–Fri) hours 6–22.
    pub fn available(mut self, state: AvailabilityState) -> Self {
        let mut avail = Availability::default();
        for day in [
            Weekday::Mon,
            Weekday::Tue,
            Weekday::Wed,
            Weekday::Thu,
            Weekday::Fri,
        ] {
            for h in 6..22 {
                avail.set(day, h, state);
            }
        }
        self.inner.default_availability = avail.clone();
        self.inner.availability = avail;
        self
    }

    /// Set availability from a raw `Availability` value.
    pub fn availability(mut self, a: Availability) -> Self {
        self.inner.default_availability = a.clone();
        self.inner.availability = a;
        self
    }

    pub fn deleted(mut self) -> Self {
        self.inner.deleted = true;
        self
    }

    pub fn build(self) -> Employee {
        self.inner
    }
}

// ── Shift ───────────────────────────────────────────────────────────────────

pub struct ShiftBuilder {
    inner: Shift,
}

impl Default for ShiftBuilder {
    fn default() -> Self {
        Self::new()
    }
}

impl ShiftBuilder {
    /// Create a shift builder.
    ///
    /// Defaults: Monday 2026-03-23, 07:00–12:00, barista, rota_id=1,
    /// template_id=Some(1), capacity 1/1.
    pub fn new() -> Self {
        Self {
            inner: Shift {
                id: next_id(&NEXT_SHIFT_ID),
                template_id: Some(1),
                rota_id: 1,
                date: NaiveDate::from_ymd_opt(2026, 3, 23).unwrap(),
                start_time: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
                end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
                required_role: "barista".to_string(),
                min_employees: 1,
                max_employees: 1,
                role_requirements: vec![],
            },
        }
    }

    pub fn id(mut self, id: i64) -> Self {
        self.inner.id = id;
        self
    }

    pub fn rota(mut self, rota_id: i64) -> Self {
        self.inner.rota_id = rota_id;
        self
    }

    pub fn template(mut self, id: i64) -> Self {
        self.inner.template_id = Some(id);
        self
    }

    pub fn no_template(mut self) -> Self {
        self.inner.template_id = None;
        self
    }

    pub fn date(mut self, d: NaiveDate) -> Self {
        self.inner.date = d;
        self
    }

    /// Set start and end times from whole hours.
    pub fn times(mut self, start: u32, end: u32) -> Self {
        self.inner.start_time = NaiveTime::from_hms_opt(start, 0, 0).unwrap();
        self.inner.end_time = NaiveTime::from_hms_opt(end, 0, 0).unwrap();
        self
    }

    /// Set start and end times with minutes: `times_hm((7, 30), (12, 0))`.
    pub fn times_hm(mut self, start: (u32, u32), end: (u32, u32)) -> Self {
        self.inner.start_time = NaiveTime::from_hms_opt(start.0, start.1, 0).unwrap();
        self.inner.end_time = NaiveTime::from_hms_opt(end.0, end.1, 0).unwrap();
        self
    }

    pub fn role(mut self, r: &str) -> Self {
        self.inner.required_role = r.to_string();
        self
    }

    /// Set explicit multi-role requirements (overrides the synthesized legacy role).
    pub fn require_roles(mut self, reqs: &[(&str, u32)]) -> Self {
        self.inner.role_requirements = reqs
            .iter()
            .map(|(role, min)| RoleRequirement {
                role: role.to_string(),
                min_count: *min,
            })
            .collect();
        self
    }

    pub fn capacity(mut self, min: u32, max: u32) -> Self {
        self.inner.min_employees = min;
        self.inner.max_employees = max;
        self
    }

    pub fn build(mut self) -> Shift {
        synthesize_role_requirement(
            &mut self.inner.role_requirements,
            &self.inner.required_role,
            self.inner.min_employees,
        );
        self.inner
    }
}

/// Mirror the DB migration backfill: if no explicit role requirements were set
/// but a legacy single role is present, derive one requirement whose minimum is
/// the overall `min_employees`. Keeps pre-multi-role test fixtures behaving as
/// "needs N of that role".
fn synthesize_role_requirement(reqs: &mut Vec<RoleRequirement>, role: &str, min: u32) {
    if reqs.is_empty() && !role.is_empty() {
        reqs.push(RoleRequirement {
            role: role.to_string(),
            min_count: min,
        });
    }
}

// ── ShiftTemplate ───────────────────────────────────────��───────────────────

pub struct ShiftTemplateBuilder {
    inner: ShiftTemplate,
}

impl ShiftTemplateBuilder {
    /// Create a shift template builder with the given name.
    ///
    /// Defaults: Monday only, 07:00–12:00, barista, capacity 1/2.
    pub fn new(name: &str) -> Self {
        Self {
            inner: ShiftTemplate {
                id: next_id(&NEXT_TEMPLATE_ID),
                name: name.to_string(),
                weekdays: vec![Weekday::Mon],
                start_time: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
                end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
                required_role: "barista".to_string(),
                min_employees: 1,
                max_employees: 2,
                role_requirements: vec![],
                deleted: false,
            },
        }
    }

    pub fn id(mut self, id: i64) -> Self {
        self.inner.id = id;
        self
    }

    pub fn weekdays(mut self, days: &[Weekday]) -> Self {
        self.inner.weekdays = days.to_vec();
        self
    }

    /// Set weekdays to Monday–Friday.
    pub fn weekday_range_mf(mut self) -> Self {
        self.inner.weekdays = vec![
            Weekday::Mon,
            Weekday::Tue,
            Weekday::Wed,
            Weekday::Thu,
            Weekday::Fri,
        ];
        self
    }

    pub fn times(mut self, start: u32, end: u32) -> Self {
        self.inner.start_time = NaiveTime::from_hms_opt(start, 0, 0).unwrap();
        self.inner.end_time = NaiveTime::from_hms_opt(end, 0, 0).unwrap();
        self
    }

    pub fn times_hm(mut self, start: (u32, u32), end: (u32, u32)) -> Self {
        self.inner.start_time = NaiveTime::from_hms_opt(start.0, start.1, 0).unwrap();
        self.inner.end_time = NaiveTime::from_hms_opt(end.0, end.1, 0).unwrap();
        self
    }

    pub fn role(mut self, r: &str) -> Self {
        self.inner.required_role = r.to_string();
        self
    }

    /// Set explicit multi-role requirements (overrides the synthesized legacy role).
    pub fn require_roles(mut self, reqs: &[(&str, u32)]) -> Self {
        self.inner.role_requirements = reqs
            .iter()
            .map(|(role, min)| RoleRequirement {
                role: role.to_string(),
                min_count: *min,
            })
            .collect();
        self
    }

    pub fn capacity(mut self, min: u32, max: u32) -> Self {
        self.inner.min_employees = min;
        self.inner.max_employees = max;
        self
    }

    pub fn deleted(mut self) -> Self {
        self.inner.deleted = true;
        self
    }

    pub fn build(mut self) -> ShiftTemplate {
        synthesize_role_requirement(
            &mut self.inner.role_requirements,
            &self.inner.required_role,
            self.inner.min_employees,
        );
        self.inner
    }
}

// ── Assignment ──────────────────────────────────────────────────────────────

pub struct AssignmentBuilder {
    inner: Assignment,
}

impl AssignmentBuilder {
    /// Create an assignment builder for the given shift and employee.
    ///
    /// Defaults: Proposed status, rota_id=1, no name/wage snapshot.
    pub fn new(shift_id: i64, employee_id: i64) -> Self {
        Self {
            inner: Assignment {
                id: next_id(&NEXT_ASSIGNMENT_ID),
                rota_id: 1,
                shift_id,
                employee_id,
                status: AssignmentStatus::Proposed,
                employee_name: None,
                hourly_wage: None,
            },
        }
    }

    pub fn id(mut self, id: i64) -> Self {
        self.inner.id = id;
        self
    }

    pub fn rota(mut self, id: i64) -> Self {
        self.inner.rota_id = id;
        self
    }

    pub fn confirmed(mut self) -> Self {
        self.inner.status = AssignmentStatus::Confirmed;
        self
    }

    pub fn overridden(mut self) -> Self {
        self.inner.status = AssignmentStatus::Overridden;
        self
    }

    pub fn status(mut self, s: AssignmentStatus) -> Self {
        self.inner.status = s;
        self
    }

    pub fn name(mut self, n: &str) -> Self {
        self.inner.employee_name = Some(n.to_string());
        self
    }

    pub fn wage(mut self, w: f32) -> Self {
        self.inner.hourly_wage = Some(w);
        self
    }

    pub fn build(self) -> Assignment {
        self.inner
    }
}

// ── Rota ────────────────────────────────────────────────────────────────────

pub struct RotaBuilder {
    inner: Rota,
}

impl Default for RotaBuilder {
    fn default() -> Self {
        Self::new()
    }
}

impl RotaBuilder {
    /// Create a rota builder.
    ///
    /// Defaults: Monday 2026-03-23, empty assignments.
    pub fn new() -> Self {
        Self {
            inner: Rota {
                id: next_id(&NEXT_ROTA_ID),
                week_start: NaiveDate::from_ymd_opt(2026, 3, 23).unwrap(),
                assignments: vec![],
            },
        }
    }

    pub fn id(mut self, id: i64) -> Self {
        self.inner.id = id;
        self
    }

    pub fn week(mut self, date: NaiveDate) -> Self {
        self.inner.week_start = date;
        self
    }

    pub fn assignments(mut self, a: Vec<Assignment>) -> Self {
        self.inner.assignments = a;
        self
    }

    pub fn build(self) -> Rota {
        self.inner
    }
}

// ── EmployeeAvailabilityOverride ────────────────────────────────────────────

pub struct EmployeeOverrideBuilder {
    inner: EmployeeAvailabilityOverride,
}

impl EmployeeOverrideBuilder {
    pub fn new(employee_id: i64, date: NaiveDate) -> Self {
        Self {
            inner: EmployeeAvailabilityOverride {
                id: next_id(&NEXT_OVERRIDE_ID),
                employee_id,
                date,
                availability: DayAvailability::default(),
                notes: None,
                source: OverrideSource::Exception,
            },
        }
    }

    pub fn id(mut self, id: i64) -> Self {
        self.inner.id = id;
        self
    }

    pub fn source(mut self, s: OverrideSource) -> Self {
        self.inner.source = s;
        self
    }

    /// Set a single hour slot.
    pub fn slot(mut self, hour: u8, state: AvailabilityState) -> Self {
        self.inner.availability.set(hour, state);
        self
    }

    /// Set a range of hours to the given state (start inclusive, end exclusive).
    pub fn available_range(mut self, start: u8, end: u8, state: AvailabilityState) -> Self {
        for h in start..end {
            self.inner.availability.set(h, state);
        }
        self
    }

    pub fn note(mut self, n: &str) -> Self {
        self.inner.notes = Some(n.to_string());
        self
    }

    pub fn build(self) -> EmployeeAvailabilityOverride {
        self.inner
    }
}

// ── ShiftTemplateOverride ───────────────────────────────────────────────────

pub struct ShiftTemplateOverrideBuilder {
    inner: ShiftTemplateOverride,
}

impl ShiftTemplateOverrideBuilder {
    pub fn new(template_id: i64, date: NaiveDate) -> Self {
        Self {
            inner: ShiftTemplateOverride {
                id: next_id(&NEXT_OVERRIDE_ID),
                template_id,
                date,
                cancelled: false,
                start_time: None,
                end_time: None,
                min_employees: None,
                max_employees: None,
                notes: None,
            },
        }
    }

    pub fn id(mut self, id: i64) -> Self {
        self.inner.id = id;
        self
    }

    pub fn cancelled(mut self) -> Self {
        self.inner.cancelled = true;
        self
    }

    pub fn times(mut self, start: u32, end: u32) -> Self {
        self.inner.start_time = Some(NaiveTime::from_hms_opt(start, 0, 0).unwrap());
        self.inner.end_time = Some(NaiveTime::from_hms_opt(end, 0, 0).unwrap());
        self
    }

    pub fn capacity(mut self, min: u32, max: u32) -> Self {
        self.inner.min_employees = Some(min);
        self.inner.max_employees = Some(max);
        self
    }

    pub fn note(mut self, n: &str) -> Self {
        self.inner.notes = Some(n.to_string());
        self
    }

    pub fn build(self) -> ShiftTemplateOverride {
        self.inner
    }
}

// ── EmployeeShiftRecord ─────────────────────────────────────────────────────

pub struct EmployeeShiftRecordBuilder {
    inner: EmployeeShiftRecord,
}

impl EmployeeShiftRecordBuilder {
    pub fn new(employee_id: i64) -> Self {
        Self {
            inner: EmployeeShiftRecord {
                assignment_id: next_id(&NEXT_ASSIGNMENT_ID),
                rota_id: 1,
                shift_id: next_id(&NEXT_SHIFT_ID),
                employee_id,
                status: AssignmentStatus::Proposed,
                employee_name: None,
                hourly_wage: None,
                date: NaiveDate::from_ymd_opt(2026, 3, 23).unwrap(),
                start_time: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
                end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
                required_role: "barista".to_string(),
                week_start: NaiveDate::from_ymd_opt(2026, 3, 23).unwrap(),
            },
        }
    }

    pub fn date(mut self, d: NaiveDate) -> Self {
        self.inner.date = d;
        self
    }

    pub fn times(mut self, start: u32, end: u32) -> Self {
        self.inner.start_time = NaiveTime::from_hms_opt(start, 0, 0).unwrap();
        self.inner.end_time = NaiveTime::from_hms_opt(end, 0, 0).unwrap();
        self
    }

    pub fn role(mut self, r: &str) -> Self {
        self.inner.required_role = r.to_string();
        self
    }

    pub fn wage(mut self, w: f32) -> Self {
        self.inner.hourly_wage = Some(w);
        self
    }

    pub fn name(mut self, n: &str) -> Self {
        self.inner.employee_name = Some(n.to_string());
        self
    }

    pub fn confirmed(mut self) -> Self {
        self.inner.status = AssignmentStatus::Confirmed;
        self
    }

    pub fn week_start(mut self, d: NaiveDate) -> Self {
        self.inner.week_start = d;
        self
    }

    pub fn rota(mut self, id: i64) -> Self {
        self.inner.rota_id = id;
        self
    }

    pub fn build(self) -> EmployeeShiftRecord {
        self.inner
    }
}

// ���─ ExportConfig builders ───────────────────────────────────────────────────

use crate::export::config::{
    CellContentFlags, ExportConfig, ExportFormat, ExportLayout, ExportProfile, PdfTemplate,
};

pub struct ExportConfigBuilder {
    inner: ExportConfig,
}

impl ExportConfigBuilder {
    /// Staff schedule CSV config with employee-by-weekday layout.
    pub fn staff() -> Self {
        Self {
            inner: ExportConfig {
                layout: ExportLayout::EmployeeByWeekday,
                format: ExportFormat::Csv,
                profile: ExportProfile::StaffSchedule,
                cell_content: CellContentFlags {
                    show_shift_name: true,
                    show_times: true,
                    show_role: false,
                },
                pdf_template: None,
            },
        }
    }

    /// Manager report CSV config with employee-by-weekday layout.
    pub fn manager() -> Self {
        Self {
            inner: ExportConfig {
                layout: ExportLayout::EmployeeByWeekday,
                format: ExportFormat::Csv,
                profile: ExportProfile::ManagerReport,
                cell_content: CellContentFlags {
                    show_shift_name: true,
                    show_times: true,
                    show_role: false,
                },
                pdf_template: None,
            },
        }
    }

    pub fn layout(mut self, l: ExportLayout) -> Self {
        self.inner.layout = l;
        self
    }

    pub fn format(mut self, f: ExportFormat) -> Self {
        self.inner.format = f;
        self
    }

    pub fn profile(mut self, p: ExportProfile) -> Self {
        self.inner.profile = p;
        self
    }

    pub fn show_role(mut self) -> Self {
        self.inner.cell_content.show_role = true;
        self
    }

    pub fn hide_times(mut self) -> Self {
        self.inner.cell_content.show_times = false;
        self
    }

    pub fn hide_shift_name(mut self) -> Self {
        self.inner.cell_content.show_shift_name = false;
        self
    }

    pub fn pdf_template(mut self, t: PdfTemplate) -> Self {
        self.inner.pdf_template = Some(t);
        self
    }

    pub fn cell_content(mut self, flags: CellContentFlags) -> Self {
        self.inner.cell_content = flags;
        self
    }

    pub fn build(self) -> ExportConfig {
        self.inner
    }
}
