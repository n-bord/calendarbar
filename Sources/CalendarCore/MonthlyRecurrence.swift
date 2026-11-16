import Foundation

/// Gregorian monthly enumeration without Calendar.RecurrenceRule's monthly BYDAY expansion.
/// Full calendar months are expanded before applying BYSETPOS, COUNT or query bounds.
enum MonthlyRecurrence {
    struct Weekday {
        let number: Int // Calendar numbering: Sunday = 1, Monday = 2, ...
        let ordinal: Int?
    }

    static func dates(start: Date, range: Range<Date>, calendar: Calendar, interval: Int,
                      months: [Int], monthDays: [Int], weekdays: [Weekday], hours: [Int],
                      minutes: [Int], seconds: [Int], positions: [Int], count: Int?, until: Date?) throws -> [Date] {
        guard interval > 0, let origin = calendar.dateInterval(of: .month, for: start)?.start else {
            throw CalendarError.message("Не удалось определить первый месяц повторения.")
        }
        let initial = calendar.dateComponents([.day, .hour, .minute, .second], from: start)
        let possibleHours = hours.isEmpty ? [initial.hour ?? 0] : Array(Set(hours)).sorted()
        let possibleMinutes = minutes.isEmpty ? [initial.minute ?? 0] : Array(Set(minutes)).sorted()
        let possibleSeconds = seconds.isEmpty ? [initial.second ?? 0] : Array(Set(seconds)).sorted()
        let endLimit = min(range.upperBound, until?.addingTimeInterval(0.001) ?? range.upperBound)
        guard start < endLimit else { return [] }
        var index = 0
        if count == nil, range.lowerBound > start,
           let queryMonth = calendar.dateInterval(of: .month, for: range.lowerBound)?.start {
            let difference = calendar.dateComponents([.month], from: origin, to: queryMonth).month ?? 0
            index = max(0, difference / interval)
        }
        var seen = 0
        var result: [Date] = []
        let deadline = Date().addingTimeInterval(3)
        while true {
            guard Date() < deadline, index < 120_000 else {
                throw CalendarError.message("Слишком длительный расчёт месячной серии. Загрузка остановлена.")
            }
            guard let monthStart = calendar.date(byAdding: .month, value: index * interval, to: origin) else {
                throw CalendarError.message("Не удалось вычислить месяц повторения.")
            }
            if monthStart >= endLimit { break }
            index += 1
            let monthNumber = calendar.component(.month, from: monthStart)
            if !months.isEmpty && !months.contains(monthNumber) { continue }
            guard let days = calendar.range(of: .day, in: .month, for: monthStart) else {
                throw CalendarError.message("Не удалось определить дни месяца.")
            }
            let lastDay = days.count
            let requestedDays = Set(monthDays.map { $0 > 0 ? $0 : lastDay + $0 + 1 })
            var candidates: [Date] = []
            for day in days {
                guard let dayStart = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { continue }
                if !requestedDays.isEmpty && !requestedDays.contains(day) { continue }
                if !weekdays.isEmpty {
                    let weekday = calendar.component(.weekday, from: dayStart)
                    let matches = weekdays.contains { request in
                        guard request.number == weekday else { return false }
                        guard let ordinal = request.ordinal else { return true }
                        return ordinal > 0 ? ((day - 1) / 7 + 1 == ordinal) : (-((lastDay - day) / 7 + 1) == ordinal)
                    }
                    if !matches { continue }
                } else if monthDays.isEmpty && day != initial.day { continue }
                for hour in possibleHours {
                    for minute in possibleMinutes {
                        for second in possibleSeconds {
                            guard candidates.count < 50_000, Date() < deadline else {
                                throw CalendarError.message("Слишком много дат в месячной серии.")
                            }
                            guard let candidate = calendar.date(bySettingHour: hour, minute: minute, second: second,
                                of: dayStart, matchingPolicy: .strict, repeatedTimePolicy: .first, direction: .forward) else { continue }
                            // Strict matching may search into the following day for a missing DST time.
                            let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: candidate)
                            guard actual.year == calendar.component(.year, from: monthStart),
                                  actual.month == monthNumber, actual.day == day,
                                  actual.hour == hour, actual.minute == minute, actual.second == second else { continue }
                            candidates.append(candidate)
                        }
                    }
                }
            }
            let selected = try RecurrencePositions.select(candidates, positions: positions, calendar: calendar, unit: .month)
            for candidate in selected {
                if candidate < start { continue }
                if let until, candidate > until { return result }
                seen += 1
                if let count, seen > count { return result }
                if range.contains(candidate) { result.append(candidate) }
                if let count, seen == count { return result }
            }
        }
        return result
    }
}
