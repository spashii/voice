import Foundation

/// MCP's methods on JSON-RPC messages: initialize, ping, the tools and the transcript
/// resources. MCPServer carries them over HTTP.
struct MCPRouter: Sendable {
    /// Newest first: initialize answers with the client's version when it is here, and with
    /// the newest otherwise.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
        Voice keeps this Mac's dictations and recorded calls. In call transcripts "Me:" is the \
        Mac's owner and "Call:" is everyone else. To follow a live call, call wait_for_transcript \
        again and again, each time passing the cursor it returned, until ended is true. Corrections, \
        key-term changes and tag changes are recorded as edits: list_edits shows them, undo_edit \
        reverts one.
        """

    /// Each message in a batch can be a 60 s wait, so a batch is kept short.
    static let maxBatch = 10

    let store: CallStore
    let recording: (any RecordingControl)?
    let recordingUnavailable: String
    let version: String
    /// Where key-term changes go; nil where there is no app to change them for.
    var keyTerms: KeyTermsEditor? = nil

    /// The HTTP status and body for one POST. Notifications and responses get 202 and no
    /// body; a batch gets an array of answers. `client` names the MCP client in the edits
    /// its writes record.
    func handle(_ body: Data, client: String? = nil) async -> (Int, Data?) {
        guard let message = try? JSONSerialization.jsonObject(with: body) else {
            return (400, Self.encode(Self.failure(id: NSNull(), code: -32700, "Parse error: the body isn't JSON.")))
        }
        if let batch = message as? [Any] {
            guard !batch.isEmpty else {
                return (400, Self.encode(Self.failure(id: NSNull(), code: -32600, "Empty batch.")))
            }
            guard batch.count <= Self.maxBatch else {
                return (400, Self.encode(Self.failure(id: NSNull(), code: -32600,
                                                      "A batch holds at most \(Self.maxBatch) messages.")))
            }
            var answers: [Any] = []
            // The client is gone when the task is cancelled, so the rest would go unread.
            for item in batch where !Task.isCancelled {
                if let answer = await answer(item, client: client) { answers.append(answer) }
            }
            return answers.isEmpty ? (202, nil) : (200, Self.encode(answers))
        }
        guard let answer = await answer(message, client: client) else { return (202, nil) }
        return (200, Self.encode(answer))
    }

    /// The answer to one message, or nil when it was a notification or a response.
    private func answer(_ message: Any, client: String?) async -> [String: Any]? {
        guard let object = message as? [String: Any] else {
            return Self.failure(id: NSNull(), code: -32600, "A JSON-RPC message is an object.")
        }
        guard let method = object["method"] as? String else {
            // A client's response to a request; this server never sends any.
            if object["result"] != nil || object["error"] != nil { return nil }
            return Self.failure(id: object["id"] ?? NSNull(), code: -32600, "No method.")
        }
        guard let id = object["id"] else { return nil }
        let params = object["params"] as? [String: Any] ?? [:]
        do {
            let result = try await call(method, params, client: client)
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let error as RPCError {
            return Self.failure(id: id, code: error.code, error.message)
        } catch {
            return Self.failure(id: id, code: -32603, "\(error)")
        }
    }

    private func call(_ method: String, _ params: [String: Any], client: String?) async throws -> Any {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            return [
                "protocolVersion": asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0],
                "capabilities": [
                    "tools": ["listChanged": false],
                    "resources": ["subscribe": false, "listChanged": false],
                ],
                "serverInfo": ["name": "voice", "title": "Voice", "version": version],
                "instructions": Self.instructions,
            ] as [String: Any]
        case "ping":
            return [String: Any]()
        case "tools/list":
            return ["tools": Self.tools]
        case "tools/call":
            guard let name = params["name"] as? String else { throw RPCError(-32602, "tools/call needs a name.") }
            guard Self.tools.contains(where: { $0["name"] as? String == name }) else {
                throw RPCError(-32602, "No tool \(name).")
            }
            let arguments = Arguments(params["arguments"] as? [String: Any] ?? [:])
            do {
                return Self.content(try await tool(name, arguments, client: client))
            } catch let error as ToolError {
                return Self.content(error.message, isError: true)
            } catch {
                return Self.content("\(error)", isError: true)
            }
        case "resources/list":
            return ["resources": try resources()]
        case "resources/templates/list":
            return ["resourceTemplates": [[
                "uriTemplate": "call://{id}/transcript", "name": "call-transcript",
                "title": "A call's transcript", "mimeType": "text/plain",
                "description": "Both sides merged by time with Me: and Call: labels.",
            ]]]
        case "resources/read":
            guard let uri = params["uri"] as? String else { throw RPCError(-32602, "resources/read needs a uri.") }
            return ["contents": [["uri": uri, "mimeType": "text/plain", "text": try readResource(uri)]]]
        default:
            throw RPCError(-32601, "Method not found: \(method).")
        }
    }

    // MARK: Tools

    /// The tool's answer: text for a transcript, JSON for everything else.
    private func tool(_ name: String, _ args: Arguments, client: String?) async throws -> String {
        switch name {
        case "list_calls":
            let calls = try store.calls(since: try args.date("since"), tag: try args.string("tag"),
                                        limit: try args.int("limit", default: 20, range: 1...200))
            return try Self.json(try calls.map { try Self.plain($0) })

        case "get_call":
            let call = try requireCall(try args.require("id"))
            var object = try Self.plain(call)
            let segments = try store.segments(call.id)
            object["segment_count"] = segments.count
            object["last_cursor"] = segments.last?.id ?? 0
            return try Self.json(object)

        case "get_transcript":
            let call = try requireCall(try args.require("id"))
            let channel = try args.channel("channel")
            switch try args.string("format") ?? "text" {
            case "text":
                return try transcriptText(call, try store.transcript(call.id, channel: channel))
            case "segments":
                let segments = try store.segments(call.id, channel: channel)
                    .sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
                let object: [String: Any] = ["call": try Self.plain(call), "segments": segments.map(Self.compact)]
                return try Self.json(object)
            case let other:
                throw ToolError("format is text or segments, not \(other).")
            }

        case "current_call":
            let call: Any = try store.currentCall().map { try Self.plain($0) } ?? NSNull()
            let object: [String: Any] = ["call": call, "cursor": try store.latestCursor()]
            return try Self.json(object)

        case "wait_for_transcript":
            let id = try args.string("call_id") ?? "current"
            let cursor = try args.int64("cursor") ?? 0
            let timeout = min(max(try args.double("timeout_s") ?? 30, 0), 60)
            let batch = try await store.waitForSegments(id == "current" ? nil : id, after: cursor,
                                                        timeout: .milliseconds(Int(timeout * 1000)))
            var object: [String: Any] = [
                "call_id": batch.call?.id ?? NSNull(), "status": batch.call?.status.rawValue ?? NSNull(),
                "cursor": batch.cursor, "segments": batch.segments.map(Self.compact),
                "ended": batch.ended, "more": batch.more,
            ]
            if batch.call == nil { object["note"] = "No call is being recorded." }
            return try Self.json(object)

        case "search_transcripts":
            let hits = try store.search(try args.require("query"), limit: try args.int("limit", default: 20, range: 1...100))
            return try Self.json(try hits.map { try Self.plain($0) })

        case "tag_call":
            let id = try args.require("id")
            let (tags, edit) = try store.tagCall(id, add: try args.strings("add"), remove: try args.strings("remove"),
                                                 client: client)
            var object: [String: Any] = ["id": id, "tags": tags]
            if let edit { object["edit_id"] = edit.id }
            return try Self.json(object)

        case "list_dictations":
            let dictations = try store.dictations(since: try args.date("since"),
                                                  limit: try args.int("limit", default: 20, range: 1...200))
            return try Self.json(dictations.map(Self.summary))

        case "get_dictation":
            let id = try args.require("id")
            guard let dictation = try store.dictation(id) else { throw ToolError("No dictation \(id).") }
            return try Self.json(try Self.full(dictation))

        case "correct_dictation":
            let (dictation, edit) = try store.correctDictation(try args.require("id"), text: try args.require("text"),
                                                               client: client)
            var object = try Self.full(dictation)
            object["edit_id"] = edit.id
            return try Self.json(object)

        case "correct_segment":
            let call = try requireCall(try args.require("call_id"))
            guard let segmentID = try args.int64("segment_id") else { throw ToolError("segment_id is required.") }
            let (segment, edit) = try store.correctSegment(call.id, segmentID, text: try args.require("text"),
                                                           client: client)
            var object = Self.compact(segment)
            object["call_id"] = call.id
            object["edit_id"] = edit.id
            return try Self.json(object)

        case "list_key_terms":
            return try Self.json(Self.plain(try await requireKeyTerms().list()))

        case "add_key_terms":
            let change = try await requireKeyTerms().add(try args.strings("terms"), client: client)
            return try Self.json(Self.plain(change, changed: "added", unchanged: "already_present"))

        case "remove_key_terms":
            let change = try await requireKeyTerms().remove(try args.strings("terms"), client: client)
            return try Self.json(Self.plain(change, changed: "removed", unchanged: "not_found"))

        case "list_edits":
            let edits = try store.edits(since: try args.date("since"), target: try args.string("target"),
                                        limit: try args.int("limit", default: 20, range: 1...200))
            return try Self.json(try edits.map { try Self.plain($0) })

        case "undo_edit":
            guard let id = try args.int64("id") else { throw ToolError("id is required.") }
            guard let edit = try store.edit(id) else { throw ToolError("No edit \(id).") }
            let undo: Edit
            switch edit.kind {
            case .addKeyTerms, .removeKeyTerms:
                undo = try await requireKeyTerms().undo(id, client: client)
            default:
                undo = try store.undo(id, client: client)
            }
            return try Self.json(try Self.plain(undo))

        case "start_recording":
            guard let recording else { throw ToolError(recordingUnavailable) }
            let call = try await recording.startRecording(title: try args.string("title"))
            return try Self.json(try Self.plain(call))

        case "stop_recording":
            guard let recording else { throw ToolError(recordingUnavailable) }
            let call = try await recording.stopRecording()
            return try Self.json(try Self.plain(call))

        default:
            throw RPCError(-32602, "No tool \(name).")
        }
    }

    private func requireKeyTerms() throws -> KeyTermsEditor {
        guard let keyTerms else { throw ToolError("Key terms can't be changed from this server.") }
        return keyTerms
    }

    private func requireCall(_ id: String) throws -> Call {
        if id == "current" {
            guard let call = try store.currentCall() else { throw ToolError("No call is being recorded.") }
            return call
        }
        guard let call = try store.call(id) else { throw ToolError("No call \(id).") }
        return call
    }

    static var tools: [[String: Any]] {
        let since: [String: Any] = [
            "type": "string",
            "description": "Only those from this time on: ISO 8601 such as 2026-11-04T09:00:00Z or 2026-11-04 (local midnight), or a span back from now such as 90m, 24h or 7d.",
        ]
        let callID: [String: Any] = ["type": "string", "description": "The call's id, or \"current\" for the call being recorded."]
        func limit(_ value: Int, _ max: Int) -> [String: Any] {
            ["type": "integer", "minimum": 1, "maximum": max, "default": value]
        }
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = [],
                  readOnly: Bool = true) -> [String: Any] {
            var schema: [String: Any] = ["type": "object", "properties": properties]
            if !required.isEmpty { schema["required"] = required }
            return ["name": name, "description": description, "inputSchema": schema,
                    "annotations": ["readOnlyHint": readOnly, "openWorldHint": false]]
        }
        return [
            tool("list_calls", "List recorded calls newest first, optionally only those since a time or with a tag.",
                 ["since": since, "tag": ["type": "string", "description": "Only calls with this tag."],
                  "limit": limit(20, 200)]),
            tool("get_call", "Get one call's details, tags and segment count by its id.", ["id": callID],
                 required: ["id"]),
            tool("get_transcript",
                 "Get a call's transcript, both sides merged by time with Me: and Call: labels unless you pick one channel.",
                 ["id": callID,
                  "channel": ["type": "string", "enum": ["all", "me", "call", "mix"], "default": "all",
                              "description": "me is this Mac's microphone, call is everyone else, mix is a call recorded without the split."],
                  "format": ["type": "string", "enum": ["text", "segments"], "default": "text",
                             "description": "text gives timed, labelled lines; segments gives JSON with milliseconds."]],
                 required: ["id"]),
            tool("current_call",
                 "Get the call being recorded now (null when there is none) and the cursor to wait from for only what is said next."),
            tool("wait_for_transcript",
                 "Wait up to timeout_s for a live call's segments after cursor, then call again with the returned cursor until ended is true.",
                 ["call_id": ["type": "string", "default": "current",
                              "description": "The call's id, or \"current\" to follow whichever call is being recorded, waiting for one to start."],
                  "cursor": ["type": "integer", "minimum": 0, "default": 0,
                             "description": "The cursor from the last answer, or from current_call; 0 returns the call from its start."],
                  "timeout_s": ["type": "number", "minimum": 0, "maximum": 60, "default": 30]]),
            tool("search_transcripts",
                 "Search call transcripts and dictations for words, best matches first, with the call or dictation id of each match.",
                 ["query": ["type": "string", "description": "Words to find; all must match, or failing that any."],
                  "limit": limit(20, 100)],
                 required: ["query"]),
            tool("tag_call", "Add or remove tags on a call and get its tags back. A change is recorded as an edit.",
                 ["id": ["type": "string", "description": "The call's id."],
                  "add": ["type": "array", "items": ["type": "string"]],
                  "remove": ["type": "array", "items": ["type": "string"]]],
                 required: ["id"], readOnly: false),
            tool("list_dictations", "List dictations newest first with their final text.",
                 ["since": since, "limit": limit(20, 200)]),
            tool("get_dictation", "Get one dictation by id with its raw and final text, timings and segments.",
                 ["id": ["type": "string", "description": "The dictation's id."]], required: ["id"]),
            tool("correct_dictation",
                 "Correct a dictation's text. The original is kept: reads and search return the correction with corrected: true and original_text. Nothing is pasted again; the correction is an edit undo_edit can revert.",
                 ["id": ["type": "string", "description": "The dictation's id."],
                  "text": ["type": "string", "description": "The whole corrected text. The original text clears the correction."]],
                 required: ["id", "text"], readOnly: false),
            tool("correct_segment",
                 "Correct one segment of a call's transcript, by the segment id get_transcript gives in format segments. The original is kept: reads and search return the correction with corrected: true and original_text.",
                 ["call_id": callID,
                  "segment_id": ["type": "integer", "minimum": 1, "description": "The segment's id."],
                  "text": ["type": "string", "description": "The segment's whole corrected text. The original text clears the correction."]],
                 required: ["call_id", "segment_id", "text"], readOnly: false),
            tool("list_key_terms",
                 "List the key terms from Voice's Settings, the names and words whisper is told to spell as given, with the tokens they take of whisper's prompt and its limit."),
            tool("add_key_terms",
                 "Add key terms to Voice's Settings, skipping any already there in any case. If whisper's prompt would pass its token limit nothing is added, and the answer says how many tokens are left and which terms fit.",
                 ["terms": ["type": "array", "items": ["type": "string"], "description": "The terms, spelled as whisper should write them."]],
                 required: ["terms"], readOnly: false),
            tool("remove_key_terms", "Remove key terms from Voice's Settings, matching without case.",
                 ["terms": ["type": "array", "items": ["type": "string"]]],
                 required: ["terms"], readOnly: false),
            tool("list_edits",
                 "List the writes agents made, newest first: when, which client, what kind, the target, and its before and after.",
                 ["since": since, "target": ["type": "string", "description": "Only edits to this target, such as dictation:ID, call:ID/segment:N, call:ID or key_terms."],
                  "limit": limit(20, 200)]),
            tool("undo_edit",
                 "Undo one edit by its id: a correction goes back to the text before it, a key-term add or remove and a tag change are reverted. The undo is recorded as an edit too.",
                 ["id": ["type": "integer", "minimum": 1, "description": "The edit's id from list_edits."]],
                 required: ["id"], readOnly: false),
            tool("start_recording", "Start recording a call in the Voice app and get the new call's id.",
                 ["title": ["type": "string", "description": "A title for the call."]], readOnly: false),
            tool("stop_recording", "Stop the call recording in progress in the Voice app.", readOnly: false),
        ]
    }

    // MARK: Sessions

    /// The Mcp-Session-Id to answer an initialize with: the client's name and version from
    /// clientInfo, base64url encoded, then a random part. The client sends it with every
    /// request after, so an edit can name its client with no session kept here, and the name
    /// survives a restart of the server. Nil when the body isn't an initialize.
    static func session(initializing body: Data) -> String? {
        guard body.range(of: Data("initialize".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: body) else { return nil }
        let messages = (object as? [Any]) ?? [object]
        guard let initialize = messages.lazy.compactMap({ $0 as? [String: Any] })
            .first(where: { $0["method"] as? String == "initialize" }) else { return nil }
        let info = (initialize["params"] as? [String: Any])?["clientInfo"] as? [String: Any] ?? [:]
        let name = String((info["name"] as? String ?? "unnamed").prefix(100))
        let version = String((info["version"] as? String ?? "").prefix(50))
        guard let json = try? JSONSerialization.data(withJSONObject: ["n": name, "v": version], options: [.sortedKeys])
        else { return nil }
        let encoded = json.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let random = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return "v1.\(encoded).\(random)"
    }

    /// `name version` from a session id `session(initializing:)` made, else nil.
    static func client(session: String) -> String? {
        let parts = session.split(separator: ".")
        guard parts.count == 3, parts[0] == "v1" else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let name = info["n"] else { return nil }
        let printable = { (text: String) in String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }) }
        let version = printable(info["v"] ?? "")
        return version.isEmpty ? printable(name) : "\(printable(name)) \(version)"
    }

    // MARK: Resources

    private func resources() throws -> [[String: Any]] {
        let current: [String: Any] = [
            "uri": "call://current/transcript", "name": "current-call-transcript",
            "title": "The call being recorded", "mimeType": "text/plain",
            "description": "The transcript of the call being recorded now, both sides merged by time.",
        ]
        return [current] + (try store.calls(limit: 20)).map { call in
            [
                "uri": "call://\(call.id)/transcript", "name": "call-\(call.id)",
                "title": call.title ?? "Call at \(Self.iso(call.startedAt))", "mimeType": "text/plain",
            ]
        }
    }

    private func readResource(_ uri: String) throws -> String {
        guard uri.hasPrefix("call://"), uri.hasSuffix("/transcript") else {
            throw RPCError(-32002, "Resource not found: \(uri).")
        }
        let id = String(uri.dropFirst("call://".count).dropLast("/transcript".count))
        let call = id == "current" ? try store.currentCall() : try store.call(id)
        guard let call else {
            throw RPCError(-32002, id == "current" ? "No call is being recorded." : "Resource not found: \(uri).")
        }
        return try transcriptText(call, try store.transcript(call.id))
    }

    // MARK: Encoding

    private func transcriptText(_ call: Call, _ transcript: String) throws -> String {
        let corrected = try store.correctedSegments(call.id)
        let note = corrected == 0 ? "" : ", \(corrected) segment\(corrected == 1 ? "" : "s") corrected"
        let head = "\(call.title ?? "Call") (\(call.status.rawValue), started \(Self.iso(call.startedAt)), id \(call.id)\(note))"
        return head + "\n\n" + (transcript.isEmpty ? "(nothing transcribed yet)" : transcript)
    }

    private static func content(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private static func failure(id: Any, code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
    }

    private static func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
               as: UTF8.self)
    }

    /// A Codable value as JSON objects, with snake_case keys and ISO 8601 times.
    private static func plain(_ value: some Encodable) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        // Whisper's log probability can be -inf, which JSON can't hold as a number.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity",
                                                                      negativeInfinity: "-Infinity", nan: "NaN")
        return try JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any] ?? [:]
    }

    /// What an agent following a call needs of a segment; the id is what correct_segment takes.
    private static func compact(_ segment: CallSegment) -> [String: Any] {
        var object: [String: Any] = [
            "id": segment.id, "channel": segment.channel.rawValue, "start_ms": segment.startMs,
            "end_ms": segment.endMs, "text": segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        if let original = segment.originalText {
            object["corrected"] = true
            object["original_text"] = original.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return object
    }

    private static func summary(_ dictation: Dictation) -> [String: Any] {
        var object: [String: Any] = [
            "id": dictation.id, "created_at": iso(dictation.createdAt), "duration_s": dictation.duration,
            "mode": dictation.mode.rawValue, "text": dictation.finalText,
        ]
        if dictation.rawText != dictation.finalText { object["raw_text"] = dictation.rawText }
        if let original = dictation.originalText {
            object["corrected"] = true
            object["original_text"] = original
        }
        if let error = dictation.error { object["error"] = error }
        if let origin = dictation.origin { object["origin"] = origin.rawValue }
        return object
    }

    /// A dictation with everything, and corrected: true when original_text is there.
    private static func full(_ dictation: Dictation) throws -> [String: Any] {
        var object = try plain(dictation)
        if dictation.corrected { object["corrected"] = true }
        return object
    }

    private static func plain(_ change: KeyTermsChange, changed: String? = nil, unchanged: String? = nil) -> [String: Any] {
        var object: [String: Any] = ["terms": change.terms, "tokens": change.tokens ?? NSNull(),
                                     "token_limit": change.limit ?? NSNull()]
        if let changed { object[changed] = change.changed }
        if let unchanged { object[unchanged] = change.unchanged }
        if let edit = change.edit { object["edit_id"] = edit.id }
        return object
    }

    private static func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

struct RPCError: Error {
    let code: Int
    let message: String

    init(_ code: Int, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// A tool that ran and failed: reported in its result, so the agent reads why.
struct ToolError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// A tool call's arguments, read leniently: agents send numbers as strings and one tag
/// where a list was asked for.
struct Arguments {
    let values: [String: Any]

    init(_ values: [String: Any]) {
        self.values = values
    }

    private func value(_ key: String) -> Any? {
        guard let value = values[key], !(value is NSNull) else { return nil }
        return value
    }

    func string(_ key: String) throws -> String? {
        guard let value = value(key) else { return nil }
        guard let text = value as? String else { throw ToolError("\(key) must be a string.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func require(_ key: String) throws -> String {
        guard let text = try string(key) else { throw ToolError("\(key) is required.") }
        return text
    }

    func double(_ key: String) throws -> Double? {
        guard let value = value(key) else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String, let number = Double(text) { return number }
        throw ToolError("\(key) must be a number.")
    }

    func int64(_ key: String) throws -> Int64? {
        guard let number = try double(key) else { return nil }
        guard number.rounded() == number, number >= 0 else { throw ToolError("\(key) must be a whole number, 0 or more.") }
        return Int64(number)
    }

    func int(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let number = try int64(key) else { return fallback }
        return min(max(Int(clamping: number), range.lowerBound), range.upperBound)
    }

    func strings(_ key: String) throws -> [String] {
        guard let value = value(key) else { return [] }
        if let text = value as? String { return [text] }
        guard let list = value as? [Any], list.allSatisfy({ $0 is String }) else {
            throw ToolError("\(key) must be a list of strings.")
        }
        return list.compactMap { $0 as? String }
    }

    func channel(_ key: String) throws -> CallSegment.Channel? {
        guard let text = try string(key)?.lowercased(), text != "all" else { return nil }
        guard let channel = CallSegment.Channel(rawValue: text) else {
            throw ToolError("\(key) is all, me, call or mix, not \(text).")
        }
        return channel
    }

    func date(_ key: String, now: Date = Date()) throws -> Date? {
        guard let text = try string(key) else { return nil }
        guard let date = Self.date(text, now: now) else {
            throw ToolError("\(key) must be an ISO 8601 time such as 2026-11-04T09:00:00Z, or a span such as 24h.")
        }
        return date
    }

    /// ISO 8601 with a zone; a date and time without one, in local time; a date alone, from
    /// local midnight; or minutes, hours, days or weeks back from now, as 90m, 24h, 7d, 2w.
    static func date(_ text: String, now: Date = Date()) -> Date? {
        let units: [Character: Double] = ["m": 60, "h": 3600, "d": 86400, "w": 604_800]
        let lower = text.lowercased()
        if let unit = lower.last, let seconds = units[unit], let amount = Double(lower.dropLast()), amount >= 0 {
            return now.addingTimeInterval(-amount * seconds)
        }
        let formatter = ISO8601DateFormatter()
        let attempts: [(ISO8601DateFormatter.Options, TimeZone?)] = [
            ([.withInternetDateTime, .withFractionalSeconds], nil),
            ([.withInternetDateTime], nil),
            ([.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate], .current),
            ([.withFullDate, .withDashSeparatorInDate], .current),
        ]
        let normalized = text.replacingOccurrences(of: " ", with: "T")
        for (options, zone) in attempts {
            formatter.formatOptions = options
            formatter.timeZone = zone ?? TimeZone(secondsFromGMT: 0)
            if let date = formatter.date(from: normalized) { return date }
        }
        return nil
    }
}
