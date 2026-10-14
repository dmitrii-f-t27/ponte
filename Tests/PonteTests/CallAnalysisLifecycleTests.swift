// CallAnalysisModel over whole calls, without the network or the Keychain: a fake host (the transcript, the call
// state, a temporary report folder), the fake service of CallAnalysisTests (replies at once or when a gate opens,
// cancelled requests counted), MemoryAnalysisKeyStore or KeychainAnalysisKeyStore over fake Security calls.
// Covered: reports across two calls, quit (autosave, the bounded wait, abandoned requests), turning the analysis off
// and deleting the key while requests are in flight, stale probes, the key bound to its base URL, a foreign
// Keychain item, cut replies (notes never applied, a cut report marked incomplete), chunk notes kept.
// Keys here are fake ("test-key-…").
import Foundation
@testable import PonteApp
import PonteCore
@testable import PonteSpeech
import Security
import Testing

// MARK: - Fakes

@MainActor
final class AnalysisFakeApp: CallAnalysisApp {
    var lines: [ConversationLine] = []
    var isRunning = false
    var callStartedAt: Date?
    var activeSourceName: String? = "Zoom"
    var banner: Banner?
    let reportFolder: URL

    init() {
        reportFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ponte-analysis-life-\(UUID().uuidString)")
    }

    func startCall(_ lines: [ConversationLine] = []) {
        self.lines = lines
        isRunning = true
        callStartedAt = Date()
    }

    var reportFiles: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: reportFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Ponte-report-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func removeFolder() { try? FileManager.default.removeItem(at: reportFolder) }
}

/// A Keychain of generic passwords keyed by service and account; `plant` puts in an item another app made, which
/// Ponte can read only under its own account and can never delete.
final class AnalysisFakeKeychain: @unchecked Sendable {
    struct Item {
        var secret: Data
        var foreign: Bool
    }

    private let lock = NSLock()
    private var items: [String: Item] = [:]
    private(set) var log: [String] = []

    private static func name(_ service: String, _ account: String) -> String { service + "|" + account }

    func plant(_ secret: Data, service: String, account: String, foreign: Bool) {
        lock.withLock { items[Self.name(service, account)] = Item(secret: secret, foreign: foreign) }
    }

    func secret(service: String, account: String) -> Data? { lock.withLock { items[Self.name(service, account)]?.secret } }
    var operations: [String] { lock.withLock { log } }

    var calls: AnalysisKeychainCalls {
        AnalysisKeychainCalls(
            copy: { service, account in
                self.lock.withLock {
                    self.log.append("copy")
                    guard let item = self.items[Self.name(service, account)] else { return (errSecItemNotFound, nil) }
                    return (errSecSuccess, item.secret)
                }
            },
            add: { service, account, secret in
                self.lock.withLock {
                    self.log.append("add")
                    guard self.items[Self.name(service, account)] == nil else { return errSecDuplicateItem }
                    self.items[Self.name(service, account)] = Item(secret: secret, foreign: false)
                    return errSecSuccess
                }
            },
            delete: { service, account in
                self.lock.withLock {
                    self.log.append("delete")
                    guard let item = self.items[Self.name(service, account)] else { return errSecItemNotFound }
                    guard !item.foreign else { return errSecInvalidOwnerEdit }
                    self.items[Self.name(service, account)] = nil
                    return errSecSuccess
                }
            })
    }
}

