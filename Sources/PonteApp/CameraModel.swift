import AppKit
import Foundation
import Observation
import PonteAudio
import PonteCamera

/// «Камера в Meet»: the picture settings the Ponte Camera extension applies (Specs/camera_rules.t27), kept between
/// launches, sent over the camera link on every change; the link's status for the panel; and the extension's files,
/// copied out of the app to a folder BrowserOS loads them from.
@MainActor @Observable final class CameraModel {
    /// One value per CameraRules setting kind, each held to its range.
    private(set) var settings: [Int]
    /// «Обрабатывать камеру»: off, every frame passes as it came.
    var on: Bool { didSet { persist(); publish() } }
    /// The link and the Meet pages' cameras as the extension reports them.
    private(set) var link = CameraLinkStatus()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let server: CameraLink
    @ObservationIgnored private var started = false

    private enum Key {
        static let settings = "cameraSettings"
        static let on = "cameraOn"
    }

    init(defaults: UserDefaults = .standard, port: Int = CameraRules.linkPort) {
        self.defaults = defaults
        let stored = defaults.array(forKey: Key.settings) as? [Int] ?? []
        settings = (0..<CameraRules.setCount).map { kind in
            CameraRules.clamp(kind, kind < stored.count ? stored[kind] : CameraRules.settingDefault(kind))
        }
        on = defaults.object(forKey: Key.on) as? Bool ?? CameraRules.defaultOn
        server = CameraLink(port: port)
        server.onStatus = { [weak self] status in
            MainActor.assumeIsolated {
                self?.link = status
            }
        }
    }

    /// Starts the link (once) and puts the extension's files where BrowserOS loads them from.
    func start() {
        guard !started else { return }
        started = true
        installExtensionFiles()
        publish()
        server.start()
    }

    func stop() {
        server.stop()
        started = false
    }

    /// The panel's status (CameraRules.linkPanel): a camera in trouble before a processed one.
    var status: Int { link.code }

    func value(_ kind: Int) -> Int { kind < settings.count ? settings[kind] : CameraRules.settingDefault(kind) }

    func set(_ kind: Int, _ value: Int) {
        guard kind >= 0, kind < settings.count else { return }
        let held = CameraRules.clamp(kind, value)
        guard settings[kind] != held else { return }
        settings[kind] = held
        persist()
        publish()
    }

    /// A preset sets light and colour and keeps the frame.
    func applyPreset(_ preset: Int) {
        for kind in 0..<settings.count where CameraRules.presetSets(kind) {
            settings[kind] = CameraRules.presetValue(preset, kind)
        }
        persist()
        publish()
    }

    /// The preset whose values the light and colour have now (nil: changed by hand).
    var currentPreset: Int? { CameraRules.matchingPreset(settings) }

    /// «Сбросить»: every setting back to its default (the picture as it comes).
    func reset() {
        settings = (0..<CameraRules.setCount).map { CameraRules.settingDefault($0) }
        persist()
        publish()
    }

    private func persist() {
        defaults.set(settings, forKey: Key.settings)
        defaults.set(on, forKey: Key.on)
    }

    private func publish() {
        let message: [String: Any] = ["type": "settings", "v": CameraRules.linkVersion, "on": on, "s": settings]
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { return }
        server.publish(data)
    }

    // MARK: The extension's files

    /// ~/Library/Application Support/Ponte/PonteCamera: «Загрузить распакованное» in BrowserOS points here once.
    nonisolated static var extensionFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ponte/PonteCamera", isDirectory: true)
    }

    /// The extension inside the app (scripts/bundle.sh copies camera/extension there).
    nonisolated static var bundledExtension: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("PonteCamera", isDirectory: true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { return nil }
        return url
    }

    /// Copies the extension out of the app when the folder lacks it or holds other files (an older Ponte's).
    /// BrowserOS picks up the new files when the extension is reloaded or the browser restarts.
    func installExtensionFiles() {
        guard let source = Self.bundledExtension else { return }
        let target = Self.extensionFolder
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let names = try fm.contentsOfDirectory(atPath: source.path)
            for name in names {
                let from = source.appendingPathComponent(name)
                let to = target.appendingPathComponent(name)
                if fm.contentsEqual(atPath: from.path, andPath: to.path) { continue }
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
            }
        } catch {
            PonteDiagnostics.log("camera: cannot copy the extension to \(target.path): \(error)")
        }
    }

    var extensionInstalledFiles: Bool {
        FileManager.default.fileExists(atPath: Self.extensionFolder.appendingPathComponent("manifest.json").path)
    }

    func revealExtensionFolder() {
        installExtensionFiles()
        NSWorkspace.shared.activateFileViewerSelecting([Self.extensionFolder])
    }
}
