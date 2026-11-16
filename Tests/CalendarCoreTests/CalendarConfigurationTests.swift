import XCTest
import Foundation
@testable import CalendarCore

private struct LegacyConfiguration: Decodable {
    let login: String
    let zone: String
    let calendarIDs: [String]
    let notifyNew: Bool
    let notifyChanges: Bool
    let reminders: Bool
}

final class CalendarConfigurationTests: XCTestCase {
    private func decode(_ json: String) throws -> CalendarConfiguration {
        try JSONDecoder().decode(CalendarConfiguration.self, from: Data(json.utf8))
    }

    func testOldEnabledSettingsKeepTheAccountAndDefaultReminders() throws {
        let config = try decode(#"{"login":"work@example.org","zone":"Asia/Yekaterinburg","calendarIDs":["work"],"notifyNew":false,"notifyChanges":true,"reminders":true}"#)
        XCTAssertEqual(config.login, "work@example.org")
        XCTAssertEqual(config.zone, "Asia/Yekaterinburg")
        XCTAssertEqual(config.calendarIDs, ["work"])
        XCTAssertFalse(config.notifyNew); XCTAssertTrue(config.notifyChanges)
        XCTAssertEqual(config.reminderMinutes, [15, 5])
        XCTAssertEqual(config.menuCountdownWindow, .oneHour)
    }

    func testOldDisabledRemindersStayDisabledAfterMigration() throws {
        let config = try decode(#"{"login":"work@example.org","reminders":false}"#)
        XCTAssertFalse(config.firstReminderEnabled); XCTAssertFalse(config.secondReminderEnabled)
        XCTAssertTrue(config.reminderMinutes.isEmpty)
        XCTAssertEqual(config.firstReminderMinutes, 15); XCTAssertEqual(config.secondReminderMinutes, 5)
    }

    func testCustomMinutesAndIndependentSwitchesSurviveRelaunch() throws {
        var config = CalendarConfiguration()
        config.login = "work@example.org"
        config.firstReminderMinutes = 45; config.secondReminderMinutes = 7
        config.firstReminderEnabled = false; config.secondReminderEnabled = true
        config.menuCountdownWindow = .threeHours
        let restored = try JSONDecoder().decode(CalendarConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored, config)
        XCTAssertEqual(restored.reminderMinutes, [7])
    }

    func testEqualOffsetsProduceOnlyOneReminder() {
        var config = CalendarConfiguration()
        config.firstReminderMinutes = 10; config.secondReminderMinutes = 10
        XCTAssertEqual(config.reminderMinutes, [10])
    }

    func testSlotsCanBeEnabledSeparatelyOrBothDisabled() {
        var config = CalendarConfiguration()
        config.secondReminderEnabled = false
        XCTAssertEqual(config.reminderMinutes, [15])
        config.firstReminderEnabled = false; config.secondReminderEnabled = true
        XCTAssertEqual(config.reminderMinutes, [5])
        config.secondReminderEnabled = false
        XCTAssertTrue(config.reminderMinutes.isEmpty)
    }

    func testInvalidNewFieldsDoNotDiscardTheSavedAccount() throws {
        let config = try decode(#"{"login":"work@example.org","firstReminderMinutes":0,"secondReminderMinutes":999999,"menuCountdownMinutes":999}"#)
        XCTAssertEqual(config.login, "work@example.org")
        XCTAssertEqual(config.firstReminderMinutes, 1)
        XCTAssertEqual(config.secondReminderMinutes, 1440)
        XCTAssertEqual(config.menuCountdownWindow, .oneHour)
        let badType = try decode(#"{"login":"work@example.org","firstReminderMinutes":"bad","menuCountdownMinutes":"bad"}"#)
        XCTAssertEqual(badType.login, "work@example.org")
        XCTAssertEqual(badType.firstReminderMinutes, 15)
        XCTAssertEqual(badType.menuCountdownWindow, .oneHour)
    }

    func testNewSettingsRemainReadableByOlderVersions() throws {
        var config = CalendarConfiguration()
        config.login = "work@example.org"; config.calendarIDs = ["work"]
        config.firstReminderEnabled = false; config.secondReminderEnabled = true
        var old = try JSONDecoder().decode(LegacyConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(old.login, config.login); XCTAssertEqual(old.calendarIDs, config.calendarIDs)
        XCTAssertTrue(old.reminders)
        config.secondReminderEnabled = false
        old = try JSONDecoder().decode(LegacyConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertFalse(old.reminders)
    }

    func testCountdownStartsAtEachSelectedBoundary() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(MenuCountdownWindow, TimeInterval, String)] = [
            (.fifteenMinutes, 900, "15 мин"), (.thirtyMinutes, 1800, "30 мин"),
            (.oneHour, 3600, "1 ч"), (.threeHours, 10800, "3 ч")
        ]
        for (window, seconds, expected) in cases {
            XCTAssertEqual(window.label(start: now.addingTimeInterval(seconds), now: now), expected)
            XCTAssertEqual(window.label(start: now.addingTimeInterval(seconds + 1), now: now), "")
        }
    }

    func testCountdownFormatsHoursAndRoundsUpRemainingMinutes() {
        let now = Date()
        XCTAssertEqual(MenuCountdownWindow.threeHours.label(start: now.addingTimeInterval(4800), now: now), "1 ч 20 мин")
        XCTAssertEqual(MenuCountdownWindow.oneHour.label(start: now.addingTimeInterval(61), now: now), "2 мин")
        XCTAssertEqual(MenuCountdownWindow.oneHour.label(start: now.addingTimeInterval(1), now: now), "1 мин")
    }

    func testOngoingMeetingAndHiddenCountdown() {
        let now = Date()
        XCTAssertEqual(MenuCountdownWindow.oneHour.label(start: now, now: now), "идёт встреча")
        XCTAssertEqual(MenuCountdownWindow.oneHour.label(start: now.addingTimeInterval(-60), now: now), "идёт встреча")
        XCTAssertEqual(MenuCountdownWindow.hidden.label(start: now.addingTimeInterval(60), now: now), "")
        XCTAssertEqual(MenuCountdownWindow.hidden.label(start: now.addingTimeInterval(-60), now: now), "")
    }

    func testIndividualNewSwitchesOverrideTheLegacyFlag() throws {
        let config = try decode(#"{"reminders":false,"firstReminderEnabled":true,"secondReminderEnabled":false,"firstReminderMinutes":25}"#)
        XCTAssertEqual(config.reminderMinutes, [25])
    }
    func testExtendedPreferencesSurviveRoundTrip() throws {
        var value = CalendarConfiguration()
        value.notifyMinorChanges = true; value.dailyOverviewEnabled = true; value.dailyOverviewHour = 7; value.dailyOverviewMinute = 30
        value.workdayStartHour = 8; value.workdayEndHour = 21
        XCTAssertEqual(try JSONDecoder().decode(CalendarConfiguration.self, from: JSONEncoder().encode(value)), value)
    }
    func testExtendedPreferencesMigrateAndClampHours() throws {
        let data = Data("{\"workdayStartHour\":23,\"workdayEndHour\":0,\"dailyOverviewHour\":99}".utf8)
        let value = try JSONDecoder().decode(CalendarConfiguration.self, from: data)
        XCTAssertEqual(value.workdayStartHour, 23); XCTAssertEqual(value.workdayEndHour, 24)
        XCTAssertEqual(value.dailyOverviewHour, 23); XCTAssertFalse(value.dailyOverviewEnabled)
        XCTAssertEqual(value.dailyOverviewMinute, 0)
        XCTAssertFalse(value.notifyMinorChanges)
    }

    func testMorningOverviewUsesSelectedMinutesAndMovesToTomorrowAfterTheDeadline() throws {
        var configuration = CalendarConfiguration()
        configuration.dailyOverviewMinute = 30
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Moscow"))
        let before = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 9, minute: 29)))
        let fire = try XCTUnwrap(configuration.nextDailyOverview(after: before, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.day, .hour, .minute], from: fire),
                       DateComponents(day: 13, hour: 9, minute: 30))
        let tomorrow = try XCTUnwrap(configuration.nextDailyOverview(after: fire, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.day, .hour, .minute], from: tomorrow),
                       DateComponents(day: 14, hour: 9, minute: 30))
    }

