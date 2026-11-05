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
        #expect(records[2]?.retriedText == nil)
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
        #expect(out.segments[0].retry == SegmentRetry.Record(firstText: "unsure", firstLogprob: -0.9, flagged: true))
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

@Suite struct RetryStorageTests {
    /// A file as Voice 0.3.0 left it: the dictation tables and the first three migrations.
    private func oldDatabase() throws -> URL {
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
        for migration in CallStore.migrations.prefix(3) {
            try db.exec(migration.sql)
            try db.run("INSERT INTO voice_migrations VALUES (?, ?)", [migration.name, Date()])
        }
        return url
    }

    private func count(_ url: URL, _ sql: String) throws -> Int {
        try SQLiteConnection(url: url).query(sql) { $0.int(0) }.first ?? -1
    }

    @Test func theMigrationAddsTheRetryTablesToAnOldFileAndKeepsItsRows() throws {
        let url = try oldDatabase()
        let store = try Store(url: url)
        #expect(try CallStore(url: url).appliedMigrations() == ["calls-1", "search-1", "speakers-1", "retries-1"])
        #expect(store.recent(5).map(\.finalText) == ["from before"])
        #expect(try count(url, "SELECT count(*) FROM segment_retries") == 0)
        #expect(try count(url, "SELECT count(*) FROM retry_references") == 0)
        #expect(try count(url, "SELECT count(*) FROM pragma_table_info('dictations') WHERE name = 'retry_ms'") == 1)
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
        d.segments = [plain, kept]
        try store.insert(d)
        let rows = try SQLiteConnection(url: url).query("""
            SELECT source, dictation_id, segment_idx, first_text, retried_text, logprob_before, logprob_after, flagged,
                   kept, retry_seconds, changed, call_segment_id FROM segment_retries ORDER BY segment_idx
            """) { row in
            [row.text(0), row.text(1), "\(row.int(2))", row.text(3), row.string(4) ?? "-", "\(row.double(5))",
             row.optionalDouble(6).map { "\($0)" } ?? "-", "\(row.int(7))", "\(row.int(8))", "\(row.double(9))",
             "\(row.int(10))", row.optionalInt(11).map { "\($0)" } ?? "-"]
        }
        #expect(rows == [
            ["dictation", d.id, "0", "sure", "-", "-0.2", "-", "0", "0", "0.0", "0", "-"],
            ["dictation", d.id, "1", "very unsure", "the better text", "-1.2", "-0.1", "1", "1", "0.6", "1", "-"],
        ])
        // Inserting again replaces the records rather than adding to them.
        try store.insert(d)
        #expect(try count(url, "SELECT count(*) FROM segment_retries") == 2)
        store.delete(d.id)
        #expect(try count(url, "SELECT count(*) FROM segment_retries") == 0)

        var old = d
        old.id = "old"
        old.createdAt = Date().addingTimeInterval(-40 * 24 * 3600)
        try store.insert(old)
        try RetryReferences(url: url).save(.init(source: "dictation", dictationID: "old", audioPath: old.audioPath,
                                                 t0: 0, t1: 2), model: "m", text: "ref", seconds: 1)
        store.prune(before: Date().addingTimeInterval(-30 * 24 * 3600))
        #expect(try count(url, "SELECT count(*) FROM segment_retries") == 0)
        #expect(try count(url, "SELECT count(*) FROM retry_references") == 0)
    }

    @Test func aCallSegmentsRecordPointsAtItsRowAndGoesWithARebuild() throws {
        let url = temporaryCallDatabase()
        let calls = try CallStore(url: url)
        let call = try calls.createCall(NewCall(split: true))
        var new = sampleSegment(.me, 61_000, "the better text")
        new.retry = .init(firstText: "very unsure", firstLogprob: -1.2, flagged: true, retriedText: "the better text",
                          retriedLogprob: -0.1, seconds: 0.6, kept: true, changed: true)
        let stored = try calls.appendSegments(call.id, [new, sampleSegment(.call, 62_000, "no record")])
        let rows = try SQLiteConnection(url: url).query(
            "SELECT source, call_id, call_segment_id, t0, t1, kept FROM segment_retries") { row in
            "\(row.text(0)) \(row.text(1)) \(row.int(2)) \(row.double(3)) \(row.double(4)) \(row.int(5))"
        }
        #expect(rows == ["me \(call.id) \(stored[0].id) 61.0 62.5 1"])
        try calls.deleteSegments(call.id)
        #expect(try count(url, "SELECT count(*) FROM segment_retries") == 0)
    }
}

