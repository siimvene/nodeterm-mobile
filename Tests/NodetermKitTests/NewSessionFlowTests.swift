import Foundation
@testable import NodetermKit

// Framework-free (see NewSessionPlanTests.swift); RegisteredTests.swift promotes each `run…()` to a
// swift-testing `@Test`. Covers the pieces of the SPAWN flow that were pulled into the Kit after the
// first review: the §7.11.4 read-back decision table, launch re-delivery, the desktop's three-layer
// permission-mode resolution, per-row tolerant account decoding, and (serverId, projectId) grouping.

private func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), "new-session-flow failed: \(label)")
}

// MARK: - RegistrationOutcome.decide — all rows of the §7.11.4 table

public func runRegistrationOutcomeTests() {
    let node = CanvasNodeState(id: "term-a-1", kind: .terminal, title: "t", color: "#fff")
    let readableWith = Workspace(projects: [Project(id: "p1", name: "P", color: "#000", nodes: [node])])
    let readableWithout = Workspace(projects: [Project(id: "p1", name: "P", color: "#000", nodes: [])])
    let unavailable = Workspace(projects: [Project(id: "p1", name: "P", color: "#000", nodes: [],
                                                   unavailable: true)])
    let otherProject = Workspace(projects: [Project(id: "p2", name: "Q", color: "#000", nodes: [node])])

    func decide(_ ws: Workspace?, loaded: Bool = true) -> RegistrationOutcome {
        RegistrationOutcome.decide(workspace: ws, loadSucceeded: loaded, projectId: "p1", nodeId: "term-a-1")
    }

    // Row 0: the load itself failed — a stale snapshot that lacks the node is NOT "not saved".
    check(decide(readableWithout, loaded: false) == .unknown, "failed load ⇒ unknown even when the (stale) snapshot lacks the node")
    check(decide(readableWith, loaded: false) == .unknown, "failed load ⇒ unknown even when the (stale) snapshot has the node")
    check(decide(nil) == .unknown, "no snapshot at all ⇒ unknown")
    // Row 1: project missing from the reply.
    check(decide(otherProject) == .unknown, "project missing ⇒ unknown")
    // Row 2: project present but unreadable — its empty nodes array is not evidence.
    check(decide(unavailable) == .unknown, "unavailable project ⇒ unknown (empty nodes is not evidence)")
    // Row 3: readable + node present.
    check(decide(readableWith) == .registered, "readable + present ⇒ registered")
    // Row 4: readable + node absent.
    check(decide(readableWithout) == .unsaved, "readable + absent ⇒ unsaved")
}

// MARK: - LaunchRedelivery.decide (SPEC §7.11.3: never type a launch into a running agent)

public func runLaunchRedeliveryTests() {
    check(LaunchRedelivery.decide(paneCommand: "zsh") == .send, "zsh ⇒ send")
    check(LaunchRedelivery.decide(paneCommand: "-zsh") == .send, "login shell (-zsh) ⇒ send")
    check(LaunchRedelivery.decide(paneCommand: "/bin/bash") == .send, "path-qualified bash ⇒ send")
    check(LaunchRedelivery.decide(paneCommand: "fish\n") == .send, "trailing newline tolerated")
    check(LaunchRedelivery.decide(paneCommand: "claude") == .alreadyRunning, "claude ⇒ already running")
    check(LaunchRedelivery.decide(paneCommand: "node") == .alreadyRunning, "node (an agent CLI) ⇒ already running")
    check(LaunchRedelivery.decide(paneCommand: "vim") == .alreadyRunning, "editor ⇒ not a shell, do not type")
    check(LaunchRedelivery.decide(paneCommand: nil) == .unknown, "nil ⇒ unknown")
    check(LaunchRedelivery.decide(paneCommand: "") == .unknown, "empty ⇒ unknown")
}

// MARK: - resolvePermissionMode — the desktop's three layers (SPEC §7.11.3)

