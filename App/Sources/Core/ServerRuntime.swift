import SwiftUI
import NodetermKit

/// The live per-server connection the UI observes (SPEC §8.1/§8.4: one RpcClient + stores per
/// server). Depends ONLY on Kit protocols — the concrete implementations are injected by `Factory`.
/// It owns the connect loop wiring: on `connected` it loads the workspace, subscribes the event
/// channels, and casts `presence:hello` (SPEC §11.8).
@MainActor
public final class ServerRuntime: ObservableObject, Identifiable {
    public let profile: ServerProfile
    // nonisolated: Identifiable's `id` is read from nonisolated generic code (ForEach); `profile`
    // is a let of a Sendable value type, so the read crosses no isolation boundary in practice.
    public nonisolated var id: String { profile.id }

    private let rpc: RpcClienting
    private let workspaceStore: WorkspaceStoring
    private let reducer: AgentStatusReducing
    public let terminal: TerminalSessionControlling
    /// Both dictation engines are held so the per-server toggle (SPEC §9.4/§9.5) resolves at
    /// dictation time; `speechTranscriber(_:)` picks. Apple is the default (SPEC §9.5).
    public let appleSpeech: SpeechTranscribing
    public let serverSpeech: SpeechTranscribing

    @Published public private(set) var connectionState: ConnectionState = .offline
    @Published public private(set) var workspace: Workspace?
    /// nodeId → reduced status, republished after every reducer fold (SPEC §6.3).
    @Published public private(set) var statuses: [String: AgentNodeStatus] = [:]
    /// Account rate-limit usage, forwarded from the desktop over `usage:update` (shown on the Home dashboard).
    @Published public private(set) var accountUsage: [AccountUsage] = []

    /// The session currently shown full-screen — its `onScreen` flag governs unread-setting (§6.3 #8).
    public var onScreenNodeId: String?

    /// Invoked (edge-triggered) when the connection reports `.authRequired` — the cookie is dead,
    /// so the owner should pause the reconnect loop and re-auth (SPEC §3.5 step 1) instead of
    /// letting the client hammer the dead cookie at the backoff cap forever.
    public var onAuthRequired: (() -> Void)?

    private var tasks: [Task<Void, Never>] = []
    /// Serializes the rpc.start()/rpc.stop() hops so a stop→start cycle (background→foreground,
    /// SPEC §8.4) can never execute out of order on the client actor.
    private var rpcLifecycle: Task<Void, Never>?
    private let deviceName: String

    public init(profile: ServerProfile,
                rpc: RpcClienting,
                workspaceStore: WorkspaceStoring,
                reducer: AgentStatusReducing,
                terminal: TerminalSessionControlling,
                appleSpeech: SpeechTranscribing,
                serverSpeech: SpeechTranscribing,
                deviceName: String) {
        self.profile = profile
        self.rpc = rpc
        self.workspaceStore = workspaceStore
        self.reducer = reducer
        self.terminal = terminal
        self.appleSpeech = appleSpeech
        self.serverSpeech = serverSpeech
        self.deviceName = deviceName
    }

    /// Resolve the transcriber for a chosen engine (SPEC §9.5).
    public func speechTranscriber(_ engine: AppSettings.SpeechEngine) -> SpeechTranscribing {
        engine == .serverWhisper ? serverSpeech : appleSpeech
    }

    /// The RPC client, exposed for the terminal VM (it needs the raw pty streams + subscriptions).
    public var rpcClient: RpcClienting { rpc }

    // MARK: Lifecycle

    /// Restartable (SPEC §8.4): backgrounding calls stop(), foregrounding calls start() again on
    /// the SAME runtime. Event channels are wired ONCE per run here — subscriptions are client-
    /// local fan-out that survives socket drops, so re-subscribing per `.connected` transition
    /// (as an earlier revision did) stacked a new decoder set on every reconnect.
    public func start() {
        guard tasks.isEmpty else { return }
        // The rpc hop is enqueued FIRST and every subscription awaits it: a still-queued stop()
        // from a background cycle finishes all client streams, so subscribing before the queued
        // stop→start pair has run would hand this run's subscriptions to the OLD run's teardown.
        enqueueRpc { await $0.start() }
        let ready = rpcLifecycle
        tasks.append(Task { await ready?.value; await self.observeConnection() })
        wireEvents(after: ready)
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        enqueueRpc { await $0.stop() }
        connectionState = .offline
    }

