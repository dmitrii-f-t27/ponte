import CryptoKit
import Foundation
import Network
import PonteAudio

/// Ponte's end of the camera link (Specs/camera_rules.t27): a WebSocket server on 127.0.0.1:CM_LINK_PORT for the
/// Ponte Camera extension's service worker. It is written on a plain TCP listener so the handshake's Origin can be
/// checked (CameraRules.originAllowed: only the extension, never a web page). Ponte sends the settings on connect,
/// on every change and every CM_LINK_PING_MS (which keeps the service worker awake); the extension sends how many
/// cameras its Meet pages process. RFC 6455 framing only: text frames from the client, masked, unfragmented, at
/// most CM_LINK_MESSAGE_MAX bytes; anything else closes the connection. All state lives on `queue`.
public final class CameraLink: @unchecked Sendable {
    /// Listening, failed, connected extensions, processed cameras: on the main queue.
    public var onStatus: ((Bool, Bool, Int, Int) -> Void)?

    private let port: UInt16
    private let queue = DispatchQueue(label: "app.ponte.camera.link")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var settings = Data()
    private var listening = false
    private var failed = false
    private var lastStatus: (Bool, Bool, Int, Int)?
    private var pingTimer: DispatchSourceTimer?

    private final class Client {
        let connection: NWConnection
        var buffer = Data()
        var open = false
        var cameras = 0
        init(_ connection: NWConnection) { self.connection = connection }
    }

    public init(port: Int = CameraRules.linkPort) {
        self.port = UInt16(clamping: port)
    }

    deinit {
        pingTimer?.cancel()
        listener?.cancel()
        for client in clients.values { client.connection.cancel() }
    }

