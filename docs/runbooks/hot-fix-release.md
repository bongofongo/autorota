# Hot-fix release flow

**Trigger:** a correctness bug is in a shipped build (TestFlight or App
Store) and waiting for the next release-plz Release PR is too slow.
Used during PR1 of the bulletproofing pass.

## Decision

Hot-fix only when:

- The bug causes data loss, security exposure, or app launch failure.
- The fix is small and contained (single PR, ideally <500 lines).
- Skipping the release-plz cadence is genuinely faster than just merging
  to main and letting the next Release PR pick it up.

Otherwise: merge to main and wait for the next Release PR (it auto-opens
on every push).

## Steps

1. **Branch off the release tag, not main.** Avoids dragging in unrelated
   in-flight work:
   ```bash
   git fetch --tags
   git checkout -b hotfix/v0.2.1 v0.2.0
   ```

2. **Cherry-pick the fix from main** (assumes the fix has already landed
   on main as a regular PR):
   ```bash
   git cherry-pick <sha>
   ```
   If the fix isn't on main yet, write it directly on the hotfix branch
   and remember to also commit it to main afterwards.

3. **Bump the patch version manually** (release-plz won't run on this
   branch):
   - `Cargo.toml`: `workspace.package.version`
   - `CHANGELOG.md`: prepend the fix under `[0.2.1] - YYYY-MM-DD`

4. **Run the gates locally** (CI also runs them, but failing locally
   first is faster):
   ```bash
   cargo fmt && cargo clippy && cargo test
   make swift-build-check
   make swift-test-app-macos
   ```

5. **Push and tag.** The tag is what fires `release.yml`:
   ```bash
   git push -u origin hotfix/v0.2.1
   git tag v0.2.1
   git push origin v0.2.1
   ```

6. **Watch CI.** `release.yml` builds the XCFramework, signs / uploads
   iOS to TestFlight, signs / notarizes / staples macOS, runs the new
   `spctl --assess` Gatekeeper check (PR6), and creates a GitHub Release
   with the `.dmg`.

7. **Backmerge to main.** Even if you cherry-picked, the version bump
   and changelog need to land on main:
   ```bash
   git checkout main
   git pull
   git merge --no-ff hotfix/v0.2.1
   git push
   ```
   release-plz will reconcile and skip the bump on its next Release PR.

## Aftermath

- Post in #releases (or wherever) with the version, the bug, and the
  one-line fix.
- If the bug warranted a hot-fix, it warranted a regression test —
  confirm the test landed in the same PR (don't queue it as a follow-up).
- Open a postmortem if this is the second hot-fix for the same area.
