//! Scheduler perf benches.
//!
//! Runs the pure two-pass scheduling algorithm against the synthetic corpus at
//! 50 / 200 / 500 employees. The corpus is generated once per group and reused
//! across iterations; the scheduler is a pure function so no fixture reset is
//! needed between runs.

use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};

use autorota_core::scheduler::schedule_pure;
use autorota_core::testutil::corpus::{self, CorpusSize, DEFAULT_SEED, LARGE, MEDIUM, SMALL};

fn bench_schedule_pure(c: &mut Criterion) {
    let mut group = c.benchmark_group("schedule_pure");
    for size in [SMALL, MEDIUM, LARGE] {
        let CorpusSize { employees, weeks } = size;
        let corpus = corpus::generate_corpus(employees, weeks, DEFAULT_SEED);
        group.throughput(Throughput::Elements(corpus.shifts.len() as u64));
        group.bench_with_input(
            BenchmarkId::from_parameter(employees),
            &corpus,
            |b, corpus| {
                b.iter(|| {
                    schedule_pure(
                        &corpus.shifts,
                        &corpus.employees,
                        &corpus.existing_assignments,
                        &corpus.avail_overrides,
                        corpus.rota.id,
                        corpus.week_start,
                    )
                });
            },
        );
    }
    group.finish();
}

criterion_group!(benches, bench_schedule_pure);
criterion_main!(benches);
