import Foundation

// The badge state machine (SPEC §6.3) implemented VERBATIM as a pure `(state, event) -> state`
// function. No wall-clock is read here: every rule that needs "now" takes it as a parameter, so
// the 3000 ms DONE-HOLDOFF (SPEC §6.3 rule 5) is deterministic under test. The owning actor
// (`AgentStatusStore`) injects a clock; this file never calls `Date()`.

/// The internal per-node reduction (SPEC §6.3). Carries the observable badge fields plus the
/// bookkeeping the rules need: `doneEnteredAt` (rule 5 holdoff clock), `awaitingInputLatch`
/// (rule 3 latch-through-done), and `lastEventAt` (rule 5 stale-working decay). The public
/// `AgentNodeStatus` is projected from this by the store (folding in `context:update`).
public struct NodeReduction: Sendable, Equatable {
    public var nodeId: String
    /// Reduced badge state; initial `.unknown` — live state is transient/unpersisted server-side,
    /// so a node is unknown until its next hook fires (SPEC §6.3).
    public var state: ReducedAgentState
    /// Unread dot — set on a working→(done|waiting|blocked) edge while off screen; INDEPENDENT of
    /// state (SPEC §6.3 rule 8).
    public var unread: Bool
    public var sessionId: String?
    /// Present ⇒ a genuine approval is held (drives inline Allow/Deny) (SPEC §6.2/§6.3).
    public var pendingId: String?
    public var askKind: AskKind?
    /// Last actual state change (ms) for newest-first sorting; `nil` sorts last (SPEC §6.3).
    public var lastTransitionAt: Int?

    // --- rule bookkeeping (not directly rendered) ---
    /// When the node entered `done` (ms) — the DONE-HOLDOFF clock (SPEC §6.3 rule 5).
    public var doneEnteredAt: Int?
    /// `awaitingInput:true` latched a waiting that must hold through the turn-end done (rule 3).
    public var awaitingInputLatch: Bool
    /// Last `kind:'state'` event time (ms) for stale-working decay (SPEC §6.3 rule 5 hygiene).
    public var lastEventAt: Int?

    public init(
        nodeId: String,
        state: ReducedAgentState = .unknown,
        unread: Bool = false,
        sessionId: String? = nil,
        pendingId: String? = nil,
        askKind: AskKind? = nil,
        lastTransitionAt: Int? = nil,
        doneEnteredAt: Int? = nil,
        awaitingInputLatch: Bool = false,
        lastEventAt: Int? = nil
    ) {
        self.nodeId = nodeId
        self.state = state
        self.unread = unread
        self.sessionId = sessionId
        self.pendingId = pendingId
        self.askKind = askKind
        self.lastTransitionAt = lastTransitionAt
        self.doneEnteredAt = doneEnteredAt
        self.awaitingInputLatch = awaitingInputLatch
        self.lastEventAt = lastEventAt
    }
}

/// The result of folding one `agent:status` event. `reduction` is the new state; the flags are
/// side effects the rules name but that live outside the reduced badge model:
/// `completionAlert` (rule 4 — suppressed when interrupted), `clearedFanOut` (rule 7 — `newTurn`
/// clears subagent cards, which the fan-out store owns), and `ignored` (rule 5 — the DONE-HOLDOFF
/// dropped the event, state and clock untouched).
public struct ReduceOutcome: Sendable, Equatable {
    public var reduction: NodeReduction
    public var completionAlert: Bool
    public var clearedFanOut: Bool
    public var ignored: Bool

    public init(reduction: NodeReduction, completionAlert: Bool = false,
                clearedFanOut: Bool = false, ignored: Bool = false) {
        self.reduction = reduction
        self.completionAlert = completionAlert
        self.clearedFanOut = clearedFanOut
        self.ignored = ignored
    }
}

/// The pure badge state machine (SPEC §6.3). All eight rules live here as static functions so the
/// store is a thin actor around them.
public enum AgentStatusReducer {

