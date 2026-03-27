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
# Building the XCFramework is required before running any Swift test that
# imports AutorotaKit (including the app target compile).  Run once:
#   make swift-build-xcframework

PROJECT := platforms/apple/Apps/AutorotaApp/AutorotaApp.xcodeproj
SCHEME  := AutorotaApp
SPM_PKG := platforms/apple/AutorotaKit
XCB     := xcodebuild -project $(PROJECT) -scheme $(SCHEME)

# ─── Rust ────────────────────────────────────────────────────────────────────

.PHONY: rust-test rust-test-unit rust-test-integration rust-fmt rust-clippy lint

rust-test: rust-test-unit rust-test-integration

rust-test-unit:
	cargo test --lib --workspace

rust-test-integration:
	cargo test --test '*' -p autorota-core

rust-fmt:
	cargo fmt --check --all

rust-clippy:
	cargo clippy --workspace -- -D warnings

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

.PHONY: swift-build-check-macos swift-build-check-ios swift-build-check-ipad swift-build-check

swift-build-check-macos:
	$(XCB) build -destination 'platform=macOS' $(NOSIGN)

swift-build-check-ios:
	$(XCB) build -destination 'platform=iOS Simulator,name=iPhone 17' $(NOSIGN)

swift-build-check-ipad:
	$(XCB) build -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' $(NOSIGN)

swift-build-check: swift-build-check-macos swift-build-check-ios swift-build-check-ipad

# ─── Apple — ViewModel unit tests (mock service, no live FFI) ────────────────

.PHONY: swift-test-app-macos swift-test-app-ios swift-test-app-ipad

# CODE_SIGN_IDENTITY="" disables code signing for local test runs (no provisioning profile needed).
NOSIGN := CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

swift-test-app-macos:
	$(XCB) test -destination 'platform=macOS' $(NOSIGN)

swift-test-app-ios:
	$(XCB) test -destination 'platform=iOS Simulator,name=iPhone 17' $(NOSIGN)

swift-test-app-ipad:
	$(XCB) test -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' $(NOSIGN)

# ─── Apple — SPM integration tests (real FFI calls, XCFramework required) ────

.PHONY: swift-test-package

swift-test-package:
	cd $(SPM_PKG) && swift test

# ─── Combined ────────────────────────────────────────────────────────────────

.PHONY: swift-test-all test-all

# All Swift tests — requires XCFramework to be already built.
swift-test-all: swift-test-app-macos swift-test-app-ios swift-test-app-ipad swift-test-package

# Full suite: Rust, then all Swift platforms.
# On a clean machine, run `make swift-build-xcframework` first.
test-all: rust-test swift-test-all
