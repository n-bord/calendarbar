import XCTest
@testable import CalendarCore

final class MenuScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var now: Date { date("2026-10-22T12:00:00+03:00") }
    private func event(_ id: String, _ start: String, _ end: String, calendarID: String = "visible",
                       allDay: Bool = false, cancelled: Bool = false, declined: Bool = false) -> Meeting {
        Meeting(id: id, seriesID: id, calendarID: calendarID, calendarName: calendarID, title: id,
            start: date(start), end: date(end), allDay: allDay, details: "", location: "", link: nil,
            attendees: declined ? [Attendee(email: "me@example.org", name: "", optional: false, response: "DECLINED")] : [],
            organizer: "", cancelled: cancelled)
    }
    private var past: Meeting { event("past", "2026-10-22T10:00:00+03:00", "2026-10-22T11:00:00+03:00") }
    private var ongoing: Meeting { event("ongoing", "2026-10-22T11:30:00+03:00", "2026-10-22T12:30:00+03:00") }
    private var future: Meeting { event("future", "2026-10-22T13:00:00+03:00", "2026-10-22T14:00:00+03:00") }
    private var allDay: Meeting { event("allDay", "2026-10-22T00:00:00+03:00", "2026-10-23T00:00:00+03:00", allDay: true) }
    private func make(_ events: [Meeting], _ mode: MenuMeetingsMode = .currentAndUpcoming, at time: Date? = nil) -> MenuSchedule {
        MenuSchedule(meetings: events, mode: mode, visibleCalendarIDs: ["visible"], account: "me@example.org",
            now: time ?? now, calendar: calendar)
    }

    func testDefaultKeepsMeetingUntilEndAndHidesFinishedEvents() {
        let result = make([past, ongoing, future])
        XCTAssertEqual(result.ongoing.map(\.id), ["ongoing"])
        XCTAssertEqual(result.next.map(\.id), ["future"])
        XCTAssertEqual(result.meetings.count, 2)
        XCTAssertTrue(result.finished.isEmpty)
    }
    func testAllTodayKeepsPastMeetingAndItsJoinLink() {
        let link = URL(string: "https://telemost.yandex.ru/j/123456")!
        let old = Meeting(id: "past", seriesID: "past", calendarID: "visible", calendarName: "Рабочий", title: "Встреча",
            start: past.start, end: past.end, allDay: false, details: "", location: "", link: link,
            attendees: [], organizer: "", cancelled: false)
        let result = make([old, ongoing, future], .allToday)
        XCTAssertEqual(result.finished.map(\.id), ["past"])
        XCTAssertEqual(result.finished.first?.joinURL, link)
    }
    func testCombinedMenuKeepsEarlierTodayAndTheNextFourteenDays() {
        let yesterday = event("yesterday", "2026-10-21T10:00:00+03:00", "2026-10-21T11:00:00+03:00")
        let nextWeek = event("nextWeek", "2026-10-28T13:00:00+03:00", "2026-10-28T14:00:00+03:00")
        let result = MenuSchedule(meetings: [yesterday, past, ongoing, future, nextWeek],
            mode: .currentAndUpcoming, visibleCalendarIDs: ["visible"], account: "me@example.org",
            now: now, calendar: calendar, includeFinishedToday: true)
        XCTAssertEqual(result.finished.map(\.id), ["past"])
        XCTAssertEqual(result.lastFinished?.id, "past")
        XCTAssertEqual(result.ongoing.map(\.id), ["ongoing"])
        XCTAssertEqual(result.next.map(\.id), ["future"])
        XCTAssertEqual(result.later.map(\.id), ["nextWeek"])
    }
    func testLastFinishedUsesLatestEndAndFallsBackToYesterday() {
        let yesterday = event("yesterday", "2026-10-21T16:00:00+03:00", "2026-10-21T17:00:00+03:00")
        let earlier = event("earlier", "2026-10-22T09:00:00+03:00", "2026-10-22T11:30:00+03:00")
        let hidden = event("hidden", "2026-10-22T09:00:00+03:00", "2026-10-22T11:45:00+03:00", calendarID: "hidden")
        func schedule(at date: Date) -> MenuSchedule {
            MenuSchedule(meetings: [yesterday, past, earlier, hidden, ongoing, allDay],
                mode: .currentAndUpcoming, visibleCalendarIDs: ["visible"], account: "me@example.org",
                now: date, calendar: calendar, includeFinishedToday: true)
        }
        let morning = schedule(at: date("2026-10-22T08:00:00+03:00"))
        XCTAssertEqual(morning.lastFinished?.id, "yesterday")
        XCTAssertTrue(morning.finished.isEmpty)
        let midday = schedule(at: now)
        XCTAssertEqual(midday.lastFinished?.id, "earlier")
        XCTAssertEqual(midday.finished.dropFirst().map(\.id), ["past"])
    }
    func testHidingLatestLeavesItInHistoryAndDoesNotHideNewCompletion() throws {
        var state = PersonalCalendarState()
        state.hiddenLastMeeting = FinishedMeetingReference(past)
        let restored = try JSONDecoder().decode(PersonalCalendarState.self, from: JSONEncoder().encode(state))
        let schedule = MenuSchedule(meetings: [past, ongoing], mode: .currentAndUpcoming,
            visibleCalendarIDs: ["visible"], account: "me@example.org", now: now, calendar: calendar,
            includeFinishedToday: true)
        XCTAssertNil(schedule.highlightedLastMeeting(hiding: restored.hiddenLastMeeting))
        XCTAssertEqual(schedule.finished.map(\.id), ["past"])
        let updated = MenuSchedule(meetings: [past, ongoing], mode: .currentAndUpcoming,
            visibleCalendarIDs: ["visible"], account: "me@example.org", now: ongoing.end, calendar: calendar,
            includeFinishedToday: true)
        XCTAssertEqual(updated.highlightedLastMeeting(hiding: restored.hiddenLastMeeting)?.id, "ongoing")
    }
    func testAtStartItIsCurrentAndAtEndItIsFinished() {
        XCTAssertEqual(make([future], at: future.start).ongoing.map(\.id), ["future"])
        XCTAssertTrue(make([future], .upcomingOnly, at: future.start).meetings.isEmpty)
        XCTAssertTrue(make([ongoing], at: ongoing.end).meetings.isEmpty)
        XCTAssertEqual(make([ongoing], .allToday, at: ongoing.end).finished.map(\.id), ["ongoing"])
    }
    func testUpcomingOnlyExcludesCurrentAndTodayAllDayEvents() {
        let result = make([past, ongoing, future, allDay], .upcomingOnly)
        XCTAssertEqual(result.meetings.map(\.id), ["future"])
    }
    func testCurrentOnlyIncludesAllDayAndNoFutureMeetings() {
        let result = make([past, ongoing, future, allDay], .currentOnly)
        XCTAssertEqual(Set(result.meetings.map(\.id)), ["ongoing", "allDay"])
        XCTAssertEqual(result.allDay.map(\.id), ["allDay"])
        XCTAssertTrue(result.next.isEmpty)
    }
    func testTodayUsesLocalDayAndExcludesMidnightBoundaries() {
        let early = event("early", "2026-10-22T00:30:00+03:00", "2026-10-22T01:00:00+03:00")
        let yesterday = event("yesterday", "2026-10-21T23:30:00+03:00", "2026-10-22T00:00:00+03:00")
        let tomorrow = event("tomorrow", "2026-10-23T00:00:00+03:00", "2026-10-23T01:00:00+03:00")
        XCTAssertEqual(make([yesterday, tomorrow, early], .allToday).meetings.map(\.id), ["early"])
    }
    func testMidnightRecomputesTheDayWithoutARefresh() {
        let before = date("2026-10-22T23:59:59+03:00"), after = date("2026-10-23T00:00:00+03:00")
        XCTAssertEqual(make([past], .allToday, at: before).finished.count, 1)
        XCTAssertTrue(make([past], .allToday, at: after).meetings.isEmpty)
    }
    func testMeetingThatStartedYesterdayRemainsCurrentToday() {
        let overnight = event("overnight", "2026-10-21T23:30:00+03:00", "2026-10-22T13:00:00+03:00")
        XCTAssertEqual(make([overnight], .allToday).ongoing.map(\.id), ["overnight"])
    }
    func testCancelledDeclinedAndHiddenCalendarsAreExcludedInEveryMode() {
        let bad = [event("hidden", "2026-10-22T11:00:00+03:00", "2026-10-22T14:00:00+03:00", calendarID: "hidden"),
            event("cancelled", "2026-10-22T11:00:00+03:00", "2026-10-22T14:00:00+03:00", cancelled: true),
            event("declined", "2026-10-22T11:00:00+03:00", "2026-10-22T14:00:00+03:00", declined: true)]
        for mode in MenuMeetingsMode.allCases { XCTAssertTrue(make(bad, mode).meetings.isEmpty) }
    }
    func testParallelNextMeetingsAreAllHighlighted() {
        let second = event("parallel", "2026-10-22T13:00:00+03:00", "2026-10-22T13:30:00+03:00")
        let result = make([second, future])
        XCTAssertEqual(result.next.map(\.id), ["future", "parallel"])
        XCTAssertTrue(result.laterToday.isEmpty)
    }
    func testEveryMeetingAppearsInExactlyOneSectionIncludingFutureAllDay() {
        let tomorrow = event("tomorrow", "2026-10-23T00:00:00+03:00", "2026-10-24T00:00:00+03:00", allDay: true)
        let laterToday = event("later", "2026-10-22T15:00:00+03:00", "2026-10-22T16:00:00+03:00")
        for mode in MenuMeetingsMode.allCases {
            let r = make([past, ongoing, future, allDay, tomorrow, laterToday], mode)
            let ids = (r.ongoing + r.next + r.laterToday + r.allDay + r.finished + r.later).map(\.id)
            XCTAssertEqual(Set(ids), Set(r.meetings.map(\.id)))
            XCTAssertEqual(ids.count, Set(ids).count)
        }
        XCTAssertEqual(make([tomorrow]).later.map(\.id), ["tomorrow"])
    }
    func testFutureHorizonExcludesEventsFromAnUnrelatedLoadedMonth() {
        let far = event("far", "2026-12-22T13:00:00+03:00", "2026-12-22T14:00:00+03:00")
        XCTAssertTrue(make([far]).meetings.isEmpty)
    }
    func testTodaySpansDSTCalendarDayRatherThanFixed86400Seconds() {
        var local = calendar; local.timeZone = TimeZone(identifier: "America/New_York")!
        let time = date("2026-03-08T12:00:00-04:00")
        let dayEnd = event("dayEnd", "2026-03-08T23:30:00-04:00", "2026-03-08T23:45:00-04:00")
        let tomorrow = event("tomorrow", "2026-03-09T00:15:00-04:00", "2026-03-09T00:30:00-04:00")
        let r = MenuSchedule(meetings: [dayEnd, tomorrow], mode: .allToday, visibleCalendarIDs: ["visible"],
            account: "me@example.org", now: time, calendar: local)
        XCTAssertEqual(r.meetings.map(\.id), ["dayEnd"])
    }
    func testMenuModeDoesNotChangeReminderSelection() {
        let displayed = make([future], .currentOnly)
        XCTAssertTrue(displayed.meetings.isEmpty)
        let plans = ReminderPlanner.plan(meetings: [future], state: PersonalCalendarState(), defaults: [15, 5],
            calendarIDs: ["visible"], account: "me@example.org", now: now)
        XCTAssertEqual(plans.count, 2)
    }
    func testNewPreferenceMigratesAndUnknownValuesPreserveAccount() throws {
        for raw in ["{}", #"{"login":"work@example.org","menuMeetingsMode":"future-version"}"#,
                    #"{"login":"work@example.org","menuMeetingsMode":5}"#] {
            let config = try JSONDecoder().decode(CalendarConfiguration.self, from: Data(raw.utf8))
            XCTAssertEqual(config.menuMeetingsMode, .currentAndUpcoming)
            if raw != "{}" { XCTAssertEqual(config.login, "work@example.org") }
        }
        for mode in MenuMeetingsMode.allCases {
            var config = CalendarConfiguration(); config.login = "me@example.org"; config.menuMeetingsMode = mode
            let restored = try JSONDecoder().decode(CalendarConfiguration.self, from: JSONEncoder().encode(config))
            XCTAssertEqual(restored, config)
        }
    }
    func testLegacyTemplatesDoNotDiscardRemindersOrHiddenCalendarsOnUpgrade() throws {
        let json = #"{"hiddenCalendars":["hidden"],"overrides":{"meeting":{"muted":true}},"templates":[{"id":"11111111-1111-1111-1111-111111111111","title":"Старая встреча","durationMinutes":30,"details":"Описание","location":"","link":""}]}"#
        let old = try JSONDecoder().decode(PersonalCalendarState.self, from: Data(json.utf8))
        let new = try JSONDecoder().decode(PersonalCalendarState.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(new.hiddenCalendars, ["hidden"])
        XCTAssertEqual(new.overrides["meeting"]?.muted, true)
        XCTAssertEqual(new.templates, old.templates)
    }
}
