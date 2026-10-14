import AppKit
import Foundation
import Observation
import os
import PonteCore
import PonteSpeech

/// The call analysis in the app: its settings (service, base URL, model, the key in the Keychain, on/off), the
/// background notes while a call runs, and the report after it. Every decision comes from AnalysisRules
/// (Specs/analysis_rules.t27); the requests are CallAnalyst's. Failures never interrupt the call: they show as a
/// quiet status line in the report window and in the settings, never as an alert.
/// AppModel owns one (`analysis`) and calls `callStarted` and `callStopped`.
@MainActor @Observable
final class CallAnalysisModel {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let keyStore: AnalysisKeyStore
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let log = Logger(subsystem: "app.ponte.translator", category: "analysis")
    @ObservationIgnored private let testMode: Bool

    /// The settings keys (UserDefaults); the key itself is only in the Keychain.
    enum Key {
        static let provider = "analysis.provider"
        static let enabled = "analysis.enabled"
        static func baseURL(_ id: String) -> String { "analysis.baseURL.\(id)" }
        static func model(_ id: String) -> String { "analysis.model.\(id)" }
    }

    init(defaults: UserDefaults = .standard, keyStore: AnalysisKeyStore = KeychainAnalysisKeyStore(),
         session: URLSession = .shared, testMode: Bool = LaunchOptions.current.isTestMode) {
        self.defaults = defaults
        self.keyStore = keyStore
        self.session = session
        self.testMode = testMode
        provider = AnalysisRules.providerCode(stored: defaults.object(forKey: Key.provider) == nil
                                              ? AnalysisRules.defaultProvider : defaults.integer(forKey: Key.provider))
        enabledStored = defaults.object(forKey: Key.enabled) as? Bool
    }

    // MARK: Settings

    /// AnalysisRules.provider*.
    var provider: Int {
        didSet {
            guard provider != oldValue else { return }
            defaults.set(provider, forKey: Key.provider)
            probeResult = nil
            reloadKey()
            settingsChanged()
        }
    }

    static func providerName(_ provider: Int) -> String {
        switch provider {
        case AnalysisRules.providerDeepSeek: "DeepSeek"
        case AnalysisRules.providerCustom: "Свой (OpenAI-совместимый)"
        default: "Z.ai (GLM)"
        }
    }

    var providerName: String { Self.providerName(provider) }
    private var providerID: String { AnalysisRules.providerID(provider) }

    /// The base URL of the current service: the stored one, else the spec's default.
    var baseURL: String {
        get {
            _ = settingsRevision
            return defaults.string(forKey: Key.baseURL(providerID)) ?? AnalysisRules.defaultBaseURL(provider)
        }
        set {
            defaults.set(newValue, forKey: Key.baseURL(providerID))
            settingsRevision += 1
            settingsChanged()
        }
    }

    /// The model of the current service: the stored one, else the spec's default.
    var model: String {
        get {
            _ = settingsRevision
            return defaults.string(forKey: Key.model(providerID)) ?? AnalysisRules.defaultModel(provider)
        }
        set {
            defaults.set(newValue, forKey: Key.model(providerID))
            settingsRevision += 1
            settingsChanged()
        }
    }

    /// Back to the spec's base URL and model for the current service.
    func resetToDefaults() {
        defaults.removeObject(forKey: Key.baseURL(providerID))
        defaults.removeObject(forKey: Key.model(providerID))
        settingsRevision += 1
        settingsChanged()
    }

    var isDefault: Bool {
        baseURL == AnalysisRules.defaultBaseURL(provider) && model == AnalysisRules.defaultModel(provider)
    }

    /// Changes of the stored base URL and model (UserDefaults is not observed).
    private var settingsRevision = 0
    private var enabledStored: Bool?

    /// «Анализировать звонок» (AnalysisRules.analysisOn).
    var enabled: Bool {
        get { AnalysisRules.analysisOn(hasStored: enabledStored != nil, stored: enabledStored ?? false, hasKey: hasKey, testMode: testMode) }
        set {
            enabledStored = newValue
            defaults.set(newValue, forKey: Key.enabled)
        }
    }

    // MARK: The key (Keychain only)

    /// The current service's key, read from the Keychain only when needed (the settings, a call, a report) and again
    /// when the service or the key changes. Never logged.
    @ObservationIgnored private var apiKey: String?
    @ObservationIgnored private var keyLoaded = false
    private(set) var hasKey = false
    /// What happened to the key last («Ключ сохранён…» or an error).
    var keyMessage: String?

    /// Reads the key once (the settings call it when they appear; a call and a report call it themselves).
    func loadKeyIfNeeded() {
        if !keyLoaded { reloadKey() }
    }

