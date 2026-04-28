# Performance & app size

Snapshot taken 2026-04-25 against the post-localization-infra build.

## TL;DR

Autorota ships at roughly **8–11 MB** for an end user (App Store slice), placing it in the lightweight tier — well below typical SaaS scheduling competitors that ship at 80–200 MB. The Rust + UniFFI core sets a ~7 MB floor; the Swift UI itself is tiny.

## Measured artifacts

Built locally on macOS (Apple Silicon), Xcode 26, debug + release.

| Artifact | Size | Notes |
|---|---|---|
| `target/release/libautorota_ffi.dylib` (unstripped) | 9.1 MB | Release optimized, no LTO |
| `target/release/libautorota_ffi.dylib` (stripped) | 7.9 MB | Realistic linked size |
| `target/release/libautorota_ffi.a` | 43 MB | Static archive — only relevant portions get pulled in by linker |
| `AutorotaApp.app` (macOS Debug) | 101 MB | Debug symbols + `-enable-testing` bundles XCTest |
| `AutorotaApp.app` (iOS Sim Debug) | 69 MB | Same caveats |
| `AutorotaFFI.xcframework` (Debug, all archs + dSYMs) | 902 MB | Distribution artifact, not user-facing |

The debug `.app` is dominated by:
- `AutorotaApp.debug.dylib`: 69 MB — debug DWARF + profile instrumentation
- `Frameworks/`: 29 MB — XCTest, XCUIAutomation, Testing.framework auto-bundled by Xcode for `-enable-testing` debug builds
- App executable itself: 39 KB

None of that ships in release.

## Estimated release IPA

| Component | Size |
|---|---|
| Rust FFI dylib (stripped) | ~7.9 MB |
| Swift app code + `AutorotaKit` Swift bindings | ~300–500 KB |
| Compiled xcstrings catalog (5 locales) | ~50–75 KB before slicing |
| Asset catalog | <50 KB (no images yet) |
| **IPA before App Store slicing** | **~9–12 MB** |
| **End-user download after slicing** | **~8–11 MB** |

App Store slicing strips locales and architectures the user doesn't need. With 5 declared locales (`en`, `zh-Hans`, `zh-Hant`, `ar`, `bn`), a single-language user pays ~10–15 KB for their localization, not the full ~50 KB.

## Where the 7.9 MB Rust binary goes

| Crate / area | Approx contribution |
|---|---|
| `sqlx` + bundled SQLite | ~3 MB |
| `printpdf` + `rust_xlsxwriter` (export pipeline) | ~2 MB |
| `tokio` runtime + Rust std | ~1.5 MB |
| `chrono`, `serde_json`, `csv`, `calamine` | ~700 KB |
| `fluent` + `intl_pluralrules` + ICU plural data + `unic-langid` | ~600 KB |
| App logic (scheduler, models, FFI glue) | ~100 KB |

## Peer comparison

iOS App Store sizes (approximate, late-2025 era):

| Tier | Range | Examples |
|---|---|---|
| Lightweight | <10 MB | Native iOS calculator/notepad utilities, simple indie tools |
| Lower-mid | 10–30 MB | Things 3 (~25 MB), Bear, lots of indie productivity |
| Mid | 30–80 MB | Todoist (~40 MB), Notion (~80 MB), most paid SaaS |
| Upper-mid | 80–200 MB | Slack (~180 MB), Spotify (~150 MB), banking apps |
| Heavyweight | 200+ MB | Instagram, TikTok, Facebook, Office, most games |

Direct competitors in shift scheduling (Deputy, 7shifts, When I Work, Homebase, Sling) ship at **80–200 MB**. Most of that weight is bundled SDKs: Firebase, Crashlytics, Segment, Intercom, Pendo, OAuth providers, push frameworks, and sometimes a JS/RN runtime. Autorota carries none of these because it is local-first.

The closest architectural peer — Bitwarden iOS, which uses Rust via UniFFI behind a native UI — ships at **~80 MB**, mostly UI assets and OAuth providers.

## Classification

