// Test oracle for Specs/analysis_rules.t27 (the call analysis agent). Written in plain Swift from the same rules,
// independently of the t27 (strings and collection operations instead of byte loops, closed forms instead of the
// spec's loops), so the differential tests compare two implementations of one rule set, bit for bit.

enum AnalysisRulesLegacy {
    // MARK: Providers

    static let providerZai = 0
    static let providerDeepSeek = 1
    static let providerCustom = 2
    static let providerCount = 3
    static let defaultProvider = 0
    static let ids = ["zai", "deepseek", "custom"]
    static let baseURLs = ["https://api.z.ai/api/paas/v4", "https://api.deepseek.com", ""]
    static let models = ["glm-4.5-flash", "deepseek-flash", ""]
    static let path = "/chat/completions"
    static let keychainPrefix = "ponte-analysis-"
    static let bearerPrefix = "Bearer "

    static func providerCode(stored: Int) -> Int { (0..<providerCount).contains(stored) ? stored : defaultProvider }
    static func providerID(_ provider: Int) -> String { ids[providerCode(stored: provider)] }
    static func defaultBaseURL(_ provider: Int) -> String { baseURLs[providerCode(stored: provider)] }
    static func defaultModel(_ provider: Int) -> String { models[providerCode(stored: provider)] }
    static func keychainService(_ provider: Int) -> String { keychainPrefix + providerID(provider) }
    static func thinkingOff(_ provider: Int) -> Bool { providerCode(stored: provider) == providerZai }

    // MARK: Constants

    static let intervalMs = 120_000
    static let minNewLines = 4
    static let forceNewLines = 60
    static let tickMs = 5_000
    static let lineSettleMs = 20_000
    static let maxRequestBytes = 40_000
    static let maxLineBytes = 4_000
    static let maxNotesBytes = 24_000
    static let notesChars = 6_000
    static let listMax = 256
    static let requestTimeoutMs = 90_000
    static let probeTimeoutMs = 30_000
    static let maxTokens = 4_096
    static let reportMaxTokens = 8_000
    static let probeMaxTokens = 16
    static let temperatureMilli = 200
    static let textOutMax = 256
    static let urlMax = 2_048
    static let keyMax = 1_024

    // MARK: Errors

    static let kindHTTP = 0, kindTimeout = 1, kindNetwork = 2, kindEmpty = 3, kindBadReply = 4, kindNoKey = 5, kindBadURL = 6
    static let errNone = 0, errNetwork = 1, errTimeout = 2, errAuth = 3, errPayment = 4, errRateLimit = 5, errServer = 6
    static let errNotFound = 7, errRejected = 8, errEmpty = 9, errBadReply = 10, errNoKey = 11, errBadURL = 12, errOther = 13

    static func httpClass(status: Int) -> Int {
        switch status {
        case 200..<300: return errNone
        case 0: return errNetwork
        case 401, 403: return errAuth
        case 402: return errPayment
        case 404: return errNotFound
        case 408: return errTimeout
        case 429: return errRateLimit
        case 500..<600: return errServer
        case 400..<500: return errRejected
        default: return errOther
        }
    }

    static func errorClass(kind: Int, status: Int) -> Int {
        switch kind {
        case kindHTTP: return httpClass(status: status)
        case kindTimeout: return errTimeout
        case kindNetwork: return errNetwork
        case kindEmpty: return errEmpty
        case kindBadReply: return errBadReply
        case kindNoKey: return errNoKey
        case kindBadURL: return errBadURL
        default: return errOther
        }
    }

    static func isTransient(_ error: Int) -> Bool {
        [errNetwork, errTimeout, errRateLimit, errServer, errEmpty].contains(error)
    }

    static let maxAttempts = 3
    static let retryGiveUp = 0, retryAgain = 1
    static let retryBaseMs = 15_000
    static let retryMaxMs = 300_000
    static let maxBackgroundFailures = 6
    static let backgroundRetry = 0, backgroundStop = 1

    static func retryAction(error: Int, attempt: Int) -> Int {
        isTransient(error) && attempt < maxAttempts - 1 ? retryAgain : retryGiveUp
    }

    /// Closed form: base × 2^(failures − 1), at most the maximum.
    static func retryDelayMs(failures: Int) -> Int {
        guard failures > 0 else { return 0 }
        return min(retryBaseMs << min(failures - 1, 30), retryMaxMs)
    }

    static func backgroundAfterError(error: Int, failures: Int) -> Int {
        !isTransient(error) || failures >= maxBackgroundFailures ? backgroundStop : backgroundRetry
    }

    static func probeOK(error: Int) -> Bool { error == errNone || error == errEmpty }

    // MARK: Base URL, key, configuration

    static let urlOK = 0, urlEmpty = 1, urlNoScheme = 2, urlNoHost = 3, urlSpace = 4, urlTooLong = 5

