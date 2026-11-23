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

    private static let byIdentifierOrName: [String: ExplanationLanguage] = {
        var result: [String: ExplanationLanguage] = [:]
        for language in all {
            for key in [language.id, language.name, language.nativeName] where result[key] == nil {
                result[key] = language
            }
        }
        return result
    }()

    static func lookup(_ value: String) -> ExplanationLanguage? {
        byIdentifierOrName[value]
    }
}