    public func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            parameters.allowLocalEndpointReuse = true
            do {
                let listener = try NWListener(using: parameters)
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    self.queue.async { self.listenerChanged(state) }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    self.queue.async { self.accept(connection) }
                }
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                failed = true
                PonteDiagnostics.log("camera link: cannot listen on \(port): \(error)")
                report()
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let every = DispatchTimeInterval.milliseconds(CameraRules.linkPingMs)
            timer.schedule(deadline: .now() + every, repeating: every)
            timer.setEventHandler { [weak self] in self?.broadcast() }
            timer.resume()
            pingTimer = timer
        }
    }

    public func stop() {
        queue.async { [self] in
            pingTimer?.cancel()
            pingTimer = nil
            listener?.cancel()
            listener = nil
            for client in clients.values { client.connection.cancel() }
            clients.removeAll()
            listening = false
            report()
        }
    }

    /// The settings message (JSON) every extension gets now and after every reconnect.
    public func publish(_ message: Data) {
        queue.async { [self] in
            settings = message
            broadcast()
        }
    }

    // MARK: Listener (on `queue`)

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            listening = true
            failed = false
            PonteDiagnostics.log("camera link listening on 127.0.0.1:\(port)")
        case .failed(let error):
            listening = false
            failed = true
            PonteDiagnostics.log("camera link failed: \(error)")
            listener?.cancel()
            listener = nil
        case .cancelled:
            listening = false
        default:
            break
        }
        report()
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        let id = ObjectIdentifier(client)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.queue.async { self.drop(id) }
            default:
                break
            }
        }
        clients[id] = client
        connection.start(queue: queue)
        receive(client)
    }

    private func drop(_ id: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.cancel()
        report()
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.queue.async {
                guard self.clients[ObjectIdentifier(client)] != nil else { return }
                if let data { client.buffer.append(data) }
                if client.open { self.readFrames(client) } else { self.handshake(client) }
                if complete || error != nil {
                    self.drop(ObjectIdentifier(client))
                } else if self.clients[ObjectIdentifier(client)] != nil {
                    self.receive(client)
                }
            }
        }
    }

    // MARK: Handshake

    private func handshake(_ client: Client) {
        guard let end = client.buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if client.buffer.count > CameraRules.linkMessageMax { refuse(client, status: "431 Request Header Fields Too Large") }
            return
        }
        let head = String(decoding: client.buffer[..<end.lowerBound], as: UTF8.self)
        client.buffer.removeSubrange(..<end.upperBound)
        var lines = head.components(separatedBy: "\r\n")
        let request = lines.isEmpty ? "" : lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let others = clients.values.filter { $0.open }.count
        guard request.hasPrefix("GET "),
              headers["upgrade"]?.lowercased() == "websocket",
              let key = headers["sec-websocket-key"], !key.isEmpty else {
            refuse(client, status: "400 Bad Request")
            return
        }
        guard CameraRules.originAllowed(utf8: Array((headers["origin"] ?? "").utf8)) else {
            PonteDiagnostics.log("camera link: refused origin \(headers["origin"] ?? "(none)")")
            refuse(client, status: "403 Forbidden")
            return
        }
        guard CameraRules.linkAccepts(openClients: others) else {
            refuse(client, status: "503 Service Unavailable")
            return
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        client.connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
        client.open = true
        if !settings.isEmpty { send(client, opcode: 0x1, payload: settings) }
        report()
        readFrames(client)
    }

    private func refuse(_ client: Client, status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        client.connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.drop(ObjectIdentifier(client)) }
        })
    }

    // MARK: Frames

    private func readFrames(_ client: Client) {
        while clients[ObjectIdentifier(client)] != nil {
            let b = [UInt8](client.buffer.prefix(14))
            guard b.count >= 2 else { return }
            let fin = b[0] & 0x80 != 0
            let opcode = b[0] & 0x0F
            let masked = b[1] & 0x80 != 0
            var length = Int(b[1] & 0x7F)
            var at = 2
            if length == 126 {
                guard b.count >= 4 else { return }
                length = Int(b[2]) << 8 | Int(b[3])
                at = 4
            } else if length == 127 {
                close(client, code: 1009)   // never this large
                return
            }
            guard fin, masked, length <= CameraRules.linkMessageMax else {
                close(client, code: masked ? 1009 : 1002)
                return
            }
            guard client.buffer.count >= at + 4 + length else { return }
            let start = client.buffer.startIndex
            let mask = [UInt8](client.buffer[(start + at)..<(start + at + 4)])
            var payload = [UInt8](client.buffer[(start + at + 4)..<(start + at + 4 + length)])
            for i in payload.indices { payload[i] ^= mask[i % 4] }
            client.buffer.removeSubrange(start..<(start + at + 4 + length))
            switch opcode {
            case 0x1: message(client, Data(payload))
            case 0x8: close(client, code: 1000); return
            case 0x9: send(client, opcode: 0xA, payload: Data(payload))
            case 0xA: break
            default: close(client, code: 1003); return
            }
        }
    }

    private func message(_ client: Client, _ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["v"] as? Int == CameraRules.linkVersion else { return }
        switch object["type"] as? String {
        case "status":
            client.cameras = CameraRules.linkCameras(object["cameras"] as? Int ?? 0)
            report()
        case "hello":
            PonteDiagnostics.log("camera link: extension \(object["version"] as? String ?? "?") connected")
        default:
            break
        }
    }

    private func send(_ client: Client, opcode: UInt8, payload: Data) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8 & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        }
        frame.append(payload)
        client.connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func close(_ client: Client, code: UInt16) {
        let payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
        var frame = Data([0x88, UInt8(payload.count)])
        frame.append(payload)
        client.connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.drop(ObjectIdentifier(client)) }
        })
        client.open = false
    }

    private func broadcast() {
        guard !settings.isEmpty else { return }
        for client in clients.values where client.open { send(client, opcode: 0x1, payload: settings) }
    }

    private func report() {
        let open = clients.values.filter { $0.open }
        let status = (listening, failed, open.count, open.reduce(0) { $0 + $1.cameras })
        if let last = lastStatus, last == status { return }
        lastStatus = status
        let handler = onStatus
        DispatchQueue.main.async { handler?(status.0, status.1, status.2, status.3) }
    }
}
