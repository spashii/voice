import Foundation
import SQLite3
import Testing
@testable import VoiceCore

private func segment(_ t0: Double, _ text: String, _ logprob: Double) -> Segment {
    Segment(t0: t0, t1: t0 + 2, text: text, avgLogprob: logprob, noSpeechProb: 0, compressionRatio: 1,
            speechSeconds: 2, wordsPerSecond: 1)
}

private func transcript(_ segments: [Segment], seconds: Double) -> Transcript {
    Transcript(text: segments.map(\.text).joined(separator: " "), segments: segments, seconds: seconds)
}

/// A stand-in for whisper's second decode: says what it was asked and answers with a text,
/// a log probability and a cost.
private final class FakeDecoder: @unchecked Sendable {
    var prompts: [String] = []
    var calls = 0
    let text: String
    let logprob: Double
    let seconds: Double

    init(text: String = "the better text", logprob: Double = -0.1, seconds: Double = 0.6) {
        self.text = text
        self.logprob = logprob
        self.seconds = seconds
    }

    func decode(_ samples: [Float], _ options: WhisperOptions) -> Transcript {
        calls += 1
        prompts.append(options.initialPrompt)
        #expect(options.beamSize == 5)
        #expect(!options.vad)
        return transcript([segment(0, text, logprob)], seconds: seconds)
    }
}

private let tenSeconds = [Float](repeating: 0, count: 16_000 * 10)

@Suite struct SegmentRetryTests {
    private var retry: SegmentRetry {
        var retry = SegmentRetry()
        retry.enabled = true
        return retry
    }

    @Test func flagsBelowTheThresholdAndRetriesWorstFirstUntilTheBudgetIsSpent() throws {
        let first = transcript([segment(0, "sure", -0.2), segment(2, "unsure", -0.9), segment(4, "a bit unsure", -0.7),
                                segment(6, "very unsure", -1.2)], seconds: 2)
        let fake = FakeDecoder()
        let out = try retry.run(first, samples: tenSeconds, options: WhisperOptions(), decode: fake.decode)

        // Budget 0.5 of 2 s: the worst (0.6 s) and the next (1.2 s in all) start under 1 s;
        // the third would start over it.
        #expect(fake.calls == 2)
        #expect(out.retried == 2)
        #expect(abs(out.retrySeconds - 1.2) < 1e-9)
        #expect(abs(out.seconds - 3.2) < 1e-9)
        #expect(out.retrySpans.count == 2)
        let records = out.segments.map(\.retry)
        #expect(records.map { $0?.flagged } == [false, true, true, true])
        #expect(records[0]?.retriedText == nil)
        #expect(records[0]?.skipped == nil)
        #expect(records[2]?.retriedText == nil)
        // Flagged, but the two worse ones had spent the budget.
        #expect(records[2]?.skipped == .budget)
        #expect(records[1]?.skipped == nil)
        #expect(records[3]?.skipped == nil)
        #expect(records[3]?.kept == true)
        #expect(records[3]?.changed == true)
        #expect(records[3]?.firstText == "very unsure")
        #expect(records[3]?.firstLogprob == -1.2)
        #expect(records[3]?.retriedLogprob == -0.1)
        #expect(records[3]?.seconds == 0.6)
        #expect(out.segments[3].text == "the better text")
        #expect(out.segments[3].replaced == "very unsure")
        #expect(out.text == "sure the better text a bit unsure the better text")
        // Each retry reads the segment before it.
        #expect(fake.prompts == ["a bit unsure", "sure"])
    }

