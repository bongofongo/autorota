use serde::{Deserialize, Serialize};

/// A saved snapshot of shift/assignment data at a point in time.
#[derive(Debug, Clone)]
pub struct Save {
    pub id: i64,
    pub rota_id: i64,
    pub saved_at: String,
    pub summary: String,
    pub snapshot_json: String,
    /// User-assigned tags for this save, ordered by insertion.
    pub tags: Vec<String>,
    /// RFC3339 timestamp set when the user restored the rota to this save.
    /// Non-NULL means the entry gets a red "Restored" badge and is sorted
    /// above its week siblings by `COALESCE(restored_at, saved_at)`.
    pub restored_at: Option<String>,
}

// ── Tag validation ──────────────────────────────────────────────────────────

/// Max characters in a single tag.
pub const TAG_MAX_LEN: usize = 15;

/// Max tags that may exist on a single save.
pub const TAG_MAX_PER_SAVE: usize = 3;

/// Reasons a tag add may fail. Variants cross the FFI boundary as distinct
/// error messages so the UI can show a specific inline hint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TagError {
    Empty,
    TooLong,
    ContainsSemicolon,
    Duplicate,
    MaxReached,
}

impl TagError {
    pub fn as_code(&self) -> &'static str {
        match self {
            TagError::Empty => "tag_empty",
            TagError::TooLong => "tag_too_long",
            TagError::ContainsSemicolon => "tag_has_semicolon",
            TagError::Duplicate => "tag_duplicate",
            TagError::MaxReached => "tag_max_reached",
        }
    }
}

impl std::fmt::Display for TagError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_code())
    }
}

/// Validate a raw tag string against the per-tag rules.
///
/// Trims whitespace, rejects empty, >15 chars, or containing `;`.
/// Returns the trimmed value on success (preserving original case).
pub fn validate_tag(raw: &str) -> Result<String, TagError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(TagError::Empty);
    }
    if trimmed.chars().count() > TAG_MAX_LEN {
        return Err(TagError::TooLong);
    }
    if trimmed.contains(';') {
        return Err(TagError::ContainsSemicolon);
    }
    Ok(trimmed.to_string())
}

#[cfg(test)]
mod tag_validation_tests {
    use super::*;

    #[test]
    fn accepts_normal_tag() {
        assert_eq!(validate_tag("morning").unwrap(), "morning");
    }

    #[test]
    fn trims_whitespace() {
        assert_eq!(validate_tag("  busy  ").unwrap(), "busy");
    }

    #[test]
    fn rejects_empty() {
        assert_eq!(validate_tag("").unwrap_err(), TagError::Empty);
        assert_eq!(validate_tag("   ").unwrap_err(), TagError::Empty);
    }

    #[test]
    fn rejects_too_long() {
        // 16 ASCII chars > max (15)
        assert_eq!(
            validate_tag("abcdefghijklmnop").unwrap_err(),
            TagError::TooLong
        );
    }

    #[test]
    fn accepts_exactly_max() {
        assert_eq!(validate_tag("abcdefghijklmno").unwrap(), "abcdefghijklmno");
    }

    #[test]
    fn rejects_semicolon() {
        assert_eq!(
            validate_tag("a;b").unwrap_err(),
            TagError::ContainsSemicolon
        );
    }
}

// ── Snapshot JSON structure ──────────────────────────────────────────────────

/// Top-level snapshot stored as JSON in the `saves.snapshot_json` column.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SaveSnapshot {
    pub week_start: String,
    #[serde(rename = "committed_shift_ids", alias = "saved_shift_ids")]
    pub saved_shift_ids: Vec<i64>,
    pub shifts: Vec<SaveShiftSnapshot>,
    pub total_hours: f32,
    pub total_shifts: usize,
    pub unique_employees: usize,
    /// Employee availability overrides that fell within this rota's week at
    /// save time. Frozen here so historical regeneration/analytics isn't
    /// distorted by later edits to the live overrides table. `#[serde(default)]`
    /// keeps older snapshots (written before this field existed) deserializable.
    #[serde(default)]
    pub avail_overrides: Vec<SaveEmployeeAvailabilityOverrideSnapshot>,
}

