// Tests of the call analysis (CallAnalyst, ChatCompletionsClient, AnalysisNotebook, CallReportExporter,
// CallAnalysisModel's settings) without the network: every request goes to a fake URLProtocol that answers per
// test host. Keys here are fake ("test-key-…"); no test touches the Keychain (MemoryAnalysisKeyStore).
// All fakes are prefixed `Analysis` to avoid clashing with other tests.
import Foundation
@testable import PonteApp
import PonteCore
@testable import PonteSpeech
import Testing

// MARK: - Fake service

/// Answers the requests of one test host with scripted replies (the last one repeats) and records them.
final class AnalysisTestService: @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var error: URLError.Code?
    }

    let host = "t\(UUID().uuidString.lowercased().prefix(12)).ponte.test"
    let session: URLSession
    private let lock = NSLock()
    private var replies: [Reply]
    /// Answers by the user message instead of the queue.
    private let responder: (@Sendable (String) -> Reply)?
    private var recorded: [(request: URLRequest, body: Data)] = []

    init(_ replies: [Reply]) {
        self.replies = replies
        responder = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalysisTestURLProtocol.self]
        session = URLSession(configuration: configuration)
        AnalysisTestURLProtocol.register(self)
    }

    init(responder: @escaping @Sendable (String) -> Reply) {
        replies = []
        self.responder = responder
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalysisTestURLProtocol.self]
        session = URLSession(configuration: configuration)
        AnalysisTestURLProtocol.register(self)
    }

    var requests: [(request: URLRequest, body: Data)] { lock.withLock { recorded } }

    /// The JSON bodies of the requests.
    var bodies: [[String: Any]] {
        requests.compactMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any] }
    }

    /// The user message of each request.
    var userMessages: [String] {
        bodies.map { (($0["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? "" }
    }

    func reply(to request: URLRequest, body: Data) -> Reply {
        lock.withLock {
            recorded.append((request, body))
            if let responder {
                let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                let user = ((json?["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
                return responder(user)
            }
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
    }

    var baseURL: String { "https://\(host)/api/paas/v4" }

    func config(provider: Int = AnalysisRules.providerZai, key: String = "test-key-not-real", base: String? = nil,
                model: String = "glm-4.5-flash") -> AnalysisConfig {
        AnalysisConfig(provider: provider, baseURL: base ?? baseURL, model: model, apiKey: key)
    }

    func analyst(_ config: AnalysisConfig? = nil, waits: AnalysisWaits = AnalysisWaits()) -> CallAnalyst {
        CallAnalyst(client: ChatCompletionsClient(config: config ?? self.config(), session: session),
                    timeZone: TimeZone(identifier: "UTC")!, sleep: { ms in waits.add(ms) })
    }

    static func chat(_ content: String) -> Reply {
        let json: [String: Any] = ["id": "x", "object": "chat.completion",
                                   "choices": [["index": 0, "message": ["role": "assistant", "content": content],
                                                "finish_reason": "stop"]]]
        return Reply(status: 200, body: try! JSONSerialization.data(withJSONObject: json))
    }

    static func error(_ status: Int, _ message: String = "error") -> Reply {
        Reply(status: status, body: Data(#"{"error":{"message":"\#(message)","type":"invalid_request_error"}}"#.utf8))
    }

    static func failure(_ code: URLError.Code) -> Reply { Reply(status: 0, error: code) }
}

final class AnalysisWaits: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Int] = []
    func add(_ ms: Int) { lock.withLock { all.append(ms) } }
    var values: [Int] { lock.withLock { all } }
}

final class AnalysisProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [AnalysisProgress] = []
    func add(_ p: AnalysisProgress) { lock.withLock { all.append(p) } }
    var values: [AnalysisProgress] { lock.withLock { all } }
}

final class AnalysisTestURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var services: [String: AnalysisTestService] = [:]

    static func register(_ service: AnalysisTestService) { lock.withLock { services[service.host] = service } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let service = Self.lock.withLock({ Self.services[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let reply = service.reply(to: request, body: Self.body(of: request))
        if let code = reply.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

// MARK: - Lines

private let analysisStart = Date(timeIntervalSince1970: 1_791_900_300)   // 2026-10-13 14:05:00 UTC
private let utc = TimeZone(identifier: "UTC")!

private func analysisLine(_ seconds: TimeInterval, _ direction: Direction, _ original: String, _ translation: String? = nil,
                          error: Bool = false) -> AnalysisLine {
    AnalysisLine(at: analysisStart + seconds, direction: direction, original: original, translation: translation, hasError: error)
}

private let shortCall = [
    analysisLine(5, .incoming, "Bom dia! O preço é R$ 5.400,00 por mês.", "Доброе утро! Цена — 5 400,00 реалов в месяц."),
    analysisLine(9, .outgoing, "Отправьте договор на dmitrii@example.com до пятницы.", "Envie o contrato para dmitrii@example.com até sexta."),
]

// MARK: - Requests and replies

@Suite("Call analysis") struct CallAnalysisTests {

    @Test func providerDefaultsComeFromTheSpec() {
        #expect(AnalysisRules.defaultBaseURL(AnalysisRules.providerZai) == "https://api.z.ai/api/paas/v4")
        #expect(AnalysisRules.defaultModel(AnalysisRules.providerZai) == "glm-4.5-flash")
        #expect(AnalysisRules.defaultBaseURL(AnalysisRules.providerDeepSeek) == "https://api.deepseek.com")
        #expect(AnalysisRules.defaultModel(AnalysisRules.providerDeepSeek) == "deepseek-chat")
        #expect(AnalysisRules.defaultBaseURL(AnalysisRules.providerCustom).isEmpty)
        #expect(AnalysisRules.defaultModel(AnalysisRules.providerCustom).isEmpty)
        #expect(AnalysisRules.keychainService(AnalysisRules.providerZai) == "ponte-analysis-zai")
        #expect(AnalysisRules.keychainService(AnalysisRules.providerDeepSeek) == "ponte-analysis-deepseek")
        #expect(AnalysisRules.keychainService(AnalysisRules.providerCustom) == "ponte-analysis-custom")
        let deepseek = AnalysisConfig(provider: AnalysisRules.providerDeepSeek, baseURL: "https://api.deepseek.com/",
                                      model: "deepseek-chat", apiKey: "k-1")
        #expect(deepseek.endpoint?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(!deepseek.description.contains("k-1"))
        #expect(AnalysisRules.requestTimeoutMs == 90_000)
    }

    @Test func requestShape() async throws {
        let service = AnalysisTestService([AnalysisTestService.chat("Заметки: цена 5 400,00 [14:05]")])
        let result = try await service.analyst().updateNotes(notes: "", lines: shortCall)
        #expect(result.notes == "Заметки: цена 5 400,00 [14:05]")
        #expect(result.covered == 2)

        let (request, body) = try #require(service.requests.first)
        #expect(request.url?.absoluteString == "https://\(service.host)/api/paas/v4/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-not-real")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 90)
        let json = try #require((try JSONSerialization.jsonObject(with: body)) as? [String: Any])
        #expect(json["model"] as? String == "glm-4.5-flash")
        #expect((json["temperature"] as? Double).map { abs($0 - 0.2) < 1e-12 } == true)
        #expect(json["max_tokens"] as? Int == 4096)
        #expect(json["stream"] as? Bool == false)
        #expect((json["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages[0]["content"] as? String == CallAnalysisPrompts.system)
        let user = try #require(messages[1]["content"] as? String)
        #expect(user.contains("<заметки>\n(пока пусто)\n</заметки>"))
        #expect(user.contains("[14:05:05] Собеседник (pt-BR): Bom dia! O preço é R$ 5.400,00 por mês.\n"
                              + "    перевод (ru-RU): Доброе утро! Цена — 5 400,00 реалов в месяц."))
        #expect(user.contains("[14:05:09] Я (ru-RU): Отправьте договор на dmitrii@example.com до пятницы."))
        #expect(CallAnalysisPrompts.system.contains("Ничего не придумывай"))
        #expect(CallAnalysisPrompts.system.contains("(не уверен)"))
    }

    @Test func onlyZaiGetsTheThinkingSwitch() throws {
        for provider in [AnalysisRules.providerDeepSeek, AnalysisRules.providerCustom] {
            let config = AnalysisConfig(provider: provider, baseURL: "https://api.deepseek.com", model: "deepseek-chat", apiKey: "k-1")
            let request = try ChatCompletionsClient(config: config).urlRequest(messages: [.user("x")], maxTokens: 10, timeoutMs: 1000)
            let json = try #require((try JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any])
            #expect(json["thinking"] == nil)
            #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        }
    }

    @Test func parseReplies() throws {
        let ok = #"{"choices":[{"message":{"role":"assistant","content":"  Отчёт  \n"}}]}"#
        #expect(try ChatCompletionsClient.parse(Data(ok.utf8), status: 200) == "Отчёт")
        let parts = #"{"choices":[{"message":{"content":[{"type":"text","text":"А"},{"type":"text","text":"Б"}]}}]}"#
        #expect(try ChatCompletionsClient.parse(Data(parts.utf8), status: 200) == "АБ")
        let thinkingOnly = #"{"choices":[{"message":{"content":"","reasoning_content":"думаю"}}]}"#
        #expect(throws: AnalysisError(errorClass: AnalysisRules.errEmpty, status: 200)) {
            try ChatCompletionsClient.parse(Data(thinkingOnly.utf8), status: 200)
        }
        #expect(throws: AnalysisError(errorClass: AnalysisRules.errEmpty, status: 200)) {
            try ChatCompletionsClient.parse(Data(#"{"choices":[]}"#.utf8), status: 200)
        }
        #expect(throws: AnalysisError(errorClass: AnalysisRules.errBadReply, status: 200)) {
            try ChatCompletionsClient.parse(Data("<html>ok</html>".utf8), status: 200)
        }
        #expect(throws: AnalysisError(errorClass: AnalysisRules.errAuth, status: 401, message: "Invalid API key •••")) {
            try ChatCompletionsClient.parse(Data(#"{"error":{"message":"Invalid API key test-key-not-real"}}"#.utf8),
                                            status: 401, key: "test-key-not-real")
        }
        #expect(throws: AnalysisError(errorClass: AnalysisRules.errPayment, status: 402, message: "Insufficient Balance")) {
            try ChatCompletionsClient.parse(Data(#"{"error":{"message":"Insufficient Balance"}}"#.utf8), status: 402)
        }
    }

    @Test func errorClassesOverTheWire() async {
        let cases: [(AnalysisTestService.Reply, Int)] = [
            (AnalysisTestService.error(401), AnalysisRules.errAuth),
            (AnalysisTestService.error(403), AnalysisRules.errAuth),
            (AnalysisTestService.error(402), AnalysisRules.errPayment),
            (AnalysisTestService.error(404), AnalysisRules.errNotFound),
            (AnalysisTestService.error(400), AnalysisRules.errRejected),
            (AnalysisTestService.error(429), AnalysisRules.errRateLimit),
            (AnalysisTestService.error(500), AnalysisRules.errServer),
            (AnalysisTestService.error(503), AnalysisRules.errServer),
            (AnalysisTestService.failure(.timedOut), AnalysisRules.errTimeout),
            (AnalysisTestService.failure(.notConnectedToInternet), AnalysisRules.errNetwork),
            (AnalysisTestService.failure(.cannotConnectToHost), AnalysisRules.errNetwork),
        ]
        for (reply, expected) in cases {
            let service = AnalysisTestService([reply])
            do {
                _ = try await service.analyst().updateNotes(notes: "", lines: shortCall)
                Issue.record("no error for \(reply.status) \(String(describing: reply.error))")
            } catch let error as AnalysisError {
                #expect(error.errorClass == expected, "\(reply.status) \(String(describing: reply.error))")
                #expect(error.isTransient == AnalysisRules.isTransient(expected))
                #expect(!(error.errorDescription ?? "").isEmpty)
            } catch {
                Issue.record("not an AnalysisError: \(error)")
            }
        }
    }

    @Test func settingsThatCannotWorkSendNothing() async {
        let service = AnalysisTestService([AnalysisTestService.chat("x")])
        let configs: [(AnalysisConfig, Int)] = [
            (service.config(key: ""), AnalysisRules.errNoKey),
            (service.config(key: "test key"), AnalysisRules.errNoKey),
            (service.config(key: "test-key\nX-Other: 1"), AnalysisRules.errNoKey),
            (service.config(base: "api.z.ai/api/paas/v4"), AnalysisRules.errBadURL),
            (service.config(base: "https://"), AnalysisRules.errBadURL),
            (service.config(model: " "), AnalysisRules.errBadURL),
        ]
        for (config, expected) in configs {
            do {
                _ = try await service.analyst(config).updateNotes(notes: "", lines: shortCall)
                Issue.record("no error for \(config)")
            } catch let error as AnalysisError {
                #expect(error.errorClass == expected, "\(config)")
            } catch {
                Issue.record("not an AnalysisError: \(error)")
            }
        }
        #expect(service.requests.isEmpty)
    }

    @Test func linesAreFormattedAndCut() {
        let pending = analysisLine(3, .incoming, "Sem tradução ainda")
        #expect(CallAnalysisPrompts.formatLine(pending, timeZone: utc) == "[14:05:03] Собеседник (pt-BR): Sem tradução ainda\n    перевод: нет")
        let long = analysisLine(4, .outgoing, String(repeating: "ж", count: 5000), "x")
        let text = CallAnalysisPrompts.formatLine(long, timeZone: utc)
        #expect(text.utf8.count <= AnalysisRules.maxLineBytes)
        #expect(text.utf8.count >= AnalysisRules.maxLineBytes - 1)   // cut at a character boundary (2-byte letters)
        #expect(CallAnalysisPrompts.cut("абв", maxBytes: 3) == "а")
        #expect(CallAnalysisPrompts.cut("абв", maxBytes: 100) == "абв")
        #expect(CallAnalysisPrompts.reportSections == ["Кратко", "Участники", "Важные данные", "Договорённости", "Задачи",
                                                      "Открытые вопросы", "Риски и на что обратить внимание", "Следующие шаги"])
        let facts = CallFacts(startedAt: analysisStart, endedAt: analysisStart + 42 * 60, sourceName: "Chrome (Meet)", lines: shortCall)
        let report = CallAnalysisPrompts.reportUser(notes: "", lines: "L", facts: facts, timeZone: utc)
        #expect(report.contains("Дата и время: 13.10.2026 14:05–14:47 (42 мин)\nИсточник звука: Chrome (Meet)\nРеплик: 2 (собеседник: 1, я: 1)"))
        for section in CallAnalysisPrompts.reportSections { #expect(report.contains(section)) }
        #expect(report.contains("Кто — что — срок"))
    }

    /// A long transcript: the notes update takes the oldest lines that fit one request, exactly as chunkTake says.
    @Test func notesUpdateTakesOneChunk() async throws {
        let lines = (0..<120).map { i in
            analysisLine(Double(i) * 10, i % 2 == 0 ? .incoming : .outgoing,
                         "Frase número \(i) " + String(repeating: "palavra ", count: 120),
                         "Фраза номер \(i) " + String(repeating: "слово ", count: 80))
        }
        let service = AnalysisTestService([AnalysisTestService.chat("N1")])
        let result = try await service.analyst().updateNotes(notes: "старые заметки", lines: lines)
        let used = CallAnalysisPrompts.system.utf8.count + CallAnalysisPrompts.notesUser(notes: "старые заметки", lines: "").utf8.count
        let sizes = lines.map { CallAnalysisPrompts.formatLine($0, timeZone: utc).utf8.count + 1 }
        #expect(result.covered == AnalysisRules.chunkTake(sizes: sizes, usedBytes: used))
        #expect(result.covered > 1 && result.covered < lines.count)
        let user = try #require(service.userMessages.first)
        #expect(user.contains("старые заметки"))
        #expect(user.contains("Frase número \(result.covered - 1) "))
        #expect(!user.contains("Frase número \(result.covered) "))
        #expect(CallAnalysisPrompts.system.utf8.count + user.utf8.count <= AnalysisRules.maxRequestBytes)
    }

    /// The report of a long call goes into the notes chunk by chunk first; every request stays within the limit.
    @Test func reportOfALongCallGoesThroughTheNotesFirst() async throws {
        let lines = (0..<150).map { i in
            analysisLine(Double(i) * 7, i % 3 == 0 ? .outgoing : .incoming,
                         "Linha \(i): " + String(repeating: "conteúdo ", count: 90), "Строка \(i): " + String(repeating: "текст ", count: 70))
        }
        // The fake answers a notes request with notes and the report request (it carries the facts) with a report.
        let service = AnalysisTestService { user in
            user.hasPrefix("Сведения о звонке:") ? AnalysisTestService.chat("Кратко\nЗвонок о договоре.")
                : AnalysisTestService.chat("Заметки: участники, суммы, сроки [14:05]")
        }
        let progress = AnalysisProgressLog()
        let facts = CallFacts(startedAt: analysisStart, endedAt: analysisStart + 1050, sourceName: "Zoom", lines: lines)
        let report = try await service.analyst().buildReport(notes: "", lines: lines, facts: facts) { progress.add($0) }
        #expect(report.text == "Кратко\nЗвонок о договоре.")
        let users = service.userMessages
        #expect(users.count >= 3)
        #expect(users.dropLast().allSatisfy { $0.hasPrefix("Рабочие заметки по звонку") })
        #expect(users.last?.hasPrefix("Сведения о звонке:") == true)
        #expect(report.chunks == users.count - 1)
        #expect(report.notes == "Заметки: участники, суммы, сроки [14:05]")
        for body in service.bodies {
            let messages = body["messages"] as? [[String: Any]] ?? []
            let bytes = messages.compactMap { $0["content"] as? String }.reduce(0) { $0 + $1.utf8.count }
            #expect(bytes <= AnalysisRules.maxRequestBytes)
        }
        #expect(service.bodies.last?["max_tokens"] as? Int == AnalysisRules.reportMaxTokens)
        let events = progress.values
        #expect(events.first == .notes(chunk: 1, linesLeft: 150))
        #expect(events.last == .report)
        // Every line reached the service exactly once.
        let all = users.joined(separator: "\n")
        for i in [0, 37, 75, 149] { #expect(all.components(separatedBy: "Linha \(i): ").count == 2) }
    }

    @Test func reportRetriesTransientErrors() async throws {
        let service = AnalysisTestService([AnalysisTestService.error(500), AnalysisTestService.failure(.timedOut),
                                           AnalysisTestService.chat("Кратко\nВсё хорошо.")])
        let waits = AnalysisWaits()
        let progress = AnalysisProgressLog()
        let facts = CallFacts(startedAt: analysisStart, endedAt: nil, sourceName: nil, lines: shortCall)
        let report = try await service.analyst(waits: waits).buildReport(notes: "N", lines: shortCall, facts: facts) { progress.add($0) }
        #expect(report.text == "Кратко\nВсё хорошо.")
        #expect(report.chunks == 0)
        #expect(service.requests.count == 3)
        #expect(waits.values == [15_000, 30_000])
        #expect(progress.values.filter { if case .retrying = $0 { true } else { false } }.count == 2)
    }

    @Test func reportGivesUpAfterTheAttemptsOrOnTheKey() async {
        let facts = CallFacts(startedAt: analysisStart, endedAt: nil, sourceName: nil, lines: shortCall)
        let busy = AnalysisTestService([AnalysisTestService.error(429)])
        await #expect(throws: AnalysisError(errorClass: AnalysisRules.errRateLimit, status: 429, message: "error")) {
            _ = try await busy.analyst().buildReport(notes: "", lines: shortCall, facts: facts)
        }
        #expect(busy.requests.count == AnalysisRules.maxAttempts)
        let key = AnalysisTestService([AnalysisTestService.error(401, "bad key")])
        await #expect(throws: AnalysisError(errorClass: AnalysisRules.errAuth, status: 401, message: "bad key")) {
            _ = try await key.analyst().buildReport(notes: "", lines: shortCall, facts: facts)
        }
        #expect(key.requests.count == 1)
    }

    @Test func probe() async {
        let empty = AnalysisTestService([AnalysisTestService.chat("")])
        #expect(await empty.analyst().probe() == nil)
        #expect(empty.bodies.first?["max_tokens"] as? Int == AnalysisRules.probeMaxTokens)
        #expect(empty.requests.first?.request.timeoutInterval == 30)
        let ok = AnalysisTestService([AnalysisTestService.chat("OK")])
        #expect(await ok.analyst().probe() == nil)
        let denied = AnalysisTestService([AnalysisTestService.error(401, "no")])
        #expect(await denied.analyst().probe()?.errorClass == AnalysisRules.errAuth)
        let missing = AnalysisTestService([AnalysisTestService.error(404, "no model")])
        #expect(await missing.analyst().probe()?.errorClass == AnalysisRules.errNotFound)
    }

    /// The background notes: which lines are ready, when an update is due, what success and failure do.
    @Test func notebookFlow() async throws {
        var lines = (1...5).map { analysisLine(Double($0), .incoming, "frase \($0)", "фраза \($0)") }
        lines.insert(analysisLine(6, .outgoing, "без перевода"), at: 0)            // out of order, not translated yet
        lines.append(analysisLine(7, .outgoing, "ошибка перевода", error: true))
        var notebook = AnalysisNotebook(startedAt: analysisStart)
        #expect(notebook.pending(lines, now: analysisStart + 10, all: false).map(\.original)
                == ["frase 1", "frase 2", "frase 3", "frase 4", "frase 5", "ошибка перевода"])
        #expect(notebook.pending(lines, now: analysisStart + 26, all: false).count == 7)   // 20 s later it is ready too
        #expect(notebook.pending(lines, now: analysisStart + 10, all: true).map(\.original)[5] == "без перевода")

        func due(_ seconds: TimeInterval, busy: Bool = false, count: Int = 6) -> Bool {
            notebook.shouldUpdate(running: true, enabled: true, configured: true, busy: busy, pendingCount: count, now: analysisStart + seconds)
        }
        #expect(!due(60))
        #expect(due(120))
        #expect(!due(120, busy: true))
        #expect(!due(500, count: 3))
        #expect(due(5, count: 60))
        #expect(!notebook.shouldUpdate(running: false, enabled: true, configured: true, busy: false, pendingCount: 60, now: analysisStart))

        // A real update through the fake: the next request carries the new notes.
        let service = AnalysisTestService([AnalysisTestService.chat("Заметки v1"), AnalysisTestService.chat("Заметки v2")])
        let pending = notebook.pending(lines, now: analysisStart + 130, all: false)
        let first = try await service.analyst().updateNotes(notes: notebook.notes, lines: pending)
        notebook.applied(notes: first.notes, covering: Array(pending.prefix(first.covered)), at: analysisStart + 130)
        #expect(notebook.notes == "Заметки v1")
        #expect(notebook.covered.count == 7)
        #expect(notebook.pending(lines, now: analysisStart + 130, all: true).isEmpty)
        lines.append(analysisLine(140, .incoming, "nova", "новая"))
        _ = try await service.analyst().updateNotes(notes: notebook.notes, lines: notebook.pending(lines, now: analysisStart + 150, all: false))
        #expect(service.userMessages.last?.contains("<заметки>\nЗаметки v1\n</заметки>") == true)
        #expect(!(service.userMessages.last?.contains("frase 1") ?? true))

        // Failures back off 15 s, then 30 s; an error that will not pass stops the background notes.
        let t = analysisStart + 1000
        notebook.failed(AnalysisError(errorClass: AnalysisRules.errTimeout), at: t)
        #expect(notebook.retryAt == t + 15)
        #expect(!notebook.shouldUpdate(running: true, enabled: true, configured: true, busy: false, pendingCount: 60, now: t + 14))
        #expect(notebook.shouldUpdate(running: true, enabled: true, configured: true, busy: false, pendingCount: 60, now: t + 15))
        notebook.failed(AnalysisError(errorClass: AnalysisRules.errServer, status: 503), at: t + 15)
        #expect(notebook.retryAt == t + 45)
        notebook.failed(AnalysisError(errorClass: AnalysisRules.errAuth, status: 401), at: t + 45)
        #expect(notebook.stopped)
        #expect(!notebook.shouldUpdate(running: true, enabled: true, configured: true, busy: false, pendingCount: 60, now: t + 999))
        notebook.resume()
        #expect(!notebook.stopped && notebook.failures == 0)
        #expect(notebook.shouldUpdate(running: true, enabled: true, configured: true, busy: false, pendingCount: 60, now: t + 999))
    }
}

// MARK: - TXT export

@Test func callReportTXTExport() throws {
    let lines = [
        ConversationLine(direction: .outgoing, at: analysisStart + 9, original: "Отправьте договор.\nСегодня.", translation: nil),
        ConversationLine(direction: .incoming, at: analysisStart + 5, original: "Bom dia!", translation: "Доброе утро!"),
    ]
    let facts = CallFacts(startedAt: analysisStart, endedAt: analysisStart + 42 * 60, sourceName: "Chrome (Meet)",
                          lines: lines.map(AnalysisLine.init))
    let text = CallReportExporter.text(report: "Кратко\nЗвонок о договоре.\n", lines: lines, facts: facts,
                                       service: "Z.ai (GLM), модель glm-4.5-flash", madeAt: analysisStart + 43 * 60, timeZone: utc)
    #expect(text.hasPrefix("PONTE — ОТЧЁТ ПО ЗВОНКУ\n\nДата: 13.10.2026\nВремя: 14:05–14:47, длительность 42 мин\n"
                           + "Источник звука: Chrome (Meet)\nРеплик: 2 (собеседник: 1, я: 1)\n"
                           + "Анализ: Z.ai (GLM), модель glm-4.5-flash\nОтчёт составлен: 13.10.2026 14:48\n"))
    #expect(text.contains("ОТЧЁТ\n\(CallReportExporter.rule)\n\nКратко\nЗвонок о договоре.\n"))
    let transcript = try #require(text.components(separatedBy: "СТЕНОГРАММА\n").last)
    #expect(transcript.contains("[14:05:05] Собеседник (pt-BR → ru-RU)\n  Оригинал: Bom dia!\n  Перевод: Доброе утро!\n"))
    #expect(transcript.contains("[14:05:09] Я (ru-RU → pt-BR)\n  Оригинал: Отправьте договор.\n            Сегодня.\n  Перевод: нет\n"))
    #expect(transcript.range(of: "14:05:05")!.lowerBound < transcript.range(of: "14:05:09")!.lowerBound)   // by time

    #expect(CallReportExporter.fileName(for: analysisStart, timeZone: utc) == "Ponte-report-2026-10-13-1405.txt")
    #expect(CallReportExporter.fileName(for: analysisStart, attempt: 3, timeZone: utc) == "Ponte-report-2026-10-13-1405-3.txt")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ponte-report-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try CallReportExporter.write(text, startedAt: analysisStart, to: folder)
    let second = try CallReportExporter.write(text, startedAt: analysisStart, to: folder)
    #expect(first.pathExtension == "txt")
    #expect(first != second)
    #expect(second.lastPathComponent.hasSuffix("-2.txt"))
    #expect(try String(contentsOf: first, encoding: .utf8) == text)
    #expect(try Data(contentsOf: second) == Data(text.utf8))
}

// MARK: - Settings (memory key store, private defaults)

@MainActor @Test func analysisSettingsKeepTheKeyInTheStore() throws {
    let suite = "ponte-analysis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MemoryAnalysisKeyStore()
    let model = CallAnalysisModel(defaults: defaults, keyStore: store, testMode: false)
    model.loadKeyIfNeeded()
    #expect(model.provider == AnalysisRules.providerZai)
    #expect(model.baseURL == "https://api.z.ai/api/paas/v4")
    #expect(model.model == "glm-4.5-flash")
    #expect(!model.hasKey && !model.enabled && !model.configured)
    #expect(model.configCheck == AnalysisRules.configNoKey)

    #expect(!model.saveKey("bad key with spaces"))
    #expect(!model.saveKey("   "))
    #expect(store.key(for: AnalysisRules.providerZai) == nil)
    #expect(model.saveKey("  test-key-123\n"))
    #expect(store.key(for: AnalysisRules.providerZai) == "test-key-123")
    #expect(model.hasKey && model.enabled && model.configured)   // on by default once a key is saved
    #expect(model.endpointText == "https://api.z.ai/api/paas/v4/chat/completions")
    model.enabled = false
    #expect(!model.enabled)
    #expect(defaults.object(forKey: "analysis.enabled") as? Bool == false)
    model.enabled = true

    model.provider = AnalysisRules.providerDeepSeek
    #expect(defaults.integer(forKey: "analysis.provider") == AnalysisRules.providerDeepSeek)
    #expect(!model.hasKey && !model.configured)
    #expect(model.baseURL == "https://api.deepseek.com" && model.model == "deepseek-chat")
    model.baseURL = "https://example.test/v1"
    #expect(defaults.string(forKey: "analysis.baseURL.deepseek") == "https://example.test/v1")
    #expect(!model.isDefault)
    model.resetToDefaults()
    #expect(model.isDefault)

    model.provider = AnalysisRules.providerZai
    #expect(model.hasKey && model.baseURL == "https://api.z.ai/api/paas/v4")
    model.deleteKey()
    #expect(!model.hasKey && store.key(for: AnalysisRules.providerZai) == nil)

    // Test mode (files instead of devices): nothing is analysed even with a key.
    let test = CallAnalysisModel(defaults: defaults, keyStore: MemoryAnalysisKeyStore([0: "test-key-9"]), testMode: true)
    test.loadKeyIfNeeded()
    #expect(test.hasKey && !test.enabled)
}
