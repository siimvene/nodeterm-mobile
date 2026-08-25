import Foundation
import NodetermKit

/// The one `presence:hello` cast the phone sends on connect (SPEC §11.8): even though v0 consumes
/// no presence, announcing the device name keeps the desktop facepile from showing an anonymous
/// "Someone". The exact arg shape is UNPINNED (SPEC §12 item 6) — we send a single object carrying
/// the device name and `kind:'phone'`, which is forward-safe (unknown fields are ignored server
/// side, and a cast to a method that ignores the arg is a silent no-op — SPEC §4.6).
public enum PresenceHello {
    /// Build the `presence:hello` cast args. `name` is the device name, capped at 32 (SPEC §11.8).
    public static func args(deviceName: String) -> [RpcArg] {
        let name = String(deviceName.prefix(32))
        let payload: JSONValue = .object([
            "name": .string(name),
            "kind": .string(PeerKind.phone.wire),
        ])
        return [.value(payload)]
    }
}
