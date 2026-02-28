from .shift import Shift, PShift
from typing import TypeAlias
from datetime import date, timedelta
import json
from pathlib import Path

DateShiftDict: TypeAlias = dict[date, list[Shift]]

WDAY_MAP = {
    "Monday": 0,
    "Tuesday": 1,
    "Wednesday": 2,
    "Thursday": 3,
    "Friday": 4,
    "Saturday": 5,
    "Sunday": 6,
}


def dsdict_to_json(dsdict: DateShiftDict, fp: Path):
    def to_json_dict(obj: DateShiftDict):
        return {
            d.isoformat(): [{"start": s.start_hour, "end": s.end_hour} for s in shifts]
            for d, shifts in obj.items()
        }

    with open(fp) as f:
        json.dump(dsdict, f, default=to_json_dict)


def dsdict_from_json(fp: Path) -> DateShiftDict:
    with open(fp) as f:
        data = json.load(f)

    res = {}
    for d, shifts in data.items():
        date = d.fromisoformat()
        res[date] = [Shift(s["start"], s["end"], date) for s in shifts]

    return res


def loadOverrides(path: Path) -> DateShiftDict:
    with open(path) as f:
        data = json.load(f)

    overrides: DateShiftDict = {}
    for isodate, shifts in data.items():
        realdate = date.fromisoformat(isodate)
        overrides[realdate] = [
            Shift(shift["start"], shift["end"], realdate) for shift in shifts
        ]

    return overrides


def loadWeekdaySchedule(path: Path) -> dict[int, list[PShift]]:
    with open(path) as f:
        data = json.load(f)

    return {
        WDAY_MAP[weekday]: [PShift(shift["start"], shift["end"]) for shift in pshifts]
        for weekday, pshifts in data.items()
    }


def loadShifts(
    start_date: date, duration: int, override_fp: Path, weekday_fp: Path
) -> DateShiftDict:
    weekdays, overrides = (
        loadWeekdaySchedule(weekday_fp),
        loadOverrides(override_fp),
    )

    res_schedule: DateShiftDict = {}
    period = (start_date + timedelta(days=i) for i in range(duration))
    for day in period:
        if day in overrides:
            res_schedule[day] = overrides[day]
        else:
            pshift_list = weekdays[day.weekday()]
            res_schedule[day] = [
                Shift(pshift.start_hour, pshift.end_hour, day) for pshift in pshift_list
            ]

    return res_schedule
