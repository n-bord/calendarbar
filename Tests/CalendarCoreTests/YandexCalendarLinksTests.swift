import XCTest
@testable import CalendarCore

final class YandexCalendarLinksTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/Moscow")!
    private let start = ISO8601DateFormatter().date(from: "2026-10-22T23:30:00Z")!
    private func meeting(source: String? = nil) -> Meeting {
        Meeting(id: "resource", seriesID: "series", calendarID: "work", calendarName: "Рабочий", title: "Встреча",
            start: start, end: start.addingTimeInterval(1800), allDay: false, details: "", location: "", link: nil,
            attendees: [], organizer: "", cancelled: false, uid: "arbitrary-caldav-uid", sourceURL: source.flatMap(URL.init(string:)))
    }
    func testExactServerEventLinkIsPreservedWithoutReplacingItsIdentifiers() {
        let source = "https://calendar.yandex.ru/event?event_id=123&uid=456&recurrence_id=2026-10-22"
        XCTAssertEqual(YandexCalendarLinks.event(meeting(source: source), timeZone: zone).absoluteString, source)
    }
    func testFallbackOpensLocalDateAndNeverUsesCalDAVUIDAsWebEventID() {
        let url = YandexCalendarLinks.event(meeting(), timeZone: zone)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(url.path, "/day")
        XCTAssertEqual(query.first { $0.name == "show_date" }?.value, "2026-10-23")
        XCTAssertEqual(query.first { $0.name == "tz_id" }?.value, "Europe/Moscow")
        XCTAssertFalse(url.absoluteString.contains("arbitrary-caldav-uid"))
        XCTAssertFalse(query.contains { ["event_id", "uid"].contains($0.name) })
    }
    func testCreateOpensWebFormAndPassesLocalDateAndThirtyMinuteInterval() {
        let url = YandexCalendarLinks.create(start: start, timeZone: zone)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(url.scheme, "https"); XCTAssertEqual(url.host, "calendar.yandex.ru")
        XCTAssertEqual(url.path, "/week/create")
        XCTAssertEqual(query.first { $0.name == "start" }?.value, "2026-10-23T02:30:00")
        XCTAssertEqual(query.first { $0.name == "end" }?.value, "2026-10-23T03:00:00")
        XCTAssertEqual(query.first { $0.name == "show_date" }?.value, "2026-10-23")
        XCTAssertFalse(MeetingLinks.isUsableMeetingURL(url))
    }

    func testCreateUsesEndOfShortFreeSlot() {
        let url = YandexCalendarLinks.create(start: start, end: start.addingTimeInterval(600), timeZone: zone)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "end" }?.value, "2026-10-23T02:40:00")
    }
    func testUntrustedSourcesAndNonEventURLsFallBackToCalendarDay() {
        for source in ["https://example.org/event/1", "https://calendar.yandex.ru.evil.example/event/1",
            "http://calendar.yandex.ru/event/1", "https://user:secret@calendar.yandex.ru/event/1",
            "https://calendar.yandex.ru:8080/event/1", "https://calendar.yandex.ru/week",
            "https://calendar.yandex.ru/event?event_id=&uid=456", "https://calendar.yandex.ru/event?create=1",
            "https://telemost.yandex.ru/j/1234"] {
            let url = YandexCalendarLinks.event(meeting(source: source), timeZone: zone)
            XCTAssertEqual(url.host, "calendar.yandex.ru"); XCTAssertEqual(url.path, "/day", source)
            XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.password)
        }
    }
    func testParserKeeps360EventLinksSeparateFromConferenceLinks() throws {
        let source = "https://calendar.360.yandex.ru/event/123?uid=456"
        let data = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:123\nDTSTART:20261023T090000Z\nURL:\(source)\nDESCRIPTION:https://telemost.yandex.ru/j/1234\nEND:VEVENT\nEND:VCALENDAR"
        let event = try XCTUnwrap(ICalendar.parse(data, calendar: CalendarInfo(id: "work", name: "Рабочий"), fallbackZone: zone).first)
        XCTAssertEqual(event.sourceURL?.absoluteString, source)
        XCTAssertEqual(event.joinURL?.host, "telemost.yandex.ru")
    }
}
