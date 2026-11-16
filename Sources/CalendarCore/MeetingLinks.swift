import Foundation

public enum MeetingLinks {
    private static let telemostHosts = ["telemost.yandex.ru", "telemost.360.yandex.ru", "telemost.yandex.com", "telemost.360.yandex.com"]

    /// Calendar event pages describe an event; they never join a conference.
    public static func isUsableMeetingURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return false }
        if ["calendar.yandex.ru", "calendar.yandex.com", "calendar.360.yandex.ru", "calendar.360.yandex.com",
            "calendar.google.com"].contains(host) { return false }
        if telemostHosts.contains(host) { return telemostDesktopURL(for: url) != nil }
        return true
    }

    public static func conferenceURL(explicitURLs: [URL], texts: [String]) -> URL? {
        let candidates = explicitURLs + texts.flatMap(urls(in:))
        // A real join link in DESCRIPTION/LOCATION takes priority over the event URL.
        if let telemost = candidates.first(where: { telemostDesktopURL(for: $0) != nil }) { return telemost }
        if let known = candidates.first(where: isKnownConferenceURL) { return known }
        // Unknown providers are allowed only in an explicit URL/CONFERENCE field.
        return explicitURLs.first(where: isUsableMeetingURL)
    }

    private static func isKnownConferenceURL(_ url: URL) -> Bool {
        guard isUsableMeetingURL(url), let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        if host == "meet.google.com" { return !path.isEmpty && path != "/" }
        if host == "meet.jit.si" { return !path.isEmpty && path != "/" }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "zoom.com" || host.hasSuffix(".zoom.com") {
            return path.hasPrefix("/j/") || path.hasPrefix("/my/") || path.hasPrefix("/wc/")
        }
        if ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(host) {
            return path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/")
        }
        if host.hasSuffix(".webex.com") {
            return path.contains("/meet/") || path.contains("/join/") ||
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name.uppercased() == "MTID" }) == true
        }
        return false
    }

    private static func urls(in text: String) -> [URL] {
        guard let expression = try? NSRegularExpression(pattern: "https?://[^\\s<>\\\"]+", options: [.caseInsensitive]) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return URL(string: String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;]")))
        }
    }

    /// Matches the public Telemost web client's desktop meeting deeplink format.
    public static func telemostDesktopURL(for url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              telemostHosts.contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let path = parts.path.split(separator: "/")
        guard path.count == 2, path[0] == "j", !path[1].isEmpty,
              path[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        parts.scheme = "https"; parts.path = "/j/" + String(path[1]); parts.query = nil; parts.fragment = nil
        guard let canonical = parts.url else { return nil }
        return URL(string: "telemost://" + canonical.absoluteString)
    }

    public static func browserURL(for url: URL) -> URL {
        guard telemostDesktopURL(for: url) != nil,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = parts.queryItems ?? []
        items.removeAll { $0.name == "skip_app" }
        items.append(URLQueryItem(name: "skip_app", value: "1"))
        parts.queryItems = items
        return parts.url ?? url
    }
}
