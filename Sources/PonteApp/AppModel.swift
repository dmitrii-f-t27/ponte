import AppKit
import AVFoundation
import Foundation
import Observation
import os
import PonteAudio
import PonteCore
import PonteSpeech

/// A status light (AppRules.LIGHT_*), as the views draw it.
enum Check: Equatable {
    case unknown, ok, bad, busy, warn

    init(light: Int32) {
        switch light {
        case AppRules.LIGHT_OK: self = .ok
        case AppRules.LIGHT_BAD: self = .bad
        case AppRules.LIGHT_BUSY: self = .busy
        case AppRules.LIGHT_WARN: self = .warn
        default: self = .unknown
        }
    }
}

enum RunState: Equatable {
    case idle, starting, running, stopping

    var code: Int32 {
        switch self {
        case .idle: AppRules.RUN_IDLE
        case .starting: AppRules.RUN_STARTING
        case .running: AppRules.RUN_RUNNING
        case .stopping: AppRules.RUN_STOPPING
        }
    }

    init(code: Int32) {
        switch code {
        case AppRules.RUN_STARTING: self = .starting
        case AppRules.RUN_RUNNING: self = .running
        case AppRules.RUN_STOPPING: self = .stopping
        default: self = .idle
        }
    }
}

/// Raw values are the AppRules.WZ_* codes.
enum WizardStep: Int, CaseIterable, Identifiable {
    case permissions, models, packs, blackHole, callApps, done
    var id: Int { rawValue }
    var code: Int32 { Int32(rawValue) }
    init?(code: Int32) { self.init(rawValue: Int(code)) }
}

struct Banner: Identifiable, Equatable {
    enum Kind { case error, warning, info }
    enum Action: Equatable {
        case openWizard(WizardStep)
        case reveal(URL)
        case accessibility
        /// System Settings → Privacy & Security pane (anchor such as "Privacy_ScreenCapture").
        case privacySettings(String)
    }

    let id = UUID()
    let kind: Kind
    let text: String
    var action: Action?
    var actionTitle: String?
}

/// The app state: settings, both lanes, status row, transcript. Decisions come from AppRules.
@MainActor @Observable
final class AppModel {
    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Launch arguments (test mode, autostart, wizard step). Never persisted.
    @ObservationIgnored let launch: LaunchOptions
    @ObservationIgnored private let log = Logger(subsystem: "app.ponte.translator", category: "app")
    @ObservationIgnored let deviceCatalog = CoreAudioDeviceCatalog()
    @ObservationIgnored let appCatalog = RunningAudioAppCatalog()
    @ObservationIgnored private let memory = ConversationMemory()
    @ObservationIgnored private let echoGuard = EchoGuard()
    @ObservationIgnored private var incomingLane: TranslationLane?
    @ObservationIgnored private var outgoingLane: TranslationLane?
    @ObservationIgnored private let ptt = PushToTalkMonitor()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var overlay: SubtitleOverlayController?
    @ObservationIgnored private var claudeChecked = false
    @ObservationIgnored private var cachedClaude: ClaudeTranslator?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var incomingTap: AppAudioTapSource?
    @ObservationIgnored private var terminationSignal: DispatchSourceSignal?
    @ObservationIgnored private var silenceWarned = false

    // MARK: Catalog snapshots

    var devices: [AudioDevice] = []
    var audioApps: [AudioApp] = []
    var defaultOutput: AudioDevice?
    var blackHoleDevice: AudioDevice?
    var accessibilityGranted = PushToTalkMonitor.hasGlobalPermission
    /// The owner listens on a loudspeaker (built-in or display speakers, AirPlay):
    /// AudioRules.echoRisk of the listening device is echoSpeaker. Shows «наденьте наушники».
    var speakerWarning = false

    // MARK: Settings (persisted)

