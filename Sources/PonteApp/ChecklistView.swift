import PonteAudio
import PonteCore
import SwiftUI

// The checklist «Перед звонком» (owner 2026-10-13). Live test that day: Meet's microphone was muted; Meet fell back
// from BlackHole to the MacBook microphone; a browser extension (MeetVoice) replaced the microphone; without
// headphones the microphone heard the other side. Marks come from ui_rules.t27 (ui_checklist_mark), the
// listener status from device_rules.t27 (dv_listen_status); the Russian texts are here.

/// What the checklist shows, collected by AppModel.
struct ChecklistFacts: Equatable {
    /// AppRules.LISTEN_* (the AudioRules.listen* codes).
    var listenStatus: Int32 = AppRules.LISTEN_UNKNOWN
    /// The app the listener status names and the input it reads (ListenerCheck.reader).
    var listenAppName: String?
    var listenDeviceName: String?
    /// AudioRules.kind* of that input.
    var listenDeviceKind: Int = AudioRules.kindUnknown
    /// Where the owner hears the call: the headphones setting, else the default output.
    var listeningName: String?
    var headphonesLike = false
    /// Ponte's microphone and where it comes from (AppRules.MICSRC_*).
    var micName: String?
    var micSource: Int32 = AppRules.MICSRC_SYSTEM
    /// The push-to-talk key, as the main window names it («правый ⌥»).
    var pttKeyShort = PTTKey.rightOption.short
}

/// One row of the checklist.
struct ChecklistItem: Identifiable, Equatable {
    enum Mark: Equatable {
        case unknown, ok, warn, bad, info

        /// From AppRules.CK_*.
        init(code: Int32) {
            switch code {
            case AppRules.CK_OK: self = .ok
            case AppRules.CK_WARN: self = .warn
            case AppRules.CK_BAD: self = .bad
            case AppRules.CK_INFO: self = .info
            default: self = .unknown
            }
        }
    }

    /// AppRules.CKI_*.
    let id: Int32
    let title: String
    let mark: Mark
    let detail: String
}

enum Checklist {
    /// The rows, in the order of the AppRules.CKI_* codes.
    static func items(_ facts: ChecklistFacts) -> [ChecklistItem] {
        (0..<AppRules.CKI_COUNT).map { item in
            let mark = AppRules.checklistMark(item: item, listenStatus: facts.listenStatus,
                                              headphonesLike: facts.headphonesLike, micSource: facts.micSource)
            return ChecklistItem(id: item, title: title(item), mark: ChecklistItem.Mark(code: mark),
                                 detail: detail(item, mark: mark, facts))
        }
    }

    static func title(_ item: Int32) -> String {
        switch item {
        case AppRules.CKI_LISTENER: "Meet слушает BlackHole"
        case AppRules.CKI_CALL_MIC: "Микрофон в Meet включён"
        case AppRules.CKI_HEADPHONES: "Наушники"
        case AppRules.CKI_MY_MIC: "Ваш микрофон для Ponte"
        case AppRules.CKI_EXTENSIONS: "Переводчики в браузере выключены"
        case AppRules.CKI_HOW_TO_TALK: "Как говорить"
        default: ""
        }
    }

