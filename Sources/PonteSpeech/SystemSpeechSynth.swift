import AVFoundation
import Foundation
import PonteCore

/// A system voice the settings screen can offer.
public struct SpeechVoice: Hashable, Identifiable, Sendable {
    public enum Quality: Int, Comparable, Sendable, CaseIterable {
        case compact = 1
        case enhanced = 2
        case premium = 3

        public static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }

        public var title: String {
            switch self {
            case .compact: return "компактный"
            case .enhanced: return "улучшенный"
            case .premium: return "премиум"
            }
        }
    }

    public let id: String          // AVSpeechSynthesisVoice.identifier
    public let name: String
    public let quality: Quality
    public let language: String    // BCP-47, e.g. "pt-BR"

    public init(id: String, name: String, quality: Quality, language: String) {
        self.id = id
        self.name = name
        self.quality = quality
        self.language = language
    }

    /// Novelty voices (Eddy, Flo, Reed…: `com.apple.eloquence.*`) rank lower (`SpeechRules.isNoveltyVoice`).
    public var isNovelty: Bool { SpeechRules.isNoveltyVoice(identifierUTF8: Array(id.utf8)) }
}

/// Orders voices with `SpeechRules.voiceRankKey`: best quality first, then regular before novelty
/// voices, then the preferred name for the language (Luciana for pt-BR, Milena for ru);
/// ties by name, then identifier.
public enum VoiceRanking {
    public static func preferredNames(for lang: Lang) -> [String] {
        switch lang {
        case .ptBR: return ["Luciana", "Felipe", "Fernanda"]
        case .ru: return ["Milena", "Yuri", "Katya"]
        }
    }

    public static func rank(_ voices: [SpeechVoice], preferredNames: [String]) -> [SpeechVoice] {
        func key(_ v: SpeechVoice) -> Int {
            let index = preferredNames.firstIndex { v.name.localizedCaseInsensitiveContains($0) } ?? -1
            return SpeechRules.voiceRankKey(qualityCode: v.quality.rawValue, isNovelty: v.isNovelty, preferredIndex: index)
        }
        return voices.map { ($0, key($0)) }.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.name != b.0.name { return a.0.name < b.0.name }
            return a.0.id < b.0.id
        }.map(\.0)
    }
}

/// Speech synthesis with AVSpeechSynthesizer rendered to PCM (`write(_:toBufferCallback:)`), not played.
public final class SystemSpeechSynth: SpeechSynth, @unchecked Sendable {
    /// Lang → AVSpeechSynthesisVoice.identifier chosen in settings. Missing → best installed voice.
    public var voiceIdentifiers: [Lang: String]
    /// AVSpeechUtterance rate (0...1, default 0.5). Nil keeps the system default.
    public var rate: Float?

    private let lock = NSLock()
    private var active: [UUID: Render] = [:]

    public init(voiceIdentifiers: [Lang: String] = [:]) {
        self.voiceIdentifiers = voiceIdentifiers
    }

