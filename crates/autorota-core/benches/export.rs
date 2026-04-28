//! Export pipeline perf benches.
//!
//! Composes the public render submodules directly (`grid::build_grid` →
//! `csv::render_csv` etc.) instead of going through the async DB-backed
//! `export_week_schedule` wrapper, so the bench measures CPU not sqlite.

use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};

use autorota_core::export::config::{
    CellContentFlags, ExportConfig, ExportFormat, ExportLayout, ExportProfile, PdfTemplate,
};
use autorota_core::export::{csv, grid, json, markdown, pdf, xlsx};
use autorota_core::testutil::corpus::{
    self, Corpus, CorpusSize, DEFAULT_SEED, LARGE, MEDIUM, SMALL,
};

fn manager_csv_config() -> ExportConfig {
    ExportConfig {
        layout: ExportLayout::EmployeeByWeekday,
        format: ExportFormat::Csv,
        profile: ExportProfile::ManagerReport,
        cell_content: CellContentFlags {
            show_shift_name: true,
            show_times: true,
            show_role: true,
        },
        pdf_template: None,
    }
}

fn build_grid_for(corpus: &Corpus, layout: ExportLayout) -> grid::ExportGrid {
    let mut cfg = manager_csv_config();
    cfg.layout = layout;
    grid::build_grid(
        &cfg,
        corpus.week_start,
        &corpus.existing_assignments,
        &corpus.shifts,
        &corpus.employees,
        &corpus.templates,
    )
}

fn bench_build_grid(c: &mut Criterion) {
    let mut group = c.benchmark_group("export_build_grid");
    for size in [SMALL, MEDIUM, LARGE] {
        let CorpusSize { employees, weeks } = size;
        let corpus = corpus::generate_corpus(employees, weeks, DEFAULT_SEED);
        group.throughput(Throughput::Elements(corpus.shifts.len() as u64));
        group.bench_with_input(
            BenchmarkId::from_parameter(employees),
            &corpus,
            |b, corpus| {
                b.iter(|| build_grid_for(corpus, ExportLayout::EmployeeByWeekday));
            },
        );
    }
    group.finish();
}

fn bench_csv_json_markdown(c: &mut Criterion) {
    let mut group = c.benchmark_group("export_text");
    let CorpusSize { employees, weeks } = MEDIUM;
    let corpus = corpus::generate_corpus(employees, weeks, DEFAULT_SEED);
    let g = build_grid_for(&corpus, ExportLayout::EmployeeByWeekday);
    let cfg = manager_csv_config();

    group.bench_function("csv", |b| b.iter(|| csv::render_csv(&g)));
    group.bench_function("json", |b| {
        b.iter(|| json::render_json(&g, &cfg, corpus.week_start))
    });
    group.bench_function("markdown", |b| b.iter(|| markdown::render_markdown(&g)));
    group.finish();
}

fn bench_xlsx(c: &mut Criterion) {
    let mut group = c.benchmark_group("export_xlsx");
    let CorpusSize { employees, weeks } = MEDIUM;
    let corpus = corpus::generate_corpus(employees, weeks, DEFAULT_SEED);
    let g = build_grid_for(&corpus, ExportLayout::EmployeeByWeekday);
    let sheets = vec![("Schedule".to_string(), &g)];
    group.bench_function(BenchmarkId::from_parameter(employees), |b| {
        b.iter(|| xlsx::render_workbook(&sheets).unwrap());
    });
    group.finish();
}

fn bench_pdf(c: &mut Criterion) {
    let mut group = c.benchmark_group("export_pdf_weekly");
    // PDF renderer is heavy; sample MEDIUM only, with a smaller sample size so
    // criterion doesn't burn too long.
    group.sample_size(20);
    let CorpusSize { employees, weeks } = MEDIUM;
    let corpus = corpus::generate_corpus(employees, weeks, DEFAULT_SEED);
    let g = build_grid_for(&corpus, ExportLayout::EmployeeByWeekday);
    group.bench_function(BenchmarkId::from_parameter(employees), |b| {
        b.iter(|| pdf::weekly::render(&g, corpus.week_start).unwrap());
    });
    group.finish();
}

// Suppress unused-import lint on PdfTemplate for future expansion.
#[allow(dead_code)]
fn _unused_template() -> PdfTemplate {
    PdfTemplate::WeeklyGrid
}

criterion_group!(
    benches,
    bench_build_grid,
    bench_csv_json_markdown,
    bench_xlsx,
    bench_pdf
);
criterion_main!(benches);
