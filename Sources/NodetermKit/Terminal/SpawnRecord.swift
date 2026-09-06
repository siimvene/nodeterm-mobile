import Foundation

/// The §7.11 spawn state machine for ONE session this phone spawned: what the launch line still
/// owes the pane, whether the canvas registration is settled, and WHEN the launch may be typed.
/// Pure — every transition takes its inputs (clock, delivery result, read-back outcome) as values —
/// so the whole decision table is unit-tested and the App runtime only executes I/O.
///
/// Why the memory lives here and not on the terminal view (review finding, third round): the view
/// used to decide "launch owed" from `fresh && !isReconnect`, and the runtime dropped the record once
/// registered. Two ways that went wrong: (a) a first `pty:create` whose answer was LOST (or that
/// threw transport-side) came back on the rejoin as `isReconnect:true` ⇒ no launch, so a bare shell
/// was registered as an agent node; (b) after a settled spawn every later reconnect re-created a
/// pending record and re-registered a long-confirmed node. So: the record is retained once settled
/// (`recording(existing:…)` is a no-op on it), and "launch owed" is decided from RECORD state —
/// no record + `fresh:true` ⇒ owed; no record + `fresh:false` ⇒ owed but GATED through
/// `LaunchRedelivery` (a `pty:pane-command` read), so a shell already running the agent is never
/// typed into again.
public struct SpawnRecord: Sendable, Equatable {

    /// The desktop's cap on total shell silence before the launch is written anyway (SPEC §7.11.3).
    /// A record is never delivered into before `recordedAt + silenceCap` unless the view that
    /// watched the pane's first output marks it settled earlier (`markSettled`).
    public static let silenceCap: TimeInterval = 1.5
    /// The ONE bounded delay before a launch that stayed undelivered (a `.deferred` delivery) is
    /// re-tried on the runtime's own initiative; after that the banner takes over.
    public static let redeliveryDelay: TimeInterval = 3.0
    /// The ONE bounded delay before a launch whose FIRST pane check said "busy" (a provisional
    /// `.dropped`) is probed again, before the drop is concluded — the 1.5 s silence cap can end
    /// while a transient rc-file child (starship/node/git) still holds the foreground, and a bare
    /// shell returns moments later (SPEC §7.11.3).
    public static let reprobeDelay: TimeInterval = 2.0

    public enum Launch: Sendable, Equatable {
        /// A plain terminal: nothing to type, ever.
        case none
        /// Still owed to the pane. `gated`: a delivery must first prove (via `pty:pane-command` →
        /// `LaunchRedelivery.decide`) that the pane is still a bare shell. Set from birth for a
        /// lost-answer record, and after ANY attempt (a throw can hide a request that landed).
        case owed(command: String, gated: Bool)
        /// `pty:send-text` answered `true`.
        case landed
        /// The pane already runs something other than a shell: the launch is there or would land in
        /// the wrong process. Never typed. Only reached after a re-probe confirmed the busy pane —
        /// a single "busy" read never concludes here (`apply(delivery: .dropped)` re-probes once).
        case dropped
    }

    /// What the driver should do for the launch half right now.
    public enum Step: Sendable, Equatable {
        case nothing
        /// The settle window has not passed: poll again (a `markSettled` may shorten it).
        case wait(until: Date)
        /// Deliver; `checkPane` says a `pty:pane-command` proof must precede the `pty:send-text`.
        case deliver(command: String, checkPane: Bool)
    }

    /// The outcome of one delivery attempt, as the runtime observed it.
    public enum Delivery: Sendable, Equatable {
        /// `pty:send-text` answered `true`.
        case landed
        /// The pane check said something else is in the foreground.
        case dropped
        /// Nothing landed as far as we know (`send-text` answered `false`, the pane check could not
        /// say, or a non-transport error): still owed, and every later attempt is gated.
        case deferred
        /// Socket gone mid-call: the request MAY have landed. Still owed, gated, but this does not
        /// count as an attempt — the reconnect re-drives it.
        case transient
    }

