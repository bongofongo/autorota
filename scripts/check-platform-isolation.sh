#!/usr/bin/env bash
# Enforces the Views/ layer convention:
#   - Views/Shared/**         no #if os(...) directives
#   - Views/Platform/iOS/**   whole-file #if os(iOS) gate, no other #if os
#   - Views/Platform/macOS/** whole-file #if os(macOS) gate, no other #if os
# Files directly in Views/ (not yet sorted into Shared/Platform) are ignored
# during the migration. Once migration completes they should be either moved
# into a subfolder or this script tightened to flag stragglers.
set -euo pipefail

ROOT="platforms/apple/Apps/AutorotaApp/Views"
fail=0

if [ ! -d "$ROOT" ]; then
    echo "Views root not found: $ROOT" >&2
    exit 2
fi

# 1. Shared must be platform-clean
if [ -d "$ROOT/Shared" ]; then
    while IFS= read -r f; do
        if grep -q '#if os(' "$f"; then
            echo "FAIL [Shared]: $f contains #if os(...) — Shared must be platform-agnostic"
            fail=1
        fi
    done < <(find "$ROOT/Shared" -name '*.swift' -type f)
fi

# 2. Platform/iOS files: must whole-file gate with #if os(iOS) and contain only that gate
if [ -d "$ROOT/Platform/iOS" ]; then
    while IFS= read -r f; do
        if ! grep -q '^#if os(iOS)$' "$f"; then
            echo "FAIL [Platform/iOS]: $f missing top-level '#if os(iOS)' gate"
            fail=1
            continue
        fi
        count=$(grep -c '^#if os(' "$f" || true)
        if [ "$count" != "1" ]; then
            echo "FAIL [Platform/iOS]: $f has $count '#if os(...)' directives (expected 1)"
            fail=1
        fi
    done < <(find "$ROOT/Platform/iOS" -name '*.swift' -type f)
fi

# 3. Platform/macOS mirror check
if [ -d "$ROOT/Platform/macOS" ]; then
    while IFS= read -r f; do
        if ! grep -q '^#if os(macOS)$' "$f"; then
            echo "FAIL [Platform/macOS]: $f missing top-level '#if os(macOS)' gate"
            fail=1
            continue
        fi
        count=$(grep -c '^#if os(' "$f" || true)
        if [ "$count" != "1" ]; then
            echo "FAIL [Platform/macOS]: $f has $count '#if os(...)' directives (expected 1)"
            fail=1
        fi
    done < <(find "$ROOT/Platform/macOS" -name '*.swift' -type f)
fi

if [ "$fail" -ne 0 ]; then
    echo
    echo "Platform isolation check failed."
    exit 1
fi

echo "Platform isolation OK"
