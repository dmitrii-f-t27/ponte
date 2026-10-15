// Two Russians in one call (Specs/peer_rules.t27, through the PeerRules facade) against their Swift oracle
// (PeerRulesLegacy), bit for bit: exhaustive over flags and small integer ranges, seeded random elsewhere
// (Portuguese words with accents, punctuation, digits and Cyrillic; invalid bytes; texts beyond the buffers; secret
// codes as typed and pasted; times around every edge of a voice window and over the whole time domain), plus hand
// cases from real calls and from the review of 2026-10-14.
import Foundation
import PonteAudio
import PonteSpecs
import Testing
@testable import PontePeer

private typealias F = PeerRules
private typealias L = PeerRulesLegacy

@Suite("Differential: peer rules") struct PeerRulesDifferentialTests {

    @Test func constants() {
        let log = DiffLog("peer constants and codes")
        log.check(F.sampleRate, L.sampleRate, "sampleRate")
        log.check([F.frameMs, F.maxPeers, F.helloEveryMs, F.peerTimeoutMs, F.vadHangoverMs, F.jitterWindow, F.failedAfter],
                  [L.frameMs, L.maxPeers, L.helloEveryMs, L.peerTimeoutMs, L.vadHangoverMs, L.jitterWindow, L.failedAfter],
                  "Int constants")
        log.check([F.msgHello, F.msgAudio, F.msgVoice, F.msgBye], [L.msgHello, L.msgAudio, L.msgVoice, L.msgBye], "messages")
        log.check([F.voiceTTS, F.voiceOwn, F.voiceStart, F.voiceEnd], [L.voiceTTS, L.voiceOwn, L.voiceStart, L.voiceEnd], "voice codes")
        log.check([F.statusOff, F.statusConnecting, F.statusWaiting, F.statusLinked, F.statusFailed],
                  [L.statusOff, L.statusConnecting, L.statusWaiting, L.statusLinked, L.statusFailed], "status codes")
        log.check([F.jitterTargetMs, F.jitterMaxMs, F.jitterSlackMs], [L.jitterTargetMs, L.jitterMaxMs, L.jitterSlackMs], "jitter ms")
        log.check([F.windowBeforeMs, F.windowAfterMs, F.textWindowMs, F.windowKeepMs, F.ownAfterMs, F.echoLagMs],
                  [L.windowBeforeMs, L.windowAfterMs, L.textWindowMs, L.windowKeepMs, L.ownAfterMs, L.echoLagMs], "window ms")
        log.check([F.containMinMilli, F.containSureMilli, F.ownOverlapPermille, F.minWords],
                  [L.containMinMilli, L.containSureMilli, L.ownOverlapPermille, L.minWords], "phrase thresholds")
        log.check(F.secretAlphabet, L.secretAlphabet, "secretAlphabet")
        log.check(String(decoding: F.secretAlphabet, as: UTF8.self), "23456789abcdefghjkmnpqrstuvwxyz", "the alphabet asked for")
        log.check([F.secretLength, F.secretGroup, F.kdfIterations, F.closeRoomFull, F.stableMs, F.voiceRefreshMs],
                  [L.secretLength, L.secretGroup, L.kdfIterations, L.closeRoomFull, L.stableMs, L.voiceRefreshMs], "link constants")
        log.check([F.maxSkewMs, F.voiceStaleMs], [L.maxSkewMs, L.voiceStaleMs], "Int64 constants")
        log.check(Int(PE_SECRET_DISPLAY_LEN), L.secretLength + (L.secretLength - 1) / L.secretGroup, "display length")
        log.check([Int(PE_TEXT_MAX), Int(PE_WORDS_MAX)], [L.textMax, L.wordsMax], "text limits")
        log.check(Int(PE_PEER_TIMEOUT_MS), 3 * Int(PE_HELLO_EVERY_MS), "three HELLOs missed")
        log.finish(minimumCases: 15)
    }