    /// The one-line banner the terminal shows for this spawn, or nil (pending / all settled).
    /// Registration states win over the launch state: `.unsaved` and `.registrationUnknown` are the
    /// §7.11.4 read-back outcomes; `.launchUndelivered` shows only for a REGISTERED node whose
    /// launch is still owed after the delayed redelivery also failed — the exact shape a bare shell
    /// registered as an agent node takes, which is the failure §7.11 warns about; `.launchDropped`
    /// shows for a REGISTERED node whose launch was skipped because the pane was already busy (the
    /// re-probe confirmed it) — dismissible, and its Retry re-probes and re-delivers.
    public enum Banner: Sendable, Equatable {
        case unsaved
        case registrationUnknown
        case launchUndelivered
        case launchDropped
    }

    public let projectId: String
    /// The `workspace:register-node` payload, minted once from the launch (SPEC §7.11.4).
    public let payload: JSONValue
    /// The launch line this record owes, retained across a `.dropped` (which drops it off `launch`)
    /// so an explicit Retry can re-arm the exact same command.
    public let launchCommand: String?
    public private(set) var launch: Launch
    /// The launch may not be typed before this instant (SPEC §7.11.3 timing), whoever drives.
    public private(set) var notBefore: Date
    /// Completed, non-transient delivery attempts (`.deferred` outcomes so far).
    public private(set) var launchAttempts = 0
    public private(set) var redeliveryScheduled = false
    /// A first "busy" pane read (a provisional `.dropped`) has been seen; the next `.dropped`
    /// CONCLUDES the drop instead of re-probing. Reset by an explicit `retryLaunch`.
    public private(set) var dropReprobed = false
    /// A one-shot re-probe is owed after a provisional `.dropped`; consumed by `scheduleDropReprobe`.
    public private(set) var pendingDropReprobe = false
    /// The user dismissed the `.launchDropped` banner: hide it (the session keeps running).
    public private(set) var launchDropAcknowledged = false
    /// nil while registration is still pending (never concluded, or waiting for a socket).
    public private(set) var outcome: RegistrationOutcome?

    /// - Parameters:
    ///   - command: the launch line, or nil for a plain terminal.
    ///   - createFresh: the `fresh` flag of the `pty:create` answer that produced this record. `false`
    ///     means the session already existed when we first heard of it (a lost first answer): the
    ///     launch is still owed, but only into a proven bare shell.
    ///   - now: the clock; the settle window is `now + silenceCap`.
    public init(projectId: String, payload: JSONValue, command: String?, createFresh: Bool, now: Date) {
        self.projectId = projectId
        self.payload = payload
        self.launchCommand = command
        self.launch = command.map { .owed(command: $0, gated: !createFresh) } ?? .none
        self.notBefore = now.addingTimeInterval(Self.silenceCap)
    }

    /// The runtime's record rule: an EXISTING record — pending, settled, anything — is returned
    /// unchanged, so a rejoin (reconnect, attach race, re-appearance) can neither re-arm a launch
    /// nor re-open a settled registration. Only a node with no record gets a new one.
    public static func recording(existing: SpawnRecord?, projectId: String, payload: JSONValue,
                                 command: String?, createFresh: Bool, now: Date) -> SpawnRecord {
        if let existing { return existing }
        return SpawnRecord(projectId: projectId, payload: payload, command: command,
                           createFresh: createFresh, now: now)
    }

    // MARK: Derived state

    public var launchOwed: Bool {
        if case .owed = launch { return true }
        return false
    }
    public var registrationPending: Bool { outcome == nil || outcome == .unknown }
    /// Still owes work: an undelivered launch, or a registration that is pending / UNKNOWN.
    public var needsDrive: Bool { launchOwed || registrationPending }
    public var isSettled: Bool { !needsDrive }

    public var banner: Banner? {
        switch outcome {
        case .unsaved: return .unsaved
        case .unknown: return .registrationUnknown
        case .registered:
            // A concluded drop and an undelivered launch both surface only on a REGISTERED node
            // (the registration banners above dominate). The drop banner is dismissible.
            if case .dropped = launch, !launchDropAcknowledged { return .launchDropped }
            return (launchOwed && launchAttempts >= 2) ? .launchUndelivered : nil
        case nil: return nil
        }
    }