/// Snapshot of one employee availability override within a save.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SaveEmployeeAvailabilityOverrideSnapshot {
    pub employee_id: i64,
    pub date: String,
    /// Raw JSON of `DayAvailability` — string-keyed hour → state map, exactly
    /// as stored in `employee_availability_overrides.availability`.
    pub availability_json: String,
    pub notes: Option<String>,
    /// "manual" | "exception". Defaults to "exception" when absent so
    /// pre-upgrade snapshots keep their current semantics.
    #[serde(default = "default_override_source")]
    pub source: String,
}

fn default_override_source() -> String {
    "exception".to_string()
}

/// Snapshot of a single shift within a save.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SaveShiftSnapshot {
    pub shift_id: i64,
    /// Parent template if this was a template-driven shift. Template shifts
    /// get new `shift_id`s each time the scheduler is regenerated, so the diff
    /// logic uses `(date, template_id)` to match identity across regens. Ad-hoc
    /// shifts leave this `None` and are matched by `shift_id` instead.
    #[serde(default)]
    pub template_id: Option<i64>,
    pub date: String,
    pub start_time: String,
    pub end_time: String,
    pub required_role: String,
    pub min_employees: u32,
    pub max_employees: u32,
    pub assignments: Vec<SaveAssignmentSnapshot>,
}

/// Snapshot of a single assignment within a saved shift.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SaveAssignmentSnapshot {
    pub assignment_id: i64,
    pub employee_id: i64,
    pub employee_name: String,
    pub status: String,
    pub hourly_wage: Option<f32>,
    pub wage_currency: Option<String>,
}

// ── Diff ────────────────────────────────────────────────────────────────────

/// Result of comparing a live shift against the latest save snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShiftDiff {
    pub shift_id: i64,
    /// Shift exists in live schedule but not in any save.
    pub is_new: bool,
    /// Shift exists in both but differs (times, role, capacity, or assignments).
    pub is_changed: bool,
}

// ── Detailed change types (in-memory, not persisted) ────────────────────────

/// One semantic change between two snapshots (or between a snapshot and live state).
///
/// Designed for UI display: each variant carries the human-relevant fields so
/// the renderer doesn't need to look up anything else. Not persisted — these
/// are computed on-demand by `diff_snapshots`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ChangeKind {
    /// A shift was added (exists in new, not in old).
    ShiftAdded {
        start_time: String,
        end_time: String,
        required_role: String,
        min_employees: u32,
        max_employees: u32,
    },
    /// A shift was removed (exists in old, not in new).
    ShiftRemoved {
        start_time: String,
        end_time: String,
        required_role: String,
    },
    /// A shift's start/end time changed.
    ShiftTimeChanged {
        old_start: String,
        new_start: String,
        old_end: String,
        new_end: String,
    },
    /// A shift's capacity (min/max) changed.
    ShiftCapacityChanged {
        old_min: u32,
        new_min: u32,
        old_max: u32,
        new_max: u32,
    },
    /// A shift's required role changed.
    ShiftRoleChanged { old_role: String, new_role: String },
    /// An employee was assigned to a shift.
    AssignmentAdded {
        employee_id: i64,
        employee_name: String,
    },
    /// An employee was unassigned from a shift.
    AssignmentRemoved {
        employee_id: i64,
        employee_name: String,
    },
    /// An assignment's status changed (e.g. Proposed → Confirmed).
    AssignmentStatusChanged {
        employee_id: i64,
        employee_name: String,
        old_status: String,
        new_status: String,
    },
    /// An employee was moved between shifts on the same date — collapsed from
    /// one AssignmentRemoved + one AssignmentAdded. `shift_id` on the parent
    /// `ChangeDetail` refers to the *destination* shift.
    EmployeeMoved {
        employee_id: i64,
        employee_name: String,
        from_shift_id: i64,
        from_start_time: String,
        from_end_time: String,
    },
}

