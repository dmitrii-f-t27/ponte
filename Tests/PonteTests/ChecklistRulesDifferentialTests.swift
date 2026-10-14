// Owned by the t27 agent. The checklist «Перед звонком» (2026-10-13): the rules written in device_rules.t27
// (who reads which input, the listener status, headphones-like outputs, Ponte's automatic microphone) and in
// ui_rules.t27 (row marks, the microphone source, when the sheet opens, the listener polling and the call's red
// banner, the one-time microphone migration), against their Swift oracles (AudioRulesLegacy, AppRulesLegacy),
// bit for bit.
import Foundation
import PonteCore
import Testing
@testable import PonteApp
@testable import PonteAudio

private typealias AF = AudioRules
private typealias AL = AudioRulesLegacy
private typealias PF = AppRules
private typealias PL = AppRulesLegacy

@Suite("Differential: checklist rules") struct ChecklistRulesDifferentialTests {

    @Test func constantsAndCodes() {
        let log = DiffLog("checklist constants and codes")
        log.check([AF.readerPonte, AF.readerCall, AF.readerOther], [AL.readerPonte, AL.readerCall, AL.readerOther], "reader roles")
        log.check([AF.useNone, AF.useCallBlackHole, AF.useOtherBlackHole, AF.useCallRealMic],
                  [AL.useNone, AL.useCallBlackHole, AL.useOtherBlackHole, AL.useCallRealMic], "uses")
        let listen = [AF.listenUnknown, AF.listenOK, AF.listenNobody, AF.listenRealMic, AF.listenBoth, AF.listenNoBlackHole]
        log.check(listen, [AL.listenUnknown, AL.listenOK, AL.listenNobody, AL.listenRealMic, AL.listenBoth, AL.listenNoBlackHole],
                  "listen codes")
        // The app reads the device rules' listener codes as its own.
        log.check(listen.map(Int32.init), [PF.LISTEN_UNKNOWN, PF.LISTEN_OK, PF.LISTEN_NOBODY, PF.LISTEN_REAL_MIC, PF.LISTEN_BOTH,
                                           PF.LISTEN_NO_BLACKHOLE], "listen codes in the app")
        log.check([PF.CKI_LISTENER, PF.CKI_CALL_MIC, PF.CKI_HEADPHONES, PF.CKI_MY_MIC, PF.CKI_EXTENSIONS, PF.CKI_HOW_TO_TALK, PF.CKI_COUNT],
                  [PL.CKI_LISTENER, PL.CKI_CALL_MIC, PL.CKI_HEADPHONES, PL.CKI_MY_MIC, PL.CKI_EXTENSIONS, PL.CKI_HOW_TO_TALK, PL.CKI_COUNT],
                  "rows")
        log.check([PF.CK_UNKNOWN, PF.CK_OK, PF.CK_WARN, PF.CK_BAD, PF.CK_INFO], [PL.CK_UNKNOWN, PL.CK_OK, PL.CK_WARN, PL.CK_BAD, PL.CK_INFO],
                  "marks")
        log.check([PF.MICSRC_SAVED, PF.MICSRC_AUTO, PF.MICSRC_SYSTEM, PF.CKO_LAUNCH, PF.CKO_ASKED],
                  [PL.MICSRC_SAVED, PL.MICSRC_AUTO, PL.MICSRC_SYSTEM, PL.CKO_LAUNCH, PL.CKO_ASKED], "sources and reasons")
        log.check([PF.LB_NONE, PF.LB_SHOW, PF.LB_CLEAR, PF.MIGRATE_NONE, PF.MIGRATE_CLEAR, PF.MIGRATE_MARK],
                  [PL.LB_NONE, PL.LB_SHOW, PL.LB_CLEAR, PL.MIGRATE_NONE, PL.MIGRATE_CLEAR, PL.MIGRATE_MARK], "banner and migration")
        log.check(PF.DEFAULT_CHECKLIST_ON_LAUNCH, PL.DEFAULT_CHECKLIST_ON_LAUNCH, "show at launch by default")
        log.finish(minimumCases: 9)
    }

