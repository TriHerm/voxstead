import AppKit
import SwiftUI

struct ChatGPTConnectionView: View {
    @Bindable var store: WorkspaceStore
    @State var profile: ProviderProfile
    @Environment(\.dismiss) private var dismiss
    @State private var credentials: ChatGPTCredentials?
    @State private var restoring = true
    @State private var models: [ChatGPTModel] = []
    @State private var work: Task<Void, Never>?
    @State private var status: String?
    @State private var loopback: ChatGPTLoopback?
    @State private var confirmDisconnect = false

    static var available: Bool { Bundle.main.object(forInfoDictionaryKey: "VoxsteadAllowsChatGPTPlan") as? Bool == true }
    private var active: Bool { credentials?.connected == true }
    private var busy: Bool { restoring || work != nil || store.runningID != nil || store.liveAutomationEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Connect your ChatGPT plan").font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Use your eligible ChatGPT plan for answers, summaries, and coaching in this local open-source edition.")
                .foregroundStyle(.secondary)
            Form {
                Section("ChatGPT connection") {
                    if restoring { ProgressView("Restoring saved connection…") }
                    if let credentials {
                        LabeledContent("Account", value: credentials.email ?? "ChatGPT account")
                        Text(active ? (credentials.planEnabled ? "ChatGPT plan usage is enabled." : "Signed in. ChatGPT plan usage is not enabled.") : "Signed out on this Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Button(active ? "Reconnect with ChatGPT" : "Continue with ChatGPT") { signIn() }
                        .buttonStyle(.borderedProminent).tint(.primary)
                        .disabled(busy || !Self.available)
                    if active && credentials?.planEnabled != true {
                        Button("Enable ChatGPT plan usage") { signIn(reconsent: true) }.disabled(busy)
                    }
                    Text("Your browser handles sign-in and permission to use your plan. Voxstead never asks for your ChatGPT password.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if active && credentials?.planEnabled == true {
                    Section("Model") {
                        Picker("Use model", selection: $profile.model) {
                            Text("Choose a model").tag("")
                            if !profile.model.isEmpty && !models.contains(where: { $0.id == profile.model }) {
                                Text(profile.model).tag(profile.model)
                            }
                            ForEach(models) { Text($0.name).tag($0.id) }
                        }.disabled(busy)
                        Button("Refresh available models") { loadModels() }.disabled(busy)
                        Button("Test connection") { testConnection() }
                            .disabled(busy || profile.model.isEmpty)
                            .help("Sends a short test using your ChatGPT plan, without any transcript.")
                    }
                }
                Section("Usage and billing") {
                    Text("AI requests use your ChatGPT allowance or applicable credits. Limits are controlled in ChatGPT. This connection does not include a Voxstead subscription.")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("Manage usage", destination: ChatGPTConnection.usageURL)
                    Text("Relevant text is sent to OpenAI when you use AI features. Your ChatGPT conversations are not imported. Voxstead will not switch to another billing source automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let status {
                Text(status).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if active { Button("Disconnect…", role: .destructive) { confirmDisconnect = true }.disabled(busy) }
                if work != nil {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { work?.cancel(); loopback?.cancel() }
                }
                Spacer()
                Button("Use this connection") {
                    store.saveChatGPTProfile(profile, select: true)
                    dismiss()
                }.buttonStyle(.borderedProminent)
                    .disabled(busy || !active || credentials?.planEnabled != true || profile.model.isEmpty)
            }
        }
        .padding(22).frame(width: 580, height: 610)
        .task {
            defer { restoring = false }
            do {
                let saved = try await ChatGPTConnection.shared.read(profile.id)
                try Task.checkCancellation()
                credentials = saved
                if active && saved?.planEnabled == true { loadModels() }
            } catch is CancellationError { }
            catch { status = "Could not read this connection from Keychain. Close and reopen this panel to try again." }
        }
        .onDisappear { work?.cancel(); loopback?.cancel() }
        .confirmationDialog("Disconnect this ChatGPT connection?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { disconnect() }
        } message: { Text("Your transcripts stay on this Mac. AI requests using this connection will stop until you reconnect.") }
    }

    private func signIn(reconsent: Bool = false) {
        status = "Continue in your browser. You can cancel here at any time."
        work = Task { @MainActor in
            let listener = ChatGPTLoopback()
            loopback = listener
            defer { listener.cancel(); loopback = nil; work = nil }
            do {
                guard Self.available else { throw WorkspaceError("ChatGPT plan sign-in is not enabled for this edition.") }
                let defaults = UserDefaults.standard
                let host = defaults.string(forKey: "chatGPTAgentHostID") ?? "urn:uuid:" + UUID().uuidString.lowercased()
                defaults.set(host, forKey: "chatGPTAgentHostID")
                let redirect = try await listener.start()
                let attempt = try ChatGPTIdentity.Attempt(redirect: redirect, clientID: credentials?.clientID, host: host)
                listener.expectedState = attempt.state
                guard NSWorkspace.shared.open(attempt.authorizationURL(reconsent: reconsent)) else {
                    throw WorkspaceError("Could not open your browser. Check your default browser and try again.")
                }
                let callback = try await listener.wait()
                NSApp.activate(ignoringOtherApps: true)
                status = "Verifying your ChatGPT connection…"
                let result = try await ChatGPTConnection.shared.exchange(attempt: attempt, callback: callback, previous: credentials)
                try Task.checkCancellation()
                try await ChatGPTConnection.shared.save(result, id: profile.id)
                credentials = result
                store.saveChatGPTProfile(profile, select: false)
                if result.planEnabled {
                    models = try await ChatGPTConnection.shared.models(profile.id)
                    if profile.model.isEmpty { profile.model = models.first?.id ?? "" }
                    status = models.isEmpty ? "Connected, but no available models were returned. Refresh later." : "Connected. Choose a model, then use this connection."
                } else { status = "Signed in without plan usage. Enable it here or keep using another provider." }
            } catch is CancellationError { status = "Operation canceled. Saved connections remain available." }
            catch { status = error.localizedDescription }
        }
    }

    private func loadModels() {
        work = Task { @MainActor in
            defer { work = nil }
            do {
                models = try await ChatGPTConnection.shared.models(profile.id)
                if profile.model.isEmpty { profile.model = models.first?.id ?? "" }
                status = models.isEmpty ? "No available models were returned. Try again later." : nil
            } catch is CancellationError { status = nil }
            catch { status = error.localizedDescription }
        }
    }

    private func testConnection() {
        status = "Sending a short test without your transcripts…"
        work = Task { @MainActor in
            defer { work = nil }
            do {
                let reply = try await ModelClient(profile: profile, key: "").reply(
                    system: "Reply briefly.", prompt: "Reply with OK only.", tools: [])
                try Task.checkCancellation()
                status = "ChatGPT responded successfully: " + String(reply.text.prefix(120))
            } catch is CancellationError { status = "Test canceled." }
            catch { status = error.localizedDescription }
        }
    }

    private func disconnect() {
        work = Task { @MainActor in
            defer { work = nil }
            do {
                let revoked = try await ChatGPTConnection.shared.disconnect(profile.id)
                credentials = try await ChatGPTConnection.shared.read(profile.id)
                models = []
                status = revoked ? "Disconnected. Your transcripts are unchanged." : "Signed out locally. Remote revocation was not confirmed; disconnect the app in ChatGPT settings as well."
            } catch { status = error.localizedDescription }
        }
    }
}

struct ChatGPTUsageLabel: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Using ChatGPT plan").font(.caption).foregroundStyle(.secondary)
            Link("Manage usage", destination: ChatGPTConnection.usageURL).font(.caption)
        }
    }
}
