import Foundation

/// Language choices for model output, separate from installed speech-recognition locales.
struct ExplanationLanguage: Identifiable, Sendable {
    let id: String
    let name: String
    let nativeName: String
    var title: String { name == nativeName ? name : "\(name) · \(nativeName)" }

    static let all: [ExplanationLanguage] = {
        let english = Locale(identifier: "en")
        return Locale.LanguageCode.isoLanguageCodes.compactMap { code in
            let id = code.identifier
            guard let name = english.localizedString(forLanguageCode: id), name != id,
                  !["und", "mul", "zxx", "mis"].contains(id) else { return nil }
            return ExplanationLanguage(id: id, name: name,
                nativeName: Locale(identifier: id).localizedString(forLanguageCode: id) ?? name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    static func matching(_ query: String) -> [ExplanationLanguage] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? all : all.filter {
            $0.title.localizedStandardContains(query) || $0.id.localizedStandardContains(query)
        }
    }

    static func lookup(_ value: String) -> ExplanationLanguage? {
        all.first { $0.id == value || $0.name == value || $0.nativeName == value }
    }
}
