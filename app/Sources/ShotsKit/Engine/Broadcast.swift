import Foundation
import Synchronization

/// Hands every value to each reader's `AsyncStream`. `yield` can be called from any thread and
/// delivers in call order, which a hop through `Task { @MainActor in … }` wouldn't promise.
final class Broadcast<Value: Sendable>: Sendable {
    private let readers = Mutex<[UUID: AsyncStream<Value>.Continuation]>([:])

    /// A new reader that gets every value from now on. It ends when the reading task is cancelled.
    func stream() -> AsyncStream<Value> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self)
        continuation.onTermination = { [weak self] _ in
            _ = self?.readers.withLock { $0.removeValue(forKey: id) }
        }
        readers.withLock { $0[id] = continuation }
        return stream
    }

    func yield(_ value: Value) {
        for reader in readers.withLock({ Array($0.values) }) { reader.yield(value) }
    }
}
