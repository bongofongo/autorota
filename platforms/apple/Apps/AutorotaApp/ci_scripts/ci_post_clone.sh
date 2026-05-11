#!/usr/bin/env bash
#
# Xcode Cloud post-clone hook.
#
# Xcode Cloud runners ship with Xcode but no Rust toolchain, and the
# AutorotaFFI.xcframework is gitignored (built from the Rust workspace by
# `scripts/build_xcframework.sh`). This script installs Rust, adds the four
# Apple targets we ship, then builds the XCFramework so that the subsequent
# `xcodebuild -resolvePackageDependencies` step can locate the binary target.
#
# Working directory on entry is this `ci_scripts` directory. The cloned repo
# lives at `$CI_WORKSPACE` (typically /Volumes/workspace/repository).

set -euo pipefail

REPO_ROOT="${CI_WORKSPACE:-$(cd "$(dirname "$0")/../../../../.." && pwd)}"

echo "==> ci_post_clone.sh starting"
echo "    REPO_ROOT=$REPO_ROOT"
echo "    PWD=$(pwd)"

# ── 1. Install rustup via Homebrew ──────────────────────────────────────────
# Xcode Cloud's post-clone phase has flaky DNS for static.rust-lang.org, so the
# canonical `curl https://sh.rustup.rs | sh` bootstrapper fails (build #5 hit
# four "Could not resolve host" errors and aborted). Homebrew is preinstalled
# on Cloud runners and pulls bottles from GitHub-hosted CDNs that resolve
# reliably — use it to drop the rustup binary, then bootstrap the toolchain.
if ! brew list --formula rustup >/dev/null 2>&1; then
  echo "==> Installing rustup via Homebrew"
  brew install rustup
fi

# The `rustup` formula is keg-only (it conflicts with the `rust` formula's
# cargo/rustc), so its bin dir is NOT symlinked into /usr/local/bin. Add it
# to PATH explicitly, otherwise `rustup-init` would not be findable.
RUSTUP_KEG_BIN="$(brew --prefix rustup)/bin"
export PATH="$RUSTUP_KEG_BIN:$PATH"

# Pin the rustup/cargo home dirs to the standard locations under $HOME so the
# generated shims land where everything downstream expects them.
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"

# Bootstrap stable toolchain on first run. Build #7 showed that
# `rustup show active-toolchain` can succeed (warm-runner state) while the
# cargo/rustc shims at $CARGO_HOME/bin are still missing — check the shim
# directly so we always end up with a working `cargo` on PATH.
if [[ ! -x "$CARGO_HOME/bin/cargo" ]]; then
  echo "==> Bootstrapping stable toolchain"
  rustup-init -y --default-toolchain stable --profile minimal --no-modify-path
fi

# Put cargo/rustc/rustup shims on PATH for everything downstream (including
# scripts/build_xcframework.sh, which invokes `cargo` directly).
export PATH="$CARGO_HOME/bin:$PATH"

# Fail fast if the shims still aren't where we expect — much clearer than
# letting build_xcframework.sh die with "cargo: command not found" later.
for tool in rustup rustc cargo; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: '$tool' not on PATH after rustup bootstrap" >&2
    echo "       PATH=$PATH" >&2
    echo "       CARGO_HOME=$CARGO_HOME" >&2
    echo "       RUSTUP_HOME=$RUSTUP_HOME" >&2
    exit 1
  fi
done

echo "==> Rust version: $(rustc --version)"
echo "==> Cargo:        $(command -v cargo)"

# ── 2. Add Apple targets required by build_xcframework.sh ───────────────────
rustup target add \
  aarch64-apple-ios \
  aarch64-apple-ios-sim \
  aarch64-apple-darwin \
  x86_64-apple-darwin

# ── 3. Build the XCFramework ────────────────────────────────────────────────
cd "$REPO_ROOT"
bash scripts/build_xcframework.sh

echo "==> ci_post_clone.sh done — XCFramework ready"
ls -la platforms/apple/AutorotaKit/XCFrameworks/AutorotaFFI.xcframework
