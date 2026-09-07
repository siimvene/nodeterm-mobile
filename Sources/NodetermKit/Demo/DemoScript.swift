import Foundation

// The canned dataset the demo transport replays (docs/DEMO-MODE.md, P2). Every frame is built from
// the SAME typed wire models the real decoders consume (`Workspace`, `AgentStatusEvent`,
// `PtyCreateResult`, `AccountUsageUpdate`, `ChatTranscriptResult`, …) and then flattened to a
// `JSONValue`, so the shapes are correct BY CONSTRUCTION — there is no hand-typed JSON to drift out
// of sync with the models. The App reads by key (`RpcFrame.parse`), so field order never matters.
//
// Nothing here touches the network, the Keychain, or a real `ServerProfile` on disk: `DemoScript`
// is pure data + pure builders, and `DemoScript.profile` is the synthetic `isDemo` server that the
// App never persists (docs/DEMO-MODE.md §P3).

/// One synthetic push the transport emits, unsolicited, after `connect()` — an `ev` frame or a
/// binary pty frame, each after a small delay so the badge machine and the terminal animate the way
/// a live session would. `delayMs` is the pause BEFORE the item is delivered.
public enum DemoPush: Sendable {
    /// An `ev` frame: `channel` + already-decoded `args` (the transport wraps them as `t:"ev"`).
    case event(channel: String, args: [JSONValue], delayMs: Int)
    /// A binary pty output frame (server→client), pre-encoded to the §4.5 byte layout.
    case binary(Data, delayMs: Int)
}

public enum DemoScript {

    // MARK: - Stable identifiers (referenced by tests + the App entry UX)

    public static let webProjectId = "demo-web"
    public static let infraProjectId = "demo-infra"

    /// The one `claude` agent session the walkthrough animates.
    public static let claudeNodeId = "nt-claude-1"
    /// The tmux session id `pty:create` returns and the binary pty frames are tagged with. Distinct
    /// from the AGENT session id below (tmux name vs. the CLI's own resumable session — §7.2/§6.2).
    public static let claudeTmuxSessionId = "nt-claude-1"
    /// The agent (transcript) session id carried on `agent:status` / `context:update`.
    public static let claudeAgentSessionId = "sess-claude-1"

    /// A node the live `canvas:mut` push adds mid-run, to prove the store stays live.
    public static let liveAddedNodeId = "nt-term-live"

    // MARK: - The synthetic server profile (never persisted, never keychained)

    public static let profile = ServerProfile(
        id: "demo",
        name: "Demo Workspace",
        baseURL: URL(string: "https://demo.termscape.local")!,
        autoConnect: true,
        rememberPassword: false,
        insecureHTTP: false,
        isDemo: true
    )

    // MARK: - Workspace (2 projects, 4 terminal sessions incl. one claude, + a sticky note)

    public static let workspace = Workspace(
        version: 2,
        activeProjectId: webProjectId,
        projects: [
            Project(
                id: webProjectId,
                name: "termscape-web",
                color: "#5B8DEF",
                nodes: [
                    CanvasNodeState(
                        id: claudeNodeId, kind: .terminal, title: "claude · refactor auth",
                        color: "#C9A227", cwd: "/home/dev/termscape-web",
                        agentId: "claude", accountId: nil, sshRemoteTmux: false
                    ),
                    CanvasNodeState(
                        id: "nt-dev-1", kind: .terminal, title: "dev server",
                        color: "#3FB950", cwd: "/home/dev/termscape-web",
                        agentId: nil
                    ),
                    CanvasNodeState(
                        id: "nt-note-1", kind: .sticky, title: "release checklist",
                        color: "#E3B341"
                    ),
                ]
            ),
            Project(
                id: infraProjectId,
                name: "infra",
                color: "#DB6D28",
                nodes: [
                    CanvasNodeState(
                        id: "nt-codex-1", kind: .terminal, title: "codex · terraform plan",
                        color: "#A371F7", cwd: "/home/dev/infra",
                        agentId: "codex"
                    ),
                    CanvasNodeState(
                        id: "nt-logs-1", kind: .terminal, title: "prod logs",
                        color: "#8B949E", cwd: "/home/dev/infra",
                        agentId: nil
                    ),
                ]
            ),
        ]
    )

