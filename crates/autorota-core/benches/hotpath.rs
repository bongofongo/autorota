//! Inner-primitive micro-benches.
//!
//! `schedule_pure` calls these O(shifts × employees × slots) times, so a win in
//! `Availability::for_window` (the availability scan) or `Employee::has_role`
//! (the role filter) is where the algorithm-level speedups actually come from.
//! Benching them in isolation makes those wins attributable rather than hidden
//! inside the whole-algorithm number.

use criterion::{Criterion, criterion_group, criterion_main};

use autorota_core::testutil::corpus::{self, DEFAULT_SEED, MEDIUM};

/// `Availability::for_window` over every (employee, weekday) for a representative
/// 5-hour window — the exact shape of the scheduler's availability probe.
fn bench_for_window(c: &mut Criterion) {
    use chrono::Weekday;
    let corpus = corpus::generate_corpus(MEDIUM.employees, MEDIUM.weeks, DEFAULT_SEED);
    let weekdays = [
        Weekday::Mon,
        Weekday::Tue,
        Weekday::Wed,
        Weekday::Thu,
        Weekday::Fri,
        Weekday::Sat,
        Weekday::Sun,
    ];
    c.bench_function("for_window", |b| {
        b.iter(|| {
            let mut acc = 0u32;
            for e in &corpus.employees {
                for wd in weekdays {
                    // 9..14 is a typical lunch-peak window.
                    acc += e.availability.for_window(wd, 9, 14) as u32;
                }
            }
            acc
        });
    });
}

/// `Employee::has_role` — the role filter run in the two-stage fill.
fn bench_has_role(c: &mut Criterion) {
    let corpus = corpus::generate_corpus(MEDIUM.employees, MEDIUM.weeks, DEFAULT_SEED);
    let roles = ["barista", "lead", "kitchen"];
    c.bench_function("has_role", |b| {
        b.iter(|| {
            let mut hits = 0usize;
            for e in &corpus.employees {
                for r in roles {
                    if e.has_role(r) {
                        hits += 1;
                    }
                }
            }
            hits
        });
    });
}

criterion_group!(benches, bench_for_window, bench_has_role);
criterion_main!(benches);
