// The oracle of Specs/camera_rules.t27: the camera picture rules in plain Swift, written separately from the spec.
// It builds the colour matrix as a product (contrast x saturation x warmth gains) in a loop where the spec writes
// each entry out, holds settings with min/max instead of branches, and compares the origin as a String.
// All arithmetic is Float, in the spec's order, so the facade and this oracle agree bit for bit.
import Foundation

enum CameraRulesLegacy {
    static let setCount = 9
    static let presetCount = 4
    static let paramsCount = 13
    static let linkPort = 47839
    static let linkVersion = 1
    static let linkPingMs = 20_000
    static let linkMessageMax = 4096
    static let clientsMax = 4

    /// (min, max, default) by kind: brightness, contrast, shadows, warmth, saturation, zoom, pan x, pan y, mirror.
    static let ranges: [(Int, Int, Int)] = [(-100, 100, 0), (-100, 100, 0), (0, 100, 0), (-100, 100, 0), (-100, 100, 0),
                                            (100, 300, 100), (-100, 100, 0), (-100, 100, 0), (0, 1, 0)]

    static func settingMin(_ kind: Int) -> Int { ranges.indices.contains(kind) ? ranges[kind].0 : 0 }
    static func settingMax(_ kind: Int) -> Int { ranges.indices.contains(kind) ? ranges[kind].1 : 0 }
    static func settingDefault(_ kind: Int) -> Int { ranges.indices.contains(kind) ? ranges[kind].2 : 0 }
    static func clamp(_ kind: Int, _ value: Int) -> Int { min(max(value, settingMin(kind)), settingMax(kind)) }

    /// Light and colour values by preset: normal, warm, dark room, vivid.
    static let presets: [[Int]] = [[0, 0, 0, 0, 0], [5, 0, 15, 30, 0], [20, -10, 50, 0, 10], [0, 20, 10, 0, 25]]

    static func presetSets(_ kind: Int) -> Bool { (0...4).contains(kind) }
    static func matchingPreset(_ s: [Int]) -> Int? {
        let colour = (0...4).map { clamp($0, $0 < s.count ? s[$0] : 0) }
        return presets.firstIndex(of: colour)
    }
    static func presetValue(_ preset: Int, _ kind: Int) -> Int {
        guard presetSets(kind) else { return settingDefault(kind) }
        return presets.indices.contains(preset) ? presets[preset][kind] : 0
    }

    private static func unit(_ kind: Int, _ s: [Int]) -> Float {
        Float(clamp(kind, kind < s.count ? s[kind] : settingDefault(kind))) / Float(100)
    }

    static func colorIdentity(_ s: [Int]) -> Bool { (0...4).allSatisfy { unit($0, s) == 0 } }

    static func colorParams(_ s: [Int]) -> [Float] {
        let w = unit(3, s) * Float(0.12)
        let gains: [Float] = [1 + w, 1, 1 - w]
        let sat = 1 + unit(4, s)
        let f = 1 + unit(1, s) * Float(0.5)
        let shift = unit(0, s) * Float(0.2)
        let rest = 1 - sat
        let luma: [Float] = [0.2126, 0.7152, 0.0722].map { rest * $0 }
        var out: [Float] = []
        for i in 0..<3 {
            for j in 0..<3 {
                // A diagonal entry adds the saturation; an off-diagonal one adds nothing (its sum is the luma part).
                let entry = i == j ? luma[j] + sat : luma[j]
                out.append(gains[j] == 1 ? f * entry : f * entry * gains[j])
            }
        }
        let offset = Float(0.5) * (1 - f) + shift
        out += [offset, offset, offset, unit(2, s) * Float(1.2)]
        return out
    }

    static func clamp01(_ x: Float) -> Float { x > 0 ? (x < 1 ? x : 1) : 0 }

    static func applyPixel(_ s: [Int], r: Float, g: Float, b: Float) -> (Float, Float, Float) {
        let p = colorParams(s)
        let rgb = [r, g, b]
        let lifted: [Float] = (0..<3).map { i in
            let v = clamp01(p[3 * i] * rgb[0] + p[3 * i + 1] * rgb[1] + p[3 * i + 2] * rgb[2] + p[9 + i])
            let d = 1 - v
            return clamp01(v + p[12] * v * d * d)
        }
        return (lifted[0], lifted[1], lifted[2])
    }

    static func frameIdentity(_ s: [Int]) -> Bool {
        clamp(5, s.count > 5 ? s[5] : 100) == 100 && clamp(8, s.count > 8 ? s[8] : 0) == 0
    }

    private static func edge(_ x: Float, _ limit: Float) -> Float { x > 0 ? (x < limit ? x : limit) : 0 }

    static func crop(_ s: [Int]) -> [Float] {
        let size = Float(100) / Float(clamp(5, s.count > 5 ? s[5] : 100))
        let room = (1 - size) * Float(0.5)
        let cx = Float(0.5) + unit(6, s) * room
        let cy = Float(0.5) + unit(7, s) * room
        let left = edge(cx - size * Float(0.5), 1 - size)
        let top = edge(cy - size * Float(0.5), 1 - size)
        let mirrored = clamp(8, s.count > 8 ? s[8] : 0) == 1
        return mirrored ? [left + size, top, -size, size] : [left, top, size, size]
    }

    static func needsProcessing(on: Bool, colorIdentity: Bool, frameIdentity: Bool) -> Bool {
        on && !(colorIdentity && frameIdentity)
    }

    static let extensionOrigin = "chrome-extension://jinldckdcbeojhpahpkagmacfdapfnln"

    static func originAllowed(utf8 origin: [UInt8]) -> Bool { origin == Array(extensionOrigin.utf8) }

    static func linkAccepts(openClients: Int) -> Bool { (0..<clientsMax).contains(openClients) }
    static func linkCameras(_ reported: Int) -> Int { min(max(reported, 0), 16) }

    static func linkStatus(listening: Bool, failed: Bool, clients: Int, activeCameras: Int) -> Int {
        if failed { return 1 }
        if !listening { return 0 }
        if clients <= 0 { return 2 }
        return activeCameras <= 0 ? 3 : 4
    }
}