    // MARK: - Believable pty output for the claude turn (real ANSI)

    /// The co-attach seed screen (LF-separated, no CR — the App rewrites LF→CRLF; §7.2).
    public static let seedScreen =
        "\u{1b}[1;38;5;179m✻ Claude Code\u{1b}[0m  \u{1b}[2m/home/dev/termscape-web\u{1b}[0m\n" +
        "\n" +
        "\u{1b}[2m> refactor the auth middleware to reject expired cookies\u{1b}[0m\n"

    /// First live chunk: a working banner + a tool line, with SGR color, a spinner glyph and a CR
    /// progress rewrite — the kind of bytes a claude turn actually streams.
    static let ptyChunk1 =
        "\u{1b}[38;5;179m⏺\u{1b}[0m Reading \u{1b}[1msrc/auth/middleware.ts\u{1b}[0m\n" +
        "\u{1b}[2m  ⎿  Read 214 lines\u{1b}[0m\n" +
        "\u{1b}[36m∴\u{1b}[0m thinking\u{1b}[38;5;240m…\u{1b}[0m\r" +
        "\u{1b}[36m∴\u{1b}[0m editing \u{1b}[38;5;240m…\u{1b}[0m"

    /// Second live chunk: the edit result + a green success line, closing the turn.
    static let ptyChunk2 =
        "\r\u{1b}[K\u{1b}[38;5;179m⏺\u{1b}[0m Edit \u{1b}[1msrc/auth/middleware.ts\u{1b}[0m\n" +
        "\u{1b}[32m  +12 \u{1b}[31m-4\u{1b}[0m  reject when \u{1b}[3mexpiresAt < now\u{1b}[0m\n" +
        "\u{1b}[32m✓\u{1b}[0m auth middleware now rejects expired cookies\n"

    // MARK: - Canned request/response bodies (keyed by RPC method)

    /// The `result` payload for a client `req`, matched by METHOD (the transport reuses the req's
    /// own id in the `res`). `nil` ⇒ the demo does not serve that method (the transport answers
    /// `E_NO_HANDLER`, exactly as a real edition would for an unserved method).
    public static func cannedResult(forMethod method: String) -> JSONValue? {
        switch method {
        case RpcMethod.workspaceLoad:
            return demoEncode(workspace)

        case RpcMethod.ptyCreate:
            return demoEncode(PtyCreateResult(
                sessionId: claudeTmuxSessionId,
                fresh: false,
                screen: seedScreen,
                cursor: PtyCursor(x: 0, y: 3, visible: true),
                coAttachMouse: true,
                persistent: true
            ))

        case RpcMethod.ptyReadScrollback:
            return .string(seedScreen)

        case RpcMethod.ptyCapture:
            return .string(seedScreen + ptyChunk1 + ptyChunk2)

        case RpcMethod.ptyPaneCommand:
            return .string("claude")

        case RpcMethod.ptyTmuxStatus:
            return demoEncode(TmuxStatus(available: true, platform: "linux"))

        case RpcMethod.ptySendText:
            return .bool(true)

        case RpcMethod.chatReadTranscript, RpcMethod.claudeReadTranscript:
            return demoEncode(transcript)

        // Fire-and-forget from the App's side (reply ignored). Answer OK so no id is left pending.
        case RpcMethod.agentAnswerPermission, RpcMethod.agentAckDone:
            return .null

        default:
            return nil
        }
    }

    /// A short but structurally complete transcript: a user turn and an assistant turn carrying
    /// thinking + text + a tool part with a diff summary (every `ChatPart` kind the App renders).
    public static let transcript = ChatTranscriptResult(
        messages: [
            ChatMessage(role: .user, parts: [
                .text("refactor the auth middleware to reject expired cookies")
            ]),
            ChatMessage(role: .assistant, parts: [
                .thinking("The guard only checks presence, not expiry. Compare expiresAt to now."),
                .tool(
                    name: "Edit",
                    arg: .object(["file": .string("src/auth/middleware.ts")]),
                    result: "applied",
                    summary: ChatToolSummary(filePath: "src/auth/middleware.ts", added: 12, removed: 4)
                ),
                .text("Done — the middleware now rejects any cookie whose expiresAt is in the past."),
            ]),
        ],
        found: true
    )

