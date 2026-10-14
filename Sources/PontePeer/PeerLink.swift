import AVFoundation
import CryptoKit
import Foundation
import PonteAudio
import PonteCore

/// «Русские в звонке»: links the Ponte apps of the Russians in one Meet call through a WebSocket relay, so they hear
/// each other's own Russian voice (the Portuguese side never does: it only goes through this link), and each Ponte
/// knows when another one speaks Portuguese into the call, so it does not translate that voice back.
///
/// Everything is end to end encrypted: the room on the relay is SHA-256 of the Meet code, the key AES-GCM from
/// another hash of it; the relay only forwards opaque frames. Plain frame (inside AES-GCM):
///   [kind u8][sender u64 LE][seq u32 LE][payload]
///   audio: 16 kHz mono Int16 LE; voice: [voiceKind u8][state u8][UTF-8 text]; hello, bye: empty.
/// The decisions (status, reconnect backoff, presence, frame size) come from PeerRules (peer_rules.t27).
public final class PeerLink: @unchecked Sendable {
    public struct VoiceEvent: Sendable {
        public let sender: UInt64
        public let kind: Int
        public let state: Int
        public let text: String
        public let receivedAt: Date
    }

    /// Status (PeerRules.status*) and how many other Russians are in the room; on the main queue.
    public var onStatus: ((Int, Int) -> Void)?
    /// Another Ponte speaks into the call (TTS or the owner's own voice) or stopped; on the link queue.
    public var onVoice: ((VoiceEvent) -> Void)?
    /// A frame of another Russian's voice (16 kHz mono Float32); on the link queue.
    public var onAudio: ((UInt64, AVAudioPCMBuffer) -> Void)?

    public let roomID: String
    public let sender = UInt64.random(in: 1...UInt64.max)

