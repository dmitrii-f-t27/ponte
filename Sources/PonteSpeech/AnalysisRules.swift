// AnalysisRules — every decision of the call analysis agent (CallAnalyst), in one place.
//
// The decisions are written in t27 (Specs/analysis_rules.t27) and compiled to C (Sources/PonteSpecs). This facade
// only marshals: integers to and from Int64, Bool straight through, UTF-8 text into the fixed buffers the C takes
// (AN_URL_MAX bytes for a base URL or a key, AN_TEXT_OUT_MAX for names) and byte strings back. Constants come
// from the C #defines. The test oracle is AnalysisRulesLegacy (Tests/PonteTests/Oracles), a separate plain-Swift
// implementation of the same rules; AnalysisRulesDifferentialTests compare both bit for bit.
// Units: times are integer milliseconds, sizes UTF-8 bytes.
// Domains: a base URL or a key longer than AN_URL_MAX bytes is reported as too long without being read past the
// buffer; at most AN_LIST_MAX line sizes are planned at once; counts and times stay far from Int64 overflow.
import Foundation
import PonteCore
import PonteSpecs

public enum AnalysisRules {

    // MARK: - Providers

    public static let providerZai = Int(AN_PROVIDER_ZAI)
    public static let providerDeepSeek = Int(AN_PROVIDER_DEEPSEEK)
    public static let providerCustom = Int(AN_PROVIDER_CUSTOM)
    public static let providerCount = Int(AN_PROVIDER_COUNT)
    public static let defaultProvider = Int(AN_DEFAULT_PROVIDER)
    public static let allProviders = Array(0..<Int(AN_PROVIDER_COUNT))

    /// A stored provider code; anything unknown is the default (Z.ai).
    public static func providerCode(stored: Int) -> Int { Int(an_provider_code(Int64(stored))) }

    /// "zai", "deepseek", "custom": names the Keychain item and the stored settings.
    public static func providerID(_ provider: Int) -> String { text { an_provider_id(Int64(provider), $0) } }
    /// The base URL the settings start from (empty for the custom provider).
    public static func defaultBaseURL(_ provider: Int) -> String { text { an_default_base_url(Int64(provider), $0) } }
    /// The model the settings start from (empty for the custom provider).
    public static func defaultModel(_ provider: Int) -> String { text { an_default_model(Int64(provider), $0) } }
    /// The Keychain generic password service of the provider's key: "ponte-analysis-<id>".
    public static func keychainService(_ provider: Int) -> String { text { an_keychain_service(Int64(provider), $0) } }
    /// Z.ai's GLM models get `"thinking": {"type": "disabled"}`.
    public static func thinkingOff(_ provider: Int) -> Bool { an_thinking_off(Int64(provider)) }

    /// Bytes of one AN_ROW_* row.
    public static func rowBytes(_ row: Int64) -> [UInt8] { bytes { an_row_bytes(row, $0) } }
    /// "Bearer " (Authorization: Bearer <key>).
    public static let bearerPrefix = String(decoding: rowBytes(Int64(AN_ROW_BEARER)), as: UTF8.self)
    /// "/chat/completions".
    public static let chatPath = String(decoding: rowBytes(Int64(AN_ROW_PATH)), as: UTF8.self)

    // MARK: - Timing and limits

    public static let intervalMs = Int(AN_INTERVAL_MS)
    public static let minNewLines = Int(AN_MIN_NEW_LINES)
    public static let forceNewLines = Int(AN_FORCE_NEW_LINES)
    public static let tickMs = Int(AN_TICK_MS)
    public static let lineSettleMs = Int(AN_LINE_SETTLE_MS)
    public static let maxRequestBytes = Int(AN_MAX_REQUEST_BYTES)
    public static let maxLineBytes = Int(AN_MAX_LINE_BYTES)
    public static let maxNotesBytes = Int(AN_MAX_NOTES_BYTES)
    public static let notesChars = Int(AN_NOTES_CHARS)
    public static let listMax = Int(AN_LIST_MAX)
    public static let requestTimeoutMs = Int(AN_REQUEST_TIMEOUT_MS)
    public static let probeTimeoutMs = Int(AN_PROBE_TIMEOUT_MS)
    public static let maxTokens = Int(AN_MAX_TOKENS)
    public static let reportMaxTokens = Int(AN_REPORT_MAX_TOKENS)
    public static let probeMaxTokens = Int(AN_PROBE_MAX_TOKENS)
    public static let temperatureMilli = Int(AN_TEMPERATURE_MILLI)
    /// The request temperature (AN_TEMPERATURE_MILLI / 1000).
    public static let temperature = Double(AN_TEMPERATURE_MILLI) / 1000
    public static let textOutMax = Int(AN_TEXT_OUT_MAX)
    public static let urlMax = Int(AN_URL_MAX)
    public static let keyMax = Int(AN_KEY_MAX)

    // MARK: - Errors

