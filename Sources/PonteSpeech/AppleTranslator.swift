import Foundation
import PonteCore
import Translation

/// On-device translation with the Translation framework.
///
/// Uses `TranslationSession(installedSource:target:)`, which works without SwiftUI but
/// cannot download language packs: `canRequestDownloads` is false and `prepareTranslation()`
/// throws `notInstalled` (checked on this Mac 2026-10-11). Packs are downloaded by the app
/// through SwiftUI `.translationTask` (the system asks the user), or by the owner in
/// System Settings → General → Language & Region → Translation Languages.
public final class AppleTranslator: Translator, @unchecked Sendable {
    public let name = "Apple (на устройстве)"

    private let lock = NSLock()
    private var sessions: [String: TranslationSession] = [:]

    public init() {}

    /// Pack status for one direction, for the setup wizard.
    public static func status(from: Lang, to: Lang) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: from.language, to: to.language)
    }

    public func prepare(from: Lang, to: Lang) async throws {
        switch SpeechRules.packResult(status: Self.availabilityCode(await Self.status(from: from, to: to))) {
        case SpeechRules.packReady:
            _ = session(from: from, to: to)
        case SpeechRules.packMissing:
            throw PonteSpeechError.translationAssetsMissing(from: from, to: to)
        default:
            throw PonteSpeechError.translationUnsupported(from: from, to: to)
        }
    }

    /// LanguageAvailability.Status → SpeechRules pack status code.
    public static func availabilityCode(_ status: LanguageAvailability.Status) -> Int {
        switch status {
        case .installed: return SpeechRules.availInstalled
        case .supported: return SpeechRules.availSupported
        case .unsupported: return SpeechRules.availUnsupported
        @unknown default: return SpeechRules.availUnknown
        }
    }

    public func translate(_ text: String, from: Lang, to: Lang, context: [String]) async throws -> String {
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return "" }
        let session = session(from: from, to: to)
        do {
            return try await session.translate(phrase).targetText
        } catch let error as TranslationError where TranslationError.notInstalled ~= error {
            throw PonteSpeechError.translationAssetsMissing(from: from, to: to)
        } catch let error as TranslationError where TranslationError.unsupportedLanguagePairing ~= error {
            throw PonteSpeechError.translationUnsupported(from: from, to: to)
        } catch {
            throw PonteSpeechError.translationFailed(error.localizedDescription)
        }
    }

    /// One cached session per direction.
    private func session(from: Lang, to: Lang) -> TranslationSession {
        lock.withLock {
            let key = "\(from.rawValue)>\(to.rawValue)"
            if let s = sessions[key] { return s }
            // Default strategy: the same one `LanguageAvailability()` reports the pack status for.
            let s = TranslationSession(installedSource: from.language, target: to.language)
            sessions[key] = s
            return s
        }
    }
}
