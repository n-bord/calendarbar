import XCTest
@testable import CalendarCore

final class CalendarLayoutTests: XCTestCase {
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    func meeting(_ id: String, _ start: String, _ end: String) -> Meeting {
        Meeting(id: id, seriesID: id, calendarID: "c", calendarName: "c", title: id,
            start: date(start), end: date(end), allDay: false, details: "", location: "", link: nil,
            attendees: [], organizer: "", cancelled: false)
    }

    func testOverlapsUseSeparateLanesButTouchingEventsDoNot() {
        let events = [meeting("a", "2026-10-21T09:00:00Z", "2026-10-21T10:00:00Z"),
                      meeting("b", "2026-10-21T09:30:00Z", "2026-10-21T10:30:00Z"),
                      meeting("c", "2026-10-21T10:30:00Z", "2026-10-21T11:00:00Z")]
        let items = CalendarLayout.placements(events, day: date("2026-10-21T00:00:00Z"), calendar: calendar)
        XCTAssertEqual(items.map(\.columnCount), [2, 2, 1])
        XCTAssertNotEqual(items[0].column, items[1].column)
    }

    func testShortCardsUseSeparateLanesWithoutChangingEventTimes() {
        let first = meeting("a", "2026-10-21T09:00:00Z", "2026-10-21T09:05:00Z")
        let second = meeting("b", "2026-10-21T09:05:00Z", "2026-10-21T09:15:00Z")
        let items = CalendarLayout.placements([first, second], day: first.start, calendar: calendar,
            minimumVisibleDuration: 18 * 60)

        XCTAssertEqual(items.map(\.columnCount), [2, 2])
        XCTAssertNotEqual(items[0].column, items[1].column)
        XCTAssertEqual(items.map(\.end), [first.end, second.end])
    }

    func testOvernightEventIsClippedToEachDay() {
        let event = meeting("night", "2026-10-21T23:30:00Z", "2026-10-22T01:00:00Z")
        let midnight = date("2026-10-22T00:00:00Z")
        let before = CalendarLayout.placements([event], day: event.start, calendar: calendar)
        let after = CalendarLayout.placements([event], day: midnight, calendar: calendar)
        XCTAssertEqual(before.first?.end, midnight)
        XCTAssertEqual(after.first?.start, midnight)
    }

    func testCompactTimelineExtendsToVisibleEventsAndPreservesFullDayOption() {
        let early = meeting("early", "2026-10-21T07:45:00Z", "2026-10-21T08:10:00Z")
        let late = meeting("late", "2026-10-22T20:00:00Z", "2026-10-22T20:30:00Z")
        let outside = meeting("outside", "2026-10-23T05:00:00Z", "2026-10-23T23:00:00Z")
        let days = [early.start, late.start]
        let compact = CalendarTimeline(days: days, meetings: [early, late, outside], workdayHours: 9..<18, calendar: calendar)
        XCTAssertEqual(compact.startMinute, 465)
        XCTAssertEqual(compact.endMinute, 1230)
        XCTAssertEqual(compact.ticks.first, 465)
        XCTAssertEqual(compact.ticks.last, 1230)
        XCTAssertEqual(compact.date(at: 480, on: early.start, calendar: calendar), date("2026-10-21T08:00:00Z"))
        let full = CalendarTimeline(days: days, meetings: [early, late], workdayHours: nil, calendar: calendar)
        XCTAssertEqual(full.duration, 1440)
    }

    func testOvernightTimelineExtendsToMidnightOnlyForTheVisibleDay() {
        let event = meeting("overnight", "2026-10-21T23:55:00Z", "2026-10-22T00:10:00Z")
        let evening = CalendarTimeline(days: [event.start], meetings: [event], workdayHours: 9..<18, calendar: calendar)
        let morning = CalendarTimeline(days: [event.end], meetings: [event], workdayHours: 9..<18, calendar: calendar)
        XCTAssertEqual(evening.startMinute, 540)
        XCTAssertEqual(evening.endMinute, 1440)
        XCTAssertEqual(morning.startMinute, 0)
        XCTAssertEqual(morning.endMinute, 1080)
        let card = evening.placements([event], on: event.start, calendar: calendar, minimumVisibleMinutes: 18).first
        XCTAssertEqual(card?.endMinute, 1440)
        XCTAssertEqual(card?.startMinute, 1422)
    }

    func testOldCalendarMetadataDecodesWithoutPrivilegeField() throws {
        let old = Data("{\"id\":\"c\",\"name\":\"Рабочий\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(CalendarInfo.self, from: old).canCreate)
    }
}