    /// Owners and targets that matter: the call apps, Ponte (and near misses), companions, helpers, the pid fallback.
    private static let ids: [String] = AL.knownCallAppBundleIDs + [
        "app.ponte.translator", "app.ponte.translatorX", "app.ponte", "App.ponte.translator", "com.apple.avconferenced",
        "com.apple.TelephonyUtilities", "com.browseros.BrowserClaw.helper", "com.google.Chrome.helper", "pid.123", "",
        "com.apple.Music", "us.zoom.xo",
    ]

    @Test func readerRoles() {
        let log = DiffLog("isPonteID, readerRole")
        var r = DiffRandom(seed: 701)
        let pids: [Int32] = [1, 5, 9, 0, -1, .max, .min]
        for owner in Self.ids {
            log.check(AF.isPonteID(owner), AL.isPonteID(owner), owner)
            for target in [nil] + Self.ids.map(Optional.some) {
                for pid in pids {
                    for selfPID: Int32 in [9, 5] {
                        log.check(AF.readerRole(ownerBundleID: owner, targetBundleID: target, pid: pid, selfPID: selfPID),
                                  AL.readerRole(ownerBundleID: owner, targetBundleID: target, pid: pid, selfPID: selfPID),
                                  describe(owner, target as Any, pid, selfPID))
                    }
                }
            }
        }
        for _ in 0..<100_000 {
            let owner = r.bool() ? r.pick(Self.ids) : r.text(maxPieces: 6)
            let target: String? = r.int(0...3) == 0 ? nil : (r.bool() ? r.pick(Self.ids) : (r.bool() ? owner : r.text(maxPieces: 6)))
            let pid = r.pick(pids), selfPID = r.pick(pids)
            log.check(AF.isPonteID(owner), AL.isPonteID(owner), owner)
            log.check(AF.readerRole(ownerBundleID: owner, targetBundleID: target, pid: pid, selfPID: selfPID),
                      AL.readerRole(ownerBundleID: owner, targetBundleID: target, pid: pid, selfPID: selfPID),
                      describe(owner, target as Any, pid, selfPID))
        }
        log.finish(minimumCases: 200_000)
    }

    @Test func readerUseKindsAndStatus() {
        let log = DiffLog("isRealMicKind, isHeadphonesLike, readerUse, listenStatus, listenIndex")
        for kind in -5...20 {
            log.check(AF.isRealMicKind(kind), AL.isRealMicKind(kind), "\(kind)")
            log.check(AF.isHeadphonesLike(kind: kind), AL.isHeadphonesLike(kind: kind), "\(kind)")
            log.check(AF.outputNeedsRescue(kind: kind), AL.outputNeedsRescue(kind: kind), "rescue \(kind)")
            for channels in [0, 2] {
                for selectable in [false, true] {
                    log.check(AF.isHearOutput(kind: kind, outputChannels: channels, selectable: selectable),
                              AL.isHearOutput(kind: kind, outputChannels: channels, selectable: selectable),
                              "hear \(kind) \(channels) \(selectable)")
                }
            }
            for role in -2...4 {
                for running in [false, true] {
                    log.check(AF.readerUse(role: role, kind: kind, runningInput: running),
                              AL.readerUse(role: role, kind: kind, runningInput: running), describe(role, kind, running))
                }
            }
        }
        // Every list of up to four pairs over the uses and a stray code, with both flags.
        var lists: [[Int]] = [[]]
        var longest: [[Int]] = [[]]
        for _ in 1...4 {
            longest = longest.flatMap { l in (-1...4).map { l + [$0] } }
            lists += longest
        }
        for uses in lists {
            log.check(AF.listenIndex(uses: uses), AL.listenIndex(uses: uses), "\(uses)")
            for listed in [false, true] {
                for present in [false, true] {
                    log.check(AF.listenStatus(uses: uses, listed: listed, blackHolePresent: present),
                              AL.listenStatus(uses: uses, listed: listed, blackHolePresent: present), describe(uses, listed, present))
                }
            }
        }
        var r = DiffRandom(seed: 702)
        for _ in 0..<20_000 {
            let n = r.int(0...256)
            let uses = (0..<n).map { _ in r.int(0...9) < 8 ? AL.useNone : r.int(-1...4) }
            let listed = r.int(0...7) > 0, present = r.int(0...7) > 0
            log.check(AF.listenIndex(uses: uses), AL.listenIndex(uses: uses), "\(n) uses")
            log.check(AF.listenStatus(uses: uses, listed: listed, blackHolePresent: present),
                      AL.listenStatus(uses: uses, listed: listed, blackHolePresent: present), describe(n, listed, present))
        }
        log.finish(minimumCases: 45_000)
    }