@Suite struct RetryReferenceTests {
    @Test func aCallSideIsCutIntoStretchesAtPausesAndBeforeHalfAMinute() {
        let spans = RetryReferences.spans([(0, 3), (3.5, 8), (12, 14), (14.5, 30), (30.2, 44)])
        // 8 to 12 is a pause; 12 to 44 would be over 28 s, so 30.2 starts its own.
        #expect(spans.map { [($0.t0 * 10).rounded() / 10, ($0.t1 * 10).rounded() / 10] }
            == [[0, 8.3], [11.7, 30.3], [29.9, 44.3]])
    }

    @Test func onlyRecordingsWithRecordsAndNoReferenceAreDecoded() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        try store.insert(sampleDictation("no records"))
        var d = sampleDictation("with records")
        var s = segment(0, "with records", -0.3)
        s.retry = .init(firstText: "with records", firstLogprob: -0.3, flagged: false)
        d.segments = [s]
        d.duration = 5
        try store.insert(d)
        let references = try RetryReferences(url: url)
        let unit = try #require(try references.next())
        #expect(unit == .init(source: "dictation", dictationID: d.id, audioPath: d.audioPath, t0: 0, t1: 5))
        try references.save(unit, model: "ggml-large-v3", text: nil, error: "Too short", seconds: 0)
        #expect(try references.next() == nil)
    }

    @Test func aDoneCallsSidesComeUpOneStretchAtATime() throws {
        let url = temporaryCallDatabase()
        let calls = try CallStore(url: url)
        let call = try calls.createCall(NewCall(split: true, audioPath: "/tmp/call.wav"))
        var me = sampleSegment(.me, 1000, "hello")
        me.retry = .init(firstText: "hello", firstLogprob: -0.2, flagged: false)
        var them = sampleSegment(.call, 5000, "hi")
        them.retry = .init(firstText: "hi", firstLogprob: -0.2, flagged: false)
        try calls.appendSegments(call.id, [me, them])
        let references = try RetryReferences(url: url)
        // Not while it records.
        #expect(try references.next() == nil)
        try calls.finishCall(call.id)
        let first = try #require(try references.next())
        #expect(first.source == "me")
        #expect(first.channel == 0)
        try references.save(first, model: "m", text: "hello", seconds: 1)
        let second = try #require(try references.next())
        #expect(second.source == "call")
        #expect(second.channel == 1)
        try references.save(second, model: "m", text: "hi", seconds: 1)
        #expect(try references.next() == nil)
    }

    @Test func runsOnlyWhenTheMacIsIdle() {
        let idle = IdleState(recording: false, userIdleSeconds: 600, onACPower: true, memoryPressure: false,
                             ollamaLoaded: false)
        #expect(idle.allowsReference)
        var state = idle
        state.recording = true
        #expect(!state.allowsReference)
        state = idle
        state.userIdleSeconds = 599
        #expect(!state.allowsReference)
        state = idle
        state.onACPower = false
        #expect(!state.allowsReference)
        state = idle
        state.memoryPressure = true
        #expect(!state.allowsReference)
        state = idle
        state.ollamaLoaded = true
        #expect(!state.allowsReference)
    }
}

@Suite struct RetryReportTests {
    private func record(_ flagged: Bool, retried: Bool = false, kept: Bool = false, changed: Bool = false,
                        seconds: Double = 0, day: Double = 0) -> RetryReport.Record {
        .init(flagged: flagged, retried: retried, kept: kept, changed: changed, seconds: seconds,
              createdAt: Date(timeIntervalSince1970: 1_793_000_000 + day * 86_400))
    }