    public static let kindHTTP = Int(AN_KIND_HTTP)
    public static let kindTimeout = Int(AN_KIND_TIMEOUT)
    public static let kindNetwork = Int(AN_KIND_NETWORK)
    public static let kindEmpty = Int(AN_KIND_EMPTY)
    public static let kindBadReply = Int(AN_KIND_BAD_REPLY)
    public static let kindNoKey = Int(AN_KIND_NO_KEY)
    public static let kindBadURL = Int(AN_KIND_BAD_URL)

    public static let errNone = Int(AN_ERR_NONE)
    public static let errNetwork = Int(AN_ERR_NETWORK)
    public static let errTimeout = Int(AN_ERR_TIMEOUT)
    public static let errAuth = Int(AN_ERR_AUTH)
    public static let errPayment = Int(AN_ERR_PAYMENT)
    public static let errRateLimit = Int(AN_ERR_RATE_LIMIT)
    public static let errServer = Int(AN_ERR_SERVER)
    public static let errNotFound = Int(AN_ERR_NOT_FOUND)
    public static let errRejected = Int(AN_ERR_REJECTED)
    public static let errEmpty = Int(AN_ERR_EMPTY)
    public static let errBadReply = Int(AN_ERR_BAD_REPLY)
    public static let errNoKey = Int(AN_ERR_NO_KEY)
    public static let errBadURL = Int(AN_ERR_BAD_URL)
    public static let errOther = Int(AN_ERR_OTHER)

    public static func httpClass(status: Int) -> Int { Int(an_http_class(Int64(status))) }
    public static func errorClass(kind: Int, status: Int) -> Int { Int(an_error_class(Int64(kind), Int64(status))) }
    public static func isTransient(_ error: Int) -> Bool { an_is_transient(Int64(error)) }

    public static let maxAttempts = Int(AN_MAX_ATTEMPTS)
    public static let retryGiveUp = Int(AN_RETRY_GIVE_UP)
    public static let retryAgain = Int(AN_RETRY_AGAIN)
    public static let retryBaseMs = Int(AN_RETRY_BASE_MS)
    public static let retryMaxMs = Int(AN_RETRY_MAX_MS)
    public static let maxBackgroundFailures = Int(AN_MAX_BACKGROUND_FAILURES)
    public static let backgroundRetry = Int(AN_BG_RETRY)
    public static let backgroundStop = Int(AN_BG_STOP)

    /// After a failed attempt (0-based) of a report request: retry or give up.
    public static func retryAction(error: Int, attempt: Int) -> Int { Int(an_retry_action(Int64(error), Int64(attempt))) }
    /// The wait after `failures` failures in a row.
    public static func retryDelayMs(failures: Int) -> Int { Int(an_retry_delay_ms(Int64(failures))) }
    /// After a failed notes update: retry later or stop the background notes.
    public static func backgroundAfterError(error: Int, failures: Int) -> Int {
        Int(an_background_after_error(Int64(error), Int64(failures)))
    }
    /// «Проверить»: the service answered.
    public static func probeOK(error: Int) -> Bool { an_probe_ok(Int64(error)) }

    // MARK: - Base URL, key and configuration

    public static let urlOK = Int(AN_URL_OK)
    public static let urlEmpty = Int(AN_URL_EMPTY)
    public static let urlNoScheme = Int(AN_URL_NO_SCHEME)
    public static let urlNoHost = Int(AN_URL_NO_HOST)
    public static let urlSpace = Int(AN_URL_SPACE)
    public static let urlTooLong = Int(AN_URL_TOO_LONG)

    /// Whether a base URL (trimmed) can be used.
    public static func baseURLCheck(utf8: [UInt8]) -> Int {
        var b = URLBuffer(utf8)
        return Int(an_base_url_check(&b.bytes, b.length))
    }

    /// `<base>/chat/completions` (trailing slashes dropped; a base that already ends with the path is kept).
    public static func endpoint(utf8: [UInt8]) -> [UInt8] {
        var b = URLBuffer(utf8)
        var out = [UInt8](repeating: 0, count: urlMax)
        let n = Int(an_endpoint(&b.bytes, b.length, &out))
        return Array(out[0..<n])
    }

    public static let keyOK = Int(AN_KEY_OK)
    public static let keyEmpty = Int(AN_KEY_EMPTY)
    public static let keyBadChar = Int(AN_KEY_BAD_CHAR)
    public static let keyTooLong = Int(AN_KEY_TOO_LONG)

    /// Whether a pasted key (trimmed) can go into the Authorization header.
    public static func keyCheck(utf8: [UInt8]) -> Int {
        var b = URLBuffer(utf8)
        return Int(an_key_check(&b.bytes, b.length))
    }

    public static let configOK = Int(AN_CFG_OK)
    public static let configNoKey = Int(AN_CFG_NO_KEY)
    public static let configBadURL = Int(AN_CFG_BAD_URL)
    public static let configNoModel = Int(AN_CFG_NO_MODEL)

    public static func configCheck(keyBytes: Int, urlCheck: Int, modelBytes: Int) -> Int {
        Int(an_config_check(Int64(keyBytes), Int64(urlCheck), Int64(modelBytes)))
    }

    /// «Анализировать звонок»: never without a key or in test mode; else the stored choice, on by default.
    public static func analysisOn(hasStored: Bool, stored: Bool, hasKey: Bool, testMode: Bool) -> Bool {
        an_analysis_on(hasStored, stored, hasKey, testMode)
    }

