import Foundation
import Testing
@testable import NodetermKit

// Demo-mode end-to-end: the REAL stack (actor `RpcClient`, `WorkspaceStore`, `AgentStatusStore`,
// `TerminalSessionController`) driven entirely by `DemoFrameTransport` + `DemoScript` — no server,
// no network (docs/DEMO-MODE.md). This exercises the concrete types, not mocks: the only synthetic
// element is the transport below the socket, so the connect → workspace:load → subscribe → request
// path is byte-identical to a live server.
//
// Registered directly as a swift-testing `@Test` (RegisteredTests.swift is left untouched — the
// demo is purely additive). The body aborts via `precondition` on the first failed assertion, the
// same convention the sibling framework-free suites use.

@Test func demoModeDrivesRealStack() async { await runDemoModeTests() }

@inline(__always)
private func expect(_ condition: Bool, _ label: String) {
    precondition(condition, "demo-mode test failed: \(label)")
}

private func waitUntil(timeoutMs: Int = 5000, _ cond: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if await cond() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await cond()
}

private actor Box<T: Sendable> {
    private var value: T
    init(_ initial: T) { value = initial }
    func set(_ v: T) { value = v }
    func get() -> T { value }
}

public func runDemoModeTests() async {
    // Build the REAL object graph. `makeTransport` hands RpcClient a fresh demo transport per
    // connect (only one is ever built — the demo never drops the socket).
    let client = RpcClient(makeTransport: { DemoFrameTransport() })
    let workspaceStore = WorkspaceStore()
    let statusStore = AgentStatusStore()
    let terminal = TerminalSessionController(rpc: client)

    await client.start()

    // 1) Connect flow: the demo socket opens, RpcClient reports `.connected`.
    let connected = await waitUntil { await client.connectionState() == .connected }
    expect(connected, "client reached .connected over the demo transport")

    // Wire the event channels BEFORE anything else, exactly as ServerRuntime does — early events
    // buffer in the client and replay to the first subscriber (§4.9), so nothing is lost.
    let statusStream = await client.subscribe("agent:status")
    let contextStream = await client.subscribe("context:update")
    let usageStream = await client.subscribe("accounts:usage")
    let canvasStream = await client.subscribe("canvas:mut")

    // Consumer: fold agent:status into the real reducer (off-screen, so the working→done edge sets
    // unread — the desktop-parity badge behavior).
    let statusTask = Task {
        for await args in statusStream { await statusStore.ingestRawStatus(args, onScreen: false) }
    }
    let contextTask = Task {
        for await args in contextStream { await statusStore.ingestRawContext(args) }
    }
    let usageBox = Box<AccountUsageUpdate?>(nil)
    let usageTask = Task {
        for await args in usageStream {
            if let u = try? args.first?.decoded(as: AccountUsageUpdate.self) { await usageBox.set(u) }
        }
    }
    // canvas:mut carries TWO args: projectId + delta (§6.4). Apply to the real workspace store.
    let canvasTask = Task {
        for await args in canvasStream {
            guard args.count >= 2, let projectId = args[0].stringValue,
                  let mut = try? args[1].decoded(as: CanvasMutation.self) else { continue }
            await workspaceStore.apply(mut, projectId: projectId)
        }
    }

    // 2) workspace:load — the FIRST request of the run, so its id is 1; the demo echoes that id.
    let loadResult = try! await client.request(RpcMethod.workspaceLoad, [])
    let ws = try! loadResult.decoded(as: Workspace.self)
    await workspaceStore.replace(with: ws)

    expect(ws.version == 2, "workspace decoded")
    expect(ws.activeProjectId == DemoScript.webProjectId, "active project is the web project")
    expect(ws.projects.count == 2, "two demo projects")

    // The session list = terminal nodes across non-closed projects (SessionListModel rule).
    let terminalNodes = ws.projects.flatMap { $0.nodes }.filter {
        if case .terminal = $0.kind { return true }; return false
    }
    expect(terminalNodes.count == 4, "four terminal sessions (got \(terminalNodes.count))")
    let claude = terminalNodes.first { $0.id == DemoScript.claudeNodeId }
    expect(claude != nil, "the claude session is present")
    expect(claude?.agentId == "claude", "claude node carries agentId=claude")

    // The store adopted it and dropped nothing terminal.
    let snap = await workspaceStore.snapshot()
    expect(snap?.projects.count == 2, "store holds both projects")

    // 3) Badge machine: the claude session transitions working → done.
    let sawWorking = await waitUntil {
        await statusStore.status(for: DemoScript.claudeNodeId)?.state == .working
    }
    expect(sawWorking, "claude session observed in .working")
    let workingBadge = await statusStore.status(for: DemoScript.claudeNodeId)?.badge
    expect(workingBadge == .running, "working ⇒ RUNNING badge")

    let sawDone = await waitUntil {
        await statusStore.status(for: DemoScript.claudeNodeId)?.state == .done
    }
    expect(sawDone, "claude session observed in .done")
    let final = await statusStore.status(for: DemoScript.claudeNodeId)
    expect(final?.badge == .idle, "done ⇒ idle badge (no NEEDS-YOU)")
    expect(final?.unread == true, "working→done off-screen set the unread dot (§6.3 rule 8)")

    // 4) Context meter merged by sessionId (a DIFFERENT channel folded into the same node).
    let sawContext = await waitUntil {
        await statusStore.status(for: DemoScript.claudeNodeId)?.context != nil
    }
    expect(sawContext, "context:update merged into the claude node")
    let ctx = await statusStore.status(for: DemoScript.claudeNodeId)?.context
    expect(ctx?.usedPercent == 21, "context meter reads the canned 21%")

    // 5) A pty frame reaches the terminal path — BOTH the co-attach create result and the live
    //    binary stream.
    let createResult = try! await terminal.create(
        PtyCreateOptions(cols: 80, rows: 24,
                         persistKey: DemoScript.claudeNodeId, viewerId: "viewer-demo-1",
                         cwd: "/home/siim/termscape-web", agentId: "claude")
    )
    expect(createResult.sessionId == DemoScript.claudeTmuxSessionId, "pty:create returned the session id")
    expect(createResult.fresh == false, "warm co-attach (fresh=false)")
    expect(createResult.screen?.isEmpty == false, "seed screen present to paint")
    expect(createResult.coAttachMouse == true, "co-attach mouse enable flagged")

    let ptyStream = await client.ptyData(for: DemoScript.claudeTmuxSessionId)
    let ptyBox = Box<Data>(Data())
    let ptyTask = Task {
        for await chunk in ptyStream {
            var d = await ptyBox.get(); d.append(chunk); await ptyBox.set(d)
        }
    }
    let gotBytes = await waitUntil { await ptyBox.get().count > 0 }
    expect(gotBytes, "binary pty frame decoded and reached the ptyData stream")
    let ptyBytes = await ptyBox.get()
    expect(ptyBytes.contains(0x1b), "pty output carries real ANSI (ESC) bytes")

    // 6) Usage snapshot decoded read-as-is for the Home dashboard.
    let sawUsage = await waitUntil { await usageBox.get() != nil }
    expect(sawUsage, "accounts:usage event delivered")
    let usage = await usageBox.get()
    expect(usage?.accounts.count == 1, "one usage account")
    expect(usage?.accounts.first?.limits.first?.usedPercent == 42, "canned session_5h at 42%")

    // 7) canvas:mut kept the list live — a node the load did NOT contain now exists.
    let sawLiveNode = await waitUntil {
        let p = await workspaceStore.project(id: DemoScript.webProjectId)
        return p?.nodes.contains { $0.id == DemoScript.liveAddedNodeId } ?? false
    }
    expect(sawLiveNode, "canvas:mut upsert added the live node to the store")

    // 8) A transcript request round-trips through the real controller path (chat:read-transcript).
    let transcriptJSON = try! await client.request(RpcMethod.chatReadTranscript,
                                                   [.omitted, .value(.string("/home/siim/termscape-web")), .omitted])
    let transcript = try! transcriptJSON.decoded(as: ChatTranscriptResult.self)
    expect(transcript.found, "transcript resolved (found=true)")
    expect(transcript.messages.count == 2, "user + assistant turns present")

    // 9) markViewed on a done node asks the caller to ack; the ack request completes without error.
    let shouldAck = await statusStore.markViewed(nodeId: DemoScript.claudeNodeId)
    expect(shouldAck, "a done node acks on view (§6.3 rule 8)")
    let ackReply = try! await client.request(RpcMethod.agentAckDone,
                                             [.value(.string(DemoScript.claudeNodeId))])
    expect(ackReply.isNull, "agent:ack-done answered")

    // Teardown — close() ends the receive suspension; stop() must not hang.
    statusTask.cancel(); contextTask.cancel(); usageTask.cancel()
    canvasTask.cancel(); ptyTask.cancel()
    await client.stop()
}
