import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PersonalizeView: View {
    let store: WorkspaceStore
    @State private var vocabulary = ""
    @State private var selectedPersona: WritingPersona?
    @State private var selectedPrompt: QuickPrompt?

    var body: some View {
        Form {
            Section("Dictation output") {
                ExplanationLanguagePicker(selection: Binding(
                    get: { store.document.settings.translationLanguage ?? "" },
                    set: { value in store.updateSettings { $0.translationLanguage = value } }
                ), label: "Translate into", allowsOriginal: true)
                Text("Translation and writing styles send dictated text to the selected provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speech dictionary") {
                TextField("One name or term per line", text: $vocabulary, axis: .vertical)
                .onChange(of: vocabulary) { _, value in store.updateSpeechVocabulary(value) }
                .lineLimit(4...8)
                Text("Applies to Apple on-device speech recognition. Use it for names and technical terms.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Writing styles by app") {
                ForEach(store.document.settings.personas ?? []) { persona in
                    Button(persona.bundleID) { selectedPersona = persona }
                }
                Button("Add writing style…") { selectedPersona = WritingPersona() }
            }
            Section("Quick prompts for live meetings") {
                ForEach(store.quickPrompts) { prompt in
                    Button(prompt.label) { selectedPrompt = prompt }
                }
                Button("Add quick prompt…") { selectedPrompt = QuickPrompt(label: "", instruction: "") }
            }
        }
        .formStyle(.grouped)
        .onAppear { vocabulary = (store.document.settings.speechVocabulary ?? []).joined(separator: "\n") }
        .sheet(item: $selectedPersona) { persona in
            PersonaEditor(store: store, persona: persona)
        }
        .sheet(item: $selectedPrompt) { prompt in
            QuickPromptEditor(store: store, prompt: prompt)
        }
    }
}

private struct PersonaEditor: View {
    let store: WorkspaceStore
    @State var persona: WritingPersona
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Writing style").font(.title2.weight(.semibold))
            Form {
                TextField("App bundle identifier", text: $persona.bundleID)
                Button("Choose app…") { chooseApp() }
                TextField("Writing instructions", text: $persona.instructions, axis: .vertical)
                    .lineLimit(3...7)
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if store.document.settings.personas?.contains(where: { $0.id == persona.id }) == true {
                    Button("Delete", role: .destructive) {
                        store.updateSettings { $0.personas?.removeAll { $0.id == persona.id } }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(persona.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || persona.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 490)
    }

    private func chooseApp() {
        let picker = NSOpenPanel()
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.allowedContentTypes = [.applicationBundle]
        picker.treatsFilePackagesAsDirectories = false
        picker.begin { result in
            guard result == .OK, let url = picker.url else { return }
            if let id = Bundle(url: url)?.bundleIdentifier {
                persona.bundleID = id
                error = nil
            } else {
                error = "This app has no bundle identifier."
            }
        }
    }

    private func save() {
        var personas = store.document.settings.personas ?? []
        persona.bundleID = persona.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !personas.contains(where: { $0.id != persona.id && $0.bundleID == persona.bundleID }) else {
            error = "A writing style already exists for this app."
            return
        }
        if let index = personas.firstIndex(where: { $0.id == persona.id }) {
            personas[index] = persona
        } else { personas.append(persona) }
        store.updateSettings { $0.personas = personas }
        dismiss()
    }
}

private struct QuickPromptEditor: View {
    let store: WorkspaceStore
    @State var prompt: QuickPrompt
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick prompt").font(.title2.weight(.semibold))
            Form {
                TextField("Button label", text: $prompt.label)
                TextField("Prompt", text: $prompt.instruction, axis: .vertical).lineLimit(3...7)
            }
            .formStyle(.grouped)
            HStack {
                if store.quickPrompts.contains(where: { $0.id == prompt.id }) {
                    Button("Delete", role: .destructive) {
                        let prompts = store.quickPrompts.filter { $0.id != prompt.id }
                        store.updateSettings { $0.prompts = prompts }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var prompts = store.quickPrompts
                    if let index = prompts.firstIndex(where: { $0.id == prompt.id }) {
                        prompts[index] = prompt
                    } else { prompts.append(prompt) }
                    store.updateSettings { $0.prompts = prompts }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || prompt.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 490)
    }
}
