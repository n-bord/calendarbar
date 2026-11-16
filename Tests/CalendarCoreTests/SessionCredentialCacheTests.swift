import XCTest
import Foundation
@testable import CalendarCore

private enum CredentialTestError: Error { case denied }

private final class CredentialResults {
    private let lock = NSLock()
    private var loads = 0
    private var values: [String] = []
    func recordLoad() { lock.lock(); loads += 1; lock.unlock() }
    func record(_ value: String?) { lock.lock(); values.append(value ?? "missing"); lock.unlock() }
    var snapshot: (loads: Int, values: [String]) {
        lock.lock(); defer { lock.unlock() }; return (loads, values)
    }
}

final class SessionCredentialCacheTests: XCTestCase {
    func testConcurrentReadersShareOneKeychainLoad() {
        let cache = SessionCredentialCache(), results = CredentialResults()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let secret = cache.read(for: "work@example.org") {
                results.recordLoad()
                Thread.sleep(forTimeInterval: 0.01)
                return "app-password"
            }
            results.record(secret)
        }
        let result = results.snapshot
        XCTAssertEqual(result.loads, 1)
        XCTAssertEqual(result.values, Array(repeating: "app-password", count: 16))
    }

    func testSavingUpdatedPasswordReplacesTheCachedValue() {
        let cache = SessionCredentialCache()
        _ = cache.read(for: "work") { "old" }
        var written = false
        cache.save("new", for: "work") { written = true }
        XCTAssertTrue(written)
        XCTAssertEqual(cache.read(for: "work") { XCTFail("Must use the updated session secret"); return nil }, "new")
    }

    func testDeletionForcesTheNextReadToReload() {
        let cache = SessionCredentialCache()
        _ = cache.read(for: "work") { "old" }
        var deleted = false
        cache.remove(for: "work") { deleted = true }
        XCTAssertTrue(deleted)
        XCTAssertEqual(cache.read(for: "work") { "reloaded" }, "reloaded")
    }

    func testAnotherAccountCannotReceiveTheCachedSecret() {
        let cache = SessionCredentialCache()
        XCTAssertEqual(cache.read(for: "first") { "first-secret" }, "first-secret")
        XCTAssertEqual(cache.read(for: "second") { "second-secret" }, "second-secret")
        XCTAssertEqual(cache.read(for: "first") { XCTFail("Each active account has its own cached value"); return nil }, "first-secret")
        cache.clear(for: "first")
        XCTAssertEqual(cache.read(for: "first") { "first-reloaded" }, "first-reloaded")
        XCTAssertEqual(cache.read(for: "second") { XCTFail("Clearing one account must preserve the other"); return nil }, "second-secret")
    }

    func testFailedReadCanBeRetriedExplicitly() {
        let cache = SessionCredentialCache()
        XCTAssertThrowsError(try cache.read(for: "work") { throw CredentialTestError.denied })
        XCTAssertEqual(cache.read(for: "work") { "authorized" }, "authorized")
    }

    func testFailedWritePreservesTheWorkingSecret() {
        let cache = SessionCredentialCache()
        _ = cache.read(for: "work") { "working" }
        XCTAssertThrowsError(try cache.save("replacement", for: "work") { throw CredentialTestError.denied })
        XCTAssertEqual(cache.read(for: "work") { XCTFail("The old session must remain available"); return nil }, "working")
    }

    func testFailedDeletePreservesTheWorkingSecret() {
        let cache = SessionCredentialCache()
        _ = cache.read(for: "work") { "working" }
        XCTAssertThrowsError(try cache.remove(for: "work") { throw CredentialTestError.denied })
        XCTAssertEqual(cache.read(for: "work") { XCTFail("Deletion did not succeed"); return nil }, "working")
    }
}
