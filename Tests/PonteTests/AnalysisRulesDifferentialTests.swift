// The call analysis rules (Specs/analysis_rules.t27, through the AnalysisRules facade) against their Swift oracle
// (AnalysisRulesLegacy), bit for bit: exhaustive over flags, codes and small ranges, seeded random elsewhere
// (base URLs built from schemes, hosts and paths that matter, random and invalid bytes, pairs of base URLs for the
// key binding, keys, model names, finish reasons, line size lists, times around every threshold, file name
// components over the whole Int32 range).
import Foundation
import PonteSpecs
import PonteSpeech
import Testing

private typealias F = AnalysisRules
private typealias L = AnalysisRulesLegacy

@Suite("Differential: analysis rules") struct AnalysisRulesDifferentialTests {

    @Test func constantsAndTables() {
        let log = DiffLog("analysis constants and tables")
        log.check([F.providerZai, F.providerDeepSeek, F.providerCustom, F.providerCount, F.defaultProvider],
                  [L.providerZai, L.providerDeepSeek, L.providerCustom, L.providerCount, L.defaultProvider], "providers")
        log.check([F.intervalMs, F.minNewLines, F.forceNewLines, F.tickMs, F.lineSettleMs, F.maxRequestBytes, F.maxLineBytes,
                   F.maxNotesBytes, F.notesChars, F.listMax, F.requestTimeoutMs, F.probeTimeoutMs, F.maxTokens,
                   F.reportMaxTokens, F.probeMaxTokens, F.temperatureMilli, F.textOutMax, F.urlMax, F.keyMax],
                  [L.intervalMs, L.minNewLines, L.forceNewLines, L.tickMs, L.lineSettleMs, L.maxRequestBytes, L.maxLineBytes,
                   L.maxNotesBytes, L.notesChars, L.listMax, L.requestTimeoutMs, L.probeTimeoutMs, L.maxTokens,
                   L.reportMaxTokens, L.probeMaxTokens, L.temperatureMilli, L.textOutMax, L.urlMax, L.keyMax], "limits")
        log.check(F.temperature, Double(L.temperatureMilli) / 1000, "temperature")
        log.check([F.kindHTTP, F.kindTimeout, F.kindNetwork, F.kindEmpty, F.kindBadReply, F.kindNoKey, F.kindBadURL, F.kindCut,
                   F.kindKeyElsewhere],
                  [L.kindHTTP, L.kindTimeout, L.kindNetwork, L.kindEmpty, L.kindBadReply, L.kindNoKey, L.kindBadURL, L.kindCut,
                   L.kindKeyElsewhere], "kinds")
        log.check([F.errNone, F.errNetwork, F.errTimeout, F.errAuth, F.errPayment, F.errRateLimit, F.errServer, F.errNotFound,
                   F.errRejected, F.errEmpty, F.errBadReply, F.errNoKey, F.errBadURL, F.errOther, F.errCut, F.errKeyElsewhere],
                  [L.errNone, L.errNetwork, L.errTimeout, L.errAuth, L.errPayment, L.errRateLimit, L.errServer, L.errNotFound,
                   L.errRejected, L.errEmpty, L.errBadReply, L.errNoKey, L.errBadURL, L.errOther, L.errCut, L.errKeyElsewhere],
                  "error classes")
        log.check([F.maxAttempts, F.retryGiveUp, F.retryAgain, F.retryBaseMs, F.retryMaxMs, F.maxBackgroundFailures,
                   F.backgroundRetry, F.backgroundStop],
                  [L.maxAttempts, L.retryGiveUp, L.retryAgain, L.retryBaseMs, L.retryMaxMs, L.maxBackgroundFailures,
                   L.backgroundRetry, L.backgroundStop], "retries")
        log.check([F.urlOK, F.urlEmpty, F.urlNoScheme, F.urlNoHost, F.urlSpace, F.urlTooLong, F.urlHTTPRemote, F.keyOK, F.keyEmpty,
                   F.keyBadChar, F.keyTooLong, F.configOK, F.configNoKey, F.configBadURL, F.configNoModel, F.configKeyElsewhere],
                  [L.urlOK, L.urlEmpty, L.urlNoScheme, L.urlNoHost, L.urlSpace, L.urlTooLong, L.urlHTTPRemote, L.keyOK, L.keyEmpty,
                   L.keyBadChar, L.keyTooLong, L.configOK, L.configNoKey, L.configBadURL, L.configNoModel, L.configKeyElsewhere],
                  "check codes")
        log.check([F.bindOK, F.bindOther, F.bindUnbound, F.modelMax, F.modelOK, F.modelEmpty, F.modelTooLong, F.modelBadChar,
                   F.kcOK, F.kcNotFound, F.kcDuplicate, F.kcOther, F.saveOK, F.saveForeign, F.saveFailed],
                  [L.bindOK, L.bindOther, L.bindUnbound, L.modelMax, L.modelOK, L.modelEmpty, L.modelTooLong, L.modelBadChar,
                   L.kcOK, L.kcNotFound, L.kcDuplicate, L.kcOther, L.saveOK, L.saveForeign, L.saveFailed], "binding, model, Keychain codes")
        log.check([F.finishNone, F.finishStop, F.finishLength, F.finishCut, F.finishOther, F.cutSmaller, F.cutCompress, F.cutFail,
                   F.maxCuts, F.compressFromBytes, F.compressChars],
                  [L.finishNone, L.finishStop, L.finishLength, L.finishCut, L.finishOther, L.cutSmaller, L.cutCompress, L.cutFail,
                   L.maxCuts, L.compressFromBytes, L.compressChars], "reply codes")
        log.check([F.directionIncoming, F.directionOutgoing, F.speakerThem, F.speakerMe, F.openShow, F.openBuild, F.openExplain,
                   F.checkOK, F.checkBusy, F.checkNotSet, F.checkNoLines, F.checkOff, F.quitWaitLimitMs],
                  [L.directionIncoming, L.directionOutgoing, L.speakerThem, L.speakerMe, L.openShow, L.openBuild, L.openExplain,
                   L.checkOK, L.checkBusy, L.checkNotSet, L.checkNoLines, L.checkOff, L.quitWaitLimitMs], "line and report codes")
        log.check(F.firstAttempt, L.firstAttempt, "first attempt")
        log.check(F.bearerPrefix, L.bearerPrefix, "bearer")
        log.check(F.chatPath, L.path, "path")
        log.finish(minimumCases: 13)
    }

