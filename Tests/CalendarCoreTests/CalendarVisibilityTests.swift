import XCTest
@testable import CalendarCore

final class CalendarVisibilityTests: XCTestCase {
    private let calendars = [CalendarInfo(id: "work", name: "Рабочий"), CalendarInfo(id: "team", name: "Команда")]

    func testBothCalendarsAreListedAndVisibleInitially() {
        let state = PersonalCalendarState()
        XCTAssertEqual(state.listedCalendarIDs(in: calendars), ["work", "team"])
        XCTAssertEqual(state.visibleCalendarIDs(in: calendars), ["work", "team"])
    }
    func testSidebarCheckboxKeepsCalendarInListAndInSettings() {
        var state = PersonalCalendarState()
        state.showCalendarEvents("team", visible: false)
        XCTAssertEqual(state.listedCalendarIDs(in: calendars), ["work", "team"])
        XCTAssertEqual(state.visibleCalendarIDs(in: calendars), ["work"])
        XCTAssertTrue(state.hiddenCalendars.isEmpty)
        state.showCalendarEvents("team", visible: true)
        XCTAssertEqual(state.visibleCalendarIDs(in: calendars), ["work", "team"])
    }
    func testSettingsRemovesCalendarAndEventsWithoutChangingTheOtherCalendar() {
        var state = PersonalCalendarState()
        state.includeCalendar("team", included: false)
        XCTAssertEqual(state.listedCalendarIDs(in: calendars), ["work"])
        XCTAssertEqual(state.visibleCalendarIDs(in: calendars), ["work"])
        state.includeCalendar("team", included: true)
        XCTAssertEqual(state.listedCalendarIDs(in: calendars), ["work", "team"])
        XCTAssertEqual(state.visibleCalendarIDs(in: calendars), ["work", "team"])
    }
    func testAllSidebarCheckboxesCanBeOffWithoutAnEmptySidebar() {
        var state = PersonalCalendarState()
        for calendar in calendars { state.showCalendarEvents(calendar.id, visible: false) }
        XCTAssertEqual(state.listedCalendarIDs(in: calendars).count, 2)
        XCTAssertTrue(state.visibleCalendarIDs(in: calendars).isEmpty)
        XCTAssertTrue(state.hiddenCalendars.isEmpty)
    }
    func testSidebarCannotRestoreCalendarExcludedInSettings() {
        var state = PersonalCalendarState()
        state.includeCalendar("team", included: false)
        state.showCalendarEvents("team", visible: true)
        XCTAssertFalse(state.listedCalendarIDs(in: calendars).contains("team"))
        XCTAssertFalse(state.visibleCalendarIDs(in: calendars).contains("team"))
    }
    func testReaddingExcludedCalendarShowsItsEventsInitially() {
        var state = PersonalCalendarState()
        state.showCalendarEvents("team", visible: false)
        state.includeCalendar("team", included: false)
        state.includeCalendar("team", included: true)
        XCTAssertEqual(state.visibleCalendarIDs(in: calendars), ["work", "team"])
    }
    func testRepeatedIncludeDoesNotResetSidebarFilter() {
        var state = PersonalCalendarState()
        state.showCalendarEvents("team", visible: false)
        state.includeCalendar("team", included: true)
        XCTAssertTrue(state.listedCalendarIDs(in: calendars).contains("team"))
        XCTAssertFalse(state.visibleCalendarIDs(in: calendars).contains("team"))
    }
    func testOldSettingsMigrateWithoutRestoringAnExcludedCalendar() throws {
        let data = Data(#"{"hiddenCalendars":["team"],"overrides":{"meeting":{"muted":true}}}"#.utf8)
        let state = try JSONDecoder().decode(PersonalCalendarState.self, from: data)
        XCTAssertEqual(state.listedCalendarIDs(in: calendars), ["work"])
        XCTAssertEqual(state.visibleCalendarIDs(in: calendars), ["work"])
        XCTAssertTrue(state.filteredCalendars.isEmpty)
        XCTAssertEqual(state.overrides["meeting"]?.muted, true)
    }
    func testListAndSidebarFilterSurviveRestartIndependently() throws {
        var state = PersonalCalendarState()
        state.includeCalendar("team", included: false)
        state.showCalendarEvents("work", visible: false)
        let restored = try JSONDecoder().decode(PersonalCalendarState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.listedCalendarIDs(in: calendars), ["work"])
        XCTAssertTrue(restored.visibleCalendarIDs(in: calendars).isEmpty)
        XCTAssertEqual(restored.hiddenCalendars, ["team"])
        XCTAssertEqual(restored.filteredCalendars, ["work"])
    }
    func testUnavailableSavedCalendarDoesNotAppearInSidebar() {
        var state = PersonalCalendarState()
        state.showCalendarEvents("removed", visible: false)
        XCTAssertEqual(state.listedCalendarIDs(in: calendars), ["work", "team"])
        XCTAssertEqual(state.visibleCalendarIDs(in: calendars), ["work", "team"])
    }
    func testFilteringAffectsMenuImmediatelyWithoutMutatingCachedEvents() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [event("work", now: now), event("team", now: now)]
        var state = PersonalCalendarState()
        func menu() -> MenuSchedule {
            MenuSchedule(meetings: events, mode: .currentAndUpcoming, visibleCalendarIDs: state.visibleCalendarIDs(in: calendars),
                account: "me@example.org", now: now, calendar: Calendar(identifier: .gregorian))
        }
        XCTAssertEqual(menu().meetings.count, 2)
        state.showCalendarEvents("team", visible: false)
        XCTAssertEqual(menu().meetings.map(\.calendarID), ["work"])
        state.showCalendarEvents("team", visible: true)
        XCTAssertEqual(menu().meetings.count, 2)
        XCTAssertEqual(events.count, 2)
    }
    func testBothDisplayFiltersLeaveNotificationSelectionAndRemindersIndependent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [event("work", now: now), event("team", now: now)]
        var state = PersonalCalendarState(), config = CalendarConfiguration()
        config.calendarIDs = ["work", "team"]
        state.showCalendarEvents("work", visible: false)
        state.includeCalendar("team", included: false)
        XCTAssertTrue(state.visibleCalendarIDs(in: calendars).isEmpty)
        let plans = ReminderPlanner.plan(meetings: events, state: state, defaults: [15],
            calendarIDs: Set(config.calendarIDs), account: "me@example.org", now: now)
        XCTAssertEqual(Set(plans.map { $0.meeting.calendarID }), ["work", "team"])
        XCTAssertEqual(config.calendarIDs, ["work", "team"])
    }
    private func event(_ calendarID: String, now: Date) -> Meeting {
        Meeting(id: calendarID, seriesID: calendarID, calendarID: calendarID, calendarName: calendarID, title: calendarID,
            start: now.addingTimeInterval(3600), end: now.addingTimeInterval(5400), allDay: false,
            details: "", location: "", link: nil, attendees: [], organizer: "", cancelled: false)
    }
}
