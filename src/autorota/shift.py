from datetime import date, datetime, timedelta, time


class PShift:
    start_hour: int
    end_hour: int

    def __init__(self, start, end):
        self.start_hour, self.end_hour = start, end

    def toShift(self, date: date):
        return Shift(self.start_hour, self.end_hour, date)


class Shift:
    start_hour: int
    end_hour: int
    duration: int

    dt_start: datetime
    dt_duration: timedelta

    def __init__(self, start, end, date: date):
        self.start_hour, self.end_hour = start, end
        self.duration = end - start

        self.dt_start = datetime.combine(date, time(hour=self.start_hour))
        self.dt_duration = timedelta(hours=self.duration)

    def __repr__(self):
        return "( %r: %r, %r )" % (
            self.dt_start.date().isoformat(),
            self.start_hour,
            self.end_hour,
        )

    def showHours(self):
        def toPm(hour):
            return f"{hour % 12}" if hour > 12 else f"{hour}"

        start, end = toPm(self.start_hour), toPm(self.end_hour)
        return f"({start}, {end})"
