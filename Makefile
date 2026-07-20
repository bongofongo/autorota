# Makefile — autorota test suite
#
# Requires: Rust toolchain, Xcode 26+, xcbeautify (optional, prettier output)
#
# Quickstart:
#   make test-all                 Run every test suite
#   make rust-test                Rust unit + integration tests only
#   make swift-test-app-macos     ViewModel mock tests on macOS (fast, no FFI needed)
#   make swift-test-all           All three Swift app targets + package integration tests
#
# Output is concise by default. For full verbose output:
#   VERBOSE=1 make test-all
#
# Building the XCFramework is required before running any Swift test that
# imports AutorotaKit (including the app target compile).  Run once:
#   make swift-build-xcframework

VERBOSE ?=

ifdef VERBOSE
  CARGO_TEST_FLAGS :=
  XCB_QUIET :=
  SWIFT_TEST_QUIET :=
else
  CARGO_TEST_FLAGS := -- --format=terse
  XCB_QUIET := -quiet
  SWIFT_TEST_QUIET := --quiet
endif

PROJECT := platforms/apple/Apps/AutorotaApp/AutorotaApp.xcodeproj
SCHEME  := AutorotaApp
SPM_PKG := platforms/apple/AutorotaKit
XCB     := xcodebuild -project $(PROJECT) -scheme $(SCHEME)

# ─── Rust ────────────────────────────────────────────────────────────────────

.PHONY: rust-test rust-test-unit rust-test-integration rust-fmt rust-clippy lint
.PHONY: rust-test-one rust-test-scheduler rust-test-models rust-test-export
.PHONY: rust-test-db rust-test-edge rust-test-loud rust-test-invariants rust-test-saves
.PHONY: rust-test-migrations rust-test-concurrency rust-test-pdf rust-test-ffi

rust-test: rust-test-unit rust-test-integration

rust-test-unit:
	cargo test --lib --workspace $(CARGO_TEST_FLAGS)

rust-test-integration:
	cargo test --test '*' -p autorota-core $(CARGO_TEST_FLAGS)

# Run a single test by name (substring match).
# Usage: make rust-test-one NAME=single_employee
rust-test-one:
	cargo test -p autorota-core $(NAME) $(CARGO_TEST_FLAGS)

# Run tests for a specific module.
rust-test-scheduler:
	cargo test -p autorota-core scheduler $(CARGO_TEST_FLAGS)

rust-test-models:
	cargo test -p autorota-core models $(CARGO_TEST_FLAGS)

rust-test-export:
	cargo test -p autorota-core export $(CARGO_TEST_FLAGS)

# Run specific integration test files.
rust-test-db:
	cargo test --test db_integration -p autorota-core $(CARGO_TEST_FLAGS)

rust-test-edge:
	cargo test --test edge_cases_test -p autorota-core $(CARGO_TEST_FLAGS)

# Corpus-driven scheduler invariant suite (seeded, deterministic).
rust-test-invariants:
	cargo test --test scheduler_invariants_test -p autorota-core $(CARGO_TEST_FLAGS)

rust-test-saves:
	cargo test --test save_diff_test -p autorota-core $(CARGO_TEST_FLAGS)

# Migration upgrade-path spine (001 → current, schema equivalence + data).
rust-test-migrations:
	cargo test --test migration_matrix_test -p autorota-core $(CARGO_TEST_FLAGS)

# Pool-contention smoke tests (file-backed DB, 5-connection pool).
rust-test-concurrency:
	cargo test --test db_concurrency_test -p autorota-core $(CARGO_TEST_FLAGS)

# PDF text-layer content assertions (lopdf extraction).
rust-test-pdf:
	cargo test --test export_pdf_content_test -p autorota-core $(CARGO_TEST_FLAGS)

# FFI surface tests (lifecycle, export/import, sync, saves).
rust-test-ffi:
	cargo test -p autorota-ffi $(CARGO_TEST_FLAGS)

# Always-verbose test run (shows println! output).
rust-test-loud:
	cargo test --lib --workspace -- --nocapture

rust-fmt:
	cargo fmt --check --all

# app-desktop excluded to match CI's rust-checks job (known pre-existing
# breakage; it has its own compile-check job). Check it with: cargo check -p app-desktop
rust-clippy:
	cargo clippy --workspace --exclude app-desktop -- -D warnings

lint: rust-fmt rust-clippy

# ─── Apple — build ───────────────────────────────────────────────────────────

.PHONY: swift-build-xcframework swift-build-xcframework-debug

# Release build (used by CI and before running Swift tests on a clean machine).
swift-build-xcframework:
	bash scripts/build_xcframework.sh

# Debug build — faster for local iteration; not for distribution.
swift-build-xcframework-debug:
	bash scripts/build_xcframework.sh --debug

# ─── Apple — build-only (compile check, no simulator) ────────────────────────

.PHONY: swift-build-check-macos swift-build-check-ios swift-build-check-ipad swift-build-check swift-platform-lint

swift-build-check-macos:
	$(XCB) build $(XCB_QUIET) -destination 'platform=macOS' $(NOSIGN)

swift-build-check-ios:
	$(XCB) build $(XCB_QUIET) -destination 'platform=iOS Simulator,name=iPhone 17' $(NOSIGN)

swift-build-check-ipad:
	$(XCB) build $(XCB_QUIET) -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' $(NOSIGN)

swift-platform-lint:
	@bash scripts/check-platform-isolation.sh

swift-build-check: swift-platform-lint swift-build-check-macos swift-build-check-ios swift-build-check-ipad

# ─── Apple — ViewModel unit tests (mock service, no live FFI) ────────────────

.PHONY: swift-test-app-macos swift-test-app-ios swift-test-app-ipad

