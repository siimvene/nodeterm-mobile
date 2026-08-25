import SwiftUI
import NodetermKit

/// The live per-server connection the UI observes (SPEC §8.1/§8.4: one RpcClient + stores per
/// server). Depends ONLY on Kit protocols — the concrete implementations are injected by `Factory`.
/// It owns the connect loop wiring: on `connected` it loads the workspace, subscribes the event
/// channels, and casts `presence:hello` (SPEC §11.8).
@MainActor
public final class ServerRuntime: ObservableObject, Identifiable {
    public let profile: ServerProfile
    public var id: String { profile.id }

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

    /// The session currently shown full-screen — its `onScreen` flag governs unread-setting (§6.3 #8).
    public var onScreenNodeId: String?

    private var tasks: [Task<Void, Never>] = []
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

    public func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { await self.observeConnection() })
        Task { [rpc] in await rpc.start() }
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        Task { [rpc] in await rpc.stop() }
        connectionState = .offline
    }

    private func observeConnection() async {
        let states = await rpc.connectionStates()
        for await state in states {
            connectionState = state
            if state == .connected { await onConnected() }
        }
    }

    /// On (re)connect: load the workspace, wire the event channels, announce presence (SPEC §4.8
    /// step 3 / §11.8). Idempotent-safe: subscriptions replay the early-event buffer to the first
    /// subscriber (§4.9), and re-subscribing after a drop is expected.
    private func onConnected() async {
        await rpc.cast("presence:hello", PresenceHello.args(deviceName: deviceName))
        await reloadWorkspace()
        wireEvents()
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

    private func wireEvents() {
        subscribe("agent:status") { [weak self] args in
            guard let self, let first = args.first,
                  let event = try? first.decoded(as: AgentStatusEvent.self) else { return }
            let onScreen = (self.onScreenNodeId == event.nodeId)
            await self.reducer.ingest(event, onScreen: onScreen)
            await self.republishStatuses()
        }
        subscribe("context:update") { [weak self] args in
            guard let self, let first = args.first,
                  let usage = try? first.decoded(as: ContextWindowUsage.self) else { return }
            await self.reducer.ingestContext(usage)
            await self.republishStatuses()
        }
        subscribe("agent:unread-clear") { [weak self] args in
            guard let self, let nodeId = args.first?.stringValue else { return }
            await self.reducer.clearUnread(nodeId: nodeId)   // clear WITHOUT re-acking (§6.3 #8)
            await self.republishStatuses()
        }
        subscribe("canvas:mut") { [weak self] args in
            guard let self, args.count >= 2, let projectId = args[0].stringValue,
                  let mut = try? args[1].decoded(as: CanvasMutation.self) else { return }
            await self.workspaceStore.apply(mut, projectId: projectId)
            self.workspace = await self.workspaceStore.snapshot()
        }
    }

    private func subscribe(_ channel: String,
                           _ handler: @escaping @MainActor @Sendable ([JSONValue]) async -> Void) {
        tasks.append(Task { [rpc] in
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