    private let url: URL
    private let key: SymmetricKey
    private let queue = DispatchQueue(label: "app.ponte.peer.link")
    private let events = SocketEvents()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: events, delegateQueue: nil)
    private var task: URLSessionWebSocketTask?
    private var running = false
    private var connected = false
    private var failures = 0
    private var seq: UInt32 = 0
    private var peers: [UInt64: Date] = [:]
    private var helloTimer: DispatchSourceTimer?
    private var lastStatus: (Int, Int) = (-1, -1)
    // Microphone → 16 kHz frames.
    private var converter: PCM.Converter?
    private var pendingSamples: [Int16] = []

    /// `relay`: the relay's base URL (wss://host/r/); `meetCode`: the Meet code both Russians entered (abc-defg-hij).
    public init(relay: URL, meetCode: String) {
        let code = meetCode.lowercased()
        roomID = SHA256.hash(data: Data("ponte-room-v1|\(code)".utf8)).map { String(format: "%02x", $0) }.joined()
        key = SymmetricKey(data: SHA256.hash(data: Data("ponte-key-v1|\(code)".utf8)))
        url = relay.appendingPathComponent(roomID)
        events.onOpen = { [weak self] task in
            guard let self else { return }
            self.queue.async {
                guard task === self.task, self.running else { return }
                self.connected = true
                self.failures = 0
                self.send(kind: PeerRules.msgHello, payload: Data())
                self.reportStatus()
            }
        }
        events.onClose = { [weak self] task in
            guard let self else { return }
            self.queue.async { self.dropped(task) }
        }
    }

    deinit { stop() }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            failures = 0
            connect()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(PeerRules.helloEveryMs),
                           repeating: .milliseconds(PeerRules.helloEveryMs))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            helloTimer = timer
            reportStatus()
        }
    }

    public func stop() {
        queue.sync {
            guard running else { return }
            send(kind: PeerRules.msgBye, payload: Data())
            running = false
            helloTimer?.cancel()
            helloTimer = nil
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            connected = false
            peers.removeAll()
            reportStatus()
        }
    }

    // MARK: Sending

    /// The owner's microphone (any rate, mono Float32), already gated by the caller (PeerRules.sendsMic/vadSends).
    /// Called on the capture thread; converts and sends whole frames of PeerRules.frameMs.
    public func sendMicrophone(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let copy = buffer.copy() as? AVAudioPCMBuffer
        queue.async { [self] in
            guard running, connected, let copy else { return }
            let target = PCM.monoFormat(sampleRate: PeerRules.sampleRate)
            if converter == nil || converter?.inputFormat != copy.format {
                converter = PCM.Converter(from: copy.format, to: target)
            }
            guard let converted = try? converter?.convert(copy), let data = converted.floatChannelData else { return }
            for i in 0..<Int(converted.frameLength) {
                let v = max(-1, min(1, data[0][i]))
                pendingSamples.append(Int16(v * Float(Int16.max)))
            }
            let frame = Int(PeerRules.sampleRate) * PeerRules.frameMs / 1000
            while pendingSamples.count >= frame {
                var payload = Data(capacity: frame * 2)
                for s in pendingSamples.prefix(frame) { withUnsafeBytes(of: s.littleEndian) { payload.append(contentsOf: $0) } }
                pendingSamples.removeFirst(frame)
                send(kind: PeerRules.msgAudio, payload: payload)
            }
        }
    }

    /// The microphone stopped going out (muted, key released, silence): drop half a frame instead of sending it later.
    public func flushMicrophone() {
        queue.async { [self] in pendingSamples.removeAll() }
    }

    /// This Ponte starts or stops speaking into the call: PeerRules.voiceTTS with the Portuguese text, or voiceOwn.
    public func sendVoice(kind: Int, state: Int, text: String) {
        queue.async { [self] in
            var payload = Data([UInt8(truncatingIfNeeded: kind), UInt8(truncatingIfNeeded: state)])
            payload.append(Data(text.utf8.prefix(4000)))
            send(kind: PeerRules.msgVoice, payload: payload)
        }
    }

    // MARK: Link (on `queue`)

    private func connect() {
        guard running else { return }
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard task === self.task else { return }
                switch result {
                case .success(let message):
                    if case .data(let data) = message { self.open(data) }
                    self.receive(on: task)
                case .failure:
                    self.dropped(task)
                }
            }
        }
    }

    private func dropped(_ task: URLSessionWebSocketTask) {
        guard running, task === self.task else { return }
        connected = false
        self.task = nil
        failures += 1
        peers.removeAll()
        reportStatus()
        let delay = PeerRules.reconnectDelayMs(attempt: failures - 1)
        queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            guard let self, self.running, self.task == nil else { return }
            self.connect()
        }
    }

    private func tick() {
        guard running else { return }
        send(kind: PeerRules.msgHello, payload: Data())
        let now = Date()
        peers = peers.filter { PeerRules.peerAlive(msSinceHello: Int64(now.timeIntervalSince($0.value) * 1000)) }
        reportStatus()
    }

    private func send(kind: UInt8, payload: Data) {
        guard let task else { return }
        seq &+= 1
        var plain = Data([kind])
        withUnsafeBytes(of: sender.littleEndian) { plain.append(contentsOf: $0) }
        withUnsafeBytes(of: seq.littleEndian) { plain.append(contentsOf: $0) }
        plain.append(payload)
        guard connected, let sealed = try? AES.GCM.seal(plain, using: key).combined else { return }
        task.send(.data(sealed)) { [weak self] error in
            guard let self, error != nil else { return }
            self.queue.async { self.dropped(task) }
        }
    }

    private func open(_ data: Data) {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key), plain.count >= 13 else { return }
        let kind = plain[plain.startIndex]
        let from = plain.subdata(in: plain.startIndex + 1 ..< plain.startIndex + 9).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        let peer = UInt64(littleEndian: from)
        guard peer != sender else { return }
        let payload = plain.subdata(in: plain.startIndex + 13 ..< plain.endIndex)
        let now = Date()
        switch kind {
        case PeerRules.msgBye:
            peers.removeValue(forKey: peer)
            reportStatus()
            return
        default:
            let isNew = peers[peer] == nil
            peers[peer] = now
            if isNew { reportStatus() }
        }
        switch kind {
        case PeerRules.msgAudio:
            let count = payload.count / 2
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: PCM.monoFormat(sampleRate: PeerRules.sampleRate),
                                                           frameCapacity: AVAudioFrameCount(count)),
                  let out = buffer.floatChannelData else { return }
            payload.withUnsafeBytes { raw in
                for i in 0..<count {
                    let s = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                    out[0][i] = Float(s) / Float(Int16.max)
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            onAudio?(peer, buffer)
        case PeerRules.msgVoice:
            guard payload.count >= 2 else { return }
            let text = String(decoding: payload.dropFirst(2), as: UTF8.self)
            onVoice?(VoiceEvent(sender: peer, kind: Int(payload[payload.startIndex]),
                                state: Int(payload[payload.startIndex + 1]), text: text, receivedAt: now))
        default:
            break   // hello: presence only
        }
    }

    private func reportStatus() {
        let status = PeerRules.status(linkOn: running, connected: connected, peers: peers.count, failures: failures)
        let current = (status, peers.count)
        guard current != lastStatus else { return }
        lastStatus = current
        let handler = onStatus
        DispatchQueue.main.async { handler?(current.0, current.1) }
    }
}

/// URLSession reports the socket opening and closing to its delegate only.
private final class SocketEvents: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: ((URLSessionWebSocketTask) -> Void)?
    var onClose: ((URLSessionWebSocketTask) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?(webSocketTask)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose?(webSocketTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let socket = task as? URLSessionWebSocketTask { onClose?(socket) }
    }
}