    private func reloadKey() {
        keyLoaded = true
        apiKey = keyStore.key(for: provider)
        hasKey = !(apiKey ?? "").isEmpty
    }

    /// «Сохранить ключ»: checks the pasted key (AnalysisRules.keyCheck) and writes it to the Keychain.
    /// Returns true when saved (the field then clears).
    @discardableResult
    func saveKey(_ pasted: String) -> Bool {
        let key = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        switch AnalysisRules.keyCheck(utf8: Array(key.utf8)) {
        case AnalysisRules.keyEmpty:
            keyMessage = "Вставьте ключ в поле."
            return false
        case AnalysisRules.keyBadChar:
            keyMessage = "В ключе есть пробелы, переводы строк или не латинские символы. Скопируйте ключ ещё раз."
            return false
        case AnalysisRules.keyTooLong:
            keyMessage = "Слишком длинный ключ: не больше \(AnalysisRules.keyMax) символов."
            return false
        default:
            break
        }
        do {
            try keyStore.save(key, for: provider)
            reloadKey()
            keyMessage = "Ключ \(providerName) сохранён в связке ключей macOS."
            log.info("analysis key saved for \(self.providerID, privacy: .public)")
            probeResult = nil
            settingsChanged()
            return true
        } catch {
            keyMessage = error.localizedDescription
            return false
        }
    }

    /// «Удалить ключ».
    func deleteKey() {
        do {
            try keyStore.delete(for: provider)
            reloadKey()
            keyMessage = "Ключ \(providerName) удалён из связки ключей."
            log.info("analysis key deleted for \(self.providerID, privacy: .public)")
            probeResult = nil
        } catch {
            keyMessage = error.localizedDescription
        }
    }

    // MARK: Configuration

    var config: AnalysisConfig {
        AnalysisConfig(provider: provider, baseURL: baseURL, model: model, apiKey: apiKey ?? "")
    }

    /// AnalysisRules.config*.
    var configCheck: Int { config.check }
    var configured: Bool { configCheck == AnalysisRules.configOK }
    var urlCheck: Int { config.urlCheck }
    var endpointText: String? { config.endpoint?.absoluteString }

    private func analyst() -> CallAnalyst {
        CallAnalyst(client: ChatCompletionsClient(config: config, session: session))
    }

    /// A new key, URL, model or service: the stopped background notes may try again.
    private func settingsChanged() {
        notebook.resume()
        if app?.isRunning == true { notesStatus = nil }
    }

    // MARK: «Проверить»

    enum ProbeResult: Equatable {
        case running
        case ok(String)
        case failed(String)
    }

    var probeResult: ProbeResult?

    func probe() {
        guard probeResult != .running else { return }
        guard configured else {
            probeResult = .failed(AnalysisError.configMessage(configCheck))
            return
        }
        probeResult = .running
        let analyst = analyst()
        let name = "\(providerName), модель \(config.trimmedModel)"
        Task { [weak self] in
            let failure = await analyst.probe()
            guard let self else { return }
            if let failure {
                self.probeResult = .failed(failure.localizedDescription)
            } else {
                self.probeResult = .ok("Сервис отвечает: \(name).")
            }
        }
    }

    // MARK: The call

    @ObservationIgnored private weak var app: AppModel?
    /// Each call (and each settings reset) gets a new generation; late answers of an older one are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var notebook = AnalysisNotebook()
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var callStartedAt: Date?
    @ObservationIgnored private var callEndedAt: Date?
    @ObservationIgnored private var sourceName: String?
    /// The quiet status of the background notes («Заметки обновлены…», a failure); nil when there is nothing to say.
    private(set) var notesStatus: String?
    private(set) var notesUpdating = false

