import Foundation

// The WS-RPC client (SPEC §4 / §8.2). One instance per server. It owns the id counter, the
// pending-request map, the `undef` codec wiring (encode via `RpcArgs`, decode on inbound `ev`),
// binary pty decode, channel fan-out with the bounded early-event buffer (§4.9), the outbound
// 8 MiB size guard (§4.10), and the reconnect loop with exponential backoff (§4.8).
//
// The frame/codec primitives themselves live in the fixed contract (`Models/RpcFrame.swift`:
// `RpcFrame.parse` / `.encodedText`, `RpcArgs`, `PtyBinaryFrame`). This file drives them.

/// Errors the client raises locally (i.e. not decoded from a wire `res.error`). Kept separate from
/// the fixed `RpcError` (Contracts.swift), which has no "frame too large" case — see the GAP note
/// at the bottom of this file.
public enum RpcClientError: Error, Sendable, Equatable {
    /// An outbound frame exceeded the server's 8 MiB inbound cap (SPEC §4.10). Refused LOCALLY so
    /// the server never has to close the whole socket with code 1009.
    case frameTooLarge(bytes: Int)
}

/// Transport-level failures the `FrameTransporting.connect()` implementation surfaces so the
/// reconnect loop can distinguish auth-expiry (re-auth, §3.5/§4.8.4) from plain connectivity.
public enum RpcTransportError: Error, Sendable, Equatable {
    case authFailed              // raw HTTP/1.1 401 at the WS upgrade (SPEC §4.1)
    case upgradeFailed(status: Int)
    case connectFailure          // TCP / TLS / timeout — indistinguishable connectivity failure
    case closed                  // receive() after a normal/remote close
    case frameTooLarge(bytes: Int)
}

