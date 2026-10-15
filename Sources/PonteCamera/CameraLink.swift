import CryptoKit
import Foundation
import Network
import PonteAudio

/// What a Meet page reported as its last failure (Specs/camera_rules.t27: the stage, the renderer, the
/// DOMException's name and message, cleaned by cm_report_clean).
public struct CameraLinkError: Equatable, Sendable {
    public let stage: Int
    public let renderer: Int
    public let name: String
    public let message: String

    public init(stage: Int, renderer: Int, name: String, message: String) {
        self.stage = stage
        self.renderer = renderer
        self.name = name
        self.message = message
    }
}

/// The link's state for the panel: the listener, the connected extensions, and their Meet pages' cameras —
/// processed, passing as they came, in trouble — with the last error a page reported.
public struct CameraLinkStatus: Equatable, Sendable {
    public var listening = false
    public var failed = false
    public var clients = 0
    public var processed = 0
    public var passing = 0
    public var troubled = 0
    public var error: CameraLinkError?

    public init() {}

    /// The panel's status code (CameraRules.linkPanel).
    public var code: Int {
        CameraRules.linkPanel(listening: listening, failed: failed, clients: clients, processed: processed,
                              passing: passing, troubled: troubled)
    }
}

/// Ponte's end of the camera link (Specs/camera_rules.t27): a WebSocket server on 127.0.0.1:CM_LINK_PORT for the
/// Ponte Camera extension's service worker. It is written on a plain TCP listener so the handshake's Origin can be
/// checked (CameraRules.originAllowed: only the extension, never a web page). Ponte sends the settings on connect,
/// on every change and every CM_LINK_PING_MS (which keeps the service worker awake); the extension sends its Meet
/// pages' cameras and their last error. RFC 6455 framing only, every check and answer from the spec
/// (cm_ws_handshake_status, cm_ws_frame_close, cm_ws_opcode_action): text frames from the client, masked,
/// unfragmented, at most CM_LINK_MESSAGE_MAX bytes; anything else closes the connection. All state lives on `queue`.
public final class CameraLink: @unchecked Sendable {
    /// The link's state, on the main queue, on every change.
    public var onStatus: ((CameraLinkStatus) -> Void)?

    private let port: UInt16
    private let queue = DispatchQueue(label: "app.ponte.camera.link")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var settings = Data()
    private var listening = false
    private var failed = false
    private var lastStatus: CameraLinkStatus?
    private var lastLoggedError: CameraLinkError?
    private var pingTimer: DispatchSourceTimer?

    private final class Client {
        let connection: NWConnection
        var buffer = Data()
        var open = false
        var processed = 0
        var passing = 0
        var troubled = 0
        var error: CameraLinkError?
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
        guard CameraRules.linkTakesConnection(clients.count) else {
            connection.cancel()
            return
        }
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
        // A handshake not finished in time closes the connection.
        let accepted = Date()
        queue.asyncAfter(deadline: .now() + .milliseconds(CameraRules.linkHandshakeMs)) { [weak self, weak client] in
            guard let self, let client, !client.open, self.clients[id] != nil else { return }
            if CameraRules.linkHandshakeExpired(msSinceAccept: AudioRules.millis(Date().timeIntervalSince(accepted))) {
                self.drop(id)
            }
        }
    }

