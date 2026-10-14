import AppKit
import SwiftUI

@main
struct PonteMain: App {
    @NSApplicationDelegateAdaptor(PonteAppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Ponte", id: "main") {
            MainView()
                .environment(model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1080, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Звонок") {
                Button(model.isRunning ? "Стоп" : "Старт") { model.toggleRun() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.enabled(AppRules.BTN_START_STOP))
                Toggle("Пауза голоса в звонок", isOn: Binding(get: { model.voicePaused },
                                                               set: { model.voicePaused = $0 }))
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Toggle("Свой голос", isOn: Binding(get: { model.ownVoice }, set: { _ in model.toggleOwnVoice() }))
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(!model.ownVoiceAvailable)
                Divider()
                Button("Сохранить стенограмму") { model.saveTranscript() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.enabled(AppRules.BTN_SAVE_TRANSCRIPT))
                Toggle("Субтитры поверх окон", isOn: Binding(get: { model.overlayVisible },
                                                             set: { model.overlayVisible = $0 }))
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Мастер настройки…") {
                    model.wizardStep = .permissions
                    model.showWizard = true
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class PonteAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Stops both lanes first so the transcript of a running call is saved.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, AppRules.quitWaits(runState: model.runState.code) else { return .terminateNow }
        Task { @MainActor in
            await model.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
