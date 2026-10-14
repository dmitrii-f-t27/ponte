import AppKit
import PonteCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ControlBar()
            if let banner = model.banner {
                BannerView(banner: banner, perform: { model.perform($0) }, dismiss: { model.banner = nil })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Divider()
            HStack(spacing: 0) {
                IncomingColumn()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                OutgoingColumn()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 880, minHeight: 560)
        .background(Color(nsColor: .textBackgroundColor))
        .animation(.easeOut(duration: 0.2), value: model.banner)
        .toolbar { MainToolbar() }
        .navigationTitle("Ponte")
        .navigationSubtitle(model.ownVoice ? OwnVoiceBar.notice
                            : model.isRunning ? "Идёт перевод · \(model.activeSourceName ?? "")" : "PT-BR ⇄ RU")
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .wizard:
                SetupWizardView()
                    .environment(model)
            case .checklist:
                ChecklistView()
                    .environment(model)
            }
        }
        .task { model.appDidLaunchOnce() }
    }
}

private struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.overlayVisible.toggle()
            } label: {
                Label("Субтитры поверх окон",
                      systemImage: model.overlayVisible ? "captions.bubble.fill" : "captions.bubble")
            }
            .accessibilityHint(model.overlayVisible ? "Скрыть плавающие субтитры" : "Показать плавающие субтитры поверх звонка")

            Button {
                model.saveTranscript()
            } label: {
                Label("Сохранить стенограмму", systemImage: "square.and.arrow.down")
            }
            .accessibilityHint("Сохранить стенограмму в ~/Documents/Ponte")
            .disabled(!model.enabled(AppRules.BTN_SAVE_TRANSCRIPT))

            Button {
                model.openChecklist()
            } label: {
                Label("Перед звонком", systemImage: "checklist")
            }
            .accessibilityHint("Перед звонком: BlackHole в Meet, наушники, микрофон")

            Button {
                model.openWizard(.permissions)
            } label: {
                Label("Мастер настройки", systemImage: "wand.and.stars")
            }
            .accessibilityHint("Мастер настройки: разрешения, модели, BlackHole")

            SettingsLink {
                Label("Настройки", systemImage: "gearshape")
            }
            .accessibilityHint("Настройки")
        }
    }
}

// MARK: - Top bar: source, status, start/stop

private struct ControlBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Слушать")
                    .foregroundStyle(.secondary)
                SourcePicker()
                    .frame(width: 280)
                    .disabled(!model.enabled(AppRules.BTN_SOURCE))
                    .accessibilityHint(model.enabled(AppRules.BTN_SOURCE) ? "Программа, в которой идёт звонок" : "Источник меняется после «Стоп»")
                Spacer()
                StartStopButton()
            }
            StatusRow()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct SourcePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let calls = apps(in: AppRules.SRC_CALLS)
        let playing = apps(in: AppRules.SRC_PLAYING)
        let others = apps(in: AppRules.SRC_OTHER)
        let known = Set(model.audioApps.map(\.bundleID))
        Picker("Источник звука", selection: $model.sourceKey) {
            if case .app(let id) = model.source, !known.contains(id) {
                Label("\(model.sourceTitle) (не запущен)", systemImage: "app.dashed")
                    .tag(model.sourceKey)
            }
            if !calls.isEmpty {
                Section("Звонилки") { ForEach(calls) { row($0) } }
            }
            if !playing.isEmpty {
                Section("Сейчас звучат") { ForEach(playing) { row($0) } }
            }
            if !others.isEmpty {
                Section("Другие программы") { ForEach(others) { row($0) } }
            }
            Divider()
            Label("Весь звук Мака", systemImage: "macbook").tag("system")
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    /// Menu section of each running app (AppRules.sourceSection).
    private func apps(in section: Int32) -> [AudioApp] {
        model.audioApps.filter {
            AppRules.sourceSection(isKnownCallApp: $0.isKnownCallApp, isPlayingAudio: $0.isPlayingAudio) == section
        }
    }

    @ViewBuilder private func row(_ app: AudioApp) -> some View {
        let tag = SourceChoice.app(bundleID: app.bundleID).key
        if let icon = AppIcons.icon(for: app.bundleID) {
            Label { Text(app.name) } icon: { Image(nsImage: icon) }.tag(tag)
        } else {
            Label(app.name, systemImage: "app").tag(tag)
        }
    }
}

private struct StartStopButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.runState {
        case .idle:
            Button { model.toggleRun() } label: {
                Label("Старт", systemImage: "play.fill").frame(minWidth: 84)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(model.commandReturnShortcut(TextRules.CMDRET_RUN))
        case .running:
            Button { model.toggleRun() } label: {
                Label("Стоп", systemImage: "stop.fill").frame(minWidth: 84)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut(model.commandReturnShortcut(TextRules.CMDRET_RUN))
        case .starting, .stopping:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.runState == .starting ? "Запуск…" : "Остановка…")
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 110, minHeight: 28)
        }
    }
}

