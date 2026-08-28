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
    /// Account rate-limit usage, forwarded from the desktop over `usage:update` (Settings → Usage).
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
    }

    public func reloadWorkspace() async {
        do {
            let result = try await rpc.request(RpcMethod.workspaceLoad, [])
            let ws = try result.decoded(as: Workspace.self)
            await workspaceStore.replace(with: ws)
            workspace = ws
        } catch {
            // A failed load is not fatal; keep the last snapshot. (Secrets never logged, §10.2.)
        }
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
        subscribe("usage:update", after: ready) { [weak self] args in
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
