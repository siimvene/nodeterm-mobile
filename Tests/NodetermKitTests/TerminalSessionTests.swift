import Foundation
import NodetermKit

// NOTE ON THE TEST FRAMEWORK (mirrors WireCodecTests.swift)
// This machine has only Apple CommandLineTools (no full Xcode), so neither XCTest nor the
// swift-testing macro plugin is available to `swift test`. This file compiles framework-free and
// exposes its assertions as a callable `runTerminalSessionSmoke()` using `precondition`. A builder
// on a full toolchain promotes each `check(...)` to a `@Test`/`XCTest` case. `swift test` here runs
// and reports zero discovered tests, which is the accepted state for the skeleton. The assertions
// are executed for real by the scratchpad-only `TerminalVerify` executable during development.

private func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), "terminal-smoke failed: \(label)")
}

// MARK: - Mock RPC client (records outbound frames, returns canned results)

/// A `RpcClienting` double that records every `cast` / `request` and answers requests from a
/// per-method table. Only the pty methods this module exercises are stubbed.
public actor MockRpc: RpcClienting {
    public private(set) var casts: [(method: String, args: [RpcArg])] = []
    public private(set) var requests: [(method: String, args: [RpcArg])] = []
    private var responses: [String: JSONValue] = [:]

    public init() {}

    public func stub(_ method: String, _ value: JSONValue) { responses[method] = value }

    public func recordedCasts() -> [(method: String, args: [RpcArg])] { casts }
    public func recordedRequests() -> [(method: String, args: [RpcArg])] { requests }

    public func start() async {}
    public func stop() async {}

    public func request(_ method: String, _ args: [RpcArg]) async throws -> JSONValue {
        requests.append((method, args))
        return responses[method] ?? .null
    }
    public func cast(_ method: String, _ args: [RpcArg]) async {
        casts.append((method, args))
    }
    public func subscribe(_ channel: String) async -> AsyncStream<[JSONValue]> {
        AsyncStream { $0.finish() }
    }
    public func ptyData(for sessionId: String) async -> AsyncStream<Data> {
        AsyncStream { $0.finish() }
    }
    public func connectionStates() async -> AsyncStream<ConnectionState> {
        AsyncStream { $0.finish() }
    }
    public func connectionState() async -> ConnectionState { .connected }
}

// MARK: - Fixtures

private func terminalNode(
    id: String = "n1",
    cwd: String? = "/home/siim/proj",
    agentId: String? = "claude",
    accountId: String? = "acct-1"
) -> CanvasNodeState {
    CanvasNodeState(id: id, kind: .terminal, title: "T", color: "#fff",
                    cwd: cwd, agentId: agentId, accountId: accountId)
}

private func localProject(cwd: String? = "/proj") -> Project {
    Project(id: "p1", name: "P", color: "#000",
            nodes: [], cwd: cwd, ssh: nil)
}

private func sshProject() -> Project {
    Project(id: "p2", name: "S", color: "#000",
            nodes: [], cwd: "/remote", ssh: ProjectSSH(server: "user@host", remoteCwd: "/remote"))
}

// MARK: - Entry point

public func runTerminalSessionSmoke() async {
    createOptionsMatrix()
    seedPaintDecisionTable()
    parkNullEncodingChecks()
    inputRoutingChecks()
    osc52Checks()
    passiveEventChecks()
    await controllerEncodingChecks()
}

// MARK: - (1) createOptions matrix (§7.1)

