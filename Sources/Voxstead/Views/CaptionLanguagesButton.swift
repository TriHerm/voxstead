import SwiftUI
import Translation

struct CaptionLanguagesButton: View {
    let pair: CaptionLanguagePair
    let ready: () -> Void
    @State private var configuration: TranslationSession.Configuration?
    @State private var availability: LanguageAvailability.Status?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if availability == .installed {
                Label("Translation languages ready", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if availability == .unsupported {
                Text("On-device translation is unavailable for \(pair.name).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button {
                    message = nil
                    configuration = pair.configuration
                } label: {
                    Label(configuration == nil ? "Prepare \(pair.name)" : "Preparing languages…",
                          systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
                .disabled(configuration != nil)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: pair) {
            configuration = nil
            message = nil
            let status = await pair.availability()
            if !Task.isCancelled {
                availability = status
                if status == .installed { ready() }
            }
        }
        .translationTask(configuration) { @Sendable session in
            await prepare(using: session)
        }
    }

    nonisolated private func prepare(using session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            while await !session.isReady {
                try await Task.sleep(for: .milliseconds(500))
            }
            try Task.checkCancellation()
            await MainActor.run {
                availability = .installed
                configuration = nil
                ready()
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                configuration = nil
                message = "Couldn’t prepare these languages. Try again."
            }
        }
    }
}
