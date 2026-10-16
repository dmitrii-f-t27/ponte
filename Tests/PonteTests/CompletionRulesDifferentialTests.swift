// The decisions the completion audit moved into the specs on 2026-10-15 (0.1.15), through their facades or the C,
// against the Swift and JavaScript they replaced (CompletionRulesLegacy), over their whole small domains. The
// error choice and the pagehide rule are also run as the callers run them (CameraLink and sw.js over lists of
// reports), and the key deletion through KeychainAnalysisKeyStore with a played Keychain.
import Foundation
import PonteAudio
import PonteCamera
import PontePeer
import PonteSpecs
import PonteSpeech
import Security
import Testing

private typealias L = CompletionRulesLegacy

@Suite("Differential: rules moved by the completion audit") struct CompletionRulesDifferentialTests {
    static let channelCounts = [Int.min, -2, -1, 0, 1, 2, 3, 8, 16, 64, Int.max]

    @Test func deviceLists() {
        let log = DiffLog("isHeadphonesChoice, isSelectableOutput, isRegularApp, isOutput")
        for channels in Self.channelCounts {
            for blackHole in [false, true] {
                log.check(AudioRules.isHeadphonesChoice(outputChannels: channels, isBlackHole: blackHole),
                          L.isHeadphonesChoice(outputChannels: channels, isBlackHole: blackHole), "headphones \(channels) \(blackHole)")
            }
            log.check(AudioRules.isOutput(channels: channels), L.deviceCanPlay(outputChannels: channels), "plays \(channels)")
        }
        // The HAL flags as CoreAudioDeviceCatalog marshals them (any UInt32 other than 0 is set).
        let flags: [UInt32] = [0, 1, 2, 0x8000_0000, .max]
        for hidden in flags { for canDefault in flags {
            log.check(AudioRules.isSelectableOutput(hidden: hidden != 0, canBeDefault: canDefault != 0),
                      L.isSelectableOutput(hidden: hidden, canDefault: canDefault), "selectable \(hidden) \(canDefault)")
        } }
        for regular in [false, true] { for bundle in [false, true] {
            log.check(AudioRules.isRegularApp(policyRegular: regular, hasBundleID: bundle),
                      L.parentIsRegularApp(policyRegular: regular, hasBundleID: bundle), "regular \(regular) \(bundle)")
        } }
        log.finish(minimumCases: 50)
    }

    @Test func analysisKeyAndReset() {
        let log = DiffLog("keyDeleteOK, offersReset")
        let statuses: [OSStatus] = [errSecSuccess, errSecItemNotFound, errSecDuplicateItem, errSecAuthFailed,
                                    errSecInteractionNotAllowed, errSecNoSuchKeychain, errSecParam, -1, 1, .min, .max]
        for status in statuses {
            log.check(AnalysisRules.keyDeleteOK(deleted: KeychainAnalysisKeyStore.statusCode(status)),
                      L.keyDeleteOK(status: status), "delete \(status)")
        }
        for provider in -2...5 { for isDefault in [false, true] {
            log.check(AnalysisRules.offersReset(provider: AnalysisRules.providerCode(stored: provider), isDefault: isDefault),
                      L.offersReset(provider: provider, isDefault: isDefault), "reset \(provider) \(isDefault)")
        } }
        log.finish(minimumCases: 25)
    }

    /// «Удалить ключ» through the store, with a played Keychain: an item that is gone, or was never there, is deleted;
    /// any other status throws, as before the move.
    @Test func keyDeletionThroughTheStore() {
        for status in [errSecSuccess, errSecItemNotFound, errSecDuplicateItem, errSecAuthFailed, errSecParam] {
            let calls = AnalysisKeychainCalls(copy: { _, _ in (errSecItemNotFound, nil) }, add: { _, _, _ in errSecSuccess },
                                              delete: { _, _ in status })
            let store = KeychainAnalysisKeyStore(calls: calls)
            var threw = false
            do { try store.delete(for: AnalysisRules.providerZai) } catch { threw = true }
            #expect(threw == !L.keyDeleteOK(status: status), "status \(status)")
        }
    }

    @Test func peerMicrophone() {
        let log = DiffLog("micSends")
        let hangover = Int64(PeerRules.vadHangoverMs)
        let times: [Int64] = [.min, -2, -1, 0, 1, hangover - 1, hangover, hangover + 1, 10_000, .max]
        for bits in 0..<32 {
            let (up, mute, phones, key, voice) = (bits & 1 != 0, bits & 2 != 0, bits & 4 != 0, bits & 8 != 0, bits & 16 != 0)
            for ms in times {
                log.check(PeerRules.micSends(linkUp: up, muted: mute, headphonesLike: phones, keyHeld: key, hasSignal: voice,
                                             msSinceSignal: ms),
                          L.micSends(linkUp: up, muted: mute, headphonesLike: phones, keyHeld: key, hasSignal: voice,
                                     msSinceSignal: ms), "\(bits) \(ms)")
            }
        }
        log.finish(minimumCases: 320)
    }