/// Waits (on the main actor, letting the model's tasks run) until the condition holds; false after the timeout (long:
/// the whole suite runs in parallel and can keep the main actor busy for seconds).
@MainActor
func analysisWait(_ seconds: Double = 60, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

private func line(_ seconds: TimeInterval, _ direction: Direction, _ original: String, _ translation: String? = "перевод",
                  from start: Date = Date()) -> ConversationLine {
    ConversationLine(direction: direction, at: start.addingTimeInterval(seconds), original: original, translation: translation)
}

private let twoLines = [
    line(1, .incoming, "Bom dia! O preço é R$ 5.400,00.", "Доброе утро! Цена 5 400,00 реалов."),
    line(3, .outgoing, "Отправьте договор до пятницы.", "Envie o contrato até sexta."),
]

/// A model set up for the fake service: its base URL applied, a key saved for it, private defaults.
@MainActor
private func analysisModel(_ service: AnalysisTestService, store: AnalysisKeyStore = MemoryAnalysisKeyStore(),
                           suite: String = "ponte-analysis-life-\(UUID().uuidString)")
    throws -> (CallAnalysisModel, AnalysisFakeApp, () -> Void) {
    let defaults = try #require(UserDefaults(suiteName: suite))
    let model = CallAnalysisModel(defaults: defaults, keyStore: store, session: service.session, testMode: false)
    model.loadKeyIfNeeded()
    #expect(model.applyBaseURL(service.baseURL) == nil)
    #expect(model.saveKey("test-key-lifecycle"))
    #expect(model.configured && model.enabled)
    let app = AnalysisFakeApp()
    return (model, app, {
        defaults.removePersistentDomain(forName: suite)
        app.removeFolder()
    })
}

private func isReport(_ user: String) -> Bool { user.hasPrefix("Сведения о звонке:") }

// MARK: - Calls and reports

@MainActor @Suite("Call analysis: whole calls") struct CallAnalysisLifecycleTests {

    /// The report of call 1, still being written when call 2 starts, neither blocks nor labels call 2's window; it
    /// arrives as a file.
    @Test func reportOfThePreviousCallGoesToAFile() async throws {
        let gate = AnalysisGate()
        let service = AnalysisTestService { user in
            isReport(user) ? AnalysisTestService.chat("Кратко\nОтчёт первого звонка.").gated(gate) : AnalysisTestService.chat("N")
        }
        let (model, app, cleanup) = try analysisModel(service)
        defer { cleanup() }

        app.startCall(twoLines)
        model.callStarted(app)
        app.isRunning = false
        model.callStopped(app)
        #expect(model.building && model.showReport)
        #expect(await analysisWait { service.requests.count == 1 })

        // Call 2 starts while call 1's report is out.
        app.startCall()
        model.callStarted(app)
        #expect(!model.building && model.progressText == nil && model.buildStartedAt == nil)
        #expect(model.buildsInFlight == 1)
        #expect(model.buildCheck == AnalysisRules.checkNoLines)
        #expect(!model.reportButtonEnabled(lines: 0))
        app.lines = [line(1, .incoming, "Olá", "Привет")]
        #expect(model.buildCheck == AnalysisRules.checkOK)
        #expect(model.reportButtonEnabled(lines: 1))

        gate.open()
        #expect(await analysisWait { model.buildsInFlight == 0 })
        #expect(model.report == nil)
        #expect(model.reportError == nil)
        let saved = try #require(model.autosavedURL)
        #expect(try String(contentsOf: saved, encoding: .utf8).contains("Отчёт первого звонка."))
        #expect(app.reportFiles.count == 1)
    }

    /// The previous call's report failing is never shown as this call's error.
    @Test func failureOfThePreviousCallsReportIsNotThisCalls() async throws {
        let gate = AnalysisGate()
        let service = AnalysisTestService { user in
            isReport(user) ? AnalysisTestService.error(401, "bad key").gated(gate) : AnalysisTestService.chat("N")
        }
        let (model, app, cleanup) = try analysisModel(service)
        defer { cleanup() }
        app.startCall(twoLines)
        model.callStarted(app)
        app.isRunning = false
        model.callStopped(app)
        #expect(await analysisWait { service.requests.count == 1 })
        app.startCall()
        model.callStarted(app)
        gate.open()
        #expect(await analysisWait { model.buildsInFlight == 0 })
        #expect(model.reportError == nil)
        #expect(model.previousReportError?.hasPrefix("Отчёт прошлого звонка не получен.") == true)
        #expect(!model.building)
        // This call's own failure is shown as its own.
        app.lines = twoLines
        model.buildReport()
        #expect(await analysisWait { model.reportError != nil })
        #expect(model.reportError?.hasPrefix("Отчёт не получен.") == true)
    }

    /// A report the owner did not save goes to a file when the next call starts, and on quit.
    @Test func unsavedReportsAreWrittenOnTheNextCallAndOnQuit() async throws {
        let service = AnalysisTestService { user in
            isReport(user) ? AnalysisTestService.chat("Кратко\nДоговорились.") : AnalysisTestService.chat("N")
        }
        let (model, app, cleanup) = try analysisModel(service)
        defer { cleanup() }
        app.startCall(twoLines)
        model.callStarted(app)
        app.isRunning = false
        model.callStopped(app)
        #expect(await analysisWait { model.report != nil })
        #expect(app.reportFiles.isEmpty)
        app.startCall(twoLines)
        model.callStarted(app)
        #expect(app.reportFiles.count == 1)
        #expect(model.report == nil)

        // Quit after the second call's report: written once, even if the quit is asked twice (SIGTERM, then ⌘Q).
        app.isRunning = false
        model.callStopped(app)
        #expect(await analysisWait { model.report != nil })
        model.quitting = true
        await model.finishForQuit()
        #expect(app.reportFiles.count == 2)
        #expect(model.report?.savedURL != nil)
        await model.finishForQuit()
        #expect(app.reportFiles.count == 2)
    }

    /// On quit Stop starts no report; one being written gets the bounded wait and is written to a file.
    @Test func quitWaitsBrieflyForAReportBeingWritten() async throws {
        let gate = AnalysisGate()
        let service = AnalysisTestService { user in
            isReport(user) ? AnalysisTestService.chat("Кратко\nУспели до выхода.").gated(gate) : AnalysisTestService.chat("N")
        }
        let (model, app, cleanup) = try analysisModel(service)
        defer { cleanup() }

        // Quitting during a call: Stop sends nothing.
        app.startCall(twoLines)
        model.callStarted(app)
        model.quitting = true
        app.isRunning = false
        model.callStopped(app)
        #expect(!model.building && service.requests.isEmpty)
        await model.finishForQuit()
        #expect(app.reportFiles.isEmpty)

        // A report already being written when the app quits.
        model.quitting = false
        app.startCall(twoLines)
        model.callStarted(app)
        app.isRunning = false
        model.callStopped(app)
        #expect(model.building)
        #expect(await analysisWait { service.requests.count == 1 })
        model.quitting = true
        model.quitWaitOverrideMs = 60_000
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            gate.open()
        }
        await model.finishForQuit()
        #expect(model.buildsInFlight == 0)
        let file = try #require(app.reportFiles.first)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Успели до выхода."))
    }

    /// A report that does not arrive within the wait is abandoned: the request is cancelled, nothing is written.
    @Test func quitAbandonsAReportThatDoesNotArrive() async throws {
        let gate = AnalysisGate()
        let service = AnalysisTestService { user in
            isReport(user) ? AnalysisTestService.chat("никогда").gated(gate) : AnalysisTestService.chat("N")
        }
        let (model, app, cleanup) = try analysisModel(service)
        defer { cleanup() }
        app.startCall(twoLines)
        model.callStarted(app)
        app.isRunning = false
        model.callStopped(app)
        #expect(await analysisWait { service.requests.count == 1 })
        model.quitting = true
        model.quitWaitOverrideMs = 100
        let started = Date()
        await model.finishForQuit()
        #expect(Date().timeIntervalSince(started) < 30)
        #expect(model.buildsInFlight == 0 && !model.building)
        #expect(await analysisWait { service.cancelled == 1 })
        gate.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.reportFiles.isEmpty)
        #expect(model.report == nil)
        #expect(AnalysisRules.quitWaitMs(builds: 1) == AnalysisRules.quitWaitLimitMs)
    }

    /// «Анализировать звонок» off: the requests in flight stop, nothing more is sent, the window says why.
    @Test func turningTheAnalysisOffStopsRequestsInFlight() async throws {
        let gate = AnalysisGate()
        let service = AnalysisTestService { _ in AnalysisTestService.chat("Кратко\nпоздно").gated(gate) }
        let (model, app, cleanup) = try analysisModel(service)
        defer { cleanup() }
        app.startCall(twoLines)
        model.callStarted(app)
        app.isRunning = false
        model.callStopped(app)
        #expect(await analysisWait { service.requests.count == 1 })
        model.enabled = false
        #expect(!model.building && model.buildsInFlight == 0)
        #expect(model.reportError == "Отчёт не составлен: анализ звонка выключен.")
        #expect(await analysisWait { service.cancelled == 1 })
        gate.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.report == nil)
        // The window explains, the button does not build.
        #expect(model.buildCheck == AnalysisRules.checkOff)
        model.openReport(app)
        #expect(model.showReport && !model.building)
        #expect(service.requests.count == 1)
    }

    /// Deleting the key stops a background notes update in flight.
    @Test func deletingTheKeyStopsTheNotesUpdate() async throws {
        let gate = AnalysisGate()
        let service = AnalysisTestService { _ in AnalysisTestService.chat("Заметки").gated(gate) }
        let (model, app, cleanup) = try analysisModel(service)
        defer { cleanup() }
        let start = Date().addingTimeInterval(-600)
        app.startCall((0..<AnalysisRules.forceNewLines).map { line(Double($0), .incoming, "frase \($0)", "фраза \($0)", from: start) })
        model.callStarted(app)
        model.tick(now: Date())
        #expect(model.notesUpdating)
        #expect(await analysisWait { service.requests.count == 1 })
        model.deleteKey()
        #expect(!model.notesUpdating && !model.hasKey)
        #expect(await analysisWait { service.cancelled == 1 })
        model.tick(now: Date())
        #expect(service.requests.count == 1)
        gate.open()
        app.isRunning = false
        model.callStopped(app)
    }

    /// A check of the previous service never shows under the newly chosen one.
    @Test func probeOfThePreviousServiceIsDropped() async throws {
        let gate = AnalysisGate()
        let service = AnalysisTestService([AnalysisTestService.chat("OK").gated(gate)])
        let (model, _, cleanup) = try analysisModel(service)
        defer { cleanup() }
        model.keyMessage = "Ключ сохранён"
        model.probe()
        #expect(model.probeResult == .running)
        #expect(await analysisWait { service.requests.count == 1 })
        model.provider = AnalysisRules.providerDeepSeek
        #expect(model.probeResult == nil && model.keyMessage == nil)
        gate.open()
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.probeResult == nil)
        // Back on the first service a new check answers for it.
        model.provider = AnalysisRules.providerZai
        model.probe()
        #expect(await analysisWait { model.probeResult != .running })
        #expect(model.probeResult == .ok("Сервис отвечает: Z.ai (GLM), модель glm-4.5-flash."))
    }

    /// The report's chunk notes stay in the notebook: «Обновить» sends only the lines not in them yet.
    @Test func reportChunkNotesAreKept() async throws {
        let service = AnalysisTestService { user in
            isReport(user) ? AnalysisTestService.chat("Кратко\nДлинный звонок.") : AnalysisTestService.chat("Заметки по частям [14:05]")
        }
        let (model, app, cleanup) = try analysisModel(service)
        defer { cleanup() }
        let start = Date().addingTimeInterval(-3600)
        app.startCall((0..<150).map { i in
            line(Double(i) * 7, i % 3 == 0 ? .outgoing : .incoming, "Linha \(i): " + String(repeating: "conteúdo ", count: 90),
                 "Строка \(i): " + String(repeating: "текст ", count: 70), from: start)
        })
        model.callStarted(app)
        app.isRunning = false
        model.callStopped(app)
        #expect(await analysisWait { model.report != nil })
        let first = service.userMessages
        #expect(first.count >= 3)
        #expect(first.dropLast().allSatisfy { $0.hasPrefix("Рабочие заметки по звонку") })
        model.buildReport()
        #expect(await analysisWait { !model.building && service.userMessages.count > first.count })
        let again = Array(service.userMessages.dropFirst(first.count))
        #expect(again.count == 1)
        #expect(again.first.map(isReport) == true)
        #expect(again.first?.contains("Заметки по частям [14:05]") == true)
        #expect(again.first?.contains("Linha 0: ") == false)
    }

    /// The analysis off: the report button shows what there is and explains; it never builds.
    @Test func reportButtonFollowsTheToggle() async throws {
        let service = AnalysisTestService([AnalysisTestService.chat("x")])
        let (model, app, cleanup) = try analysisModel(service)
        defer { cleanup() }
        app.startCall(twoLines)
        model.callStarted(app)
        model.enabled = false
        model.openReport(app)
        #expect(model.showReport && !model.building && model.buildCheck == AnalysisRules.checkOff)
        model.buildReport()
        #expect(!model.building)
        app.isRunning = false
        model.callStopped(app)
        #expect(service.requests.isEmpty)
    }
}

