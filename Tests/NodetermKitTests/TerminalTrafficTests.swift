import Foundation
import Testing
@testable import NodetermKit

@Test func outputCoalescesWithoutChangingVTOrUTF8Bytes() async {
    let parts = [Data([0x1b]), Data("[31m".utf8), Data([0xf0, 0x9f]),
                 Data([0x98, 0x80]), Data("\u{1b}[0m".utf8)]
    let buffer = PtyOutputBuffer(initial: parts)
    let result = await buffer.next()
    #expect(result == parts.reduce(into: Data()) { $0.append($1) })
    await buffer.finish()
    #expect(await buffer.next() == nil)
}

@Test func largeLegalOutputIsSplitIntoBoundedParserBatches() async {
    let input = Data(repeating: 0x61, count: PtyOutputBuffer.byteLimit + 7)
    let buffer = PtyOutputBuffer()
    #expect(await buffer.append(input))
    var output = Data()
    while output.count < input.count {
        let batch = await buffer.next()
        #expect(batch != nil)
        guard let batch else { return }
        #expect(batch.count <= PtyOutputBuffer.batchSize)
        output.append(batch)
    }
    #expect(output == input)
    await buffer.finish()
}

@Test func outputByteOverflowEndsTheStreamInsteadOfDroppingAnEscapePrefix() async {
    let buffer = PtyOutputBuffer()
    #expect(await buffer.append(Data(repeating: 0x1b, count: PtyOutputBuffer.byteLimit)))
    #expect(!(await buffer.append(Data("[31m".utf8))))
    #expect(await buffer.next() == nil)
}

@Test func cancellingAWaitingOutputConsumerReleasesIt() async {
    let buffer = PtyOutputBuffer()
    let consumer = Task { await buffer.next() }
    consumer.cancel()
    #expect(await consumer.value == nil)
    await buffer.finish()
}

@Test func subscriptionReleaseFiresOnceOnExplicitFireOrDeinit() {
    final class Count: @unchecked Sendable { var n = 0 }
    let fired = Count(), dropped = Count()
    var token: PtySubscriptionRelease? = PtySubscriptionRelease { fired.n += 1 }
    token?.fire()
    token = nil
    #expect(fired.n == 1)
    var other: PtySubscriptionRelease? = PtySubscriptionRelease { dropped.n += 1 }
    _ = other
    other = nil
    #expect(dropped.n == 1)
}

/// The leak the release token exists for: a consumer that `break`s out of `for await` after a
/// delivered batch never cancels a pending pull, so `onCancel` alone would never deregister it.
@Test func breakingOutOfAnOutputStreamStillReleasesTheSubscription() async {
    final class Count: @unchecked Sendable { var n = 0 }
    let released = Count()
    let buffer = PtyOutputBuffer(initial: [Data("a".utf8), Data("b".utf8)])
    do {
        let release = PtySubscriptionRelease { released.n += 1 }
        let stream = AsyncStream(unfolding: {
            withExtendedLifetime(release) {}
            return await buffer.next()
        }, onCancel: { release.fire() })
        for await _ in stream { break }
    }
    #expect(released.n == 1)
    await buffer.finish()
}

@Test func scrollPreservesFastDragDistanceAcrossFrameBatches() {
    var scroll = TerminalScrollMotion()
    scroll.drag(points: 500)
    var lines = 0
    for _ in 0..<10 { lines += scroll.advance(seconds: 1 / 60, lineHeight: 10) }
    #expect(lines == 50)
    #expect(!scroll.needsFrame(lineHeight: 10))
}

@Test func scrollMomentumIsFrameRateIndependentAndStops() {
    func travel(hz: Double) -> Int {
        var scroll = TerminalScrollMotion()
        scroll.end(velocity: 2000)
        var lines = 0
        for _ in 0..<Int(hz * 2) {
            lines += scroll.advance(seconds: 1 / hz, lineHeight: 10)
        }
        #expect(!scroll.needsFrame(lineHeight: 10))
        return lines
    }
    #expect(abs(travel(hz: 60) - travel(hz: 120)) <= 1)
    #expect(travel(hz: 60) > 0)
}

@Test func scrollCancelAndNewTouchStopOldMomentum() {
    var scroll = TerminalScrollMotion()
    scroll.end(velocity: -2000)
    #expect(scroll.advance(seconds: 1 / 60, lineHeight: 10) < 0)
    scroll.cancel()
    #expect(!scroll.needsFrame(lineHeight: 10))
    #expect(scroll.advance(seconds: 1, lineHeight: 10) == 0)
    scroll.end(velocity: 2000)
    scroll.begin()
    scroll.drag(points: -25)
    #expect(scroll.advance(seconds: 1 / 60, lineHeight: 10) == -2)
}

private final class TransportPair: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    let first = FakeTransport()
    let second = FakeTransport()
    func make() -> FrameTransporting {
        lock.withLock {
            defer { taken = true }
            return taken ? second : first
        }
    }
}

private actor ReconnectGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private func eventually(_ predicate: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        await Task.yield()
    }
    return await predicate()
}

@Test func rendererOverflowReconnectsAndFreshOutputContainsNoOldVT() async throws {
    let pair = TransportPair()
    let gate = ReconnectGate()
    let rpc = RpcClient(makeTransport: { pair.make() }, sleeper: { _ in await gate.wait() })
    await rpc.start()
    try #require(await eventually { await rpc.connectionState() == .connected })
    let staleStream = await rpc.ptyData(for: "pane")
    let pending = Task {
        do { _ = try await rpc.request("test:pending", []); return false }
        catch let error as RpcError { return error == .disconnected }
        catch { return false }
    }
    try #require(await eventually { await pair.first.sentFrames().count == 1 })
    for _ in 0...PtyOutputBuffer.chunkLimit {
        await pair.first.push(.binary(PtyBinaryFrame.encode(sessionId: "pane", text: "\u{1b}[")!))
    }
    try #require(await eventually { await pair.first.closes() > 0 })
    #expect(await pending.value)
    #expect(await rpc.connectionState() == .reconnecting)
    var staleIterator = staleStream.makeAsyncIterator()
    #expect(await staleIterator.next() == nil)
    #expect(await pair.first.sentFrames().count == 1) // only test:pending; no destroy, flow, or replay
    await gate.release()
    try #require(await eventually { await rpc.connectionState() == .connected })
    let freshStream = await rpc.ptyData(for: "pane")
    await pair.second.push(.binary(PtyBinaryFrame.encode(sessionId: "pane", text: "new screen")!))
    var freshIterator = freshStream.makeAsyncIterator()
    #expect(await freshIterator.next() == Data("new screen".utf8))
    await rpc.stop()
}

@Test func outputOverflowBeforeSubscriptionAlsoReconnects() async throws {
    let pair = TransportPair()
    let gate = ReconnectGate()
    let rpc = RpcClient(makeTransport: { pair.make() }, sleeper: { _ in await gate.wait() })
    await rpc.start()
    try #require(await eventually { await rpc.connectionState() == .connected })
    let payload = Data(repeating: 0x61, count: PtyOutputBuffer.byteLimit)
    await pair.first.push(.binary(PtyBinaryFrame.encode(sessionId: "pane", payload: payload)!))
    await pair.first.push(.binary(PtyBinaryFrame.encode(sessionId: "pane", text: "overflow")!))
    try #require(await eventually { await pair.first.closes() > 0 })
    await rpc.stop()
    await gate.release()
}
