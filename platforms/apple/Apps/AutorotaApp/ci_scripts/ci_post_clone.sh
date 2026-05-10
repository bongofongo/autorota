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

# ── 1. Install Rust (rustup, non-interactive, minimal profile) ──────────────
if ! command -v rustup >/dev/null 2>&1; then
  echo "==> Installing rustup"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path
fi

# shellcheck disable=SC1091
source "$HOME/.cargo/env"

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
