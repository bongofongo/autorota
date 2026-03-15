from autorota.shift import PShift
from datetime import datetime

pshift1 = PShift(5, 10)
shift1 = pshift1.toShift(datetime.today())

print(shift1)
