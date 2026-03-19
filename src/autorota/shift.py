from __future__ import annotations
from datetime import date, datetime, timedelta, time
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from autorota.employee import Employee


class PShift:
    start_hour: int
    end_hour: int

    def __init__(self, start, end):
        self.start_hour, self.end_hour = start, end

    def toShift(self, date: date) -> "Shift":
        end = self.end_hour if self.end_hour > self.start_hour else self.end_hour + 24
        delta = timedelta(hours=(end - self.start_hour))
        return Shift(datetime.combine(date, time(hour=self.start_hour)), delta)


class Shift:
    def __init__(
        self,
        dt_start: datetime,
        duration: timedelta,
        capacity: int = 1,
        tags: set[str] | None = None,
    ) -> None:
        if capacity < 1:
            raise ValueError("capacity must be at least 1")

        self.dt_start = dt_start
        self.duration = duration
        self.capacity = capacity

        self.assigned_employees: list[Employee] = []
        self.worked_employees: list[Employee] = []
        self.tags: set[str] = tags or set()

    @property
    def dt_end(self) -> datetime:
        return self.dt_start + self.duration

    @property
    def start_time(self) -> time:
        return self.dt_start.time()

    @property
    def end_time(self) -> time:
        return self.dt_end.time()

    @property
    def frame(self) -> str:
        start = self.dt_start.strftime("%I:%M %p")
        end = self.dt_end.strftime("%I:%M %p")
        return f"{start} - {end}"

    def has_capacity(self) -> bool:
        return len(self.assigned_employees) <= self.capacity

    def assign_employee(self, employee: Employee) -> None:
        if not self.has_capacity():
            raise ValueError("Shift is already at full capacity")
        if employee in self.assigned_employees:
            raise ValueError("Employee is already assigned to this shift")
        self.assigned_employees.append(employee)

    def __repr__(self) -> str:
        return (
            f"Shift({self.dt_start.date().isoformat()}, "
            f"{self.frame}, "
            f"capacity={self.capacity})"
        )