/// A single change attached to a shift on a specific date.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ChangeDetail {
    pub shift_id: i64,
    pub date: String,
    pub kind: ChangeKind,
}

/// Result of restoring a rota from a save snapshot.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RestoreResult {
    pub rota_id: i64,
    pub shifts_restored: usize,
    pub assignments_restored: usize,
    /// Assignments whose employee no longer exists and were skipped.
    pub assignments_skipped: usize,
}

// ── Pure diff function ──────────────────────────────────────────────────────

/// Compute detailed changes between two snapshots.
///
/// `old` and `new` can be any two snapshots (e.g. previous save vs current
/// save, or a persisted save vs a synthesized live-state snapshot). The
/// result lists additions, removals, per-shift modifications, and
/// cross-shift employee moves.
/// Stable identity used to match the "same" shift across two snapshots.
///
/// Template-driven shifts get new `shift_id`s every time the scheduler
/// regenerates the week, so matching by `shift_id` alone reports every shift
/// on every day as removed+added whenever a regen happens between saves.
/// For those we key on `(date, template_id)` instead — that survives regens.
/// Ad-hoc shifts (no template) keep a stable DB id, so we key on `shift_id`.
#[derive(Hash, Eq, PartialEq, Clone, Debug)]
enum ShiftIdentity {
    Template { date: String, template_id: i64 },
    AdHoc { shift_id: i64 },
}

fn shift_identity(s: &SaveShiftSnapshot) -> ShiftIdentity {
    match s.template_id {
        Some(tid) => ShiftIdentity::Template {
            date: s.date.clone(),
            template_id: tid,
        },
        None => ShiftIdentity::AdHoc {
            shift_id: s.shift_id,
        },
    }
}

