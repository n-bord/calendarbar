import Foundation

/// Serializes access to a user-authorized credential. Concurrent readers share
/// one successful load, even when the underlying call displays a system dialog.
/// Keeps each successfully loaded secret in memory until cleared or exit.
public final class SessionCredentialCache {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    public init() {}

    public func read(for account: String, load: () throws -> String?) rethrows -> String? {
        lock.lock(); defer { lock.unlock() }
        if let secret = secrets[account] { return secret }
        let secret = try load()
        if let secret { secrets[account] = secret }
        return secret
    }

    /// A failed write must not replace a previously working credential.
    public func save(_ secret: String, for account: String, write: () throws -> Void) rethrows {
        lock.lock(); defer { lock.unlock() }
        try write()
        secrets[account] = secret
    }

    public func remove(for account: String, delete: () throws -> Void) rethrows {
        lock.lock(); defer { lock.unlock() }
        try delete()
        secrets.removeValue(forKey: account)
    }

    public func clear(for account: String) {
        lock.lock(); defer { lock.unlock() }
        secrets.removeValue(forKey: account)
    }
}
