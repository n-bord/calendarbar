import Foundation

public enum CalendarAccountIdentity {
    /// Encode the account separately so separators in the original ID are never ambiguous.
    public static func scoped(_ id: String, to login: String) -> String {
        guard !login.isEmpty else { return id }
        return "account:" + Data(login.utf8).base64EncodedString() + ":" + id
    }
}

public struct CalendarInfo: Identifiable, Codable, Hashable {
    public let sourceID: String
    public private(set) var accountLogin: String?
    public let name: String
    public let canCreate: Bool?
    public let canEdit: Bool?
    public let canDelete: Bool?

    public var id: String { CalendarAccountIdentity.scoped(sourceID, to: accountLogin ?? "") }

    private enum CodingKeys: String, CodingKey {
        case sourceID = "id"
        case accountLogin, name, canCreate, canEdit, canDelete
    }

    public init(id: String, name: String, canCreate: Bool? = nil, canEdit: Bool? = nil, canDelete: Bool? = nil) {
        self.sourceID = id; self.name = name; self.canCreate = canCreate
        self.canEdit = canEdit; self.canDelete = canDelete
    }

    public func scoped(to login: String) -> CalendarInfo {
        var calendar = self
        calendar.accountLogin = login.isEmpty ? nil : login
        return calendar
    }

    public func unscoped() -> CalendarInfo { scoped(to: "") }
}

public struct Attendee: Codable, Equatable, Hashable {
    public let email: String
    public let name: String
    public let optional: Bool
    public let response: String

    public init(email: String, name: String, optional: Bool, response: String) {
        self.email = email
        self.name = name
        self.optional = optional
        self.response = response
    }
}

public enum MeetingInvitationStatus: Equatable {
    case accepted, needsAction, tentative, declined, organizer, unknown
}

/// iCalendar DATE values describe civil days and have no time zone.
public struct AllDayDates: Codable, Equatable {
    private let start: DateComponents
    private let end: DateComponents

    init(start: Date, end: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.start = calendar.dateComponents([.year, .month, .day], from: start)
        self.end = calendar.dateComponents([.year, .month, .day], from: end)
    }

    func bounds(in timeZone: TimeZone) -> (start: Date, end: Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let first = calendar.date(from: start), let last = calendar.date(from: end) else { return nil }
        return (first, last)
    }
}

public struct Meeting: Identifiable, Codable, Equatable {
    public let sourceID: String
    public let sourceSeriesID: String
    public let sourceCalendarID: String
    public let sourceCalendarName: String
    public private(set) var accountLogin: String?
    private var displayCalendarName: String?
    public let title: String
    public private(set) var start: Date
    public private(set) var end: Date
    public let allDay: Bool
    public let details: String
    public let location: String
    public let link: URL?
    public let attendees: [Attendee]
    public let organizer: String
    public let cancelled: Bool
    public let uid: String?
    public let recurrenceRule: String?
    public let originalStart: Date?
    public let sourceURL: URL?
    public private(set) var resourceURL: URL?
    public private(set) var etag: String?
    public let isFree: Bool?
    public private(set) var allDayDates: AllDayDates?

    public var id: String { CalendarAccountIdentity.scoped(sourceID, to: accountLogin ?? "") }
    public var seriesID: String { CalendarAccountIdentity.scoped(sourceSeriesID, to: accountLogin ?? "") }
    public var calendarID: String { CalendarAccountIdentity.scoped(sourceCalendarID, to: accountLogin ?? "") }
    public var calendarName: String { displayCalendarName ?? sourceCalendarName }

    private enum CodingKeys: String, CodingKey {
        case sourceID = "id"
        case sourceSeriesID = "seriesID"
        case sourceCalendarID = "calendarID"
        case sourceCalendarName = "calendarName"
        case accountLogin, displayCalendarName, title, start, end, allDay, details, location, link, attendees, organizer
        case cancelled, uid, recurrenceRule, originalStart, sourceURL, resourceURL, etag, isFree, allDayDates
    }

    public init(id: String, seriesID: String, calendarID: String, calendarName: String, title: String,
                start: Date, end: Date, allDay: Bool, details: String, location: String, link: URL?,
                attendees: [Attendee], organizer: String, cancelled: Bool, uid: String? = nil,
                recurrenceRule: String? = nil, originalStart: Date? = nil, sourceURL: URL? = nil,
                resourceURL: URL? = nil, etag: String? = nil, isFree: Bool? = nil, allDayDates: AllDayDates? = nil) {
        self.sourceID = id; self.sourceSeriesID = seriesID; self.sourceCalendarID = calendarID; self.sourceCalendarName = calendarName
        self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.details = details
        self.location = location; self.link = link; self.attendees = attendees; self.organizer = organizer
        self.cancelled = cancelled; self.uid = uid; self.recurrenceRule = recurrenceRule
        self.originalStart = originalStart; self.sourceURL = sourceURL; self.resourceURL = resourceURL
        self.etag = etag; self.isFree = isFree; self.allDayDates = allDayDates
    }

