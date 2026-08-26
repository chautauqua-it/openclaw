import Foundation

public enum ThrowingContinuationSupport {
    public static func resumeVoid(_ continuation: CheckedContinuation<Void, Error>, error: Error?) {
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: ())
        }
    }
}

/// Guards a `CheckedContinuation` so it is resumed at most once even if the
/// underlying callback fires more than once. `URLSessionWebSocketTask.sendPing`'s
/// pongReceiveHandler can be invoked twice when the socket tears down while a ping
/// is in flight; without this guard the second resume traps (EXC_BREAKPOINT).
public final class OnceResumer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<T, Error>

    public init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    private func claim() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.resumed { return false }
        self.resumed = true
        return true
    }

    public func resume(returning value: sending T) {
        if self.claim() { self.continuation.resume(returning: value) }
    }

    public func resume(throwing error: sending Error) {
        if self.claim() { self.continuation.resume(throwing: error) }
    }
}
