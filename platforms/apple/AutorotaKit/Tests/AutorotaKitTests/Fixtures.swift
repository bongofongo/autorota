import AutorotaKit

/// Shared factory functions for test data.
enum Fixtures {
    static func employee(
        firstName: String = "Alice",
        lastName: String = "Smith",
        nickname: String? = nil,
        role: String = "Barista",
        startDate: String = "2026-01-01"
    ) -> FfiEmployee {
        let avail = (7...11).map { h in
            AvailabilitySlot(weekday: "Mon", hour: UInt8(h), state: "Yes")
        }
        return FfiEmployee(
            id: 0,
            firstName: firstName,
            lastName: lastName,
            nickname: nickname,
            displayName: "",
            roles: [role],
            startDate: startDate,
            targetWeeklyHours: 40.0,
            weeklyHoursDeviation: 6.0,
            maxDailyHours: 8.0,
            notes: nil,
            bankDetails: nil,
            hourlyWage: nil,
            wageCurrency: nil,
            defaultAvailability: avail,
            availability: avail,
            deleted: false
        )
    }

    static func shiftTemplate(
        name: String = "Morning",
        weekdays: [String] = ["Mon"],
        startTime: String = "07:00",
        endTime: String = "12:00",
        role: String = "Barista"
    ) -> FfiShiftTemplate {
        FfiShiftTemplate(
            id: 0,
            name: name,
            weekdays: weekdays,
            startTime: startTime,
            endTime: endTime,
            requiredRole: role,
            minEmployees: 1,
            maxEmployees: 1,
            deleted: false
        )
    }
}
