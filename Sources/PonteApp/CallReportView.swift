import AppKit
import PonteSpeech
import SwiftUI

// The call analysis in the main window: the toolbar button «Отчёт по звонку» and the report window (a sheet) with
// its progress, the selectable report text and «Обновить», «Скопировать», «Сохранить в TXT». MainView adds both with
// one line: `.callAnalysis()`. Tooltips are accessibility hints (.help crashes SwiftUI on macOS 27).

extension View {
    /// The toolbar button «Отчёт по звонку» and the report sheet (CallAnalysisModel).
    func callAnalysis() -> some View { modifier(CallAnalysisHost()) }
}

private struct CallAnalysisHost: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var analysis = model.analysis
        content
            .toolbar { CallReportToolbar() }
            // On its own view, so it never competes with the wizard and checklist sheet of MainView.
            .background {
                Color.clear
                    .sheet(isPresented: $analysis.showReport) {
                        CallReportView()
                            .environment(model)
                    }
            }
    }
}

private struct CallReportToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.analysis.openReport(model)
            } label: {
                Label("Отчёт по звонку", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(!model.analysis.reportButtonEnabled(lines: model.lines.count))
            .accessibilityHint("Отчёт ИИ по звонку: важные данные, договорённости и задачи, с выгрузкой в TXT")
        }
    }
}

struct CallReportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let analysis = model.analysis
        VStack(alignment: .leading, spacing: 14) {
            header(analysis)
            if analysis.building {
                progressRow(analysis)
            }
            if let error = analysis.reportError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            content(analysis)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let status = analysis.notesStatus, model.isRunning {
                Label(status, systemImage: "note.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = analysis.report?.savedURL {
                savedRow("Сохранено: \((url.path as NSString).abbreviatingWithTildeInPath)", url)
            }
            if let url = analysis.autosavedURL {
                savedRow("Отчёт прошлого звонка сохранён: \((url.path as NSString).abbreviatingWithTildeInPath)", url)
            }
            buttons(analysis)
        }
        .padding(20)
        .frame(minWidth: 660, idealWidth: 760, minHeight: 520, idealHeight: 640)
    }

    private func header(_ analysis: CallAnalysisModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.tint)
            Text("Отчёт по звонку")
                .font(.title2.weight(.semibold))
            Spacer()
            if let report = analysis.report {
                Text("\(report.service) · \(CallAnalysisModel.clock(report.madeAt))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func progressRow(_ analysis: CallAnalysisModel) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(analysis.progressText ?? "Готовлю отчёт…")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let start = analysis.buildStartedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text("\(max(0, Int(context.date.timeIntervalSince(start)))) с")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder private func content(_ analysis: CallAnalysisModel) -> some View {
        if let report = analysis.report {
            ScrollView {
                Text(report.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        } else if analysis.building {
            placeholder("hourglass", "Отчёт составляется",
                        "Сервис читает стенограмму звонка. На длинном звонке и бесплатной модели это может занять пару минут.")
        } else {
            explanation(analysis)
        }
    }

    @ViewBuilder private func explanation(_ analysis: CallAnalysisModel) -> some View {
        switch analysis.buildCheck {
        case AnalysisRules.checkNotSet:
            VStack(spacing: 12) {
                placeholder("key", "Анализ не настроен", AnalysisError.configMessage(analysis.configCheck)
                            + " Настройки → «Анализ звонка»: сервис, модель и API-ключ.")
                SettingsLink { Text("Открыть настройки") }
            }
        case AnalysisRules.checkNoLines:
            placeholder("text.bubble", "Реплик пока нет", "Отчёт появится, когда в звонке будут фразы.")
        default:
            placeholder("doc.text", "Отчёта ещё нет", "Нажмите «Обновить», чтобы составить отчёт по звонку.")
        }
    }

    private func placeholder(_ icon: String, _ title: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func savedRow(_ text: String, _ url: URL) -> some View {
        HStack(spacing: 8) {
            Label(text, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Показать") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link)
                .accessibilityHint("Показать файл в Finder")
        }
        .font(.callout)
    }

    private func buttons(_ analysis: CallAnalysisModel) -> some View {
        HStack(spacing: 10) {
            Button {
                analysis.buildReport()
            } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            .disabled(analysis.buildCheck != AnalysisRules.checkOK)
            .accessibilityHint("Составить отчёт заново по всем репликам звонка")
            Button {
                analysis.copyReport()
            } label: {
                Label("Скопировать", systemImage: "doc.on.doc")
            }
            .disabled(analysis.report == nil)
            .accessibilityHint("Скопировать текст отчёта")
            Button {
                analysis.saveReport()
            } label: {
                Label("Сохранить в TXT", systemImage: "square.and.arrow.down")
            }
            .disabled(analysis.report == nil)
            .accessibilityHint("Сохранить отчёт и стенограмму в ~/Documents/Ponte")
            Spacer()
            Button("Закрыть") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.large)
    }
}