public actor RpcClient: RpcClienting {

    // MARK: Injected seams

    /// A FRESH transport is built per connect attempt — a `URLSessionWebSocketTask` is single-use,
    /// so reconnect (§4.8) needs a new socket each time.
    private let makeTransport: @Sendable () -> FrameTransporting
    /// Backoff sleep, injectable so tests observe the schedule without real time (SPEC §4.8.2).
    private let sleeper: @Sendable (_ ms: Int) async -> Void

    // MARK: Mutable state (actor-isolated)

    private var transport: FrameTransporting?
    private var loopTask: Task<Void, Never>?
    private var stopped = false

    private var nextId = 1  // client-chosen, monotonically increasing, starts at 1 (SPEC §4.3)
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]

    private var evSubs: [String: [UUID: AsyncStream<[JSONValue]>.Continuation]] = [:]
    private var ptySubs: [String: [UUID: AsyncStream<Data>.Continuation]] = [:]
    private var stateSubs: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    /// Global early-event buffer, insertion-ordered, drop-oldest at 4096 (SPEC §4.9).
    private var earlyEvents: [(channel: String, args: [JSONValue])] = []
    /// Per-session early pty-output buffer (same discipline) so no bytes are lost between
    /// `pty:create` and the first `ptyData` subscription.
    private var earlyPty: [String: [Data]] = [:]

    private var state: ConnectionState = .offline

    // MARK: Init

    public init(
        makeTransport: @escaping @Sendable () -> FrameTransporting,
        sleeper: @escaping @Sendable (_ ms: Int) async -> Void = { ms in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
        }
    ) {
        self.makeTransport = makeTransport
        self.sleeper = sleeper
    }

    // MARK: RpcClienting — lifecycle

    public func start() async {
        guard loopTask == nil, !stopped else { return }
        loopTask = Task { [weak self] in await self?.runLoop() }
    }

    public func stop() async {
        stopped = true
        loopTask?.cancel()
        loopTask = nil
        let t = transport
        transport = nil
        await t?.close()
        // Clear BEFORE rejecting (SPEC §4.8.1).
        failAllPending()
        setState(.offline)
        finishAllStreams()
    }

    // MARK: RpcClienting — request / cast

    public func request(_ method: String, _ args: [RpcArg]) async throws -> JSONValue {
        let (jsonArgs, undef) = RpcArgs.encode(args)              // §4.4 encode
        let id = allocId()
        let framedText = try RpcFrame.req(id: id, method: method, args: jsonArgs, undef: undef).encodedText()
        let bytes = framedText.utf8.count
        guard bytes <= NodetermWire.maxPayloadBytes else {       // §4.10 outbound guard
            throw RpcClientError.frameTooLarge(bytes: bytes)
        }
        guard state == .connected, transport != nil else {
            throw RpcError.disconnected                          // §4.6/§4.8: no live socket
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
            // Runs synchronously under actor isolation: register BEFORE the send hop so a close
            // that races the send can still reject this id (§4.8.1).
            pending[id] = cont
            Task { [weak self] in await self?.deliver(id: id, text: framedText) }
        }
    }

    public func cast(_ method: String, _ args: [RpcArg]) async {
        let (jsonArgs, undef) = RpcArgs.encode(args)              // §4.4 encode
        guard let text = try? RpcFrame.cast(method: method, args: jsonArgs, undef: undef).encodedText() else {
            return
        }
        let bytes = text.utf8.count
        guard bytes <= NodetermWire.maxPayloadBytes else { return }  // §4.10: drop; a cast cannot throw
        guard state == .connected, let transport else { return }
        // Awaited directly (not hopped) so sequential casts — e.g. keystroke `pty:write`s — keep
        // their order (SPEC §7.6). A send failure just drops; the receive loop owns the disconnect.
        try? await transport.send(text)
    }

    /// Await the send for a `request`; on failure reject the pending id with `.disconnected` unless
    /// the disconnect path already cleared it.
    private func deliver(id: Int, text: String) async {
        guard let transport, pending[id] != nil else { return }
        do {
            try await transport.send(text)
        } catch {
            if let cont = pending.removeValue(forKey: id) {
                cont.resume(throwing: RpcError.disconnected)
            }
        }
    }

    private func allocId() -> Int {
        let id = nextId
        nextId += 1
        return id
    }

    // MARK: RpcClienting — subscriptions

    public func subscribe(_ channel: String) async -> AsyncStream<[JSONValue]> {
        let id = UUID()
        let (stream, cont) = AsyncStream.makeStream(of: [JSONValue].self)
        let firstForChannel = (evSubs[channel]?.isEmpty ?? true)
        evSubs[channel, default: [:]][id] = cont
        cont.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.dropEvSub(channel: channel, id: id) }
        }
        if firstForChannel {
            // Replay the early buffer for this channel, in order, to the FIRST subscriber (§4.9),
            // then remove those entries so a later subscriber does not re-receive them.
            var kept: [(channel: String, args: [JSONValue])] = []
            kept.reserveCapacity(earlyEvents.count)
            for entry in earlyEvents {
                if entry.channel == channel {
                    cont.yield(entry.args)
                } else {
                    kept.append(entry)
                }
            }
            earlyEvents = kept
        }
        return stream
    }

    public func ptyData(for sessionId: String) async -> AsyncStream<Data> {
        let id = UUID()
        let (stream, cont) = AsyncStream.makeStream(of: Data.self)
        let firstForSession = (ptySubs[sessionId]?.isEmpty ?? true)
        ptySubs[sessionId, default: [:]][id] = cont
        cont.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.dropPtySub(sessionId: sessionId, id: id) }
        }
        if firstForSession, let buffered = earlyPty[sessionId] {
            for payload in buffered { cont.yield(payload) }
            earlyPty[sessionId] = nil
        }
        return stream
    }

    public func connectionStates() async -> AsyncStream<ConnectionState> {
        let id = UUID()
        let (stream, cont) = AsyncStream.makeStream(of: ConnectionState.self)
        stateSubs[id] = cont
        cont.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.dropStateSub(id: id) }
        }
        cont.yield(state)  // hand the current state to a fresh observer immediately
        return stream
    }

    public func connectionState() async -> ConnectionState { state }

    private func dropEvSub(channel: String, id: UUID) {
        evSubs[channel]?[id] = nil
        if evSubs[channel]?.isEmpty == true { evSubs[channel] = nil }
    }
    private func dropPtySub(sessionId: String, id: UUID) {
        ptySubs[sessionId]?[id] = nil
        if ptySubs[sessionId]?.isEmpty == true { ptySubs[sessionId] = nil }
    }
    private func dropStateSub(id: UUID) { stateSubs[id] = nil }

    // MARK: Reconnect loop (SPEC §4.8)

    private func runLoop() async {
        var attempt = 0
        while !stopped {
            let t = makeTransport()
            setState(.reconnecting)
            do {
                try await t.connect()
            } catch {
                // Connect failure is treated identically to a mid-life drop (§4.8.5).
                setState(authState(for: error))
                if stopped { break }
                await sleeper(NodetermWire.reconnectDelayMs(attempt: attempt))  // §4.8.2
                attempt += 1
                continue
            }
            if stopped { await t.close(); break }
            transport = t
            attempt = 0                          // reset backoff on a successful open (§4.8.2)
            setState(.connected)                 // higher layers re-subscribe / re-issue pty:create (§4.8.3)
            await receiveUntilClose(t)
            transport = nil
            // Clear the pending map BEFORE rejecting so a re-request cannot collide with a stale id
            // (SPEC §4.8.1).
            failAllPending()
            if stopped { break }
            setState(.reconnecting)
            await sleeper(NodetermWire.reconnectDelayMs(attempt: attempt))      // §4.8.2
            attempt += 1
        }
    }

    private func receiveUntilClose(_ t: FrameTransporting) async {
        while !stopped {
            let msg: WSMessage
            do {
                msg = try await t.receive()
            } catch {
                return  // socket closed/errored → back to the reconnect loop
            }
            handle(msg)
        }
    }

    private func authState(for error: Error) -> ConnectionState {
        if let te = error as? RpcTransportError {
            switch te {
            case .authFailed, .upgradeFailed(401): return .authRequired
            default: return .reconnecting
            }
        }
        return .reconnecting
    }

    // MARK: Inbound dispatch (SPEC §4.3 / §4.4 / §4.5)

    private func handle(_ msg: WSMessage) {
        switch msg {
        case .text(let s):
            // One bad frame must never crash the connection — parse returns nil ⇒ drop (§4.3).
            guard let frame = RpcFrame.parse(text: s) else { return }
            switch frame {
            case .resOk(let id, let result):
                // A `res` whose id matches no in-flight request is dropped (§4.3).
                pending.removeValue(forKey: id)?.resume(returning: result)
            case .resErr(let id, let err):
                pending.removeValue(forKey: id)?.resume(
                    throwing: RpcError(code: err.code, message: err.message))  // §4.6 mapping
            case .ev(let channel, let args, let undef):
                dispatchEvent(channel: channel, args: applyInboundUndef(args, undef))  // §4.4 decode
            case .req, .cast:
                return  // the server never sends these; ignore (§4.3)
            }
        case .binary(let data):
            // Binary is pty output only; a bad layout drops (§4.5).
            guard let (sid, payload) = PtyBinaryFrame.decode(data) else { return }
            dispatchPty(sessionId: sid, payload: payload)
        }
    }

    /// Apply the inbound `undef` decode (SPEC §4.4): marked indexes are logically absent. Junk /
    /// out-of-range indexes mark nothing and can never lengthen the array. We trim trailing absent
    /// slots so a typed decoder sees an omitted trailing optional as missing; interior/leading
    /// marks stay as their on-the-wire `null` (removing them would shift positions).
    private func applyInboundUndef(_ args: [JSONValue], _ undef: [Int]) -> [JSONValue] {
        guard !undef.isEmpty else { return args }
        let absent = RpcArgs.absentIndexes(undef, count: args.count)
        guard !absent.isEmpty else { return args }
        var end = args.count
        while end > 0 && absent.contains(end - 1) { end -= 1 }
        return Array(args[0..<end])
    }

    private func dispatchEvent(channel: String, args: [JSONValue]) {
        if let subs = evSubs[channel], !subs.isEmpty {
            for (_, cont) in subs { cont.yield(args) }
            return
        }
        // No subscriber yet → buffer, drop-oldest at the cap (§4.9).
        earlyEvents.append((channel: channel, args: args))
        if earlyEvents.count > NodetermWire.earlyEventBufferCap {
            earlyEvents.removeFirst(earlyEvents.count - NodetermWire.earlyEventBufferCap)
        }
    }

    private func dispatchPty(sessionId: String, payload: Data) {
        if let subs = ptySubs[sessionId], !subs.isEmpty {
            for (_, cont) in subs { cont.yield(payload) }
            return
        }
        var buf = earlyPty[sessionId] ?? []
        buf.append(payload)
        if buf.count > NodetermWire.earlyEventBufferCap {
            buf.removeFirst(buf.count - NodetermWire.earlyEventBufferCap)
        }
        earlyPty[sessionId] = buf
    }

    // MARK: State + teardown helpers

    private func setState(_ new: ConnectionState) {
        guard new != state else { return }
        state = new
        for (_, cont) in stateSubs { cont.yield(new) }
    }

    /// Reject every in-flight request with `.disconnected` (SPEC §4.6/§4.8.1). The map is cleared
    /// FIRST, then the continuations are resumed, so a handler that immediately re-requests can
    /// never collide with a stale id.
    private func failAllPending() {
        let conts = pending
        pending.removeAll()
        for (_, cont) in conts { cont.resume(throwing: RpcError.disconnected) }
    }

    private func finishAllStreams() {
        for (_, subs) in evSubs { for (_, c) in subs { c.finish() } }
        for (_, subs) in ptySubs { for (_, c) in subs { c.finish() } }
        for (_, c) in stateSubs { c.finish() }
        evSubs.removeAll(); ptySubs.removeAll(); stateSubs.removeAll()
        earlyEvents.removeAll(); earlyPty.removeAll()
    }
}

// GAP (reported in the return): the fixed `RpcError` (Contracts.swift) has no "frame too large"
// case, and `cast` is non-throwing, so the 8 MiB outbound guard (§4.10) surfaces as
// `RpcClientError.frameTooLarge` from `request` and as a silent drop from `cast`. No Models/Contract
// file was edited to add a case.