    /// Pause for re-auth (SPEC §3.5): same teardown as stop(), but the visible state stays
    /// `.authRequired` so the server row keeps showing "Sign in" instead of "Offline".
    public func pauseForAuth() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        enqueueRpc { await $0.stop() }
        connectionState = .authRequired
    }

    /// FIFO-chain a lifecycle hop onto the rpc actor (start/stop stay ordered across turns).
    private func enqueueRpc(_ op: @escaping @Sendable (RpcClienting) async -> Void) {
        let previous = rpcLifecycle
        rpcLifecycle = Task { [rpc] in
            await previous?.value
            await op(rpc)
        }
    }

    private func observeConnection() async {
        let states = await rpc.connectionStates()
        for await state in states {
            if Task.isCancelled { break }
            connectionState = state
            if state == .connected { await onConnected() }
            // Dead cookie (SPEC §3.5/§4.8.4): hand off to the owner ONCE — the owner pauses this
            // runtime (which ends this loop), so the edge cannot re-fire per backoff tick.
            if state == .authRequired { onAuthRequired?() }
        }
    }

    /// On (re)connect: announce presence and reload the workspace (SPEC §4.8 step 3 / §11.8).
    /// Event channels are NOT re-wired here — they are wired once per start() (subscriptions are
    /// client-local and survive a socket drop; §4.8's "re-subscribe" is about the wire).
    private func onConnected() async {
        await rpc.cast("presence:hello", PresenceHello.args(deviceName: deviceName))
        await reloadWorkspace()
        // SPEC §7.11: a spawn whose launch line or registration was cut off by a socket drop is
        // resumed here, on the runtime, whether or not its terminal view still exists. Runs until
        // the record is settled; `.unknown` (and an undelivered launch) re-run. Settled records are
        // retained but never re-driven (`SpawnRecord.needsDrive`).
        for (nodeId, record) in spawns where record.needsDrive {
            Task { await self.driveSpawn(nodeId: nodeId) }
        }
    }

    /// `workspace:load` → adopt the snapshot. Returns whether a FRESH snapshot was adopted: on
    /// `false` the previous snapshot is kept for display but is NOT evidence of anything — the
    /// §7.11.4 read-back must treat a failed load as UNKNOWN, never as "the node is absent".
    @discardableResult
    public func reloadWorkspace() async -> Bool {
        do {
            let result = try await rpc.request(RpcMethod.workspaceLoad, [])
            let ws = try result.decoded(as: Workspace.self)
            await workspaceStore.replace(with: ws)
            workspace = ws
            return true
        } catch {
            // A failed load is not fatal; keep the last snapshot. (Secrets never logged, §10.2.)
            return false
        }
    }

    // MARK: New-session spawn helpers (SPEC §7.11)

    /// Read `settings:load` for the new-session sheet (SPEC §7.11.3): managed accounts + the global
    /// permission mode. Tolerant — a failed/absent read returns nil and the sheet offers no accounts.
    public func loadSettings() async -> Settings? {
        guard let result = try? await rpc.request(RpcMethod.settingsLoad, []) else { return nil }
        return try? result.decoded(as: Settings.self)
    }

    /// Probe `claude-cli:caps` for the launch grammar (SPEC §7.11.3). Fail-closed: any failure →
    /// the all-false default, so `--permission-mode auto` is never emitted on a guess.
    public func loadClaudeCliCaps() async -> ClaudeCliCaps {
        guard let result = try? await rpc.request(RpcMethod.claudeCliCaps, []) else {
            return ClaudeCliCaps()
        }
        return (try? result.decoded(as: ClaudeCliCaps.self)) ?? ClaudeCliCaps()
    }

    /// Register a session the phone SPAWNED as a node on its project (SPEC §7.11.4). Returns the raw
    /// boolean the server answers — `false` is overloaded (permanent refusal vs. transient I/O), so
    /// the caller resolves a `false` with a `workspace:load` read-back. THROWS on a transport
    /// failure (`.disconnected` / `.timeout`) so the caller can tell "the server said no" from
    /// "the server was never asked" — the two must not both burn the bounded retry budget. The ONE
    /// scoped workspace write the phone may issue (`workspace:save` stays forbidden).
    public func registerNode(projectId: String, payload: JSONValue) async throws -> Bool {
        let res = try await rpc.request(RpcMethod.workspaceRegisterNode,
                                        [.value(.string(projectId)), .value(payload)])
        return res.boolValue == true
    }

    // MARK: Spawn drive: launch line + registration, owned by the RUNTIME (SPEC §7.11.3 / §7.11.4)

    /// Spawns keyed by node id (= persistKey). The state machine itself is `NodetermKit.SpawnRecord`
    /// (pure, unit-tested); this dictionary is its only home. Records are RETAINED once settled: a
    /// rejoin of a long-registered node must find its record and do nothing, not mint a pending one
    /// that re-registers the node and can raise the UNKNOWN banner on it.
    @Published public private(set) var spawns: [String: SpawnRecord] = [:]
    private var spawnDrivesInFlight: Set<String> = []
    private var spawnRedriveRequested: Set<String> = []

    /// Record a spawn as soon as a `pty:create` has answered for it — the session exists from that
    /// moment, whether or not the view that asked for it is still on screen. A no-op when a record
    /// already exists (two joins racing, a reconnect rejoin, a re-appearance): `SpawnRecord.recording`
    /// decides. `createFresh:false` on a node with NO record is the lost-first-answer path — the
    /// launch is still owed, gated through `pty:pane-command` so a running agent is never typed into.
    public func recordSpawn(nodeId: String, projectId: String, launch: PendingLaunch, createFresh: Bool) {
        spawns[nodeId] = SpawnRecord.recording(
            existing: spawns[nodeId], projectId: projectId,
            payload: NewSessionPlan.registerPayload(id: nodeId, title: launch.title,
                                                    agentId: launch.agentId, accountId: launch.accountId),
            command: launch.command, createFresh: createFresh, now: Date())
    }

    /// The view that watched the pane's first output saw 200 ms of quiet (SPEC §7.11.3): the launch
    /// may be typed now, instead of at the record's 1.5 s silence cap.
    public func markSpawnSettled(nodeId: String) {
        spawns[nodeId]?.markSettled(now: Date())
    }

    /// The banner the terminal shows for a spawned node (nil = pending / not a spawn of this phone /
    /// fully settled).
    public func spawnBanner(for nodeId: String) -> SpawnRecord.Banner? { spawns[nodeId]?.banner }

    /// Whether a spawn record already exists for this node — i.e. a `pty:create` has ALREADY answered
    /// for it. The §7.11.2 spawn branch keys off its ABSENCE (this fresh answer is the first create),
    /// so a reconnect whose lost first answer left no record is correctly treated as the spawn, not a
    /// cold restore.
    public func hasSpawnRecord(nodeId: String) -> Bool { spawns[nodeId] != nil }

    /// The Retry affordance behind the UNKNOWN and launch-undelivered banners.
    public func retrySpawn(nodeId: String) {
        Task { await self.driveSpawn(nodeId: nodeId) }
    }

    /// Retry a launch concluded `.dropped` (the "already busy" banner): re-arm the gated command and
    /// re-drive — the drive re-probes the pane once more, then delivers only into a bare shell.
    public func retryDroppedLaunch(nodeId: String) {
        spawns[nodeId]?.retryLaunch()
        Task { await self.driveSpawn(nodeId: nodeId) }
    }

    /// Dismiss the "already busy" banner (the session keeps running).
    public func dismissDroppedBanner(nodeId: String) {
        spawns[nodeId]?.acknowledgeDrop()
    }

    /// Run the spawn's remaining work, serialized per node: a second caller while one drive is in
    /// flight requests a re-run instead of racing it. The settle wait lives on the RECORD
    /// (`SpawnRecord.notBefore`), so whoever drives — the view after its quiet observation, a blind
    /// off-screen caller, an `onConnected` re-drive — honors the same window.
    public func driveSpawn(nodeId: String) async {
        guard spawns[nodeId] != nil else { return }
        if spawnDrivesInFlight.contains(nodeId) { spawnRedriveRequested.insert(nodeId); return }
        spawnDrivesInFlight.insert(nodeId)
        repeat {
            spawnRedriveRequested.remove(nodeId)
            await driveSpawnOnce(nodeId: nodeId)
        } while spawnRedriveRequested.contains(nodeId)
        spawnDrivesInFlight.remove(nodeId)
        // A launch that stayed undelivered (`.deferred`) gets ONE delayed redelivery on the runtime's
        // own initiative — not just the next socket drop. Still gated by the pane check. If that one
        // fails too, `SpawnRecord.banner` turns `.launchUndelivered` and Retry takes over.
        //
        // A launch whose FIRST pane check said "busy" (a provisional `.dropped`) gets ONE re-probe
        // after a short delay before the drop is concluded — the initial "busy" can be a transient
        // rc-file child, gone a second later. The two are mutually exclusive per drive (a provisional
        // drop counts no attempt, so `scheduleRedelivery` is false there), but arm at most one anyway.
        if spawns[nodeId]?.scheduleRedelivery() == true {
            Task {
                try? await Task.sleep(for: .seconds(SpawnRecord.redeliveryDelay))
                await self.driveSpawn(nodeId: nodeId)
            }
        } else if spawns[nodeId]?.scheduleDropReprobe() == true {
            Task {
                try? await Task.sleep(for: .seconds(SpawnRecord.reprobeDelay))
                await self.driveSpawn(nodeId: nodeId)
            }
        }
    }

    private func driveSpawnOnce(nodeId: String) async {
        // Every step below is gated on a live socket; while disconnected, do NOTHING — `onConnected`
        // re-drives. Retrying into a dead socket would only burn the bounded register budget.
        guard await rpc.connectionState() == .connected else { return }

        // 1. The launch line (SPEC §7.11.3), not before the record's settle window has passed.
        launch: while true {
            guard let record = spawns[nodeId] else { return }
            switch record.launchStep(now: Date()) {
            case .nothing:
                break launch
            case .wait:
                // Poll, do not sleep to the deadline: `markSpawnSettled` may shorten the window.
                try? await Task.sleep(for: .milliseconds(40))
            case .deliver(let command, let checkPane):
                guard await rpc.connectionState() == .connected else { return }
                let delivery = await deliverLaunch(nodeId: nodeId, command: command, checkPane: checkPane)
                spawns[nodeId]?.apply(delivery: delivery)
                if delivery == .transient { return }   // socket gone mid-call — the reconnect re-drives both halves
                break launch
            }
        }

        // 2. Registration (SPEC §7.11.4). Steps 1 and 2 are independent on purpose.
        guard let record = spawns[nodeId], record.registrationPending else { return }
        for attempt in 0..<4 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(300))
                guard await rpc.connectionState() == .connected else { return }
            }
            do {
                if try await registerNode(projectId: record.projectId, payload: record.payload) {
                    // No canvas:mut / external-change subscription picks this up (SPEC §7.11.5), so
                    // reload so the phone's own Home list shows the new node.
                    await reloadWorkspace()
                    spawns[nodeId]?.apply(registration: .registered)
                    return
                }
            } catch let err as RpcError where err == .disconnected || err == .timeout {
                // A gone socket (or a `.timeout` on a dropping one) was never answered: leave pending,
                // re-drive on reconnect. A `.timeout` on a LIVE socket reached the server — fall
                // through to the read-back like an E_HANDLER refusal, so the outcome still resolves
                // (mapping it to a bare `return` armed nothing and stranded the node UNKNOWN forever).
                let connected = await rpc.connectionState() == .connected
                if SpawnTransportFault.classify(error: err, stillConnected: connected) == .socketGone {
                    return
                }
            } catch {
                // E_NO_HANDLER / E_HANDLER: the server answered and refused — counts like a `false`.
            }
        }
        // Read-back. A failed load is UNKNOWN, never evidence (RegistrationOutcome's table).
        let loaded = await reloadWorkspace()
        spawns[nodeId]?.apply(registration: RegistrationOutcome.decide(
            workspace: workspace, loadSucceeded: loaded, projectId: record.projectId, nodeId: nodeId))
    }

    /// `pty:send-text` the launch line, checking BOTH the throw and the Bool (SPEC §7.6/§7.11.3). A
    /// gated delivery first asks `pty:pane-command`: only a bare shell may receive it, so a launch is
    /// never typed twice into an agent that is already running.
    private func deliverLaunch(nodeId: String, command: String, checkPane: Bool) async -> SpawnRecord.Delivery {
        if checkPane {
            let pane: String?
            do {
                pane = try await terminal.paneCommand(persistKey: nodeId)
            } catch let err as RpcError where err == .disconnected || err == .timeout {
                return await deliveryFault(err)
            } catch {
                return .deferred
            }
            switch LaunchRedelivery.decide(paneCommand: pane) {
            case .alreadyRunning: return .dropped
            case .unknown: return .deferred
            case .send: break
            }
        }
        do {
            return try await terminal.sendText(persistKey: nodeId, text: command, enter: true) ? .landed : .deferred
        } catch let err as RpcError where err == .disconnected || err == .timeout {
            return await deliveryFault(err)
        } catch {
            return .deferred
        }
    }

    /// A `.disconnected` / `.timeout` from a spawn RPC → the delivery outcome. A live-socket deadline
    /// (`.timeout` while still `.connected`) is a REAL gated attempt (`.deferred`): it reached the
    /// server, so it counts and can arm the one delayed redelivery — mapping it to `.transient` armed
    /// NOTHING and left the launch permanently owed with no re-drive until the next socket drop. A
    /// gone socket stays `.transient` (the reconnect re-drives it). `SpawnTransportFault` decides.
    private func deliveryFault(_ err: RpcError) async -> SpawnRecord.Delivery {
        let connected = await rpc.connectionState() == .connected
        return SpawnTransportFault.classify(error: err, stillConnected: connected) == .socketGone
            ? .transient : .deferred
    }

    private func wireEvents(after ready: Task<Void, Never>?) {
        subscribe("agent:status", after: ready) { [weak self] args in
            guard let self, let first = args.first,
                  let event = try? first.decoded(as: AgentStatusEvent.self) else { return }
            let onScreen = (self.onScreenNodeId == event.nodeId)
            await self.reducer.ingest(event, onScreen: onScreen)
            await self.republishStatuses()
        }
        subscribe("context:update", after: ready) { [weak self] args in
            guard let self, let first = args.first,
                  let usage = try? first.decoded(as: ContextWindowUsage.self) else { return }
            await self.reducer.ingestContext(usage)
            await self.republishStatuses()
        }
        subscribe("agent:unread-clear", after: ready) { [weak self] args in
            guard let self, let nodeId = args.first?.stringValue else { return }
            await self.reducer.clearUnread(nodeId: nodeId)   // clear WITHOUT re-acking (§6.3 #8)
            await self.republishStatuses()
        }
        subscribe("accounts:usage", after: ready) { [weak self] args in
            guard let self, let first = args.first,
                  let update = try? first.decoded(as: AccountUsageUpdate.self) else { return }
            self.accountUsage = update.accounts   // desktop-authoritative snapshot; render as-is
        }
        subscribe("canvas:mut", after: ready) { [weak self] args in
            guard let self, args.count >= 2, let projectId = args[0].stringValue,
                  let mut = try? args[1].decoded(as: CanvasMutation.self) else { return }
            await self.workspaceStore.apply(mut, projectId: projectId)
            self.workspace = await self.workspaceStore.snapshot()
        }
    }

    private func subscribe(_ channel: String, after ready: Task<Void, Never>?,
                           _ handler: @escaping @MainActor @Sendable ([JSONValue]) async -> Void) {
        tasks.append(Task { [rpc] in
            await ready?.value   // never subscribe past a still-queued stop() (see start())
            let stream = await rpc.subscribe(channel)
            for await args in stream {
                if Task.isCancelled { break }
                await handler(args)   // @MainActor handler runs on main; safe to touch @Published state
            }
        })
    }

    private func republishStatuses() async {
        let all = await reducer.all()
        statuses = Dictionary(uniqueKeysWithValues: all.map { ($0.nodeId, $0) })
    }

    // MARK: UI-facing helpers

    public func status(for nodeId: String) -> AgentNodeStatus? { statuses[nodeId] }

    /// The HOME session rows for this server (SPEC §9.1).
    public var sessionRows: [SessionRow] {
        SessionListModel.rows(serverId: profile.id, serverName: profile.name,
                              workspace: workspace) { statuses[$0] }
    }

    /// Answer a held approval (SPEC §5.3 / §6.2). Only valid on a `pendingId` row.
    public func answerPermission(nodeId: String, pendingId: String, decision: PermissionDecision) async {
        let request = AnswerPermissionRequest(nodeId: nodeId, pendingId: pendingId, decision: decision)
        guard let arg = try? JSONValue.encoding(request) else { return }
        _ = try? await rpc.request(RpcMethod.agentAnswerPermission, [.value(arg)])
        // The server broadcasts a synthetic agent:status that clears the NEEDS-YOU badge (§5.3).
    }

    /// The user viewed a session: clear unread, and ack a finished (`done`) node (SPEC §5.3/§6.3 #8).
    public func markViewed(nodeId: String) async {
        let shouldAck = await reducer.markViewed(nodeId: nodeId)
        await republishStatuses()
        if shouldAck {
            _ = try? await rpc.request(RpcMethod.agentAckDone, [.value(.string(nodeId))])
        }
    }
}
