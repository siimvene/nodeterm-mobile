import Foundation
@testable import NodetermKit

// FRAMEWORK-FREE TESTS (see the sibling test files): this machine has only CommandLineTools, so
// neither XCTest nor swift-testing is available to `swift test`. This file compiles in the test
// target (proving the Rpc surface type-checks) and exposes its assertions as a callable
// `runRpcCodecTests()` using `precondition`. On a full toolchain a builder promotes each
// `expect(...)` to a `@Test`/XCTest case — the assertions are already written. `swift test` here
// runs and reports zero discovered tests, the accepted skeleton state.
//
// Codec round-trips: the `undef` out-of-band index encoding (SPEC §4.4) and the binary pty frame
// (§4.5), both directions, over the fixed contract primitives plus this builder's binary encoder.

@inline(__always)
private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), "rpc-codec test failed: \(label)")
}

public func runRpcCodecTests() {
    // MARK: §4.4 encode — omitted vs meaningful null vs value

    // pty:resize(sid, x, <omitted viewerId>) — the omitted trailing slot IS listed in undef.
    do {
        let (args, undef) = RpcArgs.encode([.value("nt-1"), .value(80), .omitted])
        expect(args == [.string("nt-1"), .number(80), .null], "omitted emits null")
        expect(undef == [2], "omitted index listed")
    }

    // pty:resize(sid, null, null) — the PARK signal. Real nulls, NOT listed (§4.4/§7.3).
    do {
        let (args, undef) = RpcArgs.encode([.value("nt-1"), .null, .null])
        expect(args == [.string("nt-1"), .null, .null], "park emits nulls")
        expect(undef == [], "park nulls never appear in undef")
    }

    // Identical wire `args`, distinguished only by `undef`.
    do {
        let (argsA, undefA) = RpcArgs.encode([.value("a"), .null])      // meaningful null
        let (argsB, undefB) = RpcArgs.encode([.value("a"), .omitted])   // omitted
        expect(argsA == argsB, "both emit [a, null]")
        expect(undefA == [], "meaningful null unlisted")
        expect(undefB == [1], "omitted listed")
    }

    do {
        let (args, undef) = RpcArgs.encode([.omitted, .value("x"), .omitted, .omitted])
        expect(args == [.null, .string("x"), .null, .null], "multi-omit args")
        expect(undef == [0, 2, 3], "multi-omit indexes in order")
    }

    // MARK: §4.4 decode — junk indexes can never lengthen args

    expect(RpcArgs.absentIndexes([-1, 0, 5, 99], count: 2) == Set([0]), "junk/out-of-range filtered")
    expect(RpcArgs.absentIndexes([99], count: 2) == Set([]), "all-junk marks nothing")
    expect(RpcArgs.absentIndexes([], count: 3) == Set([]), "empty undef marks nothing")
    expect(RpcArgs.absentIndexes([0, 1, 2], count: 3) == Set([0, 1, 2]), "all valid marked")
    do {
        let args: [JSONValue] = [.string("only")]
        let absent = RpcArgs.absentIndexes([1, 2, 3, 100], count: args.count)
        expect(absent.isEmpty && args.count == 1, "junk undef never lengthens args")
    }

    // MARK: §4.3 JSON frame round-trip preserving undef

    roundTrip(RpcFrame.req(id: 7, method: "pty:resize",
                           args: [.string("nt-1"), .number(80), .null], undef: [2]), "req+undef")
    do {
        let frame = RpcFrame.req(id: 1, method: "workspace:load", args: [], undef: [])
        let text = try! frame.encodedText()
        expect(!text.contains("undef"), "undef omitted when empty")
        expect(RpcFrame.parse(text: text) == frame, "req empty-undef round-trip")
    }
    roundTrip(RpcFrame.cast(method: "pty:write", args: [.string("nt-1"), .string("ls\r")], undef: []), "cast")
    roundTrip(RpcFrame.resOk(id: 3, result: .null), "resOk null result")
    roundTrip(RpcFrame.resErr(id: 4, error: RpcErrorPayload(code: "E_NO_HANDLER", message: "pty:generate-name")), "resErr")
    roundTrip(RpcFrame.ev(channel: "agent:status", args: [.object(["nodeId": .string("nt-9")]), .null], undef: [1]), "ev+undef")

    // MARK: §4.3 malformed frames drop to nil, never crash

    expect(RpcFrame.parse(text: "not json") == nil, "non-json drops")
    expect(RpcFrame.parse(text: "[1,2,3]") == nil, "non-object drops")
    expect(RpcFrame.parse(text: #"{"t":"res"}"#) == nil, "res without id drops")
    expect(RpcFrame.parse(text: #"{"t":"res","id":1}"#) == nil, "res without ok drops")
    expect(RpcFrame.parse(text: #"{"t":"res","id":1,"ok":false,"error":null}"#) == nil, "res null error drops")
    expect(RpcFrame.parse(text: #"{"t":"ev","channel":"x"}"#) == nil, "ev without args drops")
    expect(RpcFrame.parse(text: #"{"t":"ev","args":[]}"#) == nil, "ev without channel drops")
    expect(RpcFrame.parse(text: #"{"t":"bogus"}"#) == nil, "unknown t drops")

    // MARK: §4.5 binary pty frame round-trip (both directions)

    binRoundTrip(sid: "nt-abc", text: "hello world")
    binRoundTrip(sid: "nt-1", text: "héllo · 🦝 · 世界 · \u{1b}[31mred\u{1b}[0m")  // multi-byte payload
    binRoundTrip(sid: "nt-世界-🦝", text: "x")                                     // multi-byte sid
    do {
        // sessionId > 255 bytes forces a real 2-byte big-endian length (300 = 0x01 0x2C).
        let sid = String(repeating: "s", count: 300)
        expect(sid.utf8.count == 300, "sid is 300 bytes")
        let frame = PtyBinaryFrame.encode(sessionId: sid, text: "payload")
        expect(frame.map { [UInt8]($0)[1] } == 0x01, "big-endian high byte")
        expect(frame.map { [UInt8]($0)[2] } == 0x2C, "big-endian low byte")
        let decoded = frame.flatMap(PtyBinaryFrame.decode)
        expect(decoded?.sessionId == sid, ">255-byte sid round-trips")
        expect(decoded.map { String(decoding: $0.payload, as: UTF8.self) } == "payload", ">255 payload")
    }
    do {
        let frame = PtyBinaryFrame.encode(sessionId: "nt-1", payload: Data())
        let decoded = frame.flatMap(PtyBinaryFrame.decode)
        expect(decoded?.sessionId == "nt-1" && decoded?.payload.count == 0, "empty payload round-trips")
    }

    // §4.5 decode rejects malformed binary frames
    expect(PtyBinaryFrame.decode(Data([0x01, 0x00])) == nil, "length < 3 drops")
    expect(PtyBinaryFrame.decode(Data([0x02, 0x00, 0x00])) == nil, "wrong tag drops")
    expect(PtyBinaryFrame.decode(Data([0x01, 0x00, 0x05, 0x61])) == nil, "3+sidLen>length drops")

    // encoder refuses a sid beyond uint16 (matches what decode can read back)
    expect(PtyBinaryFrame.encode(sessionId: String(repeating: "s", count: 70_000), text: "x") == nil,
           "sid beyond uint16 refused")

    expect(PtyBinaryFrame.channel(for: "nt-1") == "pty:data:nt-1", "channel name")
}

private func roundTrip(_ frame: RpcFrame, _ label: String) {
    let text = try! frame.encodedText()
    precondition(RpcFrame.parse(text: text) == frame, "rpc-codec test failed: round-trip \(label)")
}

private func binRoundTrip(sid: String, text: String) {
    let frame = PtyBinaryFrame.encode(sessionId: sid, text: text)
    let decoded = frame.flatMap(PtyBinaryFrame.decode)
    precondition(decoded?.sessionId == sid, "rpc-codec test failed: bin sid \(sid)")
    precondition(decoded.map { String(decoding: $0.payload, as: UTF8.self) } == text,
                 "rpc-codec test failed: bin payload \(sid)")
}