    /// DONE-HOLDOFF window (SPEC §6.3 rule 5): a `working` without `newTurn` arriving strictly
    /// under this many ms after entering `done` is ignored. `<3000` ⇒ ignore; `>=3000` ⇒ adopt.
    public static let doneHoldoffMs = 3000

    /// Default stale-working decay threshold (SPEC §6.3 rule 5 hygiene / desktop `sweepStaleWorking`).
    public static let defaultStaleWorkingMs = 5 * 60_000

    /// Fold one `agent:status` event into a node's reduction (SPEC §6.3, rules 1–8). Pure: `now`
    /// is supplied by the caller. Unknown event kinds are a no-op (no crash, no state change).
    public static func reduce(_ prior: NodeReduction, _ event: AgentStatusEvent,
                              onScreen: Bool, now: Int) -> ReduceOutcome {
        switch event.kind {
        case .session:
            return reduceSession(prior, event, now: now)
        case .state:
            return reduceStateEvent(prior, event, onScreen: onScreen, now: now)
        case .subagentStart, .subagentEnd, .recurring, .backgroundTask, .unknown:
            // Not part of (state, unread). SPEC §6.3 rule 7: `newTurn` clears per-turn fan-out
            // (subagent cards live in a separate store). No change to the reduced badge.
            return ReduceOutcome(reduction: prior, clearedFanOut: event.newTurn == true)
        }
    }

    // MARK: - kind:'session' (SPEC §6.3 rule 6)

    private static func reduceSession(_ prior: NodeReduction, _ event: AgentStatusEvent,
                                      now: Int) -> ReduceOutcome {
        var s = prior
        if let sid = event.sessionId, !sid.isEmpty { s.sessionId = sid }

        switch event.sessionPhase {
        case .start?, .end?:
            // SPEC §6.3 rule 6: start → reset to idle/unknown; end → reset AND clear recurring/
            // fan-out UI. Both drop any held prompt, the latch, the done clock, and unread.
            s.state = .unknown
            s.unread = false
            s.pendingId = nil
            s.askKind = nil
            s.doneEnteredAt = nil
            s.awaitingInputLatch = false
            s.lastTransitionAt = now
            s.lastEventAt = now
            return ReduceOutcome(reduction: s, clearedFanOut: true)
        case .unknown?, nil:
            // A session event without a recognized phase changes nothing (tolerant, SPEC §6.4).
            return ReduceOutcome(reduction: s)
        }
    }

    // MARK: - kind:'state' (SPEC §6.3 rules 1–5, 7, 8)

    private static func reduceStateEvent(_ prior: NodeReduction, _ event: AgentStatusEvent,
                                         onScreen: Bool, now: Int) -> ReduceOutcome {
        // Map wire state → reduced; unknown/absent yields no base transition.
        let mapped: ReducedAgentState? = {
            switch event.state {
            case .working?: return .working
            case .waiting?: return .waiting
            case .blocked?: return .blocked
            case .done?: return .done
            case .unknown?, nil: return nil
            }
        }()

        // --- Rule 5: DONE-HOLDOFF -------------------------------------------------------------
        // A `working` WITHOUT `newTurn` arriving <3000 ms after the node entered `done` is IGNORED
        // (state AND clock untouched). `newTurn:true` bypasses it (an in-order new turn).
        // SPEC §6.3 rule 5.
        if mapped == .working, event.newTurn != true, prior.state == .done,
           let doneAt = prior.doneEnteredAt, (now - doneAt) < doneHoldoffMs {
            return ReduceOutcome(reduction: prior, ignored: true)
        }

        var s = prior
        if let sid = event.sessionId, !sid.isEmpty { s.sessionId = sid }
        s.lastEventAt = now
        let fanCleared = (event.newTurn == true) // SPEC §6.3 rule 7

        // --- Rule 2: idle done-only rescue ----------------------------------------------------
        // `idle:true` may ONLY move a currently-`working` node → done. It MUST NOT clear
        // waiting/blocked (a pending approval is also "idle at the prompt"). SPEC §6.3 rule 2.
        if event.idle == true {
            if prior.state == .working {
                return applyTransition(&s, to: .done, event: event, priorState: .working,
                                       onScreen: onScreen, now: now, fanCleared: fanCleared)
            }
            return ReduceOutcome(reduction: s, clearedFanOut: fanCleared)
        }

        // --- Rule 3: awaitingInput latch ------------------------------------------------------
        // `awaitingInput:true` latches WAITING and holds it through the subsequent turn-end done.
        // SPEC §6.3 rule 3.
        if event.awaitingInput == true {
            s.awaitingInputLatch = true
            return applyTransition(&s, to: .waiting, event: event, priorState: prior.state,
                                   onScreen: onScreen, now: now, fanCleared: fanCleared)
        }
        // Latched: a turn-end `done` is absorbed — stay WAITING and consume the latch (rule 3).
        if prior.awaitingInputLatch, mapped == .done {
            s.awaitingInputLatch = false
            return ReduceOutcome(reduction: s, clearedFanOut: fanCleared)
        }

        // --- Rule 1: adopt the state (interrupted handled in applyTransition) ------------------
        guard let target = mapped else {
            // Unknown/absent state on a kind:'state' event → no base transition (tolerant).
            return ReduceOutcome(reduction: s, clearedFanOut: fanCleared)
        }
        // Any adopted non-waiting transition clears the awaiting latch.
        if target != .waiting { s.awaitingInputLatch = false }

        return applyTransition(&s, to: target, event: event, priorState: prior.state,
                               onScreen: onScreen, now: now, fanCleared: fanCleared)
    }

