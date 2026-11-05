import SQLite3
import XCTest
@testable import VoiceCore

final class StoreInsertTests: StoreTestCase {
    func testAnInsertedDictationComesBackInRecent() throws {
        let d = try dictation("a", mode: .cleanup, text: "Fixed text.")
        try store.insert(d)

        let rows = store.recent(5)

        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, "a")
        XCTAssertEqual(row.audioPath, d.audioPath)
        XCTAssertEqual(row.duration, 3)
        XCTAssertEqual(row.mode, .cleanup)
        XCTAssertEqual(row.whisperModel, "ggml-test")
        XCTAssertEqual(row.rawText, "Fixed text.")
        XCTAssertEqual(row.finalText, "Fixed text.")
        XCTAssertEqual(row.cleanupModel, "qwen")
        XCTAssertNil(row.error)
        XCTAssertNil(row.origin)
        XCTAssertEqual(row.createdAt.timeIntervalSince1970, d.createdAt.timeIntervalSince1970, accuracy: 1e-6)
    }

    func testRawAndFinalTextAreKeptApart() throws {
        var d = try dictation("a", mode: .cleanup)
        d.rawText = "um so the the plan"
        d.finalText = "So, the plan"
        try store.insert(d)

        let row = try XCTUnwrap(store.recent(1).first)

        XCTAssertEqual(row.rawText, "um so the the plan")
        XCTAssertEqual(row.finalText, "So, the plan")
    }

    func testAFailedCleanupKeepsWhispersTextAndTheError() throws {
        var d = try dictation("a", mode: .cleanup, text: "whisper's words")
        d.error = "Ollama isn't answering at http://127.0.0.1:11434."
        try store.insert(d)

        let row = try XCTUnwrap(store.recent(1).first)

        XCTAssertEqual(row.finalText, "whisper's words")
        XCTAssertEqual(row.error, "Ollama isn't answering at http://127.0.0.1:11434.")
    }

    func testInsertingTheSameIDReplacesTheRow() throws {
        try store.insert(try dictation("a", text: "first"))
        try store.insert(try dictation("a", text: "second"))

        let rows = store.recent(5)

        XCTAssertEqual(rows.map(\.finalText), ["second"])
        XCTAssertEqual(count("SELECT count(*) FROM dictations"), 1)
    }

    func testSegmentsAreStoredWithTheirSignals() throws {
        let segments = [segment("one", t0: 0, t1: 1.5), segment("two", t0: 1.5, t1: 3)]
        try store.insert(try dictation("a", segments: segments))

        XCTAssertEqual(count("SELECT count(*) FROM segments WHERE dictation_id = 'a'"), 2)
        XCTAssertEqual(count("SELECT count(*) FROM segments WHERE idx = 1 AND text = 'two' AND t0 = 1.5"), 1)
        XCTAssertEqual(count("SELECT count(*) FROM segments WHERE avg_logprob = -0.25 AND no_speech_prob = 0.01"), 2)
        XCTAssertEqual(count("SELECT count(*) FROM segments WHERE compression_ratio = 1.2 AND speech_seconds = 0.9 AND words_per_second = 2.5"), 2)
    }

    func testTimingsAreStoredAndMissingOnesStayNull() throws {
        try store.insert(try dictation("a"))

        XCTAssertEqual(count("SELECT record_ms FROM dictations"), 3000)
        XCTAssertEqual(count("SELECT load_ms FROM dictations"), 10)
        XCTAssertEqual(count("SELECT transcribe_ms FROM dictations"), 400)
        XCTAssertEqual(count("SELECT count(*) FROM dictations WHERE cleanup_ms IS NULL AND paste_ms IS NULL"), 1)
    }

    func testSetPasteTimeFillsInTheLateTiming() throws {
        try store.insert(try dictation("a"))

        store.setPasteTime("a", ms: 85)

        XCTAssertEqual(count("SELECT paste_ms FROM dictations WHERE id = 'a'"), 85)
    }

    func testTextWithQuotesNewlinesAndEmojiRoundTrips() throws {
        let text = "It's \"quoted\"; DROP TABLE dictations; --\nsecond line\ttab \u{1F600} naïve café 日本語"
        try store.insert(try dictation("a", text: text))

        let row = try XCTUnwrap(store.recent(1).first)

        XCTAssertEqual(row.finalText, text)
        XCTAssertEqual(row.rawText, text)
    }

    func testAVeryLongDictationRoundTrips() throws {
        let text = String(repeating: "dictating for a long time. ", count: 40_000)  // about 1 MB
        try store.insert(try dictation("a", text: text))

        XCTAssertEqual(try XCTUnwrap(store.recent(1).first).finalText, text)
    }

    func testStoredDatesKeepTheirFractionOfASecond() throws {
        var d = try dictation("a")
        d.createdAt = Date(timeIntervalSince1970: 1_700_000_000.123)
        try store.insert(d)

        XCTAssertEqual(try XCTUnwrap(store.recent(1).first).createdAt.timeIntervalSince1970,
                       1_700_000_000.123, accuracy: 1e-3)
    }

    func testReinsertingWithFewerSegmentsLeavesNoStaleOnes() throws {
        try store.insert(try dictation("a", segments: [segment("one"), segment("two"), segment("three")]))
        try store.insert(try dictation("a", segments: [segment("only")]))

        XCTAssertEqual(count("SELECT count(*) FROM segments WHERE dictation_id = 'a'"), 1)
    }

    func testConcurrentInsertsAreAllKept() throws {
        let rows = try (0..<40).map { try dictation("row-\($0)", ageDays: Double($0) / 100) }
        let store = store!
        nonisolated(unsafe) var failures = 0
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: rows.count) { i in
            do { try store.insert(rows[i]) } catch { lock.withLock { failures += 1 } }
        }

        XCTAssertEqual(failures, 0)
        XCTAssertEqual(count("SELECT count(*) FROM dictations"), 40)
        XCTAssertEqual(count("SELECT count(*) FROM segments"), 40)
    }
}