    public func scoped(to login: String, calendarName: String? = nil) -> Meeting {
        var meeting = self
        meeting.accountLogin = login.isEmpty ? nil : login
        meeting.displayCalendarName = login.isEmpty ? nil : calendarName
        return meeting
    }

    public func unscoped() -> Meeting { scoped(to: "") }

    public func withResource(url: URL?, etag: String?) -> Meeting {
        var meeting = self
        meeting.resourceURL = url
        meeting.etag = etag
        return meeting
    }

    public func displayed(in calendar: Calendar, fallbackZone: TimeZone) -> Meeting {
        guard allDay else { return self }
        let days = allDayDates ?? AllDayDates(start: start, end: end, timeZone: fallbackZone)
        guard let bounds = days.bounds(in: calendar.timeZone) else { return self }
        var meeting = self
        meeting.start = bounds.start
        meeting.end = bounds.end
        meeting.allDayDates = days
        return meeting
    }

    public func displayStart(in calendar: Calendar, fallbackZone: TimeZone) -> Date {
        displayed(in: calendar, fallbackZone: fallbackZone).start
    }

    public var isRecurring: Bool { recurrenceRule != nil || originalStart != nil }

    /// Also validates old cached events, which may contain a calendar page in `link`.
    public var joinURL: URL? { MeetingLinks.conferenceURL(explicitURLs: link.map { [$0] } ?? [], texts: [location, details]) }

    public var signature: String {
        // Deterministic across launches; ignore technical DTSTAMP/LAST-MODIFIED changes.
        let people = attendees.sorted { $0.email < $1.email }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return [title, String(start.timeIntervalSince1970), String(end.timeIntervalSince1970),
                String(allDay), details, location, link?.absoluteString ?? "", organizer,
                String(cancelled), String(data: (try? encoder.encode(people)) ?? Data(), encoding: .utf8) ?? ""]
            .joined(separator: "\u{1f}")
    }

    public func declined(by login: String) -> Bool {
        let owner = accountLogin ?? login
        return attendees.contains { $0.email.caseInsensitiveCompare(owner) == .orderedSame && $0.response == "DECLINED" }
    }

    public func invitationStatus(for login: String) -> MeetingInvitationStatus {
        let owner = accountLogin ?? login
        guard !owner.isEmpty else { return .unknown }
        if organizer.caseInsensitiveCompare(owner) == .orderedSame { return .organizer }
        let response = attendees.first { $0.email.caseInsensitiveCompare(owner) == .orderedSame }?.response.uppercased()
        switch response {
        case "ACCEPTED": return .accepted
        case "NEEDS-ACTION": return .needsAction
        case "TENTATIVE": return .tentative
        case "DECLINED": return .declined
        default: return .unknown
        }
    }
}

public enum CalendarError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public enum ChangeKind: String, Codable { case new, changed, cancelled }
public struct MeetingChange {
    public let meeting: Meeting
    public let kind: ChangeKind
    public var previous: Meeting? = nil

    public init(meeting: Meeting, kind: ChangeKind, previous: Meeting? = nil) {
        self.meeting = meeting
        self.kind = kind
        self.previous = previous
    }
}

public enum ChangeDetector {
    public static func changes(old: [Meeting], new: [Meeting], knownSeries: Set<String>,
                               initialized: Bool, now: Date, localWrites: [LocalWriteReceipt] = [], account: String = "") -> [MeetingChange] {
        guard initialized else { return [] }
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return new.compactMap { meeting in
            guard meeting.end > now else { return nil }
            if let prior = previous[meeting.id] {
                guard prior.signature != meeting.signature else { return nil }
                if localWrites.contains(where: { $0.canAcknowledge(previous: prior, current: meeting, account: account, now: now) }) { return nil }
                return MeetingChange(meeting: meeting, kind: meeting.cancelled ? .cancelled : .changed, previous: prior)
            }
            guard !meeting.cancelled, !knownSeries.contains(meeting.seriesID) else { return nil }
            return MeetingChange(meeting: meeting, kind: .new)
        }
    }
}
