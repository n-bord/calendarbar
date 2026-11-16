import Foundation

/// Decodes data saved by versions with an embedded event editor. Not exposed in the UI.
public struct EventTemplate: Codable, Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let durationMinutes: Int
    public let details: String
    public let location: String
    public let link: String
    public let recurrenceRule: String?
}
