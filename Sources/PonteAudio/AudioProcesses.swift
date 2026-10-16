import AppKit
import CoreAudio
import Darwin
import Foundation
import PonteCore

/// One HAL client process (an entry of kAudioHardwarePropertyProcessObjectList) and the app it belongs to.
struct AudioProcessInfo: Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    /// Bundle ID the HAL reports for this process (helpers have their own, e.g. com.google.Chrome.helper).
    let bundleID: String?
    let isRunningOutput: Bool
    let owner: AppOwner
}

/// The user-facing app a process belongs to (Chrome for its helpers, Safari for WebKit.GPU, …).
struct AppOwner: Hashable {
    let bundleID: String
    let name: String
    let pid: pid_t
    /// A normal Dock app (NSApplication.ActivationPolicy.regular).
    let isRegularApp: Bool
}

/// OS glue for process → app attribution. The decisions are in `AudioRules` (ownerSource,
/// outermostAppPathLength, parentAppIndex, isTapTargetProcess, the PID checks and the owner ID and name sources).
enum AudioProcesses {
    /// Snapshot of all HAL client processes with their owning app resolved.
    static func snapshot() -> [AudioProcessInfo] {
        var cache: [pid_t: AppOwner] = [:]
        let regularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return HAL.processObjectIDs().compactMap { object in
            guard let pid = HAL.pid(ofProcess: object), AudioRules.isProcessPID(pid) else { return nil }
            let bundleID = HAL.bundleID(ofProcess: object)
            let owner: AppOwner
            if let cached = cache[pid] {
                owner = cached
            } else {
                owner = resolveOwner(pid: pid, halBundleID: bundleID, regularApps: regularApps)
                cache[pid] = owner
            }
            return AudioProcessInfo(objectID: object, pid: pid, bundleID: bundleID,
                                    isRunningOutput: HAL.isRunningOutput(object), owner: owner)
        }
    }

    /// Processes to tap for an app (AudioRules.isTapTargetProcess): every process the app owns, processes
    /// whose own bundle ID is the target, known companions. Never `selfPID`.
    static func objects(forApp bundleID: String, in processes: [AudioProcessInfo],
                        selfPID: pid_t = getpid()) -> [AudioProcessInfo] {
        processes.filter { p in
            AudioRules.isTapTargetProcess(processBundleID: p.bundleID ?? "", ownerBundleID: p.owner.bundleID,
                                          targetBundleID: bundleID, pid: p.pid, selfPID: selfPID)
        }
    }

    // MARK: Owner resolution

