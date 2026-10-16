import AVFoundation
import CommonCrypto
import CryptoKit
import Foundation
import PonteAudio
import PonteCore

/// «Русские в звонке»: links the Ponte apps of the Russians in one call through a WebSocket relay, so they hear each
/// other's own Russian voice, and each Ponte knows when another one speaks into the call, so it does not translate
/// that voice back.
///
/// The secret is a code only the Russians share (PeerRules.secretNormalized), never the Meet code, which every
/// participant of the call has. PBKDF2-HMAC-SHA256 (PeerRules.kdfIterations) derives, with two different salts, the
/// room on the relay and the AES-GCM key, so the relay and its logs learn nothing useful. Plain frame (inside AES-GCM):
///   [kind u8][sender u64 LE][seq u32 LE][sent ms i64 LE][payload]
///   audio: 16 kHz mono Int16 LE; voice: [voiceKind u8][state u8][UTF-8 text]; hello, bye: empty.
/// Stale or replayed frames are dropped (PeerRules.frameFresh, seqNewer). A voice still playing is announced again
/// every PeerRules.voiceRefreshMs, so a lost end or a Russian who joins later never leaves a window open for good.
/// The decisions (status, backoff, presence, limits, frame size) come from PeerRules (peer_rules.t27).
public final class PeerLink: @unchecked Sendable {
    public struct VoiceEvent: Sendable {
        public let sender: UInt64
        public let kind: Int
        public let state: Int
        public let text: String
        public let receivedAt: Date

        public init(sender: UInt64, kind: Int, state: Int, text: String, receivedAt: Date) {
            self.sender = sender
            self.kind = kind
            self.state = state
            self.text = text
            self.receivedAt = receivedAt
        }
    }

    /// Status (PeerRules.status*), how many other Pontes announced themselves, and how many connections the relay
    /// counts in the room (this one included; -1 until it says): on the main queue. More connections than Pontes
    /// means someone listens without announcing himself.
    public var onStatus: ((Int, Int, Int) -> Void)?
    /// True: someone in the room never announced himself (PeerRules.unknownListener); false when that is over. On the
    /// main queue.
    public var onListener: ((Bool) -> Void)?
    /// True: the room already has PeerRules.maxPeers members; the link tries again every PeerRules.roomFullRetryMs.
    /// False: a seat was free after all and the link joined. On the main queue.
    public var onRoomFull: ((Bool) -> Void)?
    /// Another Ponte speaks into the call (TTS or the owner's own voice) or stopped; on the link queue.
    public var onVoice: ((VoiceEvent) -> Void)?
    /// A frame of another Russian's voice (16 kHz mono Float32); on the link queue.
    public var onAudio: ((UInt64, AVAudioPCMBuffer) -> Void)?
    /// Another Russian left (bye) or went silent past PeerRules.peerTimeoutMs; on the link queue.
    public var onPeerGone: ((UInt64) -> Void)?

    public let sender = UInt64.random(in: 1...UInt64.max)

