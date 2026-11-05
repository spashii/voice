import Foundation
import SQLite3

public struct Dictation: Sendable, Codable, Identifiable {
    public enum Mode: String, Sendable, Codable {
        /// Whisper's text as it came out.
        case plain
        /// Whisper's text rewritten by the cleanup prompt.
        case cleanup
    }

    /// Milliseconds spent in each stage, for finding where the wait goes.
    public struct Timings: Sendable, Codable {
        public var record: Int?
        public var load: Int?
        public var transcribe: Int?
        public var cleanup: Int?
        public var paste: Int?
        /// The part of `transcribe` spent retrying segments after the stop: what retries
        /// added to the wait for the paste. Retries while speaking cost nothing here.
        public var retry: Int?
    }

    public var id: String
    public var createdAt: Date
    public var audioPath: String
    public var duration: Double
    public var mode: Mode
    public var whisperModel: String
    public var rawText: String
    public var finalText: String
    public var cleanupModel: String?
    public var cleanupSystem: String?
    public var timings: Timings
    public var segments: [Segment]
    /// Set when a stage failed; the dictation then keeps what came before it.
    public var error: String?
    /// Where the recording came from, when it wasn't a dictation that finished normally.
    public var origin: Origin? = nil
    /// The text it had before an agent corrected it, when `finalText` is the correction.
    /// Whisper's own text stays in `rawText` either way.
    public var originalText: String? = nil

    public var corrected: Bool { originalText != nil }

    public enum Origin: String, Sendable, Codable {
        /// Found on disk without a history row at launch, after a crash, a force quit or a
        /// quit while recording, and transcribed then without pasting.
        case recovered
        /// Brought in from another dictation app's history (OpenSuperWhisper), so its past
        /// dictations can serve as a test set. Pruning leaves these alone: they are dated
        /// by when they were spoken, which is usually older than any cutoff.
        case imported
    }

    /// Whisper had nothing to work with, so the row only keeps the audio.
    public static let tooShort: Double = 0.3
}

