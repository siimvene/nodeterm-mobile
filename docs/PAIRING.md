# SPEC — QR pairing and per-device tokens (iOS / `nodeterm-mobile`)

Target repo: `/Users/siim/git/nodeterm-mobile` (product **Termscape**, bundle `ee.vene.termscape`,
shared library `NodetermKit`).
Companion desktop change: fused host mode in `/Users/siim/git/termscape` (the Electron app hosts the
Server Edition http+ws layer in-process). This document is the **client** half and is written to be
self-contained: §1 restates the wire contract in full so this repo does not have to read the desktop
spec to implement against it.

Every claim about existing iOS code in this document was read out of the repo at
`ba8f5a9` and is cited by `file:line`. Two claims were re-measured on this machine and are marked
`[MEASURED]`.

---

## 0. Problem statement and the one fact that shapes the whole design

Today the phone's only credential is an opaque string obtained by POSTing a **password** to
`/auth/login`. It is stored in the Keychain and replayed as a hand-written
`Cookie: nt_session=<value>` header on HTTP and on the WebSocket upgrade.

- Password → cookie: `Sources/NodetermKit/Auth/AuthClient.swift:43-52`. Success is judged **only**
  by an `nt_session` `Set-Cookie` on a 303 — a wrong password is also a 303
  (`Auth/AuthResponseClassifier.swift:23-39`).
- Keychain: generic password, `kSecAttrAccount = profile.id`, service `ee.vene.termscape.cookie`,
  accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  (`Keychain/KeychainService.swift:27-42, 74-94`).
- HTTP replay: manual `Cookie:` header, ephemeral session, cookie jar off
  (`Auth/AuthClient.swift:17-24, 103-107`).
- WS replay: manual `Cookie:` header, **no `Origin` header ever**
  (`Rpc/WebSocketFrameTransport.swift:63-72`). The cookie is a `let` captured at transport init
  (`:40, :55-57`) and closed over by the transport factory (`App/Sources/Core/Factory.swift:75-77`),
  which is exactly why a credential change requires `dropRuntime` + `connect`
  (`App/Sources/Core/AppEnvironment.swift:232-234, 262-264`).

**The consequence that sets the scope of this work:** the WS gate authenticates on the raw cookie
value alone. If the desktop's enrollment endpoint returns a string that the phone writes into the
same Keychain slot the login cookie occupies today, then `WebSocketFrameTransport`, `RpcClient`,
`TerminalSessionController`, `ServerRuntime` and every stream above them are **unchanged**. The iOS
diff is therefore: one pure payload parser, one HTTP client, one scanner view, three optional
`ServerProfile` fields, and two branches in the auth-recovery UI (one of which is the escape hatch
that makes the desktop's host cut-over survivable — §4.6). Nothing in the transport layer.

Design to that. Any proposal that introduces a second header, a bearer scheme, or a second Keychain
service is more expensive for zero security gain and should be rejected.

---

## 1. Wire contract (this is what the client consumes)

> **The desktop spec is normative for the protocol.** `SPEC-desktop-fused-host.md` §3.3 (payload),
> §3.4 (`/pair/claim`, `/pair/revoke-self`, `deviceId`, `deviceName`) and §3.5 (token lifetime) are
> the definitions; this section restates them so the client can be implemented without reading the
> other document, and **must not diverge from them.** Where the two disagreed before the 2026-09-01
> review — who mints `deviceId`, whether `/pair/revoke-self` exists, what happens to the profile
> already on Siim's phone — the desktop spec now carries the decision and this section has been
> corrected to match.

### 1.1 QR payload

A **bare JSON object**, UTF-8, encoded directly into the QR code. Not a URL. Not
`nodeterm://pair?code=…` (that scheme belongs to the desktop's *relay* offer codec,
`src/main/remote/pairing.ts`, whose validator requires `relayEndpoint` + `pairingToken` +
`hostPublicKeyB64`). Not the desktop's SSH pairing JSON (`src/main/pairing-core.ts`, which carries
`nodeterm:true`, `pairPort`, `user`, `host`).

```json
{
  "v": 1,
  "kind": "host",
  "url": "https://plgs-macbook-pro.monkey-kanyu.ts.net",
  "code": "kJ8xQ2m1Ff0pR7wYvNbL4tHc9sAeZdUg",
  "name": "Siim's Mac",
  "exp": 1756732800
}
```

| field  | type | required | client rule |
|---|---|---|---|
| `v`    | int | yes | must equal `1`; any other value → "This QR is from a newer version of the desktop app." |
| `kind` | string | yes | must equal `"host"`; anything else is not our payload (see §1.2) |
| `url`  | string | yes | the reachable **base** URL. Validated per §3.3. Becomes `ServerProfile.baseURL` verbatim. |
| `code` | string | yes | one-time enrollment code. Opaque. 1–256 chars from `[A-Za-z0-9_-]`. Never logged. |
| `name` | string | no | seeds `ServerProfile.name`. Trimmed, clamped to 64 chars; empty/absent → derive from `url` host. |
| `exp`  | int | no | Unix seconds, **advisory only**. Used to render a countdown and to say "expired" without a round trip. The server is the authority. |

Unknown top-level keys are ignored (forward compatibility). The parser is strict about `v`, `kind`,
`url`, `code` and lenient about everything else.

### 1.2 Payload disambiguation (deliberate, do not "unify")

Three QR shapes exist in this product family. They must reject each other, and the rejection is free
because their required key sets are disjoint:

| shape | required keys | consumer |
|---|---|---|
| host pairing (this spec) | `kind:"host"`, `url`, `code` | Termscape (`nodeterm-mobile`) |
| SSH pairing (`src/main/pairing-core.ts`) | `nodeterm:true`, `host`, `port`, `user`, `pairPort` | `nodeterm-ios` (separate private repo) |
| relay offer (`src/main/remote/pairing.ts`) | `nodeterm://pair` URL, `relayEndpoint`, `pairingToken`, `hostPublicKeyB64` | relay path (being walked away from) |

