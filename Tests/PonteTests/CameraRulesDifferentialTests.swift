// The camera picture rules (Specs/camera_rules.t27, through the CameraRules facade) against their Swift oracle
// (CameraRulesLegacy), bit for bit: every setting kind and value near its range, a grid of edge values over all
// five colour settings, seeded random settings and pixels (out of range, NaN, infinities), every zoom and pan.
import Foundation
import PonteSpecs
import PonteCamera
import Testing
@testable import PonteApp

private typealias F = CameraRules
private typealias L = CameraRulesLegacy

@Suite("Differential: camera rules") struct CameraRulesDifferentialTests {
    static let edges = [Int.min, -1000, -101, -100, -99, -50, -1, 0, 1, 50, 99, 100, 101, 299, 300, 301, 1000, Int.max]

    @Test func constants() {
        let log = DiffLog("camera constants")
        log.check([F.setCount, F.presetCount, F.paramsCount, F.linkPort, F.linkVersion, F.linkPingMs, F.linkMessageMax],
                  [L.setCount, L.presetCount, L.paramsCount, L.linkPort, L.linkVersion, L.linkPingMs, L.linkMessageMax],
                  "limits")
        log.check([F.setBrightness, F.setContrast, F.setShadows, F.setWarmth, F.setSaturation, F.setZoom, F.setPanX,
                   F.setPanY, F.setMirror], Array(0..<9), "setting kinds")
        log.check([F.linkOff, F.linkFailed, F.linkNoExtension, F.linkWaiting, F.linkActive], Array(0..<5), "link codes")
        log.check(F.extensionOrigin, L.extensionOrigin, "extension origin")
        log.finish(minimumCases: 4)
    }

    @Test func settingsAndPresets() {
        let log = DiffLog("settings, presets")
        for kind in -3...12 {
            log.check([F.settingMin(kind), F.settingMax(kind), F.settingDefault(kind)],
                      [L.settingMin(kind), L.settingMax(kind), L.settingDefault(kind)], "range \(kind)")
            log.check(F.presetSets(kind), L.presetSets(kind), "presetSets \(kind)")
            for value in Array(-400...400) + Self.edges {
                log.check(F.clamp(kind, value), L.clamp(kind, value), "clamp \(kind) \(value)")
            }
            for preset in -2...6 {
                log.check(F.presetValue(preset, kind), L.presetValue(preset, kind), "preset \(preset) \(kind)")
            }
        }
        log.finish(minimumCases: 12_000)
    }

    @Test func colour() {
        let log = DiffLog("colorIdentity, colorParams")
        let grid = [Int.min, -101, -100, -37, -1, 0, 1, 64, 100, 101, Int.max]
        for b in grid { for c in grid { for sh in grid { for w in grid { for sat in grid {
            let s = [b, c, sh, w, sat]
            log.check(F.colorParams(s), L.colorParams(s), "\(s)")
            log.check(F.colorIdentity(s), L.colorIdentity(s), "identity \(s)")
            log.check(F.matchingPreset(s), L.matchingPreset(s), "preset \(s)")
        } } } } }
        for preset in 0..<L.presetCount {
            let s = L.presets[preset]
            log.check(F.matchingPreset(s), L.matchingPreset(s), "preset values \(preset)")
            for kind in 0..<5 { for delta in [-1, 1] {
                var t = s
                t[kind] += delta
                log.check(F.matchingPreset(t), L.matchingPreset(t), "near preset \(preset) \(kind) \(delta)")
            } }
        }
        var r = DiffRandom(seed: 0xCA3E_7A)
        for _ in 0..<60_000 {
            let s = (0..<5).map { _ in r.int(-120...120) }
            log.check(F.colorParams(s), L.colorParams(s), "\(s)")
            log.check(F.colorIdentity(s), L.colorIdentity(s), "identity \(s)")
        }
        log.finish(minimumCases: 400_000)
    }

    @Test func pixels() {
        let log = DiffLog("applyPixel")
        var r = DiffRandom(seed: 0x9_1C5E1)
        let channels: [Float] = [0, 1, 0.5, 1.0 / 3, 0.25, 0.75, 1e-6, 0.999_999, -0.1, 1.1, .nan, .infinity, -.infinity]
        for _ in 0..<150_000 {
            let s = (0..<5).map { _ in r.bool() ? r.int(-100...100) : r.pick(Self.edges) }
            let rgb: [Float] = (0..<3).map { _ in
                switch r.int(0...3) {
                case 0: return r.pick(channels)
                case 1: return r.float()
                default: return Float(r.int(0...255)) / 255
                }
            }
            let a = F.applyPixel(s, r: rgb[0], g: rgb[1], b: rgb[2])
            let b = L.applyPixel(s, r: rgb[0], g: rgb[1], b: rgb[2])
            log.check([a.0, a.1, a.2], [b.0, b.1, b.2], "\(s) \(rgb)")
        }
        log.finish(minimumCases: 150_000)
    }

