import Foundation

/// Launch arguments for demos, screenshots and end-to-end checks without permissions or a call.
/// Read only from the argument domain (`open Ponte.app --args -Key value`), never from the
/// persistent domain, and never written back.
///
///   -PonteIncomingFile <path>     incoming lane reads this audio file in real time instead of a process tap
///   -PonteOutgoingFile <path>     outgoing lane reads this file instead of the microphone
///   -PonteOutgoingSink <path.wav> synthesized pt-BR speech goes to this WAV file instead of BlackHole
///   -PonteTranscriptDir <dir>     transcripts are saved here instead of ~/Documents/Ponte
///   -PonteAutostart YES           press «Старт» after launch
///   -PonteWizardStep <n>          open the setup wizard on step n (AppRules.WZ_*)
///   -PonteAppearance dark|light
struct LaunchOptions {
    var incomingFile: URL?
    var outgoingFile: URL?
    var outgoingSink: URL?
    var transcriptDir: URL?
    var autostart = false
    /// AppRules.WZ_NONE unless given.
    var wizardStep = AppRules.WZ_NONE
    var appearance: String?

    /// Files instead of devices: no permissions or call needed.
    var isTestMode: Bool { incomingFile != nil || outgoingFile != nil || outgoingSink != nil || transcriptDir != nil }

    init() {}

    init(arguments: [String: Any]) {
        func string(_ key: String) -> String? {
            guard let value = arguments[key] else { return nil }
            let text = value as? String ?? "\(value)"
            return text.isEmpty ? nil : text
        }
        func path(_ key: String) -> URL? {
            string(key).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        }
        incomingFile = path("PonteIncomingFile")
        outgoingFile = path("PonteOutgoingFile")
        outgoingSink = path("PonteOutgoingSink")
        transcriptDir = path("PonteTranscriptDir")
        if let flag = string("PonteAutostart") {
            autostart = ["yes", "true", "1"].contains(flag.lowercased())
        }
        if let step = string("PonteWizardStep"), let n = Int32(step) { wizardStep = n }
        appearance = string("PonteAppearance")
    }

    /// The options this process was launched with.
    static let current = LaunchOptions(
        arguments: UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain))
}
