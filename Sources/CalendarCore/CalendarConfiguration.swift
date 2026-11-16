import Foundation

public enum CalendarRefreshInterval: Int, CaseIterable {
    case oneMinute = 1, threeMinutes = 3, fiveMinutes = 5, tenMinutes = 10, fifteenMinutes = 15
    case thirtyMinutes = 30, oneHour = 60, twoHours = 120

    public static let recommended: Self = .fiveMinutes
    public static let workdayOptions: [Self] = [.oneMinute, .threeMinutes, .fiveMinutes, .tenMinutes, .fifteenMinutes]
    public static let outsideWorkdayOptions: [Self] = [.fifteenMinutes, .thirtyMinutes, .oneHour, .twoHours]
    public static let outsideWorkdayDefault: Self = .thirtyMinutes
    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }

    public func isDue(after lastAttempt: Date?, at now: Date) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed < 0 || elapsed >= seconds
    }
}

public struct CalendarRefreshSchedule {
    public let duringWorkday: CalendarRefreshInterval
    public let outsideWorkday: CalendarRefreshInterval?
    public let startHour: Int
    public let endHour: Int

    public init(duringWorkday: CalendarRefreshInterval, outsideWorkday: CalendarRefreshInterval?,
                startHour: Int, endHour: Int) {
        self.duringWorkday = duringWorkday
        self.outsideWorkday = outsideWorkday
        self.startHour = startHour
        self.endHour = endHour
    }

    public func interval(at date: Date, calendar: Calendar) -> CalendarRefreshInterval? {
        isWorkingTime(date, calendar: calendar) ? duringWorkday : outsideWorkday
    }

    public func nextCheck(after now: Date, lastAttempt: Date?, calendar: Calendar,
                          retryDelay: TimeInterval = 0) -> Date? {
        let boundary = nextBoundary(after: now, calendar: calendar)
        guard let interval = interval(at: now, calendar: calendar) else { return boundary }
        let due = lastAttempt.map { min($0, now).addingTimeInterval(interval.seconds) } ?? now
        let check = max(now.addingTimeInterval(retryDelay), due)
        return boundary.map { min(check, $0) } ?? check
    }

    private func isWorkingTime(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        return (2...6).contains(parts.weekday ?? 0) && (startHour..<endHour).contains(parts.hour ?? -1)
    }

    private func nextBoundary(after now: Date, calendar: Calendar) -> Date? {
        if isWorkingTime(now, calendar: calendar) {
            return nextHour(endHour % 24, after: now, calendar: calendar)
        }
        var cursor = now
        // At most two weekend starts can precede the next weekday.
        for _ in 0..<3 {
            guard let start = nextHour(startHour, after: cursor, calendar: calendar) else { return nil }
            if (2...6).contains(calendar.component(.weekday, from: start)) { return start }
            cursor = start
        }
        return nil
    }

    private func nextHour(_ hour: Int, after date: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: 0, second: 0),
                          matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }
}

public enum MenuMeetingsMode: String, CaseIterable, Codable, Hashable {
    case currentAndUpcoming, allToday, upcomingOnly, currentOnly

    public var title: String {
        switch self {
        case .currentAndUpcoming: return "Текущие и предстоящие"
        case .allToday: return "Все встречи сегодня"
        case .upcomingOnly: return "Только предстоящие"
        case .currentOnly: return "Только текущие"
        }
    }

    public var explanation: String {
        switch self {
        case .currentAndUpcoming: return "Встречи остаются в меню до времени окончания. Также показаны ближайшие встречи."
        case .allToday: return "Все встречи за сегодняшний день, включая прошедшие. Их ссылки остаются доступны для повторного подключения."
        case .upcomingOnly: return "Только встречи, которые ещё не начались, на ближайшие 14 дней."
        case .currentOnly: return "Только встречи, которые идут сейчас по расписанию, и события на весь день."
        }
    }
}

public enum MenuCountdownWindow: Int, CaseIterable, Codable, Hashable {
    case hidden = 0, fifteenMinutes = 15, thirtyMinutes = 30, oneHour = 60, threeHours = 180

    public var title: String {
        switch self {
        case .hidden: return "Не показывать"
        case .fifteenMinutes: return "За 15 минут"
        case .thirtyMinutes: return "За 30 минут"
        case .oneHour: return "За 1 час"
        case .threeHours: return "За 3 часа"
        }
    }

    public func label(start: Date, now: Date) -> String {
        guard self != .hidden else { return "" }
        let remaining = start.timeIntervalSince(now)
        if remaining <= 0 { return "идёт встреча" }
        guard remaining <= Double(rawValue * 60) else { return "" }
        let minutes = Int(ceil(remaining / 60))
        if minutes < 60 { return "\(minutes) мин" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) ч" : "\(hours) ч \(rest) мин"
    }
}

public struct CalendarConfiguration: Codable, Equatable {
    public static let reminderRange = 1...1440
    public var login = ""
    public var zone = "Europe/Moscow"
    public var calendarIDs: [String] = []
    public var notifyNew = true
    public var notifyChanges = true
    public var firstReminderEnabled = true
    public var firstReminderMinutes = 15
    public var secondReminderEnabled = true
    public var secondReminderMinutes = 5
    public var notifyMinorChanges = false
    public var workdayStartHour = 9
    public var workdayEndHour = 18
    public var dailyOverviewEnabled = false
    public var dailyOverviewHour = 9
    public var dailyOverviewMinute = 0
    public var menuCountdownWindow = MenuCountdownWindow.oneHour
    public var menuMeetingsMode = MenuMeetingsMode.currentAndUpcoming