    private let relay: URL
    private let secret: String
    private let queue = DispatchQueue(label: "app.ponte.peer.link")
    private let events = SocketEvents()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: events, delegateQueue: nil)
    private var url: URL?
    private var key: SymmetricKey?
    private var task: URLSessionWebSocketTask?
    private var running = false
    private var connected = false
    private var roomFull = false
    private var failures = 0
    private var seq: UInt32 = 0
    private var peers: [UInt64: Date] = [:]
    /// The last frame number of every sender seen in this session (kept after he leaves: no replays).
    private var lastSeq: [UInt64: UInt32] = [:]
    /// Voices of this Ponte still playing into the call: kind → text (announced again on every tick).
    private var activeVoices: [Int: String] = [:]
    private var helloTimer: DispatchSourceTimer?
    private var lastStatus: (Int, Int, Int) = (-1, -1, -1)
    /// Since when the relay has counted more connections than the known peers plus this Ponte.
    private var mismatchSince: Date?
    private var listenerShown = false
    /// Connections in the room as the relay counts them (-1: not told yet).
    private var members = -1
    /// Audio frames handed to the socket and not yet sent (backpressure on a slow uplink).
    private var audioInFlight = 0
    /// Bumped when a socket drops: completions of the old socket's sends no longer count down the new one's frames.
    private var audioGeneration = 0
    // Microphone → 16 kHz frames.
    private var converter: PCM.Converter?
    private var pendingSamples: [Int16] = []

    /// `relay`: the relay's base URL (wss://host/r/); `secret`: the code the Russians share, normalized
    /// (PeerRules.secretNormalized).
    public init(relay: URL, secret: String) {
        self.relay = relay
        self.secret = secret
        events.onOpen = { [weak self] task in
            guard let self else { return }
            self.queue.async { self.opened(task) }
        }
        events.onClose = { [weak self] task, code in
            guard let self else { return }
            self.queue.async { self.dropped(task, closeCode: code) }
        }
    }

    deinit {
        // Nothing else holds the link now: no queue hop (a deinit on `queue` must not wait for `queue`).
        helloTimer?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            roomFull = false
            failures = 0
            reportStatus()
            if key == nil {
                // Slow on purpose (PBKDF2): done once, off the main thread.
                let room = Self.derive(secret, salt: PeerRules.roomSalt)
                key = SymmetricKey(data: Self.derive(secret, salt: PeerRules.keySalt))
                url = relay.appendingPathComponent(room.map { String(format: "%02x", $0) }.joined())
            }
            connect()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let every = PeerRules.tickMs
            timer.schedule(deadline: .now() + .milliseconds(every), repeating: .milliseconds(every))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            helloTimer = timer
        }
    }

    /// Says goodbye and closes; returns at once (the main thread never waits for the link queue).
    public func stop() {
        queue.async { [self] in
            guard running else { return }
            send(kind: PeerRules.msgBye, payload: Data())
            running = false
            helloTimer?.cancel()
            helloTimer = nil
            let closing = task
            task = nil
            connected = false
            peers.removeAll()
            lastSeq.removeAll()
            activeVoices.removeAll()
            members = -1
            reportStatus()
            // Let the bye go out, then close the socket and release the session.
            queue.asyncAfter(deadline: .now() + .milliseconds(PeerRules.byeGraceMs)) { [session] in
                closing?.cancel(with: .goingAway, reason: nil)
                session.finishTasksAndInvalidate()
            }
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
                pendingSamples.append(PeerRules.sampleToInt16(data[0][i]))
            }
            let frame = PeerRules.frameSamples
            while pendingSamples.count >= frame {
                var payload = Data(capacity: frame * 2)
                for s in pendingSamples.prefix(frame) { withUnsafeBytes(of: s.littleEndian) { payload.append(contentsOf: $0) } }
                pendingSamples.removeFirst(frame)
                // A slow uplink: drop live audio rather than let it pile up (late voice is useless).
                guard PeerRules.audioSends(inFlight: audioInFlight) else { continue }
                audioInFlight += 1
                let generation = audioGeneration
                send(kind: PeerRules.msgAudio, payload: payload) { [weak self] in
                    guard let self, self.audioGeneration == generation else { return }
                    self.audioInFlight -= 1
                }
            }
        }
    }

    /// The microphone stopped going out (muted, key released, silence): drop half a frame instead of sending it later.
    public func flushMicrophone() {
        queue.async { [self] in pendingSamples.removeAll() }
    }

    /// This Ponte starts or stops speaking into the call at `at`: PeerRules.voiceTTS with the Portuguese text, or
    /// voiceOwn. A voice that is still playing is announced again on every tick.
    public func sendVoice(kind: Int, state: Int, text: String, at: Date = Date()) {
        queue.async { [self] in
            if state == PeerRules.voiceStart { activeVoices[kind] = text } else { activeVoices.removeValue(forKey: kind) }
            sendVoiceFrame(kind: kind, state: state, text: text, at: at)
        }
    }

    private func sendVoiceFrame(kind: Int, state: Int, text: String, at: Date = Date()) {
        var payload = Data([UInt8(truncatingIfNeeded: kind), UInt8(truncatingIfNeeded: state)])
        withUnsafeBytes(of: Self.ms(at).littleEndian) { payload.append(contentsOf: $0) }
        let utf8 = Array(text.utf8)
        payload.append(Data(utf8.prefix(PeerRules.voiceTextBytes(utf8))))
        send(kind: PeerRules.msgVoice, payload: payload)
    }

    // MARK: Link (on `queue`)

    private func connect() {
        guard running, let url else { return }
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func opened(_ task: URLSessionWebSocketTask) {
        guard task === self.task, running else { return }
        connected = true
        send(kind: PeerRules.msgHello, payload: Data())
        for (kind, text) in activeVoices { sendVoiceFrame(kind: kind, state: PeerRules.voiceStart, text: text) }
        reportStatus()
        // The relay accepts and then closes a full room: failures only count as overcome once the socket held.
        queue.asyncAfter(deadline: .now() + .milliseconds(PeerRules.stableMs)) { [weak self] in
            guard let self, task === self.task, self.connected else { return }
            self.joined()
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard task === self.task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .data(let data): self.open(data)
                    case .string(let text): self.relayNote(text)
                    @unknown default: break
                    }
                    self.receive(on: task)
                case .failure:
                    self.dropped(task, closeCode: task.closeCode.rawValue)
                }
            }
        }
    }

    /// The relay's own plain note: {"members": n}, the connections in the room (it cannot read the frames).
    private func relayNote(_ text: String) {
        guard PeerRules.noteFits(text.utf8.count), let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = object["members"] as? Int, PeerRules.membersValid(n) else { return }
        members = n
        reportStatus()
    }

    /// The socket held or the room answered: failures are overcome and the room has a seat for this Ponte.
    private func joined() {
        guard failures != 0 || roomFull else { return }
        failures = 0
        if roomFull {
            roomFull = false
            let handler = onRoomFull
            DispatchQueue.main.async { handler?(false) }
        }
        reportStatus()
    }

    private func dropped(_ task: URLSessionWebSocketTask, closeCode: Int) {
        guard running, task === self.task else { return }
        connected = false
        self.task = nil
        members = -1
        audioInFlight = 0
        audioGeneration &+= 1
        for peer in peers.keys { onPeerGone?(peer) }
        peers.removeAll()
        let full = PeerRules.roomFull(closeCode: closeCode)
        failures = PeerRules.failuresAfterClose(failures, roomFull: full)
        if full {
            // Shown as failed and full; tried again later (a slept Mac's socket may still hold a seat).
            if !roomFull {
                roomFull = true
                let handler = onRoomFull
                DispatchQueue.main.async { handler?(true) }
            }
        }
        reportStatus()
        let delay = PeerRules.retryDelayMs(closeCode: closeCode, attempt: failures - 1)
        queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            guard let self, self.running, self.task == nil else { return }
            self.connect()
        }
    }

    private func tick() {
        guard running else { return }
        send(kind: PeerRules.msgHello, payload: Data())
        for (kind, text) in activeVoices { sendVoiceFrame(kind: kind, state: PeerRules.voiceStart, text: text) }
        let now = Date()
        let gone = peers.filter { !PeerRules.peerAlive(msSinceHello: PeerRules.millis(now.timeIntervalSince($0.value))) }.keys
        for peer in gone {
            peers.removeValue(forKey: peer)
            onPeerGone?(peer)   // lastSeq stays for the whole session: his old frames cannot be replayed
        }
        reportStatus()
    }

    private func send(kind: UInt8, payload: Data, sent: (() -> Void)? = nil) {
        guard let task, connected, let key else {
            sent?()
            return
        }
        seq &+= 1
        var plain = Data([kind])
        withUnsafeBytes(of: sender.littleEndian) { plain.append(contentsOf: $0) }
        withUnsafeBytes(of: seq.littleEndian) { plain.append(contentsOf: $0) }
        withUnsafeBytes(of: Self.ms(Date()).littleEndian) { plain.append(contentsOf: $0) }
        plain.append(payload)
        guard let sealed = try? AES.GCM.seal(plain, using: key).combined else {
            sent?()
            return
        }
        task.send(.data(sealed)) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                sent?()
                if error != nil { self.dropped(task, closeCode: task.closeCode.rawValue) }
            }
        }
    }

    private func open(_ data: Data) {
        guard let key, let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key), PeerRules.frameComplete(plain.count) else { return }
        let bytes = [UInt8](plain)
        // The header's fields where peer_rules.t27 puts them, little-endian.
        let kind = bytes[PeerRules.hdrKind]
        let peer = Self.uint(bytes, at: PeerRules.hdrSender, count: 8)
        let frameSeq = UInt32(truncatingIfNeeded: Self.uint(bytes, at: PeerRules.hdrSeq, count: 4))
        let sentMs = Int64(bitPattern: Self.uint(bytes, at: PeerRules.hdrSent, count: 8))
        let now = Date()
        guard PeerRules.frameAccepted(isSelf: peer == sender, sentMs: sentMs, nowMs: Self.ms(now)) else { return }
        let last = lastSeq[peer]
        guard PeerRules.seqNewer(seq: frameSeq, lastSeq: last ?? 0, hasLast: last != nil) else { return }
        let known = peers[peer] != nil
        guard PeerRules.frameAdmitted(known: known, kind: kind, knownPeers: peers.count) else { return }
        lastSeq[peer] = frameSeq
        joined()   // the room answers: the link holds
        let payload = Array(bytes[PeerRules.hdrBytes...])
        switch kind {
        case PeerRules.msgBye:
            if peers.removeValue(forKey: peer) != nil { onPeerGone?(peer) }
            reportStatus()
            return
        default:
            peers[peer] = now
            // A Ponte that just joined learns of this one at once, not at its next tick.
            if PeerRules.answersHello(newPeer: !known, kind: kind) { send(kind: PeerRules.msgHello, payload: Data()) }
            reportStatus()
        }
        switch kind {
        case PeerRules.msgAudio:
            let count = PeerRules.audioSamples(payload.count)
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: PCM.monoFormat(sampleRate: PeerRules.sampleRate),
                                                           frameCapacity: AVAudioFrameCount(count)),
                  let out = buffer.floatChannelData else { return }
            for i in 0..<count {
                let s = Int16(bitPattern: UInt16(payload[2 * i]) | UInt16(payload[2 * i + 1]) << 8)
                out[0][i] = AudioRules.int16ToFloat(s)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            onAudio?(peer, buffer)
        case PeerRules.msgVoice:
            guard PeerRules.voiceComplete(payload.count) else { return }
            let atMs = Int64(bitPattern: Self.uint(payload, at: PeerRules.vpAt, count: 8))
            // When it started or ended, on this Mac's clock (the two Macs' clocks need not agree).
            let at = Date(timeIntervalSince1970: Double(PeerRules.voiceLocalMs(atMs: atMs, sentMs: sentMs, nowMs: Self.ms(now))) / 1000)
            let text = String(decoding: payload[PeerRules.vpText...], as: UTF8.self)
            onVoice?(VoiceEvent(sender: peer, kind: Int(payload[PeerRules.vpKind]), state: Int(payload[PeerRules.vpState]),
                                text: text, receivedAt: at))
        default:
            break   // hello: presence only
        }
    }

    /// `count` bytes from `at`, little-endian.
    private static func uint(_ bytes: [UInt8], at: Int, count: Int) -> UInt64 {
        bytes[at..<(at + count)].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }


    private func reportStatus() {
        let now = Date()
        if PeerRules.membersMismatch(members: members, peers: peers.count) {
            if mismatchSince == nil { mismatchSince = now }
        } else {
            mismatchSince = nil
        }
        let since = mismatchSince.map { PeerRules.millis(now.timeIntervalSince($0)) } ?? -1
        let listener = PeerRules.unknownListener(members: members, peers: peers.count, msSinceMismatch: since)
        if listener != listenerShown {
            listenerShown = listener
            let handler = onListener
            DispatchQueue.main.async { handler?(listener) }
        }
        let status = PeerRules.status(linkOn: running, connected: connected, peers: peers.count, failures: failures)
        let current = (status, peers.count, members)
        guard current != lastStatus else { return }
        lastStatus = current
        let handler = onStatus
        DispatchQueue.main.async { handler?(current.0, current.1, current.2) }
    }

    static func ms(_ date: Date) -> Int64 { PeerRules.millis(date.timeIntervalSince1970) }

    /// PBKDF2-HMAC-SHA256 of the secret, 32 bytes.
    static func derive(_ secret: String, salt: String) -> Data {
        var out = [UInt8](repeating: 0, count: PeerRules.keyBytes)
        let password = Array(secret.utf8)
        let saltBytes = Array(salt.utf8)
        _ = password.withUnsafeBufferPointer { p in
            saltBytes.withUnsafeBufferPointer { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     p.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) }, password.count,
                                     s.baseAddress, saltBytes.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(PeerRules.kdfIterations),
                                     &out, out.count)
            }
        }
        return Data(out)
    }
}

/// URLSession reports the socket opening and closing to its delegate only.
private final class SocketEvents: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: ((URLSessionWebSocketTask) -> Void)?
    var onClose: ((URLSessionWebSocketTask, Int) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?(webSocketTask)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose?(webSocketTask, closeCode.rawValue)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let socket = task as? URLSessionWebSocketTask { onClose?(socket, socket.closeCode.rawValue) }
    }
}
