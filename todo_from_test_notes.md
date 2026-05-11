# AutoRota Implementation Todo

## Zero Pass (Bug fixes)

### P0 — Bugs (fix first)
- Availability save bug when creating + setting availability on same page → restrict availability to edit page.
- Shift edit: switching required role is buggy.
- Screen flicker switching to a rota with an existing schedule.
- Screen flicker after Swap while editing a rota.
- Employee Save button: no alert on missing required fields.
- System Appearance settings section stays English when language switched.
- Export preview "By Employee" with shift name + times → time renders twice.

## First Pass

### 🎯 Advert orientation — swipe gesture missing
Swipe navigation should be enabled on the onboarding advert/intro screens **in addition to** the existing "Next" button. Users instinctively try to swipe between intro slides; relying on the button alone feels dated.

- **Action:** add horizontal swipe gesture recognizer alongside Next button. Both should advance/reverse the same state.

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

## Second Pass (Shifts)

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
