import SwiftUI
import NodetermKit

/// Per-open-terminal view-model implementing the co-attach VIEWER contract (SPEC §7). It never
/// performs owner actions (destroy/recycle/flow — SPEC §7.4/§7.9). Drives seed paint, the size
/// ledger + PARK, input routing, passive close events, and reconnect re-attach.
@MainActor
public final class TerminalSessionVM: ObservableObject {

    public enum Phase: Equatable {
        case connecting
        case ready
        case closed(by: Int?)        // pty:closed — permanently destroyed elsewhere (SPEC §7.5)
        case unavailable(String)     // 'ssh' | 'codex-account' (SPEC §11.5)
        case exited(Int)             // pty:exit
    }

    let runtime: ServerRuntime
    let row: SessionRow
    public let handle = TerminalHandle()

    // Captured once from the runtime so detached Tasks capture Sendable values, never read
    // @MainActor properties off-actor.
    private let rpc: RpcClienting
    private let control: TerminalSessionControlling

    /// Unique within THIS connection (SPEC §7.1). Reused on reconnect re-attach.
    private let viewerId = UUID().uuidString

    @Published public private(set) var phase: Phase = .connecting
    @Published public private(set) var sessionId: String = ""
    @Published public var ctrlLatched = false
    @Published public private(set) var persistent: Bool? = nil

    private var tasks: [Task<Void, Never>] = []
    /// The in-flight join (pty:create) — tracked so onDisappear can cancel it, and so a create
    /// that resolves AFTER dismissal still kills its own viewer (SPEC §7.3/§7.4: an unkilled
    /// phone viewer stays in the size ledger and clamps the desktop's grid).
    private var joinTask: Task<Void, Never>?
    /// Set by onDisappear; a join that resolves afterwards must register nothing (SPEC §7.4).
    private var tornDown = false
    private var lastCols = 0
    private var lastRows = 0
    private var didCreate = false
    private var connectionObserver: Task<Void, Never>?

    public init(runtime: ServerRuntime, row: SessionRow) {
        self.runtime = runtime
        self.row = row
        self.rpc = runtime.rpcClient
        self.control = runtime.terminal
    }

    private var persistKey: String { row.nodeId }

    /// Whether this node's project is SSH (SPEC §7.1: pass `requireRemote` so the server refuses a
    /// phantom local shell — the Server Edition can't reach SSH hosts, §11.2).
    private var isSSHProject: Bool {
        runtime.workspace?.projects.first { $0.id == row.projectId }?.isSSH ?? false
    }

    // MARK: Lifecycle

    /// Called on view appear (SPEC §9.3: join on appear + mark viewed).
    public func onAppear(initialCols: Int, initialRows: Int) {
        runtime.onScreenNodeId = row.nodeId
        Task { await runtime.markViewed(nodeId: row.nodeId) }   // clears unread + acks done (§6.3 #8)
        lastCols = max(initialCols, 1); lastRows = max(initialRows, 1)
        tornDown = false
        observeReconnect()
        joinTask = Task { await join(isReconnect: false) }
    }

    /// Called on view disappear: kill ONLY this viewer (SPEC §7.4).
    public func onDisappear() {
        if runtime.onScreenNodeId == row.nodeId { runtime.onScreenNodeId = nil }
        tornDown = true
        connectionObserver?.cancel(); connectionObserver = nil
        joinTask?.cancel(); joinTask = nil
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        let sid = sessionId, vid = viewerId
        if !sid.isEmpty {
            Task { [control] in await control.kill(sessionId: sid, viewerId: vid) }
        }
        // A create still in flight is handled by join()'s post-create check: it sends the kill
        // itself once the sessionId is known (SPEC §7.4).
    }

    /// App → background OR view off-screen kept warm (SPEC §7.3): PARK, do not kill.
    public func park() {
        guard !sessionId.isEmpty else { return }
        let sid = sessionId, vid = viewerId
        Task { [control] in await control.park(sessionId: sid, viewerId: vid) }
    }

    /// Return from background: report a real size again (SPEC §7.3).
    public func unpark() {
        reportSize(cols: lastCols, rows: lastRows, force: true)
    }

    // MARK: Join / seed paint (SPEC §7.1/§7.2)

    private func join(isReconnect: Bool) async {
        let options = PtyCreateOptions(
            cols: lastCols, rows: lastRows,
            persistKey: persistKey, viewerId: viewerId,
            cwd: row.cwd, ownerProjectId: row.projectId,
            agentId: row.agentId, accountId: row.accountId,
            requireRemote: isSSHProject ? true : nil)   // §7.1 refuse-phantom-shell for SSH nodes

        let result: PtyCreateResult
        do { result = try await control.create(options) } catch {
            phase = .unavailable("Couldn't attach"); return
        }

        // Refusals come back IN-BAND, not as errors (SPEC §5.1/§7.2 step 1).
        if let closed = result.closed { phase = .closed(by: closed.by); return }
        if let reason = result.unavailable { phase = .unavailable(reason); return }

        // The view was dismissed while pty:create was in flight: the viewer WAS registered
        // server-side, so kill it immediately instead of wiring streams for a dead VM (SPEC §7.4).
        if tornDown {
            let vid = viewerId
            let sid = result.sessionId
            if !sid.isEmpty { Task { [control] in await control.kill(sessionId: sid, viewerId: vid) } }
            return
        }

        sessionId = result.sessionId
        persistent = result.persistent
        guard !sessionId.isEmpty else { phase = .unavailable("No session"); return }

        // Cold start (SPEC §7.2 step 2): fetch the persisted snapshot for replay.
        var scrollback: String? = nil
        if result.fresh {
            scrollback = try? await control.readScrollback(persistKey: persistKey)
        }

        handle.apply(SeedPaint.plan(result: result, scrollback: scrollback, isReconnect: isReconnect))

        subscribeStreams()
        reportSize(cols: lastCols, rows: lastRows, force: true)   // §7.3 initial local fit
        phase = .ready
        didCreate = true
    }

