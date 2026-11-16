import AppKit
import SwiftUI
import CalendarCore

enum AppTheme {
    static let teal = Color(red: 8.0 / 255, green: 196.0 / 255, blue: 169.0 / 255)
    static let violet = Color(red: 125.0 / 255, green: 106.0 / 255, blue: 1)
    static let telemostGreen = Color(red: 26.0 / 255, green: 203.0 / 255, blue: 100.0 / 255)
    static let meetingCyan = Color(red: 0.14, green: 0.66, blue: 0.77)
    static let graphite = Color(red: 35.0 / 255, green: 36.0 / 255, blue: 40.0 / 255)
    static let calendarRed = adaptive(light: NSColor(srgbRed: 0.81, green: 0.11, blue: 0.17, alpha: 1),
                                      dark: NSColor(srgbRed: 1, green: 0.39, blue: 0.42, alpha: 1))
    static let todayDateText = adaptive(light: .white, dark: .black)
    static let controlAccent = adaptive(light: NSColor(srgbRed: 0.04, green: 0.43, blue: 0.23, alpha: 1),
                                        dark: NSColor(srgbRed: 0.10, green: 0.80, blue: 0.39, alpha: 1))
    static let canvas = adaptive(light: .white, dark: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
    static let calendarChrome = adaptive(light: NSColor(srgbRed: 0.96, green: 0.97, blue: 0.97, alpha: 1),
                                         dark: NSColor(srgbRed: 0.14, green: 0.14, blue: 0.16, alpha: 1))
    static let todayColumn = Color(red: 0.44, green: 0.50, blue: 0.76).opacity(0.12)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    static let defaultCalendarColor = telemostGreen
}

enum CalendarDates {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .autoupdatingCurrent; value.firstWeekday = 2; value.minimumDaysInFirstWeek = 4
        return value
    }
    static func text(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = format
        return formatter.string(from: date)
    }
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        let hours = minutes / 60
        let remainder = minutes % 60
        if minutes == 0 { return "менее минуты" }
        if hours == 0 { return "\(remainder) мин" }
        return remainder == 0 ? "\(hours) ч" : "\(hours) ч \(remainder) мин"
    }
    static func monthDays(_ date: Date) -> [Date] {
        let first = calendar.dateInterval(of: .month, for: date)!.start
        let offset = (calendar.component(.weekday, from: first) + 5) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: first)!
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }
    static func weekDays(_ date: Date) -> [Date] {
        let first = calendar.dateInterval(of: .weekOfYear, for: date)!.start
        return (0..<7).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }
    static func agendaDays(_ date: Date) -> [Date] {
        let first = calendar.dateInterval(of: .month, for: date)!.start
        let count = calendar.range(of: .day, in: .month, for: first)!.count
        return (0..<count).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }
    static func dayRange(_ date: Date) -> Range<Date> {
        let start = calendar.startOfDay(for: date)
        return start..<calendar.date(byAdding: .day, value: 1, to: start)!
    }
    static func events(_ meetings: [Meeting], on day: Date) -> [Meeting] {
        let range = dayRange(day)
        return meetings.filter { CalendarLayout.intersects($0, range: range) }.sorted {
            if $0.allDay != $1.allDay { return $0.allDay }
            return $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
    }
    static func defaultStart(on day: Date) -> Date {
        if calendar.isDateInToday(day) {
            let rounded = ceil(Date().timeIntervalSince1970 / 900) * 900
            return Date(timeIntervalSince1970: rounded)
        }
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
    }
}

private enum CalendarMode: String, CaseIterable { case day = "День", week = "Неделя", month = "Месяц", agenda = "Расписание" }
private struct CalendarQueryKey: Hashable {
    let start: Date; let end: Date; let accounts: [String: String]; let revision: Int
}

private struct CalendarScrollRequest {
    let id = UUID()
    let date: Date
    var showTime = false
}

private enum CalendarCreation {
    case date(Date)
    case slot(Range<Date>)
}

