# User Test Notes

Reconciled feedback from user testing session. Organized by feature area with severity tags:

- 🐛 **Bug** — broken behavior
- 🎯 **UX** — friction or confusion, not broken
- ✨ **Feature** — new capability requested
- 💡 **Idea** — speculative, needs design pass
- ✅ **Liked** — positive feedback worth preserving

---

## Onboarding / Adverts

### 🎯 Advert orientation — swipe gesture missing
Swipe navigation should be enabled on the onboarding advert/intro screens **in addition to** the existing "Next" button. Users instinctively try to swipe between intro slides; relying on the button alone feels dated.

- **Action:** add horizontal swipe gesture recognizer alongside Next button. Both should advance/reverse the same state.

### ✅ Free trial option
User likes the free trial flow as currently presented. Keep it.

### ✨ "Limited trial" tier — further restrict write features
User suggests an additional trial variant — a **"Limited trial"** — that further constrains the **write** features (creating/editing employees, shifts, rotas, exports, etc.) compared to the existing free trial. Read/preview features stay accessible.

- **Action:** scope which mutations count as "write" and gate them behind the trial tier. Likely a feature-flag matrix: Free Trial → most writes allowed; Limited Trial → only minimal writes (e.g. can preview generation but not save / export).
- Decide whether this is a separate SKU, a conversion-funnel step, or a downgrade after the free trial expires.

---

## Employee Creation & Editing

### ✨ Auto-advance on first/last name entry
When inputting an employee's name, hitting **Return** on the first-name field should auto-focus the last-name field (and similarly across related grouped fields). Goal: reduce friction when entering a batch of employees.

- **Action:** wire `.onSubmit` / focus management between `first_name` → `last_name` → `nickname` → next logical field.
- Apply same pattern anywhere related fields appear in sequence.

### 🐛 Save button — missing validation alert
The employee-creation **Save** button does not surface an alert when required fields are missing. User expects a clear "Missing X, Y" message rather than a silent no-op or a vague failure.

- **Action:** validate on Save tap. If invalid, present an alert listing missing/invalid fields.

### 🐛 Availability save bug on employee-creation page
There appears to be a bug when saving availability **at the same time** as creating a new employee on the same page. Saving availability on the dedicated **edit** page works fine.

- **Proposed fix:** disallow availability input on the *create* page entirely. Availability becomes editable only after the employee exists (i.e. on the edit screen).
- This also simplifies the create flow.

### 🎯 Employee input/export clarity
Overall, employee input and export flows need to be clearer. Specific pain points TBD — flag for a dedicated UX pass.

---

## Availability

### 🎯 Default vs. actual availability — labelling confusion
The distinction between the *default weekly template* and *actual / date-specific availability* is not obvious on first use. Users don't immediately grasp which they are editing.

- **Action:** clearer copy on each screen header. Consider tooltips or a one-time inline explainer.

### ✅ Group selection feature — liked
User likes the **group selection** feature for availability input as a concept.

### 🎯 Group selection — not intuitive (takes over input)
Activating group-select mode currently **takes over all input**, which surprised the user. They tried to **drag/slide** to multi-select hours rather than discovering the lasso tool.

- **Action:** support drag-to-multi-select as a primary gesture. Lasso can remain as a secondary/advanced mode.
- Make the mode change more discoverable and reversible (clear "exit group select" affordance).

### 🎯 Availability colors — confusing on first use
Colors used for `Yes` / `Maybe` / `No` are not self-evident. **Yellow specifically caused confusion** (presumed `Maybe` but unclear).

- **Action:** add a persistent legend on the availability screen, or label the cells until the user dismisses an inline tutorial.
- Reconsider the yellow shade or pair it with a glyph (e.g. `?`) for clarity.

### ✅ "Weekly availability" carousel — liked
User likes the weekly-availability carousel as a feature. However, the **button title is unclear** about what the carousel actually does/shows.

- **Action:** rename button to describe the action (e.g. "Browse weekly availability" or "View weekly template").

---

## Shifts

### 🎯 Shifts tab — overall clarity
The Shifts tab needs to be clearer on how to use it. User finds shifts "slightly confusing" right now. Treat as a holistic redesign signal, not a single fix.