// MARK: - The key and its address

@MainActor @Suite("Call analysis: the key and its address") struct CallAnalysisKeyBindingTests {

    /// The key goes only to the address it was saved for: another applied address, a value another process wrote
    /// into the settings, or a key of an older Ponte at a non-default address send nothing.
    @Test func keyGoesOnlyToItsAddress() async throws {
        let service = AnalysisTestService([AnalysisTestService.chat("OK")])
        let store = MemoryAnalysisKeyStore()
        let suite = "ponte-analysis-bind-\(UUID().uuidString)"
        let (model, _, cleanup) = try analysisModel(service, store: store, suite: suite)
        defer { cleanup() }
        let settings = try #require(UserDefaults(suiteName: suite))
        #expect(store.stored(for: AnalysisRules.providerZai)?.baseURL == service.baseURL)

        // Another address applied in the settings.
        #expect(model.applyBaseURL("https://other.ponte.test/v1") == nil)
        #expect(model.configCheck == AnalysisRules.configKeyElsewhere)
        #expect(model.configProblem?.contains("Ключ сохранён для адреса \(service.baseURL)") == true)
        model.probe()
        #expect(model.probeResult.map { if case .failed = $0 { true } else { false } } == true)
        // Back to the saved address: fine again (trailing slashes and the path do not matter).
        #expect(model.applyBaseURL(service.baseURL + "/chat/completions/") == nil)
        #expect(model.configured)

        model.probe()
        #expect(await analysisWait { model.probeResult != .running })
        #expect(service.requests.count == 1)
        // Another process rewrites the setting: nothing is sent there.
        settings.set("https://evil.example/v1", forKey: "analysis.baseURL.zai")
        #expect(model.baseURL == "https://evil.example/v1")
        #expect(model.configCheck == AnalysisRules.configKeyElsewhere)
        model.probe()
        #expect(model.probeResult.map { if case .failed = $0 { true } else { false } } == true)
        #expect(service.requests.count == 1)

        // A key of an older Ponte: the built-in default only.
        let legacy = MemoryAnalysisKeyStore([AnalysisRules.providerZai: AnalysisStoredKey(key: "test-key-old", baseURL: nil)])
        let legacySuite = "ponte-analysis-legacy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: legacySuite))
        defer { defaults.removePersistentDomain(forName: legacySuite) }
        let old = CallAnalysisModel(defaults: defaults, keyStore: legacy, session: service.session, testMode: false)
        old.loadKeyIfNeeded()
        #expect(old.configured)
        defaults.set(service.baseURL, forKey: "analysis.baseURL.zai")   // as if another process wrote it
        #expect(old.configCheck == AnalysisRules.configKeyElsewhere)
        #expect(old.configProblem?.hasPrefix("Ключ сохранён прежней версией Ponte без адреса.") == true)
        old.probe()
        #expect(service.requests.count == 1)
        // Saving the key again binds it to this address.
        #expect(old.saveKey("test-key-old"))
        #expect(old.configured && old.keyBaseURL == service.baseURL)
        // The custom service has no default: an older key never works there.
        let custom = MemoryAnalysisKeyStore([AnalysisRules.providerCustom: AnalysisStoredKey(key: "test-key-c", baseURL: nil)])
        let c = CallAnalysisModel(defaults: defaults, keyStore: custom, session: service.session, testMode: false)
        c.provider = AnalysisRules.providerCustom
        #expect(c.applyBaseURL(service.baseURL) == nil && c.applyModel("m-1") == nil)
        #expect(c.hasKey && c.configCheck == AnalysisRules.configKeyElsewhere)
    }

