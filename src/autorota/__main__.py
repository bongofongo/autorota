# from typing import Annotated
# import typer
#
# app = typer.Typer()

# __main.py__
from autorota.utils import getNextMonday, iterNextWeek
from .employee import Employee
from .rota import Rota
import autorota.tiebreak as tiebreak


# @app.command()
def main():
    emps = [Employee("john"), Employee("jeff"), Employee("ted"), Employee("yule")]
    # shop = Shop(emps)
    rota = Rota(getNextMonday(), 7, emps)
    for employee in emps:
        for day in iterNextWeek():
            for shift in rota.shift_schedule[day]:
                employee.randomPref(shift)

    print(rota.getPossibleRota([tiebreak.sortByPreference]))


if __name__ == "__main__":
    main()
