//! Integration coverage for the Save / Edit-Log engine: live snapshots,
//! save-vs-save diffs, tags, restore, and the shift/template mutators the
//! save flow depends on.

mod helpers;

use autorota_core::db::queries;
use autorota_core::models::assignment::{Assignment, AssignmentStatus};
use autorota_core::models::availability::AvailabilityState;
use autorota_core::models::overrides::{
    DayAvailability, EmployeeAvailabilityOverride, OverrideSource,
};
use autorota_core::models::save::{ChangeKind, SaveSnapshot, SaveSource};
use autorota_core::models::shift::{RoleRequirement, Shift};
use chrono::{NaiveDate, NaiveTime};
use sqlx::SqlitePool;

use helpers::{EmployeeBuilder, test_pool};

fn week() -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 3, 23).unwrap() // Monday
}

fn t(h: u32) -> NaiveTime {
    NaiveTime::from_hms_opt(h, 0, 0).unwrap()
}

struct Seeded {
    rota_id: i64,
    shift_ids: Vec<i64>,
    employee_id: i64,
}

/// Rota with two ad-hoc shifts, one wage-carrying employee, one assignment
/// on the first shift, and one availability override inside the week.
async fn seed_week(pool: &SqlitePool) -> Seeded {
    let rota_id = queries::insert_rota(pool, week()).await.unwrap();

    let mut shift_ids = Vec::new();
    for (day, start, end) in [(0i64, 8, 12), (1, 12, 18)] {
        let shift = Shift {
            id: 0,
            template_id: None,
            rota_id,
            date: week() + chrono::Duration::days(day),
            start_time: t(start),
            end_time: t(end),
            required_role: "barista".to_string(),
            min_employees: 1,
            max_employees: 2,
            role_requirements: vec![RoleRequirement {
                role: "barista".to_string(),
                min_count: 1,
            }],
        };
        shift_ids.push(queries::insert_shift(pool, &shift).await.unwrap());
    }

    let emp = EmployeeBuilder::new("Alice")
        .last_name("Smith")
        .role("barista")
        .wage(12.5, "gbp")
        .available(AvailabilityState::Yes)
        .build();
    let employee_id = queries::insert_employee(pool, &emp).await.unwrap();

    queries::insert_assignment(
        pool,
        &Assignment {
            id: 0,
            rota_id,
            shift_id: shift_ids[0],
            employee_id,
            status: AssignmentStatus::Confirmed,
            employee_name: Some("Alice Smith".to_string()),
            hourly_wage: Some(12.5),
        },
    )
    .await
    .unwrap();

    let mut da = DayAvailability::default();
    da.set(9, AvailabilityState::No);
    queries::upsert_employee_availability_override(
        pool,
        &EmployeeAvailabilityOverride {
            id: 0,
            employee_id,
            date: week() + chrono::Duration::days(2),
            availability: da,
            notes: Some("dentist".to_string()),
            source: OverrideSource::Exception,
        },
    )
    .await
    .unwrap();

    Seeded {
        rota_id,
        shift_ids,
        employee_id,
    }
}

// ── snapshot_from_live ───────────────────────────────────────

#[tokio::test]
async fn snapshot_from_live_captures_full_week_state() {
    let pool = test_pool().await;
    let s = seed_week(&pool).await;

    let snap = queries::snapshot_from_live(&pool, s.rota_id).await.unwrap();

    assert_eq!(snap.week_start, week().to_string());
    assert_eq!(snap.total_shifts, 2);
    assert_eq!(snap.total_hours, 10.0); // 4h + 6h
    assert_eq!(snap.unique_employees, 1);
    assert_eq!(snap.shifts.len(), 2);

    let first = snap
        .shifts
        .iter()
        .find(|sh| sh.shift_id == s.shift_ids[0])
        .unwrap();
    assert_eq!(first.start_time, "08:00");
    assert_eq!(first.end_time, "12:00");
    assert_eq!(first.required_role, "barista");
    assert_eq!(first.min_employees, 1);
    assert_eq!(first.max_employees, 2);
    assert_eq!(first.assignments.len(), 1);
    let a = &first.assignments[0];
    assert_eq!(a.employee_id, s.employee_id);
    assert_eq!(a.employee_name, "Alice Smith");
    assert_eq!(a.status, "Confirmed");
    assert_eq!(a.hourly_wage, Some(12.5));
    assert_eq!(a.wage_currency.as_deref(), Some("gbp"));

    assert_eq!(snap.avail_overrides.len(), 1);
    assert_eq!(snap.avail_overrides[0].employee_id, s.employee_id);
    assert_eq!(snap.avail_overrides[0].source, "exception");
}