    /// The base URL and the model apply only when committed and valid: a half-typed address never becomes the
    /// address requests go to.
    @Test func baseURLAndModelApplyOnlyWhenValid() throws {
        let service = AnalysisTestService([AnalysisTestService.chat("OK")])
        let (model, _, cleanup) = try analysisModel(service)
        defer { cleanup() }
        let applied = model.baseURL
        for typed in ["https://", "https:/", "api.z.ai", "", "https://a b", "http://example.com/v1", "http://localhost@evil.example"] {
            #expect(model.applyBaseURL(typed) != nil, "\(typed)")
            #expect(model.baseURL == applied, "\(typed)")
        }
        #expect(model.applyBaseURL("http://example.com/v1") == AnalysisTexts.urlProblem(AnalysisRules.urlHTTPRemote))
        #expect(AnalysisTexts.urlProblem(AnalysisRules.urlHTTPRemote)?.contains("localhost, 127.0.0.1 или [::1]") == true)
        #expect(AnalysisTexts.urlProblem(AnalysisRules.urlNoScheme)?.contains("localhost, 127.0.0.1 или [::1]") == true)
        #expect(model.configured)
        for typed in ["", "  ", "glm 4.5", String(repeating: "m", count: 257)] {
            #expect(model.applyModel(typed) != nil, "\(typed)")
        }
        #expect(model.model == "glm-4.5-flash")
        #expect(model.applyModel(" deepseek/deepseek-chat:free ") == nil)
        #expect(model.model == "deepseek/deepseek-chat:free")
        // http:// to this Mac is fine (the key is then bound elsewhere, so it is not sent).
        #expect(model.applyBaseURL("http://127.0.0.1:11434/v1") == nil)
        #expect(model.configCheck == AnalysisRules.configKeyElsewhere)
    }

