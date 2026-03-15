from autorota.employee import Employee, Weekday, Availability

jim = Employee("Jim")
print(jim)
jim.default_avail.show()

jim.set_final_avail_range(Weekday.MONDAY, 14, 17, Availability.YES)
jim.final_avail.show()
