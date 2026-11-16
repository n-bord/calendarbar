import AppKit
import SwiftUI
import CalendarCore

private struct ScheduleScrollKey: Hashable {
    let day: Date
    let id: UUID
}

struct ScheduleCalendar: View {
    @ObservedObject var model: AppModel
    let days: [Date]
    let meetings: [Meeting]
    let selectedID: String?
    let selectedDay: Date
    let scrollDate: Date
    let scrollID: UUID
    let loading: Bool
    let complete: Bool
    let account: String
    let selectDay: (Date) -> Void
    let select: (Meeting, Date) -> Void
    let create: (Date) -> Void
    let previousMonth: () -> Void
    let nextMonth: () -> Void

    private var targetDay: Date {
        let day = CalendarDates.calendar.startOfDay(for: scrollDate)
        guard let first = days.first, let last = days.last else { return day }
        return min(max(day, first), last)
    }
    private var scrollKey: ScheduleScrollKey {
        ScheduleScrollKey(day: targetDay, id: scrollID)
    }

    var body: some View {
        ScrollViewReader { proxy in
            agendaContent.task(id: scrollKey) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(targetDay, anchor: .top) }
            }
        }.id(days.first)
    }

    private var agendaContent: some View {
        let selection = CalendarDates.calendar.startOfDay(for: selectedDay)
        let populated = days.filter { $0 == targetDay || $0 == selection || !CalendarDates.events(meetings, on: $0).isEmpty }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                HStack {
                    Button(action: previousMonth) { Label("Предыдущий месяц", systemImage: "chevron.left") }
                    Spacer()
                    Text("Все встречи месяца, включая прошедшие").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
                if populated.isEmpty {
                    Text("Нет загруженных событий по выбранным календарям и условиям поиска.")
                        .foregroundStyle(.secondary).padding(24)
                }
                ForEach(populated, id: \.self) { day in
                    Section {
                        let events = CalendarDates.events(meetings, on: day)
                        if events.isEmpty {
                            Text(loading ? "Загружаю встречи…" : (complete ? "В этот день встреч нет по выбранным календарям и условиям поиска." : "За этот день пока нет загруженных встреч."))
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        }
                        ForEach(events) { meeting in
                            row(meeting, day: day)
                        }
                    } header: {
                        let selected = day == selection
                        HStack(spacing: 10) {
                            Button { selectDay(day) } label: {
                                HStack(spacing: 10) {
                                    Text(CalendarDates.text(day, "d")).font(.title2.weight(.semibold))
                                        .foregroundStyle(CalendarDates.calendar.isDateInToday(day) ? AppTheme.controlAccent : .primary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(CalendarDates.text(day, "EEEE").capitalized).fontWeight(.semibold)
                                        Text((CalendarDates.calendar.isDateInToday(day) ? "Сегодня · " : "") + CalendarDates.text(day, "MMMM yyyy"))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(CalendarDates.text(day, "EEEE, d MMMM yyyy"))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .help("Показать сводку за " + CalendarDates.text(day, "d MMMM"))
                            Button { create(CalendarDates.defaultStart(on: day)) } label: {
                                Label("Создать событие", systemImage: "plus").labelStyle(.iconOnly)
                            }
                                .buttonStyle(.borderless).help("Создать событие в этот день в браузере")
                        }.padding(.vertical, 12).padding(.horizontal, 16)
                            .background {
                                AppTheme.calendarChrome
                                    .overlay(selected ? AppTheme.controlAccent.opacity(0.15) : .clear)
                            }
                    }.id(day)
                }
                Button(action: nextMonth) { Label("Следующий месяц", systemImage: "chevron.right") }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }.padding(.horizontal, 12).padding(.bottom, 16)
        }
    }

    private func row(_ meeting: Meeting, day: Date) -> some View {
        let response = meeting.invitationStatus(for: account)
        return HStack(alignment: .center, spacing: 12) {
            Button { select(meeting, day) } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meeting.allDay ? "Весь день" : CalendarDates.text(meeting.start, "HH:mm")).fontWeight(.medium)
                        if !meeting.allDay { Text(CalendarDates.text(meeting.end, "HH:mm")).foregroundStyle(.secondary) }
                    }.font(.caption).frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            InvitationStatusLabel(status: response, iconOnly: true)
                            Text(meeting.title).fontWeight(.medium).strikethrough(response == .declined)
                        }
                        Text(meeting.calendarName + (meeting.location.isEmpty ? "" : " · " + meeting.location))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(meeting.title), \(meeting.allDay ? "весь день" : CalendarDates.text(meeting.start, "HH:mm")), \(response.title)")
                .help(meeting.title + " · " + response.title)
            JoinMeetingButton(url: meeting.joinURL, symbolOnly: true).buttonStyle(.bordered)
        }.padding(12)
            .calendarEventCard(color: AppTheme.meetingColor(meeting, model: model), selected: selectedID == meeting.id, cornerRadius: 8)
            .contextMenu { MeetingTintMenu(model: model, meeting: meeting) }
            .opacity(response == .declined ? 0.6 : 1)
    }
}
