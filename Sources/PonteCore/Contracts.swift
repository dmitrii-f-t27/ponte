import AVFoundation
import Foundation

// Shared contracts between PonteAudio, PonteSpeech and PonteApp.
// Changing a signature here breaks the other agents: propose changes in the
// final report instead of editing this file.

public enum Lang: String, Sendable, CaseIterable, Codable {
    case ru = "ru-RU"
    case ptBR = "pt-BR"

    public var locale: Locale { Locale(identifier: rawValue) }
    public var language: Locale.Language { Locale.Language(identifier: rawValue) }
    public var title: String { self == .ru ? "Русский" : "Português (Brasil)" }
}

/// incoming: call participants (pt-BR) → me (ru). outgoing: me (ru) → call (pt-BR).
public enum Direction: String, Sendable, CaseIterable, Codable {
    case incoming
    case outgoing

    public var source: Lang { self == .incoming ? .ptBR : .ru }
    public var target: Lang { self == .incoming ? .ru : .ptBR }
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

    public var isVirtualMic: Bool { name.localizedCaseInsensitiveContains("BlackHole") }
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

    public static let knownCallApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.google.Chrome": "Chrome (Meet)",
        "com.apple.Safari": "Safari (Meet)",
        "ru.keepcoder.Telegram": "Telegram",
        "org.telegram.desktop": "Telegram Desktop",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.apple.FaceTime": "FaceTime",
        "com.microsoft.teams2": "Teams",
    ]
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
    func stopAll()
}

// MARK: - Speech

public enum TranscriptEvent: Sendable {
    /// Volatile text for the current phrase; may still change.
    case partial(id: UUID, text: String)
    /// Stable phrase; the pipeline translates only these.
    case final(id: UUID, text: String)
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
}

/// One line of the call log shown in the UI and exported after the call.
public struct ConversationLine: Identifiable, Sendable, Codable {
    public let id: UUID
    public let direction: Direction
    public let at: Date
    public var original: String
    public var translation: String?
    public var latency: TimeInterval?   // end of phrase → translation ready

    public init(id: UUID = UUID(), direction: Direction, at: Date = Date(), original: String,
                translation: String? = nil, latency: TimeInterval? = nil) {
        self.id = id
        self.direction = direction
        self.at = at
        self.original = original
        self.translation = translation
        self.latency = latency
    }
}