    // MARK: - The usage snapshot (Home dashboard)

    public static let usage = AccountUsageUpdate(
        updatedAt: 1_735_600_000_000,
        accounts: [
            AccountUsage(
                accountId: nil, label: "System account", email: nil,
                agentId: "claude", status: "ok", updatedAt: 1_735_600_000_000,
                limits: [
                    AccountUsageLimit(kind: "session_5h", group: nil, usedPercent: 42,
                                      severity: "ok", resetsAt: 1_735_617_600_000,
                                      windowMinutes: 300, scopeLabel: nil),
                    AccountUsageLimit(kind: "weekly", group: nil, usedPercent: 18,
                                      severity: "ok", resetsAt: 1_736_100_000_000,
                                      windowMinutes: 10_080, scopeLabel: nil),
                ]
            )
        ]
    )

    // MARK: - The unsolicited push sequence (after connect)

    /// Built once; delivered in order by the transport with the per-item delay. The order mirrors a
    /// real turn: the session goes `working`, the meter fills, usage + a live node arrive, the pane
    /// streams two chunks, then the turn ends `done`.
    public static var pushes: [DemoPush] {
        var out: [DemoPush] = []

        // 1) working
        out.append(.event(
            channel: "agent:status",
            args: [demoEncode(AgentStatusEvent(
                nodeId: claudeNodeId, agentId: "claude", kind: .state,
                state: .working, sessionId: claudeAgentSessionId
            ))],
            delayMs: 40
        ))

        // 2) context meter
        out.append(.event(
            channel: "context:update",
            args: [demoEncode(ContextWindowUsage(
                sessionId: claudeAgentSessionId, usedTokens: 42_000, windowTokens: 200_000,
                usedPercent: 21, model: "claude-opus", updatedAt: 1_735_600_000_000
            ))],
            delayMs: 15
        ))

        // 3) usage snapshot
        out.append(.event(channel: "accounts:usage", args: [demoEncode(usage)], delayMs: 15))

        // 4) a live node appears on the active project (proves canvas:mut keeps the list live)
        out.append(.event(
            channel: "canvas:mut",
            args: [
                .string(webProjectId),
                demoEncode(CanvasMutation.upsert(
                    node: CanvasNodeState(
                        id: liveAddedNodeId, kind: .terminal, title: "test watcher",
                        color: "#3FB950", cwd: "/home/dev/termscape-web"
                    ),
                    seq: 5
                )),
            ],
            delayMs: 15
        ))

        // 5) + 6) the pane streams
        if let f1 = PtyBinaryFrame.encode(sessionId: claudeTmuxSessionId, text: ptyChunk1) {
            out.append(.binary(f1, delayMs: 20))
        }
        if let f2 = PtyBinaryFrame.encode(sessionId: claudeTmuxSessionId, text: ptyChunk2) {
            out.append(.binary(f2, delayMs: 60))
        }

        // 7) done — the working→done edge the badge machine reduces
        out.append(.event(
            channel: "agent:status",
            args: [demoEncode(AgentStatusEvent(
                nodeId: claudeNodeId, agentId: "claude", kind: .state,
                state: .done, sessionId: claudeAgentSessionId
            ))],
            delayMs: 40
        ))

        return out
    }
}

// MARK: - Encoding helper

/// Flatten a typed wire model into a `JSONValue`. The dataset is hand-authored from well-formed
/// Codable models, so this round-trip cannot fail at runtime — a throw would be an authoring bug,
/// which is exactly what a fatal `try!` documents here (never reached for the shipped data).
func demoEncode<T: Encodable>(_ value: T) -> JSONValue {
    let data = try! JSONEncoder().encode(value)
    return try! JSONDecoder().decode(JSONValue.self, from: data)
}