    // MARK: Transitions

    /// The view that watched the pane's first output saw 200 ms of quiet (SPEC §7.11.3): the launch
    /// may go now. Only ever SHORTENS the window.
    public mutating func markSettled(now: Date) {
        if now < notBefore { notBefore = now }
    }

    public func launchStep(now: Date) -> Step {
        guard case .owed(let command, let gated) = launch else { return .nothing }
        if now < notBefore { return .wait(until: notBefore) }
        return .deliver(command: command, checkPane: gated)
    }

    public mutating func apply(delivery: Delivery) {
        guard case .owed(let command, _) = launch else { return }
        switch delivery {
        case .landed: launch = .landed
        case .dropped:
            // A single "busy" pane read never concludes: the 1.5 s silence cap can end while a
            // transient rc-file child still holds the foreground. Re-probe ONCE (stay owed+gated);
            // only a second "busy" read — after `reprobeDelay` — concludes `.dropped`.
            if dropReprobed {
                launch = .dropped
            } else {
                dropReprobed = true
                pendingDropReprobe = true
                launch = .owed(command: command, gated: true)
            }
        case .deferred:
            launch = .owed(command: command, gated: true)
            launchAttempts += 1
        case .transient:
            launch = .owed(command: command, gated: true)
        }
    }

    public mutating func apply(registration: RegistrationOutcome) {
        outcome = registration
    }

    /// Whether the runtime should arm its ONE delayed redelivery now: the launch is still owed after
    /// a completed attempt, and none was armed before. Returns true exactly once per record.
    public mutating func scheduleRedelivery() -> Bool {
        guard launchOwed, launchAttempts >= 1, !redeliveryScheduled else { return false }
        redeliveryScheduled = true
        return true
    }

    /// Whether the runtime should arm its ONE post-drop re-probe now. Returns true exactly once per
    /// provisional `.dropped`; after it fires, a second "busy" read concludes the drop.
    public mutating func scheduleDropReprobe() -> Bool {
        guard pendingDropReprobe else { return false }
        pendingDropReprobe = false
        return true
    }

    /// The user dismissed the `.launchDropped` banner. The session keeps running; the banner hides.
    public mutating func acknowledgeDrop() { launchDropAcknowledged = true }

    /// Retry a launch that was CONCLUDED `.dropped`: re-arm the owed (gated) command and clear the
    /// re-probe/dismiss latches, so the explicit retry gets its own one re-probe before giving up.
    /// A no-op unless the launch is currently `.dropped` (nothing else needs re-arming).
    public mutating func retryLaunch() {
        guard case .dropped = launch, let command = launchCommand else { return }
        launch = .owed(command: command, gated: true)
        dropReprobed = false
        pendingDropReprobe = false
        launchDropAcknowledged = false
    }
}

/// Classify a transport failure of a spawn RPC (`pty:send-text`, `pty:pane-command`, or
/// `workspace:register-node`) by whether the request could still have reached a LIVE server. A
/// `.disconnected`, or a `.timeout` on a socket no longer `.connected`, means the socket is gone:
/// the call MAY have landed and the reconnect re-drives it, so it counts nothing and abandons this
/// drive. A `.timeout` while the socket is still `.connected` reached a live server and the client's
/// deadline passed — a REAL attempt: a launch delivery becomes `.deferred` (counts, can arm the one
/// redelivery), and a registration proceeds to its read-back exactly as an `E_HANDLER` refusal does.
/// Any other `RpcError` is a server answer (`E_NO_HANDLER`/`E_HANDLER`), i.e. `.liveDeadline`.
public enum SpawnTransportFault: Sendable, Equatable {
    case socketGone
    case liveDeadline

    public static func classify(error: RpcError, stillConnected: Bool) -> SpawnTransportFault {
        switch error {
        case .disconnected: return .socketGone
        case .timeout: return stillConnected ? .liveDeadline : .socketGone
        default: return .liveDeadline
        }
    }
}
