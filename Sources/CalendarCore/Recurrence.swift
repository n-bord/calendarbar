import Foundation

/// Converts RFC 5545 rule fields to Foundation's native recurrence engine.
/// RDATE, EXDATE and detached instances are combined by ICalendar.
enum Recurrence {
    static func dates(rule text: String, start: Date, zone: TimeZone, range: Range<Date>) throws -> [Date] {
        #if compiler(>=6.0) && os(macOS)
        if #available(macOS 15.0, *) {
            return try nativeDates(rule: text, start: start, zone: zone, range: range)
        }
        #endif
        throw CalendarError.message("Для локальной обработки повторяющихся встреч нужны macOS 15 или новее и сборка в Xcode 16 или новее.")
    }

    #if compiler(>=6.0) && os(macOS)
    @available(macOS 15.0, *)
    private static func nativeDates(rule text: String, start: Date, zone: TimeZone, range: Range<Date>) throws -> [Date] {
        var fields: [String: String] = [:]
        for part in text.uppercased().split(separator: ";", omittingEmptySubsequences: false) {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[1].isEmpty, fields[String(pair[0])] == nil else {
                throw CalendarError.message("Некорректное правило повторения встречи.")
            }
            fields[String(pair[0])] = String(pair[1])
        }
        let allowed: Set<String> = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "WKST", "BYMONTH", "BYMONTHDAY",
            "BYYEARDAY", "BYWEEKNO", "BYDAY", "BYHOUR", "BYMINUTE", "BYSECOND", "BYSETPOS"]
        if let unsupported = Set(fields.keys).subtracting(allowed).sorted().first {
            throw CalendarError.message("Параметр повторения \(unsupported) пока не поддерживается.")
        }
        let frequency: Calendar.RecurrenceRule.Frequency
        switch fields["FREQ"] {
        case "MINUTELY": frequency = .minutely
        case "HOURLY": frequency = .hourly
        case "DAILY": frequency = .daily
        case "WEEKLY": frequency = .weekly
        case "MONTHLY": frequency = .monthly
        case "YEARLY": frequency = .yearly
        default: throw CalendarError.message("Неизвестная частота повторения: \(fields["FREQ"] ?? "не указана").")
        }
        func integer(_ key: String, default fallback: Int, bounds: ClosedRange<Int>) throws -> Int {
            guard let raw = fields[key] else { return fallback }
            guard let value = Int(raw), bounds.contains(value) else {
                throw CalendarError.message("Некорректный параметр повторения \(key).")
            }
            return value
        }
        func numbers(_ key: String, bounds: ClosedRange<Int>, excludeZero: Bool = false) throws -> [Int] {
            guard let raw = fields[key] else { return [] }
            return try raw.split(separator: ",", omittingEmptySubsequences: false).map {
                guard let value = Int($0), bounds.contains(value), !excludeZero || value != 0 else {
                    throw CalendarError.message("Некорректный параметр повторения \(key).")
                }
                return value
            }
        }
        let weekdays: [String: Locale.Weekday] = ["SU": .sunday, "MO": .monday, "TU": .tuesday,
            "WE": .wednesday, "TH": .thursday, "FR": .friday, "SA": .saturday]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let firstWeekday = fields["WKST"] ?? "MO"
        let weekdayNumbers = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        guard let first = weekdayNumbers[firstWeekday] else { throw CalendarError.message("Некорректное начало недели WKST.") }
        calendar.firstWeekday = first
        calendar.minimumDaysInFirstWeek = 4
        let interval = try integer("INTERVAL", default: 1, bounds: 1...1_000_000)
        var rule = Calendar.RecurrenceRule(calendar: calendar, frequency: frequency, interval: interval)
        rule.matchingPolicy = .strict
        rule.repeatedTimePolicy = .first
        if fields["COUNT"] != nil && fields["UNTIL"] != nil {
            throw CalendarError.message("Правило встречи одновременно содержит COUNT и UNTIL.")
        }
        let occurrenceLimit: Int?
        if fields["COUNT"] != nil {
            occurrenceLimit = try integer("COUNT", default: 1, bounds: 1...1_000_000)
            rule.end = .afterOccurrences(occurrenceLimit!)
        } else { occurrenceLimit = nil }
        var until: Date?
        if let raw = fields["UNTIL"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = raw.hasSuffix("Z") ? TimeZone(secondsFromGMT: 0) : zone
            formatter.isLenient = false
            formatter.dateFormat = raw.count == 8 ? "yyyyMMdd" : (raw.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss")
            guard let last = formatter.date(from: raw) else { throw CalendarError.message("Некорректная граница повторения UNTIL.") }
            until = raw.count == 8 ? calendar.date(byAdding: .day, value: 1, to: last)?.addingTimeInterval(-1) : last
            rule.end = .afterDate(until!.addingTimeInterval(1))
        }
        rule.months = try numbers("BYMONTH", bounds: 1...12).map { Calendar.RecurrenceRule.Month($0) }
        rule.daysOfTheMonth = try numbers("BYMONTHDAY", bounds: -31...31, excludeZero: true)
        rule.daysOfTheYear = try numbers("BYYEARDAY", bounds: -366...366, excludeZero: true)
        rule.weeks = try numbers("BYWEEKNO", bounds: -53...53, excludeZero: true)
        rule.hours = try numbers("BYHOUR", bounds: 0...23)
        rule.minutes = try numbers("BYMINUTE", bounds: 0...59)
        rule.seconds = try numbers("BYSECOND", bounds: 0...59)
        let positions = try numbers("BYSETPOS", bounds: -366...366, excludeZero: true)
        // Native BYSETPOS on the user's macOS produced incorrect monthly dates.
        // Enumerate ordinary candidates and perform positional selection ourselves.
        rule.setPositions = []
        var monthlyWeekdays: [MonthlyRecurrence.Weekday] = []
        if let raw = fields["BYDAY"] {
            rule.weekdays = try raw.split(separator: ",", omittingEmptySubsequences: false).map { token in
                let text = String(token)
                guard text.count >= 2, let day = weekdays[String(text.suffix(2))] else {
                    throw CalendarError.message("Некорректный день недели в повторении BYDAY.")
                }
                let prefix = String(text.dropLast(2))
                if prefix.isEmpty {
                    monthlyWeekdays.append(MonthlyRecurrence.Weekday(number: weekdayNumbers[String(text.suffix(2))]!, ordinal: nil))
                    return .every(day)
                }
                guard let ordinal = Int(prefix), ordinal != 0, (-53...53).contains(ordinal),
                      fields["FREQ"] == "MONTHLY" || fields["FREQ"] == "YEARLY" else {
                    throw CalendarError.message("Некорректный порядковый номер дня BYDAY.")
                }
                monthlyWeekdays.append(MonthlyRecurrence.Weekday(number: weekdayNumbers[String(text.suffix(2))]!, ordinal: ordinal))
                return .nth(ordinal, day)
            }
        }
        if fields["FREQ"] == "WEEKLY", !rule.daysOfTheMonth.isEmpty {
            throw CalendarError.message("BYMONTHDAY нельзя использовать с WEEKLY.")
        }
        if !rule.weeks.isEmpty, fields["FREQ"] != "YEARLY" {
            throw CalendarError.message("BYWEEKNO требует частоты YEARLY.")
        }
        if !rule.daysOfTheYear.isEmpty, ["DAILY", "WEEKLY", "MONTHLY"].contains(fields["FREQ"] ?? "") {
            throw CalendarError.message("BYYEARDAY несовместим с указанной частотой.")
        }
        if fields["FREQ"] == "MONTHLY" {
            return try MonthlyRecurrence.dates(start: start, range: range, calendar: calendar, interval: interval,
                months: rule.months.map(\.index), monthDays: rule.daysOfTheMonth, weekdays: monthlyWeekdays,
                hours: rule.hours, minutes: rule.minutes, seconds: rule.seconds, positions: positions,
                count: occurrenceLimit, until: until)
        }
        if !positions.isEmpty {
            let unit: Calendar.Component
            switch fields["FREQ"] {
            case "YEARLY": unit = .year
            case "MONTHLY": unit = .month
            case "WEEKLY": unit = .weekOfYear
            case "DAILY": unit = .day
            case "HOURLY": unit = .hour
            default: unit = .minute
            }
            // A partial query month must not turn its last visible weekday into
            // the last business day of that month. UNTIL must not truncate the set either.
            let lowerAnchor = occurrenceLimit == nil ? max(start, range.lowerBound) : start
            let upperAnchor = min(range.upperBound.addingTimeInterval(-0.001), until ?? range.upperBound)
            guard upperAnchor >= lowerAnchor,
                  let firstPeriod = calendar.dateInterval(of: unit, for: lowerAnchor),
                  let lastPeriod = calendar.dateInterval(of: unit, for: upperAnchor) else { return [] }
            rule.end = .never
            let wholePeriods = firstPeriod.start..<lastPeriod.end
            var candidates: [Date] = []
            let deadline = Date().addingTimeInterval(3)
            for date in rule.recurrences(of: start, in: wholePeriods) {
                guard candidates.count < 500_000, Date() < deadline else {
                    throw CalendarError.message("Слишком большой набор дат для BYSETPOS. Расчёт остановлен.")
                }
                if wholePeriods.contains(date) { candidates.append(date) }
            }
            var selected = try RecurrencePositions.select(candidates, positions: positions, calendar: calendar, unit: unit)
                .filter { $0 >= start && (until == nil || $0 <= until!) }
            if let occurrenceLimit { selected = Array(selected.prefix(occurrenceLimit)) }
            return selected.filter { range.contains($0) }
        }
        var dates: [Date] = []
        let deadline = Date().addingTimeInterval(3)
        for date in rule.recurrences(of: start, in: range) {
            if let until, date > until { break }
            guard dates.count < 50_000, Date() < deadline else {
                throw CalendarError.message("Правило встречи создаёт слишком много повторов. Расчёт остановлен.")
            }
            if range.contains(date) { dates.append(date) }
        }
        return dates
    }
    #endif
}