private struct StatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            StatusChip(title: "Звук источника", systemImage: "speaker.wave.2", check: model.sourceCheck,
                       level: model.sourceLevel, help: model.sourceHelp)
            StatusChip(title: "Микрофон", systemImage: "mic", check: model.micCheck,
                       level: model.micLevel, help: model.micDevice?.name ?? "Системный микрофон")
            StatusChip(title: "BlackHole", systemImage: "cable.connector",
                       check: model.blackHoleCheck,
                       help: model.blackHoleDevice == nil ? "BlackHole не установлен: голос не попадёт в звонок"
                                                          : "Голос в звонок идёт через \(model.blackHoleDevice?.name ?? "")")
            StatusChip(title: "Модели", systemImage: "cpu", check: model.modelsCheck,
                       help: "Распознавание и перевод на устройстве")
            StatusChip(title: "Задержка", systemImage: "timer", check: .unknown,
                       value: model.lastLatency.map(secondsText) ?? "—",
                       valueTint: latencyTint(model.latencyColorCode),
                       help: "От конца фразы до перевода на экране (цель — до 2 с)")
            Spacer(minLength: 0)
            if model.speakerWarning {
                Label("Динамики Мака — нужны наушники", systemImage: "headphones")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityHint("Микрофон услышит собеседников из динамиков. Наденьте наушники.")
            }
        }
    }
}

// MARK: - Columns

private struct ColumnHeader<Controls: View>: View {
    let title: String
    let route: String
    let systemImage: String
    let tint: Color
    @ViewBuilder var controls: Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(route)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) { controls }
                .controlSize(.regular)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

private struct IncomingColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ColumnHeader(title: "Они → по-русски", route: "pt-BR → ru", systemImage: "person.2.wave.2.fill", tint: .blue) {
                Toggle(isOn: $model.speakRussian) {
                    Label("Голос в наушники", systemImage: "headphones")
                }
                .toggleStyle(.button)
                .accessibilityHint("Озвучивать русский перевод в наушники")
                Button {
                    model.replayLast(.incoming)
                } label: {
                    Label("Повторить", systemImage: "arrow.counterclockwise")
                }
                .disabled(!model.enabled(AppRules.BTN_REPLAY_INCOMING))
                .accessibilityHint("Повторить последнюю фразу в наушники")
                Spacer()
                if model.incomingSpeaking {
                    SpeakingBadge(text: "в наушниках", tint: .blue)
                }
            }
            Divider().padding(.horizontal, 22)
            TranscriptList(lines: model.incomingLines, partial: model.incomingPartial, fontSize: model.fontSize,
                           emptyIcon: "text.bubble",
                           emptyTitle: "Здесь будет перевод собеседников",
                           emptyText: model.isRunning
                               ? "Ponte слушает «\(model.activeSourceName ?? "")». Русский текст появится после первой фразы."
                               : "Выберите программу звонка сверху и нажмите «Старт».")
        }
    }
}

private struct OutgoingColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ColumnHeader(title: "Я → по-португальски", route: "ru → pt-BR", systemImage: "person.wave.2.fill", tint: .green) {
                Button {
                    model.replayLast(.outgoing)
                } label: {
                    Label("Сказать заново", systemImage: "arrow.counterclockwise")
                }
                .disabled(!model.enabled(AppRules.BTN_REPLAY_OUTGOING))
                .accessibilityHint("Повторить последнюю фразу в звонок")
                Spacer(minLength: 0)
            }
            Divider().padding(.horizontal, 22)
            TranscriptList(lines: model.outgoingLines, partial: model.outgoingPartial, fontSize: model.fontSize,
                           emptyIcon: "mic",
                           emptyTitle: "Здесь будет ваш перевод",
                           emptyText: model.outgoingMode == .pushToTalk
                               ? "Держите \(model.pttKey.short) и говорите по-русски — собеседники услышат португальский."
                               : "Говорите по-русски — собеседники услышат португальский.",
                           marker: { model.lineMarker($0) })
            OutgoingFooter()
        }
    }
}

