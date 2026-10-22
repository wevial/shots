import Foundation

/// A FIFO of async tasks with bounded concurrency. CLI backends are slow, so the daemon
/// keeps this at 1 or 2.
public actor AsyncQueue {
    public typealias Work = @Sendable () async -> Void

    private let concurrency: Int
    private var running = 0
    private var waiting: [Work] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var paused = false

    public init(concurrency: Int) {
        self.concurrency = max(1, concurrency)
    }

    /// Queued plus running.
    public var size: Int { waiting.count + running }

    /// Started and not finished yet.
    public var active: Int { running }

    public func push(_ work: @escaping Work) {
        waiting.append(work)
        pump()
    }

    /// Returns once nothing is queued or running. While paused, queued work counts too, so
    /// this waits for `resume()` or `dropWaiting()`.
    public func onIdle() async {
        guard size > 0 else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Stops starting queued work; running work carries on.
    public func pause() {
        paused = true
    }

    public func resume() {
        paused = false
        pump()
    }

    /// Forgets work that hasn't started and returns how much there was.
    @discardableResult
    public func dropWaiting() -> Int {
        let dropped = waiting.count
        waiting = []
        notifyIfIdle()
        return dropped
    }

    private func pump() {
        while !paused, running < concurrency, !waiting.isEmpty {
            let work = waiting.removeFirst()
            running += 1
            Task {
                await work()
                self.finished()
            }
        }
    }

    private func finished() {
        running -= 1
        pump()
        notifyIfIdle()
    }

    private func notifyIfIdle() {
        guard size == 0 else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
