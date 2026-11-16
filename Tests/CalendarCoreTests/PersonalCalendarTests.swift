import XCTest
@testable import CalendarCore

final class PersonalCalendarTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func meeting(start: Date? = nil, end: Date? = nil, cancelled: Bool = false, link: URL? = nil) -> Meeting {
        Meeting(id: "c|u|master", seriesID: "c|u", calendarID: "c", calendarName: "Рабочий", title: "Планёрка",
            start: start ?? now.addingTimeInterval(1800), end: end ?? now.addingTimeInterval(3600), allDay: false,
            details: "Обсудить поставки", location: "Москва", link: link,
            attendees: [Attendee(email: "anna@example.org", name: "Анна", optional: false, response: "ACCEPTED")], organizer: "boss@example.org", cancelled: cancelled)
    }
    func testDefaultRemindersAreDeduplicatedAndSortedByFireDate() {
        let plans = ReminderPlanner.plan(meetings: [meeting()], state: PersonalCalendarState(), defaults: [5, 15, 15], calendarIDs: ["c"], account: "me", now: now)
        XCTAssertEqual(plans.map(\.minutes), [15, 5]); XCTAssertTrue(plans.allSatisfy { $0.date > now })
    }
    func testOccurrenceOverrideTakesPrecedenceOverSeries() {
        let event = meeting(); var state = PersonalCalendarState()
        state.overrides["series:" + event.seriesID] = ReminderOverride(muted: true)
        state.overrides[event.id] = ReminderOverride(minutes: [2])
        let plans = ReminderPlanner.plan(meetings: [event], state: state, defaults: [15, 5], calendarIDs: ["c"], account: "me", now: now)
        XCTAssertEqual(plans.map(\.minutes), [2])
    }
    func testMutedEventHasNoDefaultOrSnoozedReminders() {
        let event = meeting(); var state = PersonalCalendarState()
        state.overrides[event.id] = ReminderOverride(muted: true)
        state.snoozes = [SnoozedReminder(meeting: event, fireAt: now.addingTimeInterval(300))]
        XCTAssertTrue(ReminderPlanner.plan(meetings: [event], state: state, defaults: [15], calendarIDs: ["c"], account: "me", now: now).isEmpty)
    }
    func testSnoozeSuppressesEarlierDefaultsButKeepsLaterOne() {
        let event = meeting(); var state = PersonalCalendarState()
        state.snoozes = [SnoozedReminder(meeting: event, fireAt: now.addingTimeInterval(1200))]
        let plans = ReminderPlanner.plan(meetings: [event], state: state, defaults: [15, 5], calendarIDs: ["c"], account: "me", now: now)
        XCTAssertEqual(plans.count, 2); XCTAssertTrue(plans[0].snoozed); XCTAssertEqual(plans[1].minutes, 5)
    }
    func testMovingMeetingInvalidatesSnooze() {
        let original = meeting(); var state = PersonalCalendarState()
        state.snoozes = [SnoozedReminder(meeting: original, fireAt: now.addingTimeInterval(300))]
        let moved = meeting(start: original.start.addingTimeInterval(300))
        state.reconcileSnoozes(with: [moved], refreshedRange: now..<now.addingTimeInterval(86400), calendarIDs: ["c"], now: now)
        XCTAssertTrue(state.snoozes.isEmpty)
    }
    func testIncompleteRangeDoesNotDiscardUnrelatedSnooze() {
        let event = meeting(); var state = PersonalCalendarState()
        state.snoozes = [SnoozedReminder(meeting: event, fireAt: now.addingTimeInterval(300))]
        state.reconcileSnoozes(with: [], refreshedRange: now.addingTimeInterval(86400)..<now.addingTimeInterval(172800), calendarIDs: ["c"], now: now)
        XCTAssertEqual(state.snoozes.count, 1)
    }
    func testConfirmedRemovalDiscardsSnooze() {
        let event = meeting(); var state = PersonalCalendarState()
        state.snoozes = [SnoozedReminder(meeting: event, fireAt: now.addingTimeInterval(300))]
        state.reconcileSnoozes(with: [], refreshedRange: now..<now.addingTimeInterval(86400), calendarIDs: ["c"], now: now)
        XCTAssertTrue(state.snoozes.isEmpty)
    }
    func testSnoozeCannotOutliveEvent() {
        let event = meeting(); let snooze = SnoozedReminder(meeting: event, fireAt: event.end)
        XCTAssertFalse(snooze.isValid(for: event, now: now))
    }
    func testStateSurvivesJSONRoundTrip() throws {
        var state = PersonalCalendarState(); let event = meeting()
        state.overrides[event.id] = ReminderOverride(minutes: [7, 2]); state.hiddenCalendars = ["team"]
        state.snoozes = [SnoozedReminder(meeting: event, fireAt: now.addingTimeInterval(300))]
        state.activity = [ActivityEntry(change: MeetingChange(meeting: event, kind: .new), date: now)]
        let decoded = try JSONDecoder().decode(PersonalCalendarState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.overrides, state.overrides); XCTAssertEqual(decoded.snoozes, state.snoozes)
        XCTAssertEqual(decoded.activity, state.activity); XCTAssertEqual(decoded.hiddenCalendars, ["team"])
    }

    func testPinsPersistAndDeduplicateTelemostRoomVariants() throws {
        var state = try JSONDecoder().decode(PersonalCalendarState.self, from: Data("{}".utf8))
        let room = try XCTUnwrap(URL(string: "https://telemost.yandex.ru/j/123456"))
        let alternate = try XCTUnwrap(URL(string: "https://telemost.yandex.ru/j/123456?skip_app=1"))
        let calendarPage = try XCTUnwrap(URL(string: "https://calendar.yandex.ru/day"))
        state.togglePin(title: "Командная комната", url: room)
        state.togglePin(title: "Календарь", url: calendarPage)
        state = try JSONDecoder().decode(PersonalCalendarState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(state.pinnedMeetings.map(\.title), ["Командная комната"])
        XCTAssertTrue(state.isPinned(alternate))
        state.togglePin(title: "Другая встреча в той же комнате", url: alternate)
        XCTAssertTrue(state.pinnedMeetings.isEmpty)
    }
    func testStandalonePinsCanBeEditedAndReorderedWithoutReplacingDuplicates() throws {
        let firstURL = try XCTUnwrap(URL(string: "https://telemost.yandex.ru/j/123456"))
        let secondURL = try XCTUnwrap(URL(string: "https://telemost.yandex.ru/j/987654"))
        let first = try XCTUnwrap(PinnedMeeting(title: "  Комната команды ", url: firstURL))
        let second = try XCTUnwrap(PinnedMeeting(title: "Разбор", url: secondURL))
        var state = PersonalCalendarState()
        XCTAssertTrue(state.savePin(first))
        XCTAssertTrue(state.savePin(second))
        XCTAssertFalse(state.savePin(first, replacing: second.id))
        XCTAssertTrue(state.movePin(first.id, by: -1))
        let renamed = try XCTUnwrap(PinnedMeeting(title: "Команда", url: firstURL))
        XCTAssertTrue(state.savePin(renamed, replacing: first.id))
        XCTAssertEqual(first.title, "Комната команды")
        let decoded = try JSONDecoder().decode(PersonalCalendarState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.pinnedMeetings, [renamed, second])
    }
    func testSearchIncludesParticipantsAndRequiresAllWords() {
        XCTAssertTrue(MeetingSearch.matches(meeting(), query: "Анна поставки"))
        XCTAssertTrue(MeetingSearch.matches(meeting(), query: "ANNA@EXAMPLE.ORG"))
        XCTAssertFalse(MeetingSearch.matches(meeting(), query: "Анна отпуск"))
    }
    func testCancelledOrUnselectedCalendarsNeverGetReminders() {
        XCTAssertTrue(ReminderPlanner.plan(meetings: [meeting(cancelled: true)], state: PersonalCalendarState(), defaults: [15], calendarIDs: ["c"], account: "me", now: now).isEmpty)
        XCTAssertTrue(ReminderPlanner.plan(meetings: [meeting()], state: PersonalCalendarState(), defaults: [15], calendarIDs: [], account: "me", now: now).isEmpty)
    }
    func testChangeSummaryShowsBothOldAndNewTimes() {
        let old = meeting(), updated = meeting(start: meeting().start.addingTimeInterval(1800), end: meeting().end.addingTimeInterval(1800))
        let entry = ActivityEntry(change: MeetingChange(meeting: updated, kind: .changed, previous: old), date: now)
        XCTAssertTrue(entry.important)
        XCTAssertTrue(entry.timeChanged)
        XCTAssertFalse(entry.joinLinkChanged)
        XCTAssertTrue(entry.summary().hasPrefix("Было "))
        XCTAssertTrue(entry.summary().contains(" → стало "))
    }
    func testActivityDistinguishesAddingReplacingAndRemovingJoinLink() {
        let first = meeting(link: URL(string: "https://telemost.yandex.ru/j/1111111111"))
        let second = meeting(link: URL(string: "https://telemost.yandex.ru/j/2222222222"))
        for (old, new, summary) in [
            (meeting(), first, "Добавлена ссылка на звонок"),
            (first, second, "Сменилась ссылка на звонок"),
            (second, meeting(), "Ссылка на звонок удалена")
        ] {
            let entry = ActivityEntry(change: MeetingChange(meeting: new, kind: .changed, previous: old))
            XCTAssertTrue(entry.joinLinkChanged)
            XCTAssertFalse(entry.timeChanged)
            XCTAssertEqual(entry.summary(), summary)
        }
    }
    func testOverviewMergesOverlapsAndFindsFreeTime() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = cal.startOfDay(for: now), start = day.addingTimeInterval(9 * 3600)
        let a = meeting(start: start, end: start.addingTimeInterval(3600))
        let b = Meeting(id: "b", seriesID: "b", calendarID: "c", calendarName: "Рабочий", title: "Вторая", start: start.addingTimeInterval(1800), end: start.addingTimeInterval(5400), allDay: false, details: "", location: "", link: nil, attendees: [], organizer: "", cancelled: false)
        let overview = DayOverview.make(meetings: [a,b], day: day, calendar: cal, account: "me")
        XCTAssertEqual(overview.busyMinutes, 90); XCTAssertEqual(overview.conflicts.count, 1)
        XCTAssertEqual(overview.conflicts.first?.overlap, 1800)
        XCTAssertEqual(overview.freeSlots.first?.lowerBound, start.addingTimeInterval(5400))
        let availabilityOnly = DayOverview.make(meetings: [a,b], day: day, calendar: cal, account: "me", includeConflicts: false)
        XCTAssertTrue(availabilityOnly.conflicts.isEmpty)
        XCTAssertEqual(availabilityOnly.freeSlots, overview.freeSlots)
        XCTAssertEqual(availabilityOnly.busyMinutes, overview.busyMinutes)
    }
    func testTouchingMeetingsAreNotAConflict() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let a = meeting(start: now, end: now.addingTimeInterval(3600))
        let b = meeting(start: a.end, end: a.end.addingTimeInterval(1800))
        XCTAssertTrue(DayOverview.make(meetings: [a,b], day: now, calendar: cal, account: "me").conflicts.isEmpty)
    }

    func testPlanningFindsEveryGapAndDoesNotCoverEventsMarkedFree() {
        let cal = Calendar(identifier: .gregorian)
        let day = cal.startOfDay(for: now)
        let first = cal.date(bySettingHour: 13, minute: 0, second: 0, of: day)!
        let second = first.addingTimeInterval(105 * 60)
        let meetings = [Meeting(id: "free", seriesID: "free", calendarID: "c", calendarName: "Работа",
            title: "Событие", start: first, end: first.addingTimeInterval(10 * 60), allDay: false,
            details: "", location: "", link: nil, attendees: [], organizer: "", cancelled: false, isFree: true),
            meeting(start: second, end: second.addingTimeInterval(60 * 60))]
        let slots = DayOverview.make(meetings: meetings, day: day, calendar: cal, account: "me",
            minimumMinutes: 1, includeConflicts: false, blockAllTimedEvents: true).freeSlots
        XCTAssertEqual(slots.count, 3)
        XCTAssertEqual(slots[1], first.addingTimeInterval(10 * 60)..<second)
        XCTAssertEqual(slots[2].lowerBound, second.addingTimeInterval(60 * 60))
    }

    func testPlanningClampsDurationAndDoesNotStartInThePast() {
        let start = Date(timeIntervalSinceReferenceDate: 3600)
        let end = start.addingTimeInterval(12 * 60)
        let slot = start..<end
        XCTAssertEqual(FreeSlotPlanning.eventRange(in: slot, at: start.addingTimeInterval(1)),
                       start.addingTimeInterval(60)..<end)
        XCTAssertNil(FreeSlotPlanning.eventRange(in: slot, at: end))
    }
}
