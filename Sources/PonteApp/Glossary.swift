import Foundation
import PonteCore

// Pure logic, also compiled into PonteTests (see Tests/PonteTests/AppLogic).

/// A name or term with its fixed form in both languages.
struct GlossaryTerm: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var pt: String
    var ru: String

    init(id: UUID = UUID(), pt: String, ru: String) {
        self.id = id
        self.pt = pt
        self.ru = ru
    }

    var isComplete: Bool {
        !pt.trimmingCharacters(in: .whitespaces).isEmpty && !ru.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Translators often pass names and jargon through untranslated. Where the
    /// source-language form of a term survives in the translation as a whole word,
    /// replace it with the fixed target-language form.
    static func apply(_ terms: [GlossaryTerm], to translation: String, direction: Direction) -> String {
        var result = translation
        for term in terms where term.isComplete {
            let from = (direction == .incoming ? term.pt : term.ru).trimmingCharacters(in: .whitespaces)
            let to = (direction == .incoming ? term.ru : term.pt).trimmingCharacters(in: .whitespaces)
            guard from.caseInsensitiveCompare(to) != .orderedSame else { continue }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: from) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range,
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: to))
        }
        return result
    }

    static func decode(_ json: String) -> [GlossaryTerm] {
        guard let data = json.data(using: .utf8),
              let terms = try? JSONDecoder().decode([GlossaryTerm].self, from: data) else { return [] }
        return terms
    }

    static func encode(_ terms: [GlossaryTerm]) -> String {
        guard let data = try? JSONEncoder().encode(terms) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
