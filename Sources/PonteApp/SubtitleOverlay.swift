import AppKit
import PonteCore
import SwiftUI

/// Floating subtitles over the call window: non-activating, always on top,
/// translucent, draggable, on every Space (also next to full-screen apps).
@MainActor
final class SubtitleOverlayController {
    private let model: AppModel
    private var panel: NSPanel?

    init(model: AppModel) { self.model = model }

    func show() {
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = SubtitlePanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 130),
                                  styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                  backing: .buffered, defer: false)
        panel.title = "Субтитры Ponte"
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: 360, height: 90)

        let root = SubtitleOverlayView(onClose: { [weak model] in model?.overlayVisible = false })
            .environment(model)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host

        if !panel.setFrameUsingName("PonteSubtitles"), let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 380, y: frame.minY + 60))
        }
        panel.setFrameAutosaveName("PonteSubtitles")
        return panel
    }
}

private final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Behind-window blur, so the call shows through.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

struct SubtitleOverlayView: View {
    @Environment(AppModel.self) private var model
    var onClose: () -> Void
    @State private var hovering = false
    @State private var panelHeight: CGFloat = 130

    /// The last incoming translations; how many is AppRules.overlayLineCount.
    private var lastTwo: [ConversationLine] {
        let translated = model.incomingLines.filter { !($0.translation ?? "").isEmpty }
        let count = AppRules.overlayLineCount(available: Int32(translated.count), panelHeight: Int32(panelHeight),
                                              fontSize: Int32(model.fontSize))
        return Array(translated.suffix(Int(count)))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                if lastTwo.isEmpty {
                    Text(model.isRunning ? "Ponte слушает собеседников…" : "Здесь появятся субтитры. Нажмите «Старт» в Ponte.")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    ForEach(Array(lastTwo.enumerated()), id: \.element.id) { index, line in
                        let newest = index == lastTwo.count - 1
                        Text(line.translation ?? "")
                            .font(.system(size: newest ? model.fontSize + 4 : model.fontSize - 2,
                                          weight: newest ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(newest ? 1 : 0.62))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !model.incomingPartial.isEmpty {
                    Text(model.incomingPartial)
                        .font(.system(size: 15))
                        .italic()
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Скрыть субтитры")
                .padding(10)
            }
        }
        .background {
            ZStack {
                VisualEffectBackground()
                Color.black.opacity(0.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .gesture(WindowDragGesture())
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
        .animation(.easeOut(duration: 0.2), value: lastTwo.map(\.id))
    }
}
