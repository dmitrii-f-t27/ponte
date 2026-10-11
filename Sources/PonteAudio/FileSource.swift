import AVFoundation
import Foundation
import PonteCore

/// Reads any audio file AVFoundation understands (wav, aiff, m4a, mp3, caf…) and delivers mono
/// Float32 chunks of about 100 ms at the file's native rate, on a background thread.
/// `realtime: true` paces the chunks at playback speed (each chunk is delivered when its last
/// sample "would have been heard"), `false` delivers as fast as possible.
public final class FileSource: AudioSource {
    public let url: URL
    public let realtime: Bool
    /// Chunk length in seconds (default AudioRules.chunkSeconds = 0.1). Set before `start`.
    public var chunkDuration: Double = AudioRules.chunkSeconds
    /// Called on the reading thread after the last chunk (not called after `stop`).
    /// Keep a strong reference to the source while it runs; releasing it stops reading.
    public var onFinish: (() -> Void)?

    /// Mono Float32 at the file's sample rate (AudioRules.fallbackSampleRate if the file cannot be opened; `start` then throws).
    public let outputFormat: AVAudioFormat

    private let lock = NSLock()
    private var generation = 0
    private var isRunning = false

    public init(url: URL, realtime: Bool) {
        self.url = url
        self.realtime = realtime
        let rate = AudioRules.rateOrDefault((try? AVAudioFile(forReading: url))?.processingFormat.sampleRate ?? 0)
        self.outputFormat = PCM.monoFormat(sampleRate: rate)
    }

    deinit { stop() }

    public func start(handler: @escaping PCMHandler) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == outputFormat.sampleRate else {
            throw PonteAudioError.unsupportedFormat("file changed since init: \(format)")
        }
        lock.lock()
        guard !isRunning else { lock.unlock(); throw PonteAudioError.alreadyRunning }
        isRunning = true
        generation += 1
        let myGeneration = generation
        lock.unlock()

        let chunk = PCM.framesPerChunk(sampleRate: format.sampleRate, seconds: chunkDuration)
        let realtime = self.realtime
        let thread = Thread { [weak self] in
            let startHost = DispatchTime.now().uptimeNanoseconds
            var position: AVAudioFramePosition = 0
            while true {
                guard let self, self.isCurrent(myGeneration) else { return }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                do {
                    try file.read(into: buffer, frameCount: chunk)
                } catch {
                    break
                }
                if buffer.frameLength == 0 { break }
                if realtime {
                    let wait = AudioRules.pacingSleepNanos(startNanos: startHost, nowNanos: DispatchTime.now().uptimeNanoseconds,
                                                           endFrame: position + AVAudioFramePosition(buffer.frameLength),
                                                           sampleRate: format.sampleRate)
                    if wait > 0 { Thread.sleep(forTimeInterval: Double(wait) / 1e9) }
                }
                guard let mono = PCM.mono(buffer), self.isCurrent(myGeneration) else { return }
                let time = AVAudioTime(sampleTime: position, atRate: format.sampleRate)
                handler(mono, time)
                position += AVAudioFramePosition(buffer.frameLength)
            }
            // End of file (or a read error): report completion unless stopped meanwhile.
            guard let self, self.finishIfCurrent(myGeneration) else { return }
            self.onFinish?()
        }
        thread.name = "ponte.audio.file"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func stop() {
        lock.lock()
        generation += 1
        isRunning = false
        lock.unlock()
    }

    private func isCurrent(_ g: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return g == generation && isRunning
    }

    /// Marks the run finished; true if it was not stopped meanwhile.
    private func finishIfCurrent(_ g: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard g == generation, isRunning else { return false }
        isRunning = false
        return true
    }

    /// Reads a whole file as one mono Float32 buffer at its native rate (tests, offline checks).
    public static func readMono(url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(max(file.length, 1))) else {
            throw PonteAudioError.unsupportedFormat("cannot allocate \(file.length) frames")
        }
        try file.read(into: buffer)
        guard let mono = PCM.mono(buffer) else { throw PonteAudioError.unsupportedFormat("\(file.processingFormat)") }
        return mono
    }
}
