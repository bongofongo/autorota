# Autorota TODO

## 1. Language support (DONE)
Add localizations for key markets:
- Mandarin (zh-Hans, zh-Hant)
- Arabic (ar) — RTL layout audit needed
- Bengali (bn) + related (Assamese, Sylheti?)
- Audit `String(localized:)` coverage, extract hardcoded strings
- Test RTL mirroring on iOS/iPadOS/macOS

## 2. Onboarding + help polish (DONE)
- Sharpen onboarding wizard flow (clearer steps, sample data option, skip path)
    - use tooltips and a guided employee creation + availability filling
- Expand Help/Guidance page:
  - Roles + shift setup walkthrough
  - Availability vs override explainer
  - Save/restore + Edit Log usage
  - Export profiles (staff vs manager) examples
  - Tips for two-pass scheduler behavior
  - More examples for everything in an example section for help

## 3. CI/CD sharpening (DONE)
- Tighten release pipeline (Rust + XCFramework + Apple builds)
- Auto version bump + changelog
- Signed/notarized macOS build artifact
- TestFlight upload automation for iOS/iPadOS
- Pre-merge checks: `cargo fmt && clippy && test`, swift-build-check-all
- One-command release path

## 4. Tier signup / licensing page (DONE)
Onboarding page where user picks app tier. MVP = Local Manager only.
- **Local Manager** (now) — paid one-time, price TBD. No network.
- **Employee** (future) — companion app for staff, syncs with manager.
- **SaaS** (future) — subscription, web-backed, multi-device, extra features.
Build flow now with stub for future tiers (gated/disabled).
- The stub for these other "entry points" can be built, but I'd like the onboarding page to allow for "beta testing" that will 
allow users to use the app provided they have a key that I'll distribute. This will be for the local manager part of the app
which is everything at the moment, but provided a good key system for beta testing, this will be used in the future for major updates
and such. 
- For now, build the onboarding page with one entry point (local manager), and allow entry through either the key system you'll set up 
or an in-app purchase subject to change. Set it to $5, 5gbp at the moment. Also write a temporary description that will be right underneath the
button for the entry point. This should just be one page.

## 5. Performance + memory measurement
Build infra to track app perf and memory across releases.
- Rust core benchmarks: `criterion` for scheduler two-pass, save/restore, export paths
- Track DB query timings (migrations, rota load, edit log) — log slow queries
- Swift side: `XCTest` measure blocks for cold launch, week navigation, edit-mode enter/exit, large-rota render
- Instruments templates checked in: Time Profiler, Allocations, Leaks scheme presets
- Memory ceilings per platform (iOS/iPadOS/macOS); fail CI if regression > threshold
- FFI boundary cost: measure UniFFI call overhead for hot paths
- Baseline corpus: synthetic 50/200/500 employee rotas for repeatable runs
- CI job: nightly perf run, post results to artifact + trend graph
- Doc page: how to run benches locally + interpret results

## 6. Branding + App Store assets
- Design logo (icon + wordmark)
- App Store screenshots (iPhone, iPad, Mac)
- Marketing copy + feature highlights
- App Store preview video (optional)
- Localized store listings matching #1
