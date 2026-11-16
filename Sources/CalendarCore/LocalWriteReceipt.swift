import Foundation

/// One successful synchronization acknowledges the server's normalization of a local write.
/// A real time, title, link, location or description change is still reported.
public struct LocalWriteReceipt: Codable, Equatable {
    public let seriesID: String
    public let savedAt: Date
    public init(seriesID: String, savedAt: Date = Date()) { self.seriesID = seriesID; self.savedAt = savedAt }
    public func canAcknowledge(previous: Meeting, current: Meeting, account: String, now: Date) -> Bool {
        guard previous.seriesID == seriesID, current.seriesID == seriesID,
              now >= savedAt, now.timeIntervalSince(savedAt) < 600,
              previous.start == current.start, previous.end == current.end,
              previous.allDay == current.allDay, previous.cancelled == current.cancelled else { return false }
        func text(_ value: String) -> String {
            value.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func join(_ meeting: Meeting) -> String {
            guard let url = meeting.joinURL else { return "" }
            return MeetingLinks.telemostDesktopURL(for: url)?.absoluteString ?? url.absoluteString
        }
        guard text(previous.title) == text(current.title), text(previous.details) == text(current.details),
              text(previous.location) == text(current.location), join(previous) == join(current),
              previous.recurrenceRule == current.recurrenceRule else { return false }
        let login = account.lowercased()
        let before = previous.organizer.lowercased(), after = current.organizer.lowercased()
        guard before == after || (before.isEmpty && after == login) else { return false }
        func others(_ meeting: Meeting) -> [Attendee] {
            meeting.attendees.filter { $0.email.lowercased() != login }.sorted { $0.email.lowercased() < $1.email.lowercased() }
        }
        return others(previous) == others(current)
    }
}
