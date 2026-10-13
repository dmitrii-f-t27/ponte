import AVFoundation
import PonteAudio
import PonteCore
import PonteSpeech
import SwiftUI
import Translation

extension WizardStep {
    var title: String {
        switch self {
        case .permissions: "Разрешения"
        case .models: "Модели речи"
        case .packs: "Языковые пакеты"
        case .blackHole: "BlackHole"
        case .callApps: "Звонилки"
        case .done: "Готово"
        }
    }

    var systemImage: String {
        switch self {
        case .permissions: "lock.shield"
        case .models: "waveform.badge.magnifyingglass"
        case .packs: "character.book.closed"
        case .blackHole: "cable.connector"
        case .callApps: "phone.bubble"
        case .done: "checkmark.seal"
        }
    }
}

/// Wizard-only state: permission and download checks.
@MainActor @Observable
final class SetupState {
    var mic = Permissions.microphone
    var speech = Permissions.speech
    var capture: Check = .unknown
    var captureDetail: String?
    var models: [Lang: Check] = [.ptBR: .unknown, .ru: .unknown]
    var modelErrors: [Lang: String] = [:]
    var packs: [Direction: Check] = [.incoming: .unknown, .outgoing: .unknown]
    var packErrors: [Direction: String] = [:]
    var packConfig: TranslationSession.Configuration?
    var packDirection: Direction?
    var testCall: Check = .unknown
    var testHeadphones: Check = .unknown

    func refreshPermissions() {
        mic = Permissions.microphone
        speech = Permissions.speech
    }

    /// Listens to all audio except Ponte for AppRules.CAPTURE_CHECK_MS (macOS asks for the
    /// System Audio Recording permission the first time). The verdict comes from the tap status
    /// and the samples: a tap without the permission delivers only exact zeros.
    func checkCapture() async {
        capture = .busy
        captureDetail = nil
        let source = AppAudioTapSource(target: .systemExceptSelf)
        let meter = CaptureMeter()
        do {
            try source.start { buffer, _ in meter.add(buffer) }
        } catch {
            source.stop()
            capture = .bad
            captureDetail = "Не удалось подключиться к звуку: \(error)"
            return
        }
        try? await Task.sleep(for: .milliseconds(Int(AppRules.CAPTURE_CHECK_MS)))
        let status = AppModel.tapCode(source.status)
        source.stop()
        let (frames, signal) = meter.result
        let light = AppRules.captureCheckLight(tapStatus: status.code, framesSeen: frames > 0, signalSeen: signal)
        capture = Check(light: light)
        switch light {
        case AppRules.LIGHT_OK:
            captureDetail = "Звук других программ слышен."
        case AppRules.LIGHT_WARN:
            captureDetail = "Слышна только тишина. Включите звук в любой программе (видео, музыку) и нажмите «Проверить» ещё раз. "
                + "Если звук играет, а здесь тишина, — разрешите Ponte запись системного звука в Системных настройках."
        default:
            captureDetail = "Звук не приходит" + (status.detail.map { ": \($0)" } ?? ".")
        }
    }

    func prepareModel(_ lang: Lang) async {
        models[lang] = .busy
        modelErrors[lang] = nil
        do {
            try await AppleTranscriber(language: lang).prepare()
            models[lang] = .ok
        } catch {
            models[lang] = .bad
            modelErrors[lang] = error.localizedDescription
        }
    }

    func refreshPacks() async {
        let availability = LanguageAvailability()
        for direction in Direction.allCases where AppRules.packRefreshable(light: (packs[direction] ?? .unknown).light) {
            let status = await availability.status(from: direction.source.language, to: direction.target.language)
            packs[direction] = Check(light: AppRules.packLight(status: AppleTranslator.availabilityCode(status)))
        }
    }

    /// Triggers the system download sheet through `.translationTask`.
    func downloadPack(_ direction: Direction) {
        packs[direction] = .busy
        packErrors[direction] = nil
        packDirection = direction
        let config = TranslationSession.Configuration(source: direction.source.language,
                                                      target: direction.target.language)
        if packConfig == config {
            packConfig?.invalidate()
        } else {
            packConfig = config
        }
    }

