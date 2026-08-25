import Foundation
import os

// A `FrameTransporting` (Contracts.swift) over `URLSessionWebSocketTask` (SPEC §4.1/§4.2).
//
// Security-critical construction (SPEC §10.1a / §4.1):
//   - EPHEMERAL `URLSessionConfiguration` with `httpCookieAcceptPolicy = .never` and
//     `httpShouldSetCookies = false`, so the system cookie jar is bypassed entirely and one
//     Tailscale hostname's two ports can never leak each other's `nt_session`.
//   - The ONLY cookie transport is a manually attached `Cookie: nt_session=<value>` header keyed
//     by server PROFILE id (the caller passes the value; this type never reads a jar).
//   - NO `Origin` header is ever set (§4.1): the origin check only runs when Origin is present;
//     absent Origin passes, and a native client authenticates purely by cookie (§10.4).
//
// Defensive heartbeat (SPEC §4.7 / §12 item 1): the server pings every 30 s and reaps a silent
// peer in 30–60 s. `URLSessionWebSocketTask` is expected to auto-answer protocol PING with PONG,
// but whether it does so in every app state is UNVERIFIED on-device (§12 item 1). We therefore
// also schedule a client-side ping every 20 s while connected — it is not required by the server,
// but it surfaces a dead link sooner and keeps NAT state warm. A ping failure closes the task,
// which makes the pending `receive()` throw and drives the reconnect loop (§4.8).

/// A minimal `os_unfair_lock` wrapper. `NSLock.lock()`/`unlock()` are unavailable from async
/// contexts; the C primitive is not, so a sync scoped `withLock` is safe to call from `async` code
/// (the closure never suspends).
private final class UnfairLock: @unchecked Sendable {
    private let p: os_unfair_lock_t
    init() { p = .allocate(capacity: 1); p.initialize(to: os_unfair_lock()) }
    deinit { p.deinitialize(count: 1); p.deallocate() }
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        os_unfair_lock_lock(p); defer { os_unfair_lock_unlock(p) }
        return try body()
    }
}

public final class WebSocketFrameTransport: NSObject, FrameTransporting, @unchecked Sendable {
    // @unchecked Sendable: every mutable field is touched only inside `lock.withLock`. The
    // URLSession delegate callbacks land on an arbitrary queue, so the lock is the one sync point.

    private let url: URL
    private let cookieValue: String
    private let pingIntervalNs: UInt64

    private let lock = UnfairLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var httpStatus: Int?
    private var pingTask: Task<Void, Never>?
    private var didOpen = false

    /// - Parameters:
    ///   - url: the derived `<ws|wss>://host[:port]/ws` (SPEC §4.1). Never mutated.
    ///   - cookieValue: the raw `nt_session` value from the Keychain, keyed by profile id (§10.1a).
    ///   - pingIntervalMs: client-side ping cadence (defensive; §4.7/§12).
    public init(url: URL, cookieValue: String, pingIntervalMs: Int = 20_000) {
        self.url = url
        self.cookieValue = cookieValue
        self.pingIntervalNs = UInt64(max(1000, pingIntervalMs)) * 1_000_000
        super.init()
    }

    public func connect() async throws {
        let config = URLSessionConfiguration.ephemeral            // §10.1a: no persistent jar/cache
        config.httpCookieAcceptPolicy = .never                   // §10.1a
        config.httpShouldSetCookies = false                      // §10.1a
        config.httpCookieStorage = nil

        var request = URLRequest(url: url)
        // Manual, profile-scoped cookie — the ONLY cookie transport (§10.1a). Redacted in any log.
        request.setValue("\(NodetermWire.sessionCookieName)=\(cookieValue)", forHTTPHeaderField: "Cookie")
        // NO Origin header, ever (§4.1/§10.4). We deliberately set nothing here.

        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)

        lock.withLock {
            self.session = session
            self.task = task
            self.didOpen = false
            self.httpStatus = nil
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.withLock { self.openContinuation = cont }
            task.resume()
        }

        startPinging()
    }

    public func send(_ text: String) async throws {
        // Outbound size guard mirrored at the transport edge (SPEC §4.10): refuse locally so the
        // server never has to close the whole socket with 1009. The RPC layer also guards, but a
        // transport used directly must be safe too.
        let bytes = text.utf8.count
        guard bytes <= NodetermWire.maxPayloadBytes else {
            throw RpcTransportError.frameTooLarge(bytes: bytes)
        }
        guard let task = lock.withLock({ self.task }) else { throw RpcTransportError.closed }
        try await task.send(.string(text))
    }

    public func receive() async throws -> WSMessage {
        guard let task = lock.withLock({ self.task }) else { throw RpcTransportError.closed }
        let message = try await task.receive()
        switch message {
        case .string(let s): return .text(s)
        case .data(let d): return .binary(d)          // §4.2: binary = raw pty bytes, server→client
        @unknown default: return .binary(Data())
        }
    }

    public func close() async {
        let (task, session, ping): (URLSessionWebSocketTask?, URLSession?, Task<Void, Never>?) =
            lock.withLock {
                let t = self.task; let s = self.session; let p = self.pingTask
                self.task = nil; self.session = nil; self.pingTask = nil
                return (t, s, p)
            }
        ping?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: - Client-side ping (defensive; §4.7/§12)

    private func startPinging() {
        let t = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.pingIntervalNs)
                if Task.isCancelled { return }
                guard let task = self.lock.withLock({ self.task }) else { return }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    task.sendPing { _ in cont.resume() }   // a failure surfaces via receive()
                }
            }
        }
        lock.withLock { self.pingTask = t }
    }

    // MARK: - Open/close resolution

    private func resolveOpen(_ result: Result<Void, Error>) {
        let cont: CheckedContinuation<Void, Error>? = lock.withLock {
            let c = self.openContinuation
            self.openContinuation = nil
            if case .success = result { self.didOpen = true }
            return c
        }
        guard let cont else { return }
        switch result {
        case .success: cont.resume()
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    /// Classify a connect/close failure into an auth vs connectivity error (SPEC §4.8.4).
    private func failure(from error: Error?) -> Error {
        let status = lock.withLock { self.httpStatus }
        if status == 401 { return RpcTransportError.authFailed }     // §4.1 raw 401 at upgrade
        if let status, status >= 400 { return RpcTransportError.upgradeFailed(status: status) }
        return error ?? RpcTransportError.connectFailure
    }
}

extension WebSocketFrameTransport: URLSessionWebSocketDelegate {
    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocolName: String?
    ) {
        resolveOpen(.success(()))
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        // If the socket closed before it ever opened, fail the connect continuation (§4.8.5).
        if !lock.withLock({ self.didOpen }) { resolveOpen(.failure(failure(from: nil))) }
    }
}

extension WebSocketFrameTransport: URLSessionTaskDelegate {
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // The HTTP upgrade response carries the 401 (SPEC §4.1). Capture the status so `failure`
        // can classify auth-expiry, then resolve any still-pending connect.
        if let http = task.response as? HTTPURLResponse {
            lock.withLock { self.httpStatus = http.statusCode }
        }
        if !lock.withLock({ self.didOpen }) { resolveOpen(.failure(failure(from: error))) }
    }
}
