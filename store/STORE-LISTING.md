# Termscape — App Store listing copy

Paste-ready metadata for App Store Connect. Fields are capped at Apple's character limits (noted).

---

## App name (30)
`Termscape`

## Subtitle (30)
`Your terminals, anywhere`

## Promotional text (170) — editable anytime without a new build
`Attach to your self-hosted terminal sessions and coding agents from your phone. Live tmux over your own network — no relay, no cloud middleman, no account.`

## Description (4000)
```
Termscape is a native iOS client for a self-hosted nodeterm Server Edition. Point it at a server you run — over Tailscale, a reverse proxy, or your LAN — and pick up your terminal sessions and coding agents right where you left them, from your phone.

No relay. No cloud middleman. No Termscape account. The app talks straight to a server you control, and nothing is stored with the developer.

WHAT YOU GET

• Live terminals — each session is a real, co-attached tmux view. Scroll the history, select text, and use an accessory key bar for the keys a soft keyboard lacks (Esc, arrows, Tab, pipe, Ctrl).

• Agents in your pocket — watch Claude Code, Codex, Gemini and other agents work, with live status badges (running / needs you) and a readable transcript view of the conversation.

• Grouped by project — collapsible project cards with per-project session and agent counts, updated live over the wire.

• Multi-server — add any number of self-hosted servers, each its own profile. Credentials live in the iOS Keychain, scoped per server.

• Account usage — see each managed account's rate-limit windows at a glance.

• Dictation — talk to your terminal with on-device speech, or your server's own Whisper. You review before anything is sent.

• Local notifications — a banner and badge when an agent finishes or needs you.

TRY IT WITH NO SETUP

Tap "Explore a demo" on the first screen to drive the full app offline, with no server or account — a live-looking session, agent status, and transcript, all local.

REQUIRES A SERVER

Termscape is a companion for a self-hosted nodeterm Server Edition instance. It is the client only; you run the server. The nodeterm Server Edition is open source.

PRIVATE BY DESIGN

The app connects only to the server address you configure. There is no developer backend, no analytics, and no tracking.
```

## Keywords (100, comma-separated, no spaces)
`terminal,ssh,tmux,console,server,remote,selfhost,claude,codex,agent,developer,shell,devops,tailscale`

## Support URL
`https://github.com/siimvene/nodeterm-mobile`

## Marketing URL (optional)
`https://siimvene.github.io/nodeterm-mobile/`

## Privacy Policy URL (REQUIRED)
`https://siimvene.github.io/nodeterm-mobile/privacy.html`  *(GitHub Pages, gh-pages branch)*

---

## App Review notes (paste into "Notes" for the reviewer)
```
No account or server is required to review this app. On the first screen, tap "Explore a demo" — this runs the entire UI offline against a built-in demo dataset (a live-looking terminal session, agent status transitions, and a transcript), so you can evaluate every screen with zero setup.

For real use, the app is a client for a self-hosted, open-source "nodeterm Server Edition" that the user runs on their own machine; there is no developer-operated backend.

Dictation uses on-device speech (or the user's own server) and requires microphone permission.
```

## Categories
- Primary: **Developer Tools**
- Secondary: **Utilities**

## Age rating
- **4+** — no objectionable content. (It is a developer tool; terminal output is user-generated and local.)

## Export compliance
- Already declared in the binary: `ITSAppUsesNonExemptEncryption = NO` (standard SSH/TLS only, exempt). No compliance questionnaire needed per build.

## What's New (version 1.0.0)
```
Fixes two bugs worth the update. Typing in a terminal could paint every character twice, and tapping the microphone could close the app immediately. Both are fixed.
```

## What's New (version 0.0.1 — shipped)
```
First release of Termscape — a native client for your self-hosted nodeterm Server Edition. Live tmux terminals, agent status, transcript view, multi-server, dictation, and an offline demo you can try with no setup.
```

## Screenshots required
- **6.9" iPhone** (1320 × 2868 or 1290 × 2796) — REQUIRED, at least 1 (up to 10).
- 6.5" is auto-scaled from 6.9" by Apple if omitted.
- iPad 13" — only required because the bundle currently declares iPad support (device family 1,2). If you do not want to ship iPad, set `TARGETED_DEVICE_FAMILY: "1"` and no iPad screenshots are needed.
  Generated set (from the offline demo) lands in `store/screenshots/`.
