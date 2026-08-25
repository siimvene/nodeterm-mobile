import Foundation
@testable import NodetermKit

// NOTE ON THE TEST FRAMEWORK
// This machine has only Apple CommandLineTools (no full Xcode), so neither XCTest nor the
// swift-testing macro plugin is available to `swift test`. This file therefore compiles
// framework-free (proving Models + Contracts import and type-check from the test target) and
// exposes the codec smoke checks as a callable function. A builder on a full toolchain promotes
// each `check(...)` to a `@Test`/`XCTest` case by adding `import Testing` (or `import XCTest`) —
// the assertions are already written. `swift test` here runs and reports zero discovered tests,
// which is the accepted state for the skeleton.

private func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), "wire-smoke failed: \(label)")
}

/// Exercises the wire codecs the whole client rests on (SPEC §4.3/§4.4/§4.5, §11.7). Call from a
/// real test once a testing framework is available on the toolchain.
public func runWireCodecSmoke() {
    // SPEC §4.4: OMITTED slot → null + index in `undef`; a MEANINGFUL null (park) → null, unlisted.
    let (args, undef) = RpcArgs.encode([.value("nt-1"), .null, .null, .omitted])
    check(args == [.string("nt-1"), .null, .null, .null], "undef encode args")
    check(undef == [3], "undef encode indexes")

    // SPEC §4.4: decode ignores out-of-range / negative indexes.
    check(RpcArgs.absentIndexes([1, 9, -2], count: 3) == Set([1]), "undef decode range")

    // SPEC §4.5 binary pty frame round-trip + drop rules.
    let sid = "nt-abc"
    let payload = Data("hello".utf8)
    var frame = Data([PtyBinaryFrame.dataFrameTag])
    let sidBytes = Array(sid.utf8)
    frame.append(UInt8((sidBytes.count >> 8) & 0xff))
    frame.append(UInt8(sidBytes.count & 0xff))
    frame.append(contentsOf: sidBytes)
    frame.append(payload)
    let decoded = PtyBinaryFrame.decode(frame)
    check(decoded?.sessionId == sid, "binary sid")
    check(decoded?.payload == payload, "binary payload")
    check(PtyBinaryFrame.decode(Data([0x01, 0x00])) == nil, "binary too short")
    check(PtyBinaryFrame.decode(Data([0x02, 0x00, 0x00])) == nil, "binary wrong tag")

    // SPEC §4.3: res parsing; a res with null error must drop.
    check(RpcFrame.parse(text: #"{"t":"res","id":7,"ok":true,"result":null}"#)
          == .resOk(id: 7, result: .null), "res ok")
    check(RpcFrame.parse(text:
          #"{"t":"res","id":8,"ok":false,"error":{"code":"E_NO_HANDLER","message":"x"}}"#)
          == .resErr(id: 8, error: RpcErrorPayload(code: "E_NO_HANDLER", message: "x")), "res err")
    check(RpcFrame.parse(text: #"{"t":"res","id":9,"ok":false,"error":null}"#) == nil, "res null-error drop")
    check(RpcFrame.parse(text: "not json") == nil, "non-json drop")

    // SPEC §6.2/§11.4: unknown agent event kind decodes tolerantly; absent optionals are nil.
    let ev = try! JSONDecoder().decode(
        AgentStatusEvent.self,
        from: Data(#"{"nodeId":"n1","agentId":"claude","kind":"future-kind"}"#.utf8))
    check(ev.kind == .unknown("future-kind"), "agent kind tolerant")
    check(ev.state == nil && ev.pendingId == nil, "agent absent optionals")

    // SPEC §11.7: Settings falls back to spec defaults for absent fields.
    let s = try! JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    check(s.claudePermissionMode == "auto" && s.tmuxScrollback == 50000 && s.defaultShell == nil,
          "settings defaults")
}