/// Every dictation and its segments, in SQLite.
public final class Store: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "voice.store")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw VoiceError.store("Can't open \(url.path).")
        }
        // CallStore and voice-cli mcp write to this file from other connections; an insert
        // waits out their transaction instead of failing with "database is locked".
        sqlite3_busy_timeout(db, 5000)
        try exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS dictations (
              id TEXT PRIMARY KEY,
              created_at REAL NOT NULL,
              audio_path TEXT NOT NULL,
              duration REAL NOT NULL,
              mode TEXT NOT NULL,
              whisper_model TEXT NOT NULL,
              raw_text TEXT NOT NULL,
              final_text TEXT NOT NULL,
              cleanup_model TEXT,
              cleanup_system TEXT,
              record_ms INTEGER, load_ms INTEGER, transcribe_ms INTEGER, cleanup_ms INTEGER, paste_ms INTEGER,
              error TEXT,
              origin TEXT
            );
            CREATE TABLE IF NOT EXISTS segments (
              dictation_id TEXT NOT NULL REFERENCES dictations(id) ON DELETE CASCADE,
              idx INTEGER NOT NULL,
              t0 REAL NOT NULL, t1 REAL NOT NULL,
              text TEXT NOT NULL,
              avg_logprob REAL, no_speech_prob REAL, compression_ratio REAL,
              speech_seconds REAL, words_per_second REAL,
              PRIMARY KEY (dictation_id, idx)
            );
            CREATE INDEX IF NOT EXISTS dictations_created ON dictations(created_at);
            """)
        // Databases made before origin existed.
        if !columns("dictations").contains("origin") {
            try exec("ALTER TABLE dictations ADD COLUMN origin TEXT")
        }
        // The rest of the schema, retry records included, comes from the migrations. They run
        // here as well as in CallStore so a process that opens only Store (the app's history,
        // voice-cli transcribe) never writes a dictation the file has no columns for.
        try CallStore.migrate(SQLiteConnection(url: url))
    }

    deinit { sqlite3_close(db) }

    public func insert(_ d: Dictation) throws {
        try queue.sync {
            try exec("BEGIN")
            do {
                // Foreign keys are off, so replacing the row does not cascade: a shorter re-insert
                // would otherwise keep the old row's trailing segments.
                try run("DELETE FROM segments WHERE dictation_id = ?", [d.id])
                try run("DELETE FROM segment_retries WHERE dictation_id = ?", [d.id])
                try run("""
                    INSERT OR REPLACE INTO dictations (id, created_at, audio_path, duration, mode,
                      whisper_model, raw_text, final_text, cleanup_model, cleanup_system, record_ms,
                      load_ms, transcribe_ms, cleanup_ms, paste_ms, error, origin, retry_ms)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [d.id, d.createdAt.timeIntervalSince1970, d.audioPath, d.duration, d.mode.rawValue,
                          d.whisperModel, d.rawText, d.finalText, d.cleanupModel, d.cleanupSystem,
                          d.timings.record, d.timings.load, d.timings.transcribe, d.timings.cleanup,
                          d.timings.paste, d.error, d.origin?.rawValue, d.timings.retry])
                for (i, s) in d.segments.enumerated() {
                    try run("""
                        INSERT OR REPLACE INTO segments (dictation_id, idx, t0, t1, text, avg_logprob, no_speech_prob,
                          compression_ratio, speech_seconds, words_per_second)
                        VALUES (?,?,?,?,?,?,?,?,?,?)
                        """, [d.id, i, s.t0, s.t1, s.text, s.avgLogprob, s.noSpeechProb, s.compressionRatio,
                              s.speechSeconds, s.wordsPerSecond])
                    if let r = s.retry {
                        try run("""
                            INSERT INTO segment_retries (source, dictation_id, segment_idx, t0, t1, first_text,
                              retried_text, logprob_before, logprob_after, flagged, kept, retry_seconds, changed,
                              skipped, created_at)
                            VALUES ('dictation',?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                            """, [d.id, i, s.t0, s.t1, r.firstText, r.retriedText, r.firstLogprob, r.retriedLogprob,
                                  r.flagged ? 1 : 0, r.kept ? 1 : 0, r.seconds, r.changed ? 1 : 0,
                                  r.skipped?.rawValue, d.createdAt.timeIntervalSince1970])
                    }
                }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Whether a row with this id exists, for callers that must not replace it.
    public func contains(_ id: String) -> Bool {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT 1 FROM dictations WHERE id = ?", -1, &statement, nil) == SQLITE_OK
            else { return false }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, id, -1, Self.transient)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    public func setPasteTime(_ id: String, ms: Int) {
        queue.sync { _ = try? run("UPDATE dictations SET paste_ms = ? WHERE id = ?", [ms, id]) }
    }

    /// Dates a row by when its audio was recorded rather than when it was transcribed, and
    /// notes where it came from.
    public func setOrigin(_ id: String, _ origin: Dictation.Origin?, createdAt: Date) {
        queue.sync {
            _ = try? run("UPDATE dictations SET origin = ?, created_at = ? WHERE id = ?",
                         [origin?.rawValue, createdAt.timeIntervalSince1970, id])
        }
    }

    /// Removes a row and its segments but keeps the audio: a retried transcription replaces
    /// the row of the attempt that failed.
    public func delete(_ id: String) {
        queue.sync {
            _ = try? run("DELETE FROM segments WHERE dictation_id = ?", [id])
            _ = try? run("DELETE FROM segment_retries WHERE dictation_id = ?", [id])
            _ = try? run("DELETE FROM dictations WHERE id = ?", [id])
        }
    }

    /// Every audio file the history knows about, to find the ones it doesn't.
    public func audioPaths() -> Set<String> {
        queue.sync { referencedAudioPaths() }
    }

    /// For callers already on the queue, which cannot re-enter it.
    private func referencedAudioPaths() -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT audio_path FROM dictations", -1, &statement, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(statement) }
        var paths: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = sqlite3_column_text(statement, 0) { paths.insert(String(cString: path)) }
        }
        return paths
    }

    /// Deletes the dictations made before this date, with their segments and audio, except
    /// imported ones. Returns how many went.
    @discardableResult
    public func prune(before date: Date) -> Int {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "SELECT audio_path FROM dictations WHERE created_at < ? AND \(Self.notImported)", -1,
                &statement, nil) == SQLITE_OK else { return 0 }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            var paths: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let path = sqlite3_column_text(statement, 0) { paths.append(String(cString: path)) }
            }
            sqlite3_finalize(statement)
            guard !paths.isEmpty else { return 0 }
            // Foreign keys are off in SQLite by default, so the segments go explicitly.
            do {
                try exec("BEGIN")
                for child in ["segments", "segment_retries"] {
                    try run("""
                        DELETE FROM \(child) WHERE dictation_id IN
                          (SELECT id FROM dictations WHERE created_at < ? AND \(Self.notImported))
                        """, [date.timeIntervalSince1970])
                }
                try run("DELETE FROM dictations WHERE created_at < ? AND \(Self.notImported)",
                        [date.timeIntervalSince1970])
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                return 0
            }
            // A retry can point a newer row at the same recording, so only files that no
            // remaining row references are safe to delete.
            let kept = referencedAudioPaths()
            for path in Set(paths) where !kept.contains(path) { try? FileManager.default.removeItem(atPath: path) }
            return paths.count
        }
    }

    /// NULL origins need their own test: `origin <> 'imported'` is not true for NULL.
    private static let notImported = "(origin IS NULL OR origin <> 'imported')"

    /// The newest dictations, without their segments. Recordings too short to transcribe
    /// stay in the history but not in this list, since there's nothing in them to copy.
    public func recent(_ limit: Int) -> [Dictation] {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                SELECT id, created_at, audio_path, duration, mode, whisper_model, raw_text,
                       coalesce(corrected_text, final_text), cleanup_model, error, origin
                FROM dictations WHERE duration >= ?
                ORDER BY created_at DESC LIMIT ?
                """, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, Dictation.tooShort)
            sqlite3_bind_int(statement, 2, Int32(limit))
            var rows: [Dictation] = []
            let text = { (i: Int32) in sqlite3_column_text(statement, i).map { String(cString: $0) } }
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(Dictation(
                    id: text(0) ?? "", createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    audioPath: text(2) ?? "", duration: sqlite3_column_double(statement, 3),
                    mode: Dictation.Mode(rawValue: text(4) ?? "") ?? .plain, whisperModel: text(5) ?? "",
                    rawText: text(6) ?? "", finalText: text(7) ?? "", cleanupModel: text(8), cleanupSystem: nil,
                    timings: Dictation.Timings(), segments: [], error: text(9),
                    origin: text(10).flatMap(Dictation.Origin.init(rawValue:))))
            }
            return rows
        }
    }

    private func columns(_ table: String) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { names.insert(String(cString: name)) }
        }
        return names
    }

    private func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            throw VoiceError.store(text)
        }
    }

    private func run(_ sql: String, _ values: [Any?]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VoiceError.store(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case let v as String: sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(statement, index, Int64(v))
            case let v as Double: sqlite3_bind_double(statement, index, v)
            default: sqlite3_bind_null(statement, index)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw VoiceError.store(String(cString: sqlite3_errmsg(db)))
        }
    }
}
