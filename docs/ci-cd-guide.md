# Using autorota's CI/CD

The complete guide to autorota's CI/CD, written for someone with zero prior context on this repo. If you already know the pipeline well, the [Troubleshooting index](#troubleshooting-index) and [Secrets and signing reference](#secrets-and-signing-reference) are the fastest lookup points.

For the prioritized list of known gaps and planned fixes, see [`ci-cd-improvement-plan.md`](ci-cd-improvement-plan.md).

## Mental model

Everything runs on GitHub Actions. Seven workflow files under `.github/workflows/`, plus Dependabot:

| Pipeline | File | When | What |
|---|---|---|---|
| **CI** | `ci.yml` | every PR + push to `main` | Rust fmt/clippy/tests, builds the XCFramework, runs SPM integration tests, compile-checks Swift on macOS/iOS/iPadOS. ViewModel test jobs are shelved (run them locally; revisit with the perf-test work) |
| **Rust checks** | `rust-checks.yml` | called by `ci.yml` and `release.yml` (not triggered directly) | `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test` — all excluding `app-desktop` (Tauri is not checked in CI at all while desktop is out of production; check locally with `cargo check -p app-desktop`) |
| **release-plz** | `release-plz.yml` | every push to `main` | Opens/updates a single "Release PR" with a version bump + `CHANGELOG.md` diff |
| **Release** | `release.yml` | push of tag `vX.Y.Z` | Builds, signs, and ships iOS → TestFlight, then a GitHub Release. macOS (Mac App Store + notarized `.dmg`) is shelved while there's no macOS app record — restore from git history when macOS ships |
| **Supply Chain** | `supply-chain.yml` | push/PR touching `Cargo.toml`/`Cargo.lock`/`deny.toml`, weekly Monday 06:00 UTC | `cargo audit` (known vulnerabilities) + `cargo deny` (license/source policy) |
| **Perf** | `perf.yml` | every PR to `main` | Rust criterion benches + Swift XCUITest perf suite. Never blocks merge — informational only, plus a soft scheduler-regression warning |
| **pr-title** | `pr-title.yml` | PR opened/edited/synced/reopened | Lints the PR title against Conventional Commits |
| **Dependabot** | `dependabot.yml` | weekly | Grouped minor/patch PRs for `cargo` and `github-actions` dependencies |