private func createOptionsMatrix() {
    // Plain local node: persistKey==id, viewerId set, cwd from node, agentId/accountId carried,
    // ownerProjectId set, requireRemote nil, sshRemote nil.
    let plain = TerminalCreatePlan.createOptions(
        for: terminalNode(), in: localProject(), cols: 80, rows: 24, viewerId: "v-1")
    check(plain.persistKey == "n1", "createOptions.persistKey==nodeId")
    check(plain.viewerId == "v-1", "createOptions.viewerId")
    check(plain.cols == 80 && plain.rows == 24, "createOptions.grid")
    check(plain.cwd == "/home/siim/proj", "createOptions.cwd from node")
    check(plain.agentId == "claude", "createOptions.agentId")
    check(plain.accountId == "acct-1", "createOptions.accountId")
    check(plain.ownerProjectId == "p1", "createOptions.ownerProjectId")
    check(plain.requireRemote == nil, "createOptions.requireRemote nil for local")
    check(plain.sshRemote == nil, "createOptions.sshRemote never set")

    // SSH project node: requireRemote == true.
    let ssh = TerminalCreatePlan.createOptions(
        for: terminalNode(), in: sshProject(), cols: 80, rows: 24, viewerId: "v-2")
    check(ssh.requireRemote == true, "createOptions.requireRemote true for ssh project")
    check(ssh.sshRemote == nil, "createOptions.sshRemote still nil on ssh project")

    // sshRemoteTmux node in a local project: requireRemote == true.
    let remoteTmux = TerminalCreatePlan.createOptions(
        for: terminalNode(), in: localProject(), cols: 80, rows: 24, viewerId: "v-3",
        sshRemoteTmux: true)
    check(remoteTmux.requireRemote == true, "createOptions.requireRemote true for sshRemoteTmux node")

    // Missing cwd: node.cwd nil AND project nil ⇒ cwd nil (server $HOME on spawn — the risk §7.1
    // warns about, but nothing to invent here).
    let noCwd = TerminalCreatePlan.createOptions(
        for: terminalNode(cwd: nil), in: nil, cols: 10, rows: 5, viewerId: "v-4")
    check(noCwd.cwd == nil, "createOptions.cwd nil when node+project have none")
    check(noCwd.ownerProjectId == nil, "createOptions.ownerProjectId nil with no project")
    check(noCwd.requireRemote == nil, "createOptions.requireRemote nil with no project")

    // Missing node cwd falls back to project cwd.
    let fallback = TerminalCreatePlan.createOptions(
        for: terminalNode(cwd: nil), in: localProject(cwd: "/proj"), cols: 10, rows: 5, viewerId: "v-5")
    check(fallback.cwd == "/proj", "createOptions.cwd falls back to project cwd")
}

// MARK: - (2) seed-paint decision table (§7.2 / §4.8)

