import Foundation
import os
@testable import NodetermKit

// FRAMEWORK-FREE TESTS (see RpcCodecTests.swift): CommandLineTools has no XCTest / swift-testing.
// This file compiles in the test target and exposes `runRpcClientTests()` (async) using
// `precondition`. It drives the actor `RpcClient` (SPEC §4/§8.2) against an in-memory fake
// transport — no network. On a full toolchain each block promotes to a `@Test`/XCTest case.

// Eager (non-autoclosure) so call sites can pass `await …` expressions as the argument.
@inline(__always)
private func expect(_ condition: Bool, _ label: String) {
    precondition(condition, "rpc-client test failed: \(label)")
}

// MARK: - In-memory fake transport (SPEC §8.2 test seam)

/// A controllable `FrameTransporting`. The test pushes inbound frames, records outbound text, and
/// can simulate a socket close. One receive waiter at a time (the client runs a single receive loop).
actor FakeTransport: FrameTransporting {
    private var connectError: Error?
    private var sent: [String] = []
    private var buffer: [WSMessage] = []
    private var waiter: CheckedContinuation<WSMessage, Error>?
    private var closed = false
    private var closeCount = 0

    func setConnectError(_ e: Error?) { connectError = e; if e == nil { closed = false } }

    // FrameTransporting
    func connect() async throws {
        if closed { throw RpcTransportError.connectFailure }
        if let connectError { throw connectError }
    }
    func send(_ text: String) async throws {
        if closed { throw RpcTransportError.closed }
        sent.append(text)
    }
    func receive() async throws -> WSMessage {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if closed { throw RpcTransportError.closed }
        return try await withCheckedThrowingContinuation { c in self.waiter = c }
    }
    func close() async {
        closed = true
        closeCount += 1
        if let w = waiter { waiter = nil; w.resume(throwing: RpcTransportError.closed) }
    }

    // Test controls
    func push(_ m: WSMessage) {
        if let w = waiter { waiter = nil; w.resume(returning: m) }
        else { buffer.append(m) }
    }
    func simulateClose() {
        closed = true
        if let w = waiter { waiter = nil; w.resume(throwing: RpcTransportError.closed) }
    }
    func sentFrames() -> [String] { sent }
    func closes() -> Int { closeCount }
    func reopen() { closed = false; connectError = nil }
    func firstSentId() -> Int? {
        guard let f = sent.first, case .req(let id, _, _, _)? = RpcFrame.parse(text: f) else { return nil }
        return id
    }
}

actor Collector<T: Sendable> {
    private var items: [T] = []
    func append(_ t: T) -> Int { items.append(t); return items.count }
    func all() -> [T] { items }
}

/// A cross-domain reference cell for the backoff test: the @Sendable sleeper needs a handle to the
/// client, which does not exist until after the sleeper is built. Guarded by an unfair lock.
final class BackoffBox: @unchecked Sendable {
    private let p: os_unfair_lock_t
    private var _client: RpcClient?
    init() { p = .allocate(capacity: 1); p.initialize(to: os_unfair_lock()) }
    deinit { p.deinitialize(count: 1); p.deallocate() }
    var client: RpcClient? {
        get { os_unfair_lock_lock(p); defer { os_unfair_lock_unlock(p) }; return _client }
        set { os_unfair_lock_lock(p); _client = newValue; os_unfair_lock_unlock(p) }
    }
}


// MARK: - Async helpers

private func waitUntil(timeoutMs: Int = 3000, _ cond: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if await cond() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await cond()
}

private func waitUntilConnected(_ c: RpcClient, timeoutMs: Int = 3000) async -> Bool {
    await waitUntil(timeoutMs: timeoutMs) { await c.connectionState() == .connected }
}

private func collect(_ stream: AsyncStream<[JSONValue]>, count: Int, timeoutMs: Int = 3000) async -> [[JSONValue]] {
    let collector = Collector<[JSONValue]>()
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await v in stream { if await collector.append(v) >= count { break } }
        }
        group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000) }
        _ = await group.next()
        group.cancelAll()
    }
    return await collector.all()
}

// MARK: - The tests