public func runPermissionModeResolutionTests() {
    func resolve(_ project: String?, _ settings: String?) -> String {
        NewSessionPlan.resolvePermissionMode(projectMode: project, settingsMode: settings)
    }
    // Layer 1: a valid project override wins over everything.
    check(resolve("plan", "manual") == "plan", "valid project mode wins")
    check(resolve("bypassPermissions", nil) == "bypassPermissions", "valid project mode wins with no setting")
    // Layer 2: invalid/absent project value falls THROUGH to a valid setting (not to the default).
    check(resolve(nil, "manual") == "manual", "absent project ⇒ setting")
    check(resolve("yolo", "acceptEdits") == "acceptEdits", "unknown project value ⇒ setting")
    check(resolve("", "plan") == "plan", "empty project value ⇒ setting")
    // Layer 3: both invalid/absent ⇒ DEFAULT_PERMISSION_MODE.
    check(resolve(nil, nil) == "auto", "nothing set ⇒ auto")
    check(resolve("nonsense", "garbage") == "auto", "both unknown ⇒ auto")
    check(resolve(nil, "") == "auto", "empty setting ⇒ auto")
    check(NewSessionPlan.defaultPermissionMode == "auto", "default is auto")
    // The auto gate still applies AFTER resolution (claude only, caps off ⇒ bare command).
    let mode = resolve(nil, nil)
    check(NewSessionPlan.launchCommand(agentId: "claude", permissionMode: mode, caps: ClaudeCliCaps()) == "claude",
          "resolved auto + caps off ⇒ bare claude")
    check(NewSessionPlan.launchCommand(agentId: "claude", permissionMode: mode,
                                       caps: ClaudeCliCaps(autoPermissionMode: true)) == "claude --permission-mode auto",
          "resolved auto + caps on ⇒ flag")
}

// MARK: - Settings: one malformed account row is skipped, the rest kept

