import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CalendarCore

final class LegacyLocalWriteTests: XCTestCase {
    private let calendar = CalendarInfo(id: "https://caldav.yandex.ru/calendars/me/events/", name: "Рабочий")
    private let zone = TimeZone(secondsFromGMT: 0)!
    private let source = "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:fixed\nDTSTAMP:20261022T080000Z\nDTSTART:20261022T100000Z\nDTEND:20261022T110000Z\nSUMMARY:Встреча\nEND:VEVENT\nEND:VCALENDAR"
    private func meeting(_ text: String) throws -> Meeting {
        try XCTUnwrap(ICalendar.parse(text, calendar: calendar, fallbackZone: zone,
            resourceURL: URL(string: calendar.id + "fixed.ics"), etag: "\"v1\"").first)
    }
    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "SUMMARY:Встреча", with: "SUMMARY:Встреча\nORGANIZER:mailto:me@example.org\nATTENDEE;PARTSTAT=ACCEPTED:mailto:me@example.org")
    }
    func testLocalCreationAcknowledgesOwnerNormalizationButNotRealLaterChanges() throws {
        let previous = try meeting(source), server = try meeting(normalized(source))
        let now = previous.start.addingTimeInterval(-300), receipt = LocalWriteReceipt(seriesID: previous.seriesID, savedAt: now.addingTimeInterval(-30))
        let changes = ChangeDetector.changes(old: [previous], new: [server], knownSeries: [previous.seriesID], initialized: true, now: now, localWrites: [receipt], account: "me@example.org")
        XCTAssertTrue(changes.isEmpty)
        let moved = try meeting(normalized(source).replacingOccurrences(of: "DTSTART:20261022T100000Z", with: "DTSTART:20261022T103000Z"))
        XCTAssertEqual(ChangeDetector.changes(old: [previous], new: [moved], knownSeries: [previous.seriesID], initialized: true, now: now, localWrites: [receipt], account: "me@example.org").count, 1)
        XCTAssertFalse(receipt.canAcknowledge(previous: previous, current: server, account: "me@example.org", now: now.addingTimeInterval(601)))
    }
    func testNewReceiptFieldIsBackwardCompatibleWithExistingPersonalSettings() throws {
        let state = try JSONDecoder().decode(PersonalCalendarState.self, from: Data("{\"hiddenCalendars\":[\"team\"]}".utf8))
        XCTAssertTrue(state.localWrites.isEmpty); XCTAssertEqual(state.hiddenCalendars, ["team"])
    }
}
