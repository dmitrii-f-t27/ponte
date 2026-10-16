import Foundation
import Security

// The decisions the completion audit of 2026-10-15 (0.1.15) moved into the specs, as the Swift and the JavaScript
// wrote them inline before. Each function names the place and the expression it replaced; the JavaScript ones are
// transcribed to Swift with the same values (a missing document is nil). Oracle of CompletionRulesDifferentialTests.
enum CompletionRulesLegacy {
    /// SettingsView «Мои наушники»: `model.outputDevices.filter { !AudioRules.isBlackHole(name: $0.name) }`, where
    /// `outputDevices` kept `outputChannels > 0`.
    static func isHeadphonesChoice(outputChannels: Int, isBlackHole: Bool) -> Bool {
        outputChannels > 0 && !isBlackHole
    }

    /// CoreAudioDeviceCatalog.isSelectableOutput: `hidden == 0 && canDefault != 0` over the two HAL flags.
    static func isSelectableOutput(hidden: UInt32, canDefault: UInt32) -> Bool {
        hidden == 0 && canDefault != 0
    }

    /// AudioProcesses.resolveOwner's parent walk: `app.activationPolicy == .regular, let o = owner(of: app)`, where
    /// `owner(of:)` is nil without a bundle ID.
    static func parentIsRegularApp(policyRegular: Bool, hasBundleID: Bool) -> Bool {
        policyRegular && hasBundleID
    }

    /// DeviceAudioPlayer.startEngine: `live.outputChannels > 0`.
    static func deviceCanPlay(outputChannels: Int) -> Bool { outputChannels > 0 }

    /// KeychainAnalysisKeyStore.delete: `status == errSecSuccess || status == errSecItemNotFound`.
    static func keyDeleteOK(status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound
    }

    /// AnalysisSettingsView: `!analysis.isDefault, analysis.provider != AnalysisRules.providerCustom` (the provider is
    /// always a known code there: CallAnalysisModel stores AnalysisRules.providerCode).
    static func offersReset(provider: Int, isDefault: Bool) -> Bool {
        !isDefault && AnalysisRulesLegacy.providerCode(stored: provider) != AnalysisRulesLegacy.providerCustom
    }

    /// PeerMicGate.push: `open && PeerRules.vadSends(...)` with `open = PeerRules.sendsMic(...)`.
    static func micSends(linkUp: Bool, muted: Bool, headphonesLike: Bool, keyHeld: Bool, hasSignal: Bool,
                         msSinceSignal: Int64) -> Bool {
        PeerRulesLegacy.sendsMic(linkUp: linkUp, muted: muted, headphonesLike: headphonesLike, keyHeld: keyHeld)
            && PeerRulesLegacy.vadSends(hasSignal: hasSignal, msSinceSignal: msSinceSignal)
    }

    /// PeerLink.open: `guard peer != sender, PeerRules.frameFresh(sentMs: sentMs, nowMs: …) else { return }`, the
    /// freshness by the independent PeerRulesLegacy (128-bit gap).
    static func frameAccepted(peer: UInt64, sender: UInt64, sentMs: Int64, nowMs: Int64) -> Bool {
        peer != sender && PeerRulesLegacy.frameFresh(sentMs: sentMs, nowMs: nowMs)
    }

    /// sw.js totals: `rank > t.rank || (rank > 0 && rank === t.rank && p.errorAt > t.at)`.
    static func swTakes(rank: Int, best: Int, at: Int, bestAt: Int) -> Bool {
        rank > best || (rank > 0 && rank == best && at > bestAt)
    }

    /// page.js report and CameraLink.report: `if (r > best)` / `if r > rank`.
    static func firstTakes(rank: Int, best: Int) -> Bool { rank > best }

    /// sw.js pagehide: `old && (old.doc === doc || old.doc == null)`; `old` is the stored report (nil: none) with its
    /// document (nil: the browser named none), `doc` the document saying it is gone.
    static func goneForgets(hasOld: Bool, oldDoc: String?, doc: String?) -> Bool {
        hasOld && (oldDoc == doc || oldDoc == nil)
    }

    /// relay/server.js upgrade: `if (!rules.roomPath(url)) rejectUpgrade(socket, 400, …)`.
    static func upgradeRefusal(roomPath: Bool) -> Int { roomPath ? 0 : 400 }

    /// relay/server.js: `url.slice(3)`.
    static let roomIDStart = 3
}