`PairPayloadParser` must reject the other two with a **specific** message ("That's an SSH pairing
code — it's for a different app"), not a generic parse failure. A future agent will be tempted to
merge these; the parser file carries a comment saying why they are separate.

**That rejection does not fall out of the type contract, so it is written explicitly.** The two
foreign shapes do not have a wrong `kind` — they have no `kind` at all, and one of them is not JSON:

- the relay offer is the **string** `nodeterm://pair?code=<base64url>` (`SCHEME_PREFIX` at
  `src/main/remote/pairing.ts:17`, `encodeOffer` at `:19-25`) — a URL, so the JSON decode fails and
  the natural answer is `.notJSON`;
- the SSH payload is `{v,host,port,user,token,pairPort,nodeterm:true,name}`
  (`buildPairingPayload`, `src/main/pairing-core.ts:47-60`) — valid JSON with **no `kind` key**, so
  the natural answer is `.missingField("kind")`.

Both would render §6.2's generic "That isn't a Termscape pairing code" instead of the specific copy,
and §8.1's corpus asserts `wrongKind` for both. So the parser **sniffs first**, before the generic
path:

1. the raw string, trimmed, starts with `nodeterm://pair` ⇒ `.wrongKind("relay")`;
2. it decodes to a JSON object whose `nodeterm` is `true` ⇒ `.wrongKind("ssh")`;
3. otherwise the ordinary path — `.notJSON` for anything that is not a JSON object,
   `.missingField("kind")` for an object without one, `.wrongKind(<value>)` for a `kind` that is
   present and not `"host"`.

Sniffs, not a rewrite of the error type: `wrongKind(String)` keeps its shape, so §6.2's copy table
is unchanged and the associated value simply carries `"relay"` / `"ssh"` for those two.

### 1.3 `POST {base}/pair/claim` — enrollment

The only new endpoint the phone calls. Public (above the session gate — the phone has no credential
by definition).

**Request**

```
POST /pair/claim HTTP/1.1
Content-Type: application/x-www-form-urlencoded
Accept: application/json
```

| field | required | value |
|---|---|---|
| `code` | yes | the `code` from the QR, verbatim |
| `deviceId` | no | this profile's stored id (§4.3), **omitted entirely when the profile does not have one yet**. Sending it makes re-enrollment idempotent: the server replaces that device's row instead of accreting one per scan. |
| `deviceName` | no | user-editable label, clamped to 64 chars client-side (§4.4) |
| `platform` | no | literal `ios` |

**`deviceId` — the minting rule, pinned** (desktop §3.4 is normative and this restates it). The
client sends its stored id when it has one and **omits the field** when it does not. The server
keys the device row by the supplied id when present and valid (`^[A-Za-z0-9_-]{8,64}$`; anything
else is `400`, never a silent substitution), and mints its own when absent. **The 200 body always
carries the effective id and the client adopts it, overwriting whatever it held.** That is the only
arrangement in which "re-pairing upserts one row" is true end to end — the client cannot end up
holding an id the server does not key by, and a first-ever pair has a defined answer. A
`UUID().uuidString` generated on the phone *may* be sent on a re-pair once the profile has adopted
one; the phone never treats its own value as authoritative over the body's.

Redirects **disabled** (reuse `NoRedirectDelegate`, `Auth/AuthClient.swift:167-177`). Cookie jar off.
Body encoded with the existing `AuthClient.formEncode` (`:145-151`) — its unreserved-set escaping
already round-trips `&`, `=`, `+` and spaces correctly.

**Response — 200**

```
HTTP/1.1 200 OK
Content-Type: application/json
Set-Cookie: nt_session=<token>; HttpOnly; SameSite=Strict; Path=/[; Secure]
```
```json
{ "ok": true, "deviceId": "…", "token": "…", "name": "Siim's Mac" }
```

The client reads the **JSON body**, not the `Set-Cookie` (which exists only so a browser doing the
same flow is logged in). This is the opposite of `login`/`setup`, which judge success by the cookie
header — a deliberate asymmetry, because the phone also needs `deviceId` back and a native client
must never depend on cookie attributes.

**Response — errors**

| status | JSON body | client meaning |
|---|---|---|
| 400 | `{"error":"bad_request"}` | body unparseable / oversized / no `code`, or a malformed `deviceId` (`^[A-Za-z0-9_-]{8,64}$`) — the client only ever sends ids the server gave it, so this is protocol drift |
| 403 | `{"error":"invalid_code"}` | unknown **or** expired **or** already consumed — one indistinguishable answer, by design (an oracle would help an attacker) |
| 409 | `{"error":"not_configured"}` | the host has no password set; it cannot mint device tokens yet |
| 429 | `{"error":"too_many_attempts"}` | the **pairing** rate limiter tripped (separate counter from the login lockout) |
| 405 | — | wrong method |

Any other status, or a 200 whose body has no `token`, is a **protocol error** and is surfaced as
"That server answered in a way this app doesn't understand."

### 1.4 Token semantics

- The returned `token` is **opaque**. The client never parses it, never infers a lifetime from it,
  never logs it (`Auth/NetworkRedaction.swift:10, 38-50` already masks `nt_session=` in any
  stringified header line — the new client routes through the same helper).
- It is presented **exactly like today's session cookie**: `Cookie: nt_session=<token>` on HTTP
  (`AuthClient.swift:103-107`) and on the WS upgrade
  (`WebSocketFrameTransport.swift:70`). No new header, no `Authorization:`.
- It is **per device**. Revoking one device must not invalidate any other device's token, and must
  not invalidate password-issued browser sessions.
- **Lifetime: no absolute expiry** for a device-class token — **confirmed by the desktop**, and the
  encoding is pinned rather than left to taste. Rationale: today's sessions expire absolutely at 30
  days measured from creation, never refreshed (`NodetermWire.sessionTTLDays = 30`,
  `Models/Constants.swift:34`, mirroring the server's `SESSION_TTL_MS`), and the only recovery UI in
  the app is a **password** sheet (`AddServerView.swift:158-207`). A device token profile has no
  password by construction, so a 30-day absolute expiry would make Siim's phone unrecoverable
  monthly except by delete-and-re-add.
  Desktop §3.5 now specifies the sweep literally: it **skips rows by `kind === 'device'`**, and
  never encodes "never" as a value in `expiresAt`. That detail is load-bearing rather than
  pedantic — `sessions.json` round-trips through `JSON.stringify`, `Infinity` serialises to `null`,
  and a sweep comparing `now >= null` culls every device row on the first pass, logging every
  paired phone out at once. **D-1 is answered.** Nothing on the client changes either way; this is
  recorded so a future reader can see the answer was given and where.
- Revocation is a **desktop-side** action. The phone sees it as a 401 and reacts per §6.4 — except
  for revoking *itself*, which is §1.5.

### 1.5 `POST {base}/pair/revoke-self` — confirmed, and the only pairing verb the phone gets

**Granted by the desktop spec** (§3.4 defines it normatively; D-3 is answered *yes*). Called
best-effort with `Cookie: nt_session=<token>` when the user removes the server from the phone. Body
empty; method POST.

| status | body | client meaning |
|---|---|---|
| 200 | `{"ok":true,"revoked":1}` | the device row was deleted and its live socket closed |
| 200 | `{"ok":true,"revoked":0}` | the presenting row was a *password* session; nothing to revoke |
| 401 | `{"error":"unauthorized"}` | the token was already dead — the outcome we wanted |
| 405 | — | wrong method |

The client treats **any** non-2xx as "already gone" and deletes its local secrets regardless,
exactly as `logout` behaves today (`AuthClient.swift:54-60`). It never blocks or retries removal on
this call.

Two things it deliberately is not. It is **not** a device-management API: a device cannot list,
rename or revoke any *other* device — that is the desktop's control plane, and desktop §3.4 puts
that plane on raw `ipcMain` precisely so no enrolled phone can reach it. And it is **not** a
substitute for `/auth/logout`, which does something different and much weaker: `/auth/logout`
(`src/server/http.ts:478-482`) only calls `clearSessionCookie` and redirects — **it never touches
the server's session map** — which is exactly why, with no absolute expiry on device rows, removing
the server on the phone would otherwise leave an immortal credential on the Mac.

### 1.6 What is unchanged on the wire

`/auth/login`, `/auth/setup`, `/auth/logout`, `GET /login`, the WS upgrade at `/ws`, the RPC method
set (`Models/Constants.swift:49-79`), the binary pty framing, the 8 MiB frame cap. Nothing in
`RpcClient`, `TerminalSessionController` or the stores is touched by this work.

---

## 2. Scope

### In scope

1. `PairPayload` + `PairPayloadParser` — pure, in `NodetermKit`, unit-tested.
2. `PairingClienting` protocol + `PairingClient` — the `/pair/claim` and `/pair/revoke-self` HTTP
   surface, in `NodetermKit`, `URLProtocol`-testable.
3. Three optional `ServerProfile` fields + their back-compatible Codable handling.
4. `QRScannerView` (AVFoundation) in the **App** target.
5. Restructured `AddServerView`: scan-first, manual entry preserved, demo preserved.
6. "Pair with QR" upgrade path on `ServerDetailView` for the profile that already exists.
7. `ReauthSheet` branching on credential kind — **both** branches: the `.deviceToken` re-pair
   sheet, and a "Pair with QR instead" secondary action on the `.password` sheet, which is the
   recovery route for the host cut-over (§4.6, §6.4).
8. `termscape://pair` deep link.
9. `NSCameraUsageDescription`; `CFBundleURLTypes` via XcodeGen.
10. Tests per §8.

### Not in scope

- **Any change to the transport, RPC, terminal, workspace, agent-status or speech layers.** If a
  change lands there, the design in §0 was abandoned and this spec no longer applies.
- **A device-management UI on the phone.** Listing and revoking other devices is the desktop's job.
  A read-only "this device: `<label>`, paired `<date>`" row is a §7 phase-4 nice-to-have, not a
  requirement, and needs a desktop RPC that does not exist.
- **Universal Links / `apple-app-site-association`.** Requires web hosting on a real domain plus an
  Associated Domains entitlement (a signing-profile change). The custom scheme in §5.2 is the v1
  mechanism and the in-app scanner is the primary path regardless.
- **Fixing the base-path-prefix defect** (§3.4). v1 refuses a QR whose URL carries a path prefix
  instead. Fixing it properly is a separate change with its own tests.
- **A device keypair / Secure Enclave attestation.** The token is a bearer. Binding enrollment to a
  device-generated public key is a wire-format change and must be decided before `/pair/claim` is
  written, not bolted on (§9 D-6).
- **Plain-HTTP LAN pairing.** See §3.3; the QR path is https-only.
- **Touching `nodeterm-ios`** (the separate private SSH/Citadel app). Payload disambiguation (§1.2)
  keeps the two apps from confusing each other; nothing else is coordinated here.
- **Removing password login.** It stays (§6.1).

---

## 3. Payload parsing and URL validation

### 3.1 Placement

```
Sources/NodetermKit/Pairing/PairPayload.swift        // the struct
Sources/NodetermKit/Pairing/PairPayloadParser.swift  // String -> Result<PairPayload, PairPayloadError>
Sources/NodetermKit/Pairing/PairingClient.swift      // HTTP
```

`NodetermKit` is dependency-free and platform-neutral (`Package.swift:16`, also builds for macOS at
`:11`), and the README states the split: *"pure, testable logic in NodetermKit; iOS-only glue in
App/"* (`README.md:46`). AVFoundation therefore **must not** appear in `Sources/`. This mirrors how
`SetCookieParser` and `AuthResponseClassifier` were split out of `AuthClient`.

### 3.2 Types

```swift
public struct PairPayload: Sendable, Equatable {
    public let version: Int          // v
    public let baseURL: URL          // url, already validated
    public let code: String          // never logged
    public let name: String?         // trimmed, <=64
    public let expiresAt: Date?      // from exp; advisory
}

public enum PairPayloadError: Error, Sendable, Equatable {
    case notJSON                 // camera saw something that isn't our QR at all
    case wrongKind(String)       // kind != "host", OR one of the two foreign shapes sniffed
                                 // ahead of the generic path as "relay" / "ssh" — §1.2
    case unsupportedVersion(Int)
    case missingField(String)    // a JSON object of ours that is missing a required key
    case invalidURL(reason: URLRejection)
    case invalidCode
}

public enum URLRejection: Sendable, Equatable {
    case unparseable
    case noHost
    case notHTTPS          // any scheme other than https
    case hasCredentials    // user:pass@ in the URL
    case hasPathPrefix     // §3.4
    case hasQueryOrFragment
}
```

The parser must never put `code` into an error's associated value, a description, or a log line.

### 3.3 URL rules — https only, no exceptions, from the QR path

`AddServerView.parsedURL` (`:92-112`) is today the **only** place that enforces the plain-http
restriction: `http` is accepted solely for host `localhost` or `127.0.0.1` and only when the
`insecureHTTP` toggle is on. Verified: the persisted `ServerProfile.insecureHTTP` field is written
at `AppEnvironment.swift:195, 212` and **never read again anywhere** (grepped across the repo). The
gate lives entirely in that screen — so restructuring that screen without re-asserting it would
silently delete the restriction.

The QR path is stricter than the manual path: **`https` only.** A QR-advertised base URL is accepted
iff, after parsing with `URLComponents`:

1. scheme is exactly `https` (case-insensitive),
2. `host != nil`,
3. `user == nil && password == nil`,
4. `query == nil && fragment == nil`,
5. path is empty or exactly `/` (§3.4).

Port is allowed and preserved. The stored `baseURL` is the re-composed URL with user / password /
query / fragment stripped — the same normalization the manual path already does at `:100-103`.

Why no http fallback from a QR:

- The desktop's recommended fused-host shape is loopback bind + `tailscale serve`, which terminates
  real TLS for the MagicDNS name. `https` is the normal case, not the strict case.
- A plain-http base at a bare LAN or `100.x` address is blocked by iOS App Transport Security
  regardless of what this app does. The desktop repo already learned this the hard way: its SSH
  pairing listener reads `/pair` responses off a **raw TCP socket** because "ATS blocks URLSession
  for bare-IP HTTP" (`src/main/pairing-service.ts:537-539`). Our transport is
  `URLSessionWebSocketTask` (`WebSocketFrameTransport.swift:74`) and has no raw-socket escape hatch.
  Verified there are **no** ATS exception keys in this project: grepping `project.yml` and every
  plist for `NSAppTransportSecurity` / `NSAllowsArbitraryLoads` / `NSAllowsLocalNetworking` returns
  nothing; the target declares exactly two `INFOPLIST_KEY_NS*` usage strings (`project.yml:50-51`).
- An enrollment code travelling over plaintext is a credential on the wire.

The manual-entry path keeps its existing localhost-http branch verbatim. `ConnectFlowUITests`
(`App/UITests/ConnectFlowUITests.swift:32-38`) drives a real server at `http://127.0.0.1:8444`
through that toggle and must keep passing.

### 3.4 Path prefixes are refused in v1 — and here is the defect that forces it

`[MEASURED]` on this machine with the Swift 6 toolchain:

```swift
let base = URL(string: "https://host.ts.net/term/")!
URL(string: "/auth/login", relativeTo: base)!.absoluteURL   // → https://host.ts.net/auth/login   (prefix DROPPED)
URL(string: "auth/login",  relativeTo: base)!.absoluteURL   // → https://host.ts.net/term/auth/login
var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
c.scheme = "wss"; c.path = "/ws"; c.url!                    // → wss://host.ts.net/ws              (prefix DROPPED)
```

Both call sites are wrong today:

- `AuthClient`'s private helper is named `appendingPathIfPresent` and its doc comment claims to
  preserve "any base path prefix (e.g. a reverse-proxy mount)" (`AuthClient.swift:180-183`) — it
  does not, because a leading-slash path is absolute.
- `ServerProfile.webSocketURL` assigns `comps.path = "/ws"` outright (`ServerProfile.swift:79-88`),
  overwriting any prefix by construction.

`tailscale serve` can publish a backend under a path prefix. A QR carrying such a base URL would
produce a profile that authenticates against the wrong path and never connects — and the failure
would look like a server problem. Rather than fix two path-composition sites and their tests inside
this change, v1 **refuses** a QR whose URL has a non-empty path with `URLRejection.hasPathPrefix`
and the message "This server is published under a sub-path, which this version can't use yet."

§9 D-4 asks the desktop to confirm it will only ever advertise a root-mounted base URL. If it
will not, the fix moves in scope and both sites plus `SYMBOLS.md` change together.

---

## 4. `ServerProfile`, Keychain, and the migration for the profile already on Siim's phone

### 4.1 The Codable trap this must not fall into

`ServerProfile`'s hand-written decoder (`ServerProfile.swift:52-62`) decodes **every** field with a
required `decode` except `isDemo`, which alone uses `decodeIfPresent` (`:61`) with a documented
rationale at `:43-47`. If a decode of any element fails, `ServerProfileStore.readAll` **sidelines
the whole file** to `servers.json.corrupt-<timestamp>` and returns `[]`
(`Profiles/ServerProfileStore.swift:94-100`).

Consequence of getting this wrong: on upgrade, Siim's server row silently disappears from Home, its
Keychain items orphan (they are keyed by the profile id that no longer exists), and the app shows
the empty state with an "Add Server" button. No error, no crash, no log.

**Rule: every new key uses `decodeIfPresent` with a default, exactly like `isDemo`.** A test that
decodes a byte-exact pre-change JSON payload is mandatory (§8.1).

Downgrade is safe in the other direction: `JSONDecoder` ignores unknown keys, so an older build
reading a file written by the new build decodes the profile and simply loses the new fields. Worth
stating because it means a TestFlight rollback does not destroy data — it degrades a device-token
profile into one the old build treats as a password profile with no stored password, i.e. a login
sheet. Acceptable.

### 4.2 New fields

```swift
/// How this profile's stored credential was obtained. Absent in every pre-pairing record ⇒
/// `.password`, which is what those records are.
public enum ServerAuthKind: String, Codable, Sendable, Equatable {
    case password
    case deviceToken
}

public var authKind: ServerAuthKind      // decodeIfPresent ?? .password
public var deviceId: String?             // decodeIfPresent; the id sent to /pair/claim (§4.3)
public var enrolledAt: Date?             // decodeIfPresent; for the detail screen's "paired on …"
```

Nothing is removed. `rememberPassword` in particular **must** survive — `AppEnvironment.reauth`
reads it at `:224` and the manual login path persists it at `:255-260`.

`init` gains three parameters, all defaulted (`authKind: .password`, `deviceId: nil`,
`enrolledAt: nil`), so `DemoScript.profile` (`Demo/DemoScript.swift:43-51`) and the two
`AppEnvironment` construction sites (`:194, :212`) compile untouched.

`encode(to:)` writes all three unconditionally, matching the existing style (`:64-73`). An
unknown-enum guard is not needed on encode; on **decode**, an unrecognized `authKind` string must
fall back to `.password` rather than throw — a hand-edited or future-written file must not sideline
the store.

`App/Sources/SYMBOLS.md:20-21` lists `ServerProfile`'s field set for the integrator's diff and must
be updated in the same commit.

### 4.3 `deviceId` — per profile, not per install

Do not use `identifierForVendor` (it resets when the last app from the vendor is deleted) and do not
invent a cross-install Keychain-persisted device identity (Apple has never guaranteed Keychain
survival across app deletion).

`deviceId` is **the value the server returned in the 200 body** of this profile's first successful
`/pair/claim`, stored on the profile and re-sent on every subsequent `/pair/claim` for that same
profile. On the first pair the field is **omitted** from the request and the server mints it (a
`crypto.randomUUID()`); on every later pair the client sends what it holds, and the server keys the
row by it. The client always re-reads the body's `deviceId` and overwrites its own — see §1.3.

An earlier draft of this section said the client mints a `UUID().uuidString` itself and §4.6 step 3
then stored "the sent id", which cannot be right on a first-ever pair (nothing was sent) and left
open whether the server keys by the client's value or its own. If it keyed by its own, every
re-pair would add a row and "revoke one device" would silently stop meaning anything. Hence the
single rule above. Meaning:

- Re-pairing an existing profile (the §4.6 upgrade, or a re-pair after revocation) sends the same
  `deviceId`, so the desktop upserts one row and the previous token dies. No accretion.
- A fresh install is a fresh profile with no `deviceId`, so the server mints a new one, it appears
  as a new device on the desktop, and the old row is left for the user to revoke. That is honest: a
  reinstalled phone genuinely cannot prove it is the same device.

The two rejections at the top of this section stand unchanged; what moved is only *who* mints the
id, not what it is derived from.

### 4.4 `deviceName`

`UIDevice.current.name` is already used for presence (`App/Sources/TermscapeApp.swift:23`), but on
iOS 16 and later it returns a generic model name ("iPhone") for apps without the user-assigned
device-name entitlement. A desktop device list showing three rows all called "iPhone" is useless, so
the pairing confirm sheet presents an **editable** label field pre-filled with
`UIDevice.current.name`, and whatever the user leaves there is sent as `deviceName`.

**D-5 is answered** (desktop §3.4): the label is displayed in the Devices list, it is **truncated to
64 chars host-side, never rejected**, and it is treated as untrusted display text and rendered
escaped. Blank or absent becomes `'iPhone'` (`normalizeDeviceName`, `src/main/pairing-core.ts:153-159`
— which has no clamp today and gains one when it moves to `src/shared/`). So the client clamps to
the same **64** it assumed, and a user who pastes an essay gets a shortened row rather than a failed
pair.

### 4.5 Keychain: reuse the cookie slot, add nothing

The device token is presented in the `nt_session` cookie header, so it is stored via the existing
`saveCookie` / `cookie` / `deleteCookie` (`KeychainService.swift:34-42`) under service
`ee.vene.termscape.cookie`, account `profile.id`.

A third service (`…​.deviceToken`) would be justified only if the server read the credential from
somewhere other than the cookie. It does not. Two services would mean two lookup paths in
`AppEnvironment.connect` (`:100-105`) — the drift this codebase has repeatedly warned about — and
`deleteAll(forServer:)` (`:58-61`) would need a third leg.

`KeychainStoring` (`Contracts.swift:131-142`) is therefore **unchanged**. That matters: the header of
`Contracts.swift` states the signatures are FINAL, and every added protocol member also forces an
edit to the `Unwired*` stubs in `Factory.swift:122-144`.

### 4.6 Migration for the profile already on Siim's phone

**Two different events, and only one of them is harmless. Do not read the first sentence as though
it covered both.**

**The app upgrade: nothing to migrate.** His record decodes as `authKind == .password`, keeps its
cookie and (if he opted in) its password, and continues to work byte-identically against the server
it is talking to. The Codable work in §4.1/§4.2 is purely additive and §8.3 proves it.

**The host cut-over: the credential dies, and the app must have a way out before it happens.** On
the day the fused host takes over the tailnet URL, the profile's stored cookie stops validating —
the fused `Auth` is `new Auth(app.getPath('userData'))` and the desktop spec's §2.4 decision 1 is
explicitly *"do not import the old `sessions.json`"*, so the row backing that cookie is not in the
new map at all. Its stored password, if any, is wrong too: desktop §3.8 **generates** a fresh random
password when the fused host is enabled. Both credentials are gone at the same instant, and nothing
about it is visible from the phone.

What that produces today, verified end to end in this repo: 401 at the WS upgrade →
`AppEnvironment.swift:107-113` pauses the runtime and calls `autoReauth` → `reauth` (`:223-241`)
tries the stored password, catches `AuthError.wrongPassword`, deletes it and sets `reauthNeeded` →
`HomeView` presents `ReauthSheet`, whose only control is `SecureField("Password")`
(`AddServerView.swift:178`). The profile is `authKind == .password`, so **§6.4's `.deviceToken`
re-pair branch does not fire** — it keys on exactly that field. The user is left typing at a
password that no longer exists anywhere in the world.

The recovery route does exist — dismiss the sheet, open `ServerDetailView`, tap "Pair with QR"
(§5.3) — but three non-obvious taps behind a dead-end sheet is not a migration story. So two things
are required, and they are the reason this section is not a footnote:

1. **§6.4 gains an escape hatch on the `.password` branch** — a secondary "Pair with QR instead"
   action on the re-auth sheet, not only on the `.deviceToken` one.
2. **That build must be on the phone before the desktop cuts over.** Desktop §7 now carries the
   ordering constraint (iOS P3 gates desktop Phase 2, which is where the launchd server is
   unloaded) and the device-checklist item that rehearses it: force a 401 while the old server is
   still up and confirm the sheet offers a route to the scanner.

The in-place **upgrade** below is a separate, voluntary flow: it converts a working
password profile into a device-token one against a host that already serves `/pair/claim`. For
Siim's own phone that means it runs **after** the cut-over, not before — the launchd server is
unloaded at desktop Phase 2 and `/pair/claim` does not exist until Phase 4, so there is no window in
which the old server could mint a device token. It is the flow the §6.4 escape hatch lands the user
in, and the flow any *later* password profile uses at leisure. Offer it as a row on
`ServerDetailView` beside the existing logout button (`ServerDetailView.swift:67-84`):

> **Pair with QR** — replaces the password sign-in for this server with a device token you can
> revoke from the Mac.

Tapping it opens the same scanner and the same confirm sheet. On a successful `/pair/claim` against
a payload whose `url` **matches this profile's `baseURL`** (host + port + scheme; a mismatch is an
error, not a silent re-point), the app performs, in this order:

1. `keychain.saveCookie(token, forServer: profile.id)` — overwrite the credential first.
2. `keychain.deletePassword(forServer: profile.id)` — **mandatory**. Skipping it leaves the plaintext
   password on the device forever and `reauth` (`AppEnvironment.swift:223-241`) keeps silently using
   it, so the token buys nothing. There is precedent for exactly this omission being caught before:
   `login(_:password:rememberPassword:)` deletes the password when the toggle goes off
   (`:249-253`, comment: *"Disabling retention must DELETE the stored password"*).
3. `profile.rememberPassword = false`, `profile.authKind = .deviceToken`,
   `profile.deviceId = <the deviceId in the 200 body>` (§1.3 / §4.3 — the body's value, never the
   one the request happened to carry; on a first pair the request carried none),
   `profile.enrolledAt = now`; `profileStore.update`.
4. `dropRuntime(id:)` then `connect(profile)` — the cookie is captured by the transport factory
   (`Factory.swift:75-77`), so a credential change **requires** a fresh runtime. This is the same
   sequence `reauth` uses at `:232-234`.

If step 1 throws, nothing else runs and the profile is untouched. If step 2 or 3 throws after step 1
succeeded, the profile is left with the new token and a stale `authKind` — recoverable, and the
credential is already the safe one, so this ordering fails in the right direction.

---

## 5. Surfaces

### 5.1 `QRScannerView` — App target only

`App/Sources/Home/QRScannerView.swift`. A `UIViewControllerRepresentable` over
`AVCaptureSession` + `AVCaptureMetadataOutput` with `metadataObjectTypes = [.qr]`, delivering the
**first** decoded string through a closure and then stopping the session (no repeat delivery — a
second frame of the same code must not fire a second `/pair/claim`).

Verified greenfield: grepping `App/`, `Sources/` and `Tests/` for `AVCapture`, `VNBarcode`,
`DataScannerViewController` returns only the unrelated `import AVFoundation` in
`App/Sources/Speech/DictationService.swift:2`. There is no camera code and no pairing client of any
kind in this repo today.

Required states, all of which must render something legible rather than a black rectangle:

| state | UI |
|---|---|
| authorized, running | live preview + a framing reticle + "Point at the QR code on your Mac" |
| `.notDetermined` | request on appear |
| `.denied` / `.restricted` | "Camera access is off for Termscape." + a button to Settings + **"Enter details manually"** |
| no capture device (Simulator) | "This device has no camera." + the manual-entry link. **Non-negotiable** — App Review runs the Simulator and the reviewer must never hit a dead screen (§6.3). |
| decoded, parse failed | inline error per §6.2, camera keeps running so a retry needs no navigation |

### 5.2 `AddServerView` restructure

Keep the entry point: it is presented as a sheet from Home's "Add Server" button
(`HomeView.swift:36, 156-161`). Restructure the body:

1. **Primary**: a large "Scan QR code" button → `.fullScreenCover` with `QRScannerView`.
2. **Confirm step** (a sheet over the scanner, never skipped, including on the deep-link path):
   shows the host from `url`, the `name`, an editable device-label field, a countdown from `exp`,
   and one "Pair" button. Nothing is sent until this is tapped.
3. **`DisclosureGroup("Enter details manually")`** containing today's form verbatim — the `Name`
   field, `Base URL (https://…)`, the insecure-http toggle, the password `SecureField`, the
   remember toggle, and the first-run `/setup` branch (`AddServerView.swift:28-53, 38-45`).
4. **"Explore a demo instead"** (`:63-70`) stays visible **without scrolling** (§6.3).

`ConnectFlowUITests` drives the manual form by literal accessibility labels: `"Add Server"` (`:20`),
`"Name"` (`:22`), `"Base URL (https://…)"` (`:26`), the switch `"Allow insecure http (localhost
only)"` (`:35`), `app.secureTextFields.firstMatch` (`:40`), `"Connect"` (`:43`). Those labels must
survive the restructure. Since they move behind a disclosure, the test gains one tap on
`"Enter details manually"` before `:22` — **in the same commit**, or CI's only end-to-end proof
breaks.

### 5.3 `ServerDetailView`

Adds the "Pair with QR" row (§4.6) above the existing logout button, shown only when
`profile.authKind == .password`. When `authKind == .deviceToken`, that slot instead shows a static
line: "Paired device — `<label>`, since `<enrolledAt>`. Remove it from your Mac to revoke access."

**This row ships in P3, not later, and it is not a convenience.** It is the recovery route for the
cut-over described in §4.6, and it is why P3 has to be on Siim's phone before the desktop unloads
its launchd server (desktop §7).

The existing logout copy (`:79`, *"The server session stays valid until it expires (30 days)"*) is
**wrong for a device token** and must branch. Since §1.5 is confirmed, the device-token copy is:

> Removing this server deletes its key from this phone and asks the Mac to revoke this device.

"Asks", not "revokes": the call is best-effort by design (§1.5 — removal never blocks on it), so if
the phone is offline at that moment the row survives on the Mac until it is revoked there. That is
the honest sentence, and it is still enormously better than the pre-§1.5 alternative, which was to
tell the user the device stays paired until they go and remove it themselves.

### 5.4 Deep link `termscape://pair`

`.onOpenURL { }` on the `WindowGroup` content (`App/Sources/TermscapeApp.swift:31-38`), routed into
the **same** `PairPayloadParser` and the **same** confirm sheet, so scan and tap share one code path
and one set of refusals.

URL form: `termscape://pair?p=<base64url(the §1.1 JSON)>`.

Scheme choice is `termscape`, not `nodeterm`. Reason: the desktop already emits `nodeterm://pair`
for the **relay** offer (`src/main/remote/pairing.ts`), and the separate `nodeterm-ios` app is the
plausible registrant for that scheme. Two apps registering one scheme is undefined behaviour on iOS
— whichever the system picks, one flow silently breaks.

**Registration cost, and the risk.** This project has **no checked-in `Info.plist`** — `git ls-files`
shows only `project.yml` and `ci_scripts/ExportOptions.plist`, and the `.xcodeproj` is generated by
XcodeGen (`ci_scripts/ci_post_clone.sh`, and `.github/workflows/ios-release.yml:44-49` runs
`xcodegen generate`). Everything comes from `GENERATE_INFOPLIST_FILE: YES` (`project.yml:42`) plus
`INFOPLIST_KEY_*` scalars (`:33, 48-55`). `CFBundleURLTypes` is an array of dictionaries and has **no
`INFOPLIST_KEY_` form**, so it requires either an XcodeGen target `info:` block (which sets
`INFOPLIST_FILE`) or a checked-in partial plist.

Because a botched migration silently drops a generated key — launch screen (`:52`), scene manifest
(`:53`), orientations (`:55`), export compliance (`:48`), display name (`:33`) — and the failure only
surfaces at archive/upload time on paid CI minutes, the DoD for this item is mechanical:

> Build the app **before** the change, `plutil -p` the built `Termscape.app/Info.plist`, save it as a
> baseline. Build after. Diff. The only permitted difference is the added `CFBundleURLTypes` (and,
> from §5.5, `NSCameraUsageDescription`). Any other key that changed or vanished is a regression.

`NSCameraUsageDescription` does have an `INFOPLIST_KEY_` form and needs none of this — it goes in
beside the two existing usage strings.

Consequence for phasing: the deep link is **phase 4**, isolated, and can be dropped without
affecting anything else. The scanner is the mechanism; the link is a convenience.

### 5.5 Camera permission string

Added to `project.yml` beside `:50-51`:

```yaml
INFOPLIST_KEY_NSCameraUsageDescription: "Termscape uses the camera only to scan the pairing QR code shown by your own computer."
```

A missing string is a hard crash on first camera access, and App Review rejects vague ones. This
wording is as narrow as the two that already ship.

---

## 6. Error states, back-compatibility, and review

### 6.1 Password login stays, and is load-bearing

Nothing in this spec touches `/auth/login`, `/auth/setup`, `/auth/logout` or their classifiers. A
profile with no `authKind` key **is** a password profile by definition, so every existing record
keeps working through the same code path.

It is not merely tolerated:

- The desktop's device list — the only place a lost phone can be revoked — is reached through a
  browser session, which needs a password. If the phone were the only credential in existence, a
  lost phone would be unrevokable.
- `/pair/claim` answers **409 `not_configured`** when the host has no password. Minting a code on an
  unconfigured host would move that failure from the Mac (where it is fixable) to the phone (where
  it is not).
- The `/setup` first-run branch (`AddServerView.swift:38-45, 119-126`) has no phone in it.

### 6.2 Failure branches — enrollment

| branch | what happened | what the user sees | code consumed? |
|---|---|---|---|
| camera denied | permission off | "Camera access is off for Termscape." + Settings button + manual entry | n/a |
| not our QR | scanned a wifi/URL/vCard code | "That isn't a Termscape pairing code." Camera keeps running. | n/a |
| SSH / relay payload | scanned the wrong nodeterm QR | "That's a pairing code for a different app." | n/a |
| `v != 1` | newer desktop | "This QR is from a newer version of the desktop app. Update Termscape." | n/a |
| non-https url | payload advertises http | "Pairing needs an https address." | no |
| path-prefixed url | §3.4 | "This server is published under a sub-path, which this version can't use yet." | no |
| **transport failure** | phone off the tailnet, Mac asleep, app quit | see §6.3 | **no** — the POST never reached a server, so the same QR still works once connectivity returns. Preserve this property. |
| **403 `invalid_code`** | expired, already used, or unknown | "That pairing code is no longer valid. Press **New code** on your Mac." Plus, when `exp` had **not** yet passed: "If the code should still be good, someone else may have used it — generate a new one." | yes (server-side) |
| 409 `not_configured` | host has no password | "That Mac isn't finished setting up. Set a password on it first." | no |
| 429 `too_many_attempts` | pairing limiter | "Too many pairing attempts. Wait a minute." **Never auto-retry.** | no |
| 400 / 405 / unknown status / 200 without `token` | protocol drift | "That server answered in a way this app doesn't understand." | unknown |
| Keychain write fails after a 200 | `saveCookie` throws | "Couldn't save the key to this device's Keychain." No profile is created; the code is spent, so the user must generate a new one. | yes |

The one-shot property is the only theft signal this design has, and it is free: if Siim scans a QR
that is still counting down and gets `invalid_code`, someone else consumed it. That sentence belongs
in the error copy.

### 6.3 Failure branches — after pairing

`AuthClient.dataThrowingNetwork` collapses **every** `URLSession` error into `AuthError.network`
(`AuthClient.swift:113-119`), so today these three render identically:

1. phone is off the tailnet — MagicDNS does not resolve (`NSURLErrorCannotFindHost`,
   `NSURLErrorDNSLookupFailed`);
2. phone is on the tailnet, Mac is asleep or Tailscale is down on it — resolves, then times out or
   is refused;
3. reachable, but the fused host is not listening (**the Electron app is quit**) — `tailscale serve`
   answers with its own 502-class error, not a Termscape response.

Case 3 is **new and permanent**: fusing removes the launchd job, so phone access now lives and dies
with the desktop app. tmux sessions survive (nothing kills them), so this is reachability loss, not
work loss — but the user must be told once rather than discover it.

`PairingClient` therefore does **not** collapse errors: it maps `URLError.Code` into a small enum
(`.nameResolutionFailed`, `.cannotConnect`, `.timedOut`, `.tls`, `.other`) so the UI can say "Turn on
Tailscale on this phone" instead of "Couldn't reach the server". `AuthClient` is left alone —
widening its error surface would ripple into `AddServerView.message(for:)` (`:143-154`),
`ReauthSheet.submit` (`:199-207`) and the classifier tests, for no gain in this change.

### 6.4 Revocation and expiry — the branch that must not be a dead end

A revoked or expired token produces a raw `HTTP/1.1 401` at the WS upgrade
(`WebSocketFrameTransport.swift:167-172` classifies `httpStatus == 401` into
`RpcTransportError.authFailed`; `RpcClient.swift:308` maps it to `ConnectionState.authRequired`;
`ServerRuntime.swift:121` fires `onAuthRequired`; `AppEnvironment.swift:107-113` pauses the runtime
and calls `autoReauth`).

For a device-token profile, `rememberPassword` is false, so `reauth` (`:223-228`) falls straight to
`reauthNeeded = profile`, which presents `ReauthSheet` (`HomeView.swift:38`) — **a password
`SecureField`** (`AddServerView.swift:178`). For a profile that has no password, that is a dead end.

`ReauthSheet` branches on `profile.authKind`:

- `.deviceToken` — no `SecureField`. Copy: "This device is no longer paired with `<name>`. It may
  have been removed from the Mac." One button, **"Scan a new code"**, opening the scanner in
  re-pair mode (same `profile.id`, same `deviceId`, host must match — §4.6).
- `.password` — the existing sheet, plus **one secondary action: "Pair with QR instead"**, which
  opens the same scanner in the same re-pair mode. This is the only change to that branch;
  everything above it — the copy, the `SecureField`, the remember toggle, `submit`
  (`AddServerView.swift:199-207`) — is untouched, and a user who does have a password never has to
  notice the extra row.

**Why the `.password` branch is not left byte-identical**, which an earlier draft of this spec said
it would be: the host cut-over (§4.6) invalidates a *password* profile's cookie **and** the password
behind it at the same instant. That profile never reaches the `.deviceToken` branch — the branch
keys on `authKind`, and the field says `.password` — so without the secondary action the sheet is a
dead end: a password field for a password that no longer exists. The route out has to be *in the
sheet*, because that sheet is what the user is looking at when it happens. Desktop §7's ordering
constraint exists to make sure this ships before the cut-over.

The 401 cannot distinguish "revoked" from "expired": it is written to a raw socket before any body
exists (the desktop emits it from the upgrade handler). Do not ask the server to differentiate.
Branching on the **client's** `authKind` is what makes the message right, and it is why that field
exists at all.

### 6.5 Demo mode

Untouched, and it is the one thing App Review actually uses (`docs/DEMO-MODE.md:1-18`; the review
notes in `store/STORE-LISTING.md:67` point at it explicitly).

`DemoScript.profile` (`Demo/DemoScript.swift:43-51`) is synthetic, never persisted, never
keychained; `exitDemo` (`AppEnvironment.swift:81-84`) drops it; `removeServer` short-circuits on
`isDemo` (`:274`); `ServerRowView` renders the demo row without navigation
(`HomeView.swift:348-362`). None of that is in the path of this change.

Two hard requirements the restructure must not break:

1. The demo button stays reachable **without scrolling** on both entry points — the Add Server sheet
   (`AddServerView.swift:63-70`) and the Home empty state (`HomeView.swift:165-173`).
2. The scanner degrades to a legible message on a device with no camera (§5.1). The reviewer is on
   the Simulator.

### 6.6 App Store review

- `NSCameraUsageDescription` is mandatory (§5.5).
- Camera is **not** a Required-Reason API — no `PrivacyInfo.xcprivacy` is needed, and
  `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO` (`project.yml:48`) is unaffected.
- The app must remain fully usable with camera permission **denied**: manual entry and demo both
  reachable. This is a Guideline 2.1 exposure otherwise.
- No change to the review notes is required (`store/STORE-LISTING.md:65-67` already routes the
  reviewer to the demo), but adding one sentence — "the QR pairing flow needs a Mac and is not part
  of the review path" — pre-empts a reviewer tapping Scan and finding a dead Simulator camera.
- Privacy nutrition label: the scanner reads a QR locally and transmits nothing but the code. No new
  data-collection disclosure.

---

## 7. Phased plan

Each phase is independently verifiable and independently revertible.

**P1 — pure core, no UI.** `PairPayload`, `PairPayloadParser`, `PairingClienting`, `PairingClient`,
`Factory.makePairing()` + an `UnwiredPairing` stub under `#if !NODETERM_KIT_IMPL_READY`
(`Factory.swift:119-144`). Registered tests per §8.1/§8.2.
**DoD:** `swift test` green, including a stubbed 200/403/409/429 round trip and a payload corpus.

**P2 — profile + Keychain migration, still no UI.** The three `ServerProfile` fields, decoder,
encoder, `SYMBOLS.md`. **DoD:** a byte-exact pre-change `servers.json` decodes to a profile with
`authKind == .password` and `deviceId == nil`, and the store does **not** sideline it.

**P3 — scanner + Add Server restructure + BOTH `ReauthSheet` branches + `ServerDetailView` upgrade
row.** Camera usage string. UI test updated for the disclosure tap.
**DoD:** on a real device against a real fused host — scan, confirm, connect, terminal attaches; the
password path still works via manual entry; `ConnectFlowUITests` passes; camera-denied and
no-camera states render; and, per §6.4, a **`.password`** profile that 401s shows a route to the
scanner and not only a password field.

**P4 — deep link.** `CFBundleURLTypes` via XcodeGen + the Info.plist diff gate (§5.4).
**DoD:** the baseline/after `plutil -p` diff shows only `CFBundleURLTypes`; tapping a
`termscape://pair?p=…` link lands on the confirm sheet, never on a direct POST.

**P5 — self-revoke** (§1.5), wired into `removeServer`, plus the branched detail copy (§5.3). No
longer optional and no longer blocked: the desktop confirmed the endpoint and ships it in its
Phase 4. Still last, because it is the only piece whose absence degrades to a wording change rather
than a broken flow.

**Sequencing, and one constraint that runs the other way.** P1+P2 land any time — they are testable
entirely against stubs, before the desktop endpoint exists. P3's *scan-and-connect* DoD needs a live
fused host, so it is verified against desktop Phase 4/5.

But **P3's code has to be installed on Siim's phone before desktop Phase 2 runs**, which is earlier
than its own DoD can be met. That is not a contradiction, it is the cut-over: desktop Phase 2
unloads the launchd server, and from that moment the existing profile's cookie and password are both
dead (§4.6). Whatever build is on the phone at that instant is the build that has to offer a way
back, and only P3 does. So: ship P3 to the device (TestFlight or a local install), *then* let the
desktop start Phase 2, *then* complete P3's DoD against the fused host once Phase 4/5 land. P5
follows desktop Phase 4. The rehearsal that can be run before any of it — force a 401 against the
still-running launchd server and confirm the sheet offers the scanner — is §8.4 item 8.

---

## 8. Testing strategy

The house pattern in this repo is **framework-free** `run…()` functions using `precondition`,
registered as swift-testing `@Test` cases in one file
(`Tests/NodetermKitTests/RegisteredTests.swift:12-52`; the rationale is in the header of
`Tests/NodetermKitTests/AuthTests.swift:1-8` — the dev machine has only CommandLineTools). New tests
follow that pattern exactly: a `PairingTests.swift` exposing `run…()` functions, plus new `@Test`
lines in `RegisteredTests.swift`. Do not introduce XCTest into the SwiftPM target.

### 8.1 Payload parser (pure — the bulk of the value)

A corpus, each asserted to the exact `PairPayloadError`:

- happy path with and without `name` / `exp`; unknown extra keys ignored.
- not JSON at all; JSON that is not an object; empty string.
- `kind` present and `"ssh"` / `"relay"` → `wrongKind(<that value>)`; `kind` **absent** from an
  otherwise well-formed object of ours → `missingField("kind")`.
- A **verbatim copy** of the desktop's SSH pairing JSON
  (`{v,host,port,user,token,pairPort,nodeterm:true,name}` — `src/main/pairing-core.ts:47-60`) →
  `wrongKind("ssh")`, via the `nodeterm === true` sniff, **not** `missingField("kind")` (that
  payload has no `kind` key at all).
- A **verbatim** `nodeterm://pair?code=<base64url>` string (`src/main/remote/pairing.ts:17-25`) →
  `wrongKind("relay")`, via the scheme-prefix sniff, **not** `notJSON` (it is a URL, not JSON).
  These last two are the whole reason §1.2's sniffs exist; without them the parser answers with the
  generic copy and this corpus is unsatisfiable as written.
- `v` = 0, 2, missing, non-integer.
- `url`: `http://…`; `https://user:pass@host`; `https://host/term/`; `https://host?x=1`;
  `https://host#f`; `https://` (no host); garbage. One case per `URLRejection`.
- `url` with a port survives; the stored URL is the stripped re-composition.
- `code`: absent, empty, 257 chars, containing `;` or a space.
- **`code` never appears in any `PairPayloadError`'s description** — assert on the stringified error.

### 8.2 `PairingClient` (stubbed HTTP)

`AuthClient` already ships an injectable `init(session:)` for `URLProtocol`-backed stubs
(`AuthClient.swift:29-32`). `PairingClient` mirrors it. Cases:

- 200 with a well-formed body → returns `token` + `deviceId`.
- 200 whose body lacks `token` → protocol error, **not** success.
- 403/409/429/400/405 → the mapped error each time.
- 302/303 → the client must **not** follow (assert the stub's redirect target is never requested).
- **`deviceId` round trip (§1.3/§4.3):** a request made with **no** stored id omits the field
  entirely (assert the encoded body contains no `deviceId=`), and the caller adopts the body's id;
  a request made with a stored id sends it; and a 200 whose body returns a **different** id than the
  one sent is adopted anyway (the body wins — assert on the returned value, since this is the case
  that silently accretes rows if it is got backwards).
- **`revokeSelf`:** 200 `{"ok":true,"revoked":1}` and 200 `{"ok":true,"revoked":0}` both succeed;
  401 is **not** an error the caller surfaces (removal proceeds); the request carries an empty body.
- Request shape: method `POST`, `Content-Type: application/x-www-form-urlencoded`,
  `Accept: application/json`, body contains `code=`, and — for the revoke call — the
  `Cookie: nt_session=` header is present.
- `code` is in the **body**, never in the URL query (mirrors the existing SPEC §10 rule 2 tests in
  `AuthTests.runFormEncodingTests`).

### 8.3 `ServerProfile` Codable

- Decode a byte-exact pre-change payload (the seven old keys only) → `authKind == .password`,
  `deviceId == nil`, `enrolledAt == nil`, and every old field intact.
- Decode a payload with an unrecognized `authKind` string → `.password`, no throw.
- Round-trip a `.deviceToken` profile.
- Extend `ProfilesTests` (`Tests/NodetermKitTests/ProfilesTests.swift:31-47`) to write a
  device-token profile through a real `ServerProfileStore` into a temp dir and assert the file
  contains **no** `"token"` / `"cookie"` / `"password"` key — the same discipline as
  `ProfilesTests:46-47`.
- A store containing one old-format and one new-format record loads **both** (proving no sidelining).

### 8.4 Non-unit verification (write these down as a device checklist, not as tests)

1. Scan against a live fused host; terminal attaches. (P3 DoD.)
2. Camera denied → the fallback screen appears and manual entry works from it.
3. Simulator, no camera → the no-camera message, and the demo button is visible without scrolling.
4. Revoke the device on the Mac while the phone is connected. Expect the socket to drop and the
   `.deviceToken` re-pair sheet to appear: **D-2 is answered** — desktop §3.6 records each socket's
   token hash and exposes `closeByTokenHash`, and `pair:revoke` closes matching sockets with code
   4001 before returning `{revoked, socketsClosed}`. If the socket does *not* drop, that is a
   desktop bug to file, not an expected degrade.
5. Upgrade path: an existing password profile → Pair with QR → confirm the Keychain password item is
   gone (a `SecItemCopyMatching` probe in a debug build, or simply: force-quit, revoke on the Mac,
   and confirm the phone shows the re-pair sheet and **not** the password sheet — if it shows the
   password sheet, step 2 of §4.6 was skipped).
6. Airplane mode → the three §6.3 messages are distinguishable.
7. Info.plist diff gate (P4 DoD).
8. **Cut-over rehearsal, and it must be run BEFORE desktop Phase 2** (§4.6, §6.4; desktop §7 owns
   the ordering). On the P3 build, while the old launchd server is still up, force a 401 — delete
   the phone's row from `~/.nodeterm-server/sessions.json` — and confirm the `.password` re-auth
   sheet offers **"Pair with QR instead"** and reaches the scanner. This is the one dress rehearsal
   available for the day the credential dies for real, and if it fails there is no route back on the
   device.
9. **Self-revoke** (P5): remove the server on the phone while it is connected, then confirm on the
   Mac's Devices list that the row is gone. Then repeat with the phone in airplane mode and confirm
   the local secrets are still deleted and the row is still there — the honest half of §5.3's copy.

### 8.5 UI test

`ConnectFlowUITests` gains a tap on `"Enter details manually"` before it reaches the `Name` field
(§5.2). Do not add a UI test for the scanner — XCUITest cannot feed the camera a QR code, and the
parse logic it would exercise is already covered in §8.1.

---

## 9. Open questions the desktop side must confirm

These block or reshape client work. Each names the client consequence, so the desktop can answer in
terms of cost.

**Status after the 2026-09-01 adversarial review.** Six of the nine are answered by
`SPEC-desktop-fused-host.md`, which is normative for the protocol. The original question text is
kept below with the answer attached, because the reasoning is still what a reader needs.

| | question | status |
|---|---|---|
| D-1 | device-token expiry | **answered — no absolute expiry**, and the encoding is pinned (desktop §3.5) |
| D-2 | does revoke close the live socket | **answered — yes**, `closeByTokenHash`, code 4001 (desktop §3.6) |
| D-3 | will `/pair/revoke-self` exist | **answered — yes**, defined in desktop §3.4; iOS P5 unblocked |
| D-4 | path-prefixed base URL | **answered — no**, the desktop refuses to mint one (desktop §4) |
| D-5 | `deviceName` handling | **answered — displayed, truncated to 64, escaped** (desktop §3.4) |
| D-6 | bearer vs device keypair | **open** — Siim's call, and it must be made before `/pair/claim` is written |
| D-7 | enrollment TTL | **open** — 120 s recommended with a countdown + auto re-mint; client is indifferent |
| D-8 | route placement + separate limiter | **answered — yes to both** (desktop §3.4, §3.7) |
| D-9 | https always | **answered — yes**, loopback bind + `tailscale serve` (desktop §2.5) |

**D-1 — Do device tokens expire?**
Client assumes **no absolute expiry**, revocation-only (§1.4). If the desktop keeps the 30-day
absolute `SESSION_TTL_MS` for device rows, Siim's phone silently unpairs one month after
enrollment. The §6.4 re-pair sheet makes that recoverable rather than fatal, but it turns pairing
into a monthly chore and the copy has to change from "no longer paired" to "this pairing expired".
A *sliding* window is the middle option and costs the desktop a write per connect, which
`sessions.json`'s whole-map `writeFileSync` (`src/server/auth.ts:128-132`) is not built for.
**ANSWERED: no absolute expiry.** Desktop §3.5 skips the sweep by `kind === 'device'` and forbids
encoding "never" as an `expiresAt` value at all (`Infinity` serialises to `null` and a naive
comparison then culls every device row on the first pass). Client copy stays "no longer paired".

**D-2 — Does `pair:revoke` close the device's LIVE WebSocket?**
`upgradeAllowed` runs once, at the upgrade (`src/server/ws.ts:88`); nothing re-validates an
established socket. If revoke only blocks future connects, a stolen phone that is currently attached
keeps full terminal access indefinitely, and §8.4 item 4 cannot be written as a pass/fail. This is
server work (record the token per socket, expose a `closeByToken`), not client work, but the client
checklist and the revoke copy depend on the answer.
**ANSWERED: yes.** Desktop §3.6 keeps `sha256hex(token)` per socket in a `WeakMap`, exposes
`closeByTokenHash`, and `pair:revoke` closes matching sockets with code 4001 before returning
`{revoked, socketsClosed}`. §8.4 item 4 is now a pass/fail.

**D-3 — Will `POST /pair/revoke-self` (§1.5) exist?**
Without it, removing the server from the phone leaves a live token on the Mac and the detail-screen
copy has to say so. With it, removal is a real revoke. Cheap on the desktop (it already has the
token from the cookie); real UX difference.
**ANSWERED: yes.** Desktop §3.4 defines it normatively — registered BELOW the session gate, deletes
only the presenting row, closes its sockets, `200 {"ok":true,"revoked":0|1}`. §1.5 carries the full
contract; P5 is unblocked and no longer optional.

**D-4 — Will the QR ever advertise a base URL with a path prefix?**
Client refuses one in v1 (§3.4), because both `AuthClient`'s path helper
(`AuthClient.swift:180-183`) and `ServerProfile.webSocketURL` (`ServerProfile.swift:79-88`) drop it
— `[MEASURED]`, both. If `tailscale serve` will publish under a sub-path, fixing those two sites
moves into scope with its own tests.
**ANSWERED: no.** Desktop §4 refuses to mint a QR for any serve mapping whose handler path is not
`/`, for exactly these two defects. The client's v1 refusal stays as defence in depth.

**D-5 — `deviceName` handling.** Confirm the desktop displays the label, truncates rather than
rejects an over-long one, and treats it as untrusted display text (it is user-supplied and reaches a
desktop UI). Confirm the max length so the client can clamp to the same number (§4.4 assumes 64).
**ANSWERED: displayed, truncated to 64, rendered escaped, blank ⇒ `'iPhone'`** (desktop §3.4). The
client's assumed 64 is correct.

**D-6 — Bearer token, or a device keypair?**
Client assumes an opaque bearer (§1.4), which is why the transport is unchanged. Binding enrollment
to a phone-generated CryptoKit key (Secure Enclave) would give the desktop a stable device identity
and defeat a stolen token, but it changes the wire format and the WS auth path, and it must be
decided **before** `/pair/claim` is written — not added later.

**D-7 — Enrollment TTL.**
Client renders a countdown from `exp` (§1.1) and does not care about the value, but the copy in §6.2
("someone else may have used it") only makes sense with a short TTL. Confirm the number. The desktop
survey recommends 120 s; the existing SSH flow uses 10 minutes
(`src/main/pairing-service.ts:190-194`) after a field report of users scanning expired codes.

**D-8 — Does `/pair/claim` really sit above the session gate, and is its rate limiter separate from
the login lockout?**
Both are assumed in §1.3. If the pairing counter is shared with `Auth.loginAllowed()`
(`src/server/auth.ts:164-174`), then a pairing brute force locks Siim out of password login and five
bad passwords break the QR he is holding. The client's "never auto-retry on 429" rule assumes a
separate counter.
**ANSWERED: yes to both.** `/pair/claim` sits above the gate and `/pair/revoke-self` below it
(desktop §3.4, pinned by a source-level test); the pairing limiter is its own counter, ~10 failures
per 60 s (desktop §3.7).

**D-9 — Is the fused host https via `tailscale serve`, always?**
§3.3 makes the QR path https-only and gives no LAN fallback. If a plain-http LAN mode is wanted, it
needs ATS exceptions, `NSLocalNetworkUsageDescription`, and possibly a raw-socket transport — a
different and much larger piece of work, and one this spec recommends against.
**ANSWERED: yes, always.** Desktop §2.5 binds `127.0.0.1` only and keeps `tailscale serve`
terminating TLS, for the same ATS reasoning; no LAN fallback is specified on either side.

### D-10 — new, raised by the review: the cut-over is not covered by any phase or DoD

Not a wire question, which is why it went unnoticed on both sides: §4.6 said "there is nothing to
migrate" (true of the app upgrade) while the desktop deliberately invalidates the profile's cookie
*and* its password on the day it takes over the URL (true of the host cut-over). Neither document's
phase list, DoD or device checklist covered the transition.

**Resolved rather than left open**, because the fix is client-side and cheap: §6.4 adds the
"Pair with QR instead" action to the `.password` re-auth branch, §5.3's row moves from
nice-to-have to P3-required, §8.4 item 8 is the rehearsal, and desktop §7 carries the hard ordering
constraint (P3 on the device before Phase 2 unloads the launchd server). What still needs Siim
rather than an implementer is only the **scheduling**: the phone is unreachable from Phase 2 until
Phase 4/5, and he should pick when that window opens.

### Still needing a decision, not an implementation

- **D-6** (bearer vs Secure Enclave keypair) — must be answered before `/pair/claim` is written on
  either side. The client design in §0 assumes a bearer; a keypair changes the wire format and the
  WS auth path, and cannot be bolted on later.
- **D-7** (enrollment TTL) — desktop §3.2 recommends 120 s with a visible countdown and automatic
  re-mint, and falls back to 300 s if the countdown is not built; the SSH flow's own history argues
  for 10 minutes. The client renders whatever `exp` says and is genuinely indifferent, but §6.2's
  "someone else may have used it" copy only makes sense with a short window.

---

## 10. Summary of files touched

| file | change |
|---|---|
| `Sources/NodetermKit/Pairing/PairPayload.swift` | new |
| `Sources/NodetermKit/Pairing/PairPayloadParser.swift` | new |
| `Sources/NodetermKit/Pairing/PairingClient.swift` | new (`PairingClienting` + concrete) |
| `Sources/NodetermKit/Models/ServerProfile.swift` | +3 optional fields, decoder, encoder, init defaults |
| `Sources/NodetermKit/Contracts.swift` | +`PairingClienting` (new protocol; existing ones untouched) |
| `Tests/NodetermKitTests/PairingTests.swift` | new |
| `Tests/NodetermKitTests/ProfilesTests.swift` | + back-compat decode + device-token round trip |
| `Tests/NodetermKitTests/RegisteredTests.swift` | + `@Test` registrations |
| `App/Sources/Home/QRScannerView.swift` | new (AVFoundation) |
| `App/Sources/Home/PairConfirmView.swift` | new (the non-skippable confirm step) |
| `App/Sources/Home/AddServerView.swift` | restructure; `ReauthSheet` branch |
| `App/Sources/Home/ServerDetailView.swift` | + upgrade row; branched logout copy |
| `App/Sources/Core/AppEnvironment.swift` | + `pairServer` / `repair` / upgrade sequence; `removeServer` revoke leg |
| `App/Sources/Core/Factory.swift` | + `makePairing()` + `UnwiredPairing` stub |
| `App/Sources/TermscapeApp.swift` | + `.onOpenURL` (P4) |
| `App/Sources/SYMBOLS.md` | update the `ServerProfile` field list |
| `App/UITests/ConnectFlowUITests.swift` | + disclosure tap |
| `project.yml` | + `NSCameraUsageDescription`; + `info:` block for `CFBundleURLTypes` (P4) |

Not touched, and a change landing in any of them means the design in §0 was abandoned:
`Rpc/WebSocketFrameTransport.swift`, `Rpc/RpcClient.swift`, `Keychain/KeychainService.swift`,
`Auth/AuthClient.swift`, `Auth/AuthResponseClassifier.swift`, `Terminal/*`, `Stores/*`, `Demo/*`.
