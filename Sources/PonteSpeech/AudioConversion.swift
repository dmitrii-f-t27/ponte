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
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw PonteSpeechError.audioConversionFailed("no output buffer for \(format)")
        }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw PonteSpeechError.audioConversionFailed(error?.localizedDescription ?? "AVAudioConverter error")
        }
        return out
    }

    /// Drains the frames a resampler still holds at the end of the stream.
    static func flush(_ converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4096) else { return nil }
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    /// Root mean square of the first channel over `count` frames from `from`, samples scaled to -1...1.
    static func rms(_ buffer: AVAudioPCMBuffer, from: Int = 0, count: Int? = nil) -> Float {
        let n = min(count ?? Int(buffer.frameLength), Int(buffer.frameLength) - from)
        guard n > 0, from >= 0 else { return 0 }
        let stride = buffer.stride
        var sum: Float = 0
        if let f = buffer.floatChannelData?[0] {
            for i in from..<(from + n) { let v = f[i * stride]; sum += v * v }
        } else if let s = buffer.int16ChannelData?[0] {
            for i in from..<(from + n) { let v = Float(s[i * stride]) / 32768; sum += v * v }
        } else if let s = buffer.int32ChannelData?[0] {
            for i in from..<(from + n) { let v = Float(s[i * stride]) / 2147483648; sum += v * v }
        } else {
            return 0
        }
        return (sum / Float(n)).squareRoot()
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
