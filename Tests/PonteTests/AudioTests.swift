import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import PonteAudio
import PonteCore

// Pure PonteAudio helpers: format conversion, downmix, chunking, grouping. No audio devices used.

private func sine(frequency: Double, amplitude: Float, sampleRate: Double, frames: Int) -> [Float] {
    (0..<frames).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
}

private func approx(_ a: Float, _ b: Float, _ tol: Float = 1e-4) -> Bool { abs(a - b) <= tol }

// MARK: Formats and downmix

@Test func monoFormatIsFloat32Deinterleaved() {
    let f = PCM.monoFormat(sampleRate: 48_000)
    #expect(f.commonFormat == .pcmFormatFloat32)
    #expect(f.channelCount == 1)
    #expect(f.sampleRate == 48_000)
    #expect(!f.isInterleaved)
    #expect(PCM.isMonoFloat32(f))
}

@Test func downmixDeinterleavedStereoAveragesChannels() throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false))
    let buf = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
    buf.frameLength = 4
    let l: [Float] = [1, 0.5, -1, 0]
    let r: [Float] = [0, 0.5, 1, -0.5]
    for i in 0..<4 { buf.floatChannelData![0][i] = l[i]; buf.floatChannelData![1][i] = r[i] }
    let mono = try #require(PCM.mono(buf))
    #expect(mono.format.channelCount == 1)
    #expect(mono.format.sampleRate == 44_100)
    #expect(PCM.samples(mono) == [0.5, 0.5, 0, -0.25])
}

@Test func downmixInterleavedStereoAveragesChannels() throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
    let buf = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
    buf.frameLength = 3
    let interleaved: [Float] = [1, 0, 0.2, 0.4, -1, -0.5]   // L R L R L R
    for i in 0..<6 { buf.floatChannelData![0][i] = interleaved[i] }
    let mono = try #require(PCM.mono(buf))
    let s = PCM.samples(mono)
    #expect(s.count == 3)
    #expect(approx(s[0], 0.5) && approx(s[1], 0.3) && approx(s[2], -0.75))
}

@Test func int16IsScaledToFloat() throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22_050, channels: 1, interleaved: false))
    let buf = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
    buf.frameLength = 3
    buf.int16ChannelData![0][0] = 16_384
    buf.int16ChannelData![0][1] = -32_768
    buf.int16ChannelData![0][2] = 0
    let s = PCM.samples(try #require(PCM.mono(buf)))
    #expect(s == [0.5, -1, 0])
}

@Test func rawBufferListDownmixHandlesInterleavedAndSkipsDisabledStreams() {
    // Two streams: an interleaved stereo stream and a disabled one (mData == NULL), as the HAL may deliver.
    let abl = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(abl.unsafeMutablePointer) }
    var stereo: [Float] = [1, 0, 0.5, 0.5, -1, 1]
    stereo.withUnsafeMutableBytes { raw in
        abl[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
        abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 12, mData: nil)
        #expect(AppAudioTapSource.frameCount(abl.unsafePointer) == 3)
        var out = [Float](repeating: 9, count: 8)
        let n = out.withUnsafeMutableBufferPointer { PCM.downmixFloat32(abl.unsafePointer, into: $0.baseAddress!, maxFrames: 8) }
        #expect(n == 3)
        #expect(Array(out[0..<3]) == [0.5, 0.5, 0])
    }
}

@Test func rawBufferListDownmixSumsDeinterleavedBuffers() {
    let abl = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(abl.unsafeMutablePointer) }
    var left: [Float] = [1, 1, 1, 1]
    var right: [Float] = [0, -1, 1, 0]
    left.withUnsafeMutableBytes { l in
        right.withUnsafeMutableBytes { r in
            abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(l.count), mData: l.baseAddress)
            abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(r.count), mData: r.baseAddress)
            var out = [Float](repeating: 0, count: 2)
            // maxFrames caps the output even when more input is available.
            let n = out.withUnsafeMutableBufferPointer { PCM.downmixFloat32(abl.unsafePointer, into: $0.baseAddress!, maxFrames: 2) }
            #expect(n == 2)
            #expect(out == [0.5, 0])
        }
    }
}

// MARK: Chunking

@Test func chunkSizeIs100msAtNativeRate() {
    #expect(PCM.framesPerChunk(sampleRate: 48_000) == 4_800)
    #expect(PCM.framesPerChunk(sampleRate: 44_100) == 4_410)
    #expect(PCM.framesPerChunk(sampleRate: 22_050) == 2_205)
    #expect(PCM.framesPerChunk(sampleRate: 16_000, seconds: 0.02) == 320)
    #expect(PCM.framesPerChunk(sampleRate: 8, seconds: 0.01) == 1)   // never zero
}

@Test func chunkRangesCoverEverythingOnce() {
    #expect(PCM.chunkRanges(total: 10, chunk: 4) == [0..<4, 4..<8, 8..<10])
    #expect(PCM.chunkRanges(total: 8, chunk: 4) == [0..<4, 4..<8])
    #expect(PCM.chunkRanges(total: 0, chunk: 4).isEmpty)
    #expect(PCM.chunkRanges(total: 5, chunk: 0).isEmpty)
    let ranges = PCM.chunkRanges(total: 70_617, chunk: 2_205)
    #expect(ranges.count == 33)
    #expect(ranges.reduce(0) { $0 + $1.count } == 70_617)
}

@Test func sliceAndConcatRoundTrip() throws {
    let samples = (0..<10).map(Float.init)
    let buf = PCM.buffer(samples, sampleRate: 16_000)
    let parts = PCM.chunkRanges(total: 10, chunk: 3).compactMap { PCM.slice(buf, $0) }
    #expect(parts.map { Int($0.frameLength) } == [3, 3, 3, 1])
    #expect(PCM.samples(parts[1]) == [3, 4, 5])
    let joined = try #require(PCM.concat(parts))
    #expect(PCM.samples(joined) == samples)
    #expect(PCM.slice(buf, 8..<11) == nil)   // out of range
}

