import Foundation
import NodetermKit

// FRAMEWORK-FREE TESTS (see WireCodecTests.swift): this machine has only CommandLineTools, so
// neither XCTest nor the swift-testing macro plugin is available to `swift test`. These files
// compile framework-free and expose the assertions as callable `run…()` functions driven by
// `precondition`. On a full toolchain a builder promotes each `check(...)` to a `@Test`/XCTest
// case. Table-driven coverage of the badge state machine (SPEC §6.3), every rule + exception.

private func check(_ cond: Bool, _ label: String) { precondition(cond, "FAIL: \(label)") }
private func checkEq<T: Equatable>(_ a: T, _ b: T, _ label: String) {
    precondition(a == b, "FAIL: \(label) — got \(a), want \(b)")
}

private func ev(
    _ node: String = "n1",
    kind: AgentEventKind = .state,
    state: AgentState? = nil,
    newTurn: Bool? = nil,
    idle: Bool? = nil,
    awaitingInput: Bool? = nil,
    interrupted: Bool? = nil,
    pendingId: String? = nil,
    askKind: AskKind? = nil,
    sessionPhase: SessionPhase? = nil,
    sessionId: String? = nil
) -> AgentStatusEvent {
    AgentStatusEvent(
        nodeId: node, agentId: "claude", kind: kind,
        state: state, interrupted: interrupted, idle: idle,
        awaitingInput: awaitingInput, newTurn: newTurn,
        sessionId: sessionId, pendingId: pendingId, askKind: askKind,
        sessionPhase: sessionPhase
    )
}

private func unknownNode(_ id: String = "n1") -> NodeReduction { NodeReduction(nodeId: id) }
private func node(_ state: ReducedAgentState, doneAt: Int? = nil, lastEventAt: Int? = nil,
                  unread: Bool = false, latch: Bool = false) -> NodeReduction {
    NodeReduction(nodeId: "n1", state: state, unread: unread,
                  doneEnteredAt: doneAt, awaitingInputLatch: latch, lastEventAt: lastEventAt)
}

/// Runs every reducer assertion; crashes via `precondition` on the first failure.
public func runStoresReducerTests() {
    testBaseTransitionsAndUnreadEdges()
    testIdleRescue()
    testAwaitingInputLatch()
    testInterruptedSuppression()
    testDoneHoldoffBoundaries()
    testSessionLifecycleReset()
    testNewTurnClearsFanOut()
    testPendingIdLifecycle()
    testUnknownKindsAndStatesAreNoOps()
    testSweepStaleWorking()
}

// MARK: - Rule 1 base adoption + Rule 8 unread edges (table-driven)

private func testBaseTransitionsAndUnreadEdges() {
    struct Case {
        let name: String
        let prior: NodeReduction
        let event: AgentStatusEvent
        let onScreen: Bool
        let expState: ReducedAgentState
        let expUnread: Bool
        let expAlert: Bool
    }
    let cases: [Case] = [
        .init(name: "unknown→working", prior: unknownNode(), event: ev(state: .working),
              onScreen: false, expState: .working, expUnread: false, expAlert: false),
        .init(name: "unknown→waiting", prior: unknownNode(), event: ev(state: .waiting),
              onScreen: false, expState: .waiting, expUnread: false, expAlert: false),
        .init(name: "unknown→blocked", prior: unknownNode(), event: ev(state: .blocked),
              onScreen: false, expState: .blocked, expUnread: false, expAlert: false),
        .init(name: "unknown→done", prior: unknownNode(), event: ev(state: .done),
              onScreen: false, expState: .done, expUnread: false, expAlert: false),
        .init(name: "working→done offscreen ⇒ unread+alert", prior: node(.working),
              event: ev(state: .done), onScreen: false,
              expState: .done, expUnread: true, expAlert: true),
        .init(name: "working→waiting offscreen ⇒ unread", prior: node(.working),
              event: ev(state: .waiting), onScreen: false,
              expState: .waiting, expUnread: true, expAlert: false),
        .init(name: "working→blocked offscreen ⇒ unread", prior: node(.working),
              event: ev(state: .blocked), onScreen: false,
              expState: .blocked, expUnread: true, expAlert: false),
        .init(name: "working→done onscreen ⇒ no unread, alert", prior: node(.working),
              event: ev(state: .done), onScreen: true,
              expState: .done, expUnread: false, expAlert: true),
        .init(name: "working→waiting onscreen ⇒ no unread", prior: node(.working),
              event: ev(state: .waiting), onScreen: true,
              expState: .waiting, expUnread: false, expAlert: false),
        .init(name: "waiting→done ⇒ not an unread edge", prior: node(.waiting),
              event: ev(state: .done), onScreen: false,
              expState: .done, expUnread: false, expAlert: false),
        .init(name: "working→working ⇒ no unread", prior: node(.working),
              event: ev(state: .working), onScreen: false,
              expState: .working, expUnread: false, expAlert: false),
    ]
    for c in cases {
        let out = AgentStatusReducer.reduce(c.prior, c.event, onScreen: c.onScreen, now: 1000)
        checkEq(out.reduction.state, c.expState, c.name)
        checkEq(out.reduction.unread, c.expUnread, "\(c.name): unread")
        checkEq(out.completionAlert, c.expAlert, "\(c.name): alert")
        check(!out.ignored, "\(c.name): not ignored")
    }
}

