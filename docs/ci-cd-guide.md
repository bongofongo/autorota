# Using autorota's CI/CD

A short operator's guide. For deeper reference (config, troubleshooting, file inventory), see [`releasing.md`](releasing.md).

## Mental model

Three pipelines, all GitHub Actions:

| Pipeline | When | What |
|---|---|---|
| **CI** (`ci.yml`) | every PR + push to `main` | Rust fmt/clippy/tests, builds XCFramework, runs Swift ViewModel + SPM tests, compile-checks Swift on macOS/iOS/iPadOS, cargo-checks Tauri |
| **release-plz** (`release-plz.yml`) | every push to `main` | Opens/updates a single "Release PR" with version bump + CHANGELOG diff |
| **Release** (`release.yml`) | tag `vX.Y.Z` | Builds + signs + ships: iOS TestFlight, macOS TestFlight, notarized `.dmg`, GitHub Release |

Plus background helpers: `rust-checks.yml` (reusable), `supply-chain.yml` (`cargo audit` + `cargo deny`, weekly), `pr-title.yml` (Conventional-Commit lint), `dependabot.yml` (weekly grouped updates).

## Day-to-day: writing code

1. Branch off `main`.
2. (Optional, recommended once) install local hooks:
   ```bash
   brew install lefthook
   make install-hooks
   ```
   This runs `cargo fmt --check` + `cargo clippy -D warnings` on every commit and `make swift-build-check` on every push that touches Swift. Skip a commit's hooks with `LEFTHOOK=0 git commit ...`.
3. Open a PR. **Title must be a Conventional Commit** — `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `perf:`, `build:`, `ci:`, `style:`, `test:`, `revert:`. Optional scope: `feat(scheduler): ...`.
4. CI runs. The full matrix has ~10 required jobs (Rust, XCFramework, 3 ViewModel platforms, 3 compile-check platforms, SPM integration, PR-title). Wait for green.
5. Squash-merge. The PR title becomes the commit and feeds the changelog.

### Reading CI failures

- **`Rust`** → fmt or clippy or test failure. Run `make lint` and `make rust-test` locally.
- **`Build XCFramework`** → almost always a Rust FFI break or missing Apple target. Run `make swift-build-xcframework` locally to repro.
- **`Swift ViewModel — <platform>`** → ViewModel test (uses `MockAutorotaService`). No XCFramework needed. Run `make swift-test-app-macos` etc.
- **`Swift Compile — <platform>`** → a Swift file that no test imports failed to compile. Run `make swift-build-check`.
- **`Swift Package Integration`** → real-FFI test failed. Needs XCFramework first: `make swift-build-xcframework && make swift-test-package`.
- **`Conventional Commit`** → rename your PR (no rebase needed; the workflow re-runs on edit).

### Local fast loop

```bash
make lint                       # rust fmt + clippy
make rust-test                  # rust unit + integration
make swift-build-check          # all 3 Apple platforms compile
make swift-build-xcframework    # only when FFI changed
make test-all                   # everything (slow)
```

## Day-to-day: cutting a release

You don't tag manually. The bot does it.

1. Land changes on `main`. Each merged PR's title becomes one changelog line.
2. Within ~1 min, the **release-plz** workflow opens (or updates) a PR titled `chore: release vX.Y.Z`. Open it and review:
   - `Cargo.toml` — workspace version bump
   - `Cargo.lock` — version reflected
   - `CHANGELOG.md` — entries grouped by Added / Fixed / Changed / etc.
3. Edit `CHANGELOG.md` directly in the PR if wording needs polish — release-plz preserves manual edits on subsequent updates.
4. Merge the PR. release-plz pushes tag `vX.Y.Z`.
5. The **Release** workflow fires on the tag. ~15-20 min later:
   - iOS build appears in App Store Connect → TestFlight
   - macOS build appears in App Store Connect → TestFlight (Mac App Store)
   - Notarized `.dmg` attached to a new GitHub Release
6. Promote builds to TestFlight testers / App Store from App Store Connect when ready.

### Bump rules

release-plz infers bump kind from commit prefixes since the last tag:

| Commit | Bump |
|---|---|
| `feat:` | minor (0.1.0 → 0.2.0) |
| `fix:`, `perf:`, `refactor:`, `chore:`, `build:`, `docs:` | patch (0.1.0 → 0.1.1) |
| `feat!:` or `BREAKING CHANGE:` footer | major (0.1.0 → 1.0.0) |
| `style:`, `test:`, `ci:` | no bump |

Want to preview the proposed bump locally before pushing?

```bash
cargo install release-plz   # one-time
make release-dry-run
```

### If the release doesn't fire after merging the Release PR

Check whether `RELEASE_PLZ_TOKEN` is set under Settings → Secrets. If absent, the tag push won't trigger `release.yml` (GitHub design — `GITHUB_TOKEN` can't chain workflows). Either:

- **Fix it permanently:** add a PAT with `repo` scope as `RELEASE_PLZ_TOKEN`. All future releases work end-to-end.
- **Recover this one:** re-push the tag manually:
  ```bash
  git fetch --tags
  git push origin :refs/tags/vX.Y.Z   # delete remote
  git push origin refs/tags/vX.Y.Z    # re-push, fires release.yml
  ```

## Hot-fix flow

Same as a normal release. There's no separate hot-fix path:

1. Branch off `main`, land a `fix:` PR.
2. release-plz opens a patch-bump Release PR.
3. Merge → tag → ship.

If you need to skip the full review cycle, the Release PR is just a normal PR — you can merge it as soon as it appears.

## What you should NOT do

- **Don't manually edit `Cargo.toml` version** — release-plz owns it. Manual bumps cause conflicts with the next Release PR.
- **Don't manually tag `vX.Y.Z`** — let release-plz do it. Manual tags work but skip the changelog/version-bump step.
- **Don't merge without a Conventional-Commit PR title** — it'll fail the `pr-title` check, and even if force-merged it pollutes the changelog.
- **Don't bypass CI with admin merge** unless production is on fire. The matrix is fast (~5 min) and catches real breaks.
- **Don't put secrets in workflows** — App Store Connect creds are already wired as repo secrets (`APP_STORE_CONNECT_API_KEY_*`). Add new ones via Settings → Secrets, never inline.

## Required setup checklist (one-time)

- [ ] `RELEASE_PLZ_TOKEN` repo secret (PAT, `repo` scope) — for tag-triggered release chaining
- [ ] `APP_STORE_CONNECT_API_KEY_P8` / `_ID` / `_ISSUER_ID` repo secrets — for TestFlight + notarization (already configured if releases were ever shipped)
- [ ] Branch protection on `main`: require all CI jobs + `pr-title` (full list in `releasing.md`)
- [ ] Linear history + require PR before merge (Settings → Branches)
- [ ] Devs run `make install-hooks` once on their machine (optional but reduces CI churn)

## Reference

- `docs/releasing.md` — full config reference, file inventory, troubleshooting
- `Makefile` — every available `make` target with comments
- `release-plz.toml` — release-plz config
- `lefthook.yml` — local hook config