# CODE_SIGN_IDENTITY="" disables code signing for local test runs (no provisioning profile needed).
NOSIGN := CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

swift-test-app-macos:
	$(XCB) test $(XCB_QUIET) -destination 'platform=macOS' $(NOSIGN)

swift-test-app-ios:
	$(XCB) test $(XCB_QUIET) -destination 'platform=iOS Simulator,name=iPhone 17' $(NOSIGN)

swift-test-app-ipad:
	$(XCB) test $(XCB_QUIET) -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' $(NOSIGN)

# ─── Apple — SPM integration tests (real FFI calls, XCFramework required) ────

.PHONY: swift-test-package

# Perf tests are excluded here — they need a release PERF_HELPERS XCFramework
# and only produce meaningful numbers via `make kit-perf`.
swift-test-package:
	cd $(SPM_PKG) && swift test --skip AutorotaKitPerfTests $(SWIFT_TEST_QUIET)

# ─── Combined ────────────────────────────────────────────────────────────────

.PHONY: swift-test-all test-all

# All Swift tests — requires XCFramework to be already built.
swift-test-all: swift-test-app-macos swift-test-app-ios swift-test-app-ipad swift-test-package

# Full suite: Rust, then all Swift platforms.
# On a clean machine, run `make swift-build-xcframework` first.
test-all: rust-test swift-test-all

# ─── Performance ─────────────────────────────────────────────────────────────
# Rust criterion benches and Swift XCUITest perf target. Results are
# informational — see docs/perf-testing.md for how to read them.

.PHONY: bench bench-scheduler bench-hotpath bench-save bench-export
.PHONY: swift-perf-xcframework swift-perf-macos swift-perf-ios perf-all

bench: bench-scheduler bench-hotpath bench-save bench-export

bench-scheduler:
	cargo bench -p autorota-core --bench scheduler

bench-hotpath:
	cargo bench -p autorota-core --bench hotpath

# Fast single-bench sanity run (~10s): make bench-quick BENCH=scheduler
BENCH ?= scheduler
.PHONY: bench-quick
bench-quick:
	cargo bench -p autorota-core --bench $(BENCH) -- --quick

bench-save:
	cargo bench -p autorota-core --bench save

bench-export:
	cargo bench -p autorota-core --bench export

# Build the XCFramework with the perf-helpers feature so the perf test target
# can call seedPerfCorpus(). Default release path stays untouched.
swift-perf-xcframework:
	PERF_HELPERS=1 bash scripts/build_xcframework.sh --debug

# ── FFI hot-path perf (AutorotaKitPerfTests) ──
# Release Rust build: debug timings are 10-50x off and worthless for trends.
.PHONY: kit-perf-xcframework kit-perf sync-merge-perf

kit-perf-xcframework:
	PERF_HELPERS=1 bash scripts/build_xcframework.sh

# XCTest prints "measured [Clock Monotonic Time, s] average: ..." lines that
# scripts/perf_report.py parses from the teed log.
kit-perf:
	cd $(SPM_PKG) && mkdir -p .build && set -o pipefail && \
	  swift test --filter AutorotaKitPerfTests 2>&1 | tee .build/kit-perf.txt

# Sync three-way merge perf lives in the app target (resolver isn't in the Kit).
# Env-gated: the test self-skips without AUTOROTA_PERF=1.
# Verbose so the "measured [...]" lines reach the teed log for perf_report.py.
sync-merge-perf:
	mkdir -p .build
	set -o pipefail && TEST_RUNNER_AUTOROTA_PERF=1 $(XCB) test -destination 'platform=macOS' \
	  -only-testing:AutorotaAppTests/SyncMergePerfTests $(NOSIGN) \
	  2>&1 | tee .build/sync-merge-perf.txt

swift-perf-macos: swift-perf-xcframework
	$(XCB) test $(XCB_QUIET) -destination 'platform=macOS' \
	  -testPlan Perf -only-testing:AutorotaAppPerfTests \
	  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) PERF_HELPERS' \
	  ENABLE_APP_SANDBOX=NO \
	  CODE_SIGN_ENTITLEMENTS= \
	  PROVISIONING_PROFILE_SPECIFIER= \
	  DEVELOPMENT_TEAM= \
	  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual

# Release Rust (kit-perf-xcframework): UI timings include DB work, and debug
# Rust distorts them. Results land in ./perf-results.xcresult and flow into
# `make perf-report` automatically.
swift-perf-ios: kit-perf-xcframework
	rm -rf perf-results.xcresult
	$(XCB) test $(XCB_QUIET) -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
	  -testPlan Perf -only-testing:AutorotaAppPerfTests \
	  -resultBundlePath perf-results.xcresult \
	  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) PERF_HELPERS' $(NOSIGN)
	python3 scripts/perf_report.py

perf-all: bench swift-perf-ios

# Aggregate whatever perf outputs exist (criterion, kit-perf log, optional
# xcresult) into one informational table. PERF_RECORD=1 appends to
# perf/history.jsonl. Never fails on regression.
.PHONY: perf-report
perf-report:
	python3 scripts/perf_report.py

# ─── Devex ───────────────────────────────────────────────────────────────────

.PHONY: install-hooks release-dry-run

# Wire up local git hooks (cargo fmt/clippy on commit, swift compile on push).
install-hooks:
	@command -v lefthook >/dev/null 2>&1 || { \
	  echo "lefthook not found. Install with: brew install lefthook"; \
	  exit 1; \
	}
	lefthook install
	@echo "Hooks installed. Skip a commit with: LEFTHOOK=0 git commit ..."

# Preview what release-plz would propose without opening a PR.
release-dry-run:
	@command -v release-plz >/dev/null 2>&1 || { \
	  echo "release-plz not found. Install with: cargo install release-plz"; \
	  exit 1; \
	}
	release-plz update --dry-run
