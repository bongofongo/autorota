use serde::{Deserialize, Serialize};

/// A committed snapshot of shift/assignment data at a point in time.
#[derive(Debug, Clone)]
pub struct Commit {
    pub id: i64,
    pub rota_id: i64,
    pub committed_at: String,
    pub summary: String,
    pub snapshot_json: String,
}

// ── Snapshot JSON structure ──────────────────────────────────────────────────

/// Top-level snapshot stored as JSON in the `commits.snapshot_json` column.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommitSnapshot {
    pub week_start: String,
    pub committed_shift_ids: Vec<i64>,
    pub shifts: Vec<CommitShiftSnapshot>,
    pub total_hours: f32,
    pub total_shifts: usize,
    pub unique_employees: usize,
}

/// Snapshot of a single shift within a commit.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommitShiftSnapshot {
    pub shift_id: i64,
    pub date: String,
    pub start_time: String,
    pub end_time: String,
    pub required_role: String,
    pub min_employees: u32,
    pub max_employees: u32,
    pub assignments: Vec<CommitAssignmentSnapshot>,
}

/// Snapshot of a single assignment within a committed shift.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommitAssignmentSnapshot {
    pub assignment_id: i64,
    pub employee_id: i64,
    pub employee_name: String,
    pub status: String,
    pub hourly_wage: Option<f32>,
    pub wage_currency: Option<String>,
}

// ── Diff ────────────────────────────────────────────────────────────────────

