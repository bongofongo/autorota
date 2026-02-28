from .employee import Employee
from .shift import Shift


def getFirst(_: Shift, emps: list[Employee]) -> list[Employee]:
    return emps[:1]


def sortByPreference(shift: Shift, emps: list[Employee]) -> list[Employee]:
    return sorted(emps, key=lambda emp: emp.pref_schedule[shift])
