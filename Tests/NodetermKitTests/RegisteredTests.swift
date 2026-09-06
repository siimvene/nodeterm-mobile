import Testing
@testable import NodetermKit

// Registers the parallel builders' framework-free `run…()` assertion suites as real
// swift-testing `@Test` cases so `swift test` discovers and executes them (the individual
// files stay framework-free and callable). Each suite aborts via `precondition` on the first
// failed assertion, which swift-testing surfaces as a failing run. Grouped by the module each
// builder owns; see the per-file headers for the SPEC sections each assertion cites.

// MARK: - Wire codecs (SPEC §4.3/§4.4/§4.5, §11.7)

@Test func wireCodecSmoke() { runWireCodecSmoke() }

// MARK: - RPC codecs (SPEC §4)

@Test func rpcCodec() { runRpcCodecTests() }

// MARK: - RPC client actor (SPEC §4/§8.2)

@Test func rpcClient() async { await runRpcClientTests() }

// MARK: - Auth HTTP surface (SPEC §3)

@Test func authSetCookieParsing() { runSetCookieParsingTests() }
@Test func authLoginClassification() { runLoginClassificationTests() }
@Test func authSetupAndProbeClassification() { runSetupAndProbeClassificationTests() }
@Test func authFormEncoding() { runFormEncodingTests() }
@Test func authRedaction() { runRedactionTests() }

// MARK: - Keychain contract (SPEC §10)

@Test func keychainFake() { runKeychainFakeTests() }

// MARK: - Server profiles (SPEC §8.1)

@Test func profileStore() { runProfileStoreTests() }
@Test func profileStoreCorruptFile() { runProfileStoreCorruptFileTest() }

// MARK: - Agent-status reducer (SPEC §6.3)

@Test func agentStatusReducer() { runStoresReducerTests() }

// MARK: - Agent-status store (SPEC §6.3)

@Test func agentStatusStore() async { await runStoresStoreTests() }

// MARK: - Workspace store (SPEC §6.4)

@Test func workspaceStore() async { await runStoresWorkspaceTests() }

// MARK: - Terminal session controller (SPEC §7)

@Test func terminalSession() async { await runTerminalSessionSmoke() }

// MARK: - New-session plan: mint / launch grammar / register payload (SPEC §7.11)

@Test func newSessionPlan() { runNewSessionPlanTests() }
@Test func newSessionPermissionMode() { runPermissionModeResolutionTests() }
@Test func newSessionSettingsRowTolerance() { runSettingsRowToleranceTests() }

// MARK: - Spawn read-back decision + launch re-delivery (SPEC §7.11.3 / §7.11.4)

@Test func registrationOutcome() { runRegistrationOutcomeTests() }
@Test func launchRedelivery() { runLaunchRedeliveryTests() }
@Test func spawnRecord() { runSpawnRecordTests() }
@Test func spawnTransportFault() { runSpawnTransportFaultTests() }
@Test func derivedTitle() { runDerivedTitleTests() }

// MARK: - HOME session list: rows + project grouping (SPEC §9.1)

@Test func sessionListModel() { runSessionListModelTests() }