    @Test func offStillRecordsEverySegmentButDecodesNothing() throws {
        let first = transcript([segment(0, "unsure", -0.9), segment(2, "", -2)], seconds: 1)
        let fake = FakeDecoder()
        let out = try SegmentRetry().run(first, samples: tenSeconds, options: WhisperOptions(), decode: fake.decode)
        #expect(fake.calls == 0)
        #expect(out.segments[0].retry == SegmentRetry.Record(firstText: "unsure", firstLogprob: -0.9, flagged: true,
                                                              skipped: .off))
        // An empty segment is nothing to retry or score.
        #expect(out.segments[1].retry == nil)
        #expect(out.seconds == 1)
    }

    @Test func keepsTheFirstTextWhenTheRetryIsLessSure() throws {
        let first = transcript([segment(0, "unsure", -0.9)], seconds: 4)
        let out = try retry.run(first, samples: tenSeconds, options: WhisperOptions(),
                                decode: FakeDecoder(text: "worse", logprob: -1.5).decode)
        let record = try #require(out.segments[0].retry)
        #expect(!record.kept)
        #expect(!record.changed)
        #expect(record.retriedText == "worse")
        #expect(out.segments[0].text == "unsure")
    }

    @Test func aRetryThatOnlyChangesPunctuationIsNotAChange() throws {
        let first = transcript([segment(0, "so, that's it", -0.9)], seconds: 4)
        let out = try retry.run(first, samples: tenSeconds, options: WhisperOptions(),
                                decode: FakeDecoder(text: "So that's it.").decode)
        let record = try #require(out.segments[0].retry)
        #expect(record.kept)
        #expect(!record.changed)
    }

    @Test func noBudgetMeansNoRetries() throws {
        var retry = retry
        retry.budget = 0
        let fake = FakeDecoder()
        let out = try retry.run(transcript([segment(0, "unsure", -0.9)], seconds: 4), samples: tenSeconds,
                                options: WhisperOptions(), decode: fake.decode)
        #expect(fake.calls == 0)
        #expect(out.segments[0].retry?.flagged == true)
        #expect(out.segments[0].retry?.skipped == .budget)
    }

    @Test func aSegmentPastTheAudioIsSkippedAsHavingNone() throws {
        let fake = FakeDecoder()
        let out = try retry.run(transcript([segment(20, "unsure", -0.9)], seconds: 4), samples: tenSeconds,
                                options: WhisperOptions(), decode: fake.decode)
        #expect(fake.calls == 0)
        #expect(out.segments[0].retry?.skipped == .noAudio)
    }

    @Test func aChangedWordIsAChangeAndANewCapitalIsNot() throws {
        let first = transcript([segment(0, "the pilot is approved", -0.9)], seconds: 4)
        let out = try retry.run(first, samples: tenSeconds, options: WhisperOptions(),
                                decode: FakeDecoder(text: "The pirate is approved.").decode)
        #expect(out.segments[0].retry?.changed == true)
    }
}

@Suite struct RetryLatencyTests {
    @Test func onlyRetryingAfterTheStopDelaysThePaste() {
        let stop = ContinuousClock.now
        let before = (stop - .seconds(3))..<(stop - .seconds(2))
        let across = (stop - .seconds(1))..<(stop + .milliseconds(500))
        let after = (stop + .seconds(1))..<(stop + .milliseconds(1250))
        #expect(SegmentRetry.seconds(after: stop, of: []) == 0)
        #expect(SegmentRetry.seconds(after: stop, of: [before]) == 0)
        #expect(abs(SegmentRetry.seconds(after: stop, of: [before, across, after]) - 0.75) < 1e-9)
    }

    @Test func aDictationStoresItsRetryLatencyApartFromItsTranscribeTime() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        var d = sampleDictation("hello")
        d.timings = .init(transcribe: 900, retry: 400)
        try store.insert(d)
        let back = try #require(try CallStore(url: url).dictation(d.id))
        #expect(back.timings.transcribe == 900)
        #expect(back.timings.retry == 400)
    }
}

private func counts(_ diff: WordDiff) -> [Int] {
    [diff.replaced, diff.added, diff.removed]
}

@Suite struct WordDiffTests {
    @Test func aSubstitutionIsOneReplacedWord() {
        let diff = WordDiff("the pilot is approved", "the pirate is approved")
        #expect(diff.changes == [.init(before: ["pilot"], after: ["pirate"])])
        #expect(counts(diff) == [1, 0, 0])
    }

