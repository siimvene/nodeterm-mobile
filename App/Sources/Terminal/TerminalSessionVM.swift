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

    /// Unique within THIS connection (SPEC §7.1). Reused on reconnect re-attach, REGENERATED for a
    /// fresh appearance: `onDisappear` queues its kill on the outbound chain while a new `join`'s
    /// `pty:create` takes the independent request path, so with one immutable id the old kill can
    /// land after the new create and detach the viewer that just attached.
    private var viewerId = UUID().uuidString

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
    /// TRUE between onAppear and onDisappear: this VM already holds a live attach (join in flight
    /// or streams subscribed). SwiftUI can fire `.onAppear` again WITHOUT a matching
    /// `.onDisappear` — dismissing a sheet (dictation, transcript) does exactly that — and a
    /// second join would leave the first one's subscriptions running (see `onAppear`).
    private var attached = false
    private var lastCols = 0
    private var lastRows = 0
    private var didCreate = false
    /// The session is KNOWN dead (pty:closed, or recycle with ready:false) — no reconnect may
    /// re-create it (consort finding #8). Split from didCreate so a TRANSIENT initial-attach
    /// failure still retries on the next reconnect (consort finding #13).
    private var permanentlyClosed = false
    private var attemptedJoin = false
    /// Bumped by every attach trigger (a fresh appearance, a reconnect rejoin). `join` carries the
    /// generation it started under and abandons itself after any `await` that a newer attach won:
    /// two joins in flight is not hypothetical (see `observeReconnect`), and the loser must not
    /// paint a stale seed, subscribe, or cancel the winner's streams on its way out.
    private var attachGeneration = 0
    /// Outbound op chain (consort finding): writes/resizes/park/kill each used to spawn an
    /// independent Task, and unstructured tasks carry no ordering guarantee — rapid keystrokes
    /// could reach the actor out of order. Every outbound op now appends to ONE chain.
    private var outboundTail: Task<Void, Never> = Task {}

    private func enqueueOutbound(_ op: @escaping @Sendable () async -> Void) {
        let prev = outboundTail
        outboundTail = Task {
            await prev.value
            await op()
        }
    }
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
        // A RE-APPEAR IS NOT A NEW ATTACH. SwiftUI fires `.onAppear` on the presenter again when a
        // sheet is dismissed, with no `.onDisappear` in between, so the previous attach is still
        // fully live. Joining twice leaves TWO `pty:data` subscriptions feeding ONE emulator
        // (`RpcClient.ptyData` fans out per subscriber, it does not share one stream): every byte
        // is painted twice (typing `claude` shows `ccllaauuddee` while the pty still receives one
        // copy, so the command runs), and every DA / DSR / XTWINOPS query is answered twice — the
        // second reply nobody is reading lands on the shell prompt as literal text
        // (`zsh: command not found: 47`).
        //
        // Do NOTHING on a duplicate: `initialCols/Rows` is the GeometryReader's crude estimate,
        // and the emulator has since refined `lastCols/lastRows` through `sizeChanged`. Writing
        // the estimate back and force-reporting it would shrink the pty for every co-attached
        // viewer (the pty runs at the min of the ledger).
        guard !attached else { return }
        attached = true
        tornDown = false
        lastCols = max(initialCols, 1); lastRows = max(initialRows, 1)
        viewerId = UUID().uuidString
        // The previous appearance's session id is not ours: until the new `pty:create` answers,
        // a `reportSize`/`park`/`write` would address (old session, new viewer). Everything on
        // those paths early-returns on an empty id, so clearing is the whole fix.
        sessionId = ""
        attachGeneration += 1
        let gen = attachGeneration
        observeReconnect()
        joinTask = Task { await join(isReconnect: false, gen: gen) }
    }

    /// Called on view disappear: kill ONLY this viewer (SPEC §7.4).
    public func onDisappear() {
        if runtime.onScreenNodeId == row.nodeId { runtime.onScreenNodeId = nil }
        tornDown = true
        attached = false
        // Teardown is an attach transition like any other. Without this bump a join suspended in
        // `readScrollback` resumes with a generation that still matches, then paints, subscribes
        // and re-reports size for a view that is gone — live streams off-screen and a killed
        // viewer back in the size ledger.
        attachGeneration += 1
        connectionObserver?.cancel(); connectionObserver = nil
        joinTask?.cancel(); joinTask = nil
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        let sid = sessionId, vid = viewerId
        if !sid.isEmpty {
            enqueueOutbound { [control] in await control.kill(sessionId: sid, viewerId: vid) }
        }
        // A create still in flight is handled by join()'s post-create check: it sends the kill
        // itself once the sessionId is known (SPEC §7.4).
    }

    /// App → background OR view off-screen kept warm (SPEC §7.3): PARK, do not kill.
    public func park() {
        guard !sessionId.isEmpty else { return }
        let sid = sessionId, vid = viewerId
        enqueueOutbound { [control] in await control.park(sessionId: sid, viewerId: vid) }
    }

    /// Return from background: report a real size again (SPEC §7.3).
    public func unpark() {
        reportSize(cols: lastCols, rows: lastRows, force: true)
    }

    // MARK: Join / seed paint (SPEC §7.1/§7.2)

    private func join(isReconnect: Bool, gen: Int) async {
        attemptedJoin = true
        guard !permanentlyClosed else { return }
        // The id THIS create registers. Read once: a fresh appearance mints a new one, so reading
        // `viewerId` again after the await could clean up (or kill) the wrong viewer.
        let vid = viewerId
        let options = PtyCreateOptions(
            cols: lastCols, rows: lastRows,
            persistKey: persistKey, viewerId: vid,
            // Project-cwd fallback (consort finding): a cold spawn of a cwd-less node must land
            // in the project folder, not the server's $HOME — under the REAL persistent node id.
            cwd: row.cwd ?? row.projectCwd, ownerProjectId: row.projectId,
            agentId: row.agentId, accountId: row.accountId,
            // §7.1 refuse-phantom-shell: node-level sshRemoteTmux counts, not just the project
            // (consort finding — a remote-tmux node can live in a non-SSH project).
            requireRemote: (isSSHProject || row.sshRemoteTmux) ? true : nil)

        let result: PtyCreateResult
        do { result = try await control.create(options) } catch {
            guard gen == attachGeneration else { return }
            phase = .unavailable("Couldn't attach"); return
        }
        // A newer attach (or a teardown) took over while `pty:create` was in flight. The create
        // still REGISTERED this viewer server-side and nobody else will ever detach it: a
        // teardown could not (our `sessionId` was still empty when it ran) and a fresh appearance
        // holds a DIFFERENT id. Kill it here or it sits in the size ledger clamping every
        // co-attached viewer's grid. Only when the id differs from the one now in force — a
        // RECONNECT loser reuses the same id, and killing that would detach the winner.
        guard gen == attachGeneration else {
            let sid = result.sessionId
            if !sid.isEmpty, vid != viewerId {
                enqueueOutbound { [control] in await control.kill(sessionId: sid, viewerId: vid) }
            }
            return
        }

        // Refusals come back IN-BAND, not as errors (SPEC §5.1/§7.2 step 1).
        // As permanent as the `pty:closed` event: the session is GONE, so a later reconnect must
        // not re-issue `pty:create` and spawn an unintended replacement. In-band `unavailable`
        // stays retryable — that one is about WHERE the session can run, not whether it exists.
        if let closed = result.closed {
            permanentlyClosed = true
            phase = .closed(by: closed.by); return
        }
        if let reason = result.unavailable { phase = .unavailable(reason); return }

        // The view was dismissed while pty:create was in flight: the viewer WAS registered
        // server-side, so kill it immediately instead of wiring streams for a dead VM (SPEC §7.4).
        if tornDown {
            let sid = result.sessionId
            if !sid.isEmpty { enqueueOutbound { [control] in await control.kill(sessionId: sid, viewerId: vid) } }
            return
        }

        sessionId = result.sessionId
        persistent = result.persistent
        guard !sessionId.isEmpty else { phase = .unavailable("No session"); return }

        // Cold start (SPEC §7.2 step 2): fetch the persisted snapshot for replay.
        var scrollback: String? = nil
        if result.fresh {
            scrollback = try? await control.readScrollback(persistKey: persistKey)
            guard gen == attachGeneration else { return }
        }

        handle.apply(SeedPaint.plan(result: result, scrollback: scrollback, isReconnect: isReconnect))

        subscribeStreams()
        reportSize(cols: lastCols, rows: lastRows, force: true)   // §7.3 initial local fit
        phase = .ready
        didCreate = true
    }

    // MARK: Event streams (SPEC §6.1/§7.5/§7.8)

    private func subscribeStreams() {
        // Belt and braces under the generation check, not instead of it. This is the LAST step of
        // every join path, so clearing here means the VM cannot hold two `pty:data` subscriptions
        // even if some future path reaches a join without a generation. (The VM is `@MainActor` and
        // this function has no suspension point, so nothing can append between the clear and the
        // appends below.) A cancelled stream task drops its next element instead of feeding it.
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
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
            guard let self else { return }
            self.phase = .closed(by: args.first?["by"]?.intValue)
            // The session is GONE: a later reconnect must not re-issue pty:create for it —
            // that would spawn an unintended replacement (consort finding).
            self.permanentlyClosed = true
        }
        subscribeEv("pty:recycled:\(sid)") { [weak self] args in
            guard let self else { return }
            let ready = args.first?["ready"]?.boolValue ?? false
            if ready {
                Task { await self.rejoin() }                          // re-attach replacement (§7.5)
            } else {
                // ready:false = no replacement ever came (SPEC §7.5) — same latch as closed.
                self.phase = .unavailable("Session ended")
                self.permanentlyClosed = true
            }
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
        // Assigning over a live observer would leak it: the old Task keeps running and fires its
        // own `rejoin()` alongside the new one's.
        connectionObserver?.cancel()
        connectionObserver = Task { [weak self, rpc] in
            let states = await rpc.connectionStates()
            // `connectionStates()` hands a FRESH observer the current state immediately — the first
            // value is a snapshot, not a transition. Acting on it fired `rejoin()` on top of the
            // very join `onAppear` had just started (`join` sets `attemptedJoin` before its first
            // await, so the flag is already true by the time the snapshot arrives): two concurrent
            // `pty:create`s on every single open, and — before `subscribeStreams` learned to clear
            // — two live `pty:data` subscriptions painting every byte twice. Only a RECONNECT, a
            // `.connected` that FOLLOWS a non-connected state, is a reason to re-attach.
            var sawDisconnect = false
            for await state in states {
                if Task.isCancelled { break }
                guard let self else { break }
                guard state == .connected else { sawDisconnect = true; continue }
                guard sawDisconnect else { continue }
                sawDisconnect = false
                // Retry on reconnect whenever an attach was ATTEMPTED and the session is not
                // known-dead — a transient initial-create failure must heal on the next socket,
                // not stay "Couldn't attach" until remount (consort finding #13).
                if await self.shouldRejoinFlag {
                    await self.rejoin()   // re-issue pty:create, reset-before-paint (SPEC §4.8 step 3)
                }
            }
        }
    }

    /// `didCreate` read hopped to the main actor (the observer Task is not main-isolated).
    private var didCreateFlag: Bool { didCreate }
    private var shouldRejoinFlag: Bool { attemptedJoin && !permanentlyClosed }

    private func rejoin() async {
        guard !tornDown, attached else { return }
        attachGeneration += 1
        let gen = attachGeneration
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        await join(isReconnect: true, gen: gen)
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
            enqueueOutbound { [control] in await control.write(sessionId: sid, data: raw) }
        case .sendText(let framed, let enter):
            enqueueOutbound { [control] in _ = try? await control.sendText(persistKey: pkey, text: framed, enter: enter) }
        }
    }

    /// A literal control/escape string (toolbar keys) → `pty:write` CAST.
    public func writeRaw(_ text: String) {
        guard !sessionId.isEmpty else { return }
        let sid = sessionId
        enqueueOutbound { [control] in await control.write(sessionId: sid, data: text) }
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
        enqueueOutbound { [control] in await control.resize(sessionId: sid, cols: c, rows: r, viewerId: vid) }
    }

    // MARK: Clipboard (SPEC §7.7)

    /// OSC 52 write → device clipboard (write-only). Handled here so the App owns `UIPasteboard`.
    public func onClipboardWrite(_ text: String) {
        ClipboardBridge.write(text)
    }
}
