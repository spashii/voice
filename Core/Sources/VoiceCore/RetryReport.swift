import Foundation

/// Scores the retry pass on real use: every segment's record against the idle references,
/// with OpenAI's English normalizer and jiwer as the open-set evaluation used. Prints
/// aggregates only, never text, so its output can leave the Mac.
public enum RetryReport {
    /// One segment's texts, as the scorer sees them.
    public struct ScoredSegment: Codable, Sendable, Equatable {
        public var first: String
        /// The text kept: the retried one when it replaced the first.
        public var final: String
        public var flagged: Bool
    }

    /// A reference and the segments it covers, in order.
    public struct Unit: Codable, Sendable, Equatable {
        public var id: Int
        public var reference: String
        public var segments: [ScoredSegment]
    }

    /// What the scorer returns for a unit: word errors of the first pass and of the kept
    /// text, overall and on the flagged segments' share of the reference.
    public struct Score: Codable, Sendable, Equatable {
        public var id: Int
        public var words: Int
        public var firstErrors: Int
        public var finalErrors: Int
        public var flaggedWords: Int
        public var flaggedFirstErrors: Int
        public var flaggedFinalErrors: Int

        enum CodingKeys: String, CodingKey {
            case id, words
            case firstErrors = "first_errors"
            case finalErrors = "final_errors"
            case flaggedWords = "flagged_words"
            case flaggedFirstErrors = "flagged_first_errors"
            case flaggedFinalErrors = "flagged_final_errors"
        }
    }

    /// One row of segment_retries, without its text.
    public struct Record: Sendable, Equatable {
        public var flagged: Bool
        public var retried: Bool
        public var kept: Bool
        public var changed: Bool
        public var seconds: Double
        public var createdAt: Date
    }

    public struct Summary: Codable, Sendable, Equatable {
        public struct Counts: Codable, Sendable, Equatable {
            public var total = 0
            public var flagged = 0
            public var retried = 0
            public var kept = 0
            public var changed = 0
        }

        /// Word error rates in percent, nil with no reference words to score.
        public struct WER: Codable, Sendable, Equatable {
            public var first: Double?
            public var retried: Double?
            public var words = 0
        }

        public struct Percentiles: Codable, Sendable, Equatable {
            public var p50: Double?
            public var p90: Double?
            public var n = 0
        }

        public var from: String?
        public var to: String?
        public var segments = Counts()
        public var dictations = 0
        public var callSegments = 0
        public var wer = WER()
        public var werFlagged = WER()
        /// Per dictation with retry records: the retry seconds after the stop, in ms.
        public var pasteLatencyMs = Percentiles()
        /// Per segment decoded again: the second decode's seconds.
        public var retrySeconds = Percentiles()
        public var recordingsWithReference = 0
        public var referenceModels: [String: Int] = [:]

        enum CodingKeys: String, CodingKey {
            case from, to, segments, dictations
            case callSegments = "call_segments"
            case wer
            case werFlagged = "wer_flagged"
            case pasteLatencyMs = "paste_latency_ms"
            case retrySeconds = "retry_seconds"
            case recordingsWithReference = "recordings_with_reference"
            case referenceModels = "reference_models"
        }
    }

