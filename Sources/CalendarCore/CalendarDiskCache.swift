import Foundation

public enum CalendarDiskCache: String, CaseIterable {
    case snapshot = "meetings.json"
    case pages = "calendar-pages.json"
    case resources = "caldav-resources.json"

    public func url(in directory: URL) -> URL {
        directory.appendingPathComponent(rawValue)
    }

    public static func size(in directory: URL, fileManager: FileManager = .default) -> Int64 {
        allCases.reduce(0) { total, file in
            let attributes = try? fileManager.attributesOfItem(atPath: file.url(in: directory).path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    public func remove(from directory: URL, fileManager: FileManager = .default) throws {
        do {
            try fileManager.removeItem(at: url(in: directory))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // A missing cache file is already clear.
        }
    }
}
