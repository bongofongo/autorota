# Bug Log

Concise running log of bugs encountered. Each entry is one bullet with sub-bullets. New entries appended at top. Patched entries remain `pending verification` until the user confirms.

- **Xcode Cloud archive build fails: rustup install can't resolve static.rust-lang.org**
  - Date fixed: 2026-05-11 (pending verification)
  - Where / what / repro: Xcode Cloud build #5 (commit `5037895`), `ci_post_clone.sh`. The `curl https://sh.rustup.rs | sh` bootstrapper downloaded the installer script, but its secondary fetch of `rustup-init` from `static.rust-lang.org` returned `curl: (6) Could not resolve host: static.rust-lang.org` four times then aborted. Without Rust, `scripts/build_xcframework.sh` never ran, so `xcodebuild -describeSchemes` failed with `local binary target 'AutorotaFFI' … does not contain a binary artifact`. Repro: push to `main`, watch the Xcode Cloud Default workflow.
  - Patched: yes — pending user verification
  - Fix: `platforms/apple/Apps/AutorotaApp/ci_scripts/ci_post_clone.sh` now installs rustup via `brew install rustup` (Homebrew is preinstalled on Cloud runners and pulls bottles from GitHub-hosted CDNs), then bootstraps the toolchain with `rustup-init -y --default-toolchain stable --profile minimal --no-modify-path`. Both steps guarded by idempotency checks. Targets and `build_xcframework.sh` invocation unchanged.
  - Followup (build #7): the brew install resolved the DNS issue but build still failed with `cargo: command not found` from `build_xcframework.sh`. Two reasons: (a) the brew `rustup` formula is **keg-only** (conflicts with `rust`), so its bin dir was never on PATH and `rustup-init` was only findable by warm-runner luck; (b) the `rustup show active-toolchain` guard reported success on a warm runner where prior state had a toolchain registered, so `rustup-init` was skipped and the `~/.cargo/bin/{cargo,rustc}` shims were never created. Patched by: explicitly adding `$(brew --prefix rustup)/bin` to PATH; pinning `RUSTUP_HOME`/`CARGO_HOME` to `$HOME/.{rustup,cargo}`; replacing the active-toolchain guard with a direct `[[ -x $CARGO_HOME/bin/cargo ]]` shim check; appending `$CARGO_HOME/bin` to PATH; and adding a fail-fast loop that aborts if `rustup`/`rustc`/`cargo` are still missing before the build script runs.

- **Menu tab "Other Pages" rows un-tappable after first navigation**
  - Date fixed: —
  - Where / what / repro: Menu tab → "Other Pages" section. After tapping one entry (e.g. Exceptions) and returning, tapping a second entry (e.g. Edit Log) only flashes the row dark grey — no navigation. Repro from a fresh state: open Menu, tap Exceptions, go back, tap Edit Log.
  - Patched: no — one fix attempt failed, see `bugs/unpatched/menu-other-pages-untappable-after-first-nav.md`
  - Fix: n/a (open). Hypothesis: nested NavigationStacks (every destination view wraps itself in its own `NavigationStack`).

- **"Required role" Picker in shift template editor cannot be opened**
  - Date fixed: —
  - Where / what / repro: `ShiftTemplateEditSheet` → "Role & Staffing" → "Required role" row tap does nothing — Picker never opens. Repro: create at least one role, create or edit a shift template, try to switch the role away from "Any Role".
  - Patched: no
  - Fix: n/a (open — see `IOS_BUGS.md` #3 for investigation notes)

- **Rota empty-state "Add employee" button does nothing when Employees is in overflow Menu**
  - Date fixed: —
  - Where / what / repro: Rota tab CUV's "Add employee" button. Repro: remove Employees from the configurable tab bar so it lives only in overflow Menu; with no employees, open Rota tab and tap "Add employee" — no tab switch, no sheet.
  - Patched: no
  - Fix: n/a (open — see `IOS_BUGS.md` #2 for proposed fix sketch)

- **Shifts tab list-placeholder flicker on empty state**
  - Date fixed: 2026-04-30 (commit `5cb5e37`)
  - Where / what / repro: `ShiftTemplateListView` briefly flashed grey "No roles yet" / "No shifts yet" rows for one frame before settling on the `ContentUnavailableView`. Repro: launch with no roles/templates, switch to another tab and back to Shifts.
  - Patched: yes — pending user verification
  - Fix: added `hasLoaded` flag to `ShiftTemplateViewModel` and `RoleViewModel`; `isFullyEmpty` now waits for both to finish loading before choosing CUV vs list; renders `Color.clear` while pending instead of the empty list.
