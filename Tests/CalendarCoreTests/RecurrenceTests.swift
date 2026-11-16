import XCTest
@testable import CalendarCore

final class RecurrenceTests: XCTestCase {
    let calendar = CalendarInfo(id: "work", name: "Рабочий")
    let utc = TimeZone(secondsFromGMT: 0)!
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func parse(_ events: String, from: String = "2026-10-20T00:00:00Z", to: String = "2026-11-03T00:00:00Z",
               zone: TimeZone? = nil) throws -> [Meeting] {
        try ICalendar.parse("BEGIN:VCALENDAR\nVERSION:2.0\n\(events)\nEND:VCALENDAR", calendar: calendar,
            fallbackZone: zone ?? utc, range: date(from)..<date(to))
    }
    func needsNativeRecurrence() throws {
        #if compiler(>=6.0) && os(macOS)
        if #available(macOS 15.0, *) { return }
        #endif
        throw XCTSkip("Native recurrence tests require macOS 15+ and Xcode 16+")
    }
    func master(_ rule: String, start: String = "20261021T100000Z", extra: String = "") -> String {
        """
        BEGIN:VEVENT
        UID:series
        SUMMARY:Планёрка
        DTSTART:\(start)
        DURATION:PT30M
        RRULE:\(rule)
        \(extra)
        END:VEVENT
        """
    }

    func testDailyCountExdateAndRdate() throws {
        try needsNativeRecurrence()
        let meetings = try parse(master("FREQ=DAILY;COUNT=3", extra: "EXDATE:20261022T100000Z\nRDATE:20261024T100000Z"))
        XCTAssertEqual(meetings.map(\.start), [date("2026-10-21T10:00:00Z"), date("2026-10-23T10:00:00Z"), date("2026-10-24T10:00:00Z")])
    }

    func testWeeklyWeekdaysAndInterval() throws {
        try needsNativeRecurrence()
        let meetings = try parse(master("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;WKST=MO;COUNT=4", start: "20261019T100000Z"),
            from: "2026-10-19T00:00:00Z", to: "2026-11-05T00:00:00Z")
        XCTAssertEqual(meetings.map(\.start), [date("2026-10-19T10:00:00Z"), date("2026-10-21T10:00:00Z"),
            date("2026-11-02T10:00:00Z"), date("2026-11-04T10:00:00Z")])
    }

    func testMonthlyLastBusinessDay() throws {
        try needsNativeRecurrence()
        let meetings = try parse(master("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", start: "20260930T100000Z"),
            from: "2026-10-01T00:00:00Z", to: "2026-12-01T00:00:00Z")
        XCTAssertEqual(meetings.map(\.start), [date("2026-10-30T10:00:00Z"), date("2026-11-30T10:00:00Z")])
    }

    func testMonthlyPositionDoesNotChangeForPartialQueryWindow() throws {
        try needsNativeRecurrence()
        let meetings = try parse(master("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", start: "20260930T100000Z"),
            from: "2026-10-01T00:00:00Z", to: "2026-10-15T00:00:00Z")
        XCTAssertTrue(meetings.isEmpty, "The query window must not create a new last business day in mid-month")
    }

    func testMonthlyPositionCountAppliesAfterSelectingPeriod() throws {
        try needsNativeRecurrence()
        let meetings = try parse(master("FREQ=MONTHLY;COUNT=2;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", start: "20260930T100000Z"),
            from: "2026-10-01T00:00:00Z", to: "2026-12-01T00:00:00Z")
        XCTAssertEqual(meetings.map(\.start), [date("2026-10-30T10:00:00Z")])
    }

    func testMonthlyPositionUntilDoesNotCreateMidMonthOccurrence() throws {
        try needsNativeRecurrence()
        let meetings = try parse(master("FREQ=MONTHLY;UNTIL=20261015T235959Z;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", start: "20260930T100000Z"),
            from: "2026-10-01T00:00:00Z", to: "2026-11-01T00:00:00Z")
        XCTAssertTrue(meetings.isEmpty)
    }

    func testPositivePositionUsesFullMonth() throws {
        try needsNativeRecurrence()
        let meetings = try parse(master("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1", start: "20260901T100000Z"),
            from: "2026-10-10T00:00:00Z", to: "2026-11-03T00:00:00Z")
        XCTAssertEqual(meetings.map(\.start), [date("2026-11-02T10:00:00Z")])
    }

    func testDailyPositionSelectsLastTimeBeforeApplyingCount() throws {
        try needsNativeRecurrence()
        let meetings = try parse(master("FREQ=DAILY;COUNT=3;BYHOUR=9,17;BYSETPOS=-1", start: "20261021T170000Z"))
        XCTAssertEqual(meetings.map(\.start), [date("2026-10-21T17:00:00Z"), date("2026-10-22T17:00:00Z"), date("2026-10-23T17:00:00Z")])
    }

    func testUntilIsInclusive() throws {
        try needsNativeRecurrence()
        let meetings = try parse(master("FREQ=DAILY;UNTIL=20261023T100000Z"))
        XCTAssertEqual(meetings.count, 3)
        XCTAssertEqual(meetings.last?.start, date("2026-10-23T10:00:00Z"))
    }