    /// Adds it all up. `pasteMs` has one entry per dictation with retry records;
    /// `recordings` counts dictations and calls with at least one reference.
    public static func summarize(records: [Record], dictations: Int, callSegments: Int, pasteMs: [Int],
                                 scores: [Score], recordings: Int, models: [String: Int]) -> Summary {
        var summary = Summary()
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let dates = records.map(\.createdAt)
        summary.from = dates.min().map(day.string)
        summary.to = dates.max().map(day.string)
        summary.segments.total = records.count
        summary.segments.flagged = records.filter(\.flagged).count
        summary.segments.retried = records.filter(\.retried).count
        summary.segments.kept = records.filter(\.kept).count
        summary.segments.changed = records.filter(\.changed).count
        summary.dictations = dictations
        summary.callSegments = callSegments
        let words = scores.reduce(0) { $0 + $1.words }
        summary.wer = Summary.WER(first: rate(scores.reduce(0) { $0 + $1.firstErrors }, words),
                                  retried: rate(scores.reduce(0) { $0 + $1.finalErrors }, words), words: words)
        let flaggedWords = scores.reduce(0) { $0 + $1.flaggedWords }
        summary.werFlagged = Summary.WER(first: rate(scores.reduce(0) { $0 + $1.flaggedFirstErrors }, flaggedWords),
                                         retried: rate(scores.reduce(0) { $0 + $1.flaggedFinalErrors }, flaggedWords),
                                         words: flaggedWords)
        let latency = pasteMs.map(Double.init)
        summary.pasteLatencyMs = Summary.Percentiles(p50: percentile(latency, 0.5), p90: percentile(latency, 0.9),
                                                     n: latency.count)
        let seconds = records.filter(\.retried).map(\.seconds)
        summary.retrySeconds = Summary.Percentiles(p50: percentile(seconds, 0.5).map { round($0, 3) },
                                                   p90: percentile(seconds, 0.9).map { round($0, 3) },
                                                   n: seconds.count)
        summary.recordingsWithReference = recordings
        summary.referenceModels = models
        return summary
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

    static func rate(_ errors: Int, _ words: Int) -> Double? {
        words > 0 ? round(100 * Double(errors) / Double(words), 2) : nil
    }

    static func round(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }

    // MARK: Reading the database

    /// Everything the report needs from the file: the records, the references with the
    /// segments each covers, and the paste latencies.
    public static func load(_ url: URL) throws -> (records: [Record], dictations: Int, callSegments: Int,
                                                    pasteMs: [Int], units: [Unit], recordings: Int,
                                                    models: [String: Int]) {
        _ = try Store(url: url)
        let db = try SQLiteConnection(url: url)
        let records = try db.query("""
            SELECT flagged, retried_text IS NOT NULL, kept, changed, retry_seconds, created_at FROM segment_retries
            """) { Record(flagged: $0.int(0) != 0, retried: $0.int(1) != 0, kept: $0.int(2) != 0,
                          changed: $0.int(3) != 0, seconds: $0.double(4), createdAt: $0.date(5)) }
        let dictations = try db.query(
            "SELECT count(DISTINCT dictation_id) FROM segment_retries WHERE dictation_id IS NOT NULL") { $0.int(0) }
            .first ?? 0
        let callSegments = try db.query("SELECT count(*) FROM segment_retries WHERE call_id IS NOT NULL") { $0.int(0) }
            .first ?? 0
        let pasteMs = try db.query("""
            SELECT coalesce(retry_ms, 0) FROM dictations
            WHERE id IN (SELECT dictation_id FROM segment_retries WHERE dictation_id IS NOT NULL)
            """) { $0.int(0) }
        let references = try db.query("""
            SELECT id, source, dictation_id, call_id, t0, t1, text, model FROM retry_references WHERE text IS NOT NULL
            """) { row in
            (id: row.int(0), source: row.text(1), dictationID: row.string(2), callID: row.string(3), t0: row.double(4),
             t1: row.double(5), text: row.text(6), model: row.text(7))
        }
        let segmentColumns = "first_text, retried_text, kept, flagged"
        let readSegment = { (row: SQLiteRow) in
            ScoredSegment(first: row.text(0), final: row.int(2) != 0 ? row.text(1) : row.text(0),
                          flagged: row.int(3) != 0)
        }
        var units: [Unit] = []
        for reference in references {
            let segments: [ScoredSegment]
            if let id = reference.dictationID {
                segments = try db.query("""
                    SELECT \(segmentColumns) FROM segment_retries WHERE dictation_id = ? ORDER BY segment_idx
                    """, [id], readSegment)
            } else {
                // A segment belongs to the stretch its middle falls in.
                segments = try db.query("""
                    SELECT \(segmentColumns) FROM segment_retries
                    WHERE call_id = ? AND source = ? AND (t0 + t1) / 2 >= ? AND (t0 + t1) / 2 < ? ORDER BY t0
                    """, [reference.callID, reference.source, reference.t0, reference.t1], readSegment)
            }
            units.append(Unit(id: reference.id, reference: reference.text, segments: segments))
        }
        let recordings = Set(references.map { $0.dictationID ?? $0.callID ?? "" }).count
        let models = references.reduce(into: [String: Int]()) { $0[$1.model, default: 0] += 1 }
        return (records, dictations, callSegments, pasteMs, units, recordings, models)
    }

    // MARK: Scoring

    /// Runs the scorer in Python through uv, with the normalizer and jiwer the open-set
    /// evaluation used, so the two sets of numbers compare. The texts go to a file only this
    /// user can read, in a folder removed afterwards.
    public static func score(_ units: [Unit]) throws -> [Score] {
        guard !units.isEmpty else { return [] }
        guard let uv = findUV() else {
            throw VoiceError.store("retry-report needs uv (https://docs.astral.sh/uv/) to run the scorer.")
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "voice-retry-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "score.py")
        let input = folder.appending(path: "units.json")
        try scorer.write(to: script, atomically: true, encoding: .utf8)
        try JSONEncoder().encode(units).write(to: input)
        let process = Process()
        process.executableURL = uv
        process.arguments = ["run", "--quiet", "--no-project", "--with", "jiwer", "--with", "whisper-normalizer",
                             "python", script.path, input.path]
        process.currentDirectoryURL = folder
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VoiceError.store("The scorer failed (\(process.terminationStatus)).")
        }
        return try JSONDecoder().decode([Score].self, from: data)
    }

    static func findUV() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = path.split(separator: ":").map { "\($0)/uv" }
            + ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// The reference is split among the segments by aligning it with the first pass, so a
    /// flagged segment is scored on the reference words it covers. Reference words the
    /// first pass dropped go to the segment before them. The overall rates are taken on the
    /// whole texts, as the open-set evaluation did.
    static let scorer = #"""
    import json
    import sys

    import jiwer
    from whisper_normalizer.english import EnglishTextNormalizer

    NORMALIZE = EnglishTextNormalizer()


    def words(text):
        return NORMALIZE(text).split()


    def errors(ref, hyp):
        if not ref:
            return len(hyp)
        if not hyp:
            return len(ref)
        out = jiwer.process_words(" ".join(ref), " ".join(hyp))
        return out.substitutions + out.deletions + out.insertions


    def owners(ref, segments):
        hyp, labels = [], []
        for i, segment in enumerate(segments):
            w = words(segment["first"])
            hyp += w
            labels += [i] * len(w)
        owner = [None] * len(ref)
        if not ref or not hyp:
            return owner
        for chunk in jiwer.process_words(" ".join(ref), " ".join(hyp)).alignments[0]:
            if chunk.type in ("equal", "substitute"):
                for k in range(chunk.ref_end_idx - chunk.ref_start_idx):
                    owner[chunk.ref_start_idx + k] = labels[chunk.hyp_start_idx + k]
            elif chunk.type == "delete":
                h = chunk.hyp_start_idx
                label = labels[h - 1] if h > 0 else labels[min(h, len(labels) - 1)]
                for k in range(chunk.ref_start_idx, chunk.ref_end_idx):
                    owner[k] = label
        return owner


    out = []
    for unit in json.load(open(sys.argv[1])):
        ref = words(unit["reference"])
        segments = unit["segments"]
        if not ref:
            continue
        first = words(" ".join(s["first"] for s in segments))
        final = words(" ".join(s["final"] for s in segments))
        score = dict(id=unit["id"], words=len(ref), first_errors=errors(ref, first), final_errors=errors(ref, final),
                     flagged_words=0, flagged_first_errors=0, flagged_final_errors=0)
        owner = owners(ref, segments)
        for i, segment in enumerate(segments):
            if not segment["flagged"]:
                continue
            piece = [w for w, o in zip(ref, owner) if o == i]
            score["flagged_words"] += len(piece)
            score["flagged_first_errors"] += errors(piece, words(segment["first"]))
            score["flagged_final_errors"] += errors(piece, words(segment["final"]))
        out.append(score)
    json.dump(out, sys.stdout)
    """#
}
