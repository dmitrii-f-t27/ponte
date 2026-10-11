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
import PonteCore
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

    // MARK: - Rules moved here from the rest of PonteSpeech

    /// Language codes of segment_rules and voice_rules (the same numbers).
    public static let langPtBR = Int(SG_LANG_PT_BR)
    public static let langRu = Int(SG_LANG_RU)
    public static func langCode(_ lang: Lang) -> Int {
        switch lang {
        case .ptBR: return langPtBR
        case .ru: return langRu
        }
    }

    /// The SpeechAnalyzer module a language uses: SpeechTranscriber, or DictationTranscriber for Russian.
    public static let moduleSpeech = Int(SG_MODULE_SPEECH)
    public static let moduleDictation = Int(SG_MODULE_DICTATION)
    public static func transcriberKind(_ lang: Lang) -> Int { Int(sg_transcriber_kind(Int64(langCode(lang)))) }

    /// AppleTranscriber defaults: fast results (pt-BR) and Ponte's own cuts.
    public static let fastResultsDefault = SG_FAST_RESULTS_DEFAULT != 0
    public static let ownCutsDefault = SG_OWN_CUTS_DEFAULT != 0

    /// Seconds to whole milliseconds, rounded half away from zero (finite input).
    public static func millis(_ seconds: Double) -> Int { Int(sg_millis(seconds)) }

    /// Level units (RMS × 100 000, rounded) of a window's RMS.
    public static func level(rms: Float) -> Int { Int(sg_level_from_rms(rms)) }

    /// Frames in one meter window, and of the silence fed after a stall cut (at least 1).
    public static func meterWindowFrames(sampleRate: Double) -> Int { Int(sg_meter_window_frames(sampleRate)) }
    public static func stallSilenceFrames(sampleRate: Double) -> Int { Int(sg_stall_silence_frames(sampleRate)) }

    /// Arrival marks: trimmed when there are too many, to those ending in the last 120 s of audio.
    public static func trimsArrivals(count: Int) -> Bool { sg_trims_arrivals(Int64(count)) }
    public static func keepsArrival(audioEnd: Double, end: Double) -> Bool { sg_keeps_arrival(audioEnd, end) }
    /// The mark that tells when audio up to `t` arrived.
    public static func arrivalCovers(audioEnd: Double, t: Double) -> Bool { sg_arrival_covers(audioEnd, t) }

    /// Phrase measures for `finalizeAction`: where the phrase starts, the current pause, the speech so far.
    public static func measureStart(phraseStart: Double, voiceStart: Double?) -> Double {
        sg_measure_start(phraseStart, voiceStart != nil, voiceStart ?? 0)
    }
    public static func measurePause(now: Double, start: Double, silence: Double?) -> Double {
        sg_measure_pause(now, start, silence != nil, silence ?? 0)
    }
    public static func measureSpeech(now: Double, start: Double, silence: Double?) -> Double {
        sg_measure_speech(now, start, silence != nil, silence ?? 0)
    }

    /// `finalizeAction` flags of the transcriber's state.
    public static func finalizeFlags(hasVolatileText: Bool, lastVoiceEnd: Double, phraseStart: Double,
                                     finishing: Bool, cutsEnabled: Bool) -> Int {
        Int(sg_finalize_flags(hasVolatileText, lastVoiceEnd, phraseStart, finishing, cutsEnabled))
    }

    /// Milliseconds since the last cut, `Int.max` when there was none.
    public static func lastCutAgoMs(now: Double, lastCut: Double?) -> Int {
        Int(sg_last_cut_ago_ms(now, lastCut != nil, lastCut ?? 0))
    }

    /// Where the analyzer is told to finalize for a cut decided at `now`.
    public static func cutTime(now: Double, action: Int, pauseMs: Int) -> Double {
        sg_cut_time(now, Int64(action), Int64(pauseMs))
    }

    /// The watchdog's cut of a source that stopped mid-phrase. nil: no append yet / no cut yet.
    public static func stallCut(finishing: Bool, cutsEnabled: Bool, hasVolatileText: Bool, msSinceAppend: Int?,
                                msFedSinceCut: Int?) -> Bool {
        sg_stall_cut(finishing, cutsEnabled, hasVolatileText, msSinceAppend != nil, Int64(msSinceAppend ?? 0),
                     msFedSinceCut != nil, Int64(msFedSinceCut ?? 0))
    }

    /// A final was forced by a cut inside the phrase.
    public static func cutInPhrase(lastCut: Double?, phraseStart: Double) -> Bool {
        sg_cut_in_phrase(lastCut != nil, lastCut ?? 0, phraseStart)
    }

    /// What a final result emits.
    public static let eventNone = Int(SG_EVENT_NONE)
    public static let eventFinal = Int(SG_EVENT_FINAL)
    public static let eventDiscard = Int(SG_EVENT_DISCARD)
    public static func finalEvent(keep: Bool, partialShown: Bool) -> Int { Int(sg_final_event(keep, partialShown)) }
    public static func partialEvent(keep: Bool, changed: Bool) -> Bool { sg_partial_event(keep, changed) }

    /// The phrase start moves forward to a finite result time.
    public static func advancePhraseStart(_ phraseStart: Double, to t: Double) -> Double { sg_advance_phrase_start(phraseStart, t) }

    /// Phrase timing: where its audio starts and ends (first and last word, or the result range).
    public static func timingStart(firstWordStart: Double?, phraseStart: Double) -> Double {
        sg_timing_start(firstWordStart != nil, firstWordStart ?? 0, phraseStart)
    }
    public static func timingEnd(lastWordStart: Double?, lastWordEnd: Double, rangeEnd: Double, audioStart: Double,
                                 lastVoiceEnd: Double) -> Double {
        sg_timing_end(lastWordStart != nil, lastWordStart ?? 0, lastWordEnd, rangeEnd, audioStart, lastVoiceEnd)
    }
    public static func trimsTimings(count: Int) -> Bool { sg_trims_timings(Int64(count)) }

    /// A result range the level meter can measure, and a recognized word worth keeping.
    public static func rangeMeasurable(start: Double, end: Double) -> Bool { sg_range_measurable(start, end) }
    public static func timedWord(start: Double, end: Double, wordBytes: Int) -> Bool { sg_timed_word(start, end, Int64(wordBytes)) }

    /// VoiceActivity: what one meter window changes.
    public static let activityKeep = Int(SG_ACTIVITY_KEEP)
    public static let activitySilenceStarts = Int(SG_ACTIVITY_SILENCE_STARTS)
    public static let activityVoiceStarts = Int(SG_ACTIVITY_VOICE_STARTS)
    public static let activitySilenceEnds = Int(SG_ACTIVITY_SILENCE_ENDS)
    public static let activitySilenceEndsVoiceStarts = Int(SG_ACTIVITY_SILENCE_ENDS_VOICE_STARTS)
    public static let activitySegmentCloses = Int(SG_ACTIVITY_SEGMENT_CLOSES)
    public static func activityStep(voice: Bool, silenceStart: Double?, hasVoice: Bool, start: Double) -> Int {
        Int(sg_activity_step(voice, silenceStart != nil, silenceStart ?? 0, hasVoice, start))
    }
    /// Closed voice segments to drop from the front (the meter keeps the last 256).
    public static func segmentsToDrop(count: Int) -> Int { Int(sg_segments_to_drop(Int64(count))) }
    /// End of the open voice segment.
    public static func openSegmentEnd(voiceStart: Double, silenceStart: Double?, lastEnd: Double) -> Double {
        sg_open_segment_end(voiceStart, silenceStart != nil, silenceStart ?? 0, lastEnd)
    }
    /// Seconds of a voice segment inside a range.
    public static func overlapSeconds(lower: Double, upper: Double, rangeLower: Double, rangeUpper: Double) -> Double {
        sg_overlap_seconds(lower, upper, rangeLower, rangeUpper)
    }

    /// AudioConversion: output capacity, frames drained at the end, input statuses
    /// (AVAudioConverterInputStatus raw values).
    public static func conversionCapacity(frames: Int, fromRate: Double, toRate: Double) -> Int {
        Int(sg_conversion_capacity(Int64(frames), fromRate, toRate))
    }
    public static let flushFrames = Int(SG_FLUSH_FRAMES)
    public static let inputHaveData = Int(SG_INPUT_HAVE_DATA)
    public static let inputNoDataNow = Int(SG_INPUT_NO_DATA_NOW)
    public static let inputEndOfStream = Int(SG_INPUT_END_OF_STREAM)
    public static func converterInput(fed: Bool, final: Bool) -> Int { Int(sg_converter_input(fed, final)) }

    /// Frames an RMS window reads: `count` (or the whole buffer) from `from`; 0 when nothing.
    public static func windowCount(from: Int, count: Int?, frameLength: Int) -> Int {
        Int(sg_window_count(Int64(from), count != nil, Int64(count ?? 0), Int64(frameLength)))
    }
    public static func int16ToFloat(_ v: Int16) -> Float { sg_int16_to_float(v) }
    public static func int32ToFloat(_ v: Int32) -> Float { sg_int32_to_float(v) }

    /// sum + Σ v² over the samples in order, in Float (blocks of SG_RMS_BLOCK).
    public static func sumSquares(_ samples: [Float], sum: Float = 0) -> Float {
        let block = Int(SG_RMS_BLOCK)
        var scratch = [Float](repeating: 0, count: block)
        var total = sum
        var at = 0
        while at < samples.count {
            let n = min(block, samples.count - at)
            scratch.replaceSubrange(0..<n, with: samples[at..<(at + n)])
            total = sg_sum_squares_f32(&scratch, Int64(n), total)
            at += n
        }
        return total
    }
    /// √(sum / count) in Float.
    public static func rms(sumOfSquares: Float, count: Int) -> Float { sg_rms_f32(sumOfSquares, Int64(count)) }

    /// ClaudeRequestBuilder: the effort name for a code (clamped to low…high), and a 2xx status.
    public static func effortName(code: Int) -> String {
        var out = [UInt8](repeating: 0, count: Int(CX_TEXT_OUT_MAX))
        let n = Int(cx_effort_name(Int64(code), &out))
        return String(decoding: out[0..<n], as: UTF8.self)
    }
    public static func httpSuccess(status: Int) -> Bool { cx_http_success(Int64(status)) }

    /// RoutingTranslator rules.
    public static func preferredEngine(preferClaude: Bool) -> Int { Int(cx_preferred_engine(preferClaude)) }
    public static func rethrowsClaudeError(appleFailed: Bool, hasApple: Bool) -> Bool { cx_rethrows_claude_error(appleFailed, hasApple) }
    public static func emptyTranslation(resultEmpty: Bool, inputEmpty: Bool) -> Bool { cx_empty_translation(resultEmpty, inputEmpty) }
    public static func forgetsAppleReady(engine: Int, errorCode: Int) -> Bool { cx_forgets_apple_ready(Int64(engine), Int64(errorCode)) }
    public static func hasTimeout(ms: Int) -> Bool { cx_has_timeout(Int64(ms)) }

    /// The kind of a translator error (RoutingTranslator reads the Swift error type into these).
    public static let kindOther = Int(CX_KIND_OTHER)
    public static let kindTimeout = Int(CX_KIND_TIMEOUT)
    public static let kindAssetsMissing = Int(CX_KIND_ASSETS_MISSING)
    public static let kindUnsupported = Int(CX_KIND_UNSUPPORTED)
    public static let kindCloudRequest = Int(CX_KIND_CLOUD_REQUEST)
    public static let kindKeyMissing = Int(CX_KIND_KEY_MISSING)
    public static let kindRefused = Int(CX_KIND_REFUSED)
    public static let kindEmpty = Int(CX_KIND_EMPTY)
    public static let kindURL = Int(CX_KIND_URL)
    public static func errorCode(kind: Int, httpStatus: Int) -> Int { Int(cx_error_code_for_kind(Int64(kind), Int64(httpStatus))) }

    /// AppleTranslator.prepare: the pack status (LanguageAvailability.Status) and what follows from it.
    public static let availInstalled = Int(CX_AVAIL_INSTALLED)
    public static let availSupported = Int(CX_AVAIL_SUPPORTED)
    public static let availUnsupported = Int(CX_AVAIL_UNSUPPORTED)
    public static let availUnknown = Int(CX_AVAIL_UNKNOWN)
    public static let packReady = Int(CX_PACK_READY)
    public static let packMissing = Int(CX_PACK_MISSING)
    public static let packUnavailable = Int(CX_PACK_UNAVAILABLE)
    public static func packResult(status: Int) -> Int { Int(cx_pack_result(Int64(status))) }

    /// VoiceRanking: the preferred voice names of a language, best first.
    public static func preferredVoiceNames(_ lang: Lang) -> [String] {
        let code = Int64(langCode(lang))
        var out = [UInt8](repeating: 0, count: Int(VO_ID_MAX))
        return (0..<vo_preferred_count(code)).map { i in
            let n = Int(vo_preferred_name(code, i, &out))
            return String(decoding: out[0..<n], as: UTF8.self)
        }
    }

    /// VoiceRanking order: `nameOrder` and `idOrder` compare a with b (-1 before, 0 equal, 1 after).
    public static func voiceBefore(keyA: Int, keyB: Int, nameOrder: Int, idOrder: Int) -> Bool {
        vo_voice_before(Int64(keyA), Int64(keyB), Int64(nameOrder), Int64(idOrder))
    }

    /// Which voice speaks.
    public static let voiceSourceSaved = Int(VO_SOURCE_SAVED)
    public static let voiceSourceBest = Int(VO_SOURCE_BEST)
    public static let voiceSourceLanguage = Int(VO_SOURCE_LANGUAGE)
    public static func voiceSource(hasSaved: Bool, hasBest: Bool) -> Int { Int(vo_voice_source(hasSaved, hasBest)) }

    /// The utterance rate: whether it is set, the base in thousandths, and the AVSpeechUtterance value.
    public static func setsRate(rate: Float?, ratePercent: Int) -> Bool { vo_sets_rate(rate != nil, Int64(ratePercent)) }
    public static func baseRateMilli(rate: Float?) -> Int { Int(vo_base_rate_milli(rate != nil, rate ?? 0)) }
    public static func utteranceRate(milli: Int) -> Float { vo_utterance_rate(Int64(milli)) }
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
