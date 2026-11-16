import Foundation
import XCTest
@testable import CalendarCore

final class AccountIdentityTests: XCTestCase {
    func testSharedCalendarAndOccurrenceIDsRemainDistinctAcrossAccounts() throws {
        let rawCalendar = CalendarInfo(id: "https://caldav.yandex.ru/calendars/shared/", name: "Общий")
        let first = rawCalendar.scoped(to: "work@example.org")
        let second = rawCalendar.scoped(to: "home@example.org")
        let contents = """
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            UID:appointment
            DTSTART:20261113T120000Z
            DTEND:20261113T123000Z
            END:VEVENT
            END:VCALENDAR
            """
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let raw = try XCTUnwrap(ICalendar.parse(contents, calendar: rawCalendar, fallbackZone: zone).first)
        let work = try XCTUnwrap(ICalendar.parse(contents, calendar: first, fallbackZone: zone).first)
        let home = work.scoped(to: "home@example.org", calendarName: "Личное · Общий")

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(work.id, home.id)
        XCTAssertNotEqual(work.seriesID, home.seriesID)
        XCTAssertEqual(work.calendarID, first.id)
        XCTAssertEqual(home.calendarID, second.id)
        XCTAssertEqual(home.calendarName, "Личное · Общий")
        XCTAssertEqual(home.sourceCalendarName, rawCalendar.name)
        XCTAssertEqual(work.unscoped(), raw)
        XCTAssertEqual(home.unscoped(), raw)
        XCTAssertEqual(first.unscoped(), rawCalendar)
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(home)), home)
    }

    func testLegacyMeetingDecodesAndInvitationStatusUsesItsOwnerInUnifiedViews() throws {
        let legacy = Data("""
            {"id":"meeting-id","seriesID":"series-id","calendarID":"shared-calendar","calendarName":"Общий",
             "title":"Встреча","start":0,"end":3600,"allDay":false,"details":"","location":"","organizer":"",
             "cancelled":false,"attendees":[{"email":"work@example.org","name":"","optional":false,"response":"ACCEPTED"},
                                             {"email":"home@example.org","name":"","optional":false,"response":"DECLINED"}]}
            """.utf8)
        let raw = try JSONDecoder().decode(Meeting.self, from: legacy)
        let work = raw.scoped(to: "work@example.org")
        let home = raw.scoped(to: "home@example.org")

        XCTAssertNil(raw.accountLogin)
        XCTAssertEqual(raw.id, "meeting-id")
        XCTAssertEqual(work.invitationStatus(for: "home@example.org"), .accepted)
        XCTAssertEqual(home.invitationStatus(for: "work@example.org"), .declined)
        XCTAssertFalse(work.declined(by: "home@example.org"))
        XCTAssertTrue(home.declined(by: "work@example.org"))

        let now = raw.start.addingTimeInterval(-60)
        let schedule = MenuSchedule(meetings: [work, home], mode: .currentAndUpcoming,
            visibleCalendarIDs: [work.calendarID, home.calendarID], account: "home@example.org", now: now, calendar: .current)
        XCTAssertEqual(schedule.meetings.map(\.id), [work.id])
    }
}
