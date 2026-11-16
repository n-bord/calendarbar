import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class XMLNode {
    let name: String
    let namespace: String
    var text = ""
    var children: [XMLNode] = []
    init(_ name: String, _ namespace: String) { self.name = name; self.namespace = namespace }
    func child(_ name: String, _ namespace: String = "DAV:") -> XMLNode? {
        children.first { $0.name == name && $0.namespace == namespace }
    }
}

private final class DAVXML: NSObject, XMLParserDelegate {
    var root: XMLNode?
    var stack: [XMLNode] = []
    static func parse(_ data: Data) throws -> XMLNode {
        let delegate = DAVXML()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root, root.name == "multistatus", root.namespace == "DAV:" else {
            throw CalendarError.message("Некорректный XML-ответ CalDAV.")
        }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let node = XMLNode(name, namespaceURI ?? "")
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.text += String(decoding: CDATABlock, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
}

private struct CalDAVHTTPError: LocalizedError {
    let status: Int
    var errorDescription: String? { "Ошибка CalDAV: HTTP \(status). Кэш встреч сохранён." }
}

private struct CalDAVResourceError: LocalizedError {
    let status: Int
    var errorDescription: String? {
        switch status {
        case 401, 403: return "Сервер запретил чтение одного из событий (HTTP \(status)). Проверьте права на календарь. Кэш сохранён."
        case 404, 410: return "Не удалось прочитать одно из событий после повторной проверки (HTTP \(status)). Кэш сохранён."
        default: return "Ошибка чтения события CalDAV: HTTP \(status). Кэш сохранён."
        }
    }
}

public final class CalDAVClient {
    private let login: String
    private let password: String
    private let session: URLSession?
    private let execute: HTTPRequestExecutor
    private let namespace = "urn:ietf:params:xml:ns:caldav"
    private let root = URL(string: "https://caldav.yandex.ru/")!

    public init(login: String, password: String) {
        self.login = login; self.password = password
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let transportSession = URLSession(configuration: configuration, delegate: NoCredentialRedirect(), delegateQueue: nil)
        session = transportSession
        execute = { try await transportSession.data(for: $0) }
    }

    init(login: String, password: String, session: URLSession) {
        self.login = login; self.password = password; self.session = session
        execute = { try await session.data(for: $0) }
    }
    init(login: String, password: String, execute: @escaping HTTPRequestExecutor) {
        self.login = login; self.password = password; self.session = nil; self.execute = execute
    }
    deinit { session?.invalidateAndCancel() }

    private func trusted(_ href: String, relativeTo base: URL) throws -> URL {
        guard let url = URL(string: href, relativeTo: base)?.absoluteURL,
              url.scheme == "https", url.host?.lowercased() == "caldav.yandex.ru",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else {
            throw CalendarError.message("CalDAV вернул адрес вне доверенного сервера Яндекса.")
        }
        return url
    }

    private func request(_ url: URL, method: String, depth: String, body: String) async throws -> XMLNode {
        _ = try trusted(url.absoluteString, relativeTo: root)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("Basic " + Data((login + ":" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await execute(request)
        guard let response = response as? HTTPURLResponse else { throw CalendarError.message("Нет ответа CalDAV.") }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw CalendarError.message("Нет доступа к календарю. Проверьте полный рабочий e-mail и пароль приложения типа «Календарь», а также ограничения организации.")
        }
        guard response.statusCode == 207 else {
            throw CalDAVHTTPError(status: response.statusCode)
        }
        return try DAVXML.parse(data)
    }

    private func properties(_ root: XMLNode) -> [(XMLNode, XMLNode)] {
        root.children.filter { $0.name == "response" && $0.namespace == "DAV:" }.flatMap { response in
            response.children.filter { $0.name == "propstat" && $0.namespace == "DAV:" }.compactMap { propstat -> (XMLNode, XMLNode)? in
                guard Self.statusCode(propstat.child("status")?.text) == 200,
                      let prop = propstat.child("prop") else { return nil }
                return (response, prop)
            }
        }
    }

    public func calendars() async throws -> [CalendarInfo] {
        let principalResponse = try await request(root, method: "PROPFIND", depth: "0", body:
            "<d:propfind xmlns:d=\"DAV:\"><d:prop><d:current-user-principal/></d:prop></d:propfind>")
        guard let principalHref = properties(principalResponse).compactMap({ $0.1.child("current-user-principal")?.child("href")?.text }).first else {
            throw CalendarError.message("CalDAV не сообщил адрес пользователя.")
        }
        let principal = try trusted(principalHref, relativeTo: root)
        let homeResponse = try await request(principal, method: "PROPFIND", depth: "0", body:
            "<d:propfind xmlns:d=\"DAV:\" xmlns:c=\"\(namespace)\"><d:prop><c:calendar-home-set/></d:prop></d:propfind>")
        let homeHrefs = properties(homeResponse).flatMap { $0.1.child("calendar-home-set", namespace)?.children.filter { $0.name == "href" && $0.namespace == "DAV:" }.map(\.text) ?? [] }
        guard !homeHrefs.isEmpty else { throw CalendarError.message("CalDAV не сообщил адрес календарей.") }
        var result: [CalendarInfo] = []
        for homeHref in homeHrefs {
            let home = try trusted(homeHref, relativeTo: principal)
            let listing = try await request(home, method: "PROPFIND", depth: "1", body:
                "<d:propfind xmlns:d=\"DAV:\" xmlns:c=\"\(namespace)\"><d:prop><d:resourcetype/><d:displayname/><d:current-user-privilege-set/><c:supported-calendar-component-set/></d:prop></d:propfind>")
            for (response, prop) in properties(listing) {
                guard prop.child("resourcetype")?.child("calendar", namespace) != nil,
                      let href = response.child("href")?.text else { continue }
                let url = try trusted(href, relativeTo: home)
                if !result.contains(where: { $0.id == url.absoluteString }) {
                    let privileges = prop.child("current-user-privilege-set")
                    let allowed = privileges.map { node in
                        node.children.contains { privilege in
                            privilege.children.contains { $0.namespace == "DAV:" && ["all", "write", "bind"].contains($0.name) }
                        }
                    }
                    result.append(CalendarInfo(id: url.absoluteString, name: prop.child("displayname")?.text ?? "Календарь", canCreate: allowed,
                        canEdit: privileges.map { node in node.children.contains { p in p.children.contains { $0.namespace == "DAV:" && ["all", "write", "write-content"].contains($0.name) } } },
                        canDelete: privileges.map { node in node.children.contains { p in p.children.contains { $0.namespace == "DAV:" && ["all", "write", "unbind"].contains($0.name) } } }))
                }
            }
        }
        guard !result.isEmpty else { throw CalendarError.message("Доступные календари не найдены.") }
        return result.sorted { $0.name < $1.name }
    }

    public func meetings(in calendar: CalendarInfo, start: Date, end: Date, fallbackZone: TimeZone) async throws -> [Meeting] {
        let result = try await fetchMeetings(in: calendar, start: start, end: end, fallbackZone: fallbackZone, cached: [:])
        if let error = result.failedResources.sorted(by: { $0.key < $1.key }).first?.value {
            throw CalendarError.message(error)
        }
        return result.meetings
    }

    /// Query only URI/ETag pairs, then fetch bodies only for changed resources.
    public func fetchMeetings(in calendar: CalendarInfo, start: Date, end: Date, fallbackZone: TimeZone,
                              cached: [String: CachedCalendarResource], displayCalendar: Calendar? = nil) async throws -> CalendarFetch {
        if let account = calendar.accountLogin, account.caseInsensitiveCompare(login) != .orderedSame {
            throw CalendarError.message("Календарь относится к другому аккаунту.")
        }
        do {
            return try await fetchMeetingsOnce(in: calendar, start: start, end: end, fallbackZone: fallbackZone, cached: cached, displayCalendar: displayCalendar)
        } catch let error as CalDAVResourceError where [404, 410].contains(error.status) {
            // A resource can disappear between the listing and download. Re-list once;
            // never publish a partial result or keep retrying indefinitely.
            try Task.checkCancellation()
            do {
                return try await fetchMeetingsOnce(in: calendar, start: start, end: end, fallbackZone: fallbackZone, cached: cached, displayCalendar: displayCalendar)
            } catch let retryError as CalDAVResourceError where [404, 405, 410, 501].contains(retryError.status) {
                return try await fullMeetings(in: calendar, start: start, end: end, fallbackZone: fallbackZone, displayCalendar: displayCalendar)
            }
        } catch let error as CalDAVResourceError where [405, 501].contains(error.status) {
            return try await fullMeetings(in: calendar, start: start, end: end, fallbackZone: fallbackZone, displayCalendar: displayCalendar)
        } catch let error as CalDAVHTTPError where [400, 405, 415, 501].contains(error.status) {
            return try await fullMeetings(in: calendar, start: start, end: end, fallbackZone: fallbackZone, displayCalendar: displayCalendar)
        }
    }

    /// Compatibility fallback: accept only a complete calendar-data response.
    private func fullMeetings(in calendar: CalendarInfo, start: Date, end: Date, fallbackZone: TimeZone,
                              displayCalendar: Calendar?) async throws -> CalendarFetch {
        try Task.checkCancellation()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let url = try trusted(calendar.sourceID, relativeTo: root)
        let queryRange = queryRange(for: start..<end, fallbackZone: fallbackZone, displayCalendar: displayCalendar)
        let response = try await request(url, method: "REPORT", depth: "1", body: """
        <c:calendar-query xmlns:d="DAV:" xmlns:c="\(namespace)">
          <d:prop><d:getetag/><c:calendar-data/></d:prop>
          <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">
            <c:time-range start="\(formatter.string(from: queryRange.lowerBound))" end="\(formatter.string(from: queryRange.upperBound))"/>
          </c:comp-filter></c:comp-filter></c:filter>
        </c:calendar-query>
        """)
        let resources = try resourceProperties(response, relativeTo: url).map { item in
            guard let data = item.prop.child("calendar-data", namespace)?.text else {
                throw CalendarError.message("Сервер не вернул полные данные календаря. Кэш сохранён.")
            }
            return CachedCalendarResource(href: item.href, etag: item.prop.child("getetag")?.text, data: data)
        }
        return try parseResources(resources, in: calendar, range: start..<end, zone: fallbackZone, displayCalendar: displayCalendar)
    }

    private func fetchMeetingsOnce(in calendar: CalendarInfo, start: Date, end: Date, fallbackZone: TimeZone,
                                   cached: [String: CachedCalendarResource], displayCalendar: Calendar?) async throws -> CalendarFetch {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let url = try trusted(calendar.sourceID, relativeTo: root)
        let queryRange = queryRange(for: start..<end, fallbackZone: fallbackZone, displayCalendar: displayCalendar)
        let response = try await request(url, method: "REPORT", depth: "1", body: """
        <c:calendar-query xmlns:d="DAV:" xmlns:c="\(namespace)">
          <d:prop><d:getetag/></d:prop>
          <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">
            <c:time-range start="\(formatter.string(from: queryRange.lowerBound))" end="\(formatter.string(from: queryRange.upperBound))"/>
          </c:comp-filter></c:comp-filter></c:filter>
        </c:calendar-query>
        """)
        let references = try resourceProperties(response, relativeTo: url).map { (href: $0.href, etag: $0.prop.child("getetag")?.text) }
        var resources: [String: CachedCalendarResource] = [:]
        var changed: [(href: String, etag: String?)] = []
        for item in references {
            if let tag = item.etag, !tag.isEmpty, var prior = cached[item.href], prior.etag == tag {
                prior.lastUsed = Date(); resources[item.href] = prior
            } else { changed.append(item) }
        }
        for offset in stride(from: 0, to: changed.count, by: 40) {
            try Task.checkCancellation()
            let batch = Array(changed[offset..<min(offset + 40, changed.count)])
            do {
                // Use origin-relative, percent-encoded resource paths, as in RFC 4791.
                // Some servers return per-resource 404 for absolute URIs in multiget.
                let hrefs = try batch.map { item -> String in
                    let target = try trusted(item.href, relativeTo: url)
                    guard let parts = URLComponents(url: target, resolvingAgainstBaseURL: false) else {
                        throw CalendarError.message("Не удалось прочитать адрес события CalDAV.")
                    }
                    let path = parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
                    return "<d:href>" + Self.xml(path) + "</d:href>"
                }.joined()
                let fetched = try await request(url, method: "REPORT", depth: "1", body: """
                <c:calendar-multiget xmlns:d="DAV:" xmlns:c="\(namespace)">
                  <d:prop><d:getetag/><c:calendar-data/></d:prop>\(hrefs)
                </c:calendar-multiget>
                """)
                let expected = Set(batch.map(\.href))
                var received = Set<String>()
                for item in try resourceProperties(fetched, relativeTo: url) {
                    guard expected.contains(item.href) else {
                        throw CalendarError.message("Сервер вернул незапрошенное событие. Сохранённые встречи не изменены.")
                    }
                    guard let text = item.prop.child("calendar-data", namespace)?.text else { continue }
                    let tag = item.prop.child("getetag")?.text ?? batch.first(where: { $0.href == item.href })?.etag
                    resources[item.href] = CachedCalendarResource(href: item.href, etag: tag, data: text)
                    received.insert(item.href)
                }
                for item in batch where !received.contains(item.href) {
                    resources[item.href] = try await getResource(item.href, etag: item.etag)
                }
            } catch let error as CalDAVHTTPError where [400, 405, 415, 501].contains(error.status) {
                // Older servers can support GET while not supporting calendar-multiget.
                for item in batch { resources[item.href] = try await getResource(item.href, etag: item.etag) }
            } catch let error as CalDAVResourceError where [404, 405, 410, 501].contains(error.status) {
                // Distinguish a multiget compatibility issue from an actually missing resource.
                for item in batch { resources[item.href] = try await getResource(item.href, etag: item.etag) }
            }
        }
        let ordered = try references.map { reference in
            guard let resource = resources[reference.href] else { throw CalendarError.message("Не удалось загрузить одно из событий.") }
            return resource
        }
        return try parseResources(ordered, in: calendar, range: start..<end, zone: fallbackZone, displayCalendar: displayCalendar)
    }

    private func queryRange(for range: Range<Date>, fallbackZone: TimeZone, displayCalendar: Calendar?) -> Range<Date> {
        guard let displayCalendar, displayCalendar.timeZone.identifier != fallbackZone.identifier else { return range }
        // CalDAV selects date-only events in the server's time zone. Expand only the request.
        return range.lowerBound.addingTimeInterval(-2 * 86_400)..<range.upperBound.addingTimeInterval(2 * 86_400)
    }

    private func parseResources(_ resources: [CachedCalendarResource], in calendar: CalendarInfo,
                                range: Range<Date>, zone: TimeZone, displayCalendar: Calendar?) throws -> CalendarFetch {
        var meetings: [Meeting] = [], accepted: [CachedCalendarResource] = []
        var failures: [String: String] = [:]
        for resource in resources {
            try Task.checkCancellation()
            do {
                meetings += try ICalendar.parse(resource.data, calendar: calendar, fallbackZone: zone, range: range,
                    resourceURL: URL(string: resource.href), etag: resource.etag, displayCalendar: displayCalendar)
                accepted.append(resource)
            } catch {
                failures[resource.href] = error.localizedDescription
            }
        }
        return CalendarFetch(meetings: meetings, resources: accepted, failedResources: failures)
    }

    private func resourceProperties(_ root: XMLNode, relativeTo base: URL) throws -> [(href: String, prop: XMLNode)] {
        var result: [(href: String, prop: XMLNode)] = []
        for item in root.children where item.name == "response" && item.namespace == "DAV:" {
            if let status = item.child("status")?.text {
                guard let code = Self.statusCode(status) else { throw CalendarError.message("Некорректный статус ответа CalDAV. Кэш сохранён.") }
                if code != 200 { throw CalDAVResourceError(status: code) }
            }
            guard let href = item.child("href")?.text else { throw CalendarError.message("В ответе CalDAV нет адреса события.") }
            let propstats = item.children.filter { $0.name == "propstat" && $0.namespace == "DAV:" }
            let good = propstats.filter { Self.statusCode($0.child("status")?.text) == 200 }
            // A missing optional getetag property is not a missing calendar resource.
            let onlyMissingETag = !propstats.isEmpty && propstats.allSatisfy {
                Self.statusCode($0.child("status")?.text) == 404 &&
                    $0.child("prop")?.children.isEmpty == false &&
                    $0.child("prop")?.children.allSatisfy { $0.name == "getetag" && $0.namespace == "DAV:" } == true
            }
            if good.isEmpty && !onlyMissingETag {
                let code = propstats.compactMap { Self.statusCode($0.child("status")?.text) }.first ?? 500
                throw CalDAVResourceError(status: code)
            }
            let combined = XMLNode("prop", "DAV:")
            combined.children = good.compactMap { $0.child("prop") }.flatMap(\.children)
            result.append((try trusted(href, relativeTo: base).absoluteString, combined))
        }
        return result
    }

    private func getResource(_ href: String, etag: String?, timeout: TimeInterval? = nil) async throws -> CachedCalendarResource {
        let url = try trusted(href, relativeTo: root)
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("Basic " + Data((login + ":" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await execute(request)
        guard let http = response as? HTTPURLResponse else {
            throw CalendarError.message("Нет ответа CalDAV при чтении события. Кэш сохранён.")
        }
        guard http.statusCode == 200 else { throw CalDAVResourceError(status: http.statusCode) }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw CalendarError.message("Не удалось получить событие. Сохранённые встречи не изменены.")
        }
        return CachedCalendarResource(href: href, etag: http.value(forHTTPHeaderField: "ETag") ?? etag, data: text)
    }

    private static func statusCode(_ text: String?) -> Int? {
        guard let text else { return nil }
        let fields = text.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2, fields[0].hasPrefix("HTTP/"),
              fields[1].count == 3, let code = Int(fields[1]), (100...599).contains(code) else { return nil }
        return code
    }

    private static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
