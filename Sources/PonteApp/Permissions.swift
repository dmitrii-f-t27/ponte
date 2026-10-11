import AppKit
import AVFoundation
import Speech

enum PermissionState: Equatable {
    case unknown, granted, denied, notAsked

    var isGranted: Bool { self == .granted }
}

@MainActor
enum Permissions {
    static var microphone: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notAsked
        @unknown default: .unknown
        }
    }

    static func requestMicrophone() async -> PermissionState {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return microphone
    }

    static var speech: PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notAsked
        @unknown default: .unknown
        }
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
