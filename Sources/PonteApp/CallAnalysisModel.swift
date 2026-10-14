import AppKit
import Foundation
import Observation
import os
import PonteCore
import PonteSpeech

/// What the call analysis needs from the app: the transcript, the state of the call, the banner and the folder of
/// the TXT files. AppModel is the host; the tests pass their own.
@MainActor
protocol CallAnalysisApp: AnyObject {
    var lines: [ConversationLine] { get }
    var isRunning: Bool { get }
    var callStartedAt: Date? { get }
    var activeSourceName: String? { get }
    var banner: Banner? { get set }
    /// Where reports are written: ~/Documents/Ponte, or the transcript folder of the launch options.
    var reportFolder: URL { get }
}

extension AppModel: CallAnalysisApp {
    var reportFolder: URL { launch.transcriptDir ?? TranscriptExporter.defaultFolder }
}

/// The call analysis in the app: its settings (service, base URL, model, the key in the Keychain bound to its base
/// URL, on/off), the background notes while a call runs, and the report after it. Every decision comes from
/// AnalysisRules (Specs/analysis_rules.t27); the requests are CallAnalyst's. Failures never interrupt the call: they
/// show as a quiet status line in the report window and as a warning icon on «Отчёт по звонку», never as an alert.
/// AppModel owns one (`analysis`) and calls `callStarted`, `callStopped` and, on quit, `finishForQuit`.
@MainActor @Observable
final class CallAnalysisModel {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let keyStore: AnalysisKeyStore
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let log = Logger(subsystem: "app.ponte.translator", category: "analysis")
    @ObservationIgnored private let testMode: Bool
    /// Tests shorten the quit wait; nil: AnalysisRules.quitWaitMs.
    @ObservationIgnored var quitWaitOverrideMs: Int?

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