    /// A call starts (AppModel.start): a report the owner did not save goes to a file first, then everything resets.
    func callStarted(_ app: AppModel) {
        self.app = app
        loadKeyIfNeeded()
        if AnalysisRules.saveBeforeReset(hasReport: report != nil, saved: report?.savedURL != nil), let report {
            autosave(report)
        }
        generation += 1
        tickTask?.cancel()
        updateTask?.cancel()
        updateTask = nil
        notesUpdating = false
        report = nil
        reportError = nil
        autosavedURL = nil
        callStartedAt = app.callStartedAt ?? Date()
        callEndedAt = nil
        sourceName = app.activeSourceName
        notebook = AnalysisNotebook(startedAt: callStartedAt ?? Date())
        notesStatus = nil
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick(now: Date())
                try? await Task.sleep(for: .milliseconds(AnalysisRules.tickMs))
            }
        }
    }

    /// The call stopped (AppModel.stop): the background notes end; the report is built when the rules say so.
    func callStopped(_ app: AppModel) {
        self.app = app
        loadKeyIfNeeded()
        tickTask?.cancel()
        tickTask = nil
        // A notes update in flight is dropped: its lines are still pending, so the report takes them.
        updateTask?.cancel()
        updateTask = nil
        notesUpdating = false
        callEndedAt = Date()
        if AnalysisRules.reportOnStop(enabled: enabled, configured: configured, lines: app.lines.count) {
            // A report asked for during the call covers only part of it: the final one replaces it.
            buildReport(replacingRunning: true)
            showReport = true
        }
    }

    /// One look at the transcript: update the notes when AnalysisRules.shouldUpdate says so.
    func tick(now: Date) {
        guard let app else { return }
        let lines = app.lines.map(AnalysisLine.init)
        let pending = notebook.pending(lines, now: now, all: false)
        // A report of this call in progress uses the service too; one of an earlier call does not hold the notes back.
        let busy = updateTask != nil || (building && buildGeneration == generation)
        guard notebook.shouldUpdate(running: app.isRunning, enabled: enabled, configured: configured,
                                    busy: busy, pendingCount: pending.count, now: now) else { return }
        let analyst = analyst()
        let notes = notebook.notes
        let gen = generation
        notesUpdating = true
        updateTask = Task { [weak self] in
            do {
                let result = try await analyst.updateNotes(notes: notes, lines: pending)
                self?.notesUpdated(result.notes, covering: Array(pending.prefix(result.covered)), generation: gen)
            } catch is CancellationError {
                return
            } catch {
                self?.notesFailed(ChatCompletionsClient.classify(error), generation: gen)
            }
        }
    }

    private func notesUpdated(_ notes: String, covering lines: [AnalysisLine], generation gen: Int) {
        guard gen == generation else { return }
        updateTask = nil
        notesUpdating = false
        notebook.applied(notes: notes, covering: lines, at: Date())
        notesStatus = "Заметки обновлены в \(Self.clock(Date())): в них \(notebook.covered.count) реплик."
        log.info("analysis notes updated: \(lines.count, privacy: .public) lines")
    }

    private func notesFailed(_ error: AnalysisError, generation gen: Int) {
        guard gen == generation else { return }
        updateTask = nil
        notesUpdating = false
        notebook.failed(error, at: Date())
        let text = error.localizedDescription
        if notebook.stopped {
            notesStatus = "Заметки во время звонка остановлены: \(text) Отчёт после звонка всё равно попробует."
        } else {
            let wait = AnalysisRules.retryDelayMs(failures: notebook.failures) / 1000
            notesStatus = "Заметки не обновились: \(text) Повторю через \(wait) с."
        }
        log.error("analysis notes failed: class \(error.errorClass, privacy: .public) status \(error.status, privacy: .public)")
    }

    // MARK: The report

    /// A built report and what it was built from.
    struct Report: Equatable {
        var text: String
        var facts: CallFacts
        var lines: [ConversationLine]
        var madeAt: Date
        var service: String
        var savedURL: URL?

        static func == (a: Report, b: Report) -> Bool {
            a.text == b.text && a.madeAt == b.madeAt && a.savedURL == b.savedURL && a.lines.map(\.id) == b.lines.map(\.id)
        }
    }

    var showReport = false
    private(set) var report: Report?
    private(set) var building = false
    private(set) var buildStartedAt: Date?
    private(set) var progressText: String?
    private(set) var reportError: String?
    /// A report of an earlier call that was written to a file without the owner's «Сохранить в TXT».
    private(set) var autosavedURL: URL?
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    /// Each build gets an ID; a build that was replaced never touches the state.
    @ObservationIgnored private var buildID = 0
    /// The call generation of the build in progress.
    @ObservationIgnored private var buildGeneration = 0

    var lineCount: Int { app?.lines.count ?? 0 }

    /// «Отчёт по звонку» in the toolbar is enabled (AnalysisRules.reportButtonEnabled).
    func reportButtonEnabled(lines: Int) -> Bool {
        AnalysisRules.reportButtonEnabled(lines: lines, hasReport: report != nil, busy: building)
    }

    /// «Отчёт по звонку»: show, build or explain (AnalysisRules.reportOnOpen); the window opens in every case.
    func openReport(_ app: AppModel) {
        self.app = app
        loadKeyIfNeeded()
        if AnalysisRules.reportOnOpen(busy: building, hasReport: report != nil, reportLines: report?.lines.count ?? 0,
                                      lines: app.lines.count, configured: configured) == AnalysisRules.openBuild {
            buildReport()
        }
        showReport = true
    }

    /// AnalysisRules.check* for «Обновить».
    var buildCheck: Int { AnalysisRules.buildCheck(busy: building, configured: configured, lines: lineCount) }

    /// Builds the report from the notes and every line not in them yet. `replacingRunning` drops a build in progress
    /// (a report asked for during the call) and starts over with every line.
    func buildReport(replacingRunning: Bool = false) {
        guard let app else { return }
        if replacingRunning, building {
            reportTask?.cancel()
            reportTask = nil
            building = false
        }
        guard AnalysisRules.buildCheck(busy: building, configured: configured, lines: app.lines.count) == AnalysisRules.checkOK
        else { return }
        let conversation = app.lines
        let lines = conversation.map(AnalysisLine.init)
        let started = callStartedAt ?? app.callStartedAt ?? lines.first?.at ?? Date()
        let ended = app.isRunning ? nil : (callEndedAt ?? Date())
        let facts = CallFacts(startedAt: started, endedAt: ended, sourceName: sourceName ?? app.activeSourceName, lines: lines)
        let pending = notebook.pending(lines, now: Date(), all: true)
        let notes = notebook.notes
        let analyst = analyst()
        let service = "\(providerName), модель \(config.trimmedModel)"
        let gen = generation
        buildID += 1
        let id = buildID
        buildGeneration = gen
        building = true
        buildStartedAt = Date()
        reportError = nil
        progressText = "Готовлю отчёт…"
        log.info("analysis report: \(pending.count, privacy: .public) lines beyond the notes")
        reportTask = Task { [weak self] in
            do {
                let result = try await analyst.buildReport(notes: notes, lines: pending, facts: facts) { progress in
                    Task { @MainActor in self?.show(progress, build: id) }
                }
                self?.reportBuilt(Report(text: result.text, facts: facts, lines: conversation, madeAt: Date(),
                                         service: service, savedURL: nil), generation: gen, build: id)
            } catch {
                self?.reportFailed(error, build: id)
            }
        }
    }

    private func show(_ progress: AnalysisProgress, build id: Int) {
        guard building, id == buildID else { return }
        switch progress {
        case .notes(let chunk, let left):
            progressText = "Длинный звонок: сжимаю стенограмму, часть \(chunk) (осталось реплик: \(left))…"
        case .report:
            progressText = "Пишу отчёт…"
        case .retrying(let error, let ms):
            progressText = "\(error.localizedDescription) Повторю через \(ms / 1000) с…"
        }
    }

    private func reportBuilt(_ built: Report, generation gen: Int, build id: Int) {
        guard id == buildID else { return }
        building = false
        progressText = nil
        reportTask = nil
        guard gen == generation else {
            // A new call started while this report was being written: it is kept as a file, not shown.
            if AnalysisRules.saveBeforeReset(hasReport: true, saved: built.savedURL != nil) { autosave(built) }
            return
        }
        report = built
        log.info("analysis report ready")
    }

    private func reportFailed(_ error: Error, build id: Int) {
        guard id == buildID else { return }
        building = false
        progressText = nil
        reportTask = nil
        if error is CancellationError { return }
        reportError = "Отчёт не получен. " + ChatCompletionsClient.classify(error).localizedDescription
    }

    /// «Сохранить в TXT»: the file in ~/Documents/Ponte, then a banner with «Показать».
    @discardableResult
    func saveReport() -> URL? {
        guard let report else { return nil }
        do {
            let url = try write(report)
            self.report?.savedURL = url
            app?.banner = Banner(kind: .info, text: "Отчёт сохранён: \((url.path as NSString).abbreviatingWithTildeInPath)",
                                 action: .reveal(url), actionTitle: "Показать")
            return url
        } catch {
            reportError = "Не удалось сохранить отчёт: \(error.localizedDescription)"
            return nil
        }
    }

    /// «Скопировать»: the report text to the clipboard.
    func copyReport() {
        guard let report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.text, forType: .string)
    }

    private func write(_ report: Report) throws -> URL {
        let text = CallReportExporter.text(report: report.text, lines: report.lines, facts: report.facts,
                                           service: report.service, madeAt: report.madeAt)
        return try CallReportExporter.write(text, startedAt: report.facts.startedAt,
                                            to: app?.launch.transcriptDir ?? TranscriptExporter.defaultFolder)
    }

    private func autosave(_ report: Report) {
        do {
            autosavedURL = try write(report)
            log.info("analysis report autosaved")
        } catch {
            log.error("analysis report autosave failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

extension AnalysisError {
    /// Why the settings cannot make a request (AnalysisRules.config*), in Russian.
    static func configMessage(_ check: Int) -> String {
        switch check {
        case AnalysisRules.configNoKey: "Сначала сохраните API-ключ."
        case AnalysisRules.configBadURL: "Базовый URL должен начинаться с https:// (или http:// для своего сервера)."
        case AnalysisRules.configNoModel: "Укажите модель."
        default: ""
        }
    }
}
