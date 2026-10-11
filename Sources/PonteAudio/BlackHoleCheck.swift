import Foundation
import PonteCore

/// BlackHole is the virtual microphone the call app listens to (Ponte plays pt-BR speech into it).
/// Install: `brew install --cask blackhole-2ch` (asks for the admin password), then pick
/// "BlackHole 2ch" as the microphone in Zoom / Meet / Telegram / WhatsApp.
public enum BlackHoleCheck {
    public static let installCommand = "brew install --cask blackhole-2ch"

    /// The BlackHole device Ponte can play into, or nil when BlackHole is not installed.
    /// Prefers "BlackHole 2ch"; any BlackHole variant with output channels is accepted (AudioRules.pickBlackHoleIndex).
    public static func find(in catalog: AudioDeviceCatalog) -> AudioDevice? {
        let all = catalog.devices()
        let i = AudioRules.pickBlackHoleIndex(names: all.map(\.name), outputChannels: all.map(\.outputChannels))
        return i >= 0 ? all[i] : nil
    }

    public static func isInstalled(in catalog: AudioDeviceCatalog) -> Bool {
        find(in: catalog) != nil
    }
}