    public init() {}

    public var reminderMinutes: [Int] {
        let values = [(firstReminderEnabled, firstReminderMinutes), (secondReminderEnabled, secondReminderMinutes)]
        return Set<Int>(values.compactMap { enabled, minutes in
            enabled && Self.reminderRange.contains(minutes) ? minutes : nil
        }).sorted(by: >)
    }

    public func nextDailyOverview(after now: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(after: now,
            matching: DateComponents(hour: dailyOverviewHour, minute: dailyOverviewMinute, second: 0),
            matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first)
    }

    private enum CodingKeys: String, CodingKey {
        case login, zone, calendarIDs, notifyNew, notifyChanges, reminders, notifyMinorChanges, workdayStartHour, workdayEndHour, dailyOverviewEnabled, dailyOverviewHour
        case dailyOverviewMinute
        case firstReminderEnabled, firstReminderMinutes, secondReminderEnabled, secondReminderMinutes, menuCountdownMinutes, menuMeetingsMode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        login = try values.decodeIfPresent(String.self, forKey: .login) ?? ""
        zone = try values.decodeIfPresent(String.self, forKey: .zone) ?? "Europe/Moscow"
        calendarIDs = try values.decodeIfPresent([String].self, forKey: .calendarIDs) ?? []
        notifyNew = try values.decodeIfPresent(Bool.self, forKey: .notifyNew) ?? true
        notifyChanges = try values.decodeIfPresent(Bool.self, forKey: .notifyChanges) ?? true
        notifyMinorChanges = try values.decodeIfPresent(Bool.self, forKey: .notifyMinorChanges) ?? false
        workdayStartHour = min(max((try? values.decode(Int.self, forKey: .workdayStartHour)) ?? 9, 0), 23)
        workdayEndHour = min(max((try? values.decode(Int.self, forKey: .workdayEndHour)) ?? 18, workdayStartHour + 1), 24)
        dailyOverviewEnabled = try values.decodeIfPresent(Bool.self, forKey: .dailyOverviewEnabled) ?? false
        dailyOverviewHour = min(max((try? values.decode(Int.self, forKey: .dailyOverviewHour)) ?? 9, 0), 23)
        dailyOverviewMinute = min(max((try? values.decode(Int.self, forKey: .dailyOverviewMinute)) ?? 0, 0), 59)
        let legacyEnabled = try values.decodeIfPresent(Bool.self, forKey: .reminders) ?? true
        firstReminderEnabled = (try? values.decode(Bool.self, forKey: .firstReminderEnabled)) ?? legacyEnabled
        secondReminderEnabled = (try? values.decode(Bool.self, forKey: .secondReminderEnabled)) ?? legacyEnabled
        let first = (try? values.decode(Int.self, forKey: .firstReminderMinutes)) ?? 15
        let second = (try? values.decode(Int.self, forKey: .secondReminderMinutes)) ?? 5
        firstReminderMinutes = min(max(first, Self.reminderRange.lowerBound), Self.reminderRange.upperBound)
        secondReminderMinutes = min(max(second, Self.reminderRange.lowerBound), Self.reminderRange.upperBound)
        let window = (try? values.decode(Int.self, forKey: .menuCountdownMinutes)) ?? 60
        menuCountdownWindow = MenuCountdownWindow(rawValue: window) ?? .oneHour
        menuMeetingsMode = (try? values.decode(MenuMeetingsMode.self, forKey: .menuMeetingsMode)) ?? .currentAndUpcoming
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(login, forKey: .login)
        try values.encode(zone, forKey: .zone)
        try values.encode(calendarIDs, forKey: .calendarIDs)
        try values.encode(notifyNew, forKey: .notifyNew)
        try values.encode(notifyChanges, forKey: .notifyChanges)
        try values.encode(notifyMinorChanges, forKey: .notifyMinorChanges)
        try values.encode(workdayStartHour, forKey: .workdayStartHour)
        try values.encode(workdayEndHour, forKey: .workdayEndHour)
        try values.encode(dailyOverviewEnabled, forKey: .dailyOverviewEnabled)
        try values.encode(dailyOverviewHour, forKey: .dailyOverviewHour)
        try values.encode(dailyOverviewMinute, forKey: .dailyOverviewMinute)
        // Keep the old key so older versions can still read this account.
        try values.encode(firstReminderEnabled || secondReminderEnabled, forKey: .reminders)
        try values.encode(firstReminderEnabled, forKey: .firstReminderEnabled)
        try values.encode(firstReminderMinutes, forKey: .firstReminderMinutes)
        try values.encode(secondReminderEnabled, forKey: .secondReminderEnabled)
        try values.encode(secondReminderMinutes, forKey: .secondReminderMinutes)
        try values.encode(menuCountdownWindow.rawValue, forKey: .menuCountdownMinutes)
        try values.encode(menuMeetingsMode, forKey: .menuMeetingsMode)
    }
}
