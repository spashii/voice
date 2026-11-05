import AVFoundation
import Foundation
import SQLite3

/// Brings OpenSuperWhisper's history into Voice's, so the dictations made there can be the
/// test set for transcription quality, next to Voice's own and readable by agents.
///
/// A folder is OpenSuperWhisper's support folder: `recordings.sqlite` and the WAVs it names
/// in `recordings/`. Nothing in it is changed. The database is opened read only and the
/// WAVs are copied, so a folder copied from another Mac imports the same way.
public enum OpenSuperWhisperImport {
    public struct Counts: Sendable, Equatable {
        /// Rows that became dictations.
        public var imported = 0
        /// Rows whose WAV isn't in the folder, so there is nothing to test against.
        public var skipped = 0
        /// Rows an earlier run already imported.
        public var alreadyPresent = 0
    }

    /// What the dictation's whisper model column says, so the imports can be told apart from
    /// Voice's own transcriptions when scoring.
    public static let model = "opensuperwhisper"

    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/ru.starmel.OpenSuperWhisper", directoryHint: .isDirectory)
    }

    /// The id a dictation gets for an OpenSuperWhisper row. It is derived from OSW's own id,
    /// so a second run, or a second copy of the same folder, finds its rows already there.
    public static func dictationID(forOSWID id: String) -> String { "osw-\(id)" }

    public static func run(folder: URL, store: Store, recordings: URL) throws -> Counts {
        let database = folder.appending(path: "recordings.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw VoiceError.store("No recordings.sqlite in \(folder.path).")
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(db)
            throw VoiceError.store("Can't open \(database.path): \(message)")
        }
        defer { sqlite3_close(db) }
        // The same database may be open in OpenSuperWhisper; a read waits out its write.
        sqlite3_busy_timeout(db, 5000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT id, timestamp, fileName, transcription, duration FROM recordings ORDER BY timestamp
            """, -1, &statement, nil) == SQLITE_OK else {
            throw VoiceError.store("\(database.path) isn't an OpenSuperWhisper history: \(String(cString: sqlite3_errmsg(db))).")
        }
        defer { sqlite3_finalize(statement) }

        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let times = Timestamps()
        var counts = Counts()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw VoiceError.store(String(cString: sqlite3_errmsg(db))) }

            let oswID = identifier(statement, 0)
            let id = dictationID(forOSWID: oswID)
            if store.contains(id) {
                counts.alreadyPresent += 1
                continue
            }
            let fileName = (text(statement, 2) as NSString).lastPathComponent
            let source = folder.appending(path: "recordings").appending(path: fileName)
            guard !fileName.isEmpty, FileManager.default.fileExists(atPath: source.path) else {
                counts.skipped += 1
                continue
            }

            let destination = recordings.appending(path: "osw-\(oswID).\(source.pathExtension.lowercased())")
            try copy(source, to: destination)
            let transcription = text(statement, 3)
            // OSW leaves duration at 0 for recordings it transcribed from the microphone, and
            // Voice hides anything under Dictation.tooShort from its lists.
            let stored = sqlite3_column_double(statement, 4)
            let duration = stored > 0 ? stored : length(of: source) ?? 0
            let spoken = times.date(statement, 1, fileName: fileName, file: source)
            try store.insert(Dictation(
                id: id, createdAt: spoken, audioPath: destination.path, duration: duration, mode: .plain,
                whisperModel: model, rawText: transcription, finalText: transcription, cleanupModel: nil,
                cleanupSystem: nil, timings: Dictation.Timings(), segments: [], error: nil, origin: .imported))
            counts.imported += 1
        }
        return counts
    }

    /// OSW's ids are UUIDs, stored as 16 bytes by default; the same UUID as text gives the
    /// same key, so a folder from a version that stores text imports to the same rows.
    private static func identifier(_ statement: OpaquePointer?, _ column: Int32) -> String {
        if sqlite3_column_type(statement, column) == SQLITE_BLOB, sqlite3_column_bytes(statement, column) == 16,
           let bytes = sqlite3_column_blob(statement, column) {
            return UUID(uuid: bytes.load(as: uuid_t.self)).uuidString.lowercased()
        }
        let value = text(statement, column)
        return UUID(uuidString: value)?.uuidString.lowercased() ?? value
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    /// Copies through a name that Recovery doesn't take for a recording, so a copy cut short
    /// is never adopted as a dictation, and the next run overwrites it.
    private static func copy(_ source: URL, to destination: URL) throws {
        let files = FileManager.default
        let partial = destination.appendingPathExtension("partial")
        try? files.removeItem(at: partial)
        try files.copyItem(at: source, to: partial)
        try? files.removeItem(at: destination)
        try files.moveItem(at: partial, to: destination)
    }

    private static func length(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// OSW's `timestamp` column is GRDB's text for a date: UTC, `2026-10-29 10:45:32.878`.
    /// When one doesn't read, the file name (OSW names recordings by their start in whole
    /// seconds) and then the file's own date stand in.
    private final class Timestamps {
        private let fractional = ISO8601DateFormatter()
        private let whole = ISO8601DateFormatter()

        init() {
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            whole.formatOptions = [.withInternetDateTime]
        }

        func date(_ statement: OpaquePointer?, _ column: Int32, fileName: String, file: URL) -> Date {
            let value = OpenSuperWhisperImport.text(statement, column)
            let iso = value.replacingOccurrences(of: " ", with: "T") + "Z"
            if let date = fractional.date(from: iso) ?? whole.date(from: iso) { return date }
            if let seconds = Double((fileName as NSString).deletingPathExtension) {
                return Date(timeIntervalSince1970: seconds)
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            return attributes?[.modificationDate] as? Date ?? Date()
        }
    }
}
