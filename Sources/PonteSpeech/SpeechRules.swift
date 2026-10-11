// Owned by the speech agent. See SPEC.md.
//
// SpeechRules — every pure decision of PonteSpeech, in one place.
//
// The decisions are written in t27 (Specs/segment_rules.t27, context_rules.t27, voice_rules.t27) and
// compiled to C (Sources/PonteSpecs). This facade only marshals: integers to and from Int64, UTF-8 text
// into the fixed buffers the C takes (SG_TEXT_MAX bytes for phrase text, VO_ID_MAX for voice IDs), and
// C codes back to Swift values. Constants come from the C #defines. The Swift that used to be here is
// the test oracle SpeechRulesLegacy (Tests/PonteTests/Oracles); the differential tests compare both.
// Units: times are integer milliseconds; audio level is RMS × 100 000; text is UTF-8 bytes.
// Domains: phrase texts up to SG_TEXT_MAX bytes (punctuationCode reads the last SG_TEXT_MAX bytes,
// cutByteIndex any length with maxBytes below SG_TEXT_MAX - 2); voice identifiers up to VO_ID_MAX bytes.
import PonteSpecs

public enum SpeechRules {

    // MARK: - Voice activity (level meter)

    /// Level meter window. The transcriber meters audio in windows of this length.
    public static let meterWindowMs = Int(SG_METER_WINDOW_MS)
    /// RMS 0.01 (about −40 dBFS) in level units (RMS × 100 000).
    public static let voiceThresholdLevel = Int(SG_VOICE_THRESHOLD_LEVEL)
    /// Effective threshold = max(voiceThresholdLevel, floor × 5 / 2).
    public static let noiseFloorFactorNumerator = Int(SG_NOISE_FLOOR_FACTOR_NUMERATOR)
    public static let noiseFloorFactorDenominator = Int(SG_NOISE_FLOOR_FACTOR_DENOMINATOR)
    /// The noise floor rises toward louder windows with this time constant.
    public static let noiseFloorRiseMs = Int(SG_NOISE_FLOOR_RISE_MS)
    /// Silences shorter than this do not split voice segments (gaps inside words).
    public static let minRecordedPauseMs = Int(SG_MIN_RECORDED_PAUSE_MS)

    /// Voice threshold for a noise floor given in milli-levels (level × 1000).
    public static func effectiveThreshold(floorMilli: Int) -> Int {
        Int(sg_effective_threshold(Int64(floorMilli)))
    }

    /// True when a meter window of `level` is voice.
    public static func isVoice(level: Int, floorMilli: Int) -> Bool {
        sg_is_voice(Int64(level), Int64(floorMilli))
    }

    /// Next noise floor (milli-levels): drops at once to a quieter window, rises slowly toward a louder one.
    public static func nextNoiseFloor(floorMilli: Int, hasFloor: Bool, level: Int, durationMs: Int) -> Int {
        Int(sg_next_noise_floor(Int64(floorMilli), hasFloor, Int64(level), Int64(durationMs)))
    }

    // MARK: - Phrase finalization

    /// Silence that ends a phrase. Speech has shorter pauses inside sentences.
    public static let endOfPhrasePauseMs = Int(SG_END_OF_PHRASE_PAUSE_MS)
    /// Audio kept after the voice stops, so the last word is not clipped.
    public static let trailingMarginMs = Int(SG_TRAILING_MARGIN_MS)
    /// Speech longer than this is cut at the next suitable pause.
    public static let maxPhraseMs = Int(SG_MAX_PHRASE_MS)
    /// A pause this long inside a long monologue is a cut point (clause and sentence pauses).
    public static let minPauseMs = Int(SG_MIN_PAUSE_MS)
    /// A gap between words this long counts after sentence-ending punctuation, or after `hardLimitMs`.
    public static let shortPauseMs = Int(SG_SHORT_PAUSE_MS)
    /// After this much speech any short pause is a cut point.
    public static let hardLimitMs = Int(SG_HARD_LIMIT_MS)
    /// After this much speech the phrase is cut at once, even inside a word.
    public static let absoluteLimitMs = Int(SG_ABSOLUTE_LIMIT_MS)
    /// Two cuts must be at least this far apart.
    public static let minCutSpacingMs = Int(SG_MIN_CUT_SPACING_MS)
    /// No audio for this long in the middle of a phrase: finalize what was heard.
    public static let stallTimeoutMs = Int(SG_STALL_TIMEOUT_MS)
    /// How often the transcriber's watchdog checks for a stalled source.
    public static let watchdogPeriodMs = Int(SG_WATCHDOG_PERIOD_MS)
    /// Silence fed to the analyzer after a stall cut (SpeechAnalyzer finalizes only once it has audio past the cut).
    public static let stallFlushSilenceMs = Int(SG_STALL_FLUSH_SILENCE_MS)