    @Test func autoMicrophone() {
        let log = DiffLog("pickAutoMicIndex")
        let names = ["AirPods Pro", "AirPods", "MacBook Pro Microphone", "BlackHole 2ch", "Jabra Evolve", "USB Audio",
                     "External Microphone", "External Headphones", "", "iPhone Microphone", "airpods pro"]
        var r = DiffRandom(seed: 703)
        // Every kind for a two-device list (an output and one more device), every output index and channel count.
        for k0 in -1...14 {
            for k1 in -1...14 {
                for i0 in [0, 1] {
                    for i1 in [0, 1] {
                        for (n0, n1) in [("AirPods Pro", "AirPods Pro"), ("AirPods Pro", "Jabra Evolve")] {
                            for output in -1...2 {
                                log.check(AF.pickAutoMicIndex(names: [n0, n1], kinds: [k0, k1], inputChannels: [i0, i1], outputIndex: output),
                                          AL.pickAutoMicIndex(names: [n0, n1], kinds: [k0, k1], inputChannels: [i0, i1], outputIndex: output),
                                          describe(k0, k1, i0, i1, n0, n1, output))
                            }
                        }
                    }
                }
            }
        }
        for _ in 0..<150_000 {
            let n = r.int(0...(r.int(0...19) == 0 ? 256 : 12))
            let ns = (0..<n).map { _ in r.pick(names) }
            let kinds = (0..<n).map { _ in r.int(-1...14) }
            let inputs = (0..<n).map { _ in r.pick([-1, 0, 0, 1, 1, 2]) }
            let output = r.int(-2...(n + 1))
            log.check(AF.pickAutoMicIndex(names: ns, kinds: kinds, inputChannels: inputs, outputIndex: output),
                      AL.pickAutoMicIndex(names: ns, kinds: kinds, inputChannels: inputs, outputIndex: output),
                      describe(ns, kinds, inputs, output))
        }
        log.finish(minimumCases: 155_000)
    }

