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

    var light: Int32 {
        switch self {
        case .unknown: AppRules.LIGHT_UNKNOWN
        case .ok: AppRules.LIGHT_OK
        case .bad: AppRules.LIGHT_BAD
        case .busy: AppRules.LIGHT_BUSY
        case .warn: AppRules.LIGHT_WARN
        }
    }

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
    enum Kind {
        case error, warning, info

        /// AppRules.BK_* (BK_NONE never makes a banner; it reads as info).
        init(code: Int32) {
            switch code {
            case AppRules.BK_ERROR: self = .error
            case AppRules.BK_WARNING: self = .warning
            default: self = .info
            }
        }
    }
    enum Action: Equatable {
        case openWizard(WizardStep)
        case reveal(URL)
        case accessibility
        /// System Settings → Privacy & Security pane (anchor such as "Privacy_ScreenCapture").
        case privacySettings(String)
        /// The checklist «Перед звонком».
        case openChecklist
    }

    let id = UUID()
    let kind: Kind
    let text: String
    var action: Action?
    var actionTitle: String?
}

/// The silence warning of one call. AppRules.silenceBanner decides from the source light: give the warning
/// once while the light is WARN, take it down as soon as the light is anything else. This keeps only what
/// the rule needs: whether the warning was given, and which banner on screen is the warning.
struct SilenceWarning {
    private(set) var warned = false
    private var bannerID: UUID?

    /// A new call.
    mutating func reset() {
        warned = false
        bannerID = nil
    }

    /// The banner to show after a poll that read `sourceLight` (AppRules.LIGHT_*); `current` is the banner on screen.
    mutating func banner(after current: Banner?, sourceLight: Int32, sourceName: String?) -> Banner? {
        let silenceShown = bannerID.map { current?.id == $0 } ?? false
        switch AppRules.silenceBanner(sourceLight: sourceLight, alreadyWarned: warned,
                                      errorShown: current?.kind == .error, silenceShown: silenceShown) {
        case AppRules.SB_MARK:
            warned = true
            return current
        case AppRules.SB_SHOW:
            warned = true
            let warning = Banner(kind: .warning, text: AppModel.silenceText(sourceName),
                                 action: .privacySettings("Privacy_ScreenCapture"), actionTitle: "Открыть настройки")
            bannerID = warning.id
            return warning
        case AppRules.SB_CLEAR:
            bannerID = nil
            return nil
        default:
            return current
        }
    }
}

/// The call's red banner when the call app does not listen to BlackHole, or listens to a real microphone
/// (AppRules.listenerBanner: the checklist's listener row is red during a call). This keeps only what the rule
/// needs: since when the row is red, which banner on screen is this one, and whether the owner closed it.
struct ListenerWarning {
    private var bannerID: UUID?
    private var dismissed = false
    private var badSince: Date?

    /// A new call.
    mutating func reset() {
        bannerID = nil
        dismissed = false
        badSince = nil
    }

    /// The banner to show after a poll; `mark` is the listener row's AppRules.CK_*, `text` its red text.
    mutating func banner(after current: Banner?, runState: Int32, mark: Int32, now: Date, text: () -> String) -> Banner? {
        if let id = bannerID, current?.id != id {
            // Gone from the screen: closed by the owner, or replaced by another banner (which it takes over again).
            if current == nil { dismissed = true }
            bannerID = nil
        }
        if AppRules.listenerStreak(mark: mark) {
            if badSince == nil { badSince = now }
        } else {
            badSince = nil
            dismissed = false
        }
        let msBad = badSince.map { millis(now.timeIntervalSince($0)) } ?? -1
        switch AppRules.listenerBanner(runState: runState, mark: mark, msBad: msBad, shown: bannerID != nil, dismissed: dismissed) {
        case AppRules.LB_SHOW:
            let wanted = text()
            if bannerID != nil, current?.text == wanted { return current }
            let warning = Banner(kind: .error, text: wanted, action: .openChecklist, actionTitle: "Перед звонком")
            bannerID = warning.id
            return warning
        case AppRules.LB_CLEAR:
            bannerID = nil
            return nil
        default:
            return current
        }
    }
}