    @Test func caseAndPunctuationAreNoChange() {
        let diff = WordDiff("So, that's it", "so that's it.")
        #expect(diff.isEmpty)
        #expect(counts(diff) == [0, 0, 0])
        #expect(WordDiff("“Kymata’s” plan", "kymata's plan").isEmpty)
    }

    @Test func addedAndRemovedWordsAreTheirOwnChanges() {
        let diff = WordDiff("we meet on monday", "we meet monday morning")
        #expect(diff.changes == [.init(before: ["on"], after: []), .init(before: [], after: ["morning"])])
        #expect(counts(diff) == [0, 1, 1])
    }

    @Test func aStretchPairsWhatItCanAndCountsTheRest() {
        let diff = WordDiff("send it to sam today", "send it to Sameer and Dembrane today")
        #expect(diff.changes == [.init(before: ["sam"], after: ["Sameer", "and", "Dembrane"])])
        #expect(counts(diff) == [1, 2, 0])
    }

    @Test func emptySidesAreAllAddedOrAllRemoved() {
        #expect(WordDiff("", "hello there").added == 2)
        #expect(WordDiff("hello there", "").removed == 2)
        #expect(WordDiff("", "").isEmpty)
    }

    @Test func wordsKeepTheirSpellingAndDropPunctuation() {
        #expect(WordDiff.words("Hello, Dembrane's team -- it's 3.5 'quoted'") ==
                ["Hello", "Dembrane's", "team", "it's", "3", "5", "quoted"])
    }
}

private func count(_ url: URL, _ sql: String) throws -> Int {
    try SQLiteConnection(url: url).query(sql) { $0.int(0) }.first ?? -1
}

@Suite struct RetryStorageTests {
    /// A file as Voice 0.4.0 left it: the 0.3.0 tables, the first four migrations, a record
    /// and a reference decode.
    private func fileFrom040() throws -> URL {
        let url = temporaryCallDatabase()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteConnection(url: url)
        try db.exec("""
            CREATE TABLE dictations (id TEXT PRIMARY KEY, created_at REAL NOT NULL, audio_path TEXT NOT NULL,
              duration REAL NOT NULL, mode TEXT NOT NULL, whisper_model TEXT NOT NULL, raw_text TEXT NOT NULL,
              final_text TEXT NOT NULL, cleanup_model TEXT, cleanup_system TEXT, record_ms INTEGER, load_ms INTEGER,
              transcribe_ms INTEGER, cleanup_ms INTEGER, paste_ms INTEGER, error TEXT, origin TEXT);
            CREATE TABLE segments (dictation_id TEXT NOT NULL, idx INTEGER NOT NULL, t0 REAL NOT NULL, t1 REAL NOT NULL,
              text TEXT NOT NULL, avg_logprob REAL, no_speech_prob REAL, compression_ratio REAL, speech_seconds REAL,
              words_per_second REAL, PRIMARY KEY (dictation_id, idx));
            CREATE TABLE voice_migrations (name TEXT PRIMARY KEY, applied_at REAL NOT NULL);
            INSERT INTO dictations VALUES ('old', 1, '/tmp/old.wav', 2, 'plain', 'test', 'from before', 'from before',
              NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
            """)
        for migration in CallStore.migrations.prefix(4) {
            try db.exec(migration.sql)
            try db.run("INSERT INTO voice_migrations VALUES (?, ?)", [migration.name, Date()])
        }
        try db.exec("""
            INSERT INTO segment_retries (source, dictation_id, segment_idx, t0, t1, first_text, retried_text,
              logprob_before, logprob_after, flagged, kept, retry_seconds, changed, created_at)
            VALUES ('dictation', 'old', 0, 0, 2, 'from before', NULL, -0.9, NULL, 1, 0, 0, 0, 1);
            INSERT INTO retry_references (source, dictation_id, t0, t1, model, text, seconds, created_at)
            VALUES ('dictation', 'old', 0, 2, 'ggml-large-v3', 'from before', 3, 1);
            """)
        return url
    }

