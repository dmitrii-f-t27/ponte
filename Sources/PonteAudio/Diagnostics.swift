import Foundation

/// A small append-only diagnostics log at ~/Library/Logs/Ponte/ponte.log (audio events only: device
/// changes, rebuilds and their errors). It exists because the unified log is often unreadable when
/// a user reports a problem. Lines are short and contain no speech or translated text.
public enum PonteDiagnostics {
    private static let queue = DispatchQueue(label: "app.ponte.diagnostics")
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Ponte", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ponte.log")
    }()
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func log(_ message: @autoclosure () -> String) {
        let line = "\(stamp.string(from: Date())) \(message())\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
