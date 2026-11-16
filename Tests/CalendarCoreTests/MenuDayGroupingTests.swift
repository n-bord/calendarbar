import XCTest
@testable import CalendarCore

final class MenuDayGroupingTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func event(_ id: String, _ start: String, allDay: Bool = false) -> Meeting {
        Meeting(id: id, seriesID: id, calendarID: "work", calendarName: "Рабочий", title: id,
            start: date(start), end: date(start).addingTimeInterval(allDay ? 86400 : 1800), allDay: allDay,
            details: "", location: "", link: nil, attendees: [], organizer: "", cancelled: false)
    }
    func testLaterEventsAreGroupedByDateAndSortedInsideEachDay() {
        let a = event("a", "2026-10-26T09:30:00+03:00"), b = event("b", "2026-10-26T14:45:00+03:00")
        let c = event("c", "2026-10-27T09:30:00+03:00")
        let groups = MenuScheduleDay.group([c, b, a], calendar: calendar)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].meetings.map(\.id), ["a", "b"])
        XCTAssertEqual(groups[1].meetings.map(\.id), ["c"])
        XCTAssertEqual(groups[0].title(relativeTo: date("2026-10-23T12:00:00+03:00"), calendar: calendar), "Понедельник, 26 октября")
    }
    func testGroupingUsesLocalDateInsteadOfUTCDate() {
        let a = event("a", "2026-10-25T22:30:00Z"), b = event("b", "2026-10-26T08:00:00Z")
        let groups = MenuScheduleDay.group([a, b], calendar: calendar)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(calendar.component(.day, from: groups[0].date), 26)
    }
    func testTodayAndTomorrowTitlesKeepWeekdayAndDate() {
        let now = date("2026-10-23T12:00:00+03:00")
        let groups = MenuScheduleDay.group([event("today", "2026-10-23T14:00:00+03:00"),
            event("tomorrow", "2026-10-24T10:00:00+03:00")], calendar: calendar)
        XCTAssertEqual(groups[0].title(relativeTo: now, calendar: calendar), "Сегодня · пятница, 23 октября")
        XCTAssertEqual(groups[1].title(relativeTo: now, calendar: calendar), "Завтра · суббота, 24 октября")
    }
    func testYearIsIncludedAcrossNewYear() {
        let now = date("2026-12-30T12:00:00+03:00")
        let groups = MenuScheduleDay.group([event("nextYear", "2027-01-02T10:00:00+03:00")], calendar: calendar)
        XCTAssertEqual(groups.first?.title(relativeTo: now, calendar: calendar), "Суббота, 2 января 2027")
    }
    func testAllDayEventsComeFirstAndNoMeetingsAreLost() {
        let events = [event("timed", "2026-10-26T10:00:00+03:00"), event("day", "2026-10-26T00:00:00+03:00", allDay: true)]
        let groups = MenuScheduleDay.group(events, calendar: calendar)
        XCTAssertEqual(groups.flatMap(\.meetings).map(\.id), ["day", "timed"])
        XCTAssertTrue(MenuScheduleDay.group([], calendar: calendar).isEmpty)
    }
    func testGroupingFollowsCalendarDayAcrossDST() {
        var local = calendar; local.timeZone = TimeZone(identifier: "America/New_York")!
        let groups = MenuScheduleDay.group([event("early", "2026-03-08T00:30:00-05:00"),
            event("late", "2026-03-08T23:30:00-04:00")], calendar: local)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].meetings.count, 2)
    }
}