/// Which sheet the main window shows (one at a time).
enum MainSheet: Identifiable {
    case wizard, checklist
    var id: Self { self }
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
    @ObservationIgnored private var outgoingMic: MicSource?
    @ObservationIgnored private var terminationSignal: DispatchSourceSignal?
    @ObservationIgnored private var silenceWarning = SilenceWarning()
    @ObservationIgnored private var listenerWarning = ListenerWarning()

    // MARK: Catalog snapshots

    var devices: [AudioDevice] = []
    var audioApps: [AudioApp] = []
    var defaultOutput: AudioDevice?
    var blackHoleDevice: AudioDevice?
    var accessibilityGranted = PushToTalkMonitor.hasGlobalPermission
    /// The owner listens on a loudspeaker (built-in or display speakers, AirPlay):
    /// AudioRules.echoRisk of the listening device is echoSpeaker. Shows «наденьте наушники».
    var speakerWarning = false
    /// The listening output is headphones or a headset (AudioRules.isHeadphonesLike).
    var headphonesLike = false
    /// Ponte's microphone when the settings say «Автоматически» (AudioRules.pickAutoMicIndex).
    var autoMicDevice: AudioDevice?
    /// Who listens to BlackHole (AudioInputReaders.check), re-read while the checklist is open or a call runs.
    var listener = ListenerCheck.unknown

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
    /// «Показывать при запуске» of the checklist «Перед звонком».
    var checklistOnLaunch: Bool { didSet { defaults.set(checklistOnLaunch, forKey: PrefKey.checklistOnLaunch) } }

    // MARK: Session

    var runState: RunState = .idle
    var lines: [ConversationLine] = []
    var incomingPartial = ""
    var outgoingPartial = ""
    var incomingSpeaking = false
    var outgoingSpeaking = false
    /// «Пауза голоса в звонок»: the outgoing lane stops listening and speaking.
    var voicePaused = false { didSet { outgoingLane?.isPaused = voicePaused } }
    /// «Свой голос»: the microphone goes into the call as it is; your speech is not translated.
    var ownVoice = false {
        didSet {
            guard ownVoice != oldValue else { return }
            outgoingLane?.setOwnVoice(ownVoice)
            log.info("own voice \(self.ownVoice, privacy: .public)")
        }
    }
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
    /// AppRules.MIC_* of the outgoing microphone (MicSource's status; MIC_NONE until a source reports one).
    var micSourceStatus = AppRules.MIC_NONE
    private var everStarted = false
    private var lanesStarted: Int32 = 0
    private var lanesFailed: Int32 = 0
    /// Running lanes whose translator is not ready (they show originals only).
    private var translatorsFailed: Int32 = 0

    // MARK: Wizard

    var showWizard = false
    var wizardStep: WizardStep = .permissions
    /// The checklist «Перед звонком».
    var showChecklist = false

    /// The one sheet on screen: the wizard wins (AppRules.checklistOpens never opens the checklist over it).
    var sheet: MainSheet? {
        get { showWizard ? .wizard : showChecklist ? .checklist : nil }
        set {
            showWizard = newValue == .wizard
            showChecklist = newValue == .checklist
        }
    }

