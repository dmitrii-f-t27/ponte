import AVFoundation
import Foundation
import PonteAudio
import PonteCore

/// Test mode (`-PonteIncomingFile`, `-PonteOutgoingFile`): an audio file played in real time
/// (FileSource), then silence until `stop()`, like the process tap of an app that went quiet or
/// a microphone in a quiet room. A live source never just stops, so the transcriber ends the last
/// phrase on its normal pause, and latency matches a real call.
final class TestFileSource: AudioSource, @unchecked Sendable {
    let url: URL
    /// Called on a background thread when the file has been played to the end.
    var onFileEnd: (() -> Void)?

    private let file: FileSource
    private let lock = NSLock()
    private var generation = 0
    private var handler: PCMHandler?

    init(url: URL) {
        self.url = url
        file = FileSource(url: url, realtime: true)
    }

    var outputFormat: AVAudioFormat { file.outputFormat }

    func start(handler: @escaping PCMHandler) throws {
        let current: Int = lock.withLock {
            generation += 1
            self.handler = handler
            return generation
        }
        file.onFinish = { [weak self] in self?.fileEnded(current) }
        do {
            try file.start(handler: handler)
        } catch {
            lock.withLock { self.handler = nil }
            throw error
        }
    }

    func stop() {
        lock.withLock {
            generation += 1
            handler = nil
        }
        file.stop()
    }

    private func currentHandler(_ g: Int) -> PCMHandler? {
        lock.withLock { generation == g ? handler : nil }
    }

    /// Delivers silent chunks at the file's rate and pace until stopped.
    private func fileEnded(_ g: Int) {
        onFileEnd?()
        let format = outputFormat
        let frames = PCM.framesPerChunk(sampleRate: format.sampleRate)
        let period = Double(frames) / format.sampleRate
        let thread = Thread { [weak self] in
            var due = Date()
            while let handler = self?.currentHandler(g) {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
                buffer.frameLength = frames
                buffer.floatChannelData?[0].update(repeating: 0, count: Int(frames))
                handler(buffer, nil)
                due += period
                let wait = due.timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
        }
        thread.name = "ponte.test.silence"
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}
