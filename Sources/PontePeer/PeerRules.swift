import PonteSpecs

/// Two Russians in one call hear each other without translation (owner's request 2026-10-13).
///
/// Each Russian runs Ponte; the Pontes meet through an end-to-end encrypted WebSocket relay, send each other the
/// owner's live Russian voice (16 kHz mono Int16 frames) and announce when their Portuguese speech (TTS or the
/// owner's own voice) plays into the call, so the other Ponte does not translate it back into Russian. Each Ponte keeps
/// the same windows of its own voice, so it does not translate its own TTS when the far side echoes it back. The room
/// and the key of the link come from a secret code only the Russians share (PBKDF2, `kdfIterations`), never from the
/// Meet code, which the Portuguese speaker has too.
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

    /// After this many failed connections in a row the link shows as failed (also: a full room).
    public static let failedAfter = Int(PE_FAILED_AFTER)

    /// Off, linked (connected with peers), waiting (connected, alone), failed (not connected after `failedAfter`
    /// failures in a row) or connecting.
    public static func status(linkOn: Bool, connected: Bool, peers: Int, failures: Int) -> Int {
        Int(pe_status(linkOn, connected, Int64(peers), Int64(failures)))
    }

    /// The wait before reconnect attempt `attempt` (0 is the first): 500, 1000, 2000, 4000, then 8000 ms.
    public static func reconnectDelayMs(attempt: Int) -> Int {
        Int(pe_reconnect_delay_ms(Int64(attempt)))
    }

    /// Failures reset only after the socket stayed open this long or a frame arrived.
    public static let stableMs = Int(PE_STABLE_MS)

    /// A HELLO goes out this often; a peer silent for `peerTimeoutMs` is gone.
    public static let helloEveryMs = Int(PE_HELLO_EVERY_MS)
    public static let peerTimeoutMs = Int(PE_PEER_TIMEOUT_MS)

    /// The peer's last HELLO came less than `peerTimeoutMs` ago (and not from the future).
    public static func peerAlive(msSinceHello: Int64) -> Bool { pe_peer_alive(msSinceHello) }

    /// A new peer is accepted while 0 to `maxPeers` - 2 peers are known.
    public static func acceptsNewPeer(knownPeers: Int) -> Bool { pe_accepts_new_peer(Int64(knownPeers)) }

    /// The relay has counted more connections than the known peers plus this Ponte for `unknownListenerMs`:
    /// someone in the room never announced himself.
    public static let unknownListenerMs = Int(PE_UNKNOWN_LISTENER_MS)
    public static func unknownListener(members: Int, peers: Int, msSinceMismatch: Int64) -> Bool {
        pe_unknown_listener(Int64(members), Int64(peers), msSinceMismatch)
    }

    /// The close code of a full room.
    public static let closeRoomFull = Int(PE_CLOSE_ROOM_FULL)
    /// After a full room the link tries again this much later (the relay drops a slept Mac's socket within 20 s).
    public static let roomFullRetryMs = Int(PE_ROOM_FULL_RETRY_MS)

    /// The relay closed the socket with `code` because the room was full.
    public static func roomFull(closeCode code: Int) -> Bool { pe_room_full(Int64(code)) }

    /// The wait before the next connection after the relay closed with `code` at failure `attempt` (0 is the first).
    public static func retryDelayMs(closeCode code: Int, attempt: Int) -> Int {
        Int(pe_retry_delay_ms(Int64(code), Int64(attempt)))
    }

    // MARK: - Secret code shared only among the Russians

    /// The bytes of a secret code: the digits 2-9 and the lowercase ASCII letters without i, l and o (no 0 1 i l o).
    public static let secretAlphabet: [UInt8] = {
        var out = [UInt8](repeating: 0, count: 64)
        let n = Int(pe_secret_alphabet(&out))
        return Array(out[0..<n])
    }()
    /// A code is `secretLength` bytes of `secretAlphabet`, shown in groups of `secretGroup` joined by "-".
    public static let secretLength = Int(PE_SECRET_LENGTH)
    public static let secretGroup = Int(PE_SECRET_GROUP)
    /// PBKDF2-HMAC-SHA256 iterations that derive the room and the link key from the normalized code.
    public static let kdfIterations = Int(PE_KDF_ITERATIONS)

    /// A typed or pasted code, normalized: ASCII A-Z folded to a-z, spaces, "-" and "_" removed; exactly `secretLength`
    /// bytes of `secretAlphabet` must remain, else nil. Only the first 4096 bytes are read.
    public static func secretNormalized(_ text: String) -> String? {
        secretNormalized(utf8: Array(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A normalized code in groups of `secretGroup` joined by "-" ("abcdefghjkmn" -> "abcd-efgh-jkmn"); anything that
    /// is not exactly `secretLength` alphabet bytes comes back unchanged.
    public static func secretDisplay(_ normalized: String) -> String {
        secretGroups(utf8: Array(normalized.utf8)).map { String(decoding: $0, as: UTF8.self) } ?? normalized
    }

    // MARK: - Frame freshness and replay

    /// A frame's clock may be this far from ours, either way.
    public static let maxSkewMs = Int64(PE_MAX_SKEW_MS)

    /// |nowMs - sentMs| <= `maxSkewMs` (any Int64 times, no overflow).
    public static func frameFresh(sentMs: Int64, nowMs: Int64) -> Bool { pe_frame_fresh(sentMs, nowMs) }

    /// When a peer's voice started or ended (`atMs`, its clock), on this Mac's clock: the gap to its frame's `sentMs`
    /// counted back from the arrival `nowMs`, so the two Macs' clocks need not agree.
    public static func voiceLocalMs(atMs: Int64, sentMs: Int64, nowMs: Int64) -> Int64 {
        pe_voice_local_ms(atMs, sentMs, nowMs)
    }

    /// No frame of that peer was taken yet, or this sequence number is above the last one taken.
    public static func seqNewer(seq: UInt32, lastSeq: UInt32, hasLast: Bool) -> Bool { pe_seq_newer(seq, lastSeq, hasLast) }

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

    /// Backpressure: one more audio frame may go to the socket (`inFlight` frames not yet sent).
    public static let maxAudioInFlight = Int(PE_MAX_AUDIO_IN_FLIGHT)
    public static func audioSends(inFlight: Int) -> Bool { pe_audio_sends(Int64(inFlight)) }

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

    // MARK: - Voice windows

    /// A sender re-sends START this often for every voice still playing.
    public static let voiceRefreshMs = Int(PE_VOICE_REFRESH_MS)
    /// A refreshed window not refreshed for longer than this ends where it was last seen.
    public static let voiceStaleMs = Int64(PE_VOICE_STALE_MS)
    /// Ended windows are kept this long, then forgotten.
    public static let windowKeepMs = Int64(PE_WINDOW_KEEP_MS)

    /// Where a voice window ends: `endMs` when announced (>= 0); else, for a `refreshed` window (another Ponte's, kept
    /// alive by repeated STARTs), `lastSeenMs` when that is more than `voiceStaleMs` before `nowMs`; else -1 (still
    /// open). A window that is not refreshed (this Ponte's own, recorded here) ends only by its END. Any Int64 times.
    public static func windowEndMs(endMs: Int64, lastSeenMs: Int64, nowMs: Int64, refreshed: Bool) -> Int64 {
        pe_window_end_ms(endMs, lastSeenMs, nowMs, refreshed)
    }

    // MARK: - Is a recognized phrase a Ponte's voice?

    /// The words of a text, exactly as `containmentMilli` counts them: ASCII case folded; a word is a run of ASCII
    /// letters and digits or of bytes from 0x80; the first 4096 bytes and 512 words.
    public static func wordCount(_ text: String) -> Int { wordCount(utf8: Array(text.utf8)) }

    /// How much of `phrase` is in `said`, 0...1000: 1000 * L / (words of phrase), L the longest common subsequence of
    /// the word sequences (words as in `wordCount`; the first 4096 bytes and 512 words of each); 0 when the phrase has
    /// no word.
    public static func containmentMilli(phrase: String, said: String) -> Int {
        containmentMilli(utf8: Array(phrase.utf8), Array(said.utf8))
    }

    /// A window starts `windowBeforeMs` early. After a TTS window, a phrase of at least `minWords` words is the TTS up
    /// to `windowAfterMs` after its end with `containMinMilli`; another Ponte's, up to `textWindowMs` with
    /// `containSureMilli`.
    public static let windowBeforeMs = Int64(PE_WINDOW_BEFORE_MS)
    public static let windowAfterMs = Int64(PE_WINDOW_AFTER_MS)
    public static let textWindowMs = Int64(PE_TEXT_WINDOW_MS)
    public static let containMinMilli = Int(PE_CONTAIN_MIN_MILLI)
    public static let containSureMilli = Int(PE_CONTAIN_SURE_MILLI)
    /// A phrase lies in a window when this share (thousandths) of its duration does.
    public static let ownOverlapPermille = Int(PE_OWN_OVERLAP_PERMILLE)
    /// After a TTS ended, only a phrase of at least this many words is matched to it by its words.
    public static let minWords = Int(PE_MIN_WORDS)
    /// The owner's own voice window counts this long past its end.
    public static let ownAfterMs = Int64(PE_OWN_AFTER_MS)
    /// A TTS window counts this long past its end for a phrase that mostly lies in it (the echo through the call).
    public static let echoLagMs = Int64(PE_ECHO_LAG_MS)

    /// Whether the phrase [phraseStartMs, phraseEndMs] (either order; at least 1 ms long) is a Ponte's voice announced
    /// as `kind` in the window [windowStartMs, windowEndMs] (windowEndMs < 0: still open, `windowEndMs(...)`).
    /// `isSelf`: the window is this Ponte's own (its voice echoed back by the far side); `phraseWords`: `wordCount` of
    /// the phrase; `containmentMilli`: how much of the phrase is in the TTS text (`containmentMilli`). The window starts
    /// `windowBeforeMs` early; "lies in" means at least `ownOverlapPermille` of the phrase's duration does.
    /// - Own voice: never this Ponte's; another Ponte's when the phrase lies in the window ending `ownAfterMs` late.
    /// - TTS, with at least `containMinMilli`: the phrase lies in the window ending `echoLagMs` late (any length); or it
    ///   has at least `minWords` words and meets the window ending `windowAfterMs` late; or, another Ponte's TTS only,
    ///   with at least `containSureMilli` and `minWords` words it meets the window ending `textWindowMs` late.
    /// - Any other kind: never. Times within ±2^62 (no overflow).
    public static func isPeerVoice(kind: Int, isSelf: Bool, phraseWords: Int, containmentMilli: Int, phraseStartMs: Int64,
                                   phraseEndMs: Int64, windowStartMs: Int64, windowEndMs: Int64) -> Bool {
        pe_is_peer_voice(Int64(kind), isSelf, Int64(phraseWords), Int64(containmentMilli), phraseStartMs, phraseEndMs,
                         windowStartMs, windowEndMs)
    }

    // MARK: - Bytes (the differential tests also pass invalid UTF-8)

    static func secretNormalized(utf8: [UInt8]) -> [UInt8]? {
        var t = PeerText(utf8)
        var out = [UInt8](repeating: 0, count: Int(PE_SECRET_LENGTH))
        let n = Int(pe_secret_normalized(&t.bytes, t.length, &out))
        return n == out.count ? out : nil
    }

    /// The groups of a normalized code; nil when the bytes are not one (shown unchanged).
    static func secretGroups(utf8: [UInt8]) -> [UInt8]? {
        var t = PeerText(utf8)
        var out = [UInt8](repeating: 0, count: 16)
        let n = Int(pe_secret_display(&t.bytes, t.length, &out))
        return n > 0 ? Array(out[0..<n]) : nil
    }

    static func secretDisplay(utf8: [UInt8]) -> [UInt8] { secretGroups(utf8: utf8) ?? utf8 }

    static func wordCount(utf8: [UInt8]) -> Int {
        var t = PeerText(utf8)
        return Int(pe_word_count(&t.bytes, t.length))
    }

    static func containmentMilli(utf8 phrase: [UInt8], _ said: [UInt8]) -> Int {
        var tp = PeerText(phrase)
        var ts = PeerText(said)
        return Int(pe_containment_milli(&tp.bytes, tp.length, &ts.bytes, ts.length))
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
