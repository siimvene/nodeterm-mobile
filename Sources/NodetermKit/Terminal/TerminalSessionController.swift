import Foundation

/// The co-attach VIEWER lifecycle (SPEC §7), mapping onto `RpcClienting`. Deliberately omits
/// `pty:destroy` / `pty:recycle` / `pty:flow` — those are owner actions the phone MUST NOT perform
/// in v0 (§7.4 / §7.9). An actor because it is shared mutable state per the concurrency house rules
/// (SPEC §8.1), though its only state is the injected client.
public actor TerminalSessionController: TerminalSessionControlling {
    private let rpc: RpcClienting

    public init(rpc: RpcClienting) {
        self.rpc = rpc
    }

    // MARK: - Create (§7.1)

    /// `pty:create` join/spawn. Refusals arrive in-band on the result, never as thrown errors
    /// (SPEC §5.1) — the caller inspects `result.isRefusal` / `closed` / `unavailable`.
    public func create(_ options: PtyCreateOptions) async throws -> PtyCreateResult {
        // PtyCreateOptions' synthesized Codable uses encodeIfPresent, so nil optionals are OMITTED
        // (not sent as null) — matching the "phone normally sends {cols,rows,persistKey,viewerId}"
        // shape (SPEC §7.1) without any manual field pruning.
        let optionsJSON = try encodeToJSONValue(options)
        let result = try await rpc.request(RpcMethod.ptyCreate, [.value(optionsJSON)])
        return try result.decoded(as: PtyCreateResult.self)
    }

    // MARK: - Input (§7.6)

    /// `pty:write` CAST — raw keystrokes (SPEC §7.6). Shift+Enter is delivered here as `\u{1b}\r`
    /// by the App (see `TerminalInputRouting`).
    public func write(sessionId: String, data: String) async {
        await rpc.cast(RpcMethod.ptyWrite, [.value(.string(sessionId)), .value(.string(data))])
    }

    /// `pty:send-text` REQ — framed, multi-line-safe delivery (SPEC §7.6). `enter` defaults to
    /// true server-side; pass nil to omit it via `undef`. Returns false when unavailable.
    public func sendText(persistKey: String, text: String, enter: Bool?) async throws -> Bool {
        // `enter` is a trailing optional: OMITTED (undef) when nil so the server default (true)
        // fires; a meaningful bool otherwise (SPEC §7.6).
        let enterArg: RpcArg = enter.map { .value(.bool($0)) } ?? .omitted
        let r = try await rpc.request(
            RpcMethod.ptySendText,
            [.value(.string(persistKey)), .value(.string(text)), enterArg]
        )
        return r.boolValue ?? false
    }

    // MARK: - Size ledger & PARK (§7.3)

    /// `pty:resize` CAST — a REPORT, not a command (SPEC §7.3). Both cols & rows nil ⇒ the PARK
    /// signal: literal JSON nulls (NOT listed in `undef`) that delete this viewer from the size
    /// ledger. `viewerId` is a trailing optional, omitted via `undef` when nil.
    public func resize(sessionId: String, cols: Int?, rows: Int?, viewerId: String?) async {
        // A present size is a real value; an absent one is a MEANINGFUL null (park) — `.null`, which
        // the codec emits as bare `null` and does NOT list in `undef` (SPEC §7.3 / §4.4). Never send
        // `0` (the server clamps it up to 1 — a 1-cell terminal for everyone).
        let colArg: RpcArg = cols.map { .value(.number(Double($0))) } ?? .null
        let rowArg: RpcArg = rows.map { .value(.number(Double($0))) } ?? .null
        let viewerArg: RpcArg = viewerId.map { .value(.string($0)) } ?? .omitted
        await rpc.cast(RpcMethod.ptyResize, [.value(.string(sessionId)), colArg, rowArg, viewerArg])
    }

    /// PARK convenience (SPEC §7.3): `resize(sessionId, nil, nil, viewerId)`. Send on
    /// background / off-screen / long rotation; re-send a real size on return.
    public func park(sessionId: String, viewerId: String?) async {
        await resize(sessionId: sessionId, cols: nil, rows: nil, viewerId: viewerId)
    }

    // MARK: - Close (§7.4)

    /// `pty:kill` CAST — detaches ONLY this viewer's `(clientId, viewerId)` slot (SPEC §7.4).
    /// `viewerId` MUST match the one used at `create`; a mismatch targets the connection's PRIMARY
    /// slot and silently LEAKS the real subscription. Never `destroy`/`recycle` in v0.
    public func kill(sessionId: String, viewerId: String?) async {
        let viewerArg: RpcArg = viewerId.map { .value(.string($0)) } ?? .omitted
        await rpc.cast(RpcMethod.ptyKill, [.value(.string(sessionId)), viewerArg])
    }

    // MARK: - Reads (§5.1 / §7.2)

    /// `pty:read-scrollback` REQ — persisted snapshot (≤256 KB) for a `fresh:true` cold replay;
    /// `""` if none (SPEC §7.2).
    public func readScrollback(persistKey: String) async throws -> String {
        let r = try await rpc.request(RpcMethod.ptyReadScrollback, [.value(.string(persistKey))])
        return r.stringValue ?? ""
    }

    /// `pty:capture` REQ — visible buffer (`full == true` → whole scrollback) (SPEC §5.1). `full`
    /// is a trailing optional, omitted via `undef` when nil.
    public func capture(persistKey: String, full: Bool?) async throws -> String {
        let fullArg: RpcArg = full.map { .value(.bool($0)) } ?? .omitted
        let r = try await rpc.request(RpcMethod.ptyCapture, [.value(.string(persistKey)), fullArg])
        return r.stringValue ?? ""
    }

    /// `pty:pane-command` REQ — pane foreground command; `nil` = unknown (SPEC §5.1).
    public func paneCommand(persistKey: String) async throws -> String? {
        let r = try await rpc.request(RpcMethod.ptyPaneCommand, [.value(.string(persistKey))])
        return r.isNull ? nil : r.stringValue
    }

    /// `pty:tmux-status` REQ — "tmux not found" banner data (SPEC §5.1 / §11.5).
    public func tmuxStatus() async throws -> TmuxStatus {
        let r = try await rpc.request(RpcMethod.ptyTmuxStatus, [])
        return try r.decoded(as: TmuxStatus.self)
    }

    // MARK: - Helpers

    /// Encode a Codable value to a `JSONValue` (reverse of `JSONValue.decoded(as:)`). Optional
    /// fields absent via the synthesized `encodeIfPresent` never appear.
    private func encodeToJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