### 🎯 Default shift times — both Rota tab manual creation & Shifts tab
Default start/end times when creating a shift are poor. This applies in **both** entry points:
1. Manual shift creation on the **Rota** tab.
2. Shift creation on the **Shifts** tab.

- **Action:** pick sensible defaults (e.g. 09:00–17:00, or last-used times for that weekday). Consider remembering the most recent shift's times.

### 🎯 "New shift" button — needs an icon
The **"New shift"** button on the Shifts tab lacks an icon, while the adjacent **"New role"** button has one. Visual asymmetry makes the Shift button look secondary/less inviting.

- **Action:** add an icon to "New shift" matching the visual weight of "New role".

### ✨ "Everyday" toggle on shift creation
Common case: creating a shift that recurs every weekday. Add an **"Everyday" toggle** that selects all weekdays at once.

- **Action:** add toggle above (or alongside) the per-weekday checkboxes. Toggling on selects all 7; toggling off clears them.

### 💡 Replace top-right options button with explicit add buttons
Instead of a generic options button in the top-right of the Shifts tab, surface **explicit "Add shift" / "Add role"** affordances inside their respective sections. Reduces hidden discovery and maps directly to user intent.

### 💡 Labour-cost-based smart shift selection
Idea: when configuring lenient employee allowances on a shift (e.g. min/max headcount range), provide a **smart suggestion** based on projected labour cost. Show estimated cost at min vs. max, suggest a sweet spot.

- Speculative — needs design + cost-model thinking. Park for later.

### 🐛 Shift edit — required role input is buggy
Editing an existing shift makes it "very difficult" to switch the **required role**. Input feels buggy.

- **Action:** reproduce, identify whether it's a Picker bug, state-binding issue, or list-refresh issue. Fix.

### 💡 Sub-shift / sub-role concept
User suggests a **sub-shift** section: within one shift, designate 1 role to 1 specific employee, with other roles (or no role) assigned to 1+ other employees. Useful for split-coverage scenarios (e.g. one barista lead + N floaters).

- Significant data-model implication. Park for design discussion.

---

## Roles

### 🎯 Role usability — needs to be clearer
General feedback: how Roles work and how they interact with Shifts/Employees needs to be more obvious. Likely overlaps with the Shifts-tab clarity work above.

---

## Rota Generation & Editing

### 🎯 Rota generation error messages — opaque
When generation fails, the error message does not explain **why**. User cannot self-diagnose (e.g. "no eligible employees", "hour budget exceeded", "no availability").

- **Action:** surface specific failure reasons from the scheduler, mapped to user-readable messages. Include actionable next step where possible ("Add availability for X" / "Increase weekly hours for Y").

### 🎯 Rota editability — edit-mode discoverability
User assumes the rota is **directly editable** without first tapping the **Edit** button. The edit-mode gating is unexpected.

- **Action options:**
  - Make the edit button much more prominent / animated on first visit.
  - Or: drop edit mode and make the rota always-editable, with the existing auto-save snapshots covering undo.
  - Decide based on data-loss risk vs. friction tradeoff.

### 🎯 Friction regenerating a rota
Regenerating an existing rota feels frictionful (exact pain point not fully captured — likely confirmation dialogs, navigation, or edit-mode interaction).

- **Action:** trace the regenerate flow; identify and remove unnecessary steps.

### ✨ Empty-rota → "Generate forward" option
From an empty (deleted) rota, there is no option to **create a rota that fills current and future days** with employees and shifts in one action. User wants a single-click "fill from here forward" path.

- **Action:** add an "auto-generate current + upcoming weeks" entry point on the empty-state view.

### 🐛 Screen flicker when switching to a rota with an existing schedule
Visible flicker when navigating to a week that already has a saved/generated rota.

- **Action:** investigate. Likely a transient empty-state render before the loaded data resolves. Show a stable placeholder (or persist last view) until data is ready.

### 🐛 Screen flicker after using "Swap" while editing a rota
After invoking the **Swap** feature while editing a rota, the screen flickers briefly before re-rendering with the employees swapped. The end state is correct, but the transient flicker is jarring.

- **Action:** trace the swap mutation path. Likely a full re-fetch / re-render rather than a localized in-place update. Either animate the swap, or update the two affected cells without rebuilding the whole view.

---

## Exceptions / Overrides

