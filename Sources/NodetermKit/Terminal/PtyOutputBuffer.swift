import Foundation

/// One viewer's lossless pending VT bytes. Pulls coalesce small network frames and split large
/// frames into bounded parser work. Overflow invalidates the stream; the RPC connection must
/// reconnect and reattach from a fresh screen, rather than paint a stream with missing bytes.
actor PtyOutputBuffer {
    static let byteLimit = 4 * 1024 * 1024
    static let chunkLimit = 2048
    static let batchSize = 64 * 1024

    private var chunks: [Data]
    private var head = 0
    private var offset = 0
    private var bytes: Int
    private var ended = false
    private var waiter: CheckedContinuation<Data?, Never>?

    init(initial: [Data] = []) {
        chunks = initial
        bytes = initial.reduce(0) { $0 + $1.count }
    }

    /// A single legal wire frame may exceed the normal queue budget. Accept it only into an
    /// empty queue, then split it on pull, so an honest large frame cannot cause a reconnect loop.
    func append(_ data: Data) -> Bool {
        guard !ended else { return true } // the subscriber was cancelled
        guard !data.isEmpty else { return true }
        guard chunks.count - head < Self.chunkLimit,
              data.count <= NodetermWire.maxPayloadBytes,
              bytes == 0 || bytes + data.count <= Self.byteLimit else {
            finish()
            return false
        }
        chunks.append(data)
        bytes += data.count
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: takeBatch())
        }
        return true
    }

    func next() async -> Data? {
        await withTaskCancellationHandler {
            guard !ended, !Task.isCancelled else { return nil }
            if bytes > 0 { return takeBatch() }
            return await withCheckedContinuation { waiter = $0 }
        } onCancel: {
            Task { await self.finish() }
        }
    }

    func finish() {
        ended = true
        chunks.removeAll()
        head = 0; offset = 0; bytes = 0
        let pending = waiter
        waiter = nil
        pending?.resume(returning: nil)
    }

    private func takeBatch() -> Data {
        var result = Data(capacity: min(bytes, Self.batchSize))
        while head < chunks.count && result.count < Self.batchSize {
            let chunk = chunks[head]
            let count = min(chunk.count - offset, Self.batchSize - result.count)
            let start = chunk.index(chunk.startIndex, offsetBy: offset)
            result.append(contentsOf: chunk[start..<chunk.index(start, offsetBy: count)])
            offset += count
            bytes -= count
            if offset == chunk.count {
                chunks[head] = Data() // release consumed storage before the next compaction
                head += 1; offset = 0
            }
        }
        if head >= 64 || head == chunks.count {
            chunks.removeFirst(head)
            head = 0
        }
        return result
    }
}

/// Runs `action` once: on an explicit `fire()` (task cancellation) or when the last reference to
/// the token goes away (the subscriber's stream was dropped without cancelling a pending pull).
final class PtySubscriptionRelease: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    init(_ action: @escaping @Sendable () -> Void) { self.action = action }

    func fire() {
        lock.lock()
        let pending = action
        action = nil
        lock.unlock()
        pending?()
    }

    deinit { fire() }
}