pub fn diff_snapshots(old: &SaveSnapshot, new: &SaveSnapshot) -> Vec<ChangeDetail> {
    use std::collections::HashMap;

    let old_by_key: HashMap<ShiftIdentity, &SaveShiftSnapshot> =
        old.shifts.iter().map(|s| (shift_identity(s), s)).collect();
    let new_by_key: HashMap<ShiftIdentity, &SaveShiftSnapshot> =
        new.shifts.iter().map(|s| (shift_identity(s), s)).collect();

    // Also keep a shift_id→old-snapshot map for collapse_moves, which needs
    // to resolve the "from" shift of a move by its database id.
    let old_by_id: HashMap<i64, &SaveShiftSnapshot> =
        old.shifts.iter().map(|s| (s.shift_id, s)).collect();

    let mut changes: Vec<ChangeDetail> = Vec::new();

    // Shifts added (in new, not in old).
    for shift in &new.shifts {
        if !old_by_key.contains_key(&shift_identity(shift)) {
            changes.push(ChangeDetail {
                shift_id: shift.shift_id,
                date: shift.date.clone(),
                kind: ChangeKind::ShiftAdded {
                    start_time: shift.start_time.clone(),
                    end_time: shift.end_time.clone(),
                    required_role: shift.required_role.clone(),
                    min_employees: shift.min_employees,
                    max_employees: shift.max_employees,
                },
            });
            // Report its assignments as individual AssignmentAdded entries so
            // the UI can list who was put on the new shift.
            for a in &shift.assignments {
                changes.push(ChangeDetail {
                    shift_id: shift.shift_id,
                    date: shift.date.clone(),
                    kind: ChangeKind::AssignmentAdded {
                        employee_id: a.employee_id,
                        employee_name: a.employee_name.clone(),
                    },
                });
            }
        }
    }

    // Shifts removed (in old, not in new).
    for shift in &old.shifts {
        if !new_by_key.contains_key(&shift_identity(shift)) {
            changes.push(ChangeDetail {
                shift_id: shift.shift_id,
                date: shift.date.clone(),
                kind: ChangeKind::ShiftRemoved {
                    start_time: shift.start_time.clone(),
                    end_time: shift.end_time.clone(),
                    required_role: shift.required_role.clone(),
                },
            });
            for a in &shift.assignments {
                changes.push(ChangeDetail {
                    shift_id: shift.shift_id,
                    date: shift.date.clone(),
                    kind: ChangeKind::AssignmentRemoved {
                        employee_id: a.employee_id,
                        employee_name: a.employee_name.clone(),
                    },
                });
            }
        }
    }

    // Shifts in both — compare fields and assignments. Iterate new shifts so
    // reported ids come from the current state (stable under template regen).
    for new_shift in &new.shifts {
        let Some(old_shift) = old_by_key.get(&shift_identity(new_shift)) else {
            continue;
        };
        let shift_id = new_shift.shift_id;

        if old_shift.start_time != new_shift.start_time || old_shift.end_time != new_shift.end_time
        {
            changes.push(ChangeDetail {
                shift_id,
                date: new_shift.date.clone(),
                kind: ChangeKind::ShiftTimeChanged {
                    old_start: old_shift.start_time.clone(),
                    new_start: new_shift.start_time.clone(),
                    old_end: old_shift.end_time.clone(),
                    new_end: new_shift.end_time.clone(),
                },
            });
        }

        if old_shift.min_employees != new_shift.min_employees
            || old_shift.max_employees != new_shift.max_employees
        {
            changes.push(ChangeDetail {
                shift_id,
                date: new_shift.date.clone(),
                kind: ChangeKind::ShiftCapacityChanged {
                    old_min: old_shift.min_employees,
                    new_min: new_shift.min_employees,
                    old_max: old_shift.max_employees,
                    new_max: new_shift.max_employees,
                },
            });
        }

        if old_shift.required_role != new_shift.required_role {
            changes.push(ChangeDetail {
                shift_id,
                date: new_shift.date.clone(),
                kind: ChangeKind::ShiftRoleChanged {
                    old_role: old_shift.required_role.clone(),
                    new_role: new_shift.required_role.clone(),
                },
            });
        }

        // Assignment diff indexed by employee_id.
        let old_emp: HashMap<i64, &SaveAssignmentSnapshot> = old_shift
            .assignments
            .iter()
            .map(|a| (a.employee_id, a))
            .collect();
        let new_emp: HashMap<i64, &SaveAssignmentSnapshot> = new_shift
            .assignments
            .iter()
            .map(|a| (a.employee_id, a))
            .collect();

        for (emp_id, new_a) in &new_emp {
            match old_emp.get(emp_id) {
                None => changes.push(ChangeDetail {
                    shift_id,
                    date: new_shift.date.clone(),
                    kind: ChangeKind::AssignmentAdded {
                        employee_id: *emp_id,
                        employee_name: new_a.employee_name.clone(),
                    },
                }),
                Some(old_a) if old_a.status != new_a.status => {
                    changes.push(ChangeDetail {
                        shift_id,
                        date: new_shift.date.clone(),
                        kind: ChangeKind::AssignmentStatusChanged {
                            employee_id: *emp_id,
                            employee_name: new_a.employee_name.clone(),
                            old_status: old_a.status.clone(),
                            new_status: new_a.status.clone(),
                        },
                    });
                }
                _ => {}
            }
        }
        for (emp_id, old_a) in &old_emp {
            if !new_emp.contains_key(emp_id) {
                changes.push(ChangeDetail {
                    shift_id: old_shift.shift_id,
                    date: old_shift.date.clone(),
                    kind: ChangeKind::AssignmentRemoved {
                        employee_id: *emp_id,
                        employee_name: old_a.employee_name.clone(),
                    },
                });
            }
        }
    }

    collapse_moves(&old_by_id, changes)
}