// MARK: Levels

@Test func rmsAndPeakOfSine() {
    let s = sine(frequency: 440, amplitude: 0.5, sampleRate: 48_000, frames: 48_000)
    #expect(approx(PCM.rms(s), 0.5 / 2.0.squareRoot().float, 1e-3))
    #expect(approx(PCM.peak(s), 0.5, 1e-3))
    #expect(PCM.rms([Float]()) == 0)
    #expect(PCM.dBFS(0) == -120)
    #expect(approx(PCM.dBFS(1), 0))
    #expect(approx(PCM.dBFS(0.1), -20, 1e-3))
}

// MARK: Conversion

@Test func resampleKeepsDurationAndLevel() throws {
    let input = PCM.buffer(sine(frequency: 300, amplitude: 0.5, sampleRate: 22_050, frames: 22_050), sampleRate: 22_050)
    let out = try PCM.convert(input, to: PCM.monoFormat(sampleRate: 48_000))
    #expect(out.format.sampleRate == 48_000)
    #expect(abs(Int(out.frameLength) - 48_000) <= 48)          // ±1 ms
    let level = PCM.rms(Array(PCM.samples(out)[2_000..<46_000]))  // skip filter edges
    #expect(approx(level, 0.3536, 0.01))
}

@Test func streamingConverterIsContinuousAcrossBuffers() throws {
    let src = sine(frequency: 200, amplitude: 0.5, sampleRate: 16_000, frames: 16_000)
    let full = PCM.buffer(src, sampleRate: 16_000)
    let converter = try #require(PCM.Converter(from: full.format, to: PCM.monoFormat(sampleRate: 48_000)))
    let ranges = PCM.chunkRanges(total: 16_000, chunk: 1_600)
    var outputs: [AVAudioPCMBuffer] = []
    for (i, r) in ranges.enumerated() {
        let piece = try #require(PCM.slice(full, r))
        outputs.append(try converter.convert(piece, final: i == ranges.count - 1))
    }
    let joined = try #require(PCM.concat(outputs.filter { $0.frameLength > 0 }))
    #expect(abs(Int(joined.frameLength) - 48_000) <= 48)
    // No clicks at chunk joints: the largest sample-to-sample step stays that of a clean 200 Hz sine.
    let s = Array(PCM.samples(joined)[1_000..<47_000])
    let maxStep = zip(s, s.dropFirst()).map { abs($1 - $0) }.max() ?? 1
    #expect(maxStep < 0.02)   // 2π·200/48000·0.5 ≈ 0.013
}

@Test func int16StereoToMonoFloatAtNewRate() throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 2, interleaved: true))
    let buf = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
    buf.frameLength = 4_410
    for i in 0..<(4_410 * 2) { buf.int16ChannelData![0][i] = 8_192 }   // DC 0.25 on both channels
    let out = try PCM.convert(buf, to: PCM.monoFormat(sampleRate: 16_000))
    #expect(out.format.channelCount == 1 && out.format.sampleRate == 16_000)
    #expect(abs(Int(out.frameLength) - 1_600) <= 16)
    let mid = Array(PCM.samples(out)[200..<1_400])
    #expect(mid.allSatisfy { abs($0 - 0.25) < 0.01 })
}

@Test func describeFormat() throws {
    #expect(PCM.describe(PCM.monoFormat(sampleRate: 48_000)) == "48000 Hz, 1 ch, Float32, non-interleaved")
    var asbd = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                           mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                           mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
    #expect(PCM.describe(asbd) == "44100 Hz, 2 ch, Int16, interleaved")
    asbd.mFormatID = kAudioFormatMPEG4AAC
    #expect(PCM.describe(asbd).contains("aac"))
}

@Test func fourCharCodes() {
    #expect(HAL.fourCC(kAudioHardwarePropertyProcessObjectList) == "prs#")
    #expect(HAL.fourCC(kAudioTapPropertyFormat) == "tfmt")
    #expect(HAL.fourCC(1) == "1")
}

// MARK: FileSource chunking (temp file, no devices)

@Test func fileSourceDeliversHundredMillisecondChunks() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ponte-audio-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("tone.wav")

    // 1.05 s stereo 16 kHz file: expect 10 chunks of 1600 frames + one of 800, all mono.
    let stereo = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: false))
    let frames = 16_800
    let buf = try #require(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(frames)))
    buf.frameLength = AVAudioFrameCount(frames)
    let tone = sine(frequency: 440, amplitude: 0.4, sampleRate: 16_000, frames: frames)
    for i in 0..<frames { buf.floatChannelData![0][i] = tone[i]; buf.floatChannelData![1][i] = tone[i] }
    do {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buf)
    }

    let source = FileSource(url: url, realtime: false)
    #expect(PCM.isMonoFloat32(source.outputFormat) && source.outputFormat.sampleRate == 16_000)

    final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var sizes: [Int] = []
        var channels: Set<UInt32> = []
        var samples: [Float] = []
    }
    let collected = Collector()
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        source.onFinish = { done.resume() }
        do {
            try source.start { b, _ in
                collected.lock.withLock {
                    collected.sizes.append(Int(b.frameLength))
                    collected.channels.insert(b.format.channelCount)
                    collected.samples += PCM.samples(b)
                }
            }
        } catch {
            Issue.record(error)
            done.resume()
        }
    }
    #expect(collected.sizes == Array(repeating: 1_600, count: 10) + [800])
    #expect(collected.channels == [1])
    #expect(approx(PCM.rms(collected.samples), 0.4 / 2.0.squareRoot().float, 2e-3))

    let whole = try FileSource.readMono(url: url)
    #expect(Int(whole.frameLength) == frames)
}

// MARK: Devices and apps (synthetic data)

