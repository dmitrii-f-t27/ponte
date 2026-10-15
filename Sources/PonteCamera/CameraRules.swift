import PonteSpecs

/// The owner's camera picture in Meet (Specs/camera_rules.t27, cm_). Every function only passes values to the
/// generated C; the Ponte Camera extension runs the same C as WebAssembly.
public enum CameraRules {
    // MARK: Settings

    public static let setBrightness = Int(CM_SET_BRIGHTNESS)
    public static let setContrast = Int(CM_SET_CONTRAST)
    public static let setShadows = Int(CM_SET_SHADOWS)
    public static let setWarmth = Int(CM_SET_WARMTH)
    public static let setSaturation = Int(CM_SET_SATURATION)
    public static let setZoom = Int(CM_SET_ZOOM)
    public static let setPanX = Int(CM_SET_PAN_X)
    public static let setPanY = Int(CM_SET_PAN_Y)
    public static let setMirror = Int(CM_SET_MIRROR)
    public static let setCount = Int(CM_SET_COUNT)

    public static func settingMin(_ kind: Int) -> Int { Int(cm_setting_min(Int64(kind))) }
    public static func settingMax(_ kind: Int) -> Int { Int(cm_setting_max(Int64(kind))) }
    public static func settingDefault(_ kind: Int) -> Int { Int(cm_setting_default(Int64(kind))) }
    /// A value held to the setting's range.
    public static func clamp(_ kind: Int, _ value: Int) -> Int { Int(cm_clamp_setting(Int64(kind), Int64(value))) }

    // MARK: Presets

    public static let presetNormal = Int(CM_PRESET_NORMAL)
    public static let presetWarm = Int(CM_PRESET_WARM)
    public static let presetDarkRoom = Int(CM_PRESET_DARK_ROOM)
    public static let presetVivid = Int(CM_PRESET_VIVID)
    public static let presetCount = Int(CM_PRESET_COUNT)

    /// A preset sets light and colour and keeps the frame.
    public static func presetSets(_ kind: Int) -> Bool { cm_preset_sets(Int64(kind)) }
    public static func presetValue(_ preset: Int, _ kind: Int) -> Int { Int(cm_preset_value(Int64(preset), Int64(kind))) }
    /// The preset whose light and colour values these are, or nil.
    public static func matchingPreset(_ s: [Int]) -> Int? {
        let p = Int(cm_matching_preset(value(s, setBrightness), value(s, setContrast), value(s, setShadows),
                                       value(s, setWarmth), value(s, setSaturation)))
        return p < 0 ? nil : p
    }

    // MARK: Colour and frame

    public static let paramsCount = Int(CM_PARAMS_COUNT)

    public static func colorIdentity(_ s: [Int]) -> Bool {
        cm_color_identity(value(s, setBrightness), value(s, setContrast), value(s, setShadows), value(s, setWarmth),
                          value(s, setSaturation))
    }

    /// The 3x3 matrix row by row, the three offsets and the shadow lift (CM_PARAMS_COUNT numbers).
    public static func colorParams(_ s: [Int]) -> [Float] {
        var out = [Float](repeating: 0, count: 16)
        let n = out.withUnsafeMutableBufferPointer {
            cm_color_params(value(s, setBrightness), value(s, setContrast), value(s, setShadows), value(s, setWarmth),
                            value(s, setSaturation), $0.baseAddress!)
        }
        return Array(out.prefix(Int(n)))
    }

    /// One pixel through the colour transform (the oracle of the extension's shader).
    public static func applyPixel(_ s: [Int], r: Float, g: Float, b: Float) -> (Float, Float, Float) {
        var out = [Float](repeating: 0, count: 4)
        _ = out.withUnsafeMutableBufferPointer {
            cm_apply_pixel(value(s, setBrightness), value(s, setContrast), value(s, setShadows), value(s, setWarmth),
                           value(s, setSaturation), r, g, b, $0.baseAddress!)
        }
        return (out[0], out[1], out[2])
    }

    public static func frameIdentity(_ s: [Int]) -> Bool {
        cm_frame_identity(value(s, setZoom), value(s, setPanX), value(s, setPanY), value(s, setMirror))
    }

    /// The part of the picture shown: u0, v0, du, dv in texture coordinates from the top left.
    public static func crop(_ s: [Int]) -> [Float] {
        var out = [Float](repeating: 0, count: 4)
        _ = out.withUnsafeMutableBufferPointer {
            cm_crop(value(s, setZoom), value(s, setPanX), value(s, setPanY), value(s, setMirror), $0.baseAddress!)
        }
        return out
    }

    public static func needsProcessing(on: Bool, colorIdentity: Bool, frameIdentity: Bool) -> Bool {
        cm_needs_processing(on, colorIdentity, frameIdentity)
    }

    // MARK: Link

    public static let linkPort = Int(CM_LINK_PORT)
    public static let linkVersion = Int(CM_LINK_VERSION)
    public static let linkPingMs = Int(CM_LINK_PING_MS)
    public static let linkMessageMax = Int(CM_LINK_MESSAGE_MAX)

    public static let linkOff = Int(CM_LINK_OFF)
    public static let linkFailed = Int(CM_LINK_FAILED)
    public static let linkNoExtension = Int(CM_LINK_NO_EXTENSION)
    public static let linkWaiting = Int(CM_LINK_WAITING)
    public static let linkActive = Int(CM_LINK_ACTIVE)

    /// The Origin header of a handshake is the Ponte Camera extension's own.
    public static func originAllowed(utf8 origin: [UInt8]) -> Bool {
        var text = [UInt8](repeating: 0, count: 256)
        let n = min(origin.count, text.count)
        text.replaceSubrange(0..<n, with: origin.prefix(n))
        // A longer header is passed with its real length, which no 256-byte origin matches.
        return text.withUnsafeMutableBufferPointer { cm_origin_allowed($0.baseAddress!, Int64(origin.count)) }
    }

    /// The extension's own origin (the table's row), for the panel's instructions and the tests.
    public static var extensionOrigin: String {
        var out = [UInt8](repeating: 0, count: 256)
        let n = out.withUnsafeMutableBufferPointer { cm_row(Int64(CM_ROW_EXTENSION_ORIGIN), $0.baseAddress!) }
        return String(decoding: out.prefix(Int(n)), as: UTF8.self)
    }

    public static func linkAccepts(openClients: Int) -> Bool { cm_link_accepts(Int64(openClients)) }
    /// A new TCP connection is taken while fewer than CM_LINK_CONNECTIONS_MAX are open or shaking hands.
    public static func linkTakesConnection(_ connections: Int) -> Bool { cm_link_takes_connection(Int64(connections)) }
    public static let linkHandshakeMs = Int(CM_LINK_HANDSHAKE_MS)
    public static func linkHandshakeExpired(msSinceAccept: Int64) -> Bool { cm_link_handshake_expired(msSinceAccept) }
    /// The processed cameras an extension reports, held to 0...CM_LINK_CAMERAS_MAX.
    public static func linkCameras(_ reported: Int) -> Int { Int(cm_link_cameras(Int64(reported))) }

    public static func linkStatus(listening: Bool, failed: Bool, clients: Int, activeCameras: Int) -> Int {
        Int(cm_link_status(listening, failed, Int64(clients), Int64(activeCameras)))
    }

    /// A setting from a settings array (missing: its default).
    private static func value(_ s: [Int], _ kind: Int) -> Int64 {
        Int64(kind < s.count ? s[kind] : settingDefault(kind))
    }
}
