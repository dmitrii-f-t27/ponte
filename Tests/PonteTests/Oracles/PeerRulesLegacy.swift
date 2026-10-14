// Test oracle for Specs/peer_rules.t27 (two Russians in one call hear each other). Written in plain Swift from the
// same rules, independently of the t27: words by splitting and counting in a dictionary (the spec matches word by
// word), the Meet code by a regular expression over the byte shape of the text (the spec scans), the voice window
// with an optional end. The differential tests compare both implementations bit for bit.
import Foundation

enum PeerRulesLegacy {
    static let sampleRate = 16_000.0
    static let frameMs = 40
    static let maxPeers = 6

    static let msgHello: UInt8 = 1
    static let msgAudio: UInt8 = 2
    static let msgVoice: UInt8 = 3
    static let msgBye: UInt8 = 4
    static let voiceTTS = 1
    static let voiceOwn = 2
    static let voiceStart = 1
    static let voiceEnd = 2

    static let statusOff = 0
    static let statusConnecting = 1
    static let statusWaiting = 2
    static let statusLinked = 3
    static let statusFailed = 4

    static let helloEveryMs = 5000
    static let peerTimeoutMs = 15_000
    static let vadHangoverMs = 600

    static let jitterTargetMs = 120.0
    static let jitterMaxMs = 400.0
    static let jitterSlackMs = 40.0
    static let jitterWindow = 50
    /// The own-voice relay's codes (AudioRulesLegacy.relayKeep...relayRefill).
    static let jitterKeep = 0, jitterSend = 1, jitterDrop = 2, jitterTrim = 3, jitterRefill = 4

    static let windowBeforeMs: Int64 = 300
    static let windowAfterMs: Int64 = 1500
    static let textWindowMs: Int64 = 15_000
    static let similarityMinMilli = 350
    static let similaritySureMilli = 700
    static let windowKeepMs: Int64 = 20_000

    static let textMax = 4096
    static let wordsMax = 512

    // MARK: - Link

    static func status(linkOn: Bool, connected: Bool, peers: Int, failures: Int) -> Int {
        guard linkOn else { return statusOff }
        switch (connected, peers) {
        case (true, let p) where p > 0: return statusLinked
        case (true, 0): return statusWaiting
        case (false, _) where failures >= 3: return statusFailed
        default: return statusConnecting
        }
    }

    static func reconnectDelayMs(attempt: Int) -> Int {
        let delays = [500, 1000, 2000, 4000]
        if attempt < 0 { return delays[0] }
        return attempt < delays.count ? delays[attempt] : 8000
    }

    static func peerAlive(msSinceHello: Int64) -> Bool { (0..<Int64(peerTimeoutMs)).contains(msSinceHello) }

    // MARK: - Microphone

    static func sendsMic(linkUp: Bool, muted: Bool, headphonesLike: Bool, keyHeld: Bool) -> Bool {
        guard linkUp, !muted else { return false }
        return headphonesLike || keyHeld
    }

    static func vadSends(hasSignal: Bool, msSinceSignal: Int64) -> Bool {
        hasSignal || (0..<Int64(vadHangoverMs)).contains(msSinceSignal)
    }

    // MARK: - Jitter buffer

    static func jitterAction(filling: Bool, pendingMs: Double, queuedMs: Double?, lowMs: Double, lowCount: Int) -> Int {
        guard let queued = queuedMs else { return pendingMs > jitterTargetMs ? jitterTrim : jitterKeep }
        if filling { return pendingMs >= jitterTargetMs ? jitterSend : jitterKeep }
        if queued <= 0 { return jitterRefill }
        if queued + pendingMs > jitterMaxMs { return jitterDrop }
        if jitterWindowEnds(lowCount: lowCount), lowMs > jitterTargetMs + jitterSlackMs { return jitterDrop }
        return jitterSend
    }

    static func jitterWindowEnds(lowCount: Int) -> Bool { lowCount >= jitterWindow }

    static func jitterTrims(pendingMs: Double, oldestMs: Double) -> Bool { pendingMs - oldestMs >= jitterTargetMs }

    // MARK: - Words

    private static func isWordByte(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"): return true
        default: return b >= 0x80
        }
    }

    private static func lower(_ b: UInt8) -> UInt8 { (0x41...0x5A).contains(b) ? b | 0x20 : b }

    /// The words of a text as folded byte strings: the first textMax bytes, split at every non-word byte, the first
    /// wordsMax words.
    static func words(_ utf8: [UInt8]) -> [[UInt8]] {
        let folded = utf8.prefix(textMax).map(lower)
        return folded.split(whereSeparator: { !isWordByte($0) }).prefix(wordsMax).map { Array($0) }
    }

    static func wordSimilarityMilli(_ a: String, _ b: String) -> Int { wordSimilarityMilli(utf8: Array(a.utf8), Array(b.utf8)) }

    static func wordSimilarityMilli(utf8 a: [UInt8], _ b: [UInt8]) -> Int {
        let wa = words(a), wb = words(b)
        let total = wa.count + wb.count
        if total == 0 { return 0 }
        var countA: [[UInt8]: Int] = [:]
        var countB: [[UInt8]: Int] = [:]
        for w in wa { countA[w, default: 0] += 1 }
        for w in wb { countB[w, default: 0] += 1 }
        let common = countA.reduce(0) { sum, entry in sum + min(entry.value, countB[entry.key] ?? 0) }
        return 2000 * common / total
    }

    // MARK: - Peer voice

    static func isPeerVoice(kind: Int, similarityMilli: Int, phraseStartMs: Int64, phraseEndMs: Int64,
                            windowStartMs: Int64, windowEndMs: Int64) -> Bool {
        let end: Int64? = windowEndMs >= 0 ? windowEndMs : nil
        let earliest = windowStartMs - windowBeforeMs
        /// The phrase meets [earliest, end + slack] (no end while the window is open).
        func meets(slack: Int64) -> Bool {
            guard phraseEndMs >= earliest else { return false }
            guard let end else { return true }
            return phraseStartMs <= end + slack
        }
        if kind == voiceOwn { return meets(slack: windowAfterMs) }
        if kind == voiceTTS {
            let inside = meets(slack: windowAfterMs) && similarityMilli >= similarityMinMilli
            let sure = similarityMilli >= similaritySureMilli && meets(slack: textWindowMs)
            return inside || sure
        }
        return false
    }

    // MARK: - Meet code

    /// Every byte as one ASCII character: letters as "L", the hyphen as "-", anything else as ".".
    private static let codePattern = try! NSRegularExpression(pattern: "(?<!L)LLL-LLLL-LLL(?!L)")

    static func meetCode(in text: String) -> String? { meetCode(utf8: Array(text.utf8)).map { String(decoding: $0, as: UTF8.self) } }

    static func meetCode(utf8: [UInt8]) -> [UInt8]? {
        let t = Array(utf8.prefix(textMax))
        let shape = String(t.map { b -> Character in
            if (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) { return "L" }
            return b == 0x2D ? "-" : "."
        })
        let ns = shape as NSString
        guard let match = codePattern.firstMatch(in: shape, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return t[match.range.location..<(match.range.location + match.range.length)].map(lower)
    }
}
