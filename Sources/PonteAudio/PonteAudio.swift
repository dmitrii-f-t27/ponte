// Owned by the audio agent. See SPEC.md.
//
// PonteAudio: everything that touches Core Audio / AVAudioEngine.
//   CoreAudioDeviceCatalog   – HAL devices, default input/output
//   RunningAudioAppCatalog   – apps that are HAL clients (helpers grouped under their app)
//   AppAudioTapSource        – Core Audio process tap of one app or of all audio except Ponte
//   MicSource                – microphone of a chosen input device
//   FileSource               – audio file in ~100 ms chunks (tests, demo)
//   DeviceAudioPlayer        – plays PCM to one fixed output device (headphones, BlackHole 2ch)
//   BlackHoleCheck           – finds the BlackHole virtual mic
// All sources deliver mono Float32 (deinterleaved) buffers at the native sample rate.
import Foundation
import PonteCore

public enum PonteAudioError: Error, CustomStringConvertible {
    /// A Core Audio call failed. `status` is the OSStatus (often a four-char code).
    case coreAudio(status: OSStatus, what: String)
    /// The device chosen for capture/playback no longer exists.
    case deviceNotFound(String)
    /// The audio format cannot be handled (for example, a non-float tap format).
    case unsupportedFormat(String)
    /// `start` was called twice without `stop`.
    case alreadyRunning
    case engine(String)
    /// The user has not answered the permission prompt yet (request it first).
    case permissionRequired(AudioPermission)
    /// The user refused the permission; it can only be enabled in System Settings.
    case permissionDenied(AudioPermission)

    public var description: String {
        switch self {
        case let .coreAudio(status, what):
            return "Core Audio error \(status) ('\(HAL.fourCC(UInt32(bitPattern: status)))') in \(what)"
        case let .deviceNotFound(name): return "Audio device not found: \(name)"
        case let .unsupportedFormat(what): return "Unsupported audio format: \(what)"
        case .alreadyRunning: return "Audio source is already running"
        case let .engine(what): return "Audio engine error: \(what)"
        case let .permissionRequired(p): return "\(p.title) permission not granted yet: request it first. \(p.settingsPath)"
        case let .permissionDenied(p): return "\(p.title) permission denied. Enable it in \(p.settingsPath)"
        }
    }
}

public enum AudioPermission: String, Sendable {
    /// kTCCServiceMicrophone: MicSource.
    case microphone
    /// kTCCServiceAudioCapture: AppAudioTapSource (process taps). Without it taps deliver silence.
    case systemAudioRecording

    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudioRecording: return "System Audio Recording"
        }
    }

    public var settingsPath: String {
        switch self {
        case .microphone:
            return "System Settings → Privacy & Security → Microphone"
        case .systemAudioRecording:
            return "System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only"
        }
    }

    /// Deep link that opens the matching System Settings pane.
    public var settingsURL: URL {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .systemAudioRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}
