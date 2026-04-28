//! Save / snapshot perf benches.
//!
//! Covers the two pure operations that scale with rota size:
//!   1. `snapshot_serialize` — `serde_json::to_string(&SaveSnapshot)`.
//!      This is the dominant cost when a manager exits edit mode.
//!   2. `diff_snapshots` — `models::save::diff_snapshots`. Drives the Edit Log
//!      diff display and the per-save change list.
//!
//! The async `create_save` / `restore_from_save` DB roundtrip is intentionally
//! out of MVP scope; it's a thin wrapper over `snapshot_serialize` plus the
//! seven `INSERT`s that any other DB write touches, and benching it adds
//! sqlx/tokio harness weight without revealing new info. Add it back if a
//! regression surfaces in the in-mem ramp test.

use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};

use autorota_core::models::save::{
    SaveAssignmentSnapshot, SaveShiftSnapshot, SaveSnapshot, diff_snapshots,
};
use autorota_core::testutil::corpus::{
    self, Corpus, CorpusSize, DEFAULT_SEED, LARGE, MEDIUM, SMALL,
};

fn snapshot_from_corpus(c: &Corpus) -> SaveSnapshot {
    let mut total_hours: f32 = 0.0;
    let mut shifts: Vec<SaveShiftSnapshot> = Vec::with_capacity(c.shifts.len());
    for shift in &c.shifts {
        total_hours += shift.duration_hours();
        let assignments: Vec<SaveAssignmentSnapshot> = c
            .existing_assignments
            .iter()
            .filter(|a| a.shift_id == shift.id)
            .map(|a| SaveAssignmentSnapshot {
                assignment_id: a.id,
                employee_id: a.employee_id,
                employee_name: a.employee_name.clone().unwrap_or_default(),
                status: format!("{:?}", a.status),
                hourly_wage: a.hourly_wage,
                wage_currency: Some("gbp".to_string()),
            })
            .collect();
        shifts.push(SaveShiftSnapshot {
            shift_id: shift.id,
            template_id: shift.template_id,
            date: shift.date.to_string(),
            start_time: shift.start_time.format("%H:%M").to_string(),
            end_time: shift.end_time.format("%H:%M").to_string(),
            required_role: shift.required_role.clone(),
            min_employees: shift.min_employees,
            max_employees: shift.max_employees,
            assignments,
        });
    }
    let unique_emps: std::collections::HashSet<i64> = c
        .existing_assignments
        .iter()
        .map(|a| a.employee_id)
        .collect();
    SaveSnapshot {
        week_start: c.week_start.to_string(),
        saved_shift_ids: shifts.iter().map(|s| s.shift_id).collect(),
        total_hours,
        total_shifts: shifts.len(),
        unique_employees: unique_emps.len(),
        avail_overrides: vec![],
        shifts,
    }
}

fn bench_snapshot_serialize(c: &mut Criterion) {
    let mut group = c.benchmark_group("snapshot_serialize");
    for size in [SMALL, MEDIUM, LARGE] {
        let CorpusSize { employees, weeks } = size;
        let corpus = corpus::generate_corpus(employees, weeks, DEFAULT_SEED);
        let snapshot = snapshot_from_corpus(&corpus);
        group.throughput(Throughput::Elements(snapshot.shifts.len() as u64));
        group.bench_with_input(BenchmarkId::from_parameter(employees), &snapshot, |b, s| {
            b.iter(|| serde_json::to_string(s).unwrap());
        });
    }
    group.finish();
}

fn bench_diff_snapshots(c: &mut Criterion) {
    let mut group = c.benchmark_group("diff_snapshots");
    let CorpusSize { employees, weeks } = MEDIUM;
    let base = corpus::generate_corpus(employees, weeks, DEFAULT_SEED);
    let mut perturbed = corpus::generate_corpus(employees, weeks, DEFAULT_SEED ^ 0x55);
    // Force a meaningful diff: keep base shifts/assignments but reuse the
    // perturbed corpus's pinned set so AssignmentAdded/Removed have material
    // to surface.
    perturbed.shifts = base.shifts.clone();
    perturbed.week_start = base.week_start;
    let old = snapshot_from_corpus(&base);
    let new = snapshot_from_corpus(&perturbed);
    group.bench_function(BenchmarkId::from_parameter(employees), |b| {
        b.iter(|| diff_snapshots(&old, &new));
    });
    group.finish();
}

criterion_group!(benches, bench_snapshot_serialize, bench_diff_snapshots);
criterion_main!(benches);