    @Test func providers() {
        let log = DiffLog("providerCode, providerID, defaultBaseURL, defaultModel, keychainService, thinkingOff")
        var stored = Array(-2000...2000) + [Int.min, Int.min + 1, Int.max, Int.max - 1, Int(Int32.max), Int(Int32.min)]
        var r = DiffRandom(seed: 0xA11A)
        stored += (0..<2000).map { _ in Int(bitPattern: UInt(r.next())) }
        for p in stored {
            log.check(F.providerCode(stored: p), L.providerCode(stored: p), "\(p)")
            log.check(F.providerID(p), L.providerID(p), "\(p)")
            log.check(F.defaultBaseURL(p), L.defaultBaseURL(p), "\(p)")
            log.check(F.defaultModel(p), L.defaultModel(p), "\(p)")
            log.check(F.keychainService(p), L.keychainService(p), "\(p)")
            log.check(F.thinkingOff(p), L.thinkingOff(p), "\(p)")
        }
        log.finish(minimumCases: 30_000)
    }

    static let schemes = ["https://", "http://", "HTTPS://", "Http://", "hTtPs://", "ftp://", "", "https:/", "https:", "https//",
                          "http:///", "https:///", " https://", "ws://"]
    static let hosts = ["api.z.ai", "api.deepseek.com", "localhost:11434", "127.0.0.1:8080", "пример.рф", "", "a", "a b", "x\ty",
                        "ex\u{7F}", "host\r\n", "API.Z.AI", "é", "\u{00A0}", "openrouter.ai", "%20",
                        // http:// is only for this Mac: the local names, with and without ports, and look-alikes.
                        "localhost", "LocalHost", "127.0.0.1", "[::1]", "[::1]:11434", "localhost:", "localhost:8a", "localhost:0",
                        "localhost@evil.example", "localhost.evil.example", "127.0.0.1.nip.io", "[::1", "::1", "127.0.0.2",
                        "localhost:11434@x", "user@localhost", "LOCALHOST:65535", "localhost\\@x", "localhos", "localhostt"]
    static let paths = ["/api/paas/v4", "/v1", "/", "//", "///", "/chat/completions", "/chat/completions/", "/chat/completions//",
                        "/CHAT/completions", "", "/v1/chat/completions", "chat/completions", "/api/paas/v4/", "?q=1", "#x", "/v1 "]

