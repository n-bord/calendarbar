import Foundation

public struct TimedPlacement: Identifiable {
    public let meeting: Meeting
    public let start: Date
    public let end: Date
    public let column: Int
    public let columnCount: Int
    public var id: String { meeting.id }
}

public enum CalendarLayout {
    public static func intersects(_ meeting: Meeting, range: Range<Date>) -> Bool {
        meeting.start < range.upperBound && (meeting.end > range.lowerBound || range.contains(meeting.start))
    }

    /// Split overlapping intervals into lanes, using half-open time ranges.
    public static func placements(_ meetings: [Meeting], day: Date, calendar: Calendar,
                                  minimumVisibleDuration: TimeInterval = 0) -> [TimedPlacement] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let events = meetings.filter { !$0.allDay && intersects($0, range: start..<end) }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }.map { meeting in
                let lower = max(start, meeting.start), upper = min(end, max(meeting.start, meeting.end))
                let visibleEnd = min(end, max(upper, lower.addingTimeInterval(minimumVisibleDuration)))
                return (meeting: meeting, start: lower, end: upper, visibleEnd: visibleEnd)
            }
        return lanes(events, start: { $0.start }, end: { $0.visibleEnd }).map { item in
            TimedPlacement(meeting: item.event.meeting, start: item.event.start, end: item.event.end,
                           column: item.column, columnCount: item.columnCount)
        }
    }

    static func lanes<Event, Position: Comparable>(_ events: [Event], start: (Event) -> Position,
                                                   end: (Event) -> Position) -> [(event: Event, column: Int, columnCount: Int)] {
        var result: [(event: Event, column: Int, columnCount: Int)] = []
        var cluster: [(event: Event, column: Int)] = []
        var laneEnds: [Position] = []
        func flush() {
            result += cluster.map { ($0.event, $0.column, laneEnds.count) }
            cluster.removeAll(keepingCapacity: true)
            laneEnds.removeAll(keepingCapacity: true)
        }
        for event in events {
            let lower = start(event), visibleEnd = end(event)
            if let clusterEnd = laneEnds.max(), lower >= clusterEnd { flush() }
            let lane = laneEnds.firstIndex(where: { $0 <= lower }) ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(visibleEnd) } else { laneEnds[lane] = visibleEnd }
            cluster.append((event, lane))
        }
        flush()
        return result
    }
}