final class StoreRecentTests: StoreTestCase {
    func testRecentIsNewestFirst() throws {
        try store.insert(try dictation("old", ageDays: 3))
        try store.insert(try dictation("new", ageDays: 0))
        try store.insert(try dictation("mid", ageDays: 1))

        XCTAssertEqual(store.recent(5).map(\.id), ["new", "mid", "old"])
    }

    func testRecentStopsAtTheLimit() throws {
        for i in 0..<8 { try store.insert(try dictation("d\(i)", ageDays: Double(i))) }

        XCTAssertEqual(store.recent(5).map(\.id), ["d0", "d1", "d2", "d3", "d4"])
        XCTAssertEqual(store.recent(1).map(\.id), ["d0"])
        XCTAssertEqual(store.recent(100).count, 8)
        XCTAssertEqual(store.recent(0).count, 0)
    }

    func testRecentOfAnEmptyHistoryIsEmpty() {
        XCTAssertEqual(store.recent(5).count, 0)
    }

    func testRecentLeavesOutRecordingsTooShortToTranscribe() throws {
        try store.insert(try dictation("quiet", duration: 0.1))
        try store.insert(try dictation("edge", ageDays: 1, duration: Dictation.tooShort))
        try store.insert(try dictation("just-under", ageDays: 2, duration: Dictation.tooShort - 0.01))
        try store.insert(try dictation("fine", ageDays: 3, duration: 2))

        XCTAssertEqual(store.recent(10).map(\.id), ["edge", "fine"])
        XCTAssertEqual(count("SELECT count(*) FROM dictations"), 4, "short ones stay in the history")
    }

    func testRecentCarriesNoSegmentsAndNoTimings() throws {
        try store.insert(try dictation("a", segments: [segment("one"), segment("two")]))

        let row = try XCTUnwrap(store.recent(1).first)

        XCTAssertTrue(row.segments.isEmpty)
        XCTAssertNil(row.timings.record)
    }

    // MARK: Failed rows

