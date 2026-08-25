# NodetermKit API surface referenced by the App layer

Every NodetermKit symbol the App/Sources code depends on. The integrator diffs this against the
real Kit once all module builders have landed. Grouped by file. Signatures are what the App
*assumes*; if the Kit differs, fix the App call site (or, for the Factory concrete names, fix
`Factory.swift` — the single place that names concrete types).

Verified: the six Foundation-only App files (EmulatorInstruction, Osc52, PcmAudio,
ServerWhisperTranscriber, SessionListModel, PresenceHello) were compiled + unit-checked against the
real Kit in a macOS mini-package — 26/26 assertions pass. The iOS-only files (SwiftUI / SwiftTerm /
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
- `Project` — `id, name, color, cwd, ssh, nodes, closed, unavailable`; `.isSSH`; `init(...)`.
- `CanvasNodeState` — `id, kind, title, color, cwd, agentId, accountId, parentId`; `init(...)`.
- `NodeKind` — `.terminal, .sticky, .group, …`; `==`.
- `CanvasMutation` — Codable (decoded from `canvas:mut` arg[1]).
- `AgentStatusEvent` — Codable (decoded from `agent:status` arg[0]).
- `ContextWindowUsage` — `sessionId, usedTokens, windowTokens, usedPercent, model, updatedAt`; Codable.
- `AgentNodeStatus` — `nodeId, state, unread, sessionId, pendingId, askKind, lastTransitionAt,
  context`; `.badge`; `init(...)`.
- `ReducedAgentState` — `.working, .waiting, .blocked, .done, .unknown`.
- `AgentBadge` — `.running, .needsYou, .idle, .none`.
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
- `RpcMethod` — `workspaceLoad`, `agentAnswerPermission`, `agentAckDone`, `speechTranscribe`,
  `speechModels`.
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
  `tmuxStatus() -> TmuxStatus`. (v0 UI uses create/write/resize/park/kill/readScrollback/sendText;
  capture/paneCommand/tmuxStatus are available but not yet surfaced.)
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
