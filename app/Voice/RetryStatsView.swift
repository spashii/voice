import SwiftUI
import VoiceCore

/// What the retry pass has done, under its switch: plain numbers for the last 7 days and
/// all time, then the newest retries that changed words. Read off the main thread when
/// Settings opens, after each dictation, and when a call starts or ends.
struct RetryStatsView: View {
    @Environment(AppModel.self) private var model
    @State private var summary: RetryStats.Summary?

    var body: some View {
        Group {
            if let summary {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Color.clear.frame(width: 0, height: 0)
                        Text("7 days").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text("All time").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    }
                    row("Segments", summary) { "\($0.segments)" }
                    row("Unsure", summary) { Self.count($0.unsure, $0.unsurePercent) }
                    row("Retried", summary) { Self.count($0.retried, $0.retriedPercent) }
                    row("Changed", summary) { Self.count($0.changed, $0.changedPercent) }
                    row("Median confidence change", summary) { w in
                        w.confidenceChange.map { String(format: "%+.2f", $0) } ?? ""
                    }
                    row("Added paste time, p50", summary) { Self.ms($0.pasteMs.p50) }
                    row("Added paste time, p90", summary) { Self.ms($0.pasteMs.p90) }
                }
                .monospacedDigit()
                if !summary.recent.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent changes").foregroundStyle(.secondary)
                        ForEach(summary.recent) { change in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Self.label(change.source))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 64, alignment: .leading)
                                Self.words(change.diff)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
        .task(id: refreshKey) {
            let url = Paths.database
            summary = await Task.detached(priority: .utility) { try? RetryStats.load(url) }.value
        }
    }

    /// Changes with each new dictation, and when a call starts or ends.
    private var refreshKey: String {
        "\(model.recent.first?.id ?? "")|\(model.calls?.recording?.id ?? "")"
    }

    private func row(_ title: String, _ summary: RetryStats.Summary,
                     _ value: @escaping (RetryStats.Window) -> String) -> some View {
        GridRow {
            Text(title)
            Text(value(summary.lastWeek)).gridColumnAlignment(.trailing)
            Text(value(summary.allTime)).gridColumnAlignment(.trailing)
        }
    }

    private static func count(_ n: Int, _ percent: Double?) -> String {
        percent.map { "\(n) (\(Int($0.rounded()))%)" } ?? "\(n)"
    }

    private static func ms(_ value: Double?) -> String {
        value.map { "\(Int($0)) ms" } ?? ""
    }

    private static func label(_ source: String) -> String {
        source == "dictation" ? "Dictation" : CallSegment.Channel(rawValue: source)?.label ?? "Call"
    }

    /// Each run of changed words: the first pass's struck through, then the retry's.
    private static func words(_ diff: WordDiff) -> Text {
        var text = Text(verbatim: "")
        for (i, change) in diff.changes.enumerated() {
            if i > 0 {
                text = Text("\(text)\(Text(verbatim: "  ·  ").foregroundStyle(.tertiary))")
            }
            if !change.before.isEmpty {
                let before = Text(verbatim: change.before.joined(separator: " "))
                    .strikethrough()
                    .foregroundStyle(.secondary)
                text = Text("\(text)\(before)")
            }
            if !change.after.isEmpty {
                let after = Text(verbatim: (change.before.isEmpty ? "" : " ") + change.after.joined(separator: " "))
                text = Text("\(text)\(after)")
            }
        }
        return text
    }
}