    @Test func baseURLsAndEndpoints() {
        let log = DiffLog("baseURLCheck, endpoint, endpointCore")
        var r = DiffRandom(seed: 2027)
        var urls: [[UInt8]] = Self.fixtures()
        let schemes = Self.schemes, hosts = Self.hosts, paths = Self.paths
        for scheme in schemes {
            for host in hosts {
                for path in paths { urls.append(Array((scheme + host + path).utf8)) }
            }
        }
        for _ in 0..<6000 {
            var s = r.pick(schemes) + r.pick(hosts)
            for _ in 0..<r.int(0...4) { s += r.pick(paths) }
            urls.append(Array(s.utf8))
        }
        for _ in 0..<3000 { urls.append(Array((r.pick(schemes) + r.text(maxPieces: r.pick([4, 20, 80]))).utf8)) }
        for _ in 0..<3000 { urls.append(r.bytes(maxCount: r.pick([10, 60, 300]))) }
        // Around the length limits: AN_URL_MAX minus the path (2031), the buffer (2048) and beyond.
        for length in [2014, 2015, 2030, 2031, 2032, 2047, 2048, 2049, 3000, 5000] {
            let host = String(repeating: "a", count: max(0, length - 8))
            urls.append(Array(("https://" + host).utf8))
            urls.append(Array(("https://" + host.dropLast(17) + "/chat/completions").utf8))
            urls.append(Array(("https://" + host.dropLast(1) + "/").utf8))
            urls.append([UInt8](repeating: 0x2F, count: length))
        }
        for url in urls {
            log.check(F.baseURLCheck(utf8: url), L.baseURLCheck(utf8: url), "\(url.count) bytes: \(String(decoding: url.prefix(80), as: UTF8.self))")
            log.check(F.endpoint(utf8: url), L.endpoint(utf8: url), "\(url.count) bytes: \(String(decoding: url.prefix(80), as: UTF8.self))")
            log.check(F.endpointCore(utf8: url), L.endpointCore(utf8: url), "\(url.count) bytes: \(String(decoding: url.prefix(80), as: UTF8.self))")
        }
        log.finish(minimumCases: 40_000)
    }

    /// The key binding: pairs of base URLs (variants of one address that send to the same endpoint, and look-alikes
    /// that do not), the binding rule over every flag and provider code, the configuration check with it.
    @Test func keyBinding() {
        let log = DiffLog("sameEndpoint, bindCheck, configCheck")
        var r = DiffRandom(seed: 0xB1D)
        let bases = ["https://api.z.ai/api/paas/v4", "https://api.deepseek.com", "http://localhost:11434/v1", "https://x.ponte.test/v1",
                     "http://[::1]:8080", "https://api.z.ai/api/coding/paas/v4", "HTTPS://API.DEEPSEEK.COM", "http://example.com/v1"]
        let tails = ["", "/", "//", "/chat/completions", "/chat/completions/", "/chat/completions//", "/v1", "/CHAT/COMPLETIONS",
                     " ", "/chat/completions/chat/completions", "?a", "#"]
        var urls: [[UInt8]] = Self.fixtures()
        for base in bases { for tail in tails { urls.append(Array((base + tail).utf8)) } }
        for _ in 0..<400 {
            urls.append(Array((r.pick(Self.schemes) + r.pick(Self.hosts) + r.pick(Self.paths) + r.pick(tails)).utf8))
        }
        for _ in 0..<100 { urls.append(r.bytes(maxCount: 40)) }
        for a in urls.prefix(250) {
            for b in urls.prefix(250) {
                log.check(F.sameEndpoint(a, b), L.sameEndpoint(a, b), "\(String(decoding: a, as: UTF8.self)) | \(String(decoding: b, as: UTF8.self))")
            }
        }
        for _ in 0..<40_000 {
            let a = r.pick(urls), b = r.bool() ? r.pick(urls) : a + Array(r.pick(tails).utf8)
            log.check(F.sameEndpoint(a, b), L.sameEndpoint(a, b), "\(String(decoding: a, as: UTF8.self)) | \(String(decoding: b, as: UTF8.self))")
        }
        // Long addresses around the buffer.
        for length in [2014, 2030, 2031, 2032, 2048, 2049, 4000] {
            let a = Array(("https://" + String(repeating: "a", count: max(0, length - 8))).utf8)
            log.check(F.sameEndpoint(a, a), L.sameEndpoint(a, a), "\(length) bytes")
            log.check(F.sameEndpoint(a, a + [0x2F]), L.sameEndpoint(a, a + [0x2F]), "\(length) bytes + /")
        }
        let bools = [false, true]
        for hasBound in bools { for same in bools { for def in bools {
            for provider in Array(-3...6) + [Int.min, Int.max] {
                log.check(F.bindCheck(hasBound: hasBound, sameAsBound: same, provider: provider, sameAsDefault: def),
                          L.bindCheck(hasBound: hasBound, sameAsBound: same, provider: provider, sameAsDefault: def),
                          describe(hasBound, same, provider, def))
            }
        } } }
        let sizes = [-3, -1, 0, 1, 2, 5, 100, Int(Int32.max), 1 << 40]
        for key in sizes {
            for url in -2...8 {
                for model in sizes {
                    for bind in -2...4 {
                        log.check(F.configCheck(keyBytes: key, urlCheck: url, modelBytes: model, bind: bind),
                                  L.configCheck(keyBytes: key, urlCheck: url, modelBytes: model, bind: bind), describe(key, url, model, bind))
                    }
                }
            }
        }
        log.finish(minimumCases: 100_000)
    }