    @Test func checklistUIRules() {
        let log = DiffLog("listenerMark, checklistMark, micSource, checklistOpens, checklistCanStart, pollReadsListeners, "
                          + "listenerStreak, listenerBanner, micMigration")
        let bools = [false, true]
        for status: Int32 in -3...8 {
            log.check(PF.listenerMark(listenStatus: status), PL.listenerMark(listenStatus: status), "\(status)")
            for item: Int32 in -2...8 {
                for like in bools {
                    for source: Int32 in -2...4 {
                        log.check(PF.checklistMark(item: item, listenStatus: status, headphonesLike: like, micSource: source),
                                  PL.checklistMark(item: item, listenStatus: status, headphonesLike: like, micSource: source),
                                  describe(item, status, like, source))
                    }
                }
            }
        }
        for bits in 0..<32 {
            let b = (0..<5).map { bits & (1 << $0) != 0 }
            log.check(PF.micSource(hasSetting: b[0], found: b[1], hasAuto: b[2]), PL.micSource(hasSetting: b[0], found: b[1], hasAuto: b[2]),
                      "\(bits)")
            log.check(PF.micMigration(migrated: b[0], hasSetting: b[1]), PL.micMigration(migrated: b[0], hasSetting: b[1]), "\(bits)")
            for reason: Int32 in -1...3 {
                log.check(PF.checklistOpens(reason: reason, showOnLaunch: b[0], wizardShown: b[1], testMode: b[2], autostart: b[3]),
                          PL.checklistOpens(reason: reason, showOnLaunch: b[0], wizardShown: b[1], testMode: b[2], autostart: b[3]),
                          describe(reason, bits))
            }
        }
        for run: Int32 in -2...6 {
            log.check(PF.checklistCanStart(runState: run), PL.checklistCanStart(runState: run), "\(run)")
            for open in bools {
                for tick: Int64 in -50...50 {
                    log.check(PF.pollReadsListeners(tick: tick, sheetOpen: open, runState: run),
                              PL.pollReadsListeners(tick: tick, sheetOpen: open, runState: run), describe(tick, open, run))
                }
            }
            for mark: Int32 in -2...7 {
                log.check(PF.listenerStreak(mark: mark), PL.listenerStreak(mark: mark), "\(mark)")
                for ms: Int64 in [.min, -1, 0, 1, 2999, 3000, 3001, 10_000, .max] {
                    for shown in bools {
                        for dismissed in bools {
                            log.check(PF.listenerBanner(runState: run, mark: mark, msBad: ms, shown: shown, dismissed: dismissed),
                                      PL.listenerBanner(runState: run, mark: mark, msBad: ms, shown: shown, dismissed: dismissed),
                                      describe(run, mark, ms, shown, dismissed))
                        }
                    }
                }
            }
        }
        var r = DiffRandom(seed: 704)
        for _ in 0..<100_000 {
            let tick = r.int64(Int64.min...Int64.max), open = r.bool(), run = r.int32(-1...5)
            log.check(PF.pollReadsListeners(tick: tick, sheetOpen: open, runState: run),
                      PL.pollReadsListeners(tick: tick, sheetOpen: open, runState: run), describe(tick, open, run))
            let ms = r.int64(-100_000...100_000), mark = r.int32(-1...5), dismissed = r.bool()
            log.check(PF.listenerBanner(runState: run, mark: mark, msBad: ms, shown: open, dismissed: dismissed),
                      PL.listenerBanner(runState: run, mark: mark, msBad: ms, shown: open, dismissed: dismissed),
                      describe(run, mark, ms, open, dismissed))
        }
        log.finish(minimumCases: 200_000)
    }

    @Test func rescueOutputPicks() {
        let log = DiffLog("pickRescueOutputIndex")
        let pool = [AF.kindBuiltInSpeaker, AF.kindBuiltInHeadphones, AF.kindBluetooth, AF.kindUSB, AF.kindBlackHole,
                    AF.kindDisplay, AF.kindAirPlay, AF.kindAggregate, AF.kindPonteAggregate, AF.kindUnknown]
        var r = DiffRandom(seed: 1014)
        for _ in 0..<5000 {
            let n = r.int(0...7)
            let kinds = (0..<n).map { _ in pool[r.int(0...(pool.count - 1))] }
            let outputs = (0..<n).map { _ in r.int(0...3) == 0 ? 0 : 2 }
            let selectable = (0..<n).map { _ in r.int(0...4) != 0 }
            log.check(AF.pickRescueOutputIndex(kinds: kinds, outputChannels: outputs, selectable: selectable),
                      AL.pickRescueOutputIndex(kinds: kinds, outputChannels: outputs, selectable: selectable),
                      "\(kinds) \(outputs) \(selectable)")
        }
        log.finish(minimumCases: 5000)
    }
}