    /// The jitter buffer answers with the own-voice relay's codes, so the app's relay code reads both.
    @Test func jitterCodesAreTheRelayCodes() {
        #expect([PE_JIT_KEEP, PE_JIT_SEND, PE_JIT_DROP, PE_JIT_TRIM, PE_JIT_REFILL].map { Int($0) }
                == [AudioRules.relayKeep, AudioRules.relaySend, AudioRules.relayDrop, AudioRules.relayTrim, AudioRules.relayRefill])
        #expect([PE_JIT_KEEP, PE_JIT_SEND, PE_JIT_DROP, PE_JIT_TRIM, PE_JIT_REFILL].map { Int64($0) }
                == [AU_RLA_KEEP, AU_RLA_SEND, AU_RLA_DROP, AU_RLA_TRIM, AU_RLA_REFILL].map { Int64($0) })
        #expect(F.jitterAction(filling: true, pendingMs: 80, queuedMs: 0, lowMs: 0, lowCount: 0) == AudioRules.relayKeep)
        #expect(F.jitterAction(filling: true, pendingMs: 120, queuedMs: 0, lowMs: 0, lowCount: 0) == AudioRules.relaySend)
        #expect(F.jitterAction(filling: false, pendingMs: 40, queuedMs: 361, lowMs: 0, lowCount: 1) == AudioRules.relayDrop)
        #expect(F.jitterAction(filling: false, pendingMs: 40, queuedMs: 200, lowMs: 161, lowCount: 50) == AudioRules.relayDrop)
        #expect(F.jitterAction(filling: true, pendingMs: 121, queuedMs: nil, lowMs: 0, lowCount: 0) == AudioRules.relayTrim)
        #expect(F.jitterAction(filling: false, pendingMs: 40, queuedMs: 0, lowMs: 0, lowCount: 3) == AudioRules.relayRefill)
        // The same algorithm as the relay: where both sets of constants give the same answer, the codes agree.
        #expect(F.jitterAction(filling: false, pendingMs: 10, queuedMs: 0, lowMs: 0, lowCount: 0)
                == AudioRules.relayAction(filling: false, pendingMs: 10, queuedMs: 0, lowMs: 0, lowCount: 0))
        #expect(F.jitterAction(filling: true, pendingMs: 10, queuedMs: nil, lowMs: 0, lowCount: 0)
                == AudioRules.relayAction(filling: true, pendingMs: 10, queuedMs: nil, lowMs: 0, lowCount: 0))
    }

    /// status, reconnectDelayMs, peerAlive.
    @Test func linkRules() {
        let log = DiffLog("status, reconnectDelayMs, peerAlive")
        let peers = [Int.min, -2, -1, 0, 1, 2, 5, 6, 7, 100, Int.max]
        let failures = [Int.min, -1, 0, 1, 2, 3, 4, 100, Int.max]
        for linkOn in [false, true] {
            for connected in [false, true] {
                for p in peers {
                    for f in failures {
                        log.check(F.status(linkOn: linkOn, connected: connected, peers: p, failures: f),
                                  L.status(linkOn: linkOn, connected: connected, peers: p, failures: f), describe(linkOn, connected, p, f))
                    }
                }
            }
        }
        for attempt in Array(-2000...2000) + [Int.min, Int.min + 1, Int.max, Int.max - 1, 1 << 40] {
            log.check(F.reconnectDelayMs(attempt: attempt), L.reconnectDelayMs(attempt: attempt), "attempt \(attempt)")
        }
        for ms in Int64(-2000)...Int64(20_000) {
            log.check(F.peerAlive(msSinceHello: ms), L.peerAlive(msSinceHello: ms), "ms \(ms)")
        }
        var r = DiffRandom(seed: 1527)
        for ms in [Int64.min, Int64.min + 1, Int64.max, -1, 0, 14_999, 15_000, 15_001] + (0..<2000).map({ _ in Int64(bitPattern: r.next()) }) {
            log.check(F.peerAlive(msSinceHello: ms), L.peerAlive(msSinceHello: ms), "ms \(ms)")
        }
        log.finish(minimumCases: 20_000)
    }

    /// acceptsNewPeer, roomFull, retryDelayMs.
    @Test func room() {
        let log = DiffLog("acceptsNewPeer, roomFull, retryDelayMs")
        log.check(F.roomFullRetryMs, L.roomFullRetryMs, "roomFullRetryMs")
        log.check(F.unknownListenerMs, L.unknownListenerMs, "unknownListenerMs")
        let counts = Array(-3...10) + [Int.min, Int.max, Int.max - 1]
        for members in counts {
            for peers in counts {
                for ms: Int64 in [.min, -1, 0, 5999, 6000, 6001, 60_000, .max] {
                    log.check(F.unknownListener(members: members, peers: peers, msSinceMismatch: ms),
                              L.unknownListener(members: members, peers: peers, msSinceMismatch: ms), "listener \(members) \(peers) \(ms)")
                }
            }
        }
        for n in Array(-2000...2000) + [Int.min, Int.min + 1, Int.max - 1, Int.max] {
            log.check(F.acceptsNewPeer(knownPeers: n), L.acceptsNewPeer(knownPeers: n), "\(n)")
        }
        for code in Array(-1000...70_000) + [Int.min, Int.max] {
            log.check(F.roomFull(closeCode: code), L.roomFull(closeCode: code), "\(code)")
        }
        for code in [Int.min, -4001, 0, 1000, 1006, 4000, 4001, 4002, Int.max] {
            for attempt in Array(-3...12) + [Int.min, Int.max] {
                log.check(F.retryDelayMs(closeCode: code, attempt: attempt), L.retryDelayMs(closeCode: code, attempt: attempt),
                          "\(code) attempt \(attempt)")
            }
        }
        var r = DiffRandom(seed: 4001)
        for _ in 0..<20_000 {
            let n = Int(bitPattern: UInt(r.next()))
            log.check(F.acceptsNewPeer(knownPeers: n), L.acceptsNewPeer(knownPeers: n), "\(n)")
            log.check(F.roomFull(closeCode: n), L.roomFull(closeCode: n), "\(n)")
            log.check(F.retryDelayMs(closeCode: n, attempt: n), L.retryDelayMs(closeCode: n, attempt: n), "\(n) attempt")
        }
        log.finish(minimumCases: 100_000)
    }

    /// sendsMic, vadSends.
    @Test func microphoneRules() {
        let log = DiffLog("sendsMic, vadSends")
        for bits in 0..<16 {
            let up = bits & 1 != 0, muted = bits & 2 != 0, phones = bits & 4 != 0, key = bits & 8 != 0
            log.check(F.sendsMic(linkUp: up, muted: muted, headphonesLike: phones, keyHeld: key),
                      L.sendsMic(linkUp: up, muted: muted, headphonesLike: phones, keyHeld: key), describe(up, muted, phones, key))
        }
        var r = DiffRandom(seed: 600)
        let edges: [Int64] = [Int64.min, Int64.min + 1, Int64.max, -601, -600, -1, 0, 1, 599, 600, 601]
        for signal in [false, true] {
            for ms in Array(Int64(-3000)...Int64(10_000)) + edges + (0..<1000).map({ _ in Int64(bitPattern: r.next()) }) {
                log.check(F.vadSends(hasSignal: signal, msSinceSignal: ms), L.vadSends(hasSignal: signal, msSinceSignal: ms), describe(signal, ms))
            }
        }
        log.finish(minimumCases: 20_000)
    }

    /// jitterAction, jitterWindowEnds, jitterTrims.
    @Test func jitterRules() {
        let log = DiffLog("jitterAction, jitterWindowEnds, jitterTrims")
        for count in [Int.min, -1, 0, 1, 48, 49, 50, 51, 1000, Int.max] {
            log.check(F.jitterWindowEnds(lowCount: count), L.jitterWindowEnds(lowCount: count), "\(count)")
        }
        var r = DiffRandom(seed: 120)
        var values: [Double] = [0, -0.0, -1, 1, 20, 40, 80, 119.999, 120, 120.001, 159.999, 160, 160.001, 200, 240,
                                360, 399.999, 400, 400.001, 1e9, -1e9, .infinity, -.infinity, .nan, .leastNonzeroMagnitude]
        for _ in 0..<45 { values.append(r.double()) }
        let lows: [Double] = [0, 100, 159.999, 160, 160.001, 300, .nan, .infinity]
        let counts = [0, 49, 50, 51]
        for pending in values {
            for queued in values + [nil] as [Double?] {
                for filling in [false, true] {
                    for low in lows {
                        for count in counts {
                            log.check(F.jitterAction(filling: filling, pendingMs: pending, queuedMs: queued, lowMs: low, lowCount: count),
                                      L.jitterAction(filling: filling, pendingMs: pending, queuedMs: queued, lowMs: low, lowCount: count),
                                      describe(filling, pending, queued as Any, low, count))
                        }
                    }
                }
            }
            for oldest in values {
                log.check(F.jitterTrims(pendingMs: pending, oldestMs: oldest), L.jitterTrims(pendingMs: pending, oldestMs: oldest),
                          describe(pending, oldest))
            }
        }
        log.finish(minimumCases: 200_000)
    }

    /// secretNormalized, secretDisplay over typed and pasted codes, any bytes, and texts past 4096 bytes.
    @Test func secretCode() {
        let log = DiffLog("secretNormalized, secretDisplay")
        var r = DiffRandom(seed: 2026)
        for text in Self.fixtures() {
            log.check(F.secretNormalized(utf8: text), L.secretNormalized(utf8: text), "fixture")
            log.check(F.secretDisplay(utf8: text), L.secretDisplay(utf8: text), "fixture display")
        }
        var valid = 0
        for k in 0..<40_000 {
            let text = Self.typedSecret(&r)
            let f = F.secretNormalized(text)
            log.check(f, L.secretNormalized(text), "typed \(k): \(text.prefix(100))")
            log.check(F.secretDisplay(text), L.secretDisplay(text), "display typed \(k): \(text.prefix(100))")
            if let f {
                valid += 1
                log.check(F.secretDisplay(f), L.secretDisplay(f), "display \(f)")
                // What is shown normalizes back to the code.
                log.check(F.secretNormalized(F.secretDisplay(f)), f, "round trip \(f)")
            }
        }
        for k in 0..<5000 {
            let bytes = r.bytes(maxCount: r.pick([14, 40, 5000]))
            log.check(F.secretNormalized(utf8: bytes), L.secretNormalized(utf8: bytes), "bytes \(k)")
            log.check(F.secretDisplay(utf8: bytes), L.secretDisplay(utf8: bytes), "display bytes \(k)")
            // Exactly the length of a code, mostly alphabet bytes.
            let twelve = (0..<12).map { _ in r.int(0...9) == 0 ? r.pick(Self.nearSecretBytes) : r.pick(L.secretAlphabet) }
            log.check(F.secretDisplay(utf8: twelve), L.secretDisplay(utf8: twelve), "display twelve \(k)")
            log.check(F.secretNormalized(utf8: twelve), L.secretNormalized(utf8: twelve), "twelve \(k)")
        }
        // A code across the 4096-byte cut.
        for at in 4070...4100 {
            let bytes = [UInt8](repeating: 0x20, count: at) + Array("abcd-efgh-jkmn".utf8)
            log.check(F.secretNormalized(utf8: bytes), L.secretNormalized(utf8: bytes), "code at \(at)")
        }
        print("secret codes: \(valid) of 40000 typed texts are codes")
        #expect(valid > 8000 && valid < 32_000)
        log.finish(minimumCases: 100_000)
    }

    /// frameFresh and voiceLocalMs over every edge of Int64; seqNewer over every edge of UInt32.
    @Test func freshness() {
        let log = DiffLog("frameFresh, voiceLocalMs, seqNewer")
        let edges: [Int64] = [.min, .min + 1, .min + 29_999, .min + 30_000, .min + 30_001, -(1 << 62), -30_001, -30_000,
                              -29_999, -1, 0, 1, 29_999, 30_000, 30_001, 1 << 62, .max - 30_001, .max - 30_000,
                              .max - 29_999, .max - 1, .max]
        for sent in edges {
            for now in edges {
                log.check(F.frameFresh(sentMs: sent, nowMs: now), L.frameFresh(sentMs: sent, nowMs: now), describe(sent, now))
            }
        }
        let clock: Int64 = 1_760_000_000_000
        for d in Int64(-40_000)...Int64(40_000) {
            log.check(F.frameFresh(sentMs: 0, nowMs: d), L.frameFresh(sentMs: 0, nowMs: d), "d \(d)")
            log.check(F.frameFresh(sentMs: clock, nowMs: clock + d), L.frameFresh(sentMs: clock, nowMs: clock + d), "clock d \(d)")
        }
        var r = DiffRandom(seed: 30_000)
        for _ in 0..<20_000 {
            let sent = Int64(bitPattern: r.next())
            let now = r.bool() ? Int64(bitPattern: r.next()) : sent &+ Int64(r.int(-40_000...40_000))
            log.check(F.frameFresh(sentMs: sent, nowMs: now), L.frameFresh(sentMs: sent, nowMs: now), describe(sent, now))
        }
        for at in edges {
            for sent in edges {
                for now in [Int64.min, -1, 0, 1, 29_999, 30_000, clock, .max] {
                    log.check(F.voiceLocalMs(atMs: at, sentMs: sent, nowMs: now), L.voiceLocalMs(atMs: at, sentMs: sent, nowMs: now),
                              "voiceLocal \(at) \(sent) \(now)")
                }
            }
        }
        for _ in 0..<20_000 {
            let sent = r.bool() ? Int64(bitPattern: r.next()) : clock &+ Int64(r.int(-40_000...40_000))
            let at = r.bool() ? Int64(bitPattern: r.next()) : sent &- Int64(r.int(-1_000...40_000))
            let now = r.bool() ? Int64(bitPattern: r.next()) : clock &+ Int64(r.int(-40_000...40_000))
            log.check(F.voiceLocalMs(atMs: at, sentMs: sent, nowMs: now), L.voiceLocalMs(atMs: at, sentMs: sent, nowMs: now),
                      "voiceLocal \(at) \(sent) \(now)")
        }
        let seqEdges: [UInt32] = [0, 1, 2, 1000, .max / 2, .max / 2 + 1, .max - 1, .max]
        for seq in seqEdges {
            for last in seqEdges {
                for has in [false, true] {
                    log.check(F.seqNewer(seq: seq, lastSeq: last, hasLast: has), L.seqNewer(seq: seq, lastSeq: last, hasLast: has),
                              describe(seq, last, has))
                }
            }
        }
        for _ in 0..<20_000 {
            let last = UInt32(truncatingIfNeeded: r.next())
            let seq = r.bool() ? UInt32(truncatingIfNeeded: r.next()) : last &+ UInt32(bitPattern: Int32(r.int(-3...3)))
            for has in [false, true] {
                log.check(F.seqNewer(seq: seq, lastSeq: last, hasLast: has), L.seqNewer(seq: seq, lastSeq: last, hasLast: has),
                          describe(seq, last, has))
            }
        }
        log.finish(minimumCases: 200_000)
    }

    /// windowEndMs, refreshed or not, around the stale edge and over every edge of Int64.
    @Test func voiceWindowEnd() {
        let log = DiffLog("windowEndMs")
        let edges: [Int64] = [.min, .min + 1, .min + 12_000, .min + 12_001, -12_001, -12_000, -1, 0, 1, 12_000, 12_001,
                              .max - 12_001, .max - 12_000, .max]
        for refreshed in [false, true] {
            for end in [Int64.min, -2, -1, 0, 1, 15_000, .max] {
                for seen in edges {
                    for now in edges {
                        log.check(F.windowEndMs(endMs: end, lastSeenMs: seen, nowMs: now, refreshed: refreshed),
                                  L.windowEndMs(endMs: end, lastSeenMs: seen, nowMs: now, refreshed: refreshed),
                                  describe(end, seen, now, refreshed))
                    }
                }
            }
            for d in Int64(-2000)...Int64(80_000) {
                log.check(F.windowEndMs(endMs: -1, lastSeenMs: 1_000_000, nowMs: 1_000_000 + d, refreshed: refreshed),
                          L.windowEndMs(endMs: -1, lastSeenMs: 1_000_000, nowMs: 1_000_000 + d, refreshed: refreshed), "d \(d) \(refreshed)")
            }
        }
        var r = DiffRandom(seed: 12_000)
        for _ in 0..<40_000 {
            let seen = r.bool() ? Int64(r.int(0...10_000_000)) : Int64(bitPattern: r.next())
            let now = r.int(0...3) == 0 ? Int64(bitPattern: r.next()) : seen &+ Int64(r.int(-1000...90_000))
            let end: Int64 = r.pick([-1, -1, -1, 0, Int64(r.int(-5...5)), seen &+ Int64(r.int(0...20_000)), Int64(bitPattern: r.next())])
            let refreshed = r.bool()
            log.check(F.windowEndMs(endMs: end, lastSeenMs: seen, nowMs: now, refreshed: refreshed),
                      L.windowEndMs(endMs: end, lastSeenMs: seen, nowMs: now, refreshed: refreshed), describe(end, seen, now, refreshed))
        }
        log.finish(minimumCases: 200_000)
    }

    /// wordCount over recognized phrases, any bytes, and texts past 4096 bytes or 512 words.
    @Test func wordCount() {
        let log = DiffLog("wordCount")
        var r = DiffRandom(seed: 3)
        for text in Self.fixtures() {
            log.check(F.wordCount(utf8: text), L.wordCount(utf8: text), "fixture \(String(decoding: text, as: UTF8.self))")
        }
        var distribution = [Int](repeating: 0, count: 6)
        for k in 0..<20_000 {
            let text = Self.render(Self.tokens(&r, count: k % 100 == 0 ? r.int(300...900) : r.int(0...12)), &r)
            let f = F.wordCount(text)
            log.check(f, L.wordCount(text), "text \(k): \(text.prefix(200))")
            distribution[Swift.min(f, 5)] += 1
        }
        for k in 0..<5000 {
            let bytes = r.bytes(maxCount: k % 100 == 0 ? 6000 : r.pick([5, 20, 200, 600]))
            log.check(F.wordCount(utf8: bytes), L.wordCount(utf8: bytes), "bytes \(k)")
            let pieces = r.text(maxPieces: r.pick([3, 10, 60, 400]))
            log.check(F.wordCount(pieces), L.wordCount(pieces), "pieces \(k)")
        }
        // Every cut of a text around both limits.
        let spaced = String(repeating: "a ", count: 2100)
        for cut in Array(1000...1040) + Array(4080...4100) {
            let bytes = Array(spaced.utf8.prefix(cut))
            log.check(F.wordCount(utf8: bytes), L.wordCount(utf8: bytes), "cut \(cut)")
        }
        let wide = String(repeating: "ж", count: 2047) + " fim"
        log.check(F.wordCount(wide), L.wordCount(wide), "beyond 4096 bytes")
        log.check(F.wordCount(wide), 2, "the 4096th byte starts a word that is cut")
        log.check(F.wordCount(String(repeating: "sim, ", count: 700)), 512, "the first 512 words")
        print("word count 0...5+: \(distribution)")
        // Short and long phrases both occur, so the minWords edge is covered.
        #expect(distribution.allSatisfy { $0 > 500 })
        log.finish(minimumCases: 30_000)
    }

    /// containmentMilli over recognized pieces of TTS texts, any bytes, and texts past the buffers.
    @Test func containment() {
        let log = DiffLog("containmentMilli")
        var r = DiffRandom(seed: 800)
        let fixtures = Self.fixtures()
        for a in fixtures {
            for b in fixtures {
                log.check(F.containmentMilli(utf8: a, b), L.containmentMilli(utf8: a, b), "fixtures")
            }
            // A phrase with words is wholly in itself: wordCount is the containment's denominator.
            log.check(F.containmentMilli(utf8: a, a) == 1000, F.wordCount(utf8: a) > 0, "self containment")
        }
        var distribution = [Int](repeating: 0, count: 11)
        for k in 0..<20_000 {
            let said = Self.tokens(&r, count: k % 100 == 0 ? r.int(300...900) : r.int(0...30))
            let phrase = Self.heard(from: said, &r)
            let tp = Self.render(phrase, &r), ts = Self.render(said, &r)
            let f = F.containmentMilli(phrase: tp, said: ts)
            log.check(f, L.containmentMilli(phrase: tp, said: ts), "pair \(k): \(tp.prefix(200)) | \(ts.prefix(200))")
            if (0...1000).contains(f) { distribution[f / 100] += 1 }
        }
        // Any bytes, the shared random pieces, and texts beyond 4096 bytes or 512 words.
        for k in 0..<4000 {
            let a = r.bytes(maxCount: k % 100 == 0 ? 5000 : r.pick([20, 200, 600]))
            let b = k % 2 == 0 ? r.bytes(maxCount: 200) : a.shuffledDeterministically(&r)
            log.check(F.containmentMilli(utf8: a, b), L.containmentMilli(utf8: a, b), "bytes \(k)")
            log.check(F.containmentMilli(utf8: b, a), L.containmentMilli(utf8: b, a), "bytes reversed \(k)")
            let sa = r.text(maxPieces: r.pick([10, 60, 400])), sb = r.text(maxPieces: 60)
            log.check(F.containmentMilli(phrase: sa, said: sb), L.containmentMilli(phrase: sa, said: sb), "pieces \(k)")
        }
        let many = String(repeating: "sim ", count: 700), some = String(repeating: "SIM, ", count: 300)
        log.check(F.containmentMilli(phrase: many, said: some), L.containmentMilli(phrase: many, said: some), "700 in 300 words")
        log.check(F.containmentMilli(phrase: many, said: some), 1000 * 300 / 512, "the first 512 words of the phrase")
        log.check(F.containmentMilli(phrase: some, said: many), 1000, "300 in 700 words")
        let wide = String(repeating: "ж", count: 3000) + " fim"
        log.check(F.containmentMilli(phrase: "fim", said: wide), L.containmentMilli(phrase: "fim", said: wide), "beyond 4096 bytes")
        log.check(F.containmentMilli(phrase: "fim", said: wide), 0, "the word after 4096 bytes is not read")
        print("containment deciles: \(distribution)")
        // The random pairs cover the whole range, not only 0 and 1000.
        #expect(distribution.filter { $0 > 100 }.count >= 8)
        log.finish(minimumCases: 30_000)
    }

    /// isPeerVoice around every edge of a voice window (closed and open, this Ponte's own or another's, short and long
    /// phrases), and over the whole time domain (|t| < 2^62).
    @Test func peerVoice() {
        let log = DiffLog("isPeerVoice")
        let limit: Int64 = (1 << 62) - 1
        func clamp(_ x: Int64) -> Int64 { Swift.min(Swift.max(x, -limit), limit) }
        func check(_ kind: Int, _ isSelf: Bool, _ words: Int, _ c: Int, _ ps: Int64, _ pe: Int64, _ ws: Int64, _ we: Int64) {
            log.check(F.isPeerVoice(kind: kind, isSelf: isSelf, phraseWords: words, containmentMilli: c, phraseStartMs: ps,
                                    phraseEndMs: pe, windowStartMs: ws, windowEndMs: we),
                      L.isPeerVoice(kind: kind, isSelf: isSelf, phraseWords: words, containmentMilli: c, phraseStartMs: ps,
                                    phraseEndMs: pe, windowStartMs: ws, windowEndMs: we),
                      describe(kind, isSelf, words, c, ps, pe, ws, we))
        }
        // Every 7 ms of phrase start around the window [10000, 12000] (closed and open), with the phrase lengths at the
        // edges of the 60% share past +300 (own voice) and +800 (TTS echo), the word counts at the edge of 3 and the
        // containments at the edges of 800 and 900.
        let lengths: [Int64] = [0, 1, 2, 499, 500, 501, 1332, 1333, 1334, 1666, 1667, 2166, 2167, 3500]
        for windowEnd: Int64 in [12_000, -1] {
            for start in stride(from: Int64(9_000), through: 14_500, by: 7) {
                for length in lengths {
                    for isSelf in [false, true] {
                        for words in [2, 3] {
                            check(F.voiceOwn, isSelf, words, 0, start, start + length, 10_000, windowEnd)
                            for c in [799, 800, 899, 900] {
                                check(F.voiceTTS, isSelf, words, c, start, start + length, 10_000, windowEnd)
                            }
                        }
                    }
                }
            }
        }
        // Every millisecond around the end of the 1.5 s and the 15 s windows (12000 + 1500, 12000 + 15000).
        for edge: Int64 in [13_500, 27_000] {
            for start in (edge - 100)...(edge + 100) {
                for c in [800, 899, 900] {
                    for words in [2, 3] {
                        for isSelf in [false, true] {
                            for length: Int64 in [0, 1000] {
                                check(F.voiceTTS, isSelf, words, c, start, start + length, 10_000, 12_000)
                            }
                        }
                    }
                }
            }
        }
        var r = DiffRandom(seed: 1_500)
        let kinds = [Int.min, -1, 0, 1, 2, 3, Int.max]
        let containments = [Int.min, -1, 0, 799, 800, 801, 899, 900, 901, 1000, Int.max]
        let wordCounts = [Int.min, -1, 0, 1, 2, 3, 4, 25, 512, Int.max]
        for k in 0..<100_000 {
            let windowStart = clamp(r.pick([0, 1, 300, 10_000, Int64(r.int(0...10_000_000)), Int64(r.int(-1_000_000...0)),
                                            limit, -limit, limit - 1500, -limit + 300, r.int64(-limit...limit)]))
            let windowEnd: Int64 = switch r.int(0...6) {
            case 0: -1
            case 1: Int64(r.int(-1_000_000 ... -1))
            case 2: .min
            case 3: 0
            case 4: windowStart
            default: clamp(windowStart + Int64(r.int(0...30_000)))
            }
            let last = Swift.max(windowEnd, windowStart)
            let anchors: [Int64] = [windowStart - 300, windowStart, last + 300, last + 800, last + 1500, last + 15_000, windowEnd,
                                    windowStart - 20_000, limit, -limit]
            func near() -> Int64 { clamp(r.pick(anchors) &+ Int64(r.int(-2...2))) }
            var phraseStart = r.bool() ? near() : clamp(windowStart &+ Int64(r.int(-20_000...40_000)))
            var phraseEnd = r.int(0...3) == 0 ? near() : clamp(phraseStart &+ Int64(r.int(0...8000)))
            if k % 10 == 0 { swap(&phraseStart, &phraseEnd) }
            if k % 50 == 1 {
                phraseStart = r.int64(-limit...limit)
                phraseEnd = r.int64(-limit...limit)
            }
            let kind = k % 3 == 0 ? r.pick(kinds) : r.pick([F.voiceTTS, F.voiceOwn])
            let c = r.bool() ? r.pick(containments) : r.int(0...1000)
            let words = r.bool() ? r.pick(wordCounts) : r.int(0...30)
            check(kind, r.bool(), words, c, phraseStart, phraseEnd, windowStart, windowEnd)
        }
        log.finish(minimumCases: 500_000)
    }

    // MARK: - Hand cases from real calls

    @Test func handCases() {
        // Link and microphone.
        #expect(F.status(linkOn: true, connected: true, peers: 1, failures: 0) == F.statusLinked)
        #expect(F.status(linkOn: true, connected: true, peers: 0, failures: 0) == F.statusWaiting)
        #expect(F.status(linkOn: true, connected: false, peers: 0, failures: 3) == F.statusFailed)
        #expect(F.status(linkOn: false, connected: true, peers: 2, failures: 0) == F.statusOff)
        #expect((-1...6).map { F.reconnectDelayMs(attempt: $0) } == [500, 500, 1000, 2000, 4000, 8000, 8000, 8000])
        #expect(F.sendsMic(linkUp: true, muted: false, headphonesLike: false, keyHeld: true))
        #expect(!F.sendsMic(linkUp: true, muted: false, headphonesLike: false, keyHeld: false))
        #expect(F.vadSends(hasSignal: false, msSinceSignal: 599) && !F.vadSends(hasSignal: false, msSinceSignal: 600))
        #expect(F.sampleRate * Double(F.frameMs) / 1000 == 640)
        // The room and the connection.
        #expect((-1...7).map { F.acceptsNewPeer(knownPeers: $0) } == [false, true, true, true, true, true, false, false, false])
        #expect(F.roomFull(closeCode: F.closeRoomFull) && !F.roomFull(closeCode: 1006) && !F.roomFull(closeCode: 1000))
        #expect(F.retryDelayMs(closeCode: 4001, attempt: 0) == 15_000 && F.retryDelayMs(closeCode: 1006, attempt: 1) == 1000)
        // A voice that ended 600 ms before its frame left: 600 ms before the frame arrived, whatever the sender's clock.
        #expect(F.voiceLocalMs(atMs: 5_000_400, sentMs: 5_001_000, nowMs: 1_760_000_000_000) == 1_759_999_999_400)
        #expect(F.closeRoomFull == 4001 && F.stableMs == 3000 && F.voiceRefreshMs == 5000 && F.voiceStaleMs == 12_000)
        // Frames: the ±30 s edges and the Int64 extremes.
        #expect(F.maxSkewMs == 30_000)
        #expect(F.frameFresh(sentMs: 0, nowMs: 30_000) && F.frameFresh(sentMs: 0, nowMs: -30_000))
        #expect(!F.frameFresh(sentMs: 0, nowMs: 30_001) && !F.frameFresh(sentMs: 0, nowMs: -30_001))
        #expect(!F.frameFresh(sentMs: .min, nowMs: .max) && !F.frameFresh(sentMs: .max, nowMs: .min))
        #expect(F.frameFresh(sentMs: .max, nowMs: .max) && F.frameFresh(sentMs: .min, nowMs: .min))
        #expect(F.frameFresh(sentMs: .max - 30_000, nowMs: .max) && !F.frameFresh(sentMs: .max - 30_001, nowMs: .max))
        #expect(F.frameFresh(sentMs: .min, nowMs: .min + 30_000) && !F.frameFresh(sentMs: .min, nowMs: .min + 30_001))
        #expect(!F.frameFresh(sentMs: -1, nowMs: .max) && !F.frameFresh(sentMs: 0, nowMs: .min))
        // Sequence numbers.
        #expect(F.seqNewer(seq: 5, lastSeq: 4, hasLast: true))
        #expect(!F.seqNewer(seq: 4, lastSeq: 4, hasLast: true))
        #expect(!F.seqNewer(seq: 3, lastSeq: 4, hasLast: true))
        #expect(F.seqNewer(seq: 0, lastSeq: .max, hasLast: false))
        #expect(!F.seqNewer(seq: 0, lastSeq: .max, hasLast: true))
        #expect(F.seqNewer(seq: .max, lastSeq: .max - 1, hasLast: true))
        // The secret code.
        #expect(F.secretNormalized("ABCD efgh-JKMN") == "abcdefghjkmn")
        #expect(F.secretNormalized("abcd-efgh-jkm0") == nil)
        #expect(F.secretNormalized("  abcd_efgh_jkmn ") == "abcdefghjkmn")
        #expect(F.secretNormalized("abcd\tefgh\tjkmn") == nil)
        #expect(F.secretNormalized("abcd-efgh-jkm") == nil)
        #expect(F.secretNormalized("abcd-efgh-jkmnp") == nil)
        #expect(F.secretDisplay("abcdefghjkmn") == "abcd-efgh-jkmn")
        #expect(F.secretDisplay("abcd-efgh-jkmn") == "abcd-efgh-jkmn")
        #expect(F.secretDisplay("ABCDEFGHJKMN") == "ABCDEFGHJKMN")
        #expect(F.secretAlphabet == Array("23456789abcdefghjkmnpqrstuvwxyz".utf8))
        #expect(F.secretLength == 12 && F.secretGroup == 4 && F.kdfIterations == 200_000)
        // Words and containment: the recognizer caught only the tail of a 25-word TTS; all of the tail is in it.
        let tts = "Entao fica combinado assim: eu preparo tudo hoje a noite e voces podem revisar com calma e, se quiserem, "
            + "assinar o contrato amanha de manha."
        #expect(F.wordCount(tts) == 25)
        #expect(F.wordCount("o contrato amanha de manha") == 5)
        #expect(F.wordCount("Dez mil?") == 2 && F.wordCount("Sim.") == 1 && F.wordCount("... -- ?!") == 0 && F.wordCount("") == 0)
        #expect(F.wordCount("quinta-feira, d'água") == 4 && F.wordCount("Привет, как дела?") == 3)
        #expect(F.containmentMilli(phrase: "o contrato amanha de manha", said: tts) == 1000)
        #expect(F.containmentMilli(phrase: tts, said: "o contrato amanha de manha") == 200)
        #expect(F.containmentMilli(phrase: "o contrato amanhã de manhã",
                                   said: "Então fica combinado assim: eu preparo tudo hoje à noite e vocês podem revisar com "
                                       + "calma e, se quiserem, assinar o contrato amanhã de manhã.") == 1000)
        #expect(F.containmentMilli(phrase: "Podemos enviar o contrato amanha", said: "Voces podem enviar o contrato hoje?") == 600)
        // Another Ponte's owner speaking himself: window [10000, 12000], 60% of the phrase up to 300 ms past its end.
        #expect(F.isPeerVoice(kind: F.voiceOwn, isSelf: false, phraseWords: 4, containmentMilli: 0, phraseStartMs: 10_200,
                              phraseEndMs: 12_300, windowStartMs: 10_000, windowEndMs: 12_000))
        #expect(!F.isPeerVoice(kind: F.voiceOwn, isSelf: false, phraseWords: 4, containmentMilli: 0, phraseStartMs: 12_000,
                               phraseEndMs: 13_000, windowStartMs: 10_000, windowEndMs: 12_000))
        // Open windows: still playing, no end.
        #expect(F.isPeerVoice(kind: F.voiceOwn, isSelf: false, phraseWords: 1, containmentMilli: 0, phraseStartMs: 90_000,
                              phraseEndMs: 91_000, windowStartMs: 10_000, windowEndMs: -1))
        #expect(F.isPeerVoice(kind: F.voiceTTS, isSelf: true, phraseWords: 1, containmentMilli: 800, phraseStartMs: 90_000,
                              phraseEndMs: 91_000, windowStartMs: 10_000, windowEndMs: -1))
        #expect(!F.isPeerVoice(kind: F.voiceTTS, isSelf: false, phraseWords: 9, containmentMilli: 799, phraseStartMs: 90_000,
                               phraseEndMs: 91_000, windowStartMs: 10_000, windowEndMs: -1))
        #expect(!F.isPeerVoice(kind: 0, isSelf: false, phraseWords: 9, containmentMilli: 1000, phraseStartMs: 10_000,
                               phraseEndMs: 11_000, windowStartMs: 10_000, windowEndMs: -1))
        // Stale windows: an END of another Ponte was lost and no START came for more than 12 s: it ends at its last START.
        #expect(F.windowEndMs(endMs: -1, lastSeenMs: 10_000, nowMs: 22_000, refreshed: true) == -1)
        #expect(F.windowEndMs(endMs: -1, lastSeenMs: 10_000, nowMs: 22_001, refreshed: true) == 10_000)
        #expect(F.windowEndMs(endMs: 15_000, lastSeenMs: 10_000, nowMs: 99_000, refreshed: true) == 15_000)
        #expect(F.windowEndMs(endMs: 15_000, lastSeenMs: 10_000, nowMs: 99_000, refreshed: false) == 15_000)
        let stale = F.windowEndMs(endMs: -1, lastSeenMs: 10_000, nowMs: 40_000, refreshed: true)
        #expect(stale == 10_000)
        #expect(!F.isPeerVoice(kind: F.voiceOwn, isSelf: false, phraseWords: 2, containmentMilli: 0, phraseStartMs: 30_000,
                               phraseEndMs: 31_000, windowStartMs: 10_000, windowEndMs: stale))
        #expect(F.voiceStaleMs > 2 * Int64(F.voiceRefreshMs))
        #expect(F.containMinMilli == 800 && F.containSureMilli == 900 && F.ownOverlapPermille == 600)
        #expect(F.minWords == 3 && F.ownAfterMs == 300 && F.echoLagMs == 800)
    }

    /// The confirmed review findings of 2026-10-14: short Brazilian replies that repeat a word of the owner's last TTS
    /// were dropped for 15 s even with the link off; the «Свой голос» window with its 600 ms hangover and a 1.5 s tail
    /// dropped quick replies; this Ponte's own windows (no keepalive) went stale after 12 s.
    @Test func reviewCases() {
        func drops(_ kind: Int, isSelf: Bool, _ phrase: String, said: String = "", _ ps: Int64, _ pe: Int64,
                   window ws: Int64, _ we: Int64) -> Bool {
            let words = F.wordCount(phrase)
            let contained = kind == F.voiceTTS ? F.containmentMilli(phrase: phrase, said: said) : 0
            let f = F.isPeerVoice(kind: kind, isSelf: isSelf, phraseWords: words, containmentMilli: contained,
                                  phraseStartMs: ps, phraseEndMs: pe, windowStartMs: ws, windowEndMs: we)
            let l = L.isPeerVoice(kind: kind, isSelf: isSelf, phraseWords: L.wordCount(phrase),
                                  containmentMilli: kind == L.voiceTTS ? L.containmentMilli(phrase: phrase, said: said) : 0,
                                  phraseStartMs: ps, phraseEndMs: pe, windowStartMs: ws, windowEndMs: we)
            #expect(f == l, "\(phrase) | \(said)")
            return f
        }
        // The owner's TTS named a price; the Brazilian asked it back 2 s later: his own, for this Ponte and the others.
        let price = "O preco e dez mil reais"
        #expect(F.containmentMilli(phrase: "Dez mil?", said: price) == 1000 && F.wordCount("Dez mil?") == 2)
        #expect(!drops(F.voiceTTS, isSelf: true, "Dez mil?", said: price, 14_000, 14_800, window: 10_000, 12_000))
        #expect(!drops(F.voiceTTS, isSelf: false, "Dez mil?", said: price, 14_000, 14_800, window: 10_000, 12_000))
        // The same two words while the TTS plays are its echo.
        #expect(drops(F.voiceTTS, isSelf: true, "Dez mil?", said: price, 10_500, 11_500, window: 10_000, 12_000))
        #expect(drops(F.voiceTTS, isSelf: false, "Dez mil?", said: price, 10_500, 11_500, window: 10_000, 12_000))
        // "Sim, claro" right after the owner's own voice (its window already holds the 600 ms hangover): translated.
        #expect(!drops(F.voiceOwn, isSelf: false, "Sim, claro", 11_900, 13_200, window: 10_000, 11_500))
        #expect(!drops(F.voiceOwn, isSelf: true, "Sim, claro", 11_900, 13_200, window: 10_000, 11_500))
        // This Ponte's own voice (sent back by a laptop next to the owner) is matched like another Ponte's.
        #expect(drops(F.voiceOwn, isSelf: true, "Sim, claro", 10_200, 11_400, window: 10_000, 11_500))
        for start in stride(from: Int64(9_000), through: 30_000, by: 250) {
            for end: Int64 in [11_500, -1] {
                #expect(drops(F.voiceOwn, isSelf: true, "Sim, claro", start, start + 1300, window: 10_000, end)
                        == drops(F.voiceOwn, isSelf: false, "Sim, claro", start, start + 1300, window: 10_000, end))
            }
        }
        // Another Ponte's owner still speaking (open window): what is heard meanwhile is his.
        #expect(drops(F.voiceOwn, isSelf: false, "Sim, claro", 12_000, 14_000, window: 10_000, -1))
        // The four-word quick reply that repeats the TTS question (750) is translated at any time, by anyone's TTS.
        let question = "Podemos comecar agora?"
        #expect(F.containmentMilli(phrase: "Sim, podemos comecar agora", said: question) == 750)
        for start in stride(from: Int64(9_000), through: 30_000, by: 100) {
            for isSelf in [false, true] {
                #expect(!drops(F.voiceTTS, isSelf: isSelf, "Sim, podemos comecar agora", said: question, start, start + 1300,
                               window: 10_000, 11_500))
            }
        }
        // A five-word tail of a long TTS, fully contained, right after it: the TTS.
        let long = "Entao fica combinado assim: eu preparo tudo hoje a noite e voces podem revisar com calma e, se quiserem, "
            + "assinar o contrato amanha de manha."
        #expect(drops(F.voiceTTS, isSelf: true, "o contrato amanha de manha", said: long, 17_800, 19_000, window: 10_000, 17_500))
        #expect(drops(F.voiceTTS, isSelf: false, "o contrato amanha de manha", said: long, 17_800, 19_000, window: 10_000, 17_500))
        // Recognized 8 s later: another Ponte's TTS (the recognizer lags behind the call), not this Ponte's own echo.
        #expect(drops(F.voiceTTS, isSelf: false, "o contrato amanha de manha", said: long, 25_000, 26_500, window: 10_000, 17_500))
        #expect(!drops(F.voiceTTS, isSelf: true, "o contrato amanha de manha", said: long, 25_000, 26_500, window: 10_000, 17_500))
        // This Ponte's own window is never refreshed: a minute on it is still open, and its echo still dropped.
        let own = F.windowEndMs(endMs: -1, lastSeenMs: 10_000, nowMs: 70_000, refreshed: false)
        #expect(own == -1)
        #expect(F.windowEndMs(endMs: -1, lastSeenMs: 10_000, nowMs: 70_000, refreshed: true) == 10_000)
        #expect(drops(F.voiceTTS, isSelf: true, "Dez mil?", said: price, 69_000, 70_000, window: 10_000, own))
    }

    @Test func audioBackpressure() {
        let log = DiffLog("audioSends")
        log.check(F.maxAudioInFlight, L.maxAudioInFlight, "maxAudioInFlight")
        for n in -5...40 { log.check(F.audioSends(inFlight: n), L.audioSends(inFlight: n), "\(n)") }
        log.finish(minimumCases: 40)
    }

    /// The wire and the link's housekeeping (moved out of PeerLink, PeerSession and AppModel).
    @Test func wireAndHousekeeping() {
        let log = DiffLog("wire, voiceTextBytes, failures, admission, windows, gate")
        log.check([F.hdrBytes, F.vpText, F.frameSamples, F.voiceTextMax, F.tickMs], [L.hdrBytes, L.vpText, L.frameSamples, L.voiceTextMax, L.tickMs], "constants")
        log.check([F.roomSalt, F.keySalt], [L.roomSalt, L.keySalt], "salts")
        for n in Array(-5...70) + [Int.min, Int.max] {
            log.check(F.frameComplete(n), L.frameComplete(n), "\(n)")
            log.check(F.voiceComplete(n), L.voiceComplete(n), "\(n)")
            log.check(F.audioSamples(n), L.audioSamples(n), "\(n)")
            log.check(F.noteFits(n), L.noteFits(n), "\(n)")
            log.check(F.membersValid(n), L.membersValid(n), "\(n)")
            log.check(F.linkUp(status: n), L.linkUp(status: n), "\(n)")
            log.check(F.windowComparesText(kind: n), L.windowComparesText(kind: n), "\(n)")
            for roomFull in [false, true] {
                log.check(F.failuresAfterClose(n, roomFull: roomFull), L.failuresAfterClose(n, roomFull: roomFull), "\(n) \(roomFull)")
            }
            for members in -2...10 { log.check(F.membersMismatch(members: members, peers: n), L.membersMismatch(members: members, peers: n), "\(members) \(n)") }
        }
        for kind in UInt8.min...UInt8.max {
            for known in [false, true] { for peers in -1...7 {
                log.check(F.frameAdmitted(known: known, kind: kind, knownPeers: peers), L.frameAdmitted(known: known, kind: kind, knownPeers: peers), "\(known) \(kind) \(peers)")
            } }
            for new in [false, true] { log.check(F.answersHello(newPeer: new, kind: kind), L.answersHello(newPeer: new, kind: kind), "\(new) \(kind)") }
        }
        for state in -1...4 { for open in [false, true] { for same in [false, true] {
            log.check(F.windowRecord(state: state, hasOpen: open, sameText: same), L.windowRecord(state: state, hasOpen: open, sameText: same), "\(state) \(open) \(same)")
        } } }
        for sends in [false, true] { for was in [false, true] { log.check(F.micGateStep(sends: sends, wasSending: was), L.micGateStep(sends: sends, wasSending: was), "\(sends) \(was)") } }
        var r = DiffRandom(seed: 0xB1E)
        for _ in 0..<40_000 {
            let ms = r.bool() ? Int64(r.int(-1000...2000)) : Int64(bitPattern: r.next())
            log.check(F.peerSpeaking(msSinceFrame: ms), L.peerSpeaking(msSinceFrame: ms), "\(ms)")
            let end = r.bool() ? Int64(r.int(-10...100_000)) : Int64(bitPattern: r.next())
            let now = r.bool() ? end &+ Int64(r.int(-100...40_000)) : Int64(bitPattern: r.next())
            log.check(F.windowForgotten(windowEndMs: end, nowMs: now), L.windowForgotten(windowEndMs: end, nowMs: now), "\(end) \(now)")
            let x = r.float()
            log.check(F.sampleToInt16(x), L.sampleToInt16(x), "\(x)")
        }
        for x: Float in [0, -0.0, 1, -1, 0.5, -0.5, 1 / 32767, .nan, .infinity, -.infinity, 0.99999] {
            log.check(F.sampleToInt16(x), L.sampleToInt16(x), "\(x)")
        }
        // Texts at the limit with characters of 1 to 4 bytes falling across it.
        let pieces = ["a", "é", "ж", "€", "😀", " "]
        for _ in 0..<4_000 {
            var text = ""
            let target = r.int(3_990...4_010)
            while text.utf8.count < target { text += r.pick(pieces) }
            let bytes = Array(text.utf8)
            log.check(F.voiceTextBytes(bytes), L.voiceTextBytes(bytes), "\(bytes.count)")
        }
        for n in [0, 1, 3999, 4000, 4001, 4096, 5000] {
            let bytes = Array(repeating: UInt8(0x80), count: n)
            log.check(F.voiceTextBytes(bytes), L.voiceTextBytes(bytes), "continuations \(n)")
        }
        log.finish(minimumCases: 130_000)
    }

    // MARK: - Inputs

    /// The spec's own test texts (pe_fixture).
    static func fixtures() -> [[UInt8]] {
        (0..<Int64(PE_FX_COUNT)).map { index in
            var out = [UInt8](repeating: 0, count: Int(PE_TEXT_MAX))
            let n = Int(pe_fixture(index, &out))
            return Array(out[0..<n])
        }
    }

    static let portuguese = ["Oi", "oi", "olá", "Olá", "como", "você", "voce", "está", "esta", "Bom", "bom", "dia", "tudo",
                             "bem", "obrigado", "Obrigada", "reunião", "reuniao", "preço", "Preço", "ação", "então", "não",
                             "nao", "sim", "Sim", "São", "Paulo", "amanhã", "às", "é", "É", "à", "o", "a", "de", "que",
                             "coração", "Florianópolis", "café", "pão", "ÓTIMO", "AÇÃO", "proposta", "contrato", "entrega",
                             "semana", "Trinity", "Ponte", "Meet", "quinta-feira", "d'água", "pra", "tá", "né", "SIM",
                             "dez", "mil", "claro", "podemos", "começar", "agora"]
    static let russian = ["привет", "Привет", "как", "дела", "да", "нет", "цена", "доставка", "договор", "завтра", "ЁЛКА", "ёлка"]
    static let numbers = ["1", "2", "10", "2026", "5,4", "3.5", "100%", "R$15", "15h", "07:30", "1º", "2ª"]
    static let separators = [" ", " ", " ", " ", ", ", ". ", "! ", "? ", "?! ", "... ", "… ", " — ", " – ", " - ", "\n", "\t",
                             " (", ") ", " \"", "\" ", " '", "«", "» ", " “", "” ", ": ", "; ", "/", "\u{00A0}", " 👍 ",
                             " € ", "_", "+", "#", "@"]

    static func word(_ r: inout DiffRandom) -> String {
        switch r.int(0...9) {
        case 0: return r.pick(russian)
        case 1: return r.pick(numbers)
        default: return r.pick(portuguese)
        }
    }

    static func tokens(_ r: inout DiffRandom, count: Int) -> [String] { (0..<count).map { _ in word(&r) } }

    /// What a recognizer might make of a spoken text: the same words, case changed, words dropped, added, replaced
    /// or reordered, accents lost; or an unrelated text.
    static func variant(of a: [String], _ r: inout DiffRandom) -> [String] {
        var b = a
        switch r.int(0...7) {
        case 0: return tokens(&r, count: r.int(0...24))
        case 1: return b
        case 2: return b.map { r.bool() ? $0.lowercased() : $0.uppercased() }
        case 3: return b.map { $0.folding(options: .diacriticInsensitive, locale: nil) }
        case 4:
            if !b.isEmpty { for _ in 0..<r.int(1...max(1, b.count / 2)) { b.remove(at: r.int(0...(b.count - 1))); if b.isEmpty { break } } }
            return b
        case 5:
            for _ in 0..<r.int(1...4) { b.insert(word(&r), at: r.int(0...b.count)) }
            return b
        case 6:
            for i in b.indices where r.int(0...3) == 0 { b[i] = word(&r) }
            return b
        default:
            for i in b.indices.reversed() where i > 0 { b.swapAt(i, r.int(0...i)) }
            return b
        }
    }

    static func render(_ words: [String], _ r: inout DiffRandom) -> String {
        var s = r.int(0...5) == 0 ? r.pick(separators) : ""
        for (i, w) in words.enumerated() {
            s += w
            if i + 1 < words.count { s += r.pick(separators) }
        }
        if r.bool() { s += r.pick([".", "?", "!", "…", "", " "]) }
        return s
    }

    /// What this Ponte's recognizer may make of a Ponte's TTS (`said`): all of it or a piece of it (the tail, the
    /// head, the middle), changed as a recognizer changes words; a word in front of it ("Sim, podemos..."); or the
    /// Brazilian's own unrelated reply.
    static func heard(from said: [String], _ r: inout DiffRandom) -> [String] {
        var piece = said
        if !said.isEmpty, r.bool() {
            let first = r.int(0...(said.count - 1))
            let last = r.int(first...(said.count - 1))
            piece = Array(said[first...last])
        }
        switch r.int(0...5) {
        case 0: return tokens(&r, count: r.int(0...12))
        case 1: return [word(&r)] + piece
        default: return variant(of: piece, &r)
        }
    }

    static let secretSeparators = [" ", "-", "_", "  ", " - ", "--", "-", " "]
    static let foreignSeparators = ["\t", "\n", "–", "—", ".", "·", "\u{00A0}", "/", ":"]
    static let lookalikes: [Character] = ["0", "1", "i", "l", "o", "I", "L", "O", "é", "ж", "!", "ı"]
    static let nearSecretBytes: [UInt8] = Array("01iloILOAZ -_\t".utf8) + [0x80, 0xC3, 0xA9, 0xFF, 0x00]

    /// A secret code as someone types or pastes it: mostly 12 alphabet characters in either case with separators;
    /// sometimes a lookalike (0 1 i l o), a foreign separator, a non-ASCII letter, a character too few or too many, or
    /// a long run of spaces before it (past the 4096-byte cut).
    static func typedSecret(_ r: inout DiffRandom) -> String {
        let count = r.pick([12, 12, 12, 11, 13, r.int(0...20)])
        var s = r.int(0...5) == 0 ? r.pick(secretSeparators) : ""
        for i in 0..<count {
            var c = Character(Unicode.Scalar(r.pick(L.secretAlphabet)))
            if r.bool() { c = Character(c.uppercased()) }
            if r.int(0...40) == 0 { c = r.pick(lookalikes) }
            s.append(c)
            if i + 1 < count, r.int(0...3) == 0 {
                s += r.int(0...30) == 0 ? r.pick(foreignSeparators) : r.pick(secretSeparators)
            }
        }
        if r.int(0...5) == 0 { s += r.pick(secretSeparators) }
        if r.int(0...300) == 0 { s = String(repeating: " ", count: r.int(4070...4100)) + s }
        return s
    }
}

private extension Array {
    /// A seeded shuffle (Fisher-Yates with DiffRandom), so the run does not depend on system randomness.
    func shuffledDeterministically(_ r: inout DiffRandom) -> [Element] {
        var a = self
        for i in a.indices.reversed() where i > 0 { a.swapAt(i, r.int(0...i)) }
        return a
    }
}