// MARK: - Rule 2 idle done-only rescue

private func testIdleRescue() {
    let w = AgentStatusReducer.reduce(node(.working), ev(idle: true), onScreen: false, now: 5)
    checkEq(w.reduction.state, .done, "idle rescue working→done")
    check(w.reduction.unread, "idle rescue sets unread offscreen")
    check(w.completionAlert, "idle rescue is a completion")
    checkEq(w.reduction.doneEnteredAt, 5, "idle rescue stamps done clock")

    for st: ReducedAgentState in [.waiting, .blocked, .done, .unknown] {
        let out = AgentStatusReducer.reduce(node(st, doneAt: st == .done ? 0 : nil),
                                            ev(idle: true), onScreen: false, now: 9)
        checkEq(out.reduction.state, st, "idle must not move \(st)")
        check(!out.reduction.unread, "idle must not set unread on \(st)")
    }
}

// MARK: - Rule 3 awaitingInput latch through the turn-end done

private func testAwaitingInputLatch() {
    let s1 = AgentStatusReducer.reduce(node(.working), ev(awaitingInput: true, askKind: .question),
                                       onScreen: false, now: 10)
    checkEq(s1.reduction.state, .waiting, "awaitingInput ⇒ waiting")
    check(s1.reduction.awaitingInputLatch, "latch armed")
    check(s1.reduction.unread, "working→waiting offscreen ⇒ unread")

    let s2 = AgentStatusReducer.reduce(s1.reduction, ev(state: .done), onScreen: false, now: 20)
    checkEq(s2.reduction.state, .waiting, "latch holds waiting through done")
    check(!s2.reduction.awaitingInputLatch, "latch consumed")

    let s3 = AgentStatusReducer.reduce(s2.reduction, ev(state: .done), onScreen: false, now: 30)
    checkEq(s3.reduction.state, .done, "second done lands after latch cleared")

    let r = AgentStatusReducer.reduce(node(.waiting, latch: true), ev(state: .working),
                                      onScreen: false, now: 40)
    checkEq(r.reduction.state, .working, "working clears the latch")
    check(!r.reduction.awaitingInputLatch, "latch cleared by working")
}

// MARK: - Rule 4 interrupted suppression

private func testInterruptedSuppression() {
    let out = AgentStatusReducer.reduce(node(.working), ev(state: .done, interrupted: true),
                                        onScreen: false, now: 7)
    checkEq(out.reduction.state, .done, "interrupted still adopts done")
    check(!out.reduction.unread, "interrupted ⇒ no unread")
    check(!out.completionAlert, "interrupted ⇒ no alert")

    let ctl = AgentStatusReducer.reduce(node(.working), ev(state: .done), onScreen: false, now: 7)
    check(ctl.reduction.unread, "control: non-interrupted sets unread")
    check(ctl.completionAlert, "control: non-interrupted alerts")
}

// MARK: - Rule 5 DONE-HOLDOFF timing boundaries

private func testDoneHoldoffBoundaries() {
    let prior = node(.done, doneAt: 0, lastEventAt: 0)
    let ig = AgentStatusReducer.reduce(prior, ev(state: .working), onScreen: false, now: 2999)
    check(ig.ignored, "2999ms ignored")
    checkEq(ig.reduction.state, .done, "2999ms stays done")
    checkEq(ig.reduction.doneEnteredAt, 0, "done clock untouched")
    checkEq(ig.reduction.lastEventAt, 0, "event clock untouched")

    let at3000 = AgentStatusReducer.reduce(prior, ev(state: .working), onScreen: false, now: 3000)
    check(!at3000.ignored, "3000ms adopted (strict <)")
    checkEq(at3000.reduction.state, .working, "3000ms working")

    let at3001 = AgentStatusReducer.reduce(prior, ev(state: .working), onScreen: false, now: 3001)
    check(!at3001.ignored, "3001ms adopted")
    checkEq(at3001.reduction.state, .working, "3001ms working")
    check(at3001.reduction.doneEnteredAt == nil, "leaving done clears done clock")

    let nt = AgentStatusReducer.reduce(prior, ev(state: .working, newTurn: true),
                                       onScreen: false, now: 2999)
    check(!nt.ignored, "newTurn bypasses holdoff")
    checkEq(nt.reduction.state, .working, "newTurn adopts working inside window")

    let wt = AgentStatusReducer.reduce(prior, ev(state: .waiting), onScreen: false, now: 100)
    check(!wt.ignored, "holdoff is working-only")
    checkEq(wt.reduction.state, .waiting, "waiting adopted inside window")
}