    /// AnalysisRules.provider*. Another service: its own key, base URL and model; the messages and a check of the
    /// previous service are dropped.
    var provider: Int {
        didSet {
            guard provider != oldValue else { return }
            defaults.set(provider, forKey: Key.provider)
            keyMessage = nil
            invalidateProbe()
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

    /// The applied base URL of the current service: the stored one, else the spec's default. The settings field
    /// edits a draft; only applyBaseURL changes this, so a half-typed address is never used.
    var baseURL: String {
        _ = settingsRevision
        return defaults.string(forKey: Key.baseURL(providerID)) ?? AnalysisRules.defaultBaseURL(provider)
    }

    /// The applied model of the current service: the stored one, else the spec's default (applyModel changes it).
    var model: String {
        _ = settingsRevision
        return defaults.string(forKey: Key.model(providerID)) ?? AnalysisRules.defaultModel(provider)
    }

    /// Applies a base URL typed in the settings (Enter, leaving the field, «Применить»), only when it can be used
    /// (AnalysisRules.baseURLCheck). Returns why not, or nil when applied or unchanged.
    @discardableResult
    func applyBaseURL(_ typed: String) -> String? {
        let url = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = AnalysisTexts.urlProblem(AnalysisRules.baseURLCheck(utf8: Array(url.utf8))) { return problem }
        guard url != baseURL else { return nil }
        defaults.set(url, forKey: Key.baseURL(providerID))
        settingsRevision += 1
        log.info("analysis base URL applied for \(self.providerID, privacy: .public)")
        invalidateProbe()
        settingsChanged()
        return nil
    }

    /// Applies a model typed in the settings, only when it can be used (AnalysisRules.modelCheck). Returns why not,
    /// or nil when applied or unchanged.
    @discardableResult
    func applyModel(_ typed: String) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = AnalysisTexts.modelProblem(AnalysisRules.modelCheck(utf8: Array(name.utf8))) { return problem }
        guard name != model else { return nil }
        defaults.set(name, forKey: Key.model(providerID))
        settingsRevision += 1
        invalidateProbe()
        settingsChanged()
        return nil
    }

    /// Back to the spec's base URL and model for the current service.
    func resetToDefaults() {
        defaults.removeObject(forKey: Key.baseURL(providerID))
        defaults.removeObject(forKey: Key.model(providerID))
        settingsRevision += 1
        invalidateProbe()
        settingsChanged()
    }

    var isDefault: Bool {
        baseURL == AnalysisRules.defaultBaseURL(provider) && model == AnalysisRules.defaultModel(provider)
    }

    /// Changes of the stored base URL and model (UserDefaults is not observed).
    private var settingsRevision = 0
    private var enabledStored: Bool?

    /// «Анализировать звонок» (AnalysisRules.analysisOn). Turning it off stops every request in flight.
    var enabled: Bool {
        get { AnalysisRules.analysisOn(hasStored: enabledStored != nil, stored: enabledStored ?? false, hasKey: hasKey, testMode: testMode) }
        set {
            enabledStored = newValue
            defaults.set(newValue, forKey: Key.enabled)
            if !newValue { cancelRequests(reason: "анализ звонка выключен", tag: "turned off") }
        }
    }

    // MARK: The key (Keychain only, bound to its base URL)

    /// The current service's key and the address it was saved for, read from the Keychain only when needed (the
    /// settings, a call, a report) and again when the service or the key changes. Never logged.
    @ObservationIgnored private var storedKey: AnalysisStoredKey?
    @ObservationIgnored private var keyLoaded = false
    private(set) var hasKey = false
    /// The base URL the saved key is bound to (nil without a key, or for a key of an older Ponte).
    private(set) var keyBaseURL: String?
    /// What happened to the key last («Ключ сохранён…» or an error).
    var keyMessage: String?

    /// Reads the key once (the settings call it when they appear; a call and a report call it themselves).
    func loadKeyIfNeeded() {
        if !keyLoaded { reloadKey() }
    }

    private func reloadKey() {
        keyLoaded = true
        storedKey = keyStore.stored(for: provider)
        hasKey = !(storedKey?.key ?? "").isEmpty
        keyBaseURL = storedKey?.baseURL
    }

    /// «Сохранить ключ»: checks the pasted key (AnalysisRules.keyCheck) and writes it to the Keychain bound to the
    /// applied base URL, which must be usable. Returns true when saved (the field then clears).
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
        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = AnalysisTexts.urlProblem(AnalysisRules.baseURLCheck(utf8: Array(address.utf8))) {
            keyMessage = "Ключ не сохранён: он сохраняется для базового URL, а этот адрес не подходит. \(problem)"
            return false
        }
        do {
            try keyStore.save(key, baseURL: address, for: provider)
            reloadKey()
            keyMessage = "Ключ \(providerName) сохранён в связке ключей macOS для адреса \(address)."
            log.info("analysis key saved for \(self.providerID, privacy: .public)")
            invalidateProbe()
            settingsChanged()
            return true
        } catch {
            // The old entry may be gone already (the save deletes it first): show what the Keychain holds now.
            reloadKey()
            invalidateProbe()
            settingsChanged()
            keyMessage = error.localizedDescription
            let outcome = (error as? AnalysisKeychainError)?.outcome ?? AnalysisRules.saveFailed
            log.error("analysis key not saved for \(self.providerID, privacy: .public): outcome \(outcome, privacy: .public)")
            return false
        }
    }

    /// «Удалить ключ»: every request in flight stops first.
    func deleteKey() {
        cancelRequests(reason: "ключ удалён", tag: "key deleted")
        invalidateProbe()
        do {
            try keyStore.delete(for: provider)
            reloadKey()
            keyMessage = "Ключ \(providerName) удалён из связки ключей."
            log.info("analysis key deleted for \(self.providerID, privacy: .public)")
        } catch {
            reloadKey()
            keyMessage = error.localizedDescription
        }
    }

    // MARK: Configuration

    var config: AnalysisConfig {
        AnalysisConfig(provider: provider, baseURL: baseURL, model: model, apiKey: storedKey?.key ?? "",
                       keyBaseURL: storedKey?.baseURL)
    }

    /// AnalysisRules.config*.
    var configCheck: Int { config.check }
    var configured: Bool { configCheck == AnalysisRules.configOK }
    var urlCheck: Int { config.urlCheck }
    var endpointText: String? { config.endpoint?.absoluteString }
    /// Why no request can be made (AnalysisTexts.configProblem); nil when it can.
    var configProblem: String? { AnalysisTexts.configProblem(config) }