    /// The Keychain store deletes its own item and adds a new one (never updates in place); an item of that name it
    /// cannot delete (another app's) makes it refuse with the way out in Russian.
    @Test func keychainWritesNeverReuseAForeignItem() throws {
        let fake = AnalysisFakeKeychain()
        let store = KeychainAnalysisKeyStore(calls: fake.calls)
        let service = AnalysisRules.keychainService(AnalysisRules.providerZai)
        #expect(store.stored(for: AnalysisRules.providerZai) == nil)
        try store.save("test-key-1", baseURL: "https://api.z.ai/api/paas/v4", for: AnalysisRules.providerZai)
        #expect(store.stored(for: AnalysisRules.providerZai) == AnalysisStoredKey(key: "test-key-1", baseURL: "https://api.z.ai/api/paas/v4"))
        try store.save("test-key-2", baseURL: "https://api.z.ai/api/coding/paas/v4", for: AnalysisRules.providerZai)
        #expect(store.stored(for: AnalysisRules.providerZai)?.key == "test-key-2")
        #expect(fake.operations.filter { $0 != "copy" } == ["delete", "add", "delete", "add"])
        // The secret holds the address too.
        let secret = try #require(fake.secret(service: service, account: "ponte"))
        #expect(AnalysisStoredKey(payload: secret)?.baseURL == "https://api.z.ai/api/coding/paas/v4")
        // A bare key of an older Ponte reads without an address.
        fake.plant(Data("test-key-legacy".utf8), service: AnalysisRules.keychainService(AnalysisRules.providerDeepSeek),
                   account: "ponte", foreign: false)
        #expect(store.stored(for: AnalysisRules.providerDeepSeek) == AnalysisStoredKey(key: "test-key-legacy", baseURL: nil))

        // Another app's item under Ponte's name and account: refused, untouched.
        let customService = AnalysisRules.keychainService(AnalysisRules.providerCustom)
        let planted = Data(#"{"key":"attacker","baseURL":"https://evil.example"}"#.utf8)
        fake.plant(planted, service: customService, account: "ponte", foreign: true)
        do {
            try store.save("test-key-3", baseURL: "https://x.ponte.test/v1", for: AnalysisRules.providerCustom)
            Issue.record("a foreign item was overwritten")
        } catch let error as AnalysisKeychainError {
            #expect(error.outcome == AnalysisRules.saveForeign)
            #expect(error.status == errSecDuplicateItem)
            let text = error.errorDescription ?? ""
            #expect(text.contains("«ponte-analysis-custom»"))
            #expect(text.contains("«Связка ключей»"))
        }
        #expect(fake.secret(service: customService, account: "ponte") == planted)
        // An item another app made under another account is never read.
        fake.plant(Data("other".utf8), service: AnalysisRules.keychainService(AnalysisRules.providerZai), account: "evil", foreign: true)
        #expect(store.stored(for: AnalysisRules.providerZai)?.key == "test-key-2")
    }

    /// The settings show the refusal and keep no key.
    @Test func settingsShowTheForeignItemRefusal() throws {
        let fake = AnalysisFakeKeychain()
        fake.plant(Data("planted".utf8), service: "ponte-analysis-zai", account: "ponte", foreign: true)
        let suite = "ponte-analysis-kc-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CallAnalysisModel(defaults: defaults, keyStore: KeychainAnalysisKeyStore(calls: fake.calls), testMode: false)
        model.loadKeyIfNeeded()
        #expect(!model.saveKey("test-key-new"))
        #expect(model.keyMessage?.contains("«ponte-analysis-zai»") == true)
        #expect(model.keyMessage?.contains("«Связка ключей»") == true)
    }

    /// A save that removed the old item and then failed: the settings no longer claim a key.
    @Test func aFailedSaveShowsWhatTheKeychainHolds() throws {
        final class LosingStore: AnalysisKeyStore, @unchecked Sendable {
            private let lock = NSLock()
            private var key: AnalysisStoredKey? = AnalysisStoredKey(key: "test-key-old", baseURL: "https://api.z.ai/api/paas/v4")
            func stored(for provider: Int) -> AnalysisStoredKey? { lock.withLock { key } }
            func save(_ key: String, baseURL: String, for provider: Int) throws {
                lock.withLock { self.key = nil }
                throw AnalysisKeychainError(outcome: AnalysisRules.saveFailed, status: errSecInteractionNotAllowed, service: "ponte-analysis-zai")
            }
            func delete(for provider: Int) throws { lock.withLock { key = nil } }
        }
        let suite = "ponte-analysis-lose-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CallAnalysisModel(defaults: defaults, keyStore: LosingStore(), testMode: false)
        model.loadKeyIfNeeded()
        #expect(model.hasKey)
        #expect(!model.saveKey("test-key-new"))
        #expect(!model.hasKey)
        #expect(model.keyMessage?.contains("Связка ключей не сохранила") == true)
    }
}

// MARK: - Cut replies

@Suite("Call analysis: cut replies") struct CallAnalysisCutReplyTests {

