import AVFoundation
import Foundation
import PonteSpecs

// Shared contracts between PonteAudio, PonteSpeech and PonteApp.
// Changes are additive: new requirements come with a default implementation in a
// protocol extension, so existing conformances keep compiling.

public enum Lang: String, Sendable, CaseIterable, Codable {
    case ru = "ru-RU"
    case ptBR = "pt-BR"

    public var locale: Locale { Locale(identifier: rawValue) }
    public var language: Locale.Language { Locale.Language(identifier: rawValue) }
    public var title: String { self == .ru ? "Русский" : "Português (Brasil)" }

    /// The spec's language code (LN_LANG_*, lane_rules.t27), and the language of a code.
    public var specCode: Int32 {
        switch self {
        case .ptBR: return LN_LANG_PT_BR
        case .ru: return LN_LANG_RU
        }
    }

    public init(specCode: Int32) { self = specCode == LN_LANG_PT_BR ? .ptBR : .ru }
}

/// incoming: call participants (pt-BR) → me (ru). outgoing: me (ru) → call (pt-BR).
/// Which language each direction hears and gives is lane_rules.t27's (ln_dir_source, ln_dir_target).
public enum Direction: String, Sendable, CaseIterable, Codable {
    case incoming
    case outgoing

    /// The spec's direction code (LN_DIR_*).
    public var specCode: Int32 {
        switch self {
        case .incoming: return LN_DIR_INCOMING
        case .outgoing: return LN_DIR_OUTGOING
        }
    }

    public var source: Lang { Lang(specCode: ln_dir_source(specCode)) }
    public var target: Lang { Lang(specCode: ln_dir_target(specCode)) }
}

// MARK: - Audio

/// Called on a real-time or capture thread. Copy the buffer if you keep it.
public typealias PCMHandler = (AVAudioPCMBuffer, AVAudioTime?) -> Void

public struct AudioDevice: Hashable, Identifiable, Sendable {
    public let id: UInt32          // AudioDeviceID
    public let uid: String         // stable across reboots, use for persistence
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int

    public init(id: UInt32, uid: String, name: String, inputChannels: Int, outputChannels: Int) {
        self.id = id
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
    }

}

public protocol AudioDeviceCatalog: AnyObject {
    func devices() -> [AudioDevice]
    func defaultInput() -> AudioDevice?
    func defaultOutput() -> AudioDevice?
}

/// What to listen to on the incoming side.
public enum CaptureTarget: Hashable, Sendable, Codable {
    /// Every process of the app (browsers play audio from helper processes).
    case app(bundleID: String)
    /// All system output except Ponte itself.
    case systemExceptSelf
}

/// A running app that can be captured.
public struct AudioApp: Hashable, Identifiable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let pids: [Int32]
    public let isPlayingAudio: Bool
    public let isKnownCallApp: Bool

    public init(bundleID: String, name: String, pids: [Int32], isPlayingAudio: Bool, isKnownCallApp: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.pids = pids
        self.isPlayingAudio = isPlayingAudio
        self.isKnownCallApp = isKnownCallApp
    }

}

public protocol AudioAppCatalog: AnyObject {
    /// Running apps with audio processes; call apps and currently playing apps first.
    func apps() -> [AudioApp]
}

/// Anything that produces mono Float32 PCM: app process tap, microphone, test file.
public protocol AudioSource: AnyObject {
    var outputFormat: AVAudioFormat { get }
    func start(handler: @escaping PCMHandler) throws
    func stop()
}

/// Plays PCM to one fixed output device (headphones, or BlackHole as the call mic).
public protocol AudioPlayer: AnyObject {
    var device: AudioDevice? { get }
    /// Enqueues the buffer and returns when it has finished playing.
    func play(_ buffer: AVAudioPCMBuffer) async
    /// Enqueues the buffers back to back (gapless) and returns when the last one has finished
    /// playing, or right away after `stopAll()`. Any sample rate and channel count.
    func play(_ buffers: [AVAudioPCMBuffer]) async
    /// Drops everything queued or playing; pending `play` calls return.
    func stopAll()
    /// Starts the output now and keeps it running between phrases (otherwise the first `play` starts it).
    /// Throws the reason the device cannot be used.
    func prepare() throws
    /// Live audio («Свой голос»): schedules the buffers right after what the output holds, without waiting for
    /// them and without playing them again after a device change. Returns the milliseconds the output still
    /// has to play afterwards, or nil when it is not running (the buffers are dropped).
    func stream(_ buffers: [AVAudioPCMBuffer]) -> Double?
    /// Milliseconds of live audio the output still has to play; nil when it is not running.
    func streamQueuedMs() -> Double?
}

extension AudioPlayer {
    /// Default: one buffer after another. Players that can schedule ahead override this.
    public func play(_ buffers: [AVAudioPCMBuffer]) async {
        for buffer in buffers { await play(buffer) }
    }

    /// Default: nothing to start ahead.
    public func prepare() throws {}

    /// Default: no live audio.
    public func stream(_ buffers: [AVAudioPCMBuffer]) -> Double? { nil }
    public func streamQueuedMs() -> Double? { nil }
}

