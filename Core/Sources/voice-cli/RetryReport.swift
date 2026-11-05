import Foundation
import VoiceCore

/// `voice-cli retry-report` without --json: the rows Settings shows, one column per window.
func printRetryStats(_ summary: RetryStats.Summary) {
    let windows = [summary.lastWeek, summary.allTime]
    func count(_ n: Int, _ percent: Double?) -> String {
        percent.map { "\(n) (\(Int($0.rounded()))%)" } ?? "\(n)"
    }
    func ms(_ value: Double?) -> String { value.map { "\(Int($0)) ms" } ?? "-" }
    let rows: [(String, (RetryStats.Window) -> String)] = [
        ("Segments", { "\($0.segments)" }),
        ("Unsure", { count($0.unsure, $0.unsurePercent) }),
        ("Retried", { count($0.retried, $0.retriedPercent) }),
        ("Changed", { count($0.changed, $0.changedPercent) }),
        ("Not retried", { w in
            w.notRetried.isEmpty ? "0" : w.notRetried.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
                .joined(separator: ", ")
        }),
        ("Words replaced, added, removed", { "\($0.words.replaced), \($0.words.added), \($0.words.removed)" }),
        ("Median confidence change", { w in w.confidenceChange.map { String(format: "%+.2f", $0) } ?? "-" }),
        ("Added paste time p50", { ms($0.pasteMs.p50) }),
        ("Added paste time p90", { ms($0.pasteMs.p90) }),
    ]
    let width = rows.map(\.0.count).max() ?? 0
    let pad = { (text: String, n: Int) in text.padding(toLength: max(n, text.count), withPad: " ", startingAt: 0) }
    print(pad("", width + 2) + pad("7 days", 18) + "All time")
    for (label, value) in rows {
        print(pad(label, width + 2) + pad(value(windows[0]), 18) + value(windows[1]))
    }
}
