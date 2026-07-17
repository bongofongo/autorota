# autorota

[![CI](https://github.com/bongofongo/autorota/actions/workflows/ci.yml/badge.svg)](https://github.com/bongofongo/autorota/actions/workflows/ci.yml)
[![Release](https://github.com/bongofongo/autorota/actions/workflows/release.yml/badge.svg)](https://github.com/bongofongo/autorota/actions/workflows/release.yml)

Multi-platform cafe shift scheduling app. Cafe managers define shifts, employees declare hour-by-hour availability, and the scheduler assigns employees to shifts respecting preferences and hour limits.

- **Core** — Rust workspace (`crates/`): scheduling engine, SQLite database, export (CSV/JSON/PDF), UniFFI bindings
- **Apple** — SwiftUI app for iOS/iPadOS/macOS (`platforms/apple/`), shipped via TestFlight + notarized `.dmg`
- **Desktop** — Tauri v2 (`crates/app-desktop`)

## Docs

- [`docs/overview.md`](docs/overview.md) — project overview (single source of truth)
- [`docs/ci-cd-guide.md`](docs/ci-cd-guide.md) — how CI/CD works: day-to-day dev flow, cutting releases, secrets, troubleshooting
- [`CLAUDE.md`](CLAUDE.md) — dev commands and working conventions

## Quick start

```bash
cargo fmt && cargo clippy && cargo test   # Rust checks
make swift-build-xcframework              # build the XCFramework (needed for Swift)
make swift-build-check                    # compile-check all Apple platforms
make test-all                             # everything
```
