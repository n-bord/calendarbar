import AppKit
import SwiftUI
import CalendarCore

struct SearchMeetingsView: View {
    @ObservedObject var model: AppModel
    let showInCalendar: (Meeting) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var query: String
    @State private var showPeriod = false
    @State private var period: Range<Date>
    @State private var revision = 0
    @State private var started = false
    @State private var selectedMeeting: Meeting?
    @State private var highlightedID: String?

    init(model: AppModel, initialQuery: String, showInCalendar: @escaping (Meeting) -> Void) {
        self.model = model
        self.showInCalendar = showInCalendar
        _query = State(initialValue: initialQuery)
        let calendar = CalendarDates.calendar
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .month, value: -3, to: today)!
        let end = calendar.date(byAdding: DateComponents(month: 3, day: 1), to: today)!
        _period = State(initialValue: start..<end)
    }

    private var groups: [MenuScheduleDay] {
        let visibleCalendars = model.visibleCalendarIDs
        let meetings = model.searchResults.filter {
            visibleCalendars.contains($0.calendarID) && !$0.cancelled && MeetingSearch.matches($0, query: query)
        }.map(model.displayedMeeting)
        return MenuScheduleDay.group(meetings, calendar: CalendarDates.calendar)
    }

    var body: some View {
        searchContent
            .opacity(selectedMeeting == nil ? 1 : 0)
            .allowsHitTesting(selectedMeeting == nil)
            .accessibilityHidden(selectedMeeting != nil)
            .overlay {
                if let selectedMeeting {
                    meetingDetails(model.searchResults.first { $0.id == selectedMeeting.id } ?? selectedMeeting)
                }
            }
            .frame(minWidth: 520, idealWidth: 690, minHeight: 350, idealHeight: 520)
            .background(AppTheme.calendarChrome)
            .tint(AppTheme.controlAccent)
            .task { searchFocused = true }
            .task(id: revision) {
                started = true
                await model.searchMeetings(range: period)
            }
            .onChange(of: model.visibleCalendarIDs) { visible in
                if let selectedMeeting, !visible.contains(selectedMeeting.calendarID) { returnToResults() }
            }
            .onReceive(model.clearedCalendarCaches) { logins in
                if let login = selectedMeeting?.accountLogin, logins.contains(login) { returnToResults() }
            }
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Поиск встреч").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if selectedMeeting == nil {
                    Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Название, участник, описание или место", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .background(SearchFieldKeys(
                        enabled: searchFocused && selectedMeeting == nil && !showPeriod,
                        onMove: moveHighlight, onOpen: openHighlightedResult))
                if !query.isEmpty {
                    Button {
                        query = ""
                        searchFocused = true
                    } label: {
                        Label("Очистить запрос", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(9)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(searchFocused ? AppTheme.controlAccent : Color.secondary.opacity(0.3))
                    .allowsHitTesting(false)
            }
            HStack(spacing: 10) {
                Button { showPeriod = true } label: {
                    Label("Период", systemImage: "calendar")
                }
                .popover(isPresented: $showPeriod, arrowEdge: .bottom) {
                    SearchPeriodPicker(period: period) { chosen in
                        period = chosen
                        revision += 1
                        showPeriod = false
                        searchFocused = true
                    }
                }
                Text(SearchPeriodPicker.title(for: period))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if model.searchLoading { ProgressView().controlSize(.small) }
            }
            Divider()
            results
        }
        .padding(20)
        .onChange(of: query) { _ in highlightedID = nil }
        .onChange(of: revision) { _ in highlightedID = nil }
    }

    private func meetingDetails(_ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: returnToResults) {
                    Label("К результатам", systemImage: "chevron.left")
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Готово") { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            MeetingView(model: model, meeting: meeting, showInCalendar: { showInCalendar(meeting) })
                .id(meeting.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.calendarChrome)
    }

    private func returnToResults() {
        selectedMeeting = nil
        searchFocused = true
    }

    private func moveHighlight(_ offset: Int) -> Bool {
        let meetings = started ? groups.flatMap(\.meetings) : []
        guard !meetings.isEmpty else { return false }
        let current = meetings.firstIndex { $0.id == highlightedID }
        let index = current.map { min(max(0, $0 + offset), meetings.count - 1) }
            ?? (offset > 0 ? 0 : meetings.count - 1)
        highlightedID = meetings[index].id
        return true
    }

    private func openHighlightedResult() -> Bool {
        guard started else { return false }
        let meetings = groups.flatMap(\.meetings)
        guard let meeting = meetings.first(where: { $0.id == highlightedID }) ?? meetings.first else { return false }
        openResult(meeting)
        return true
    }

    private func openResult(_ meeting: Meeting) {
        highlightedID = meeting.id
        searchFocused = false
        selectedMeeting = meeting
    }

    private var results: some View {
        let matches = started ? groups : []
        return ScrollViewReader { proxy in
            ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if started && !model.searchError.isEmpty {
                    Label(model.searchError, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                if matches.isEmpty {
                    Text(emptyMessage).foregroundStyle(.secondary).padding(.vertical, 16)
                }
                ForEach(matches) { day in
                    Text(day.title(relativeTo: Date(), calendar: CalendarDates.calendar))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 5)
                    ForEach(day.meetings) { meeting in
                        resultRow(meeting)
                            .id(meeting.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: highlightedID) { id in
                if let id { proxy.scrollTo(id) }
            }
            .onChange(of: selectedMeeting?.id) { id in
                if id == nil, let highlightedID { proxy.scrollTo(highlightedID) }
            }
        }
    }

    private var emptyMessage: String {
        if !started || model.searchLoading { return "Загружаю встречи…" }
        if model.activeAccountLogins.isEmpty { return "Включите аккаунт в настройках, чтобы искать встречи." }
        if !model.searchError.isEmpty { return "В сохранённых данных совпадений нет." }
        if model.visibleCalendarIDs.isEmpty { return "Включите нужные календари в боковой панели." }
        return "В этом периоде ничего не найдено. Попробуйте другой запрос или даты."
    }

    private func resultRow(_ meeting: Meeting) -> some View {
        let highlighted = highlightedID == meeting.id
        return HStack(spacing: 8) {
            Button {
                openResult(meeting)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Text(meeting.allDay ? "Весь день" : CalendarDates.text(meeting.start, "HH:mm"))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title).fontWeight(.medium)
                        Text(meeting.calendarName + (meeting.location.isEmpty ? "" : " · " + meeting.location))
                            .font(.caption).foregroundStyle(.secondary)
                        InvitationStatusLabel(status: meeting.invitationStatus(for: model.configuration.login))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(highlighted ? .isSelected : [])
            .help("Открыть карточку встречи")
            Button {
                showInCalendar(meeting)
            } label: {
                Label("В календаре", systemImage: "calendar")
            }
            .controlSize(.small)
            .help("Перейти к дате встречи в календаре")
        }
        .padding(9)
        .background(highlighted ? AppTheme.controlAccent.opacity(0.17) : Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 7).strokeBorder(AppTheme.controlAccent, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu { MeetingTintMenu(model: model, meeting: meeting) }
    }
}

/// Keeps arrow handling local to the search field editor on macOS 13 and later.
private struct SearchFieldKeys: NSViewRepresentable {
    let enabled: Bool
    let onMove: (Int) -> Bool
    let onOpen: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak coordinator] event in
            guard let window = view?.window, event.window === window,
                  coordinator?.keys?.enabled == true,
                  let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, !editor.hasMarkedText(),
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let keys = coordinator?.keys else { return event }
            let handled: Bool
            switch event.keyCode {
            case 125: handled = keys.onMove(1)
            case 126: handled = keys.onMove(-1)
            case 36, 76: handled = keys.onOpen()
            default: handled = false
            }
            return handled ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.keys = self
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    final class Coordinator {
        var keys: SearchFieldKeys?
        var monitor: Any?
    }
}

private struct SearchPeriodPicker: View {
    @State private var from: Date
    @State private var to: Date
    let apply: (Range<Date>) -> Void

    init(period: Range<Date>, apply: @escaping (Range<Date>) -> Void) {
        _from = State(initialValue: period.lowerBound)
        _to = State(initialValue: Self.inclusiveEnd(of: period))
        self.apply = apply
    }

    private var selectedPeriod: Range<Date>? {
        let calendar = CalendarDates.calendar
        let start = calendar.startOfDay(for: from)
        let lastDay = calendar.startOfDay(for: to)
        guard start <= lastDay,
              let end = calendar.date(byAdding: .day, value: 1, to: lastDay),
              end.timeIntervalSince(start) <= 3 * 366 * 86400 else { return nil }
        return start..<end
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Период поиска").font(.headline).accessibilityAddTraits(.isHeader)
            DatePicker("С", selection: $from, displayedComponents: .date)
            DatePicker("По", selection: $to, displayedComponents: .date)
            if selectedPeriod == nil {
                Text("Проверьте порядок дат. Максимальный период — три года.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Прошлый год") { selectYear(offset: -1) }
                Button("Этот год") { selectYear(offset: 0) }
            }
            Divider()
            Button("Применить") {
                if let selectedPeriod { apply(selectedPeriod) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedPeriod == nil)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private func selectYear(offset: Int) {
        let calendar = CalendarDates.calendar
        guard let date = calendar.date(byAdding: .year, value: offset, to: Date()),
              let year = calendar.dateInterval(of: .year, for: date) else { return }
        from = year.start
        to = Self.inclusiveEnd(of: year.start..<year.end)
    }

    private static func inclusiveEnd(of period: Range<Date>) -> Date {
        CalendarDates.calendar.date(byAdding: .day, value: -1, to: period.upperBound) ?? period.lowerBound
    }

    static func title(for period: Range<Date>) -> String {
        CalendarDates.text(period.lowerBound, "d MMM yyyy") + " — " +
            CalendarDates.text(inclusiveEnd(of: period), "d MMM yyyy")
    }
}