private func seedPaintDecisionTable() {
    // fresh join (cold start): replay scrollback + separator, NO agent resume, NO reset.
    let fresh = PtyCreateResult(sessionId: "s", fresh: true)
    check(TerminalSeedPaint.plan(for: fresh) == [.replayScrollback, .coldStartSeparator],
          "seedpaint fresh → replay+separator")

    // warm join with screen: paint (CRLF) + cursor, no reset.
    let warm = PtyCreateResult(sessionId: "s", fresh: false,
                               screen: "line1\nline2\n",
                               cursor: PtyCursor(x: 3, y: 1, visible: true))
    check(TerminalSeedPaint.plan(for: warm) == [
        .paint(screen: "line1\r\nline2"),
        .moveCursor(row: 2, col: 4),
        .setCursorVisible(true)
    ], "seedpaint warm join → paint+cursor")

    // warm join, screen absent: paint nothing (tmux is redrawing).
    let warmNoScreen = PtyCreateResult(sessionId: "s", fresh: false)
    check(TerminalSeedPaint.plan(for: warmNoScreen) == [], "seedpaint warm no-screen → nothing")

    // re-attach after reconnect with screen: RESET first, then paint (RESYNC, never append) (§4.8).
    let reattach = PtyCreateResult(sessionId: "s", fresh: false, screen: "hello\n")
    check(TerminalSeedPaint.plan(for: reattach, isReattach: true) == [
        .reset, .paint(screen: "hello")
    ], "seedpaint reattach → reset+paint")

    // re-attach with no screen: still reset (emulator holds stale content); redraw comes on stream.
    check(TerminalSeedPaint.plan(for: warmNoScreen, isReattach: true) == [.reset],
          "seedpaint reattach no-screen → reset only")

    // joiner WITH screen + coAttachMouse: mouse seq appended AFTER paint.
    let joinerMouse = PtyCreateResult(sessionId: "s", fresh: false, screen: "x\n", coAttachMouse: true)
    check(TerminalSeedPaint.plan(for: joinerMouse) == [
        .paint(screen: "x"),
        .writeCoAttachMouse(seq: NodetermWire.coAttachMouseSeq)
    ], "seedpaint joiner with screen+mouse")

    // joiner WITHOUT screen but coAttachMouse: only the mouse seq.
    let joinerNoScreen = PtyCreateResult(sessionId: "s", fresh: false, coAttachMouse: true)
    check(TerminalSeedPaint.plan(for: joinerNoScreen) == [
        .writeCoAttachMouse(seq: NodetermWire.coAttachMouseSeq)
    ], "seedpaint joiner without screen (mouse only)")

    // closed refusal short-circuits everything.
    let closed = PtyCreateResult(sessionId: "", fresh: false, closed: PtyClosedInfo(by: 7))
    check(TerminalSeedPaint.plan(for: closed) == [.showClosed(by: 7)], "seedpaint closed refusal")

    // unavailable refusal short-circuits.
    let unavail = PtyCreateResult(sessionId: "", fresh: false, unavailable: "ssh")
    check(TerminalSeedPaint.plan(for: unavail) == [.showUnavailable(reason: "ssh")],
          "seedpaint unavailable refusal")

    // hidden cursor after paint.
    let hidden = PtyCreateResult(sessionId: "s", fresh: false, screen: "a\n",
                                 cursor: PtyCursor(x: 0, y: 0, visible: false))
    check(TerminalSeedPaint.plan(for: hidden) == [
        .paint(screen: "a"), .moveCursor(row: 1, col: 1), .setCursorVisible(false)
    ], "seedpaint hidden cursor")

    // LF→CRLF transform: strips EXACTLY ONE trailing newline.
    check(TerminalSeedPaint.lfToCRLF("a\nb\n") == "a\r\nb", "lfToCRLF strips one trailing newline")
    check(TerminalSeedPaint.lfToCRLF("a\nb\n\n") == "a\r\nb\r\n", "lfToCRLF leaves the second trailing newline")
    check(TerminalSeedPaint.lfToCRLF("solo") == "solo", "lfToCRLF no-newline passthrough")

    // resync: reset + paint; empty payload ignored.
    check(TerminalSeedPaint.resyncPlan(screen: "cap\n") == [.reset, .paint(screen: "cap")],
          "resync reset+paint")
    check(TerminalSeedPaint.resyncPlan(screen: "") == [], "resync ignores empty payload")
}

// MARK: - (3) park-signal null encoding (§7.3)

private func parkNullEncodingChecks() {
    // A real resize: both sizes present, viewerId present.
    let real = RpcArgs.encode([
        .value(.string("s")), .value(.number(80)), .value(.number(24)), .value(.string("v"))
    ])
    check(real.undef.isEmpty, "real resize has empty undef")

    // PARK: cols/rows are MEANINGFUL nulls (bare null, NOT in undef); viewerId present.
    let park = RpcArgs.encode([
        .value(.string("s")), .null, .null, .value(.string("v"))
    ])
    check(park.args.count == 4, "park has 4 args")
    check(park.args[1] == .null && park.args[2] == .null, "park cols/rows are JSON null")
    check(park.undef.isEmpty, "park nulls are NOT listed in undef (meaningful nulls, §7.3)")

    // PARK with omitted viewerId: viewerId index IS in undef; cols/rows nulls still are NOT.
    let parkNoViewer = RpcArgs.encode([
        .value(.string("s")), .null, .null, .omitted
    ])
    check(parkNoViewer.undef == [3], "omitted viewerId index in undef")
    check(!parkNoViewer.undef.contains(1) && !parkNoViewer.undef.contains(2),
          "meaningful nulls stay OUT of undef even when a later slot is omitted")
}

// MARK: - (4) input routing (§7.6)