private final class FakeCatalog: AudioDeviceCatalog {
    let list: [AudioDevice]
    init(_ list: [AudioDevice]) { self.list = list }
    func devices() -> [AudioDevice] { list }
    func defaultInput() -> AudioDevice? { list.first { $0.inputChannels > 0 } }
    func defaultOutput() -> AudioDevice? { list.first { $0.outputChannels > 0 } }
}

@Test func blackHoleIsFoundOnlyWhenInstalled() {
    let speakers = AudioDevice(id: 1, uid: "spk", name: "MacBook Pro Speakers", inputChannels: 0, outputChannels: 2)
    let mic = AudioDevice(id: 2, uid: "mic", name: "MacBook Pro Microphone", inputChannels: 1, outputChannels: 0)
    #expect(BlackHoleCheck.find(in: FakeCatalog([speakers, mic])) == nil)
    #expect(!BlackHoleCheck.isInstalled(in: FakeCatalog([])))

    let bh16 = AudioDevice(id: 3, uid: "BlackHole16ch_UID", name: "BlackHole 16ch", inputChannels: 16, outputChannels: 16)
    let bh2 = AudioDevice(id: 4, uid: "BlackHole2ch_UID", name: "BlackHole 2ch", inputChannels: 2, outputChannels: 2)
    #expect(BlackHoleCheck.find(in: FakeCatalog([speakers, bh16, bh2]))?.id == 4)   // prefers 2ch
    #expect(BlackHoleCheck.find(in: FakeCatalog([bh16]))?.id == 3)
    let inputOnly = AudioDevice(id: 5, uid: "x", name: "BlackHole 2ch", inputChannels: 2, outputChannels: 0)
    #expect(BlackHoleCheck.find(in: FakeCatalog([inputOnly])) == nil)               // cannot play into it
}

@Test func helperProcessesAreGroupedUnderTheirApp() {
    let chrome = AppOwner(bundleID: "com.google.Chrome", name: "Google Chrome", pid: 100, isRegularApp: true)
    let notes = AppOwner(bundleID: "com.apple.Notes", name: "Notes", pid: 300, isRegularApp: true)
    let daemon = AppOwner(bundleID: "com.apple.CoreSpeech", name: "corespeechd", pid: 400, isRegularApp: false)
    let chime = AppOwner(bundleID: "com.apple.PowerChime", name: "PowerChime", pid: 500, isRegularApp: false)
    let zoom = AppOwner(bundleID: "us.zoom.xos", name: "zoom.us", pid: 600, isRegularApp: true)
    let me = AppOwner(bundleID: "ai.ponte", name: "Ponte", pid: 999, isRegularApp: true)
    let processes = [
        AudioProcessInfo(objectID: 1, pid: 100, bundleID: "com.google.Chrome", isRunningOutput: false, owner: chrome),
        AudioProcessInfo(objectID: 2, pid: 101, bundleID: "com.google.Chrome.helper", isRunningOutput: true, owner: chrome),
        AudioProcessInfo(objectID: 3, pid: 300, bundleID: "com.apple.Notes", isRunningOutput: false, owner: notes),
        AudioProcessInfo(objectID: 4, pid: 400, bundleID: "com.apple.CoreSpeech", isRunningOutput: false, owner: daemon),
        AudioProcessInfo(objectID: 5, pid: 500, bundleID: "com.apple.PowerChime", isRunningOutput: true, owner: chime),
        AudioProcessInfo(objectID: 6, pid: 600, bundleID: "us.zoom.xos", isRunningOutput: false, owner: zoom),
        AudioProcessInfo(objectID: 7, pid: 999, bundleID: "ai.ponte", isRunningOutput: true, owner: me),
    ]
    let apps = RunningAudioAppCatalog.group(processes, selfPID: 999)
    // Playing call app, other playing app, idle call app, idle regular app. Idle daemons and Ponte are hidden.
    #expect(apps.map(\.bundleID) == ["com.google.Chrome", "com.apple.PowerChime", "us.zoom.xos", "com.apple.Notes"])
    let chromeApp = apps[0]
    #expect(chromeApp.pids == [100, 101])
    #expect(chromeApp.isPlayingAudio && chromeApp.isKnownCallApp)
    #expect(chromeApp.name == "Chrome (Meet)")   // known call apps use the label from Contracts
    #expect(apps[3].name == "Notes")

    // The tap target for Chrome covers the helper that actually plays.
    let objects = AudioProcesses.objects(forApp: "com.google.Chrome", in: processes).map(\.objectID)
    #expect(objects == [1, 2])
}

@Test func browserOSMeetIsAKnownCallApp() {
    // Google Meet in BrowserOS neo (Chromium): the helper that plays is grouped under the browser,
    // which is listed first as a known call app with its label.
    let browser = AppOwner(bundleID: "com.browseros.BrowserClaw", name: "BrowserOS neo", pid: 700, isRegularApp: true)
    let notes = AppOwner(bundleID: "com.apple.Notes", name: "Notes", pid: 300, isRegularApp: true)
    let processes = [
        AudioProcessInfo(objectID: 1, pid: 300, bundleID: "com.apple.Notes", isRunningOutput: false, owner: notes),
        AudioProcessInfo(objectID: 2, pid: 700, bundleID: "com.browseros.BrowserClaw", isRunningOutput: false, owner: browser),
        AudioProcessInfo(objectID: 3, pid: 701, bundleID: "com.browseros.BrowserClaw.helper", isRunningOutput: true, owner: browser),
    ]
    let apps = RunningAudioAppCatalog.group(processes, selfPID: 999)
    #expect(apps.map(\.bundleID) == ["com.browseros.BrowserClaw", "com.apple.Notes"])
    #expect(apps[0].isKnownCallApp && apps[0].isPlayingAudio)
    #expect(apps[0].name == "BrowserOS (Meet)")
    #expect(apps[0].pids == [700, 701])
    #expect(AudioApp.knownCallApps["com.browseros.BrowserClaw"] == "BrowserOS (Meet)")
    #expect(AudioRules.isKnownCallApp(bundleID: "com.browseros.BrowserClaw"))
    #expect(!AudioRules.isKnownCallApp(bundleID: "com.browseros.BrowserClaw.helper"))
    #expect(AudioProcesses.objects(forApp: "com.browseros.BrowserClaw", in: processes).map(\.objectID) == [2, 3])
}

