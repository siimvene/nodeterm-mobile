import Foundation
@testable import NodetermKit

// NOTE ON THE TEST FRAMEWORK (mirrors WireCodecTests.swift)
// Compiles framework-free and exposes its assertions as a callable `runNewSessionPlanTests()` using
// `precondition`; RegisteredTests.swift promotes it to a swift-testing `@Test`. Covers SPEC §7.11:
// node-id shape, the launch-command grammar for claude/codex/gemini, the register payload's
// nil-omission, and the tolerant Settings / ClaudeCliCaps / Project decodes the sheet depends on.

private func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), "new-session-plan failed: \(label)")
}

private func matchesNodeIdRegex(_ id: String) -> Bool {
    id.range(of: "^term-[a-z0-9]+-[a-z0-9]{1,16}$", options: .regularExpression) != nil
}

public func runNewSessionPlanTests() {
    // MARK: - mintNodeId shape / length (SPEC §7.11.1)

    let id1 = NewSessionPlan.mintNodeId(now: Date(timeIntervalSince1970: 1),
                                        random: { 0x1a2b })
    check(matchesNodeIdRegex(id1), "mint id matches regex: \(id1)")
    check(id1.count <= 128, "mint id ≤ 128")
    check(id1.hasSuffix("-1a2b"), "mint id carries the hex suffix: \(id1)")
    check(id1.hasPrefix("term-"), "mint id has term- prefix")

    // A UInt64 renders to at most 16 hex chars — the suffix stays within {1,16}.
    let idMax = NewSessionPlan.mintNodeId(now: Date(timeIntervalSince1970: 1_700_000_000),
                                          random: { UInt64.max })
    check(matchesNodeIdRegex(idMax), "mint id (max entropy) matches regex: \(idMax)")
    check(idMax.hasSuffix("-ffffffffffffffff"), "mint id max hex is 16 f's")

    // A zero random still yields a valid 1-char suffix (never an empty middle/trailing segment).
    let idZero = NewSessionPlan.mintNodeId(now: Date(timeIntervalSince1970: 0), random: { 0 })
    check(matchesNodeIdRegex(idZero), "mint id (zero clock+random) matches regex: \(idZero)")

    // Distinct entropy ⇒ distinct ids at the same instant.
    let now = Date(timeIntervalSince1970: 12345)
    check(NewSessionPlan.mintNodeId(now: now, random: { 1 })
          != NewSessionPlan.mintNodeId(now: now, random: { 2 }), "distinct random ⇒ distinct id")

    // MARK: - launchCommand branches (SPEC §7.11.3)

    let capsOff = ClaudeCliCaps(autoPermissionMode: false, sessionIdFlag: false)
    let capsOn = ClaudeCliCaps(autoPermissionMode: true, sessionIdFlag: true)
    func cmd(_ agent: String?, _ mode: String, _ caps: ClaudeCliCaps = capsOff) -> String? {
        NewSessionPlan.launchCommand(agentId: agent, permissionMode: mode, caps: caps)
    }

    // Plain terminal / unsupported agent → no launch line.
    check(cmd(nil, "auto") == nil, "nil agent ⇒ nil")
    check(cmd("terminal", "auto") == nil, "terminal agent ⇒ nil")
    check(cmd("opencode", "auto") == nil, "unsupported agent ⇒ nil")

    // claude — auto is gated by caps.autoPermissionMode.
    check(cmd("claude", "auto", capsOff) == "claude", "claude auto (caps off) ⇒ bare")
    check(cmd("claude", "auto", capsOn) == "claude --permission-mode auto", "claude auto (caps on)")
    check(cmd("claude", "manual") == "claude", "claude manual ⇒ bare")
    check(cmd("claude", "acceptEdits") == "claude --permission-mode acceptEdits", "claude acceptEdits")
    check(cmd("claude", "plan") == "claude --permission-mode plan", "claude plan")
    check(cmd("claude", "bypassPermissions") == "claude --permission-mode bypassPermissions",
          "claude bypassPermissions")
    check(cmd("claude", "nonsense") == "claude", "claude unknown mode ⇒ bare")

    // codex — its own approval dialect; acceptEdits/plan have no equivalent ⇒ bare.
    check(cmd("codex", "manual") == "codex --ask-for-approval untrusted", "codex manual")
    check(cmd("codex", "auto") == "codex --ask-for-approval on-request", "codex auto")
    check(cmd("codex", "acceptEdits") == "codex", "codex acceptEdits ⇒ bare")
    check(cmd("codex", "plan") == "codex", "codex plan ⇒ bare")
    check(cmd("codex", "bypassPermissions") == "codex --dangerously-bypass-approvals-and-sandbox",
          "codex bypassPermissions ⇒ full yolo")
    // caps.autoPermissionMode is CLAUDE's alone — it must not change codex's on-request.
    check(cmd("codex", "auto", capsOn) == "codex --ask-for-approval on-request",
          "codex auto ignores claude caps")

    // gemini — manual/auto emit nothing (auto has no gemini equivalent).
    check(cmd("gemini", "manual") == "gemini", "gemini manual ⇒ bare")
    check(cmd("gemini", "auto") == "gemini", "gemini auto ⇒ bare (no equivalent)")
    check(cmd("gemini", "acceptEdits") == "gemini --approval-mode auto_edit", "gemini acceptEdits")
    check(cmd("gemini", "plan") == "gemini --approval-mode plan", "gemini plan")
    check(cmd("gemini", "bypassPermissions") == "gemini --approval-mode yolo", "gemini bypassPermissions")

    // MARK: - registerPayload omits nils (SPEC §7.11.4)

    let full = NewSessionPlan.registerPayload(id: "term-x-1", title: "My session",
                                              agentId: "claude", accountId: "acc-7")
    check(full["id"]?.stringValue == "term-x-1", "payload id")
    check(full["title"]?.stringValue == "My session", "payload title")
    check(full["agentId"]?.stringValue == "claude", "payload agentId")
    check(full["accountId"]?.stringValue == "acc-7", "payload accountId")
    check(full.objectValue?.count == 4, "full payload has exactly 4 keys")

    let bare = NewSessionPlan.registerPayload(id: "term-x-2", title: nil, agentId: nil, accountId: nil)
    check(bare.objectValue?.count == 1, "bare payload omits all nils (only id)")
    check(bare["title"] == nil && bare["agentId"] == nil && bare["accountId"] == nil,
          "bare payload has no null fields")
    // A managed-account session keeps accountId but may still omit a title.
    let acc = NewSessionPlan.registerPayload(id: "term-x-3", title: nil, agentId: "codex", accountId: "c1")
    check(acc.objectValue?.count == 3 && acc["title"] == nil, "account payload keeps agentId+accountId, drops title")

    // MARK: - Settings tolerant decode (SPEC §7.11.3 / §11.7)

    let sJSON = """
    {"claudePermissionMode":"plan",
     "claudeAccounts":[{"id":"a1","label":"Work","email":"w@x"},
                       {"id":"a2","pending":true},
                       {"id":"a3","host":"ssh-host"}],
     "codexAccounts":[{"id":"c1","label":"Cdx"}]}
    """
    let s = try! JSONDecoder().decode(Settings.self, from: Data(sJSON.utf8))
    check(s.claudePermissionMode == "plan", "settings claudePermissionMode")
    check(s.claudeAccounts.count == 3, "settings claudeAccounts count")
    check(s.claudeAccounts.filter { $0.isUsableHere }.map { $0.id } == ["a1"],
          "settings usable accounts skip pending + host")
    check(s.claudeAccounts[0].displayName == "Work", "account displayName ← label")
    check(s.codexAccounts.count == 1 && s.codexAccounts[0].isUsableHere, "settings codexAccounts")

    let sEmpty = try! JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    check(sEmpty.claudePermissionMode == "auto", "settings default mode")
    check(sEmpty.claudeAccounts.isEmpty && sEmpty.codexAccounts.isEmpty, "settings default empty accounts")

    // MARK: - ClaudeCliCaps tolerant decode (SPEC §7.11.3)

    let capsEmpty = try! JSONDecoder().decode(ClaudeCliCaps.self, from: Data("{}".utf8))
    check(!capsEmpty.autoPermissionMode && !capsEmpty.sessionIdFlag, "caps default false/false")
    let capsPartial = try! JSONDecoder().decode(ClaudeCliCaps.self,
                                                from: Data(#"{"autoPermissionMode":true}"#.utf8))
    check(capsPartial.autoPermissionMode && !capsPartial.sessionIdFlag, "caps partial")
    let capsFull = try! JSONDecoder().decode(
        ClaudeCliCaps.self, from: Data(#"{"autoPermissionMode":true,"sessionIdFlag":true}"#.utf8))
    check(capsFull.autoPermissionMode && capsFull.sessionIdFlag, "caps full")

    // MARK: - Project.defaultAccountId decode (SPEC §7.11.3)

    let pJSON = #"{"id":"p1","name":"P","color":"blue","nodes":[],"defaultAccountId":"acc-9"}"#
    let p = try! JSONDecoder().decode(Project.self, from: Data(pJSON.utf8))
    check(p.defaultAccountId == "acc-9", "project defaultAccountId decodes")
    let pNone = try! JSONDecoder().decode(
        Project.self, from: Data(#"{"id":"p2","name":"P","color":"gray","nodes":[]}"#.utf8))
    check(pNone.defaultAccountId == nil, "project defaultAccountId absent ⇒ nil")
}

// MARK: - mergeAccounts (SPEC §7.11.3): settings rows first, peer rows unioned by id

public func runMergeAccountsTests() {
    let a = ManagedAccount(id: "a", label: "A")
    let aPeer = ManagedAccount(id: "a", label: "A (peer)", pending: true)
    let b = ManagedAccount(id: "b", label: "B")
    let c = ManagedAccount(id: "c", label: "C")
    let merged = NewSessionPlan.mergeAccounts(settings: [a, b], peer: [c, aPeer, b])
    check(merged.map(\.id) == ["a", "b", "c"], "settings first, peer appended, duplicates dropped")
    check(merged[0].label == "A", "settings row wins over the peer row with the same id")
    check(NewSessionPlan.mergeAccounts(settings: [], peer: [c]) == [c], "peer-only topology offers the peer rows")
    check(NewSessionPlan.mergeAccounts(settings: [a], peer: []) == [a], "no peer ⇒ settings unchanged")
    check(NewSessionPlan.mergeAccounts(settings: [], peer: []).isEmpty, "nothing ⇒ nothing")
}
