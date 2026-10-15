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
    static let kindCut = 7, kindKeyElsewhere = 8
    static let errNone = 0, errNetwork = 1, errTimeout = 2, errAuth = 3, errPayment = 4, errRateLimit = 5, errServer = 6
    static let errNotFound = 7, errRejected = 8, errEmpty = 9, errBadReply = 10, errNoKey = 11, errBadURL = 12, errOther = 13
    static let errCut = 14, errKeyElsewhere = 15

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
        case kindCut: return errCut
        case kindKeyElsewhere: return errKeyElsewhere
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

    static func probeOK(error: Int) -> Bool { [errNone, errEmpty, errCut].contains(error) }

    // MARK: Replies

    static let finishNone = 0, finishStop = 1, finishLength = 2, finishCut = 3, finishOther = 4
    static let finishCutWords: Set<String> = ["content_filter", "sensitive", "insufficient_system_resource", "network_error"]
    static let cutSmaller = 0, cutCompress = 1, cutFail = 2
    static let maxCuts = 6
    static let compressFromBytes = 6_000
    static let compressChars = 3_000

    /// A word longer than the C buffer (256 bytes) is never one of the words.
    static func finishCode(utf8: [UInt8]) -> Int {
        if utf8.isEmpty { return finishNone }
        guard utf8.count <= textOutMax, let word = String(validating: utf8, as: UTF8.self) else { return finishOther }
        if word == "stop" { return finishStop }
        if word == "length" { return finishLength }
        return finishCutWords.contains(word) ? finishCut : finishOther
    }

    static func replyComplete(finish: Int) -> Bool { ![finishLength, finishCut].contains(finish) }

    static func afterCut(taken: Int, cuts: Int, notesBytes: Int) -> Int {
        switch true {
        case cuts >= maxCuts, taken < 1: return cutFail
        case notesBytes >= compressFromBytes: return cutCompress
        case taken >= 2: return cutSmaller
        default: return cutFail
        }
    }

    static func cutLineCap(taken: Int) -> Int { Swift.max(taken / 2, 1) }

    // MARK: Base URL, key, configuration

    static let urlOK = 0, urlEmpty = 1, urlNoScheme = 2, urlNoHost = 3, urlSpace = 4, urlTooLong = 5, urlHTTPRemote = 6
    static let localHosts = ["localhost", "127.0.0.1", "[::1]"]

    static func baseURLCheck(utf8: [UInt8]) -> Int {
        if utf8.isEmpty { return urlEmpty }
        if utf8.count > urlMax - path.utf8.count { return urlTooLong }
        if utf8.contains(where: { $0 <= 0x20 || $0 == 0x7F }) { return urlSpace }
        let folded = utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
        let scheme: Int
        let plain: Bool
        if folded.starts(with: Array("https://".utf8)) {
            (scheme, plain) = (8, false)
        } else if folded.starts(with: Array("http://".utf8)) {
            (scheme, plain) = (7, true)
        } else {
            return urlNoScheme
        }
        if utf8.dropFirst(scheme).allSatisfy({ $0 == 0x2F }) { return urlNoHost }
        return plain && !isThisMac(authority: Array(folded.dropFirst(scheme).prefix { !"/?#".utf8.contains($0) }))
            ? urlHTTPRemote : urlOK
    }

    /// "localhost", "127.0.0.1" or "[::1]" (already case folded), with an optional ":<digits>" port.
    static func isThisMac(authority: [UInt8]) -> Bool {
        localHosts.map { Array($0.utf8) }.contains { host in
            guard authority.starts(with: host) else { return false }
            let rest = authority.dropFirst(host.count)
            guard let colon = rest.first else { return true }
            let port = rest.dropFirst()
            return colon == UInt8(ascii: ":") && !port.isEmpty && port.allSatisfy { (0x30...0x39).contains($0) }
        }
    }

    /// The bytes before "/chat/completions" in the endpoint (the endpoint always ends with the path).
    static func endpointCore(utf8: [UInt8]) -> Int { endpoint(utf8: utf8).count - path.utf8.count }

    /// Both usable and the same endpoint.
    static func sameEndpoint(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        baseURLCheck(utf8: a) == urlOK && baseURLCheck(utf8: b) == urlOK && endpoint(utf8: a) == endpoint(utf8: b)
    }

    static let bindOK = 0, bindOther = 1, bindUnbound = 2

    static func bindCheck(hasBound: Bool, sameAsBound: Bool, provider: Int, sameAsDefault: Bool) -> Int {
        switch (hasBound, sameAsBound) {
        case (true, true): return bindOK
        case (true, false): return bindOther
        default:
            let builtIn = providerCode(stored: provider) == providerZai || providerCode(stored: provider) == providerDeepSeek
            return builtIn && sameAsDefault ? bindOK : bindUnbound
        }
    }

    static let modelMax = 256
    static let modelOK = 0, modelEmpty = 1, modelTooLong = 2, modelBadChar = 3

    static func modelCheck(utf8: [UInt8]) -> Int {
        guard !utf8.isEmpty else { return modelEmpty }
        guard utf8.count <= modelMax else { return modelTooLong }
        return utf8.allSatisfy { $0 > 0x20 && $0 != 0x7F } ? modelOK : modelBadChar
    }

    static let kcOK = 0, kcNotFound = 1, kcDuplicate = 2, kcOther = 3
    static let saveOK = 0, saveForeign = 1, saveFailed = 2

    static func keyWriteOutcome(added: Int) -> Int {
        [kcOK: saveOK, kcDuplicate: saveForeign][added] ?? saveFailed
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

    static let configOK = 0, configNoKey = 1, configBadURL = 2, configNoModel = 3, configKeyElsewhere = 4

    static func configCheck(keyBytes: Int, urlCheck: Int, modelBytes: Int, bind: Int) -> Int {
        if keyBytes < 1 { return configNoKey }
        if urlCheck != urlOK { return configBadURL }
        if modelBytes < 1 { return configNoModel }
        return bind == bindOK ? configOK : configKeyElsewhere
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
    static let checkOK = 0, checkBusy = 1, checkNotSet = 2, checkNoLines = 3, checkOff = 4
    static let quitWaitLimitMs = 10_000

    static func reportOnStop(enabled: Bool, configured: Bool, lines: Int, quitting: Bool) -> Bool {
        !quitting && enabled && configured && lines > 0
    }

    static func reportOnOpen(enabled: Bool, busy: Bool, hasReport: Bool, reportLines: Int, lines: Int, configured: Bool) -> Int {
        if busy || (hasReport && reportLines == lines) { return openShow }
        if enabled && lines > 0 && configured { return openBuild }
        return hasReport ? openShow : openExplain
    }

    static func buildCheck(enabled: Bool, busy: Bool, configured: Bool, lines: Int) -> Int {
        !enabled ? checkOff : busy ? checkBusy : !configured ? checkNotSet : lines < 1 ? checkNoLines : checkOK
    }

    static func quitWaitMs(builds: Int) -> Int { builds >= 1 ? quitWaitLimitMs : 0 }

    static func reportButtonEnabled(lines: Int, hasReport: Bool, busy: Bool) -> Bool { lines >= 1 || hasReport || busy }

    static func saveBeforeReset(hasReport: Bool, saved: Bool) -> Bool { hasReport && !saved }
    static func quitHasWork(hasReport: Bool, saved: Bool, builds: Int) -> Bool { (hasReport && !saved) || builds >= 1 }

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

    // MARK: Moved out of Swift 2026-10-15 (CallAnalyst, CallAnalysisModel)

    /// analysisMillis, now the lane's rule: NaN 0, held to +-1e15 ms.
    static func millis(_ seconds: Double) -> Int {
        let ms = seconds * 1000
        guard !ms.isNaN else { return 0 }
        return Int(min(max(ms, -1e15), 1e15).rounded())
    }
    /// `$0.at != $1.at ? $0.at < $1.at : $0.offset < $1.offset`.
    static func lineBefore(atA: Double, indexA: Int, atB: Double, indexB: Int) -> Bool { atA != atB ? atA < atB : indexA < indexB }
    /// `lines.prefix(max(1, maxLines ?? lines.count))`.
    static func reportLineCap(maxLines: Int?, count: Int) -> Int { max(1, maxLines ?? count) }
    /// `max(1, min(step.covered, rest.count))`.
    static func coveredProgress(covered: Int, remaining: Int) -> Int { max(1, min(covered, remaining)) }
    static func excerptCut(chars: Int) -> Bool { chars > 300 }
    static func redactsKey(chars: Int) -> Bool { chars >= 4 }
    /// `callStartedAt ?? host.callStartedAt ?? lines.first?.at ?? Date()`.
    static func startSource(hasOwn: Bool, hasApp: Bool, hasLines: Bool) -> Int { hasOwn ? 0 : (hasApp ? 1 : (hasLines ? 2 : 3)) }
    /// `host.isRunning ? nil : (callEndedAt ?? Date())`.
    static func endMs(running: Bool, endMs: Int64?, nowMs: Int64) -> Int64? { running ? nil : (endMs ?? nowMs) }
}
