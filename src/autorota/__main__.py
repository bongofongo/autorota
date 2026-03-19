from autorota.employee import Employee, Weekday, Availability
from autorota.schedule import Schedule
from autorota.utils import getNextMonday


def _is_available(employee: Employee, shift) -> bool:
    weekday = Weekday(shift.dt_start.weekday())
    return employee.final_avail[weekday].get(shift.dt_start.hour) != Availability.NO


def main():
    # 1. Load shifts from bundled JSON files (weekly template + date overrides)
    schedule = Schedule.from_default_json(start_date=getNextMonday(), duration=7)

    # 2. Create employees
    employees = [
        Employee("Alice"),
        Employee("Bob"),
        Employee("Carol"),
        Employee("Dave"),
    ]

    # Give everyone full availability so the demo produces a complete rota
    for emp in employees:
        for day in Weekday:
            emp.set_final_avail_range(day, 0, 23, Availability.YES)

    # 3. Assign: for each shift, pick the first available employee
    for shift in schedule.shifts:
        if shift.assigned_employees:
            continue
        for emp in employees:
            if _is_available(emp, shift):
                schedule.assign(emp, shift)
                break

    # Print result
    for shift in schedule.shifts:
        assigned = shift.assigned_employees
        label = assigned[0].name if assigned else "UNFILLED"
        print(f"{shift.dt_start.date()}  {shift.frame:<22}  {label}")


if __name__ == "__main__":
    main()