public func runRpcClientTests() async {
    await testDisconnectFailsPendingRequests()
    await testResOkResolvesRequest()
    await testResErrMapsToTypedNoHandler()
    await testEarlyEventReplayedToFirstSubscriber()
    await testEarlyEventBufferConsumedByFirstSubscriberOnly()
    await testEarlyEventBufferDropsOldestAtCap()
    await testBinaryFramesFanOutToPtyDataStream()
    await testOutboundSizeGuardThrowsFrameTooLarge()
    await testJustUnderCapIsAllowedThroughGuard()
    testReconnectBackoffScheduleValues()
    await testClientDrivesBackoffScheduleOnRepeatedConnectFailure()
    await testInboundUndefTrimsTrailingOmittedArg()
    await testInboundMeaningfulNullPreserved()
    await testConnectionStateReachesConnectedThenOffline()
    await testClientRestartsAfterStop()
    await testAbandonedTransportsAreClosed()
}

// §4.8.1 — every in-flight request fails with .disconnected on close
private func testDisconnectFailsPendingRequests() async {
    let fake = FakeTransport()
    let client = RpcClient(makeTransport: { fake })
    await client.start()
    expect(await waitUntilConnected(client), "connected")

    let reqTask = Task { try await client.request("workspace:load", []) }
    expect(await waitUntil { await !fake.sentFrames().isEmpty }, "request sent")

    await fake.simulateClose()
    do {
        _ = try await reqTask.value
        expect(false, "request should fail on disconnect")
    } catch let e as RpcError {
        expect(e == .disconnected, "disconnected error")
    } catch { expect(false, "unexpected error \(error)") }
    await client.stop()
}

// §4.3/§4.6 — res routing to the matching pending id
private func testResOkResolvesRequest() async {
    let fake = FakeTransport()
    let client = RpcClient(makeTransport: { fake })
    await client.start()
    expect(await waitUntilConnected(client), "connected")

    let reqTask = Task { try await client.request("pty:capture", [.value("nt-1"), .omitted]) }
    expect(await waitUntil { await fake.firstSentId() != nil }, "sent")
    let id = await fake.firstSentId()!
    await fake.push(.text(try! RpcFrame.resOk(id: id, result: .string("screen text")).encodedText()))
    let result = try! await reqTask.value
    expect(result.stringValue == "screen text", "resOk resolves")
    await client.stop()
}

private func testResErrMapsToTypedNoHandler() async {
    let fake = FakeTransport()
    let client = RpcClient(makeTransport: { fake })
    await client.start()
    expect(await waitUntilConnected(client), "connected")

    let reqTask = Task { try await client.request("pty:generate-name", []) }
    expect(await waitUntil { await fake.firstSentId() != nil }, "sent")
    let id = await fake.firstSentId()!
    let err = RpcErrorPayload(code: "E_NO_HANDLER", message: "pty:generate-name")
    await fake.push(.text(try! RpcFrame.resErr(id: id, error: err).encodedText()))
    do {
        _ = try await reqTask.value
        expect(false, "expected E_NO_HANDLER")
    } catch let e as RpcError {
        expect(e == .noHandler(method: "pty:generate-name"), "noHandler mapped")
    } catch { expect(false, "unexpected \(error)") }
    await client.stop()
}

// §4.9 — early-event buffering
private func testEarlyEventReplayedToFirstSubscriber() async {
    let fake = FakeTransport()
    let client = RpcClient(makeTransport: { fake })
    await client.start()
    expect(await waitUntilConnected(client), "connected")

    await fake.push(.text(try! RpcFrame.ev(channel: "presence:sync", args: [.string("early")], undef: []).encodedText()))
    let marker = await client.subscribe("marker")
    await fake.push(.text(try! RpcFrame.ev(channel: "marker", args: [.string("go")], undef: []).encodedText()))
    _ = await collect(marker, count: 1)

    let sub = await client.subscribe("presence:sync")
    let got = await collect(sub, count: 1)
    expect(got.first?.first?.stringValue == "early", "early event replayed to first subscriber")
    await client.stop()
}

private func testEarlyEventBufferConsumedByFirstSubscriberOnly() async {
    let fake = FakeTransport()
    let client = RpcClient(makeTransport: { fake })
    await client.start()
    expect(await waitUntilConnected(client), "connected")

    await fake.push(.text(try! RpcFrame.ev(channel: "c", args: [.string("buffered")], undef: []).encodedText()))
    let marker = await client.subscribe("marker")
    await fake.push(.text(try! RpcFrame.ev(channel: "marker", args: [.string("go")], undef: []).encodedText()))
    _ = await collect(marker, count: 1)

    let sub1 = await client.subscribe("c")
    expect((await collect(sub1, count: 1)).first?.first?.stringValue == "buffered", "first drains buffer")

    let sub2 = await client.subscribe("c")
    await fake.push(.text(try! RpcFrame.ev(channel: "c", args: [.string("live")], undef: []).encodedText()))
    expect((await collect(sub2, count: 1)).first?.first?.stringValue == "live", "second sees only live event")
    await client.stop()
}