    /// `finalizeAction` results.
    public static let actionWait = Int(SG_ACTION_WAIT)
    /// The speaker stopped: silent for `endOfPhrasePauseMs`.
    public static let actionEndOfPhrase = Int(SG_ACTION_END_OF_PHRASE)
    /// Long monologue, cut in a pause.
    public static let actionMonologuePause = Int(SG_ACTION_MONOLOGUE_PAUSE)
    /// Monologue past `absoluteLimitMs` without any pause: cut now.
    public static let actionMonologueForced = Int(SG_ACTION_MONOLOGUE_FORCED)

    /// `finalizeAction` flags: something to finalize; the stream is closing; Ponte's own cuts are off.
    public static let flagHasContent = Int(SG_FLAG_HAS_CONTENT)
    public static let flagFinishing = Int(SG_FLAG_FINISHING)
    public static let flagCutsDisabled = Int(SG_FLAG_CUTS_DISABLED)

    /// `punctuationCode` results.
    public static let punctuationNone = Int(SG_PUNCTUATION_NONE)
    public static let punctuationClause = Int(SG_PUNCTUATION_CLAUSE)
    public static let punctuationSentence = Int(SG_PUNCTUATION_SENTENCE)

    /// Should the transcriber ask SpeechAnalyzer to finalize now? See `sg_finalize_action`.
    public static func finalizeAction(pauseMs: Int, speechMs: Int, punctuation: Int, lastCutAgoMs: Int,
                                      phraseAgeMs: Int, flags: Int) -> Int {
        Int(sg_finalize_action(Int64(pauseMs), Int64(speechMs), Int64(punctuation), Int64(lastCutAgoMs),
                               Int64(phraseAgeMs), Int64(flags)))
    }

    /// How far before "now" the cut lies: just after the voice stopped (plus `trailingMarginMs`).
    public static func cutBackoffMs(action: Int, pauseMs: Int) -> Int {
        Int(sg_cut_backoff_ms(Int64(action), Int64(pauseMs)))
    }

    // MARK: - Text classification (UTF-8 bytes)

    static func isSpace(_ b: UInt8) -> Bool { sg_is_space(b) }

    /// Punctuation at the end of the text, ignoring trailing spaces and closing quotes or brackets.
    public static func punctuationCode(utf8: [UInt8]) -> Int {
        var t = PhraseText(suffixOf: utf8)
        return Int(sg_punctuation_code(&t.bytes, t.length))
    }

    /// Words separated by ASCII whitespace.
    public static func wordCount(utf8: [UInt8]) -> Int {
        var t = PhraseText(utf8)
        return Int(sg_word_count(&t.bytes, t.length))
    }

    /// Shorter text is never a phrase.
    public static let minPhraseBytes = Int(SG_MIN_PHRASE_BYTES)

    /// At least `minPhraseBytes` and one letter or digit (see `sg_has_speech_content`).
    public static func hasSpeechContent(utf8: [UInt8]) -> Bool {
        var t = PhraseText(utf8)
        return sg_has_speech_content(&t.bytes, t.length)
    }

    /// The recognizer sometimes "hears" a few words in silence. Up to this many words…
    public static let hallucinationMaxWords = Int(SG_HALLUCINATION_MAX_WORDS)
    /// …over less than this much metered voice are dropped.
    public static let hallucinationMinVoiceMs = Int(SG_HALLUCINATION_MIN_VOICE_MS)

    /// `phraseAction` results.
    public static let phraseKeep = Int(SG_PHRASE_KEEP)
    public static let phraseDropHallucination = Int(SG_PHRASE_DROP_HALLUCINATION)
    public static let phraseDropNoContent = Int(SG_PHRASE_DROP_NO_CONTENT)

    /// Keep or drop a recognized phrase (partial or final), given its text and the voice
    /// the level meter measured inside its audio range.
    public static func phraseAction(utf8: [UInt8], voiceMs: Int) -> Int {
        var t = PhraseText(utf8)
        return Int(sg_phrase_action(&t.bytes, t.length, Int64(voiceMs)))
    }

    // MARK: - Cutting long text (UTF-8 byte index)

    /// Long finals are split into pieces of at most this many bytes for synthesis (first audio sooner).
    public static let speechChunkMaxBytes = Int(SG_SPEECH_CHUNK_MAX_BYTES)
    /// A piece is never shorter than this.
    public static let speechChunkMinBytes = Int(SG_SPEECH_CHUNK_MIN_BYTES)