@Test func outermostAppBundleOfHelpers() {
    let chromeHelper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/131/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
    #expect(AudioProcesses.outermostAppBundle(in: chromeHelper)?.path == "/Applications/Google Chrome.app")
    #expect(AudioProcesses.outermostAppBundle(in: "/usr/bin/afplay") == nil)
    #expect(AudioProcesses.outermostAppBundle(in: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU") == nil)
}

// MARK: - AudioRules (oracle for the t27 specs: every function, every branch)

@Suite("AudioRules") struct AudioRulesTests {
    typealias R = AudioRules

    // Constants the t27 specs must match.
    @Test func constants() {
        #expect(R.chunkSeconds == 0.1)
        #expect(R.fallbackSampleRate == 48_000)
        #expect(R.dBFSFloor == -120)
        #expect(R.quietThresholdDBFS == -60)
        #expect(R.conversionSlackFrames == 1024)
        #expect(R.reconcileDebounceSeconds == 0.05)
        #expect(R.ponteAggregateUIDPrefix == "ai.ponte.tap.")
        #expect(R.micTapBufferFrames == 2048)
        #expect(R.parentChainMaxDepth == 8)
        #expect(R.int16FullScale == 32_768 && R.int32FullScale == 2_147_483_648)
        #expect(AppAudioTapSource.aggregateUIDPrefix == R.ponteAggregateUIDPrefix)
    }

    @Test func transportCodesMatchCoreAudio() {
        #expect(R.transportBuiltIn == kAudioDeviceTransportTypeBuiltIn)
        #expect(R.transportAggregate == kAudioDeviceTransportTypeAggregate)
        #expect(R.transportVirtual == kAudioDeviceTransportTypeVirtual)
        #expect(R.transportPCI == kAudioDeviceTransportTypePCI)
        #expect(R.transportUSB == kAudioDeviceTransportTypeUSB)
        #expect(R.transportFireWire == kAudioDeviceTransportTypeFireWire)
        #expect(R.transportBluetooth == kAudioDeviceTransportTypeBluetooth)
        #expect(R.transportBluetoothLE == kAudioDeviceTransportTypeBluetoothLE)
        #expect(R.transportHDMI == kAudioDeviceTransportTypeHDMI)
        #expect(R.transportDisplayPort == kAudioDeviceTransportTypeDisplayPort)
        #expect(R.transportAirPlay == kAudioDeviceTransportTypeAirPlay)
        #expect(R.transportAVB == kAudioDeviceTransportTypeAVB)
        #expect(R.transportThunderbolt == kAudioDeviceTransportTypeThunderbolt)
        #expect(R.transportContinuityWired == kAudioDeviceTransportTypeContinuityCaptureWired)
        #expect(R.transportContinuityWireless == kAudioDeviceTransportTypeContinuityCaptureWireless)
    }

    // MARK: Audio math

    @Test func sampleConversion() {
        #expect(R.int16ToFloat(16_384) == 0.5)
        #expect(R.int16ToFloat(-32_768) == -1)
        #expect(R.int16ToFloat(32_767) == Float(32_767) / 32_768)
        #expect(R.int32ToFloat(Int32.min) == -1)
        #expect(R.int32ToFloat(1 << 30) == 0.5)
    }

    @Test func framesInBuffer() {
        #expect(R.framesInBuffer(byteSize: 4096, channels: 2, bytesPerSample: 4) == 512)
        #expect(R.framesInBuffer(byteSize: 4095, channels: 2, bytesPerSample: 4) == 511)   // floor
        #expect(R.framesInBuffer(byteSize: 4096, channels: 0, bytesPerSample: 4) == 0)
        #expect(R.framesInBuffer(byteSize: 4096, channels: 1, bytesPerSample: 0) == 0)
    }

    @Test func downmix() {
        #expect(R.downmixInterleaved([1, 0, 0.5, 0.5, -1, 1], channels: 2) == [0.5, 0.5, 0])
        #expect(R.downmixInterleaved([1, 2, 3, 4, 5], channels: 2) == [1.5, 3.5])        // remainder ignored
        #expect(R.downmixInterleaved([0.25, -0.5], channels: 1) == [0.25, -0.5])         // mono passes through
        #expect(R.downmixInterleaved([1, 2], channels: 0) == [])
        #expect(R.downmixInterleaved([4, 0, 0, 0, 1, 1, 1, 1], channels: 4) == [1, 1])   // sum × Float(1/4), not ÷
        // Bit-exact semantics for C: multiply the Float sum by the Float reciprocal (9 × 0.33333334 ≠ 9 ÷ 3).
        #expect(R.downmixInterleaved([3, 3, 3], channels: 3) == [Float(9) * (Float(1) / Float(3))])
        #expect(R.downmixPlanar([[1, 1, 1], [0, -1, 1]]) == [0.5, 0, 1])
        #expect(R.downmixPlanar([[1, 1, 1], [1]]) == [1])                                 // shortest channel wins
        #expect(R.downmixPlanar([]) == [])
        #expect(R.averageFactor(totalChannels: 0) == 1)
        #expect(R.averageFactor(totalChannels: 1) == 1)
        #expect(R.averageFactor(totalChannels: 2) == 0.5)
        #expect(R.averageFactor(totalChannels: 4) == 0.25)
    }

