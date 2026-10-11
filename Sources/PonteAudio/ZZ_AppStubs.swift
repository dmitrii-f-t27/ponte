// TEMPORARY stubs written by the app agent so PonteApp compiles before the real
// PonteAudio lands. They implement exactly the public API from SPEC.md
// («Публичный API модулей») with fakes. The lead deletes this file on merge.
import AppKit
import AVFoundation
import Foundation
import PonteCore

public final class CoreAudioDeviceCatalog: AudioDeviceCatalog {
    public init() {}

    public func devices() -> [AudioDevice] {
        [
            AudioDevice(id: 91, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
                        inputChannels: 1, outputChannels: 0),
            AudioDevice(id: 84, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
                        inputChannels: 0, outputChannels: 2),
            AudioDevice(id: 120, uid: "stub-headphones", name: "S6-L",
                        inputChannels: 1, outputChannels: 2),
        ]
    }

    public func defaultInput() -> AudioDevice? { devices().first { $0.inputChannels > 0 } }
    public func defaultOutput() -> AudioDevice? { devices().first { $0.outputChannels > 0 } }
}

public final class RunningAudioAppCatalog: AudioAppCatalog {
    public init() {}

    public func apps() -> [AudioApp] {
        var result: [String: AudioApp] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, app.activationPolicy == .regular else { continue }
            let known = AudioApp.knownCallApps[id] != nil
            let name = AudioApp.knownCallApps[id] ?? app.localizedName ?? id
            if let existing = result[id] {
                result[id] = AudioApp(bundleID: id, name: name, pids: existing.pids + [app.processIdentifier],
                                      isPlayingAudio: false, isKnownCallApp: known)
            } else {
                result[id] = AudioApp(bundleID: id, name: name, pids: [app.processIdentifier],
                                      isPlayingAudio: false, isKnownCallApp: known)
            }
        }
        return result.values.sorted {
            if $0.isKnownCallApp != $1.isKnownCallApp { return $0.isKnownCallApp }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

/// Emits 100 ms silent buffers in real time. Shared by the fake tap and the fake mic.
private final class StubSilenceSource {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var timer: DispatchSourceTimer?

    func start(handler: @escaping PCMHandler) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ponte.stub.audio"))
        let format = self.format
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600) else { return }
            buffer.frameLength = 1_600
            handler(buffer, nil)
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

public final class AppAudioTapSource: AudioSource {
    public let target: CaptureTarget
    private let silence = StubSilenceSource()
    public var outputFormat: AVAudioFormat { silence.format }

    public init(target: CaptureTarget) { self.target = target }
    public func start(handler: @escaping PCMHandler) throws { silence.start(handler: handler) }
    public func stop() { silence.stop() }
}

public final class MicSource: AudioSource {
    public let device: AudioDevice?
    private let silence = StubSilenceSource()
    public var outputFormat: AVAudioFormat { silence.format }

    public init(device: AudioDevice?) { self.device = device }
    public func start(handler: @escaping PCMHandler) throws { silence.start(handler: handler) }
    public func stop() { silence.stop() }
}

/// Really reads the file (mono Float32 at the file's rate) and emits 100 ms chunks.
public final class FileSource: AudioSource {
    public let url: URL
    public let realtime: Bool
    public let outputFormat: AVAudioFormat
    private var thread: Thread?
    private let lock = NSLock()
    private var cancelled = false

    public init(url: URL, realtime: Bool) {
        self.url = url
        self.realtime = realtime
        let rate = (try? AVAudioFile(forReading: url))?.processingFormat.sampleRate ?? 16_000
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    }

    public func start(handler: @escaping PCMHandler) throws {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let mono = outputFormat
        let chunk = AVAudioFrameCount(source.sampleRate / 10)
        lock.withLock { cancelled = false }
        let realtime = self.realtime
        let thread = Thread { [weak self] in
            while let self, !self.lock.withLock({ self.cancelled }) {
                guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk) else { return }
                do { try file.read(into: input, frameCount: chunk) } catch { return }
                if input.frameLength == 0 { return }
                guard let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: input.frameLength),
                      let src = input.floatChannelData, let dst = out.floatChannelData else { return }
                out.frameLength = input.frameLength
                let channels = Int(source.channelCount)
                for frame in 0..<Int(input.frameLength) {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += src[channel][frame] }
                    dst[0][frame] = sum / Float(channels)
                }
                handler(out, nil)
                if realtime { Thread.sleep(forTimeInterval: Double(input.frameLength) / source.sampleRate) }
            }
        }
        self.thread = thread
        thread.start()
    }

    public func stop() {
        lock.withLock { cancelled = true }
        thread = nil
    }
}

/// Fake player: "plays" by waiting for the buffer duration.
public final class DeviceAudioPlayer: AudioPlayer {
    public let device: AudioDevice?
    private let lock = NSLock()
    private var generation = 0

    public init(device: AudioDevice?) { self.device = device }

    public func play(_ buffer: AVAudioPCMBuffer) async {
        let started = lock.withLock { generation }
        let seconds = Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
        var waited = 0.0
        while waited < seconds, lock.withLock({ generation }) == started {
            try? await Task.sleep(for: .milliseconds(20))
            waited += 0.02
        }
    }

    public func stopAll() { lock.withLock { generation += 1 } }
}

public enum BlackHoleCheck {
    public static func find(in catalog: AudioDeviceCatalog) -> AudioDevice? {
        catalog.devices().first { $0.isVirtualMic && $0.outputChannels > 0 }
    }
}
