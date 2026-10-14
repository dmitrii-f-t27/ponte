import PonteSpecs

/// Two Russians in one call hear each other without translation (owner's request 2026-10-13).
///
/// Each Russian runs Ponte; the Pontes meet through an end-to-end encrypted WebSocket relay, send each other the
/// owner's live Russian voice (16 kHz mono Int16 frames) and announce when their Portuguese speech (TTS or the
/// owner's own voice) plays into the call, so the other Ponte does not translate it back into Russian.
///
/// The decisions are written in t27 (`Specs/peer_rules.t27`) and compiled to C (`Sources/PonteSpecs`). This facade
/// only marshals: Bool and Int pass straight through as `bool` and `int64_t`, an optional queue becomes a flag and a
/// value, text goes into the fixed buffers the C takes (`PE_TEXT_MAX` bytes; a longer text is read up to there).
/// Constants come from the C `#define`s. The test oracle is `PeerRulesLegacy` (Tests/PonteTests/Oracles); the
/// differential tests compare both bit for bit. Times are milliseconds on one clock (no overflow within ±2^62).
public enum PeerRules {

    // MARK: - Audio between Pontes

    /// 16 kHz mono Int16 on the wire.
    public static let sampleRate: Double = PE_SAMPLE_RATE
    /// One frame on the wire, in milliseconds.
    public static let frameMs = Int(PE_FRAME_MS)
    /// The most Pontes in one room besides this one.
    public static let maxPeers = Int(PE_MAX_PEERS)

    // MARK: - Messages (the first byte of a relay message)

    public static let msgHello = UInt8(PE_MSG_HELLO)
    public static let msgAudio = UInt8(PE_MSG_AUDIO)
    public static let msgVoice = UInt8(PE_MSG_VOICE)
    public static let msgBye = UInt8(PE_MSG_BYE)

    /// What plays into the call: the Portuguese TTS of a translated phrase, or the owner's own voice.
    public static let voiceTTS = Int(PE_VOICE_TTS)
    public static let voiceOwn = Int(PE_VOICE_OWN)
    /// A voice window starts or ends.
    public static let voiceStart = Int(PE_VOICE_START)
    public static let voiceEnd = Int(PE_VOICE_END)

    // MARK: - Link

    public static let statusOff = Int(PE_STATUS_OFF)
    public static let statusConnecting = Int(PE_STATUS_CONNECTING)
    /// Connected to the relay, nobody else in the room yet.
    public static let statusWaiting = Int(PE_STATUS_WAITING)
    public static let statusLinked = Int(PE_STATUS_LINKED)
    public static let statusFailed = Int(PE_STATUS_FAILED)

    /// Off, linked (connected with peers), waiting (connected, alone), failed (not connected after 3 failures
    /// in a row) or connecting.
    public static func status(linkOn: Bool, connected: Bool, peers: Int, failures: Int) -> Int {
        Int(pe_status(linkOn, connected, Int64(peers), Int64(failures)))
    }

    /// The wait before reconnect attempt `attempt` (0 is the first): 500, 1000, 2000, 4000, then 8000 ms.
    public static func reconnectDelayMs(attempt: Int) -> Int {
        Int(pe_reconnect_delay_ms(Int64(attempt)))
    }

    /// A HELLO goes out this often; a peer silent for `peerTimeoutMs` is gone.
    public static let helloEveryMs = Int(PE_HELLO_EVERY_MS)
    public static let peerTimeoutMs = Int(PE_PEER_TIMEOUT_MS)

    /// The peer's last HELLO came less than `peerTimeoutMs` ago (and not from the future).
    public static func peerAlive(msSinceHello: Int64) -> Bool { pe_peer_alive(msSinceHello) }

    // MARK: - The microphone to the peers

    /// The link is up, the owner did not mute, and either headphones (open microphone) or the push-to-talk key
    /// is held (speakers would echo the peers back).
    public static func sendsMic(linkUp: Bool, muted: Bool, headphonesLike: Bool, keyHeld: Bool) -> Bool {
        pe_sends_mic(linkUp, muted, headphonesLike, keyHeld)
    }

    /// Frames keep going this long after the last frame with signal.
    public static let vadHangoverMs = Int(PE_VAD_HANGOVER_MS)

    /// A frame goes out when it has signal, or within `vadHangoverMs` after the last one that had.
    public static func vadSends(hasSignal: Bool, msSinceSignal: Int64) -> Bool {
        pe_vad_sends(hasSignal, msSinceSignal)
    }

    // MARK: - Jitter buffer of a peer's voice

