import Foundation

public struct MenuScheduleDay: Identifiable {
    public let date: Date
    public let meetings: [Meeting]
    public var id: Date { date }

    public static func group(_ meetings: [Meeting], calendar: Calendar) -> [MenuScheduleDay] {
        Dictionary(grouping: meetings, by: { calendar.startOfDay(for: $0.start) })
            .map { date, meetings in
                MenuScheduleDay(date: date, meetings: meetings.sorted {
                    if $0.allDay != $1.allDay { return $0.allDay }
                    return $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
                })
            }.sorted { $0.date < $1.date }
    }

    public func title(relativeTo now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "EEEE, d MMMM" : "EEEE, d MMMM yyyy"
        let text = formatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "Сегодня · " + text }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Завтра · " + text
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Presentation is independent of notification selection and never schedules alerts.
public struct MenuSchedule {
    public let meetings: [Meeting]
    public let ongoing: [Meeting]
    public let next: [Meeting]
    public let laterToday: [Meeting]
    public let allDay: [Meeting]
    public let lastFinished: Meeting?
    public let finished: [Meeting]
    public let later: [Meeting]

    public func highlightedLastMeeting(hiding hidden: FinishedMeetingReference?) -> Meeting? {
        guard let lastFinished, FinishedMeetingReference(lastFinished) != hidden else { return nil }
        return lastFinished
    }

    public init(meetings source: [Meeting], mode: MenuMeetingsMode, visibleCalendarIDs: Set<String>,
                account: String, now: Date, calendar: Calendar, includeFinishedToday: Bool = false) {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let horizon = calendar.date(byAdding: .day, value: 14, to: now)!
        let visible = source.filter {
            visibleCalendarIDs.contains($0.calendarID) && !$0.cancelled &&
                !$0.declined(by: account) && $0.end > $0.start
        }
        let eligible = visible.filter { meeting in
            switch mode {
            case .currentAndUpcoming:
                return (meeting.end > now && meeting.start < horizon) ||
                    (includeFinishedToday && CalendarLayout.intersects(meeting, range: start..<end))
            case .allToday: return CalendarLayout.intersects(meeting, range: start..<end)
            case .upcomingOnly: return meeting.start > now && meeting.start < horizon
            case .currentOnly: return meeting.start <= now && meeting.end > now
            }
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        meetings = eligible
        ongoing = eligible.filter { !$0.allDay && $0.start <= now && $0.end > now }
        let nextStart = eligible.first { !$0.allDay && $0.start > now }?.start
        next = eligible.filter { !$0.allDay && $0.start == nextStart }
        allDay = eligible.filter { $0.allDay && CalendarLayout.intersects($0, range: start..<end) }
        func endedLater(_ lhs: Meeting, _ rhs: Meeting) -> Bool {
            lhs.end == rhs.end ? lhs.id < rhs.id : lhs.end > rhs.end
        }
        let finished = eligible.filter { !$0.allDay && $0.end <= now }.sorted(by: endedLater)
        self.finished = finished
        // The background refresh covers yesterday and today. Use yesterday
        // before the first meeting ends today so the previous link stays handy.
        if includeFinishedToday, finished.isEmpty,
           let yesterday = calendar.date(byAdding: .day, value: -1, to: start) {
            lastFinished = visible.filter { !$0.allDay && $0.end > yesterday && $0.end <= start }
                .min(by: endedLater)
        } else {
            lastFinished = finished.first
        }
        let highlighted = Set((ongoing + next + allDay + finished).map(\.id))
        laterToday = eligible.filter { !highlighted.contains($0.id) && CalendarLayout.intersects($0, range: start..<end) }
        let todayIDs = Set(laterToday.map(\.id))
        later = eligible.filter { !highlighted.contains($0.id) && !todayIDs.contains($0.id) }
    }
}
