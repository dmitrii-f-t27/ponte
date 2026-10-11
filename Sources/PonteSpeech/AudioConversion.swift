import AVFoundation
import Foundation

/// Small PCM helpers shared by the transcriber and the synthesizer.
enum AudioConversion {
    /// A copy of `buffer` that the caller may keep (capture threads reuse their buffers).
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: max(buffer.frameLength, 1)) else {
            return nil
        }
        out.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sp = s.mData, let dp = d.mData else { continue }
            memcpy(dp, sp, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return out
    }

    /// Converts one buffer with a stateful converter (keeps resampler state between calls).
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) throws -> AVAudioPCMBuffer {
        let format = converter.outputFormat
        let capacity = AVAudioFrameCount(SpeechRules.conversionCapacity(
            frames: Int(buffer.frameLength), fromRate: buffer.format.sampleRate, toRate: format.sampleRate))
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw PonteSpeechError.audioConversionFailed("no output buffer for \(format)")
        }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            let input = SpeechRules.converterInput(fed: fed, final: false)
            inputStatus.pointee = AVAudioConverterInputStatus(rawValue: input) ?? .endOfStream
            guard input == SpeechRules.inputHaveData else { return nil }
            fed = true
            return buffer
        }
        if status == .error {
            throw PonteSpeechError.audioConversionFailed(error?.localizedDescription ?? "AVAudioConverter error")
        }
        return out
    }

    /// Drains the frames a resampler still holds at the end of the stream.
    static func flush(_ converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                         frameCapacity: AVAudioFrameCount(SpeechRules.flushFrames)) else { return nil }
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            let input = SpeechRules.converterInput(fed: true, final: true)
            inputStatus.pointee = AVAudioConverterInputStatus(rawValue: input) ?? .endOfStream
            return nil
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    /// Root mean square of the first channel over `count` frames from `from`, samples scaled to -1...1.
    static func rms(_ buffer: AVAudioPCMBuffer, from: Int = 0, count: Int? = nil) -> Float {
        let n = SpeechRules.windowCount(from: from, count: count, frameLength: Int(buffer.frameLength))
        guard n > 0 else { return 0 }
        let stride = buffer.stride
        // The sample type picks the channel-data accessor; the math is in SpeechRules.
        let samples: [Float]
        if let f = buffer.floatChannelData?[0] {
            samples = (from..<(from + n)).map { f[$0 * stride] }
        } else if let s = buffer.int16ChannelData?[0] {
            samples = (from..<(from + n)).map { SpeechRules.int16ToFloat(s[$0 * stride]) }
        } else if let s = buffer.int32ChannelData?[0] {
            samples = (from..<(from + n)).map { SpeechRules.int32ToFloat(s[$0 * stride]) }
        } else {
            return 0
        }
        return SpeechRules.rms(sumOfSquares: SpeechRules.sumSquares(samples), count: n)
    }

    /// Converts any PCM buffers to one Float32 mono buffer at `sampleRate` (nil keeps the source rate).
    static func float32Mono(_ buffers: [AVAudioPCMBuffer], sampleRate: Double? = nil) throws -> AVAudioPCMBuffer? {
        guard let first = buffers.first(where: { $0.frameLength > 0 }) else { return nil }
        let rate = sampleRate ?? first.format.sampleRate
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
            throw PonteSpeechError.audioConversionFailed("no Float32 mono format")
        }
        var parts: [AVAudioPCMBuffer] = []
        var converter: AVAudioConverter?
        for buffer in buffers where buffer.frameLength > 0 {
            if buffer.format == target {
                if let c = copy(buffer) { parts.append(c) }
                continue
            }
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: target)
                converter?.downmix = true
            }
            guard let converter else {
                throw PonteSpeechError.audioConversionFailed("no converter from \(buffer.format)")
            }
            parts.append(try convert(buffer, with: converter))
        }
        if let converter, let tail = flush(converter) { parts.append(tail) }
        return concatenate(parts, format: target)
    }

    /// Joins Float32 non-interleaved buffers of one format.
    static func concatenate(_ parts: [AVAudioPCMBuffer], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let total = parts.reduce(0) { $0 + Int($1.frameLength) }
        guard total > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let dst = out.floatChannelData else { return nil }
        var offset = 0
        for part in parts {
            guard let src = part.floatChannelData else { continue }
            let n = Int(part.frameLength)
            for ch in 0..<Int(format.channelCount) {
                memcpy(dst[ch] + offset, src[ch], n * MemoryLayout<Float>.size)
            }
            offset += n
        }
        out.frameLength = AVAudioFrameCount(offset)
        return out
    }
}