    init(launch: LaunchOptions = .current) {
        self.launch = launch
        let d = UserDefaults.standard
        sourceKey = d.string(forKey: PrefKey.source) ?? AppRules.SOURCE_SYSTEM_KEY
        var storedMic = d.string(forKey: PrefKey.micUID) ?? ""
        // Before «Автоматически» existed the stored microphone was set by the lead, not the owner: once, it
        // becomes automatic (ui_mic_migration).
        switch AppRules.micMigration(migrated: d.bool(forKey: PrefKey.micAutoMigrated), hasSetting: !storedMic.isEmpty) {
        case AppRules.MIGRATE_CLEAR:
            storedMic = ""
            d.removeObject(forKey: PrefKey.micUID)
            d.set(true, forKey: PrefKey.micAutoMigrated)
        case AppRules.MIGRATE_MARK:
            d.set(true, forKey: PrefKey.micAutoMigrated)
        default:
            break
        }
        micUID = storedMic
        headphonesUID = d.string(forKey: PrefKey.headphonesUID) ?? ""
        callOutputUID = d.string(forKey: PrefKey.callOutputUID) ?? ""
        voicePT = d.string(forKey: PrefKey.voicePT) ?? ""
        voiceRU = d.string(forKey: PrefKey.voiceRU) ?? ""
        speakRussian = d.object(forKey: PrefKey.speakRussian) == nil ? AppRules.DEFAULT_SPEAK_RUSSIAN
            : d.bool(forKey: PrefKey.speakRussian)
        translatorKind = TranslatorKind(rawValue: d.string(forKey: PrefKey.translator) ?? "")
            ?? TranslatorKind(ruleCode: AppRules.DEFAULT_TRANSLATOR)
        glossary = GlossaryTerm.decode(d.string(forKey: PrefKey.glossary) ?? "[]")
        let storedMode = CaptureMode(rawValue: d.string(forKey: PrefKey.outgoingMode) ?? "")
            ?? CaptureMode(ruleCode: AppRules.DEFAULT_MODE)
        // Push-to-talk only (lane_rules: ln_lane_mode); a stored «Авто» is ignored.
        outgoingMode = CaptureMode(ruleCode: AppRules.laneMode(direction: AppRules.directionCode(.outgoing),
                                                               outgoingMode: storedMode.ruleCode))
        pttKey = PTTKey(rawValue: d.string(forKey: PrefKey.pttKey) ?? "") ?? PTTKey(ruleCode: AppRules.DEFAULT_PTT_KEY)
        fontSize = Double(AppRules.translationFontSize(stored: Int32(d.integer(forKey: PrefKey.fontSize))))
        overlayVisible = d.object(forKey: PrefKey.overlayVisible) == nil ? AppRules.DEFAULT_OVERLAY_VISIBLE
            : d.bool(forKey: PrefKey.overlayVisible)
        setupCompleted = d.bool(forKey: PrefKey.setupCompleted)
        checklistOnLaunch = d.object(forKey: PrefKey.checklistOnLaunch) == nil ? AppRules.DEFAULT_CHECKLIST_ON_LAUNCH
            : d.bool(forKey: PrefKey.checklistOnLaunch)
        // Launch arguments for demos, screenshots and end-to-end checks (LaunchOptions):
        //   open dist/Ponte.app --args -PonteWizardStep 3 -PonteAutostart YES
        showWizard = AppRules.wizardShowOnLaunchInMode(setupCompleted: setupCompleted, forcedStep: launch.wizardStep,
                                                       testMode: launch.isTestMode)
        if let step = WizardStep(code: launch.wizardStep) { wizardStep = step }
        showChecklist = AppRules.checklistOpens(reason: AppRules.CKO_LAUNCH, showOnLaunch: checklistOnLaunch,
                                                wizardShown: showWizard, testMode: launch.isTestMode,
                                                autostart: launch.autostart)
        ptt.key = pttKey
        refreshCatalogs()
        if showChecklist { refreshListener() }
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
    /// The microphone chosen in the settings, if it is connected.
    var savedMicDevice: AudioDevice? { devices.first { $0.uid == micUID && $0.inputChannels > 0 } }
    /// AppRules.MICSRC_*: the setting, the automatic pick, or the system default (no microphone found).
    var micSource: Int32 {
        AppRules.micSource(hasSetting: !micUID.isEmpty, found: savedMicDevice != nil, hasAuto: autoMicDevice != nil)
    }
    /// Ponte's microphone (nil: the system default input).
    var micDevice: AudioDevice? {
        switch micSource {
        case AppRules.MICSRC_SAVED: savedMicDevice
        case AppRules.MICSRC_AUTO: autoMicDevice
        default: nil
        }
    }
    var headphonesDevice: AudioDevice? { devices.first { $0.uid == headphonesUID && $0.outputChannels > 0 } }
    var inputDevices: [AudioDevice] { devices.filter { $0.inputChannels > 0 && !AudioRules.isBlackHole(name: $0.name) } }
    var outputDevices: [AudioDevice] { devices.filter { $0.outputChannels > 0 } }

    /// Where the user hears things: chosen headphones or the system output.
    var listeningDevice: AudioDevice? { headphonesDevice ?? defaultOutput }

    /// The listening output decides the headphone warning, the checklist's headphones row and the automatic microphone.
    private func refreshSpeakerWarning() {
        let kind = listeningDevice.map { deviceCatalog.kind(of: $0) }
        let warning = kind.map { AudioRules.needsHeadphones(kind: $0) } ?? false
        if warning != speakerWarning { speakerWarning = warning }
        let like = kind.map { AudioRules.isHeadphonesLike(kind: $0) } ?? false
        if like != headphonesLike { headphonesLike = like }
        let auto = deviceCatalog.autoMic(in: devices, listening: listeningDevice)
        if auto != autoMicDevice { autoMicDevice = auto }
    }

    var source: SourceChoice { SourceChoice(key: sourceKey) }

    var sourceTitle: String {
        var id = ""
        if case .app(let bundleID) = source { id = bundleID }
        let running = audioApps.first { $0.bundleID == id }?.name
        let label = AudioApp.knownCallApps[id]
        switch AppRules.sourceTitle(isSystem: source == .system, hasRunningName: running != nil, hasLabel: label != nil) {
        case AppRules.TITLE_SYSTEM: return "Весь звук Мака"
        case AppRules.TITLE_RUNNING: return running ?? id
        case AppRules.TITLE_LABEL: return label ?? id
        default: return id
        }
    }

    /// Tooltip of «Звук источника».
    var sourceHelp: String {
        switch AppRules.sourceHelp(runState: runState.code, tapStatus: sourceTapStatus, sourceLight: sourceCheck.light) {
        case AppRules.HELP_IDLE:
            return "Идёт ли звук из выбранной программы"
        case AppRules.HELP_WAITING:
            return "Ждём звук: «\(activeSourceName ?? "")» ещё не выводит звук. Ponte подключится сам, когда начнётся звонок."
        case AppRules.HELP_FAILED:
            return "Не удалось подключиться к звуку: \(sourceTapDetail ?? "")"
        case AppRules.HELP_FILE:
            return "Тестовый режим: звук из файла \(launch.incomingFile?.lastPathComponent ?? "")"
        case AppRules.HELP_SILENCE:
            return Self.silenceText(activeSourceName)
        default:
            return "Звук из «\(activeSourceName ?? "")» идёт"
        }
    }

    nonisolated static func silenceText(_ name: String?) -> String {
        "Из «\(name ?? "источника")» приходит только тишина. Если собеседники говорят, а текста нет, — разрешите Ponte "
            + "запись системного звука: Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука."
    }

    var blackHoleCheck: Check { Check(light: AppRules.blackHoleLight(found: blackHoleDevice != nil)) }

    var modelsCheck: Check {
        Check(light: AppRules.modelsLightAll(runState: runState.code, everStarted: everStarted, lanesStarted: lanesStarted,
                                             lanesFailed: lanesFailed, translatorsFailed: translatorsFailed))
    }

    /// AppRules.LAT_* for the last phrase.
    var latencyColorCode: Int32 { AppRules.latencyColor(ms: lastLatency.map { millis($0) } ?? -1) }

    /// The «Свой голос» button works (AppRules.ownVoiceAvailable); pressing it asks AppRules.ownVoiceAfterToggle.
    var ownVoiceAvailable: Bool { AppRules.ownVoiceAvailable(running: isRunning, hasCallOutput: hasLiveCallOutput) }
    func toggleOwnVoice() {
        ownVoice = AppRules.ownVoiceAfterToggle(ownVoice: ownVoice, running: isRunning, hasCallOutput: hasLiveCallOutput)
    }
    /// The outgoing lane runs with a call output.
    private var hasLiveCallOutput: Bool {
        outgoingLane != nil && AppRules.hasCallOutput(hasBlackHole: blackHoleDevice != nil, hasSink: launch.outgoingSink != nil)
    }

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
        refreshDevices()
        audioApps = appCatalog.apps()
    }

