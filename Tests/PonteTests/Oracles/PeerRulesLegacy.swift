// Test oracle for Specs/peer_rules.t27 (two Russians in one call hear each other). Written in plain Swift from the
// same rules, independently of the t27: words by splitting the folded bytes (the spec scans runs and caps as it goes);
// the secret code by folding, filtering and set membership (the spec scans with early exits); times in 128-bit
// integers, so no case analysis for overflow (the spec compares case by case and splits the permille product);
// containment by a full longest-common-subsequence table filled from the back over word identifiers (the spec keeps
// two rows of prefixes and compares bytes); the window end as an optional, and the phrase rule as a list of the
// spans a phrase may lie in or meet. The differential tests compare both implementations bit for bit.
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
    static let failedAfter = 3

    static let helloEveryMs = 5000
    static let peerTimeoutMs = 15_000
    static let vadHangoverMs = 600
    static let maxAudioInFlight = 6
    static func audioSends(inFlight: Int) -> Bool { inFlight >= 0 && inFlight < 6 }
    static let stableMs = 3000
    static let closeRoomFull = 4001
    static let roomFullRetryMs = 15_000

    static let jitterTargetMs = 120.0
    static let jitterMaxMs = 400.0
    static let jitterSlackMs = 40.0
    static let jitterWindow = 50
    /// The own-voice relay's codes (AudioRulesLegacy.relayKeep...relayRefill).
    static let jitterKeep = 0, jitterSend = 1, jitterDrop = 2, jitterTrim = 3, jitterRefill = 4

    /// The digits 2-9, then a-z without i, l and o.
    static let secretAlphabet: [UInt8] = Array(UInt8(ascii: "2")...UInt8(ascii: "9"))
        + Array(UInt8(ascii: "a")...UInt8(ascii: "z")).filter { !Array("ilo".utf8).contains($0) }
    static let secretLength = 12
    static let secretGroup = 4
    static let kdfIterations = 200_000
    static let maxSkewMs: Int64 = 30_000

    static let voiceRefreshMs = 5000
    static let voiceStaleMs: Int64 = 12_000
    static let windowKeepMs: Int64 = 20_000

    static let windowBeforeMs: Int64 = 300
    static let windowAfterMs: Int64 = 1500
    static let textWindowMs: Int64 = 15_000
    static let containMinMilli = 800
    static let containSureMilli = 900
    static let ownOverlapPermille = 600
    static let minWords = 3
    static let ownAfterMs: Int64 = 300
    static let echoLagMs: Int64 = 800

    static let textMax = 4096
    static let wordsMax = 512

    // MARK: - Link

    static func status(linkOn: Bool, connected: Bool, peers: Int, failures: Int) -> Int {
        guard linkOn else { return statusOff }
        switch (connected, peers) {
        case (true, let p) where p > 0: return statusLinked
        case (true, 0): return statusWaiting
        case (false, _) where failures >= failedAfter: return statusFailed
        default: return statusConnecting
        }
    }

    static func reconnectDelayMs(attempt: Int) -> Int {
        let delays = [500, 1000, 2000, 4000]
        if attempt < 0 { return delays[0] }
        return attempt < delays.count ? delays[attempt] : 8000
    }

    static func peerAlive(msSinceHello: Int64) -> Bool { (0..<Int64(peerTimeoutMs)).contains(msSinceHello) }

    static func acceptsNewPeer(knownPeers: Int) -> Bool { (0..<(maxPeers - 1)).contains(knownPeers) }

    static let unknownListenerMs = 6000
    /// AppModel/PeerPanel before the review: `members > peerCount + 1`, now held for 6 s.
    static func unknownListener(members: Int, peers: Int, msSinceMismatch: Int64) -> Bool {
        members >= 0 && peers >= 0 && Int128(members) - Int128(peers) > 1 && msSinceMismatch >= Int64(unknownListenerMs)
    }

    static func roomFull(closeCode code: Int) -> Bool { code == closeRoomFull }

    static func retryDelayMs(closeCode code: Int, attempt: Int) -> Int {
        roomFull(closeCode: code) ? roomFullRetryMs : reconnectDelayMs(attempt: attempt)
    }

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

    static func wordCount(_ text: String) -> Int { wordCount(utf8: Array(text.utf8)) }

    static func wordCount(utf8: [UInt8]) -> Int { words(utf8).count }

    // MARK: - Secret code

    private static let secretDropped: Set<UInt8> = [UInt8(ascii: " "), UInt8(ascii: "-"), UInt8(ascii: "_")]

    static func secretNormalized(_ text: String) -> String? {
        secretNormalized(utf8: Array(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func secretNormalized(utf8: [UInt8]) -> [UInt8]? {
        let kept = utf8.prefix(textMax).map(lower).filter { !secretDropped.contains($0) }
        guard isSecret(kept) else { return nil }
        return kept
    }

    private static func isSecret(_ bytes: [UInt8]) -> Bool {
        bytes.count == secretLength && Set(bytes).isSubset(of: Set(secretAlphabet))
    }

    static func secretDisplay(_ normalized: String) -> String {
        let bytes = Array(normalized.utf8)
        guard isSecret(bytes) else { return normalized }
        return String(decoding: secretDisplay(utf8: bytes), as: UTF8.self)
    }

    static func secretDisplay(utf8: [UInt8]) -> [UInt8] {
        guard isSecret(utf8) else { return utf8 }
        let groups = stride(from: 0, to: utf8.count, by: secretGroup).map { Array(utf8[$0..<Swift.min($0 + secretGroup, utf8.count)]) }
        return Array(groups.joined(separator: [UInt8(ascii: "-")]))
    }

    // MARK: - Freshness and replay

    static func frameFresh(sentMs: Int64, nowMs: Int64) -> Bool {
        (Int128(nowMs) - Int128(sentMs)).magnitude <= UInt128(maxSkewMs)
    }

    /// Swift integers widen the arithmetic: the gap is exact for any Int64 times.
    static func voiceLocalMs(atMs: Int64, sentMs: Int64, nowMs: Int64) -> Int64 {
        guard nowMs >= 0, atMs <= sentMs else { return nowMs }
        let gap = Int128(sentMs) - Int128(atMs)
        return gap > Int128(maxSkewMs) ? nowMs : nowMs - Int64(gap)
    }

    static func seqNewer(seq: UInt32, lastSeq: UInt32, hasLast: Bool) -> Bool {
        guard hasLast else { return true }
        return seq > lastSeq
    }

    // MARK: - Voice windows

    static func windowEndMs(endMs: Int64, lastSeenMs: Int64, nowMs: Int64, refreshed: Bool) -> Int64 {
        if endMs >= 0 { return endMs }
        // This Ponte's own windows get no keepalive and lose no END.
        guard refreshed else { return -1 }
        let silentFor = Int128(nowMs) - Int128(lastSeenMs)
        return silentFor > Int128(voiceStaleMs) ? lastSeenMs : -1
    }

    // MARK: - Containment

    static func containmentMilli(phrase: String, said: String) -> Int {
        containmentMilli(utf8: Array(phrase.utf8), Array(said.utf8))
    }

    static func containmentMilli(utf8 phrase: [UInt8], _ said: [UInt8]) -> Int {
        // Every distinct word gets a number, so the table compares integers.
        var ids: [[UInt8]: Int] = [:]
        func id(_ w: [UInt8]) -> Int {
            if let known = ids[w] { return known }
            ids[w] = ids.count
            return ids.count - 1
        }
        let p = words(phrase).map(id), s = words(said).map(id)
        if p.isEmpty { return 0 }
        // common[i * width + j]: the longest common subsequence of p[i...] and s[j...].
        let width = s.count + 1
        var common = [Int](repeating: 0, count: (p.count + 1) * width)
        for i in p.indices.reversed() {
            for j in s.indices.reversed() {
                common[i * width + j] = p[i] == s[j]
                    ? common[(i + 1) * width + j + 1] + 1
                    : Swift.max(common[(i + 1) * width + j], common[i * width + j + 1])
            }
        }
        return 1000 * common[0] / p.count
    }

    // MARK: - Is a recognized phrase a Ponte's voice?

    /// A stretch of time the phrase is tested against: from `from`, up to `until` (nil: no end).
    private struct Span {
        let from: Int128
        let until: Int128?
    }

    static func isPeerVoice(kind: Int, isSelf: Bool, phraseWords: Int, containmentMilli: Int, phraseStartMs: Int64,
                            phraseEndMs: Int64, windowStartMs: Int64, windowEndMs: Int64) -> Bool {
        let a = Int128(phraseStartMs), b = Int128(phraseEndMs)
        let start = Swift.min(a, b)
        let duration = Swift.max(Int128(1), Int128((a - b).magnitude))
        let end = start + duration
        let windowEnd: Int128? = windowEndMs < 0 ? nil : Int128(windowEndMs)
        /// The window from its early start up to `late` ms past its end.
        func span(late: Int64) -> Span {
            Span(from: Int128(windowStartMs) - Int128(windowBeforeMs), until: windowEnd.map { $0 + Int128(late) })
        }
        /// At least ownOverlapPermille of the phrase's time lies in the span.
        func liesIn(_ s: Span) -> Bool {
            let inside = Swift.max(0, Swift.min(end, s.until ?? end) - Swift.max(start, s.from))
            return inside * 1000 >= Int128(ownOverlapPermille) * duration
        }
        /// The phrase and the span touch: it ends at or after the span's start and starts at or before its end.
        func meets(_ s: Span) -> Bool { end >= s.from && (s.until.map { start <= $0 } ?? true) }
        let long = phraseWords >= minWords
        switch kind {
        case voiceOwn:
            return liesIn(span(late: ownAfterMs))
        case voiceTTS:
            let playing = containmentMilli >= containMinMilli && liesIn(span(late: echoLagMs))
            let justAfter = long && containmentMilli >= containMinMilli && meets(span(late: windowAfterMs))
            let lateFromPeer = !isSelf && long && containmentMilli >= containSureMilli && meets(span(late: textWindowMs))
            return playing || justAfter || lateFromPeer
        default:
            return false
        }
    }

    // MARK: - The wire and the link's housekeeping (PeerLink, PeerSession and AppModel before 2026-10-15)

    static let hdrBytes = 21
    static let vpText = 10
    static let frameSamples = 640
    static let voiceTextMax = 4000
    static let roomSalt = "ponte-room-v2"
    static let keySalt = "ponte-key-v2"
    static func frameComplete(_ len: Int) -> Bool { len >= 21 }
    static func voiceComplete(_ payloadLen: Int) -> Bool { payloadLen >= 10 }
    static func audioSamples(_ payloadLen: Int) -> Int { max(0, payloadLen) / 2 }
    /// The old encoder truncated `max(-1, min(1, x)) * 32767`; the rule now rounds half away from zero.
    static func sampleToInt16(_ x: Float) -> Int16 {
        let v: Float = x > 0 ? min(x, 1) : (x < 0 ? max(x, -1) : 0)
        return Int16((v * 32767).rounded(.toNearestOrAwayFromZero))
    }
    /// `text.utf8.prefix(4000)`, moved back to the start of a character the limit falls in.
    static func voiceTextBytes(_ utf8: [UInt8]) -> Int {
        guard utf8.count > voiceTextMax else { return utf8.count }
        var n = voiceTextMax
        while n > 0, utf8[n] & 0xC0 == 0x80 { n -= 1 }
        return n
    }
    static func noteFits(_ len: Int) -> Bool { (0...64).contains(len) }
    static func membersValid(_ n: Int) -> Bool { (0...64).contains(n) }
    /// `failures = max(failures + 1, failedAfter)` on a full room, else `failures += 1`.
    static func failuresAfterClose(_ failures: Int, roomFull: Bool) -> Int {
        let next = failures < 0 ? 1 : (failures >= 1 << 62 ? failures : failures + 1)
        return roomFull ? max(next, 3) : next
    }
    /// `if peers[peer] == nil, kind != msgBye, !acceptsNewPeer(..) { return }`.
    static func frameAdmitted(known: Bool, kind: UInt8, knownPeers: Int) -> Bool {
        known || kind == 4 || acceptsNewPeer(knownPeers: knownPeers)
    }
    static func answersHello(newPeer: Bool, kind: UInt8) -> Bool { newPeer && kind != 4 }
    static let tickMs = min(helloEveryMs, 5000)
    static func linkUp(status: Int) -> Bool { status == 3 }
    /// PeerVoices.speaking: `Date().timeIntervalSince(lastAt) < 0.5`.
    static func peerSpeaking(msSinceFrame: Int64) -> Bool { (0..<500).contains(msSinceFrame) }
    static func membersMismatch(members: Int, peers: Int) -> Bool {
        members >= 0 && peers >= 0 && Int128(members) - Int128(peers) > 1
    }
    /// PeerWindows.record: same text → refresh; new text → end and append; END → end.
    static func windowRecord(state: Int, hasOpen: Bool, sameText: Bool) -> Int {
        switch state {
        case 1: return hasOpen ? (sameText ? 1 : 2) : 3
        case 2: return hasOpen ? 4 : 0
        default: return 0
        }
    }
    /// `end >= 0 && ms - end > windowKeepMs`, without overflow.
    static func windowForgotten(windowEndMs: Int64, nowMs: Int64) -> Bool {
        windowEndMs >= 0 && Int128(nowMs) - Int128(windowEndMs) > 20_000
    }
    static func windowComparesText(kind: Int) -> Bool { kind == 1 }
    /// PeerMicGate.push: `if sends { send } else if wasSending { flush }`.
    static func micGateStep(sends: Bool, wasSending: Bool) -> Int { sends ? 1 : (wasSending ? 2 : 0) }
}
