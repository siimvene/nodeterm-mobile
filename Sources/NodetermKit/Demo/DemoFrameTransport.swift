import Foundation

// A self-contained `FrameTransporting` that drives the ENTIRE real stack — `RpcClient`, the stores,
// `TerminalSessionController`, the SwiftTerm view — with NO server and NO network (docs/DEMO-MODE.md).
// It is the one and only synthetic type: everything above the socket depends solely on the
// `FrameTransporting` protocol (Contracts.swift), so swapping this in reuses the real byte-for-byte
// connect/subscribe/request flow.
//
// Behavior:
//   - `connect()` succeeds immediately and, once, kicks off the scripted push sequence
//     (agent-status, context, usage, canvas:mut, binary pty frames) on a short timer.
//   - `send(text)` parses the outbound frame; a `req` is answered by matching its METHOD to a
//     canned result and echoing the request's own `id` in the `res` (the client picks ids, so a
//     `res` can only be built once the id is on the wire — §4.3). A `cast` (presence:hello,
//     pty:write, pty:resize, …) is accepted and dropped, exactly like a real server that needs no
//     reply.
//   - `receive()` yields the queued frames in order and then **SUSPENDS INDEFINITELY** when the
//     script is exhausted. It MUST NOT throw on exhaustion: a throw would make `RpcClient` treat
//     the socket as dropped and spin its reconnect/backoff loop forever (Contracts.swift / §4.8).
//     The only thing that ends the suspension is `close()`.
//
// Isolation: an `actor`, so the frame queue and the single receive waiter need no extra locking;
// every method already runs on the actor's executor.
public actor DemoFrameTransport: FrameTransporting {

    /// Resolve a client `req` method to its canned `result` (nil ⇒ answer `E_NO_HANDLER`).
    private let resolve: @Sendable (String) -> JSONValue?
    /// The unsolicited push sequence emitted after connect.
    private let script: [DemoPush]

    private var queue: [WSMessage] = []
    private var waiter: CheckedContinuation<WSMessage, Error>?
    private var closed = false
    private var scriptStarted = false

    public init(
        script: [DemoPush] = DemoScript.pushes,
        resolve: @escaping @Sendable (String) -> JSONValue? = { DemoScript.cannedResult(forMethod: $0) }
    ) {
        self.script = script
        self.resolve = resolve
    }

    // MARK: - FrameTransporting

    public func connect() async throws {
        // A demo socket always opens (offline-friendly). Start the push script exactly once.
        closed = false
        guard !scriptStarted else { return }
        scriptStarted = true
        Task { await self.runScript() }
    }

    public func send(_ text: String) async throws {
        guard !closed else { throw RpcTransportError.closed }
        // The client only ever sends `req` / `cast` (§4.3). A `req` gets a canned reply keyed by
        // method, reusing the client's own id; a `cast` is accepted and dropped.
        switch RpcFrame.parse(text: text) {
        case let .req(id, method, _, _):
            if let result = resolve(method) {
                enqueue(.text(try RpcFrame.resOk(id: id, result: result).encodedText()))
            } else {
                let err = RpcErrorPayload(code: "E_NO_HANDLER", message: method)
                enqueue(.text(try RpcFrame.resErr(id: id, error: err).encodedText()))
            }
        case .cast, .none, .ev, .resOk, .resErr:
            return  // fire-and-forget or not-client-shaped: nothing to answer
        }
    }

    public func receive() async throws -> WSMessage {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { throw RpcTransportError.closed }
        // Script exhausted and nothing queued: suspend until a later push or close(). NEVER throw
        // here — that would drive RpcClient's reconnect loop (docs/DEMO-MODE.md).
        return try await withCheckedThrowingContinuation { cont in
            self.waiter = cont
        }
    }

    public func close() async {
        closed = true
        if let w = waiter {
            waiter = nil
            // Ending the suspension on close is correct — the client is tearing down (stop()), not
            // reconnecting, so this throw does not spin the loop.
            w.resume(throwing: RpcTransportError.closed)
        }
    }

    // MARK: - Internal

    /// Deliver a frame to a waiting `receive()` or buffer it in order.
    private func enqueue(_ message: WSMessage) {
        if let w = waiter {
            waiter = nil
            w.resume(returning: message)
        } else {
            queue.append(message)
        }
    }

    /// Emit the scripted pushes in order, each after its delay. Stops early if the socket closed.
    private func runScript() async {
        for push in script {
            switch push {
            case let .event(channel, args, delayMs):
                await sleep(ms: delayMs)
                if closed { return }
                guard let text = try? RpcFrame.ev(channel: channel, args: args, undef: []).encodedText()
                else { continue }
                enqueue(.text(text))
            case let .binary(data, delayMs):
                await sleep(ms: delayMs)
                if closed { return }
                enqueue(.binary(data))
            }
        }
    }

    private func sleep(ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
    }
}
