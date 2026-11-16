import XCTest
@testable import CalendarCore

final class MonthlyRecurrenceTests: XCTestCase {
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    func testAllWeekdaysInMonthAreExpanded() throws {
        let days = (2...6).map { MonthlyRecurrence.Weekday(number: $0, ordinal: nil) }
        let actual = try MonthlyRecurrence.dates(start: date("2026-09-30T10:00:00Z"),
            range: date("2026-10-01T00:00:00Z")..<date("2026-11-01T00:00:00Z"), calendar: calendar,
            interval: 1, months: [], monthDays: [], weekdays: days, hours: [], minutes: [], seconds: [],
            positions: [], count: nil, until: nil)
        XCTAssertEqual(actual.map { calendar.component(.day, from: $0) },
            [1, 2, 5, 6, 7, 8, 9, 12, 13, 14, 15, 16, 19, 20, 21, 22, 23, 26, 27, 28, 29, 30])
    }

    func testMissingDay31IsSkippedWithoutClamping() throws {
        let actual = try MonthlyRecurrence.dates(start: date("2026-01-31T10:00:00Z"),
            range: date("2026-02-01T00:00:00Z")..<date("2026-05-01T00:00:00Z"), calendar: calendar,
            interval: 1, months: [], monthDays: [], weekdays: [], hours: [], minutes: [], seconds: [],
            positions: [], count: nil, until: nil)
        XCTAssertEqual(actual, [date("2026-03-31T10:00:00Z")])
    }

    func testLastFridayUsesWholeMonth() throws {
        let actual = try MonthlyRecurrence.dates(start: date("2026-09-25T10:00:00Z"),
            range: date("2026-10-01T00:00:00Z")..<date("2026-11-01T00:00:00Z"), calendar: calendar,
            interval: 1, months: [], monthDays: [], weekdays: [.init(number: 6, ordinal: -1)],
            hours: [], minutes: [], seconds: [], positions: [], count: nil, until: nil)
        XCTAssertEqual(actual, [date("2026-10-30T10:00:00Z")])
    }

    func testIntervalAndCountUseOriginalSeriesStart() throws {
        let actual = try MonthlyRecurrence.dates(start: date("2026-08-31T10:00:00Z"),
            range: date("2026-10-01T00:00:00Z")..<date("2027-02-01T00:00:00Z"), calendar: calendar,
            interval: 2, months: [], monthDays: [-1], weekdays: [], hours: [], minutes: [], seconds: [],
            positions: [], count: 3, until: nil)
        XCTAssertEqual(actual, [date("2026-10-31T10:00:00Z"), date("2026-12-31T10:00:00Z")])
    }
}
