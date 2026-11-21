import ApplicationServices
import Speech
import SwiftUI

struct ConnectionsView: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var editor: Editor?
    @State private var supportedLocales = ["en-US"]

    private enum Editor: Identifiable {
        case provider(ProviderProfile)
        case server(ServerProfile)

        var id: UUID {
            switch self {
            case .provider(let profile): profile.id
            case .server(let profile): profile.id
            }
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Settings", selection: $store.settingsPage) {
                ForEach(SettingsPage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            switch store.settingsPage {
            case .general: general
            case .providers: providers
            case .tools: servers
            case .recording: recording
            case .personalize: PersonalizeView(store: store)
            }
        }
        .padding(21)
        .frame(width: 640, height: 540)
        .sheet(item: $editor) { item in
            switch item {
            case .provider(let profile):
                if profile.kind == .chatGPT {
                    ChatGPTConnectionView(store: store, profile: profile)
                } else { ProviderEditor(store: store, profile: profile) }
            case .server(let profile):
                ServerEditor(store: store, profile: profile)
            }
        }
    }

    private var general: some View {
        Form {
            Section("Your workspace") {
                LabeledContent("Edition", value: "Open source · Bring your own AI")
                Text("Dictation and transcripts run on your Mac. An AI provider adds answers, summaries, and coaching.")
                    .foregroundStyle(.secondary)
                Button("Configure recording and languages") { store.settingsPage = .recording }
            }
            Section("AI connection") {
                if store.document.settings.providers.isEmpty {
                    Text("No AI provider configured. You can still dictate and transcribe.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Default provider", selection: $store.providerID) {
                        ForEach(store.document.settings.providers) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    .disabled(store.runningID != nil)
                    Text("This choice is remembered for your next session.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Manage AI providers") { store.settingsPage = .providers }
            }
            Section("Your data") {
                Label("Transcripts are saved on this Mac", systemImage: "internaldrive")
                Text("AI features send relevant text to the provider you choose. Tools ask for your approval before each call. Export any session as Markdown from its menu.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Voxstead · TriHerm Labs") {
                Text("A managed subscription is planned for people who prefer built-in AI and simpler setup. It is not available in this build. No subscription is required to use this edition.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var providers: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ChatGPTConnectionView.available {
                Button("Continue with ChatGPT") {
                    editor = .provider(ProviderProfile(kind: .chatGPT, name: "ChatGPT", endpoint: ProviderKind.chatGPT.baseURL))
                }.buttonStyle(.borderedProminent).tint(.primary)
                Text("Use your eligible ChatGPT plan, or connect an API provider below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.document.settings.providers.isEmpty {
                ContentUnavailableView("Add AI when you need it", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Connect an API provider or local model for summaries, answers, and coaching. API usage is billed by your provider."))
            } else {
                List(store.document.settings.providers) { profile in
                    Button { editor = .provider(profile) } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name).fontWeight(.medium)
                                    Text(profile.model).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edit provider")
                }
                .listStyle(.inset)
            }
            Spacer(minLength: 0)
            Button { editor = .provider(ProviderProfile()) } label: {
                Label("Add provider", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var servers: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.document.settings.servers.isEmpty {
                ContentUnavailableView("Connect optional tools", systemImage: "hammer",
                                       description: Text("MCP connects the assistant to other tools. You do not need it for dictation or meeting summaries."))
            } else {
                List(store.document.settings.servers) { profile in
                    Button { editor = .server(profile) } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name).fontWeight(.medium)
                                    Text("\(profile.transport.title) · \(profile.enabled ? "Enabled" : "Disabled")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "hammer") }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edit MCP server")
                }
                .listStyle(.inset)
            }
            Spacer(minLength: 0)
            Button { editor = .server(ServerProfile()) } label: {
                Label("Add server", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var recording: some View {
        let settings = store.document.settings
        let dictationLocales = languageChoices(current: store.dictationLanguage == "auto" ? "en-US" : store.dictationLanguage)
        return Form {
            Section("Microphone") {
                MicrophonePicker(selection: Binding(
                    get: { store.document.settings.microphoneID },
                    set: { value in store.updateSettings { $0.microphoneID = value } }
                ))
                Text("Used for new meetings and dictations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Dictation") {
                Picker("Dictation language", selection: Binding(
                    get: { store.dictationLanguage },
                    set: { value in store.updateSettings { $0.dictationLocale = value } }
                )) {
                    Text("Automatic (Whisper)").tag("auto")
                        .disabled(WhisperEngine.installed == nil && store.dictationLanguage != "auto")
                    ForEach(dictationLocales, id: \.self) { locale in Text(languageName(locale)).tag(locale) }
                }
                if WhisperEngine.installed == nil {
                    Text("Automatic detection is not installed. Choose a language below to use on-device dictation.")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Developer setup") {
                        Text("Run script/setup_dictation.sh from the source project to install automatic language detection.")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Toggle("Insert dictated text at the cursor", isOn: Binding(
                    get: { settings.insertDictation == true },
                    set: { value in store.updateSettings { $0.insertDictation = value } }
                ))
                if settings.insertDictation == true {
                    Text("Insertion uses macOS Accessibility. Voxstead copies the text when the original field is unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Request Accessibility access…") {
                        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                    }
                }
                Toggle("Copy finished dictations to the clipboard", isOn: Binding(
                    get: { settings.copyDictation },
                    set: { value in store.updateSettings { $0.copyDictation = value } }
                ))
                LabeledContent("Global shortcut", value: "Hold ⌃⌥D")
                if let error = store.hotkeyError { Text(error).foregroundStyle(.red) }
            }
            Section("Meetings") {
                Picker("Meeting speech language", selection: Binding(
                    get: { settings.locale },
                    set: { value in store.updateSettings { $0.locale = value } }
                )) {
                    ForEach(languageChoices(current: settings.locale), id: \.self) { locale in
                        Text(languageName(locale)).tag(locale)
                    }
                }
                Toggle("Include Mac audio by default", isOn: Binding(
                    get: { settings.includeSystemAudio },
                    set: { value in store.updateSettings { $0.includeSystemAudio = value } }
                ))
                Toggle("Generate a debrief when the meeting ends", isOn: Binding(
                    get: { settings.autoDebrief == true },
                    set: { value in store.updateSettings { $0.autoDebrief = value } }
                ))
                Text("Automatic debriefs send transcript excerpts to the selected provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            supportedLocales = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        }
    }

    private func languageChoices(current: String) -> [String] {
        Array(Set(supportedLocales + [current])).sorted {
            languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending
        }
    }

    private func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }

}

private struct ProviderEditor: View {
    let store: WorkspaceStore
    @State var profile: ProviderProfile
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var storedEndpoint: String?
    @State private var status: String?
    @State private var test: Task<Void, Never>?
    @State private var loaded = false
    @State private var confirmingDelete = false
    @State private var browsingModels = false

    private var exists: Bool { store.document.settings.providers.contains { $0.id == profile.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(exists ? "Edit provider" : "Add provider").font(.title2.weight(.semibold))
            Form {
                Picker("Type", selection: $profile.kind) {
                    ForEach(ProviderKind.allCases.filter { $0 != .chatGPT }, id: \.self) { Text($0.title).tag($0) }
                }
                SecureField(profile.kind.requiresKey ? "API key" : "API key (optional)", text: $key)
                TextField("Model ID", text: $profile.model)
                Button("Browse available models…") { browsingModels = true }
                    .disabled(test != nil || cleanProfile.endpoint.isEmpty || (profile.kind.requiresKey && cleanKey.isEmpty))
                Text(profile.kind == .ollama ? "Use the name of a model installed in Ollama. Keep Ollama running while using AI features." : "Use a model ID available in your provider account. Your key is stored in macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Advanced") {
                    TextField("Display name", text: $profile.name)
                    TextField("API base URL", text: $profile.endpoint)
                }
            }
            .formStyle(.grouped)
            if let status { Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                if exists {
                    Button("Delete…", role: .destructive) { confirmingDelete = true }
                }
                Spacer()
                Button(test == nil ? "Test connection" : "Testing…") { check() }
                    .disabled(test != nil || cleanProfile.model.isEmpty || cleanProfile.endpoint.isEmpty || (profile.kind.requiresKey && cleanKey.isEmpty))
                    .help("Send a short test query without your transcript.")
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try store.saveProvider(cleanProfile, key: cleanKey)
                        dismiss()
                    } catch { status = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(test != nil || cleanProfile.model.isEmpty || cleanProfile.name.isEmpty || cleanProfile.endpoint.isEmpty || (profile.kind.requiresKey && cleanKey.isEmpty))
            }
        }
        .padding(22)
        .frame(width: 540, height: 500)
        .sheet(isPresented: $browsingModels) {
            ModelBrowser(profile: cleanProfile, key: cleanKey) { profile.model = $0 }
        }
        .confirmationDialog("Remove this provider and its saved key?", isPresented: $confirmingDelete) {
            Button("Remove provider", role: .destructive) {
                do { try store.removeProvider(profile.id); dismiss() }
                catch { status = error.localizedDescription }
            }
        }
        .task {
            guard !loaded else { return }
            storedEndpoint = profile.endpoint
            do { key = try Keychain.read(profile.id) }
            catch { status = error.localizedDescription }
            loaded = true
        }
        .onDisappear { test?.cancel() }
        .onChange(of: profile.kind) { _, new in
            profile.name = new.title
            profile.endpoint = new.baseURL
            profile.model = ""
            key = ""
        }
        .onChange(of: profile.endpoint) { _, value in
            if storedEndpoint != value { key = "" }
        }
    }

    private var cleanProfile: ProviderProfile {
        var result = profile
        result.name = result.name.trimmed
        result.endpoint = result.endpoint.trimmed
        result.model = result.model.trimmed
        return result
    }

    private var cleanKey: String { key.trimmed }

    private func check() {
        let client = ModelClient(profile: cleanProfile, key: cleanKey)
        status = "Testing the model…"
        test = Task {
            defer { test = nil }
            do {
                _ = try await client.reply(system: "Reply briefly.", prompt: "Reply with OK only.", tools: [])
                status = "The model responded successfully."
            } catch { status = error.localizedDescription }
        }
    }
}

private struct ModelBrowser: View {
    let profile: ProviderProfile
    let key: String
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var models: [String] = []
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?
    @State private var attempt = 0

    private var matches: [String] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.filter { term.isEmpty || $0.localizedStandardContains(term) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Choose a model").font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("From \(profile.name). Choose a chat model, then use Test connection to check compatibility.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search models", text: $query).textFieldStyle(.roundedBorder)
            if loading {
                ProgressView("Loading available models…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Could not load models", systemImage: "exclamationmark.circle").font(.headline)
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Try again") { attempt += 1 }
                    Text("You can also cancel and enter a model ID manually.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if matches.isEmpty {
                ContentUnavailableView(models.isEmpty ? "No models returned" : "No matching models", systemImage: "magnifyingglass",
                                       description: Text(models.isEmpty ? "Check that your provider has models available, or enter a model ID manually." : "Try a different search."))
            } else {
                List(matches, id: \.self) { model in
                    Button { select(model); dismiss() } label: {
                        HStack {
                            Text(model).lineLimit(2)
                            Spacer()
                            Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help(model)
                }
                .listStyle(.inset)
            }
            Text("Only your connection credentials are sent to list models. No transcript is shared.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).frame(width: 520, height: 470)
        .task(id: attempt) {
            loading = true
            error = nil
            do {
                models = try await ModelClient(profile: profile, key: key).availableModels()
            } catch {
                if !Task.isCancelled {
                    if profile.kind == .ollama, let connectionError = error as? URLError,
                       [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(connectionError.code) {
                        self.error = "Start Ollama on your Mac, then try again. If it runs elsewhere, check Advanced → API base URL."
                    } else {
                        self.error = error.localizedDescription
                    }
                }
            }
            loading = false
        }
    }
}

private struct ServerEditor: View {
    let store: WorkspaceStore
    @State var profile: ServerProfile
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var inputArguments = ""
    @State private var storedAddress: String?
    @State private var status: String?
    @State private var test: Task<Void, Never>?
    @State private var loaded = false
    @State private var confirmingDelete = false

    private var exists: Bool { store.document.settings.servers.contains { $0.id == profile.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(exists ? "Edit MCP server" : "Add MCP server").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $profile.name)
                Picker("Transport", selection: $profile.transport) {
                    ForEach(MCPTransportKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField(profile.transport == .http ? "Server URL /mcp" : "Absolute executable path",
                          text: $profile.address)
                if profile.transport == .stdio {
                    TextField("Arguments (one per line)", text: $inputArguments, axis: .vertical)
                        .lineLimit(2...5)
                    TextField("Environment variable (optional)", text: Binding(
                        get: { profile.environmentName ?? "" },
                        set: { profile.environmentName = $0 }
                    ))
                    if !(profile.environmentName ?? "").isEmpty { SecureField("Variable value", text: $token) }
                    Text("Testing or using this server runs the local executable with your permissions.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    SecureField("Bearer token (optional)", text: $token)
                }
                Toggle("Enable for the assistant", isOn: $profile.enabled)
            }
            .formStyle(.grouped)

            if let status {
                ScrollView {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 110)
            }
            HStack {
                if exists {
                    Button("Delete…", role: .destructive) { confirmingDelete = true }
                }
                Spacer()
                Button("Test connection") { check() }.disabled(test != nil)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try store.saveServer(try cleanProfile(), token: token.trimmed); dismiss() }
                    catch { status = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(test != nil)
            }
        }
        .padding(22)
        .frame(width: 550, height: 500)
        .confirmationDialog("Remove this tool connection and its saved credentials?", isPresented: $confirmingDelete) {
            Button("Remove connection", role: .destructive) {
                do { try store.removeServer(profile.id); dismiss() }
                catch { status = error.localizedDescription }
            }
        }
        .task {
            guard !loaded else { return }
            storedAddress = profile.address
            inputArguments = profile.arguments.joined(separator: "\n")
            do { token = try Keychain.read(profile.id) }
            catch { status = error.localizedDescription }
            loaded = true
        }
        .onDisappear { test?.cancel() }
        .onChange(of: profile.transport) { _, _ in
            profile.address = ""
            token = ""
        }
        .onChange(of: profile.address) { _, value in
            if storedAddress != value { token = "" }
        }
    }

    private func cleanProfile() throws -> ServerProfile {
        var result = profile
        result.name = result.name.trimmed
        result.address = result.address.trimmed
        result.arguments = inputArguments.split(separator: "\n").map(String.init)
        let variable = result.environmentName?.trimmed ?? ""
        if result.transport == .stdio, !variable.isEmpty {
            guard variable.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                throw WorkspaceError("Enter a valid environment variable name.")
            }
            result.environmentName = variable
        } else {
            result.environmentName = nil
        }
        return result
    }

    private func check() {
        do {
            let server = try cleanProfile()
            let secret = token.trimmed
            status = "Connecting to the server…"
            test = Task {
                defer { test = nil }
                do {
                    let names = try await store.testServer(server, token: secret)
                    status = names.isEmpty ? "Connected. The server lists no tools." : names.joined(separator: " · ")
                } catch { status = error.localizedDescription }
            }
        } catch { status = error.localizedDescription }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