    @Test func modelsAndKeychainOutcomes() {
        let log = DiffLog("modelCheck, keyWriteOutcome")
        var r = DiffRandom(seed: 4096)
        var models: [[UInt8]] = Self.fixtures() + [[], [0x7F], [0x20], [0x21], [0xFF]]
        for c in 0...255 { models.append(Array("glm-".utf8) + [UInt8(c)]) }
        for length in [255, 256, 257, 1000, 2047, 2048, 2049, 5000] {
            models.append([UInt8](repeating: 0x61, count: length))
            models.append([UInt8](repeating: 0x61, count: length - 1) + [0x20])
        }
        for _ in 0..<6000 { models.append(Array(r.text(maxPieces: r.pick([3, 12, 60])).utf8)) }
        for _ in 0..<4000 { models.append(r.bytes(maxCount: r.pick([8, 64, 300]))) }
        for model in models {
            log.check(F.modelCheck(utf8: model), L.modelCheck(utf8: model), "\(model.count) bytes")
        }
        for added in Array(-5...10) + [Int.min, Int.max] {
            log.check(F.keyWriteOutcome(added: added), L.keyWriteOutcome(added: added), "\(added)")
        }
        log.finish(minimumCases: 10_000)
    }

    @Test func replies() {
        let log = DiffLog("finishCode, replyComplete, afterCut, cutLineCap")
        var r = DiffRandom(seed: 0xF1)
        var words: [[UInt8]] = Self.fixtures()
        for word in ["stop", "length", "content_filter", "sensitive", "insufficient_system_resource", "network_error", "tool_calls",
                     "function_call", "eos", "end_turn", "STOP", "Length", "stop ", " stop", "stopp", "sto", "lengt", "", "null",
                     "content_filter\n", "network_error\u{0}", "sensitivé"] {
            words.append(Array(word.utf8))
        }
        words.append([UInt8](repeating: 0x61, count: 256))
        words.append([UInt8](repeating: 0x61, count: 257))
        words.append(Array("stop".utf8) + [UInt8](repeating: 0, count: 300))
        for _ in 0..<5000 { words.append(Array(r.text(maxPieces: 6).utf8)) }
        for _ in 0..<3000 { words.append(r.bytes(maxCount: r.pick([6, 30, 300]))) }
        for word in words {
            log.check(F.finishCode(utf8: word), L.finishCode(utf8: word), "\(String(decoding: word.prefix(40), as: UTF8.self))")
        }
        for finish in Array(-3...8) + [Int.min, Int.max] {
            log.check(F.replyComplete(finish: finish), L.replyComplete(finish: finish), "\(finish)")
        }
        let taken = Array(-3...300) + [Int.min, Int.max]
        for t in taken {
            log.check(F.cutLineCap(taken: t), L.cutLineCap(taken: t), "\(t)")
            for cuts in [Int.min, -1, 0, 1, 2, 5, 6, 7, 100] {
                for notes in [Int.min, -1, 0, 100, 5999, 6000, 6001, 24_000, Int.max] {
                    log.check(F.afterCut(taken: t, cuts: cuts, notesBytes: notes), L.afterCut(taken: t, cuts: cuts, notesBytes: notes),
                              describe(t, cuts, notes))
                }
            }
        }
        for _ in 0..<20_000 {
            let t = r.int(-1_000_000...1_000_000), c = r.int(-100...100), n = r.int(-1_000_000...1_000_000)
            log.check(F.afterCut(taken: t, cuts: c, notesBytes: n), L.afterCut(taken: t, cuts: c, notesBytes: n), describe(t, c, n))
        }
        log.finish(minimumCases: 50_000)
    }