    private func analyst() -> CallAnalyst {
        CallAnalyst(client: ChatCompletionsClient(config: config, session: session))
    }

    /// A new key, URL, model or service: the stopped background notes may try again.
    private func settingsChanged() {
        notebook.resume()
        if host?.isRunning == true { notesStatus = nil }
    }

    // MARK: «Проверить»

    enum ProbeResult: Equatable {
        case running
        case ok(String)
        case failed(String)
    }

    var probeResult: ProbeResult?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    /// Each change of the service, key, URL or model starts a new generation; a check of an older one is dropped.
    @ObservationIgnored private var probeGeneration = 0

    /// The settings changed: a check in flight stops, and its answer (about other settings) is never shown.
    private func invalidateProbe() {
        probeGeneration += 1
        probeTask?.cancel()
        probeTask = nil
        probeResult = nil
    }

    func probe() {
        guard probeResult != .running else { return }
        guard configured else {
            probeResult = .failed(configProblem ?? "")
            return
        }
        probeResult = .running
        let analyst = analyst()
        let name = "\(providerName), модель \(config.trimmedModel)"
        let gen = probeGeneration
        probeTask = Task { [weak self] in
            let failure = await analyst.probe()
            guard let self, gen == self.probeGeneration else { return }
            self.probeTask = nil
            if let failure {
                self.probeResult = .failed(failure.localizedDescription)
            } else {
                self.probeResult = .ok("Сервис отвечает: \(name).")
            }
        }
    }

    // MARK: The call

    @ObservationIgnored private weak var host: CallAnalysisApp?
    /// Each call gets a new generation; late answers of an older one never touch this call's state.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var notebook = AnalysisNotebook()
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    /// A background notes update is running.
    var notesUpdating: Bool { updateTask != nil }
    /// Each notes update gets an ID; one that was stopped or replaced never touches the notebook.
    @ObservationIgnored private var updateID = 0
    @ObservationIgnored private var callStartedAt: Date?
    @ObservationIgnored private var callEndedAt: Date?
    @ObservationIgnored private var sourceName: String?
    /// The quiet status of the background notes («Заметки обновлены…», a failure); nil when there is nothing to say.
    private(set) var notesStatus: String?
    /// The last background notes update failed (the toolbar button shows a warning icon).
    private(set) var notesFailing = false
    /// The app is quitting (AppModel.prepareToQuit): Stop builds no report (AnalysisRules.reportOnStop).
    @ObservationIgnored var quitting = false