### 🎯 "Exceptions" tab name — not intuitive
The word **"Exceptions"** as a tab/section label did not read as intuitive to the user. They didn't immediately know what would be inside.

- **Action:** consider renames that describe the content directly. Options: "Overrides", "Changes", "Schedule changes", "Day overrides", "One-off changes". Validate with another testing pass.

### 🎯 Exceptions date-range editable view — still rough
The date-range editing UI for exceptions/overrides still needs improvement (carry-over from prior feedback). Specifics not captured this session — flag for a dedicated pass.

---

## Export

### 🐛 Preview — "By employee" with shift name + times shows time twice
On the **rota export preview** for the **By Employee** layout, when both **shift name** and **times** are toggled on, the time appears **twice** in the rendered preview.

- **Action:** inspect the by-employee template. Likely the shift-name string already includes time (or the times row is rendering unconditionally regardless of the shift-name setting). De-duplicate the time output so it only renders once according to the user's toggle.

### 🎯 Export page — needs polish + UI flow rework
The Export page overall needs polish and a more intuitive **UI flow**. Two specific friction points called out:

1. **Exporting files** — the path from "I want to export" → file produced → file shared/saved is not obvious. Format selection, layout selection, profile selection, and the final share/save action need a clearer linear flow.
2. **Bulk send** — how to select multiple recipients/files and send them at once is unclear. The bulk path should be either (a) clearly distinct from the single-export path, or (b) a natural extension of it.

- **Action:** redesign as a stepper or wizard if the flow has >3 decisions. Group choices that always go together (layout + profile). Make the final share action visually unmistakable. Treat bulk send as a first-class entry point, not a hidden mode.

---

## Tab Bar / Navigation

### ✅ Tab-bar customizability — liked (with caveat)
User likes that the tab bar is configurable. Notes the customization is **limited** — fine for now, but a signal that further customization may be welcome later.

---

## Settings / Localization

### 🐛 System Appearance section doesn't localize
Switching the app language leaves the **System Appearance** section (and likely surrounding settings strings) rendered in English. Localized strings are not being picked up for that section.

- **Action:** audit the Appearance settings view for hardcoded strings / missing `LocalizedStringKey` / missing entries in `Localizable.xcstrings`. Verify the section header, option labels (Light / Dark / System), and any descriptive copy are wired through localization.

---

## Overall Sentiment

> "User likes the UI, thinks it's easy to use."

Headline themes for the next pass:
1. **Rota tab generation** is the biggest source of confusion.
2. **Shifts tab** needs a clarity overhaul.
3. **Employee input/export** flow needs sharpening.
4. **Roles** concept needs better surfacing.
5. **Export page** flow (file export + bulk send) needs a redesign pass.
6. Tab/section naming: **"Exceptions"** doesn't read clearly.
7. Smaller wins: swipe on adverts, return-to-next-field, everyday toggle, shift-button icon, validation alerts, color legend.

---

## Suggested Priority Buckets

### P0 — Bugs (fix first)
- Availability save bug when creating + setting availability on same page → restrict availability to edit page.
- Shift edit: switching required role is buggy.
- Screen flicker switching to a rota with an existing schedule.
- Screen flicker after Swap while editing a rota.
- Employee Save button: no alert on missing required fields.
- System Appearance settings section stays English when language switched.
- Export preview "By Employee" with shift name + times → time renders twice.

### P1 — High-impact UX
- Rota generation error messages: explain *why*.
- Rota edit-mode discoverability.
- Default shift times (Rota + Shifts tab).
- Availability colors / yellow confusion + legend.
- Group-select gesture: support drag-to-multi-select.
- "New shift" button icon parity with "New role".
- Export page UI flow: file export + bulk send clarity.
- Rename "Exceptions" tab to something more intuitive.

### P2 — Feature additions
- Swipe between advert slides.
- Return key auto-advances first → last → nickname.
- "Everyday" toggle on shift creation.
- Empty-rota "fill current + future" generation option.
- Rename "Weekly availability" carousel button.
- "Limited trial" tier with further-restricted write features.

### P3 — Ideas / design needed
- Replace Shifts top-right options with explicit add buttons.
- Labour-cost-based smart shift sizing.
- Sub-shift / sub-role data model.
- Exceptions date-range editor improvements.