    @Test func keys() {
        let log = DiffLog("keyCheck")
        var r = DiffRandom(seed: 9091)
        var keys: [[UInt8]] = [[], Array("sk-0123456789abcdef".utf8), Array("abc.def_ghi-JKL~".utf8), Array("sk 1".utf8),
                               Array("sk-1\n".utf8), Array("ключ".utf8), Array("sk-\u{00A0}".utf8), [0x7F], [0x7E], [0x21], [0x20]]
        for c in 0...255 { keys.append([0x73, 0x6B, UInt8(c)]) }
        for length in [1023, 1024, 1025, 2047, 2048, 2049, 4000] {
            keys.append([UInt8](repeating: 0x41, count: length))
            keys.append([UInt8](repeating: 0x41, count: length - 1) + [0x0A])
        }
        for _ in 0..<4000 {
            let n = r.pick([1, 8, 40, 64, 200, 1000, 1030])
            keys.append((0..<r.int(0...n)).map { _ in r.int(0...20) == 0 ? r.pick(DiffRandom.specialBytes) : UInt8(r.int(0x21...0x7E)) })
        }
        for _ in 0..<2000 { keys.append(r.bytes(maxCount: r.pick([8, 64, 1100]))) }
        for _ in 0..<1000 { keys.append(Array(r.text(maxPieces: 12).utf8)) }
        for key in keys {
            log.check(F.keyCheck(utf8: key), L.keyCheck(utf8: key), "\(key.count) bytes")
        }
        log.finish(minimumCases: 7_000)
    }

    @Test func configurationAndLines() {
        let log = DiffLog("configCheck, analysisOn, speaker, lineReady, fits")
        let bools = [false, true]
        let sizes = [-3, -1, 0, 1, 2, 5, 100, Int(Int32.max), 1 << 40]
        for key in sizes {
            for url in -2...8 {
                for model in sizes {
                    for bind in [F.bindOK, F.bindUnbound] {
                        log.check(F.configCheck(keyBytes: key, urlCheck: url, modelBytes: model, bind: bind),
                                  L.configCheck(keyBytes: key, urlCheck: url, modelBytes: model, bind: bind),
                                  describe(key, url, model, bind))
                    }
                }
            }
        }
        for a in bools { for b in bools { for c in bools { for d in bools {
            log.check(F.analysisOn(hasStored: a, stored: b, hasKey: c, testMode: d),
                      L.analysisOn(hasStored: a, stored: b, hasKey: c, testMode: d), describe(a, b, c, d))
        } } } }
        for direction in Array(-50...50) + [Int.min, Int.max] {
            log.check(F.speaker(direction: direction), L.speaker(direction: direction), "\(direction)")
        }
        var r = DiffRandom(seed: 515)
        var times = Array(19_900...20_100) + [Int.min, Int.min + 1, -1, 0, 1, Int.max]
        times += (0..<3000).map { _ in r.int(-1_000_000_000_000...1_000_000_000_000) }
        for ms in times {
            for t in bools {
                for e in bools {
                    log.check(F.lineReady(hasTranslation: t, hasError: e, msSinceLine: ms),
                              L.lineReady(hasTranslation: t, hasError: e, msSinceLine: ms), describe(t, e, ms))
                }
            }
        }
        for _ in 0..<20_000 {
            let bytes = r.pick([r.int(0...5000), r.int(-1_000_000_000_000...1_000_000_000_000), 3998, 3999, 4000, 23_999, 24_000])
            let size = r.pick([1, 2, 3, 4, r.int(-10...10), r.int(-1_000_000_000_000...1_000_000_000_000)])
            let limit = r.pick([AnalysisRules.maxLineBytes, AnalysisRules.maxNotesBytes, r.int(-1_000_000_000_000...1_000_000_000_000)])
            log.check(F.fits(bytes: bytes, charBytes: size, limit: limit), L.fits(bytes: bytes, charBytes: size, limit: limit),
                      describe(bytes, size, limit))
        }
        log.finish(minimumCases: 30_000)
    }