    /// The row's text for its mark (AppRules.CK_*).
    static func detail(_ item: Int32, mark: Int32, _ facts: ChecklistFacts) -> String {
        switch item {
        case AppRules.CKI_LISTENER:
            return listenerText(facts)
        case AppRules.CKI_CALL_MIC:
            return "Не выключайте микрофон в Meet — иначе перевод не дойдёт. Ваш живой голос туда не попадает: "
                + "Ponte отправляет только перевод."
        case AppRules.CKI_HEADPHONES:
            if mark == AppRules.CK_OK {
                return "Наушники: \(facts.listeningName ?? "—"). В Meet выберите их как «Динамик»."
            }
            return "Наушников нет — собеседники звучат из динамиков. Говорите только с зажатой кнопкой. "
                + "Ponte слушает микрофон ноутбука."
        case AppRules.CKI_MY_MIC:
            switch facts.micSource {
            case AppRules.MICSRC_SAVED:
                return "\(facts.micName ?? "—") — выбран в настройках."
            case AppRules.MICSRC_AUTO:
                return "\(facts.micName ?? "—") — выбран автоматически. Гарнитура с микрофоном (например, AirPods) "
                    + "подхватится сама, если звук идёт в неё."
            default:
                return "Подходящий микрофон не найден: Ponte возьмёт системный микрофон по умолчанию."
            }
        case AppRules.CKI_EXTENSIONS:
            return "Расширения вроде MeetVoice подменяют микрофон в Meet. Держите их выключенными."
        case AppRules.CKI_HOW_TO_TALK:
            return "Зажмите зелёную полосу или \(facts.pttKeyShort), скажите фразу по-русски, отпустите — "
                + "Meet услышит португальский."
        default:
            return ""
        }
    }

    /// The listener row's text; during a call the red banner shows the same text.
    static func listenerText(_ facts: ChecklistFacts) -> String {
        let app = facts.listenAppName ?? "Звонилка"
        let mic = facts.listenDeviceKind == AudioRules.kindBuiltInMic
            ? "микрофон MacBook" : "микрофон «\(facts.listenDeviceName ?? "—")»"
        switch facts.listenStatus {
        case AppRules.LISTEN_OK:
            return "\(app) берёт звук из BlackHole."
        case AppRules.LISTEN_NOBODY:
            return "Звонилка не слушает BlackHole: в Meet откройте ⋮ → Настройки → Аудио → Микрофон "
                + "и выберите «BlackHole 2ch»."
        case AppRules.LISTEN_REAL_MIC:
            return "\(app) слушает \(mic) — собеседники слышат ваш русский голос. Выберите «BlackHole 2ch»."
        case AppRules.LISTEN_BOTH:
            return "\(app) слушает и BlackHole, и \(mic). Если собеседники слышат ваш русский голос, "
                + "выберите в Meet микрофон «BlackHole 2ch»."
        case AppRules.LISTEN_NO_BLACKHOLE:
            return "BlackHole не установлен — перевод не попадёт в звонок. Установите его: "
                + BlackHoleCheck.installCommand
        default:
            return "Проверяем, кто слушает BlackHole…"
        }
    }
}

/// The sheet «Перед звонком»: opens at launch (unless turned off), from the toolbar and from the «Звонок» menu.
struct ChecklistView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "checklist")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Перед звонком")
                        .font(.title2.weight(.semibold))
                    Text("Включите микрофон в Meet и наденьте наушники. Без наушников Ponte слушает микрофон ноутбука.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.checklistItems) { ChecklistRow(item: $0) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            HStack(spacing: 12) {
                Toggle("Показывать при запуске", isOn: $model.checklistOnLaunch)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Закрыть") { model.showChecklist = false }
                    .keyboardShortcut(.cancelAction)
                Button {
                    model.startFromChecklist()
                } label: {
                    Label("Начать", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!AppRules.checklistCanStart(runState: model.runState.code))
                .accessibilityHint("Закрыть список и начать перевод")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 620)
    }
}

private struct ChecklistRow: View {
    let item: ChecklistItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            icon
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .fontWeight(.semibold)
                Text(item.detail)
                    .foregroundStyle(item.mark == .bad ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(background))
        .accessibilityElement(children: .combine)
    }

    private var background: Color {
        switch item.mark {
        case .bad: Color.red.opacity(0.09)
        case .warn: Color.orange.opacity(0.08)
        default: Color.clear
        }
    }

    @ViewBuilder private var icon: some View {
        switch item.mark {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .bad:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .info:
            Image(systemName: "info.circle").foregroundStyle(.blue)
        case .unknown:
            ProgressView().controlSize(.small)
        }
    }
}