private func inputRoutingChecks() {
    check(TerminalInputRouting.delivery(for: .keystroke("a")) == .write(data: "a"),
          "keystroke → raw write")
    check(TerminalInputRouting.delivery(for: .shiftEnter) == .write(data: "\u{1b}\r"),
          "shiftEnter → ESC+CR write")
    check(TerminalInputRouting.delivery(for: .paste("a\nb")) == .sendText(text: "a\nb", enter: false),
          "multiline paste → send-text enter:false")
    check(TerminalInputRouting.delivery(for: .keystroke("x\ny")) == .sendText(text: "x\ny", enter: false),
          "keystroke carrying newline is force-framed")
    check(TerminalInputRouting.delivery(for: .dictationSend("hi")) == .sendText(text: "hi", enter: true),
          "dictation Send → send-text enter:true")
    check(TerminalInputRouting.delivery(for: .dictationInsert("hi")) == .sendText(text: "hi", enter: false),
          "dictation Insert → send-text enter:false")
    check(TerminalInputRouting.delivery(for: .submitComposed) == .sendText(text: "", enter: true),
          "submitComposed → send-text('', true)")
    check(TerminalInputRouting.requiresFramedDelivery("a\nb"), "multiline requires framed delivery")
    check(!TerminalInputRouting.requiresFramedDelivery("abc"), "single line does not require framing")
}

// MARK: - (5) OSC 52 (§7.7)

private func osc52Checks() {
    let hello = Data("hello".utf8).base64EncodedString()
    check(TerminalOsc52.classify("c;\(hello)") == .write(text: "hello"), "osc52 valid → write")
    check(TerminalOsc52.classify("c;?") == .ignore(.readQuery), "osc52 ? → read-query ignore")
    check(TerminalOsc52.classify("c;") == .ignore(.empty), "osc52 empty payload")
    check(TerminalOsc52.classify("no-separator") == .ignore(.malformed), "osc52 missing ; → malformed")
    check(TerminalOsc52.classify("c;@@not_base64@@") == .ignore(.malformed), "osc52 bad base64 → malformed")
    let tooBig = String(repeating: "A", count: TerminalOsc52.maxBase64Bytes + 1)
    check(TerminalOsc52.classify("c;\(tooBig)") == .ignore(.tooLarge), "osc52 >1MB → tooLarge")
    // selection with an embedded default (p) still splits on the FIRST ;
    check(TerminalOsc52.classify("p;\(hello)") == .write(text: "hello"), "osc52 primary selection")
}

// MARK: - (6) passive close events (§7.5)

private func passiveEventChecks() {
    check(TerminalPassiveEvents.classifyClosed(PtyClosedInfo(by: 3)) == .showClosed(by: 3),
          "closed → showClosed")
    check(TerminalPassiveEvents.classifyClosed(PtyClosedInfo(by: nil)) == .showClosed(by: nil),
          "closed unknown by → showClosed nil")
    check(TerminalPassiveEvents.classifyRecycled(RecycledInfo(ready: true)) == .recreate,
          "recycled ready → recreate")
    check(TerminalPassiveEvents.classifyRecycled(RecycledInfo(ready: false)) == .doNotRespawn,
          "recycled not-ready → doNotRespawn")
    check(TerminalPassiveEvents.shouldRecreate(.recreate), "shouldRecreate true only for recreate")
    check(!TerminalPassiveEvents.shouldRecreate(.showClosed(by: nil)), "closed is not recreate")
    check(!TerminalPassiveEvents.shouldRecreate(.doNotRespawn), "not-ready is not recreate")
}

// MARK: - (7) controller wire encoding (§7.1/7.3/7.4/7.6)