    @Test func updates() {
        let log = DiffLog("shouldUpdate")
        var r = DiffRandom(seed: 120)
        let lines = Array(-3...70) + [Int.min, Int.max, 1000]
        let since = [Int.min, -1, 0, 1, 119_999, 120_000, 120_001, Int.max]
        let until = [Int.min, -1, 0, 1, Int.max]
        for flags in 0..<32 {
            let running = flags & 1 != 0, enabled = flags & 2 != 0, configured = flags & 4 != 0
            let busy = flags & 8 != 0, stopped = flags & 16 != 0
            for n in lines {
                for s in since {
                    for u in until {
                        log.check(F.shouldUpdate(running: running, enabled: enabled, configured: configured, busy: busy, stopped: stopped,
                                                 newLines: n, msSinceLast: s, msUntilRetry: u),
                                  L.shouldUpdate(running: running, enabled: enabled, configured: configured, busy: busy, stopped: stopped,
                                                 newLines: n, msSinceLast: s, msUntilRetry: u),
                                  describe(flags, n, s, u))
                    }
                }
            }
        }
        for _ in 0..<20_000 {
            let flags = r.int(0...31)
            let n = r.int(-100...500), s = r.int(-1_000_000...1_000_000), u = r.int(-100_000...100_000)
            log.check(F.shouldUpdate(running: flags & 1 != 0, enabled: flags & 2 != 0, configured: flags & 4 != 0,
                                     busy: flags & 8 != 0, stopped: flags & 16 != 0, newLines: n, msSinceLast: s, msUntilRetry: u),
                      L.shouldUpdate(running: flags & 1 != 0, enabled: flags & 2 != 0, configured: flags & 4 != 0,
                                     busy: flags & 8 != 0, stopped: flags & 16 != 0, newLines: n, msSinceLast: s, msUntilRetry: u),
                      describe(flags, n, s, u))
        }
        log.finish(minimumCases: 100_000)
    }

    @Test func chunks() {
        let log = DiffLog("chunkTake, fitsOneRequest")
        var r = DiffRandom(seed: 40_000)
        var cases: [([Int], Int)] = [([], 0), ([], 50_000), ([1], 0), ([40_000], 0), ([40_001], 0), ([0, 0, 0], 40_000)]
        cases.append(([Int](repeating: 10, count: 300), 0))
        cases.append(([Int](repeating: 157, count: 256), 0))
        cases.append(([Int](repeating: 157, count: 257), -1_000_000))
        for _ in 0..<6000 {
            let count = r.pick([r.int(0...5), r.int(0...60), r.int(200...320)])
            let typical = r.pick([60, 400, 1500, 4001, 20_000])
            let sizes = (0..<count).map { _ in r.int(0...10) == 0 ? r.int(0...60_000) : r.int(1...typical) }
            let used = r.pick([0, r.int(0...42_000), r.int(-1_000_000...1_000_000), 39_999, 40_000, 40_001])
            cases.append((sizes, used))
        }
        // Lines that fill the request exactly, or miss it by one byte.
        for _ in 0..<1500 {
            let used = r.int(0...39_000)
            var left = AnalysisRules.maxRequestBytes - used
            var sizes: [Int] = []
            while left > 0 {
                let size = min(left, r.int(1...4000))
                sizes.append(size)
                left -= size
            }
            let tail = r.int(0...2)
            sizes.append(contentsOf: (0..<r.int(0...3)).map { _ in r.int(0...10) })
            cases.append((sizes, used + tail - 1))
        }
        for (sizes, used) in cases {
            log.check(F.chunkTake(sizes: sizes, usedBytes: used), L.chunkTake(sizes: sizes, usedBytes: used),
                      "\(sizes.count) sizes, used \(used)")
        }
        for _ in 0..<20_000 {
            let used = r.int(-1_000_000_000...1_000_000_000), remaining = r.pick([r.int(0...80_000), r.int(-1_000_000_000...1_000_000_000)])
            log.check(F.fitsOneRequest(usedBytes: used, remainingBytes: remaining),
                      L.fitsOneRequest(usedBytes: used, remainingBytes: remaining), describe(used, remaining))
        }
        for used in 39_990...40_010 {
            log.check(F.fitsOneRequest(usedBytes: used, remainingBytes: 0), L.fitsOneRequest(usedBytes: used, remainingBytes: 0), "\(used)")
        }
        log.finish(minimumCases: 25_000)
    }