    /// Devices, the default output, the call output, the headphone warning and the automatic microphone.
    private func refreshDevices() {
        let listed = deviceCatalog.devices()
        if listed != devices { devices = listed }
        let output = deviceCatalog.defaultOutput()
        if output != defaultOutput { defaultOutput = output }
        let chosen = devices.first { $0.uid == callOutputUID }
        let callOutput: AudioDevice?
        switch AppRules.deviceChoice(hasSetting: !callOutputUID.isEmpty, found: chosen != nil) {
        case AppRules.DEV_SAVED: callOutput = chosen
        default: callOutput = BlackHoleCheck.find(in: deviceCatalog)
        }
        if callOutput != blackHoleDevice { blackHoleDevice = callOutput }
        refreshSpeakerWarning()
    }

    // MARK: Checklist «Перед звонком»

    /// Who listens to BlackHole now, for the chosen source (AudioInputReaders.check).
    func refreshListener() {
        var target: String?
        if case .app(let bundleID) = source { target = bundleID }
        let present = AudioRules.pickBlackHoleIndex(names: devices.map(\.name), outputChannels: devices.map(\.outputChannels)) >= 0
        let check = AudioInputReaders.check(AudioInputReaders.snapshot(), targetBundleID: target, blackHolePresent: present)
        if check != listener { listener = check }
    }

