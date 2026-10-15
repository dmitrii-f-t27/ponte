import PonteSpeech
import SwiftUI

/// Settings → «Анализ звонка»: the service (Z.ai, DeepSeek or an own OpenAI-compatible one), its base URL and
/// model (prefilled from Specs/analysis_rules.t27), the API key in the Keychain (bound to the base URL it was saved
/// for), «Проверить», and the toggle «Анализировать звонок». The base URL and the model are drafts while typed:
/// they apply on Enter, on leaving the field or with «Применить», and only when the rules accept them, so a call in
/// progress never sends anything to a half-typed address. SettingsView adds it as a tab.
struct AnalysisSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draftKey = ""
    @State private var draftBaseURL = ""
    @State private var draftModel = ""
    /// The service the drafts were taken from; a draft of another service is never applied.
    @State private var draftProvider: Int?
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case baseURL
        case model
    }

    var body: some View {
        @Bindable var analysis = model.analysis
        Form {
            Section {
                Picker("Сервис", selection: $analysis.provider) {
                    ForEach(AnalysisRules.allProviders, id: \.self) { provider in
                        Text(CallAnalysisModel.providerName(provider)).tag(provider)
                    }
                }
                TextField("Базовый URL", text: $draftBaseURL, prompt: Text("https://…/v1"))
                    .autocorrectionDisabled()
                    .focused($focus, equals: .baseURL)
                    .onSubmit(applyBaseURL)
                if let problem = draftURLProblem {
                    hint(problem)
                }
                TextField("Модель", text: $draftModel, prompt: Text("название модели"))
                    .autocorrectionDisabled()
                    .focused($focus, equals: .model)
                    .onSubmit(applyModel)
                if let problem = draftModelProblem {
                    hint(problem)
                }
                if draftsChanged(analysis) {
                    HStack {
                        Text("Изменения ещё не применены: нажмите Enter, перейдите в другое поле или «Применить».")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Применить", action: applyDrafts)
                            .disabled(draftURLProblem != nil || draftModelProblem != nil)
                            .accessibilityHint("Применить базовый URL и модель")
                    }
                }
                HStack {
                    if let endpoint = analysis.endpointText {
                        Text("Запросы: \(endpoint)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if !analysis.isDefault, analysis.provider != AnalysisRules.providerCustom {
                        Button("Вернуть по умолчанию") {
                            analysis.resetToDefaults()
                            syncDrafts()
                        }
                        .accessibilityHint("Базовый URL и модель этого сервиса по умолчанию")
                    }
                }
            } header: {
                Text("Анализ звонка (ИИ)")
            } footer: {
                Text("Агент ведёт заметки во время звонка и после «Стоп» составляет отчёт: кратко, участники, "
                     + "важные данные (имена, суммы, даты, телефоны, e-mail, ссылки), договорённости, задачи, "
                     + "открытые вопросы, риски, следующие шаги. Подойдёт любой сервис с OpenAI-совместимым API: "
                     + "адрес https://, а http:// — только для сервера на этом Маке (\(AnalysisTexts.thisMac)).")
                    .foregroundStyle(.secondary)
            }

            Section("API-ключ") {
                if analysis.hasKey {
                    Label(keyText(analysis), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    if analysis.configCheck == AnalysisRules.configKeyElsewhere, let problem = analysis.configProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Label("Ключа \(analysis.providerName) нет", systemImage: "key")
                        .foregroundStyle(.secondary)
                }
                // A visible box with its label above it: in a Form row the field was only a grey prompt at the right edge,
                // and the owner could not find where to paste the key (2026-10-14).
                VStack(alignment: .leading, spacing: 4) {
                    Text(analysis.hasKey ? "Новый API-ключ (заменит сохранённый)" : "Вставьте API-ключ сюда (⌘V)")
                        .font(.callout.weight(.medium))
                    SecureField("API-ключ", text: $draftKey, prompt: Text("например, 1a2b3c…"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit(save)
                        .accessibilityLabel("API-ключ")
                }
                HStack {
                    Button("Сохранить ключ", action: save)
                        .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityHint("Записать ключ в связку ключей macOS для этого базового URL")
                    Button("Удалить ключ", role: .destructive) { analysis.deleteKey() }
                        .disabled(!analysis.hasKey)
                        .accessibilityHint("Удалить ключ этого сервиса из связки ключей")
                    Spacer()
                    if analysis.probeResult == .running {
                        ProgressView().controlSize(.small)
                    }
                    Button("Проверить") { analysis.probe() }
                        .disabled(!analysis.configured || analysis.probeResult == .running)
                        .accessibilityHint("Отправить короткий запрос и проверить ключ, адрес и модель")
                }
                if let message = analysis.keyMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch analysis.probeResult {
                case .ok(let text):
                    Label(text, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let text):
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                default:
                    EmptyView()
                }
            }

            Section {
                Toggle("Анализировать звонок", isOn: $analysis.enabled)
                    .disabled(!analysis.hasKey)
            } footer: {
                Text("Во время звонка и после него текст стенограммы (оригинал и перевод) отправляется в выбранный сервис — "
                     + "\(analysis.providerName). Звук никуда не уходит. Ключ хранится только в связке ключей macOS и "
                     + "отправляется только на адрес, для которого его сохранили. Выключение останавливает и запросы, "
                     + "которые уже идут. Отчёт можно открыть кнопкой «Отчёт по звонку» и сохранить в TXT.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.analysis.loadKeyIfNeeded()
            syncDrafts()
        }
        .onChange(of: analysis.provider) { syncDrafts() }
        .onChange(of: focus) { old, _ in
            if old == .baseURL { applyBaseURL() }
            if old == .model { applyModel() }
        }
        .onDisappear(perform: applyDrafts)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func keyText(_ analysis: CallAnalysisModel) -> String {
        if let address = analysis.keyBaseURL {
            return "Ключ \(analysis.providerName) сохранён в связке ключей macOS для адреса \(address)"
        }
        return "Ключ \(analysis.providerName) сохранён в связке ключей macOS (прежней версией Ponte, без адреса)"
    }

    /// The drafts from the applied settings of the current service.
    private func syncDrafts() {
        let analysis = model.analysis
        draftBaseURL = analysis.baseURL
        draftModel = analysis.model
        draftProvider = analysis.provider
    }

    private var draftURLProblem: String? {
        AnalysisTexts.urlProblem(AnalysisRules.baseURLCheck(utf8: Array(trimmed(draftBaseURL).utf8)))
    }

    private var draftModelProblem: String? {
        AnalysisTexts.modelProblem(AnalysisRules.modelCheck(utf8: Array(trimmed(draftModel).utf8)))
    }

    private func draftsChanged(_ analysis: CallAnalysisModel) -> Bool {
        draftProvider == analysis.provider && (trimmed(draftBaseURL) != analysis.baseURL || trimmed(draftModel) != analysis.model)
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Applies the typed base URL when the rules accept it (CallAnalysisModel.applyBaseURL); else it stays a draft
    /// with its problem shown under the field.
    private func applyBaseURL() {
        guard draftProvider == model.analysis.provider else { return }
        model.analysis.applyBaseURL(draftBaseURL)
    }

    private func applyModel() {
        guard draftProvider == model.analysis.provider else { return }
        model.analysis.applyModel(draftModel)
    }

    private func applyDrafts() {
        applyBaseURL()
        applyModel()
    }

    /// The key is saved for the applied base URL: a typed one is applied first.
    private func save() {
        applyDrafts()
        if model.analysis.saveKey(draftKey) { draftKey = "" }
    }
}
