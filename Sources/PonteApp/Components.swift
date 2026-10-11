import AppKit
import PonteCore
import SwiftUI

/// Russian-style number: 1,2 с.
func secondsText(_ value: TimeInterval) -> String {
    value.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "ru_RU"))) + " с"
}

/// Colour for an AppRules.LAT_* code.
func latencyTint(_ code: Int32) -> Color {
    switch code {
    case AppRules.LAT_GOOD: .green
    case AppRules.LAT_SLOW: .orange
    case AppRules.LAT_BAD: .red
    default: .primary
    }
}

struct StatusChip: View {
    let title: String
    let systemImage: String
    let check: Check
    var level: Float? = nil
    var value: String? = nil
    var valueTint: Color = .primary
    var help: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
            if let value {
                Text(value)
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(valueTint)
            } else {
                indicator
            }
            if let level, check == .ok {
                LevelMeter(level: level)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help(help)
    }

    @ViewBuilder private var indicator: some View {
        switch check {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .bad:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .busy:
            ProgressView().controlSize(.mini)
        case .warn:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .unknown:
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        }
    }
}

/// A tiny input level bar.
struct LevelMeter: View {
    let level: Float

    var body: some View {
        let normalized = CGFloat(min(1, max(0, (20 * log10(max(level, 1e-5)) + 60) / 60)))
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.1))
            Capsule().fill(Color.green.opacity(0.8)).frame(width: 28 * normalized)
        }
        .frame(width: 28, height: 5)
        .animation(.linear(duration: 0.2), value: normalized)
    }
}

struct BannerView: View {
    let banner: Banner
    var perform: (Banner.Action) -> Void
    var dismiss: () -> Void

    private var tint: Color {
        switch banner.kind {
        case .error: .red
        case .warning: .orange
        case .info: .accentColor
        }
    }

    private var icon: String {
        switch banner.kind {
        case .error: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(banner.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let action = banner.action, let title = banner.actionTitle {
                Button(title) { perform(action) }
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Скрыть")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(tint.opacity(0.1))
    }
}

/// One phrase: large translation, grey original underneath, time and latency.
struct LineRow: View {
    let line: ConversationLine
    let isNewest: Bool
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let translation = line.translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: isNewest ? fontSize + 2 : fontSize, weight: isNewest ? .semibold : .regular))
                    .foregroundStyle(Color.primary.opacity(isNewest ? 1 : 0.72))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = line.translationError {
                Label("Перевод не получен", systemImage: "exclamationmark.triangle")
                    .font(.system(size: max(13, fontSize - 6)))
                    .foregroundStyle(.orange)
                    .help(error)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("переводится…")
                        .font(.system(size: fontSize - 6))
                        .foregroundStyle(.secondary)
                }
            }
            Text(line.original)
                .font(.system(size: max(13, fontSize * 0.6)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text(line.at, format: .dateTime.hour().minute().second())
                if let latency = line.latency {
                    Text("· \(secondsText(latency))")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The scrolling list of one column, with the live volatile line at the bottom.
struct TranscriptList: View {
    let lines: [ConversationLine]
    let partial: String
    let fontSize: Double
    let emptyIcon: String
    let emptyTitle: String
    let emptyText: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(lines) { line in
                        LineRow(line: line, isNewest: line.id == lines.last?.id, fontSize: fontSize)
                            .id(line.id)
                    }
                    if !partial.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "waveform")
                                .symbolEffect(.variableColor.iterative, options: .repeating)
                                .foregroundStyle(.secondary)
                            Text(partial)
                                .font(.system(size: max(15, fontSize - 6)))
                                .italic()
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .overlay {
                if lines.isEmpty && partial.isEmpty {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: emptyIcon)
                    } description: {
                        Text(emptyText)
                    }
                }
            }
            .onChange(of: lines.count) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: lines.last?.translation) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: partial) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

/// Shell command with a copy button (the owner runs it: it needs an admin password).
struct CommandBox: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            Text(command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

/// App icon for a bundle ID, for the source menu.
enum AppIcons {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        cache[bundleID] = image
        return image
    }
}
