import CalendarCore
import Foundation

/// Local fixtures for the separately bundled demo. Dates follow the current week
/// so the same gallery can be reproduced without setting the system clock.
struct DemoCalendar {
    struct Profile {
        let login: String
        let label: String
        let calendars: [CalendarInfo]
        let meetings: [Meeting]
        let personal: PersonalCalendarState
    }

    let now: Date
    let range: Range<Date>
    let profiles: [Profile]

    init(today: Date = Date(), calendar: Calendar = CalendarDates.calendar) {
        func day(_ offset: Int) -> Date {
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: today)!)
        }
        func time(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day(offset))!
        }
        let team = "team@example.test"
        let personal = "personal@example.test"
        let shared = CalendarInfo(id: "demo-team", name: "Командный календарь")
        let project = CalendarInfo(id: "demo-project", name: "Проект Север")
        let plans = CalendarInfo(id: "demo-personal", name: "Личные планы")
        let room = URL(string: "https://example.test/meet/design-review")!
        let people = [
            Attendee(email: "alex@example.test", name: "Алекс Миронов", optional: false, response: "ACCEPTED"),
            Attendee(email: "irina@example.test", name: "Ирина Волкова", optional: false, response: "ACCEPTED")
        ]
        func event(_ id: String, _ title: String, _ source: CalendarInfo, _ start: Date, minutes: Int = 45,
                   allDayEnd: Date? = nil, details: String = "", link: URL? = nil,
                   recurring: Bool = false, attendees: [Attendee] = []) -> Meeting {
            Meeting(id: id, seriesID: recurring ? "demo-daily" : id, calendarID: source.id,
                    calendarName: source.name, title: title, start: start,
                    end: allDayEnd ?? start.addingTimeInterval(Double(minutes) * 60),
                    allDay: allDayEnd != nil, details: details, location: "", link: link,
                    attendees: attendees, organizer: source == plans ? personal : team,
                    cancelled: false, recurrenceRule: recurring ? "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR" : nil)
        }

        now = time(0, 11, 12)
        range = day(-35)..<day(56)
        let review = event("design", "Дизайн-ревью", project, time(0, 11, 25), minutes: 35,
            details: "Проверяем сценарий подключения, макеты календаря и список задач к демо проекта.",
            link: room, attendees: people)
        let showcase = event("showcase", "Демо проекта", project, time(2, 14), minutes: 60,
            details: "Показываем прототип и собираем вопросы команды.", link: room, attendees: people)
        var teamMeetings = (-6...6).compactMap { offset -> Meeting? in
            guard !calendar.isDateInWeekend(day(offset)) else { return nil }
            return event("daily-\(offset)", "Синхронизация команды", shared, time(offset, 9, 30),
                         minutes: 20, recurring: true)
        }
        teamMeetings += [
            event("planning", "Планирование недели", shared, time(-1, 10), minutes: 50),
            review,
            event("roadmap", "Обсуждение дорожной карты", shared, time(0, 14), minutes: 50),
            event("notes", "Работа над прототипом", project, time(1, 11), minutes: 100),
            event("handoff", "Передача макетов", project, time(1, 15, 30), minutes: 50),
            showcase,
            event("release", "Неделя запуска", project, day(0), allDayEnd: day(1))
        ]
        let personalMeetings = [
            event("reading", "Книжный клуб", plans, time(-1, 16), minutes: 60),
            event("lunch", "Обед", plans, time(0, 13), minutes: 45),
            event("workout", "Тренировка", plans, time(2, 17), minutes: 60)
        ]
        var teamSettings = PersonalCalendarState()
        teamSettings.setCalendarTint(.green, for: shared.id)
        teamSettings.setCalendarTint(.violet, for: project.id)
        if let pin = PinnedMeeting(title: "Комната команды", url: room) { teamSettings.savePin(pin) }
        teamSettings.activity = [ActivityEntry(change: MeetingChange(meeting: showcase, kind: .new), date: time(0, 10, 50))]
        var personalSettings = PersonalCalendarState()
        personalSettings.setCalendarTint(.orange, for: plans.id)
        profiles = [
            Profile(login: team, label: "Команда", calendars: [shared, project], meetings: teamMeetings, personal: teamSettings),
            Profile(login: personal, label: "Личный", calendars: [plans], meetings: personalMeetings, personal: personalSettings)
        ]
    }
}
