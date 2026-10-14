// Two Russians in one call (Specs/peer_rules.t27, through the PeerRules facade) against their Swift oracle
// (PeerRulesLegacy), bit for bit: exhaustive over flags and small integer ranges, seeded random elsewhere
// (Portuguese words with accents, punctuation, digits and Cyrillic; invalid bytes; texts beyond the buffers;
// times around every edge of a voice window), plus hand cases from real calls.
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
        log.check([F.frameMs, F.maxPeers, F.helloEveryMs, F.peerTimeoutMs, F.vadHangoverMs, F.jitterWindow],
                  [L.frameMs, L.maxPeers, L.helloEveryMs, L.peerTimeoutMs, L.vadHangoverMs, L.jitterWindow], "Int constants")
        log.check(F.browserTabPorts + [F.tabListTimeoutMs], L.browserTabPorts + [L.tabListTimeoutMs], "tab list")
        log.check([F.msgHello, F.msgAudio, F.msgVoice, F.msgBye], [L.msgHello, L.msgAudio, L.msgVoice, L.msgBye], "messages")
        log.check([F.voiceTTS, F.voiceOwn, F.voiceStart, F.voiceEnd], [L.voiceTTS, L.voiceOwn, L.voiceStart, L.voiceEnd], "voice codes")
        log.check([F.statusOff, F.statusConnecting, F.statusWaiting, F.statusLinked, F.statusFailed],
                  [L.statusOff, L.statusConnecting, L.statusWaiting, L.statusLinked, L.statusFailed], "status codes")
        log.check([F.jitterTargetMs, F.jitterMaxMs, F.jitterSlackMs], [L.jitterTargetMs, L.jitterMaxMs, L.jitterSlackMs], "jitter ms")
        log.check([F.windowBeforeMs, F.windowAfterMs, F.textWindowMs, F.windowKeepMs],
                  [L.windowBeforeMs, L.windowAfterMs, L.textWindowMs, L.windowKeepMs], "window ms")
        log.check([F.similarityMinMilli, F.similaritySureMilli], [L.similarityMinMilli, L.similaritySureMilli], "similarity thresholds")
        log.check([Int(PE_TEXT_MAX), Int(PE_WORDS_MAX)], [L.textMax, L.wordsMax], "text limits")
        log.check(Int(PE_PEER_TIMEOUT_MS), 3 * Int(PE_HELLO_EVERY_MS), "three HELLOs missed")
        log.finish(minimumCases: 10)
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

    /// wordSimilarityMilli over text pairs that range from equal to unrelated.
    @Test func wordSimilarity() {
        let log = DiffLog("wordSimilarityMilli")
        var r = DiffRandom(seed: 700)
        // The spec's own test texts, every pair.
        let fixtures = Self.fixtures()
        for a in fixtures {
            for b in fixtures {
                log.check(F.wordSimilarityMilli(utf8: a, b), L.wordSimilarityMilli(utf8: a, b), "fixtures")
            }
        }
        var distribution = [Int](repeating: 0, count: 11)
        for k in 0..<20_000 {
            let long = k % 100 == 0
            let a = Self.tokens(&r, count: long ? r.int(300...900) : r.int(0...24))
            let b = Self.variant(of: a, &r)
            let ta = Self.render(a, &r), tb = Self.render(b, &r)
            let f = F.wordSimilarityMilli(ta, tb)
            log.check(f, L.wordSimilarityMilli(ta, tb), "pair \(k): \(ta.prefix(200)) | \(tb.prefix(200))")
            if (0...1000).contains(f) { distribution[f / 100] += 1 }
        }
        // Any bytes, the shared random pieces, and texts beyond 4096 bytes or 512 words.
        for k in 0..<3000 {
            let a = r.bytes(maxCount: r.pick([20, 200, 5000]))
            let b = k % 2 == 0 ? r.bytes(maxCount: 200) : a.shuffledDeterministically(&r)
            log.check(F.wordSimilarityMilli(utf8: a, b), L.wordSimilarityMilli(utf8: a, b), "bytes \(k)")
            let sa = r.text(maxPieces: r.pick([10, 60, 400])), sb = r.text(maxPieces: 60)
            log.check(F.wordSimilarityMilli(sa, sb), L.wordSimilarityMilli(sa, sb), "pieces \(k)")
        }
        let many = String(repeating: "sim ", count: 700), some = String(repeating: "SIM, ", count: 300)
        log.check(F.wordSimilarityMilli(many, some), L.wordSimilarityMilli(many, some), "700 vs 300 words")
        log.check(F.wordSimilarityMilli(many, some), 2000 * 300 / 812, "first 512 words")
        let wide = String(repeating: "ж", count: 3000) + " fim", short = "fim"
        log.check(F.wordSimilarityMilli(wide, short), L.wordSimilarityMilli(wide, short), "beyond 4096 bytes")
        log.check(F.wordSimilarityMilli(wide, short), 0, "the word after 4096 bytes is not read")
        print("similarity deciles: \(distribution)")
        // The random pairs cover the whole range, not only 0 and 1000.
        #expect(distribution.filter { $0 > 100 }.count >= 8)
        log.finish(minimumCases: 26_000)
    }

    /// isPeerVoice around every edge of a voice window.
    @Test func peerVoice() {
        let log = DiffLog("isPeerVoice")
        var r = DiffRandom(seed: 1500)
        let kinds = [Int.min, -1, 0, 1, 2, 3, Int.max]
        let sims = [Int.min, -1, 0, 349, 350, 351, 699, 700, 701, 1000, Int.max]
        for k in 0..<30_000 {
            let start = Int64(r.pick([0, 1, 300, 10_000, r.int(0...10_000_000), r.int(-1_000_000...0), 1 << 61]))
            let end: Int64 = switch r.int(0...5) {
            case 0: -1
            case 1: Int64(r.int(-1_000_000 ... -1))
            case 2: 0
            case 3: start
            default: start + Int64(r.int(0...30_000))
            }
            let anchors: [Int64] = [start - 300, start, max(end, start) + 1500, max(end, start) + 15_000, end, start - 20_000]
            func near() -> Int64 { r.pick(anchors) + Int64(r.int(-2...2)) }
            var phraseStart = r.bool() ? near() : start + Int64(r.int(-20_000...40_000))
            var phraseEnd = r.bool() ? near() : phraseStart + Int64(r.int(0...8000))
            if k % 10 == 0 { swap(&phraseStart, &phraseEnd) }
            let kind = k % 3 == 0 ? r.pick(kinds) : r.pick([1, 2])
            let sim = r.bool() ? r.pick(sims) : r.int(0...1000)
            log.check(F.isPeerVoice(kind: kind, similarityMilli: sim, phraseStartMs: phraseStart, phraseEndMs: phraseEnd,
                                    windowStartMs: start, windowEndMs: end),
                      L.isPeerVoice(kind: kind, similarityMilli: sim, phraseStartMs: phraseStart, phraseEndMs: phraseEnd,
                                    windowStartMs: start, windowEndMs: end),
                      describe(kind, sim, phraseStart, phraseEnd, start, end))
        }
        log.finish(minimumCases: 30_000)
    }

    /// meetCode in titles, links and noise.
    @Test func meetCode() {
        let log = DiffLog("meetCode")
        var r = DiffRandom(seed: 3)
        var found = 0
        for text in Self.fixtures() {
            log.check(F.meetCode(utf8: text), L.meetCode(utf8: text), "fixture \(String(decoding: text, as: UTF8.self))")
        }
        for k in 0..<20_000 {
            let text = Self.meetText(&r)
            let f = F.meetCode(in: text)
            log.check(f, L.meetCode(in: text), "text \(k): \(text.prefix(200))")
            if f != nil { found += 1 }
        }
        for k in 0..<2000 {
            var bytes = r.bytes(maxCount: 100)
            if r.bool() { bytes += Array(Self.codeLike(&r).utf8) + r.bytes(maxCount: 10) }
            log.check(F.meetCode(utf8: bytes), L.meetCode(utf8: bytes), "bytes \(k)")
        }
        // A code across the 4096-byte cut, and right at its end.
        for at in 4075...4096 {
            var bytes = [UInt8](repeating: 0x20, count: at) + Array("abc-defg-hij".utf8)
            bytes += r.bool() ? [0x61] : [0x20]
            log.check(F.meetCode(utf8: bytes), L.meetCode(utf8: bytes), "code at \(at)")
        }
        print("meet codes found in \(found) of 20000 texts")
        #expect(found > 3000 && found < 17_000)
        log.finish(minimumCases: 22_000)
    }

    // MARK: - Hand cases from real calls

    @Test func handCases() {
        // The other Ponte said "Oi, como voce esta?"; this Ponte's recognizer heard "Oi como voce esta".
        let sim = F.wordSimilarityMilli("Oi, como voce esta?", "Oi como voce esta")
        #expect(sim == 1000 && sim >= F.similaritySureMilli)
        #expect(F.wordSimilarityMilli("Oi, como você está?", "oi como você está") == 1000)
        #expect(F.wordSimilarityMilli("Bom dia, tudo bem com você?", "bom dia tudo bem") == 800)
        #expect(F.wordSimilarityMilli("Obrigado pela reunião de hoje.", "Qual é o preço?") == 0)
        #expect(F.wordSimilarityMilli("", "...") == 0)
        // Inside the TTS window, and late (the recognizer lags) with a sure match.
        #expect(F.isPeerVoice(kind: F.voiceTTS, similarityMilli: sim, phraseStartMs: 10_200, phraseEndMs: 11_800,
                              windowStartMs: 10_000, windowEndMs: 11_500))
        #expect(F.isPeerVoice(kind: F.voiceTTS, similarityMilli: sim, phraseStartMs: 20_000, phraseEndMs: 21_000,
                              windowStartMs: 10_000, windowEndMs: 11_500))
        #expect(!F.isPeerVoice(kind: F.voiceTTS, similarityMilli: 600, phraseStartMs: 20_000, phraseEndMs: 21_000,
                               windowStartMs: 10_000, windowEndMs: 11_500))
        // The owner of the other Ponte spoke Portuguese himself («Свой голос»): any overlapping phrase is his.
        #expect(F.isPeerVoice(kind: F.voiceOwn, similarityMilli: 0, phraseStartMs: 12_900, phraseEndMs: 14_000,
                              windowStartMs: 10_000, windowEndMs: 11_500))
        #expect(!F.isPeerVoice(kind: F.voiceOwn, similarityMilli: 1000, phraseStartMs: 13_001, phraseEndMs: 14_000,
                               windowStartMs: 10_000, windowEndMs: 11_500))
        // Still playing: the window has no end yet.
        #expect(F.isPeerVoice(kind: F.voiceOwn, similarityMilli: 0, phraseStartMs: 90_000, phraseEndMs: 91_000,
                              windowStartMs: 10_000, windowEndMs: -1))
        #expect(F.isPeerVoice(kind: F.voiceTTS, similarityMilli: 350, phraseStartMs: 90_000, phraseEndMs: 91_000,
                              windowStartMs: 10_000, windowEndMs: -1))
        #expect(!F.isPeerVoice(kind: F.voiceTTS, similarityMilli: 349, phraseStartMs: 90_000, phraseEndMs: 91_000,
                               windowStartMs: 10_000, windowEndMs: -1))
        #expect(!F.isPeerVoice(kind: 0, similarityMilli: 1000, phraseStartMs: 10_000, phraseEndMs: 11_000,
                               windowStartMs: 10_000, windowEndMs: -1))
        // Meet window titles.
        #expect(F.meetCode(in: "Meet - kfs-cgvc-qrk") == "kfs-cgvc-qrk")
        #expect(F.meetCode(in: "Meet – KFS-CGVC-QRK - BrowserOS") == "kfs-cgvc-qrk")
        #expect(F.meetCode(in: "https://meet.google.com/abc-defg-hij?authuser=0") == "abc-defg-hij")
        #expect(F.meetCode(in: "Meet") == nil)
        #expect(F.meetCode(in: "xabc-defg-hij") == nil)
        #expect(F.meetCode(in: "abc-defg-hijk") == nil)
        #expect(F.meetCode(in: "abc-dégf-hij") == nil)
        #expect(F.meetCode(in: "Встреча abc-defg-hij2") == "abc-defg-hij")
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
                             "semana", "Trinity", "Ponte", "Meet", "quinta-feira", "d'água", "pra", "tá", "né", "SIM"]
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

    static let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// Letter groups joined by hyphens: mostly 3-4-3 (a code), sometimes a group too short or too long.
    static func codeLike(_ r: inout DiffRandom) -> String {
        let sizes = r.int(0...3) == 0 ? [r.int(2...5), r.int(3...5), r.int(2...4)] : [3, 4, 3]
        return sizes.map { n in String((0..<n).map { _ in r.int(0...20) == 0 ? r.pick(["é", "1", "ж", "_"]).first! : r.pick(letters) }) }
            .joined(separator: r.int(0...15) == 0 ? "_" : "-")
    }

    static func meetText(_ r: inout DiffRandom) -> String {
        let neighbours = ["", "", "", " ", "x", "Z", "1", "-", "ж", "é", "/", "?", "(", ")", ":", "_", "–", "  "]
        let parts = ["Meet - ", "Meet – ", " - BrowserOS", " - Google Chrome", "https://meet.google.com/", "?authuser=0",
                     "Reunião ", "Встреча ", "Zoom", "FaceTime", "(2) ", "abc", "-", "--", "a-b-c", "kfs-cgvc", "qrk"]
        var s = ""
        for _ in 0..<r.int(1...8) {
            switch r.int(0...4) {
            case 0, 1: s += r.pick(neighbours) + codeLike(&r) + r.pick(neighbours)
            case 2: s += r.pick(parts)
            case 3: s += word(&r) + r.pick(separators)
            default: s += String((0..<r.int(1...6)).map { _ in r.pick(letters) })
            }
        }
        if r.int(0...200) == 0 { s = String(repeating: "Meet ", count: 820) + s }
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