/// Collapse matching (AssignmentRemoved, AssignmentAdded) pairs with the same
/// employee on the same date into a single EmployeeMoved entry.
fn collapse_moves(
    old_by_id: &std::collections::HashMap<i64, &SaveShiftSnapshot>,
    changes: Vec<ChangeDetail>,
) -> Vec<ChangeDetail> {
    use std::collections::{HashMap, HashSet};

    // Index by (date, employee_id) → change index.
    let mut removed_at: HashMap<(String, i64), usize> = HashMap::new();
    let mut added_at: HashMap<(String, i64), usize> = HashMap::new();
    for (i, c) in changes.iter().enumerate() {
        match &c.kind {
            ChangeKind::AssignmentRemoved { employee_id, .. } => {
                removed_at.insert((c.date.clone(), *employee_id), i);
            }
            ChangeKind::AssignmentAdded { employee_id, .. } => {
                added_at.insert((c.date.clone(), *employee_id), i);
            }
            _ => {}
        }
    }

    // Indices of changes to suppress because they become part of a Move.
    let mut suppressed: HashSet<usize> = HashSet::new();
    // Indices where a Move should be emitted (destination-shift AssignmentAdded).
    let mut moves: HashMap<usize, ChangeDetail> = HashMap::new();

    for (key, &add_idx) in &added_at {
        let Some(&rm_idx) = removed_at.get(key) else {
            continue;
        };
        let add = &changes[add_idx];
        let rm = &changes[rm_idx];
        if add.shift_id == rm.shift_id {
            continue; // same shift — not a move
        }
        let (emp_id, emp_name) = match &add.kind {
            ChangeKind::AssignmentAdded {
                employee_id,
                employee_name,
            } => (*employee_id, employee_name.clone()),
            _ => continue,
        };
        let (from_start, from_end) = old_by_id
            .get(&rm.shift_id)
            .map(|s| (s.start_time.clone(), s.end_time.clone()))
            .unwrap_or_default();

        suppressed.insert(rm_idx);
        moves.insert(
            add_idx,
            ChangeDetail {
                shift_id: add.shift_id,
                date: add.date.clone(),
                kind: ChangeKind::EmployeeMoved {
                    employee_id: emp_id,
                    employee_name: emp_name,
                    from_shift_id: rm.shift_id,
                    from_start_time: from_start,
                    from_end_time: from_end,
                },
            },
        );
    }

    let mut result: Vec<ChangeDetail> = Vec::with_capacity(changes.len());
    for (i, c) in changes.into_iter().enumerate() {
        if suppressed.contains(&i) {
            continue;
        }
        if let Some(mv) = moves.remove(&i) {
            result.push(mv);
        } else {
            result.push(c);
        }
    }
    result
}

#[cfg(test)]
mod diff_tests {
    use super::*;

    fn shift(
        id: i64,
        date: &str,
        start: &str,
        end: &str,
        role: &str,
        min: u32,
        max: u32,
        assignments: Vec<SaveAssignmentSnapshot>,
    ) -> SaveShiftSnapshot {
        SaveShiftSnapshot {
            shift_id: id,
            template_id: None,
            date: date.to_string(),
            start_time: start.to_string(),
            end_time: end.to_string(),
            required_role: role.to_string(),
            min_employees: min,
            max_employees: max,
            assignments,
        }
    }

    fn assign(emp_id: i64, name: &str, status: &str) -> SaveAssignmentSnapshot {
        SaveAssignmentSnapshot {
            assignment_id: 0,
            employee_id: emp_id,
            employee_name: name.to_string(),
            status: status.to_string(),
            hourly_wage: None,
            wage_currency: None,
        }
    }

