import Foundation
import NodetermKit

/// THE SINGLE PLACE that names concrete NodetermKit implementations. Every other App file depends
/// only on the Kit PROTOCOLS (Contracts.swift), so when the module builders land their concrete
/// types the integrator fixes names HERE and nowhere else.
///
/// The concrete construction is guarded behind `NODETERM_KIT_IMPL_READY` so the App target keeps
/// type-checking with lightweight stubs even in a checkout where a build setting has not enabled
/// the live wiring yet. Define `NODETERM_KIT_IMPL_READY` in the App target's build settings to go
/// live; the concrete Kit types below all exist in NodetermKit.
///
/// The two speech transcribers (`AppleSpeechTranscriber`, `ServerWhisperTranscriber`) are THIS
/// builder's own types and are always available.
///
/// Concrete type names (verified against the real Kit — see SYMBOLS.md):
///   KeychainStoring            → `KeychainService()`
///   ServerProfileStoring       → `try ServerProfileStore()`
///   AuthClienting              → `AuthClient()`
///   FrameTransporting          → `WebSocketFrameTransport(url:cookieValue:)`
///   RpcClienting               → `RpcClient(makeTransport:)`
///   WorkspaceStoring           → `WorkspaceStore()`
///   AgentStatusReducing        → `AgentStatusStore()`
///   TerminalSessionControlling → `TerminalSessionController(rpc:)`
public enum Factory {

    @MainActor
    public static func makeKeychain() -> KeychainStoring {
        #if NODETERM_KIT_IMPL_READY
        return KeychainService()
        #else
        return UnwiredKeychain()
        #endif
    }

    @MainActor
    public static func makeProfileStore() -> ServerProfileStoring {
        #if NODETERM_KIT_IMPL_READY
        // ServerProfileStore.init throws only if the app-support directory is unavailable — an
        // unrecoverable condition for a store whose whole job is to persist servers (SPEC §8.1).
        do {
            return try ServerProfileStore()
        } catch {
            fatalError("Factory.makeProfileStore: server profile storage is unavailable: \(error)")
        }
        #else
        return UnwiredProfileStore()
        #endif
    }

    @MainActor
    public static func makeAuth() -> AuthClienting {
        #if NODETERM_KIT_IMPL_READY
        return AuthClient()
        #else
        return UnwiredAuth()
        #endif
    }

    /// Build a fully wired per-server runtime (SPEC §8.1). This is the only assembly of the
    /// per-server object graph: FrameTransport → RpcClient → stores → terminal control + speech.
    @MainActor
    public static func makeRuntime(profile: ServerProfile,
                                   cookie: String,
                                   settings: AppSettings,
                                   deviceName: String) -> ServerRuntime {
        #if NODETERM_KIT_IMPL_READY
        // SPEC §4.1/§10.1a: the WS upgrade carries `Cookie: nt_session=<cookie>` keyed by PROFILE,
        // never by hostname, and NO Origin header. The transport is responsible for that.
        guard let wsURL = profile.webSocketURL else {
            fatalError("Factory: profile \(profile.id) has no host for a WebSocket URL")
        }
        // SPEC §4.8: RpcClient owns the reconnect loop, so it is handed a transport FACTORY (a
        // fresh WebSocketFrameTransport per connect attempt), not a single reused instance.
        let rpc: RpcClienting = RpcClient(makeTransport: {
            WebSocketFrameTransport(url: wsURL, cookieValue: cookie)
        })
        let workspace: WorkspaceStoring = WorkspaceStore()
        let reducer: AgentStatusReducing = AgentStatusStore()
        let terminal: TerminalSessionControlling = TerminalSessionController(rpc: rpc)
        let serverSpeech: SpeechTranscribing = ServerWhisperTranscriber(rpc: rpc)
        let appleSpeech: SpeechTranscribing = AppleSpeechTranscriber()
        return ServerRuntime(profile: profile, rpc: rpc, workspaceStore: workspace,
                             reducer: reducer, terminal: terminal,
                             appleSpeech: appleSpeech, serverSpeech: serverSpeech,
                             deviceName: deviceName)
        #else
        fatalError("Factory.makeRuntime: define NODETERM_KIT_IMPL_READY and wire the concrete Kit types (see this file's header).")
        #endif
    }

    /// Build the synthetic **demo** runtime (docs/DEMO-MODE.md): the SAME object graph as
    /// `makeRuntime`, but with NO cookie and NO Keychain — the only difference is the transport
    /// factory, which builds a `DemoFrameTransport` that opens offline and replays `DemoScript`.
    /// Everything above the socket (`RpcClient`, the stores, `TerminalSessionController`, the
    /// SwiftTerm view) is byte-identical to a live server, so a reviewer drives the real UI.
    @MainActor
    public static func makeDemoRuntime(settings: AppSettings,
                                       deviceName: String) -> ServerRuntime {
        #if NODETERM_KIT_IMPL_READY
        // SPEC §4.8: RpcClient owns the reconnect loop, so it is handed a transport FACTORY. The
        // demo factory needs no URL and no cookie — the synthetic transport is offline by design.
        let rpc: RpcClienting = RpcClient(makeTransport: { DemoFrameTransport() })
        let workspace: WorkspaceStoring = WorkspaceStore()
        let reducer: AgentStatusReducing = AgentStatusStore()
        let terminal: TerminalSessionControlling = TerminalSessionController(rpc: rpc)
        let serverSpeech: SpeechTranscribing = ServerWhisperTranscriber(rpc: rpc)
        let appleSpeech: SpeechTranscribing = AppleSpeechTranscriber()
        return ServerRuntime(profile: DemoScript.profile, rpc: rpc, workspaceStore: workspace,
                             reducer: reducer, terminal: terminal,
                             appleSpeech: appleSpeech, serverSpeech: serverSpeech,
                             deviceName: deviceName)
        #else
        fatalError("Factory.makeDemoRuntime: define NODETERM_KIT_IMPL_READY and wire the concrete Kit types (see this file's header).")
        #endif
    }
}

#if !NODETERM_KIT_IMPL_READY
// Placeholder witnesses so the App target type-checks before the Kit implementations land. They
// throw/fatalError if used — the app is a compiling scaffold until `NODETERM_KIT_IMPL_READY` is set.
private struct UnwiredKeychain: KeychainStoring {
    func saveCookie(_ value: String, forServer profileId: String) throws { throw unwired() }
    func cookie(forServer profileId: String) throws -> String? { nil }
    func deleteCookie(forServer profileId: String) throws {}
    func savePassword(_ value: String, forServer profileId: String) throws { throw unwired() }
    func password(forServer profileId: String) throws -> String? { nil }
    func deletePassword(forServer profileId: String) throws {}
    func deleteAll(forServer profileId: String) throws {}
    private func unwired() -> NSError { NSError(domain: "nodeterm.factory", code: -1) }
}
private struct UnwiredProfileStore: ServerProfileStoring {
    func all() throws -> [ServerProfile] { [] }
    func profile(id: String) throws -> ServerProfile? { nil }
    func add(_ profile: ServerProfile) throws {}
    func update(_ profile: ServerProfile) throws {}
    func remove(id: String) throws {}
}
private struct UnwiredAuth: AuthClienting {
    func login(baseURL: URL, password: String) async throws -> String { throw AuthError.network }
    func logout(baseURL: URL, cookie: String) async {}
    func setup(baseURL: URL, token: String, password: String) async throws -> String { throw AuthError.network }
    func detectUnconfigured(baseURL: URL) async throws -> Bool { false }
}
#endif
