import XCTest
@testable import CalendarCore

final class MeetingLinksTests: XCTestCase {
    func testTelemostUsesDesktopMeetingProtocolAndCanonicalURL() {
        let url = URL(string: "https://telemost.yandex.ru/j/123456?skip_app=1#fragment")!
        XCTAssertEqual(MeetingLinks.telemostDesktopURL(for: url)?.absoluteString, "telemost://https://telemost.yandex.ru/j/123456")
        XCTAssertNotNil(MeetingLinks.telemostDesktopURL(for: URL(string: "https://telemost.360.yandex.ru/j/123456")!))
    }
    func testUnrelatedOrMalformedLinksAreNotSentToTelemost() {
        for text in ["https://telemost.yandex.ru.evil.test/j/123", "https://example.org/j/123", "https://telemost.yandex.ru/j/abc", "https://user@telemost.yandex.ru/j/123"] {
            XCTAssertNil(MeetingLinks.telemostDesktopURL(for: URL(string: text)!))
        }
    }
    func testBrowserFallbackDisablesRepeatedAppPrompt() {
        let url = URL(string: "https://telemost.yandex.ru/j/123?skip_app=0&other=yes")!
        let query = URLComponents(url: MeetingLinks.browserURL(for: url), resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.filter { $0.name == "skip_app" }.map(\.value), ["1"])
        XCTAssertEqual(query.first { $0.name == "other" }?.value, "yes")
    }

    func testEventPageIsNotAJoinLink() {
        let page = URL(string: "https://calendar.yandex.ru/event?event_id=123&uid=456")!
        XCTAssertFalse(MeetingLinks.isUsableMeetingURL(page))
        XCTAssertNil(MeetingLinks.conferenceURL(explicitURLs: [page], texts: ["Обсудим документ https://example.org/specification"]))
        XCTAssertNil(MeetingLinks.conferenceURL(explicitURLs: [], texts: ["Переговорная 5"]))
        XCTAssertFalse(MeetingLinks.isUsableMeetingURL(URL(string: "javascript:alert(1)")!))
    }

    func testConferenceInDescriptionTakesPriorityOverEventPage() {
        let page = URL(string: "https://calendar.yandex.ru/event?event_id=123&uid=456")!
        let link = MeetingLinks.conferenceURL(explicitURLs: [page], texts: ["Подключение: https://telemost.360.yandex.ru/j/123456"])
        XCTAssertEqual(link?.absoluteString, "https://telemost.360.yandex.ru/j/123456")
        XCTAssertNotNil(MeetingLinks.conferenceURL(explicitURLs: [page], texts: ["https://meet.google.com/abc-defg-hij"]))
    }

    func testCalendarParserFindsConferenceFieldInsteadOfEventURL() throws {
        let data = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:meeting
        DTSTART:20261021T090000Z
        DTEND:20261021T093000Z
        SUMMARY:Встреча
        URL:https://calendar.yandex.ru/event?event_id=123&uid=456
        CONFERENCE;VALUE=URI:https://telemost.yandex.ru/j/123456
        END:VEVENT
        END:VCALENDAR
        """
        let events = try ICalendar.parse(data, calendar: CalendarInfo(id: "test", name: "Рабочий"), fallbackZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(events.first?.link?.absoluteString, "https://telemost.yandex.ru/j/123456")
    }

    func testOldCachedCalendarPageCannotEnableJoinButton() throws {
        let event = Meeting(id: "event", seriesID: "series", calendarID: "calendar", calendarName: "Рабочий",
            title: "Встреча", start: Date(), end: Date().addingTimeInterval(1800), allDay: false,
            details: "", location: "Переговорная", link: URL(string: "https://calendar.yandex.ru/event?event_id=123&uid=456"),
            attendees: [], organizer: "", cancelled: false)
        let restored = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(event))
        XCTAssertNil(restored.joinURL)
    }

    func testCalendarParserDoesNotTreatArbitraryDescriptionURLAsConference() throws {
        let data = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:without-conference
        DTSTART:20261021T090000Z
        URL:https://calendar.yandex.ru/event?event_id=123&uid=456
        DESCRIPTION:Документы https://example.org/specification
        END:VEVENT
        END:VCALENDAR
        """
        let events = try ICalendar.parse(data, calendar: CalendarInfo(id: "test", name: "Рабочий"), fallbackZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertNil(events.first?.link)
        XCTAssertNil(events.first?.joinURL)
    }
}
