# Requested Changes

## 1. Per-role min/max headcount on shift templates

Shift template currently has single capacity (min/max headcount) optionally tied to one role (or wildcard).

Want: shift template carry list of role requirements, each with own min and max.

### Example
Single shift demands:
- ≥1 manager
- ≥2 baristas
- ≤2 dishwashers

### Behavior
- Each requirement: `{ role_id, min, max }`. `min` optional (default 0), `max` optional (unbounded).
- Total shift capacity = sum of role mins (lower bound) … sum of role maxes (upper bound), or explicit overall cap if set.
- Wildcard slots still allowed alongside role requirements (any-role filler).
- Scheduler must satisfy each role's min before filling extras; never exceed any role's max.
- Assignment must record which role-slot it filled (so UI/exports can show "Alice — barista" on a multi-role shift).

### Touch points
- `autorota-core` shift model + migration (new `shift_role_requirements` table or JSON column).
- Scheduler two-pass greedy: hardest-to-fill heuristic uses per-role mins.
- FFI types + UniFFI regen.
- SwiftUI shift editor: list of role rows with min/max steppers, add/remove role.
- Rota display: group assignments under role within shift.
- CSV/JSON/PDF export: include role per assignment line.
- Shift template overrides: per-role requirement overridable per date.
