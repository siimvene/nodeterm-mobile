# NodetermKit API surface referenced by the App layer

Every NodetermKit symbol the App/Sources code depends on. The integrator diffs this against the
real Kit once all module builders have landed. Grouped by file. Signatures are what the App
*assumes*; if the Kit differs, fix the App call site (or, for the Factory concrete names, fix
`Factory.swift` — the single place that names concrete types).

Verified: the Foundation-only App files (EmulatorInstruction, Osc52, PcmAudio,
ServerWhisperTranscriber, PresenceHello) were compiled + unit-checked against the real Kit in a macOS
mini-package — 26/26 assertions pass. `SessionListModel` (+ `SessionRow`, `ProjectGroup`) has since
MOVED into the Kit (`Sources/NodetermKit/Models/SessionListModel.swift`) so the HOME grouping rule is
covered by `swift test`. The iOS-only files (SwiftUI / SwiftTerm /
UIKit / Speech / AVFoundation) cannot be compiled on this machine; they were authored against the
symbols below by reading the Kit sources.

## Models (Sources/NodetermKit/Models)

- `JSONValue` — cases `.null/.bool/.number/.string/.array/.object`; accessors `.stringValue`,
  `.boolValue`, `.intValue`, `.doubleValue`, `.objectValue`, `.arrayValue`; `subscript(String)`,
  `subscript(Int)`; `.decoded(as:)`; `ExpressibleBy{String,Integer,Float,Boolean,Nil}Literal`.
  (App adds one extension: `static JSONValue.encoding<Encodable>(_:) throws -> JSONValue`.)
- `ServerProfile` — `id, name, baseURL, autoConnect, rememberPassword, insecureHTTP`; `init(...)`;
  `.webSocketURL`; conforms `Identifiable, Hashable, Codable, Sendable`.
- `ConnectionState` — `.connected, .reconnecting, .authRequired, .offline` (RawRepresentable String).
- `Workspace` — `version, activeProjectId, projects`; `init(version:activeProjectId:projects:)`.
- `Project` — `id, name, color, cwd, ssh, nodes, defaultPermissionMode, defaultAccountId, closed,
  unavailable`; `.isSSH`; `init(...)`.
- `Settings` — `claudePermissionMode, defaultShell, tmuxScrollback, claudeAccounts, codexAccounts`; Codable
  (account lists decode PER ROW: one malformed row is skipped, the rest kept).