    @Test func accumulateAndScaleInPlace() {
        var dst: [Float] = [1, 1, 1]
        let src: [Float] = [1, 2, 3, 4, 5, 6]
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                R.accumulateFrames(s.baseAddress!, channels: 2, frames: 3, into: d.baseAddress!)
                R.scale(d.baseAddress!, frames: 3, by: 0.5)
            }
        }
        #expect(dst == [2, 4, 6])   // (1 + 1+2)/2, (1 + 3+4)/2, (1 + 5+6)/2
    }

    @Test func gainAndClip() {
        #expect(R.clamp(2, -1, 1) == 1 && R.clamp(-2, -1, 1) == -1 && R.clamp(0.3, -1, 1) == 0.3)
        #expect(R.clampUnit(-0.5) == 0 && R.clampUnit(1.5) == 1 && R.clampUnit(0.7) == 0.7)
        #expect(R.gainClip(0.4, gain: 2) == 0.8)
        #expect(R.gainClip(0.8, gain: 2) == 1)
        #expect(R.gainClip(-0.8, gain: 2) == -1)
        #expect(R.applyGain([0.1, -0.6, 0.6], gain: 2) == [0.2, -1, 1])
    }

    @Test func levels() {
        #expect(R.rmsFromSum(sumSquares: 4, count: 4) == 1)
        #expect(R.rmsFromSum(sumSquares: 1, count: 0) == 0)
        #expect(R.rms([3, -4, 0, 0]) == 2.5)
        #expect(R.rms([Float]()) == 0)
        #expect(R.peak([0.1, -0.7, 0.3]) == 0.7)
        #expect(R.peak([Float]()) == 0)
        #expect(R.dBFS(1) == 0)
        #expect(approx(R.dBFS(0.1), -20, 1e-4))
        #expect(R.dBFS(0) == -120 && R.dBFS(-1) == -120)
        #expect(R.dBFS(1e-9) == -120)                       // floored
    }

    @Test func levelCodes() {
        #expect(R.levelCode(peak: 0, rms: 0) == R.levelDigitalSilence)
        #expect(R.levelCode(peak: 0.0005, rms: 0.0005) == R.levelQuiet)   // -66 dBFS
        #expect(R.levelCode(peak: 0.002, rms: 0.001) == R.levelSignal)    // -60 dBFS exactly is not quiet
        #expect(R.levelCode(peak: 0.5, rms: 0.2) == R.levelSignal)
        #expect([R.levelDigitalSilence, R.levelQuiet, R.levelSignal] == [0, 1, 2] as [Int])
        #expect(R.tapSilenceSuspect(totalFrames: 1000, peak: 0))
        #expect(!R.tapSilenceSuspect(totalFrames: 0, peak: 0))
        #expect(!R.tapSilenceSuspect(totalFrames: 1000, peak: 0.01))
    }

    @Test func ratesAndChunks() {
        #expect(R.rateOrDefault(44_100) == 44_100 && R.rateOrDefault(0) == 48_000 && R.rateOrDefault(-1) == 48_000)
        #expect(R.framesPerChunk(sampleRate: 48_000) == 4_800)
        #expect(R.framesPerChunk(sampleRate: 22_050) == 2_205)
        #expect(R.framesPerChunk(sampleRate: 11_025) == 1_103)              // 1102.5 rounds half away from zero
        #expect(R.framesPerChunk(sampleRate: 16_000, seconds: 0.02) == 320)
        #expect(R.framesPerChunk(sampleRate: 0) == 1)
        #expect(R.chunkLengths(total: 10, chunk: 4) == [4, 4, 2])
        #expect(R.chunkLengths(total: 8, chunk: 4) == [4, 4])
        #expect(R.chunkLengths(total: 0, chunk: 4) == [] && R.chunkLengths(total: 3, chunk: 0) == [])
        #expect(R.conversionCapacity(frames: 22_050, fromRate: 22_050, toRate: 48_000) == 48_000 + 1024)
        #expect(R.conversionCapacity(frames: 1, fromRate: 44_100, toRate: 48_000) == 2 + 1024)   // ceil
        #expect(R.conversionCapacity(frames: 10, fromRate: 0, toRate: 48_000) == 10 + 1024)
        #expect(R.needsResample(fromRate: 48_000, toRate: 44_100) && !R.needsResample(fromRate: 48_000, toRate: 48_000))
        #expect(R.converterShouldDownmix(inputChannels: 2, outputChannels: 1))
        #expect(!R.converterShouldDownmix(inputChannels: 1, outputChannels: 2))
        #expect(R.sessionRate(fixedRate: 0, tapRate: 44_100) == 44_100)
        #expect(R.sessionRate(fixedRate: 48_000, tapRate: 44_100) == 48_000)
    }

    @Test func pacing() {
        // Chunk ending at frame 4800 at 48 kHz is due 100 ms after start.
        #expect(R.pacingSleepNanos(startNanos: 1_000, nowNanos: 1_000, endFrame: 4_800, sampleRate: 48_000) == 100_000_000)
        #expect(R.pacingSleepNanos(startNanos: 0, nowNanos: 40_000_000, endFrame: 4_800, sampleRate: 48_000) == 60_000_000)
        #expect(R.pacingSleepNanos(startNanos: 0, nowNanos: 200_000_000, endFrame: 4_800, sampleRate: 48_000) == 0)
        #expect(R.pacingSleepNanos(startNanos: 0, nowNanos: 0, endFrame: 4_800, sampleRate: 0) == 0)
    }

    @Test func conversionPathAndTapFormat() {
        #expect(R.conversionPath(sameFormat: true, sameRate: true) == R.convertNone)
        #expect(R.conversionPath(sameFormat: false, sameRate: true) == R.convertDownmix)
        #expect(R.conversionPath(sameFormat: false, sameRate: false) == R.convertResample)
        #expect([R.convertNone, R.convertDownmix, R.convertResample] == [0, 1, 2] as [Int])
        #expect(R.isUsableTapFormat(isLinearPCM: true, isFloat: true, bitsPerChannel: 32, sampleRate: 48_000))
        #expect(!R.isUsableTapFormat(isLinearPCM: true, isFloat: false, bitsPerChannel: 16, sampleRate: 48_000))
        #expect(!R.isUsableTapFormat(isLinearPCM: false, isFloat: true, bitsPerChannel: 32, sampleRate: 48_000))
        #expect(!R.isUsableTapFormat(isLinearPCM: true, isFloat: true, bitsPerChannel: 64, sampleRate: 48_000))
        #expect(!R.isUsableTapFormat(isLinearPCM: true, isFloat: true, bitsPerChannel: 32, sampleRate: 0))
    }

    // MARK: Tap lifecycle and permission

    @Test func tapActions() {
        #expect([R.tapKeep, R.tapWait, R.tapUpdate, R.tapRebuild] == [0, 1, 2, 3] as [Int])
        // start (force, not attached)
        #expect(R.tapAction(attached: false, desiredCount: 2, sameSet: false, isGlobal: false, force: true) == R.tapRebuild)
        #expect(R.tapAction(attached: false, desiredCount: 0, sameSet: false, isGlobal: false, force: true) == R.tapWait)
        #expect(R.tapAction(attached: false, desiredCount: 0, sameSet: false, isGlobal: true, force: true) == R.tapRebuild)
        // process list changes while attached
        #expect(R.tapAction(attached: true, desiredCount: 2, sameSet: true, isGlobal: false, force: false) == R.tapKeep)
        #expect(R.tapAction(attached: true, desiredCount: 3, sameSet: false, isGlobal: false, force: false) == R.tapUpdate)
        #expect(R.tapAction(attached: true, desiredCount: 0, sameSet: false, isGlobal: false, force: false) == R.tapWait)
        #expect(R.tapAction(attached: true, desiredCount: 1, sameSet: false, isGlobal: true, force: false) == R.tapUpdate)
        // waiting for the app
        #expect(R.tapAction(attached: false, desiredCount: 0, sameSet: true, isGlobal: false, force: false) == R.tapKeep)
        #expect(R.tapAction(attached: false, desiredCount: 1, sameSet: false, isGlobal: false, force: false) == R.tapRebuild)
        // format changed
        #expect(R.tapAction(attached: true, desiredCount: 2, sameSet: true, isGlobal: false, force: true) == R.tapRebuild)
        #expect(R.tapAction(attached: true, desiredCount: 0, sameSet: false, isGlobal: false, force: true) == R.tapWait)
    }

    @Test func micPermission() {
        #expect(AVAuthorizationStatus.notDetermined.rawValue == 0 && AVAuthorizationStatus.authorized.rawValue == 3)
        #expect(R.micStartDecision(authorizationStatus: 3) == R.micStart)
        #expect(R.micStartDecision(authorizationStatus: 0) == R.micRequestFirst)
        #expect(R.micStartDecision(authorizationStatus: 1) == R.micDenied)
        #expect(R.micStartDecision(authorizationStatus: 2) == R.micDenied)
        #expect(R.micStartDecision(authorizationStatus: 99) == R.micDenied)
    }

    // MARK: Devices

    @Test func deviceKinds() {
        func kind(_ name: String, _ uid: String, _ t: UInt32, _ i: Int, _ o: Int) -> Int {
            R.deviceKind(name: name, uid: uid, transportType: t, inputChannels: i, outputChannels: o)
        }
        #expect(kind("MacBook Pro Speakers", "BuiltInSpeakerDevice", R.transportBuiltIn, 0, 2) == R.kindBuiltInSpeaker)
        #expect(kind("External Headphones", "BuiltInHeadphoneOutputDevice", R.transportBuiltIn, 0, 2) == R.kindBuiltInHeadphones)
        #expect(kind("MacBook Pro Microphone", "BuiltInMicrophoneDevice", R.transportBuiltIn, 1, 0) == R.kindBuiltInMic)
        #expect(kind("Odd", "x", R.transportBuiltIn, 0, 0) == R.kindUnknown)
        #expect(kind("BlackHole 2ch", "BlackHole2ch_UID", R.transportVirtual, 2, 2) == R.kindBlackHole)
        #expect(kind("Ponte Tap", "ai.ponte.tap.123", R.transportAggregate, 2, 0) == R.kindPonteAggregate)
        #expect(kind("S6-L", "296C1429", R.transportBluetooth, 0, 2) == R.kindBluetooth)
        #expect(kind("AirPods", "a", R.transportBluetoothLE, 1, 2) == R.kindBluetooth)
        #expect(kind("USB Audio", "u", R.transportUSB, 2, 2) == R.kindUSB)
        #expect(kind("LG", "h", R.transportHDMI, 0, 2) == R.kindDisplay)
        #expect(kind("Studio Display", "d", R.transportDisplayPort, 0, 2) == R.kindDisplay)
        #expect(kind("TV", "t", R.transportAirPlay, 0, 2) == R.kindAirPlay)
        #expect(kind("Multi-Output", "m", R.transportAggregate, 0, 2) == R.kindAggregate)
        #expect(kind("ZoomAudioDevice", "z", R.transportVirtual, 2, 2) == R.kindVirtual)
        #expect(kind("iPhone Microphone", "c", R.transportContinuityWireless, 1, 0) == R.kindContinuity)
        #expect(kind("Interface", "p", R.transportThunderbolt, 2, 2) == R.kindOtherWired)
        #expect(kind("?", "?", 0, 1, 1) == R.kindUnknown)
    }

    @Test func echoRiskByKind() {
        #expect(R.echoRisk(kind: R.kindBuiltInSpeaker) == R.echoSpeaker)
        #expect(R.echoRisk(kind: R.kindDisplay) == R.echoSpeaker)
        #expect(R.echoRisk(kind: R.kindAirPlay) == R.echoSpeaker)
        #expect(R.echoRisk(kind: R.kindBuiltInHeadphones) == R.echoNone)
        #expect(R.echoRisk(kind: R.kindBlackHole) == R.echoNone)
        #expect(R.echoRisk(kind: R.kindVirtual) == R.echoNone)
        #expect(R.echoRisk(kind: R.kindBluetooth) == R.echoMaybe)
        #expect(R.echoRisk(kind: R.kindUSB) == R.echoMaybe)
        #expect(R.echoRisk(kind: R.kindUnknown) == R.echoMaybe)
    }

    @Test func nameRules() {
        #expect(R.isBlackHole(name: "BlackHole 2ch") && R.isBlackHole(name: "blackhole 16ch") && R.isBlackHole(name: "My BLACKHOLE"))
        #expect(!R.isBlackHole(name: "Black Hole") && !R.isBlackHole(name: "MacBook Pro Speakers"))
        #expect(R.isPonteAggregate(uid: "ai.ponte.tap.ABC") && !R.isPonteAggregate(uid: "ai.ponte.ta"))
        #expect(R.containsCI("MacBook Pro Speakers", "pro sp") && R.containsCI("x", "") && !R.containsCI("ab", "abc"))
        #expect(R.foldedBytes("AbZ-ç") == Array("abz-ç".utf8))   // only ASCII letters fold
    }

    @Test func devicePicks() {
        let k = R.self
        // BlackHole: prefer 2ch, must have outputs.
        #expect(R.pickBlackHoleIndex(names: ["MacBook Pro Speakers", "BlackHole 16ch", "BlackHole 2ch"], outputChannels: [2, 16, 2]) == 2)
        #expect(R.pickBlackHoleIndex(names: ["BlackHole 16ch"], outputChannels: [16]) == 0)
        #expect(R.pickBlackHoleIndex(names: ["BlackHole 2ch"], outputChannels: [0]) == -1)
        #expect(R.pickBlackHoleIndex(names: [], outputChannels: []) == -1)
        // Mic: default unless excluded; then built-in mic; then any input.
        let kinds = [k.kindBlackHole, k.kindUSB, k.kindBuiltInMic, k.kindBuiltInSpeaker]
        #expect(R.pickMicIndex(kinds: kinds, inputChannels: [2, 1, 1, 0], defaultIndex: 1) == 1)
        #expect(R.pickMicIndex(kinds: kinds, inputChannels: [2, 1, 1, 0], defaultIndex: 0) == 2)
        #expect(R.pickMicIndex(kinds: kinds, inputChannels: [2, 1, 0, 0], defaultIndex: 0) == 1)
        #expect(R.pickMicIndex(kinds: kinds, inputChannels: [2, 0, 0, 0], defaultIndex: -1) == -1)
        // Listen output: default unless BlackHole; then headphones > Bluetooth > USB > speaker.
        let outs = [k.kindBlackHole, k.kindBuiltInSpeaker, k.kindUSB, k.kindBluetooth, k.kindBuiltInHeadphones]
        #expect(R.pickListenOutputIndex(kinds: outs, outputChannels: [2, 2, 2, 2, 2], defaultIndex: 1) == 1)
        #expect(R.pickListenOutputIndex(kinds: outs, outputChannels: [2, 2, 2, 2, 2], defaultIndex: 0) == 4)
        #expect(R.pickListenOutputIndex(kinds: outs, outputChannels: [2, 2, 2, 2, 0], defaultIndex: 0) == 3)
        #expect(R.pickListenOutputIndex(kinds: outs, outputChannels: [2, 2, 2, 0, 0], defaultIndex: 0) == 2)
        #expect(R.pickListenOutputIndex(kinds: outs, outputChannels: [2, 2, 0, 0, 0], defaultIndex: 9) == 1)
        #expect(R.pickListenOutputIndex(kinds: [k.kindVirtual], outputChannels: [2], defaultIndex: -1) == 0)
        #expect(R.pickListenOutputIndex(kinds: [k.kindBlackHole], outputChannels: [2], defaultIndex: 0) == -1)
        // Lookup: UID, exact name, substring.
        let names = ["MacBook Pro Speakers", "S6-L", "MacBook Pro Microphone"]
        let uids = ["BuiltInSpeakerDevice", "296C", "BuiltInMicrophoneDevice"]
        #expect(R.matchDeviceIndex(query: "296C", names: names, uids: uids) == 1)
        #expect(R.matchDeviceIndex(query: "S6-L", names: names, uids: uids) == 1)
        #expect(R.matchDeviceIndex(query: "microphone", names: names, uids: uids) == 2)
        #expect(R.matchDeviceIndex(query: "macbook", names: names, uids: uids) == 0)
        #expect(R.matchDeviceIndex(query: "BlackHole", names: names, uids: uids) == -1)
    }

    // MARK: App catalog

    @Test func knownCallAppsMatchContracts() {
        #expect(R.knownCallAppBundleIDs == AudioApp.knownCallApps.keys.sorted())
        #expect(R.knownCallAppBundleIDs.count == R.knownCallAppLabels.count)
        for (i, bid) in R.knownCallAppBundleIDs.enumerated() {
            #expect(R.knownCallAppLabels[i] == AudioApp.knownCallApps[bid])
            #expect(R.knownCallAppIndex(bundleID: bid) == i)
        }
        #expect(R.knownCallAppIndex(bundleID: "com.google.Chrome.helper") == -1)
        #expect(R.isKnownCallApp(bundleID: "us.zoom.xos") && !R.isKnownCallApp(bundleID: "com.apple.Music"))
    }

    @Test func helperToParentByPrefix() {
        let apps = ["com.google.Chrome", "com.google", "com.apple.Safari", ""]
        #expect(R.parentAppIndex(helperBundleID: "com.google.Chrome.helper", appBundleIDs: apps) == 0)   // longest wins
        #expect(R.parentAppIndex(helperBundleID: "com.google.Chrome.helper.Renderer", appBundleIDs: apps) == 0)
        #expect(R.parentAppIndex(helperBundleID: "com.google.ChromeX", appBundleIDs: apps) == 1)
        #expect(R.parentAppIndex(helperBundleID: "com.google.Chrome", appBundleIDs: apps) == 1)          // not its own parent
        #expect(R.parentAppIndex(helperBundleID: "com.apple.WebKit.GPU", appBundleIDs: apps) == -1)
    }

    @Test func appBundlePath() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/131/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        #expect(R.outermostAppPathLength(helper) == "/Applications/Google Chrome.app".utf8.count)
        #expect(R.outermostAppPathLength("/Applications/zoom.us.app") == "/Applications/zoom.us.app".utf8.count)
        #expect(R.outermostAppPathLength("/Applications/Téléphone.app/Contents/MacOS/x") == "/Applications/Téléphone.app".utf8.count)
        #expect(R.outermostAppPathLength("/usr/bin/afplay") == -1)
        #expect(R.outermostAppPathLength("/Apps/My.application/x") == -1)
        #expect(R.outermostAppPathLength("/x/.app/y") == -1)
        #expect(R.outermostAppPathLength("/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU") == -1)
    }

    @Test func ownerSourceOrder() {
        #expect([R.ownerSelf, R.ownerAppBundlePath, R.ownerResponsible, R.ownerParent, R.ownerBundlePrefix, R.ownerFallback] == [1, 2, 3, 4, 5, 6] as [Int])
        #expect(R.ownerSource(selfIsRegularApp: true, hasAppBundlePath: true, hasResponsibleApp: true, hasRegularParentApp: true, hasPrefixParent: true) == R.ownerSelf)
        #expect(R.ownerSource(selfIsRegularApp: false, hasAppBundlePath: true, hasResponsibleApp: true, hasRegularParentApp: true, hasPrefixParent: true) == R.ownerAppBundlePath)
        #expect(R.ownerSource(selfIsRegularApp: false, hasAppBundlePath: false, hasResponsibleApp: true, hasRegularParentApp: true, hasPrefixParent: true) == R.ownerResponsible)
        #expect(R.ownerSource(selfIsRegularApp: false, hasAppBundlePath: false, hasResponsibleApp: false, hasRegularParentApp: true, hasPrefixParent: true) == R.ownerParent)
        #expect(R.ownerSource(selfIsRegularApp: false, hasAppBundlePath: false, hasResponsibleApp: false, hasRegularParentApp: false, hasPrefixParent: true) == R.ownerBundlePrefix)
        #expect(R.ownerSource(selfIsRegularApp: false, hasAppBundlePath: false, hasResponsibleApp: false, hasRegularParentApp: false, hasPrefixParent: false) == R.ownerFallback)
    }

    @Test func tapTargets() {
        #expect(R.isTapTargetProcess(processBundleID: "com.google.Chrome.helper", ownerBundleID: "com.google.Chrome", targetBundleID: "com.google.Chrome", pid: 5, selfPID: 9))
        #expect(R.isTapTargetProcess(processBundleID: "us.zoom.xos", ownerBundleID: "com.apple.Terminal", targetBundleID: "us.zoom.xos", pid: 5, selfPID: 9))
        #expect(R.isTapTargetProcess(processBundleID: "com.apple.avconferenced", ownerBundleID: "com.apple.avconferenced", targetBundleID: "com.apple.FaceTime", pid: 5, selfPID: 9))
        #expect(R.isTapTargetProcess(processBundleID: "com.apple.TelephonyUtilities", ownerBundleID: "x", targetBundleID: "com.apple.FaceTime", pid: 5, selfPID: 9))
        #expect(!R.isTapTargetProcess(processBundleID: "com.apple.avconferenced", ownerBundleID: "x", targetBundleID: "us.zoom.xos", pid: 5, selfPID: 9))
        #expect(!R.isTapTargetProcess(processBundleID: "com.google.Chrome", ownerBundleID: "com.google.Chrome", targetBundleID: "com.google.Chrome", pid: 9, selfPID: 9))
        #expect(!R.isTapTargetProcess(processBundleID: "", ownerBundleID: "x", targetBundleID: "", pid: 5, selfPID: 9))
        #expect(R.isCompanionProcess(processBundleID: "com.apple.avconferenced", targetBundleID: "com.apple.FaceTime"))
        #expect(!R.isCompanionProcess(processBundleID: "com.apple.FaceTime", targetBundleID: "com.apple.avconferenced"))
    }

    @Test func listingAndOrder() {
        #expect(R.isSelfProcess(pid: 9, ownerPID: 1, selfPID: 9) && R.isSelfProcess(pid: 5, ownerPID: 9, selfPID: 9))
        #expect(!R.isSelfProcess(pid: 5, ownerPID: 6, selfPID: 9))
        #expect(R.shouldListApp(isRegularApp: true, isPlaying: false, isKnownCallApp: false))
        #expect(R.shouldListApp(isRegularApp: false, isPlaying: true, isKnownCallApp: false))
        #expect(R.shouldListApp(isRegularApp: false, isPlaying: false, isKnownCallApp: true))
        #expect(!R.shouldListApp(isRegularApp: false, isPlaying: false, isKnownCallApp: false))
        #expect(R.appRank(isKnownCallApp: true, isPlaying: true) == 0)
        #expect(R.appRank(isKnownCallApp: false, isPlaying: true) == 1)
        #expect(R.appRank(isKnownCallApp: true, isPlaying: false) == 2)
        #expect(R.appRank(isKnownCallApp: false, isPlaying: false) == 3)
        // rank, then case-folded name, then original index
        #expect(R.appSortOrder(ranks: [3, 0, 3, 3, 1, 3], names: ["notes", "Zoom", "Music", "Notes", "x", "notes"]) == [1, 4, 2, 0, 3, 5])
        #expect(R.appSortOrder(ranks: [], names: []) == [])
    }
}

private extension Double {
    var float: Float { Float(self) }
}
