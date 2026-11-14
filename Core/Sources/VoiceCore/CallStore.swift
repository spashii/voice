import Foundation

/// Calls, their transcripts and tags, in the same SQLite file as the dictations, and one
/// full-text index over both. The recorder writes through it while a call runs; the MCP
/// server reads through it, often from another process, so every read goes to the file.
public final class CallStore: @unchecked Sendable {
    /// How often a wait for new segments looks at the file. A segment covers a few seconds of
    /// speech, so half a second adds little delay, and the query is one indexed lookup.
    public static let pollInterval: Duration = .milliseconds(500)

    let db: SQLiteConnection
    let queue = DispatchQueue(label: "voice.calls")
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        // Store owns the dictation tables. Opening it first means they exist before the
        // search index's triggers attach to them, even in a file no dictation has touched.
        _ = try Store(url: url)
        db = try SQLiteConnection(url: url)
    }

    // MARK: Writing, for the recorder

    /// Starts a call, in the recording state unless `new.status` says otherwise.
    @discardableResult
    public func createCall(_ new: NewCall) throws -> Call {
        try queue.sync { try insert(new) }
        return try require(new.id)
    }

    /// Runs on the queue.
    private func insert(_ new: NewCall) throws {
        _ = try db.run("""
            INSERT INTO calls (id, started_at, ended_at, time_zone, app_bundle_id, app_name, device_uid, split,
                               audio_path, status, title, title_source, speakers, file_name, file_hash)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [new.id, new.startedAt, new.endedAt, new.timeZone, new.appBundleID, new.appName, new.deviceUID,
                  new.split, new.audioPath, new.status.rawValue,
                  new.title, new.title.map { _ in (new.titleSource ?? .user).rawValue },
                  new.speakers?.joined(separator: "\u{1F}"), new.fileName, new.fileHash])
    }

    /// Adds segments as they are transcribed, in one transaction, and returns them numbered.
    @discardableResult
    public func appendSegments(_ callID: String, _ segments: [NewCallSegment]) throws -> [CallSegment] {
        guard !segments.isEmpty else { return [] }
        let now = Date()
        return try queue.sync {
            try db.transaction {
                guard try exists(callID) else { throw VoiceError.store("No call \(callID).") }
                return try segments.map { s in
                    try db.run("""
                        INSERT INTO call_segments (call_id, channel, start_ms, end_ms, text, avg_logprob,
                          no_speech_prob, compression_ratio, created_at)
                        VALUES (?,?,?,?,?,?,?,?,?)
                        """, [callID, s.channel.rawValue, s.startMs, s.endMs, s.text, s.avgLogprob, s.noSpeechProb,
                              s.compressionRatio, now])
                    let id = db.lastInsertRowID
                    if let r = s.retry {
                        try db.run("""
                            INSERT INTO segment_retries (source, call_id, call_segment_id, t0, t1, first_text,
                              retried_text, logprob_before, logprob_after, flagged, kept, retry_seconds, changed,
                              skipped, created_at)
                            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                            """, [s.channel.rawValue, callID, id, Double(s.startMs) / 1000, Double(s.endMs) / 1000,
                                  r.firstText, r.retriedText, r.firstLogprob, r.retriedLogprob, r.flagged, r.kept,
                                  r.seconds, r.changed, r.skipped?.rawValue, now])
                    }
                    return CallSegment(id: id, callID: callID, channel: s.channel, startMs: s.startMs,
                                       endMs: s.endMs, text: s.text, avgLogprob: s.avgLogprob,
                                       noSpeechProb: s.noSpeechProb, compressionRatio: s.compressionRatio,
                                       createdAt: now)
                }
            }
        }
    }

    /// Recording has stopped; the rest of the audio is still being transcribed. An end time
    /// already set stays: an import knows its length before it is read.
    public func markTranscribing(_ callID: String, endedAt: Date = Date()) throws {
        try update(callID, "status = 'transcribing', ended_at = coalesce(ended_at, ?)", [endedAt])
    }

    /// An import's stored copy and its end time, written together so the row never shows a
    /// duration without audio to play.
    public func setImportedAudio(_ callID: String, path: String, endedAt: Date) throws {
        try update(callID, "audio_path = ?, ended_at = ?", [path, endedAt])
    }

    /// The transcript is complete. Keeps the end time markTranscribing set, if it ran.
    public func finishCall(_ callID: String, endedAt: Date = Date()) throws {
        try update(callID, "status = 'done', ended_at = coalesce(ended_at, ?)", [endedAt])
    }

    /// Keeps whatever was transcribed, with the reason the rest wasn't.
    public func failCall(_ callID: String, error: String, endedAt: Date = Date()) throws {
        try update(callID, "status = 'failed', error = ?, ended_at = coalesce(ended_at, ?)", [error, endedAt])
    }

    public func setTitle(_ callID: String, _ title: String?) throws {
        try update(callID, "title = ?", [title])
    }

    /// Gives an untitled call the title a model made. Writes only while nobody has set one,
    /// a person's clearing it included, so a title that matters is never replaced and a
    /// cleared one stays cleared. Not an edit: it is not something to undo. Returns whether
    /// it wrote.
    @discardableResult
    public func setAutoTitle(_ callID: String, _ title: String) throws -> Bool {
        try queue.sync {
            try db.run("""
                UPDATE calls SET title = ?, title_source = 'auto'
                WHERE id = ? AND title IS NULL AND title_source IS NULL
                """, [title, callID]) > 0
        }
    }

    /// Marks who set a title that already exists. Returns whether the call has one.
    @discardableResult
    public func setTitleSource(_ callID: String, _ source: TitleSource) throws -> Bool {
        try queue.sync {
            try db.run("UPDATE calls SET title_source = ? WHERE id = ? AND title IS NOT NULL",
                       [source.rawValue, callID]) > 0
        }
    }

    /// Points the call at its audio after the file changed format. The old file is the
    /// caller's to remove.
    public func setAudioPath(_ callID: String, _ path: String) throws {
        try update(callID, "audio_path = ?", [path])
    }

    /// Forgets a call's audio after its file was removed.
    public func clearAudioPath(_ callID: String) throws {
        try update(callID, "audio_path = NULL", [])
    }

    /// Calls still marked recording or transcribing when nothing is recording them: Voice
    /// quit or crashed during the call. The recorder calls this at launch, before it starts
    /// one, so the current call is never a call that ended long ago. Returns how many.
    /// `except` keeps the calls about to be rebuilt live, so a crash during the rebuild
    /// leaves them for the next launch to rebuild.
    @discardableResult
    public func failInterruptedCalls(_ reason: String = "Dictate stopped while recording this call.",
                                     except keep: Set<String> = []) throws -> Int {
        if !keep.isEmpty {
            let calls = try liveCalls().filter { !keep.contains($0.id) }
            for call in calls {
                try failCall(call.id, error: call.fileName != nil ? Self.importInterrupted : reason)
            }
            return calls.count
        }
        return try queue.sync {
            try db.run("""
                UPDATE calls SET status = 'failed',
                  error = CASE WHEN file_name IS NOT NULL THEN ?3 ELSE ?1 END,
                  ended_at = coalesce(ended_at, ?2)
                WHERE status IN ('recording', 'transcribing')
                """, [reason, Date(), Self.importInterrupted])
        }
    }

    /// An import is no recording that stopped: what is left of it is a file to read again.
    static let importInterrupted = "Dictate quit before this file was read. Import it again."

    /// Adds and removes tags; returns the call's tags after. Tags compare without case.
    @discardableResult
    public func tagCall(_ callID: String, add: [String] = [], remove: [String] = []) throws -> [String] {
        let clean = { (tags: [String]) in tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        try queue.sync {
            try db.transaction {
                guard try exists(callID) else { throw VoiceError.store("No call \(callID).") }
                for tag in clean(remove) {
                    try db.run("DELETE FROM call_tags WHERE call_id = ? AND tag = ?", [callID, tag])
                }
                for tag in clean(add) {
                    try db.run("INSERT OR IGNORE INTO call_tags (call_id, tag, created_at) VALUES (?,?,?)",
                               [callID, tag, Date()])
                }
            }
        }
        return try require(callID).tags
    }

    /// Deletes the calls that started before this date, with their segments, tags and audio
    /// files, as Store.prune does for dictations. A call still recording or transcribing is
    /// never deleted, whatever its age: its audio is what a rebuild reads. Returns how many
    /// went.
    @discardableResult
    public func prune(before date: Date) throws -> Int {
        // Files go after the queue is released, so a long pass never blocks a reader.
        let (count, doomed): (Int, [String]) = try queue.sync {
            let old = "started_at < ? AND status NOT IN ('recording', 'transcribing')"
            // The app prunes after every dictation; a lookup first keeps the common case from
            // taking the write lock.
            guard try !db.query("SELECT 1 FROM calls WHERE \(old) LIMIT 1", [date], { _ in 1 }).isEmpty else { return (0, []) }
            // Read in the transaction that deletes the rows, so the files are exactly theirs.
            let rows = try db.transaction { () -> [String?] in
                let paths = try db.query("SELECT audio_path FROM calls WHERE \(old)", [date]) { $0.string(0) }
                // Foreign keys are off in SQLite by default, so the children go explicitly.
                for child in ["call_segments", "call_tags", "segment_retries"] {
                    try db.run("DELETE FROM \(child) WHERE call_id IN (SELECT id FROM calls WHERE \(old))", [date])
                }
                // The call's edits, and its segments', go too. Prefix tests use substr, so an
                // id can't act as a LIKE wildcard. Key term suggestions stay.
                try db.run("""
                    DELETE FROM edits WHERE EXISTS (
                      SELECT 1 FROM calls c WHERE c.started_at < ? AND c.status NOT IN ('recording', 'transcribing')
                        AND (edits.target = 'call:' || c.id
                             OR substr(edits.target, 1, length(c.id) + 6) = 'call:' || c.id || '/'))
                    """, [date])
                try db.run("DELETE FROM calls WHERE \(old)", [date])
                return paths
            }
            // Only files no remaining call points at are safe to delete.
            let kept = Set(try db.query("SELECT audio_path FROM calls WHERE audio_path IS NOT NULL") { $0.text(0) })
            return (rows.count, Set(rows.compactMap { $0 }).filter { !kept.contains($0) })
        }
        for path in doomed { try? FileManager.default.removeItem(atPath: path) }
        return count
    }

    /// How many calls `prune(before:)` would delete.
    public func countCalls(before date: Date) throws -> Int {
        try queue.sync {
            try db.query("SELECT count(*) FROM calls WHERE started_at < ? AND status NOT IN ('recording', 'transcribing')",
                         [date]) { $0.int(0) }.first ?? 0
        }
    }

    /// The finished calls, and the failed ones unless `finishedOnly`, that started before this
    /// date and still point at an audio file. A call still recording or transcribing is never
    /// listed: its audio is what a rebuild reads.
    public func callsWithAudio(before date: Date, finishedOnly: Bool) throws -> [String] {
        try callsWithAudio(finishedBefore: finishedOnly ? date : .distantPast,
                           anyBefore: finishedOnly ? .distantPast : date, keptFrom: nil).map(\.id)
    }

    /// Calls that finished before `finishedBefore`, and calls that finished or failed before
    /// `anyBefore`. `keptFrom` leaves out calls older than it, which a transcript deletion
    /// removes first.
    func callsWithAudio(finishedBefore: Date, anyBefore: Date,
                        keptFrom: Date?) throws -> [(id: String, path: String)] {
        try queue.sync {
            try db.query("""
                SELECT id, audio_path FROM calls
                WHERE audio_path IS NOT NULL
                  AND ((status = 'done' AND started_at < ?1) OR (status IN ('done', 'failed') AND started_at < ?2))
                  AND (?3 IS NULL OR started_at >= ?3)
                ORDER BY started_at
                """, [finishedBefore, anyBefore, keptFrom]) { (id: $0.text(0), path: $0.text(1)) }
        }
    }

    /// Forgets a call's audio and deletes the file, unless another call points at it. Callers
    /// that may race a compression go through `CallRecorder.deleteAudio`. Returns whether a
    /// file was deleted.
    @discardableResult
    public func clearAudio(_ callID: String) throws -> Bool {
        let doomed: String? = try queue.sync {
            try db.transaction {
                guard let path = try db.query("SELECT audio_path FROM calls WHERE id = ?", [callID], { $0.string(0) }).first ?? nil
                else { return nil }
                try db.run("UPDATE calls SET audio_path = NULL WHERE id = ?", [callID])
                let shared = try !db.query("SELECT 1 FROM calls WHERE audio_path = ? LIMIT 1", [path], { _ in 1 }).isEmpty
                return shared ? nil : path
            }
        }
        guard let doomed, FileManager.default.fileExists(atPath: doomed) else { return false }
        return (try? FileManager.default.removeItem(atPath: doomed)) != nil
    }

    /// A call is still being made, failed, or has words in it. Only a finished call with
    /// nothing in it is a recording that heard nothing.
    static func heardSomething(_ calls: String = "calls") -> String {
        """
        (\(calls).status <> 'done' OR \(calls).file_name IS NOT NULL OR EXISTS (SELECT 1 FROM call_segments s WHERE s.call_id = \(calls).id
          AND trim(coalesce(s.corrected_text, s.text), ' ' || char(9, 10, 13)) <> ''))
        """
    }

    /// Removes a call with its segments and tags. The audio file stays where it is.
    public func deleteCall(_ callID: String) throws {
        try queue.sync {
            try db.transaction {
                // Foreign keys are off in SQLite by default, so the children go explicitly.
                for child in ["call_segments", "call_tags", "segment_retries"] {
                    try db.run("DELETE FROM \(child) WHERE call_id = ?", [callID])
                }
                try db.run("DELETE FROM calls WHERE id = ?", [callID])
            }
        }
    }

    /// Clears a call's transcript, and its retry records, so it can be made again from the audio.
    public func deleteSegments(_ callID: String) throws {
        try queue.sync {
            try db.transaction {
                try db.run("DELETE FROM call_segments WHERE call_id = ?", [callID])
                try db.run("DELETE FROM segment_retries WHERE call_id = ?", [callID])
            }
        }
    }

    // MARK: Reading

    /// Calls still marked recording or transcribing: at launch, before failInterruptedCalls,
    /// these are the ones a crash or a quit cut off.
    public func liveCalls() throws -> [Call] {
        try queue.sync {
            try db.query("SELECT \(Self.callColumns) FROM calls WHERE status IN ('recording', 'transcribing')",
                         [], Self.readCall)
        }
    }

    /// Finished calls whose audio is still the WAV they recorded into: ones that finished
    /// before the recorder compressed them, or while it couldn't. Oldest first.
    public func callsAwaitingCompression() throws -> [Call] {
        try queue.sync {
            try db.query("""
                SELECT \(Self.callColumns) FROM calls
                WHERE status = 'done' AND audio_path IS NOT NULL AND lower(audio_path) LIKE '%.wav'
                ORDER BY started_at
                """, [], Self.readCall)
        }
    }

    /// Newest first.
    public func calls(since: Date? = nil, tag: String? = nil, limit: Int = 20) throws -> [Call] {
        try calls(since: since, tag: tag, limit: limit, heardSomething: false)
    }

    /// The newest calls for the menu: a finished call with no words in it is left out.
    public func recentCalls(limit: Int) throws -> [Call] {
        try calls(since: nil, tag: nil, limit: limit, heardSomething: true)
    }

    private func calls(since: Date?, tag: String?, limit: Int, heardSomething: Bool) throws -> [Call] {
        var conditions: [String] = []
        var values: [Any?] = []
        if let since {
            conditions.append("started_at >= ?")
            values.append(since)
        }
        if let tag {
            conditions.append("id IN (SELECT call_id FROM call_tags WHERE tag = ?)")
            values.append(tag.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if heardSomething { conditions.append(Self.heardSomething()) }
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        values.append(limit)
        return try queue.sync {
            try db.query("SELECT \(Self.callColumns) FROM calls \(filter) ORDER BY started_at DESC LIMIT ?",
                         values, Self.readCall)
        }
    }

    public func call(_ id: String) throws -> Call? {
        try queue.sync {
            try db.query("SELECT \(Self.callColumns) FROM calls WHERE id = ?", [id], Self.readCall).first
        }
    }

    /// The import of a file with this SHA-256 that hasn't failed, oldest first: a failed one
    /// doesn't stop the same file being imported again.
    public func importedCall(hash: String) throws -> Call? {
        try queue.sync {
            try db.query("""
                SELECT \(Self.callColumns) FROM calls WHERE file_hash = ? AND status <> 'failed'
                ORDER BY started_at LIMIT 1
                """, [hash], Self.readCall).first
        }
    }

    /// Adds an import's row unless a call already holds the same bytes, checking and inserting
    /// in one transaction so two imports of one file can't both pass the check.
    public func createImport(_ new: NewCall) throws -> (call: Call, duplicate: Bool) {
        guard let hash = new.fileHash else { throw VoiceError.store("An import needs the hash of its file.") }
        let existing: String? = try queue.sync {
            try db.transaction { () -> String? in
                if let found = try db.query("SELECT id FROM calls WHERE file_hash = ? AND status <> 'failed' ORDER BY started_at LIMIT 1",
                                            [hash], { $0.text(0) }).first { return found }
                try insert(new)
                return nil
            }
        }
        return (try require(existing ?? new.id), existing != nil)
    }

    /// The newest call recorded and still recording or transcribing, if any. An import is a
    /// file being read, not something a person is in.
    public func currentCall() throws -> Call? {
        try queue.sync {
            try db.query("""
                SELECT \(Self.callColumns) FROM calls WHERE status IN ('recording', 'transcribing') AND file_name IS NULL
                ORDER BY started_at DESC LIMIT 1
                """, [], Self.readCall).first
        }
    }

    /// A call's segments in the order they were written, after the cursor, from one channel
    /// or all of them. A corrected segment's text is the correction, with whisper's beside it.
    public func segments(_ callID: String, channel: CallSegment.Channel? = nil, after cursor: Int64 = 0,
                         limit: Int = -1) throws -> [CallSegment] {
        try queue.sync {
            try db.query("""
                SELECT \(Self.segmentColumns)
                FROM call_segments WHERE call_id = ? AND id > ? AND (?3 IS NULL OR channel = ?3)
                ORDER BY id LIMIT ?
                """, [callID, cursor, channel?.rawValue, limit], Self.readSegment)
        }
    }

    /// One segment by its id, if it belongs to that call.
    public func segment(_ callID: String, _ segmentID: Int64) throws -> CallSegment? {
        try queue.sync {
            try db.query("SELECT \(Self.segmentColumns) FROM call_segments WHERE call_id = ? AND id = ?",
                         [callID, segmentID], Self.readSegment).first
        }
    }

    /// The newest segment's id across every call: where a wait should start to see only
    /// what is said from now on.
    public func latestCursor() throws -> Int64 {
        try queue.sync {
            try db.query("SELECT coalesce(max(id), 0) FROM call_segments") { $0.int64(0) }.first ?? 0
        }
    }

    /// The transcript as text: both sides merged by time and labeled "Me:" and "Call:" (or
    /// by the call's speakers), or one channel on its own.
    public func transcript(_ callID: String, channel: CallSegment.Channel? = nil) throws -> String {
        CallTranscript.text(try segments(callID, channel: channel), labels: channel == nil,
                            speakers: try call(callID)?.speakers)
    }

    /// Waits until the call has segments after the cursor, the call ends, or the timeout
    /// passes, and returns what there is. Another process writes the segments, so this looks
    /// at the file every pollInterval rather than waiting on anything in memory.
    ///
    /// With no call id it follows the current call; when none is live it waits for one to
    /// start. Cursors rise across calls, so one from an earlier call works for the next.
    public func waitForSegments(_ callID: String?, after cursor: Int64, timeout: Duration,
                                limit: Int = 500) async throws -> SegmentBatch {
        let deadline = ContinuousClock.now + timeout
        var target = callID
        while true {
            if target == nil { target = try currentCall()?.id }
            let timedOut = ContinuousClock.now >= deadline
            if let id = target {
                guard let call = try call(id) else { throw VoiceError.store("No call \(id).") }
                let found = try segments(id, after: cursor, limit: limit + 1)
                if !found.isEmpty || !call.status.isLive || timedOut {
                    let page = Array(found.prefix(limit))
                    return SegmentBatch(call: call, segments: page, cursor: page.last?.id ?? cursor,
                                        more: found.count > limit)
                }
            } else if timedOut {
                return SegmentBatch(call: nil, segments: [], cursor: cursor, more: false)
            }
            try await Task.sleep(for: min(Self.pollInterval, max(deadline - ContinuousClock.now, .zero)))
        }
    }

    /// Best matches first, across call segments and dictations. Every word has to appear;
    /// when nothing has them all, any of them will do.
    public func search(_ query: String, limit: Int = 20) throws -> [SearchHit] {
        guard let words = Self.matchWords(query) else { return [] }
        let all = try queue.sync { try hits(words.joined(separator: " "), limit) }
        guard all.isEmpty, words.count > 1 else { return all }
        return try queue.sync { try hits(words.joined(separator: " OR "), limit) }
    }

    /// Each word becomes a quoted phrase, so punctuation and FTS5's own operators in what
    /// an agent types are searched for rather than parsed. Nil when nothing is searchable.
    private static func matchWords(_ query: String, prefixOnLast: Bool = false) -> [String]? {
        var words = query.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        guard !words.isEmpty else { return nil }
        // Someone still typing the last word means its start, as FTS5 spells a prefix.
        if prefixOnLast { words[words.count - 1] += "*" }
        return words
    }

    /// The calls and dictations whose text the query finds, by the same index and rules as
    /// `search` but one id per recording, not one hit per matching segment.
    func recordingsMatching(_ query: String, prefixOnLast: Bool) throws -> Set<String> {
        guard let words = Self.matchWords(query, prefixOnLast: prefixOnLast) else { return [] }
        func ids(_ match: String) throws -> Set<String> {
            try queue.sync {
                Set(try db.query("SELECT DISTINCT ref_id FROM transcript_search WHERE transcript_search MATCH ?",
                                 [match]) { $0.text(0) })
            }
        }
        let all = try ids(words.joined(separator: " "))
        guard all.isEmpty, words.count > 1 else { return all }
        return try ids(words.joined(separator: " OR "))
    }

    // MARK: Dictations, for agents

    /// Newest first, without segments, leaving out recordings too short to transcribe.
    public func dictations(since: Date? = nil, limit: Int = 20) throws -> [Dictation] {
        try queue.sync {
            try db.query("""
                SELECT \(Self.dictationColumns) FROM dictations WHERE duration >= ? AND created_at >= ?
                ORDER BY created_at DESC LIMIT ?
                """, [Dictation.tooShort, since ?? Date.distantPast, limit], Self.readDictation)
        }
    }

    /// One dictation with its segments.
    public func dictation(_ id: String) throws -> Dictation? {
        try queue.sync {
            guard var dictation = try db.query("SELECT \(Self.dictationColumns) FROM dictations WHERE id = ?", [id],
                                               Self.readDictation).first else { return nil }
            dictation.segments = try db.query("""
                SELECT t0, t1, text, avg_logprob, no_speech_prob, compression_ratio, speech_seconds,
                       words_per_second
                FROM segments WHERE dictation_id = ? ORDER BY idx
                """, [id]) { row in
                Segment(t0: row.double(0), t1: row.double(1), text: row.text(2), avgLogprob: row.double(3),
                        noSpeechProb: row.double(4), compressionRatio: row.double(5), speechSeconds: row.double(6),
                        wordsPerSecond: row.double(7))
            }
            let edits = try db.query("""
                SELECT segment_idx, span, replacement, key_term, char_offset, rejected
                FROM fix_edits WHERE dictation_id = ? ORDER BY idx
                """, [id]) { row in
                FixEdit(segment: row.int(0), span: row.text(1), replacement: row.text(2), keyTerm: row.string(3),
                        offset: row.optionalInt(4), rejected: row.string(5).flatMap(FixEdit.Rejection.init))
            }
            if dictation.mode == .fix || !edits.isEmpty { dictation.fixEdits = edits }
            return dictation
        }
    }

    // MARK: Schema

    /// Applied in order, each once, recorded by name in voice_migrations. A name never
    /// changes once shipped; a change to the schema is a new entry at the end.
    static let migrations: [(name: String, sql: String)] = [
        ("calls-1", """
            CREATE TABLE calls (
              id TEXT PRIMARY KEY,
              started_at REAL NOT NULL,
              ended_at REAL,
              app_bundle_id TEXT,
              app_name TEXT,
              device_uid TEXT,
              split INTEGER NOT NULL DEFAULT 0,
              audio_path TEXT,
              status TEXT NOT NULL DEFAULT 'recording'
                CHECK (status IN ('recording', 'transcribing', 'done', 'failed')),
              title TEXT,
              error TEXT
            );
            CREATE INDEX calls_started ON calls(started_at);
            CREATE INDEX calls_live ON calls(started_at) WHERE status IN ('recording', 'transcribing');
            -- AUTOINCREMENT, so an id is never reused after a delete: ids are the wait cursor.
            CREATE TABLE call_segments (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              call_id TEXT NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
              channel TEXT NOT NULL CHECK (channel IN ('me', 'call', 'mix')),
              start_ms INTEGER NOT NULL,
              end_ms INTEGER NOT NULL,
              text TEXT NOT NULL,
              avg_logprob REAL,
              no_speech_prob REAL,
              compression_ratio REAL,
              created_at REAL NOT NULL
            );
            CREATE INDEX call_segments_call ON call_segments(call_id, id);
            CREATE TABLE call_tags (
              call_id TEXT NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
              tag TEXT NOT NULL COLLATE NOCASE,
              created_at REAL NOT NULL,
              PRIMARY KEY (call_id, tag)
            ) WITHOUT ROWID;
            CREATE INDEX call_tags_tag ON call_tags(tag);
            """),
        // One index for both kinds of text. A call segment's row is its id; a dictation's is
        // minus its rowid, so the two never collide and a trigger finds its row directly.
        // Store writes dictations with INSERT OR REPLACE, which deletes the old row without
        // firing a delete trigger, so the insert trigger clears its rowid first and searches
        // join back to the live rows.
        ("search-1", """
            CREATE VIRTUAL TABLE transcript_search USING fts5(
              text, kind UNINDEXED, ref_id UNINDEXED,
              tokenize = 'porter unicode61 remove_diacritics 2'
            );
            INSERT INTO transcript_search (rowid, text, kind, ref_id)
              SELECT id, text, 'call', call_id FROM call_segments;
            INSERT INTO transcript_search (rowid, text, kind, ref_id)
              SELECT -rowid, final_text, 'dictation', id FROM dictations WHERE final_text <> '';
            CREATE TRIGGER call_segments_search_insert AFTER INSERT ON call_segments BEGIN
              DELETE FROM transcript_search WHERE rowid = new.id;
              INSERT INTO transcript_search (rowid, text, kind, ref_id) VALUES (new.id, new.text, 'call', new.call_id);
            END;
            CREATE TRIGGER call_segments_search_update AFTER UPDATE OF text ON call_segments BEGIN
              DELETE FROM transcript_search WHERE rowid = old.id;
              INSERT INTO transcript_search (rowid, text, kind, ref_id) VALUES (new.id, new.text, 'call', new.call_id);
            END;
            CREATE TRIGGER call_segments_search_delete AFTER DELETE ON call_segments BEGIN
              DELETE FROM transcript_search WHERE rowid = old.id;
            END;
            CREATE TRIGGER dictations_search_insert AFTER INSERT ON dictations BEGIN
              DELETE FROM transcript_search WHERE rowid = -new.rowid;
              INSERT INTO transcript_search (rowid, text, kind, ref_id)
                SELECT -new.rowid, new.final_text, 'dictation', new.id WHERE new.final_text <> '';
            END;
            CREATE TRIGGER dictations_search_update AFTER UPDATE OF final_text ON dictations BEGIN
              DELETE FROM transcript_search WHERE rowid = -old.rowid;
              INSERT INTO transcript_search (rowid, text, kind, ref_id)
                SELECT -new.rowid, new.final_text, 'dictation', new.id WHERE new.final_text <> '';
            END;
            CREATE TRIGGER dictations_search_delete AFTER DELETE ON dictations BEGIN
              DELETE FROM transcript_search WHERE rowid = -old.rowid;
            END;
            """),
        // The names of a split call's two sides when neither is me, left then right, joined
        // by the unit separator as tags are.
        ("speakers-1", "ALTER TABLE calls ADD COLUMN speakers TEXT;"),
        // What the retry pass did with every dictation and call segment. Nothing here leaves
        // the Mac. A record points at its row: a dictation's segment by (dictation_id,
        // segment_idx), since Store rewrites those rows, or a call segment by its id. Times
        // are seconds on the recording's timeline. retries-2 drops retry_references again.
        ("retries-1", """
            CREATE TABLE segment_retries (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              source TEXT NOT NULL CHECK (source IN ('dictation', 'me', 'call', 'mix')),
              dictation_id TEXT,
              segment_idx INTEGER,
              call_id TEXT,
              call_segment_id INTEGER,
              t0 REAL NOT NULL,
              t1 REAL NOT NULL,
              first_text TEXT NOT NULL,
              retried_text TEXT,
              logprob_before REAL NOT NULL,
              logprob_after REAL,
              flagged INTEGER NOT NULL,
              kept INTEGER NOT NULL,
              retry_seconds REAL NOT NULL,
              changed INTEGER NOT NULL,
              created_at REAL NOT NULL
            );
            CREATE INDEX segment_retries_dictation ON segment_retries(dictation_id) WHERE dictation_id IS NOT NULL;
            CREATE INDEX segment_retries_call ON segment_retries(call_id, t0) WHERE call_id IS NOT NULL;
            -- One slow decode of a dictation, or of a stretch of one side of a call. text is
            -- NULL when it couldn't be made, with the reason, so it isn't tried forever.
            CREATE TABLE retry_references (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              source TEXT NOT NULL CHECK (source IN ('dictation', 'me', 'call', 'mix')),
              dictation_id TEXT,
              call_id TEXT,
              t0 REAL NOT NULL,
              t1 REAL NOT NULL,
              model TEXT NOT NULL,
              text TEXT,
              error TEXT,
              seconds REAL NOT NULL,
              created_at REAL NOT NULL
            );
            CREATE INDEX retry_references_dictation ON retry_references(dictation_id) WHERE dictation_id IS NOT NULL;
            CREATE INDEX retry_references_call ON retry_references(call_id, t0) WHERE call_id IS NOT NULL;
            ALTER TABLE dictations ADD COLUMN retry_ms INTEGER;
            """),
        // Retries are measured by what they change, so the slow reference decodes go, and a
        // flagged segment left alone keeps why (SegmentRetry.Skip). Settings reads the
        // records by time, the retried ones most.
        ("retries-2", """
            DROP TABLE IF EXISTS retry_references;
            ALTER TABLE segment_retries ADD COLUMN skipped TEXT;
            CREATE INDEX segment_retries_created ON segment_retries(created_at);
            CREATE INDEX segment_retries_flagged ON segment_retries(created_at) WHERE flagged = 1;
            """),
        // An agent's correction sits beside whisper's text and never replaces it: reads and
        // the search index take corrected_text when it is set. Every write an agent makes
        // over MCP is an edit, with what it changed, so it can be listed and undone. old_value
        // and new_value are JSON, shaped by kind; undone_by and undoes link an undo to its edit.
        ("edits-1", """
            ALTER TABLE dictations ADD COLUMN corrected_text TEXT;
            ALTER TABLE call_segments ADD COLUMN corrected_text TEXT;
            CREATE TABLE edits (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              created_at REAL NOT NULL,
              client TEXT,
              kind TEXT NOT NULL,
              target TEXT NOT NULL,
              old_value TEXT,
              new_value TEXT,
              undoes INTEGER,
              undone_by INTEGER
            );
            CREATE INDEX edits_target ON edits(target, id);
            DROP TRIGGER call_segments_search_insert;
            DROP TRIGGER call_segments_search_update;
            DROP TRIGGER dictations_search_insert;
            DROP TRIGGER dictations_search_update;
            CREATE TRIGGER call_segments_search_insert AFTER INSERT ON call_segments BEGIN
              DELETE FROM transcript_search WHERE rowid = new.id;
              INSERT INTO transcript_search (rowid, text, kind, ref_id)
                VALUES (new.id, coalesce(new.corrected_text, new.text), 'call', new.call_id);
            END;
            CREATE TRIGGER call_segments_search_update AFTER UPDATE OF text, corrected_text ON call_segments BEGIN
              DELETE FROM transcript_search WHERE rowid = old.id;
              INSERT INTO transcript_search (rowid, text, kind, ref_id)
                VALUES (new.id, coalesce(new.corrected_text, new.text), 'call', new.call_id);
            END;
            CREATE TRIGGER dictations_search_insert AFTER INSERT ON dictations BEGIN
              DELETE FROM transcript_search WHERE rowid = -new.rowid;
              INSERT INTO transcript_search (rowid, text, kind, ref_id)
                SELECT -new.rowid, coalesce(new.corrected_text, new.final_text), 'dictation', new.id
                WHERE coalesce(new.corrected_text, new.final_text) <> '';
            END;
            CREATE TRIGGER dictations_search_update AFTER UPDATE OF final_text, corrected_text ON dictations BEGIN
              DELETE FROM transcript_search WHERE rowid = -old.rowid;
              INSERT INTO transcript_search (rowid, text, kind, ref_id)
                SELECT -new.rowid, coalesce(new.corrected_text, new.final_text), 'dictation', new.id
                WHERE coalesce(new.corrected_text, new.final_text) <> '';
            END;
            """),
        // Key terms proposed from agents' corrections, one row a term, waiting for Settings'
        // Add or Dismiss. heard holds whisper's spellings joined by the unit separator, as
        // tags are. decision_edit is the edit that took or dismissed it: when that edit is
        // undone the suggestion reads as pending again.
        ("suggestions-1", """
            CREATE TABLE key_term_suggestions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              term TEXT NOT NULL COLLATE NOCASE UNIQUE,
              heard TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'dismissed')),
              edit_id INTEGER NOT NULL,
              corrections INTEGER NOT NULL DEFAULT 1,
              created_at REAL NOT NULL,
              decision_edit INTEGER,
              decided_at REAL
            );
            """),
        // Every edit the fix step proposed for a dictation's flagged segments, in the order the
        // model gave them: applied ones with rejected NULL, the rest with why
        // (FixEdit.Rejection). char_offset is in characters of the segment's stored text.
        ("fixes-1", """
            CREATE TABLE fix_edits (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              dictation_id TEXT NOT NULL,
              idx INTEGER NOT NULL,
              segment_idx INTEGER NOT NULL,
              span TEXT NOT NULL,
              replacement TEXT NOT NULL,
              key_term TEXT,
              char_offset INTEGER,
              rejected TEXT,
              created_at REAL NOT NULL
            );
            CREATE INDEX fix_edits_dictation ON fix_edits(dictation_id, idx);
            """),
        // The IANA zone a recording was made in, beside its start instant, so History can show
        // the clock it was made on. Rows from before this have NULL: their zone is unknown and
        // reads as the current one, not as a guess.
        ("zones-1", """
            ALTER TABLE calls ADD COLUMN time_zone TEXT;
            ALTER TABLE dictations ADD COLUMN time_zone TEXT;
            """),
        // A name a person gave a recording; a call has had one since calls-1.
        ("titles-1", "ALTER TABLE dictations ADD COLUMN title TEXT;"),
        // Who set the title. Titles that exist were set by a person or by an agent (set_recording_title).
        ("titles-2", """
            ALTER TABLE calls ADD COLUMN title_source TEXT;
            ALTER TABLE dictations ADD COLUMN title_source TEXT;
            UPDATE calls SET title_source = 'user' WHERE title IS NOT NULL;
            UPDATE dictations SET title_source = 'user' WHERE title IS NOT NULL;
            """),
        // A call made from an imported audio or video file: the file's name, and its SHA-256 so
        // the same file isn't imported twice.
        ("imports-1", """
            ALTER TABLE calls ADD COLUMN file_name TEXT;
            ALTER TABLE calls ADD COLUMN file_hash TEXT;
            CREATE INDEX calls_file_hash ON calls(file_hash) WHERE file_hash IS NOT NULL;
            """),
        // How long the intelligence model takes, per title and per fix: numbers only, no text,
        // names or ids (ModelTimings). The insert keeps the newest rows.
        ("model-timings-1", """
            CREATE TABLE model_timings (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              created_at REAL NOT NULL,
              task TEXT NOT NULL CHECK (task IN ('title', 'fix')),
              model_kind TEXT NOT NULL CHECK (model_kind IN ('apple', 'ollama')),
              outcome TEXT NOT NULL,
              total_ms INTEGER NOT NULL,
              model_ms INTEGER
            );
            CREATE INDEX model_timings_created ON model_timings(created_at);
            """),
    ]

    /// The names of the migrations this file has had.
    func appliedMigrations() throws -> [String] {
        try queue.sync { try db.query("SELECT name FROM voice_migrations ORDER BY rowid") { $0.text(0) } }
    }

    /// Store runs this when it opens the file, so every connection finds the schema current.
    static func migrate(_ db: SQLiteConnection) throws {
        try db.exec("CREATE TABLE IF NOT EXISTS voice_migrations (name TEXT PRIMARY KEY, applied_at REAL NOT NULL)")
        let applied = Set(try db.query("SELECT name FROM voice_migrations") { $0.text(0) })
        for migration in Self.migrations where !applied.contains(migration.name) {
            // The app and dictate-cli can open the file at the same moment; the second to take
            // the write lock finds the migration done and skips it.
            try db.transaction {
                guard try db.query("SELECT 1 FROM voice_migrations WHERE name = ?", [migration.name], { _ in 1 })
                    .isEmpty else { return }
                try db.exec(migration.sql)
                try db.run("INSERT INTO voice_migrations (name, applied_at) VALUES (?, ?)", [migration.name, Date()])
            }
        }
    }

    // MARK: Helpers

    private static let callColumns = """
        id, started_at, ended_at, app_bundle_id, app_name, device_uid, split, audio_path, status, title, error,
        (SELECT group_concat(tag, char(31)) FROM call_tags WHERE call_id = calls.id), speakers, time_zone,
        title_source, file_name
        """

    private static func readCall(_ row: SQLiteRow) -> Call {
        Call(id: row.text(0), startedAt: row.date(1), timeZone: row.string(13), endedAt: row.optionalDate(2), appBundleID: row.string(3),
             appName: row.string(4), deviceUID: row.string(5), split: row.int(6) != 0, audioPath: row.string(7),
             status: Call.Status(rawValue: row.text(8)) ?? .failed, title: row.string(9),
             titleSource: row.string(14).flatMap(TitleSource.init(rawValue:)), fileName: row.string(15),
             error: row.string(10),
             tags: (row.string(11) ?? "").split(separator: "\u{1F}").map(String.init)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending },
             speakers: row.string(12).map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init) })
    }

    static let dictationColumns = """
        id, created_at, audio_path, duration, mode, whisper_model, raw_text, final_text, cleanup_model,
        cleanup_system, record_ms, load_ms, transcribe_ms, cleanup_ms, paste_ms, error, origin, retry_ms,
        corrected_text, time_zone
        """

    /// A corrected dictation reads as its correction, with the text it had kept beside it.
    static func readDictation(_ row: SQLiteRow) -> Dictation {
        let corrected = row.string(18)
        return Dictation(id: row.text(0), createdAt: row.date(1), timeZone: row.string(19), audioPath: row.text(2), duration: row.double(3),
                         mode: Dictation.Mode(rawValue: row.text(4)) ?? .plain, whisperModel: row.text(5),
                         rawText: row.text(6), finalText: corrected ?? row.text(7), cleanupModel: row.string(8),
                         cleanupSystem: row.string(9),
                         timings: Dictation.Timings(record: row.optionalInt(10), load: row.optionalInt(11),
                                                    transcribe: row.optionalInt(12), cleanup: row.optionalInt(13),
                                                    paste: row.optionalInt(14), retry: row.optionalInt(17)),
                         segments: [], error: row.string(15), origin: row.string(16).flatMap(Dictation.Origin.init),
                         originalText: corrected == nil ? nil : row.text(7))
    }

    static let segmentColumns = """
        id, call_id, channel, start_ms, end_ms, coalesce(corrected_text, text), avg_logprob, no_speech_prob,
        compression_ratio, created_at, CASE WHEN corrected_text IS NULL THEN NULL ELSE text END
        """

    static func readSegment(_ row: SQLiteRow) -> CallSegment {
        CallSegment(id: row.int64(0), callID: row.text(1), channel: CallSegment.Channel(rawValue: row.text(2)) ?? .mix,
                    startMs: row.int(3), endMs: row.int(4), text: row.text(5), avgLogprob: row.optionalDouble(6),
                    noSpeechProb: row.optionalDouble(7), compressionRatio: row.optionalDouble(8),
                    createdAt: row.date(9), originalText: row.string(10))
    }

    private func hits(_ match: String, _ limit: Int) throws -> [SearchHit] {
        try db.query("""
            SELECT transcript_search.kind, transcript_search.ref_id,
                   snippet(transcript_search, 0, '[', ']', '…', 24),
                   cs.id, cs.channel, cs.start_ms, c.started_at, c.title, d.created_at,
                   coalesce(cs.corrected_text, d.corrected_text) IS NOT NULL
            FROM transcript_search
            LEFT JOIN call_segments cs ON transcript_search.kind = 'call' AND cs.id = transcript_search.rowid
            LEFT JOIN calls c ON c.id = cs.call_id
            LEFT JOIN dictations d ON transcript_search.kind = 'dictation' AND d.rowid = -transcript_search.rowid
            WHERE transcript_search MATCH ? AND (c.id IS NOT NULL OR d.id IS NOT NULL)
            ORDER BY bm25(transcript_search) LIMIT ?
            """, [match, limit]) { row in
            let isCall = row.text(0) == SearchHit.Kind.call.rawValue
            return SearchHit(kind: isCall ? .call : .dictation, id: row.text(1),
                             at: isCall ? row.date(6) : row.date(8), title: isCall ? row.string(7) : nil,
                             channel: isCall ? row.string(4).flatMap(CallSegment.Channel.init) : nil,
                             segmentID: isCall ? row.int64(3) : nil, startMs: isCall ? row.int(5) : nil,
                             snippet: row.text(2), corrected: row.int(9) != 0 ? true : nil)
        }
    }

    func exists(_ callID: String) throws -> Bool {
        try !db.query("SELECT 1 FROM calls WHERE id = ?", [callID], { _ in 1 }).isEmpty
    }

    func require(_ callID: String) throws -> Call {
        guard let call = try call(callID) else { throw VoiceError.store("No call \(callID).") }
        return call
    }

    private func update(_ callID: String, _ assignments: String, _ values: [Any?]) throws {
        let changed = try queue.sync { try db.run("UPDATE calls SET \(assignments) WHERE id = ?", values + [callID]) }
        guard changed > 0 else { throw VoiceError.store("No call \(callID).") }
    }
}
