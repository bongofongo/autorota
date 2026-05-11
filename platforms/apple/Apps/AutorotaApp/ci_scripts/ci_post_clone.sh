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
# reliably — use it to drop the rustup binaries, then bootstrap the toolchain.
if ! command -v rustup >/dev/null 2>&1; then
  echo "==> Installing rustup via Homebrew"
  brew install rustup
fi

# Bootstrap a stable toolchain on first run (idempotent — no-op if already set).
if ! rustup show active-toolchain >/dev/null 2>&1; then
  echo "==> Bootstrapping stable toolchain"
  rustup-init -y --default-toolchain stable --profile minimal --no-modify-path
fi

# rustup-init writes ~/.cargo/env; brew rustup also drops shims in ~/.cargo/bin.
# shellcheck disable=SC1091
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
export PATH="$HOME/.cargo/bin:$PATH"

echo "==> Rust version: $(rustc --version)"

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