- `ManagedAccount` — `id, label, email, pending, host`; `.isUsableHere`, `.displayName`; Codable, Identifiable.
- `ClaudeCliCaps` — `autoPermissionMode, sessionIdFlag`; tolerant Codable (missing → false).
- `NewSessionPlan` — `mintNodeId(now:random:)`, `launchCommand(agentId:permissionMode:caps:) -> String?`,
  `resolvePermissionMode(projectMode:settingsMode:) -> String` (desktop's three layers: valid project
  → valid setting → `auto`), `isPermissionMode(_:)`, `defaultPermissionMode`,
  `registerPayload(id:title:agentId:accountId:) -> JSONValue`,
  `derivedTitle(agentId:) -> String` (the canvas's own no-title label — `"Claude Code" / "Codex" /
  "Gemini"`, else `"Mobile session"` — so the phone's synthetic row matches; SPEC §7.11),
  `mergeAccounts(settings:peer:) -> [ManagedAccount]` (settings rows first, `claude-accounts:peer-list`
  rows appended for unseen ids; `RpcMethod.claudeAccountsPeerList`, SPEC §7.11.3).
- `RegistrationOutcome` — `.registered / .unsaved / .unknown`;
  `decide(workspace:loadSucceeded:projectId:nodeId:)` — the §7.11.4 read-back table (a failed load,
  a missing project, or `unavailable == true` ⇒ `.unknown`, never "not saved").
- `LaunchRedelivery` — `.send / .alreadyRunning / .unknown`; `decide(paneCommand:)` — whether a launch
  line may be RE-delivered (only into a bare shell; SPEC §7.11.3).
- `SpawnRecord` — the §7.11 spawn state machine for one phone-spawned node (`Sources/NodetermKit/
  Terminal/SpawnRecord.swift`); `init(projectId:payload:command:createFresh:now:)`,
  `recording(existing:projectId:payload:command:createFresh:now:)` (an existing record is returned
  unchanged — a rejoin can neither re-arm a launch nor re-open a settled registration; no record +
  `createFresh:false` = lost first answer ⇒ launch owed but GATED), `launch` (`.none / .owed(command:
  gated:) / .landed / .dropped`), `notBefore` + `markSettled(now:)` (the 1.5 s `silenceCap`, shortened
  by the view's 200 ms-quiet observation), `launchStep(now:) -> Step` (`.nothing / .wait(until:) /
  .deliver(command:checkPane:)`), `apply(delivery:)` (`.landed / .dropped / .deferred / .transient`),
  `apply(registration:)`, `scheduleRedelivery() -> Bool` (true once; `redeliveryDelay` 3 s),
  `scheduleDropReprobe() -> Bool` (true once; `reprobeDelay` 2 s — a FIRST `.dropped` re-probes
  before concluding, so a transient rc-file child isn't misread as a busy pane),
  `retryLaunch()` (re-arm a concluded `.dropped`, gated), `acknowledgeDrop()` (dismiss the banner),
  `banner -> Banner?` (`.unsaved / .registrationUnknown / .launchUndelivered / .launchDropped`),
  `launchCommand`, `launchOwed`, `registrationPending`, `needsDrive`, `isSettled`, `launchAttempts`,
  `outcome`.
- `SpawnTransportFault` — `.socketGone / .liveDeadline`; `classify(error:stillConnected:)` — splits a
  live-socket `.timeout` (a counted attempt: `.deferred` delivery / proceed to read-back) from a gone
  socket (`.disconnected`, or `.timeout` while offline ⇒ re-driven on reconnect; SPEC §7.11.3/4).
- `SessionRow` — one HOME row (`serverId, serverName, projectId, projectName, nodeId, title, agentId,
  cwd, accountId, projectCwd, sshRemoteTmux, status`); `.badge`, `.unread`, `.showsApproval`.
- `ProjectGroup` — one HOME project card: `id` (= `serverId/projectId`), `serverId, projectId,
  baseTitle, title, projectCwd, rows`; `ProjectGroup.key(serverId:projectId:)`.
- `SessionListModel` — `rows(serverId:serverName:workspace:status:)`,
  `groupedByProject(_:multiServer:) -> [ProjectGroup]` (keyed by (server, project), NOT by title;
  colliding titles get a cwd-basename or ordinal suffix for display), `grouped(_:)`.
- `CanvasNodeState` — `id, kind, title, color, cwd, agentId, accountId, parentId`; `init(...)`.
- `NodeKind` — `.terminal, .sticky, .group, …`; `==`.
- `CanvasMutation` — Codable (decoded from `canvas:mut` arg[1]).
- `AgentStatusEvent` — Codable (decoded from `agent:status` arg[0]).
- `ContextWindowUsage` — `sessionId, usedTokens, windowTokens, usedPercent, model, updatedAt`; Codable.
- `AgentNodeStatus` — `nodeId, state, unread, sessionId, pendingId, askKind, lastTransitionAt,
  context`; `.badge`; `init(...)`.
- `ReducedAgentState` — `.working, .waiting, .blocked, .done, .unknown`.
- `AgentBadge` — `.running, .needsYou, .done, .idle, .none` (`.done` = done AND unread).
- `AskKind` — `.approval, .question, .unknown(String)`.
- `PermissionDecision` — `.allow, .deny`.
- `AnswerPermissionRequest` — `init(nodeId:pendingId:decision:)`; Codable.
- `PtyCreateOptions` — `init(cols:rows:persistKey:viewerId:cwd:shell:shellArgs:ownerProjectId:agentId:
  agentModel:accountId:sshRemote:requireRemote:)`.
- `PtyCreateResult` — `sessionId, fresh, screen, cursor, coAttachMouse, persistent, closed,
  unavailable`; `.isRefusal`.
- `PtyCursor` — `x, y, visible`.
- `PtyClosedInfo` — `by`.
- `PtyGrid` — `cols, rows`; Codable (decoded from `pty:size` arg[0]).
- `SpeechModelInfo` — Codable (returned by `speech:models`).
- `SpeechTranscribeRequest` — `init(pcm:language:)`; Codable.
- `SpeechTranscribeResult` — `text`; Codable.
- `PeerKind` — `.phone` (uses `.wire`).
- `NodetermWire` — `coAttachMouseSeq`, `shiftEnterSeq`.
- `RpcMethod` — `workspaceLoad`, `settingsLoad`, `workspaceRegisterNode`, `claudeCliCaps`,
  `agentAnswerPermission`, `agentAckDone`, `speechTranscribe`, `speechModels`.
- `RpcArg` — `.value(JSONValue)`, `.null`, `.omitted`; `init(_ value:)`.

## Protocols (Sources/NodetermKit/Contracts.swift)

- `FrameTransporting` — named only as a type annotation in `Factory` (constructed concrete).
- `RpcClienting` — `start()`, `stop()`, `request(_:_:) -> JSONValue`, `cast(_:_:)`,
  `subscribe(_:) -> AsyncStream<[JSONValue]>`, `ptyData(for:) -> AsyncStream<Data>`,
  `connectionStates() -> AsyncStream<ConnectionState>`, `connectionState() -> ConnectionState`.
- `AuthClienting` — `login(baseURL:password:) -> String`, `logout(baseURL:cookie:)`,
  `setup(baseURL:token:password:) -> String`, `detectUnconfigured(baseURL:) -> Bool`.
- `AuthError` — `.wrongPassword, .rateLimited, .badRequest, .alreadyConfigured, .invalidSetup,
  .missingSetCookie, .network`.
- `KeychainStoring` — `saveCookie/cookie/deleteCookie`, `savePassword/password/deletePassword`,
  `deleteAll(forServer:)`.
- `ServerProfileStoring` — `all()`, `profile(id:)`, `add(_:)`, `update(_:)`, `remove(id:)`.
- `WorkspaceStoring` — `replace(with:)`, `apply(_:projectId:)`, `snapshot()`, `project(id:)`.
- `AgentStatusReducing` — `ingest(_:onScreen:)`, `ingestContext(_:)`, `clearUnread(nodeId:)`,
  `markViewed(nodeId:) -> Bool`, `status(for:)`, `all()`.
- `TerminalSessionControlling` — `create(_:) -> PtyCreateResult`, `write(sessionId:data:)`,
  `resize(sessionId:cols:rows:viewerId:)`, `park(sessionId:viewerId:)`, `kill(sessionId:viewerId:)`,
  `readScrollback(persistKey:) -> String`, `sendText(persistKey:text:enter:) -> Bool`,
  `capture(persistKey:full:) -> String`, `paneCommand(persistKey:) -> String?`,
  `tmuxStatus() -> TmuxStatus`. (v0 UI uses create/write/resize/park/kill/readScrollback/sendText, and
  paneCommand for a spawn launch RE-delivery check; capture/tmuxStatus are available but not yet surfaced.)
- `SpeechTranscribing` — `transcribe(pcm:language:) -> String`, `availableModels() -> [SpeechModelInfo]`.

## Concrete types expected from the OTHER builders — named ONLY in `Factory.swift`

These are now VERIFIED against the landed Kit and wired in `Factory.swift` (still guarded behind
`NODETERM_KIT_IMPL_READY`). The "assumed" names in the original skeleton drifted from what the Kit
builders actually shipped; the real names/inits are below.

| Protocol | Concrete name / init (verified) | Was (skeleton guess) |
|---|---|---|
| `KeychainStoring` | `KeychainService()` | `KeychainStore()` |
| `ServerProfileStoring` | `try ServerProfileStore()` (init throws) | `ServerProfileStore()` |
| `AuthClienting` | `AuthClient()` | `HTTPAuthClient()` |
| `FrameTransporting` | `WebSocketFrameTransport(url:cookieValue:)` | `…(url:cookie:)` |
| `RpcClienting` | `RpcClient(makeTransport:)` (transport FACTORY, §4.8 reconnect) | `WSRpcClient(transport:)` |
| `WorkspaceStoring` | `WorkspaceStore()` | `WorkspaceSnapshotStore()` |
| `AgentStatusReducing` | `AgentStatusStore()` (the actor; `AgentStatusReducer` is the pure enum it folds through) | `AgentStatusReducer()` |
| `TerminalSessionControlling` | `TerminalSessionController(rpc:)` | `CoAttachTerminalControl(rpc:)` |

`AppleSpeechTranscriber` and `ServerWhisperTranscriber` are THIS builder's own types (App layer).

## Interface gaps / deviations (see the return summary)

1. **Duplicate seed-paint enum: Kit `EmulatorInstruction`/`TerminalSeedPaint` vs App
   `EmulatorInstruction`/`SeedPaint`.** The skeleton assumed no Kit enum existed and built an
   App-layer one (`App/Sources/Terminal/EmulatorInstruction.swift`). A Kit builder has since landed
   `NodetermKit.EmulatorInstruction` + `NodetermKit.TerminalSeedPaint` (SPEC §7.2/§4.8/§7.8) with a
   DIFFERENT shape (Kit: `paint(screen:)`, `moveCursor(row:col:)`, `setCursorVisible`,
   `writeCoAttachMouse(seq:)`, `replayScrollback`, `showClosed`, `showUnavailable`; App: `feedRaw`,
   `paintCapture`, `cursor(x:y:visible:)`, `coAttachMouse`). This is NOT a compile collision — they
   live in different modules and the App's own type wins for unqualified lookup inside the App
   target — so the App keeps its self-contained, unit-verified version (SwiftTermView + VM already
   drive it). Converging on the Kit enum means rewriting `SwiftTermView`/`TerminalSessionVM`, which
   cannot be compile-verified on this machine (no iOS SDK); left as a deliberate follow-up rather
   than an unverifiable rewrite.
2. **`pty:size` letterboxing** (SPEC §7.3) is not implemented — `TerminalHandle.applyGrid` resizes
   the emulator to the authoritative grid but does not letterbox the slack. Follow-up.
3. **OSC 52** is taken from SwiftTerm's `clipboardCopy(source:content:)` delegate (already decoded,
   write-only). The App-layer `Osc52` parser is retained for the raw path if the integrator routes
   OSC bytes directly; SPEC §7.7 write-only + read-query-ignore is enforced there.
4. **`presence:hello` arg shape** is UNPINNED (SPEC §12 item 6) — sent as `[{name, kind:"phone"}]`.
5. **`pty:exit` payload** is UNVERIFIED (SPEC §12 item 7) — read as `{exitCode}` with a bare-number
   fallback.
6. `TmuxStatus` "tmux not found" banner (SPEC §11.5) is not yet surfaced in the UI (method wired in
   the protocol, no screen). Follow-up.

## Known gaps — New Session flow (SPEC §7.11), deferred from the 2026-09-06 cross-vendor review

7. **A re-auth replaces the `ServerRuntime`, and the in-memory spawn records go with it.** A spawn
   still pending its launch or registration when the session is re-authenticated (a fresh runtime
   is built) is forgotten: the session runs, but nobody types its launch or registers it, and no
   banner says so. The records would need to persist per server (or survive the runtime swap) to
   close this. Deferred: re-auth mid-spawn is a narrow window; the drive is otherwise re-run on
   every reconnect.
8. **`ClaudeCliCaps.sessionIdFlag` is probed and unused.** The desktop pins a Claude session id at
   launch through `--session-id`; the phone's `register-node` payload carries no such field and the
   launch line does not pass one, so a phone-spawned Claude session gets its id from the CLI. Wired
   into the caps model for parity; the flag is honored once the register payload can carry it.