// MARK: - Speech

public enum TranscriptEvent: Sendable {
    /// Volatile text for the current phrase; may still change.
    case partial(id: UUID, text: String)
    /// Stable phrase; the pipeline translates only these.
    ///
    /// A final with empty text means "discard this phrase": the recognizer showed volatile
    /// text for it but then decided it was noise. Remove its volatile line and do not
    /// translate it. Every `.partial` is eventually closed by a `.final` with the same id.
    case final(id: UUID, text: String)
}

/// Timing of one final phrase, for latency (end of phrase → translation on screen).
public struct PhraseTiming: Equatable, Sendable {
    /// Audio time of the first word, seconds from the start of the stream.
    public let audioStart: TimeInterval
    /// Audio time where the voice of the last word ended.
    public let audioEnd: TimeInterval
    /// Wall clock time when the audio at `audioEnd` reached `append(_:)`: the moment the
    /// speaker finished, as seen by Ponte.
    public let audioEndArrivedAt: Date
    /// Wall clock time when the final was emitted.
    public let finalizedAt: Date
    /// True when the transcriber cut the phrase itself (end-of-phrase pause or a cut inside
    /// a long monologue) instead of waiting for the recognizer.
    public let forced: Bool

    public init(audioStart: TimeInterval, audioEnd: TimeInterval, audioEndArrivedAt: Date,
                finalizedAt: Date, forced: Bool) {
        self.audioStart = audioStart
        self.audioEnd = audioEnd
        self.audioEndArrivedAt = audioEndArrivedAt
        self.finalizedAt = finalizedAt
        self.forced = forced
    }

    /// End of phrase audio → final text.
    public var recognitionLatency: TimeInterval { finalizedAt.timeIntervalSince(audioEndArrivedAt) }
}

public protocol Transcriber: AnyObject {
    var language: Lang { get }
    /// Installs on-device models if needed. Safe to call repeatedly.
    func prepare() async throws
    func start() throws -> AsyncStream<TranscriptEvent>
    /// Any sample rate / channel count; the transcriber converts.
    func append(_ buffer: AVAudioPCMBuffer)
    /// Flushes pending audio and finishes the stream.
    func finish() async
    /// Timing of a phrase already emitted as `.final` (non-empty text); nil if unknown.
    /// Available by the time the `.final` event is delivered.
    func timing(for id: UUID) -> PhraseTiming?
    /// What the lane's watchdog reads (lane_rules ln_session_stalled).
    func health() -> TranscriberHealth
    /// Drops the session without waiting for it: a stalled recognizer may never finish its input.
    func cancel() async
}

/// The running session as the lane sees it.
public struct TranscriberHealth: Sendable, Equatable {
    /// Seconds of voice (the level meter's) given to the session since its last result, or since it started.
    public var voiceSinceResult: Double
    /// Why the session stopped early, if it did.
    public var error: String?

    public init(voiceSinceResult: Double = 0, error: String? = nil) {
        self.voiceSinceResult = voiceSinceResult
        self.error = error
    }
}

extension Transcriber {
    public func timing(for id: UUID) -> PhraseTiming? { nil }
    public func health() -> TranscriberHealth { TranscriberHealth() }
    public func cancel() async { await finish() }
}

public protocol Translator: AnyObject {
    var name: String { get }
    func prepare(from: Lang, to: Lang) async throws
    /// `context` holds the last few phrases of the conversation, oldest first.
    func translate(_ text: String, from: Lang, to: Lang, context: [String]) async throws -> String
}

public protocol SpeechSynth: AnyObject {
    /// Renders speech to PCM without playing it.
    func synthesize(_ text: String, lang: Lang) async throws -> [AVAudioPCMBuffer]
    /// Same, at `ratePercent` of the normal speaking speed (100 = normal, 130 = 30 % faster).
    /// Used to catch up when translated phrases pile up.
    func synthesize(_ text: String, lang: Lang, ratePercent: Int32) async throws -> [AVAudioPCMBuffer]
}

extension SpeechSynth {
    /// Default: the rate is ignored.
    public func synthesize(_ text: String, lang: Lang, ratePercent: Int32) async throws -> [AVAudioPCMBuffer] {
        try await synthesize(text, lang: lang)
    }
}

/// One line of the call log shown in the UI and exported after the call.
public struct ConversationLine: Identifiable, Sendable, Codable {
    public let id: UUID
    public let direction: Direction
    public let at: Date
    public var original: String
    public var translation: String?
    public var latency: TimeInterval?   // end of phrase → translation ready
    /// Why `translation` is missing (shown instead of "translating…"); nil while pending or done.
    public var translationError: String?

    public init(id: UUID = UUID(), direction: Direction, at: Date = Date(), original: String,
                translation: String? = nil, latency: TimeInterval? = nil, translationError: String? = nil) {
        self.id = id
        self.direction = direction
        self.at = at
        self.original = original
        self.translation = translation
        self.latency = latency
        self.translationError = translationError
    }
}
