import CoreAudio
import Foundation
import PonteCore

/// Apps that are connected to the audio system right now, with helper processes grouped under
/// their app (Chrome helpers → Chrome, WebKit.GPU → Safari). Each call reads the live state.
public final class RunningAudioAppCatalog: AudioAppCatalog {
    public init() {}

    /// Regular (Dock) apps that are audio clients, plus anything that is playing audio right now.
    /// Ponte itself is never listed. Order: playing call apps, other playing apps, idle call apps, the rest.
    public func apps() -> [AudioApp] {
        Self.group(AudioProcesses.snapshot(), selfPID: getpid())
    }

    /// Groups processes by owning app. Filtering, labels and order come from `AudioRules`.
    static func group(_ processes: [AudioProcessInfo], selfPID: pid_t) -> [AudioApp] {
        var byOwner: [String: (owner: AppOwner, pids: [Int32], playing: Bool)] = [:]
        var order: [String] = []   // first-seen order keeps the result deterministic before sorting
        for p in processes where !AudioRules.isSelfProcess(pid: p.pid, ownerPID: p.owner.pid, selfPID: selfPID) {
            if byOwner[p.owner.bundleID] == nil { order.append(p.owner.bundleID) }
            var entry = byOwner[p.owner.bundleID] ?? (p.owner, [], false)
            if !entry.pids.contains(p.pid) { entry.pids.append(p.pid) }
            entry.playing = entry.playing || p.isRunningOutput
            if p.owner.isRegularApp && !entry.owner.isRegularApp { entry.owner = p.owner }
            byOwner[p.owner.bundleID] = entry
        }
        let apps = order.compactMap { bid -> AudioApp? in
            guard let entry = byOwner[bid] else { return nil }
            let labelIndex = AudioRules.knownCallAppIndex(bundleID: bid)
            let known = labelIndex >= 0
            guard AudioRules.shouldListApp(isRegularApp: entry.owner.isRegularApp, isPlaying: entry.playing,
                                           isKnownCallApp: known) else { return nil }
            return AudioApp(bundleID: bid,
                            name: known ? AudioRules.knownCallAppLabels[labelIndex] : entry.owner.name,
                            pids: entry.pids.sorted(),
                            isPlayingAudio: entry.playing,
                            isKnownCallApp: known)
        }
        return sort(apps)
    }

    static func sort(_ apps: [AudioApp]) -> [AudioApp] {
        let ranks = apps.map { AudioRules.appRank(isKnownCallApp: $0.isKnownCallApp, isPlaying: $0.isPlayingAudio) }
        return AudioRules.appSortOrder(ranks: ranks, names: apps.map(\.name)).map { apps[$0] }
    }

    /// Devices a process currently uses for output (kAudioProcessPropertyDevices, output scope).
    /// Shows where an app really sends its sound, e.g. that Ponte plays into BlackHole.
    public static func outputDevices(ofPID pid: Int32) -> [AudioDevice] {
        guard let object = HAL.processObject(for: pid),
              let ids = try? HAL.array(object, HAL.address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput),
                                       of: AudioObjectID.self) else { return [] }
        return ids.compactMap { HAL.device($0) }
    }

    /// Raw HAL client processes (diagnostics for AudioProbe `apps --raw`).
    public static func rawProcesses() -> [(pid: Int32, bundleID: String?, ownerBundleID: String, ownerName: String, playing: Bool)] {
        AudioProcesses.snapshot().map { ($0.pid, $0.bundleID, $0.owner.bundleID, $0.owner.name, $0.isRunningOutput) }
    }
}