private func controllerEncodingChecks() async {
    let rpc = MockRpc()
    let controller = TerminalSessionController(rpc: rpc)
    let viewerId = "viewer-abc"

    // create carries viewerId + persistKey inside the single options object arg.
    await rpc.stub(RpcMethod.ptyCreate, .object([
        "sessionId": .string("nt-n1"), "fresh": .bool(false)
    ]))
    let opts = TerminalCreatePlan.createOptions(
        for: terminalNode(), in: localProject(), cols: 80, rows: 24, viewerId: viewerId)
    let result = try! await controller.create(opts)
    check(result.sessionId == "nt-n1" && result.fresh == false, "create decodes result")

    let reqs = await rpc.recordedRequests()
    check(reqs.count == 1 && reqs[0].method == RpcMethod.ptyCreate, "create issues pty:create req")
    if case .value(let optionsJSON) = reqs[0].args[0] {
        check(optionsJSON["viewerId"]?.stringValue == viewerId, "create options carry viewerId")
        check(optionsJSON["persistKey"]?.stringValue == "n1", "create options carry persistKey")
        // nil optionals are OMITTED, not null.
        check(optionsJSON["sshRemote"] == nil, "create omits nil sshRemote entirely")
        check(optionsJSON["requireRemote"] == nil, "create omits nil requireRemote entirely")
    } else {
        check(false, "create arg[0] is a value")
    }

    // PARK then KILL must use the SAME viewerId as create.
    await controller.park(sessionId: "nt-n1", viewerId: viewerId)
    await controller.kill(sessionId: "nt-n1", viewerId: viewerId)

    let casts = await rpc.recordedCasts()
    check(casts.count == 2, "park+kill produced 2 casts")

    // park cast: pty:resize [sid, null, null, viewerId]
    let park = casts[0]
    check(park.method == RpcMethod.ptyResize, "park casts pty:resize")
    check(park.args[0] == .value(.string("nt-n1")), "park sid")
    check(park.args[1] == .null && park.args[2] == .null, "park cols/rows are meaningful nulls")
    check(park.args[3] == .value(.string(viewerId)), "park viewerId matches create")
    let parkEnc = RpcArgs.encode(park.args)
    check(parkEnc.undef.isEmpty, "park null-null encodes with empty undef")

    // kill cast: pty:kill [sid, viewerId] — SAME viewerId as create (§7.4).
    let kill = casts[1]
    check(kill.method == RpcMethod.ptyKill, "kill casts pty:kill")
    check(kill.args[0] == .value(.string("nt-n1")), "kill sid")
    check(kill.args[1] == .value(.string(viewerId)), "kill viewerId matches create viewerId")

    // resize with a real size uses .value slots (report path).
    await controller.resize(sessionId: "nt-n1", cols: 100, rows: 30, viewerId: viewerId)
    let casts2 = await rpc.recordedCasts()
    let resize = casts2[2]
    check(resize.args[1] == .value(.number(100)) && resize.args[2] == .value(.number(30)),
          "real resize sends value cols/rows")

    // write CAST raw.
    await controller.write(sessionId: "nt-n1", data: "ls")
    let casts3 = await rpc.recordedCasts()
    check(casts3[3].method == RpcMethod.ptyWrite && casts3[3].args[1] == .value(.string("ls")),
          "write casts pty:write raw")

    // sendText REQ: default enter omitted; explicit enter=false sent.
    await rpc.stub(RpcMethod.ptySendText, .bool(true))
    _ = try! await controller.sendText(persistKey: "n1", text: "block", enter: nil)
    _ = try! await controller.sendText(persistKey: "n1", text: "block", enter: false)
    let reqs2 = await rpc.recordedRequests()
    let st1 = reqs2[1] // after create
    check(st1.method == RpcMethod.ptySendText, "sendText issues pty:send-text")
    check(st1.args[2] == .omitted, "sendText nil enter → omitted (server default true)")
    let st2 = reqs2[2]
    check(st2.args[2] == .value(.bool(false)), "sendText enter:false → value false")

    // readScrollback empty fallback.
    await rpc.stub(RpcMethod.ptyReadScrollback, .string("snap"))
    let snap = try! await controller.readScrollback(persistKey: "n1")
    check(snap == "snap", "readScrollback returns the string")

    // paneCommand null → nil.
    await rpc.stub(RpcMethod.ptyPaneCommand, .null)
    let pc = try! await controller.paneCommand(persistKey: "n1")
    check(pc == nil, "paneCommand null → nil")
}
