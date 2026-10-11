import AVFoundation
import CoreAudio
import Foundation

/// Pure PCM helpers: formats, downmix, chunking, levels, conversion. No device access.
public enum PCM {
    /// The format every PonteAudio source delivers: mono, Float32, deinterleaved.
    public static func monoFormat(sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    public static func isMonoFloat32(_ format: AVAudioFormat) -> Bool {
        AudioRules.isMonoFloat32(format: Int(format.commonFormat.rawValue), channels: Int(format.channelCount))
    }

    // MARK: Downmix (math in AudioRules)

    /// Averages all channels of a raw Float32 AudioBufferList (interleaved or deinterleaved, any
    /// number of buffers) into `dst`. Buffers with a NULL `mData` (disabled streams) are skipped.
    /// Returns the number of frames written (the shortest buffer wins, capped at `maxFrames`).
    /// Real-time safe: no allocation, no locks.
    static func downmixFloat32(_ abl: UnsafePointer<AudioBufferList>,
                               into dst: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        let shape = AudioRules.bufferListShape(buffers, maxFrames: maxFrames)
        guard shape.frames > 0 else { return 0 }
        dst.update(repeating: 0, count: shape.frames)
        var used = 0
        for b in buffers where used < AudioRules.bufferListMax
            && AudioRules.usesBuffer(hasData: b.mData != nil, channels: Int(b.mNumberChannels)) {
            used += 1
            AudioRules.accumulateFrames(b.mData!.assumingMemoryBound(to: Float.self), channels: Int(b.mNumberChannels),
                                        frames: shape.frames, into: dst)
        }
        AudioRules.scale(dst, frames: shape.frames, by: AudioRules.averageFactor(totalChannels: shape.channels))
        return shape.frames
    }

    /// Returns a new mono Float32 buffer at the same sample rate (channels averaged).
    /// Accepts Float32, Int16 and Int32 PCM, interleaved or not. Returns nil for other formats.
    public static func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        guard channels > 0,
              let out = AVAudioPCMBuffer(pcmFormat: monoFormat(sampleRate: format.sampleRate),
                                         frameCapacity: AVAudioFrameCount(max(frames, 1))) else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        guard frames > 0 else { return out }
        let dst = out.floatChannelData![0]
        dst.update(repeating: 0, count: frames)
        // Interleaved data is one block of `channels`; planar data is `channels` blocks of 1 (AudioRules).
        let blocks = AudioRules.monoBlocks(interleaved: format.isInterleaved, channels: channels)
        let perBlock = AudioRules.monoPerBlock(interleaved: format.isInterleaved, channels: channels)
        let samplesPerBlock = frames * perBlock
        guard AudioRules.monoSupported(format: Int(format.commonFormat.rawValue)) else { return nil }

        // The sample type picks the channel-data accessor.
        switch format.commonFormat {
        case .pcmFormatFloat32:
            for k in 0..<blocks {
                AudioRules.accumulateFrames(buffer.floatChannelData![k], channels: perBlock, frames: frames, into: dst)
            }
        case .pcmFormatInt16:
            for k in 0..<blocks {
                let src = buffer.int16ChannelData![k]
                let floats = (0..<samplesPerBlock).map { AudioRules.int16ToFloat(src[$0]) }
                floats.withUnsafeBufferPointer { AudioRules.accumulateFrames($0.baseAddress!, channels: perBlock, frames: frames, into: dst) }
            }
        default:
            for k in 0..<blocks {
                let src = buffer.int32ChannelData![k]
                let floats = (0..<samplesPerBlock).map { AudioRules.int32ToFloat(src[$0]) }
                floats.withUnsafeBufferPointer { AudioRules.accumulateFrames($0.baseAddress!, channels: perBlock, frames: frames, into: dst) }
            }
        }
        AudioRules.scale(dst, frames: frames, by: AudioRules.averageFactor(totalChannels: channels))
        return out
    }

    /// Makes a mono Float32 buffer from samples (tests, synthetic signals).
    public static func buffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer {
        let out = AVAudioPCMBuffer(pcmFormat: monoFormat(sampleRate: sampleRate),
                                   frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        out.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { out.floatChannelData![0].update(from: base, count: samples.count) }
        }
        return out
    }

