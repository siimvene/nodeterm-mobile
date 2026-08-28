# Remote Claude

A native iOS client for a self-hosted **nodeterm Server Edition** — attach to your
terminal sessions and Claude Code (or Codex / Gemini / …) agents from your phone,
over your own network. No relay, no cloud middleman: the app talks straight to a
server you run, at an address you configure (a Tailscale MagicDNS name works well).

Built in Swift (SwiftUI + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)),
with a dependency-free protocol core (`NodetermKit`) that is unit-tested on macOS.

> Companion app for a self-hosted nodeterm server. This repository is the **client only** —
> it speaks the server's WebSocket-RPC protocol.

---

## What it does

- **Multi-server** — add any number of self-hosted servers, each a profile with its
  own base URL and password. Session cookies live in the iOS Keychain, scoped per
  server profile; nothing is stored in `UserDefaults` or synced.
- **Live sessions, grouped by project** — collapsible project cards with per-project
  session/agent counts and a running counter fed by live agent status over the wire.
- **Real terminals** — each session is a live co-attached tmux view via SwiftTerm.
  Touch-scroll through history, drag to select, an accessory toolbar for the keys a
  soft keyboard lacks (Esc, arrows, Paste, Mic, ⇧⏎), and a one-tap keyboard dismiss.
- **Account usage** — Settings → Usage shows every managed account's rate-limit
  windows (session / weekly / per-model), forwarded live from the server.
- **Local notifications** — a banner + app-icon badge when an agent finishes or
  needs your response, while the app is alive. (No push server, so nothing arrives
  when the app is fully closed — that would need APNs.)
- **Dictation** — on-device Apple speech, or the server's own Whisper as a per-server
  alternative. Review before sending; nothing auto-submits.

## Architecture

```
Sources/NodetermKit/     Dependency-free protocol + domain core (tested with `swift test`)
  Rpc/                   WS-RPC frame codec, RpcClient actor, reconnect, binary pty frames
  Auth/  Keychain/       Login + cookie handling, Keychain storage
  Stores/                Agent-status badge reducer, notification-edge detector
  Terminal/              Co-attach viewer contract (create-options, seed-paint, park/kill)
  Models/                Wire types (Codable, tolerant decoding)
App/Sources/             SwiftUI app: Home, terminal screen, Settings, dictation, notifications
```

The design principle: **pure, testable logic in `NodetermKit`; iOS-only glue in `App/`.**
The protocol core has no UIKit/SwiftUI dependency and runs its full suite under
`swift test` on any Mac.

House rules the code holds to: Swift 6 with complete strict concurrency (actors for
shared mutable state, `Sendable` value types), no force-unwraps outside tests, no
third-party dependency beyond SwiftTerm (App target only — `NodetermKit` stays
dependency-free), and secrets never in logs.

## Build

```sh
swift test                    # runs the NodetermKit suite (macOS)
brew install xcodegen         # once
xcodegen generate             # produces NodetermMobile.xcodeproj (gitignored)
open NodetermMobile.xcodeproj # build/run the iOS app in Xcode
```

Device builds use automatic signing with your own team; open the generated project
and select your signing team. iOS targets can't be compiled from the CommandLineTools
CLI — build the app in Xcode.

## Connecting to a server

You need a running nodeterm Server Edition reachable from your phone. Point the app
at the server's `https://…` address (over Tailscale, a reverse proxy, or your LAN)
and sign in with the server's password. The client is fully unlocked — no
subscription, quota, or entitlement system.

## License

MIT — see [`LICENSE`](LICENSE). SwiftTerm is a separate dependency under its own MIT license.
