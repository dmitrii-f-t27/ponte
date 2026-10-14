import PonteSpeech
import SwiftUI

/// Settings → «Анализ звонка»: the service (Z.ai, DeepSeek or an own OpenAI-compatible one), its base URL and
/// model (prefilled from Specs/analysis_rules.t27), the API key in the Keychain, «Проверить», and the toggle
/// «Анализировать звонок». SettingsView adds it as a tab.
struct AnalysisSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draftKey = ""

    var body: some View {
        @Bindable var analysis = model.analysis
        Form {
            Section {
                Picker("Сервис", selection: $analysis.provider) {
                    ForEach(AnalysisRules.allProviders, id: \.self) { provider in
                        Text(CallAnalysisModel.providerName(provider)).tag(provider)
                    }
                }
                TextField("Базовый URL", text: $analysis.baseURL, prompt: Text("https://…/v1"))
                    .autocorrectionDisabled()
                if let problem = urlProblem(analysis) {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                TextField("Модель", text: $analysis.model, prompt: Text("название модели"))
                    .autocorrectionDisabled()
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
                        Button("Вернуть по умолчанию") { analysis.resetToDefaults() }
                            .accessibilityHint("Базовый URL и модель этого сервиса по умолчанию")
                    }
                }
            } header: {
                Text("Анализ звонка (ИИ)")
            } footer: {
                Text("Агент ведёт заметки во время звонка и после «Стоп» составляет отчёт: кратко, участники, "
                     + "важные данные (имена, суммы, даты, телефоны, e-mail, ссылки), договорённости, задачи, "
                     + "открытые вопросы, риски, следующие шаги. Подойдёт любой сервис с OpenAI-совместимым API.")
                    .foregroundStyle(.secondary)
            }

            Section("API-ключ") {
                if analysis.hasKey {
                    Label("Ключ \(analysis.providerName) сохранён в связке ключей macOS", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Ключа \(analysis.providerName) нет", systemImage: "key")
                        .foregroundStyle(.secondary)
                }
                SecureField("API-ключ", text: $draftKey, prompt: Text(analysis.hasKey ? "вставьте новый, чтобы заменить" : "вставьте ключ"))
                    .onSubmit(save)
                HStack {
                    Button("Сохранить ключ", action: save)
                        .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityHint("Записать ключ в связку ключей macOS")
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
                     + "\(analysis.providerName). Звук никуда не уходит. Ключ хранится только в связке ключей macOS. "
                     + "Отчёт можно открыть кнопкой «Отчёт по звонку» и сохранить в TXT.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.analysis.loadKeyIfNeeded() }
    }

    private func save() {
        if model.analysis.saveKey(draftKey) { draftKey = "" }
    }

    private func urlProblem(_ analysis: CallAnalysisModel) -> String? {
        switch analysis.urlCheck {
        case AnalysisRules.urlOK: nil
        case AnalysisRules.urlEmpty: "Укажите базовый URL сервиса."
        case AnalysisRules.urlNoScheme: "Адрес должен начинаться с https:// (или http:// для своего сервера)."
        case AnalysisRules.urlNoHost: "После https:// нужен адрес сервера."
        case AnalysisRules.urlSpace: "В адресе есть пробел или служебный символ."
        default: "Слишком длинный адрес."
        }
    }
}
