from __future__ import annotations
from datetime import date
from pathlib import Path
from typing import TYPE_CHECKING
from autorota.shift import Shift

if TYPE_CHECKING:
    from autorota.employee import Employee

_PACKAGE_DIR = Path(__file__).parent
_DEFAULT_SHIFTS_FP = _PACKAGE_DIR / "shifts.json"
_DEFAULT_OVERRIDES_FP = _PACKAGE_DIR / "shift_overrides.json"


class Schedule:
    def __init__(self, shifts: list[Shift] | None = None):
        self.shifts: list[Shift] = shifts or []

    # --- Constructors ---

    @classmethod
    def from_json(
        cls,
        start_date: date,
        duration: int,
        shifts_fp: Path,
        overrides_fp: Path,
    ) -> Schedule:
        """Build a Schedule from explicit JSON file paths over a date range."""
        from autorota.shift_utils import loadShifts

        dsdict = loadShifts(start_date, duration, overrides_fp, shifts_fp)
        return cls([shift for day_shifts in dsdict.values() for shift in day_shifts])

    @classmethod
    def from_default_json(cls, start_date: date, duration: int) -> Schedule:
        """Build a Schedule using the bundled shifts.json and shift_overrides.json."""
        return cls.from_json(
            start_date, duration, _DEFAULT_SHIFTS_FP, _DEFAULT_OVERRIDES_FP
        )

    # --- Mutation ---

    def add_shift(self, shift: Shift) -> None:
        self.shifts.append(shift)

    def assign(self, employee: Employee, shift: Shift) -> None:
        """Assign an employee to a shift, keeping both sides in sync."""
        if shift not in self.shifts:
            raise ValueError("Shift is not part of this schedule")
        shift.assign_employee(employee)
        employee.planned_shifts.append(shift)

    def unassign(self, employee: Employee, shift: Shift) -> None:
        """Remove an employee from a shift, keeping both sides in sync."""
        if employee not in shift.assigned_employees:
            raise ValueError("Employee is not assigned to this shift")
        shift.assigned_employees.remove(employee)
        employee.planned_shifts.remove(shift)

    # --- Queries ---

    def shifts_on(self, day: date) -> list[Shift]:
        """All shifts starting on a given date."""
        return [s for s in self.shifts if s.dt_start.date() == day]

    def shifts_for(self, employee: Employee) -> list[Shift]:
        """All shifts in this schedule assigned to an employee."""
        return [s for s in self.shifts if employee in s.assigned_employees]

    # --- Properties ---

    @property
    def employees(self) -> list[Employee]:
        """All unique employees assigned across the schedule."""
        seen: set = set()
        result = []
        for shift in self.shifts:
            for emp in shift.assigned_employees:
                if id(emp) not in seen:
                    seen.add(id(emp))
                    result.append(emp)
        return result

    @property
    def unfilled_shifts(self) -> list[Shift]:
        """Shifts that still have remaining capacity."""
        return [s for s in self.shifts if s.has_capacity()]