Nothing here uses fastlane, Bitrise, CircleCI, or Xcode Cloud as the primary path. There is a legacy Xcode Cloud hook at `platforms/apple/Apps/AutorotaApp/ci_scripts/ci_post_clone.sh` — see [Secrets and signing reference](#secrets-and-signing-reference) for what it's for and whether it's currently active.

## Glossary

Skip this if you already know these terms.

- **XCFramework** — a multi-platform binary framework bundle. Autorota's Rust core is compiled once per Apple target (macOS arm64/x86_64, iOS device, iOS Simulator) and packaged into one `.xcframework` that Swift code links against. Built by `scripts/build_xcframework.sh` / `make swift-build-xcframework`.
- **UniFFI** — the Mozilla tool that generates the Swift (and eventually Kotlin) bindings for calling into the Rust core. Runs as part of the XCFramework build.
- **TestFlight** — Apple's beta-distribution system. Builds uploaded here don't go live to App Store customers automatically; you promote a build to public release separately in App Store Connect.
- **Notarization** — Apple's automated malware/signature scan for software distributed outside the Mac App Store. A notarized `.dmg` can be "stapled" (the notarization ticket embedded in the file) so Gatekeeper can verify it offline.
- **Conventional Commits** — a commit/PR-title format (`feat:`, `fix:`, `chore:`, etc.) that both humans and tools like release-plz can parse to decide changelog grouping and version-bump size.
- **release-plz** — the tool that watches `main`, infers the next semver version from Conventional Commit prefixes since the last tag, and opens a PR with the version bump + changelog. It does not build or ship anything itself — it only proposes the version bump and, once merged, pushes the git tag.
- **`ExportOptions*.plist`** — Xcode config files that tell `xcodebuild -exportArchive` how to package a built app: which distribution method (App Store, Developer ID), which team, which signing style.

## One-time setup checklist

Do this once per repo (not per developer), typically as the person setting up releases for the first time:

- [ ] `RELEASE_PLZ_TOKEN` repo secret — a PAT (classic, `repo` scope) or GitHub App token. Needed because a tag pushed by a workflow authenticated with the default `GITHUB_TOKEN` cannot trigger another workflow (GitHub's anti-recursion design) — without this, merging the Release PR won't auto-fire `release.yml`.
- [ ] `APP_STORE_CONNECT_API_KEY_P8` / `APP_STORE_CONNECT_API_KEY_ID` / `APP_STORE_CONNECT_API_ISSUER_ID` repo secrets — see [Secrets and signing reference](#secrets-and-signing-reference) for how to generate these.
- [ ] Branch protection on `main` (Settings → Branches → Add rule): require these status checks before merging —
  - `Rust`
  - `Build XCFramework`
  - `Swift Compile — macOS`, `Swift Compile — iOS`, `Swift Compile — iPadOS`
  - `Swift Package Integration`
  - `Conventional Commit`

  Also recommended: require linear history, require PR before merge, require conversation resolution before merge.
- [ ] Each developer runs `make install-hooks` once, locally (optional but reduces CI churn — see [Local hooks](#local-hooks-optional)).
- [ ] **Before the first real release**, dry-run the pipeline against a throwaway tag below the real version (`v0.0.1` — a `-rc1` suffix won't trigger the workflow; the tag filter and `tag-parse` both require exactly `vX.Y.Z`) so signing/secrets/runner issues surface at low stakes instead of during the actual first ship. Delete the tag, GitHub Release, and TestFlight build afterward. See [`ci-cd-improvement-plan.md`](ci-cd-improvement-plan.md) gap #2.

## Day-to-day: writing code

1. Branch off `main`.
2. (Optional but recommended) install local hooks once:
   ```bash
   brew install lefthook
   make install-hooks
   ```
   This runs `cargo fmt --check` + `cargo clippy --workspace --all-targets -- -D warnings` on every commit (`pre-commit`, parallelized), and `make swift-build-check` on every push that touches Swift files, plus `make swift-test-app-macos` on pushes touching ViewModels/Services/tests (`pre-push`). Skip a single commit's hooks with `LEFTHOOK=0 git commit ...`. Uninstall entirely with `lefthook uninstall`.
3. Open a PR. **The PR title must be a Conventional Commit** — `feat:`, `fix:`, `docs:`, `style:`, `refactor:`, `perf:`, `test:`, `build:`, `ci:`, `chore:`, or `revert:`, optionally scoped (`feat(scheduler): add fairness tiebreak`), and the subject must start lowercase. This is enforced by the `pr-title` check and matters beyond style: **the squash-merge commit message is the PR title**, and release-plz parses that message to build the changelog. A bad title either fails the check or (if force-merged) silently pollutes the changelog.
4. CI runs automatically (`ci.yml` + `pr-title.yml`, and `perf.yml` non-blocking). Wait for the required checks to go green — see [One-time setup checklist](#one-time-setup-checklist) for the exact list, or just wait for all of them.
5. Squash-merge.

### Local fast loop

Run these locally before pushing, to catch what CI will catch, faster:

```bash
make lint                       # cargo fmt --check + cargo clippy -D warnings
make rust-test                  # cargo test --lib --workspace + integration tests
make swift-build-check          # compile-check all 3 Apple platforms (macOS, iOS, iPadOS)
make swift-build-xcframework    # rebuild the XCFramework — only needed when Rust FFI changed
make swift-test-app-macos       # ViewModel unit tests (mock service, no FFI/XCFramework needed)
make test-all                   # everything — Rust + all Swift platforms (slow)
```

Narrower Rust test targets exist too — `make rust-test-scheduler`, `rust-test-models`, `rust-test-export`, `rust-test-db`, `rust-test-migrations`, `rust-test-ffi`, and more. Run `grep '^\.PHONY' Makefile` or just open the `Makefile` to see the full list; each has a one-line comment explaining its scope.

### Reading CI failures

| Check name | Means | Repro locally |
|---|---|---|
| `Rust` | `cargo fmt`, `cargo clippy`, or `cargo test` failed | `make lint && make rust-test` |
| `Build XCFramework` | Rust FFI broke, or a target/toolchain issue | `make swift-build-xcframework` |
| ViewModel test failures | Not run in CI (shelved 2026-07-17, revisit with perf-test work) — local only | `make swift-test-app-macos` / `-ios` / `-ipad` |
| `Swift Compile — <platform>` | A Swift file that no test imports failed to compile | `make swift-build-check` |
| `Swift Package Integration` | A real-FFI test in `AutorotaKit`'s SPM test suite failed | `make swift-build-xcframework && make swift-test-package` |
| `Conventional Commit` | PR title doesn't match the required format | Rename the PR (no rebase needed — the check re-runs on title edit) |
| `cargo audit` / `cargo deny` (Supply Chain) | A dependency has a known vulnerability, or violates the license/source policy in `deny.toml` | `cargo audit` / `cargo deny check` locally (needs `cargo install cargo-audit cargo-deny` once) |

## Day-to-day: cutting a release

You never tag manually in the normal flow — release-plz does it for you.

1. Land changes on `main` via squash-merged PRs with Conventional-Commit titles. Each merged PR's title becomes one changelog line.
2. Within about a minute, the **release-plz** workflow opens (or updates) a PR titled `chore: release vX.Y.Z`. This is a normal PR you can review like any other:
   - `Cargo.toml` — workspace version bump (`workspace.package.version`)
   - `Cargo.lock` — reflects the new version
   - `CHANGELOG.md` — new entries grouped by Added / Fixed / Performance / Changed / Documentation / Internal / Build / Reverted (see [Bump and changelog rules](#bump-and-changelog-rules) for exactly how commits map to groups)
3. If a changelog entry's wording needs polish, edit `CHANGELOG.md` directly in that PR — release-plz preserves manual edits on subsequent updates (it won't stomp your wording if more PRs land before you merge).
4. Merge the Release PR. This pushes tag `vX.Y.Z` (using the `RELEASE_PLZ_TOKEN` secret — see [troubleshooting](#the-release-pr-merged-but-releaseyml-never-fired) if it doesn't fire).
5. The **Release** workflow (`release.yml`) fires on the tag push. It runs, in order:
   - `tag-parse` — validates the tag matches `vX.Y.Z` exactly (semver, no `v0.1` or `v1.0.0-beta`), extracts the version; build number = the GitHub Actions run number.
   - `rust-checks` — the same fmt/clippy/test gate as CI, re-run for safety.
   - `release-ios` — builds the XCFramework, patches `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` into `project.pbxproj` via `sed`, archives with `xcodebuild archive -allowProvisioningUpdates` authenticated via the App Store Connect API key, then exports with `platforms/apple/ExportOptions.plist`. The plist's `destination: upload` means the export step itself uploads the build to TestFlight — there is no separate upload step.
   - `release-ios` ends by zipping the archive's `dSYMs/` and uploading them as a build artifact (`dSYMs-ios-vX.Y.Z`, 90-day retention). **Download and keep these for any build that ships to real users** — CI archives vanish with the runner, and without the matching dSYMs a crash report from that build can never be symbolicated.
   - (`release-macos` — Mac App Store TestFlight + notarized `.dmg` — is shelved while there's no macOS app record in App Store Connect. Restore it from git history when macOS distribution resumes.)
   - `publish` — creates a GitHub Release (not draft, not prerelease) with auto-generated release notes. No artifacts attached while macOS/.dmg is shelved.
   - `notify-failure` — if any job above failed, auto-files a GitHub Issue titled `Release vX.Y.Z failed` linking the run. This is the failure signal: a half-shipped release (e.g. TestFlight upload succeeded but publish failed) shows up as an issue, not just a red check in the Actions tab.
6. ~10–15 minutes after the tag push: the iOS build appears in App Store Connect → TestFlight, and a GitHub Release is published.
7. **Manually confirm the TestFlight builds actually finished processing** in App Store Connect before telling testers — a green `release.yml` only confirms the upload succeeded; Apple's binary processing (export compliance / asset validation) happens afterward and isn't currently monitored by CI. See gap #5 in [`ci-cd-improvement-plan.md`](ci-cd-improvement-plan.md).
8. Promote builds to TestFlight testers, or submit to the App Store, from App Store Connect when ready — that step is manual and intentionally not automated.

### Bump and changelog rules

release-plz infers the version bump from Conventional Commit prefixes since the last tag:

| Prefix | Bump | Changelog group |
|---|---|---|
| `feat:` | minor (`0.1.0` → `0.2.0`) | Added |
| `fix:` | patch (`0.1.0` → `0.1.1`) | Fixed |
| `perf:` | patch | Performance |
| `refactor:` | patch | Changed |
| `docs:` | patch | Documentation |
| `chore:` | patch | Internal |
| `build:` | patch | Build |
| `revert:` | patch | Reverted |
| `feat!:` or a `BREAKING CHANGE:` footer | major (`0.1.0` → `1.0.0`) | Added (breaking) |
| `style:`, `test:`, `ci:`, `chore(release):` | no bump, no changelog entry | (skipped) |

Preview the proposed bump locally before pushing anything:

```bash
cargo install release-plz   # one-time
make release-dry-run
```

### What you should NOT do

- **Don't manually edit the version in `Cargo.toml`.** release-plz owns it; manual bumps cause conflicts with the next Release PR.
- **Don't manually tag `vX.Y.Z`.** Let release-plz do it — a manual tag works (it'll still fire `release.yml`) but skips the version-bump/changelog step, so `Cargo.toml` and the tag drift apart.
- **Don't merge without a Conventional-Commit PR title.** It fails the `pr-title` check, and even if force-merged it silently breaks the changelog.
- **Don't bypass CI with an admin merge** unless production is actually on fire. The full matrix is a few minutes and catches real breaks.
- **Don't put secrets in workflow files.** App Store Connect credentials are already wired as repo secrets — add new ones via Settings → Secrets, never inline in YAML.

## Hot-fix flow

Use this only when a correctness bug is already in a shipped build (TestFlight or App Store) and waiting for the normal release-plz cadence is too slow — data loss, security exposure, or app-launch failure, with a small contained fix. Otherwise, just merge to `main` and let the next Release PR pick it up; there's no separate "fast path" needed for ordinary bugs.

1. **Branch off the release tag, not `main`**, to avoid dragging in unrelated in-flight work:
   ```bash
   git fetch --tags
   git checkout -b hotfix/v0.2.1 v0.2.0
   ```
2. **Cherry-pick the fix from `main`** (assumes it's already landed there as a normal PR):
   ```bash
   git cherry-pick <sha>
   ```
   If the fix isn't on `main` yet, write it directly on the hotfix branch and remember to also land it on `main` separately.
3. **Bump the patch version by hand** — release-plz doesn't run on this branch:
   - `Cargo.toml`: `workspace.package.version`
   - `CHANGELOG.md`: prepend the fix under `[0.2.1] - YYYY-MM-DD`
4. **Run the gates locally** before pushing (CI runs them too, but failing fast locally is quicker):
   ```bash
   cargo fmt && cargo clippy && cargo test
   make swift-build-check
   make swift-test-app-macos
   ```
5. **Push and tag** — the tag is what fires `release.yml`:
   ```bash
   git push -u origin hotfix/v0.2.1
   git tag v0.2.1
   git push origin v0.2.1
   ```
6. **Watch `release.yml`** run through the full iOS build-sign-ship path described above.
7. **Backmerge to `main`**, even though you cherry-picked — the version bump and changelog still need to land there:
   ```bash
   git checkout main
   git pull
   git merge --no-ff hotfix/v0.2.1
   git push
   ```
   release-plz reconciles automatically and skips a redundant bump on its next Release PR.
8. **Afterward:** tell the team the version, the bug, and the one-line fix. If the bug warranted a hot-fix, it warranted a regression test — confirm it landed in the same PR rather than queuing it as a follow-up. If this is the second hot-fix for the same area, consider a postmortem.

## Reading perf checks

`perf.yml` runs on every PR to `main`. **It never blocks merge** — both jobs (`rust-bench`, `swift-perf`) use `continue-on-error: true` by design. Treat a red Perf check as a signal to look, not a merge blocker.

```bash
make bench              # Rust criterion benches (~3 min)
make swift-perf-ios     # XCUITest cold launch + week nav + render, iOS Simulator (~2 min)
make perf-all           # both
```

Rust results: `target/criterion/report/index.html`. Swift results: latest `.xcresult` in `~/Library/Developer/Xcode/DerivedData/AutorotaApp-*/Logs/Test/`. In CI, both are uploaded as artifacts (`criterion-html`, `swift-perf-xcresult`, 14-day retention) plus a bencher-format summary in the job summary.

### The soft regression gate

`rust-bench` additionally benches the PR's merge base and the PR head **on the same runner** (so machine variance cancels out) and lets criterion's own statistical test decide whether the scheduler engine (`schedule_pure*` groups only — save/export stay purely informational) regressed. If it did (`p < 0.05`), the step emits a `::warning::` annotation — it never exits non-zero, so the check stays green regardless (report-only policy). Read the `criterion-html` artifact or the step's `cmp.txt` output to see which group moved and by how much. `perf.yml` also runs the Kit FFI perf suite per-PR (`kit-perf` job, job-summary table via `scripts/perf_report.py`) and the XCUITest simulator suite weekly on `main` + on manual dispatch.

### What's covered

Rust: scheduler (by employee count, by week count, two-stage enriched fill), the hottest inner primitives (`for_window`, `has_role`), save snapshot/diff, and export (grid build, CSV/JSON/markdown, xlsx, PDF). Swift: cold/warm launch, week navigation, first rota render — all via XCUITest with a synthetic seeded corpus (`--perf-seed-corpus <N>` launch argument), skipping iCloud sync/onboarding/exchange-rate fetch.

### Test plan wiring (already done — reference only)

The `AutorotaAppPerfTests` target exists, and the `AutorotaApp` scheme references two test plans, both living next to the `.xcodeproj`:

- `AutorotaApp.xctestplan` (default) — `AutorotaAppTests` only. Plain `xcodebuild test` / `make swift-test-app-*` uses this, so the XCUITest perf runner never boots during unit runs.
- `Perf.xctestplan` — `AutorotaAppPerfTests` only, selected via `-testPlan Perf` by `make swift-perf-ios` / `swift-perf-macos` and `perf.yml`.

If either plan stops resolving (e.g. after a project rename), check the `<TestPlans>` block in `AutorotaApp.xcscheme` and verify with `xcodebuild -showTestPlans -project … -scheme AutorotaApp`.

### Baselines

This repo never records Xcode perf baselines — comparison happens outside Xcode via `make perf-report` and `perf/history.jsonl` (see [`perf-testing.md`](perf-testing.md#why-we-dont-use-xcode-baselines)). Criterion named baselines for refactors: `cargo bench -p autorota-core --bench scheduler -- --save-baseline <name>`, then compare with `-- --baseline <name>`.

## Secrets and signing reference

All secrets live as GitHub Actions repo secrets (Settings → Secrets and variables → Actions). No `.env` files, no keychain-import steps in CI — signing is entirely API-key-driven via `xcodebuild -allowProvisioningUpdates`, not certificate/keychain-based.

| Secret | Used by | What it is | Rotation |
|---|---|---|---|
| `RELEASE_PLZ_TOKEN` | `release-plz.yml` | PAT (`repo` scope, classic) or GitHub App token | Falls back to `GITHUB_TOKEN` if unset, but then the tag it pushes can't trigger `release.yml` (GitHub's anti-recursion rule) — see [troubleshooting](#the-release-pr-merged-but-releaseyml-never-fired). Rotate by generating a new PAT and updating the secret; no downstream code changes needed. |
| `APP_STORE_CONNECT_API_KEY_P8` | `release.yml` | Base64-encoded contents of an App Store Connect API key `.p8` file. **The key must have the Admin role** — cloud signing (`-allowProvisioningUpdates` creating the distribution cert/profile) fails with "Cloud signing permission error" on an App Manager key | Generate at App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys. Base64-encode with `base64 -i AuthKey_XXXX.p8 \| pbcopy` before pasting into the GitHub secret. Decoded to `~/private_keys/AuthKey_<ID>.p8` at job start and `rm -rf`'d in an `if: always()` cleanup step — never persists on the runner. |
| `APP_STORE_CONNECT_API_KEY_ID` | `release.yml` | The key ID shown next to the key in App Store Connect | Changes whenever the key is regenerated. |
| `APP_STORE_CONNECT_API_ISSUER_ID` | `release.yml` | The Issuer ID for the whole App Store Connect account (same for all keys) | Rarely changes. |

### `ExportOptions*.plist`

Three files under `platforms/apple/`, each referenced by exact path in `release.yml`:

- `ExportOptions.plist` — `method: app-store-connect`, team `34VGHNCG6J`, destination `upload` → used for the iOS TestFlight export.
- `ExportOptions-MacAppStore.plist` — same method/team, destination `upload` → macOS Mac App Store TestFlight export. Currently unused (macOS release shelved); kept for when it resumes.
- `ExportOptions-DeveloperID.plist` — `method: developer-id`, `signingStyle: automatic`, destination `export` → the notarized-`.dmg` path. Currently unused, same reason.

These files are **intentionally committed** — they contain a team ID and export method, not private keys (each carries a comment saying so). Keep them in sync with the signing certificates and team ID if either ever changes.

### The Xcode Cloud hook

`platforms/apple/Apps/AutorotaApp/ci_scripts/ci_post_clone.sh` is Apple's auto-detected Xcode Cloud post-clone hook — it installs `rustup` via Homebrew and builds the XCFramework, working around two real incidents documented in `BUG_LOG.md` (a DNS resolution failure fetching the rustup installer, and a keg-only Homebrew formula not exposing `cargo`/`rustc` on `PATH`). Xcode Cloud is **not** the release path — GitHub Actions is — and the script's header comment now says so. The hook only does anything if an Xcode Cloud workflow is actually configured for this app in App Store Connect. As of 2026-07-20 the only workflow there was disabled (gap #7 closed) — GitHub Actions is the single build/submit path, and nothing (including perf) runs on Xcode Cloud.

## Troubleshooting index

| You see | Do this |
|---|---|
| A required CI check failing | Find it in the [Reading CI failures](#reading-ci-failures) table above and run the matching local repro command |
| Release PR opened but no version bump | release-plz only bumps on a meaningful Conventional Commit since the last tag — `style:`, `test:`, `ci:`, and `chore(release):` are all skipped by design |
| `<a name="the-release-pr-merged-but-releaseyml-never-fired"></a>`Tag pushed (via merging the Release PR) but `release.yml` never fired | `RELEASE_PLZ_TOKEN` is missing or under-scoped. Fix permanently by adding a `repo`-scope PAT as that secret. Recover the stuck release by re-pushing the tag manually: `git fetch --tags && git push origin :refs/tags/vX.Y.Z && git push origin refs/tags/vX.Y.Z` |
| A `CHANGELOG.md` entry reads wrong | Edit it directly in the open Release PR — release-plz preserves manual edits on subsequent updates |
| Stale Release PR after a force-push to `main` | Close it; release-plz opens a fresh one on the next push |
| `make swift-perf-macos` / `-ios` fails with "scheme does not contain a test plan named Perf" | The scheme's `<TestPlans>` block lost its `Perf.xctestplan` reference — see [Test plan wiring](#test-plan-wiring-already-done--reference-only) |
| `make swift-perf-macos` fails with "Timed out while enabling automation mode" | Needs Accessibility permission: System Settings → Privacy & Security → Accessibility, enable for Terminal (or your shell host) and Xcode. First run after granting may still time out — re-run once. |
| `make swift-perf-macos` fails with `LaunchServices error -10661` | App sandbox is active; confirm the `ENABLE_APP_SANDBOX=NO` and cleared-entitlements overrides in the `swift-perf-macos` Make target survived |
| `seedPerfCorpus` symbol not found | XCFramework was built without `PERF_HELPERS=1` — run `make swift-perf-xcframework` |
| Criterion says "Unable to complete benchmarks" | Usually a panic during setup — run `cargo bench -p autorota-core --bench <name> 2>&1 \| head -50` to see the message |
| A Swift CI job fails selecting Xcode (`setup-xcode` can't find `26.0`) | Swift/Apple jobs run on the `macos-26` runner image; if GitHub rotates the preinstalled Xcode versions, bump `xcode-version` in `ci.yml` / `release.yml` / `perf.yml` to a version present on the image |
| `release.yml` green but the build never shows up in TestFlight | Apple's async binary processing failed after upload — this isn't currently monitored by CI (gap #5); check App Store Connect directly for a rejection reason |
| `release.yml` failed and you weren't watching | A GitHub Issue titled `Release vX.Y.Z failed` is auto-filed with a link to the run — check whether either platform already uploaded to TestFlight before the failure |
| Export step fails with `Cloud signing permission error` / `No profiles for '<bundle id>' were found` | The App Store Connect API key can't create signing assets — generate a new Team Key with the **Admin** role, update `APP_STORE_CONNECT_API_KEY_P8` + `_KEY_ID` secrets, re-push the tag |

## Reference

- [`ci-cd-improvement-plan.md`](ci-cd-improvement-plan.md) — prioritized gaps and planned fixes
- `Makefile` — every available `make` target, each with a one-line comment
- `release-plz.toml` — release-plz config
- `lefthook.yml` — local hook config
- `.github/workflows/` — the actual workflow definitions; this guide summarizes them but they're the source of truth if anything drifts
