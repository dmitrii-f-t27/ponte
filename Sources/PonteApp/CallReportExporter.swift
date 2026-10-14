import Foundation
import PonteCore
import PonteSpeech

/// Writes the call report as UTF-8 plain text next to the transcripts: ~/Documents/Ponte/Ponte-report-YYYY-MM-DD-HHmm.txt.
/// The file name comes from AnalysisRules (Specs/analysis_rules.t27) and is never reused ("-2", "-3"…); the Russian
/// layout is here: a header (date, time and length, source app, line counts, service, and a warning when the service
/// cut the report), the report, then the whole transcript (time, who, original, translation).
enum CallReportExporter {
    static func fileName(for date: Date, attempt: Int32 = AnalysisRules.firstAttempt, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let bytes = AnalysisRules.reportFileName(year: Int32(c.year ?? 0), month: Int32(c.month ?? 0), day: Int32(c.day ?? 0),
                                                 hour: Int32(c.hour ?? 0), minute: Int32(c.minute ?? 0), attempt: attempt)
        return String(decoding: bytes, as: UTF8.self)
    }

    static let rule = String(repeating: "=", count: 72)
    /// The warning of a report the service cut before its end (AnalysisRules.replyComplete).
    static let incompleteNote = "ВНИМАНИЕ: отчёт неполный — сервис оборвал ответ, не дописав его (предел длины ответа или фильтр сервиса)."
    /// The mark at the cut.
    static let cutMark = "[…ответ сервиса оборван здесь]"

    /// The whole text of the file.
    static func text(report: String, lines: [ConversationLine], facts: CallFacts, service: String?, madeAt: Date,
                     complete: Bool = true, timeZone: TimeZone = .current) -> String {
        let day = formatter("dd.MM.yyyy", timeZone)
        let minute = formatter("HH:mm", timeZone)
        let second = formatter("HH:mm:ss", timeZone)
        var out = "PONTE — ОТЧЁТ ПО ЗВОНКУ\n\n"
        out += "Дата: \(day.string(from: facts.startedAt))\n"
        var time = "Время: \(minute.string(from: facts.startedAt))"
        if let end = facts.endedAt { time += "–\(minute.string(from: end))" } else { time += " (звонок ещё шёл)" }
        let minutes = facts.minutes(now: madeAt)
        time += minutes > 0 ? ", длительность \(minutes) мин" : ", длительность меньше минуты"
        out += time + "\n"
        if let source = facts.sourceName, !source.isEmpty { out += "Источник звука: \(source)\n" }
        out += "Реплик: \(facts.lines) (собеседник: \(facts.theirs), я: \(facts.mine))\n"
        if let service, !service.isEmpty { out += "Анализ: \(service)\n" }
        out += "Отчёт составлен: \(day.string(from: madeAt)) \(minute.string(from: madeAt))\n"
        if !complete { out += incompleteNote + "\n" }
        out += "\n\(rule)\nОТЧЁТ\n\(rule)\n\n"
        out += report.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        if !complete { out += "\n\(cutMark)\n" }
        out += "\n\(rule)\nСТЕНОГРАММА\n\(rule)\n"
        let ordered = lines.enumerated().sorted {
            AppRules.lineBefore(atA: $0.element.at.timeIntervalSinceReferenceDate, indexA: $0.offset,
                                atB: $1.element.at.timeIntervalSinceReferenceDate, indexB: $1.offset)
        }.map(\.element)
        if ordered.isEmpty { out += "\n(реплик нет)\n" }
        for line in ordered {
            let analysis = AnalysisLine(line)
            out += "\n[\(second.string(from: line.at))] \(analysis.speakerName) "
                + "(\(line.direction.source.rawValue) → \(line.direction.target.rawValue))\n"
            out += "  Оригинал: \(oneBlock(line.original))\n"
            if let translation = line.translation, !translation.isEmpty {
                out += "  Перевод: \(oneBlock(translation))\n"
            } else {
                out += "  Перевод: нет\n"
            }
        }
        return out
    }

    /// Writes the text and returns the file's URL. Never overwrites: attempt 2, 3… add "-N".
    @discardableResult
    static func write(_ text: String, startedAt: Date, to folder: URL = TranscriptExporter.defaultFolder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var attempt = AnalysisRules.firstAttempt
        var url = folder.appendingPathComponent(fileName(for: startedAt, attempt: attempt))
        while FileManager.default.fileExists(atPath: url.path) {
            attempt += 1
            url = folder.appendingPathComponent(fileName(for: startedAt, attempt: attempt))
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A phrase on its lines, indented under its label.
    private static func oneBlock(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\n            ")
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }
}
