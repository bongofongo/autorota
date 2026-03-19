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


def dsdict_to_json(dsdict: DateShiftDict, fp: Path) -> None:
    def serialise(obj: DateShiftDict):
        return {
            d.isoformat(): [
                {
                    "start": s.dt_start.hour,
                    "end": s.dt_end.hour,
                }
                for s in shifts
            ]
            for d, shifts in obj.items()
        }

    with open(fp, "w") as f:
        json.dump(serialise(obj=dsdict), f, indent=2)


def dsdict_from_json(fp: Path) -> DateShiftDict:
    with open(fp) as f:
        data = json.load(f)

    return {
        date.fromisoformat(d): [
            PShift(s["start"], s["end"]).toShift(date.fromisoformat(d))
            for s in shifts
        ]
        for d, shifts in data.items()
    }


def loadOverrides(path: Path) -> DateShiftDict:
    with open(path) as f:
        data = json.load(f)

    return {
        date.fromisoformat(isodate): [
            PShift(shift["start"], shift["end"]).toShift(date.fromisoformat(isodate))
            for shift in shifts
        ]
        for isodate, shifts in data.items()
    }


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
    weekdays = loadWeekdaySchedule(weekday_fp)
    overrides = loadOverrides(override_fp)

    res: DateShiftDict = {}
    for i in range(duration):
        day = start_date + timedelta(days=i)
        if day in overrides:
            res[day] = overrides[day]
        else:
            res[day] = [pshift.toShift(day) for pshift in weekdays[day.weekday()]]

    return res