    fn snap(shifts: Vec<SaveShiftSnapshot>) -> SaveSnapshot {
        SaveSnapshot {
            week_start: "2026-04-20".to_string(),
            saved_shift_ids: shifts.iter().map(|s| s.shift_id).collect(),
            shifts,
            total_hours: 0.0,
            total_shifts: 0,
            unique_employees: 0,
            avail_overrides: vec![],
        }
    }

    #[test]
    fn no_changes_returns_empty() {
        let s = snap(vec![shift(
            1,
            "2026-04-20",
            "09:00",
            "17:00",
            "barista",
            1,
            2,
            vec![],
        )]);
        assert!(diff_snapshots(&s, &s).is_empty());
    }

    #[test]
    fn detects_new_shift() {
        let old = snap(vec![]);
        let new = snap(vec![shift(
            1,
            "2026-04-20",
            "09:00",
            "17:00",
            "barista",
            1,
            2,
            vec![],
        )]);
        let d = diff_snapshots(&old, &new);
        assert_eq!(d.len(), 1);
        assert!(matches!(d[0].kind, ChangeKind::ShiftAdded { .. }));
    }

    #[test]
    fn detects_removed_shift() {
        let old = snap(vec![shift(
            1,
            "2026-04-20",
            "09:00",
            "17:00",
            "barista",
            1,
            2,
            vec![],
        )]);
        let new = snap(vec![]);
        let d = diff_snapshots(&old, &new);
        assert_eq!(d.len(), 1);
        assert!(matches!(d[0].kind, ChangeKind::ShiftRemoved { .. }));
    }

    #[test]
    fn detects_time_capacity_role_changes() {
        let old = snap(vec![shift(
            1,
            "2026-04-20",
            "09:00",
            "17:00",
            "barista",
            1,
            2,
            vec![],
        )]);
        let new = snap(vec![shift(
            1,
            "2026-04-20",
            "09:00",
            "18:00",
            "cashier",
            2,
            3,
            vec![],
        )]);
        let d = diff_snapshots(&old, &new);
        assert_eq!(d.len(), 3);
        assert!(
            d.iter()
                .any(|c| matches!(c.kind, ChangeKind::ShiftTimeChanged { .. }))
        );
        assert!(
            d.iter()
                .any(|c| matches!(c.kind, ChangeKind::ShiftCapacityChanged { .. }))
        );
        assert!(
            d.iter()
                .any(|c| matches!(c.kind, ChangeKind::ShiftRoleChanged { .. }))
        );
    }

    #[test]
    fn detects_assignment_add_remove_status() {
        let old = snap(vec![shift(
            1,
            "2026-04-20",
            "09:00",
            "17:00",
            "barista",
            1,
            2,
            vec![
                assign(10, "Alice", "Proposed"),
                assign(11, "Bob", "Confirmed"),
            ],
        )]);
        let new = snap(vec![shift(
            1,
            "2026-04-20",
            "09:00",
            "17:00",
            "barista",
            1,
            2,
            vec![
                assign(10, "Alice", "Confirmed"),
                assign(12, "Carol", "Confirmed"),
            ],
        )]);
        let d = diff_snapshots(&old, &new);
        assert!(d.iter().any(|c| matches!(
            &c.kind,
            ChangeKind::AssignmentStatusChanged {
                employee_id: 10,
                ..
            }
        )));
        assert!(d.iter().any(|c| matches!(
            &c.kind,
            ChangeKind::AssignmentRemoved {
                employee_id: 11,
                ..
            }
        )));
        assert!(d.iter().any(|c| matches!(
            &c.kind,
            ChangeKind::AssignmentAdded {
                employee_id: 12,
                ..
            }
        )));
    }