    /// Where to cut a long text: a UTF-8 byte index in `minBytes…maxBytes` (the head is `utf8[0..<index]`).
    /// Text that fits returns `utf8.count`; see `sg_cut_byte_index`.
    public static func cutByteIndex(utf8: [UInt8], maxBytes: Int, minBytes: Int) -> Int {
        var t = PhraseText(utf8)
        let index = Int(sg_cut_byte_index(&t.bytes, t.length, Int64(maxBytes), Int64(minBytes)))
        return index == t.readable ? utf8.count : index
    }

    // MARK: - Translation context

    /// At most this many previous phrases go into the Claude prompt…
    public static let contextMaxPhrases = Int(CX_CONTEXT_MAX_PHRASES)
    /// …and at most this many bytes of them.
    public static let contextMaxBytes = Int(CX_CONTEXT_MAX_BYTES)

    /// How many of the newest previous phrases to send as context.
    /// - Parameter byteLengths: UTF-8 lengths of the previous phrases, oldest first.
    public static func contextCount(byteLengths: [Int]) -> Int {
        let listMax = Int(CX_CONTEXT_LIST_MAX)
        var lengths = [Int64](repeating: 0, count: listMax)
        let newest = byteLengths.suffix(listMax)
        for (i, length) in newest.enumerated() { lengths[i] = Int64(length) }
        return Int(cx_context_count(&lengths, Int64(newest.count)))
    }

    // MARK: - Translator choice and fallback

    public static let engineNone = Int(CX_ENGINE_NONE)
    public static let engineApple = Int(CX_ENGINE_APPLE)
    public static let engineClaude = Int(CX_ENGINE_CLAUDE)

    /// Translation error codes (`errorCode…`).
    public static let errorTimeout = Int(CX_ERROR_TIMEOUT)
    public static let errorNetwork = Int(CX_ERROR_NETWORK)
    public static let errorOverloaded = Int(CX_ERROR_OVERLOADED)            // HTTP 429, 5xx
    public static let errorRejected = Int(CX_ERROR_REJECTED)                // other HTTP 4xx: key, request
    public static let errorAssetsMissing = Int(CX_ERROR_ASSETS_MISSING)     // Apple language pack not downloaded
    public static let errorUnsupported = Int(CX_ERROR_UNSUPPORTED)
    public static let errorRefused = Int(CX_ERROR_REFUSED)                  // Claude stop_reason "refusal"
    public static let errorEmpty = Int(CX_ERROR_EMPTY)
    public static let errorOther = Int(CX_ERROR_OTHER)

    /// Attempts per phrase, all engines together.
    public static let maxTranslationAttempts = Int(CX_MAX_TRANSLATION_ATTEMPTS)

    /// `retryAction` results.
    public static let retryGiveUp = Int(CX_RETRY_GIVE_UP)
    public static let retrySame = Int(CX_RETRY_SAME)
    public static let retrySwitch = Int(CX_RETRY_SWITCH)

    /// The engine to try first.
    public static func primaryEngine(preferred: Int, appleReady: Bool, claudeAvailable: Bool) -> Int {
        Int(cx_primary_engine(Int64(preferred), appleReady, claudeAvailable))
    }

    /// The other engine, if it can be used.
    public static func fallbackEngine(failed: Int, appleReady: Bool, claudeAvailable: Bool) -> Int {
        Int(cx_fallback_engine(Int64(failed), appleReady, claudeAvailable))
    }

    /// Per-attempt time limit. On-device translation takes about 0.1–0.3 s once warm.
    public static func translationTimeoutMs(engine: Int) -> Int { Int(cx_translation_timeout_ms(Int64(engine))) }

    /// Error code for an HTTP status from the Claude API (0 = no response).
    public static func errorCode(httpStatus: Int) -> Int { Int(cx_error_code(Int64(httpStatus))) }

    /// After a failed attempt (`attempt` is 0-based): give up, retry the same engine, or switch.
    public static func retryAction(errorCode: Int, attempt: Int, fallback: Int) -> Int {
        Int(cx_retry_action(Int64(errorCode), Int64(attempt), Int64(fallback)))
    }

    // MARK: - Claude request shape

    /// Model id, ASCII bytes of "claude-haiku-5-5".
    public static func claudeModelID() -> [UInt8] { requestBytes { cx_claude_model_id($0) } }

    /// API version header, ASCII bytes of "2023-06-01".
    public static func anthropicVersion() -> [UInt8] { requestBytes { cx_anthropic_version($0) } }

