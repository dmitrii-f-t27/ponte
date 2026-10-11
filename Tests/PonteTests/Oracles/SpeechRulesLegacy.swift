// Test oracle, owned by the t27 agent. The Swift SpeechRules as it was before its bodies called the C generated from Specs/*.t27.
// Kept verbatim (only renamed) as the reference the differential tests compare the C-backed
// facade with, function by function, bit for bit.

// Owned by the speech agent. See SPEC.md.
//
// SpeechRulesLegacy — every pure decision of PonteSpeech, in one place.
//
// The decisions are specified in t27 (Specs/*.t27) and compiled to C. At integration the bodies
// below are replaced by calls into the generated C; these Swift versions stay as test oracles.
// Rules for this file:
//   - plain static functions and constants; inputs and outputs are integers, Bools or UTF-8 byte arrays;
//   - times are integer milliseconds; audio level is RMS × 100 000 (0…100 000); text is UTF-8 bytes;
//   - no Russian or Portuguese text here; prompts and JSON stay in Swift;
//   - deterministic: no clocks, no randomness, no globals that change.
// Integer ranges: products below fit in 64-bit (t27: use i64 for levels × durations).

enum SpeechRulesLegacy {

    // MARK: - Voice activity (level meter)

    /// Level meter window. The transcriber meters audio in windows of this length.
    static let meterWindowMs = 20
    /// RMS 0.01 (about −40 dBFS) in level units (RMS × 100 000).
    static let voiceThresholdLevel = 1_000
    /// Effective threshold = max(voiceThresholdLevel, floor × 5 / 2).
    static let noiseFloorFactorNumerator = 5
    static let noiseFloorFactorDenominator = 2
    /// The noise floor rises toward louder windows with this time constant.
    static let noiseFloorRiseMs = 60_000
    /// Silences shorter than this do not split voice segments (gaps inside words).
    static let minRecordedPauseMs = 60

    /// Voice threshold for a noise floor given in milli-levels (level × 1000).
    static func effectiveThreshold(floorMilli: Int) -> Int {
        max(voiceThresholdLevel, floorMilli * noiseFloorFactorNumerator / (noiseFloorFactorDenominator * 1000))
    }

    /// True when a meter window of `level` is voice.
    static func isVoice(level: Int, floorMilli: Int) -> Bool {
        level >= effectiveThreshold(floorMilli: floorMilli)
    }

    /// Next noise floor (milli-levels): drops at once to a quieter window, rises slowly toward a louder one.
    static func nextNoiseFloor(floorMilli: Int, hasFloor: Bool, level: Int, durationMs: Int) -> Int {
        let target = level * 1000
        if !hasFloor || target < floorMilli { return target }
        let d = min(max(durationMs, 0), noiseFloorRiseMs)
        return floorMilli + (target - floorMilli) * d / noiseFloorRiseMs
    }

    // MARK: - Phrase finalization

    /// Silence that ends a phrase. Speech has shorter pauses inside sentences.
    static let endOfPhrasePauseMs = 600
    /// Audio kept after the voice stops, so the last word is not clipped.
    static let trailingMarginMs = 150
    /// Speech longer than this is cut at the next suitable pause.
    static let maxPhraseMs = 6_000
    /// A pause this long inside a long monologue is a cut point (clause and sentence pauses).
    static let minPauseMs = 150
    /// A gap between words this long counts after sentence-ending punctuation, or after `hardLimitMs`.
    static let shortPauseMs = 80
    /// After this much speech any short pause is a cut point.
    static let hardLimitMs = 9_000
    /// After this much speech the phrase is cut at once, even inside a word.
    static let absoluteLimitMs = 12_000
    /// Two cuts must be at least this far apart.
    static let minCutSpacingMs = 100
    /// No audio for this long in the middle of a phrase: finalize what was heard.
    static let stallTimeoutMs = 1_000
    /// How often the transcriber's watchdog checks for a stalled source.
    static let watchdogPeriodMs = 250
    /// Silence fed to the analyzer after a stall cut. SpeechAnalyzer finalizes only once it has
    /// audio past the cut (measured 2026-10-11: with nothing after it, the final waited for `finish()`).
    static let stallFlushSilenceMs = 500

