from autorota.shift import Shift
import collections
import random
from datetime import date, datetime
from enum import Enum, IntEnum
from copy import deepcopy


class Weekday(IntEnum):
    MONDAY = 0
    TUESDAY = 1
    WEDNESDAY = 2
    THURSDAY = 3
    FRIDAY = 4
    SATURDAY = 5
    SUNDAY = 6


class Availability(Enum):
    YES = 3
    MAYBE = 2
    NO = 1


class AvailDict(collections.UserDict[Weekday, dict[int, Availability]]):
    def __init__(self):
        super().__init__()

        self.data = {
            day: {hour: Availability.MAYBE for hour in range(24)} for day in Weekday
        }

    def set_range(self, weekday: Weekday, start_hour, end_hour, avail: Availability):
        if weekday not in Weekday:
            raise ValueError("Not a weekday")
        if end_hour <= start_hour:
            raise ValueError("End hour surpasses start hour.")
        for i in range(start_hour, end_hour + 1):
            self.data[weekday][i] = avail

    def set_random(self):
        for day in Weekday:
            avail = random.choice(list(Availability))
            self.set_range(day, 0, 23, avail)

    def prompt_day(self, weekday: Weekday, start_hour: int = 6, end_hour: int = 22) -> None:
        """Interactively edit availability for a single weekday.

        Enter a range and availability level, e.g.:
          9-17 yes   — mark hours 9 through 17 as YES
          18 no      — mark hour 18 as NO
          done       — finish editing this day
        """
        abbrev: dict[str, Availability] = {
            "y": Availability.YES, "yes": Availability.YES,
            "m": Availability.MAYBE, "maybe": Availability.MAYBE,
            "n": Availability.NO, "no": Availability.NO,
        }
        symbol: dict[Availability, str] = {
            Availability.YES: "Y", Availability.MAYBE: "M", Availability.NO: "N",
        }

        while True:
            hours = range(start_hour, end_hour)
            header = "  ".join(f"{h:02}" for h in hours)
            row = "  ".join(symbol[self.data[weekday][h]] for h in hours)
            print(f"\n{weekday.name}")
            print(header)
            print(row)
            print("  Y=yes  M=maybe  N=no  |  e.g. '9-17 yes'  '18 no'  'done'")

            raw = input("> ").strip().lower()
            if raw in ("done", ""):
                break

            parts = raw.split()
            if len(parts) != 2:
                print("Invalid — expected '<hour-or-range> <yes|no|maybe>'")
                continue

            range_part, avail_part = parts
            if avail_part not in abbrev:
                print(f"Unknown availability '{avail_part}' — use yes, no, or maybe")
                continue

            avail = abbrev[avail_part]
            try:
                if "-" in range_part:
                    s, e = range_part.split("-", 1)
                    s, e = int(s), int(e)
                    if s == e:
                        self.data[weekday][s] = avail
                    else:
                        self.set_range(weekday, s, e, avail)
                else:
                    self.data[weekday][int(range_part)] = avail
            except (ValueError, KeyError) as exc:
                print(f"Error: {exc}")

    def show(
        self,
        start_hour: int = 6,
        end_hour: int = 22,
    ) -> None:
        hours = range(start_hour, end_hour)

        symbol: dict[Availability, str] = {
            Availability.YES: "Y",
            Availability.MAYBE: "M",
            Availability.NO: "N",
        }

        header = " " * 10 + " ".join(f"{h:02}" for h in hours)
        print(header)

        for day in Weekday:
            row = []
            for hour in hours:
                value = self.get(day, {}).get(hour)
                if value is None:
                    row.append(".")
                else:
                    row.append(symbol[value])

            print(f"{day.name:<10} {'  '.join(row)}")


class Employee:
    # General Details
    name: str
    bank: str
    start_date: date

    # Job Ability
    role: set[str]
    skills: set[str]

    # Easy Work Preference
    hours_per_week_min: int
    hours_per_week_max: int
    max_daily_hours: int

    # Availability
    default_avail: AvailDict
    final_avail: AvailDict

    # Calendar
    past_shifts: list[Shift]
    planned_shifts: list[Shift]
    planned_overrides: dict[date, dict[int, Availability]]

    def __init__(self, name, start_date=None):
        self.name = name
        self.start_date = start_date if start_date is not None else datetime.today()

        self.role = set()
        self.skills = set()

        self.past_shifts = []
        self.planned_shifts = []
        self.planned_overrides = {}

        self.default_avail = AvailDict()
        self.default_avail.set_random()

        self.final_avail = deepcopy(self.default_avail)

        self.update_final_avail()

    def __repr__(self):
        return self.name

    def set_weekly_hours(self, minimum: int, maximum: int):
        self.hours_per_week_max = maximum
        self.hours_per_week_min = minimum

    def set_daily_hours(self, max_daily: int):
        self.max_daily_hours = max_daily

    def add_role(self, role):
        self.role.add(role)

    def update_final_avail(self):
        self.final_avail = deepcopy(self.default_avail)

    def set_final_avail_range(
        self, weekday: Weekday, start_hour: int, end_hour: int, avail: Availability
    ):
        self.final_avail.set_range(weekday, start_hour, end_hour, avail)

    def edit_default_avail(self, start_hour: int = 6, end_hour: int = 22) -> None:
        """Interactively set default (reusable) availability across all weekdays.

        After completing, final_avail is reset to match the new default.
        """
        print(f"\n=== Default Availability: {self.name} ===")
        print("Set your usual weekly availability. Press Enter or type 'done' to skip a day.\n")
        self.default_avail.show(start_hour, end_hour)

        for day in Weekday:
            ans = input(f"\nEdit {day.name}? [y/N] ").strip().lower()
            if ans in ("y", "yes"):
                self.default_avail.prompt_day(day, start_hour, end_hour)

        self.update_final_avail()
        print("\nDefault availability saved. Final availability reset to match.")

    def edit_final_avail(self, start_hour: int = 6, end_hour: int = 22) -> None:
        """Interactively set final (week-specific) availability.

        Starts from a fresh copy of default_avail so only exceptions need to be entered.
        """
        print(f"\n=== Final Availability for the Week: {self.name} ===")
        print("Adjust your availability for this specific week (defaults shown below).\n")
        self.update_final_avail()
        self.final_avail.show(start_hour, end_hour)

        for day in Weekday:
            ans = input(f"\nEdit {day.name}? [y/N] ").strip().lower()
            if ans in ("y", "yes"):
                self.final_avail.prompt_day(day, start_hour, end_hour)

        print("\nFinal availability saved.")