    private static let start = Date(timeIntervalSince1970: 1_791_900_300)

    private static func lines(_ count: Int) -> [AnalysisLine] {
        (0..<count).map { AnalysisLine(at: start + Double($0), direction: .incoming, original: "frase \($0)", translation: "фраза \($0)") }
    }

    /// A notes reply cut at max_tokens is never notes: the update fails with the lines it took.
    @Test func cutNotesReplyIsNotApplied() async throws {
        let service = AnalysisTestService([AnalysisTestService.chat("Заметки, оборванные на", finish: "length")])
        await #expect(throws: AnalysisError(errorClass: AnalysisRules.errCut, status: 200, lines: 10)) {
            _ = try await service.analyst().updateNotes(notes: "", lines: Self.lines(10))
        }
        var notebook = AnalysisNotebook(startedAt: Self.start)
        do {
            let step = try await service.analyst().updateNotesSafely(notes: "", lines: Self.lines(10))
            notebook.applied(notes: step.notes, covering: [], at: Self.start)
            Issue.record("a cut reply was taken")
        } catch let error as AnalysisError {
            #expect(error.errorClass == AnalysisRules.errCut)
            notebook.failed(error, at: Self.start)
        }
        #expect(notebook.notes.isEmpty && notebook.covered.isEmpty)
        #expect(notebook.stopped)   // a cut that persists stops the background notes; the report still tries
    }