    // MARK: Event streams (SPEC §6.1/§7.5/§7.8)

    private func subscribeStreams() {
        let sid = sessionId
        // Live output (binary → decoded) — feed verbatim.
        tasks.append(Task { [handle, rpc] in
            let stream = await rpc.ptyData(for: sid)
            for await data in stream {
                if Task.isCancelled { break }
                await handle.apply([.feedRaw(data)])
            }
        })
        subscribeEv("pty:size:\(sid)") { [weak self] args in
            guard let self, let obj = args.first,
                  let grid = try? obj.decoded(as: PtyGrid.self) else { return }
            self.handle.applyGrid(cols: grid.cols, rows: grid.rows)   // authoritative (§7.3)
        }
        subscribeEv("pty:resync:\(sid)") { [weak self] args in
            guard let self, let text = args.first?.stringValue else { return }
            self.handle.apply(SeedPaint.planResync(text))             // reset+repaint, ignore empty (§7.8)
        }
        subscribeEv("pty:exit:\(sid)") { [weak self] args in
            let code = args.first?["exitCode"]?.intValue ?? args.first?.intValue ?? 0
            self?.phase = .exited(code)
        }
        subscribeEv("pty:closed:\(sid)") { [weak self] args in
            self?.phase = .closed(by: args.first?["by"]?.intValue)
        }
        subscribeEv("pty:recycled:\(sid)") { [weak self] args in
            guard let self else { return }
            let ready = args.first?["ready"]?.boolValue ?? false
            if ready { Task { await self.rejoin() } }                 // re-attach replacement (§7.5)
        }
    }

    private func subscribeEv(_ channel: String,
                             _ handler: @escaping @MainActor @Sendable ([JSONValue]) -> Void) {
        tasks.append(Task { [rpc] in
            let stream = await rpc.subscribe(channel)
            for await args in stream {
                if Task.isCancelled { break }
                await handler(args)   // @MainActor handler hops to main
            }
        })
    }

    // MARK: Reconnect (SPEC §4.8 step 3)

    private func observeReconnect() {
        connectionObserver = Task { [weak self, rpc] in
            let states = await rpc.connectionStates()
            for await state in states {
                if Task.isCancelled { break }
                guard let self else { break }
                if state == .connected, await self.didCreateFlag {
                    await self.rejoin()   // re-issue pty:create, reset-before-paint (SPEC §4.8 step 3)
                }
            }
        }
    }

    /// `didCreate` read hopped to the main actor (the observer Task is not main-isolated).
    private var didCreateFlag: Bool { didCreate }

    private func rejoin() async {
        guard !tornDown else { return }
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        await join(isReconnect: true)
    }

    // MARK: Input (SPEC §7.6)

    /// Raw keystrokes (already Ctrl-transformed by the emulator coordinator) → `pty:write` CAST.
    /// SwiftTerm's system paste paths (long-press Paste, hardware ⌘V) ALSO deliver here, as the
    /// whole blob — so anything carrying `\n` is routed through the framed `pty:send-text` path
    /// via `TerminalInputRouting` (SPEC §7.6 MUST: multi-line paste never rides a raw pty:write,
    /// which would submit once per line in agent CLIs). Never auto-submits (`enter:false`).
    public func write(_ data: Data) {
        guard !sessionId.isEmpty else { return }
        let sid = sessionId, pkey = persistKey
        let text = String(decoding: data, as: UTF8.self)
        switch TerminalInputRouting.delivery(for: .keystroke(text)) {
        case .write(let raw):
            Task { [control] in await control.write(sessionId: sid, data: raw) }
        case .sendText(let framed, let enter):
            Task { [control] in _ = try? await control.sendText(persistKey: pkey, text: framed, enter: enter) }
        }
    }

    /// A literal control/escape string (toolbar keys) → `pty:write` CAST.
    public func writeRaw(_ text: String) {
        guard !sessionId.isEmpty else { return }
        let sid = sessionId
        Task { [control] in await control.write(sessionId: sid, data: text) }
    }

    /// Shift+Enter → ESC+CR so agent CLIs insert a newline instead of submitting (SPEC §7.6).
    public func sendShiftEnter() { writeRaw(NodetermWire.shiftEnterSeq) }

    /// Any paste / composed / dictated block → framed `pty:send-text` (SPEC §7.6). Never a raw
    /// multi-line `pty:write`. `enter:false` for paste/insert, `true` to submit.
    public func sendText(_ text: String, submit: Bool) async {
        _ = try? await control.sendText(persistKey: persistKey, text: text, enter: submit)
    }

    /// Paste from the device clipboard (SPEC §9.3: `⌘V` → send-text, enter:false).
    public func pasteFromClipboard(_ text: String) {
        Task { await sendText(text, submit: false) }
    }

    // MARK: Size ledger (SPEC §7.3)

    public func reportSize(cols: Int, rows: Int, force: Bool = false) {
        let c = max(cols, 1), r = max(rows, 1)
        guard force || c != lastCols || r != lastRows else { return }
        lastCols = c; lastRows = r
        guard !sessionId.isEmpty else { return }
        let sid = sessionId, vid = viewerId
        Task { [control] in await control.resize(sessionId: sid, cols: c, rows: r, viewerId: vid) }
    }

    // MARK: Clipboard (SPEC §7.7)

    /// OSC 52 write → device clipboard (write-only). Handled here so the App owns `UIPasteboard`.
    public func onClipboardWrite(_ text: String) {
        ClipboardBridge.write(text)
    }
}
