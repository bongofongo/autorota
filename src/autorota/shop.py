from .employee import Employee
from .shift import PShift, Shift
from datetime import datetime, date, timedelta


class Shop:
    employees: list[Employee]
    shifts: dict[date, list[Shift]]
    weekday_shift_presets: list[list[PShift]]

    def __init__(self, emps: list[Employee]):
        year = datetime.now().date().year
        startDate, endDate = date(year, 1, 1), date(year, 12, 31)
        self.shifts = {}
        self.fillDateShifts(self.shifts, startDate, endDate)
        self.employees = emps

    def fillDateShifts(self, d: dict, start_date: date, end_date: date):
        cur_date: date = start_date
        for _ in range((end_date - start_date).days):
            cur_date += timedelta(days=1)
            days_shifts = [
                psh.toShift(cur_date)
                for psh in self.weekday_shift_presets[cur_date.weekday()]
            ]
            d[cur_date] = days_shifts