    /// After a cut the update tries again at once with half the lines.
    @Test func cutRetriesWithFewerLines() async throws {
        let service = AnalysisTestService { user in
            user.contains("frase 12") ? AnalysisTestService.chat("слишком", finish: "length") : AnalysisTestService.chat("Заметки v1")
        }
        let step = try await service.analyst().updateNotesSafely(notes: "", lines: Self.lines(16))
        #expect(step.notes == "Заметки v1")
        #expect(step.cuts == 1)
        #expect(step.covered == 8 && step.lineCap == 8)
        #expect(service.requests.count == 2)
        #expect(service.userMessages.last?.contains("frase 8") == false)
    }

    /// Long notes are shortened first when a reply is cut.
    @Test func cutWithLongNotesAsksForShorterNotes() async throws {
        let long = String(repeating: "заметка ", count: 500)   // 8 000 bytes
        let service = AnalysisTestService { user in
            if user.hasPrefix("Рабочие заметки по звонку стали слишком длинными") { return AnalysisTestService.chat("Короткие заметки") }
            return user.contains("Короткие заметки") ? AnalysisTestService.chat("Заметки v2") : AnalysisTestService.chat("…", finish: "length")
        }
        let step = try await service.analyst().updateNotesSafely(notes: long, lines: Self.lines(4))
        #expect(step.notes == "Заметки v2" && step.covered == 4 && step.cuts == 1 && step.lineCap == nil)
        #expect(service.userMessages.count == 3)
        #expect(service.userMessages[1].contains("Сократи заметки до \(AnalysisRules.compressChars) знаков"))
    }