private func testEarlyEventBufferDropsOldestAtCap() async {
    let fake = FakeTransport()
    let client = RpcClient(makeTransport: { fake })
    await client.start()
    expect(await waitUntilConnected(client), "connected")

    let cap = NodetermWire.earlyEventBufferCap
    for i in 0...cap {
        await fake.push(.text(try! RpcFrame.ev(channel: "flood", args: [.number(Double(i))], undef: []).encodedText()))
    }
    let marker = await client.subscribe("marker")
    await fake.push(.text(try! RpcFrame.ev(channel: "marker", args: [.string("go")], undef: []).encodedText()))
    _ = await collect(marker, count: 1)

    let flood = await client.subscribe("flood")
    let got = await collect(flood, count: cap)
    expect(got.count == cap, "buffer holds exactly the cap after drop-oldest (got \(got.count))")
    expect(got.first?.first?.intValue == 1, "oldest (index 0) dropped")
    expect(got.last?.first?.intValue == cap, "newest retained")
    await client.stop()
}

// §4.5 — binary frames fan out to the pty:data stream
private func testBinaryFramesFanOutToPtyDataStream() async {
    let fake = FakeTransport()
    let client = RpcClient(makeTransport: { fake })
    await client.start()
    expect(await waitUntilConnected(client), "connected")

    let stream = await client.ptyData(for: "nt-7")
    let payload = "\u{1b}[32mok\u{1b}[0m 🦝"
    await fake.push(.binary(PtyBinaryFrame.encode(sessionId: "nt-7", text: payload)!))

    let collector = Collector<Data>()
    await withTaskGroup(of: Void.self) { group in
        group.addTask { for await d in stream { _ = await collector.append(d); break } }
        group.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000) }
        _ = await group.next(); group.cancelAll()
    }
    let payloads = await collector.all()
    expect(payloads.count == 1, "one pty frame delivered")
    expect(payloads.first.map { String(decoding: $0, as: UTF8.self) } == payload, "pty payload intact")
    await client.stop()
}

// §4.10 — outbound 8 MiB guard, refused locally
private func testOutboundSizeGuardThrowsFrameTooLarge() async {
    let fake = FakeTransport()
    let client = RpcClient(makeTransport: { fake })
    let big = String(repeating: "a", count: NodetermWire.maxPayloadBytes + 1024)
    do {
        _ = try await client.request("pty:send-text", [.value("nt-1"), .value(.string(big)), .value(true)])
        expect(false, "oversized frame must be refused, not sent")
    } catch let e as RpcClientError {
        guard case .frameTooLarge(let bytes) = e else { return expect(false, "wrong case \(e)") }
        expect(bytes > NodetermWire.maxPayloadBytes, "reported byte count over cap")
    } catch { expect(false, "unexpected \(error)") }
    expect(await fake.sentFrames().isEmpty, "nothing was sent")
}

private func testJustUnderCapIsAllowedThroughGuard() async {
    let fake = FakeTransport()
    let client = RpcClient(makeTransport: { fake })
    await client.start()
    expect(await waitUntilConnected(client), "connected")
    let ok = String(repeating: "b", count: 1024)
    let reqTask = Task { try await client.request("pty:send-text", [.value("nt-1"), .value(.string(ok)), .value(true)]) }
    expect(await waitUntil { await fake.firstSentId() != nil }, "under-cap frame sent")
    let id = await fake.firstSentId()!
    await fake.push(.text(try! RpcFrame.resOk(id: id, result: .bool(true)).encodedText()))
    expect((try! await reqTask.value).boolValue == true, "under-cap request resolves")
    await client.stop()
}

// §4.8.2 — reconnect backoff schedule 1s·2^n capped at 10s
private func testReconnectBackoffScheduleValues() {
    expect(NodetermWire.reconnectDelayMs(attempt: 0) == 1000, "2^0")
    expect(NodetermWire.reconnectDelayMs(attempt: 1) == 2000, "2^1")
    expect(NodetermWire.reconnectDelayMs(attempt: 2) == 4000, "2^2")
    expect(NodetermWire.reconnectDelayMs(attempt: 3) == 8000, "2^3")
    expect(NodetermWire.reconnectDelayMs(attempt: 4) == 10_000, "cap")
    expect(NodetermWire.reconnectDelayMs(attempt: 5) == 10_000, "cap holds")
}