    @Test func retries2DropsTheReferencesAndKeepsTheRecords() throws {
        let url = try fileFrom040()
        #expect(try count(url, "SELECT count(*) FROM retry_references") == 1)
        let store = try Store(url: url)
        #expect(try CallStore(url: url).appliedMigrations()
            == ["calls-1", "search-1", "speakers-1", "retries-1", "retries-2"])
        #expect(store.recent(5).map(\.finalText) == ["from before"])
        #expect(try count(url, "SELECT count(*) FROM sqlite_master WHERE name LIKE 'retry_references%'") == 0)
        #expect(try count(url, "SELECT count(*) FROM segment_retries WHERE skipped IS NULL") == 1)
        #expect(try count(url, """
            SELECT count(*) FROM sqlite_master WHERE name IN ('segment_retries_created', 'segment_retries_flagged')
            """) == 2)
        // A record from before reasons were kept counts as not retried for an unknown reason.
        #expect(try RetryStats.load(url).allTime.notRetried == ["unknown": 1])
        // Opening it again changes nothing.
        _ = try Store(url: url)
        #expect(try CallStore(url: url).appliedMigrations().count == 5)
    }

    @Test func aFileFrom030GetsBothRetryMigrations() throws {
        let url = temporaryCallDatabase()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteConnection(url: url)
        try db.exec("""
            CREATE TABLE dictations (id TEXT PRIMARY KEY, created_at REAL NOT NULL, audio_path TEXT NOT NULL,
              duration REAL NOT NULL, mode TEXT NOT NULL, whisper_model TEXT NOT NULL, raw_text TEXT NOT NULL,
              final_text TEXT NOT NULL, cleanup_model TEXT, cleanup_system TEXT, record_ms INTEGER, load_ms INTEGER,
              transcribe_ms INTEGER, cleanup_ms INTEGER, paste_ms INTEGER, error TEXT, origin TEXT);
            CREATE TABLE voice_migrations (name TEXT PRIMARY KEY, applied_at REAL NOT NULL);
            """)
        for migration in CallStore.migrations.prefix(3) {
            try db.exec(migration.sql)
            try db.run("INSERT INTO voice_migrations VALUES (?, ?)", [migration.name, Date()])
        }
        _ = try Store(url: url)
        #expect(try count(url, "SELECT count(*) FROM pragma_table_info('segment_retries') WHERE name = 'skipped'") == 1)
        #expect(try count(url, "SELECT count(*) FROM pragma_table_info('dictations') WHERE name = 'retry_ms'") == 1)
        #expect(try count(url, "SELECT count(*) FROM sqlite_master WHERE name = 'retry_references'") == 0)
    }

    @Test func aDictationKeepsARecordPerSegmentAndLosesThemWithItself() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        var d = sampleDictation("sure the better text")
        var kept = segment(2, "the better text", -0.1)
        kept.retry = .init(firstText: "very unsure", firstLogprob: -1.2, flagged: true, retriedText: "the better text",
                           retriedLogprob: -0.1, seconds: 0.6, kept: true, changed: true)
        var plain = segment(0, "sure", -0.2)
        plain.retry = .init(firstText: "sure", firstLogprob: -0.2, flagged: false)
        var held = segment(4, "held back", -0.7)
        held.retry = .init(firstText: "held back", firstLogprob: -0.7, flagged: true, skipped: .budget)
        d.segments = [plain, kept, held]
        try store.insert(d)
        let rows = try SQLiteConnection(url: url).query("""
            SELECT source, dictation_id, segment_idx, first_text, retried_text, logprob_before, logprob_after, flagged,
                   kept, retry_seconds, changed, call_segment_id, skipped FROM segment_retries ORDER BY segment_idx
            """) { row in
            [row.text(0), row.text(1), "\(row.int(2))", row.text(3), row.string(4) ?? "-", "\(row.double(5))",
             row.optionalDouble(6).map { "\($0)" } ?? "-", "\(row.int(7))", "\(row.int(8))", "\(row.double(9))",
             "\(row.int(10))", row.optionalInt(11).map { "\($0)" } ?? "-", row.string(12) ?? "-"]
        }
        #expect(rows == [
            ["dictation", d.id, "0", "sure", "-", "-0.2", "-", "0", "0", "0.0", "0", "-", "-"],
            ["dictation", d.id, "1", "very unsure", "the better text", "-1.2", "-0.1", "1", "1", "0.6", "1", "-", "-"],
            ["dictation", d.id, "2", "held back", "-", "-0.7", "-", "1", "0", "0.0", "0", "-", "budget"],
        ])
        // Inserting again replaces the records rather than adding to them.
        try store.insert(d)
        #expect(try count(url, "SELECT count(*) FROM segment_retries") == 3)
        store.delete(d.id)
        #expect(try count(url, "SELECT count(*) FROM segment_retries") == 0)

        var old = d
        old.id = "old"
        old.createdAt = Date().addingTimeInterval(-40 * 24 * 3600)
        try store.insert(old)
        store.prune(before: Date().addingTimeInterval(-30 * 24 * 3600))
        #expect(try count(url, "SELECT count(*) FROM segment_retries") == 0)
    }

    @Test func aCallSegmentsRecordPointsAtItsRowAndGoesWithARebuild() throws {
        let url = temporaryCallDatabase()
        let calls = try CallStore(url: url)
        let call = try calls.createCall(NewCall(split: true))
        var new = sampleSegment(.me, 61_000, "the better text")
        new.retry = .init(firstText: "very unsure", firstLogprob: -1.2, flagged: true, retriedText: "the better text",
                          retriedLogprob: -0.1, seconds: 0.6, kept: true, changed: true)
        var held = sampleSegment(.call, 63_000, "held back")
        held.retry = .init(firstText: "held back", firstLogprob: -0.8, flagged: true, skipped: .off)
        let stored = try calls.appendSegments(call.id, [new, held, sampleSegment(.call, 62_000, "no record")])
        let rows = try SQLiteConnection(url: url).query(
            "SELECT source, call_id, call_segment_id, t0, t1, kept, skipped FROM segment_retries ORDER BY t0") { row in
            "\(row.text(0)) \(row.text(1)) \(row.int(2)) \(row.double(3)) \(row.double(4)) \(row.int(5)) \(row.string(6) ?? "-")"
        }
        #expect(rows == ["me \(call.id) \(stored[0].id) 61.0 62.5 1 -", "call \(call.id) \(stored[1].id) 63.0 64.5 0 off"])
        try calls.deleteSegments(call.id)
        #expect(try count(url, "SELECT count(*) FROM segment_retries") == 0)
    }
}

@Suite struct RetryStatsTests {
    private func record(_ first: String, _ logprob: Double, retried: String? = nil, after: Double? = nil,
                        skipped: SegmentRetry.Skip? = nil) -> SegmentRetry.Record {
        let flagged = logprob < -0.6
        let kept = retried != nil && after.map { $0 > logprob } == true
        return .init(firstText: first, firstLogprob: logprob, flagged: flagged, retriedText: retried,
                     retriedLogprob: after, seconds: retried == nil ? 0 : 0.5, kept: kept,
                     changed: kept && !WordDiff(first, retried ?? "").isEmpty, skipped: skipped)
    }

    private func dictation(_ records: [SegmentRetry.Record], daysAgo: Double, retryMs: Int?) -> Dictation {
        var d = sampleDictation("text", at: Date().addingTimeInterval(-daysAgo * 24 * 3600))
        d.timings.retry = retryMs
        d.segments = records.enumerated().map { i, r in
            var s = segment(Double(i) * 2, r.kept ? r.retriedText! : r.firstText, r.kept ? r.retriedLogprob! : r.firstLogprob)
            s.retry = r
            return s
        }
        return d
    }

    /// This week: a dictation with four segments (one sure, one retried and changed, one
    /// retried and kept back, one the budget held back), a dictation with none flagged, and
    /// a call side with one retried and changed. Ten days ago: one flagged with retries off.
    private func filled() throws -> URL {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        try store.insert(dictation([
            record("sure", -0.2),
            record("the pilot is approved", -1.0, retried: "the pirate is approved", after: -0.4),
            record("unsure", -0.8, retried: "worse", after: -1.0),
            record("held back", -0.7, skipped: .budget),
        ], daysAgo: 0, retryMs: 300))
        try store.insert(dictation([record("fine", -0.1)], daysAgo: 1, retryMs: nil))
        try store.insert(dictation([record("off then", -0.9, skipped: .off), record("sure", -0.3)],
                                   daysAgo: 10, retryMs: nil))
        let calls = try CallStore(url: url)
        let call = try calls.createCall(NewCall(split: true))
        var side = sampleSegment(.call, 1000, "we meet monday morning")
        side.retry = record("we meet on monday", -0.9, retried: "we meet monday morning", after: -0.5)
        try calls.appendSegments(call.id, [side])
        return url
    }

    @Test func countsUnsureRetriedAndChangedWithTheirShares() throws {
        let summary = try RetryStats.load(try filled())
        let week = summary.lastWeek
        #expect(week.segments == 6)
        #expect(week.dictations == 2)
        #expect(week.callSegments == 1)
        #expect(week.unsure == 4)
        #expect(week.retried == 3)
        #expect(week.changed == 2)
        #expect(week.unsurePercent.map { RetryStats.round($0, 1) } == 66.7)
        #expect(week.retriedPercent == 75)
        #expect(week.changedPercent.map { RetryStats.round($0, 1) } == 66.7)
        #expect(week.notRetried == ["budget": 1])
        // pilot to pirate; "on" removed and "morning" added.
        #expect(week.words == .init(replaced: 1, added: 1, removed: 1))
        // +0.6, -0.2 and +0.4.
        #expect(week.confidenceChange.map { RetryStats.round($0, 3) } == 0.4)
        // Per dictation: 300 ms and 0.
        #expect(week.pasteMs == .init(p50: 150, p90: 270, n: 2))

        let all = summary.allTime
        #expect(all.segments == 8)
        #expect(all.unsure == 5)
        #expect(all.retried == 3)
        #expect(all.retriedPercent == 60)
        #expect(all.notRetried == ["budget": 1, "off": 1])
        #expect(all.pasteMs.n == 3)
    }

    @Test func recentChangesAreNewestFirstWithTheirSource() throws {
        let summary = try RetryStats.load(try filled())
        #expect(summary.recent.map(\.source) == ["call", "dictation"])
        #expect(summary.recent[1].diff.changes == [.init(before: ["pilot"], after: ["pirate"])])
    }

    @Test func nothingYetGivesNoRatesRatherThanZeros() throws {
        let url = temporaryCallDatabase()
        _ = try Store(url: url)
        let summary = try RetryStats.load(url)
        #expect(summary.allTime.segments == 0)
        #expect(summary.allTime.unsurePercent == nil)
        #expect(summary.allTime.confidenceChange == nil)
        #expect(summary.allTime.pasteMs == .init(p50: nil, p90: nil, n: 0))
        #expect(summary.recent.isEmpty)
    }

    @Test func theJSONIsNumbersOnly() throws {
        let summary = try RetryStats.load(try filled())
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        for text in ["pilot", "pirate", "monday", "held back", "off then"] {
            #expect(!json.contains(text))
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["last_7_days", "all_time"])
        let week = try #require(object["last_7_days"] as? [String: Any])
        #expect(week["retried_pct"] as? Double == 75)
        #expect(week["confidence_change_median"] as? Double == 0.4)
    }

    @Test func percentilesInterpolateBetweenRanks() {
        #expect(RetryStats.percentile([5], 0.9) == 5)
        #expect(RetryStats.percentile([1, 2, 3, 4], 0.5) == 2.5)
        #expect(RetryStats.percentile([10, 0, 20], 0.9) == 18)
        #expect(RetryStats.percentile([], 0.5) == nil)
    }
}
