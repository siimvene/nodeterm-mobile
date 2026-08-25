# nodeterm-mobile

Native iOS client for a self-hosted **nodeterm Server Edition**. This repository is the build
skeleton: a dependency-free Swift package (`NodetermKit`) that fixes every wire type and protocol,
plus an iOS app target that five parallel builders fill in.

The single source of truth is **[`docs/SPEC.md`](docs/SPEC.md)** — the standalone, normative iOS
client specification. Every normative behavior in the code cites its section (e.g. `// SPEC §7.1`).

## Layout

```
Package.swift                 Swift 6, library product NodetermKit, iOS 17 / macOS 14, NO deps
Sources/NodetermKit/
  Models/                     All wire types (SPEC §11) — Codable, Sendable, tolerant decoding
  Contracts.swift             The FIXED protocols builders implement against (SPEC §5/§7/§8)
Tests/NodetermKitTests/       Codec smoke checks (see the testing note below)
App/Sources/                  iOS app target (SwiftUI @main placeholder; builder 5 replaces it)
project.yml                   xcodegen config for the app target (SwiftTerm 1.15.0, Info.plist)
docs/SPEC.md                  The normative specification
```

`NodetermKit` MUST stay free of third-party dependencies. SwiftTerm (pinned to **exact 1.15.0**)
is an App-target dependency only.

## Building the package (here, on macOS)

```bash
swift build
swift test --disable-swift-testing
```

`swift build` compiles the library. The test target compiles too, but see the caveat below.

### Testing caveat (CommandLineTools-only host)

`swift build` and the test-target compile work on a machine with only Apple CommandLineTools.
Running tests does **not**: CommandLineTools ships neither `XCTest.framework` nor
`Testing.framework` at runtime, so plain `swift test` fails while trying to `dlopen`
`Testing.framework`, and there are no runnable test cases regardless.

- On a CommandLineTools-only host, use `swift test --disable-swift-testing` — it builds the tests
  and exits 0 (zero discovered tests).
- On a full Xcode toolchain, plain `swift test` runs. To make the codec smoke checks in
  `Tests/NodetermKitTests/WireCodecTests.swift` execute, a builder adds `import Testing` (or
  `import XCTest`) and wraps `runWireCodecSmoke()` in a `@Test` / `XCTestCase` — the assertions are
  already written.

## Building the iOS app

There is no Xcode on the CI/dev host, so the `.xcodeproj` is generated on demand and is
**gitignored** (never committed):

```bash
xcodegen generate      # writes NodetermMobile.xcodeproj from project.yml
open NodetermMobile.xcodeproj
```

The app target (`NodetermMobile`, bundle id `dev.nodeterm.mobile`, iOS 17+, SwiftUI lifecycle)
depends on the local `NodetermKit` package and on SwiftTerm 1.15.0. iOS targets cannot be compiled
from the CommandLineTools CLI — build the app in Xcode.

## House rules (enforced across all builders)

- Swift 6 language mode, complete strict concurrency. Actors for shared mutable state; `Sendable`
  value types. `@unchecked Sendable` only with a comment proving why.
- No force-unwraps outside tests.
- No third-party dependencies beyond SwiftTerm (App target only). `NodetermKit` stays dep-free.
- Secrets never in logs; redact `Cookie` / `Set-Cookie` in any debug output (SPEC §10).
- Comments in English. Every normative behavior cites its spec section.
- **The protocol signatures in `Contracts.swift` are FINAL** — builders implement against them and
  MUST NOT change them.

## What this is NOT (SPEC §1)

No subscription/quota/"Unlock"/"Pair Desktop"/"Restore Purchase", no entitlement system, no relay
or `api.nodeterm.dev`. The self-host build is fully unlocked.