    /// Mono Float32 samples of channel 0 (or of the downmix) as an array.
    public static func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let format = buffer.format
        let plain = AudioRules.isPlainMono(format: Int(format.commonFormat.rawValue), channels: Int(format.channelCount),
                                           interleaved: format.isInterleaved)
        let mono = plain ? buffer : (PCM.mono(buffer) ?? buffer)
        guard let data = mono.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(mono.frameLength)))
    }

    // MARK: Chunking (sizes in AudioRules)

    /// Frames in one chunk of `seconds` at `sampleRate` (at least 1). 100 ms at 48 kHz = 4800.
    public static func framesPerChunk(sampleRate: Double, seconds: Double = AudioRules.chunkSeconds) -> AVAudioFrameCount {
        AVAudioFrameCount(AudioRules.framesPerChunk(sampleRate: sampleRate, seconds: seconds))
    }

    /// Splits `total` frames into consecutive ranges of `chunk` frames; the last one may be shorter.
    public static func chunkRanges(total: Int, chunk: Int) -> [Range<Int>] {
        var start = 0
        return AudioRules.chunkLengths(total: total, chunk: chunk).map { length in
            defer { start += length }
            return start..<(start + length)
        }
    }

    /// Copies a frame range of a deinterleaved Float32 buffer into a new buffer of the same format.
    public static func slice(_ buffer: AVAudioPCMBuffer, _ range: Range<Int>) -> AVAudioPCMBuffer? {
        let format = buffer.format
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              range.lowerBound >= 0, range.upperBound <= Int(buffer.frameLength),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(range.count, 1)))
        else { return nil }
        out.frameLength = AVAudioFrameCount(range.count)
        for c in 0..<Int(format.channelCount) {
            out.floatChannelData![c].update(from: buffer.floatChannelData![c] + range.lowerBound, count: range.count)
        }
        return out
    }

    /// Joins deinterleaved Float32 buffers of one format.
    public static func concat(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let format = buffers.first?.format, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              buffers.allSatisfy({ $0.format.isEqual(format) }) else { return nil }
        let total = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(total, 1))) else { return nil }
        var offset = 0
        for b in buffers {
            let n = Int(b.frameLength)
            for c in 0..<Int(format.channelCount) {
                (out.floatChannelData![c] + offset).update(from: b.floatChannelData![c], count: n)
            }
            offset += n
        }
        out.frameLength = AVAudioFrameCount(total)
        return out
    }

    // MARK: Levels (math in AudioRules)

    /// Root mean square over the mono downmix of the buffer.
    public static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        AudioRules.rms(samples(buffer))
    }

    public static func rms(_ samples: [Float]) -> Float { AudioRules.rms(samples) }

    public static func peak(_ samples: [Float]) -> Float { AudioRules.peak(samples) }

    /// Level in dBFS, floored at -120.
    public static func dBFS(_ rms: Float) -> Float { AudioRules.dBFS(rms) }

    // MARK: Conversion

    /// Stateful converter between two PCM formats (sample rate, channel count, sample type).
    /// Keep one instance per stream so resampling stays continuous across buffers.
    public final class Converter {
        public let inputFormat: AVAudioFormat
        public let outputFormat: AVAudioFormat
        private let converter: AVAudioConverter

        public init?(from input: AVAudioFormat, to output: AVAudioFormat) {
            guard let c = AVAudioConverter(from: input, to: output) else { return nil }
            if AudioRules.converterShouldDownmix(inputChannels: Int(input.channelCount),
                                                 outputChannels: Int(output.channelCount)) { c.downmix = true }
            c.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            self.inputFormat = input
            self.outputFormat = output
            self.converter = c
        }

        /// Converts one buffer. With `final: true` the converter flushes its internal state.
        public func convert(_ buffer: AVAudioPCMBuffer, final: Bool = false) throws -> AVAudioPCMBuffer {
            let capacity = AVAudioFrameCount(AudioRules.conversionCapacity(
                frames: Int(buffer.frameLength), fromRate: inputFormat.sampleRate, toRate: outputFormat.sampleRate))
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw PonteAudioError.unsupportedFormat("cannot allocate \(outputFormat)")
            }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                let input = AudioRules.converterInput(supplied: supplied, final: final)
                inputStatus.pointee = AVAudioConverterInputStatus(rawValue: input) ?? .endOfStream
                guard input == AudioRules.inputHaveData else { return nil }
                supplied = true
                return buffer
            }
            if status == .error {
                throw PonteAudioError.unsupportedFormat(error?.localizedDescription ?? "conversion failed")
            }
            return out
        }

        public func reset() { converter.reset() }
    }

    /// One-shot conversion (resets state each call). Prefer `Converter` for streams.
    public static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format.isEqual(format) { return buffer }
        guard let c = Converter(from: buffer.format, to: format) else {
            throw PonteAudioError.unsupportedFormat("\(buffer.format) → \(format)")
        }
        return try c.convert(buffer, final: true)
    }

    // MARK: Format description

    /// Human-readable summary, e.g. "48000 Hz, 2 ch, Float32, interleaved".
    public static func describe(_ asbd: AudioStreamBasicDescription) -> String {
        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let interleaved = flags & kAudioFormatFlagIsNonInterleaved == 0
        let kind = asbd.mFormatID == kAudioFormatLinearPCM
            ? "\(isFloat ? "Float" : "Int")\(asbd.mBitsPerChannel)" : HAL.fourCC(asbd.mFormatID)
        return "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, \(kind), \(interleaved ? "interleaved" : "non-interleaved")"
    }

    public static func describe(_ format: AVAudioFormat) -> String {
        describe(format.streamDescription.pointee)
    }
}