    private static func requestBytes(_ write: (UnsafeMutablePointer<UInt8>) -> UInt32) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CX_TEXT_OUT_MAX))
        let n = out.withUnsafeMutableBufferPointer { Int(write($0.baseAddress!)) }
        return Array(out[0..<n])
    }

    /// Room for adaptive thinking plus a one-phrase answer.
    public static let claudeMaxTokens = Int(CX_CLAUDE_MAX_TOKENS)
    /// Effort codes: 0 low, 1 medium, 2 high. Low keeps the latency down.
    public static let claudeEffortCode = Int(CX_CLAUDE_EFFORT_CODE)
    /// URLRequest timeout; the router's per-attempt limit (`translationTimeoutMs`) is shorter.
    public static let claudeRequestTimeoutMs = Int(CX_CLAUDE_REQUEST_TIMEOUT_MS)

    // MARK: - Voices

    /// Quality codes, also AVSpeechSynthesisVoiceQuality raw values.
    public static let qualityCompact = Int(VO_QUALITY_COMPACT)
    public static let qualityEnhanced = Int(VO_QUALITY_ENHANCED)
    public static let qualityPremium = Int(VO_QUALITY_PREMIUM)

    /// AVSpeechSynthesisVoiceQuality raw value → quality code (unknown → compact).
    public static func voiceQualityCode(avQualityRaw: Int) -> Int { Int(vo_voice_quality_code(Int64(avQualityRaw))) }

    /// Novelty voices (Eddy, Flo, Reed…: "com.apple.eloquence.*") and the old
    /// "com.apple.speech.synthesis.voice.*" voices rank below regular voices.
    public static func isNoveltyVoice(identifierUTF8 id: [UInt8]) -> Bool {
        var buffer = [UInt8](repeating: 0, count: Int(VO_ID_MAX))
        let n = min(id.count, buffer.count)
        buffer.replaceSubrange(0..<n, with: id[0..<n])
        return vo_is_novelty_voice(&buffer, Int64(n))
    }

    /// Sort key, larger is better: quality first, then regular before novelty, then the position of the
    /// voice name in the preferred list for the language (`preferredIndex`, −1 if absent).
    public static func voiceRankKey(qualityCode: Int, isNovelty: Bool, preferredIndex: Int) -> Int {
        Int(vo_voice_rank_key(Int64(qualityCode), isNovelty, Int64(preferredIndex)))
    }

    // MARK: - Synthesis

    /// Rendering time limit for a phrase of `textBytes` UTF-8 bytes.
    public static func synthesisTimeoutMs(textBytes: Int) -> Int { Int(vo_synthesis_timeout_ms(Int64(textBytes))) }

    /// After `didFinish`, wait this long for a late buffer before completing.
    public static let synthesisEndGraceMs = Int(VO_SYNTHESIS_END_GRACE_MS)

    // MARK: - Speaking rate

    /// `AVSpeechUtteranceDefaultSpeechRate` (0.5) in thousandths.
    public static let defaultUtteranceRateMilli = Int(VO_DEFAULT_UTTERANCE_RATE_MILLI)
    /// Rate change, in thousandths of AVSpeechUtterance.rate, per 10 % of speaking speed.
    public static let utteranceRateMilliPer10Percent = Int(VO_UTTERANCE_RATE_MILLI_PER_10_PERCENT)

    /// AVSpeechUtterance.rate × 1000 for speaking at `ratePercent` of normal speed from `baseRateMilli`.
    public static func utteranceRateMilli(ratePercent: Int, baseRateMilli: Int) -> Int {
        Int(vo_utterance_rate_milli(Int64(ratePercent), Int64(baseRateMilli)))
    }
}

/// Phrase text for `segment_rules`: a buffer of `SG_TEXT_MAX` bytes and the length the C reads.
struct PhraseText {
    static let capacity = Int(SG_TEXT_MAX)

    var bytes = [UInt8](repeating: 0, count: capacity)
    /// The text length passed to the C (it reads at most `capacity` bytes).
    let length: Int64
    /// Bytes the C can read.
    let readable: Int

    /// The first `capacity` bytes; the length is the whole text's.
    init(_ utf8: [UInt8]) {
        readable = min(utf8.count, Self.capacity)
        bytes.replaceSubrange(0..<readable, with: utf8[0..<readable])
        length = Int64(utf8.count)
    }

    /// The last `capacity` bytes (for rules that read the end of the text).
    init(suffixOf utf8: [UInt8]) {
        let tail = utf8.suffix(Self.capacity)
        readable = tail.count
        bytes.replaceSubrange(0..<readable, with: tail)
        length = Int64(readable)
    }
}