    /// PeerLink.open's first admission check: self or another sender × stale or fresh, at the skew's edges, with the
    /// sender IDs 0, 1 and UInt64.max on both sides. The caller's step (`isSelf: peer == sender`, then the rule) is
    /// simulated as PeerLink.open writes it, and compared with the guard it replaced.
    @Test func peerFrameAdmission() {
        let log = DiffLog("frameAccepted")
        let skew = Int64(PeerRules.maxSkewMs)
        #expect(skew == PeerRulesLegacy.maxSkewMs)
        let now: Int64 = 1_760_000_000_000
        let offsets: [Int64] = [0, 1, -1, skew - 1, skew, skew + 1, -skew + 1, -skew, -skew - 1, 10 * skew, -10 * skew]
        let ids: [UInt64] = [0, 1, 2, .max - 1, .max]
        for own in ids { for peer in ids {
            for offset in offsets {
                let sent = now + offset
                let caller = PeerRules.frameAccepted(isSelf: peer == own, sentMs: sent, nowMs: now)
                log.check(caller, L.frameAccepted(peer: peer, sender: own, sentMs: sent, nowMs: now),
                          "own \(own) peer \(peer) offset \(offset)")
                if peer == own { #expect(!caller, "a frame of this link itself is never taken (\(own), \(offset))") }
            }
            // The ends of the clock: never fresh across the whole range, fresh at the same instant.
            for (sent, at) in [(Int64.min, Int64.max), (Int64.max, Int64.min), (Int64.max, Int64.max), (Int64.min, Int64.min)] {
                log.check(PeerRules.frameAccepted(isSelf: peer == own, sentMs: sent, nowMs: at),
                          L.frameAccepted(peer: peer, sender: own, sentMs: sent, nowMs: at), "own \(own) peer \(peer) \(sent) \(at)")
            }
        } }
        // Fresh and from another Ponte exactly at the edges; one past them, stale.
        #expect(PeerRules.frameAccepted(isSelf: false, sentMs: now - skew, nowMs: now))
        #expect(PeerRules.frameAccepted(isSelf: false, sentMs: now + skew, nowMs: now))
        #expect(!PeerRules.frameAccepted(isSelf: false, sentMs: now - skew - 1, nowMs: now))
        #expect(!PeerRules.frameAccepted(isSelf: false, sentMs: now + skew + 1, nowMs: now))
        log.finish(minimumCases: 375)
    }

    /// The choice among reports: the rule against each caller's old comparison, then whole lists as the callers walk
    /// them. CameraLink keeps the first among equals (its reports have no times); sw.js the newest.
    @Test func errorChoice() {
        let log = DiffLog("reportErrorTakes")
        let ranks = [CameraRules.reportErrorRank(hasError: false, troubled: false),
                     CameraRules.reportErrorRank(hasError: true, troubled: false),
                     CameraRules.reportErrorRank(hasError: true, troubled: true)]
        #expect(ranks == [0, 1, 2])
        for rank in -1...3 { for best in -1...3 {
            for (at, bestAt) in [(5, 4), (4, 4), (4, 5), (0, -1)] {
                log.check(CameraRules.reportErrorTakes(rank: rank, best: best, newer: at > bestAt),
                          L.swTakes(rank: rank, best: best, at: at, bestAt: bestAt), "sw \(rank) \(best) \(at) \(bestAt)")
            }
            log.check(CameraRules.reportErrorTakes(rank: rank, best: best, newer: false), L.firstTakes(rank: rank, best: best),
                      "first \(rank) \(best)")
        } }
        // Every list of up to four reports: (has error, troubled, the time its error was first reported).
        for count in 0...4 {
            for bits in 0..<(1 << (2 * count)) {
                let reports = (0..<count).map { (hasError: bits >> (2 * $0) & 1 == 1, troubled: bits >> (2 * $0 + 1) & 1 == 1) }
                for order in 0..<3 {
                    let times = (0..<count).map { order == 0 ? $0 : order == 1 ? count - $0 : 7 }
                    var best = 0, bestAt = -1, chosen: Int?, oldBest = 0, oldBestAt = -1, oldChosen: Int?
                    var firstBest = 0, firstChosen: Int?
                    for (i, r) in reports.enumerated() {
                        let rank = CameraRules.reportErrorRank(hasError: r.hasError, troubled: r.troubled)
                        if CameraRules.reportErrorTakes(rank: rank, best: best, newer: times[i] > bestAt) {
                            best = rank; bestAt = times[i]; chosen = i
                        }
                        if L.swTakes(rank: rank, best: oldBest, at: times[i], bestAt: oldBestAt) {
                            oldBest = rank; oldBestAt = times[i]; oldChosen = i
                        }
                        if CameraRules.reportErrorTakes(rank: rank, best: firstBest, newer: false) { firstBest = rank; firstChosen = i }
                    }
                    log.check(chosen, oldChosen, "sw list \(reports) \(times)")
                    log.check(firstChosen, CameraRulesLegacy.chosenError(reports), "CameraLink list \(reports)")
                }
            }
        }
        log.finish(minimumCases: 1000)
    }

    @Test func pageGone() {
        let log = DiffLog("cm_page_gone_forgets")
        let docs: [String?] = [nil, "a", "b"]
        for hasOld in [false, true] { for oldDoc in docs { for doc in docs {
            let same = hasOld && oldDoc == doc
            log.check(cm_page_gone_forgets(hasOld, same, hasOld && oldDoc != nil),
                      L.goneForgets(hasOld: hasOld, oldDoc: oldDoc, doc: doc), "\(hasOld) \(String(describing: oldDoc)) \(String(describing: doc))")
        } } }
        log.finish(minimumCases: 18)
    }

    @Test func relayUpgrade() {
        let log = DiffLog("rl_upgrade_refusal, rl_room_id_start")
        for room in [false, true] {
            log.check(Int(rl_upgrade_refusal(room)), L.upgradeRefusal(roomPath: room), "upgrade \(room)")
        }
        log.check(Int(rl_room_id_start()), L.roomIDStart, "room id start")
        log.check(Int(RL_ROOM_PATH_BYTES) - Int(rl_room_id_start()), Int(RL_ROOM_HEX), "room id length")
        log.finish(minimumCases: 4)
    }
}
