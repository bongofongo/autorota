from typing import Callable
from .shift import Shift
from datetime import date, timedelta
from .employee import Employee
import autorota.shift_utils as shutils
from pathlib import Path
import collections


class RotaDict(collections.UserDict[date, dict[Shift, list[Employee]]]):
    def __repr__(self):
        res = []
        for day in sorted(self.data.keys()):
            res.append(f"{day}:")
            for shift, emps in self.data[day].items():
                res.append(f"\t{shift.showHours()}: {emps[0]}")

        return "\n".join(res)


class Rota:
    possible_rota: RotaDict
    emps: list[Employee]
    shift_schedule: dict[date, list[Shift]]
    start_date: date
    duration: int

    def __init__(self, start_date: date, duration: int, employees):
        self.shift_schedule = shutils.loadShifts(
            start_date,
            duration,
            Path("./src/autorota/shift_overrides.json"),
            Path("./src/autorota/shifts.json"),
        )
        self.start_date = start_date
        self.duration = duration
        self.emps = employees
        self.possible_rota = RotaDict()

    def getPossibleRota(
        self,
        funcs: list[Callable[[Shift, list[Employee]], list[Employee]]],
    ):
        period = (self.start_date + timedelta(days=day) for day in range(self.duration))
        for day in period:
            shift_dict = {}
            for shift in self.shift_schedule[day]:
                sorted_emps = self.emps
                for f in funcs:
                    sorted_emps = f(shift, sorted_emps)
                shift_dict[shift] = sorted_emps
            self.possible_rota[day] = shift_dict

        return self.possible_rota