    func testMovedOverrideReplacesOneInstanceAndInheritsDetails() throws {
        try needsNativeRecurrence()
        let text = master("FREQ=DAILY;COUNT=3", extra: "DESCRIPTION:Общее описание") + "\n" + """
        BEGIN:VEVENT
        UID:series
        RECURRENCE-ID:20261022T100000Z
        DTSTART:20261022T120000Z
        DURATION:PT1H
        SUMMARY:Перенос
        END:VEVENT
        """
        let meetings = try parse(text)
        XCTAssertEqual(meetings.count, 3)
        let moved = try XCTUnwrap(meetings.first { $0.title == "Перенос" })
        XCTAssertEqual(moved.start, date("2026-10-22T12:00:00Z"))
        XCTAssertEqual(moved.end.timeIntervalSince(moved.start), 3600)
        XCTAssertEqual(moved.details, "Общее описание")
        XCTAssertTrue(moved.id.hasSuffix(String(date("2026-10-22T10:00:00Z").timeIntervalSince1970)))
    }

    func testCancelledOverrideWithoutStartIsPreserved() throws {
        try needsNativeRecurrence()
        let meetings = try parse(master("FREQ=DAILY;COUNT=3") + "\n" + """
        BEGIN:VEVENT
        UID:series
        RECURRENCE-ID:20261022T100000Z
        STATUS:CANCELLED
        END:VEVENT
        """)
        XCTAssertEqual(meetings.count, 3)
        XCTAssertEqual(meetings.filter(\.cancelled).map(\.start), [date("2026-10-22T10:00:00Z")])
    }

    func testTimezonePreservesWallTimeAcrossDaylightSaving() throws {
        try needsNativeRecurrence()
        let text = master("FREQ=DAILY;COUNT=3", start: "20261024T090000")
            .replacingOccurrences(of: "DTSTART:", with: "DTSTART;TZID=Europe/Paris:")
        let meetings = try parse(text, from: "2026-10-24T00:00:00Z", to: "2026-10-27T00:00:00Z")
        XCTAssertEqual(meetings.map(\.start), [date("2026-10-24T07:00:00Z"), date("2026-10-25T08:00:00Z"), date("2026-10-26T08:00:00Z")])
    }

    func testAllDayKeepsCalendarDayLengthAcrossDaylightSaving() throws {
        try needsNativeRecurrence()
        let meetings = try parse("""
        BEGIN:VEVENT
        UID:day
        DTSTART;VALUE=DATE:20261024
        RRULE:FREQ=DAILY;COUNT=3
        END:VEVENT
        """, from: "2026-10-23T00:00:00Z", to: "2026-10-27T00:00:00Z", zone: TimeZone(identifier: "Europe/Paris")!)
        XCTAssertEqual(meetings.count, 3)
        XCTAssertTrue(meetings.allSatisfy(\.allDay))
        XCTAssertEqual(meetings[1].end.timeIntervalSince(meetings[1].start), 25 * 3600)
    }

    func testThisAndFutureMovesFollowingInstances() throws {
        try needsNativeRecurrence()
        let meetings = try parse(master("FREQ=DAILY;COUNT=4") + "\n" + """
        BEGIN:VEVENT
        UID:series
        RECURRENCE-ID;RANGE=THISANDFUTURE:20261022T100000Z
        DTSTART:20261022T110000Z
        SUMMARY:Новое время
        END:VEVENT
        """)
        XCTAssertEqual(meetings.map(\.start), [date("2026-10-21T10:00:00Z"), date("2026-10-22T11:00:00Z"),
            date("2026-10-23T11:00:00Z"), date("2026-10-24T11:00:00Z")])
        XCTAssertEqual(meetings.filter { $0.title == "Новое время" }.count, 3)
    }

    func testOldFiniteSeriesDoesNotRestartAtQueryRange() throws {
        try needsNativeRecurrence()
        let meetings = try parse(master("FREQ=DAILY;COUNT=2", start: "20250101T100000Z"))
        XCTAssertTrue(meetings.isEmpty)
    }

    func testRdateAndExdateWithoutRrule() throws {
        let meetings = try parse("""
        BEGIN:VEVENT
        UID:dates
        DTSTART:20261021T100000Z
        DURATION:PT30M
        RDATE:20261022T100000Z,20261023T100000Z
        EXDATE:20261021T100000Z,20261023T100000Z
        END:VEVENT
        """)
        XCTAssertEqual(meetings.map(\.start), [date("2026-10-22T10:00:00Z")])
    }

    func testMovedExceptionCanEnterRangeFromOldOriginalDate() throws {
        try needsNativeRecurrence()
        let meetings = try parse(master("FREQ=DAILY;COUNT=2", start: "20260901T100000Z") + "\n" + """
        BEGIN:VEVENT
        UID:series
        RECURRENCE-ID:20260901T100000Z
        DTSTART:20261021T100000Z
        END:VEVENT
        """)
        XCTAssertEqual(meetings.map(\.start), [date("2026-10-21T10:00:00Z")])
    }

    func testUnsupportedRuleIsReportedClearly() throws {
        try needsNativeRecurrence()
        XCTAssertThrowsError(try parse(master("FREQ=DAILY;X-UNKNOWN=1"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("X-UNKNOWN"))
        }
    }

    func testOneOffOutsideRangeIsFilteredOut() throws {
        let meetings = try parse("BEGIN:VEVENT\nUID:old\nDTSTART:20250101T100000Z\nEND:VEVENT")
        XCTAssertTrue(meetings.isEmpty)
    }
}