private func testClientDrivesBackoffScheduleOnRepeatedConnectFailure() async {
    let fake = FakeTransport()
    await fake.setConnectError(RpcTransportError.connectFailure)  // every connect attempt fails

    let recorder = Collector<Int>()
    let box = BackoffBox()
    let sleeper: @Sendable (Int) async -> Void = { ms in
        let n = await recorder.append(ms)
        if n >= 5 { await box.client?.stop() }   // break the loop after 5 recorded delays
    }
    let client = RpcClient(makeTransport: { fake }, sleeper: sleeper)
    box.client = client
    await client.start()

    expect(await waitUntil(timeoutMs: 5000) { await recorder.all().count >= 5 }, "5 backoff delays observed")
    let delays = Array((await recorder.all()).prefix(5))
    expect(delays == [1000, 2000, 4000, 8000, 10_000], "backoff schedule = \(delays)")
    await client.stop()
}

// §4.4 — inbound undef decode trims trailing absent slots
private func testInboundUndefTrimsTrailingOmittedArg() async {
    let fake = FakeTransport()
    let client = RpcClient(makeTransport: { fake })
    await client.start()
    expect(await waitUntilConnected(client), "connected")

    let sub = await client.subscribe("ch")
    await fake.push(.text(try! RpcFrame.ev(channel: "ch", args: [.string("x"), .null], undef: [1]).encodedText()))
    let got = await collect(sub, count: 1)
    expect(got.first == [.string("x")], "trailing omitted arg trimmed")
    await client.stop()
}

private func testInboundMeaningfulNullPreserved() async {
    let fake = FakeTransport()
    let client = RpcClient(makeTransport: { fake })
    await client.start()
    expect(await waitUntilConnected(client), "connected")

    let sub = await client.subscribe("ch")
    await fake.push(.text(try! RpcFrame.ev(channel: "ch", args: [.string("x"), .null], undef: []).encodedText()))
    let got = await collect(sub, count: 1)
    expect(got.first == [.string("x"), .null], "meaningful null preserved")
    await client.stop()
}

// SPEC §8.4 — the app foreground/background lifecycle: stop() then start() on the SAME client
// must reconnect (the background→foreground round-trip; `stopped` is per-run, not a tombstone).
private func testClientRestartsAfterStop() async {
    let fake = FakeTransport()
    let client = RpcClient(makeTransport: { fake })
    await client.start()
    expect(await waitUntilConnected(client), "first run connects")

    await client.stop()
    expect(await client.connectionState() == .offline, "offline after stop")

    await fake.reopen()   // background killed the socket; foreground gets a fresh one
    await client.start()
    expect(await waitUntilConnected(client), "restart after stop reconnects")

    // The restarted run serves requests end-to-end.
    let reqTask = Task { try await client.request("workspace:load", []) }
    expect(await waitUntil { await fake.firstSentId() != nil }, "restarted run sends")
    let id = await fake.firstSentId()!
    await fake.push(.text(try! RpcFrame.resOk(id: id, result: .bool(true)).encodedText()))
    expect((try! await reqTask.value).boolValue == true, "restarted run resolves requests")
    await client.stop()
}

// Leak guard — every transport the reconnect loop abandons is close()d: N failed connect
// attempts must produce N closes (the URLSession/ping-task leak fix).
private func testAbandonedTransportsAreClosed() async {
    let fake = FakeTransport()
    await fake.setConnectError(RpcTransportError.connectFailure)

    let recorder = Collector<Int>()
    let box = BackoffBox()
    let sleeper: @Sendable (Int) async -> Void = { ms in
        let n = await recorder.append(ms)
        if n >= 3 { await box.client?.stop() }
    }
    let client = RpcClient(makeTransport: { fake }, sleeper: sleeper)
    box.client = client
    await client.start()
    expect(await waitUntil(timeoutMs: 5000) { await recorder.all().count >= 3 }, "3 attempts ran")
    await client.stop()
    expect(await waitUntil { await fake.closes() >= 3 },
           "every failed connect attempt closed its transport (got \(await fake.closes()))")
}

private func testConnectionStateReachesConnectedThenOffline() async {
    let fake = FakeTransport()
    let client = RpcClient(makeTransport: { fake })
    await client.start()
    expect(await waitUntilConnected(client), "reaches connected")
    await client.stop()
    expect(await client.connectionState() == .offline, "offline after stop")
}
