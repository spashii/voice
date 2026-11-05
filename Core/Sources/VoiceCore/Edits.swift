import Foundation

/// One write an agent made over MCP: a correction, a key-term change or a tag change, or the
/// undo of one of those. `before` and `after` hold what the target was and became, so the
/// edit can be read back and undone.
public struct Edit: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case correctDictation = "correct_dictation"
        case correctSegment = "correct_segment"
        case addKeyTerms = "add_key_terms"
        case removeKeyTerms = "remove_key_terms"
        case tagCall = "tag_call"
        case undo
    }

    /// A target's state, by kind: text and corrected for a correction, terms for the key
    /// terms, tags for a call.
    public struct Value: Sendable, Codable, Equatable {
        public var text: String?
        public var corrected: Bool?
        public var terms: [String]?
        public var tags: [String]?

        public init(text: String? = nil, corrected: Bool? = nil, terms: [String]? = nil, tags: [String]? = nil) {
            self.text = text
            self.corrected = corrected
            self.terms = terms
            self.tags = tags
        }
    }

    public var id: Int64
    public var at: Date
    /// The MCP client that made it, as `name version` from its initialize.
    public var client: String?
    public var kind: Kind
    /// `dictation:ID`, `call:ID/segment:N`, `call:ID` or `key_terms`; an undo has its edit's.
    public var target: String
    public var before: Value?
    public var after: Value?
    /// For an undo, the edit it undid.
    public var undoes: Int64?
    /// The undo that reverted this edit, if one did.
    public var undoneBy: Int64?

    public static let keyTermsTarget = "key_terms"

    public static func target(dictation id: String) -> String { "dictation:\(id)" }
    public static func target(call id: String) -> String { "call:\(id)" }
    public static func target(call id: String, segment: Int64) -> String { "call:\(id)/segment:\(segment)" }
}

extension CallStore {
    // MARK: Corrections

    /// Sets a dictation's text to the correction, beside the text it keeps. Correcting it back
    /// to that text clears the correction. Nothing is pasted.
    @discardableResult
    public func correctDictation(_ id: String, text: String, client: String?) throws -> (Dictation, Edit) {
        let edit = try queue.sync {
            try db.transaction { () -> Edit in
                guard let row = try db.query("SELECT final_text, corrected_text FROM dictations WHERE id = ?", [id],
                                             { ($0.text(0), $0.string(1)) }).first else {
                    throw VoiceError.store("No dictation \(id).")
                }
                let correction = text == row.0 ? nil : text
                try db.run("UPDATE dictations SET corrected_text = ? WHERE id = ?", [correction, id])
                return try insertEdit(.correctDictation, target: Edit.target(dictation: id), client: client,
                                      before: Self.state(row.0, row.1), after: Self.state(row.0, correction))
            }
        }
        guard let dictation = try dictation(id) else { throw VoiceError.store("No dictation \(id).") }
        return (dictation, edit)
    }

    /// The same for one segment of a call, found by the call's id and the segment's.
    @discardableResult
    public func correctSegment(_ callID: String, _ segmentID: Int64, text: String,
                               client: String?) throws -> (CallSegment, Edit) {
        let edit = try queue.sync {
            try db.transaction { () -> Edit in
                guard let row = try db.query("SELECT text, corrected_text FROM call_segments WHERE call_id = ? AND id = ?",
                                             [callID, segmentID], { ($0.text(0), $0.string(1)) }).first else {
                    throw VoiceError.store("No segment \(segmentID) in call \(callID).")
                }
                let correction = text == row.0 ? nil : text
                try db.run("UPDATE call_segments SET corrected_text = ? WHERE id = ?", [correction, segmentID])
                return try insertEdit(.correctSegment, target: Edit.target(call: callID, segment: segmentID),
                                      client: client, before: Self.state(row.0, row.1),
                                      after: Self.state(row.0, correction))
            }
        }
        guard let segment = try segment(callID, segmentID) else {
            throw VoiceError.store("No segment \(segmentID) in call \(callID).")
        }
        return (segment, edit)
    }

