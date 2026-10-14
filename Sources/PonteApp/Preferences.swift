import AppKit
import Foundation
import PonteCore

/// UserDefaults keys. Devices are stored by UID (stable), never by AudioDeviceID.
enum PrefKey {
    static let source = "source"                    // "system" | "app:<bundleID>"
    static let micUID = "micUID"                    // "" = automatic (AudioRules.pickAutoMicIndex)
    static let micAutoMigrated = "micAutoMigrated"  // the one-time move of a stored mic to automatic is done
    static let headphonesUID = "headphonesUID"      // "" = system default output
    static let callOutputUID = "callOutputUID"      // "" = BlackHole, found automatically
    static let voicePT = "voicePT"                  // "" = best available
    static let voiceRU = "voiceRU"
    static let speakRussian = "speakRussian"
    static let hearOriginal = "hearOriginal"        // the other side's own voices on the Mac («Слышать их»)
    static let translator = "translator"            // TranslatorKind
    static let glossary = "glossary"                // JSON [GlossaryTerm]
    static let outgoingMode = "outgoingMode"        // CaptureMode
    static let pttKey = "pttKey"                    // PTTKey
    static let fontSize = "fontSize"
    static let overlayVisible = "overlayVisible"
    static let setupCompleted = "setupCompleted"
    static let checklistOnLaunch = "checklistOnLaunch"  // «Перед звонком» opens at launch
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

    /// A stored key "app:<bundleID>" (AppRules.sourceKeyAppPrefix); anything else is all Mac audio.
    /// Bundle IDs are ASCII (reverse DNS).
    init(key: String) {
        let utf8 = Array(key.utf8)
        let prefix = AppRules.sourceKeyAppPrefix(utf8: utf8)
        if prefix >= 0 {
            self = .app(bundleID: String(decoding: utf8[prefix...], as: UTF8.self))
        } else {
            self = .system
        }
    }

    var key: String {
        switch self {
        case .system: AppRules.SOURCE_SYSTEM_KEY
        case .app(let id): AppRules.SOURCE_APP_PREFIX + id
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

    /// From an AppRules.MODE_* code (push-to-talk for MODE_PUSH_TO_TALK, else «Авто»).
    init(ruleCode: Int32) { self = ruleCode == AppRules.MODE_PUSH_TO_TALK ? .pushToTalk : .continuous }
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

    init(ruleCode: Int32) { self = ruleCode == AppRules.TR_CLAUDE ? .claude : .apple }
}

extension PTTKey {
    init(ruleCode: Int32) { self = PTTKey.allCases.first { $0.ruleCode == ruleCode } ?? .rightOption }
}
