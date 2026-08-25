import SwiftUI
import NodetermKit

/// The chat/transcript view of a Claude session (SPEC §1.1 "Transcript read" v0, §5.4, §11.7).
/// Calls `chat:read-transcript` with `[sessionId?, cwd?, accountId?]` — absent slots ride the
/// `undef` encoding (`.omitted`, §4.4). The two failure shapes render DIFFERENTLY per the §5.4
/// MUST: `found:false` = transcript unresolvable on this server; `found:true` + empty `messages`
/// = a genuinely empty conversation. All transcript text is DATA — rendered as plain text, never
/// markup or commands (SPEC §10 rule 6).
public struct TranscriptView: View {
    let runtime: ServerRuntime
    let row: SessionRow

    private enum LoadState {
        case loading
        case loaded(ChatTranscriptResult)
        case failed(String)
    }

    @State private var state: LoadState = .loading

    public init(runtime: ServerRuntime, row: SessionRow) {
        self.runtime = runtime
        self.row = row
    }

    public var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView().tint(Theme.accent)
            case .failed(let message):
                ContentUnavailableView("Couldn't load transcript", systemImage: "text.bubble",
                                       description: Text(message))
            case .loaded(let result) where !result.found:
                // SPEC §5.4: found:false = UNRESOLVABLE (other machine / cleaned up) — a distinct
                // story from an empty conversation.
                ContentUnavailableView("Transcript not on this server",
                                       systemImage: "questionmark.folder",
                                       description: Text("The session's transcript lives on another machine or was cleaned up."))
            case .loaded(let result) where result.messages.isEmpty:
                // SPEC §5.4: found:true + empty messages = a REAL empty session.
                ContentUnavailableView("No conversation yet", systemImage: "text.bubble",
                                       description: Text("This session has no transcript messages."))
            case .loaded(let result):
                messageList(result.messages)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .tint(Theme.textSecondary)
            }
        }
        .task { await load() }
    }

    private func messageList(_ messages: [ChatMessage]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    MessageBubble(message: message)
                }
            }
            .padding(16)
        }
    }

    /// SPEC §5.4: args are `[sessionId?, cwd?, accountId?]`; the server ignores `nodeId` (no SSH
    /// leg), so it is not sent. Absent slots are `.omitted` → the `undef` encoding (§4.4).
    private func load() async {
        state = .loading
        let sessionId = runtime.status(for: row.nodeId)?.sessionId
        let args: [RpcArg] = [
            sessionId.map { .value(.string($0)) } ?? .omitted,
            row.cwd.map { .value(.string($0)) } ?? .omitted,
            row.accountId.map { .value(.string($0)) } ?? .omitted,
        ]
        do {
            let result = try await runtime.rpcClient.request(RpcMethod.chatReadTranscript, args)
            state = .loaded(try result.decoded(as: ChatTranscriptResult.self))
        } catch {
            // No secrets in the surfaced text (SPEC §10.2) — a generic story is enough here.
            state = .failed("The server couldn't answer. Check the connection and try again.")
        }
    }
}

/// One transcript message (SPEC §11.7): role header + parts, everything as plain text
/// (SPEC §10 rule 6 — transcript content is DATA, never rendered as markup).
private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(roleLabel)
                .font(.caption2.weight(.bold))
                .foregroundStyle(roleColor)
            ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                partView(part)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .card()
    }

    @ViewBuilder private func partView(_ part: ChatPart) -> some View {
        switch part {
        case .text(let text):
            Text(text).font(.callout).foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
        case .thinking(let text):
            Text(text).font(.caption.italic()).foregroundStyle(Theme.textTertiary)
                .textSelection(.enabled)
        case .tool(let name, _, _, let summary):
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver").font(.caption2)
                Text(toolLine(name: name, summary: summary)).font(.caption).lineLimit(2)
            }
            .foregroundStyle(Theme.textSecondary)
        case .unknown:
            EmptyView()   // tolerant: an unknown part kind renders nothing, never crashes (§11.7)
        }
    }

    private func toolLine(name: String, summary: ChatToolSummary?) -> String {
        if let path = summary?.filePath {
            let delta = [summary?.added.map { "+\($0)" }, summary?.removed.map { "−\($0)" }]
                .compactMap(\.self).joined(separator: " ")
            return delta.isEmpty ? "\(name) · \(path)" : "\(name) · \(path) (\(delta))"
        }
        return name
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "YOU"
        case .assistant: return "ASSISTANT"
        case .tool: return "TOOL"
        case .unknown(let s): return s.uppercased()
        }
    }

    private var roleColor: Color {
        switch message.role {
        case .user: return Theme.accent
        case .assistant: return Theme.running
        default: return Theme.textTertiary
        }
    }
}
