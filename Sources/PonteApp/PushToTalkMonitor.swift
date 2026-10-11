import AppKit
import ApplicationServices

/// Watches the push-to-talk modifier. Scope comes from AppRules.pttScope: a global
/// monitor needs the Accessibility permission; otherwise only Ponte's windows are seen.
@MainActor
final class PushToTalkMonitor {
    var key: PTTKey = .rightOption
    var onChange: (Bool) -> Void = { _ in }
    private(set) var isGlobal = false
    private var local: Any?
    private var global: Any?
    private var held = false

    static var hasGlobalPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security → Accessibility.
    static func requestGlobalPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Installs the monitors for an AppRules.PTT_SCOPE_* code.
    func apply(scope: Int32) {
        stop()
        guard AppRules.pttLocal(scope: scope) else { return }
        local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event.modifierFlags) }
            return event
        }
        if AppRules.pttGlobal(scope: scope) {
            global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event.modifierFlags) }
            }
            isGlobal = global != nil
        }
    }

    func stop() {
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        local = nil
        global = nil
        isGlobal = false
        if held {
            held = false
            onChange(false)
        }
    }

    private func handle(_ flags: NSEvent.ModifierFlags) {
        let down = AppRules.pttKeyDown(key: key.ruleCode, flags: UInt64(flags.rawValue))
        guard down != held else { return }
        held = down
        onChange(down)
    }
}
