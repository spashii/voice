import Foundation
import Testing
@testable import VoiceCore

/// A server on a free port with its own database, and a client for it.
private struct Fixture {
    let calls: CallStore
    let server: MCPServer
    let base: URL
    let token = String(repeating: "ab", count: 32)

    init() async throws {
        calls = try CallStore(url: temporaryCallDatabase())
        server = MCPServer(store: calls, token: token, port: 0)
        let port = try await server.start()
        base = URL(string: "http://127.0.0.1:\(port)")!
    }

    func post(_ body: Any, path: String = "/mcp", token: String? = nil) async throws -> (Int, Any?) {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token ?? self.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data))
    }

    func rpc(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let (status, body) = try await post(["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        #expect(status == 200)
        return try #require(body as? [String: Any])
    }

    /// A tool's text, and whether it reported an error.
    func tool(_ name: String, _ arguments: [String: Any] = [:]) async throws -> (String, Bool) {
        let reply = try await rpc("tools/call", ["name": name, "arguments": arguments])
        let result = try #require(reply["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    func toolJSON(_ name: String, _ arguments: [String: Any] = [:]) async throws -> Any {
        let (text, isError) = try await tool(name, arguments)
        #expect(!isError, "\(name): \(text)")
        return try JSONSerialization.jsonObject(with: Data(text.utf8))
    }
}

@Suite struct MCPServerTests {
    @Test func refusesRequestsWithoutTheToken() async throws {
        let fixture = try await Fixture()
        defer { fixture.server.stop() }
        var request = URLRequest(url: fixture.base.appending(path: "/mcp"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 401)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate")?.hasPrefix("Bearer") == true)

        let (wrong, _) = try await fixture.post(["jsonrpc": "2.0", "id": 1, "method": "ping"],
                                                token: String(repeating: "cd", count: 32))
        #expect(wrong == 401)
        let (otherPath, _) = try await fixture.post(["jsonrpc": "2.0", "id": 1, "method": "ping"], path: "/other",
                                                    token: "short")
        #expect(otherPath == 401)
    }

    @Test func initializesAndListsTools() async throws {
        let fixture = try await Fixture()
        defer { fixture.server.stop() }
        let reply = try await fixture.rpc("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:],
            "clientInfo": ["name": "test", "version": "1"],
        ])
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "voice")

        let newer = try await fixture.rpc("initialize", ["protocolVersion": "2099-01-01"])
        #expect((newer["result"] as? [String: Any])?["protocolVersion"] as? String == MCPRouter.protocolVersions[0])

        let (status, body) = try await fixture.post(["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(status == 202)
        #expect(body == nil)

        let tools = try #require((try await fixture.rpc("tools/list"))["result"] as? [String: Any])
        let names = (tools["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        #expect(Set(names) == ["list_calls", "get_call", "get_transcript", "current_call", "wait_for_transcript",
                               "search_transcripts", "tag_call", "list_dictations", "get_dictation",
                               "start_recording", "stop_recording", "correct_dictation", "correct_segment",
                               "list_key_terms", "add_key_terms", "remove_key_terms", "list_edits", "undo_edit"])
        #expect(try await fixture.rpc("ping")["result"] != nil)
        let unknown = try await fixture.rpc("prompts/get")
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func answersBatchesAndRejectsOtherMethods() async throws {
        let fixture = try await Fixture()
        defer { fixture.server.stop() }
        let (status, body) = try await fixture.post([
            ["jsonrpc": "2.0", "id": "a", "method": "ping"],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "ping"],
        ])
        #expect(status == 200)
        #expect((body as? [[String: Any]])?.count == 2)

        var get = URLRequest(url: fixture.base.appending(path: "/mcp"))
        get.setValue("Bearer \(fixture.token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: get)
        #expect((response as? HTTPURLResponse)?.statusCode == 405)
    }

    @Test func reportsACallsAudioWhateverItsFormat() async throws {
        let fixture = try await Fixture()
        defer { fixture.server.stop() }
        let wav = try fixture.calls.createCall(NewCall(split: true, audioPath: "/calls/a.wav"))
        let m4a = try fixture.calls.createCall(NewCall(split: true, audioPath: "/calls/b.wav"))
        try fixture.calls.setAudioPath(m4a.id, "/calls/b.m4a")

        let first = try #require(try await fixture.toolJSON("get_call", ["id": wav.id]) as? [String: Any])
        let second = try #require(try await fixture.toolJSON("get_call", ["id": m4a.id]) as? [String: Any])
        #expect(first["audio_path"] as? String == "/calls/a.wav")
        #expect(second["audio_path"] as? String == "/calls/b.m4a")
    }

    @Test func readsCallsThroughTheTools() async throws {
        let fixture = try await Fixture()
        defer { fixture.server.stop() }
        let call = try fixture.calls.createCall(NewCall(split: true, title: "Standup"))
        try fixture.calls.appendSegments(call.id, [sampleSegment(.me, 0, "Morning all."), sampleSegment(.call, 1500, "Morning!")])

        let list = try #require(try await fixture.toolJSON("list_calls", ["limit": 5]) as? [[String: Any]])
        #expect(list.first?["id"] as? String == call.id)
        #expect(list.first?["status"] as? String == "recording")

        let (text, _) = try await fixture.tool("get_transcript", ["id": "current"])
        #expect(text.hasSuffix("[00:00] Me: Morning all.\n[00:01] Call: Morning!"))

        let current = try #require(try await fixture.toolJSON("current_call") as? [String: Any])
        #expect((current["call"] as? [String: Any])?["title"] as? String == "Standup")

        let tags = try #require(try await fixture.toolJSON("tag_call", ["id": call.id, "add": ["team"]]) as? [String: Any])
        #expect(tags["tags"] as? [String] == ["team"])

        let hits = try #require(try await fixture.toolJSON("search_transcripts", ["query": "morning"]) as? [[String: Any]])
        #expect(hits.count == 2)

        let (missing, isError) = try await fixture.tool("get_call", ["id": "nope"])
        #expect(isError)
        #expect(missing == "No call nope.")

        let (recording, recordingError) = try await fixture.tool("start_recording")
        #expect(recordingError)
        #expect(recording.contains("only available in the Voice app"))

        let read = try await fixture.rpc("resources/read", ["uri": "call://\(call.id)/transcript"])
        let contents = (read["result"] as? [String: Any])?["contents"] as? [[String: Any]]
        #expect((contents?.first?["text"] as? String)?.contains("Call: Morning!") == true)
        let resources = try await fixture.rpc("resources/list")
        #expect(((resources["result"] as? [String: Any])?["resources"] as? [Any])?.count == 2)
    }

    @Test func waitsForLiveSegments() async throws {
        let fixture = try await Fixture()
        defer { fixture.server.stop() }
        let call = try fixture.calls.createCall(NewCall(split: true))
        let current = try #require(try await fixture.toolJSON("current_call") as? [String: Any])
        let cursor = try #require(current["cursor"] as? Int)

        let started = ContinuousClock.now
        async let waited = fixture.tool("wait_for_transcript", ["cursor": cursor, "timeout_s": 20])
        // A second request on another connection isn't held up by the wait.
        #expect(try await fixture.rpc("ping")["result"] != nil)
        try await Task.sleep(for: .milliseconds(400))
        try fixture.calls.appendSegments(call.id, [sampleSegment(.call, 0, "Can you hear me?")])
        let (text, isError) = try await waited
        #expect(!isError)
        let result = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(result["call_id"] as? String == call.id)
        #expect((result["segments"] as? [[String: Any]])?.first?["text"] as? String == "Can you hear me?")
        #expect((result["cursor"] as? Int ?? 0) > cursor)
    }
}

@Suite struct MCPTokenAndDateTests {
    @Test func makesAPrivateTokenOnceAndKeepsIt() throws {
        let url = temporaryCallDatabase().deletingLastPathComponent().appending(path: "mcp-token")
        let token = try MCPToken.load(from: url)
        #expect(token.count == 64)
        #expect(token.allSatisfy { $0.isHexDigit })
        #expect(try MCPToken.load(from: url) == token)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func readsDatesAgentsSend() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Arguments.date("24h", now: now) == now.addingTimeInterval(-86400))
        #expect(Arguments.date("90m", now: now) == now.addingTimeInterval(-5400))
        #expect(Arguments.date("2026-11-04T09:00:00Z") == Date(timeIntervalSince1970: 1_793_782_800))
        #expect(Arguments.date("2026-11-04T09:00:00.500+01:00") != nil)
        #expect(Arguments.date("2026-11-04") != nil)
        #expect(Arguments.date("2026-11-04 09:30") != nil)
        #expect(Arguments.date("yesterday") == nil)
    }
}