    @Test func addsUpCountsRatesAndPercentiles() throws {
        let records = [record(false), record(false, day: 3), record(true),
                       record(true, retried: true, kept: true, changed: true, seconds: 0.4),
                       record(true, retried: true, seconds: 0.8)]
        let scores = [
            RetryReport.Score(id: 1, words: 40, firstErrors: 4, finalErrors: 2, flaggedWords: 10,
                              flaggedFirstErrors: 3, flaggedFinalErrors: 1),
            RetryReport.Score(id: 2, words: 60, firstErrors: 6, finalErrors: 6, flaggedWords: 0,
                              flaggedFirstErrors: 0, flaggedFinalErrors: 0),
        ]
        let summary = RetryReport.summarize(records: records, dictations: 3, callSegments: 1,
                                            pasteMs: [0, 0, 100, 300, 1000], scores: scores, recordings: 2,
                                            models: ["ggml-large-v3": 2])
        #expect(summary.segments == .init(total: 5, flagged: 3, retried: 2, kept: 1, changed: 1))
        #expect(summary.from == "2026-10-26")
        #expect(summary.to == "2026-10-29")
        #expect(summary.wer == .init(first: 10, retried: 8, words: 100))
        #expect(summary.werFlagged == .init(first: 30, retried: 10, words: 10))
        #expect(summary.pasteLatencyMs == .init(p50: 100, p90: 720, n: 5))
        #expect(summary.retrySeconds == .init(p50: 0.6, p90: 0.76, n: 2))
        #expect(summary.recordingsWithReference == 2)
        // Aggregates only: the JSON has no field that could carry text.
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        #expect(!json.contains("text"))
    }

    @Test func nothingYetGivesEmptyRatesNotZeros() {
        let summary = RetryReport.summarize(records: [], dictations: 0, callSegments: 0, pasteMs: [], scores: [],
                                            recordings: 0, models: [:])
        #expect(summary.wer.first == nil)
        #expect(summary.pasteLatencyMs.p50 == nil)
        #expect(summary.from == nil)
    }

    @Test func percentilesInterpolateBetweenRanks() {
        #expect(RetryReport.percentile([5], 0.9) == 5)
        #expect(RetryReport.percentile([1, 2, 3, 4], 0.5) == 2.5)
        #expect(RetryReport.percentile([10, 0, 20], 0.9) == 18)
    }

    @Test func loadsEachReferenceWithTheSegmentsItCovers() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        var d = sampleDictation("a b")
        var kept = segment(0, "retried", -0.1)
        kept.retry = .init(firstText: "first", firstLogprob: -1, flagged: true, retriedText: "retried",
                           retriedLogprob: -0.1, seconds: 0.5, kept: true, changed: true)
        var other = segment(2, "plain", -0.2)
        other.retry = .init(firstText: "plain", firstLogprob: -0.2, flagged: false)
        d.segments = [kept, other]
        d.timings.retry = 250
        try store.insert(d)
        let calls = try CallStore(url: url)
        let call = try calls.createCall(NewCall(split: true))
        var inside = sampleSegment(.me, 10_000, "inside")
        inside.retry = .init(firstText: "inside", firstLogprob: -0.2, flagged: false)
        var outside = sampleSegment(.me, 40_000, "outside")
        outside.retry = .init(firstText: "outside", firstLogprob: -0.2, flagged: false)
        try calls.appendSegments(call.id, [inside, outside])
        let references = try RetryReferences(url: url)
        try references.save(.init(source: "dictation", dictationID: d.id, audioPath: "", t0: 0, t1: 4), model: "big",
                            text: "the reference", seconds: 3)
        try references.save(.init(source: "me", callID: call.id, audioPath: "", channel: 0, t0: 9.7, t1: 11.8),
                            model: "big", text: "inside ref", seconds: 1)
        try references.save(.init(source: "call", callID: call.id, audioPath: "", channel: 1, t0: 0, t1: 50),
                            model: "big", text: nil, error: "Too short", seconds: 0)

        let data = try RetryReport.load(url)
        #expect(data.records.count == 4)
        #expect(data.dictations == 1)
        #expect(data.callSegments == 2)
        #expect(data.pasteMs == [250])
        #expect(data.recordings == 2)
        #expect(data.models == ["big": 2])
        #expect(data.units.map(\.reference) == ["the reference", "inside ref"])
        #expect(data.units[0].segments == [.init(first: "first", final: "retried", flagged: true),
                                          .init(first: "plain", final: "plain", flagged: false)])
        #expect(data.units[1].segments == [.init(first: "inside", final: "inside", flagged: false)])
    }
}
