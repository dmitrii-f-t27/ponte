import AppKit
import AVFoundation
import Foundation
import Observation
import PonteAudio
import PonteCore
import PonteSpeech

/// A status light (AppRules.LIGHT_*), as the views draw it.
enum Check: Equatable {
    case unknown, ok, bad, busy

    init(light: Int32) {
        switch light {
        case AppRules.LIGHT_OK: self = .ok
        case AppRules.LIGHT_BAD: self = .bad
        case AppRules.LIGHT_BUSY: self = .busy
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

    // MARK: Catalog snapshots

    var devices: [AudioDevice] = []
    var audioApps: [AudioApp] = []
    var defaultOutput: AudioDevice?
    var blackHoleDevice: AudioDevice?
    var accessibilityGranted = PushToTalkMonitor.hasGlobalPermission

    // MARK: Settings (persisted)

    var sourceKey: String { didSet { defaults.set(sourceKey, forKey: PrefKey.source) } }
    var micUID: String { didSet { defaults.set(micUID, forKey: PrefKey.micUID) } }
    var headphonesUID: String { didSet { defaults.set(headphonesUID, forKey: PrefKey.headphonesUID) } }
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
    private var everStarted = false
    private var lanesStarted: Int32 = 0
    private var lanesFailed: Int32 = 0

    // MARK: Wizard

    var showWizard = false
    var wizardStep: WizardStep = .permissions

    init() {
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
        // Launch-argument hook for demos and screenshots (argument domain, never persisted):
        //   open dist/Ponte.app --args -PonteWizardStep 3 -PonteAutostart YES
        let forced = d.object(forKey: "PonteWizardStep") != nil ? Int32(d.integer(forKey: "PonteWizardStep")) : AppRules.WZ_NONE
        showWizard = AppRules.wizardShowOnLaunch(setupCompleted: setupCompleted, forcedStep: forced)
        if let step = WizardStep(code: forced) { wizardStep = step }
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
        if defaults.bool(forKey: "PonteAutostart") {
            Task { await start() }
        }
        if let appearance = defaults.string(forKey: "PonteAppearance") {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
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
    var speakerWarning: Bool { listeningDevice?.isBuiltInSpeaker == true }

    var source: SourceChoice { SourceChoice(key: sourceKey) }

    var sourceTitle: String {
        switch source {
        case .system: return "Весь звук Мака"
        case .app(let id):
            return audioApps.first { $0.bundleID == id }?.name ?? AudioApp.knownCallApps[id] ?? id
        }
    }

    var blackHoleCheck: Check { Check(light: AppRules.blackHoleLight(found: blackHoleDevice != nil)) }

    var modelsCheck: Check {
        Check(light: AppRules.modelsLight(runState: runState.code, everStarted: everStarted,
                                          lanesStarted: lanesStarted, lanesFailed: lanesFailed))
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
        }
        return cachedClaude
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
        func light(_ lane: TranslationLane?) -> (Check, Float) {
            let stats = lane?.audioStats
            let sinceBuffer = stats?.lastBufferAt.map { millis(now.timeIntervalSince($0)) } ?? -1
            let code = AppRules.audioLight(runState: runState.code, laneActive: lane != nil,
                                           msSinceStart: sinceStart, msSinceBuffer: sinceBuffer)
            return (Check(light: code), code == AppRules.LIGHT_OK ? stats?.level ?? 0 : 0)
        }
        (sourceCheck, sourceLevel) = light(incomingLane)
        (micCheck, micLevel) = light(outgoingLane)
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
        activeSourceName = sourceTitle
        everStarted = true
        lanesStarted = 0
        lanesFailed = 0
        pollAudioStats()

        let translator = makeTranslator()
        translatorInUse = translator.name
        let synth = SystemSpeechSynth(voiceIdentifiers: voiceMap)
        echoGuard.configure(speakerOutput: speakerWarning)
        let incoming = TranslationLane(
            direction: .incoming,
            source: AppAudioTapSource(target: source.target),
            makeTranscriber: { AppleTranscriber(language: .ptBR) },
            translator: translator,
            synth: synth,
            player: DeviceAudioPlayer(device: headphonesDevice),
            memory: memory,
            mode: .continuous,
            speechOutputEnabled: speakRussian)
        let outgoing = TranslationLane(
            direction: .outgoing,
            source: MicSource(device: micDevice),
            makeTranscriber: { AppleTranscriber(language: .ru) },
            translator: translator,
            synth: synth,
            player: blackHoleDevice.map { DeviceAudioPlayer(device: $0) },
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
        var packsMissing = false
        for (lane, title) in [(incoming, "Они → по-русски"), (outgoing, "Я → по-португальски")] {
            do {
                try await lane.start()
                if lane.direction == .incoming { incomingLane = lane } else { outgoingLane = lane }
                lanesStarted += 1
            } catch {
                lanesFailed += 1
                problems.append("\(title): \(describe(error))")
                packsMissing = packsMissing || isMissingPacks(error)
            }
        }

        runState = RunState(code: AppRules.runStateAfterStart(lanesStarted: lanesStarted))
        if !isRunning { callStartedAt = nil }
        pollAudioStats()
        updatePushToTalk()

        switch AppRules.startBanner(lanesFailed: lanesFailed, packsMissing: packsMissing,
                                    hasBlackHole: blackHoleDevice != nil, speakerOutput: speakerWarning) {
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

    private func makeTranslator() -> Translator {
        let choice = AppRules.translatorChoice(preferred: translatorKind.ruleCode,
                                               claudeAvailable: translatorKind == .claude && claudeTranslator() != nil)
        if choice == AppRules.TR_CLAUDE, let claude = claudeTranslator() { return claude }
        return AppleTranslator()
    }

    private func isMissingPacks(_ error: Error) -> Bool {
        if case PonteSpeechError.translationAssetsMissing = error { return true }
        return false
    }

    private func describe(_ error: Error) -> String {
        if case PonteSpeechError.translationAssetsMissing(let from, let to) = error {
            return "не скачан языковой пакет \(from.rawValue) → \(to.rawValue)"
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
                                                   sourceName: activeSourceName)
            lastTranscriptURL = url
            banner = Banner(kind: .info, text: "Стенограмма сохранена: ~/Documents/Ponte/\(url.lastPathComponent)",
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
        for buffer in buffers { await player.play(buffer) }
    }
}