    @Test func errorsAndRetries() {
        let log = DiffLog("httpClass, errorClass, isTransient, retryAction, retryDelayMs, backgroundAfterError, probeOK")
        var statuses = Array(-1000...1000) + [Int.min, Int.max, 65_535, 99_999]
        var r = DiffRandom(seed: 429)
        statuses += (0..<2000).map { _ in Int(bitPattern: UInt(r.next())) }
        for status in statuses {
            log.check(F.httpClass(status: status), L.httpClass(status: status), "\(status)")
        }
        for kind in Array(-3...10) + [Int.min, Int.max] {
            for status in [0, 1, 199, 200, 299, 300, 401, 402, 403, 404, 408, 429, 499, 500, 599, 600, -1, Int.max] {
                log.check(F.errorClass(kind: kind, status: status), L.errorClass(kind: kind, status: status), describe(kind, status))
            }
        }
        let errors = Array(-3...16) + [Int.min, Int.max]
        for error in errors {
            log.check(F.isTransient(error), L.isTransient(error), "\(error)")
            log.check(F.probeOK(error: error), L.probeOK(error: error), "\(error)")
            for attempt in Array(-1000...1000) + [Int.min, Int.max - 1] {
                log.check(F.retryAction(error: error, attempt: attempt), L.retryAction(error: error, attempt: attempt), describe(error, attempt))
            }
            for failures in Array(-20...100) + [Int.min, Int.max] {
                log.check(F.backgroundAfterError(error: error, failures: failures),
                          L.backgroundAfterError(error: error, failures: failures), describe(error, failures))
            }
        }
        for failures in Array(-1000...1000) + [Int.min, Int.max, 1 << 40] + (0..<1000).map({ _ in Int(bitPattern: UInt(r.next())) }) {
            log.check(F.retryDelayMs(failures: failures), L.retryDelayMs(failures: failures), "\(failures)")
        }
        log.finish(minimumCases: 50_000)
    }

    @Test func reportRules() {
        let log = DiffLog("reportOnStop, reportOnOpen, buildCheck, reportButtonEnabled, saveBeforeReset, quitWaitMs, quitHasWork, durationMinutes")
        let bools = [false, true]
        let counts = Array(-3...12) + [Int.min, Int.max, 1000]
        for a in bools {
            for b in bools {
                log.check(F.saveBeforeReset(hasReport: a, saved: b), L.saveBeforeReset(hasReport: a, saved: b), describe(a, b))
                for n in counts {
                    log.check(F.reportButtonEnabled(lines: n, hasReport: a, busy: b), L.reportButtonEnabled(lines: n, hasReport: a, busy: b),
                              describe(n, a, b))
                    for c in bools {
                        log.check(F.reportOnStop(enabled: a, configured: b, lines: n, quitting: c),
                                  L.reportOnStop(enabled: a, configured: b, lines: n, quitting: c), describe(a, b, n, c))
                        for e in bools {
                            log.check(F.buildCheck(enabled: e, busy: a, configured: b, lines: n),
                                      L.buildCheck(enabled: e, busy: a, configured: b, lines: n), describe(e, a, b, n))
                            for reportLines in counts {
                                log.check(F.reportOnOpen(enabled: e, busy: a, hasReport: b, reportLines: reportLines, lines: n, configured: c),
                                          L.reportOnOpen(enabled: e, busy: a, hasReport: b, reportLines: reportLines, lines: n, configured: c),
                                          describe(e, a, b, reportLines, n, c))
                            }
                        }
                    }
                }
            }
        }
        for builds in Array(-5...20) + [Int.min, Int.max] {
            log.check(F.quitWaitMs(builds: builds), L.quitWaitMs(builds: builds), "\(builds)")
            for a in bools {
                for b in bools {
                    log.check(F.quitHasWork(hasReport: a, saved: b, builds: builds), L.quitHasWork(hasReport: a, saved: b, builds: builds),
                              describe(a, b, builds))
                }
            }
        }
        var r = DiffRandom(seed: 60_000)
        var times = Array(-5...5) + [29_999, 30_000, 89_999, 90_000, 149_999, 150_000, Int.min, Int.max - 30_000]
        times += (0..<20_000).map { _ in r.pick([r.int(0...7_200_000), r.int(-1_000_000_000_000_000...1_000_000_000_000_000)]) }
        for ms in times {
            log.check(F.durationMinutes(ms: ms), L.durationMinutes(ms: ms), "\(ms)")
        }
        log.finish(minimumCases: 20_000)
    }

