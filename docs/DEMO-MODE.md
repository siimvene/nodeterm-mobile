# Demo mode

## Why it exists

The App Store reviewer sits on the public internet with no Tailscale, no server, and no
credentials. Termscape is a client for a self-hosted **nodeterm Server Edition**, so without a
zero-setup demo the app is untestable and gets rejected under **Guideline 2.1** (can't test) /
**4.2** (minimum functionality). Demo mode is the one remaining hard blocker before submission.

It is dual-purpose: the same flow is the real first-run onboarding, so it ships in production, not
behind a build flag.

## Target (done =)

On a fresh install in **airplane mode**, the reviewer taps one control on the first screen and
within ~30s is driving the *real* UI: Home → project/session list → a live-looking terminal → an
agent badge flipping working→done → a transcript. The real login/connect flow stays byte-identical
for non-demo servers.

## The insertion point (verified against the code)

Everything above the socket depends only on Kit protocols (`Contracts.swift`), and
`Factory.makeRuntime` is the single assembly seam that builds `FrameTransport → RpcClient → stores
→ terminal`. So demo mode fakes exactly **one** type and reuses the entire real stack:

- **`DemoFrameTransport: FrameTransporting`** (`Sources/NodetermKit/Demo/`) — the 4-method
  transport protocol (`connect` / `send` / `receive` / `close`). `send(text)` matches the outgoing
  RPC method and enqueues canned responses; `receive()` yields those plus scripted push events
  (agent-status, binary pty frames) on a short timer. When the script is exhausted, `receive()`
  **suspends** — it must never throw, or `RpcClient` would spin its reconnect/backoff loop.
- **`DemoScript`** (`Sources/NodetermKit/Demo/`) — the canned dataset: 2 projects, ~4 sessions
  including one `claude` agent, a working→done status cycle, believable pty output for a claude
  turn, a transcript payload, a usage snapshot. Shaped exactly per the real wire contract so the
  real decoder accepts it.
- **`ServerProfile.isDemo`** (default `false`, back-compatible Codable) — marks the synthetic demo
  profile. Never persisted to `ProfileStore`, never writes the Keychain.
- **`Factory.makeDemoRuntime(...)`** — builds `RpcClient(makeTransport: { DemoFrameTransport(...) })`
  with the same object graph as `makeRuntime`. The real `RpcClient`, stores,
  `TerminalSessionController`, and SwiftTerm view run unchanged.
- **Entry UX** — an "Explore a demo" button on the Home empty-state and AddServer screen; a "Demo"
  chip on the row; one-tap exit that returns to the empty state leaving no phantom server.

The reviewer sees the actual app behavior, not a mock screen, because only the bytes below the
transport are synthetic.

## Phases (each independently verifiable)

- **P1 — plumbing.** `DemoFrameTransport` + `DemoScript` + `ServerProfile.isDemo` +
  `makeDemoRuntime` + entry button, driven by a canned script. **DoD:** airplane-mode Home shows
  demo projects; tapping a session mounts the terminal view.
- **P2 — the dataset.** The frames the script replays. The initial dataset is **hand-authored**
  against the verified wire shapes (the existing `WireCodecTests` / `RpcCodecTests` /
  `RpcClientTests` encode real JSON examples to copy from). **DoD:** terminal shows a believable
  agent turn; badge flips; transcript opens.
- **P3 — polish + safety.** Demo cannot persist or write the Keychain; server-Whisper dictation
  hidden in demo (Apple on-device speech works offline, kept); usage block fed a canned frame or
  hidden; script end does not spin the reconnect loop; real flow untouched. **DoD:** full
  airplane-mode walkthrough; exit demo → clean empty state.

## Verification reality

`swift test` runs the **NodetermKit** suite on this Mac; the **iOS App target cannot be compiled
from the CommandLineTools CLI** (no full Xcode / simulator SDK here). So the design pushes the
verifiable logic **into the Kit**: `DemoFrameTransport`, `DemoScript`, and a `DemoModeTests` that
drives the **real** `RpcClient` + stores through the demo transport are covered by `swift test`.
The App-target glue (`Factory`, `AppEnvironment`, Home/AddServer entry) is thin and pattern-mirrors
existing code, but is **not build-verified here** — it needs one Xcode build on Siim's Mac before
demo mode is "done-done".

## Ships with (App Store Connect review notes)

> No account needed — tap "Explore a demo" on the first screen. For real use, run the open-source
> nodeterm Server Edition (link) and add your own server.

## Follow-up: real captured frames (optional upgrade)

The hand-authored dataset is enough for review and onboarding. To make it maximally realistic,
capture real frames later: a temporary tap in `WebSocketFrameTransport` dumps `WSMessage`s to a
file during a ~2-min real session, curate + **redact hostnames/paths/secrets** (non-negotiable — it
ships in a public binary), and swap the resource into `DemoScript`. Realistic and decode-safe
because it is exactly what the app expects.

## Surfaces

iOS only (this repo). Desktop / Server Edition: N/A.
