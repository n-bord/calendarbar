import Foundation

/// Scope of a local meeting override.
public enum EventScope: String, CaseIterable { case occurrence = "Только эта встреча", series = "Вся серия" }

public struct ReminderOverride: Codable, Equatable {
    public var muted: Bool
    /// nil inherits the defaults; an empty array explicitly disables reminders.
    public var minutes: [Int]?
    public init(muted: Bool = false, minutes: [Int]? = nil) {
        self.muted = muted
        self.minutes = minutes.map { Array(Set($0.filter { CalendarConfiguration.reminderRange.contains($0) })).sorted(by: >) }
    }
}

public struct SnoozedReminder: Codable, Identifiable, Equatable {
    public let meeting: Meeting
    public let fireAt: Date
    public var id: String { meeting.id }
    public init(meeting: Meeting, fireAt: Date) { self.meeting = meeting; self.fireAt = fireAt }
    public func isValid(for current: Meeting, now: Date) -> Bool {
        !current.cancelled && current.end > now && fireAt > now && fireAt < current.end &&
        meeting.start == current.start && meeting.end == current.end && meeting.joinURL == current.joinURL
    }
}

public struct ActivityEntry: Codable, Identifiable, Equatable {
    public let id: String
    public let meeting: Meeting
    public let previous: Meeting?
    public let kind: ChangeKind
    public let date: Date
    public var read: Bool
    public init(change: MeetingChange, date: Date = Date()) {
        meeting = change.meeting; previous = change.previous; kind = change.kind; self.date = date; read = false
        id = meeting.id + "|" + kind.rawValue + "|" + meeting.signature
    }
    public var title: String {
        switch kind { case .new: return "Новая встреча"; case .changed: return "Встреча изменена"; case .cancelled: return "Встреча отменена" }
    }
    public var important: Bool {
        guard kind == .changed, let old = previous else { return true }
        return timeChanged || old.title != meeting.title || old.location != meeting.location ||
            joinLinkChanged || old.cancelled != meeting.cancelled
    }
    public var timeChanged: Bool {
        guard kind == .changed, let previous else { return false }
        return previous.start != meeting.start || previous.end != meeting.end ||
            previous.allDay != meeting.allDay || previous.allDayDates != meeting.allDayDates
    }

    public var joinLinkChanged: Bool {
        kind == .changed && previous.map { $0.joinURL != meeting.joinURL } == true
    }

    public func summary(timeZone: TimeZone = .current) -> String {
        guard kind == .changed, let old = previous else { return title }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU"); formatter.timeZone = timeZone
        func timeRange(_ event: Meeting) -> String {
            let dayBounds = event.allDay ? event.allDayDates?.bounds(in: timeZone) : nil
            formatter.dateFormat = event.allDay ? "d MMM yyyy" : "d MMM yyyy, HH:mm"
            let start = formatter.string(from: dayBounds?.start ?? event.start)
            if event.allDay {
                let lastDay = formatter.string(from: (dayBounds?.end ?? event.end).addingTimeInterval(-1))
                return (lastDay == start ? start : start + "–" + lastDay) + " · весь день"
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            if calendar.isDate(event.start, inSameDayAs: event.end) { formatter.dateFormat = "HH:mm" }
            return start + "–" + formatter.string(from: event.end)
        }
        var changes: [String] = []
        if timeChanged { changes.append("Было " + timeRange(old) + " → стало " + timeRange(meeting)) }
        if old.title != meeting.title { changes.append("Название: «\(old.title)» → «\(meeting.title)»") }
        if joinLinkChanged {
            if meeting.joinURL == nil { changes.append("Ссылка на звонок удалена") }
            else if old.joinURL == nil { changes.append("Добавлена ссылка на звонок") }
            else { changes.append("Сменилась ссылка на звонок") }
        }
        if old.location != meeting.location { changes.append(meeting.location.isEmpty ? "Место встречи удалено" : "Место: " + meeting.location) }
        if old.details != meeting.details { changes.append("Обновлено описание") }
        if old.attendees != meeting.attendees { changes.append("Обновлены участники") }
        return changes.isEmpty ? "Обновлены сведения о встрече" : changes.joined(separator: "\n")
    }
}

public struct PinnedMeeting: Codable, Equatable, Identifiable {
    public let title: String
    public let url: URL

    public var id: URL { Self.identity(for: url) }

