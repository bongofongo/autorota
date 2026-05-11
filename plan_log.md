# Plan Log

## 2026-04-30 (revised — risk-first reorder)

Replaces earlier 2026-04-30 entry below. Reorder driven by: v1 = iOS/iPadOS only, core rota UX never user-tested (top risk), 1-2 real cafe managers lined up for testing, cloud is later major release but worth unblocking now.

**Guiding principle: local-first, cloud-as-superset.**
Local app must stand on its own as a polished one-time-purchase product. Cloud = strict superset, additive only. Phase 3 should leave local code paths essentially untouched. This means the local data model + export shape must *already* match the future push payload shape — decided in Phase 0, validated in Phase 1, locked by ship.

**Phase 0 — Validate (week 1, before any polish)**
1. User-test rota-gen flow with 1-2 cafe managers on current build. Cold test, no pre-polish. Goal: surface real UX gaps.
2. Sketch push-schema + employee-app read contract on paper. **This is a constraint check on the local data model**, not just cloud-prep: if local can't produce the right shape today, fix it before polish locks the wrong shape in. Buy domain + stub landing page (~1-2 days).
3. Audit local data model + export against the sketched push shape. Identify any mismatches that would force a local rewrite when cloud lands. Schedule those fixes into Phase 1.

**Phase 1 — Fix what testing revealed + lock superset shape**
4. Refine rota-gen UX based on test feedback.
5. Draft orientation guide alongside fixes — writing it forces happy-path walkthrough and exposes UX gaps. Guide as detection tool, not just docs.
6. Rethink export with explicit goal: **export shape ≈ future cloud push payload shape**. Same serialization both directions. File-export today, URL-served tomorrow, no schema rework between. Implement minimum coherent version.
7. Apply any data-model fixes from Phase 0 audit so local already speaks superset shape.

**Phase 2 — Polish & ship**
8. iOS/iPadOS polish + bug hunt (only after core UX validated and superset shape locked).
9. Finalize orientation guide with screenshots from polished build.
10. Ship local v1 to App Store as one-time-purchase product. Standalone, complete, no cloud dependency.

**Phase 3 — Cloud (post-ship, additive only)**
11. Build cloud lean-push: serve the same export payload at a URL. Local emits, cloud relays. Local code paths untouched ideally; if a local change is needed, it should be a small flag/toggle, not a rewrite.
12. Build employee app: reads pushed URL data using the locked-in payload shape from Phase 1. Calendar-based availability generation. Worker QoL features.
13. Cloud release as upgrade/expansion, not replacement.

**Cut from critical path**
- macOS polish — stays compile-passing only. No design budget pre-ship.

Target: ~1 month aspirational, not firm. Revisit after Phase 0 — test findings may force re-prioritization.

**Key UI Focuses**
- Enabling Gestures for Everything / Press + hold
- Customizability
- Orientation
- Needs _FLOW_

---

## 2026-04-30 (original — superseded)

1. Polish iOS UI: hunt bugs, make it feel good
2. Polish macOS UI: usable + decent feel, no deep time sink
3. Rework export flow (local-only plan)
4. Refine rota generation UX end-to-end for intuitiveness
5. Build comprehensive orientation guide — user feels fluent in <5 min (local users)
6. Ship to App Store, local-only mode
7. Start cloud "lean push" arch: one-way URL push of schedules; employees read via URL
    - Web infra, buy domain, design landing page
8. Build employee app: calendar-based availability generation; primary path = read pushed URL data, present nicely; bundle worker QoL features
9. Target timeframe: ~1 month