#[tokio::test]
async fn create_save_persists_live_snapshot() {
    let pool = test_pool().await;
    let s = seed_week(&pool).await;

    let live = queries::snapshot_from_live(&pool, s.rota_id).await.unwrap();
    let save_id = queries::create_save(&pool, s.rota_id, SaveSource::Manual)
        .await
        .unwrap();
    let save = queries::get_save(&pool, save_id).await.unwrap().unwrap();

    let stored: SaveSnapshot = serde_json::from_str(&save.snapshot_json).unwrap();
    assert_eq!(stored.total_shifts, live.total_shifts);
    assert_eq!(stored.total_hours, live.total_hours);
    assert_eq!(stored.shifts.len(), live.shifts.len());
    assert_eq!(save.rota_id, s.rota_id);
}

#[tokio::test]
async fn save_source_round_trips() {
    let pool = test_pool().await;
    let s = seed_week(&pool).await;

    let gen_id = queries::create_save(&pool, s.rota_id, SaveSource::Generation)
        .await
        .unwrap();
    let manual_id = queries::create_save(&pool, s.rota_id, SaveSource::Manual)
        .await
        .unwrap();

    let gen_save = queries::get_save(&pool, gen_id).await.unwrap().unwrap();
    assert_eq!(gen_save.source, SaveSource::Generation);
    let manual = queries::get_save(&pool, manual_id).await.unwrap().unwrap();
    assert_eq!(manual.source, SaveSource::Manual);

    let listed = queries::list_saves(&pool, Some(s.rota_id)).await.unwrap();
    assert_eq!(listed.len(), 2);
    assert!(
        listed
            .iter()
            .any(|m| m.id == gen_id && m.source == SaveSource::Generation)
    );
    assert!(
        listed
            .iter()
            .any(|m| m.id == manual_id && m.source == SaveSource::Manual)
    );
}

// ── diffs ────────────────────────────────────────────────────

#[tokio::test]
async fn first_save_diffs_against_empty_snapshot() {
    let pool = test_pool().await;
    let s = seed_week(&pool).await;
    let save_id = queries::create_save(&pool, s.rota_id, SaveSource::Manual)
        .await
        .unwrap();

    let changes = queries::diff_save_vs_previous(&pool, save_id)
        .await
        .unwrap();
    let added = changes
        .iter()
        .filter(|c| matches!(c.kind, ChangeKind::ShiftAdded { .. }))
        .count();
    assert_eq!(added, 2, "every shift in the first save is an addition");
}

#[tokio::test]
async fn diff_save_vs_previous_shows_mutations_between_saves() {
    let pool = test_pool().await;
    let s = seed_week(&pool).await;
    queries::create_save(&pool, s.rota_id, SaveSource::Manual)
        .await
        .unwrap();

    // Mutate: capacity change on shift 1, new assignment on shift 2.
    queries::update_shift_capacity(&pool, s.shift_ids[0], 2, 4)
        .await
        .unwrap();
    queries::insert_assignment(
        &pool,
        &Assignment {
            id: 0,
            rota_id: s.rota_id,
            shift_id: s.shift_ids[1],
            employee_id: s.employee_id,
            status: AssignmentStatus::Proposed,
            employee_name: Some("Alice Smith".to_string()),
            hourly_wage: Some(12.5),
        },
    )
    .await
    .unwrap();

    let second = queries::create_save(&pool, s.rota_id, SaveSource::Manual)
        .await
        .unwrap();
    let changes = queries::diff_save_vs_previous(&pool, second).await.unwrap();

    assert!(
        changes.iter().any(|c| c.shift_id == s.shift_ids[0]
            && matches!(
                c.kind,
                ChangeKind::ShiftCapacityChanged {
                    old_min: 1,
                    new_min: 2,
                    old_max: 2,
                    new_max: 4
                }
            )),
        "capacity change missing from diff: {changes:?}"
    );
    assert!(
        changes.iter().any(|c| c.shift_id == s.shift_ids[1]
            && matches!(c.kind, ChangeKind::AssignmentAdded { employee_id, .. } if employee_id == s.employee_id)),
        "assignment addition missing from diff: {changes:?}"
    );
}