    public init?(title: String, url: URL) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, MeetingLinks.isUsableMeetingURL(url) else { return nil }
        self.title = title
        self.url = url
    }

    public static func identity(for url: URL) -> URL {
        MeetingLinks.telemostDesktopURL(for: url) ?? url
    }
}

public struct FinishedMeetingReference: Codable, Equatable {
    public let id: String
    public let end: Date

    public init(_ meeting: Meeting) {
        id = meeting.id
        end = meeting.end
    }
}

public struct PersonalCalendarState: Codable {
    public var overrides: [String: ReminderOverride] = [:]
    public var snoozes: [SnoozedReminder] = []
    public var activity: [ActivityEntry] = []
    public var localWrites: [LocalWriteReceipt] = []
    public var templates: [EventTemplate] = []
    public private(set) var pinnedMeetings: [PinnedMeeting] = []
    public var hiddenLastMeeting: FinishedMeetingReference?
    /// Calendars excluded from the sidebar in Settings (legacy key retained).
    public var hiddenCalendars: Set<String> = []
    /// Sidebar checkboxes hide events without removing the calendar from the list.
    public var filteredCalendars: Set<String> = []
    private var calendarTints: [String: CalendarTint] = [:]
    private var occurrenceTints: [String: CalendarTint] = [:]
    private var seriesTints: [String: CalendarTint] = [:]
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case overrides, snoozes, activity, hiddenCalendars, filteredCalendars, templates, localWrites, pinnedMeetings, hiddenLastMeeting
        case calendarTints, occurrenceTints, seriesTints
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localWrites = try c.decodeIfPresent([LocalWriteReceipt].self, forKey: .localWrites) ?? []
        overrides = try c.decodeIfPresent([String: ReminderOverride].self, forKey: .overrides) ?? [:]
        snoozes = try c.decodeIfPresent([SnoozedReminder].self, forKey: .snoozes) ?? []
        activity = try c.decodeIfPresent([ActivityEntry].self, forKey: .activity) ?? []
        hiddenCalendars = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenCalendars) ?? []
        filteredCalendars = try c.decodeIfPresent(Set<String>.self, forKey: .filteredCalendars) ?? []
        templates = try c.decodeIfPresent([EventTemplate].self, forKey: .templates) ?? []
        var pinnedIDs = Set<URL>()
        pinnedMeetings = (try? c.decode([PinnedMeeting].self, forKey: .pinnedMeetings))?.filter {
            MeetingLinks.isUsableMeetingURL($0.url) && pinnedIDs.insert($0.id).inserted
        } ?? []
        hiddenLastMeeting = try? c.decode(FinishedMeetingReference.self, forKey: .hiddenLastMeeting)
        calendarTints = Self.decodeTints(c, forKey: .calendarTints)
        occurrenceTints = Self.decodeTints(c, forKey: .occurrenceTints)
        seriesTints = Self.decodeTints(c, forKey: .seriesTints)
    }

    private static func decodeTints(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> [String: CalendarTint] {
        let values = (try? container.decode([String: String].self, forKey: key)) ?? [:]
        return values.compactMapValues(CalendarTint.init(rawValue:))
    }

    public func calendarTint(for calendarID: String) -> CalendarTint? {
        calendarTints[calendarID]
    }

    public mutating func setCalendarTint(_ tint: CalendarTint?, for calendarID: String) {
        calendarTints[calendarID] = tint
    }

    public func meetingTint(for meeting: Meeting, scope: EventScope? = nil) -> CalendarTint? {
        let occurrence = occurrenceTints[meeting.sourceID]
        let series = seriesTints[meeting.sourceSeriesID]
        switch scope {
        case .occurrence: return occurrence
        case .series: return series
        case nil: return occurrence ?? series ?? calendarTint(for: meeting.sourceCalendarID)
        }
    }

    public mutating func setMeetingTint(_ tint: CalendarTint?, for meeting: Meeting, scope: EventScope) {
        switch scope {
        case .occurrence: occurrenceTints[meeting.sourceID] = tint
        case .series: seriesTints[meeting.sourceSeriesID] = tint
        }
    }
    public func isPinned(_ url: URL) -> Bool {
        pinnedMeetings.contains { $0.id == PinnedMeeting.identity(for: url) }
    }
    public mutating func togglePin(title: String, url: URL) {
        if isPinned(url) { removePin(PinnedMeeting.identity(for: url)) }
        else if let pin = PinnedMeeting(title: title, url: url) { _ = savePin(pin) }
    }
    @discardableResult
    public mutating func savePin(_ pin: PinnedMeeting, replacing id: URL? = nil) -> Bool {
        guard !pinnedMeetings.contains(where: { $0.id == pin.id && $0.id != id }) else { return false }
        if let id {
            guard let index = pinnedMeetings.firstIndex(where: { $0.id == id }) else { return false }
            pinnedMeetings[index] = pin
        } else {
            pinnedMeetings.insert(pin, at: 0)
        }
        return true
    }
    @discardableResult
    public mutating func movePin(_ id: URL, by offset: Int) -> Bool {
        guard let index = pinnedMeetings.firstIndex(where: { $0.id == id }),
              offset == -1 || offset == 1, pinnedMeetings.indices.contains(index + offset) else { return false }
        pinnedMeetings.swapAt(index, index + offset)
        return true
    }
    public mutating func removePin(_ id: URL) {
        pinnedMeetings.removeAll { $0.id == id }
    }
    public func listedCalendarIDs(in calendars: [CalendarInfo]) -> Set<String> {
        Set(calendars.map(\.id)).subtracting(hiddenCalendars)
    }
    public func visibleCalendarIDs(in calendars: [CalendarInfo]) -> Set<String> {
        listedCalendarIDs(in: calendars).subtracting(filteredCalendars)
    }
    public mutating func includeCalendar(_ id: String, included: Bool) {
        if included {
            guard hiddenCalendars.remove(id) != nil else { return }
        } else {
            guard hiddenCalendars.insert(id).inserted else { return }
        }
        // Adding a calendar to the list should also show its events initially.
        filteredCalendars.remove(id)
    }
    public mutating func showCalendarEvents(_ id: String, visible: Bool) {
        guard !hiddenCalendars.contains(id) else { return }
        if visible { filteredCalendars.remove(id) }
        else { filteredCalendars.insert(id) }
    }
    public func settings(for meeting: Meeting) -> ReminderOverride? {
        overrides[meeting.id] ?? overrides["series:" + meeting.seriesID]
    }
    public func offsets(for meeting: Meeting, defaults: [Int]) -> [Int] {
        guard let value = settings(for: meeting) else { return defaults }
        return value.muted ? [] : value.minutes ?? defaults
    }
    public mutating func reconcileSnoozes(with meetings: [Meeting], refreshedRange: Range<Date>, calendarIDs: Set<String>, now: Date) {
        let current = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        snoozes.removeAll { snooze in
            guard snooze.fireAt > now, snooze.meeting.end > now else { return true }
            guard calendarIDs.contains(snooze.meeting.calendarID), CalendarLayout.intersects(snooze.meeting, range: refreshedRange) else { return false }
            guard let meeting = current[snooze.id] else { return true }
            return !snooze.isValid(for: meeting, now: now)
        }
    }
}

