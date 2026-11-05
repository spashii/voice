import Foundation

/// What the retry pass has done on real use, read from segment_retries: how many segments
/// whisper was unsure of, how many of those were decoded again, how many came back with
/// different words and which, and what that cost the paste. Settings shows it beside the
/// switch, and `voice-cli retry-report` prints the same numbers.
public enum RetryStats {
    /// The numbers for one stretch of time.
    public struct Window: Sendable, Equatable, Encodable {
        public struct Words: Sendable, Equatable, Encodable {
            public var replaced = 0
            public var added = 0
            public var removed = 0
        }

        public struct Percentiles: Sendable, Equatable, Encodable {
            public var p50: Double?
            public var p90: Double?
            public var n = 0
        }

        /// Every non-empty segment the retry pass looked at.
        public var segments = 0
        public var dictations = 0
        public var callSegments = 0
        /// Flagged: mean log probability under the threshold.
        public var unsure = 0
        public var retried = 0
        /// Retried, kept, and different once case and punctuation are set aside.
        public var changed = 0
        /// Unsure segments not decoded again, by `SegmentRetry.Skip` raw value; "unknown" for
        /// records written before the reason was kept.
        public var notRetried: [String: Int] = [:]
        /// Across the changed segments, from the first pass to the kept text.
        public var words = Words()
        /// Median of the retried text's mean log probability minus the first's.
        public var confidenceChange: Double?
        /// Per dictation the retry pass looked at: retry time after the stop, in ms.
        public var pasteMs = Percentiles()

        public var unsurePercent: Double? { RetryStats.percent(unsure, of: segments) }
        public var retriedPercent: Double? { RetryStats.percent(retried, of: unsure) }
        public var changedPercent: Double? { RetryStats.percent(changed, of: retried) }

        enum CodingKeys: String, CodingKey {
            case segments, dictations
            case callSegments = "call_segments"
            case unsure
            case unsurePercent = "unsure_pct"
            case retried
            case retriedPercent = "retried_pct"
            case changed
            case changedPercent = "changed_pct"
            case notRetried = "not_retried"
            case words
            case confidenceChange = "confidence_change_median"
            case pasteMs = "paste_ms"
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(segments, forKey: .segments)
            try c.encode(dictations, forKey: .dictations)
            try c.encode(callSegments, forKey: .callSegments)
            try c.encode(unsure, forKey: .unsure)
            try c.encode(unsurePercent.map { RetryStats.round($0, 1) }, forKey: .unsurePercent)
            try c.encode(retried, forKey: .retried)
            try c.encode(retriedPercent.map { RetryStats.round($0, 1) }, forKey: .retriedPercent)
            try c.encode(changed, forKey: .changed)
            try c.encode(changedPercent.map { RetryStats.round($0, 1) }, forKey: .changedPercent)
            try c.encode(notRetried, forKey: .notRetried)
            try c.encode(words, forKey: .words)
            try c.encode(confidenceChange.map { RetryStats.round($0, 3) }, forKey: .confidenceChange)
            try c.encode(pasteMs, forKey: .pasteMs)
        }
    }

    /// A retried segment whose words changed, for the list under the numbers.
    public struct Change: Sendable, Equatable, Identifiable {
        public var id: Int64
        /// "dictation", or the call side it came from: "me", "call" or "mix".
        public var source: String
        public var createdAt: Date
        public var diff: WordDiff
    }

    public struct Summary: Sendable, Equatable, Encodable {
        public var lastWeek = Window()
        public var allTime = Window()
        /// Newest first. Not encoded: the report crosses to other machines as numbers only.
        public var recent: [Change] = []

        enum CodingKeys: String, CodingKey {
            case lastWeek = "last_7_days"
            case allTime = "all_time"
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(lastWeek, forKey: .lastWeek)
            try c.encode(allTime, forKey: .allTime)
        }
    }