    /// Apply an adopted transition: set state, resolve the unread edge (rule 8) with the
    /// interrupted suppression (rule 4), carry/clear the held prompt, and maintain the done clock.
    private static func applyTransition(_ s: inout NodeReduction, to target: ReducedAgentState,
                                        event: AgentStatusEvent, priorState: ReducedAgentState,
                                        onScreen: Bool, now: Int, fanCleared: Bool) -> ReduceOutcome {
        // SPEC §6.3 rule 4: `interrupted:true` applies to a `done` only — adopt done but suppress
        // the completion alert and do NOT set unread.
        let interrupted = (event.interrupted == true) && target == .done

        // SPEC §6.3 rule 8: unread on a working→(done|waiting|blocked) edge while off screen;
        // independent of state; suppressed when interrupted.
        let isUnreadEdge = priorState == .working
            && (target == .done || target == .waiting || target == .blocked)
        var completionAlert = false
        if isUnreadEdge && !interrupted {
            if !onScreen { s.unread = true }
            if target == .done { completionAlert = true }
        }

        // Held prompt: kept on waiting/blocked, cleared once resolved to working/done.
        switch target {
        case .waiting, .blocked:
            s.pendingId = event.pendingId
            s.askKind = event.askKind
        case .working, .done, .unknown:
            s.pendingId = nil
            s.askKind = nil
        }

        // DONE-HOLDOFF clock (rule 5 support): stamp on ENTRY into done, clear on leaving done.
        if target == .done && priorState != .done {
            s.doneEnteredAt = now
        } else if target != .done {
            s.doneEnteredAt = nil
        }

        if target != priorState { s.lastTransitionAt = now }
        s.state = target
        return ReduceOutcome(reduction: s, completionAlert: completionAlert,
                             clearedFanOut: fanCleared)
    }

    // MARK: - Stale-working decay (SPEC §6.3 rule 5 hygiene)

    /// Decay a `working` node that has emitted no `kind:'state'` event for `thresholdMs` back to
    /// `unknown` (the desktop's `sweepStaleWorking`). Unread is INDEPENDENT of state (rule 8) and
    /// is left untouched. Pure: caller supplies `now`.
    public static func sweepStaleWorking(_ s: NodeReduction, now: Int,
                                         thresholdMs: Int = defaultStaleWorkingMs) -> NodeReduction {
        guard s.state == .working, let last = s.lastEventAt, (now - last) >= thresholdMs else {
            return s
        }
        var out = s
        out.state = .unknown
        out.doneEnteredAt = nil
        out.awaitingInputLatch = false
        out.lastTransitionAt = now
        return out
    }
}
