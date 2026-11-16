import Foundation

/// A shared wall-clock scale for the columns in a day or week view.
public struct CalendarTimeline {
    public let startMinute: Int
    public let endMinute: Int

    public init(days: [Date], meetings: [Meeting], workdayHours: Range<Int>?, calendar: Calendar) {
        guard let workdayHours, !workdayHours.isEmpty,
              workdayHours.lowerBound >= 0, workdayHours.upperBound <= 24 else {
            startMinute = 0
            endMinute = 24 * 60
            return
        }
        var start = workdayHours.lowerBound * 60
        var end = workdayHours.upperBound * 60
        for day in days {
            for event in Self.events(meetings, on: day, calendar: calendar) {
                start = min(start, Int(event.start.rounded(.down)))
                end = max(end, min(24 * 60, max(Int(event.start.rounded(.down)) + 1, Int(event.end.rounded(.up)))))
            }
        }
        startMinute = start
        endMinute = end
    }

    public var duration: Int { endMinute - startMinute }

    public var ticks: [Int] {
        let hours = stride(from: 0, through: 24 * 60, by: 60)
        return [startMinute] + hours.filter { $0 - startMinute >= 15 && endMinute - $0 >= 15 } + [endMinute]
    }

    public func minute(of date: Date, on day: Date, calendar: Calendar) -> Double {
        guard let bounds = calendar.dateInterval(of: .day, for: day) else { return 0 }
        return Self.minute(of: date, within: bounds, calendar: calendar)
    }

    public func date(at minute: Double, on day: Date, calendar: Calendar) -> Date? {
        let rounded = Int(minute / 15) * 15
        let chosen = min(endMinute - 1, max(startMinute, rounded))
        guard let date = calendar.date(bySettingHour: chosen / 60, minute: chosen % 60, second: 0, of: day,
                                       matchingPolicy: .nextTimePreservingSmallerComponents),
              calendar.isDate(date, inSameDayAs: day),
              self.minute(of: date, on: day, calendar: calendar) < Double(endMinute) else { return nil }
        return date
    }

    public struct Placement: Identifiable {
        public let meeting: Meeting
        public let startMinute: Double
        public let endMinute: Double
        public let column: Int
        public let columnCount: Int
        public var id: String { meeting.id }
    }

    public func placements(_ meetings: [Meeting], on day: Date, calendar: Calendar,
                           minimumVisibleMinutes: Double) -> [Placement] {
        let lower = Double(startMinute), upper = Double(endMinute)
        let minimum = min(upper - lower, max(0, minimumVisibleMinutes))
        let events = Self.events(meetings, on: day, calendar: calendar).compactMap { event -> VisibleEvent? in
            guard event.start < upper, event.end >= lower else { return nil }
            let start = min(upper - minimum, max(lower, event.start))
            return VisibleEvent(meeting: event.meeting, start: start, end: min(upper, max(event.end, start + minimum)))
        }.sorted { $0.start == $1.start ? $0.meeting.id < $1.meeting.id : $0.start < $1.start }
        return CalendarLayout.lanes(events, start: \.start, end: \.end).map { item in
            Placement(meeting: item.event.meeting, startMinute: item.event.start, endMinute: item.event.end,
                      column: item.column, columnCount: item.columnCount)
        }
    }

    private struct VisibleEvent {
        let meeting: Meeting
        let start: Double
        let end: Double
    }

    private static func events(_ meetings: [Meeting], on day: Date, calendar: Calendar) -> [VisibleEvent] {
        guard let bounds = calendar.dateInterval(of: .day, for: day) else { return [] }
        let zone = calendar.timeZone
        let clockBack = zone.nextDaylightSavingTimeTransition(after: bounds.start).flatMap { transition -> (Date, Int)? in
            let shift = zone.secondsFromGMT(for: transition.addingTimeInterval(-1)) - zone.secondsFromGMT(for: transition)
            return shift > 0 && transition < bounds.end ? (transition, shift) : nil
        }
        return meetings.compactMap { meeting in
            guard !meeting.allDay, !meeting.cancelled,
                  CalendarLayout.intersects(meeting, range: bounds.start..<bounds.end) else { return nil }
            let start = max(meeting.start, bounds.start)
            let end = min(max(meeting.end, start), bounds.end)
            var first = minute(of: start, within: bounds, calendar: calendar)
            var last = minute(of: end, within: bounds, calendar: calendar)
            // The repeated wall-clock hour shares its row with the other days.
            // Cover both portions of a meeting that crosses the rollback.
            if let (transition, shift) = clockBack, start < transition, transition <= end {
                let repeated = minute(of: transition, within: bounds, calendar: calendar)
                if transition < end { first = min(first, repeated) }
                last = max(last, repeated + Double(shift) / 60)
            }
            return VisibleEvent(meeting: meeting, start: first, end: max(first, last))
        }
    }

    private static func minute(of date: Date, within day: DateInterval, calendar: Calendar) -> Double {
        if date >= day.end { return 24 * 60 }
        if date < day.start { return 0 }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
    }
}