    /// Reads the file through its own connection, so the app can call it off the main
    /// thread while its stores write. Nothing is written.
    public static func load(_ url: URL, now: Date = Date(), recent: Int = 5) throws -> Summary {
        let db = try SQLiteConnection(url: url)
        var summary = Summary()
        summary.lastWeek = try window(db, since: now.addingTimeInterval(-7 * 24 * 3600))
        summary.allTime = try window(db, since: nil)
        summary.recent = try db.query("""
            SELECT id, source, first_text, retried_text, created_at FROM segment_retries
            WHERE flagged = 1 AND changed = 1 ORDER BY created_at DESC, id DESC LIMIT ?
            """, [recent]) { row in
            Change(id: row.int64(0), source: row.text(1), createdAt: row.date(4),
                   diff: WordDiff(row.text(2), row.text(3)))
        }
        return summary
    }

    /// The counts come from SQL, since every segment of every call has a record; only the
    /// retried rows, a small share, are read for their texts and log probabilities.
    static func window(_ db: SQLiteConnection, since: Date?) throws -> Window {
        let from = since?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
        var window = Window()
        _ = try db.query("""
            SELECT count(*), coalesce(sum(flagged), 0), coalesce(sum(retried_text IS NOT NULL), 0),
              coalesce(sum(changed), 0), coalesce(sum(call_id IS NOT NULL), 0)
            FROM segment_retries WHERE created_at >= ?
            """, [from]) { row in
            window.segments = row.int(0)
            window.unsure = row.int(1)
            window.retried = row.int(2)
            window.changed = row.int(3)
            window.callSegments = row.int(4)
        }
        window.dictations = try db.query("""
            SELECT count(DISTINCT dictation_id) FROM segment_retries WHERE dictation_id IS NOT NULL AND created_at >= ?
            """, [from]) { $0.int(0) }.first ?? 0
        for (reason, count) in try db.query("""
            SELECT coalesce(skipped, 'unknown'), count(*) FROM segment_retries
            WHERE flagged = 1 AND retried_text IS NULL AND created_at >= ? GROUP BY 1
            """, [from], { ($0.text(0), $0.int(1)) }) {
            window.notRetried[reason] = count
        }
        var deltas: [Double] = []
        for row in try db.query("""
            SELECT logprob_after - logprob_before, changed, first_text, retried_text FROM segment_retries
            WHERE flagged = 1 AND retried_text IS NOT NULL AND created_at >= ?
            """, [from], { (delta: $0.optionalDouble(0), changed: $0.int(1) != 0, first: $0.text(2), retried: $0.text(3)) }) {
            if let delta = row.delta { deltas.append(delta) }
            guard row.changed else { continue }
            let diff = WordDiff(row.first, row.retried)
            window.words.replaced += diff.replaced
            window.words.added += diff.added
            window.words.removed += diff.removed
        }
        window.confidenceChange = percentile(deltas, 0.5)
        let paste = try db.query("""
            SELECT coalesce(retry_ms, 0) FROM dictations d
            WHERE created_at >= ? AND EXISTS (SELECT 1 FROM segment_retries r WHERE r.dictation_id = d.id)
            """, [from]) { Double($0.int(0)) }
        window.pasteMs = Window.Percentiles(p50: percentile(paste, 0.5).map { round($0, 0) },
                                            p90: percentile(paste, 0.9).map { round($0, 0) }, n: paste.count)
        return window
    }

    /// Nil with nothing to take a share of, so an empty week shows no rate rather than 0%.
    static func percent(_ part: Int, of whole: Int) -> Double? {
        whole > 0 ? 100 * Double(part) / Double(whole) : nil
    }

    /// Linear between the two nearest ranks, as numpy's default.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = p * Double(sorted.count - 1)
        let low = Int(rank.rounded(.down))
        let high = min(low + 1, sorted.count - 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (rank - Double(low))
    }

    static func round(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}
