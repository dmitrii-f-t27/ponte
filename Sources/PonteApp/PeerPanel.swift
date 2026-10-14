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
            Text("Если в звонке двое русских с Ponte, вы слышите друг друга своими голосами, без перевода. Португалец этот голос не слышит. Второй русский вводит в своём Ponte тот же код встречи.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("Код встречи Meet: abc-defg-hij", text: $model.peerCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200)
                    .disabled(model.peerOn)
                Button("Взять из Meet") {
                    Task {
                        if let code = await model.detectMeetCode() {
                            model.peerCode = code
                            model.peerNotice = nil
                        } else {
                            model.peerNotice = "Код встречи не найден. Скопируйте его из адреса Meet: meet.google.com/abc-defg-hij."
                        }
                    }
                }
                .disabled(model.peerOn)
                .accessibilityHint("Найти код встречи в окне Meet")
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
        case PeerRules.statusFailed: return "Нет связи с сервером. Пробуем снова…"
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
