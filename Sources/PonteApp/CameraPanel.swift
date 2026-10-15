import PonteCamera
import SwiftUI

/// «Камера в Meet»: light, colour and framing of the owner's camera as the other side sees it, applied by the Ponte
/// Camera extension in BrowserOS (Specs/camera_rules.t27). Changes show at once in Meet's own preview of you.
struct CameraPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Scrolls when the screen is short: eight sliders, presets and the install steps.
        ScrollView {
            content
                .padding(16)
        }
        .frame(width: 460)
        .frame(maxHeight: 600)
    }

    private var content: some View {
        let camera = model.camera
        return VStack(alignment: .leading, spacing: 10) {
            Text("Камера в Meet")
                .font(.headline)
            Label(statusText(camera), systemImage: statusIcon(camera))
                .foregroundStyle(statusColor(camera))
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Обрабатывать камеру", isOn: Binding(get: { camera.on }, set: { camera.on = $0 }))
                .accessibilityHint("Выключено: Meet получает картинку с камеры как есть")

            Picker("Готовые настройки", selection: Binding(get: { camera.currentPreset ?? -1 },
                                                           set: { if $0 >= 0 { camera.applyPreset($0) } })) {
                if camera.currentPreset == nil { Text("Свои").tag(-1) }
                Text("Обычный").tag(CameraRules.presetNormal)
                Text("Тёплый").tag(CameraRules.presetWarm)
                Text("Тёмная комната").tag(CameraRules.presetDarkRoom)
                Text("Ярче").tag(CameraRules.presetVivid)
            }
            .disabled(!camera.on)

            group("Свет", rows: [(CameraRules.setBrightness, "Яркость", "темнее", "светлее"),
                                 (CameraRules.setContrast, "Контраст", "мягче", "резче"),
                                 (CameraRules.setShadows, "Тени", "как есть", "светлее")])
            group("Цвет", rows: [(CameraRules.setWarmth, "Оттенок", "холоднее", "теплее"),
                                 (CameraRules.setSaturation, "Насыщенность", "бледнее", "ярче")])
            group("Кадр", rows: [(CameraRules.setZoom, "Приближение", "весь кадр", "×3"),
                                 (CameraRules.setPanX, "Сдвиг ↔", "влево", "вправо"),
                                 (CameraRules.setPanY, "Сдвиг ↕", "вверх", "вниз")])
            Toggle("Зеркально (как в зеркале для собеседника)",
                   isOn: Binding(get: { camera.value(CameraRules.setMirror) == 1 },
                                 set: { camera.set(CameraRules.setMirror, $0 ? 1 : 0) }))
                .disabled(!camera.on)

            HStack {
                Button("Сбросить всё") { camera.reset() }
                Spacer()
                Button("Папка расширения") { camera.revealExtensionFolder() }
            }

            // Open by itself while the extension is not connected.
            DisclosureGroup("Как установить расширение (один раз)", isExpanded: Binding(
                get: { installShown ?? CameraRules.panelInstallOpen(status: camera.status) },
                set: { installShown = $0 })) {
                InstallSteps()
            }
        }
    }

    @State private var installShown: Bool?

    private func group(_ title: String, rows: [(Int, String, String, String)]) -> some View {
        let camera = model.camera
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { kind, name, low, high in
                // One line: name, the slider between its two ends, the value.
                HStack(spacing: 8) {
                    Text(name)
                        .frame(width: 104, alignment: .leading)
                    Slider(value: Binding(get: { Double(camera.value(kind)) },
                                          set: { camera.set(kind, Int($0.rounded())) }),
                           in: Double(CameraRules.settingMin(kind))...Double(CameraRules.settingMax(kind)),
                           step: 1) {
                        Text(name)
                    } minimumValueLabel: {
                        Text(low).font(.caption2).foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
                    } maximumValueLabel: {
                        Text(high).font(.caption2).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    }
                    .labelsHidden()
                    .accessibilityLabel(name)
                    Text(shown(kind, camera.value(kind)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .disabled(!camera.on)
    }

    /// The zoom shows as 1.0×…3.0×, the rest as signed numbers.
    private func shown(_ kind: Int, _ value: Int) -> String {
        if kind == CameraRules.setZoom { return String(format: "%.1f×", Double(value) / 100) }
        return value > 0 ? "+\(value)" : "\(value)"
    }

    private func statusText(_ camera: CameraModel) -> String {
        switch camera.status {
        case CameraRules.linkActive: return "Meet получает обработанную картинку."
        case CameraRules.linkPassing:
            return camera.on ? "Камера в Meet открыта. Настройки не меняют картинку — кадры идут как есть."
                             : "Обработка выключена: Meet получает камеру как есть."
        case CameraRules.linkTrouble:
            let reason = camera.link.error.map { " Сбой: \(stageText($0.stage)) — \($0.name): \($0.message)." } ?? ""
            return "Meet получает картинку без обработки.\(reason) Ponte Camera пробует снова сама."
        case CameraRules.linkWaiting: return "Расширение подключено. Включите камеру в Meet."
        case CameraRules.linkNoExtension:
            return "Расширение Ponte Camera не подключено. Если оно уже установлено, оно подключится само в течение "
                + "полуминуты после открытия Meet; иначе установите его один раз (ниже)."
        case CameraRules.linkFailed: return "Порт \(CameraRules.linkPort) занят: закройте второй Ponte и откройте этот снова."
        default: return "Связь с расширением выключена."
        }
    }

    /// Where a page's renderer failed (CM_STAGE_*).
    private func stageText(_ stage: Int) -> String {
        switch stage {
        case CameraRules.stageCreate: return "не удалось подготовить рисование"
        case CameraRules.stageUpload: return "кадр камеры не принят видеокартой"
        case CameraRules.stageDraw: return "ошибка рисования"
        case CameraRules.stageOutput: return "не удалось собрать новый кадр"
        case CameraRules.stageLost: return "видеокарта сбросила контекст"
        case CameraRules.stageWrite: return "Meet не принял кадр"
        case CameraRules.stageRead: return "камера перестала отдавать кадры"
        default: return "неизвестный этап"
        }
    }

    private func statusIcon(_ camera: CameraModel) -> String {
        switch camera.status {
        case CameraRules.linkActive: return "video.fill"
        case CameraRules.linkWaiting, CameraRules.linkPassing: return "video"
        case CameraRules.linkFailed, CameraRules.linkTrouble: return "exclamationmark.triangle.fill"
        default: return "video.slash"
        }
    }

    private func statusColor(_ camera: CameraModel) -> Color {
        switch camera.status {
        case CameraRules.linkActive: return .green
        case CameraRules.linkFailed: return .red
        case CameraRules.linkNoExtension, CameraRules.linkTrouble: return .orange
        default: return .secondary
        }
    }
}

/// One-time installation of the extension in BrowserOS.
private struct InstallSteps: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("1. Нажмите «Папка расширения»: откроется папка PonteCamera.")
            Text("2. В BrowserOS откройте адрес chrome://extensions.")
            Text("3. Включите «Режим разработчика» справа вверху.")
            Text("4. Нажмите «Загрузить распакованное» и выберите папку PonteCamera.")
            Text("5. Перезагрузите вкладку Meet или включите камеру заново.")
            Button("Скопировать адрес chrome://extensions") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("chrome://extensions", forType: .string)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The toolbar button that opens the panel; its icon shows whether Meet gets the processed picture.
struct CameraToolbarButton: View {
    @Environment(AppModel.self) private var model
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Label("Камера в Meet", systemImage: model.camera.status == CameraRules.linkActive ? "video.fill" : "video")
        }
        .accessibilityHint("Камера в Meet: свет, цвет и кадр")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            CameraPanel()
                .environment(model)
        }
    }
}