    /// tagCall for an agent: the change is recorded as an edit when it changed anything.
    public func tagCall(_ callID: String, add: [String], remove: [String],
                        client: String?) throws -> (tags: [String], edit: Edit?) {
        let before = try require(callID).tags
        let after = try tagCall(callID, add: add, remove: remove)
        guard Self.lowered(before) != Self.lowered(after) else { return (after, nil) }
        let edit = try queue.sync {
            try db.transaction {
                try insertEdit(.tagCall, target: Edit.target(call: callID), client: client,
                               before: Edit.Value(tags: before), after: Edit.Value(tags: after))
            }
        }
        return (after, edit)
    }

    /// How many of a call's segments an agent has corrected.
    public func correctedSegments(_ callID: String) throws -> Int {
        try queue.sync {
            try db.query("SELECT count(*) FROM call_segments WHERE call_id = ? AND corrected_text IS NOT NULL",
                         [callID]) { $0.int(0) }.first ?? 0
        }
    }

    // MARK: The record

    /// Records an edit whose change was made elsewhere: the key terms, in the app's defaults.
    @discardableResult
    public func recordEdit(_ kind: Edit.Kind, target: String, client: String?, before: Edit.Value?,
                           after: Edit.Value?) throws -> Edit {
        try queue.sync {
            try db.transaction { try insertEdit(kind, target: target, client: client, before: before, after: after) }
        }
    }

    /// Newest first.
    public func edits(since: Date? = nil, target: String? = nil, limit: Int = 20) throws -> [Edit] {
        try queue.sync {
            try db.query("""
                SELECT \(Self.editColumns) FROM edits WHERE created_at >= ? AND (?2 IS NULL OR target = ?2)
                ORDER BY id DESC LIMIT ?
                """, [since ?? Date.distantPast, target, limit], Self.readEdit)
        }
    }

    public func edit(_ id: Int64) throws -> Edit? {
        try queue.sync { try db.query("SELECT \(Self.editColumns) FROM edits WHERE id = ?", [id], Self.readEdit).first }
    }

    // MARK: Undo

    /// Reverts a correction or a tag change and records the undo. A correction is put back
    /// only while its target still reads as the edit left it, so a later correction isn't
    /// lost; undo that one first. Key-term edits are undone by KeyTermsEditor, which owns
    /// the list, through `recordUndo`.
    @discardableResult
    public func undo(_ id: Int64, client: String?) throws -> Edit {
        try queue.sync {
            try db.transaction { () -> Edit in
                let edit = try undoable(id)
                let (before, after): (Edit.Value, Edit.Value)
                switch edit.kind {
                case .correctDictation, .correctSegment:
                    let (table, original, key, value) = try Self.correctionRow(edit)
                    guard let row = try db.query("SELECT \(original), corrected_text FROM \(table) WHERE \(key) = ?",
                                                 [value], { ($0.text(0), $0.string(1)) }).first else {
                        throw VoiceError.store("\(edit.target) no longer exists.")
                    }
                    before = Self.state(row.0, row.1)
                    guard before == edit.after else {
                        let later = try db.query("""
                            SELECT id FROM edits WHERE target = ? AND id > ? AND undone_by IS NULL AND kind <> 'undo'
                            ORDER BY id DESC LIMIT 1
                            """, [edit.target, edit.id]) { $0.int64(0) }.first
                        throw VoiceError.store("\(edit.target) has changed since edit \(edit.id)"
                                               + (later.map { "; undo edit \($0) first." } ?? "."))
                    }
                    let restored = edit.before?.corrected == true ? edit.before?.text : nil
                    try db.run("UPDATE \(table) SET corrected_text = ? WHERE \(key) = ?", [restored, value])
                    after = Self.state(row.0, restored)
                case .tagCall:
                    let callID = String(edit.target.dropFirst("call:".count))
                    let current = try db.query("SELECT tag FROM call_tags WHERE call_id = ?", [callID]) { $0.text(0) }
                    guard try exists(callID) else { throw VoiceError.store("\(edit.target) no longer exists.") }
                    let added = Self.minus(edit.after?.tags ?? [], edit.before?.tags ?? [])
                    let removed = Self.minus(edit.before?.tags ?? [], edit.after?.tags ?? [])
                    for tag in added { try db.run("DELETE FROM call_tags WHERE call_id = ? AND tag = ?", [callID, tag]) }
                    for tag in removed {
                        try db.run("INSERT OR IGNORE INTO call_tags (call_id, tag, created_at) VALUES (?,?,?)",
                                   [callID, tag, Date()])
                    }
                    before = Edit.Value(tags: Self.sorted(current))
                    after = Edit.Value(tags: Self.sorted(try db.query("SELECT tag FROM call_tags WHERE call_id = ?",
                                                                      [callID]) { $0.text(0) }))
                case .addKeyTerms, .removeKeyTerms, .undo:
                    throw VoiceError.store("Edit \(id) isn't undone here.")
                }
                return try insertUndo(of: edit, client: client, before: before, after: after)
            }
        }
    }