struct CalendarWindow: View {
    @ObservedObject var model: AppModel
    @State private var anchor = Date()
    @State private var selectedDay = Date()
    @State private var selectedMeeting: Meeting?
    @State private var scroll = CalendarScrollRequest(date: Date())
    @AppStorage("calendarMode") private var mode = CalendarMode.week
    @AppStorage("showDeclinedMeetings") private var showDeclined = false
    @AppStorage("calendarSidebar") private var showSidebar = true
    @AppStorage("calendarAnchor") private var savedAnchor = Date().timeIntervalSince1970
    @AppStorage(CalendarViewPreferences.compactHoursKey)
    private var compactHours = CalendarViewPreferences.compactHoursDefault
    @State private var restored = false
    @State private var showSearch = false
    @State private var searchCalendarDestination: Meeting?
    @State private var compactLayout = false
    @State private var showCompactSidebar = false
    @State private var showCompactInspector = false
    @State private var showInspector = false
    @State private var showDatePicker = false
    @State private var search = ""
    @State private var revision = 0
    @State private var forceReload = false
    @State private var collapsedAccounts = Set<String>()
    @State private var pendingCreation: CalendarCreation?
    @State private var showUnavailableSlot = false

    private var days: [Date] {
        switch mode {
        case .day: return [CalendarDates.calendar.startOfDay(for: anchor)]
        case .week: return CalendarDates.weekDays(anchor)
        case .month: return CalendarDates.monthDays(anchor)
        case .agenda: return CalendarDates.agendaDays(anchor)
        }
    }
    private var range: Range<Date> { days[0]..<CalendarDates.calendar.date(byAdding: .day, value: 1, to: days.last!)! }
    private var query: CalendarQueryKey {
        CalendarQueryKey(start: range.lowerBound, end: range.upperBound,
            accounts: Dictionary(model.activeProfiles.map { ($0.login, $0.zone) }, uniquingKeysWith: { first, _ in first }),
            revision: revision)
    }
    private var displayedMeetings: [Meeting] {
        let visibleCalendars = model.visibleCalendarIDs
        return model.calendarMeetings.filter { visibleCalendars.contains($0.calendarID) && !$0.cancelled }
            .map(model.displayedMeeting)
    }
    private var hasCompleteData: Bool {
        model.hasCompleteCalendarData(for: range)
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 1200
            let displayed = displayedMeetings
            let filtered = displayed.filter {
                (showDeclined || !$0.declined(by: model.configuration.login)) && MeetingSearch.matches($0, query: search)
            }
            VStack(spacing: 0) {
                toolbar(compact: compact, inspectorHeight: min(640, max(320, geometry.size.height - 76)),
                    displayed: displayed, filtered: filtered)
                Divider()
                HSplitView {
                    if !compact && showSidebar { sidebar.frame(minWidth: 154, idealWidth: 180, maxWidth: 230) }
                    calendarBody(meetings: filtered, availabilityMeetings: displayed)
                        .frame(minWidth: compact ? 0 : 570, maxWidth: .infinity, maxHeight: .infinity)
                    if !compact && showInspector {
                        inspector(displayed: displayed, filtered: filtered).frame(minWidth: 290, idealWidth: 320, maxWidth: 380)
                    }
                }
                Divider()
                statusBar
            }
            .onAppear { compactLayout = compact }
            .onChange(of: compact) { newValue in
                let inspectorWasOpen = compactLayout ? showCompactInspector : showInspector
                compactLayout = newValue
                showCompactSidebar = false
                showDatePicker = false
                showCompactInspector = newValue && inspectorWasOpen
                showInspector = !newValue && inspectorWasOpen
            }
        }
        .background(AppTheme.calendarChrome).tint(AppTheme.controlAccent)
        .task(id: query) {
            let force = forceReload; forceReload = false
            await model.loadCalendar(range: range, force: force)
        }
        .onAppear {
            if !restored {
                navigate(to: Date(timeIntervalSince1970: savedAnchor))
                restored = true
            }
            if let request = model.calendarNavigation { navigate(request) }
        }
        .onChange(of: anchor) { savedAnchor = $0.timeIntervalSince1970 }
        .onChange(of: model.calendarNavigation) { request in
            if let request { navigate(request) }
        }
        .onChange(of: model.visibleCalendarIDs) { visible in
            if let selectedMeeting, !visible.contains(selectedMeeting.calendarID) { closeInspector() }
        }
        .onReceive(model.clearedCalendarCaches) { logins in
            if let login = selectedMeeting?.accountLogin, logins.contains(login) { closeInspector() }
        }
        .onChange(of: mode) { _ in
            anchor = selectedDay
            scroll = CalendarScrollRequest(date: selectedDay, showTime: selectedMeeting?.allDay == false)
        }
        .onExitCommand {
            if !showSearch && !showDatePicker && !showCompactSidebar { closeInspector() }
        }
        .sheet(isPresented: $showSearch, onDismiss: {
            if let meeting = searchCalendarDestination {
                searchCalendarDestination = nil
                model.focusInCalendar(meeting)
            }
        }) {
            SearchMeetingsView(model: model, initialQuery: search) { meeting in
                searchCalendarDestination = meeting
                showSearch = false
            }
        }
        .confirmationDialog("Создать событие в Яндексе", isPresented: Binding(
            get: { pendingCreation != nil }, set: { if !$0 { pendingCreation = nil } }
        ), presenting: pendingCreation) { creation in
            Button("Открыть Яндекс Календарь") {
                switch creation {
                case .date(let date): model.createInYandex(at: date)
                case .slot(let slot): openPlannedMeeting(in: slot)
                }
            }
        } message: { _ in
            Text("Выберите нужную почту в Яндекс Календаре после открытия браузера.")
        }
        .alert("Свободное окно изменилось", isPresented: $showUnavailableSlot) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text("Проверьте расписание и выберите свободное время заново.")
        }
    }

    private func toolbar(compact: Bool, inspectorHeight: CGFloat, displayed: [Meeting], filtered: [Meeting]) -> some View {
        let navigation = HStack(spacing: 8) {
            Button { if compact { showCompactSidebar.toggle() } else { showSidebar.toggle() } } label: {
                Label("Календари", systemImage: "sidebar.left").labelStyle(.iconOnly)
            }.help("Показать или скрыть календари")
                .popover(isPresented: $showCompactSidebar, arrowEdge: .bottom) {
                    sidebar.frame(width: 245, height: inspectorHeight)
                }
            Button("Сегодня") { navigate(to: Date()) }.keyboardShortcut("t", modifiers: .command)
            Button { move(-1) } label: { Label("Предыдущий период", systemImage: "chevron.left").labelStyle(.iconOnly) }
                .buttonStyle(.borderless).help("Предыдущий период")
            Button { move(1) } label: { Label("Следующий период", systemImage: "chevron.right").labelStyle(.iconOnly) }
                .buttonStyle(.borderless).help("Следующий период")
            Button { showDatePicker.toggle() } label: {
                HStack(spacing: 5) {
                    Text(periodTitle)
                        .font(.title3.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(Color.primary)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }.buttonStyle(.borderless)
                .accessibilityHint("Открывает мини-календарь")
                .help("Выбрать дату")
                .popover(isPresented: $showDatePicker, arrowEdge: .bottom) {
                    MiniCalendar(anchor: anchor, selection: selectedDay) { date in
                        navigate(to: date)
                        showDatePicker = false
                        showDaySummary(date)
                    }.frame(width: 230).padding(14)
                }
        }
        let actions = HStack(spacing: 8) {
            Button {
                if compact ? showCompactInspector : showInspector { closeInspector() }
                else { openInspector() }
            } label: {
                Label("Подробности дня", systemImage: "sidebar.right").labelStyle(.iconOnly)
            }.help("Показать или скрыть подробности")
                .popover(isPresented: $showCompactInspector, arrowEdge: .bottom) {
                    inspector(displayed: displayed, filtered: filtered).frame(width: 330, height: inspectorHeight)
                }
            calendarDisplayOptions
            Button { beginCreate(CalendarDates.defaultStart(on: selectedDay)) } label: {
                Label("Создать", systemImage: "plus")
            }.buttonStyle(.borderedProminent).keyboardShortcut("n", modifiers: .command)
                .help("Создать событие в Яндекс Календаре в браузере")
        }
        return ViewThatFits(in: .horizontal) {
            toolbarRow(navigation: navigation, modes: calendarModePicker,
                       search: searchControls(compact: false), actions: actions)
            toolbarRow(navigation: navigation, modes: calendarModePicker,
                       search: searchControls(compact: true), actions: actions)
            toolbarRow(navigation: navigation, modes: calendarModeMenu,
                       search: searchControls(compact: true), actions: actions)
            VStack(alignment: .leading, spacing: 8) {
                toolbarRow(navigation: navigation, modes: calendarModeMenu,
                           search: EmptyView(), actions: EmptyView())
                HStack(spacing: 8) {
                    searchControls(compact: true)
                    Spacer(minLength: 8)
                    actions
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func toolbarRow<Navigation: View, Modes: View, Search: View, Actions: View>(
        navigation: Navigation, modes: Modes, search: Search, actions: Actions
    ) -> some View {
        HStack(spacing: 10) {
            navigation
            modes
            Spacer(minLength: 8)
            search
            actions
        }
    }

    private func searchControls(compact: Bool) -> some View {
        HStack(spacing: 8) {
            TextField(periodFilterTitle, text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: compact ? 128 : 155)
                .help("Фильтрует встречи в открытом периоде")
            Button {
                showCompactSidebar = false
                showCompactInspector = false
                showDatePicker = false
                showSearch = true
            } label: {
                if compact {
                    Label("Поиск", systemImage: "magnifyingglass").labelStyle(.iconOnly)
                } else {
                    Label("Поиск", systemImage: "magnifyingglass")
                }
            }
            .help("Поиск встреч по видимым календарям · ⌘F")
            .keyboardShortcut("f", modifiers: .command)
        }
    }

    private var periodTitle: String {
        switch mode {
        case .day:
            return CalendarDates.text(anchor, "d MMMM yyyy")
        case .week:
            let week = CalendarDates.weekDays(anchor)
            guard let first = week.first, let last = week.last else { return "" }
            let calendar = CalendarDates.calendar
            let sameMonth = calendar.isDate(first, equalTo: last, toGranularity: .month)
            let sameYear = calendar.isDate(first, equalTo: last, toGranularity: .year)
            let startFormat = sameMonth ? "d" : (sameYear ? "d MMM" : "d MMM yyyy")
            return CalendarDates.text(first, startFormat) + "–" + CalendarDates.text(last, "d MMMM yyyy")
        case .month, .agenda:
            return CalendarDates.text(anchor, "LLLL yyyy").capitalized
        }
    }

    private var periodFilterTitle: String {
        switch mode {
        case .day: return "Фильтр дня"
        case .week: return "Фильтр недели"
        case .month: return "Фильтр месяца"
        case .agenda: return "Фильтр расписания"
        }
    }

    private var calendarModePicker: some View {
        Picker("Вид календаря", selection: $mode) {
            ForEach(CalendarMode.allCases, id: \.self) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
        .help("Переключить вид календаря")
    }

    private var calendarModeMenu: some View {
        Picker("Вид календаря", selection: $mode) {
            ForEach(CalendarMode.allCases, id: \.self) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("Переключить вид календаря")
    }

    private var calendarDisplayOptions: some View {
        Menu {
            Toggle("Показывать отклонённые встречи", isOn: $showDeclined)
            if mode == .day || mode == .week {
                Toggle(CalendarViewPreferences.compactHoursTitle, isOn: $compactHours)
            }
        } label: {
            Label("Параметры отображения", systemImage: "slider.horizontal.3").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Параметры отображения")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Календари").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(model.activeProfiles, id: \.login) { account in
                        accountSection(account.login)
                    }
                    if model.activeProfiles.isEmpty {
                        Text("Включите аккаунт в настройках.").font(.callout).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            Button { model.openInYandex() } label: {
                Label("Яндекс Календарь", systemImage: "arrow.up.right")
            }.font(.caption).buttonStyle(.borderless).help("Открыть в браузере")
        }.padding(12)
    }

    private func accountSection(_ login: String) -> some View {
        let collapsed = collapsedAccounts.contains(login)
        let visible = model.isAccountVisible(login)
        let calendars = model.accountCalendars(login).filter(model.isCalendarListed)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Button {
                    if collapsed { collapsedAccounts.remove(login) } else { collapsedAccounts.insert(login) }
                } label: {
                    Label(collapsed ? "Развернуть" : "Свернуть", systemImage: collapsed ? "chevron.right" : "chevron.down")
                        .labelStyle(.iconOnly).font(.caption2)
                }.buttonStyle(.plain)
                Toggle(isOn: Binding(get: { model.isAccountVisible(login) },
                                     set: { model.setAccountVisible(login, visible: $0) })) {
                    Text(model.accountName(login)).fontWeight(.semibold).lineLimit(1)
                }.toggleStyle(.checkbox).help(login)
            }
            if !collapsed {
                ForEach(calendars) { calendar in
                    HStack(spacing: 5) {
                        CalendarSidebarColorButton(model: model, calendar: calendar)
                        Toggle(isOn: Binding(get: { model.isCalendarEventsEnabled(calendar) },
                                             set: { model.showCalendarEvents(calendar.id, visible: $0) })) {
                            Text(calendar.name).lineLimit(1)
                        }.toggleStyle(.checkbox)
                            .disabled(!visible)
                            .help(calendar.name)
                    }.padding(.leading, 14)
                }
                if calendars.isEmpty {
                    Text("Нет календарей в списке").font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 14)
                }
            }
        }
    }

    private func calendarBody(meetings: [Meeting], availabilityMeetings: [Meeting]) -> some View {
        VStack(spacing: 0) {
            if !model.calendarError.isEmpty {
                Label(model.calendarError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .help(model.calendarError)
            }
            if mode == .week || mode == .day {
                let workday = model.configuration.workdayStartHour..<model.configuration.workdayEndHour
                WeekCalendar(model: model, days: days, meetings: meetings, selectedDay: selectedDay, selectedID: selectedMeeting?.id,
                    account: model.configuration.login, scrollTime: scroll.showTime ? scroll.date : nil, scrollID: scroll.id,
                    workdayHours: compactHours ? workday : nil,
                    freeSlots: hasCompleteData && !model.visibleCalendarIDs.isEmpty
                        ? Dictionary(uniqueKeysWithValues: days.map { day in
                            (day, model.planningSlots(on: day, from: availabilityMeetings))
                        }) : [:],
                    selectDay: showDaySummary, select: select, create: beginCreate, plan: beginPlanning)
            } else if mode == .month {
                MonthCalendar(model: model, days: days, anchor: anchor, selection: selectedDay, meetings: meetings,
                    selectedID: selectedMeeting?.id, account: model.configuration.login, selectDay: { date in
                        if !CalendarDates.calendar.isDate(date, equalTo: anchor, toGranularity: .month) { anchor = date }
                        showDaySummary(date)
                    }, select: select, create: { beginCreate(CalendarDates.defaultStart(on: $0)) })
            } else {
                ScheduleCalendar(model: model, days: days, meetings: meetings, selectedID: selectedMeeting?.id,
                    selectedDay: selectedDay, scrollDate: scroll.date, scrollID: scroll.id,
                    loading: model.calendarLoading, complete: hasCompleteData,
                    account: model.configuration.login, selectDay: showDaySummary, select: select, create: beginCreate,
                    previousMonth: { move(-1) }, nextMonth: { move(1) })
            }
        }.background(AppTheme.canvas)
    }

    private func inspector(displayed: [Meeting], filtered: [Meeting]) -> some View {
        VStack(spacing: 0) {
            HStack {
                if selectedMeeting != nil {
                    Button { showDaySummary(selectedDay) } label: {
                        Label("К сводке дня", systemImage: "chevron.left").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("К сводке дня")
                }
                Text(selectedMeeting == nil ? "День" : "Встреча").font(.headline)
                Spacer()
                Button(action: closeInspector) {
                    Label("Закрыть подробности", systemImage: "xmark").labelStyle(.iconOnly)
                }.buttonStyle(.borderless).help("Закрыть подробности · Esc")
            }.padding(14)
            Divider()
            if let selectedMeeting {
                let meeting = model.calendarMeetings.first(where: { $0.id == selectedMeeting.id }) ?? selectedMeeting
                let conflicts = model.overview(on: selectedDay, from: displayed).conflicts
                    .filter { $0.first.id == meeting.id || $0.second.id == meeting.id }
                MeetingView(model: model, meeting: meeting, conflicts: conflicts, selectConflict: { other in
                    if !MeetingSearch.matches(other, query: search) { search = "" }
                    select(other, on: selectedDay)
                    scroll = CalendarScrollRequest(date: selectedDay, showTime: true)
                }).id(meeting.id)
            } else {
                let dayRange = CalendarDates.dayRange(selectedDay)
                DayInspector(model: model, day: selectedDay,
                    meetings: CalendarDates.events(filtered, on: selectedDay),
                    availabilityMeetings: CalendarDates.events(displayed, on: selectedDay),
                    loading: model.calendarLoading,
                    complete: hasCompleteData && range.lowerBound <= dayRange.lowerBound && range.upperBound >= dayRange.upperBound,
                    select: { select($0, on: selectedDay) },
                    create: beginCreate, plan: beginPlanning)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.calendarLoading { ProgressView().controlSize(.mini); Text(model.progress.isEmpty ? "Ожидаю загрузку…" : model.progress) }
            else if let date = model.calendarLastLoaded {
                Text((model.calendarFromCache ? "Из кэша · проверено: " : "Проверено: ") + date.formatted(date: .abbreviated, time: .shortened))
            }
            else { Text(model.activeAccountLogins.isEmpty ? "Нет активных аккаунтов" : "Загрузка выбранного периода ещё не завершена") }
            Spacer()
            ActivityButton(model: model)
            Button { AppWindows.showSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Настройки · ⌘,").accessibilityLabel("Настройки")
            Button { forceReload = true; revision += 1 } label: {
                Label("Обновить выбранный период", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
            }
                .buttonStyle(.borderless).disabled(model.calendarLoading).help("Обновить выбранный период")
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func navigate(_ request: CalendarNavigationRequest) {
        model.calendarNavigation = nil
        switch request.destination {
        case .day(let date):
            navigate(to: date)
        case .meeting(let rawMeeting):
            guard model.visibleCalendarIDs.contains(rawMeeting.calendarID) else { return }
            let meeting = model.displayedMeeting(rawMeeting)
            // A filter from another date must not hide the target of this navigation.
            if !MeetingSearch.matches(meeting, query: search) { search = "" }
            if meeting.declined(by: model.configuration.login) { showDeclined = true }
            anchor = meeting.start
            select(meeting, on: meeting.start)
            scroll = CalendarScrollRequest(date: meeting.start, showTime: !meeting.allDay)
        }
    }
    private func move(_ delta: Int) {
        let date = CalendarDates.calendar.date(byAdding: (mode == .week || mode == .day) ? .day : .month,
            value: mode == .week ? delta * 7 : delta, to: anchor)!
        navigate(to: date)
    }
    private func navigate(to date: Date) {
        anchor = date; selectedDay = date
        if selectedMeeting != nil { closeInspector() }
        // A repeated click on Today or the same date must scroll again, without
        // changing the network query or forcing another calendar download.
        scroll = CalendarScrollRequest(date: date)
    }
    private func select(_ meeting: Meeting, on day: Date) {
        selectedDay = CalendarDates.calendar.isDate(meeting.start, inSameDayAs: day) ? meeting.start : day
        selectedMeeting = meeting
        openInspector()
    }
    private func showDaySummary(_ day: Date) {
        selectedDay = day
        selectedMeeting = nil
        openInspector()
    }
    private func openInspector() {
        if compactLayout {
            showDatePicker = false
            showCompactSidebar = false
            showCompactInspector = true
        }
        else { showInspector = true }
    }
    private func closeInspector() {
        selectedMeeting = nil
        showInspector = false
        showCompactInspector = false
    }
    private func beginCreate(_ date: Date) {
        if model.activeAccountLogins.count > 1 { pendingCreation = .date(date) }
        else { model.createInYandex(at: date) }
    }

    private func beginPlanning(_ slot: Range<Date>) {
        if model.activeAccountLogins.count > 1 {
            pendingCreation = .slot(slot)
        } else {
            openPlannedMeeting(in: slot)
        }
    }

    private func openPlannedMeeting(in slot: Range<Date>) {
        guard hasCompleteData, !model.visibleCalendarIDs.isEmpty,
              let event = FreeSlotPlanning.eventRange(in: slot, at: Date()),
              model.planningSlots(on: slot.lowerBound, from: displayedMeetings).contains(where: {
                  $0.lowerBound <= event.lowerBound && event.upperBound <= $0.upperBound
              }) else {
            showUnavailableSlot = true
            return
        }
        model.createInYandex(at: event.lowerBound, end: event.upperBound)
    }

}

private struct MiniCalendar: View {
    let anchor: Date
    let selection: Date
    let select: (Date) -> Void
    @State private var month: Date?
    private var shown: Date { month ?? anchor }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(CalendarDates.text(shown, "LLLL yyyy").capitalized).font(.subheadline.weight(.semibold))
                Spacer()
                Button { shift(-1) } label: { Label("Предыдущий месяц", systemImage: "chevron.left").labelStyle(.iconOnly) }
                Button { shift(1) } label: { Label("Следующий месяц", systemImage: "chevron.right").labelStyle(.iconOnly) }
            }.buttonStyle(.borderless)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"], id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                ForEach(CalendarDates.monthDays(shown), id: \.self) { day in
                    let selected = CalendarDates.calendar.isDate(day, inSameDayAs: selection)
                    let inMonth = CalendarDates.calendar.isDate(day, equalTo: shown, toGranularity: .month)
                    Button { select(day) } label: {
                        Text(CalendarDates.text(day, "d")).font(.caption)
                            .foregroundStyle(inMonth || selected ? Color.primary : Color.secondary)
                            .frame(width: 23, height: 23)
                            .background(selected ? AppTheme.controlAccent.opacity(0.22) : Color.clear).clipShape(Circle())
                            .overlay(Circle().strokeBorder(CalendarDates.calendar.isDateInToday(day) ? AppTheme.calendarRed : .clear))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(CalendarDates.text(day, "d MMMM yyyy"))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }.onChange(of: anchor) { month = $0 }
    }
    private func shift(_ delta: Int) { month = CalendarDates.calendar.date(byAdding: .month, value: delta, to: shown) }
}

private struct DayInspector: View {
    @ObservedObject var model: AppModel
    let day: Date
    let meetings: [Meeting]
    let availabilityMeetings: [Meeting]
    let loading: Bool
    let complete: Bool
    let select: (Meeting) -> Void
    let create: (Date) -> Void
    let plan: (Range<Date>) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(CalendarDates.text(day, "EEEE").capitalized).font(.subheadline).foregroundStyle(.secondary)
                Text(CalendarDates.text(day, "d MMMM")).font(.title2.bold())
                Button { create(CalendarDates.defaultStart(on: day)) } label: {
                    Label("Создать событие", systemImage: "plus")
                }
                    .help("Открыть создание события в Яндекс Календаре в браузере")
                if complete {
                    DayOverviewView(model: model, day: day, meetings: availabilityMeetings, plan: plan)
                } else {
                    Text(loading ? "Проверяю занятость…" : "Для расчёта свободного времени нужны полные данные за день.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                if meetings.isEmpty {
                    Text(loading ? "Загружаю события…" : (complete ? "Подходящих событий за этот день нет." : "Нет загруженных событий за этот день."))
                        .foregroundStyle(.secondary)
                }
                ForEach(meetings) { meeting in
                    Button { select(meeting) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(meeting.allDay ? "Весь день" : CalendarDates.text(meeting.start, "HH:mm") + " — " + CalendarDates.text(meeting.end, "HH:mm"))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(meeting.title).fontWeight(.medium)
                            InvitationStatusLabel(status: meeting.invitationStatus(for: model.configuration.login))
                            Text(meeting.calendarName).font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .calendarEventCard(color: AppTheme.meetingColor(meeting, model: model), cornerRadius: 8)
                    }.buttonStyle(.plain)
                        .contextMenu { MeetingTintMenu(model: model, meeting: meeting) }
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