    /// A cut that does not pass ends within AnalysisRules.maxCuts requests.
    @Test func cutsEndWithinTheLimit() async {
        let service = AnalysisTestService([AnalysisTestService.chat("…", finish: "length")])
        await #expect(throws: AnalysisError.self) {
            _ = try await service.analyst().updateNotesSafely(notes: "", lines: Self.lines(200))
        }
        #expect(service.requests.count <= AnalysisRules.maxCuts)
    }

    /// A cut report is kept, marked incomplete, in the window and in the TXT.
    @MainActor @Test func cutReportIsMarkedIncomplete() async throws {
        let service = AnalysisTestService { user in
            isReport(user) ? AnalysisTestService.chat("Кратко\nЗвонок о", finish: "length") : AnalysisTestService.chat("N")
        }
        let (model, app, cleanup) = try analysisModel(service)
        defer { cleanup() }
        app.startCall(twoLines)
        model.callStarted(app)
        app.isRunning = false
        model.callStopped(app)
        #expect(await analysisWait { model.report != nil })
        #expect(model.report?.complete == false)
        let url = try #require(model.saveReport())
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(CallReportExporter.incompleteNote))
        #expect(text.contains(CallReportExporter.cutMark))
        let whole = CallReportExporter.text(report: "Кратко", lines: [], facts: CallFacts(startedAt: Self.start, endedAt: nil, sourceName: nil, lines: []),
                                            service: nil, madeAt: Self.start)
        #expect(!whole.contains(CallReportExporter.incompleteNote))
    }
}
