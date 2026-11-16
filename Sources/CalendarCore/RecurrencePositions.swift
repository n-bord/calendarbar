import Foundation

/// Applies BYSETPOS to the complete candidate set of each recurrence period.
/// Range trimming and COUNT must happen after this selection.
enum RecurrencePositions {
    static func select(_ candidates: [Date], positions: [Int], calendar: Calendar,
                       unit: Calendar.Component) throws -> [Date] {
        let sorted = Array(Set(candidates)).sorted()
        if positions.isEmpty { return sorted }
        var buckets: [Date: [Date]] = [:]
        for date in sorted {
            guard let period = calendar.dateInterval(of: unit, for: date) else {
                throw CalendarError.message("Не удалось определить период повторения встречи.")
            }
            buckets[period.start, default: []].append(date)
        }
        var selected = Set<Date>()
        for dates in buckets.values {
            for position in positions {
                let index = position > 0 ? position - 1 : dates.count + position
                if position != 0, dates.indices.contains(index) { selected.insert(dates[index]) }
            }
        }
        return selected.sorted()
    }
}