    // MARK: - Lines

    public static let directionIncoming = Int(AN_DIR_INCOMING)
    public static let directionOutgoing = Int(AN_DIR_OUTGOING)
    public static let speakerThem = Int(AN_SPEAKER_THEM)
    public static let speakerMe = Int(AN_SPEAKER_ME)

    public static func directionCode(_ direction: Direction) -> Int {
        direction == .outgoing ? directionOutgoing : directionIncoming
    }

    /// Who spoke a line (AN_SPEAKER_*).
    public static func speaker(direction: Int) -> Int { Int(an_speaker(Int64(direction))) }

    public static func lineReady(hasTranslation: Bool, hasError: Bool, msSinceLine: Int) -> Bool {
        an_line_ready(hasTranslation, hasError, Int64(msSinceLine))
    }

    public static func fits(bytes: Int, charBytes: Int, limit: Int) -> Bool {
        an_fits(Int64(bytes), Int64(charBytes), Int64(limit))
    }

    // MARK: - When the notes are updated

    public static func shouldUpdate(running: Bool, enabled: Bool, configured: Bool, busy: Bool, stopped: Bool,
                                    newLines: Int, msSinceLast: Int, msUntilRetry: Int) -> Bool {
        an_should_update(running, enabled, configured, busy, stopped, Int64(newLines), Int64(msSinceLast), Int64(msUntilRetry))
    }

    /// How many of the pending lines (their sizes, oldest first) go into a request that already holds `usedBytes`.
    /// The C reads the first AN_LIST_MAX sizes.
    public static func chunkTake(sizes: [Int], usedBytes: Int) -> Int {
        var table = [Int64](repeating: 0, count: listMax)
        let n = min(sizes.count, listMax)
        for i in 0..<n { table[i] = Int64(sizes[i]) }
        return Int(an_chunk_take(&table, Int64(sizes.count), Int64(usedBytes)))
    }

    public static func fitsOneRequest(usedBytes: Int, remainingBytes: Int) -> Bool {
        an_fits_one_request(Int64(usedBytes), Int64(remainingBytes))
    }

    // MARK: - The report

    public static let openShow = Int(AN_OPEN_SHOW)
    public static let openBuild = Int(AN_OPEN_BUILD)
    public static let openExplain = Int(AN_OPEN_EXPLAIN)
    public static let checkOK = Int(AN_CHECK_OK)
    public static let checkBusy = Int(AN_CHECK_BUSY)
    public static let checkNotSet = Int(AN_CHECK_NOT_SET)
    public static let checkNoLines = Int(AN_CHECK_NO_LINES)

    public static func reportOnStop(enabled: Bool, configured: Bool, lines: Int) -> Bool {
        an_report_on_stop(enabled, configured, Int64(lines))
    }

    public static func reportOnOpen(busy: Bool, hasReport: Bool, reportLines: Int, lines: Int, configured: Bool) -> Int {
        Int(an_report_on_open(busy, hasReport, Int64(reportLines), Int64(lines), configured))
    }

    public static func buildCheck(busy: Bool, configured: Bool, lines: Int) -> Int {
        Int(an_build_check(busy, configured, Int64(lines)))
    }

    public static func reportButtonEnabled(lines: Int, hasReport: Bool, busy: Bool) -> Bool {
        an_report_button_enabled(Int64(lines), hasReport, busy)
    }

    public static func saveBeforeReset(hasReport: Bool, saved: Bool) -> Bool { an_save_before_reset(hasReport, saved) }

    public static func durationMinutes(ms: Int) -> Int { Int(an_duration_minutes(Int64(ms))) }

    // MARK: - Report file name

    public static let firstAttempt: Int32 = AN_FIRST_ATTEMPT

    /// "Ponte-report-YYYY-MM-DD-HHmm[-N].txt".
    public static func reportFileName(year: Int32, month: Int32, day: Int32, hour: Int32, minute: Int32, attempt: Int32) -> [UInt8] {
        bytes { an_report_file_name(year, month, day, hour, minute, attempt, $0) }
    }

    // MARK: - Marshalling

    private static func bytes(_ write: (UnsafeMutablePointer<UInt8>) -> Int64) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(AN_TEXT_OUT_MAX))
        let n = out.withUnsafeMutableBufferPointer { Int(write($0.baseAddress!)) }
        return Array(out[0..<n])
    }

    private static func text(_ write: (UnsafeMutablePointer<UInt8>) -> Int64) -> String {
        String(decoding: bytes(write), as: UTF8.self)
    }
}

/// A base URL or a key in the fixed buffer the C takes: the first AN_URL_MAX bytes, with the whole length (the C
/// refuses a longer text before reading it).
private struct URLBuffer {
    var bytes = [UInt8](repeating: 0, count: Int(AN_URL_MAX))
    let length: Int64

    init(_ utf8: [UInt8]) {
        let n = min(utf8.count, Int(AN_URL_MAX))
        bytes.replaceSubrange(0..<n, with: utf8[0..<n])
        length = Int64(utf8.count)
    }
}