#[tokio::test]
async fn diff_saves_between_two_ids_and_bad_ids() {
    let pool = test_pool().await;
    let s = seed_week(&pool).await;
    let first = queries::create_save(&pool, s.rota_id, SaveSource::Manual)
        .await
        .unwrap();

    queries::update_shift_capacity(&pool, s.shift_ids[0], 1, 3)
        .await
        .unwrap();
    let second = queries::create_save(&pool, s.rota_id, SaveSource::Manual)
        .await
        .unwrap();

    let changes = queries::diff_saves(&pool, first, second).await.unwrap();
    assert!(
        changes
            .iter()
            .any(|c| matches!(c.kind, ChangeKind::ShiftCapacityChanged { new_max: 3, .. }))
    );

    // Reverse direction reports the inverse.
    let reverse = queries::diff_saves(&pool, second, first).await.unwrap();
    assert!(
        reverse
            .iter()
            .any(|c| matches!(c.kind, ChangeKind::ShiftCapacityChanged { new_max: 2, .. }))
    );

    assert!(matches!(
        queries::diff_saves(&pool, first, 9999).await.unwrap_err(),
        sqlx::Error::RowNotFound
    ));
    assert!(matches!(
        queries::diff_saves(&pool, 9999, second).await.unwrap_err(),
        sqlx::Error::RowNotFound
    ));
}

#[tokio::test]
async fn diff_live_vs_latest_save() {
    let pool = test_pool().await;
    let s = seed_week(&pool).await;

    // No save yet: every live shift reads as added.
    let changes = queries::diff_rota_vs_latest_save_detailed(&pool, s.rota_id)
        .await
        .unwrap();
    assert_eq!(
        changes
            .iter()
            .filter(|c| matches!(c.kind, ChangeKind::ShiftAdded { .. }))
            .count(),
        2
    );

    // After a save, an untouched rota diffs clean; a live edit shows up.
    queries::create_save(&pool, s.rota_id, SaveSource::Manual)
        .await
        .unwrap();
    assert!(
        queries::diff_rota_vs_latest_save_detailed(&pool, s.rota_id)
            .await
            .unwrap()
            .is_empty()
    );

    queries::update_shift_capacity(&pool, s.shift_ids[1], 1, 5)
        .await
        .unwrap();
    let changes = queries::diff_rota_vs_latest_save_detailed(&pool, s.rota_id)
        .await
        .unwrap();
    assert!(changes.iter().any(|c| c.shift_id == s.shift_ids[1]
        && matches!(c.kind, ChangeKind::ShiftCapacityChanged { new_max: 5, .. })));
}

#[tokio::test]
async fn corrupt_snapshot_json_yields_error_not_panic() {
    let pool = test_pool().await;
    let s = seed_week(&pool).await;
    let save_id = queries::create_save(&pool, s.rota_id, SaveSource::Manual)
        .await
        .unwrap();

    sqlx::query("UPDATE saves SET snapshot_json = 'not json' WHERE id = ?")
        .bind(save_id)
        .execute(&pool)
        .await
        .unwrap();

    assert!(
        queries::diff_rota_vs_latest_save_detailed(&pool, s.rota_id)
            .await
            .is_err()
    );
    assert!(
        queries::diff_save_vs_previous(&pool, save_id)
            .await
            .is_err()
    );
}

// ── tags ─────────────────────────────────────────────────────

#[tokio::test]
async fn save_tags_roundtrip() {
    let pool = test_pool().await;
    let s = seed_week(&pool).await;
    let save_id = queries::create_save(&pool, s.rota_id, SaveSource::Manual)
        .await
        .unwrap();

    assert!(
        queries::list_save_tags(&pool, save_id)
            .await
            .unwrap()
            .is_empty()
    );

    queries::add_save_tag(&pool, save_id, "approved")
        .await
        .unwrap();
    queries::add_save_tag(&pool, save_id, "week-12")
        .await
        .unwrap();
    assert_eq!(
        queries::list_save_tags(&pool, save_id).await.unwrap(),
        vec!["approved".to_string(), "week-12".to_string()],
        "tags list in insertion order"
    );

    queries::remove_save_tag(&pool, save_id, "APPROVED")
        .await
        .unwrap();
    assert_eq!(
        queries::list_save_tags(&pool, save_id).await.unwrap(),
        vec!["week-12".to_string()],
        "removal is case-insensitive"
    );
}

// ── restore ──────────────────────────────────────────────────