    func testAFailedTranscriptionStaysInRecentSoItCanBeTriedAgain() throws {
        let audio = dir.appending(path: "1700000000000.wav")
        try Data([1]).write(to: audio)
        try store.insert(Dictation(audio: audio, duration: 12, mode: .plain, whisperModel: "ggml-test",
                                   error: "The whisper model isn't at /nowhere."))

        let row = try XCTUnwrap(store.recent(5).first)

        XCTAssertEqual(row.finalText, "")
        XCTAssertEqual(row.error, "The whisper model isn't at /nowhere.")
        XCTAssertEqual(row.audioPath, audio.path)
        XCTAssertEqual(row.duration, 12)
    }

    func testATooShortFailureKeepsTheAudioButIsNotListed() throws {
        let audio = dir.appending(path: "short.wav")
        try Data([1]).write(to: audio)
        try store.insert(Dictation(audio: audio, duration: 0.05, mode: .plain, whisperModel: "m",
                                   error: "Too short to transcribe.", origin: .recovered))

        XCTAssertEqual(store.recent(5).count, 0)
        XCTAssertEqual(store.audioPaths(), [audio.path])
    }

    // MARK: Recovered rows

    func testARecoveredRowKeepsItsOriginAndIsDatedByTheRecording() throws {
        let recorded = Date().addingTimeInterval(-5 * 24 * 3600)
        var d = try dictation("r", ageDays: 0)
        d.origin = nil
        try store.insert(d)

        store.setOrigin("r", .recovered, createdAt: recorded)

        let row = try XCTUnwrap(store.recent(5).first)
        XCTAssertEqual(row.origin, .recovered)
        XCTAssertEqual(row.createdAt.timeIntervalSince1970, recorded.timeIntervalSince1970, accuracy: 1e-3)
    }

    func testRecoveredRowsSortByWhenTheyWereRecordedNotWhenTheyWereFound() throws {
        try store.insert(try dictation("today", ageDays: 0))
        try store.insert(try dictation("found-now", ageDays: 0))
        store.setOrigin("found-now", .recovered, createdAt: Date().addingTimeInterval(-3 * 24 * 3600))

        XCTAssertEqual(store.recent(5).map(\.id), ["today", "found-now"])
    }

    func testAnOriginInsertedWithTheRowComesBack() throws {
        var d = try dictation("a")
        d.origin = .recovered
        try store.insert(d)

        XCTAssertEqual(try XCTUnwrap(store.recent(1).first).origin, .recovered)
    }

    func testSetOriginToNilClearsIt() throws {
        var d = try dictation("a")
        d.origin = .recovered
        try store.insert(d)

        store.setOrigin("a", nil, createdAt: d.createdAt)

        XCTAssertNil(try XCTUnwrap(store.recent(1).first).origin)
    }

    func testSetOriginOfAnUnknownIDChangesNothing() throws {
        try store.insert(try dictation("a"))

        store.setOrigin("missing", .recovered, createdAt: Date(timeIntervalSince1970: 0))

        let row = try XCTUnwrap(store.recent(1).first)
        XCTAssertNil(row.origin)
        XCTAssertGreaterThan(row.createdAt.timeIntervalSince1970, 1_000_000)
    }

    func testAnUnknownOriginInTheDatabaseIsReadAsNone() throws {
        try store.insert(try dictation("a"))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE dictations SET origin = 'from-the-future'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        XCTAssertNil(try XCTUnwrap(store.recent(1).first).origin)
    }

    func testAnUnknownModeInTheDatabaseIsReadAsPlain() throws {
        try store.insert(try dictation("a", mode: .cleanup))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE dictations SET mode = 'translate'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        XCTAssertEqual(try XCTUnwrap(store.recent(1).first).mode, .plain)
    }
}

final class StoreRowsAndFilesTests: StoreTestCase {
    func testDeleteRemovesTheRowAndItsSegmentsButKeepsTheAudio() throws {
        try store.insert(try dictation("a", segments: [segment(), segment("two")]))
        try store.insert(try dictation("b"))

        store.delete("a")

        XCTAssertEqual(store.recent(5).map(\.id), ["b"])
        XCTAssertEqual(count("SELECT count(*) FROM segments WHERE dictation_id = 'a'"), 0)
        XCTAssertEqual(count("SELECT count(*) FROM segments WHERE dictation_id = 'b'"), 1)
        XCTAssertTrue(exists("a"), "a retried transcription must not lose the recording")
    }

