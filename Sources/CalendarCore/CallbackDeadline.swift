import Foundation

/// Bounds callback APIs whose system service can leave a completion unanswered.
/// A late or duplicate callback is ignored; the continuation is resumed exactly once.
public enum CallbackDeadline {
    public struct Timeout: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func wait<Value>(seconds: TimeInterval, message: String,
        start: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let gate = CompletionGate(continuation)
            let timeout = DispatchWorkItem { gate.finish(.failure(Timeout(message: message))) }
            gate.arm(timeout)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0.001, seconds), execute: timeout)
            start { result in gate.finish(result) }
        }
    }
}

private final class CompletionGate<Value> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var watchdog: DispatchWorkItem?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func arm(_ item: DispatchWorkItem) {
        lock.lock(); defer { lock.unlock() }
        watchdog = item
    }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let item = watchdog
        watchdog = nil
        lock.unlock()
        item?.cancel()
        pending?.resume(with: result)
    }
}
