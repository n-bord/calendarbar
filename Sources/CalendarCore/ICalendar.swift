import Foundation

public enum ICalendar {
    private struct Property {
        let name: String
        let parameters: [String: String]
        let value: String
    }

    private struct Component {
        let properties: [Property]
        func first(_ name: String) -> Property? { properties.first { $0.name == name } }
    }
    private struct Length {
        let days: Int
        let seconds: TimeInterval
        func end(after start: Date, zone: TimeZone) throws -> Date {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            guard let date = calendar.date(byAdding: .day, value: days, to: start) else {
                throw CalendarError.message("Не удалось вычислить окончание встречи.")
            }
            return date.addingTimeInterval(seconds)
        }
    }

    public static func parse(_ text: String, calendar: CalendarInfo, fallbackZone: TimeZone,
                             range: Range<Date>? = nil, resourceURL: URL? = nil, etag: String? = nil,
                             displayCalendar: Calendar? = nil) throws -> [Meeting] {
        let physical = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var lines: [String] = []
        for line in physical {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += String(line.dropFirst())
            } else { lines.append(line) }
        }
        var blocks: [[Property]] = []
        var block: [Property]?
        var nested = 0
        for line in lines {
            let upper = line.uppercased()
            if upper == "BEGIN:VEVENT" { block = []; nested = 0; continue }
            if upper == "END:VEVENT", let finished = block { blocks.append(finished); block = nil; continue }
            guard block != nil else { continue }
            if upper.hasPrefix("BEGIN:") { nested += 1; continue }
            if upper.hasPrefix("END:") { nested = max(0, nested - 1); continue }
            if nested == 0, let property = property(line) { block?.append(property) }
        }
        if block != nil || !text.uppercased().contains("BEGIN:VCALENDAR") {
            throw CalendarError.message("Сервер вернул повреждённые данные календаря.")
        }
        var groups: [String: [Component]] = [:]
        for properties in blocks {
            let component = Component(properties: properties)
            guard let uid = component.first("UID")?.value, !uid.isEmpty else {
                throw CalendarError.message("Не удалось прочитать UID встречи.")
            }
            groups[uid, default: []].append(component)
        }
        var result: [Meeting] = []
        for (uid, components) in groups {
            do {
                result += try expand(components, uid: uid, calendar: calendar, fallbackZone: fallbackZone,
                    range: range, displayCalendar: displayCalendar)
            } catch {
                let title = decode(components.first?.first("SUMMARY")?.value ?? "Без названия")
                throw CalendarError.message("Встреча «\(title)»: \(error.localizedDescription)")
            }
        }
        return result.map { meeting in
            meeting.withResource(url: resourceURL, etag: etag).scoped(to: calendar.accountLogin ?? "")
        }.sorted { $0.start < $1.start }
    }

    private static func expand(_ components: [Component], uid: String, calendar: CalendarInfo,
                               fallbackZone: TimeZone, range: Range<Date>?, displayCalendar: Calendar?) throws -> [Meeting] {
        let masters = components.filter { $0.first("RECURRENCE-ID") == nil }
        guard masters.count <= 1 else { throw CalendarError.message("Несколько основных записей одной серии.") }
        guard let master = masters.first else {
            return try components.compactMap { component in
                guard let rid = component.first("RECURRENCE-ID"), let original = date(rid, fallbackZone: fallbackZone) else {
                    throw CalendarError.message("Не удалось прочитать RECURRENCE-ID.")
                }
                let startProperty = component.first("DTSTART") ?? rid
                let zone = try timeZone(startProperty, fallback: fallbackZone)
                guard let start = date(startProperty, fallbackZone: zone) else { throw CalendarError.message("Не удалось прочитать дату повтора.") }
                let length = try length(of: component, start: start, zone: zone)
                let meeting = try meeting(component, inherited: nil, uid: uid, calendar: calendar,
                    start: start, original: original, zone: zone, length: length)
                return intersects(meeting, range, displayCalendar: displayCalendar, fallbackZone: zone) ? meeting : nil
            }
        }
        guard let startProperty = master.first("DTSTART"), let start = date(startProperty, fallbackZone: fallbackZone) else {
            throw CalendarError.message("Не удалось прочитать начало встречи.")
        }
        let zone = try timeZone(startProperty, fallback: fallbackZone)
        let masterLength = try length(of: master, start: start, zone: zone)
        let hasRecurrence = components.count > 1 || master.properties.contains {
            ["RRULE", "RDATE", "EXDATE", "EXRULE"].contains($0.name)
        }
        if !hasRecurrence {
            let item = try meeting(master, inherited: nil, uid: uid, calendar: calendar,
                start: start, original: nil, zone: zone, length: masterLength)
            return intersects(item, range, displayCalendar: displayCalendar, fallbackZone: zone) ? [item] : []
        }
        guard let range else { throw CalendarError.message("Для повторяющейся встречи нужен диапазон загрузки.") }
        guard master.first("EXRULE") == nil else { throw CalendarError.message("Устаревшее исключение EXRULE пока не поддерживается.") }
        let rules = master.properties.filter { $0.name == "RRULE" }
        guard rules.count <= 1 else { throw CalendarError.message("Несколько RRULE в одной серии пока не поддерживаются.") }
        var overrides: [Date: Component] = [:]
        var future: [Date] = []
        var padding: TimeInterval = 0
        for component in components where component.first("RECURRENCE-ID") != nil {
            let rid = component.first("RECURRENCE-ID")!
            guard let original = date(rid, fallbackZone: zone) else { throw CalendarError.message("Некорректная дата исключения серии.") }
            if let rangeParameter = rid.parameters["RANGE"] {
                guard rangeParameter.uppercased() == "THISANDFUTURE" else {
                    throw CalendarError.message("Неизвестный вариант переноса RANGE.")
                }
                future.append(original)
            }
            if let property = component.first("DTSTART"), let moved = date(property, fallbackZone: zone) {
                padding = max(padding, abs(moved.timeIntervalSince(original)))
            }
            if let old = overrides[original] {
                let oldSequence = Int(old.first("SEQUENCE")?.value ?? "0") ?? 0
                let newSequence = Int(component.first("SEQUENCE")?.value ?? "0") ?? 0
                if newSequence < oldSequence { continue }
            }
            overrides[original] = component
        }
        future.sort()
        let duration = try masterLength.end(after: start, zone: zone).timeIntervalSince(start)
        // Time zones can differ by more than a day. Leave room for a civil date
        // whose stored midnight falls outside the displayed range.
        let datePadding: TimeInterval = startProperty.value.count == 8 && displayCalendar != nil ? 172800 : 86400
        let searchStart = range.lowerBound.addingTimeInterval(-max(0, duration) - padding - datePadding)
        let searchEnd = range.upperBound.addingTimeInterval(padding + datePadding)
        let searchRange = searchStart..<searchEnd
        var dates: Set<Date> = [start]
        for rule in rules {
            dates.formUnion(try Recurrence.dates(rule: rule.value, start: start, zone: zone, range: searchRange))
        }
        for property in master.properties where property.name == "RDATE" {
            dates.formUnion(try dateList(property, fallbackZone: zone))
        }
        var excluded = Set<Date>()
        for property in master.properties where property.name == "EXDATE" {
            excluded.formUnion(try dateList(property, fallbackZone: zone))
        }
        dates.formUnion(overrides.keys)
        var result: [Meeting] = []
        var gregorian = Calendar(identifier: .gregorian); gregorian.timeZone = zone
        for original in dates.sorted() {
            let exact = overrides[original]
            if excluded.contains(original), exact == nil { continue }
            let futureID = future.last { $0 <= original }
            let component = exact ?? futureID.flatMap { overrides[$0] } ?? master
            let occurrenceStart: Date
            if let exact {
                occurrenceStart = try componentStart(exact, fallback: original, zone: zone)
            } else if let futureID, let override = overrides[futureID] {
                let moved = try componentStart(override, fallback: futureID, zone: zone)
                let delta = gregorian.dateComponents([.day, .hour, .minute, .second], from: futureID, to: moved)
                guard let shifted = gregorian.date(byAdding: delta, to: original) else {
                    throw CalendarError.message("Не удалось перенести следующие повторы.")
                }
                occurrenceStart = shifted
            } else { occurrenceStart = original }
            let reference = try componentStart(component, fallback: original, zone: zone)
            let effectiveLength: Length
            if component.first("DTEND") != nil || component.first("DURATION") != nil {
                effectiveLength = try length(of: component, start: reference, zone: zone)
            } else { effectiveLength = masterLength }
            let item = try meeting(component, inherited: master, uid: uid, calendar: calendar,
                start: occurrenceStart, original: original, zone: zone, length: effectiveLength)
            if intersects(item, range, displayCalendar: displayCalendar, fallbackZone: zone) { result.append(item) }
        }
        return result
    }

    private static func componentStart(_ component: Component, fallback: Date, zone: TimeZone) throws -> Date {
        guard let property = component.first("DTSTART") else { return fallback }
        guard let start = date(property, fallbackZone: zone) else { throw CalendarError.message("Не удалось прочитать перенесённое начало встречи.") }
        return start
    }

    private static func meeting(_ component: Component, inherited: Component?, uid: String, calendar: CalendarInfo,
                                start: Date, original: Date?, zone: TimeZone, length: Length) throws -> Meeting {
        func first(_ name: String) -> Property? { component.first(name) ?? inherited?.first(name) }
        let startProperty = first("DTSTART") ?? first("RECURRENCE-ID")
        let allDay = startProperty?.parameters["VALUE"] == "DATE" || startProperty?.value.count == 8
        let people: [Property]
        if component.properties.contains(where: { $0.name == "ATTENDEE" }) {
            people = component.properties
        } else { people = inherited?.properties ?? component.properties }
        let attendees = people.filter { $0.name == "ATTENDEE" }.map {
            Attendee(email: email($0.value), name: decode($0.parameters["CN"] ?? ""),
                optional: $0.parameters["ROLE"]?.uppercased() == "OPT-PARTICIPANT",
                response: ($0.parameters["PARTSTAT"] ?? "NEEDS-ACTION").uppercased())
        }
        let details = decode(first("DESCRIPTION")?.value ?? "")
        let location = decode(first("LOCATION")?.value ?? "")
        let conferenceProperties = component.properties.filter { $0.name == "CONFERENCE" }
        let explicitConferences = conferenceProperties.isEmpty ?
            (inherited?.properties.filter { $0.name == "CONFERENCE" } ?? []) : conferenceProperties
        let explicitURLs = (explicitConferences.map(\.value) + [first("URL")?.value ?? ""]).flatMap { urls(in: $0) }
        let link = MeetingLinks.conferenceURL(explicitURLs: explicitURLs, texts: [location, details])
        let series = calendar.sourceID + "|" + uid
        let end = try length.end(after: start, zone: zone)
        return Meeting(id: series + "|" + (original.map { String($0.timeIntervalSince1970) } ?? "master"),
            seriesID: series, calendarID: calendar.sourceID, calendarName: calendar.name,
            title: decode(first("SUMMARY")?.value ?? "Без названия"), start: start,
            end: end, allDay: allDay, details: details,
            location: location, link: link, attendees: attendees,
            organizer: email(first("ORGANIZER")?.value ?? ""),
            cancelled: first("STATUS")?.value.uppercased() == "CANCELLED", uid: uid,
            recurrenceRule: first("RRULE")?.value, originalStart: original,
            sourceURL: urls(in: first("URL")?.value ?? "").first(where: YandexCalendarLinks.isEventURL),
            isFree: first("TRANSP")?.value.uppercased() == "TRANSPARENT",
            allDayDates: allDay ? AllDayDates(start: start, end: end, timeZone: zone) : nil)
    }

    private static func intersects(_ meeting: Meeting, _ range: Range<Date>?,
                                   displayCalendar: Calendar?, fallbackZone: TimeZone) -> Bool {
        guard let range else { return true }
        let event = displayCalendar.map { meeting.displayed(in: $0, fallbackZone: fallbackZone) } ?? meeting
        return event.start < range.upperBound && (event.end > range.lowerBound || range.contains(event.start))
    }

    private static func timeZone(_ property: Property, fallback: TimeZone) throws -> TimeZone {
        if property.value.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0)! }
        guard let tzid = property.parameters["TZID"] else { return fallback }
        guard let zone = TimeZone(identifier: tzid) else { throw CalendarError.message("Неизвестный часовой пояс \(tzid).") }
        return zone
    }

    private static func dateList(_ property: Property, fallbackZone: TimeZone) throws -> [Date] {
        try property.value.split(separator: ",", omittingEmptySubsequences: false).map { value in
            guard !value.contains("/") else { throw CalendarError.message("RDATE с периодом пока не поддерживается.") }
            guard let parsed = date(Property(name: property.name, parameters: property.parameters, value: String(value)), fallbackZone: fallbackZone) else {
                throw CalendarError.message("Не удалось прочитать дату \(property.name).")
            }
            return parsed
        }
    }

    private static func length(of component: Component, start: Date, zone: TimeZone) throws -> Length {
        let startProperty = component.first("DTSTART") ?? component.first("RECURRENCE-ID")
        let allDay = startProperty?.parameters["VALUE"] == "DATE" || startProperty?.value.count == 8
        if let endProperty = component.first("DTEND") {
            guard let end = date(endProperty, fallbackZone: zone), end >= start else {
                throw CalendarError.message("Некорректное время окончания встречи.")
            }
            if allDay {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                return Length(days: calendar.dateComponents([.day], from: start, to: end).day ?? 1, seconds: 0)
            }
            return Length(days: 0, seconds: end.timeIntervalSince(start))
        }
        if let raw = component.first("DURATION")?.value {
            guard let seconds = durationSeconds(raw) else { throw CalendarError.message("Неизвестный формат длительности встречи.") }
            // Preserve nominal day/week durations across daylight-saving transitions.
            let nominal = raw.split(separator: "T").first.map(String.init) ?? ""
            let regex = try NSRegularExpression(pattern: "(\\d+)([WD])")
            var days = 0
            for match in regex.matches(in: nominal, range: NSRange(nominal.startIndex..., in: nominal)) {
                if let amountRange = Range(match.range(at: 1), in: nominal), let unitRange = Range(match.range(at: 2), in: nominal) {
                    days += (Int(nominal[amountRange]) ?? 0) * (nominal[unitRange] == "W" ? 7 : 1)
                }
            }
            return Length(days: days, seconds: seconds - Double(days * 86400))
        }
        return Length(days: allDay ? 1 : 0, seconds: 0)
    }

    private static func split(_ string: String, on separator: Character) -> [String] {
        var quoted = false
        var pieces = [String](); var part = ""
        for char in string {
            if char == "\"" { quoted.toggle() }
            if char == separator && !quoted { pieces.append(part); part = "" }
            else { part.append(char) }
        }
        pieces.append(part)
        return pieces
    }

    private static func property(_ line: String) -> Property? {
        var quoted = false
        var separator: String.Index?
        for index in line.indices {
            if line[index] == "\"" { quoted.toggle() }
            if line[index] == ":" && !quoted { separator = index; break }
        }
        guard let separator else { return nil }
        let tokens = split(String(line[..<separator]), on: ";")
        guard let name = tokens.first else { return nil }
        var parameters: [String: String] = [:]
        for token in tokens.dropFirst() {
            guard let equal = token.firstIndex(of: "=") else { continue }
            var value = String(token[token.index(after: equal)...])
            if value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            parameters[String(token[..<equal]).uppercased()] = value
        }
        return Property(name: name.uppercased(), parameters: parameters, value: String(line[line.index(after: separator)...]))
    }

    private static func date(_ property: Property, fallbackZone: TimeZone) -> Date? {
        let value = property.value
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        if value.hasSuffix("Z") { formatter.timeZone = TimeZone(secondsFromGMT: 0) }
        else if let tzid = property.parameters["TZID"] {
            guard let zone = TimeZone(identifier: tzid) else { return nil }
            formatter.timeZone = zone
        } else { formatter.timeZone = fallbackZone }
        formatter.dateFormat = value.count == 8 ? "yyyyMMdd" : (value.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss")
        return formatter.date(from: value)
    }

    public static func decode(_ text: String) -> String {
        var result = ""; var escaped = false
        for character in text {
            if escaped {
                result.append(character == "n" || character == "N" ? "\n" : character)
                escaped = false
            } else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        if escaped { result.append("\\") }
        return result
    }

    private static func email(_ value: String) -> String {
        value.lowercased().hasPrefix("mailto:") ? String(value.dropFirst(7)) : value
    }

    private static func urls(in text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s<>\\\"]+") else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return URL(string: String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;]")))
        }
    }

    private static func durationSeconds(_ value: String) -> TimeInterval? {
        guard let regex = try? NSRegularExpression(pattern: "^P(?:(\\d+)W)?(?:(\\d+)D)?(?:T(?:(\\d+)H)?(?:(\\d+)M)?(?:(\\d+)S)?)?$"),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              value != "P", value != "PT" else { return nil }
        let multipliers: [Double] = [604800, 86400, 3600, 60, 1]
        return (1...5).reduce(0) { total, i in
            guard let range = Range(match.range(at: i), in: value), let number = Double(value[range]) else { return total }
            return total + number * multipliers[i - 1]
        }
    }
}
