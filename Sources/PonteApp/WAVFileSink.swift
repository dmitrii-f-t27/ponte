import AVFoundation
import Foundation
import PonteAudio
import PonteCore

/// Test mode (`-PonteOutgoingSink`): an AudioPlayer that writes what it plays to a WAV file
/// instead of a device. Each call goes through the same resampler as DeviceAudioPlayer
/// (PCM.Converter: any rate and channel count → mono Float32 at `sampleRate`, flushed at the end
/// of the call), so the file holds what BlackHole would receive. The file is 16-bit PCM and is
/// rewritten after every phrase, so it is complete at any moment.
/// With `realtime`, `play` returns after the audio's duration, like a device.
final class WAVFileSink: AudioPlayer, @unchecked Sendable {
    let device: AudioDevice? = nil
    let url: URL
    let sampleRate: Double
    let realtime: Bool

    private let lock = NSLock()
    private var samples: [Float] = []
    private var generation = 0
    private(set) var lastError: Error?

    init(url: URL, sampleRate: Double = AudioRules.fallbackSampleRate, realtime: Bool = true) {
        self.url = url
        self.sampleRate = sampleRate
        self.realtime = realtime
    }

    /// Samples written so far (mono Float32 at `sampleRate`).
    var writtenSamples: [Float] { lock.withLock { samples } }

    func play(_ buffer: AVAudioPCMBuffer) async {
        await play([buffer])
    }

    func play(_ buffers: [AVAudioPCMBuffer]) async {
        let target = PCM.monoFormat(sampleRate: sampleRate)
        var out: [Float] = []
        var converter: PCM.Converter?
        let input = buffers.filter { $0.frameLength > 0 }
        do {
            for (i, buffer) in input.enumerated() {
                if converter == nil || !(converter!.inputFormat.isEqual(buffer.format)) {
                    converter = PCM.Converter(from: buffer.format, to: target)
                }
                guard let converter else { throw PonteAudioError.unsupportedFormat("\(buffer.format) → \(target)") }
                let nextDiffers = i + 1 < input.count && !input[i + 1].format.isEqual(buffer.format)
                let final = i == input.count - 1 || nextDiffers
                out += PCM.samples(try converter.convert(buffer, final: final))
            }
        } catch {
            lock.withLock { lastError = error }
            return
        }
        guard !out.isEmpty else { return }
        let (all, myGeneration): ([Float], Int) = lock.withLock {
            samples += out
            return (samples, generation)
        }
        do {
            try write(all)
        } catch {
            lock.withLock { lastError = error }
        }
        guard realtime else { return }
        // Pace like a device; stopAll() ends the wait.
        var left = Double(out.count) / sampleRate
        while left > 0, lock.withLock({ generation == myGeneration }) {
            let step = min(left, 0.05)
            try? await Task.sleep(for: .milliseconds(Int(step * 1000)))
            left -= step
        }
    }

    func stopAll() {
        lock.withLock { generation += 1 }
    }

    private func write(_ all: [Float]) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(forWriting: temp, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: PCM.buffer(all, sampleRate: sampleRate))
            file.close()
        }
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
    }
}