public struct PlannedReminder: Equatable {
    public let meeting: Meeting
    public let date: Date
    public let minutes: Int?
    public let snoozed: Bool
    public func scoped(to login: String) -> PlannedReminder {
        PlannedReminder(meeting: meeting.scoped(to: login), date: date, minutes: minutes, snoozed: snoozed)
    }
    public var key: String {
        meeting.id + "|" + String(meeting.start.timeIntervalSince1970) + "|" +
        String(meeting.end.timeIntervalSince1970) + "|" + (meeting.joinURL?.absoluteString ?? "") + "|" +
        (snoozed ? "snooze" : String(minutes ?? 0)) + "|" + String(date.timeIntervalSince1970)
    }
}

public enum ReminderPlanner {
    public static func plan(meetings: [Meeting], state: PersonalCalendarState, defaults: [Int],
                            calendarIDs: Set<String>, account: String, now: Date, limit: Int = 60) -> [PlannedReminder] {
        var result: [PlannedReminder] = []
        let snoozes = Dictionary(state.snoozes.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for meeting in meetings where calendarIDs.contains(meeting.calendarID) && !meeting.cancelled &&
            !meeting.declined(by: account) && !meeting.allDay && meeting.end > now {
            guard state.settings(for: meeting)?.muted != true else { continue }
            let snooze = snoozes[meeting.id].flatMap { $0.isValid(for: meeting, now: now) ? $0 : nil }
            if let snooze { result.append(PlannedReminder(meeting: meeting, date: snooze.fireAt, minutes: nil, snoozed: true)) }
            for minutes in Set(state.offsets(for: meeting, defaults: defaults)) where CalendarConfiguration.reminderRange.contains(minutes) {
                let date = meeting.start.addingTimeInterval(Double(-minutes * 60))
                // Snoozing acknowledges the earlier default reminders for this occurrence.
                if date > now.addingTimeInterval(1), snooze == nil || date > snooze!.fireAt {
                    result.append(PlannedReminder(meeting: meeting, date: date, minutes: minutes, snoozed: false))
                }
            }
        }
        return Array(result.sorted { $0.date == $1.date ? $0.key < $1.key : $0.date < $1.date }.prefix(max(0, limit)))
    }
}

public enum MeetingSearch {
    public static func matches(_ meeting: Meeting, query: String) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let text = ([meeting.title, meeting.details, meeting.location, meeting.organizer, meeting.calendarName] +
            meeting.attendees.flatMap { [$0.name, $0.email] }).joined(separator: " ")
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

public struct CalendarConflict: Identifiable {
    public let first: Meeting
    public let second: Meeting
    public let overlap: TimeInterval
    public var id: String { first.id + "|" + second.id }
}

public struct DayOverview {
    public let meetings: [Meeting]
    public let conflicts: [CalendarConflict]
    public let freeSlots: [Range<Date>]
    public let busyMinutes: Int
    public static func make(meetings: [Meeting], day: Date, calendar: Calendar, account: String,
                            startHour: Int = 9, endHour: Int = 18, minimumMinutes: Int = 30,
                            includeConflicts: Bool = true, blockAllTimedEvents: Bool = false) -> DayOverview {
        let first = calendar.startOfDay(for: day)
        let next = calendar.date(byAdding: .day, value: 1, to: first)!
        let events = meetings.filter {
            !$0.cancelled && (blockAllTimedEvents || !$0.declined(by: account)) &&
                CalendarLayout.intersects($0, range: first..<next)
        }
            .sorted { $0.start < $1.start }
        let timed = events.filter { !$0.allDay && (blockAllTimedEvents || $0.isFree != true) && $0.end > $0.start }
        var conflicts: [CalendarConflict] = []
        if includeConflicts {
            for (index, meeting) in timed.enumerated() {
                for other in timed[(index + 1)...] {
                    guard other.start < meeting.end else { break }
                    let overlap = min(meeting.end, other.end).timeIntervalSince(other.start)
                    conflicts.append(CalendarConflict(first: meeting, second: other, overlap: overlap))
                }
            }
        }
        let start = calendar.date(bySettingHour: min(max(startHour, 0), 23), minute: 0, second: 0, of: first)!
        let end = endHour >= 24 ? next : calendar.date(bySettingHour: min(max(endHour, 1), 23), minute: 0, second: 0, of: first)!
        var slots: [Range<Date>] = [], cursor = start, busy: TimeInterval = 0
        if end > start {
            for meeting in timed where meeting.end > start && meeting.start < end {
                let a = max(start, meeting.start), b = min(end, meeting.end)
                if a > cursor && a.timeIntervalSince(cursor) >= Double(minimumMinutes * 60) { slots.append(cursor..<a) }
                if b > max(cursor, a) { busy += b.timeIntervalSince(max(cursor, a)) }
                cursor = max(cursor, b)
            }
            if end > cursor && end.timeIntervalSince(cursor) >= Double(minimumMinutes * 60) { slots.append(cursor..<end) }
        }
        return DayOverview(meetings: events, conflicts: conflicts, freeSlots: slots, busyMinutes: Int(busy / 60))
    }
}

public enum FreeSlotPlanning {
    public static func eventRange(in slot: Range<Date>, at now: Date) -> Range<Date>? {
        let earliest = max(slot.lowerBound, now).timeIntervalSinceReferenceDate
        let start = Date(timeIntervalSinceReferenceDate: ceil(earliest / 60) * 60)
        let end = min(start.addingTimeInterval(1800), slot.upperBound)
        let endOnMinute = Date(timeIntervalSinceReferenceDate: floor(end.timeIntervalSinceReferenceDate / 60) * 60)
        guard endOnMinute > start else { return nil }
        return start..<endOnMinute
    }
}
