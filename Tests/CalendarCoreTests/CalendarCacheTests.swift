import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CalendarCore

private enum CacheProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    static func execute(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let handler else { throw URLError(.badServerResponse) }
        let (code, text) = try handler(request)
        return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

final class CalendarCacheTests: XCTestCase {
    let calendar = CalendarInfo(id: "https://caldav.yandex.ru/calendars/me/events/", name: "Рабочий")
    let zone = TimeZone(secondsFromGMT: 0)!
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    override func tearDown() { CacheProtocol.handler = nil }
    func href(_ key: String) -> String { calendar.id + key + ".ics" }
    func ics(_ key: String, title: String = "Встреча") -> String {
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:\(key)\r\nSUMMARY:\(title)\r\nDTSTART:20261021T090000Z\r\nDTEND:20261021T093000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    }
    func resource(_ key: String, _ tag: String?) -> CachedCalendarResource {
        CachedCalendarResource(href: href(key), etag: tag, data: ics(key))
    }
    func xml(_ items: [(String, String?, String?)], missing: Bool = false) -> String {
        let body = items.map { key, tag, data in
            let status = missing ? "<d:status>HTTP/1.1 404 Not Found</d:status>" : "<d:propstat><d:prop>" +
                (tag.map { "<d:getetag>\($0)</d:getetag>" } ?? "") +
                (data.map { "<c:calendar-data><![CDATA[\($0)]]></c:calendar-data>" } ?? "") +
                "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>"
            return "<d:response><d:href>\(href(key))</d:href>\(status)</d:response>"
        }.joined()
        return "<d:multistatus xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\">\(body)</d:multistatus>"
    }
    func body(_ request: URLRequest) -> String {
        if let bytes = request.httpBody { return String(decoding: bytes, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: result, as: UTF8.self)
    }
    func fetch(_ cache: [String: CachedCalendarResource]) async throws -> CalendarFetch {
        try await CalDAVClient(login: "me@example.org", password: "test-only", execute: CacheProtocol.execute)
            .fetchMeetings(in: calendar, start: date("2026-10-20T00:00:00Z"), end: date("2026-10-23T00:00:00Z"),
                fallbackZone: zone, cached: cache)
    }

    func testUnchangedResourceOnlyRequestsMetadata() async throws {
        var requests = 0
        CacheProtocol.handler = { request in
            requests += 1
            let body = self.body(request)
            XCTAssertTrue(body.contains("calendar-query")); XCTAssertFalse(body.contains("calendar-data"))
            return (207, self.xml([("a", "v1", nil)]))
        }
        let result = try await fetch([href("a"): resource("a", "v1")])
        XCTAssertEqual(requests, 1); XCTAssertEqual(result.meetings.count, 1)
    }

    func testScopedCalendarUsesOriginalRequestURLAndRejectsAnotherAccount() async throws {
        var requests = 0
        CacheProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.absoluteString, self.calendar.sourceID)
            return (207, self.xml([("a", "v1", nil)]))
        }
        let client = CalDAVClient(login: "me@example.org", password: "test-only", execute: CacheProtocol.execute)
        let start = date("2026-10-20T00:00:00Z"), end = date("2026-10-23T00:00:00Z")
        let owned = calendar.scoped(to: "me@example.org")
        let result = try await client.fetchMeetings(in: owned, start: start, end: end, fallbackZone: zone,
            cached: [href("a"): resource("a", "v1")])
        XCTAssertEqual(result.meetings.first?.calendarID, owned.id)
        XCTAssertEqual(result.meetings.first?.accountLogin, "me@example.org")

        do {
            _ = try await client.fetchMeetings(in: calendar.scoped(to: "other@example.org"), start: start, end: end,
                fallbackZone: zone, cached: [:])
            XCTFail("The other account's calendar must not be sent using this client's credentials")
        } catch {
            XCTAssertEqual(requests, 1)
        }
    }

    func testOnlyChangedBodyIsDownloaded() async throws {
        var requests = 0
        CacheProtocol.handler = { request in
            requests += 1
            let body = self.body(request)
            if body.contains("calendar-query") { return (207, self.xml([("a", "1", nil), ("b", "2", nil)])) }
            XCTAssertTrue(body.contains("calendar-multiget")); XCTAssertTrue(body.contains("/b.ics"))
            XCTAssertFalse(body.contains("/a.ics"))
            return (207, self.xml([("b", "2", self.ics("b", title: "Новое время"))]))
        }
        let result = try await fetch([href("a"): resource("a", "1"), href("b"): resource("b", "old")])
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(Set(result.meetings.map(\.title)), ["Встреча", "Новое время"])
    }

    func testDeletedResourceDoesNotRemainInQueryResults() async throws {
        CacheProtocol.handler = { _ in (207, self.xml([("a", "1", nil)])) }
        let result = try await fetch([href("a"): resource("a", "1"), href("b"): resource("b", "1")])
        XCTAssertEqual(result.resources.map(\.href), [href("a")]); XCTAssertEqual(result.meetings.count, 1)
    }

    func testPartialResponseFailsWithoutChangingInputCache() async {
        let cached = resource("a", "old")
        CacheProtocol.handler = { request in
            if self.body(request).contains("calendar-query") { return (207, self.xml([("a", "new", nil)])) }
            return (207, self.xml([("a", nil, nil)], missing: true))
        }
        do { _ = try await fetch([href("a"): cached]); XCTFail("Expected an incomplete response error") }
        catch { XCTAssertEqual(cached.etag, "old"); XCTAssertEqual(cached.data, ics("a")) }
    }

    func testUnsupportedSeriesDoesNotHideValidResourcesOrReplaceItsCachedBody() async throws {
        let malformedSeries = ics("series").replacingOccurrences(of: "DTEND:20261021T093000Z",
            with: "DTEND:20261021T093000Z\r\nRRULE:FREQ=UNSUPPORTED")
        CacheProtocol.handler = { request in
            if self.body(request).contains("calendar-query") {
                return (207, self.xml([("series", "new", nil), ("valid", "1", nil)]))
            }
            return (207, self.xml([("series", "new", malformedSeries), ("valid", "1", self.ics("valid"))]))
        }

        let cached = resource("series", "old")
        let result = try await fetch([href("series"): cached])

        XCTAssertEqual(result.meetings.map { $0.resourceURL?.absoluteString }, [href("valid")])
        XCTAssertEqual(result.resources.map(\.href), [href("valid")])
        XCTAssertEqual(Set(result.failedResources.keys), [href("series")])
    }

    func testFullQueryReportsParserFailureWithoutDroppingOtherResources() async throws {
        CacheProtocol.handler = { request in
            guard self.body(request).contains("calendar-data") else { return (405, "") }
            return (207, self.xml([("bad", "1", "not iCalendar"), ("valid", "1", self.ics("valid"))]))
        }

        let result = try await fetch([:])

        XCTAssertEqual(result.meetings.map { $0.resourceURL?.absoluteString }, [href("valid")])
        XCTAssertEqual(result.resources.map(\.href), [href("valid")])
        XCTAssertEqual(Set(result.failedResources.keys), [href("bad")])
    }

    func testMissingETagNeverTrustsOldBody() async throws {
        var requests = 0
        CacheProtocol.handler = { request in
            requests += 1
            return self.body(request).contains("calendar-query") ?
                (207, self.xml([("a", nil, nil)])) : (207, self.xml([("a", nil, self.ics("a", title: "Обновлено"))]))
        }
        let result = try await fetch([href("a"): resource("a", nil)])
        XCTAssertEqual(requests, 2); XCTAssertEqual(result.meetings.first?.title, "Обновлено")
    }

    func testUnsupportedMultigetFallsBackToGet() async throws {
        var methods: [String] = []
        CacheProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "GET" { return (200, self.ics("a")) }
            return self.body(request).contains("calendar-query") ? (207, self.xml([("a", "1", nil)])) : (405, "")
        }
        let result = try await fetch([:])
        XCTAssertEqual(methods, ["REPORT", "REPORT", "GET"]); XCTAssertEqual(result.meetings.count, 1)
    }

    func testFreshCoveringMonthCanServeDayWithoutAnotherQuery() {
        let start = date("2026-10-01T00:00:00Z"), end = date("2026-11-01T00:00:00Z"), now = date("2026-10-21T10:00:00Z")
        XCTAssertTrue(CalendarCachePolicy.isFresh(cachedRange: start..<end, savedAt: now.addingTimeInterval(-30),
            requestedRange: date("2026-10-21T00:00:00Z")..<date("2026-10-22T00:00:00Z"), now: now))
        XCTAssertFalse(CalendarCachePolicy.isFresh(cachedRange: start..<end, savedAt: now,
            requestedRange: start..<date("2026-11-02T00:00:00Z"), now: now))
    }

    func testExpiredOrFutureDatedCacheRequiresRevalidation() {
        let now = Date(), range = now..<now.addingTimeInterval(3600)
        XCTAssertFalse(CalendarCachePolicy.isFresh(cachedRange: range, savedAt: now.addingTimeInterval(-120), requestedRange: range, now: now))
        XCTAssertFalse(CalendarCachePolicy.isFresh(cachedRange: range, savedAt: now.addingTimeInterval(1), requestedRange: range, now: now))
    }

    func testStatusWithoutReasonPhraseAndWithWhitespaceIsAccepted() async throws {
        CacheProtocol.handler = { _ in
            let reply = self.xml([("a", "1", nil)])
                .replacingOccurrences(of: "HTTP/1.1 200 OK", with: "\nHTTP/1.1\t200\n")
                .replacingOccurrences(of: "<d:propstat>", with: "<d:status>HTTP/1.1 200</d:status><d:propstat>")
            return (207, reply)
        }
        let result = try await fetch([href("a"): resource("a", "1")])
        XCTAssertEqual(result.meetings.count, 1)
    }

    func testMultigetUsesOriginRelativePaths() async throws {
        CacheProtocol.handler = { request in
            let body = self.body(request)
            if body.contains("calendar-query") { return (207, self.xml([("a", "1", nil)])) }
            XCTAssertTrue(body.contains("<d:href>/calendars/me/events/a.ics</d:href>"))
            XCTAssertFalse(body.contains("<d:href>https://"))
            return (207, self.xml([("a", "1", self.ics("a"))]))
        }
        let result = try await fetch([:])
        XCTAssertEqual(result.meetings.count, 1)
    }

    func testPerResourceMultiget404FallsBackToSuccessfulGet() async throws {
        var methods: [String] = []
        CacheProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "GET" { return (200, self.ics("a")) }
            return self.body(request).contains("calendar-query") ?
                (207, self.xml([("a", "1", nil)])) : (207, self.xml([("a", nil, nil)], missing: true))
        }
        let result = try await fetch([:])
        XCTAssertEqual(result.meetings.count, 1)
        XCTAssertEqual(methods, ["REPORT", "REPORT", "GET"])
    }

    func testDeletionDuringDownloadIsResolvedByOneNewListing() async throws {
        var listings = 0
        CacheProtocol.handler = { request in
            if request.httpMethod == "GET" { return (404, "") }
            if self.body(request).contains("calendar-query") {
                listings += 1
                return (207, listings == 1 ? self.xml([("a", "1", nil)]) : self.xml([]))
            }
            return (207, self.xml([("a", nil, nil)], missing: true))
        }
        let result = try await fetch([:])
        XCTAssertTrue(result.meetings.isEmpty); XCTAssertEqual(listings, 2)
    }

    func testMissingETagProperty404StillDownloadsTheEvent() async throws {
        CacheProtocol.handler = { request in
            if self.body(request).contains("calendar-query") {
                return (207, self.xml([("a", "1", nil)]).replacingOccurrences(of: "HTTP/1.1 200 OK", with: "HTTP/1.1 404 Not Found"))
            }
            return (207, self.xml([("a", "1", self.ics("a"))]))
        }
        let result = try await fetch([:])
        XCTAssertEqual(result.meetings.count, 1)
    }

    func testForbiddenResourceIsNotPublishedAsEmptySuccess() async {
        var requests = 0
        CacheProtocol.handler = { request in
            requests += 1
            if self.body(request).contains("calendar-query") { return (207, self.xml([("a", "1", nil)])) }
            return (207, self.xml([("a", nil, nil)], missing: true).replacingOccurrences(of: "404 Not Found", with: "403 Forbidden"))
        }
        do { _ = try await fetch([:]); XCTFail("Expected an access error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("403")) }
        XCTAssertEqual(requests, 2)
    }

    func testCompleteQueryFallbackRecoversIncompatibleMultigetAndGet() async throws {
        var fullQueries = 0
        CacheProtocol.handler = { request in
            if request.httpMethod == "GET" { return (404, "") }
            let body = self.body(request)
            if body.contains("calendar-query") {
                if body.contains("calendar-data") {
                    fullQueries += 1
                    return (207, self.xml([("a", "1", self.ics("a"))]))
                }
                return (207, self.xml([("a", "1", nil)]))
            }
            return (207, self.xml([("a", nil, nil)], missing: true))
        }
        let result = try await fetch([:])
        XCTAssertEqual(result.meetings.count, 1); XCTAssertEqual(fullQueries, 1)
    }

    func testHistoricalMonthIncludesPastMeetings() async throws {
        let past = ics("past").replacingOccurrences(of: "20261021", with: "20260905")
        CacheProtocol.handler = { request in
            let body = self.body(request)
            if body.contains("calendar-query") {
                XCTAssertTrue(body.contains("20260901T000000Z")); XCTAssertTrue(body.contains("20261001T000000Z"))
                return (207, self.xml([("past", "1", nil)]))
            }
            return (207, self.xml([("past", "1", past)]))
        }
        let result = try await CalDAVClient(login: "me@example.org", password: "test-only", execute: CacheProtocol.execute)
            .fetchMeetings(in: calendar, start: date("2026-09-01T00:00:00Z"), end: date("2026-10-01T00:00:00Z"), fallbackZone: zone, cached: [:])
        XCTAssertEqual(result.meetings.first?.start, date("2026-09-05T09:00:00Z"))
    }

    func testUnsupportedGetAlsoFallsBackToCompleteCalendarQuery() async throws {
        CacheProtocol.handler = { request in
            if request.httpMethod == "GET" { return (405, "") }
            let body = self.body(request)
            if body.contains("calendar-multiget") { return (405, "") }
            return (207, body.contains("calendar-data") ?
                self.xml([("a", "1", self.ics("a"))]) : self.xml([("a", "1", nil)]))
        }
        let result = try await fetch([:])
        XCTAssertEqual(result.meetings.count, 1)
    }
}
