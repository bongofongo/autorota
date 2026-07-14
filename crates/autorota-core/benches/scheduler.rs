//! Scheduler perf benches.
//!
//! Runs the pure two-pass scheduling algorithm against the synthetic corpus at
//! 50 / 200 / 500 employees. The corpus is generated once per group and reused
//! across iterations; the scheduler is a pure function so no fixture reset is
//! needed between runs.

use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};

use autorota_core::scheduler::schedule_pure;
use autorota_core::testutil::corpus::{
    self, Corpus, CorpusConfig, CorpusSize, DEFAULT_SEED, LARGE, MEDIUM, SMALL, WEEKS_4, WEEKS_12,
};

fn run(corpus: &Corpus) {
    schedule_pure(
        &corpus.shifts,
        &corpus.employees,
        &corpus.existing_assignments,
        &corpus.avail_overrides,
        corpus.rota.id,
        corpus.week_start,
    );
}

/// Employee axis: 50 / 200 / 500 employees, one week of shifts.
fn bench_schedule_pure(c: &mut Criterion) {
    let mut group = c.benchmark_group("schedule_pure");
    for size in [SMALL, MEDIUM, LARGE] {
        let CorpusSize { employees, weeks } = size;
        let corpus = corpus::generate_corpus(employees, weeks, DEFAULT_SEED);
        group.throughput(Throughput::Elements(corpus.shifts.len() as u64));
        group.bench_with_input(BenchmarkId::from_parameter(employees), &corpus, |b, c| {
            b.iter(|| run(c));
        });
    }
    group.finish();
}

/// Week (shift) axis: fixed 200 employees, 1 / 4 / 12 weeks of shifts — the
/// dimension that actually grows scheduler workload.
fn bench_schedule_weeks(c: &mut Criterion) {
    let mut group = c.benchmark_group("schedule_pure_weeks");
    for size in [MEDIUM, WEEKS_4, WEEKS_12] {
        let CorpusSize { employees, weeks } = size;
        let corpus = corpus::generate_corpus(employees, weeks, DEFAULT_SEED);
        group.throughput(Throughput::Elements(corpus.shifts.len() as u64));
        group.bench_with_input(BenchmarkId::from_parameter(weeks), &corpus, |b, c| {
            b.iter(|| run(c));
        });
    }
    group.finish();
}

/// Enriched path: exercises the two-stage role-deficit fill (multi-role,
/// wildcard, and overnight shifts) that the legacy single-role corpus never hits.
fn bench_schedule_enriched(c: &mut Criterion) {
    let mut group = c.benchmark_group("schedule_pure_enriched");
    for size in [SMALL, MEDIUM, LARGE] {
        let CorpusSize { employees, weeks } = size;
        let corpus = corpus::generate_corpus_with(CorpusConfig {
            employees,
            weeks,
            seed: DEFAULT_SEED,
            enriched_shifts: true,
        });
        group.throughput(Throughput::Elements(corpus.shifts.len() as u64));
        group.bench_with_input(BenchmarkId::from_parameter(employees), &corpus, |b, c| {
            b.iter(|| run(c));
        });
    }
    group.finish();
}

criterion_group!(
    benches,
    bench_schedule_pure,
    bench_schedule_weeks,
    bench_schedule_enriched
);
criterion_main!(benches);