// MARK: - Rule 6 session start/end reset

private func testSessionLifecycleReset() {
    let dirty = NodeReduction(nodeId: "n1", state: .blocked, unread: true,
                              pendingId: "p1", askKind: .approval,
                              doneEnteredAt: 1, awaitingInputLatch: true, lastEventAt: 1)
    for phase: SessionPhase in [.start, .end] {
        let out = AgentStatusReducer.reduce(dirty, ev(kind: .session, sessionPhase: phase),
                                            onScreen: false, now: 500)
        checkEq(out.reduction.state, .unknown, "\(phase.wire) resets to unknown")
        check(!out.reduction.unread, "\(phase.wire) clears unread")
        check(out.reduction.pendingId == nil, "\(phase.wire) clears pendingId")
        check(out.reduction.askKind == nil, "\(phase.wire) clears askKind")
        check(out.reduction.doneEnteredAt == nil, "\(phase.wire) clears done clock")
        check(!out.reduction.awaitingInputLatch, "\(phase.wire) clears latch")
        check(out.clearedFanOut, "\(phase.wire) clears fan-out")
    }
    let noop = AgentStatusReducer.reduce(node(.working), ev(kind: .session), onScreen: false, now: 1)
    checkEq(noop.reduction.state, .working, "session w/o phase changes nothing")
}

// MARK: - Rule 7 newTurn clears fan-out

private func testNewTurnClearsFanOut() {
    let out = AgentStatusReducer.reduce(node(.working), ev(state: .working, newTurn: true),
                                        onScreen: false, now: 1)
    check(out.clearedFanOut, "newTurn clears fan-out")
    let sub = AgentStatusReducer.reduce(node(.working), ev(kind: .subagentEnd, newTurn: true),
                                        onScreen: false, now: 1)
    check(sub.clearedFanOut, "newTurn on non-state kind clears fan-out")
    checkEq(sub.reduction.state, .working, "non-state kind leaves badge unchanged")
}

// MARK: - pendingId / askKind carry + clear

private func testPendingIdLifecycle() {
    let b = AgentStatusReducer.reduce(node(.working), ev(state: .blocked, pendingId: "p9",
                                                         askKind: .approval),
                                      onScreen: false, now: 1)
    checkEq(b.reduction.pendingId, "p9", "blocked holds pendingId")
    checkEq(b.reduction.askKind, .approval, "blocked holds askKind")
    let w = AgentStatusReducer.reduce(b.reduction, ev(state: .working), onScreen: false, now: 2)
    check(w.reduction.pendingId == nil, "resolve to working clears pendingId")
    check(w.reduction.askKind == nil, "resolve to working clears askKind")
}

// MARK: - Tolerant decode: unknown kinds / states are no-ops

private func testUnknownKindsAndStatesAreNoOps() {
    let prior = node(.working, doneAt: nil, lastEventAt: 100, unread: false)
    let uk = AgentStatusReducer.reduce(prior, ev(kind: .unknown("frobnicate")),
                                       onScreen: false, now: 999)
    checkEq(uk.reduction, prior, "unknown kind must not mutate the reduction")

    for k: AgentEventKind in [.backgroundTask, .recurring, .subagentStart, .subagentEnd] {
        let out = AgentStatusReducer.reduce(prior, ev(kind: k), onScreen: false, now: 999)
        checkEq(out.reduction.state, .working, "\(k.wire) must not change state")
    }

    let us = AgentStatusReducer.reduce(prior, ev(state: .unknown("weird")), onScreen: false, now: 999)
    checkEq(us.reduction.state, .working, "unknown state string ⇒ no base transition")
}

// MARK: - Rule 5 hygiene: stale-working decay

private func testSweepStaleWorking() {
    let working = node(.working, lastEventAt: 0)
    let decayed = AgentStatusReducer.sweepStaleWorking(working, now: 300_000, thresholdMs: 300_000)
    checkEq(decayed.state, .unknown, "past threshold ⇒ unknown")
    let fresh = AgentStatusReducer.sweepStaleWorking(working, now: 299_999, thresholdMs: 300_000)
    checkEq(fresh.state, .working, "within threshold ⇒ unchanged")
    let done = node(.done, doneAt: 0, lastEventAt: 0)
    checkEq(AgentStatusReducer.sweepStaleWorking(done, now: 10_000_000, thresholdMs: 1).state, .done,
            "non-working never decays")
    var unreadWorking = working; unreadWorking.unread = true
    check(AgentStatusReducer.sweepStaleWorking(unreadWorking, now: 400_000, thresholdMs: 300_000).unread,
          "unread survives decay (independent of state)")
}