    public static let jitterTargetMs: Double = PE_JITTER_TARGET_MS
    public static let jitterMaxMs: Double = PE_JITTER_MAX_MS
    public static let jitterSlackMs: Double = PE_JITTER_SLACK_MS
    public static let jitterWindow = Int(PE_JITTER_WINDOW)

    /// What the jitter buffer does with a new frame: the codes of `AudioRules.relayAction` (keep, send, drop, trim,
    /// refill) with the jitter constants. `pendingMs` includes the frame; `queuedMs` is what the output still has
    /// to play (nil: the output is not running); `lowMs` and `lowCount`: the lowest queue of the current window and
    /// how many frames it has seen.
    public static func jitterAction(filling: Bool, pendingMs: Double, queuedMs: Double?, lowMs: Double, lowCount: Int) -> Int {
        Int(pe_jitter_action(filling, pendingMs, queuedMs ?? 0, queuedMs != nil, lowMs, Int64(lowCount)))
    }

    /// A window of `jitterWindow` frames is complete.
    public static func jitterWindowEnds(lowCount: Int) -> Bool { pe_jitter_window_ends(Int64(lowCount)) }

    /// While trimming, the oldest frame goes as long as `jitterTargetMs` stay without it.
    public static func jitterTrims(pendingMs: Double, oldestMs: Double) -> Bool { pe_jitter_trims(pendingMs, oldestMs) }

    // MARK: - Is a recognized phrase a peer's voice?

    /// How alike two texts are, 0...1000: the Dice coefficient of their word multisets (ASCII case folded; a word
    /// is a run of ASCII letters and digits or of bytes from 0x80). The first 4096 bytes and 512 words count.
    public static func wordSimilarityMilli(_ a: String, _ b: String) -> Int {
        wordSimilarityMilli(utf8: Array(a.utf8), Array(b.utf8))
    }

    /// A voice window is widened by `windowBeforeMs` before and `windowAfterMs` after; a sure TTS match counts up
    /// to `textWindowMs` after its end. Ended windows are kept `windowKeepMs`.
    public static let windowBeforeMs = Int64(PE_WINDOW_BEFORE_MS)
    public static let windowAfterMs = Int64(PE_WINDOW_AFTER_MS)
    public static let textWindowMs = Int64(PE_TEXT_WINDOW_MS)
    public static let similarityMinMilli = Int(PE_SIMILARITY_MIN_MILLI)
    public static let similaritySureMilli = Int(PE_SIMILARITY_SURE_MILLI)
    public static let windowKeepMs = Int64(PE_WINDOW_KEEP_MS)

    /// Whether the phrase [phraseStartMs, phraseEndMs] is a peer's voice announced as `kind` (`voiceTTS` or
    /// `voiceOwn`) in the window [windowStartMs, windowEndMs] (windowEndMs < 0: still playing).
    public static func isPeerVoice(kind: Int, similarityMilli: Int, phraseStartMs: Int64, phraseEndMs: Int64,
                                   windowStartMs: Int64, windowEndMs: Int64) -> Bool {
        pe_is_peer_voice(Int64(kind), Int64(similarityMilli), phraseStartMs, phraseEndMs, windowStartMs, windowEndMs)
    }

    // MARK: - Google Meet code

    /// The first Google Meet code (xxx-xxxx-xxx, ASCII letters, no letter right before or after) in a text such as
    /// a window title, lowercase; nil if there is none.
    public static func meetCode(in text: String) -> String? {
        meetCode(utf8: Array(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Bytes (the differential tests also pass invalid UTF-8)

    static func wordSimilarityMilli(utf8 a: [UInt8], _ b: [UInt8]) -> Int {
        var ta = PeerText(a)
        var tb = PeerText(b)
        return Int(pe_word_similarity_milli(&ta.bytes, ta.length, &tb.bytes, tb.length))
    }

    static func meetCode(utf8: [UInt8]) -> [UInt8]? {
        var t = PeerText(utf8)
        var out = [UInt8](repeating: 0, count: Int(PE_MEET_CODE_LEN))
        let n = Int(pe_meet_code(&t.bytes, t.length, &out))
        return n == out.count ? out : nil
    }
}

/// A text in the fixed buffer the C takes: the first PE_TEXT_MAX bytes, with the whole text's length.
private struct PeerText {
    var bytes = [UInt8](repeating: 0, count: Int(PE_TEXT_MAX))
    let length: Int64

    init(_ utf8: [UInt8]) {
        let readable = min(utf8.count, bytes.count)
        bytes.replaceSubrange(0..<readable, with: utf8[0..<readable])
        length = Int64(utf8.count)
    }
}
