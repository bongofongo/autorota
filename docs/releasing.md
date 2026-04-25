# Releasing

Autorota uses a **Release-PR flow**: every push to `main` triggers
[release-plz](https://release-plz.dev), which opens (or updates) a single
"Release PR" containing:

- Cargo workspace version bump (`workspace.package.version`)
- `CHANGELOG.md` entries derived from Conventional-Commit messages since the
  last tag

Merging the Release PR pushes a tag `vX.Y.Z`. The existing
`.github/workflows/release.yml` fires on the tag and runs the full build:

- Builds the XCFramework
- Archives + signs iOS, uploads to TestFlight
- Archives + signs macOS, uploads to TestFlight (Mac App Store) **and**
  produces a notarized `.dmg` (Developer ID)
- Creates a GitHub Release with the `.dmg` attached

## One-time setup

### 1. PAT for tag-triggered release.yml

GitHub will not fire one workflow from a tag pushed by another workflow
authenticated with the default `GITHUB_TOKEN`. To make the merge of the
Release PR auto-trigger `release.yml`, supply a Personal Access Token (or a
GitHub App token) as repo secret **`RELEASE_PLZ_TOKEN`**:

- Scope: `repo` (classic PAT) or `contents: read/write` + `pull_requests: read/write`
  (fine-grained PAT)
- Settings → Secrets and variables → Actions → New repository secret →
  `RELEASE_PLZ_TOKEN`

If `RELEASE_PLZ_TOKEN` is unset, the Release PR still works, but after merge
you'll need to re-push the tag manually to fire the release pipeline:
```bash
git fetch --tags
git push origin :refs/tags/v0.2.0   # delete remote
git push origin refs/tags/v0.2.0    # re-push to trigger
```

### 2. App Store Connect API key (already configured)

`release.yml` expects these secrets:

- `APP_STORE_CONNECT_API_KEY_P8` (base64-encoded `.p8`)
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_API_ISSUER_ID`

### 3. Branch protection (manual, GitHub UI)

Settings → Branches → `main` → Add rule:

**Require status checks to pass before merging**, select:

- `Rust` (from `rust-checks.yml`)
- `Build XCFramework`
- `Swift ViewModel — macOS`
- `Swift ViewModel — iOS`
- `Swift ViewModel — iPadOS`
- `Swift Compile — macOS`
- `Swift Compile — iOS`
- `Swift Compile — iPadOS`
- `Swift Package Integration`
- `Conventional Commit` (from `pr-title.yml`)

Also recommended:
- Require linear history (compatible with squash-merge + release-plz)
- Require pull request before merging
- Require conversation resolution before merging

## Day-to-day workflow

### Authoring commits

Use Conventional Commits in **PR titles**:

| Prefix | Use for | Changelog group |
|---|---|---|
| `feat:` | new feature | Added |
| `fix:` | bug fix | Fixed |
| `perf:` | perf improvement | Performance |
| `refactor:` | refactor (no user-visible change) | Changed |
| `docs:` | docs only | Documentation |
| `chore:` | tooling, deps | Internal |
| `build:` | build system | Build |
| `ci:` | CI config | (skipped) |
| `style:` / `test:` | style / tests | (skipped) |
| `revert:` | revert | Reverted |

Bump rules (release-plz default):
- `feat:` → minor (0.1.0 → 0.2.0)
- `fix:` / `perf:` / others → patch (0.1.0 → 0.1.1)
- `BREAKING CHANGE:` footer or `feat!:` → major

### Cutting a release

1. Land changes on `main` via squash-merged PRs with Conventional-Commit titles.
2. Wait ~1 minute. The `release-plz` workflow opens (or updates) a PR titled
   `chore: release vX.Y.Z`. Review the diff:
   - `Cargo.toml` version bump
   - `Cargo.lock`
   - `CHANGELOG.md` entries
3. Merge the Release PR.
4. release-plz pushes tag `vX.Y.Z` (using `RELEASE_PLZ_TOKEN`).
5. `release.yml` fires on the tag. Watch the Actions tab.
6. Done — TestFlight builds appear in App Store Connect, GitHub Release is
   published with the notarized `.dmg`.

### Local preview

Before pushing, preview what release-plz would propose:

```bash
cargo install release-plz   # one-time
make release-dry-run
```

### Local hooks (optional)

Opt-in pre-commit + pre-push checks:

```bash
brew install lefthook       # one-time
make install-hooks
```

This installs:
- **pre-commit**: `cargo fmt --check` on staged `*.rs`, `cargo clippy
  --workspace --all-targets -- -D warnings`
- **pre-push**: `make swift-build-check` (3-platform compile) if any Swift
  files changed in the push

Skip a single commit: `LEFTHOOK=0 git commit ...`.
Uninstall entirely: `lefthook uninstall`.

## Troubleshooting

### Release PR opened but no version bump

release-plz only bumps when it sees a meaningful Conventional-Commit since
the last tag. `style:`, `test:`, `ci:`, `chore(release):` are skipped.

### Tag pushed but release.yml didn't fire

`RELEASE_PLZ_TOKEN` is missing or lacks scope. Re-push the tag manually
(see "One-time setup → PAT" above).

### CHANGELOG entry looks wrong

Edit `CHANGELOG.md` directly in the open Release PR; release-plz preserves
manual edits on subsequent updates.

### Stale Release PR after force-push to main

Close the PR; release-plz will open a fresh one on the next push.

## Files

| File | Role |
|---|---|
| `release-plz.toml` | release-plz config |
| `.github/workflows/release-plz.yml` | Opens/updates Release PR on push to main |
| `.github/workflows/release.yml` | Tag-triggered: builds, signs, ships |
| `.github/workflows/pr-title.yml` | Conventional-Commit lint on PR titles |
| `.github/workflows/ci.yml` | Per-PR checks (Rust, XCFramework, Swift) |
| `.github/workflows/rust-checks.yml` | Reusable: fmt + clippy + tests |
| `.github/workflows/supply-chain.yml` | cargo audit + cargo deny |
| `lefthook.yml` | Local pre-commit / pre-push hooks |
| `CHANGELOG.md` | Auto-maintained release log |
