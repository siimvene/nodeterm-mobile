import Foundation

// The per-server agent-status store (SPEC §8.1 `AgentStatusStore`). An actor holding one
// `NodeReduction` per node, folding the `agent:status` stream through the pure reducer (SPEC §6.3)
// and merging `context:update` (SPEC §6.1/§11.6) by sessionId. Exposes badge + pendingId/askKind +
// ContextWindowUsage per node via `AgentNodeStatus` (whose `badge` is derived, SPEC §6.3 mapping).

/// Actor implementing `AgentStatusReducing` (SPEC §6.3). Shared mutable state lives behind actor
/// isolation (house rule: actors for shared mutable state). The wall-clock is injected — never
/// `Date()` inline — so the DONE-HOLDOFF (SPEC §6.3 rule 5) is testable.
public actor AgentStatusStore: AgentStatusReducing {
    private var reductions: [String: NodeReduction] = [:]
    /// `context:update` is keyed by sessionId, not nodeId, and can arrive before or after the node
    /// is known — hold it here and merge at read time (SPEC §6.1).
    private var contextBySession: [String: ContextWindowUsage] = [:]
    private let clock: @Sendable () -> Int
    private let staleThresholdMs: Int

    /// - Parameters:
    ///   - clock: injected millisecond wall-clock (SPEC §6.3 rule 5 — never `Date()` inline).
    ///   - staleThresholdMs: stale-working decay window (SPEC §6.3 rule 5 hygiene).
    public init(
        clock: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
        staleThresholdMs: Int = AgentStatusReducer.defaultStaleWorkingMs
    ) {
        self.clock = clock
        self.staleThresholdMs = staleThresholdMs
    }

    // MARK: - AgentStatusReducing (SPEC §6.3)

    /// Fold one `agent:status` event (SPEC §6.3). `onScreen` gates the unread edge (rule 8).
    public func ingest(_ event: AgentStatusEvent, onScreen: Bool) async {
        let prior = reductions[event.nodeId] ?? NodeReduction(nodeId: event.nodeId)
        let outcome = AgentStatusReducer.reduce(prior, event, onScreen: onScreen, now: clock())
        reductions[event.nodeId] = outcome.reduction
    }

    /// Fold a `context:update` payload into the meter, keyed by sessionId (SPEC §6.1/§11.6).
    public func ingestContext(_ usage: ContextWindowUsage) async {
        contextBySession[usage.sessionId] = usage
    }

    /// Clear unread WITHOUT re-acking — for an `agent:unread-clear` event (SPEC §6.3 rule 8).
    public func clearUnread(nodeId: String) async {
        guard var r = reductions[nodeId] else { return }
        r.unread = false
        reductions[nodeId] = r
    }

    /// The user viewed the session: clear unread. Returns `true` iff the node is `done` and the
    /// caller should now send `agent:ack-done` (SPEC §5.3/§6.3 rule 8). Unknown node ⇒ false.
    public func markViewed(nodeId: String) async -> Bool {
        guard var r = reductions[nodeId] else { return false }
        r.unread = false
        let shouldAck = (r.state == .done)
        reductions[nodeId] = r
        return shouldAck
    }

    /// Reduced status for one node (`nil` = never seen ⇒ unknown) (SPEC §6.3).
    public func status(for nodeId: String) async -> AgentNodeStatus? {
        guard let r = reductions[nodeId] else { return nil }
        return project(r)
    }

    /// All reduced statuses, for the sessions-list grouping/sort (SPEC §6.3).
    public func all() async -> [AgentNodeStatus] {
        reductions.values.map(project)
    }

    // MARK: - Additive helpers (not in the protocol)

    /// Run the stale-working sweep across every node (SPEC §6.3 rule 5 hygiene). Call on a timer.
    public func sweepStaleWorking(now: Int? = nil) async {
        let t = now ?? clock()
        for (id, r) in reductions {
            reductions[id] = AgentStatusReducer.sweepStaleWorking(r, now: t, thresholdMs: staleThresholdMs)
        }
    }

    /// Tolerantly decode a raw `agent:status` event's `args` and ingest it. A frame that cannot be
    /// decoded is dropped (no crash, no state change — SPEC §4.3/§6.4).
    public func ingestRawStatus(_ args: [JSONValue], onScreen: Bool) async {
        guard let first = args.first,
              let event = try? first.decoded(as: AgentStatusEvent.self) else { return }
        await ingest(event, onScreen: onScreen)
    }

    /// Tolerantly decode a raw `context:update` event's `args` and fold it (SPEC §6.1).
    public func ingestRawContext(_ args: [JSONValue]) async {
        guard let first = args.first,
              let usage = try? first.decoded(as: ContextWindowUsage.self) else { return }
        await ingestContext(usage)
    }

    /// Consume the `agent:status` channel (SPEC §6.1). `onScreen` resolves per-node visibility for
    /// the unread edge (rule 8). Returns when the stream ends.
    public func consumeStatus(_ stream: AsyncStream<[JSONValue]>,
                              onScreen: @escaping @Sendable (String) -> Bool) async {
        for await args in stream {
            guard let first = args.first,
                  let event = try? first.decoded(as: AgentStatusEvent.self) else { continue }
            await ingest(event, onScreen: onScreen(event.nodeId))
        }
    }

    /// Consume the `context:update` channel (SPEC §6.1). Returns when the stream ends.
    public func consumeContext(_ stream: AsyncStream<[JSONValue]>) async {
        for await args in stream {
            await ingestRawContext(args)
        }
    }

    // MARK: - Projection

    /// Project the internal reduction to the public `AgentNodeStatus`, merging any context
    /// buffered for the node's sessionId (SPEC §6.1). `badge` is derived on `AgentNodeStatus`.
    private func project(_ r: NodeReduction) -> AgentNodeStatus {
        var ctx: ContextWindowUsage?
        if let sid = r.sessionId { ctx = contextBySession[sid] }
        return AgentNodeStatus(
            nodeId: r.nodeId,
            state: r.state,
            unread: r.unread,
            sessionId: r.sessionId,
            pendingId: r.pendingId,
            askKind: r.askKind,
            lastTransitionAt: r.lastTransitionAt,
            context: ctx
        )
    }
}
