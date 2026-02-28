from .shift import Shift
import random
from .shift_utils import DateShiftDict


# TODO: incorporate synergies
# TODO: incorporate variety of working preferences
class Employee:
    name: str
    hours_per_week_min: int
    hours_per_week_max: int

    past_shifts: DateShiftDict
    weekly_time_pref: dict[int, tuple[int, int]]
    max_daily_hours = int

    def __init__(self, name):
        self.name = name
        self.pref_schedule = {}

    def __repr__(self):
        return self.name

    def randomPref(self, s: Shift):
        self.pref_schedule[s] = random.randrange(2)

        # return { d.isoformat():{"start":s.start_hour, "end":s.end_hour for s in shifts} for d, shifts in obj.items() }

    def setWeeklyHours(self, minimum: int, maximum: int):
        self.hours_per_week_max = maximum
        self.hours_per_week_min = minimum

    # def takePref(self, shifts: list[Shift]):
    #     for shift in shifts:
    #         while True:
    #             pref = int(
    #                 input(
    #                     f"{self.name}, indicate your preference for this shift: {shift}: [0/1/2 (lowest)]: "
    #                 )
    #             )
    #             if 0 <= pref < 3:
    #                 self.pref_schedule[shift] = pref
    #                 break
    #             else:
    #                 print("[error] invalid input. Try again")
