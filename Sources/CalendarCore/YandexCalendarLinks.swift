import Foundation

/// Web navigation only: these URLs must never be used as conference join links.
public enum YandexCalendarLinks {
    public static let home = URL(string: "https://calendar.yandex.ru/")!
    private static let hosts: Set<String> = ["calendar.yandex.ru", "calendar.yandex.com", "calendar.360.yandex.ru", "calendar.360.yandex.com"]

    public static func isEventURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", hosts.contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil else { return false }
        let path = parts.path.split(separator: "/")
        guard let index = path.firstIndex(of: "event") else { return false }
        if path.index(after: index) < path.endIndex { return true }
        return parts.queryItems?.contains(where: {
            $0.name == "event_id" && !($0.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) == true
    }

    /// The public Yandex Calendar landing page links its Create action to /week/create.
    public static func create(start: Date, end: Date? = nil, timeZone: TimeZone) -> URL {
        var parts = URLComponents(string: "https://calendar.yandex.ru/week/create")!
        parts.queryItems = [URLQueryItem(name: "show_date", value: day(start, timeZone: timeZone)),
            URLQueryItem(name: "start", value: localDateTime(start, timeZone: timeZone)),
            URLQueryItem(name: "end", value: localDateTime(end ?? start.addingTimeInterval(1800), timeZone: timeZone)),
            URLQueryItem(name: "tz_id", value: timeZone.identifier)]
        return parts.url!
    }

    public static func event(_ meeting: Meeting, timeZone: TimeZone) -> URL {
        if let source = meeting.sourceURL, isEventURL(source) { return source }
        // A CalDAV UID is not a web event_id. Open its date instead of fabricating a broken event link.
        var parts = URLComponents(string: "https://calendar.yandex.ru/day")!
        parts.queryItems = [URLQueryItem(name: "show_date", value: day(meeting.start, timeZone: timeZone)),
            URLQueryItem(name: "tz_id", value: timeZone.identifier)]
        return parts.url!
    }

    private static func day(_ date: Date, timeZone: TimeZone) -> String {
        format(date, pattern: "yyyy-MM-dd", timeZone: timeZone)
    }
    private static func localDateTime(_ date: Date, timeZone: TimeZone) -> String {
        format(date, pattern: "yyyy-MM-dd'T'HH:mm:ss", timeZone: timeZone)
    }
    private static func format(_ date: Date, pattern: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone; formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
