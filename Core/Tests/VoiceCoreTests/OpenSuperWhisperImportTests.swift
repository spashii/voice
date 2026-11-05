import SQLite3
import XCTest
@testable import VoiceCore

/// A fake OpenSuperWhisper folder and a Voice database in temp folders; nothing here reads
/// the real ones.
final class OpenSuperWhisperImportTests: XCTestCase {
    struct Row {
        var id = UUID()
        var timestamp = "2026-10-29 10:45:32.878"
        var fileName = "1793270732.wav"
        var transcription = "Hello from the other app."
        var duration = 2.5
        /// Frames of audio to write at 16 kHz, or nil for a row whose WAV is missing.
        var frames: Int? = 24_000
        /// Stored as the UUID's 16 bytes, as GRDB does, or as text.
        var idAsText = false
    }

    var osw: URL!
    var support: URL!
    var recordings: URL!
    var store: Store!

    override func setUpWithError() throws {
        let root = try makeTempDir(self)
        osw = root.appending(path: "osw", directoryHint: .isDirectory)
        support = root.appending(path: "voice", directoryHint: .isDirectory)
        recordings = support.appending(path: "recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: osw.appending(path: "recordings"), withIntermediateDirectories: true)
        store = try Store(url: support.appending(path: "voice.sqlite"))
        try createDatabase(rows: [])
    }

    // MARK: Fake folder

    /// Rebuilds recordings.sqlite with the table OpenSuperWhisper creates, and writes each
    /// row's WAV.
    func createDatabase(rows: [Row]) throws {
        let url = osw.appending(path: "recordings.sqlite")
        try? FileManager.default.removeItem(at: url)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE "recordings" ("id" TEXT PRIMARY KEY, "timestamp" DATETIME NOT NULL,
              "fileName" TEXT NOT NULL, "transcription" TEXT NOT NULL COLLATE NOCASE, "duration" DOUBLE NOT NULL,
              "status" TEXT NOT NULL DEFAULT 'completed', "progress" DOUBLE NOT NULL DEFAULT 1.0, "sourceFileURL" TEXT);
            """, nil, nil, nil), SQLITE_OK)
        for row in rows {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, """
                INSERT INTO recordings (id, timestamp, fileName, transcription, duration) VALUES (?,?,?,?,?)
                """, -1, &statement, nil), SQLITE_OK)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            if row.idAsText {
                sqlite3_bind_text(statement, 1, row.id.uuidString, -1, transient)
            } else {
                var bytes = row.id.uuid
                withUnsafeBytes(of: &bytes) { _ = sqlite3_bind_blob(statement, 1, $0.baseAddress, 16, transient) }
            }
            sqlite3_bind_text(statement, 2, row.timestamp, -1, transient)
            sqlite3_bind_text(statement, 3, row.fileName, -1, transient)
            sqlite3_bind_text(statement, 4, row.transcription, -1, transient)
            sqlite3_bind_double(statement, 5, row.duration)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
            if let frames = row.frames {
                try writeFile(WAVFile(audio: pcm16Sine(frames: frames)).build().bytes, named: "recordings/\(row.fileName)",
                              in: osw)
            }
        }
    }

    func runImport() throws -> OpenSuperWhisperImport.Counts {
        try OpenSuperWhisperImport.run(folder: osw, store: store, recordings: recordings)
    }

    func counts(imported: Int = 0, skipped: Int = 0, alreadyPresent: Int = 0) -> OpenSuperWhisperImport.Counts {
        var counts = OpenSuperWhisperImport.Counts()
        counts.imported = imported
        counts.skipped = skipped
        counts.alreadyPresent = alreadyPresent
        return counts
    }

    /// Every file under the folder with its bytes and date, to see that nothing changed.
    func snapshot(_ folder: URL) throws -> [String: [Data]] {
        var result: [String: [Data]] = [:]
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)!
        for case let url as URL in files {
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            result[url.path] = [isFolder.boolValue ? Data() : try Data(contentsOf: url),
                                Data("\(modified?.timeIntervalSince1970 ?? 0)".utf8)]
        }
        return result
    }

    func row(_ row: Row) -> Dictation? {
        store.recent(100).first { $0.id == OpenSuperWhisperImport.dictationID(forOSWID: row.id.uuidString.lowercased()) }
    }

    // MARK: What a row becomes

    func testARowBecomesAnImportedDictationWithOSWsTimeDurationAndText() throws {
        let r = Row()
        try createDatabase(rows: [r])

        let result = try runImport()

        XCTAssertEqual(result, counts(imported: 1))
        let d = try XCTUnwrap(row(r))
        XCTAssertEqual(d.id, "osw-" + r.id.uuidString.lowercased())
        XCTAssertEqual(d.origin, .imported)
        XCTAssertEqual(d.whisperModel, "opensuperwhisper")
        XCTAssertEqual(d.mode, .plain)
        XCTAssertEqual(d.rawText, "Hello from the other app.")
        XCTAssertEqual(d.finalText, "Hello from the other app.")
        XCTAssertEqual(d.duration, 2.5)
        XCTAssertNil(d.error)
        XCTAssertNil(d.cleanupModel)
    }

    func testTheTimestampIsReadAsUTC() throws {
        var r = Row()
        r.timestamp = "2026-10-29 10:45:32.878"
        try createDatabase(rows: [r])

        _ = try runImport()

        // 1793270732 is the second in this recording's file name.
        XCTAssertEqual(try XCTUnwrap(row(r)).createdAt.timeIntervalSince1970, 1_793_270_732.878, accuracy: 1e-3)
    }

    func testATimestampWithoutFractionalSecondsReads() throws {
        var r = Row()
        r.timestamp = "2026-10-29 10:45:32"
        try createDatabase(rows: [r])

        _ = try runImport()

        XCTAssertEqual(try XCTUnwrap(row(r)).createdAt.timeIntervalSince1970, 1_793_270_732, accuracy: 1e-3)
    }

    func testAnUnreadableTimestampFallsBackToTheFileNamesSeconds() throws {
        var r = Row()
        r.timestamp = "not a date"
        r.fileName = "1700000123.wav"
        try createDatabase(rows: [r])

        _ = try runImport()

        XCTAssertEqual(try XCTUnwrap(row(r)).createdAt.timeIntervalSince1970, 1_700_000_123, accuracy: 1e-3)
    }

    func testAZeroDurationTakesTheWAVsLengthSoRecentStillListsIt() throws {
        var r = Row()
        r.duration = 0
        r.frames = 24_000
        try createDatabase(rows: [r])

        _ = try runImport()

        let d = try XCTUnwrap(row(r), "a row under Dictation.tooShort would be left out of recent")
        XCTAssertEqual(d.duration, 1.5, accuracy: 1e-6)
    }

    func testTheWAVIsCopiedIntoVoicesRecordingsFolder() throws {
        let r = Row()
        try createDatabase(rows: [r])

        _ = try runImport()

        let d = try XCTUnwrap(row(r))
        XCTAssertTrue(d.audioPath.hasPrefix(recordings.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: d.audioPath)),
                       try Data(contentsOf: osw.appending(path: "recordings/\(r.fileName)")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: recordings.path).count, 1,
                       "no partial copy is left beside it")
    }

    func testTheCopyIsKnownToTheStoreSoRecoveryDoesNotAdoptIt() throws {
        let r = Row()
        try createDatabase(rows: [r])

        _ = try runImport()

        XCTAssertEqual(Recovery.orphans(in: recordings, known: store.audioPaths()), [])
    }

    // MARK: Leaving OpenSuperWhisper alone

    func testNothingInTheOSWFolderChanges() throws {
        try createDatabase(rows: [Row(), Row(fileName: "b.wav"), Row(fileName: "gone.wav", frames: nil)])
        // A read only database in a read only folder still imports, so it is opened read only.
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                              ofItemAtPath: osw.appending(path: "recordings.sqlite").path)
        let folder = osw.path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        let before = try snapshot(osw)

        let result = try runImport()

        XCTAssertEqual(result, counts(imported: 2, skipped: 1))
        XCTAssertEqual(try snapshot(osw), before)
    }

    // MARK: Running twice

    func testRunningAgainImportsNothingTwice() throws {
        try createDatabase(rows: [Row(), Row(fileName: "b.wav", transcription: "second")])
        XCTAssertEqual(try runImport(), counts(imported: 2))
        let rows = store.recent(100)
        let files = try FileManager.default.contentsOfDirectory(atPath: recordings.path).sorted()

        let again = try runImport()

        XCTAssertEqual(again, counts(alreadyPresent: 2))
        XCTAssertEqual(store.recent(100).map(\.id), rows.map(\.id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: recordings.path).sorted(), files)
        XCTAssertEqual(scalarInt(support.appending(path: "voice.sqlite"), "SELECT count(*) FROM dictations"), 2)
    }

    func testARerunImportsOnlyTheRowsAddedSince() throws {
        let first = Row(), second = Row(fileName: "b.wav", transcription: "second")
        try createDatabase(rows: [first])
        _ = try runImport()

        try createDatabase(rows: [first, second])
        let result = try runImport()

        XCTAssertEqual(result, counts(imported: 1, alreadyPresent: 1))
        XCTAssertNotNil(row(second))
    }

    func testARerunKeepsWhatTheHistoryHoldsEvenIfTheTextWasEditedThere() throws {
        let r = Row()
        try createDatabase(rows: [r])
        _ = try runImport()
        var edited = try XCTUnwrap(row(r))
        edited.finalText = "edited in Voice"
        try store.insert(edited)

        _ = try runImport()

        XCTAssertEqual(try XCTUnwrap(row(r)).finalText, "edited in Voice")
    }

    func testTheSameDictationAsTextAndAsBlobIsTheSameRow() throws {
        let r = Row()
        try createDatabase(rows: [r])
        XCTAssertEqual(try runImport(), counts(imported: 1))

        var asText = r
        asText.idAsText = true
        try createDatabase(rows: [asText])

        XCTAssertEqual(try runImport(), counts(alreadyPresent: 1))
    }

    func testTwoFoldersWithTheSameRecordingNameKeepBothRecordings() throws {
        let a = Row(fileName: "1793270732.wav", transcription: "a")
        try createDatabase(rows: [a])
        _ = try runImport()
        let otherMac = Row(fileName: "1793270732.wav", transcription: "b", frames: 8_000)
        try createDatabase(rows: [otherMac])

        XCTAssertEqual(try runImport(), counts(imported: 1))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: recordings.path).count, 2)
        XCTAssertEqual(try XCTUnwrap(row(a)).rawText, "a")
        XCTAssertEqual(try XCTUnwrap(row(otherMac)).rawText, "b")
    }

    // MARK: Rows without a WAV

    func testARowWithoutItsWAVIsSkippedAndCounted() throws {
        let kept = Row(), lost = Row(fileName: "lost.wav", frames: nil)
        try createDatabase(rows: [kept, lost])

        let result = try runImport()

        XCTAssertEqual(result, counts(imported: 1, skipped: 1))
        XCTAssertNotNil(row(kept))
        XCTAssertNil(row(lost))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: recordings.path).count, 1)
    }

    func testASkippedRowImportsOnceItsWAVTurnsUp() throws {
        let r = Row(frames: nil)
        try createDatabase(rows: [r])
        XCTAssertEqual(try runImport(), counts(skipped: 1))

        try writeFile(WAVFile(audio: pcm16Sine(frames: 16_000)).build().bytes, named: "recordings/\(r.fileName)", in: osw)

        XCTAssertEqual(try runImport(), counts(imported: 1))
    }

    func testAFileNameCannotReachOutsideTheRecordingsFolder() throws {
        let outside = Row(fileName: "../escape.wav", frames: nil)
        try createDatabase(rows: [outside])
        try writeFile(WAVFile(audio: pcm16Sine(frames: 16_000)).build().bytes, named: "escape.wav", in: osw)

        XCTAssertEqual(try runImport(), counts(skipped: 1))
    }

    func testACopyCutShortByAnEarlierRunIsReplaced() throws {
        let r = Row()
        try createDatabase(rows: [r])
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let name = "osw-\(r.id.uuidString.lowercased()).wav"
        try Data([9, 9, 9]).write(to: recordings.appending(path: name))
        try Data([9]).write(to: recordings.appending(path: name + ".partial"))

        XCTAssertEqual(try runImport(), counts(imported: 1))

        XCTAssertEqual(try Data(contentsOf: recordings.appending(path: name)),
                       try Data(contentsOf: osw.appending(path: "recordings/\(r.fileName)")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: recordings.path), [name])
    }

    // MARK: Bad folders

    func testAFolderWithoutADatabaseThrows() throws {
        let empty = try makeTempDir(self)

        XCTAssertThrowsError(try OpenSuperWhisperImport.run(folder: empty, store: store, recordings: recordings))
    }

    func testADatabaseThatIsNotOpenSuperWhispersThrows() throws {
        try Data("not sqlite at all".utf8).write(to: osw.appending(path: "recordings.sqlite"))

        XCTAssertThrowsError(try runImport())
        XCTAssertEqual(store.recent(10).count, 0)
    }

    func testAnEmptyHistoryImportsNothing() throws {
        XCTAssertEqual(try runImport(), counts())
    }

    // MARK: Many rows

    func testALargeHistoryImportsInOneRun() throws {
        let rows = (0..<300).map { Row(timestamp: "2025-01-01 00:00:00.000", fileName: "\($0).wav", frames: 1_600) }
        try createDatabase(rows: rows)

        XCTAssertEqual(try runImport(), counts(imported: 300))
        XCTAssertEqual(try runImport(), counts(alreadyPresent: 300))
    }
}

/// The imports exist to be a test set, so Keep history's cutoff has to leave them alone.
final class ImportedPruneTests: StoreTestCase {
    private let thirtyDays: TimeInterval = 30 * 24 * 3600

    func testPruneKeepsImportedRowsAndTheirAudioButStillRemovesOldOnes() throws {
        var imported = try dictation("imported", ageDays: 400, segments: [])
        imported.origin = .imported
        try store.insert(imported)
        try store.insert(try dictation("old", ageDays: 40))
        var recovered = try dictation("recovered", ageDays: 50)
        recovered.origin = .recovered
        try store.insert(recovered)

        let removed = store.prune(before: Date().addingTimeInterval(-thirtyDays))

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(store.recent(10).map(\.id), ["imported"])
        XCTAssertTrue(exists("imported"))
        XCTAssertFalse(exists("old"))
        XCTAssertFalse(exists("recovered"))
    }

    func testPruneWithOnlyImportedRowsRemovesNothing() throws {
        var imported = try dictation("imported", ageDays: 400)
        imported.origin = .imported
        try store.insert(imported)

        XCTAssertEqual(store.prune(before: Date()), 0)
        XCTAssertEqual(count("SELECT count(*) FROM segments WHERE dictation_id = 'imported'"), 1)
    }

    func testContainsFindsARowById() throws {
        try store.insert(try dictation("here"))

        XCTAssertTrue(store.contains("here"))
        XCTAssertFalse(store.contains("not-here"))
    }

    func testTheImportedOriginRoundTrips() throws {
        var d = try dictation("a")
        d.origin = .imported
        try store.insert(d)

        XCTAssertEqual(try XCTUnwrap(store.recent(1).first).origin, .imported)
    }
}