    /// What the checklist shows.
    var checklistFacts: ChecklistFacts {
        ChecklistFacts(listenStatus: Int32(listener.status), listenAppName: listener.reader?.appName,
                       listenDeviceName: listener.reader?.device.name,
                       listenDeviceKind: listener.reader?.deviceKind ?? AudioRules.kindUnknown,
                       listeningName: listeningDevice?.name, headphonesLike: headphonesLike,
                       micName: micDevice?.name, micSource: micSource, pttKeyShort: pttKey.short)
    }

    var checklistItems: [ChecklistItem] { Checklist.items(checklistFacts) }

    /// Opens the checklist (toolbar, menu, banner); never over the wizard.
    func openChecklist() {
        guard AppRules.checklistOpens(reason: AppRules.CKO_ASKED, showOnLaunch: checklistOnLaunch, wizardShown: showWizard,
                                      testMode: launch.isTestMode, autostart: launch.autostart) else { return }
        refreshCatalogs()
        refreshListener()
        showChecklist = true
    }

    /// «Начать»: closes the checklist and starts translation (only from idle).
    func startFromChecklist() {
        showChecklist = false
        if AppRules.checklistCanStart(runState: runState.code) { toggleRun() }
    }

    /// Opens the setup wizard on a step, in place of the checklist if it is open.
    func openWizard(_ step: WizardStep) {
        wizardStep = step
        sheet = .wizard
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var tick: Int64 = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.pollAudioStats()
                if AppRules.pollRefreshesCatalogs(tick: tick) { self.refreshCatalogs() }
                if AppRules.pollReadsListeners(tick: tick, sheetOpen: self.showChecklist, runState: self.runState.code) {
                    // The open checklist follows plugged headphones within a second, too.
                    if self.showChecklist { self.refreshDevices() }
                    self.refreshListener()
                }
                self.pollListenerBanner()
                tick += 1
                try? await Task.sleep(for: .milliseconds(AppRules.POLL_INTERVAL_MS))
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
        sourceLevel = AppRules.showsLevel(light: sourceCode) ? incoming?.level ?? 0 : 0

        let mic = AppModel.micStatus(runState: runState.code, stats: outgoingLane?.audioStats, micSource: micSourceStatus,
                                     callStartedAt: callStartedAt, now: now)
        micCheck = Check(light: mic.light)
        micLevel = mic.level

        if isRunning {
            translatorsFailed = Int32([incomingLane, outgoingLane].compactMap { $0 }.filter { $0.translatorError != nil }.count)
        }
        // The silence banner follows the source light: it goes as soon as a non-zero sample turns the light OK.
        let next = silenceWarning.banner(after: banner, sourceLight: sourceCode, sourceName: activeSourceName)
        if next != banner { banner = next }
    }