    /// `finalizeAction` results.
    static let actionWait = 0
    /// The speaker stopped: silent for `endOfPhrasePauseMs`.
    static let actionEndOfPhrase = 1
    /// Long monologue, cut in a pause.
    static let actionMonologuePause = 2
    /// Monologue past `absoluteLimitMs` without any pause: cut now.
    static let actionMonologueForced = 3

    /// `finalizeAction` flags.
    /// There is something to finalize: volatile text, or voice the analyzer has not reported yet.
    static let flagHasContent = 1
    /// The stream is closing; the analyzer finalizes by itself.
    static let flagFinishing = 2
    /// Ponte's own cuts are switched off (diagnostics: the analyzer alone decides).
    static let flagCutsDisabled = 4

    /// `punctuationCode` results.
    static let punctuationNone = 0
    static let punctuationClause = 1
    static let punctuationSentence = 2

    /// Should the transcriber ask SpeechAnalyzer to finalize now?
    ///
    /// Measured on this Mac: `SpeechAnalyzer.finalize(through:)` finalizes everything it has
    /// received, so a cut always happens at "now"; it must happen while the speaker is in a pause.
    /// - Parameters:
    ///   - pauseMs: length of the current silence, 0 while someone speaks (or if the silence began
    ///     before this phrase's speech).
    ///   - speechMs: speech in this phrase: from its first voice to the start of the current silence,
    ///     or to now while speaking.
    ///   - punctuation: `punctuationCode` of the volatile text.
    ///   - lastCutAgoMs: time since the last requested cut (`Int.max` if none).
    ///   - phraseAgeMs: time since the current phrase began (end of the previous final).
    ///   - flags: `flagHasContent` | `flagFinishing` | `flagCutsDisabled`.
    /// - Returns: `actionWait`, `actionEndOfPhrase`, `actionMonologuePause` or `actionMonologueForced`.
    static func finalizeAction(pauseMs: Int, speechMs: Int, punctuation: Int, lastCutAgoMs: Int,
                                      phraseAgeMs: Int, flags: Int) -> Int {
        guard flags & flagHasContent != 0, flags & flagFinishing == 0, flags & flagCutsDisabled == 0 else {
            return actionWait
        }
        var action = actionWait
        if pauseMs <= 0 {
            if speechMs >= absoluteLimitMs { action = actionMonologueForced }
        } else if pauseMs >= endOfPhrasePauseMs {
            action = actionEndOfPhrase
        } else if speechMs >= maxPhraseMs {
            if pauseMs >= minPauseMs {
                action = actionMonologuePause
            } else if pauseMs >= shortPauseMs && (punctuation == punctuationSentence || speechMs >= hardLimitMs) {
                action = actionMonologuePause
            }
        }
        guard action != actionWait else { return actionWait }
        let backoff = cutBackoffMs(action: action, pauseMs: pauseMs)
        guard phraseAgeMs > backoff, lastCutAgoMs - backoff > minCutSpacingMs else { return actionWait }
        return action
    }

    /// How far before "now" the cut lies: just after the voice stopped (plus `trailingMarginMs`).
    static func cutBackoffMs(action: Int, pauseMs: Int) -> Int {
        if action == actionEndOfPhrase || action == actionMonologuePause {
            return max(0, pauseMs - trailingMarginMs)
        }
        return 0
    }

    // MARK: - Text classification (UTF-8 bytes)

    static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

    /// Punctuation at the end of the text, ignoring trailing spaces and closing quotes or brackets.
    /// Sentence: `.` `!` `?` `…`. Clause: `,` `;` `:` `—` `–`.
    static func punctuationCode(utf8: [UInt8]) -> Int {
        var end = utf8.count
        while end > 0 {
            let b = utf8[end - 1]
            if isSpace(b) || b == 0x22 || b == 0x27 || b == 0x29 { end -= 1; continue }       // space " ' )
            if end >= 2, utf8[end - 2] == 0xC2, b == 0xBB { end -= 2; continue }               // »
            if end >= 3, utf8[end - 3] == 0xE2, utf8[end - 2] == 0x80, b == 0x9D { end -= 3; continue } // ”
            break
        }
        guard end > 0 else { return punctuationNone }
        let b = utf8[end - 1]
        if b == 0x2E || b == 0x21 || b == 0x3F { return punctuationSentence }
        if b == 0x2C || b == 0x3B || b == 0x3A { return punctuationClause }
        if end >= 3, utf8[end - 3] == 0xE2, utf8[end - 2] == 0x80 {
            if b == 0xA6 { return punctuationSentence }                 // …
            if b == 0x94 || b == 0x93 { return punctuationClause }      // — –
        }
        return punctuationNone
    }

