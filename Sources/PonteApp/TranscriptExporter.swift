import Foundation
import PonteCore

/// Writes the call log as Markdown: ~/Documents/Ponte/YYYY-MM-DD-HHMM.md.
/// File name and escaping come from AppRules; Russian labels and layout are here.
enum TranscriptExporter {
    static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ponte", isDirectory: true)
    }

    static func fileName(for date: Date, attempt: Int32 = 1, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let bytes = AppRules.transcriptFileName(year: Int32(c.year ?? 0), month: Int32(c.month ?? 0),
                                                day: Int32(c.day ?? 0), hour: Int32(c.hour ?? 0),
                                                minute: Int32(c.minute ?? 0), attempt: attempt)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Markdown-safe text: cut to AppRules.MD_ESCAPE_MAX_INPUT bytes at a character
    /// boundary (Swift owns Unicode), then escaped by AppRules.markdownEscape.
    static func escaped(_ text: String) -> String {
        var cut = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > Int(AppRules.MD_ESCAPE_MAX_INPUT) { break }
            cut.append(character)
            bytes += size
        }
        return String(decoding: AppRules.markdownEscape(Array(cut.utf8)), as: UTF8.self)
    }

    static func markdown(lines: [ConversationLine], startedAt: Date, endedAt: Date? = nil,
                         sourceName: String? = nil, timeZone: TimeZone = .current) -> String {
        let day = formatter("dd.MM.yyyy", timeZone)
        let minute = formatter("HH:mm", timeZone)
        let second = formatter("HH:mm:ss", timeZone)
        let theirs = lines.filter { $0.direction == .incoming }.count
        var out = "# Ponte — звонок \(day.string(from: startedAt)), \(minute.string(from: startedAt))\n\n"
        if let sourceName { out += "- Источник звука: \(escaped(sourceName))\n" }
        if let endedAt {
            out += "- Время: \(minute.string(from: startedAt))–\(minute.string(from: endedAt))\n"
        }
        out += "- Фраз: \(lines.count) (они: \(theirs), я: \(lines.count - theirs))\n\n---\n"
        for line in lines.sorted(by: { $0.at < $1.at }) {
            let who = line.direction == .incoming ? "Они" : "Я"
            let route = "\(line.direction.source.rawValue) → \(line.direction.target.rawValue)"
            var header = "\n**\(second.string(from: line.at)) · \(who)** (\(route))"
            if let latency = line.latency {
                header += String(format: " · задержка %.1f с", latency)
            }
            out += header + "\n\n"
            out += quote(escaped(line.original)) + "\n\n"
            if let translation = line.translation, !translation.isEmpty {
                out += escaped(translation) + "\n"
            } else {
                out += "_перевод не получен_\n"
            }
        }
        return out
    }

    /// Writes the file and returns its URL. Never overwrites: attempt 2, 3… add "-N".
    @discardableResult
    static func write(lines: [ConversationLine], startedAt: Date, endedAt: Date? = nil,
                      sourceName: String? = nil, to folder: URL = defaultFolder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var attempt: Int32 = 1
        var url = folder.appendingPathComponent(fileName(for: startedAt, attempt: attempt))
        while FileManager.default.fileExists(atPath: url.path) {
            attempt += 1
            url = folder.appendingPathComponent(fileName(for: startedAt, attempt: attempt))
        }
        let text = markdown(lines: lines, startedAt: startedAt, endedAt: endedAt, sourceName: sourceName)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func quote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }
            .joined(separator: "\n")
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }
}