#[tokio::test]
async fn restore_from_save_rolls_live_state_back() {
    let pool = test_pool().await;
    let s = seed_week(&pool).await;
    let save_id = queries::create_save(&pool, s.rota_id, SaveSource::Manual)
        .await
        .unwrap();

    // Drift the live state: capacity edit + an extra shift.
    queries::update_shift_capacity(&pool, s.shift_ids[0], 3, 6)
        .await
        .unwrap();
    queries::insert_shift(
        &pool,
        &Shift {
            id: 0,
            template_id: None,
            rota_id: s.rota_id,
            date: week() + chrono::Duration::days(3),
            start_time: t(9),
            end_time: t(13),
            required_role: String::new(),
            min_employees: 1,
            max_employees: 1,
            role_requirements: vec![],
        },
    )
    .await
    .unwrap();

    let result = queries::restore_from_save(&pool, save_id).await.unwrap();
    assert_eq!(result.rota_id, s.rota_id);
    assert_eq!(result.shifts_restored, 2);
    assert_eq!(result.assignments_restored, 1);
    assert_eq!(result.assignments_skipped, 0);

    let live = queries::snapshot_from_live(&pool, s.rota_id).await.unwrap();
    assert_eq!(live.total_shifts, 2, "extra shift rolled back");
    let restored_first = live
        .shifts
        .iter()
        .find(|sh| sh.start_time == "08:00")
        .unwrap();
    assert_eq!(
        (restored_first.min_employees, restored_first.max_employees),
        (1, 2),
        "capacity edit rolled back"
    );
    assert_eq!(restored_first.assignments.len(), 1);
}

// ── shift/template mutators used by the save flow ────────────

#[tokio::test]
async fn update_shift_capacity_persists() {
    let pool = test_pool().await;
    let s = seed_week(&pool).await;

    queries::update_shift_capacity(&pool, s.shift_ids[0], 2, 7)
        .await
        .unwrap();

    let shifts = queries::list_shifts_for_rota(&pool, s.rota_id)
        .await
        .unwrap();
    let updated = shifts.iter().find(|sh| sh.id == s.shift_ids[0]).unwrap();
    assert_eq!((updated.min_employees, updated.max_employees), (2, 7));
}

#[tokio::test]
async fn set_template_role_requirements_replaces_and_denormalises() {
    let pool = test_pool().await;
    let tmpl = helpers::ShiftTemplateBuilder::new("Morning").build();
    let tmpl_id = queries::insert_shift_template(&pool, &tmpl).await.unwrap();

    let reqs = vec![
        RoleRequirement {
            role: "kitchen".to_string(),
            min_count: 2,
        },
        RoleRequirement {
            role: "lead".to_string(),
            min_count: 1,
        },
    ];
    queries::set_template_role_requirements(&pool, tmpl_id, &reqs)
        .await
        .unwrap();

    let templates = queries::list_shift_templates(&pool).await.unwrap();
    let stored = templates.iter().find(|t| t.id == tmpl_id).unwrap();
    assert_eq!(stored.role_requirements, reqs);
    assert_eq!(
        stored.required_role, "kitchen",
        "primary role denormalised to first requirement"
    );
}

/// Restore must preserve template linkage. Template shifts are matched across
/// regenerations by `(date, template_id)` — a restore that re-inserts them
/// with `template_id = NULL` turns them ad-hoc, so the very save that was just
/// restored diffs as "everything removed + added" (phantom Edit-Log diff) and
/// re-materialisation loses track of them.
#[tokio::test]
async fn restore_preserves_template_linkage_and_diffs_clean() {
    let pool = test_pool().await;

    let tmpl = helpers::ShiftTemplateBuilder::new("Morning").build();
    let tmpl_id = queries::insert_shift_template(&pool, &tmpl).await.unwrap();

    let rota_id = queries::insert_rota(&pool, week()).await.unwrap();
    queries::materialise_shifts(&pool, rota_id, week())
        .await
        .unwrap();
    let before = queries::list_shifts_for_rota(&pool, rota_id).await.unwrap();
    assert!(
        before.iter().any(|s| s.template_id == Some(tmpl_id)),
        "materialised shift should be template-linked"
    );

    let save_id = queries::create_save(&pool, rota_id, SaveSource::Manual)
        .await
        .unwrap();
    queries::restore_from_save(&pool, save_id).await.unwrap();

    let after = queries::list_shifts_for_rota(&pool, rota_id).await.unwrap();
    assert_eq!(after.len(), before.len());
    assert!(
        after.iter().any(|s| s.template_id == Some(tmpl_id)),
        "restore dropped template_id — restored shifts became ad-hoc"
    );

    let diff = queries::diff_rota_vs_latest_save_detailed(&pool, rota_id)
        .await
        .unwrap();
    assert!(
        diff.is_empty(),
        "restored rota should diff clean against the restored save, got {} changes",
        diff.len()
    );
}
