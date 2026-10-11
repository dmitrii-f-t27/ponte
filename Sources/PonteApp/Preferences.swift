import AppKit
import Foundation
import PonteCore

/// UserDefaults keys. Devices are stored by UID (stable), never by AudioDeviceID.
enum PrefKey {
    static let source = "source"                    // "system" | "app:<bundleID>"
    static let micUID = "micUID"                    // "" = system default input
    static let headphonesUID = "headphonesUID"      // "" = system default output
    static let callOutputUID = "callOutputUID"      // "" = BlackHole, found automatically
    static let voicePT = "voicePT"                  // "" = best available
    static let voiceRU = "voiceRU"
    static let speakRussian = "speakRussian"
    static let translator = "translator"            // TranslatorKind
    static let glossary = "glossary"                // JSON [GlossaryTerm]
    static let outgoingMode = "outgoingMode"        // CaptureMode
    static let pttKey = "pttKey"                    // PTTKey
    static let fontSize = "fontSize"
    static let overlayVisible = "overlayVisible"
    static let setupCompleted = "setupCompleted"
}

enum TranslatorKind: String, CaseIterable, Identifiable {
    case apple, claude
    var id: String { rawValue }
    var title: String { self == .apple ? "Apple (на устройстве)" : "Claude (облако)" }
}

/// What the incoming lane listens to.
enum SourceChoice: Hashable {
    case system
    case app(bundleID: String)

    init(key: String) {
        if key.hasPrefix("app:") {
            self = .app(bundleID: String(key.dropFirst(4)))
        } else {
            self = .system
        }
    }

    var key: String {
        switch self {
        case .system: "system"
        case .app(let id): "app:\(id)"
        }
    }

    var target: CaptureTarget {
        switch self {
        case .system: .systemExceptSelf
        case .app(let id): .app(bundleID: id)
        }
    }
}

extension CaptureMode {
    var title: String { self == .continuous ? "Авто" : "Push-to-talk" }
}

/// The push-to-talk key. Right-hand modifiers are told apart by device-dependent flags.
enum PTTKey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightShift, rightControl, function
    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: "Правый Option ⌥"
        case .rightCommand: "Правый Command ⌘"
        case .rightShift: "Правый Shift ⇧"
        case .rightControl: "Правый Control ⌃"
        case .function: "Fn 🌐"
        }
    }

    var short: String {
        switch self {
        case .rightOption: "правый ⌥"
        case .rightCommand: "правый ⌘"
        case .rightShift: "правый ⇧"
        case .rightControl: "правый ⌃"
        case .function: "Fn"
        }
    }

    var ruleCode: Int32 {
        switch self {
        case .rightOption: AppRules.PTT_RIGHT_OPTION
        case .rightCommand: AppRules.PTT_RIGHT_COMMAND
        case .rightShift: AppRules.PTT_RIGHT_SHIFT
        case .rightControl: AppRules.PTT_RIGHT_CONTROL
        case .function: AppRules.PTT_FN
        }
    }
}

extension TranslatorKind {
    var ruleCode: Int32 { self == .claude ? AppRules.TR_CLAUDE : AppRules.TR_APPLE }
}

extension AudioDevice {
    /// The Mac's own speakers: the mic would hear the other side (AppRules.isBuiltInSpeaker).
    var isBuiltInSpeaker: Bool {
        AppRules.isBuiltInSpeaker(uidLower: Array(uid.lowercased().utf8), nameLower: Array(name.lowercased().utf8))
    }
}