    func testBackgroundRefreshWaitsForSelectedIntervalAfterTheLastAttempt() {
        let attempt = Date(timeIntervalSince1970: 1_700_000_000)
        for interval in CalendarRefreshInterval.allCases {
            XCTAssertTrue(interval.isDue(after: nil, at: attempt))
            XCTAssertFalse(interval.isDue(after: attempt, at: attempt.addingTimeInterval(interval.seconds - 1)))
            XCTAssertTrue(interval.isDue(after: attempt, at: attempt.addingTimeInterval(interval.seconds)))
            XCTAssertTrue(interval.isDue(after: attempt, at: attempt.addingTimeInterval(-1)))
        }
        XCTAssertEqual(CalendarRefreshInterval.recommended.seconds, 300)
    }

    func testRefreshScheduleUsesWorkingHoursAndResumesAfterTheWeekend() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Moscow"))
        let dates = ISO8601DateFormatter()
        let friday = try XCTUnwrap(dates.date(from: "2026-11-13T17:58:00+03:00"))
        let closing = try XCTUnwrap(dates.date(from: "2026-11-13T18:00:00+03:00"))
        let saturday = try XCTUnwrap(dates.date(from: "2026-11-14T10:00:00+03:00"))
        let monday = try XCTUnwrap(dates.date(from: "2026-11-16T09:00:00+03:00"))
        let paused = CalendarRefreshSchedule(duringWorkday: .fiveMinutes, outsideWorkday: nil, startHour: 9, endHour: 18)
        XCTAssertEqual(paused.interval(at: friday, calendar: calendar), .fiveMinutes)
        XCTAssertEqual(paused.nextCheck(after: friday, lastAttempt: friday, calendar: calendar), closing)
        XCTAssertNil(paused.interval(at: closing, calendar: calendar))
        XCTAssertNil(paused.interval(at: saturday, calendar: calendar))
        XCTAssertEqual(paused.nextCheck(after: closing, lastAttempt: friday, calendar: calendar), monday)
        XCTAssertEqual(paused.nextCheck(after: saturday, lastAttempt: nil, calendar: calendar), monday)
        XCTAssertEqual(paused.interval(at: monday, calendar: calendar), .fiveMinutes)
        XCTAssertEqual(paused.nextCheck(after: monday, lastAttempt: friday, calendar: calendar), monday)
    }

    func testRefreshScheduleShortensIntervalAtOpeningAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let dates = ISO8601DateFormatter()
        let sunday = try XCTUnwrap(dates.date(from: "2026-03-08T22:00:00-04:00"))
        let beforeOpening = try XCTUnwrap(dates.date(from: "2026-03-09T08:50:00-04:00"))
        let monday = try XCTUnwrap(dates.date(from: "2026-03-09T09:00:00-04:00"))
        let schedule = CalendarRefreshSchedule(duringWorkday: .fiveMinutes, outsideWorkday: .oneHour, startHour: 9, endHour: 24)
        XCTAssertEqual(schedule.interval(at: sunday, calendar: calendar), .oneHour)
        XCTAssertEqual(schedule.nextCheck(after: sunday, lastAttempt: sunday, calendar: calendar),
                       sunday.addingTimeInterval(3600))
        XCTAssertEqual(schedule.nextCheck(after: beforeOpening, lastAttempt: beforeOpening, calendar: calendar), monday)
        XCTAssertEqual(schedule.nextCheck(after: monday, lastAttempt: beforeOpening, calendar: calendar), monday)
        let paused = CalendarRefreshSchedule(duringWorkday: .fiveMinutes, outsideWorkday: nil, startHour: 9, endHour: 24)
        let friday = try XCTUnwrap(dates.date(from: "2026-03-06T23:00:00-05:00"))
        let saturday = try XCTUnwrap(dates.date(from: "2026-03-07T00:00:00-05:00"))
        XCTAssertEqual(paused.interval(at: friday, calendar: calendar), .fiveMinutes)
        XCTAssertEqual(paused.nextCheck(after: saturday, lastAttempt: friday, calendar: calendar), monday)
    }
}