    @Test func frame() {
        let log = DiffLog("frameIdentity, crop, needsProcessing")
        for zoom in Array(90...310) + Self.edges {
            for pan in stride(from: -110, through: 110, by: 1) {
                for mirror in [0, 1] {
                    let s = [0, 0, 0, 0, 0, zoom, pan, -pan / 2, mirror]
                    log.check(F.crop(s), L.crop(s), "\(s)")
                    log.check(F.frameIdentity(s), L.frameIdentity(s), "identity \(s)")
                }
            }
        }
        var r = DiffRandom(seed: 0xF4A3E)
        for _ in 0..<40_000 {
            let s = [0, 0, 0, 0, 0, r.int(-500...800), r.pick(Self.edges + [r.int(-150...150)]), r.int(-150...150), r.int(-2...3)]
            log.check(F.crop(s), L.crop(s), "\(s)")
            log.check(F.frameIdentity(s), L.frameIdentity(s), "identity \(s)")
        }
        for on in [false, true] { for c in [false, true] { for f in [false, true] {
            log.check(F.needsProcessing(on: on, colorIdentity: c, frameIdentity: f),
                      L.needsProcessing(on: on, colorIdentity: c, frameIdentity: f), "\(on) \(c) \(f)")
        } } }
        log.finish(minimumCases: 200_000)
    }

    @Test func link() {
        let log = DiffLog("originAllowed, linkAccepts, linkStatus")
        let origin = Array(L.extensionOrigin.utf8)
        var cases: [[UInt8]] = [origin, Array(origin.dropLast()), origin + [0x2F], origin + [0], [],
                                Array(L.extensionOrigin.uppercased().utf8), Array("https://meet.google.com".utf8),
                                Array(repeating: 0x61, count: 300), origin + Array(repeating: 0x61, count: 300)]
        var r = DiffRandom(seed: 0x0_419_17)
        for _ in 0..<20_000 {
            var bytes = origin
            switch r.int(0...3) {
            case 0: bytes[r.int(0...(bytes.count - 1))] = UInt8(truncatingIfNeeded: r.next())
            case 1: bytes = r.bytes(maxCount: 80)
            case 2: bytes.removeLast(r.int(0...5))
            default: bytes += r.bytes(maxCount: 3)
            }
            cases.append(bytes)
        }
        for bytes in cases {
            log.check(F.originAllowed(utf8: bytes), L.originAllowed(utf8: bytes), "\(bytes)")
        }
        for n in -3...10 { log.check(F.linkAccepts(openClients: n), L.linkAccepts(openClients: n), "\(n)") }
        for n in Array(-20...40) + [Int.min, Int.max] {
            log.check(F.linkCameras(n), L.linkCameras(n), "cameras \(n)")
            log.check(F.linkTakesConnection(n), L.linkTakesConnection(n), "connections \(n)")
        }
        for ms: Int64 in Array(stride(from: -1000, through: 12_000, by: 250)) + [4999, 5000, 5001, .min, .max] {
            log.check(F.linkHandshakeExpired(msSinceAccept: ms), L.linkHandshakeExpired(msSinceAccept: ms), "handshake \(ms)")
        }
        for listening in [false, true] { for failed in [false, true] {
            for clients in -1...3 { for active in -1...3 {
                log.check(F.linkStatus(listening: listening, failed: failed, clients: clients, activeCameras: active),
                          L.linkStatus(listening: listening, failed: failed, clients: clients, activeCameras: active),
                          "\(listening) \(failed) \(clients) \(active)")
            } }
        } }
        log.finish(minimumCases: 20_000)
    }

    /// Hand cases: the presets change the picture, the defaults do not, and the extension's origin is the only one.
    @Test func handCases() {
        let defaults = (0..<F.setCount).map { F.settingDefault($0) }
        #expect(F.colorIdentity(defaults) && F.frameIdentity(defaults))
        #expect(!F.needsProcessing(on: true, colorIdentity: true, frameIdentity: true))
        for preset in 1..<F.presetCount {
            let s = (0..<F.setCount).map { F.presetValue(preset, $0) }
            #expect(!F.colorIdentity(s), "preset \(preset) changes the picture")
            #expect(F.frameIdentity(s), "preset \(preset) keeps the frame")
        }
        #expect(F.originAllowed(utf8: Array("chrome-extension://jinldckdcbeojhpahpkagmacfdapfnln".utf8)))
        #expect(!F.originAllowed(utf8: Array("https://meet.google.com".utf8)))
        #expect(F.crop([0, 0, 0, 0, 0, 200, 0, 0, 0]) == [0.25, 0.25, 0.5, 0.5])
        let lifted = F.applyPixel([0, 0, 100, 0, 0], r: 0.2, g: 0.2, b: 0.2)
        #expect(lifted.0 > 0.2 && lifted.0 == lifted.1)
    }
}