    static func baseURLCheck(utf8: [UInt8]) -> Int {
        if utf8.isEmpty { return urlEmpty }
        if utf8.count > urlMax - path.utf8.count { return urlTooLong }
        if utf8.contains(where: { $0 <= 0x20 || $0 == 0x7F }) { return urlSpace }
        let folded = utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
        let scheme: Int
        if folded.starts(with: Array("https://".utf8)) {
            scheme = 8
        } else if folded.starts(with: Array("http://".utf8)) {
            scheme = 7
        } else {
            return urlNoScheme
        }
        return utf8.dropFirst(scheme).allSatisfy({ $0 == 0x2F }) ? urlNoHost : urlOK
    }

    static func endpoint(utf8: [UInt8]) -> [UInt8] {
        let suffix = Array(path.utf8)
        var base = Array(utf8.prefix(urlMax - suffix.count))
        while base.last == 0x2F { base.removeLast() }
        if base.count >= suffix.count, Array(base.suffix(suffix.count)) == suffix { return base }
        return base + suffix
    }

    static let keyOK = 0, keyEmpty = 1, keyBadChar = 2, keyTooLong = 3

    static func keyCheck(utf8: [UInt8]) -> Int {
        if utf8.isEmpty { return keyEmpty }
        if utf8.count > keyMax { return keyTooLong }
        return utf8.allSatisfy { (0x21...0x7E).contains($0) } ? keyOK : keyBadChar
    }

    static let configOK = 0, configNoKey = 1, configBadURL = 2, configNoModel = 3

    static func configCheck(keyBytes: Int, urlCheck: Int, modelBytes: Int) -> Int {
        if keyBytes < 1 { return configNoKey }
        if urlCheck != urlOK { return configBadURL }
        return modelBytes < 1 ? configNoModel : configOK
    }

    static func analysisOn(hasStored: Bool, stored: Bool, hasKey: Bool, testMode: Bool) -> Bool {
        guard hasKey, !testMode else { return false }
        return hasStored ? stored : true
    }

    // MARK: Lines

    static let directionIncoming = 0, directionOutgoing = 1
    static let speakerThem = 0, speakerMe = 1

    static func speaker(direction: Int) -> Int { direction == directionOutgoing ? speakerMe : speakerThem }

    static func lineReady(hasTranslation: Bool, hasError: Bool, msSinceLine: Int) -> Bool {
        hasTranslation || hasError || msSinceLine >= lineSettleMs
    }

    static func fits(bytes: Int, charBytes: Int, limit: Int) -> Bool { bytes + charBytes <= limit }

    // MARK: Updates and chunks

    static func shouldUpdate(running: Bool, enabled: Bool, configured: Bool, busy: Bool, stopped: Bool,
                             newLines: Int, msSinceLast: Int, msUntilRetry: Int) -> Bool {
        guard running, enabled, configured, !busy, !stopped, msUntilRetry <= 0 else { return false }
        return newLines >= forceNewLines || (newLines >= minNewLines && msSinceLast >= intervalMs)
    }

    static func chunkTake(sizes: [Int], usedBytes: Int) -> Int {
        let considered = sizes.prefix(listMax)
        guard !considered.isEmpty else { return 0 }
        let budget = maxRequestBytes - usedBytes
        var running = 0
        let fitting = considered.prefix { size in
            running += size
            return running <= budget
        }.count
        return max(fitting, 1)
    }

    static func fitsOneRequest(usedBytes: Int, remainingBytes: Int) -> Bool { usedBytes + remainingBytes <= maxRequestBytes }

    // MARK: The report

    static let openShow = 0, openBuild = 1, openExplain = 2
    static let checkOK = 0, checkBusy = 1, checkNotSet = 2, checkNoLines = 3

    static func reportOnStop(enabled: Bool, configured: Bool, lines: Int) -> Bool { enabled && configured && lines > 0 }

    static func reportOnOpen(busy: Bool, hasReport: Bool, reportLines: Int, lines: Int, configured: Bool) -> Int {
        if busy || (hasReport && reportLines == lines) { return openShow }
        if lines > 0 && configured { return openBuild }
        return hasReport ? openShow : openExplain
    }

    static func buildCheck(busy: Bool, configured: Bool, lines: Int) -> Int {
        busy ? checkBusy : !configured ? checkNotSet : lines < 1 ? checkNoLines : checkOK
    }

    static func reportButtonEnabled(lines: Int, hasReport: Bool, busy: Bool) -> Bool { lines >= 1 || hasReport || busy }

    static func saveBeforeReset(hasReport: Bool, saved: Bool) -> Bool { hasReport && !saved }

    static func durationMinutes(ms: Int) -> Int { ms > 0 ? (ms + 30_000) / 60_000 : 0 }

    static let firstAttempt: Int32 = 1

    static func reportFileName(year: Int32, month: Int32, day: Int32, hour: Int32, minute: Int32, attempt: Int32) -> [UInt8] {
        func padded(_ value: Int32, _ width: Int) -> String {
            let digits = String(max(0, value))
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        var name = "Ponte-report-\(padded(year, 4))-\(padded(month, 2))-\(padded(day, 2))-\(padded(hour, 2))\(padded(minute, 2))"
        if attempt >= 2 { name += "-\(padded(attempt, 1))" }
        return Array((name + ".txt").utf8)
    }
}
