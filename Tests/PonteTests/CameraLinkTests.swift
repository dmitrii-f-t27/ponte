// Ponte's camera link (CameraLink, Specs/camera_rules.t27) over a real socket on 127.0.0.1: the extension's origin
// gets the settings at once and after every change, reports its cameras; any other origin, a page without an Origin
// and an oversized message are refused; the model keeps its settings in range and between launches.
import Foundation
import Network
import PonteCamera
import Testing
@testable import PonteApp

@Suite("Camera link", .serialized) struct CameraLinkTests {
    private static let origin = CameraRules.extensionOrigin

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        var get: T { lock.withLock { value } }
        func set(_ v: T) { lock.withLock { value = v } }
    }

    private static func port() -> Int { 49_152 + Int.random(in: 0..<10_000) }

    private static func socket(_ port: Int, origin: String?) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/camera")!)
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
        task.resume()
        return task
    }

    private static func json(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        guard case .string(let text) = message else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    private static func waitUntil(_ seconds: Double = 5, _ test: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if test() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return test()
    }

    @Test func theExtensionGetsTheSettingsAndReportsItsCameras() async throws {
        let port = Self.port()
        let link = CameraLink(port: port)
        let status = Box((false, false, 0, 0))
        link.onStatus = { status.set(($0, $1, $2, $3)) }
        link.start()
        #expect(await Self.waitUntil { status.get.0 })
        let first = Data(#"{"type":"settings","v":1,"on":true,"s":[10,0,0,0,0,100,0,0,0]}"#.utf8)
        link.publish(first)

        let task = Self.socket(port, origin: Self.origin)
        let message = try #require(Self.json(try await task.receive()))
        #expect(message["type"] as? String == "settings")
        #expect((message["s"] as? [Int])?.first == 10)
        #expect(await Self.waitUntil { status.get.2 == 1 })

        // A change reaches the connected extension.
        link.publish(Data(#"{"type":"settings","v":1,"on":false,"s":[0,0,0,0,0,200,0,0,1]}"#.utf8))
        let changed = try #require(Self.json(try await task.receive()))
        #expect(changed["on"] as? Bool == false)

        // Its Meet pages' cameras reach the panel, held to the spec's limit.
        try await task.send(.string(#"{"type":"status","v":1,"cameras":2}"#))
        #expect(await Self.waitUntil { status.get.3 == 2 })
        try await task.send(.string(#"{"type":"status","v":1,"cameras":99}"#))
        #expect(await Self.waitUntil { status.get.3 == CameraRules.linkCameras(99) })
        #expect(CameraRules.linkStatus(listening: status.get.0, failed: status.get.1, clients: status.get.2,
                                       activeCameras: status.get.3) == CameraRules.linkActive)

        task.cancel(with: .goingAway, reason: nil)
        #expect(await Self.waitUntil { status.get.2 == 0 && status.get.3 == 0 })
        link.stop()
    }

    @Test func otherOriginsAreRefused() async throws {
        let port = Self.port()
        let link = CameraLink(port: port)
        let status = Box((false, false, 0, 0))
        link.onStatus = { status.set(($0, $1, $2, $3)) }
        link.start()
        #expect(await Self.waitUntil { status.get.0 })
        link.publish(Data(#"{"type":"settings","v":1,"on":true,"s":[]}"#.utf8))
        for origin in ["https://meet.google.com", "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Self.origin + "/", nil] {
            let task = Self.socket(port, origin: origin)
            await #expect(throws: (any Error).self, "origin \(origin ?? "none")") { _ = try await task.receive() }
        }
        #expect(status.get.2 == 0)
        link.stop()
    }

    @Test func anOversizedMessageClosesTheConnection() async throws {
        let port = Self.port()
        let link = CameraLink(port: port)
        let status = Box((false, false, 0, 0))
        link.onStatus = { status.set(($0, $1, $2, $3)) }
        link.start()
        #expect(await Self.waitUntil { status.get.0 })
        let task = Self.socket(port, origin: Self.origin)
        try await task.send(.string(#"{"type":"hello","v":1}"#))
        #expect(await Self.waitUntil { status.get.2 == 1 })
        try? await task.send(.string(String(repeating: "x", count: CameraRules.linkMessageMax + 1)))
        #expect(await Self.waitUntil { status.get.2 == 0 })
        link.stop()
    }

    /// Connections that never finish their handshake cannot pile up: at most CM_LINK_CONNECTIONS_MAX are taken, and
    /// each is closed CM_LINK_HANDSHAKE_MS after it came, so the extension gets in afterwards.
    @Test func silentConnectionsAreCappedAndExpire() async throws {
        let port = Self.port()
        let link = CameraLink(port: port)
        let status = Box((false, false, 0, 0))
        link.onStatus = { status.set(($0, $1, $2, $3)) }
        link.start()
        #expect(await Self.waitUntil { status.get.0 })
        link.publish(Data(#"{"type":"settings","v":1,"on":true,"s":[]}"#.utf8))
        let queue = DispatchQueue(label: "silent")
        var silent: [NWConnection] = []
        for _ in 0..<12 {
            let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
            c.start(queue: queue)
            silent.append(c)
        }
        try await Task.sleep(for: .milliseconds(300))
        // While they hold every seat, the extension's handshake gets no answer...
        let early = Self.socket(port, origin: Self.origin)
        let earlyResult = Box<Bool?>(nil)
        Task { earlyResult.set((try? await early.receive()) != nil) }
        // ...and after the deadline they are gone and a new connection gets the settings.
        try await Task.sleep(for: .milliseconds(CameraRules.linkHandshakeMs + 700))
        let task = Self.socket(port, origin: Self.origin)
        let message = try #require(Self.json(try await task.receive()))
        #expect(message["type"] as? String == "settings")
        for c in silent { c.cancel() }
        early.cancel()
        task.cancel()
        link.stop()
    }

    @Test @MainActor func theModelKeepsItsSettingsInRangeAndBetweenLaunches() throws {
        let suite = "ponte-camera-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CameraModel(defaults: defaults, port: Self.port())
        #expect(model.settings == (0..<CameraRules.setCount).map { CameraRules.settingDefault($0) })
        #expect(model.currentPreset == CameraRules.presetNormal)
        model.set(CameraRules.setZoom, 999)
        model.set(CameraRules.setBrightness, -500)
        #expect(model.value(CameraRules.setZoom) == 300 && model.value(CameraRules.setBrightness) == -100)
        model.applyPreset(CameraRules.presetWarm)
        #expect(model.currentPreset == CameraRules.presetWarm)
        #expect(model.value(CameraRules.setZoom) == 300)   // a preset keeps the frame
        model.on = false
        let again = CameraModel(defaults: defaults, port: Self.port())
        #expect(again.settings == model.settings && again.on == false)
        again.reset()
        #expect(again.currentPreset == CameraRules.presetNormal && again.value(CameraRules.setZoom) == 100)
        // Stored values out of range (an older or edited file) are held to the ranges.
        defaults.set([1000, -1000, -5, 0, 0, 0, 500, 0, 9], forKey: "cameraSettings")
        let held = CameraModel(defaults: defaults, port: Self.port())
        #expect(held.settings == [100, -100, 0, 0, 0, 100, 100, 0, 1])
    }
}