    /// The red banner of the listener row during a call (ListenerWarning).
    private func pollListenerBanner() {
        let mark = AppRules.listenerMark(listenStatus: Int32(listener.status))
        let facts = checklistFacts
        let next = listenerWarning.banner(after: banner, runState: runState.code, mark: mark, now: Date()) {
            Checklist.listenerText(facts)
        }
        if next != banner { banner = next }
    }

    /// «Микрофон» light and meter level from the outgoing lane's stats (nil: no outgoing lane) and the
    /// microphone's status (AppRules.MIC_*).
    nonisolated static func micStatus(runState: Int32, stats: LaneAudioStats?, micSource: Int32, callStartedAt: Date?,
                                      now: Date) -> (light: Int32, level: Float) {
        func since(_ date: Date?) -> Int64 { date.map { millis(now.timeIntervalSince($0)) } ?? -1 }
        let msSinceBuffer = since(stats?.lastBufferAt)
        let light = AppRules.micLight(runState: runState, laneActive: stats != nil, micStatus: micSource,
                                      msSinceStart: callStartedAt.map { millis(now.timeIntervalSince($0)) } ?? 0,
                                      msSinceListen: since(stats?.listeningSince), msSinceBuffer: msSinceBuffer)
        let level = AppRules.micShowsLevel(light: light, msSinceBuffer: msSinceBuffer) ? stats?.level ?? 0 : 0
        return (light, level)
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

    /// MicSource.Status → AppRules.MIC_*. Called on the source's queue.
    nonisolated static func micCode(_ status: MicSource.Status) -> Int32 {
        switch status {
        case .idle: return AppRules.MIC_IDLE
        case .capturing: return AppRules.MIC_CAPTURING
        case .restarting: return AppRules.MIC_RESTARTING
        case .failed: return AppRules.MIC_FAILED
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
        if AppRules.sourceKind(hasTestFile: launch.incomingFile != nil) == AppRules.SOURCE_FILE, let url = launch.incomingFile {
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
        ownVoice = false
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
        silenceWarning.reset()
        listenerWarning.reset()
        sourceTapDetail = nil
        refreshListener()
        pollAudioStats()

        // The microphone prompt comes before the engine starts: MicSource refuses an undecided permission.
        let micIsLive = AppRules.sourceKind(hasTestFile: launch.outgoingFile != nil) == AppRules.SOURCE_LIVE
        if AppRules.requestsMicPermission(
            micIsLive: micIsLive, micDecision: AudioRules.micStartDecision(authorizationStatus: MicSource.permission.rawValue)) {
            _ = await MicSource.requestPermission()
        }

        let translator = makeTranslator()
        translatorInUse = translator.name
        let synth = SystemSpeechSynth(voiceIdentifiers: voiceMap)
        let echoOutput = AppRules.echoGuardApplies(speakerOutput: speakerWarning, micIsLive: micIsLive)
        echoGuard.configure(speakerOutput: echoOutput)
        let callOutput: AudioPlayer?
        switch AppRules.callOutput(hasSink: launch.outgoingSink != nil, hasBlackHole: blackHoleDevice != nil) {
        case AppRules.OUT_SINK: callOutput = launch.outgoingSink.map { WAVFileSink(url: $0) }
        case AppRules.OUT_DEVICE: callOutput = blackHoleDevice.map { DeviceAudioPlayer(device: $0) }
        default: callOutput = nil
        }
        let outgoingSource: AudioSource
        if !micIsLive, let url = launch.outgoingFile {
            outgoingMic = nil
            micSourceStatus = AppRules.MIC_NONE
            outgoingSource = fileSource(url, direction: .outgoing)
        } else {
            let mic = MicSource(device: micDevice)
            mic.onStatusChange = { [weak self, weak mic] status in
                let code = AppModel.micCode(status)
                Task { @MainActor in
                    guard let self, let mic, mic === self.outgoingMic else { return }
                    self.micSourceStatus = code
                    self.log.info("mic status \(code, privacy: .public)")
                    self.pollAudioStats()
                }
            }
            outgoingMic = mic
            micSourceStatus = AppRules.MIC_IDLE
            outgoingSource = mic
        }
        func mode(_ direction: Direction) -> CaptureMode {
            CaptureMode(ruleCode: AppRules.laneMode(direction: AppRules.directionCode(direction), outgoingMode: outgoingMode.ruleCode))
        }
        func speaks(_ direction: Direction) -> Bool {
            AppRules.laneSpeaks(direction: AppRules.directionCode(direction), speakRussian: speakRussian)
        }
        let incoming = TranslationLane(
            direction: .incoming,
            source: makeIncomingSource(),
            makeTranscriber: { AppleTranscriber(language: .ptBR) },
            translator: translator,
            synth: synth,
            player: DeviceAudioPlayer(device: headphonesDevice),
            memory: memory,
            mode: mode(.incoming),
            speechOutputEnabled: speaks(.incoming))
        let outgoing = TranslationLane(
            direction: .outgoing,
            source: outgoingSource,
            makeTranscriber: { AppleTranscriber(language: .ru) },
            translator: translator,
            synth: synth,
            player: callOutput,
            memory: memory,
            mode: mode(.outgoing),
            speechOutputEnabled: speaks(.outgoing))
        for lane in [incoming, outgoing] {
            lane.glossary = glossary
            let direction = lane.direction
            lane.onEvent = { [weak self] event in self?.handle(event, from: direction) }
            let code = AppRules.directionCode(direction)
            if AppRules.laneVoicePause(direction: code) { lane.isPaused = voicePaused }
            if AppRules.laneEchoGuarded(direction: code) { lane.echoGuard = echoGuard }
        }

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
            outgoingMic = nil
            micSourceStatus = AppRules.MIC_NONE
        }
        pollAudioStats()
        updatePushToTalk()
        // Test mode (-PonteOutgoingFile): the outgoing lane is push-to-talk only, so the file is
        // "spoken" with the talk key held, as a person would.
        if isRunning, launch.outgoingFile != nil { setTalkKey(true) }

        let hasCallOutput = AppRules.hasCallOutput(hasBlackHole: blackHoleDevice != nil, hasSink: launch.outgoingSink != nil)
        let startBanner = AppRules.startBannerAfterStart(lanesFailed: lanesFailed, translatorsFailed: translatorsFailed,
                                                         packsMissing: !missingPacks.isEmpty, hasBlackHole: hasCallOutput,
                                                         speakerOutput: echoOutput)
        // Kind and wizard step come from AppRules; the texts are here.
        let kind = Banner.Kind(code: AppRules.bannerKind(banner: startBanner))
        let step = WizardStep(code: AppRules.bannerStep(banner: startBanner))
        switch startBanner {
        case AppRules.BAN_NO_PACKS:
            banner = packsBanner(missingPacks)
        case AppRules.BAN_NO_TRANSLATOR:
            banner = Banner(kind: kind,
                            text: "Речь распознаётся, но перевод недоступен.\n" + translatorProblems.joined(separator: "\n"),
                            action: step.map { .openWizard($0) }, actionTitle: "Открыть мастер")
        case AppRules.BAN_FAILED_PACKS, AppRules.BAN_FAILED_OTHER:
            banner = Banner(kind: kind, text: problems.joined(separator: "\n"),
                            action: step.map { .openWizard($0) }, actionTitle: "Открыть мастер")
        case AppRules.BAN_NO_BLACKHOLE:
            banner = Banner(kind: kind,
                            text: "BlackHole не найден: перевод на португальский виден здесь, но в звонок не идёт.",
                            action: step.map { .openWizard($0) }, actionTitle: "Как установить")
        case AppRules.BAN_SPEAKERS:
            banner = Banner(kind: kind,
                            text: "Звук идёт в динамики Мака. Микрофон услышит собеседников — наденьте наушники.")
        default:
            break
        }
    }

    func stop() async {
        guard AppRules.toggleRun(runState: runState.code) == AppRules.TOGGLE_STOP else { return }
        runState = .stopping
        ownVoice = false
        ptt.stop()
        talkKeyHeld = false
        pttIsGlobal = false
        await incomingLane?.stop()
        await outgoingLane?.stop()
        incomingLane = nil
        outgoingLane = nil
        incomingTap = nil
        sourceTapStatus = AppRules.TAP_IDLE
        outgoingMic = nil
        micSourceStatus = AppRules.MIC_NONE
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
        let probe = AppRules.probesClaude(preferred: translatorKind.ruleCode)
        let choice = AppRules.translatorChoice(preferred: translatorKind.ruleCode,
                                               claudeAvailable: probe && claudeTranslator() != nil)
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
        let step = WizardStep(code: AppRules.bannerStep(banner: AppRules.BAN_NO_PACKS))
        return Banner(kind: Banner.Kind(code: AppRules.bannerKind(banner: AppRules.BAN_NO_PACKS)),
                      text: "Перевод не работает: не скачаны языковые пакеты Apple\(which). Речь распознаётся, "
                          + "оригинал виден. Скачайте пакеты в мастере — перевод включится сам.",
                      action: step.map { .openWizard($0) }, actionTitle: "Скачать пакеты")
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
            // The start banner may say it already; show it again only if it was closed.
            let text = "Перевод: \(describe(error))"
            let packsStep = WizardStep(code: AppRules.bannerStep(banner: AppRules.BAN_NO_PACKS))
            switch AppRules.translationErrorBanner(missingPacks: isMissingPacks(error),
                                                   packsBannerShown: banner?.action == packsStep.map { Banner.Action.openWizard($0) },
                                                   sameTextShown: banner?.text == text) {
            case AppRules.TEB_PACKS: banner = packsBanner([error])
            case AppRules.TEB_WARNING: banner = Banner(kind: .warning, text: text)
            default: break
            }
        case .speaking(let on):
            if direction == .incoming { incomingSpeaking = on } else { outgoingSpeaking = on }
            if AppRules.laneEchoSource(direction: AppRules.directionCode(direction)) { echoGuard.setSpeaking(on, at: Date()) }
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
                                                   endedAt: AppRules.transcriptHasEnd(runState: runState.code) ? Date() : nil,
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
            openWizard(step)
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .accessibility:
            requestAccessibility()
        case .privacySettings(let anchor):
            Permissions.openPrivacySettings(anchor)
        case .openChecklist:
            openChecklist()
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
        guard AppRules.testPhrasePossible(intoCall: intoCall, hasBlackHole: blackHoleDevice != nil) else {
            throw CocoaError(.featureUnsupported)
        }
        let synth = SystemSpeechSynth(voiceIdentifiers: voiceMap)
        let buffers = try await synth.synthesize(Self.testPhrase, lang: .ptBR)
        let player = DeviceAudioPlayer(device: intoCall ? blackHoleDevice : headphonesDevice)
        await player.play(buffers)
    }
}