    /// A call starts (AppModel.start): a report the owner did not save goes to a file first, then this call's state
    /// starts empty. A report of the previous call still being written goes on in the background: it is written to a
    /// file when it arrives, and the new call's report window neither waits for it nor shows its errors as its own.
    func callStarted(_ host: CallAnalysisApp) {
        self.host = host
        loadKeyIfNeeded()
        autosavedURL = nil
        previousReportError = nil
        if AnalysisRules.saveBeforeReset(hasReport: report != nil, saved: report?.savedURL != nil), let report {
            autosave(report)
        }
        generation += 1
        tickTask?.cancel()
        stopNotesUpdate()
        finishCurrentBuild()
        report = nil
        reportError = nil
        notesFailing = false
        callStartedAt = host.callStartedAt ?? Date()
        callEndedAt = nil
        sourceName = host.activeSourceName
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

    /// The call stopped (AppModel.stop): the background notes end; the report is built when the rules say so (never
    /// while the app quits).
    func callStopped(_ host: CallAnalysisApp) {
        self.host = host
        loadKeyIfNeeded()
        tickTask?.cancel()
        tickTask = nil
        // A notes update in flight is dropped: its lines are still pending, so the report takes them.
        stopNotesUpdate()
        callEndedAt = Date()
        if AnalysisRules.reportOnStop(enabled: enabled, configured: configured, lines: host.lines.count, quitting: quitting) {
            // A report asked for during the call covers only part of it: the final one replaces it.
            buildReport(replacingRunning: true)
            showReport = true
        }
    }

    /// One look at the transcript: update the notes when AnalysisRules.shouldUpdate says so.
    func tick(now: Date) {
        guard let host else { return }
        let lines = host.lines.map(AnalysisLine.init)
        let pending = notebook.pending(lines, now: now, all: false)
        // A report of this call in progress uses the service and the notebook too.
        let busy = updateTask != nil || building
        guard notebook.shouldUpdate(running: host.isRunning, enabled: enabled, configured: configured,
                                    busy: busy, pendingCount: pending.count, now: now) else { return }
        let analyst = analyst()
        let notes = notebook.notes
        let cap = notebook.lineCap
        let gen = generation
        updateID += 1
        let id = updateID
        updateTask = Task { [weak self] in
            do {
                let step = try await analyst.updateNotesSafely(notes: notes, lines: pending, maxLines: cap)
                self?.notesUpdated(step, covering: Array(pending.prefix(step.covered)), generation: gen, update: id)
            } catch is CancellationError {
                return
            } catch {
                self?.notesFailed(ChatCompletionsClient.classify(error), generation: gen, update: id)
            }
        }
    }

    /// Stops the notes update in flight; its answer, should it still come, is dropped.
    private func stopNotesUpdate() {
        updateTask?.cancel()
        updateTask = nil
        updateID += 1
    }

    private func notesUpdated(_ step: NotesStep, covering lines: [AnalysisLine], generation gen: Int, update id: Int) {
        guard gen == generation, id == updateID else { return }
        updateTask = nil
        notebook.applied(notes: step.notes, covering: lines, at: Date())
        notebook.limitLines(step.lineCap)
        notesFailing = false
        notesStatus = "Заметки обновлены в \(Self.clock(Date())): в них \(notebook.covered.count) реплик."
        log.info("analysis notes updated: \(lines.count, privacy: .public) lines, \(step.cuts, privacy: .public) cut replies")
    }

    private func notesFailed(_ error: AnalysisError, generation gen: Int, update id: Int) {
        guard gen == generation, id == updateID else { return }
        updateTask = nil
        notebook.failed(error, at: Date())
        notesFailing = true
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
        /// The service finished the text (AnalysisRules.replyComplete); a cut one is shown and saved as incomplete.
        var complete = true

        static func == (a: Report, b: Report) -> Bool {
            a.text == b.text && a.madeAt == b.madeAt && a.savedURL == b.savedURL && a.complete == b.complete
                && a.lines.map(\.id) == b.lines.map(\.id)
        }
    }

    var showReport = false
    private(set) var report: Report?
    /// A report of the current call is being written (one of an earlier call never counts).
    private(set) var building = false
    private(set) var buildStartedAt: Date?
    private(set) var progressText: String?
    private(set) var reportError: String?
    /// The report of the previous call, still being written when this call started, did not arrive.
    private(set) var previousReportError: String?
    /// A report of an earlier call that was written to a file without the owner's «Сохранить в TXT».
    private(set) var autosavedURL: URL?
    /// Every report request in flight, this call's and earlier calls', by build ID with its call generation. A build
    /// that is no longer here (replaced, stopped, abandoned) never touches the state.
    @ObservationIgnored private var builds: [Int: (generation: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var buildID = 0
    /// The build of the current call the window shows; nil when none.
    @ObservationIgnored private var currentBuildID: Int?

    var lineCount: Int { host?.lines.count ?? 0 }
    /// Report requests in flight (this call's and earlier calls').
    var buildsInFlight: Int { builds.count }

    /// «Отчёт по звонку» in the toolbar is enabled (AnalysisRules.reportButtonEnabled).
    func reportButtonEnabled(lines: Int) -> Bool {
        AnalysisRules.reportButtonEnabled(lines: lines, hasReport: report != nil, busy: building)
    }

    /// «Отчёт по звонку»: show, build or explain (AnalysisRules.reportOnOpen); the window opens in every case.
    func openReport(_ host: CallAnalysisApp) {
        self.host = host
        loadKeyIfNeeded()
        if AnalysisRules.reportOnOpen(enabled: enabled, busy: building, hasReport: report != nil,
                                      reportLines: report?.lines.count ?? 0, lines: host.lines.count,
                                      configured: configured) == AnalysisRules.openBuild {
            buildReport()
        }
        showReport = true
    }

    /// AnalysisRules.check* for «Обновить» and the window's explanation.
    var buildCheck: Int { AnalysisRules.buildCheck(enabled: enabled, busy: building, configured: configured, lines: lineCount) }

    /// Builds the report from the notes and every line not in them yet. `replacingRunning` drops this call's build in
    /// progress (a report asked for during the call) and starts over with every line.
    func buildReport(replacingRunning: Bool = false) {
        guard let host else { return }
        if replacingRunning, let id = currentBuildID {
            builds.removeValue(forKey: id)?.task.cancel()
            finishCurrentBuild()
        }
        guard AnalysisRules.buildCheck(enabled: enabled, busy: building, configured: configured,
                                       lines: host.lines.count) == AnalysisRules.checkOK else { return }
        // A notes update in flight is dropped: its lines are still pending, so the report takes them, and the
        // notebook gets the report's own chunk notes instead.
        stopNotesUpdate()
        let conversation = host.lines
        let lines = conversation.map(AnalysisLine.init)
        let started = callStartedAt ?? host.callStartedAt ?? lines.first?.at ?? Date()
        let ended = host.isRunning ? nil : (callEndedAt ?? Date())
        let facts = CallFacts(startedAt: started, endedAt: ended, sourceName: sourceName ?? host.activeSourceName, lines: lines)
        let pending = notebook.pending(lines, now: Date(), all: true)
        let notes = notebook.notes
        let cap = notebook.lineCap
        let analyst = analyst()
        let service = "\(providerName), модель \(config.trimmedModel)"
        let gen = generation
        buildID += 1
        let id = buildID
        currentBuildID = id
        building = true
        buildStartedAt = Date()
        reportError = nil
        progressText = "Готовлю отчёт…"
        log.info("analysis report: \(pending.count, privacy: .public) lines beyond the notes")
        let progress: @Sendable (AnalysisProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.show(progress, build: id) }
        }
        let noted: @Sendable (String, [AnalysisLine]) async -> Void = { [weak self] notes, lines in
            await self?.reportNoted(notes, covering: lines, generation: gen, build: id)
        }
        let task = Task { [weak self] in
            do {
                let result = try await analyst.buildReport(notes: notes, lines: pending, facts: facts, maxLines: cap,
                                                           progress: progress, noted: noted)
                self?.reportBuilt(Report(text: result.text, facts: facts, lines: conversation, madeAt: Date(), service: service,
                                         savedURL: nil, complete: result.complete), generation: gen, build: id)
            } catch {
                self?.reportFailed(error, generation: gen, build: id)
            }
        }
        builds[id] = (gen, task)
    }

    /// The window no longer shows a build of this call.
    private func finishCurrentBuild() {
        currentBuildID = nil
        building = false
        progressText = nil
        buildStartedAt = nil
    }

    private func show(_ progress: AnalysisProgress, build id: Int) {
        guard building, id == currentBuildID else { return }
        switch progress {
        case .notes(let chunk, let left):
            progressText = "Длинный звонок: сжимаю стенограмму, часть \(chunk) (осталось реплик: \(left))…"
        case .report:
            progressText = "Пишу отчёт…"
        case .retrying(let error, let ms):
            progressText = "\(error.localizedDescription) Повторю через \(ms / 1000) с…"
        }
    }

    /// A chunk of this call's report went into the notes: the notebook keeps them, so «Обновить» and the report
    /// after Stop do not send those lines again. A build of an earlier call, or one replaced, changes nothing.
    private func reportNoted(_ notes: String, covering lines: [AnalysisLine], generation gen: Int, build id: Int) {
        guard gen == generation, builds[id] != nil else { return }
        notebook.applied(notes: notes, covering: lines, at: Date())
    }

    private func reportBuilt(_ built: Report, generation gen: Int, build id: Int) {
        // Stopped (the analysis off, the key deleted), replaced or abandoned on quit: dropped.
        guard builds.removeValue(forKey: id) != nil else { return }
        guard gen == generation else {
            // A report of an earlier call (a new call started while it was being written): kept as a file, not shown.
            if AnalysisRules.saveBeforeReset(hasReport: true, saved: built.savedURL != nil) { autosave(built) }
            return
        }
        if id == currentBuildID { finishCurrentBuild() }
        report = built
        log.info("analysis report ready (complete: \(built.complete, privacy: .public))")
    }

    private func reportFailed(_ error: Error, generation gen: Int, build id: Int) {
        guard builds.removeValue(forKey: id) != nil else { return }
        if error is CancellationError {
            if gen == generation, id == currentBuildID { finishCurrentBuild() }
            return
        }
        let failure = ChatCompletionsClient.classify(error)
        guard gen == generation else {
            // The report of the previous call: never shown as this call's error.
            previousReportError = "Отчёт прошлого звонка не получен. " + failure.localizedDescription
            log.error("analysis report of an earlier call failed: class \(failure.errorClass, privacy: .public)")
            return
        }
        if id == currentBuildID { finishCurrentBuild() }
        reportError = "Отчёт не получен. " + failure.localizedDescription
    }

    /// The analysis was turned off or the key deleted: every request in flight stops at once (the notes update and
    /// every report being written, this call's or an earlier call's); nothing more is sent.
    private func cancelRequests(reason: String, tag: String) {
        let count = builds.count + (updateTask == nil ? 0 : 1)
        stopNotesUpdate()
        for build in builds.values { build.task.cancel() }
        builds = [:]
        if currentBuildID != nil {
            finishCurrentBuild()
            reportError = "Отчёт не составлен: \(reason)."
        }
        if count > 0 { log.info("analysis: \(count, privacy: .public) requests stopped (\(tag, privacy: .public))") }
    }

    /// Work a quit must not lose (AnalysisRules.quitHasWork): an unsaved report or one still being written.
    var quitHasWork: Bool {
        AnalysisRules.quitHasWork(hasReport: report != nil, saved: report?.savedURL != nil, builds: builds.count)
    }

    /// The app quits (AppModel.prepareToQuit, after Stop). Reports still being written (of this call or an earlier
    /// one) get AnalysisRules.quitWaitMs to arrive and are written to a file; the ones still out after it are
    /// abandoned, with a line in the log. A report the owner has not saved is written to a file
    /// (AnalysisRules.saveBeforeReset).
    func finishForQuit() async {
        quitting = true
        tickTask?.cancel()
        tickTask = nil
        stopNotesUpdate()
        let rule = AnalysisRules.quitWaitMs(builds: builds.count)
        let wait = rule > 0 ? (quitWaitOverrideMs ?? rule) : 0
        if wait > 0 {
            log.info("quit: waiting up to \(wait, privacy: .public) ms for \(self.builds.count, privacy: .public) report(s)")
            let deadline = ContinuousClock.now + .milliseconds(wait)
            while !builds.isEmpty, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if !builds.isEmpty {
                log.error("quit: \(self.builds.count, privacy: .public) report request(s) abandoned")
                for build in builds.values { build.task.cancel() }
                builds = [:]
                finishCurrentBuild()
            }
        }
        if AnalysisRules.saveBeforeReset(hasReport: report != nil, saved: report?.savedURL != nil), let report {
            // Marked saved, so a second quit request (SIGTERM, then terminate) does not write it twice.
            self.report?.savedURL = autosave(report)
        }
    }

    /// «Сохранить в TXT»: the file in ~/Documents/Ponte, then a banner with «Показать».
    @discardableResult
    func saveReport() -> URL? {
        guard let report else { return nil }
        do {
            let url = try write(report)
            self.report?.savedURL = url
            host?.banner = Banner(kind: .info, text: "Отчёт сохранён: \((url.path as NSString).abbreviatingWithTildeInPath)",
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
                                           service: report.service, madeAt: report.madeAt, complete: report.complete)
        return try CallReportExporter.write(text, startedAt: report.facts.startedAt,
                                            to: host?.reportFolder ?? TranscriptExporter.defaultFolder)
    }

    @discardableResult
    private func autosave(_ report: Report) -> URL? {
        do {
            let url = try write(report)
            autosavedURL = url
            log.info("analysis report autosaved")
            return url
        } catch {
            log.error("analysis report autosave failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