private struct OutgoingFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Group {
                    switch AppRules.outgoingStatus(paused: model.voicePaused, speaking: model.outgoingSpeaking,
                                                   running: model.isRunning, hasBlackHole: model.blackHoleDevice != nil) {
                    case AppRules.OUTSTATUS_PAUSED:
                        Label("На паузе: микрофон не слушается", systemImage: "pause.circle.fill")
                            .foregroundStyle(.orange)
                    case AppRules.OUTSTATUS_SPEAKING:
                        SpeakingBadge(text: "Говорит в звонок", tint: .green)
                    case AppRules.OUTSTATUS_NO_BLACKHOLE:
                        Label("Нет BlackHole: голос не идёт в звонок", systemImage: "speaker.slash")
                            .foregroundStyle(.secondary)
                    default:
                        EmptyView()
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Toggle(isOn: Binding(get: { model.ownVoice }, set: { _ in model.toggleOwnVoice() })) {
                    Label("Свой голос", systemImage: "person.wave.2")
                }
                .toggleStyle(.button)
                .controlSize(.large)
                .tint(OwnVoiceBar.amber)
                .fixedSize()
                .disabled(!model.ownVoiceAvailable)
                .accessibilityHint("Выключить перевод и говорить в звонок своим голосом (⇧⌘V)")
                Toggle(isOn: $model.voicePaused) {
                    Label("Пауза голоса в звонок", systemImage: model.voicePaused ? "pause.circle.fill" : "pause.circle")
                }
                .toggleStyle(.button)
                .controlSize(.large)
                .tint(.orange)
                .fixedSize()
                .accessibilityHint("Не слушать микрофон и не говорить в звонок (⇧⌘P)")
            }
            TextComposer()
            if model.ownVoice {
                OwnVoiceBar()
            } else if model.outgoingMode == .pushToTalk {
                PushToTalkPad()
            }
        }
        .font(.callout)
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// «Сказать»: Russian text typed or pasted here is translated and said into the call like a spoken phrase,
/// without the talk key (TextRules, TranslationLane.speakText). ↩ types a new line, ⌘↩ says the text.
private struct TextComposer: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let check = model.textCheck(draft)
        let note = TextRules.fieldNote(check: check, bytes: TextRules.trimmedUTF8(draft).count, paused: model.voicePaused)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(height: 54)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Вставьте или напишите текст по-русски — Ponte переведёт и скажет его в звонок")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(focused ? Color.green.opacity(0.7) : Color.primary.opacity(0.15)))
                    .accessibilityLabel("Текст для звонка")
                Button(action: send) {
                    Label("Сказать", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .disabled(!TextRules.sayEnabled(check: check))
                .keyboardShortcut(model.commandReturnShortcut(TextRules.CMDRET_SAY))
                .help("⌘↩ — сказать, ↩ — новая строка")
                .accessibilityHint("Перевести текст и сказать его в звонок (⌘↩)")
            }
            if let text = noteText(note) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(note == TextRules.NOTE_TOO_LONG ? Color.orange : Color.secondary)
            }
        }
        .onChange(of: focused) { model.textFieldFocused = focused }
    }

    private func send() {
        if model.sayText(draft) == TextRules.SUBMIT_OK { draft = "" }
        focused = true
    }

    private func noteText(_ note: Int32) -> String? {
        switch note {
        case TextRules.NOTE_TOO_LONG:
            "Слишком длинный текст (\(draft.count) знаков): за раз — до \(TextRules.MAX_BYTES / 2) русских букв. Отправьте его частями."
        case TextRules.NOTE_NEEDS_START: "Нажмите «Старт» — тогда Ponte скажет этот текст в звонок."
        case TextRules.NOTE_NO_LANE: "Канал «Я → по-португальски» не запустился — сказать текст нельзя."
        case TextRules.NOTE_PAUSED: "Пауза голоса: перевод появится здесь, но в звонок не прозвучит."
        default: nil
        }
    }
}

extension AppModel {
    /// ⌘↩ belongs to «Старт»/«Стоп» or to «Сказать» (TextRules.commandReturn): the shortcut for `target`, or nil.
    func commandReturnShortcut(_ target: Int32) -> KeyboardShortcut? {
        TextRules.commandReturn(fieldFocused: textFieldFocused, running: isRunning) == target
            ? KeyboardShortcut(.return, modifiers: .command) : nil
    }
}

private struct PushToTalkPad: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let held = model.talkKeyHeld
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: held ? "mic.fill" : "mic")
                    .font(.title2)
                    .foregroundStyle(held ? .white : .green)
                    .symbolEffect(.pulse, isActive: held)
                VStack(alignment: .leading, spacing: 2) {
                    Text(held ? "Говорите — идёт запись" : "Держите \(model.pttKey.short) или нажмите и держите здесь")
                        .fontWeight(.medium)
                    Text("Отпустите — фраза уйдёт в звонок")
                        .font(.caption)
                        .foregroundStyle(held ? .white.opacity(0.8) : .secondary)
                }
                .foregroundStyle(held ? .white : .primary)
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(held ? Color.green : Color.green.opacity(0.1)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if model.enabled(AppRules.BTN_TALK_PAD) { model.setTalkKey(true) } }
                .onEnded { _ in model.setTalkKey(false) })
            .opacity(model.enabled(AppRules.BTN_TALK_PAD) ? 1 : 0.55)

            if !model.accessibilityGranted {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("Клавиша работает, только когда окно Ponte активно.")
                    Button("Разрешить везде…") { model.requestAccessibility() }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SpeakingBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, options: .repeating)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(tint)
    }
}

/// «Свой голос» is on: the microphone goes into the call as it is. Amber, in place of the push-to-talk bar.
private struct OwnVoiceBar: View {
    static let notice = "Сейчас вас слышно своим голосом — перевод выключен"
    static let amber = Color(red: 1.0, green: 0.69, blue: 0.0)
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.wave.2.fill")
                .font(.title2)
                .symbolEffect(.pulse, isActive: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.notice)
                    .fontWeight(.semibold)
                Text("Нажмите «Свой голос» ещё раз (⇧⌘V), чтобы вернуть перевод")
                    .font(.caption)
            }
            Spacer()
            Button("Вернуть перевод") { model.toggleOwnVoice() }
                .controlSize(.large)
        }
        .foregroundStyle(.black)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Self.amber))
        .accessibilityElement(children: .combine)
    }
}
