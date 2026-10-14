import AppKit
import PontePeer
import SwiftUI

/// «Русские в звонке»: the Russians of one Meet call hear each other's own voice through Ponte (the Portuguese side
/// does not), and no Ponte translates another Ponte's Portuguese voice back into Russian.
struct PeerPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Русские в звонке")
                .font(.headline)
            Text("Русские в звонке слышат друг друга своими голосами, без перевода, а португалец этот голос не слышит. Один нажимает «Создать код» и отправляет код остальным русским (в Telegram или WhatsApp, не португальцу). Все вводят этот код и нажимают «Подключиться».")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("Код русских: abcd-efgh-jkmn", text: $model.peerSecret)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(minWidth: 180)
                    .disabled(model.peerOn)
                Button("Создать код") { model.newPeerSecret() }
                    .disabled(model.peerOn)
                    .accessibilityHint("Новый случайный код для русских в этом звонке")
                Button("Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.peerSecret, forType: .string)
                }
                .disabled(model.peerSecret.isEmpty)
                .accessibilityHint("Скопировать код, чтобы отправить его второму русскому")
            }

            HStack(spacing: 10) {
                Button(model.peerOn ? "Отключиться" : "Подключиться") {
                    model.setPeer(on: !model.peerOn)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.peerOn ? .red : .accentColor)
                Toggle("Мой голос русским", isOn: Binding(get: { !model.peerMuted }, set: { model.peerMuted = !$0 }))
                    .disabled(!model.peerOn)
                    .accessibilityHint("Выключите, чтобы второй русский вас не слышал")
            }

            Label(statusText, systemImage: statusIcon)
                .foregroundStyle(statusColor)
            if model.peerOn, model.peerMembers > model.peerCount + 1 {
                Label("В комнате есть участник, который не назвался: возможно, кто-то подслушивает. Отключитесь и создайте новый код.",
                      systemImage: "exclamationmark.shield.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.peerOn && !model.isRunning {
                Label("Вас услышат, когда перевод запущен (кнопка «Старт»). Других русских вы слышите уже сейчас.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.peerOn && !model.headphonesLike {
                Label("Без наушников вас слышно только пока вы держите кнопку разговора: иначе второй русский услышит себя эхом.",
                      systemImage: "headphones")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.peerNotice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private var statusText: String {
        switch model.peerStatus {
        case PeerRules.statusLinked:
            return model.peerSpeaking ? "Говорит второй русский" : "Связь есть: русских рядом — \(model.peerCount)"
        case PeerRules.statusWaiting: return "Подключено. Ждём второго русского…"
        case PeerRules.statusConnecting: return "Подключаемся…"
        case PeerRules.statusFailed:
            return model.peerRoomFull ? "Комната занята: в ней уже \(PeerRules.maxPeers) участников. Пробуем снова…" : "Нет связи с сервером. Пробуем снова…"
        default: return "Выключено"
        }
    }

    private var statusIcon: String {
        switch model.peerStatus {
        case PeerRules.statusLinked: return model.peerSpeaking ? "waveform" : "person.2.fill"
        case PeerRules.statusWaiting, PeerRules.statusConnecting: return "hourglass"
        case PeerRules.statusFailed: return "exclamationmark.triangle.fill"
        default: return "person.2.slash"
        }
    }

    private var statusColor: Color {
        switch model.peerStatus {
        case PeerRules.statusLinked: return .green
        case PeerRules.statusFailed: return .red
        case PeerRules.statusWaiting, PeerRules.statusConnecting: return .orange
        default: return .secondary
        }
    }
}

/// The toolbar button that opens the panel; its icon shows the link.
struct PeerToolbarButton: View {
    @Environment(AppModel.self) private var model
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Label("Русские в звонке", systemImage: icon)
        }
        .accessibilityHint("Русские в звонке: слышать второго русского без перевода")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            PeerPanel()
                .environment(model)
        }
    }

    private var icon: String {
        switch model.peerStatus {
        case PeerRules.statusLinked: return "person.2.wave.2.fill"
        case PeerRules.statusOff: return "person.2"
        default: return "person.2.badge.gearshape"
        }
    }
}
