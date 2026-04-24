# Known Gaps

## Critical

### CI will fail on Swift jobs
CI runs on `macos-15` but requires Xcode 26+. The workflow acknowledges this with a comment. Swift jobs will fail until a runner with Xcode 26 is available. Xcode project deployment targets are iOS/iPadOS 26.2, macOS 26.1, visionOS 26.2 — matching the Xcode 26 baseline.

## Moderate

### Release pipeline: ExportOptions.plist files committed but fragile
`release.yml` is comprehensive (tag-triggered, XCFramework build, archive, App Store Connect and Developer ID paths). Notarization uses `xcrun notarytool` + `stapler`, not the deprecated `altool`. `ExportOptions.plist`, `ExportOptions-MacAppStore.plist`, and `ExportOptions-DeveloperID.plist` live under `platforms/apple/` and must be kept aligned with the signing certificates and team ID (`34VGHNCG6J`).

### Tauri desktop app missing features vs SwiftUI
Core scheduling works (employees, shifts, roles, overrides, rota, assignments, saves/diff). The Tauri frontend is vanilla TypeScript (no framework) and lags the SwiftUI app. Missing:
- **Export UI** — `export_week_schedule` backend exists; no frontend trigger
- **Wages/currency** — no hourly wage entry or exchange rate display
- **Settings view** — no app settings or currency selection
- **Shift history UI** — backend command exists but no frontend view
- **Analytics** — no analytics dashboard
- **Saves / activity log** — backend commands exist but no UI for save list, restore, or labeling
- **Onboarding** — no first-launch onboarding flow
- **iCloud sync** — Apple-platform-only by design; no equivalent on desktop

### Test coverage gaps
Several implemented features still have thin or no test coverage:
- **FFI layer** — `autorota-ffi` has no unit tests for type conversions or error handling
- **Tauri command handlers** — no integration tests for `app-desktop` commands
- **Sync Swift layer** — Rust-side sync queries are covered in integration tests, but `AutorotaSyncEngine`, `SyncConflictResolver`, and `SyncRecordMapper` are untested
- **No UI / snapshot tests** — no automated visual or interaction tests for the SwiftUI app
- **PDF rendering** — `export_test.rs` covers CSV/JSON/grid paths, but the PDF submodules (`by_role`, `employee_schedule`, `employee`, `weekly`, `theme`) are only exercised end-to-end

### Scheduler limitations
The scheduling algorithm is two-pass greedy (overrides first, then hardest-to-fill), effective for weekly rotas but with known limitations:
- No multi-week fairness balancing (each week is scheduled independently)
- No shift preference or affinity modeling
- No post-assignment optimization pass (e.g., swaps to improve fairness)
- No constraint relaxation when `min_employees` cannot be met

### No retry logic for failed sync operations
`AutorotaSyncEngine` handles `CKSyncEngine` events but does not retry failed push/fetch operations beyond what `CKSyncEngine` provides automatically. No explicit backoff, no user-visible sync error state beyond the Settings indicator.