/// Result of comparing a live shift against the latest commit snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShiftDiff {
    pub shift_id: i64,
    /// Shift exists in live schedule but not in any commit.
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
pub enum CommitChangeKind {
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
    ShiftRoleChanged {
        old_role: String,
        new_role: String,
    },
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
    /// `CommitChangeDetail` refers to the *destination* shift.
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
pub struct CommitChangeDetail {
    pub shift_id: i64,
    pub date: String,
    pub kind: CommitChangeKind,
}

/// Result of restoring a rota from a commit snapshot.
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
/// `old` and `new` can be any two snapshots (e.g. previous commit vs current
/// commit, or a persisted commit vs a synthesized live-state snapshot). The
/// result lists additions, removals, per-shift modifications, and
/// cross-shift employee moves.
pub fn diff_snapshots(old: &CommitSnapshot, new: &CommitSnapshot) -> Vec<CommitChangeDetail> {
    use std::collections::HashMap;

    let old_by_id: HashMap<i64, &CommitShiftSnapshot> =
        old.shifts.iter().map(|s| (s.shift_id, s)).collect();
    let new_by_id: HashMap<i64, &CommitShiftSnapshot> =
        new.shifts.iter().map(|s| (s.shift_id, s)).collect();

    let mut changes: Vec<CommitChangeDetail> = Vec::new();

    // Shifts added (in new, not in old).
    for shift in &new.shifts {
        if !old_by_id.contains_key(&shift.shift_id) {
            changes.push(CommitChangeDetail {
                shift_id: shift.shift_id,
                date: shift.date.clone(),
                kind: CommitChangeKind::ShiftAdded {
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
                changes.push(CommitChangeDetail {
                    shift_id: shift.shift_id,
                    date: shift.date.clone(),
                    kind: CommitChangeKind::AssignmentAdded {
                        employee_id: a.employee_id,
                        employee_name: a.employee_name.clone(),
                    },
                });
            }
        }
    }

    // Shifts removed (in old, not in new).
    for shift in &old.shifts {
        if !new_by_id.contains_key(&shift.shift_id) {
            changes.push(CommitChangeDetail {
                shift_id: shift.shift_id,
                date: shift.date.clone(),
                kind: CommitChangeKind::ShiftRemoved {
                    start_time: shift.start_time.clone(),
                    end_time: shift.end_time.clone(),
                    required_role: shift.required_role.clone(),
                },
            });
            for a in &shift.assignments {
                changes.push(CommitChangeDetail {
                    shift_id: shift.shift_id,
                    date: shift.date.clone(),
                    kind: CommitChangeKind::AssignmentRemoved {
                        employee_id: a.employee_id,
                        employee_name: a.employee_name.clone(),
                    },
                });
            }
        }
    }

    // Shifts in both — compare fields and assignments.
    for (shift_id, new_shift) in &new_by_id {
        let Some(old_shift) = old_by_id.get(shift_id) else {
            continue;
        };

        if old_shift.start_time != new_shift.start_time
            || old_shift.end_time != new_shift.end_time
        {
            changes.push(CommitChangeDetail {
                shift_id: *shift_id,
                date: new_shift.date.clone(),
                kind: CommitChangeKind::ShiftTimeChanged {
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
            changes.push(CommitChangeDetail {
                shift_id: *shift_id,
                date: new_shift.date.clone(),
                kind: CommitChangeKind::ShiftCapacityChanged {
                    old_min: old_shift.min_employees,
                    new_min: new_shift.min_employees,
                    old_max: old_shift.max_employees,
                    new_max: new_shift.max_employees,
                },
            });
        }

        if old_shift.required_role != new_shift.required_role {
            changes.push(CommitChangeDetail {
                shift_id: *shift_id,
                date: new_shift.date.clone(),
                kind: CommitChangeKind::ShiftRoleChanged {
                    old_role: old_shift.required_role.clone(),
                    new_role: new_shift.required_role.clone(),
                },
            });
        }

        // Assignment diff indexed by employee_id.
        let old_emp: HashMap<i64, &CommitAssignmentSnapshot> = old_shift
            .assignments
            .iter()
            .map(|a| (a.employee_id, a))
            .collect();
        let new_emp: HashMap<i64, &CommitAssignmentSnapshot> = new_shift
            .assignments
            .iter()
            .map(|a| (a.employee_id, a))
            .collect();

        for (emp_id, new_a) in &new_emp {
            match old_emp.get(emp_id) {
                None => changes.push(CommitChangeDetail {
                    shift_id: *shift_id,
                    date: new_shift.date.clone(),
                    kind: CommitChangeKind::AssignmentAdded {
                        employee_id: *emp_id,
                        employee_name: new_a.employee_name.clone(),
                    },
                }),
                Some(old_a) if old_a.status != new_a.status => {
                    changes.push(CommitChangeDetail {
                        shift_id: *shift_id,
                        date: new_shift.date.clone(),
                        kind: CommitChangeKind::AssignmentStatusChanged {
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
                changes.push(CommitChangeDetail {
                    shift_id: *shift_id,
                    date: old_shift.date.clone(),
                    kind: CommitChangeKind::AssignmentRemoved {
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
    old_by_id: &std::collections::HashMap<i64, &CommitShiftSnapshot>,
    changes: Vec<CommitChangeDetail>,
) -> Vec<CommitChangeDetail> {
    use std::collections::{HashMap, HashSet};

    // Index by (date, employee_id) → change index.
    let mut removed_at: HashMap<(String, i64), usize> = HashMap::new();
    let mut added_at: HashMap<(String, i64), usize> = HashMap::new();
    for (i, c) in changes.iter().enumerate() {
        match &c.kind {
            CommitChangeKind::AssignmentRemoved { employee_id, .. } => {
                removed_at.insert((c.date.clone(), *employee_id), i);
            }
            CommitChangeKind::AssignmentAdded { employee_id, .. } => {
                added_at.insert((c.date.clone(), *employee_id), i);
            }
            _ => {}
        }
    }

    // Indices of changes to suppress because they become part of a Move.
    let mut suppressed: HashSet<usize> = HashSet::new();
    // Indices where a Move should be emitted (destination-shift AssignmentAdded).
    let mut moves: HashMap<usize, CommitChangeDetail> = HashMap::new();

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
            CommitChangeKind::AssignmentAdded {
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
            CommitChangeDetail {
                shift_id: add.shift_id,
                date: add.date.clone(),
                kind: CommitChangeKind::EmployeeMoved {
                    employee_id: emp_id,
                    employee_name: emp_name,
                    from_shift_id: rm.shift_id,
                    from_start_time: from_start,
                    from_end_time: from_end,
                },
            },
        );
    }

    let mut result: Vec<CommitChangeDetail> = Vec::with_capacity(changes.len());
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
        assignments: Vec<CommitAssignmentSnapshot>,
    ) -> CommitShiftSnapshot {
        CommitShiftSnapshot {
            shift_id: id,
            date: date.to_string(),
            start_time: start.to_string(),
            end_time: end.to_string(),
            required_role: role.to_string(),
            min_employees: min,
            max_employees: max,
            assignments,
        }
    }

    fn assign(emp_id: i64, name: &str, status: &str) -> CommitAssignmentSnapshot {
        CommitAssignmentSnapshot {
            assignment_id: 0,
            employee_id: emp_id,
            employee_name: name.to_string(),
            status: status.to_string(),
            hourly_wage: None,
            wage_currency: None,
        }
    }

    fn snap(shifts: Vec<CommitShiftSnapshot>) -> CommitSnapshot {
        CommitSnapshot {
            week_start: "2026-04-20".to_string(),
            committed_shift_ids: shifts.iter().map(|s| s.shift_id).collect(),
            shifts,
            total_hours: 0.0,
            total_shifts: 0,
            unique_employees: 0,
        }
    }

    #[test]
    fn no_changes_returns_empty() {
        let s = snap(vec![shift(1, "2026-04-20", "09:00", "17:00", "barista", 1, 2, vec![])]);
        assert!(diff_snapshots(&s, &s).is_empty());
    }

    #[test]
    fn detects_new_shift() {
        let old = snap(vec![]);
        let new = snap(vec![shift(1, "2026-04-20", "09:00", "17:00", "barista", 1, 2, vec![])]);
        let d = diff_snapshots(&old, &new);
        assert_eq!(d.len(), 1);
        assert!(matches!(d[0].kind, CommitChangeKind::ShiftAdded { .. }));
    }

    #[test]
    fn detects_removed_shift() {
        let old = snap(vec![shift(1, "2026-04-20", "09:00", "17:00", "barista", 1, 2, vec![])]);
        let new = snap(vec![]);
        let d = diff_snapshots(&old, &new);
        assert_eq!(d.len(), 1);
        assert!(matches!(d[0].kind, CommitChangeKind::ShiftRemoved { .. }));
    }

    #[test]
    fn detects_time_capacity_role_changes() {
        let old = snap(vec![shift(1, "2026-04-20", "09:00", "17:00", "barista", 1, 2, vec![])]);
        let new = snap(vec![shift(1, "2026-04-20", "09:00", "18:00", "cashier", 2, 3, vec![])]);
        let d = diff_snapshots(&old, &new);
        assert_eq!(d.len(), 3);
        assert!(d.iter().any(|c| matches!(c.kind, CommitChangeKind::ShiftTimeChanged { .. })));
        assert!(d.iter().any(|c| matches!(c.kind, CommitChangeKind::ShiftCapacityChanged { .. })));
        assert!(d.iter().any(|c| matches!(c.kind, CommitChangeKind::ShiftRoleChanged { .. })));
    }

    #[test]
    fn detects_assignment_add_remove_status() {
        let old = snap(vec![shift(
            1, "2026-04-20", "09:00", "17:00", "barista", 1, 2,
            vec![assign(10, "Alice", "Proposed"), assign(11, "Bob", "Confirmed")],
        )]);
        let new = snap(vec![shift(
            1, "2026-04-20", "09:00", "17:00", "barista", 1, 2,
            vec![assign(10, "Alice", "Confirmed"), assign(12, "Carol", "Confirmed")],
        )]);
        let d = diff_snapshots(&old, &new);
        assert!(d.iter().any(|c| matches!(&c.kind, CommitChangeKind::AssignmentStatusChanged { employee_id: 10, .. })));
        assert!(d.iter().any(|c| matches!(&c.kind, CommitChangeKind::AssignmentRemoved { employee_id: 11, .. })));
        assert!(d.iter().any(|c| matches!(&c.kind, CommitChangeKind::AssignmentAdded { employee_id: 12, .. })));
    }

    #[test]
    fn collapses_same_day_move() {
        // Alice moves from shift 1 to shift 2 on the same date.
        let old = snap(vec![
            shift(1, "2026-04-20", "09:00", "13:00", "barista", 1, 1, vec![assign(10, "Alice", "Confirmed")]),
            shift(2, "2026-04-20", "14:00", "18:00", "cashier", 1, 1, vec![]),
        ]);
        let new = snap(vec![
            shift(1, "2026-04-20", "09:00", "13:00", "barista", 1, 1, vec![]),
            shift(2, "2026-04-20", "14:00", "18:00", "cashier", 1, 1, vec![assign(10, "Alice", "Confirmed")]),
        ]);
        let d = diff_snapshots(&old, &new);
        assert_eq!(d.len(), 1);
        match &d[0].kind {
            CommitChangeKind::EmployeeMoved {
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
            shift(1, "2026-04-20", "09:00", "13:00", "barista", 1, 1, vec![assign(10, "Alice", "Confirmed")]),
            shift(2, "2026-04-21", "14:00", "18:00", "cashier", 1, 1, vec![]),
        ]);
        let new = snap(vec![
            shift(1, "2026-04-20", "09:00", "13:00", "barista", 1, 1, vec![]),
            shift(2, "2026-04-21", "14:00", "18:00", "cashier", 1, 1, vec![assign(10, "Alice", "Confirmed")]),
        ]);
        let d = diff_snapshots(&old, &new);
        assert_eq!(d.len(), 2);
        assert!(d.iter().any(|c| matches!(c.kind, CommitChangeKind::AssignmentRemoved { .. })));
        assert!(d.iter().any(|c| matches!(c.kind, CommitChangeKind::AssignmentAdded { .. })));
    }
}