    private func drop(_ id: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.cancel()
        report()
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: CameraRules.linkReadMax) { [weak self] data, _, complete, error in
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

    /// The status line of an HTTP answer (CM_HTTP_*).
    private static func statusLine(_ code: Int) -> String {
        switch code {
        case CameraRules.httpBadRequest: return "400 Bad Request"
        case CameraRules.httpForbidden: return "403 Forbidden"
        case CameraRules.httpTooLarge: return "431 Request Header Fields Too Large"
        case CameraRules.httpBusy: return "503 Service Unavailable"
        default: return "\(code) Error"
        }
    }

    private func handshake(_ client: Client) {
        guard let end = client.buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if CameraRules.wsHeadTooLarge(client.buffer.count) { refuse(client, status: CameraRules.httpTooLarge) }
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
        let key = headers["sec-websocket-key"] ?? ""
        let status = CameraRules.wsHandshakeStatus(
            isGet: request.hasPrefix("GET "), upgrade: headers["upgrade"]?.lowercased() == "websocket",
            hasKey: !key.isEmpty, originAllowed: CameraRules.originAllowed(utf8: Array((headers["origin"] ?? "").utf8)),
            openClients: clients.values.filter { $0.open }.count)
        guard status == CameraRules.httpSwitching else {
            if status == CameraRules.httpForbidden {
                PonteDiagnostics.log("camera link: refused origin \(headers["origin"] ?? "(none)")")
            }
            refuse(client, status: status)
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

    private func refuse(_ client: Client, status: Int) {
        let response = "HTTP/1.1 \(Self.statusLine(status))\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
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
            let opcode = Int(b[0] & 0x0F)
            let masked = b[1] & 0x80 != 0
            let len7 = Int(b[1] & 0x7F)
            let at = CameraRules.wsHeaderBytes(len7: len7)
            var length = len7
            if at == 4 {
                guard b.count >= 4 else { return }
                length = Int(b[2]) << 8 | Int(b[3])
            }
            let code = CameraRules.wsFrameClose(fin: fin, masked: masked, len7: len7, length: length)
            guard code == 0 else {
                close(client, code: UInt16(clamping: code))
                return
            }
            guard client.buffer.count >= at + 4 + length else { return }
            let start = client.buffer.startIndex
            let mask = [UInt8](client.buffer[(start + at)..<(start + at + 4)])
            var payload = [UInt8](client.buffer[(start + at + 4)..<(start + at + 4 + length)])
            for i in payload.indices { payload[i] ^= mask[i % 4] }
            client.buffer.removeSubrange(start..<(start + at + 4 + length))
            let action = CameraRules.wsOpcodeAction(opcode)
            switch action {
            case CameraRules.wsaMessage: message(client, Data(payload))
            case CameraRules.wsaPong: send(client, opcode: 0xA, payload: Data(payload))
            case CameraRules.wsaIgnore: break
            default:
                close(client, code: UInt16(clamping: CameraRules.wsActionClose(action)))
                return
            }
        }
    }

    private func message(_ client: Client, _ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              CameraRules.linkVersionTaken(object["v"] as? Int) else { return }
        switch object["type"] as? String {
        case "status":
            // "cameras" is the processed count (an extension before 0.1.14 sent its wrapped cameras there).
            client.processed = CameraRules.linkCameras(object["cameras"] as? Int ?? 0)
            client.passing = CameraRules.linkCameras(object["passing"] as? Int ?? 0)
            client.troubled = CameraRules.linkCameras(object["troubled"] as? Int ?? 0)
            client.error = (object["error"] as? [String: Any]).map { e in
                CameraLinkError(stage: CameraRules.reportStage(e["stage"] as? Int ?? 0),
                                renderer: CameraRules.reportRenderer(e["renderer"] as? Int ?? 0),
                                name: CameraRules.reportClean(e["name"] as? String ?? "", kind: CameraRules.reportName),
                                message: CameraRules.reportClean(e["message"] as? String ?? "", kind: CameraRules.reportText))
            }
            report()
        case "hello":
            PonteDiagnostics.log("camera link: extension \(object["version"] as? String ?? "?") connected")
        default:
            break
        }
    }

    private func send(_ client: Client, opcode: UInt8, payload: Data) {
        guard CameraRules.wsSendFits(payload.count) else { return }
        let len7 = CameraRules.wsSendLen7(payload.count)
        var frame = Data([0x80 | opcode, UInt8(len7)])
        if len7 == 126 {
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
        var status = CameraLinkStatus()
        status.listening = listening
        status.failed = failed
        status.clients = open.count
        status.processed = open.reduce(0) { $0 + $1.processed }
        status.passing = open.reduce(0) { $0 + $1.passing }
        status.troubled = open.reduce(0) { $0 + $1.troubled }
        // The error of the highest rank; among equal ranks the first client's.
        var rank = 0
        for client in open {
            let r = CameraRules.reportErrorRank(hasError: client.error != nil, troubled: client.troubled > 0)
            if r > rank { rank = r; status.error = client.error }
        }
        if let error = status.error, error != lastLoggedError {
            lastLoggedError = error
            PonteDiagnostics.log("camera: a Meet page reports stage \(error.stage), renderer \(error.renderer): "
                                 + "\(error.name): \(error.message)")
        }
        if let last = lastStatus, last == status { return }
        lastStatus = status
        let handler = onStatus
        DispatchQueue.main.async { handler?(status) }
    }
}
