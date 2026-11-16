import AppKit
import SwiftUI
import CalendarCore

struct AgendaView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var showNext = false
    @State private var showPinned = false
    @State private var showAllDay = false
    @State private var showAllToday = false
    @State private var showLater = false
    @State private var showEarlier = false
    @State private var showYesterday = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            agenda(at: CalendarBarIdentity.isDemo ? model.menuTime : context.date)
        }
    }
    private func agenda(at now: Date) -> some View {
        let schedule = model.menuSchedule(at: now)
        let calendar = CalendarDates.calendar
        let featured = schedule.ongoing.first ?? schedule.next.first {
            calendar.isDate($0.start, inSameDayAs: now) && $0.start.timeIntervalSince(now) <= 15 * 60
        }
        let ongoing = schedule.ongoing.filter { $0.id != featured?.id }
        let next = schedule.next.filter { $0.id != featured?.id }
        let following = next.isEmpty && featured != nil ? Array(schedule.laterToday.prefix(1)) : []
        let laterToday = schedule.laterToday.dropFirst(following.count)
        let last = schedule.highlightedLastMeeting(hiding: model.hiddenLastMeeting(for: schedule.lastFinished))
        let earlier = schedule.finished.filter { $0.id != last?.id }
        let hiddenYesterday = last == nil && schedule.finished.isEmpty ? schedule.lastFinished : nil
        let hasAccounts = !model.activeAccountLogins.isEmpty
        let fresh = hasAccounts && model.hasFreshMenuSchedule(at: now)
        let showEmptyToday = fresh && featured == nil && laterToday.isEmpty &&
            schedule.next.allSatisfy { !calendar.isDate($0.start, inSameDayAs: now) }
        let sections = VStack(alignment: .leading, spacing: 8) {
            if !hasAccounts {
                Button(model.accounts.isEmpty ? "Подключить календарь" : "Включить аккаунт") {
                    AppWindows.showSettings()
                }
            } else {
                if let featured {
                    row(featured, now: now, style: .featured)
                } else if showEmptyToday {
                    Label(schedule.allDay.isEmpty ? "Сегодня встреч больше нет" : "Сегодня остались события на весь день",
                          systemImage: "calendar")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                if !ongoing.isEmpty {
                    Text("Сейчас по расписанию").font(.subheadline.bold())
                    ForEach(ongoing) { row($0, now: now) }
                }
                let upcoming = next + following
                if let first = upcoming.first {
                    if featured != nil || showEmptyToday || !ongoing.isEmpty {
                        sectionDivider
                    }
                    if upcoming.count == 1 {
                        sectionButton("Далее", symbol: "calendar.badge.clock", subtitle: nextSummary(first, now: now)) {
                            AppWindows.showMeeting(first)
                        }
                    } else {
                        sectionButton("Далее", symbol: "calendar.badge.clock",
                                      subtitle: nextSummary(first, now: now), expanded: $showNext)
                    }
                    if upcoming.count > 1 && showNext {
                        groupedMeetings(upcoming, now: now)
                    }
                }
            }
            sectionDivider
            pinnedSection
            if hasAccounts {
                if !schedule.allDay.isEmpty {
                    scheduleSection("Весь день · \(schedule.allDay.count)", symbol: "sun.max",
                                    expanded: $showAllDay) {
                        ForEach(schedule.allDay) { row($0, now: now) }
                    }
                }
                if !laterToday.isEmpty {
                    scheduleSection("Ещё сегодня · \(laterToday.count)", symbol: "clock",
                                    expanded: $showAllToday) {
                        ForEach(laterToday) { row($0, now: now) }
                    }
                }
                if !schedule.later.isEmpty {
                    scheduleSection("Позже · \(schedule.later.count)", symbol: "calendar",
                                    expanded: $showLater) {
                        groupedMeetings(schedule.later, now: now)
                    }
                }
                if let meeting = last {
                    sectionDivider
                    row(meeting, now: now, style: .last) { model.hideLastMeeting(meeting) }
                }
                if !earlier.isEmpty {
                    scheduleSection("Ранее сегодня · \(earlier.count)", symbol: "clock.arrow.circlepath",
                                    expanded: $showEarlier, subdued: true) {
                        ForEach(earlier) { row($0, now: now, style: .past, restore: $0.id == schedule.lastFinished?.id) }
                    }
                }
                if let hiddenYesterday {
                    scheduleSection("Вчера", symbol: "clock.arrow.circlepath",
                                    expanded: $showYesterday, subdued: true) {
                        row(hiddenYesterday, now: now, style: .past, restore: true)
                    }
                }
            }
        }

        let date = CalendarDates.text(now, "EEEE, d MMMM")
        return VStack(alignment: .leading, spacing: 10) {
            Text(date.prefix(1).uppercased() + date.dropFirst())
                .font(.system(size: 17, weight: .semibold))
                .padding(.horizontal, 4)

            if hasAccounts && !fresh {
                syncStatus(at: now)
            }

            ViewThatFits(in: .vertical) {
                sections.fixedSize(horizontal: false, vertical: true)
                ScrollView { sections }
            }
            .frame(maxHeight: 450)

            sectionDivider
            footer
        }
        .padding(12)
        .frame(width: 354)
        .background(colorScheme == .dark ? AppTheme.graphite : Color.white)
    }

    private var sectionDivider: some View {
        Divider().padding(.horizontal, 4)
    }

    private func syncStatus(at now: Date) -> some View {
        let warning = model.syncWarning != nil || model.connectionState == .unavailable
        let title: String
        if model.busy {
            title = "Обновляю расписание…"
        } else if warning {
            title = model.syncWarning != nil && model.connectionState != .unavailable
                ? "Расписание обновлено частично" : "Не удалось обновить расписание"
        } else if model.lastSync == nil {
            title = "Расписание ещё не загружено"
        } else if model.visibleCalendarIDs.isEmpty {
            title = model.listedCalendarIDs.isEmpty ? "Нет календарей в списке" : "Календари скрыты"
        } else {
            title = "Показаны сохранённые встречи"
        }
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: warning && !model.busy ? "exclamationmark.triangle" : "clock.arrow.circlepath")
                .foregroundStyle(warning && !model.busy ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let date = model.lastSync, !model.visibleCalendarIDs.isEmpty {
                    let format = CalendarDates.calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "d MMM, HH:mm"
                    Text("Данные на " + CalendarDates.text(date, format))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { AppWindows.showCalendar() } label: {
                Label("Календарь", systemImage: "arrow.up.right.square")
            }
            Spacer(minLength: 0)
            if model.connectionState == .unavailable || model.syncWarning != nil {
                Button { AppWindows.showSettings() } label: {
                    Label(model.readinessText, systemImage: "exclamationmark.triangle")
                        .labelStyle(.iconOnly)
                }
                .help(model.readinessText)
            }
            ActivityButton(model: model)
            Button { AppWindows.showSettings() } label: {
                Label("Настройки", systemImage: "gearshape").labelStyle(.iconOnly)
            }
            .help("Настройки · ⌘,")
            Button { Task { await model.sync() } } label: {
                if model.busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Label("Обновить встречи", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
            }
            .disabled(model.busy)
            .accessibilityLabel(model.busy ? "Встречи обновляются" : "Обновить встречи")
            .help(model.busy ? "Встречи обновляются" : "Обновить встречи")
            Menu {
                Button("Выход") { NSApp.terminate(nil) }
            } label: {
                Label("Действия", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Действия приложения")
        }
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func scheduleSection<Content: View>(_ title: String, symbol: String, expanded: Binding<Bool>,
                                                subdued: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionDivider
            sectionButton(title, symbol: symbol, expanded: expanded, subdued: subdued)
            if expanded.wrappedValue { content() }
        }
    }

    private func sectionButton(_ title: String, symbol: String, subtitle: String? = nil,
                               expanded: Binding<Bool>, subdued: Bool = false) -> some View {
        sectionButton(title, symbol: symbol, subtitle: subtitle, isExpanded: expanded.wrappedValue, subdued: subdued) {
            expanded.wrappedValue.toggle()
        }
        .accessibilityValue(expanded.wrappedValue ? "Развёрнуто" : "Свёрнуто")
    }

    private func sectionButton(_ title: String, symbol: String, subtitle: String? = nil,
                               isExpanded: Bool = false, subdued: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    if let subtitle {
                        Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .foregroundStyle(subdued ? Color.secondary : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(minHeight: 31)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func nextSummary(_ meeting: Meeting, now: Date) -> String {
        let format = CalendarDates.calendar.isDate(meeting.start, inSameDayAs: now) ? "HH:mm" : "EEE, d MMM · HH:mm"
        return CalendarDates.text(meeting.start, format) + " · " + meeting.title
    }

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionButton("Закреплённые", symbol: "pin", expanded: $showPinned)
            if showPinned {
                ForEach(model.menuPins) { pin in
                    HStack(spacing: 8) {
                        Text(pin.title).lineLimit(1).help(pin.title)
                        Spacer(minLength: 0)
                        JoinMeetingButton(url: pin.url, compact: true, title: "Войти")
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(.vertical, 3)
                }
                Button(model.menuPins.isEmpty ? "Закрепить по ссылке…" : "Управлять закреплёнными…") {
                    AppWindows.showPinnedMeetings()
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
        }
    }

    private func groupedMeetings(_ meetings: [Meeting], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MenuScheduleDay.group(meetings, calendar: CalendarDates.calendar)) { group in
                VStack(alignment: .leading, spacing: 7) {
                    Text(group.title(relativeTo: now, calendar: CalendarDates.calendar))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(group.meetings) { row($0, now: now, displayDay: group.date) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.top, 3)
    }
    private func row(_ meeting: Meeting, now: Date, style: AgendaMeetingRow.Style = .regular,
                     displayDay: Date? = nil, restore: Bool = false, hide: (() -> Void)? = nil) -> some View {
        AgendaMeetingRow(meeting: meeting, day: displayDay ?? CalendarDates.calendar.startOfDay(for: now), now: now,
            style: style, calendar: CalendarDates.calendar, account: model.configuration.login,
            accountName: model.activeAccountLogins.count > 1 ? meeting.accountLogin.map(model.accountName) : nil,
            pinned: model.isPinned(meeting), togglePin: { model.togglePinned(meeting) },
            tintMenu: MeetingTintMenu(model: model, meeting: meeting),
            hide: hide, restore: restore ? { model.showLastMeeting(meeting) } : nil,
            openMeeting: { AppWindows.showMeeting(meeting) })
    }
}

private struct AgendaMeetingRow: View {
    enum Style { case featured, regular, last, past }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    let meeting: Meeting
    let day: Date
    let now: Date
    let style: Style
    let calendar: Calendar
    let account: String
    let accountName: String?
    let pinned: Bool
    let togglePin: () -> Void
    let tintMenu: MeetingTintMenu
    let hide: (() -> Void)?
    let restore: (() -> Void)?
    let openMeeting: () -> Void

    var body: some View {
        let row = HStack(spacing: 8) {
            if style == .featured {
                Image(systemName: meeting.joinURL == nil ? "calendar" : "video")
                    .font(.title3)
                    .accessibilityHidden(true)
            }
            Button(action: openMeeting) {
                VStack(alignment: .leading, spacing: 3) {
                    if style == .last {
                        Text("Последняя встреча").font(.subheadline.weight(.semibold))
                        Text(timeLabel + " · " + meeting.title)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        HStack(spacing: 5) {
                            Text(meeting.title).lineLimit(1)
                                .fontWeight(style == .featured ? .semibold : .medium)
                            if style != .past {
                                InvitationStatusLabel(status: meeting.invitationStatus(for: account), iconOnly: true)
                            }
                        }
                        Text(accountName.map { timeLabel + " · " + $0 } ?? timeLabel)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(meeting.title)
            .accessibilityValue(meeting.invitationStatus(for: account).title)
            if let url = meeting.joinURL {
                if style == .featured {
                    JoinMeetingButton(url: url, compact: true)
                        .labelStyle(.titleOnly)
                        .buttonStyle(FeaturedJoinButtonStyle())
                } else {
                    JoinMeetingButton(url: url, compact: true, title: style == .regular ? nil : "Вернуться")
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(.secondary)
                }
            }
            if let hide {
                Button(action: hide) {
                    Label("Скрыть последнюю встречу", systemImage: "xmark").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Убрать из начала меню")
            }
        }
        .padding(.horizontal, style == .featured ? 12 : 8)
        .padding(.vertical, style == .featured ? 10 : 5)
        Group {
            if style == .featured {
                row.background {
                    let shape = RoundedRectangle(cornerRadius: 13)
                    let strength = contrast == .increased ? 0.08 : 0.18
                    shape.fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white)
                        .overlay {
                            shape.fill(.linearGradient(
                                colors: [AppTheme.meetingCyan.opacity(strength), AppTheme.telemostGreen.opacity(strength)],
                                startPoint: .leading, endPoint: .trailing))
                        }
                }
            } else {
                row
            }
        }
        .contextMenu {
            tintMenu
            if let restore { Button("Вернуть в начало", action: restore) }
            if meeting.joinURL != nil {
                Button(pinned ? "Открепить ссылку" : "Закрепить ссылку", action: togglePin)
            }
        }
    }

    private var timeLabel: String {
        if style == .last || style == .past {
            let format = calendar.isDate(meeting.end, inSameDayAs: now) ? "HH:mm" : "d MMM, HH:mm"
            let time = CalendarDates.text(meeting.end, format)
            return style == .last ? time : "Окончание · " + time
        }
        if meeting.allDay {
            let lastDay = calendar.startOfDay(for: meeting.end.addingTimeInterval(-1))
            guard lastDay > day else { return "Весь день" }
            return "Весь день · по " + CalendarDates.text(lastDay, "d MMMM")
        }
        let startFormat = calendar.isDate(meeting.start, inSameDayAs: day) ? "HH:mm" : "d MMM, HH:mm"
        let endFormat = calendar.isDate(meeting.end, inSameDayAs: day) ? "HH:mm" : "d MMM, HH:mm"
        return CalendarDates.text(meeting.start, startFormat) + " — " + CalendarDates.text(meeting.end, endFormat)
    }
}

struct FeaturedJoinButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .fixedSize()
            .background(shape.fill(AppTheme.telemostGreen))
            .overlay {
                shape.fill(Color.black.opacity(configuration.isPressed ? 0.14 : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                if isFocused {
                    shape.strokeBorder(Color.primary, lineWidth: 2).allowsHitTesting(false)
                }
            }
    }
}
