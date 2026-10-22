import Foundation

/// `body`'s result, or nil once `timeout` passes, whichever comes first.
///
/// Unlike racing two tasks in a task group, this returns on time even when `body` ignores
/// cancellation (a blocking AX call, a daemon draining its queue): `body` is cancelled and
/// left to finish on its own.
public func withDeadline<T: Sendable>(_ timeout: Duration, _ body: @escaping @Sendable () async -> T) async -> T? {
    let once = ResumeOnce<T?>()
    return await withCheckedContinuation { continuation in
        once.set(continuation)
        let work = Task { once.resume(await body()) }
        Task {
            try? await Task.sleep(for: timeout)
            work.cancel()
            once.resume(nil)
        }
    }
}

/// A continuation that only the first caller resumes.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func set(_ continuation: CheckedContinuation<T, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ value: T) {
        let pending = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
