import AppKit
import SwiftUI
import UserNotifications
import CalendarCore

/// A badge indicates unread changes, never merely the availability of the history window.
struct ActivityButton: View {
    @ObservedObject var model: AppModel
    private var hint: String {
        model.unreadChanges > 0 ? "Изменения и напоминания · непрочитанных: \(model.unreadChanges)"
            : "Изменения и напоминания · непрочитанных нет"
    }
    var body: some View {
        Button { AppWindows.showActivity() } label: {
            HStack(spacing: 3) {
                Image(systemName: model.unreadChanges > 0 ? "bell.badge" : "bell")
                if model.unreadChanges > 0 { Text("\(model.unreadChanges)").font(.caption.bold()) }
            }
        }.buttonStyle(.borderless).help(hint).accessibilityLabel(hint)
    }
}

struct ReadinessView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GroupBox("Готовность приложения") {
            VStack(alignment: .leading, spacing: 9) {
                row("Аккаунт", value: model.connectionState.title, ready: model.connectionState == .connected)
                row("Расписание", value: model.lastSync.map { "Обновлено " + $0.formatted(date: .omitted, time: .shortened) } ?? "Первая загрузка ещё не завершена", ready: model.lastSync != nil && model.connectionState == .connected)
                row("Уведомления", value: model.notificationAuthorization == .authorized || model.notificationAuthorization == .provisional ? "Разрешены macOS" : "Требуют проверки в настройках", ready: model.notificationAuthorization == .authorized || model.notificationAuthorization == .provisional)
                row("Календари", value: "Для напоминаний выбрано: \(model.notifyingCalendarIDs.count)", ready: !model.notifyingCalendarIDs.isEmpty)
            }.padding(8)
        }
    }
    private func row(_ title: String, value: String, ready: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ready ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) { Text(title).fontWeight(.medium); Text(value).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct ActivityView: View {
    @ObservedObject var model: AppModel
    @State private var unreadOnly = false
    @State private var copiedEntryID: String?

    var body: some View {
        let now = Date()
        let calendar = CalendarDates.calendar
        let snoozes = model.activeSnoozes.filter { $0.fireAt > now }.sorted { $0.fireAt < $1.fireAt }
        let history = model.activeActivity
        let visibleEntries = history.filter { !unreadOnly || !$0.entry.read }
        let groups = Dictionary(grouping: visibleEntries) { calendar.startOfDay(for: $0.entry.date) }

        VStack(alignment: .leading, spacing: 0) {
            header(hasHistory: !history.isEmpty)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !snoozes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            sectionTitle("Отложенные напоминания")
                            ForEach(snoozes) { reminderRow($0) }
                        }
                    }
                    if visibleEntries.isEmpty {
                        emptyState
                    }
                    ForEach(groups.keys.sorted(by: >), id: \.self) { day in
                        VStack(alignment: .leading, spacing: 4) {
                            sectionTitle(dayTitle(day, now: now, calendar: calendar))
                            ForEach(groups[day] ?? [], id: \.id) { item in
                                historyRow(item.entry, login: item.login)
                            }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
        }
        .background(AppTheme.calendarChrome)
        .tint(AppTheme.controlAccent)
    }

    private func header(hasHistory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Изменения и напоминания")
                .font(.system(size: 24, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 12) {
                Picker("Фильтр истории", selection: $unreadOnly) {
                    Text("Все").tag(false)
                    Text("Непрочитанные").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()
                Menu {
                    Button("Отметить всё прочитанным") { model.markChangesRead() }
                        .disabled(model.unreadChanges == 0)
                    Button("Очистить историю", role: .destructive) { model.clearActivity() }
                        .disabled(!hasHistory)
                } label: {
                    Label("Действия с историей", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Действия с историей")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(unreadOnly ? "Непрочитанных изменений нет" : "Изменений пока нет",
                  systemImage: unreadOnly ? "checkmark.circle" : "clock.arrow.circlepath")
                .font(.headline)
            if !unreadOnly {
                Text("Здесь появятся новые встречи, переносы и отмены после проверки календаря.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Сегодня" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Вчера" }
        let format = calendar.isDate(day, equalTo: now, toGranularity: .year) ? "d MMMM" : "d MMMM yyyy"
        return CalendarDates.text(day, format)
    }

    private func reminderRow(_ snooze: SnoozedReminder) -> some View {
        HStack(spacing: 10) {
            Button {
                AppWindows.showMeeting(model.currentMeeting(id: snooze.id) ?? snooze.meeting)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bell")
                        .foregroundStyle(AppTheme.controlAccent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snooze.meeting.title).fontWeight(.medium)
                        Text(CalendarDates.text(snooze.fireAt, "d MMM, HH:mm"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button("Убрать") { model.cancelSnooze(snooze.meeting) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Отменить отложенное напоминание")
        }
        .padding(12)
        .background(AppTheme.telemostGreen.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func historyRow(_ entry: ActivityEntry, login: String) -> some View {
        let meeting = model.activityMeeting(entry.meeting, login: login)
        let hasActions = entry.timeChanged || entry.joinLinkChanged
        let current = hasActions ? model.currentMeeting(id: meeting.id) ?? meeting : meeting
        let copyURL = entry.joinLinkChanged ? current.joinURL : nil
        let summary = entry.summary()
        let rowID = CalendarAccountIdentity.scoped(entry.id, to: login)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                model.readActivity(entry.id, login: login)
                AppWindows.showMeeting(model.currentMeeting(id: meeting.id) ?? meeting)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(entry.read ? Color.clear : AppTheme.controlAccent)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.title).font(.caption.weight(.semibold))
                                .foregroundStyle(entry.read ? Color.secondary : AppTheme.controlAccent)
                            Spacer(minLength: 4)
                            Text(CalendarDates.text(entry.date, "HH:mm"))
                                .monospacedDigit()
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(meeting.title).font(.callout.weight(.semibold))
                            .multilineTextAlignment(.leading)
                        if !meeting.calendarName.isEmpty {
                            Text(meeting.calendarName).font(.caption).foregroundStyle(.secondary)
                        }
                        if summary != entry.title {
                            Text(summary).font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        .padding(.top, 2).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(entry.read ? "Прочитано" : "Не прочитано")
            if !current.cancelled && (entry.timeChanged || copyURL != nil) {
                HStack(spacing: 10) {
                    if entry.timeChanged {
                        Button {
                            model.readActivity(entry.id, login: login)
                            model.focusInCalendar(current)
                        } label: {
                            Label("Показать новое время", systemImage: "calendar")
                        }
                    }
                    if let url = copyURL {
                        Button {
                            NSPasteboard.general.clearContents()
                            if NSPasteboard.general.setString(url.absoluteString, forType: .string) {
                                copiedEntryID = rowID
                            }
                        } label: {
                            Label(copiedEntryID == rowID ? "Скопировано" : "Копировать ссылку",
                                  systemImage: copiedEntryID == rowID ? "checkmark" : "link")
                        }
                        .task(id: copiedEntryID == rowID) {
                            guard copiedEntryID == rowID else { return }
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            if !Task.isCancelled && copiedEntryID == rowID { copiedEntryID = nil }
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.leading, 16)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(entry.read ? 0.025 : 0.055), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DayOverviewView: View {
    @ObservedObject var model: AppModel
    let day: Date
    let meetings: [Meeting]
    var compact = false
    var plan: ((Range<Date>) -> Void)? = nil
    var body: some View {
        let overview = model.overview(on: day, from: meetings)
        return VStack(alignment: .leading, spacing: 9) {
            Text("Встреч: \(overview.meetings.count) · занято \(overview.busyMinutes / 60) ч \(overview.busyMinutes % 60) мин в рабочее время").font(.caption).foregroundStyle(.secondary)
            if !overview.conflicts.isEmpty {
                if compact { Label("Пересечений: \(overview.conflicts.count)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                else {
                    DisclosureGroup("Пересечения: \(overview.conflicts.count)") {
                        ForEach(overview.conflicts) { conflict in
                            Button {
                                AppWindows.showMeeting(conflict.first)
                            } label: {
                                Text(conflict.first.title + " ↔ " + conflict.second.title + " · \(Int(conflict.overlap / 60)) мин")
                                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).padding(.vertical, 3)
                        }
                    }.font(.caption).foregroundStyle(.orange)
                }
            }
            if !compact {
                let slots = model.visibleCalendarIDs.isEmpty ? [] : model.planningSlots(on: day, from: meetings)
                DisclosureGroup("Свободные промежутки · \(slots.count)") {
                    if slots.isEmpty { Text("Свободных промежутков в рабочее время нет").font(.caption).foregroundStyle(.secondary) }
                    ForEach(slots, id: \.self) { slot in
                        HStack {
                            Text(CalendarDates.text(slot.lowerBound, "HH:mm") + " — " + CalendarDates.text(slot.upperBound, "HH:mm")).font(.caption)
                            Spacer()
                            if let plan, FreeSlotPlanning.eventRange(in: slot, at: Date()) != nil {
                                Button("Запланировать ↗") { plan(slot) }.font(.caption).buttonStyle(.borderless)
                            }
                        }.padding(.vertical, 3)
                    }
                    Text("По видимым календарям и загруженным событиям со временем.").font(.caption2).foregroundStyle(.secondary)
                }.font(.caption)
            }
        }
    }
}

struct ReminderEditor: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss
    @State private var scope = EventScope.occurrence
    @State private var mode = 0
    @State private var first = 15
    @State private var second = 5
    @State private var secondEnabled = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Личные напоминания").font(.title2.bold())
            Text(meeting.title).fontWeight(.medium)
            if meeting.isRecurring {
                Picker("Применить к", selection: $scope) { ForEach(EventScope.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .onChange(of: scope) { _ in load() }
            }
            Picker("Режим", selection: $mode) {
                Text(inheritsSeries ? "Как у серии" : "По умолчанию").tag(0)
                Text("Свои интервалы").tag(1)
                Text("Не напоминать").tag(2)
            }.pickerStyle(.radioGroup)
            if mode == 1 {
                HStack { Text("Напомнить за"); TextField("Минуты", value: $first, format: .number).frame(width: 70); Stepper("Минуты", value: $first, in: 1...1440).labelsHidden(); Text("мин.") }
                HStack { Toggle("Повторно за", isOn: $secondEnabled); TextField("Минуты", value: $second, format: .number).frame(width: 70).disabled(!secondEnabled); Stepper("Минуты", value: $second, in: 1...1440).labelsHidden().disabled(!secondEnabled); Text("мин.") }
            }
            Text("Только для вас на этом Mac. Организатору не отправляется. Настройка серии заменяет личные исключения её отдельных встреч.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction); Spacer()
                Button("Сохранить") {
                    let setting: ReminderOverride? = mode == 0 ? nil : ReminderOverride(muted: mode == 2, minutes: mode == 1 ? [first] + (secondEnabled ? [second] : []) : nil)
                    model.setReminderOverride(for: meeting, scope: scope, value: setting); dismiss()
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(mode == 1 && (!(1...1440).contains(first) || (secondEnabled && !(1...1440).contains(second))))
            }
        }
        .padding(24).frame(width: 470)
        .background(AppTheme.calendarChrome).tint(AppTheme.controlAccent)
        .onAppear { load() }
    }
    private var inheritsSeries: Bool {
        scope == .occurrence && model.reminderOverride(for: meeting, scope: .series) != nil
    }
    private func load() {
        let setting = model.reminderOverride(for: meeting, scope: scope)
        mode = setting == nil ? 0 : (setting!.muted ? 2 : 1)
        let inherited = inheritsSeries ? model.reminderOverride(for: meeting, scope: .series) : nil
        let offsets = setting?.minutes ?? inherited?.minutes ?? model.reminderDefaults(for: meeting)
        first = offsets.first ?? 15; second = offsets.dropFirst().first ?? 5; secondEnabled = offsets.count > 1
    }
}

struct StandaloneMeetingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let snapshot = model.standaloneMeeting {
            let meeting = model.currentMeeting(id: snapshot.id) ?? snapshot
            MeetingView(model: model, meeting: meeting).id(meeting.id)
        } else {
            Text("Выберите встречу в календаре или строке меню.").foregroundStyle(.secondary).padding(30)
        }
    }
}

struct MeetingView: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting
    var conflicts: [CalendarConflict] = []
    var selectConflict: ((Meeting) -> Void)? = nil
    var showInCalendar: (() -> Void)? = nil
    @State private var reminders = false
    @State private var pinFeedback: String?

    private var status: MeetingInvitationStatus { meeting.invitationStatus(for: model.configuration.login) }
    private var canRespond: Bool { status == .needsAction || status == .tentative }
    private var hasEventPage: Bool { meeting.sourceURL.map(YandexCalendarLinks.isEventURL) == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heading
                primaryActions
                secondaryActions
                if !conflicts.isEmpty {
                    conflictDetails
                }
                Divider()
                meetingDetails
                if !meeting.details.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Описание").font(.headline).accessibilityAddTraits(.isHeader)
                        Text(meeting.details).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .sheet(isPresented: $reminders) { ReminderEditor(model: model, meeting: meeting) }
        }
        .background(AppTheme.calendarChrome)
        .tint(AppTheme.controlAccent)
    }

    private var conflictDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Пересечения", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ForEach(conflicts) { conflict in
                let other = conflict.first.id == meeting.id ? conflict.second : conflict.first
                let start = max(conflict.first.start, conflict.second.start)
                let end = min(conflict.first.end, conflict.second.end)
                let endFormat = CalendarDates.calendar.isDate(start, inSameDayAs: end) ? "HH:mm" : "d MMM, HH:mm"
                Button {
                    selectConflict?(other)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(other.title).font(.callout.weight(.medium))
                            Text(CalendarDates.text(start, "HH:mm") + "–" + CalendarDates.text(end, endFormat) +
                                 " · " + CalendarDates.duration(conflict.overlap))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption)
                            .foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Показать пересекающуюся встречу")
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    private var heading: some View {
        let event = model.displayedMeeting(meeting)
        let date = CalendarDates.text(event.start, "EEEE, d MMMM yyyy")
        let endFormat = CalendarDates.calendar.isDate(event.start, inSameDayAs: event.end) ? "HH:mm" : "d MMM, HH:mm"
        let time = event.allDay ? "Весь день" :
            CalendarDates.text(event.start, "HH:mm") + "–" + CalendarDates.text(event.end, endFormat)
        return VStack(alignment: .leading, spacing: 8) {
            Text(meeting.title).font(.system(size: 24, weight: .semibold)).textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            Label(date.prefix(1).uppercased() + date.dropFirst() + " · " + time, systemImage: "calendar")
                .font(.subheadline).foregroundStyle(.secondary)
                .textSelection(.enabled)
            if model.activeAccountLogins.count > 1, let login = meeting.accountLogin {
                Label(model.accountName(login), systemImage: "person.crop.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityLabel("Аккаунт: " + model.accountName(login))
            }
            InvitationStatusLabel(status: status, showUnknown: true)
        }
    }

    @ViewBuilder private var primaryActions: some View {
        if meeting.cancelled {
            Label("Встреча отменена", systemImage: "xmark.circle").foregroundStyle(.orange)
        } else if canRespond {
            browserButton(hasEventPage ? "Ответить в Яндексе" : "Открыть день в Яндексе")
                .buttonStyle(.borderedProminent)
            if !hasEventPage {
                Text("Выберите встречу в Яндекс Календаре, чтобы ответить.").font(.caption).foregroundStyle(.secondary)
            }
            if let url = meeting.joinURL {
                JoinMeetingButton(url: url).buttonStyle(.bordered)
            }
        } else if let url = meeting.joinURL {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    callLabel(url).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 6)
                    connectButton(url)
                }
                VStack(alignment: .leading, spacing: 10) {
                    callLabel(url)
                    connectButton(url)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 13)
                    .fill(.linearGradient(
                        colors: [AppTheme.meetingCyan.opacity(0.18), AppTheme.telemostGreen.opacity(0.20)],
                        startPoint: .leading, endPoint: .trailing))
            }
        } else {
            browserButton(hasEventPage ? "Открыть в Яндексе" : "Открыть день в Яндексе")
                .buttonStyle(.borderedProminent)
        }
    }

    private func callLabel(_ url: URL) -> some View {
        Label(MeetingLinks.telemostDesktopURL(for: url) != nil ? "Яндекс Телемост" : "Видеовстреча",
              systemImage: "video")
            .font(.headline)
    }

    private func connectButton(_ url: URL) -> some View {
        JoinMeetingButton(url: url, compact: true)
            .labelStyle(.titleOnly)
            .buttonStyle(FeaturedJoinButtonStyle())
    }

    private var secondaryActions: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                actionRow(compact: false).fixedSize(horizontal: true, vertical: false)
                actionRow(compact: true)
            }
            if let pinFeedback {
                Text(pinFeedback).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .task(id: pinFeedback) {
            guard pinFeedback != nil else { return }
            do {
                try await Task.sleep(nanoseconds: 2_500_000_000)
                pinFeedback = nil
            } catch {}
        }
    }

    private func actionRow(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                if let showInCalendar { showInCalendar() }
                else { model.focusInCalendar(meeting) }
            } label: {
                actionLabel("В календаре", symbol: "calendar", compact: compact)
            }.help("Показать в календаре")
            if let url = meeting.joinURL {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                } label: {
                    actionLabel("Копировать ссылку", symbol: "link", compact: compact)
                }.help("Скопировать ссылку подключения")
            }
            let pinned = model.isPinned(meeting)
            if pinned || (!meeting.cancelled && meeting.joinURL != nil) {
                let title = pinned ? "Открепить" : "Закрепить"
                Button {
                    if model.togglePinned(meeting) {
                        pinFeedback = pinned ? "Убрано из закреплённых" : "Закреплено в строке меню"
                    } else {
                        pinFeedback = pinned ? "Не удалось открепить встречу" : "Не удалось закрепить встречу"
                    }
                } label: {
                    actionLabel(title, symbol: pinned ? "pin.fill" : "pin", compact: compact)
                }
                .tint(pinned ? AppTheme.controlAccent : nil)
                .help(pinned ? "Убрать из закреплённых в строке меню" : "Закрепить в строке меню")
            }
            MeetingTintButton(model: model, meeting: meeting)
            let canEdit = meeting.cancelled || (!canRespond && meeting.joinURL != nil)
            let canSnooze = !meeting.cancelled && !meeting.allDay && meeting.end > Date()
            if canEdit || canSnooze {
                Menu {
                    if canEdit {
                        browserButton(hasEventPage ? "Редактировать в браузере" : "Открыть день в Яндексе")
                    }
                    if canSnooze { snoozeMenu }
                } label: {
                    Label("Действия встречи", systemImage: "ellipsis").labelStyle(.iconOnly)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Действия встречи")
            }
        }
    }

    @ViewBuilder private func actionLabel(_ title: String, symbol: String, compact: Bool) -> some View {
        if compact {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: symbol)
        }
    }

    private var meetingDetails: some View {
        let required = meeting.attendees.filter { !$0.optional }
        let optional = meeting.attendees.filter(\.optional)
        return VStack(alignment: .leading, spacing: 0) {
            if !meeting.cancelled && !meeting.allDay {
                reminderRow
                Divider()
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Календарь", systemImage: "calendar")
                Spacer(minLength: 8)
                Circle().fill(AppTheme.meetingColor(meeting, model: model)).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(meeting.sourceCalendarName).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 10)
            if !required.isEmpty {
                Divider()
                people(required, title: "Участники")
            }
            if !optional.isEmpty {
                Divider()
                people(optional, title: "Необязательные участники")
            }
            if !meeting.location.isEmpty {
                Divider()
                Label(meeting.location, systemImage: "mappin.and.ellipse").textSelection(.enabled)
                    .padding(.vertical, 10)
            }
            if !meeting.organizer.isEmpty {
                Divider()
                Label("Организатор: " + meeting.organizer, systemImage: "person.crop.circle")
                    .textSelection(.enabled).padding(.vertical, 10)
            }
            if meeting.isRecurring {
                Divider()
                Label("Повторяющаяся встреча", systemImage: "repeat")
                    .foregroundStyle(.secondary).padding(.vertical, 10)
            }
        }.font(.callout)
    }

    private var reminderRow: some View {
        let state = model.personalState(for: meeting)
        let offsets = state.offsets(for: meeting.unscoped(), defaults: model.reminderDefaults(for: meeting))
        let source: String
        if model.reminderOverride(for: meeting, scope: .occurrence) != nil {
            source = "Для этой встречи"
        } else if model.reminderOverride(for: meeting, scope: .series) != nil {
            source = "Для серии"
        } else {
            source = "По умолчанию"
        }
        return VStack(alignment: .leading, spacing: 4) {
            Button { reminders = true } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Label("Напоминания", systemImage: "bell").fixedSize()
                        Spacer(minLength: 6)
                        reminderValue(offsets).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Напоминания", systemImage: "bell")
                        reminderValue(offsets)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(source).font(.caption).foregroundStyle(.secondary)
            reminderScheduleStatus
        }.padding(.vertical, 10)
    }

    @ViewBuilder private var reminderScheduleStatus: some View {
        let now = Date()
        if meeting.end > now, status != .declined {
            if !model.remindersEnabledForCalendar(of: meeting) {
                Text("Уведомления для этого календаря выключены")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.notificationAuthorization == .denied || model.notificationAuthorization == .notDetermined {
                Button("Разрешить уведомления") {
                    Task { await model.notificationPermissionAction() }
                }
                .buttonStyle(.borderless).font(.caption)
                .disabled(model.authorizationPending)
            } else if let next = model.nextScheduledReminder(for: meeting, at: now) {
                let format = CalendarDates.calendar.isDate(next.date, inSameDayAs: now) ? "HH:mm" : "d MMM, HH:mm"
                let title = next.snoozed ? "Отложено до " : "Ближайшее уведомление · "
                Text(title + CalendarDates.text(next.date, format))
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.pendingReminderIDs != nil {
                Text("Нет запланированных уведомлений")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reminderValue(_ offsets: [Int]) -> some View {
        HStack(spacing: 8) {
            Text(offsets.isEmpty ? "Выключены" : "За " + offsets.map(String.init).joined(separator: " и ") + " мин.")
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var snoozeMenu: some View {
        Menu {
            Button("Через 5 минут") { model.snooze(meeting, until: Date().addingTimeInterval(300)) }
                .disabled(Date().addingTimeInterval(300) >= meeting.end)
            Button("Через 10 минут") { model.snooze(meeting, until: Date().addingTimeInterval(600)) }
                .disabled(Date().addingTimeInterval(600) >= meeting.end)
            Button("В начале встречи") { model.snooze(meeting, until: meeting.start) }
                .disabled(meeting.start <= Date())
        } label: {
            Label("Напомнить позже", systemImage: "clock.arrow.circlepath")
        }
    }

    private func browserButton(_ title: String) -> some View {
        Button { model.openInYandex(meeting) } label: {
            Label(title, systemImage: "arrow.up.right.square")
        }
    }

    private func people(_ attendees: [Attendee], title: String) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(attendees.enumerated()), id: \.offset) { _, person in
                    Text((person.name.isEmpty ? person.email : person.name + " · " + person.email) + (person.response == "DECLINED" ? " · отказался" : ""))
                        .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.top, 8)
        } label: {
            HStack {
                Label(title, systemImage: "person.2")
                Spacer(minLength: 6)
                Text(attendees.count, format: .number).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 10)
    }
}
