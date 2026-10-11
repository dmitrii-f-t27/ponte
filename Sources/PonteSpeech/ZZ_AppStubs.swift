// TEMPORARY stubs written by the app agent so PonteApp compiles before the real
// PonteSpeech lands. They implement exactly the public API from SPEC.md
// («Публичный API модулей») with fakes. The lead deletes this file on merge.
import AVFoundation
import Foundation
import PonteCore

public enum PonteSpeechError: Error {
    case translationAssetsMissing(from: Lang, to: Lang)
}

public struct SpeechVoice: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let quality: String
}

/// Fake: turns every few seconds of audio (even silence) into a canned phrase,
/// with growing volatile text first.
public final class AppleTranscriber: Transcriber {
    public let language: Lang
    private let lock = NSLock()
    private var continuation: AsyncStream<TranscriptEvent>.Continuation?
    private var seconds = 0.0
    private var phraseIndex = 0
    private var phraseID = UUID()
    private var shownWords = 0

    private static let phrases: [Lang: [String]] = [
        .ptBR: [
            "Bom dia, Dmitrii! Tudo bem com você?",
            "Vamos começar pela proposta que você enviou ontem.",
            "O prazo de entrega pode ser no fim do mês?",
            "Perfeito, então fechamos assim.",
        ],
        .ru: [
            "Добрый день! Да, всё отлично, спасибо.",
            "Я могу отправить договор сегодня вечером.",
            "Срок поставки — конец месяца, это реально.",
        ],
    ]

    public init(language: Lang) { self.language = language }

    public func prepare() async throws { try await Task.sleep(for: .milliseconds(200)) }

    public func start() throws -> AsyncStream<TranscriptEvent> {
        let (stream, continuation) = AsyncStream<TranscriptEvent>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        seconds += Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
        let phrases = Self.phrases[language] ?? []
        guard !phrases.isEmpty else { return }
        let words = phrases[phraseIndex % phrases.count].split(separator: " ")
        let phraseLength = language == .ptBR ? 4.0 : 6.5
        let wanted = min(words.count, Int(seconds / phraseLength * Double(words.count + 2)))
        if wanted > shownWords, wanted < words.count {
            shownWords = wanted
            continuation.yield(.partial(id: phraseID, text: words.prefix(wanted).joined(separator: " ")))
        }
        if seconds >= phraseLength {
            continuation.yield(.final(id: phraseID, text: words.joined(separator: " ")))
            seconds = 0
            shownWords = 0
            phraseIndex += 1
            phraseID = UUID()
        }
    }

    public func finish() async {
        lock.withLock {
            let phrases = Self.phrases[language] ?? []
            if shownWords > 0, !phrases.isEmpty {
                let words = phrases[phraseIndex % phrases.count].split(separator: " ")
                continuation?.yield(.final(id: phraseID, text: words.prefix(shownWords).joined(separator: " ")))
            }
            continuation?.finish()
            continuation = nil
            seconds = 0
            shownWords = 0
        }
    }
}

/// Fake: canned translations for the canned phrases, a marker otherwise.
public final class AppleTranslator: Translator {
    public let name = "Apple (заглушка)"
    private static let canned: [String: String] = [
        "Bom dia, Dmitrii! Tudo bem com você?": "Доброе утро, Дмитрий! Как у вас дела?",
        "Vamos começar pela proposta que você enviou ontem.": "Давайте начнём с предложения, которое вы отправили вчера.",
        "O prazo de entrega pode ser no fim do mês?": "Срок поставки может быть в конце месяца?",
        "Perfeito, então fechamos assim.": "Отлично, тогда так и договоримся.",
        "Добрый день! Да, всё отлично, спасибо.": "Boa tarde! Sim, está tudo ótimo, obrigado.",
        "Я могу отправить договор сегодня вечером.": "Posso enviar o contrato hoje à noite.",
        "Срок поставки — конец месяца, это реально.": "O prazo de entrega no fim do mês é viável.",
    ]

    public init() {}

    public func prepare(from: Lang, to: Lang) async throws {}

    public func translate(_ text: String, from: Lang, to: Lang, context: [String]) async throws -> String {
        try await Task.sleep(for: .milliseconds(150))
        return Self.canned[text] ?? "[\(to.rawValue)] \(text)"
    }
}

/// Real one returns nil without a key; the stub always does.
public final class ClaudeTranslator: Translator {
    public let name = "Claude"

    public init?(keychainItem: String = "ponte-anthropic-key", model: String = "claude-haiku-5-5") {
        return nil
    }

    public func prepare(from: Lang, to: Lang) async throws {}

    public func translate(_ text: String, from: Lang, to: Lang, context: [String]) async throws -> String {
        text
    }
}

/// Fake: silence of a plausible length instead of speech.
public final class SystemSpeechSynth: SpeechSynth {
    public let voiceIdentifiers: [Lang: String]

    public init(voiceIdentifiers: [Lang: String] = [:]) { self.voiceIdentifiers = voiceIdentifiers }

    public static func voices(for lang: Lang) -> [SpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == lang.rawValue }
            .map { SpeechVoice(id: $0.identifier, name: $0.name, quality: "\($0.quality.rawValue)") }
            .sorted { $0.name < $1.name }
    }

    public func synthesize(_ text: String, lang: Lang) async throws -> [AVAudioPCMBuffer] {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(min(Double(text.count) * 0.06, 8) * 22_050)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)) else { return [] }
        buffer.frameLength = max(frames, 1)
        return [buffer]
    }
}