    /// Collects every candidate from the OS, then lets `AudioRules.ownerSource` pick:
    /// self (Dock app) → outermost .app in the executable path → responsible app → regular parent app
    /// → bundle-ID prefix of a running Dock app → itself.
    static func resolveOwner(pid: pid_t, halBundleID: String?, regularApps: [NSRunningApplication]) -> AppOwner {
        let selfApp = NSRunningApplication(processIdentifier: pid)
        let selfIsRegular = AudioRules.isRegularApp(policyRegular: selfApp?.activationPolicy == .regular,
                                                    hasBundleID: selfApp?.bundleIdentifier != nil)

        let path = executablePath(pid)
        let pathOwner: AppOwner? = path.flatMap { ownerFromBundlePath($0, pid: pid, selfApp: selfApp) }

        let responsibleOwner: AppOwner? = responsiblePID(pid).flatMap { rpid -> AppOwner? in
            guard AudioRules.responsibleUsable(responsiblePID: rpid, pid: pid),
                  let app = NSRunningApplication(processIdentifier: rpid) else { return nil }
            return owner(of: app)
        }

        var parentOwner: AppOwner?
        var current = pid
        for _ in 0..<AudioRules.parentChainMaxDepth {
            guard let ppid = parentPID(current), AudioRules.parentContinues(parentPID: ppid, current: current) else { break }
            if let app = NSRunningApplication(processIdentifier: ppid),
               AudioRules.isRegularApp(policyRegular: app.activationPolicy == .regular, hasBundleID: app.bundleIdentifier != nil),
               let o = owner(of: app) {
                parentOwner = o
                break
            }
            current = ppid
        }

        var prefixOwner: AppOwner?
        if let bid = halBundleID ?? selfApp?.bundleIdentifier {
            let ids = regularApps.map { $0.bundleIdentifier ?? "" }
            let i = AudioRules.parentAppIndex(helperBundleID: bid, appBundleIDs: ids)
            if i >= 0 { prefixOwner = owner(of: regularApps[i]) }
        }

        switch AudioRules.ownerSource(selfIsRegularApp: selfIsRegular, hasAppBundlePath: pathOwner != nil,
                                      hasResponsibleApp: responsibleOwner != nil,
                                      hasRegularParentApp: parentOwner != nil, hasPrefixParent: prefixOwner != nil) {
        case AudioRules.ownerSelf: if let app = selfApp, let o = owner(of: app) { return o }
        case AudioRules.ownerAppBundlePath: if let o = pathOwner { return o }
        case AudioRules.ownerResponsible: if let o = responsibleOwner { return o }
        case AudioRules.ownerParent: if let o = parentOwner { return o }
        case AudioRules.ownerBundlePrefix: if let o = prefixOwner { return o }
        default: break
        }
        let bid: String
        switch AudioRules.ownerIDSource(hasHALBundleID: halBundleID != nil, hasAppBundleID: selfApp?.bundleIdentifier != nil) {
        case AudioRules.ownerIDFromHAL: bid = halBundleID ?? ""
        case AudioRules.ownerIDFromApp: bid = selfApp?.bundleIdentifier ?? ""
        default: bid = AudioRules.pidOwnerPrefix + String(pid)
        }
        let name: String
        switch AudioRules.ownerNameSource(hasAppName: selfApp?.localizedName != nil, hasPath: path != nil) {
        case AudioRules.ownerNameFromApp: name = selfApp?.localizedName ?? bid
        case AudioRules.ownerNameFromPath: name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? bid
        default: name = bid
        }
        return AppOwner(bundleID: bid, name: name, pid: pid, isRegularApp: selfIsRegular)
    }

    private static func ownerFromBundlePath(_ path: String, pid: pid_t, selfApp: NSRunningApplication?) -> AppOwner? {
        guard let appURL = outermostAppBundle(in: path), let bundle = Bundle(url: appURL),
              let bid = bundle.bundleIdentifier else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        let name: String
        switch AudioRules.bundleNameSource(hasRunningName: running?.localizedName != nil, hasDisplayName: displayName != nil,
                                           hasBundleName: bundleName != nil) {
        case AudioRules.bundleNameRunning: name = running?.localizedName ?? ""
        case AudioRules.bundleNameDisplay: name = displayName ?? ""
        case AudioRules.bundleNameBundle: name = bundleName ?? ""
        default: name = appURL.deletingPathExtension().lastPathComponent
        }
        let regular = AudioRules.pathOwnerIsRegular(hasRunning: running != nil, runningRegular: running?.activationPolicy == .regular,
                                                    hasSelf: selfApp != nil, selfRegular: selfApp?.activationPolicy == .regular)
        return AppOwner(bundleID: bid, name: name, pid: running?.processIdentifier ?? pid, isRegularApp: regular)
    }

    private static func owner(of app: NSRunningApplication) -> AppOwner? {
        guard let bid = app.bundleIdentifier else { return nil }
        return AppOwner(bundleID: bid, name: app.localizedName ?? bid, pid: app.processIdentifier,
                        isRegularApp: app.activationPolicy == .regular)
    }

    /// `/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/…` → `/Applications/Google Chrome.app`.
    static func outermostAppBundle(in path: String) -> URL? {
        let length = AudioRules.outermostAppPathLength(path)
        guard length > 0, let prefix = String(bytes: Array(path.utf8).prefix(length), encoding: .utf8) else { return nil }
        return URL(fileURLWithPath: prefix, isDirectory: true)
    }

    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// `responsibility_get_pid_responsible_for_pid` (libsystem, not in public headers) maps an XPC
    /// service or helper to the app that is responsible for it. Looked up at run time; nil if absent.
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let fn = responsibleFn else { return nil }
        let r = fn(pid)
        return r > 0 ? r : nil
    }
}
