import SwiftUI
import NodetermKit

/// Add-server form (SPEC §3.6) with the optional first-run `/setup` path (SPEC §3.1). No QR (v1).
/// Errors are surfaced as plain sentences (SPEC §9.1). No subscription/quota/unlock UI (SPEC §1).
public struct AddServerView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var urlText = "https://"
    @State private var password = ""
    @State private var rememberPassword = false        // SPEC §3.6: default OFF
    @State private var insecureHTTP = false            // SPEC §2.1: localhost dev only

    /// Setup path (SPEC §3.1): when the server is unconfigured we ask for the console token.
    @State private var needsSetup = false
    @State private var setupToken = ""

    @State private var busy = false
    @State private var errorText: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Base URL (https://…)", text: $urlText)
                        .keyboardType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Allow insecure http (localhost only)", isOn: $insecureHTTP)
                        .tint(Theme.accent)
                }

                if needsSetup {
                    Section("First-run setup") {
                        Text("This server isn't configured yet. Enter the setup token printed in its console (Setup: …?token=…) and choose a password (min 8 characters).")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        TextField("Setup token", text: $setupToken)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }

                Section("Sign in") {
                    SecureField(needsSetup ? "New password (min 8)" : "Password", text: $password)
                    Toggle("Remember password (auto-relogin)", isOn: $rememberPassword)
                        .tint(Theme.accent)
                    Text("Stored only in the device Keychain, never synced.")
                        .font(.caption2).foregroundStyle(Theme.textTertiary)
                }

                if let errorText {
                    Section {
                        Text(errorText).font(.subheadline).foregroundStyle(Theme.needsYou)
                    }
                }

                // Zero-setup path (docs/DEMO-MODE.md): no account, no server needed — drives the
                // real UI offline. Enters the synthetic demo and closes this sheet.
                Section {
                    Button { env.enterDemo(); dismiss() } label: {
                        Label("Explore a demo instead", systemImage: "play.circle.fill")
                    }
                    .tint(Theme.accent)
                    Text("No account needed — see Termscape driving a live-looking workspace, fully offline.")
                        .font(.caption2).foregroundStyle(Theme.textTertiary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(needsSetup ? "Set up" : "Connect") { Task { await save() } }
                        .disabled(busy || !canSubmit)
                }
            }
            .overlay { if busy { ProgressView().tint(Theme.accent) } }
        }
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && parsedURL != nil && !password.isEmpty
            && (!needsSetup || !setupToken.isEmpty)
    }

    /// Normalize + validate the base URL (SPEC §2.1: prefer https; plain http only for localhost).
    private var parsedURL: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard var comps = URLComponents(string: trimmed), let scheme = comps.scheme?.lowercased(),
              comps.host != nil else { return nil }
        // Strip credentials/query BEFORE persisting (consort finding): a pasted
        // `https://user:pass@host` or token-bearing query would otherwise land in plaintext
        // Application Support storage (and its backups). The base URL is host+port, nothing else.
        comps.user = nil
        comps.password = nil
        comps.query = nil
        comps.fragment = nil
        guard let url = comps.url else { return nil }
        if scheme == "https" { return url }
        if scheme == "http" {
            let host = comps.host?.lowercased() ?? ""
            let isLocal = host == "localhost" || host == "127.0.0.1"
            return (insecureHTTP && isLocal) ? url : nil
        }
        return nil
    }

    private func save() async {
        guard let url = parsedURL else { errorText = "Enter a valid https:// URL."; return }
        busy = true; defer { busy = false }
        errorText = nil

        if needsSetup {
            do {
                try await env.setupServer(name: name, baseURL: url, token: setupToken,
                                          password: password, insecureHTTP: insecureHTTP)
                dismiss()
            } catch { errorText = message(for: error) }
            return
        }

        // Detect an unconfigured server first so we can offer the setup path (SPEC §3.1).
        if await env.isUnconfigured(baseURL: url) {
            needsSetup = true
            errorText = nil
            return
        }

        do {
            try await env.addServer(name: name, baseURL: url, password: password,
                                    rememberPassword: rememberPassword, insecureHTTP: insecureHTTP)
            dismiss()
        } catch { errorText = message(for: error) }
    }

    /// Plain-language mapping of every auth failure (SPEC §3.2/§3.3/§9.1).
    private func message(for error: Error) -> String {
        switch error {
        case AuthError.wrongPassword: return "Wrong password."
        case AuthError.rateLimited: return "Too many attempts. Wait a minute and try again."
        case AuthError.alreadyConfigured: return "This server is already set up — sign in instead."
        case AuthError.invalidSetup: return "Invalid setup token, or the password is under 8 characters."
        case AuthError.badRequest: return "The server rejected the request (bad request)."
        case AuthError.missingSetCookie: return "The server didn't return a session. Check the URL and try again."
        case AuthError.network: return "Couldn't reach the server. Check the URL and your connection."
        default: return "Something went wrong. Please try again."
        }
    }
}

/// Re-auth sheet for an expired session (SPEC §3.5 step 2). Only this server is affected.
public struct ReauthSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let profile: ServerProfile

    @State private var password = ""
    @State private var rememberPassword = false
    @State private var busy = false
    @State private var errorText: String?

    public init(profile: ServerProfile) { self.profile = profile }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Your session on \(profile.name) expired. Sign in again to reconnect.")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                Section("Sign in") {
                    SecureField("Password", text: $password)
                    Toggle("Remember password", isOn: $rememberPassword).tint(Theme.accent)
                }
                if let errorText {
                    Text(errorText).font(.subheadline).foregroundStyle(Theme.needsYou)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign in") { Task { await submit() } }.disabled(busy || password.isEmpty)
                }
            }
            .overlay { if busy { ProgressView().tint(Theme.accent) } }
        }
    }

    private func submit() async {
        busy = true; defer { busy = false }
        do {
            try await env.login(profile, password: password, rememberPassword: rememberPassword)
            dismiss()
        } catch AuthError.wrongPassword { errorText = "Wrong password." }
        catch AuthError.rateLimited { errorText = "Too many attempts. Wait a minute." }
        catch { errorText = "Couldn't reach the server." }
    }
}
