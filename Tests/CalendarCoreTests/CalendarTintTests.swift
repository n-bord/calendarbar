import Foundation
import XCTest
@testable import CalendarCore

final class CalendarTintTests: XCTestCase {
    private func meeting(_ id: String, series: String = "series") -> Meeting {
        Meeting(id: id, seriesID: series, calendarID: "calendar", calendarName: "Рабочий",
            title: "Планёрка", start: Date(timeIntervalSince1970: 1_800_000_000),
            end: Date(timeIntervalSince1970: 1_800_001_800), allDay: false, details: "",
            location: "", link: nil, attendees: [], organizer: "", cancelled: false,
            recurrenceRule: "FREQ=WEEKLY")
    }

    func testOccurrenceAndSeriesColorsOverrideCalendarColorAndResetByScope() {
        let monday = meeting("monday")
        let nextMonday = meeting("next-monday")
        let other = meeting("other", series: "other")
        var state = PersonalCalendarState()

        state.setCalendarTint(.cyan, for: "calendar")
        state.setMeetingTint(.red, for: monday, scope: .series)
        state.setMeetingTint(.orange, for: monday, scope: .occurrence)
        XCTAssertEqual(state.meetingTint(for: monday), .orange)
        XCTAssertEqual(state.meetingTint(for: nextMonday), .red)
        XCTAssertEqual(state.meetingTint(for: other), .cyan)

        state.setMeetingTint(nil, for: monday, scope: .series)
        XCTAssertEqual(state.meetingTint(for: monday), .orange)
        XCTAssertEqual(state.meetingTint(for: nextMonday), .cyan)
        state.setMeetingTint(nil, for: monday, scope: .occurrence)
        XCTAssertEqual(state.meetingTint(for: monday), .cyan)
        state.setCalendarTint(nil, for: "calendar")
        XCTAssertNil(state.meetingTint(for: monday))
    }

    func testColorsSurviveRelaunchAndMissingKeysRetainDefault() throws {
        let event = meeting("monday")
        var state = try JSONDecoder().decode(PersonalCalendarState.self, from: Data("{}".utf8))
        XCTAssertNil(state.calendarTint(for: "calendar"))
        XCTAssertNil(state.meetingTint(for: event))

        state.setCalendarTint(.green, for: "calendar")
        state.setMeetingTint(.violet, for: event, scope: .series)
        state.setMeetingTint(.blue, for: event, scope: .occurrence)
        let restored = try JSONDecoder().decode(PersonalCalendarState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.calendarTint(for: "calendar"), .green)
        XCTAssertEqual(restored.meetingTint(for: event, scope: .series), .violet)
        XCTAssertEqual(restored.meetingTint(for: event, scope: .occurrence), .blue)
        XCTAssertEqual(restored.meetingTint(for: event), .blue)
    }

    func testAnUnknownSavedColorDoesNotDiscardOtherColors() throws {
        let json = #"{"calendarTints":{"calendar":"yellow","unknown":"future-color"}}"#
        let state = try JSONDecoder().decode(PersonalCalendarState.self, from: Data(json.utf8))
        XCTAssertEqual(state.calendarTint(for: "calendar"), .yellow)
        XCTAssertNil(state.calendarTint(for: "unknown"))
    }

    func testProjectionUsesTheSameAccountLocalTintKeysAsTheCachedMeeting() {
        let event = meeting("monday")
        let projected = event.scoped(to: "work@example.org")
        var state = PersonalCalendarState()
        state.setCalendarTint(.cyan, for: event.calendarID)
        XCTAssertEqual(state.meetingTint(for: projected), .cyan)
        state.setMeetingTint(.green, for: projected, scope: .occurrence)
        XCTAssertEqual(state.meetingTint(for: event, scope: .occurrence), .green)
    }
}