    /// Words separated by ASCII whitespace.
    static func wordCount(utf8: [UInt8]) -> Int {
        var count = 0
        var inWord = false
        for b in utf8 {
            if isSpace(b) {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    /// Shorter text is never a phrase.
    static let minPhraseBytes = 2

    /// At least `minPhraseBytes` and one letter or digit: ASCII alphanumerics, or any UTF-8 character
    /// from U+00C0 up except General Punctuation (U+2000–U+206F).
    static func hasSpeechContent(utf8: [UInt8]) -> Bool {
        guard utf8.count >= minPhraseBytes else { return false }
        var i = 0
        while i < utf8.count {
            let b = utf8[i]
            if b < 0x80 {
                if (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) { return true }
                i += 1
            } else if b == 0xC2 {
                i += 2                                                   // U+0080–U+00BF: symbols, « » NBSP
            } else if b == 0xE2, i + 1 < utf8.count, utf8[i + 1] == 0x80 || utf8[i + 1] == 0x81 {
                i += 3                                                   // General Punctuation
            } else if b >= 0xC3 {
                return true                                              // letters: Latin-1 accented, Cyrillic…
            } else {
                i += 1                                                   // continuation byte
            }
        }
        return false
    }

    /// The recognizer sometimes "hears" a few words in silence. Up to this many words…
    static let hallucinationMaxWords = 3
    /// …over less than this much metered voice are dropped.
    static let hallucinationMinVoiceMs = 100

    /// `phraseAction` results.
    static let phraseKeep = 0
    static let phraseDropHallucination = 1
    static let phraseDropNoContent = 2

    /// Keep or drop a recognized phrase (partial or final), given its text and the voice
    /// the level meter measured inside its audio range.
    static func phraseAction(utf8: [UInt8], voiceMs: Int) -> Int {
        guard hasSpeechContent(utf8: utf8) else { return phraseDropNoContent }
        if voiceMs < hallucinationMinVoiceMs && wordCount(utf8: utf8) <= hallucinationMaxWords {
            return phraseDropHallucination
        }
        return phraseKeep
    }

    // MARK: - Cutting long text (UTF-8 byte index)

    /// Long finals are split into pieces of at most this many bytes for synthesis (first audio sooner).
    static let speechChunkMaxBytes = 200
    /// A piece is never shorter than this.
    static let speechChunkMinBytes = 24

    /// Where to cut a long text: a UTF-8 byte index in `minBytes…maxBytes` (the head is `utf8[0..<index]`).
    ///
    /// Text that fits returns `utf8.count`. Otherwise the last sentence end (`.` `!` `?` `…` followed by
    /// a space), else the last clause end (`,` `;` `:` `—` `–` followed by a space), else the last space,
    /// else `maxBytes` moved back to a character boundary. Never splits a UTF-8 character.
    ///
    /// SpeechAnalyzer cannot finalize at a past time (see `finalizeAction`), so the transcriber does
    /// not use this to cut recognition; it splits final text for synthesis and display.
    static func cutByteIndex(utf8: [UInt8], maxBytes: Int, minBytes: Int) -> Int {
        let n = utf8.count
        guard n > maxBytes, maxBytes > 0 else { return n }
        func followedBySpace(_ end: Int) -> Bool { end == n || isSpace(utf8[end]) }
        var sentence = 0, clause = 0, space = 0
        var i = 0
        while i < maxBytes {
            let b = utf8[i]
            var end = 0, kind = 0
            if b == 0x2E || b == 0x21 || b == 0x3F {
                end = i + 1; kind = 2
            } else if b == 0x2C || b == 0x3B || b == 0x3A {
                end = i + 1; kind = 1
            } else if b == 0xE2, i + 2 < n, utf8[i + 1] == 0x80 {
                let c = utf8[i + 2]
                if c == 0xA6 { end = i + 3; kind = 2 } else if c == 0x94 || c == 0x93 { end = i + 3; kind = 1 }
            }
            if kind > 0, end <= maxBytes, end >= minBytes, followedBySpace(end) {
                if kind == 2 { sentence = end } else { clause = end }
            }
            if isSpace(b), i >= minBytes { space = i }
            i += 1
        }
        if sentence > 0 { return sentence }
        if clause > 0 { return clause }
        if space > 0 { return space }
        var j = maxBytes
        while j > 0 && (utf8[j] & 0xC0) == 0x80 { j -= 1 }
        return j > 0 ? j : maxBytes
    }

    // MARK: - Translation context

    /// At most this many previous phrases go into the Claude prompt…
    static let contextMaxPhrases = 4
    /// …and at most this many bytes of them.
    static let contextMaxBytes = 600

    /// How many of the newest previous phrases to send as context.
    /// - Parameter byteLengths: UTF-8 lengths of the previous phrases, oldest first.
    static func contextCount(byteLengths: [Int]) -> Int {
        var count = 0
        var total = 0
        for length in byteLengths.reversed() {
            guard count < contextMaxPhrases, total + length <= contextMaxBytes else { break }
            total += length
            count += 1
        }
        return count
    }

    // MARK: - Translator choice and fallback

    static let engineNone = 0
    static let engineApple = 1
    static let engineClaude = 2

    /// Translation error codes (`errorCode…`).
    static let errorTimeout = 1
    static let errorNetwork = 2
    static let errorOverloaded = 3       // HTTP 429, 5xx
    static let errorRejected = 4         // other HTTP 4xx: key, request
    static let errorAssetsMissing = 5    // Apple language pack not downloaded
    static let errorUnsupported = 6
    static let errorRefused = 7          // Claude stop_reason "refusal"
    static let errorEmpty = 8
    static let errorOther = 9

    /// Attempts per phrase, all engines together.
    static let maxTranslationAttempts = 2

    /// `retryAction` results.
    static let retryGiveUp = 0
    static let retrySame = 1
    static let retrySwitch = 2

    /// The engine to try first.
    static func primaryEngine(preferred: Int, appleReady: Bool, claudeAvailable: Bool) -> Int {
        if preferred == engineClaude && claudeAvailable { return engineClaude }
        if appleReady { return engineApple }
        if claudeAvailable { return engineClaude }
        return engineNone
    }

    /// The other engine, if it can be used.
    static func fallbackEngine(failed: Int, appleReady: Bool, claudeAvailable: Bool) -> Int {
        if failed == engineClaude && appleReady { return engineApple }
        if failed == engineApple && claudeAvailable { return engineClaude }
        return engineNone
    }

    /// Per-attempt time limit. On-device translation takes about 0.1–0.3 s once warm.
    static func translationTimeoutMs(engine: Int) -> Int {
        switch engine {
        case engineApple: return 3_000
        case engineClaude: return 5_000
        default: return 0
        }
    }

    /// Error code for an HTTP status from the Claude API (0 = no response).
    static func errorCode(httpStatus: Int) -> Int {
        if httpStatus == 0 { return errorNetwork }
        if httpStatus == 429 || httpStatus >= 500 { return errorOverloaded }
        if httpStatus >= 400 { return errorRejected }
        return errorOther
    }

    /// After a failed attempt (`attempt` is 0-based): give up, retry the same engine, or switch.
    /// - Parameter fallback: `fallbackEngine` for the failed engine.
    static func retryAction(errorCode: Int, attempt: Int, fallback: Int) -> Int {
        guard attempt + 1 < maxTranslationAttempts else { return retryGiveUp }
        if fallback != engineNone { return retrySwitch }
        switch errorCode {
        case errorTimeout, errorNetwork, errorOverloaded, errorEmpty, errorOther:
            return retrySame
        default:
            return retryGiveUp
        }
    }

    // MARK: - Claude request shape

    /// Model id, ASCII bytes of "claude-haiku-5-5".
    static func claudeModelID() -> [UInt8] {
        [0x63, 0x6C, 0x61, 0x75, 0x64, 0x65, 0x2D, 0x68, 0x61, 0x69, 0x6B, 0x75, 0x2D, 0x35, 0x2D, 0x35]
    }

    /// API version header, ASCII bytes of "2023-06-01".
    static func anthropicVersion() -> [UInt8] {
        [0x32, 0x30, 0x32, 0x33, 0x2D, 0x30, 0x36, 0x2D, 0x30, 0x31]
    }

    /// Room for adaptive thinking plus a one-phrase answer.
    static let claudeMaxTokens = 1_024
    /// Effort codes: 0 low, 1 medium, 2 high. Low keeps the latency down.
    static let claudeEffortCode = 0
    /// URLRequest timeout; the router's per-attempt limit (`translationTimeoutMs`) is shorter.
    static let claudeRequestTimeoutMs = 20_000

    // MARK: - Voices

    /// Quality codes, also AVSpeechSynthesisVoiceQuality raw values.
    static let qualityCompact = 1
    static let qualityEnhanced = 2
    static let qualityPremium = 3

    /// AVSpeechSynthesisVoiceQuality raw value → quality code (unknown → compact).
    static func voiceQualityCode(avQualityRaw: Int) -> Int {
        (qualityCompact...qualityPremium).contains(avQualityRaw) ? avQualityRaw : qualityCompact
    }

    /// Novelty voices (Eddy, Flo, Reed…: "com.apple.eloquence.*") and the old
    /// "com.apple.speech.synthesis.voice.*" voices rank below regular voices.
    static func isNoveltyVoice(identifierUTF8 id: [UInt8]) -> Bool {
        let eloquence: [UInt8] = Array(".eloquence.".utf8)
        let legacy: [UInt8] = Array(".speech.synthesis.voice.".utf8)
        return contains(id, eloquence) || contains(id, legacy)
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    /// Sort key, larger is better: quality first, then regular before novelty, then the position of the
    /// voice name in the preferred list for the language (`preferredIndex`, −1 if absent).
    /// Ties are broken in Swift by name, then identifier.
    static func voiceRankKey(qualityCode: Int, isNovelty: Bool, preferredIndex: Int) -> Int {
        let preferred = preferredIndex >= 0 ? 100 - min(preferredIndex, 99) : 0
        return qualityCode * 10_000 + (isNovelty ? 0 : 1_000) + preferred
    }

    // MARK: - Synthesis

    /// Rendering time limit for a phrase of `textBytes` UTF-8 bytes (a safety net: the synthesizer
    /// sometimes never signals the end).
    static func synthesisTimeoutMs(textBytes: Int) -> Int {
        min(60_000, max(5_000, 5_000 + 50 * textBytes))
    }

    /// After `didFinish`, wait this long for a late buffer before completing.
    static let synthesisEndGraceMs = 200

    // MARK: - Speaking rate

    /// `AVSpeechUtteranceDefaultSpeechRate` (0.5) in thousandths.
    static let defaultUtteranceRateMilli = 500
    /// Rate change, in thousandths of AVSpeechUtterance.rate, per 10 % of speaking speed.
    /// Measured on this Mac 2026-10-11 (Luciana pt-BR and Milena ru, same phrase at rates
    /// 0.50…0.55): +0.01 of rate ≈ +5.8 % of speed, and the engine works in steps of 0.005.
    static let utteranceRateMilliPer10Percent = 17

    /// AVSpeechUtterance.rate × 1000 for speaking at `ratePercent` of normal speed, starting from
    /// `baseRateMilli` (the voice's normal rate, `defaultUtteranceRateMilli` unless the user set one):
    /// base + (ratePercent − 100) × 17 / 10, integer division truncating toward zero,
    /// clamped to 0…1000. 100 → base; 110 → base + 17; 120 → base + 34; 130 → base + 51.
    static func utteranceRateMilli(ratePercent: Int, baseRateMilli: Int) -> Int {
        let rate = baseRateMilli + (ratePercent - 100) * utteranceRateMilliPer10Percent / 10
        return min(1000, max(0, rate))
    }
}
