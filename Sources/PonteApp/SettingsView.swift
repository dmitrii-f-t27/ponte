import PonteAudio
import PonteCore
import PonteSpeech
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            DevicesSettings()
                .tabItem { Label("Устройства", systemImage: "hifispeaker.2") }
            VoiceSettings()
                .tabItem { Label("Голос и текст", systemImage: "waveform") }
            TranslationSettings()
                .tabItem { Label("Перевод", systemImage: "character.bubble") }
            GlossarySettings()
                .tabItem { Label("Глоссарий", systemImage: "text.book.closed") }
        }
        .frame(width: 600, height: 470)
    }
}

/// Picker over devices by UID; keeps a stored UID visible even when the device is unplugged.
private struct DevicePicker: View {
    let title: String
    @Binding var uid: String
    let automatic: String
    let devices: [AudioDevice]

    var body: some View {
        Picker(title, selection: $uid) {
            Text(automatic).tag("")
            if !uid.isEmpty, !devices.contains(where: { $0.uid == uid }) {
                Text("Не подключено (\(uid))").tag(uid)
            }
            ForEach(devices) { Text($0.name).tag($0.uid) }
        }
    }
}

private struct DevicesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                DevicePicker(title: "Мой микрофон", uid: $model.micUID,
                             automatic: "Системный по умолчанию", devices: model.inputDevices)
                DevicePicker(title: "Мои наушники", uid: $model.headphonesUID,
                             automatic: "Системный выход (\(model.defaultOutput?.name ?? "—"))",
                             devices: model.outputDevices.filter { !AudioRules.isBlackHole(name: $0.name) })
                DevicePicker(title: "Вывод в звонок", uid: $model.callOutputUID,
                             automatic: AppRules.callOutputLabel(hasBlackHole: model.blackHoleDevice != nil,
                                                                 hasSetting: !model.callOutputUID.isEmpty) == AppRules.COL_FOUND
                                 ? "BlackHole (найден: \(model.blackHoleDevice?.name ?? ""))"
                                 : "BlackHole (найти автоматически)",
                             devices: model.outputDevices)
            } header: {
                Text("Устройства")
            } footer: {
                Text("В звонилке выберите «BlackHole 2ch» как микрофон, а наушники — как динамик. Изменения применяются при следующем «Старт».")
                    .foregroundStyle(.secondary)
            }

            if model.speakerWarning {
                Section {
                    Label("Звук идёт в динамики Мака. Микрофон услышит собеседников и начнёт переводить их речь. Наденьте наушники.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if model.blackHoleDevice == nil {
                Section("BlackHole не установлен") {
                    Text("Виртуальный микрофон для звонилки. Установите его в Терминале (нужен пароль администратора):")
                    CommandBox(command: "brew install --cask blackhole-2ch")
                    Button("Проверить снова") { model.refreshCatalogs() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshCatalogs() }
    }
}

private struct VoiceSettings: View {
    @Environment(AppModel.self) private var model
    @State private var ptVoices: [SpeechVoice] = []
    @State private var ruVoices: [SpeechVoice] = []

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Голоса") {
                Picker("Голос pt-BR (в звонок)", selection: $model.voicePT) {
                    Text("Автоматически — лучший").tag("")
                    ForEach(ptVoices, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Голос ru (в наушники)", selection: $model.voiceRU) {
                    Text("Автоматически — лучший").tag("")
                    ForEach(ruVoices, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            Section {
                Toggle("Озвучивать русский в наушники", isOn: $model.speakRussian)
            } footer: {
                Text("Выключено по умолчанию: обычно хватает субтитров. Кнопка «Повторить» озвучит фразу и без этого.")
                    .foregroundStyle(.secondary)
            }
            Section("Размер текста перевода") {
                Slider(value: $model.fontSize,
                       in: Double(AppRules.FONT_MIN_PT)...Double(AppRules.FONT_MAX_PT), step: 1) {
                    Text("\(Int(model.fontSize)) pt")
                        .monospacedDigit()
                }
                Text("Доброе утро! Как у вас дела?")
                    .font(.system(size: model.fontSize, weight: .semibold))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            ptVoices = SystemSpeechSynth.voices(for: .ptBR)
            ruVoices = SystemSpeechSynth.voices(for: .ru)
        }
    }
}

private struct TranslationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let claude = model.claudeAvailable
        let note = AppRules.translatorNote(preferred: model.translatorKind.ruleCode, claudeAvailable: claude)
        Form {
            Section {
                Picker("Переводчик", selection: $model.translatorKind) {
                    Text(TranslatorKind.apple.title).tag(TranslatorKind.apple)
                    Text(TranslatorKind.claude.title).tag(TranslatorKind.claude)
                        .disabled(!claude)
                }
                .pickerStyle(.radioGroup)
                if note != AppRules.TN_NONE {
                    HStack {
                        Text("Claude включится, когда в связке ключей появится элемент «ponte-anthropic-key».")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Проверить снова") { model.recheckClaude() }
                    }
                    if note == AppRules.TN_NO_KEY_FALLBACK {
                        Text("Пока ключа нет, используется Apple.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Перевод")
            } footer: {
                Text("Apple работает на устройстве и бесплатно. Claude учитывает контекст разговора, но нужен интернет и ключ.")
                    .foregroundStyle(.secondary)
            }

            Section("Мой голос в звонок") {
                Picker("Режим", selection: $model.outgoingMode) {
                    ForEach(CaptureMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Клавиша push-to-talk", selection: $model.pttKey) {
                    ForEach(PTTKey.allCases) { Text($0.title).tag($0) }
                }
                if model.accessibilityGranted {
                    Label("Клавиша работает поверх любых окон.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    HStack {
                        Label("Сейчас клавиша работает, только когда окно Ponte активно.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Разрешить…") { model.requestAccessibility() }
                    }
                    Text("Нужно включить Ponte в «Конфиденциальность и безопасность → Универсальный доступ».")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct GlossarySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Имена и термины в двух формах. Если переводчик оставил слово как есть, Ponte подставит форму из глоссария.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Português (BR)").frame(maxWidth: .infinity, alignment: .leading)
                Text("Русский").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 24)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            List {
                ForEach($model.glossary) { $term in
                    HStack(spacing: 8) {
                        TextField("Trinity", text: $term.pt)
                            .textFieldStyle(.roundedBorder)
                        TextField("Тринити", text: $term.ru)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            model.glossary.removeAll { $0.id == term.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Удалить")
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay {
                if model.glossary.isEmpty {
                    Text("Глоссарий пуст").foregroundStyle(.tertiary)
                }
            }
            HStack {
                Button {
                    model.glossary.append(GlossaryTerm(pt: "", ru: ""))
                } label: {
                    Label("Добавить", systemImage: "plus")
                }
                Spacer()
                Text("Терминов: \(model.glossary.filter(\.isComplete).count)")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}
