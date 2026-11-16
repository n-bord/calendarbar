import XCTest
@testable import CalendarCore

final class CalendarCoreTests: XCTestCase {
    let calendar = CalendarInfo(id: "https://caldav.yandex.ru/calendars/test/events/", name: "Рабочий")
    let zone = TimeZone(identifier: "Europe/Moscow")!

    func parse(_ event: String) throws -> [Meeting] {
        try ICalendar.parse("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" + event + "\r\nEND:VCALENDAR", calendar: calendar, fallbackZone: zone)
    }
    func event(uid: String = "one", title: String = "Планёрка", start: String = "20261021T100000Z", extra: String = "") -> String {
        """
        BEGIN:VEVENT
        UID:\(uid)
        SUMMARY:\(title)
        DTSTART:\(start)
        DURATION:PT30M
        \(extra)
        END:VEVENT
        """
    }

    func testAttendeesDescriptionFoldingAndMeetingURL() throws {
        let text = event(extra: """
        DESCRIPTION:Описание\\nВторая строка\\, с запятой
         и продолжением
        ATTENDEE;CN="Иван; Петров";ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:ivan@example.org
        ATTENDEE;CN="Анна: Соколова";ROLE=OPT-PARTICIPANT:mailto:anna@example.org
        URL:https://telemost.yandex.ru/j/123456
        """)
        let meeting = try XCTUnwrap(parse(text).first)
        XCTAssertEqual(meeting.details, "Описание\nВторая строка, с запятойи продолжением")
        XCTAssertEqual(meeting.attendees.count, 2)
        XCTAssertEqual(meeting.attendees[0].name, "Иван; Петров")
        XCTAssertEqual(meeting.attendees[1].name, "Анна: Соколова")
        XCTAssertTrue(meeting.attendees[1].optional)
        XCTAssertEqual(meeting.link?.host, "telemost.yandex.ru")
        XCTAssertEqual(meeting.end.timeIntervalSince(meeting.start), 1800)
    }

    func testUTCAndTZIDAndFloatingDatesAgree() throws {
        let utc = try XCTUnwrap(parse(event()).first)
        let local = event().replacingOccurrences(of: "DTSTART:20261021T100000Z", with: "DTSTART;TZID=Europe/Moscow:20261021T130000")
        let floating = event(start: "20261021T130000")
        XCTAssertEqual(try parse(local).first?.start, utc.start)
        XCTAssertEqual(try parse(floating).first?.start, utc.start)
    }

    func testInvitationStatusUsesOnlyTheActiveAccount() throws {
        let meeting = try XCTUnwrap(parse(event(extra: """
        ORGANIZER:mailto:owner@example.org
        ATTENDEE;PARTSTAT=ACCEPTED:mailto:yes@example.org
        ATTENDEE;PARTSTAT=TENTATIVE:mailto:maybe@example.org
        ATTENDEE;PARTSTAT=DECLINED:mailto:no@example.org
        ATTENDEE:mailto:pending@example.org
        """)).first)
        XCTAssertEqual(meeting.invitationStatus(for: "YES@example.org"), .accepted)
        XCTAssertEqual(meeting.invitationStatus(for: "pending@example.org"), .needsAction)
        XCTAssertEqual(meeting.invitationStatus(for: "maybe@example.org"), .tentative)
        XCTAssertEqual(meeting.invitationStatus(for: "no@example.org"), .declined)
        XCTAssertEqual(meeting.invitationStatus(for: "owner@example.org"), .organizer)
        XCTAssertEqual(meeting.invitationStatus(for: "another@example.org"), .unknown)
    }

