import Foundation
import XCTest
@testable import CalendarCore

final class CalendarDiskCacheTests: XCTestCase {
    func testSizeAndRemovalOnlyIncludeCalendarCacheForSelectedAccount() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let work = root.appendingPathComponent("work")
        let personal = root.appendingPathComponent("personal")
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: personal, withIntermediateDirectories: true)

        for (index, cache) in CalendarDiskCache.allCases.enumerated() {
            try Data(repeating: 65, count: 1_000 * (index + 1)).write(to: cache.url(in: work))
            try Data(repeating: 66, count: 12).write(to: cache.url(in: personal))
        }
        let calendarList = work.appendingPathComponent("calendars.json")
        let notes = root.appendingPathComponent("personal-work.json")
        try Data("list".utf8).write(to: calendarList)
        try Data("preferences".utf8).write(to: notes)

        XCTAssertEqual(CalendarDiskCache.size(in: work), 6_000)
        XCTAssertEqual(CalendarDiskCache.size(in: personal), 36)
        for cache in CalendarDiskCache.allCases {
            try cache.remove(from: work)
            try cache.remove(from: work)
        }
        XCTAssertEqual(CalendarDiskCache.size(in: work), 0)
        XCTAssertEqual(CalendarDiskCache.size(in: personal), 36)
        XCTAssertEqual(try Data(contentsOf: calendarList), Data("list".utf8))
        XCTAssertEqual(try Data(contentsOf: notes), Data("preferences".utf8))
    }
}
