import AppKit
import AVFoundation
import Speech

enum PermissionState: Equatable {
    case unknown, granted, denied, notAsked

    var isGranted: Bool { self == .granted }

    /// From an AppRules.PERM_* code.
    init(code: Int32) {
        switch code {
        case AppRules.PERM_GRANTED: self = .granted
        case AppRules.PERM_DENIED: self = .denied
        case AppRules.PERM_NOT_ASKED: self = .notAsked
        default: self = .unknown
        }
    }

    var code: Int32 {
        switch self {
        case .unknown: AppRules.PERM_UNKNOWN
        case .granted: AppRules.PERM_GRANTED
        case .denied: AppRules.PERM_DENIED
        case .notAsked: AppRules.PERM_NOT_ASKED
        }
    }
}

@MainActor
enum Permissions {
    static var microphone: PermissionState {
        PermissionState(code: AppRules.permissionState(raw: AVCaptureDevice.authorizationStatus(for: .audio).rawValue))
    }

    static func requestMicrophone() async -> PermissionState {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return microphone
    }

    static var speech: PermissionState {
        PermissionState(code: AppRules.permissionState(raw: SFSpeechRecognizer.authorizationStatus().rawValue))
    }

    static func requestSpeech() async -> PermissionState {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
        return speech
    }

    static func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