    func testAllDayCivilDateSurvivesProjectionAndRangeFiltering() throws {
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:day
        DTSTART;VALUE=DATE:20261021
        DTEND;VALUE=DATE:20261022
        END:VEVENT
        END:VCALENDAR
        """
        var display = Calendar(identifier: .gregorian)
        display.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = try XCTUnwrap(display.date(from: DateComponents(year: 2026, month: 10, day: 21)))
        let end = first.addingTimeInterval(86400)
        let prior = first.addingTimeInterval(-86400)..<first
        let meeting = try XCTUnwrap(ICalendar.parse(text, calendar: calendar, fallbackZone: zone,
            range: first..<end, displayCalendar: display).first)
        XCTAssertTrue(try ICalendar.parse(text, calendar: calendar, fallbackZone: zone,
            range: prior, displayCalendar: display).isEmpty)
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        let projected = decoded.displayed(in: display, fallbackZone: zone)
        XCTAssertEqual(projected.start, first)
        XCTAssertEqual(projected.end, end)
        XCTAssertEqual(projected.id, meeting.id)
        XCTAssertEqual(projected.displayed(in: display, fallbackZone: zone), projected)
        var cached = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
        cached.removeValue(forKey: "allDayDates")
        let legacy = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: cached))
        XCTAssertEqual(legacy.displayed(in: display, fallbackZone: zone), projected)
    }

    func testUnknownTimezoneAndInvalidDatesFail() {
        let text = event().replacingOccurrences(of: "DTSTART:20261021T100000Z", with: "DTSTART;TZID=Wrong/Zone:20261021T130000")
        XCTAssertThrowsError(try parse(text))
        XCTAssertThrowsError(try parse(event(start: "not-a-date")))
    }

    func testExpandedMovedOccurrencesKeepOriginalIdentity() throws {
        let old = try XCTUnwrap(parse(event(extra: "RECURRENCE-ID:20261021T100000Z")).first)
        let moved = try XCTUnwrap(parse(event(start: "20261021T120000Z", extra: "RECURRENCE-ID:20261021T100000Z")).first)
        XCTAssertEqual(old.id, moved.id)
        XCTAssertNotEqual(old.signature, moved.signature)
    }

    func testRecurrenceRequiresExplicitQueryRange() {
        XCTAssertThrowsError(try parse(event(extra: "RRULE:FREQ=DAILY")))
        XCTAssertThrowsError(try parse(event(extra: "RDATE:20261022T100000Z")))
        XCTAssertThrowsError(try parse(event(extra: "EXDATE:20261022T100000Z")))
    }

    func testAllDayAndAlarmPropertiesDoNotReplaceEventProperties() throws {
        let text = """
        BEGIN:VEVENT
        UID:day
        SUMMARY:Выходной
        DTSTART;VALUE=DATE:20261021
        BEGIN:VALARM
        DESCRIPTION:Это текст будильника
        DURATION:PT5M
        END:VALARM
        END:VEVENT
        """
        let meeting = try XCTUnwrap(parse(text).first)
        XCTAssertTrue(meeting.allDay)
        XCTAssertEqual(meeting.details, "")
        XCTAssertEqual(meeting.end.timeIntervalSince(meeting.start), 86400)
    }

    func testFirstLoadIsQuietAndExistingSeriesNewOccurrenceIsQuiet() throws {
        let meeting = try XCTUnwrap(parse(event()).first)
        let now = meeting.start.addingTimeInterval(-86400)
        XCTAssertTrue(ChangeDetector.changes(old: [], new: [meeting], knownSeries: [], initialized: false, now: now).isEmpty)
        XCTAssertEqual(ChangeDetector.changes(old: [], new: [meeting], knownSeries: [], initialized: true, now: now).first?.kind, .new)
        XCTAssertTrue(ChangeDetector.changes(old: [], new: [meeting], knownSeries: [meeting.seriesID], initialized: true, now: now).isEmpty)
    }

    func testChangesCancellationsAndUnchangedEvents() throws {
        let before = try XCTUnwrap(parse(event()).first)
        let after = try XCTUnwrap(parse(event(title: "Перенесённая планёрка")).first)
        let cancelled = try XCTUnwrap(parse(event(extra: "STATUS:CANCELLED")).first)
        let now = before.start.addingTimeInterval(-3600)
        let known: Set<String> = [before.seriesID]
        XCTAssertTrue(ChangeDetector.changes(old: [before], new: [before], knownSeries: known, initialized: true, now: now).isEmpty)
        XCTAssertEqual(ChangeDetector.changes(old: [before], new: [after], knownSeries: known, initialized: true, now: now).first?.kind, .changed)
        XCTAssertEqual(ChangeDetector.changes(old: [before], new: [cancelled], knownSeries: known, initialized: true, now: now).first?.kind, .cancelled)
        // Missing from a response is deliberately not interpreted as an explicit cancellation.
        XCTAssertTrue(ChangeDetector.changes(old: [before], new: [], knownSeries: known, initialized: true, now: now).isEmpty)
    }

    func testDeclinedInviteAndPastEvents() throws {
        let meeting = try XCTUnwrap(parse(event(extra: "ATTENDEE;PARTSTAT=DECLINED:mailto:me@example.org")).first)
        XCTAssertTrue(meeting.declined(by: "ME@example.org"))
        XCTAssertFalse(meeting.declined(by: "another@example.org"))
        XCTAssertTrue(ChangeDetector.changes(old: [], new: [meeting], knownSeries: [], initialized: true, now: meeting.end.addingTimeInterval(1)).isEmpty)
    }

    func testEscapesAndCorruptedInput() throws {
        XCTAssertEqual(ICalendar.decode("a\\\\n"), "a\\n")
        XCTAssertEqual(ICalendar.decode("a\\n"), "a\n")
        XCTAssertThrowsError(try ICalendar.parse("not a calendar", calendar: calendar, fallbackZone: zone))
        XCTAssertThrowsError(try parse("BEGIN:VEVENT\nUID:unfinished"))
    }
}
