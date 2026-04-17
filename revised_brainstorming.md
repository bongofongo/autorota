---
title: "Brainstorming Key Problems of the App (Revised)"
---

# Theme 1: Immutable History + Flexible Editing

**Core tension:** Users need to edit/delete any shift (past, present, future) freely, but also need audit trail and restore capability.

## Solution: Changelog + Commits (no edit restrictions)

- Remove past/present/future distinction for editability — all shifts equally editable
- Keep minimally detailed changelog so every past state is restorable
- Commits don't need to tag shifts as past/present/future — that's calculable from dates

### Changelog Design

- **Scope:** Per-week as default view, plus total changelog view sorted by commit date
- **Storage format:** Diffs, not full snapshots
  - Restoration = assemble diffs from base commit forward
  - Custom diff language (not JSON/code diffs) — only two operations:
    1. Shift addition/deletion
    2. Employee assignment to shift
  - Availability is highly compressible (lots of adjacent repetition) — relevant for both diffs and data transfer
- **Compression:** Good defaults should handle performance. Monitor and compress when needed.

### Changelog UI

- Grid view of diff history — landscape, fill-screen, non-scrolling static view
- Same grid layout doubles as a "weekly rota overview" feature (reusable component)
- Shifts clickable to see their specific change history

**Ties into:** This changelog system is what the existing commit model already partially supports. The diff computation already happens in Rust. Main gap: the per-week changelog view and the grid visualization.

---

# Theme 2: Availability System

**Core tension:** Current availability is next-week-only. Managers need variable-range scheduling (1 week, 2 weeks, 1 month).

## Decisions

- **Minimum unit:** 1 week (not 1 day)
- **Past availability storage:** Not needed. Current system of "building" past shifts manually (without smart generation) works fine, especially with better templates.
- **Existing foundation:** Per-employee "default" availability template already exists — just rename/reframe as template
- **Future availability:** Works hand-in-hand with overrides system

## Implications for Generation

- Generation algorithm depends on availability mappings, so generation scope follows availability scope
- Variable-range availability means generation can cover more than just next week
- Overrides (date-specific) layer on top of the weekly template

**Ties into:** Templates (Theme 3) reduce the need for complex availability — good templates + simple availability = same outcome as complex availability alone. Also ties into the override polish work (Theme 5).

---

# Theme 3: Templates Beyond Shifts

**Current state:** Only shift templates exist.
**Desired state:** Three template levels:

1. **Shift templates** (existing) — single time slot definitions
2. **Daily templates** — a day's worth of shifts with employee assignments
3. **Weekly templates** — full week of shifts with employee assignments

## UX Vision

Rota building should feel like **constructing** — malleable, tool-rich, sandbox-like.

- Daily templates: drag or tap to add to a day
- Weekly templates: apply as starting point, then customize
- Templates can be "pinned" during generation (algorithm respects them as fixed)

## Open Questions

- **iPhone portrait mode:** How to achieve sandbox feel on small screen? Should iPhone focus on very smart defaults instead of manual building tools?
- **Scope:** Are daily/weekly templates needed for this iteration, or is this a future feature?

## Generation Algorithm Impact

- Pinned templates = manual overrides in the two-pass greedy algorithm
- First pass already handles manual overrides; templates slot into this naturally
- Complexity increase is manageable if templates are treated as pre-applied assignments

**Ties into:** Better templates reduce pressure on the availability system (Theme 2). Smart defaults address the iPhone UX concern. The "pinning" mechanism connects to the existing override/manual assignment flow.

---

# Theme 4: History Page vs. Logging Page

**Question:** Is a dedicated history page needed, or should it be a logging/activity page?

- **History** (what changed over time) → belongs in the rota view itself, via the changelog grid (Theme 1)
- **Logging** (activity feed, audit trail) → separate page showing commits, actions, timestamps

**Conclusion direction:** Rota view owns visual history (diffs, grid). Separate page is a log/audit feed, not a duplicate history view.

**Ties into:** Changelog grid UI (Theme 1) handles the "history" use case, so the dedicated page can focus purely on logging/audit.

---

# Theme 5: Polish + UX Fixes

- **Employee list page:** Unify title cards and formatting across pages
- **Overrides (date ranges):** Currently unintuitive and tedious — needs UX rework
- **Current day/shift highlighting:** Visual indicator for active shifts in rota view
- **Day-level shift reassembly:** Feature to combine single-day shifts and "rest of week" shifts in rota view

---

# Theme 6: Future Features (Beyond Current Iteration)

### Communication
- Assign employees to Apple/WhatsApp contacts for bulk messaging
- Smart availability submission: employees send compact data format the app can parse
  - Availability data is very compressible (adjacent repetition) — could be lightweight transfer

### Data Portability
- Export/import full database for device transfer
- Multi-business/shop switching

### Cross-Cutting Observation
The availability compression insight appears twice: in changelog diffs (Theme 1) and in data transfer (Theme 6). A shared compact availability encoding could serve both purposes.

---

# Dependency Map

```
Templates (3) ──reduces pressure on──> Availability (2)
                                            │
Availability (2) ──feeds──> Generation Algorithm
                                            │
Templates (3) ──pins into──> Generation Algorithm (first pass)
                                            │
Changelog (1) ──records output of──> Generation / Editing
                                            │
Changelog Grid (1) ──replaces need for──> History Page (4)
                                            │
Overrides (5) ──layers on──> Availability (2)
                                            │
Compact encoding ──shared by──> Changelog diffs (1) + Data transfer (6)
```