    fn tshift(
        id: i64,
        template_id: Option<i64>,
        date: &str,
        start: &str,
        end: &str,
        role: &str,
        assignments: Vec<SaveAssignmentSnapshot>,
    ) -> SaveShiftSnapshot {
        SaveShiftSnapshot {
            shift_id: id,
            template_id,
            date: date.to_string(),
            start_time: start.to_string(),
            end_time: end.to_string(),
            required_role: role.to_string(),
            min_employees: 1,
            max_employees: 1,
            assignments,
        }
    }

    #[test]
    fn regenerated_template_shifts_match_by_template_id() {
        // Scheduler regen wipes and recreates template shifts with new DB
        // ids. With matching by (date, template_id) the diff should only
        // report the real change (one new assignment), not every shift as
        // removed+added.
        let old = snap(vec![
            tshift(
                100,
                Some(7),
                "2026-04-20",
                "09:00",
                "17:00",
                "barista",
                vec![],
            ),
            tshift(
                101,
                Some(8),
                "2026-04-21",
                "09:00",
                "17:00",
                "barista",
                vec![],
            ),
        ]);
        let new = snap(vec![
            tshift(
                200,
                Some(7),
                "2026-04-20",
                "09:00",
                "17:00",
                "barista",
                vec![assign(10, "Alice", "Proposed")],
            ),
            tshift(
                201,
                Some(8),
                "2026-04-21",
                "09:00",
                "17:00",
                "barista",
                vec![],
            ),
        ]);
        let d = diff_snapshots(&old, &new);
        assert_eq!(d.len(), 1, "unexpected changes: {:?}", d);
        assert!(matches!(
            d[0].kind,
            ChangeKind::AssignmentAdded {
                employee_id: 10,
                ..
            }
        ));
    }

    #[test]
    fn collapses_same_day_move() {
        // Alice moves from shift 1 to shift 2 on the same date.
        let old = snap(vec![
            shift(
                1,
                "2026-04-20",
                "09:00",
                "13:00",
                "barista",
                1,
                1,
                vec![assign(10, "Alice", "Confirmed")],
            ),
            shift(2, "2026-04-20", "14:00", "18:00", "cashier", 1, 1, vec![]),
        ]);
        let new = snap(vec![
            shift(1, "2026-04-20", "09:00", "13:00", "barista", 1, 1, vec![]),
            shift(
                2,
                "2026-04-20",
                "14:00",
                "18:00",
                "cashier",
                1,
                1,
                vec![assign(10, "Alice", "Confirmed")],
            ),
        ]);
        let d = diff_snapshots(&old, &new);
        assert_eq!(d.len(), 1);
        match &d[0].kind {
            ChangeKind::EmployeeMoved {
                employee_id: 10,
                from_shift_id: 1,
                ..
            } => {}
            other => panic!("expected EmployeeMoved, got {:?}", other),
        }
        assert_eq!(d[0].shift_id, 2); // destination
    }

    #[test]
    fn does_not_collapse_across_dates() {
        // Alice removed from shift 1 on Mon, added to shift 2 on Tue — NOT a move.
        let old = snap(vec![
            shift(
                1,
                "2026-04-20",
                "09:00",
                "13:00",
                "barista",
                1,
                1,
                vec![assign(10, "Alice", "Confirmed")],
            ),
            shift(2, "2026-04-21", "14:00", "18:00", "cashier", 1, 1, vec![]),
        ]);
        let new = snap(vec![
            shift(1, "2026-04-20", "09:00", "13:00", "barista", 1, 1, vec![]),
            shift(
                2,
                "2026-04-21",
                "14:00",
                "18:00",
                "cashier",
                1,
                1,
                vec![assign(10, "Alice", "Confirmed")],
            ),
        ]);
        let d = diff_snapshots(&old, &new);
        assert_eq!(d.len(), 2);
        assert!(
            d.iter()
                .any(|c| matches!(c.kind, ChangeKind::AssignmentRemoved { .. }))
        );
        assert!(
            d.iter()
                .any(|c| matches!(c.kind, ChangeKind::AssignmentAdded { .. }))
        );
    }
}