    /// Installed voices for the language, best first.
    public static func voices(for lang: Lang) -> [SpeechVoice] {
        let code = lang.rawValue.lowercased()
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().replacingOccurrences(of: "_", with: "-") == code }
            .map { v in
                SpeechVoice(id: v.identifier, name: v.name, quality: Self.quality(v.quality), language: v.language)
            }
        return VoiceRanking.rank(voices, preferredNames: VoiceRanking.preferredNames(for: lang))
    }

    static func quality(_ q: AVSpeechSynthesisVoiceQuality) -> SpeechVoice.Quality {
        SpeechVoice.Quality(rawValue: SpeechRules.voiceQualityCode(avQualityRaw: q.rawValue)) ?? .compact
    }

    /// The voice `synthesize` uses for the language.
    public func voice(for lang: Lang) -> AVSpeechSynthesisVoice? {
        if let id = voiceIdentifiers[lang], let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        if let best = Self.voices(for: lang).first, let v = AVSpeechSynthesisVoice(identifier: best.id) { return v }
        return AVSpeechSynthesisVoice(language: lang.rawValue)
    }

    /// One Float32 mono buffer at the voice's native sample rate (22 050 Hz for the compact voices).
    public func synthesize(_ text: String, lang: Lang) async throws -> [AVAudioPCMBuffer] {
        try await synthesize(text, lang: lang, ratePercent: 100)
    }

    /// Same at `ratePercent` of the normal speed (`SpeechRules.utteranceRateMilli`), on top of `rate`.
    public func synthesize(_ text: String, lang: Lang, ratePercent: Int32) async throws -> [AVAudioPCMBuffer] {
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return [] }
        guard let voice = voice(for: lang) else { throw PonteSpeechError.voiceUnavailable(lang) }

        let utterance = AVSpeechUtterance(string: phrase)
        utterance.voice = voice
        if rate != nil || ratePercent != 100 {
            let base = rate.map { Int(($0 * 1000).rounded()) } ?? SpeechRules.defaultUtteranceRateMilli
            let milli = SpeechRules.utteranceRateMilli(ratePercent: Int(ratePercent), baseRateMilli: base)
            utterance.rate = Float(milli) / 1000
        }

        let timeoutMs = SpeechRules.synthesisTimeoutMs(textBytes: phrase.utf8.count)
        let raw = try await render(utterance, timeout: Double(timeoutMs) / 1000)
        guard let mono = try AudioConversion.float32Mono(raw) else {
            throw PonteSpeechError.synthesisFailed("синтезатор не вернул звук")
        }
        return [mono]
    }

    /// Splits a long phrase into pieces of at most `SpeechRules.speechChunkMaxBytes` at sentence,
    /// clause or word boundaries (`SpeechRules.cutByteIndex`), so the first piece can be synthesized
    /// and played sooner.
    public static func chunks(_ text: String, maxBytes: Int = SpeechRules.speechChunkMaxBytes) -> [String] {
        var rest = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        var pieces: [String] = []
        while !rest.isEmpty {
            let cut = SpeechRules.cutByteIndex(utf8: rest, maxBytes: maxBytes, minBytes: SpeechRules.speechChunkMinBytes)
            let head = String(decoding: rest[0..<cut], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty { pieces.append(head) }
            rest = Array(rest[cut...])
            while let first = rest.first, SpeechRules.isSpace(first) { rest.removeFirst() }
        }
        return pieces
    }

    // MARK: - Rendering

    /// Keeps the synthesizer and its delegate alive until the last buffer arrives.
    private final class Render: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        let synthesizer = AVSpeechSynthesizer()
        private let lock = NSLock()
        private var buffers: [AVAudioPCMBuffer] = []
        private var continuation: CheckedContinuation<[AVAudioPCMBuffer], Error>?
        private var done = false

        func start(_ utterance: AVSpeechUtterance, continuation: CheckedContinuation<[AVAudioPCMBuffer], Error>) {
            lock.withLock { self.continuation = continuation }
            synthesizer.delegate = self
            synthesizer.write(utterance) { [self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    complete(nil)   // an empty buffer marks the end
                } else if let copy = AudioConversion.copy(pcm) {
                    lock.withLock { if !done { buffers.append(copy) } }
                }
            }
        }

        func complete(_ error: Error?) {
            let (continuation, buffers): (CheckedContinuation<[AVAudioPCMBuffer], Error>?, [AVAudioPCMBuffer]) = lock.withLock {
                guard !done else { return (nil, []) }
                done = true
                let c = self.continuation
                self.continuation = nil
                return (c, self.buffers)
            }
            guard let continuation else { return }
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: buffers)
            }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            // Buffers are delivered before didFinish; give a late callback a moment anyway.
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(SpeechRules.synthesisEndGraceMs)) { [self] in
                complete(nil)
            }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            complete(PonteSpeechError.synthesisFailed("синтез отменён"))
        }
    }

    private func render(_ utterance: AVSpeechUtterance, timeout: TimeInterval) async throws -> [AVAudioPCMBuffer] {
        let id = UUID()
        let job = Render()
        lock.withLock { active[id] = job }
        defer { lock.withLock { active[id] = nil } }
        return try await withCheckedThrowingContinuation { continuation in
            job.start(utterance, continuation: continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak job] in
                job?.complete(PonteSpeechError.synthesisFailed("истекло время ожидания (\(Int(timeout)) с)"))
            }
        }
    }
}