    var sourceKey: String { didSet { defaults.set(sourceKey, forKey: PrefKey.source) } }
    var micUID: String { didSet { defaults.set(micUID, forKey: PrefKey.micUID) } }
    var headphonesUID: String {
        didSet {
            defaults.set(headphonesUID, forKey: PrefKey.headphonesUID)
            refreshSpeakerWarning()
        }
    }
    var callOutputUID: String {
        didSet {
            defaults.set(callOutputUID, forKey: PrefKey.callOutputUID)
            refreshCatalogs()
        }
    }
    var voicePT: String { didSet { defaults.set(voicePT, forKey: PrefKey.voicePT) } }
    var voiceRU: String { didSet { defaults.set(voiceRU, forKey: PrefKey.voiceRU) } }
    var speakRussian: Bool {
        didSet {
            defaults.set(speakRussian, forKey: PrefKey.speakRussian)
            incomingLane?.speechOutputEnabled = speakRussian
        }
    }
    var translatorKind: TranslatorKind { didSet { defaults.set(translatorKind.rawValue, forKey: PrefKey.translator) } }
    var glossary: [GlossaryTerm] {
        didSet {
            defaults.set(GlossaryTerm.encode(glossary), forKey: PrefKey.glossary)
            incomingLane?.glossary = glossary
            outgoingLane?.glossary = glossary
            updateClaudeGlossary()
        }
    }
    var outgoingMode: CaptureMode {
        didSet {
            defaults.set(outgoingMode.rawValue, forKey: PrefKey.outgoingMode)
            outgoingLane?.mode = outgoingMode
            updatePushToTalk()
        }
    }
    var pttKey: PTTKey {
        didSet {
            defaults.set(pttKey.rawValue, forKey: PrefKey.pttKey)
            ptt.key = pttKey
        }
    }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: PrefKey.fontSize) } }
    var overlayVisible: Bool {
        didSet {
            defaults.set(overlayVisible, forKey: PrefKey.overlayVisible)
            updateOverlay()
        }
    }
    var setupCompleted: Bool { didSet { defaults.set(setupCompleted, forKey: PrefKey.setupCompleted) } }

    // MARK: Session

    var runState: RunState = .idle
    var lines: [ConversationLine] = []
    var incomingPartial = ""
    var outgoingPartial = ""
    var incomingSpeaking = false
    var outgoingSpeaking = false
    /// «Пауза голоса в звонок»: the outgoing lane stops listening and speaking.
    var voicePaused = false { didSet { outgoingLane?.isPaused = voicePaused } }
    var talkKeyHeld = false
    var pttIsGlobal = false
    var lastLatency: TimeInterval?
    var callStartedAt: Date?
    var activeSourceName: String?
    var banner: Banner?
    var lastTranscriptURL: URL?
    var translatorInUse: String?

    // MARK: Status row

    var sourceCheck: Check = .unknown
    var micCheck: Check = .unknown
    var sourceLevel: Float = 0
    var micLevel: Float = 0
    /// AppRules.TAP_* of the incoming process tap (TAP_NONE for a test file).
    var sourceTapStatus = AppRules.TAP_IDLE
    var sourceTapDetail: String?
    private var everStarted = false
    private var lanesStarted: Int32 = 0
    private var lanesFailed: Int32 = 0
    /// Running lanes whose translator is not ready (they show originals only).
    private var translatorsFailed: Int32 = 0

    // MARK: Wizard

    var showWizard = false
    var wizardStep: WizardStep = .permissions

    init(launch: LaunchOptions = .current) {
        self.launch = launch
        let d = UserDefaults.standard
        sourceKey = d.string(forKey: PrefKey.source) ?? "system"
        micUID = d.string(forKey: PrefKey.micUID) ?? ""
        headphonesUID = d.string(forKey: PrefKey.headphonesUID) ?? ""
        callOutputUID = d.string(forKey: PrefKey.callOutputUID) ?? ""
        voicePT = d.string(forKey: PrefKey.voicePT) ?? ""
        voiceRU = d.string(forKey: PrefKey.voiceRU) ?? ""
        speakRussian = d.bool(forKey: PrefKey.speakRussian)
        translatorKind = TranslatorKind(rawValue: d.string(forKey: PrefKey.translator) ?? "") ?? .apple
        glossary = GlossaryTerm.decode(d.string(forKey: PrefKey.glossary) ?? "[]")
        outgoingMode = CaptureMode(rawValue: d.string(forKey: PrefKey.outgoingMode) ?? "") ?? .continuous
        pttKey = PTTKey(rawValue: d.string(forKey: PrefKey.pttKey) ?? "") ?? .rightOption
        fontSize = Double(AppRules.translationFontSize(stored: Int32(d.integer(forKey: PrefKey.fontSize))))
        overlayVisible = d.bool(forKey: PrefKey.overlayVisible)
        setupCompleted = d.bool(forKey: PrefKey.setupCompleted)
        // Launch arguments for demos, screenshots and end-to-end checks (LaunchOptions):
        //   open dist/Ponte.app --args -PonteWizardStep 3 -PonteAutostart YES
        showWizard = AppRules.wizardShowOnLaunchInMode(setupCompleted: setupCompleted, forcedStep: launch.wizardStep,
                                                       testMode: launch.isTestMode)
        if let step = WizardStep(code: launch.wizardStep) { wizardStep = step }
        ptt.key = pttKey
        refreshCatalogs()
    }

    /// Called when the main window appears (windows can be created). Runs once.
    func appDidLaunchOnce() {
        guard activationObserver == nil else { return }
        updateOverlay()
        startPolling()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
        if launch.isTestMode {
            log.info("test mode: incoming \(self.launch.incomingFile?.path ?? "tap", privacy: .public), outgoing \(self.launch.outgoingFile?.path ?? "mic", privacy: .public), sink \(self.launch.outgoingSink?.path ?? "-", privacy: .public)")
            installTerminationSignalHandler()
        }
        if launch.autostart {
            Task { await start() }
        }
        if let appearance = launch.appearance {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
    }

    /// Test mode: `kill -TERM` quits like ⌘Q (stop, save the transcript), so scripts can end a run.
    /// Stops first, then terminates: calling terminate from inside this main-queue handler while a
    /// call runs would wait for the stop task on the very queue the handler is holding.
    private func installTerminationSignalHandler() {
        guard terminationSignal == nil else { return }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                await self?.prepareToQuit()
                NSApp.terminate(nil)
            }
        }
        source.resume()
        terminationSignal = source
    }

    private func appBecameActive() {
        refreshCatalogs()
        let granted = PushToTalkMonitor.hasGlobalPermission
        if granted != accessibilityGranted {
            accessibilityGranted = granted
            updatePushToTalk()
        }
    }

    // MARK: Derived

    var isRunning: Bool { runState == .running }
    var incomingLines: [ConversationLine] { lines.filter { $0.direction == .incoming } }
    var outgoingLines: [ConversationLine] { lines.filter { $0.direction == .outgoing } }
    var micDevice: AudioDevice? { devices.first { $0.uid == micUID && $0.inputChannels > 0 } }
    var headphonesDevice: AudioDevice? { devices.first { $0.uid == headphonesUID && $0.outputChannels > 0 } }
    var inputDevices: [AudioDevice] { devices.filter { $0.inputChannels > 0 && !$0.isVirtualMic } }
    var outputDevices: [AudioDevice] { devices.filter { $0.outputChannels > 0 } }

    /// Where the user hears things: chosen headphones or the system output.
    var listeningDevice: AudioDevice? { headphonesDevice ?? defaultOutput }

    private func refreshSpeakerWarning() {
        speakerWarning = listeningDevice.map { deviceCatalog.echoRisk(of: $0) == AudioRules.echoSpeaker } ?? false
    }

    var source: SourceChoice { SourceChoice(key: sourceKey) }

    var sourceTitle: String {
        switch source {
        case .system: return "Весь звук Мака"
        case .app(let id):
            return audioApps.first { $0.bundleID == id }?.name ?? AudioApp.knownCallApps[id] ?? id
        }
    }

    /// Tooltip of «Звук источника».
    var sourceHelp: String {
        guard isRunning else { return "Идёт ли звук из выбранной программы" }
        switch sourceTapStatus {
        case AppRules.TAP_WAITING:
            return "Ждём звук: «\(activeSourceName ?? "")» ещё не выводит звук. Ponte подключится сам, когда начнётся звонок."
        case AppRules.TAP_FAILED:
            return "Не удалось подключиться к звуку: \(sourceTapDetail ?? "")"
        case AppRules.TAP_NONE:
            return "Тестовый режим: звук из файла \(launch.incomingFile?.lastPathComponent ?? "")"
        default:
            break
        }
        if sourceCheck == .warn { return Self.silenceText(activeSourceName) }
        return "Звук из «\(activeSourceName ?? "")» идёт"
    }

    static func silenceText(_ name: String?) -> String {
        "Из «\(name ?? "источника")» приходит только тишина. Если собеседники говорят, а текста нет, — разрешите Ponte "
            + "запись системного звука: Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука."
    }

    var blackHoleCheck: Check { Check(light: AppRules.blackHoleLight(found: blackHoleDevice != nil)) }

    var modelsCheck: Check {
        Check(light: AppRules.modelsLight(runState: runState.code, everStarted: everStarted,
                                          lanesStarted: lanesStarted, lanesFailed: lanesFailed + translatorsFailed))
    }

    /// AppRules.LAT_* for the last phrase.
    var latencyColorCode: Int32 { AppRules.latencyColor(ms: lastLatency.map { millis($0) } ?? -1) }

    /// AppRules.buttonEnabled for one AppRules.BTN_* code.
    func enabled(_ button: Int32, busy: Bool = false) -> Bool {
        AppRules.buttonEnabled(button: button, runState: runState.code,
                               incomingLines: Int32(incomingLines.count), outgoingLines: Int32(outgoingLines.count),
                               hasBlackHole: blackHoleDevice != nil, busy: busy)
    }

    var claudeAvailable: Bool { claudeTranslator() != nil }

    func recheckClaude() {
        claudeChecked = false
        cachedClaude = nil
        _ = claudeTranslator()
    }

    private func claudeTranslator() -> ClaudeTranslator? {
        if !claudeChecked {
            cachedClaude = ClaudeTranslator()
            claudeChecked = true
            updateClaudeGlossary()
        }
        return cachedClaude
    }

    /// Claude gets each direction's side of the glossary in its prompt. The app-side
    /// replacement (GlossaryTerm.apply in the lane) runs for every engine.
    private func updateClaudeGlossary() {
        guard let claude = cachedClaude else { return }
        for direction in Direction.allCases {
            claude.setGlossary(GlossaryTerm.translatorGlossary(glossary, direction: direction),
                               from: direction.source, to: direction.target)
        }
    }

    private var voiceMap: [Lang: String] {
        var map: [Lang: String] = [:]
        if !voicePT.isEmpty { map[.ptBR] = voicePT }
        if !voiceRU.isEmpty { map[.ru] = voiceRU }
        return map
    }

    // MARK: Catalogs

    func refreshCatalogs() {
        devices = deviceCatalog.devices()
        defaultOutput = deviceCatalog.defaultOutput()
        audioApps = appCatalog.apps()
        if !callOutputUID.isEmpty, let chosen = devices.first(where: { $0.uid == callOutputUID }) {
            blackHoleDevice = chosen
        } else {
            blackHoleDevice = BlackHoleCheck.find(in: deviceCatalog)
        }
        refreshSpeakerWarning()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.pollAudioStats()
                if tick % 6 == 5 { self.refreshCatalogs() }
                tick += 1
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func pollAudioStats() {
        let now = Date()
        let sinceStart = callStartedAt.map { millis(now.timeIntervalSince($0)) } ?? 0
        func since(_ date: Date?) -> Int64 { date.map { millis(now.timeIntervalSince($0)) } ?? -1 }

        let incoming = incomingLane?.audioStats
        let sourceCode = AppRules.sourceLight(runState: runState.code, laneActive: incomingLane != nil,
                                              tapStatus: sourceTapStatus, msSinceStart: sinceStart,
                                              msSinceBuffer: since(incoming?.lastBufferAt),
                                              msSinceSignal: since(incoming?.lastSignalAt))
        sourceCheck = Check(light: sourceCode)
        sourceLevel = sourceCode == AppRules.LIGHT_OK ? incoming?.level ?? 0 : 0

        let outgoing = outgoingLane?.audioStats
        let micCode = AppRules.audioLight(runState: runState.code, laneActive: outgoingLane != nil,
                                          msSinceStart: sinceStart, msSinceBuffer: since(outgoing?.lastBufferAt))
        micCheck = Check(light: micCode)
        micLevel = micCode == AppRules.LIGHT_OK ? outgoing?.level ?? 0 : 0

        if isRunning {
            translatorsFailed = Int32([incomingLane, outgoingLane].compactMap { $0 }.filter { $0.translatorError != nil }.count)
        }
        if sourceCheck == .warn && !silenceWarned {
            silenceWarned = true
            if banner?.kind != .error {
                banner = Banner(kind: .warning, text: Self.silenceText(activeSourceName),
                                action: .privacySettings("Privacy_ScreenCapture"), actionTitle: "Открыть настройки")
            }
        }
    }

    // MARK: Process tap status

    /// AppAudioTapSource.Status → AppRules.TAP_* (+ the failure text). Called on the tap's queue.
    nonisolated static func tapCode(_ status: AppAudioTapSource.Status) -> (code: Int32, detail: String?) {
        switch status {
        case .idle: return (AppRules.TAP_IDLE, nil)
        case .waitingForApp: return (AppRules.TAP_WAITING, nil)
        case .capturing: return (AppRules.TAP_CAPTURING, nil)
        case .failed(let why): return (AppRules.TAP_FAILED, why)
        }
    }

    private func tapStatusChanged(_ code: Int32, _ detail: String?, from tap: AppAudioTapSource) {
        guard tap === incomingTap else { return }
        sourceTapStatus = code
        sourceTapDetail = detail
        log.info("source tap status \(code, privacy: .public) \(detail ?? "", privacy: .public)")
        pollAudioStats()
    }

    private func makeIncomingSource() -> AudioSource {
        if let url = launch.incomingFile {
            incomingTap = nil
            sourceTapStatus = AppRules.TAP_NONE
            return fileSource(url, direction: .incoming)
        }
        let tap = AppAudioTapSource(target: source.target)
        tap.onStatusChange = { [weak self, weak tap] status in
            let (code, detail) = AppModel.tapCode(status)
            Task { @MainActor in
                guard let self, let tap else { return }
                self.tapStatusChanged(code, detail, from: tap)
            }
        }
        incomingTap = tap
        sourceTapStatus = AppRules.TAP_IDLE
        return tap
    }

    /// Test mode: a file played in real time instead of a device, then silence (TestFileSource).
    private func fileSource(_ url: URL, direction: Direction) -> AudioSource {
        let file = TestFileSource(url: url)
        let log = self.log
        file.onFileEnd = {
            log.info("test file ended (\(direction.rawValue, privacy: .public)): \(url.lastPathComponent, privacy: .public)")
        }
        return file
    }

    // MARK: Start / stop

    func toggleRun() {
        Task {
            switch AppRules.toggleRun(runState: runState.code) {
            case AppRules.TOGGLE_START: await start()
            case AppRules.TOGGLE_STOP: await stop()
            default: break
            }
        }
    }

    func start() async {
        guard AppRules.toggleRun(runState: runState.code) == AppRules.TOGGLE_START else { return }
        runState = .starting
        banner = nil
        refreshCatalogs()
        lines.removeAll()
        incomingPartial = ""
        outgoingPartial = ""
        lastLatency = nil
        lastTranscriptURL = nil
        memory.reset()
        callStartedAt = Date()
        activeSourceName = launch.incomingFile.map { "файл \($0.lastPathComponent)" } ?? sourceTitle
        everStarted = true
        lanesStarted = 0
        lanesFailed = 0
        translatorsFailed = 0
        silenceWarned = false
        sourceTapDetail = nil
        pollAudioStats()

        // The microphone prompt comes before the engine starts: MicSource refuses an undecided permission.
        let micIsLive = launch.outgoingFile == nil
        if micIsLive,
           AudioRules.micStartDecision(authorizationStatus: MicSource.permission.rawValue) == AudioRules.micRequestFirst {
            _ = await MicSource.requestPermission()
        }

        let translator = makeTranslator()
        translatorInUse = translator.name
        let synth = SystemSpeechSynth(voiceIdentifiers: voiceMap)
        let echoOutput = AppRules.echoGuardApplies(speakerOutput: speakerWarning, micIsLive: micIsLive)
        echoGuard.configure(speakerOutput: echoOutput)
        let callOutput: AudioPlayer? = launch.outgoingSink.map { WAVFileSink(url: $0) }
            ?? blackHoleDevice.map { DeviceAudioPlayer(device: $0) }
        let incoming = TranslationLane(
            direction: .incoming,
            source: makeIncomingSource(),
            makeTranscriber: { AppleTranscriber(language: .ptBR) },
            translator: translator,
            synth: synth,
            player: DeviceAudioPlayer(device: headphonesDevice),
            memory: memory,
            mode: .continuous,
            speechOutputEnabled: speakRussian)
        let outgoing = TranslationLane(
            direction: .outgoing,
            source: launch.outgoingFile.map { fileSource($0, direction: .outgoing) } ?? MicSource(device: micDevice),
            makeTranscriber: { AppleTranscriber(language: .ru) },
            translator: translator,
            synth: synth,
            player: callOutput,
            memory: memory,
            mode: outgoingMode,
            speechOutputEnabled: true)
        for lane in [incoming, outgoing] {
            lane.glossary = glossary
            let direction = lane.direction
            lane.onEvent = { [weak self] event in self?.handle(event, from: direction) }
        }
        outgoing.isPaused = voicePaused
        outgoing.echoGuard = echoGuard

        var problems: [String] = []
        var translatorProblems: [String] = []
        var missingPacks: [Error] = []
        for (lane, title) in [(incoming, "Они → по-русски"), (outgoing, "Я → по-португальски")] {
            do {
                try await lane.start()
                if lane.direction == .incoming { incomingLane = lane } else { outgoingLane = lane }
                lanesStarted += 1
                if let error = lane.translatorError {
                    translatorsFailed += 1
                    translatorProblems.append("\(title): \(describe(error))")
                    if isMissingPacks(error) { missingPacks.append(error) }
                }
            } catch {
                lanesFailed += 1
                problems.append("\(title): \(describe(error))")
                if isMissingPacks(error) { missingPacks.append(error) }
            }
        }

        runState = RunState(code: AppRules.runStateAfterStart(lanesStarted: lanesStarted))
        if !isRunning {
            callStartedAt = nil
            incomingTap = nil
            sourceTapStatus = AppRules.TAP_IDLE
        }
        pollAudioStats()
        updatePushToTalk()

        let hasCallOutput = blackHoleDevice != nil || launch.outgoingSink != nil
        switch AppRules.startBannerAfterStart(lanesFailed: lanesFailed, translatorsFailed: translatorsFailed,
                                              packsMissing: !missingPacks.isEmpty, hasBlackHole: hasCallOutput,
                                              speakerOutput: echoOutput) {
        case AppRules.BAN_NO_PACKS:
            banner = packsBanner(missingPacks)
        case AppRules.BAN_NO_TRANSLATOR:
            banner = Banner(kind: .error,
                            text: "Речь распознаётся, но перевод недоступен.\n" + translatorProblems.joined(separator: "\n"),
                            action: .openWizard(.packs), actionTitle: "Открыть мастер")
        case AppRules.BAN_FAILED_PACKS:
            banner = Banner(kind: .error, text: problems.joined(separator: "\n"),
                            action: .openWizard(.packs), actionTitle: "Открыть мастер")
        case AppRules.BAN_FAILED_OTHER:
            banner = Banner(kind: .error, text: problems.joined(separator: "\n"),
                            action: .openWizard(.permissions), actionTitle: "Открыть мастер")
        case AppRules.BAN_NO_BLACKHOLE:
            banner = Banner(kind: .warning,
                            text: "BlackHole не найден: перевод на португальский виден здесь, но в звонок не идёт.",
                            action: .openWizard(.blackHole), actionTitle: "Как установить")
        case AppRules.BAN_SPEAKERS:
            banner = Banner(kind: .warning,
                            text: "Звук идёт в динамики Мака. Микрофон услышит собеседников — наденьте наушники.")
        default:
            break
        }
    }

    func stop() async {
        guard AppRules.toggleRun(runState: runState.code) == AppRules.TOGGLE_STOP else { return }
        runState = .stopping
        ptt.stop()
        talkKeyHeld = false
        pttIsGlobal = false
        await incomingLane?.stop()
        await outgoingLane?.stop()
        incomingLane = nil
        outgoingLane = nil
        incomingTap = nil
        sourceTapStatus = AppRules.TAP_IDLE
        incomingSpeaking = false
        outgoingSpeaking = false
        incomingPartial = ""
        outgoingPartial = ""
        echoGuard.configure(speakerOutput: false)
        runState = .idle
        pollAudioStats()
        if AppRules.autosaveOnStop(lines: Int32(lines.count)) { saveTranscript() }
    }

    /// Stops cleanly before the app quits (and saves the transcript).
    func prepareToQuit() async {
        await stop()
    }

    /// Apple on the device; Claude only when chosen and its key exists (then Apple is the fallback).
    /// Speech never goes to the cloud unless the owner picked Claude.
    private func makeTranslator() -> Translator {
        let choice = AppRules.translatorChoice(preferred: translatorKind.ruleCode,
                                               claudeAvailable: translatorKind == .claude && claudeTranslator() != nil)
        let claude = choice == AppRules.TR_CLAUDE ? claudeTranslator() : nil
        return RoutingTranslator(apple: AppleTranslator(), claude: claude, preferClaude: claude != nil)
    }

    private func isMissingPacks(_ error: Error) -> Bool {
        if case PonteSpeechError.translationAssetsMissing = error { return true }
        return false
    }

    /// «Перевод не работает: не скачаны пакеты …» with the way to the wizard's packs step.
    private func packsBanner(_ errors: [Error]) -> Banner {
        var pairs: [String] = []
        for error in errors {
            if case PonteSpeechError.translationAssetsMissing(let from, let to) = error {
                let pair = "«\(from.title) → \(to.title)»"
                if !pairs.contains(pair) { pairs.append(pair) }
            }
        }
        let which = pairs.isEmpty ? "" : " " + pairs.joined(separator: ", ")
        return Banner(kind: .error,
                      text: "Перевод не работает: не скачаны языковые пакеты Apple\(which). Речь распознаётся, "
                          + "оригинал виден. Скачайте пакеты в мастере — перевод включится сам.",
                      action: .openWizard(.packs), actionTitle: "Скачать пакеты")
    }

    private func describe(_ error: Error) -> String {
        if case PonteSpeechError.translationAssetsMissing(let from, let to) = error {
            return "не скачан языковой пакет перевода \(from.rawValue) → \(to.rawValue)"
        }
        if let audio = error as? PonteAudioError {
            switch audio {
            case .permissionRequired(.microphone), .permissionDenied(.microphone):
                return "нет доступа к микрофону. Разрешите его: Системные настройки → Конфиденциальность и безопасность → Микрофон."
            case .deviceNotFound(let name):
                return "устройство «\(name)» не подключено"
            default:
                return audio.description
            }
        }
        return error.localizedDescription
    }

    // MARK: Lane events

    private func handle(_ event: LaneEvent, from direction: Direction) {
        switch event {
        case .partial(let text):
            if direction == .incoming { incomingPartial = text } else { outgoingPartial = text }
        case .phrase(let line):
            lines.append(line)
        case .translated(let line):
            if let index = lines.lastIndex(where: { $0.id == line.id }) {
                lines[index] = line
            } else {
                lines.append(line)
            }
            if let latency = line.latency { lastLatency = latency }
        case .translationFailed(let error):
            if isMissingPacks(error) {
                // The start banner says it already; show it again only if it was closed.
                if banner?.action != .openWizard(.packs) { banner = packsBanner([error]) }
            } else {
                let text = "Перевод: \(describe(error))"
                if banner?.text != text { banner = Banner(kind: .warning, text: text) }
            }
        case .speaking(let on):
            if direction == .incoming {
                incomingSpeaking = on
                echoGuard.setSpeaking(on, at: Date())
            } else {
                outgoingSpeaking = on
            }
        case .problem(let text):
            banner = Banner(kind: .warning, text: text)
        }
    }

    // MARK: Controls

    func replayLast(_ direction: Direction) {
        (direction == .incoming ? incomingLane : outgoingLane)?.replayLast()
    }

    func setTalkKey(_ held: Bool) {
        guard talkKeyHeld != held else { return }
        talkKeyHeld = held
        outgoingLane?.setKeyHeld(held)
    }

    private func updatePushToTalk() {
        let scope = AppRules.pttScope(running: isRunning, mode: outgoingMode.ruleCode,
                                      accessibilityGranted: accessibilityGranted)
        ptt.key = pttKey
        ptt.onChange = { [weak self] held in self?.setTalkKey(held) }
        ptt.apply(scope: scope)
        pttIsGlobal = ptt.isGlobal
    }

    func requestAccessibility() {
        PushToTalkMonitor.requestGlobalPermission()
        Permissions.openPrivacySettings("Privacy_Accessibility")
    }

    // MARK: Transcript

    @discardableResult
    func saveTranscript() -> URL? {
        guard !lines.isEmpty else {
            banner = Banner(kind: .info, text: "Стенограмма пуста: фраз ещё не было.")
            return nil
        }
        do {
            let url = try TranscriptExporter.write(lines: lines, startedAt: callStartedAt ?? lines[0].at,
                                                   endedAt: isRunning ? nil : Date(),
                                                   sourceName: activeSourceName,
                                                   to: launch.transcriptDir ?? TranscriptExporter.defaultFolder)
            lastTranscriptURL = url
            log.info("transcript saved: \(url.path, privacy: .public)")
            banner = Banner(kind: .info, text: "Стенограмма сохранена: \((url.path as NSString).abbreviatingWithTildeInPath)",
                            action: .reveal(url), actionTitle: "Показать")
            return url
        } catch {
            banner = Banner(kind: .error, text: "Не удалось сохранить стенограмму: \(error.localizedDescription)")
            return nil
        }
    }

    func perform(_ action: Banner.Action) {
        switch action {
        case .openWizard(let step):
            wizardStep = step
            showWizard = true
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .accessibility:
            requestAccessibility()
        case .privacySettings(let anchor):
            Permissions.openPrivacySettings(anchor)
        }
    }

    // MARK: Overlay

    private func updateOverlay() {
        if overlayVisible {
            if overlay == nil { overlay = SubtitleOverlayController(model: self) }
            overlay?.show()
        } else {
            overlay?.hide()
        }
    }

    // MARK: Test phrase (wizard)

    static let testPhrase = "Olá! Aqui é o Ponte, o tradutor do Dmitrii. Vocês estão me ouvindo bem?"

    /// Speaks a pt-BR phrase into the call output (BlackHole) or into the headphones.
    func playTestPhrase(intoCall: Bool) async throws {
        if intoCall && blackHoleDevice == nil { throw CocoaError(.featureUnsupported) }
        let synth = SystemSpeechSynth(voiceIdentifiers: voiceMap)
        let buffers = try await synth.synthesize(Self.testPhrase, lang: .ptBR)
        let player = DeviceAudioPlayer(device: intoCall ? blackHoleDevice : headphonesDevice)
        await player.play(buffers)
    }
}