    /// Records the undo of a key-term edit once the list has been put back.
    @discardableResult
    public func recordUndo(of id: Int64, client: String?, before: Edit.Value, after: Edit.Value) throws -> Edit {
        try queue.sync {
            try db.transaction { try insertUndo(of: try undoable(id), client: client, before: before, after: after) }
        }
    }

    /// The edit, when it exists, isn't an undo and hasn't been undone.
    public func checkUndoable(_ id: Int64) throws -> Edit {
        try queue.sync { try undoable(id) }
    }

    // MARK: Helpers

    private func undoable(_ id: Int64) throws -> Edit {
        guard let edit = try db.query("SELECT \(Self.editColumns) FROM edits WHERE id = ?", [id], Self.readEdit).first else {
            throw VoiceError.store("No edit \(id).")
        }
        if edit.kind == .undo { throw VoiceError.store("Edit \(id) is an undo; make the change again instead.") }
        if let by = edit.undoneBy { throw VoiceError.store("Edit \(id) was already undone by edit \(by).") }
        return edit
    }

    private func insertUndo(of edit: Edit, client: String?, before: Edit.Value, after: Edit.Value) throws -> Edit {
        let undo = try insertEdit(.undo, target: edit.target, client: client, before: before, after: after,
                                  undoes: edit.id)
        try db.run("UPDATE edits SET undone_by = ? WHERE id = ?", [undo.id, edit.id])
        return undo
    }

    /// Runs inside the caller's transaction, on the queue.
    private func insertEdit(_ kind: Edit.Kind, target: String, client: String?, before: Edit.Value?,
                            after: Edit.Value?, undoes: Int64? = nil) throws -> Edit {
        let now = Date()
        try db.run("""
            INSERT INTO edits (created_at, client, kind, target, old_value, new_value, undoes)
            VALUES (?,?,?,?,?,?,?)
            """, [now, client, kind.rawValue, target, try Self.encode(before), try Self.encode(after), undoes])
        return Edit(id: db.lastInsertRowID, at: now, client: client, kind: kind, target: target, before: before,
                    after: after, undoes: undoes, undoneBy: nil)
    }

    /// The table, original text column and key a correction's target names.
    private static func correctionRow(_ edit: Edit) throws -> (String, String, String, Any) {
        if edit.kind == .correctDictation {
            return ("dictations", "final_text", "id", String(edit.target.dropFirst("dictation:".count)))
        }
        guard let range = edit.target.range(of: "/segment:"), let id = Int64(edit.target[range.upperBound...]) else {
            throw VoiceError.store("Edit \(edit.id) has no segment in its target.")
        }
        return ("call_segments", "text", "id", id)
    }

    private static func state(_ original: String, _ correction: String?) -> Edit.Value {
        Edit.Value(text: correction ?? original, corrected: correction != nil)
    }

    private static func lowered(_ tags: [String]) -> Set<String> { Set(tags.map { $0.lowercased() }) }

    /// What `a` has that `b` lacks, compared without case, as tags are.
    private static func minus(_ a: [String], _ b: [String]) -> [String] {
        let other = lowered(b)
        return a.filter { !other.contains($0.lowercased()) }
    }

    private static func sorted(_ tags: [String]) -> [String] {
        tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static let editColumns = "id, created_at, client, kind, target, old_value, new_value, undoes, undone_by"

    private static func readEdit(_ row: SQLiteRow) -> Edit {
        Edit(id: row.int64(0), at: row.date(1), client: row.string(2), kind: Edit.Kind(rawValue: row.text(3)) ?? .undo,
             target: row.text(4), before: decode(row.string(5)), after: decode(row.string(6)),
             undoes: row.isNull(7) ? nil : row.int64(7), undoneBy: row.isNull(8) ? nil : row.int64(8))
    }

    private static func encode(_ value: Edit.Value?) throws -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func decode(_ text: String?) -> Edit.Value? {
        text.flatMap { try? JSONDecoder().decode(Edit.Value.self, from: Data($0.utf8)) }
    }
}