    func testDeleteOfAnUnknownIDChangesNothing() throws {
        try store.insert(try dictation("a"))

        store.delete("nope")

        XCTAssertEqual(store.recent(5).count, 1)
    }

    func testRetryReplacesAFailedRowWithoutLosingTheAudio() throws {
        // What the app does after a retry: the new row takes over the old one's date.
        let audio = dir.appending(path: "retry.wav")
        try Data([1, 2]).write(to: audio)
        let failed = Dictation(audio: audio, createdAt: Date().addingTimeInterval(-3600), duration: 5, mode: .plain,
                               whisperModel: "m", error: "Whisper failed (-6).")
        try store.insert(failed)
        let retried = try dictation("retried", text: "it worked", audio: audio)
        try store.insert(retried)

        store.setOrigin("retried", failed.origin, createdAt: failed.createdAt)
        store.delete(failed.id)

        let rows = store.recent(5)
        XCTAssertEqual(rows.map(\.id), ["retried"])
        XCTAssertEqual(rows.first?.createdAt.timeIntervalSince1970 ?? 0, failed.createdAt.timeIntervalSince1970, accuracy: 1e-3)
        XCTAssertEqual(store.audioPaths(), [audio.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testAudioPathsListsEveryRowIncludingTheOnesRecentHides() throws {
        try store.insert(try dictation("a"))
        try store.insert(try dictation("tiny", duration: 0.01))

        XCTAssertEqual(store.audioPaths(), [dir.appending(path: "a.wav").path, dir.appending(path: "tiny.wav").path])
    }

    func testAudioPathsOfAnEmptyHistoryIsEmpty() {
        XCTAssertEqual(store.audioPaths(), [])
    }

    func testRecoveredAudioIsNotRecoveredTwice() throws {
        // Recovery asks for the known paths, so every row must give its path back.
        let audio = dir.appending(path: "1700000000000.wav")
        try Data([1]).write(to: audio)
        try store.insert(Dictation(audio: audio, duration: 0, mode: .plain, whisperModel: "m", error: "Too short to transcribe.", origin: .recovered))

        XCTAssertEqual(Recovery.orphans(in: dir, known: store.audioPaths()).map(\.lastPathComponent), [])
    }
}

final class StoreOpeningTests: StoreTestCase {
    func testTheHistoryIsStillThereAfterReopening() throws {
        try store.insert(try dictation("a", text: "kept"))
        store = nil

        let reopened = try Store(url: databaseURL)

        XCTAssertEqual(reopened.recent(5).map(\.finalText), ["kept"])
        XCTAssertEqual(reopened.audioPaths(), [dir.appending(path: "a.wav").path])
    }

    func testTwoStoresOnTheSameFileSeeEachOthersRows() throws {
        let other = try Store(url: databaseURL)
        try store.insert(try dictation("a"))
        try other.insert(try dictation("b", ageDays: 1))

        XCTAssertEqual(store.recent(5).map(\.id), ["a", "b"])
        XCTAssertEqual(other.recent(5).map(\.id), ["a", "b"])
    }

    func testMissingFoldersAreCreated() throws {
        let nested = dir.appending(path: "a/b/c/voice.sqlite")

        let nestedStore = try Store(url: nested)
        try nestedStore.insert(try dictation("a"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertEqual(nestedStore.recent(5).count, 1)
    }

    func testADatabaseFromBeforeOriginExistedIsUpgradedAndKeepsItsRows() throws {
        let old = dir.appending(path: "old.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(old.path, &db), SQLITE_OK)
        let sql = """
            CREATE TABLE dictations (
              id TEXT PRIMARY KEY, created_at REAL NOT NULL, audio_path TEXT NOT NULL, duration REAL NOT NULL,
              mode TEXT NOT NULL, whisper_model TEXT NOT NULL, raw_text TEXT NOT NULL, final_text TEXT NOT NULL,
              cleanup_model TEXT, cleanup_system TEXT,
              record_ms INTEGER, load_ms INTEGER, transcribe_ms INTEGER, cleanup_ms INTEGER, paste_ms INTEGER,
              error TEXT);
            INSERT INTO dictations VALUES ('legacy', 1700000000, '/x/legacy.wav', 4.0, 'plain', 'ggml-old',
              'old words', 'old words', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let upgraded = try Store(url: old)
        var fresh = try dictation("fresh", ageDays: 0)
        fresh.origin = .recovered
        try upgraded.insert(fresh)

        let rows = upgraded.recent(5)
        XCTAssertEqual(rows.map(\.id), ["fresh", "legacy"])
        XCTAssertEqual(rows.last?.finalText, "old words")
        XCTAssertNil(rows.last?.origin)
        XCTAssertEqual(rows.first?.origin, .recovered)
    }

    func testOpeningTwiceDoesNotTryToAddTheColumnAgain() throws {
        XCTAssertNoThrow(try Store(url: databaseURL))
        XCTAssertNoThrow(try Store(url: databaseURL))
    }

    func testAFolderInPlaceOfTheDatabaseThrowsAStoreError() throws {
        let folder = dir.appending(path: "folder.sqlite", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertThrowsError(try Store(url: folder)) { error in
            guard case VoiceError.store = error else { return XCTFail("expected VoiceError.store, got \(error)") }
        }
    }

    func testAFileInPlaceOfTheFolderThrows() throws {
        let file = try writeFile(Data([1]), named: "not-a-folder", in: dir)

        XCTAssertThrowsError(try Store(url: file.appending(path: "voice.sqlite")))
    }
}

/// Deleting history deletes audio, which cannot be undone, so every edge of the cutoff
/// is pinned down here.
final class StorePruneTests: StoreTestCase {
    private let thirtyDays: TimeInterval = 30 * 24 * 3600

    func testThirtyDaysRemovesOldRowsAndTheirAudioFiles() throws {
        try store.insert(try dictation("old", ageDays: 31))
        try store.insert(try dictation("older", ageDays: 90))
        try store.insert(try dictation("recent", ageDays: 1))

        let removed = store.prune(before: Date().addingTimeInterval(-thirtyDays))

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(store.recent(10).map(\.id), ["recent"])
        XCTAssertEqual(count("SELECT count(*) FROM dictations"), 1)
        XCTAssertFalse(exists("old"))
        XCTAssertFalse(exists("older"))
        XCTAssertTrue(exists("recent"))
    }

    func testPruneRemovesTheSegmentsOfRemovedRowsOnly() throws {
        try store.insert(try dictation("old", ageDays: 40, segments: [segment("a"), segment("b"), segment("c")]))
        try store.insert(try dictation("new", ageDays: 2, segments: [segment("d"), segment("e")]))

        store.prune(before: Date().addingTimeInterval(-thirtyDays))

        XCTAssertEqual(count("SELECT count(*) FROM segments WHERE dictation_id = 'old'"), 0)
        XCTAssertEqual(count("SELECT count(*) FROM segments WHERE dictation_id = 'new'"), 2)
        XCTAssertEqual(count("SELECT count(*) FROM segments"), 2)
    }

    func testForeverRemovesNothing() throws {
        // Forever means the app never prunes, and a cutoff in the far past matches no row.
        try store.insert(try dictation("a", ageDays: 400))
        try store.insert(try dictation("b", ageDays: 4000))

        let removed = store.prune(before: .distantPast)

        XCTAssertEqual(removed, 0)
        XCTAssertEqual(count("SELECT count(*) FROM dictations"), 2)
        XCTAssertEqual(count("SELECT count(*) FROM segments"), 2)
        XCTAssertTrue(exists("a"))
        XCTAssertTrue(exists("b"))
    }

    func testRowsJustInsideAndJustOutsideThirtyDays() throws {
        try store.insert(try dictation("inside", ageDays: 29.9))
        try store.insert(try dictation("outside", ageDays: 30.1))

        store.prune(before: Date().addingTimeInterval(-thirtyDays))

        XCTAssertEqual(store.recent(10).map(\.id), ["inside"])
        XCTAssertTrue(exists("inside"))
        XCTAssertFalse(exists("outside"))
    }

    func testARowDatedExactlyAtTheCutoffStays() throws {
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        var d = try dictation("edge")
        d.createdAt = cutoff
        try store.insert(d)

        XCTAssertEqual(store.prune(before: cutoff), 0)
        XCTAssertTrue(exists("edge"))
    }

    func testPruningTwiceRemovesNothingTheSecondTime() throws {
        try store.insert(try dictation("old", ageDays: 45))
        let cutoff = Date().addingTimeInterval(-thirtyDays)

        XCTAssertEqual(store.prune(before: cutoff), 1)
        XCTAssertEqual(store.prune(before: cutoff), 0)
    }

    func testPruningAnEmptyHistoryIsFine() {
        XCTAssertEqual(store.prune(before: Date()), 0)
    }

    func testRowsThatRecentHidesArePrunedToo() throws {
        try store.insert(try dictation("tiny", ageDays: 50, duration: 0.05))
        let failed = Dictation(audio: dir.appending(path: "failed.wav"), createdAt: Date().addingTimeInterval(-50 * 24 * 3600),
                               duration: 8, mode: .plain, whisperModel: "m", error: "Whisper failed (-6).")
        try Data([1]).write(to: dir.appending(path: "failed.wav"))
        try store.insert(failed)

        XCTAssertEqual(store.prune(before: Date().addingTimeInterval(-thirtyDays)), 2)
        XCTAssertFalse(exists("tiny"))
        XCTAssertFalse(exists("failed"))
        XCTAssertEqual(store.audioPaths(), [])
    }

    func testARowWhoseAudioIsAlreadyGoneIsStillRemoved() throws {
        try store.insert(try dictation("ghost", ageDays: 60, makeAudio: false))
        try store.insert(try dictation("real", ageDays: 60))

        let removed = store.prune(before: Date().addingTimeInterval(-thirtyDays))

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(count("SELECT count(*) FROM dictations"), 0)
        XCTAssertFalse(exists("real"))
    }

    func testPruneLeavesFilesNoRowOwns() throws {
        // An orphan is a recording waiting to be recovered, never something to sweep.
        let orphan = try writeFile(Data([9, 9]), named: "1700000000000.wav", in: dir)
        let notes = try writeFile(Data([9]), named: "notes.txt", in: dir)
        try store.insert(try dictation("old", ageDays: 60))

        store.prune(before: Date())

        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path))
    }

    func testPruneRemovesFilesWithSpacesAndUnicodeInTheirPaths() throws {
        let folder = dir.appending(path: "Opnames mét spaties", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appending(path: "dictée 1.wav")
        try Data([1]).write(to: audio)
        try store.insert(try dictation("a", ageDays: 60, audio: audio))

        XCTAssertEqual(store.prune(before: Date().addingTimeInterval(-thirtyDays)), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    func testARecoveredRowDatedByItsRecordingFallsInsideThePruneWindowByThatDate() throws {
        // Recovered rows take the date the audio was recorded, so one found after 40 days
        // goes at the next prune, as any other 40 day old dictation would.
        try store.insert(try dictation("found", ageDays: 0))
        store.setOrigin("found", .recovered, createdAt: Date().addingTimeInterval(-40 * 24 * 3600))

        XCTAssertEqual(store.prune(before: Date().addingTimeInterval(-thirtyDays)), 1)
    }

    func testPruneWithAFutureCutoffRemovesEverything() throws {
        try store.insert(try dictation("a", ageDays: 0))
        try store.insert(try dictation("b", ageDays: 1))

        XCTAssertEqual(store.prune(before: Date().addingTimeInterval(3600)), 2)
        XCTAssertEqual(store.recent(5).count, 0)
    }

    func testPruneKeepsTheAudioAnotherRowStillPointsAt() throws {
        // A retry inserts a new row for the same recording before the failed one is deleted.
        let audio = dir.appending(path: "shared.wav")
        try Data([1, 2, 3]).write(to: audio)
        try store.insert(try dictation("failed-old", ageDays: 45, audio: audio))
        try store.insert(try dictation("retry-new", ageDays: 0, audio: audio))

        store.prune(before: Date().addingTimeInterval(-thirtyDays))

        XCTAssertEqual(store.recent(5).map(\.id), ["retry-new"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path),
                      "the surviving row would point at a file that was deleted")
    }
}
