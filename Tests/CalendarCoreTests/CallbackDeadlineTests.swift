import XCTest
@testable import CalendarCore

final class CallbackDeadlineTests: XCTestCase {
    func testSuccessfulCompletion() async throws {
        let value: Int = try await CallbackDeadline.wait(seconds: 1, message: "timeout") {
            $0(.success(42))
        }
        XCTAssertEqual(value, 42)
    }

    func testUnansweredSystemCallbackTimesOut() async {
        do {
            let _: Int = try await CallbackDeadline.wait(seconds: 0.02, message: "system did not respond") { _ in }
            XCTFail("Unanswered callbacks must not wait forever")
        } catch {
            XCTAssertTrue(error is CallbackDeadline.Timeout)
            XCTAssertEqual(error.localizedDescription, "system did not respond")
        }
    }

    func testLateCallbackAfterTimeoutIsIgnored() async {
        var complete: ((Result<Int, Error>) -> Void)?
        do {
            let _: Int = try await CallbackDeadline.wait(seconds: 0.02, message: "timeout") { complete = $0 }
            XCTFail("The operation must time out first")
        } catch { XCTAssertTrue(error is CallbackDeadline.Timeout) }
        // Must not resume the checked continuation a second time or crash.
        complete?(.success(99))
        complete?(.failure(CalendarError.message("late failure")))
    }

    func testDuplicateImmediateCallbackIsIgnored() async throws {
        let value: Int = try await CallbackDeadline.wait(seconds: 1, message: "timeout") { finish in
            finish(.success(1))
            finish(.success(2))
        }
        XCTAssertEqual(value, 1)
    }

    func testOriginalFailureIsPreserved() async {
        do {
            let _: Int = try await CallbackDeadline.wait(seconds: 1, message: "timeout") {
                $0(.failure(CalendarError.message("original error")))
            }
            XCTFail("The callback failure must reach the caller")
        } catch { XCTAssertEqual(error.localizedDescription, "original error") }
    }
}
