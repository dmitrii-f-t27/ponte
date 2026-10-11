import AppKit
import PonteCore
import SwiftUI
import Translation

// `SpeechProbe packs`: a CLI cannot download translation packs (TranslationSession(installedSource:)
// has canRequestDownloads == false). SwiftUI `.translationTask` gets a session that may ask the
// system to download: macOS shows its own prompt, the owner confirms it.

private struct PackDownloadView: View {
    @State private var configuration: TranslationSession.Configuration? =
        TranslationSession.Configuration(source: Lang.ptBR.language, target: Lang.ru.language)
    @State private var lines: [String] = ["Ponte: языковые пакеты перевода pt-BR ⇄ ru"]
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lines, id: \.self) { Text($0) }
        }
        .padding(20)
        .frame(width: 460, height: 180, alignment: .topLeading)
        .translationTask(configuration) { session in
            let pair = step == 0 ? "pt-BR → ru" : "ru → pt-BR"
            do {
                try await session.prepareTranslation()
                lines.append("\(pair): пакет установлен")
                print("\(pair): installed")
            } catch {
                lines.append("\(pair): ошибка \(error.localizedDescription)")
                print("\(pair): error \(error)")
            }
            step += 1
            if step == 1 {
                configuration = TranslationSession.Configuration(source: Lang.ru.language, target: Lang.ptBR.language)
            } else {
                try? await Task.sleep(for: .seconds(2))
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

@MainActor
func runPackDownloader() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 180),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Ponte — пакеты перевода"
    window.contentView = NSHostingView(rootView: PackDownloadView())
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}
