#!/usr/bin/env bash
# build_xcframework.sh
#
# Builds the autorota-ffi Rust library for all Apple targets, generates Swift
# UniFFI bindings, and assembles an XCFramework ready for use in the Swift
# Package.
#
# Prerequisites:
#   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin x86_64-apple-darwin
#
# Usage (run from the workspace root):
#   bash scripts/build_xcframework.sh
#   bash scripts/build_xcframework.sh --debug     # faster, for development

set -euo pipefail

PROFILE="release"
CARGO_FLAGS="--release"
if [[ "${1:-}" == "--debug" ]]; then
  PROFILE="debug"
  CARGO_FLAGS=""
fi

WORKSPACE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE="autorota-ffi"
LIB_NAME="libautorota_ffi.a"
DYLIB_NAME="libautorota_ffi.dylib"

OUT_DIR="$WORKSPACE_ROOT/platforms/apple/AutorotaKit"
BINDINGS_DIR="$OUT_DIR/Sources/AutorotaKit/generated"
XCFRAMEWORK_DIR="$OUT_DIR/XCFrameworks/AutorotaFFI.xcframework"
TMP_DIR="$(mktemp -d)"

echo "==> Building autorota-ffi for all Apple targets (profile: $PROFILE)"

cd "$WORKSPACE_ROOT"

# Resolve SDK paths up front — fails fast if xcode-select is wrong
SDK_MACOS="$(xcrun --sdk macosx --show-sdk-path)"
SDK_IOS="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_IOS_SIM="$(xcrun --sdk iphonesimulator --show-sdk-path)"

# ── Step 1: Compile static libraries ────────────────────────────────────────
# SDKROOT must be set per-target so libsqlite3-sys (and cc-rs) find the right SDK.

SDKROOT="$SDK_MACOS" cargo build -p "$CRATE" $CARGO_FLAGS --target aarch64-apple-darwin
SDKROOT="$SDK_MACOS" cargo build -p "$CRATE" $CARGO_FLAGS --target x86_64-apple-darwin
SDKROOT="$SDK_IOS"     cargo build -p "$CRATE" $CARGO_FLAGS --target aarch64-apple-ios
SDKROOT="$SDK_IOS_SIM" cargo build -p "$CRATE" $CARGO_FLAGS --target aarch64-apple-ios-sim

# ── Step 2: Fat library for macOS (arm64 + x86_64 for Rosetta) ──────────────

echo "==> Lipoing macOS slices"
lipo -create \
  "target/aarch64-apple-darwin/$PROFILE/$LIB_NAME" \
  "target/x86_64-apple-darwin/$PROFILE/$LIB_NAME" \
  -output "$TMP_DIR/libautorota_ffi_macos.a"

# Copy single-arch iOS device and simulator libs
cp "target/aarch64-apple-ios/$PROFILE/$LIB_NAME"     "$TMP_DIR/libautorota_ffi_ios.a"
cp "target/aarch64-apple-ios-sim/$PROFILE/$LIB_NAME" "$TMP_DIR/libautorota_ffi_ios_sim.a"

# ── Step 3: Generate Swift bindings ─────────────────────────────────────────
# Requires a .dylib (cdylib) built for the local macOS architecture so that
# uniffi-bindgen can introspect it at runtime.

# dylib was already built above; this is a no-op but kept for clarity

echo "==> Generating Swift bindings"
mkdir -p "$BINDINGS_DIR"
cargo run -p uniffi-bindgen $CARGO_FLAGS -- generate \
  --library "target/aarch64-apple-darwin/$PROFILE/$DYLIB_NAME" \
  --language swift \
  --out-dir "$BINDINGS_DIR"

# ── Step 4: Prepare header directory for XCFramework ────────────────────────
# XCFramework expects a headers directory alongside each .a

HEADERS_DIR="$TMP_DIR/Headers"
mkdir -p "$HEADERS_DIR"
cp "$BINDINGS_DIR"/*.h "$HEADERS_DIR/" 2>/dev/null || true
# Rename to module.modulemap — the standard name Clang uses for automatic
# module discovery. Without this the generated autorota_ffi.swift cannot
# import autorota_ffiFFI and all C types (RustBuffer, ForeignBytes, etc.)
# are invisible to Swift.
cp "$BINDINGS_DIR/autorota_ffiFFI.modulemap" "$HEADERS_DIR/module.modulemap"

# ── Step 5: Assemble XCFramework ─────────────────────────────────────────────

echo "==> Assembling XCFramework"
rm -rf "$XCFRAMEWORK_DIR"
xcodebuild -create-xcframework \
  -library "$TMP_DIR/libautorota_ffi_macos.a" \
    -headers "$HEADERS_DIR" \
  -library "$TMP_DIR/libautorota_ffi_ios.a" \
    -headers "$HEADERS_DIR" \
  -library "$TMP_DIR/libautorota_ffi_ios_sim.a" \
    -headers "$HEADERS_DIR" \
  -output "$XCFRAMEWORK_DIR"

rm -rf "$TMP_DIR"

echo ""
echo "Done! XCFramework at:"
echo "  $XCFRAMEWORK_DIR"
echo ""
echo "Swift bindings at:"
echo "  $BINDINGS_DIR"
echo ""
echo "Next: open platforms/apple/Apps/AutorotaApp in Xcode and build."