**Lightweight, edging into lower-middleweight.**

At **~8–11 MB end-user download**, Autorota sits in the bottom ~15% of paid productivity apps on the App Store, comparable to small native indie tools (Mela, NotePlan), and far below typical SaaS scheduling competitors. The Rust + UniFFI choice puts a ~7 MB floor on the binary; in exchange, the app ships its scheduling, persistence, and export engines locally with no backend dependency.

A pure-SwiftUI rewrite would land at ~2–4 MB but would have to either drop the local scheduling engine or reimplement it in Swift.

## Localization overhead per language

Two cost layers, scaling differently.

### Swift xcstrings catalog (UI strings)

| Metric | Per locale | At ~350 keys |
|---|---|---|
| Compiled bundle bytes | UTF-8 text × keys | 5–15 KB |
| Resident memory (loaded) | only active locale | 5–15 KB |
| Launch cost | lazy `CFBundle` load | µs |

App Store slicing eliminates per-locale cost for unused languages on store / TestFlight builds. Direct distribution (DMG, ad-hoc IPA) ships all locales — adding all 5 = ~50–75 KB total bundle bloat.

### Rust `fluent-rs` (error messages)

Two parts:

**FTL text — embedded via `include_str!`, scales linearly:**

| Locales | Embedded FTL text |
|---|---|
| 1 (en only) | ~0.5 KB |
| 5 (current, with stubs) | ~1.2 KB |
| 5 fully populated at 11 keys | ~3 KB |
| 10 fully populated | ~6 KB |

**`fluent` crate code — fixed cost regardless of locale count:** ~500–700 KB statically linked, ~150–300 KB resident heap once `localize_error` first warms the bundles.

| Locales | Binary | FTL text | Heap (warm) |
|---|---|---|---|
| 1 | 600 KB | 0.5 KB | ~50 KB |
| 5 (current) | 600 KB | 1.2 KB stubs / 3 KB full | 150–300 KB |
| 10 | 600 KB | ~6 KB | 300–600 KB |

### Total per-locale overhead

For App Store users (sliced):
- ~10–15 KB UI bundle + ~30–60 KB Fluent heap when an error first triggers.

For non-store distribution:
- ~10–15 KB UI bundle + ~30–60 KB Fluent heap.

Going from **2 → 5 locales** added: ~30–45 KB UI bundle, ~3 KB FTL text in binary, ~120–240 KB Fluent heap warm. The fluent crate itself was the one-time ~600 KB cost; scaling locales after that is cheap.

## Possible trims

| Action | Saving | Trade-off |
|---|---|---|
| Set `lto = true`, `panic = "abort"`, `strip = true` in `[profile.release]` | 15–25% on Rust dylib (~1.5–2 MB) | Slightly slower release builds; backtraces lose some detail |
| Replace `printpdf` + `rust_xlsxwriter` with thinner export libs | ~1.5 MB | Lose features or rewrite export paths |
| Drop `fluent` for a `HashMap<&str, &str>` lookup of error keys | ~600 KB | Lose CLDR plural / gender rules (matters for Arabic, Russian) |
| Lazy per-locale `FluentBundle` init | 100–200 KB heap when staying in `en` | None really; ~30-line change |
| Link system SQLite dynamically on macOS instead of bundling | ~1 MB on macOS slice | macOS-only, ties to system sqlite version |

The first one is free. The rest only make sense if app size becomes a real constraint.

## Runtime perf testing

Binary size (this doc) and runtime perf are tracked separately. For criterion benches, XCUITest measure blocks, and CI integration, see [`perf-testing.md`](perf-testing.md).

## How to re-measure

```bash
# Rust release size:
cargo build --release -p autorota-ffi
strip -x target/release/libautorota_ffi.dylib -o /tmp/stripped.dylib
ls -lh /tmp/stripped.dylib

# Realistic IPA size requires an Archive build via Xcode (not just debug):
# Product → Archive → distribute as Development → inspect .ipa contents
```

Debug `.app` measurements are not representative — always strip and use release for size analysis.
