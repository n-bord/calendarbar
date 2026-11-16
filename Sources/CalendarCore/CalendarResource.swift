import Foundation

public struct CachedCalendarResource: Codable, Equatable {
    public let href: String
    public let etag: String?
    public let data: String
    public var lastUsed: Date
    public init(href: String, etag: String?, data: String, lastUsed: Date = Date()) {
        self.href = href; self.etag = etag; self.data = data; self.lastUsed = lastUsed
    }
}

public struct CalendarFetch {
    public let meetings: [Meeting]
    public let resources: [CachedCalendarResource]
    public let failedResources: [String: String]
}

public enum CalendarCachePolicy {
    public static func isFresh(cachedRange: Range<Date>, savedAt: Date, requestedRange: Range<Date>,
                               now: Date = Date(), lifetime: TimeInterval = 120) -> Bool {
        cachedRange.lowerBound <= requestedRange.lowerBound && cachedRange.upperBound >= requestedRange.upperBound &&
            now >= savedAt && now.timeIntervalSince(savedAt) < lifetime
    }
}
