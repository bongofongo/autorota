from datetime import datetime, timedelta, date


def getNextMonday() -> date:
    today = datetime.today().date()
    return today + timedelta(days=(7 - today.weekday()))


def iterNextWeek():
    cur_day = getNextMonday()
    return (cur_day + timedelta(days=i) for i in range(7))