public func runSettingsRowToleranceTests() {
    let json = """
    {"claudeAccounts":[{"id":"a1","label":"Work"},
                       {"label":"no id here"},
                       42,
                       {"id":"a3","email":"e@x"}],
     "codexAccounts":[{"id":"c1"},{"id":7}]}
    """
    guard let s = try? JSONDecoder().decode(Settings.self, from: Data(json.utf8)) else {
        preconditionFailure("new-session-flow failed: settings with a bad row must still decode")
    }
    check(s.claudeAccounts.map(\.id) == ["a1", "a3"], "bad rows skipped, good rows kept in order: \(s.claudeAccounts.map(\.id))")
    check(s.codexAccounts.map(\.id) == ["c1"], "codex: non-string id row skipped")

    // A non-array value degrades to [] rather than failing the whole settings object.
    let odd = try? JSONDecoder().decode(Settings.self, from: Data(#"{"claudeAccounts":"nope"}"#.utf8))
    check(odd != nil && odd?.claudeAccounts.isEmpty == true, "non-array accounts ⇒ [] and settings still decode")
}

// MARK: - SessionListModel.groupedByProject keys by (serverId, projectId)

public func runSessionListModelTests() {
    func row(server: String = "s1", serverName: String = "Srv", project: String, name: String,
             node: String, cwd: String? = nil) -> SessionRow {
        SessionRow(serverId: server, serverName: serverName, projectId: project, projectName: name,
                   nodeId: node, title: node, projectCwd: cwd)
    }

    // Two SAME-NAMED projects on one server ⇒ two groups, each spawning into its own project.
    let twoClones = SessionListModel.groupedByProject([
        row(project: "p1", name: "kvart", node: "n1", cwd: "/home/u/kvart"),
        row(project: "p2", name: "kvart", node: "n2", cwd: "/home/u/kvart-hotfix"),
        row(project: "p1", name: "kvart", node: "n3", cwd: "/home/u/kvart")
    ], multiServer: false)
    check(twoClones.count == 2, "same-named projects yield two groups (got \(twoClones.count))")
    check(twoClones[0].projectId == "p1" && twoClones[0].rows.map(\.nodeId) == ["n1", "n3"], "first group is p1 with its rows")
    check(twoClones[1].projectId == "p2" && twoClones[1].rows.map(\.nodeId) == ["n2"], "second group is p2")
    check(twoClones[0].id == "s1/p1" && twoClones[1].id == "s1/p2", "group id is serverId/projectId")
    check(twoClones[0].title == "kvart · kvart" && twoClones[1].title == "kvart · kvart-hotfix",
          "colliding titles disambiguated by cwd basename: \(twoClones.map(\.title))")
    check(twoClones[0].baseTitle == "kvart", "baseTitle stays the bare project name (legacy collapsed key)")

    // Colliding titles WITHOUT distinct basenames fall back to ordinals; the first keeps its bare title.
    let ordinal = SessionListModel.groupedByProject([
        row(project: "p1", name: "app", node: "n1"),
        row(project: "p2", name: "app", node: "n2"),
        row(project: "p3", name: "app", node: "n3", cwd: "/x/app")
    ], multiServer: false)
    check(ordinal.map(\.title) == ["app", "app (2)", "app (3)"], "ordinal fallback: \(ordinal.map(\.title))")

    // Distinct names: no decoration at all, workspace order preserved.
    let plain = SessionListModel.groupedByProject([
        row(project: "p1", name: "alpha", node: "n1", cwd: "/a"),
        row(project: "p2", name: "beta", node: "n2", cwd: "/b")
    ], multiServer: false)
    check(plain.map(\.title) == ["alpha", "beta"], "distinct names undecorated")

    // Same project id on two servers ⇒ two groups (ids are per-server), server-prefixed titles.
    let multi = SessionListModel.groupedByProject([
        row(server: "s1", serverName: "Home", project: "p1", name: "kvart", node: "n1"),
        row(server: "s2", serverName: "Work", project: "p1", name: "kvart", node: "n2")
    ], multiServer: true)
    check(multi.count == 2 && multi.map(\.id) == ["s1/p1", "s2/p1"], "per-server groups")
    check(multi.map(\.title) == ["Home · kvart", "Work · kvart"], "multi-server titles keep the server prefix")

    check(SessionListModel.groupedByProject([], multiServer: false).isEmpty, "empty in ⇒ empty out")
}

// MARK: - SpawnRecord — the §7.11 launch/registration state machine (third review round)

public func runSpawnRecordTests() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let payload = NewSessionPlan.registerPayload(id: "term-a-1", title: nil, agentId: "claude", accountId: nil)
    func fresh(_ command: String? = "claude") -> SpawnRecord {
        SpawnRecord(projectId: "p1", payload: payload, command: command, createFresh: true, now: t0)
    }
    func lostAnswer() -> SpawnRecord {
        SpawnRecord(projectId: "p1", payload: payload, command: "claude", createFresh: false, now: t0)
    }
    let afterCap = t0.addingTimeInterval(SpawnRecord.silenceCap)

    // --- Birth: fresh:true ⇒ launch owed, ungated; fresh:false with NO record ⇒ owed but GATED.
    check(fresh().launch == .owed(command: "claude", gated: false), "fresh create ⇒ owed, ungated")
    check(lostAnswer().launch == .owed(command: "claude", gated: true), "lost first answer ⇒ owed, gated")
    check(fresh(nil).launch == .none && fresh(nil).launchStep(now: afterCap) == .nothing,
          "plain terminal ⇒ no launch, nothing to type")
    check(fresh(nil).needsDrive, "plain terminal still owes its registration")

    // --- Settle guard (finding 3): nobody types before recordedAt + 1.5 s unless settled earlier.
    var r = fresh()
    check(r.launchStep(now: t0) == .wait(until: afterCap), "before the cap ⇒ wait")
    check(r.launchStep(now: t0.addingTimeInterval(1.0)) == .wait(until: afterCap), "1.0 s in ⇒ still wait")
    check(r.launchStep(now: afterCap) == .deliver(command: "claude", checkPane: false), "at the cap ⇒ deliver")
    r.markSettled(now: t0.addingTimeInterval(0.3))
    check(r.launchStep(now: t0.addingTimeInterval(0.3)) == .deliver(command: "claude", checkPane: false),
          "200 ms-quiet observation shortens the window")
    r.markSettled(now: t0.addingTimeInterval(9))
    check(r.notBefore == t0.addingTimeInterval(0.3), "markSettled never EXTENDS the window")

    // --- Lost-answer path still launches exactly once, through the pane check.
    var lost = lostAnswer()
    check(lost.launchStep(now: afterCap) == .deliver(command: "claude", checkPane: true), "lost answer ⇒ gated deliver")
    lost.apply(delivery: .landed)
    check(lost.launch == .landed && !lost.launchOwed, "landed ⇒ not owed")
    check(lost.launchStep(now: afterCap.addingTimeInterval(60)) == .nothing, "landed ⇒ nothing more to type, ever")
    lost.apply(delivery: .deferred)
    check(lost.launch == .landed, "a delivery result on a settled launch is ignored")

    // --- Settled record ignores rejoins (finding 1b): `recording` returns the existing record as-is.
    var settled = fresh()
    settled.apply(delivery: .landed)
    settled.apply(registration: .registered)
    check(settled.isSettled && !settled.needsDrive, "landed + registered ⇒ settled")
    let rejoin = SpawnRecord.recording(existing: settled, projectId: "p1", payload: payload,
                                       command: "claude", createFresh: true,
                                       now: t0.addingTimeInterval(120))
    check(rejoin == settled, "a rejoin on a settled record changes nothing (no re-armed launch, no re-registration)")
    let pendingRejoin = SpawnRecord.recording(existing: lostAnswer(), projectId: "p1", payload: payload,
                                              command: "claude", createFresh: true, now: t0)
    check(pendingRejoin == lostAnswer(), "a second create answer on a pending record does not un-gate it")
    check(SpawnRecord.recording(existing: nil, projectId: "p1", payload: payload, command: "claude",
                                createFresh: false, now: t0) == lostAnswer(),
          "no record ⇒ a new one from THIS answer")

    // --- Failed first create (throws ⇒ nothing recorded) then a successful rejoin ⇒ exactly one launch.
    var afterFailure: SpawnRecord? = nil                       // the catch path records nothing
    afterFailure = SpawnRecord.recording(existing: afterFailure, projectId: "p1", payload: payload,
                                         command: "claude", createFresh: true, now: t0)
    check(afterFailure?.launchStep(now: afterCap) == .deliver(command: "claude", checkPane: false),
          "rejoin after a failed create ⇒ the launch is owed (fresh, ungated)")
    afterFailure?.apply(delivery: .landed)
    afterFailure = SpawnRecord.recording(existing: afterFailure, projectId: "p1", payload: payload,
                                         command: "claude", createFresh: false, now: afterCap)
    check(afterFailure?.launchStep(now: afterCap.addingTimeInterval(5)) == .nothing,
          "…and a later rejoin cannot arm a second one")

    // --- Delivery transitions.
    var d = fresh()
    d.apply(delivery: .transient)
    check(d.launch == .owed(command: "claude", gated: true) && d.launchAttempts == 0,
          "transient ⇒ still owed, gated, NOT an attempt")
    check(d.scheduleRedelivery() == false, "no completed attempt ⇒ no delayed redelivery")
    d.apply(delivery: .deferred)
    check(d.launch == .owed(command: "claude", gated: true) && d.launchAttempts == 1, "deferred ⇒ owed, gated, 1 attempt")
    check(d.launchStep(now: afterCap) == .deliver(command: "claude", checkPane: true), "after an attempt every delivery is gated")
    // --- Dropped re-probe (finding 2): a FIRST "busy" pane read never concludes — the 1.5 s cap can
    // end while a transient rc-file child holds the foreground — so it re-probes ONCE first.
    var dropped = fresh()
    dropped.apply(delivery: .dropped)
    check(dropped.launchOwed && dropped.launch == .owed(command: "claude", gated: true),
          "first dropped ⇒ still owed+gated, a re-probe pending (NOT concluded)")
    check(dropped.needsDrive, "…launch still owed + registration pending ⇒ needs drive")
    check(dropped.scheduleDropReprobe() == true, "…the ONE re-probe is armed")
    check(dropped.scheduleDropReprobe() == false, "…never a second re-probe arming")
    dropped.apply(registration: .registered)
    check(dropped.banner == nil, "a pending re-probe shows no banner")
    // The re-probe still reads "busy" ⇒ NOW conclude dropped, and surface the dismissible banner.
    dropped.apply(delivery: .dropped)
    check(dropped.launch == .dropped && !dropped.launchOwed, "second dropped ⇒ concluded dropped")
    check(dropped.banner == .launchDropped, "concluded drop on a registered node ⇒ 'already busy' banner")
    dropped.acknowledgeDrop()
    check(dropped.banner == nil, "dismissing the dropped banner hides it")
    // Retry re-arms the exact command, gated, and clears the latches so it gets its own re-probe.
    dropped.retryLaunch()
    check(dropped.launchOwed && dropped.launch == .owed(command: "claude", gated: true),
          "Retry on a dropped launch re-arms it (gated)")
    check(dropped.scheduleDropReprobe() == false, "…re-probe re-armed only by the next provisional drop")
    // A re-probe that finds a bare shell LANDS the launch instead of dropping.
    var reprobed = fresh()
    reprobed.apply(delivery: .dropped)      // provisional
    reprobed.apply(delivery: .landed)       // the 2 s re-probe found a bare shell
    check(reprobed.launch == .landed && !reprobed.launchOwed, "a re-probe that finds a shell lands the launch")

    // --- Delayed redelivery (finding 2) is armed exactly once, and the banner follows the attempts.
    check(d.scheduleRedelivery() == true, "first deferred ⇒ arm the ONE delayed redelivery")
    check(d.scheduleRedelivery() == false, "…never a second one")
    d.apply(registration: .registered)
    check(d.banner == nil, "registered + 1 failed attempt ⇒ no banner yet (redelivery pending)")
    d.apply(delivery: .deferred)
    check(d.launchAttempts == 2 && d.banner == .launchUndelivered,
          "registered + redelivery also failed ⇒ 'launch command not delivered' banner")
    check(d.needsDrive, "…and Retry still has work to drive")
    d.apply(delivery: .landed)
    check(d.banner == nil && d.isSettled, "a late landing clears the banner and settles the record")

    // --- Banner priority: registration outcomes win over the launch state.
    var u = fresh()
    u.apply(delivery: .deferred); u.apply(delivery: .deferred)
    check(u.banner == nil, "registration pending ⇒ no banner even with 2 failed launches")
    u.apply(registration: .unknown)
    check(u.banner == .registrationUnknown && u.needsDrive, "unknown ⇒ UNKNOWN banner, still drivable")
    u.apply(registration: .unsaved)
    check(u.banner == .unsaved && !u.registrationPending, "unsaved ⇒ unsaved banner, registration concluded")
    var plain = fresh(nil)
    plain.apply(registration: .registered)
    check(plain.banner == nil && plain.isSettled, "plain terminal registered ⇒ nothing to show, settled")
}

// MARK: - SpawnTransportFault (finding 1): live-socket timeout ≠ gone socket

public func runSpawnTransportFaultTests() {
    func classify(_ err: RpcError, connected: Bool) -> SpawnTransportFault {
        SpawnTransportFault.classify(error: err, stillConnected: connected)
    }
    // A gone socket: the call MAY have landed, the reconnect re-drives — count nothing, abandon.
    check(classify(.disconnected, connected: true) == .socketGone, "disconnected ⇒ socketGone (even if state lags)")
    check(classify(.disconnected, connected: false) == .socketGone, "disconnected while offline ⇒ socketGone")
    check(classify(.timeout, connected: false) == .socketGone, "timeout on a dropping socket ⇒ socketGone")
    // A live-socket deadline reached the server: a REAL attempt — deferred delivery / proceed to read-back.
    check(classify(.timeout, connected: true) == .liveDeadline,
          "timeout while still connected ⇒ liveDeadline (a counted attempt, not a re-drive)")
    // Any other RpcError is a server answer (E_NO_HANDLER / E_HANDLER) — a live deadline-equivalent.
    check(classify(.handler(message: "x"), connected: true) == .liveDeadline, "E_HANDLER ⇒ liveDeadline")
    check(classify(.noHandler(method: "m"), connected: false) == .liveDeadline, "E_NO_HANDLER ⇒ liveDeadline")
}

// MARK: - NewSessionPlan.derivedTitle (finding 4): the phone's synthetic title == the canvas's

public func runDerivedTitleTests() {
    // Mirrors the host's `appendProjectNode`: builtin agent label, else "Mobile session".
    check(NewSessionPlan.derivedTitle(agentId: "claude") == "Claude Code", "claude ⇒ Claude Code")
    check(NewSessionPlan.derivedTitle(agentId: "codex") == "Codex", "codex ⇒ Codex")
    check(NewSessionPlan.derivedTitle(agentId: "gemini") == "Gemini", "gemini ⇒ Gemini")
    check(NewSessionPlan.derivedTitle(agentId: nil) == "Mobile session", "plain terminal ⇒ Mobile session")
    check(NewSessionPlan.derivedTitle(agentId: "opencode") == "Mobile session",
          "an id outside the phone's builtins ⇒ Mobile session (matches the host's config miss)")
}
