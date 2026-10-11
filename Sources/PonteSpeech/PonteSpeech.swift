// Owned by the speech agent. See SPEC.md.
//
// PonteSpeech: on-device speech recognition (SpeechAnalyzer), translation
// (Translation framework, optional Claude Messages API) and speech synthesis
// (AVSpeechSynthesizer) behind the protocols in PonteCore.
import Foundation
import PonteCore

/// Errors from PonteSpeech. `localizedDescription` is Russian: the UI shows it as is.
public enum PonteSpeechError: Error, Equatable, Sendable {
    /// The on-device recognizer does not support this language at all.
    case unsupportedLanguage(Lang)
    /// The speech model could not be downloaded or installed.
    case speechAssetsUnavailable(Lang, reason: String)
    /// `start()` was called before a successful `prepare()`.
    case transcriberNotPrepared(Lang)
    /// `start()` was called while the transcriber is already running.
    case transcriberAlreadyRunning(Lang)
    /// Incoming audio could not be converted to the recognizer format.
    case audioConversionFailed(String)
    /// The Translation language pack is not downloaded yet.
    case translationAssetsMissing(from: Lang, to: Lang)
    /// The Translation framework cannot translate this pair on this Mac.
    case translationUnsupported(from: Lang, to: Lang)
    /// The on-device translator failed for another reason.
    case translationFailed(String)
    /// A translator did not answer within `SpeechRules.translationTimeoutMs`.
    case translationTimedOut(String, ms: Int)
    /// The Claude API key is absent from the keychain.
    case cloudKeyMissing(keychainItem: String)
    /// HTTP or network failure talking to the Claude API.
    case cloudRequestFailed(status: Int, message: String)
    /// Claude declined to translate the phrase (`stop_reason: refusal`).
    case cloudRefused
    /// Claude returned no text.
    case cloudEmptyResponse
    /// No system voice is installed for the language.
    case voiceUnavailable(Lang)
    /// AVSpeechSynthesizer produced no audio or failed.
    case synthesisFailed(String)
}

extension PonteSpeechError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let lang):
            return "Распознавание речи для языка «\(lang.title)» на этом Маке не поддерживается."
        case .speechAssetsUnavailable(let lang, let reason):
            return "Не удалось скачать модель распознавания речи («\(lang.title)»). \(reason)"
        case .transcriberNotPrepared(let lang):
            return "Распознавание («\(lang.title)») не подготовлено: сначала нужно скачать модель."
        case .transcriberAlreadyRunning(let lang):
            return "Распознавание («\(lang.title)») уже запущено."
        case .audioConversionFailed(let reason):
            return "Не удалось преобразовать звук для распознавания: \(reason)"
        case .translationAssetsMissing(let from, let to):
            return "Языковой пакет перевода «\(from.title) → \(to.title)» не скачан. "
                + "Скачайте его в мастере Ponte или в Системных настройках: "
                + "Основные → Язык и регион → Языки перевода."
        case .translationUnsupported(let from, let to):
            return "Перевод «\(from.title) → \(to.title)» на этом Маке не поддерживается."
        case .translationFailed(let reason):
            return "Перевод не удался: \(reason)"
        case .translationTimedOut(let name, let ms):
            return "Переводчик «\(name)» не ответил за \(String(format: "%.1f", Double(ms) / 1000)) с."
        case .cloudKeyMissing(let item):
            return "Ключ Claude не найден в связке ключей (элемент «\(item)»)."
        case .cloudRequestFailed(let status, let message):
            if status == 0 { return "Нет связи с Claude: \(message)" }
            return "Claude вернул ошибку \(status): \(message)"
        case .cloudRefused:
            return "Claude отказался переводить эту фразу."
        case .cloudEmptyResponse:
            return "Claude вернул пустой перевод."
        case .voiceUnavailable(let lang):
            return "На Маке нет голоса для языка «\(lang.title)». "
                + "Добавьте голос: Системные настройки → Универсальный доступ → Устная речь → Системный голос."
        case .synthesisFailed(let reason):
            return "Не удалось синтезировать речь: \(reason)"
        }
    }
}
