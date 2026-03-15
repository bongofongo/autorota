from autorota.utils import getNextMonday, iterNextWeek
from autorota.employee import Employee
from autorota.rota import Rota
import autorota.tiebreak as tiebreak


emps = [Employee("john"), Employee("jeff"), Employee("ted"), Employee("yule")]
# shop = Shop(emps)
rota = Rota(getNextMonday(), 7, emps)
for employee in emps:
    for day in iterNextWeek():
        for shift in rota.shift_schedule[day]:
            employee.set_random_avail("DEFAULT")

print(rota.getPossibleRota([tiebreak.sortByPreference]))
