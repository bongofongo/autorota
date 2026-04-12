# Known Gaps

## Critical

### CI will fail on Swift jobs
CI runs on `macos-15` but requires Xcode 26+. The workflow acknowledges this with a comment. Swift jobs will fail until a runner with Xcode 26 is available. Additionally, `.pbxproj` deployment targets may have drifted to iOS 26.2 / macOS 26.1 — should be iOS 17 / macOS 14.

## Moderate

### Release pipeline uses deprecated upload tool
`release.yml` is comprehensive (tag-triggered, XCFramework build, archive, App Store Connect upload) but uses `xcrun altool --upload-app` which Apple has deprecated. Migrate to App Store Connect API or Transporter. `ExportOptions.plist` files are untracked and must be maintained manually.

### Tauri desktop app missing features vs SwiftUI
Core scheduling works (employees, shifts, overrides, rota). Missing:
- **Export** — no Tauri command wrapping the existing `export_week_schedule` (easiest win)
- **Wages/currency** — no hourly wage entry or exchange rate display
- **Settings view** — no app settings or currency selection
- **Shift history UI** — backend command exists but no frontend view
- **Analytics** — no analytics dashboard
- **Staging/commits** — no staging or commit history UI (backend commands exist)
- **Onboarding** — no first-launch onboarding flow

### Test coverage gaps
Several implemented features have no test coverage:
- **Export rendering** — grid building, CSV/JSON serialization, and PDF generation are untested
- **FFI layer** — no unit tests for type conversions or error handling in `autorota-ffi`
- **Tauri command handlers** — no integration tests for `app-desktop` commands
- **Sync/staging/commit workflows** — sync query layer has integration tests, but the Swift-side `AutorotaSyncEngine`, `SyncConflictResolver`, and `SyncRecordMapper` are untested
- **No UI/snapshot tests** — no automated visual or interaction tests for the SwiftUI app

### Scheduler limitations
The scheduling algorithm is single-pass greedy, which is effective for weekly rotas but has known limitations:
- No multi-week fairness balancing (each week is scheduled independently)
- No shift preference or affinity modeling
- No post-assignment optimization pass (e.g., swaps to improve fairness)
- No constraint relaxation when `min_employees` cannot be met

### No retry logic for failed sync operations
`AutorotaSyncEngine` handles CKSyncEngine events but does not retry failed push/fetch operations beyond what CKSyncEngine provides automatically.