    func runPackSession(_ session: TranslationSession) async {
        guard let direction = packDirection else { return }
        do {
            try await session.prepareTranslation()
            packs[direction] = .ok
        } catch {
            packs[direction] = .bad
            packErrors[direction] = error.localizedDescription
        }
        await refreshPacks()
    }
}

struct SetupWizardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var state = SetupState()

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Label(model.wizardStep.title, systemImage: model.wizardStep.systemImage)
                            .font(.title.weight(.semibold))
                        content(for: model.wizardStep)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
                }
                Divider()
                footer
            }
        }
        .frame(width: 840, height: 620)
        .translationTask(state.packConfig) { session in
            await state.runPackSession(session)
        }
        .task {
            model.refreshCatalogs()
            await state.refreshPacks()
        }
    }

    // MARK: Layout

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ponte").font(.headline)
                    Text("Первый запуск").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 16)
            ForEach(WizardStep.allCases) { step in
                Button {
                    model.wizardStep = step
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: step.systemImage)
                            .frame(width: 20)
                        Text(step.title)
                        Spacer()
                        stepMark(step)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(model.wizardStep == step ? Color.accentColor.opacity(0.15) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(18)
        .frame(width: 230)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder private func stepMark(_ step: WizardStep) -> some View {
        let mark = AppRules.wizardStepMark(
            step: step.code,
            micGranted: state.mic.isGranted,
            speechGranted: state.speech.isGranted,
            modelsReady: Int32(state.models.values.filter { $0 == .ok }.count),
            packsReady: Int32(state.packs.values.filter { $0 == .ok }.count),
            blackHoleFound: model.blackHoleDevice != nil,
            testPhraseOK: state.testCall == .ok)
        switch mark {
        case AppRules.MARK_DONE: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case AppRules.MARK_WARN: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        default: EmptyView()
        }
    }

    private var footer: some View {
        HStack {
            Button("Закрыть") { close(finished: false) }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if let previous = WizardStep(code: AppRules.wizardPrevious(step: model.wizardStep.code)) {
                Button("Назад") { model.wizardStep = previous }
            }
            if let next = WizardStep(code: AppRules.wizardNext(step: model.wizardStep.code)) {
                Button("Далее") { model.wizardStep = next }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Начать работу") { close(finished: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func close(finished: Bool) {
        model.setupCompleted = AppRules.wizardCompletedAfterClose(wasCompleted: model.setupCompleted, finished: finished)
        dismiss()
    }

    // MARK: Steps

    @ViewBuilder private func content(for step: WizardStep) -> some View {
        switch step {
        case .permissions: permissions
        case .models: models
        case .packs: packs
        case .blackHole: blackHole
        case .callApps: callApps
        case .done: done
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("macOS спросит каждое разрешение один раз. Если окно не появилось — откройте Системные настройки.")
                .foregroundStyle(.secondary)
            StepRow(icon: "mic", title: "Микрофон", detail: "Слушать вашу русскую речь.",
                    check: check(state.mic)) {
                switch AppRules.permissionAction(state: state.mic.code) {
                case AppRules.PA_OPEN_SETTINGS:
                    Button("Открыть настройки") { Permissions.openPrivacySettings("Privacy_Microphone") }
                case AppRules.PA_REQUEST:
                    Button("Разрешить") { Task { state.mic = await Permissions.requestMicrophone() } }
                default:
                    EmptyView()
                }
            }
            StepRow(icon: "speaker.wave.2", title: "Запись звука программ",
                    detail: state.captureDetail ?? "Слышать собеседников из Zoom, браузера, Telegram и других программ.",
                    check: state.capture) {
                Button("Проверить") { Task { await state.checkCapture() } }
                    .disabled(state.capture == .busy)
                if AppRules.captureNeedsSettings(light: state.capture.light) {
                    Button("Открыть настройки") { Permissions.openPrivacySettings("Privacy_ScreenCapture") }
                }
            }
            StepRow(icon: "waveform", title: "Распознавание речи", detail: "Превращать речь в текст на этом Маке.",
                    check: check(state.speech)) {
                switch AppRules.permissionAction(state: state.speech.code) {
                case AppRules.PA_OPEN_SETTINGS:
                    Button("Открыть настройки") { Permissions.openPrivacySettings("Privacy_SpeechRecognition") }
                case AppRules.PA_REQUEST:
                    Button("Разрешить") { Task { state.speech = await Permissions.requestSpeech() } }
                default:
                    EmptyView()
                }
            }
            StepRow(icon: "keyboard", title: "Универсальный доступ (необязательно)",
                    detail: "Чтобы клавиша push-to-talk работала, когда активно окно звонка.",
                    check: Check(light: AppRules.accessibilityLight(granted: model.accessibilityGranted))) {
                if !model.accessibilityGranted {
                    Button("Разрешить…") { model.requestAccessibility() }
                }
            }
        }
        .onAppear { state.refreshPermissions() }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Распознавание работает на устройстве. Модели скачиваются один раз; если они уже есть, проверка займёт секунду.")
                .foregroundStyle(.secondary)
            StepRow(icon: "text.bubble", title: "Português (Brasil)", detail: state.modelErrors[.ptBR] ?? "Речь собеседников.",
                    check: state.models[.ptBR] ?? .unknown) {
                Button("Скачать") { Task { await state.prepareModel(.ptBR) } }
                    .disabled(state.models[.ptBR] == .busy)
            }
            StepRow(icon: "text.bubble", title: "Русский", detail: state.modelErrors[.ru] ?? "Ваша речь.",
                    check: state.models[.ru] ?? .unknown) {
                Button("Скачать") { Task { await state.prepareModel(.ru) } }
                    .disabled(state.models[.ru] == .busy)
            }
            Button {
                Task {
                    async let pt: Void = state.prepareModel(.ptBR)
                    async let ru: Void = state.prepareModel(.ru)
                    _ = await (pt, ru)
                }
            } label: {
                Label("Скачать обе модели", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var packs: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Перевод Apple работает без интернета. macOS покажет окно скачивания языков — подтвердите его.")
                .foregroundStyle(.secondary)
            ForEach(Direction.allCases, id: \.self) { direction in
                StepRow(icon: "character.bubble",
                        title: direction == .incoming ? "Португальский → русский" : "Русский → португальский",
                        detail: state.packErrors[direction] ?? (state.packs[direction] == .ok ? "Установлен." : "Нужно скачать."),
                        check: state.packs[direction] ?? .unknown) {
                    Button("Скачать") { state.downloadPack(direction) }
                        .disabled(!AppRules.packDownloadEnabled(light: (state.packs[direction] ?? .unknown).light))
                }
            }
            Button("Проверить снова") { Task { await state.refreshPacks() } }
        }
    }

    private var blackHole: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("BlackHole — бесплатный виртуальный микрофон. Ponte говорит в него по-португальски, а звонилка берёт его как микрофон.")
                .fixedSize(horizontal: false, vertical: true)
            if let device = model.blackHoleDevice {
                Label("Найден: \(device.name)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            } else {
                Label("Не установлен", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.headline)
                Text("Откройте Терминал, вставьте команду и введите пароль администратора:")
                CommandBox(command: "brew install --cask blackhole-2ch")
                Text("Нужен Homebrew (brew.sh). Если после установки BlackHole не появился через минуту, перезагрузите Мак.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Проверить снова") { model.refreshCatalogs() }
        }
    }

    private var callApps: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("В каждой звонилке один раз выберите **Микрофон — BlackHole 2ch**, **Динамик — ваши наушники**. Тогда собеседники слышат перевод, а вы — их.")
                .fixedSize(horizontal: false, vertical: true)
            if model.speakerWarning {
                Label("Сейчас звук идёт в динамики Мака (\(model.listeningDevice?.name ?? "")). Микрофон услышит собеседников — наденьте наушники.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                AppInstruction(name: "Google Meet в BrowserOS", bundleID: "com.browseros.BrowserClaw",
                               text: "В звонке Meet: ⋮ → Настройки → Аудио: Микрофон — «BlackHole 2ch», Динамики — ваши наушники. "
                                   + "В Ponte выберите источник «BrowserOS (Meet)». BrowserOS нужен доступ к микрофону в macOS "
                                   + "(Системные настройки → Конфиденциальность и безопасность → Микрофон), иначе Meet не увидит BlackHole. "
                                   + "Meet в Chrome или другом браузере на Chromium настраивается так же.")
                AppInstruction(name: "Zoom", bundleID: "us.zoom.xos",
                               text: "Настройки → Звук: Динамик — наушники, Микрофон — BlackHole 2ch. Снимите «Автоматически регулировать громкость микрофона».")
                AppInstruction(name: "Google Meet", bundleID: "com.google.Chrome",
                               text: "В звонке: ⋮ → Настройки → Аудио: Микрофон — BlackHole 2ch, Динамики — наушники. В Ponte выберите источник Chrome или Safari.")
                AppInstruction(name: "Telegram", bundleID: "ru.keepcoder.Telegram",
                               text: "Настройки → «Динамики и камера» (или шестерёнка в окне звонка): Микрофон — BlackHole 2ch, Динамики — наушники.")
                AppInstruction(name: "WhatsApp", bundleID: "net.whatsapp.WhatsApp",
                               text: "Настройки → Звонки (или меню устройств в окне звонка): Микрофон — BlackHole 2ch, Динамик — наушники.")
                AppInstruction(name: "FaceTime, Teams", bundleID: "com.apple.FaceTime",
                               text: "FaceTime: меню «Видео» → Микрофон — BlackHole 2ch. Teams: Настройки → Устройства.")
            }
            Divider()
            Text("Проверка: скажите тестовую фразу в BlackHole. Попросите собеседника или сделайте тестовый звонок в Zoom (Настройки → Звук → «Проверить микрофон»).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.blackHoleDevice == nil {
                Label("Сначала установите BlackHole (предыдущий шаг).", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Button {
                    Task {
                        state.testCall = .busy
                        do {
                            try await model.playTestPhrase(intoCall: true)
                            state.testCall = .ok
                        } catch {
                            state.testCall = .bad
                        }
                    }
                } label: {
                    Label("Тестовая фраза в BlackHole", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.enabled(AppRules.BTN_TEST_CALL, busy: state.testCall == .busy))
                Button {
                    Task {
                        state.testHeadphones = .busy
                        do {
                            try await model.playTestPhrase(intoCall: false)
                            state.testHeadphones = .ok
                        } catch {
                            state.testHeadphones = .bad
                        }
                    }
                } label: {
                    Label("Прослушать в наушниках", systemImage: "headphones")
                }
                .disabled(!model.enabled(AppRules.BTN_TEST_HEADPHONES, busy: state.testHeadphones == .busy))
                if state.testCall == .busy || state.testHeadphones == .busy {
                    ProgressView().controlSize(.small)
                }
            }
            Text("«\(AppModel.testPhrase)»")
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Как пользоваться:")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Label("Сверху выберите программу звонка (или «Весь звук Мака») и нажмите «Старт».", systemImage: "1.circle")
                Label("Слева — перевод собеседников. Справа — ваш перевод, который слышат они.", systemImage: "2.circle")
                Label("«Пауза голоса в звонок» — сказать что-то без перевода. «Сказать заново» — повторить фразу.", systemImage: "3.circle")
                Label("Кнопка субтитров на панели показывает перевод поверх окна звонка.", systemImage: "4.circle")
                Label("После «Стоп» стенограмма сохраняется в ~/Documents/Ponte.", systemImage: "5.circle")
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("Мастер всегда можно открыть снова кнопкой с волшебной палочкой.")
                .foregroundStyle(.secondary)
        }
    }

    private func check(_ permission: PermissionState) -> Check {
        Check(light: AppRules.permissionLight(state: permission.code))
    }
}

/// Counts what the capture check heard (called on the tap's delivery queue).
private final class CaptureMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var signal = false

    func add(_ buffer: AVAudioPCMBuffer) {
        let (rms, peak) = buffer.laneLevels
        let heard = AudioRules.hasSignal(peak: peak, rms: rms)
        lock.withLock {
            frames += Int(buffer.frameLength)
            signal = signal || heard
        }
    }

    var result: (frames: Int, signal: Bool) { lock.withLock { (frames, signal) } }
}

private struct StepRow<Actions: View>: View {
    let icon: String
    let title: String
    let detail: String
    let check: Check
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            actions
            Group {
                switch check {
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .bad: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .busy: ProgressView().controlSize(.small)
                case .warn: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .unknown: Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .font(.title3)
            .frame(width: 24)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

private struct AppInstruction: View {
    let name: String
    let bundleID: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if let icon = AppIcons.icon(for: bundleID) {
                    Image(nsImage: icon)
                } else {
                    Image(systemName: "phone.circle")
                }
            }
            .frame(width: 18)
            Text("**\(name).** \(text)")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