    @Test func reportFileNames() {
        let log = DiffLog("reportFileName")
        var r = DiffRandom(seed: 1405)
        let edges: [Int32] = [Int32.min, -1, 0, 1, 9, 10, 99, 100, 999, 1000, 9999, 10_000, Int32.max]
        for value in edges {
            for attempt in [Int32.min, -1, 0, 1, 2, 9, 10, 12, Int32.max] {
                log.check(F.reportFileName(year: value, month: value, day: value, hour: value, minute: value, attempt: attempt),
                          L.reportFileName(year: value, month: value, day: value, hour: value, minute: value, attempt: attempt),
                          describe(value, attempt))
            }
        }
        for _ in 0..<10_000 {
            func any() -> Int32 { r.pick([r.int32(0...60), r.int32(1990...2100), r.int32(Int32.min...Int32.max)]) }
            let y = any(), mo = any(), d = any(), h = any(), mi = any(), a = r.pick([r.int32(0...20), any()])
            log.check(F.reportFileName(year: y, month: mo, day: d, hour: h, minute: mi, attempt: a),
                      L.reportFileName(year: y, month: mo, day: d, hour: h, minute: mi, attempt: a), describe(y, mo, d, h, mi, a))
        }
        log.finish(minimumCases: 10_000)
    }

    /// The spec's own test texts (an_fixture).
    static func fixtures() -> [[UInt8]] {
        (0..<Int64(AN_FX_COUNT)).map { index in
            var out = [UInt8](repeating: 0, count: Int(AN_URL_MAX))
            let n = Int(an_fixture(index, &out))
            return Array(out[0..<n])
        }
    }

    @Test func movedOutOfSwift() {
        let log = DiffLog("millis, lineBefore, reportLineCap, coveredProgress, excerptCut, redactsKey, startSource, endMs")
        var r = DiffRandom(seed: 0xA1A1)
        for _ in 0..<40_000 {
            let s = r.double()
            log.check(F.millis(s), L.millis(s), "\(s)")
            let a = r.bool() ? r.double() : Double(r.int(0...5)), b = r.bool() ? a : Double(r.int(0...5))
            let ia = r.int(-3...3), ib = r.int(-3...3)
            log.check(F.lineBefore(atA: a, indexA: ia, atB: b, indexB: ib), L.lineBefore(atA: a, indexA: ia, atB: b, indexB: ib), "\(a) \(ia) \(b) \(ib)")
            let cap: Int? = r.bool() ? r.int(-5...500) : nil
            let count = r.int(-5...500)
            log.check(F.reportLineCap(maxLines: cap, count: count), L.reportLineCap(maxLines: cap, count: count), "\(String(describing: cap)) \(count)")
            let covered = r.int(-5...500), remaining = r.int(-5...500)
            log.check(F.coveredProgress(covered: covered, remaining: remaining), L.coveredProgress(covered: covered, remaining: remaining), "\(covered) \(remaining)")
            let end: Int64? = r.bool() ? Int64(r.int(0...2_000_000_000)) : nil
            let now = Int64(r.int(0...2_000_000_000))
            for running in [false, true] { log.check(F.endMs(running: running, endMs: end, nowMs: now), L.endMs(running: running, endMs: end, nowMs: now), "\(running) \(String(describing: end)) \(now)") }
        }
        for n in -5...400 { log.check(F.excerptCut(chars: n), L.excerptCut(chars: n), "\(n)"); log.check(F.redactsKey(chars: n), L.redactsKey(chars: n), "\(n)") }
        for a in [false, true] { for b in [false, true] { for c in [false, true] {
            log.check(F.startSource(hasOwn: a, hasApp: b, hasLines: c), L.startSource(hasOwn: a, hasApp: b, hasLines: c), "\(a) \(b) \(c)")
        } } }
        log.finish(minimumCases: 200_000)
    }
}
