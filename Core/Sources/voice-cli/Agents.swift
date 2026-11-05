import Foundation
import VoiceCore

// The commands for agents, which need no whisper model:
//
//   voice-cli mcp [--port N] [--db PATH]
//       serves MCP on 127.0.0.1 (port 7766) against the app's database until stopped, for
//       when Voice isn't running; the two can't both hold the port
//   voice-cli fake-call [--every SECONDS] [--count N] [--db PATH]
//       records nothing: writes a live call that gains a scripted segment every few
//       seconds, to test wait_for_transcript; prints the call's id, finishes it at the end
//       or on Ctrl-C
//   voice-cli fake-call --remove [--db PATH]
//       deletes every call fake-call wrote

/// Marks the calls fake-call writes, so --remove deletes those and nothing else.
let fakeCallBundleID = "io.github.spashii.voice-cli.fake-call"

func agentCommand(_ command: String, _ arguments: [String], dbPath: String?) async {
    do {
        try await runAgentCommand(command, arguments, dbPath: dbPath)
    } catch {
        log("voice-cli \(command): \(error)")
        exit(1)
    }
}

private func runAgentCommand(_ command: String, _ arguments: [String], dbPath: String?) async throws {
    var arguments = arguments
    func option(_ name: String) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        defer { arguments.removeSubrange(i...(i + 1)) }
        return arguments[i + 1]
    }
    let database = dbPath.map { URL(fileURLWithPath: $0) } ?? Paths.database
    switch command {
    case "mcp":
        let port = option("--port").flatMap(UInt16.init) ?? MCPServer.defaultPort
        try await serve(database, port: port)
    case "fake-call":
        if arguments.contains("--remove") {
            try removeFakeCalls(database)
        } else {
            try await fakeCall(database, every: option("--every").flatMap(Double.init) ?? 2,
                               count: option("--count").flatMap(Int.init) ?? 60)
        }
    default:
        break
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func serve(_ database: URL, port: UInt16) async throws {
    let store = try CallStore(url: database)
    let token = try MCPToken.load()
    let server = MCPServer(store: store, token: token, port: port, version: "voice-cli")
    let bound = try await server.start()
    log("MCP at http://127.0.0.1:\(bound)\(MCPServer.endpointPath) on \(database.path); token in \(MCPToken.file.path)")
    while true {
        try await Task.sleep(for: .seconds(3600))
        // Holds the server: its listener only keeps a weak reference.
        _ = server
    }
}

private let script: [(CallSegment.Channel, String)] = [
    (.me, "Hi, thanks for making the time. Can you hear me all right?"),
    (.call, "Yes, loud and clear. Shall we start with the pilot numbers?"),
    (.me, "Sure. We ran forty sessions last month across three municipalities."),
    (.call, "And how many of those produced a report the council actually used?"),
    (.me, "Thirty one. The other nine were too short to say much."),
    (.call, "That's better than I expected. What did people struggle with?"),
    (.me, "Mostly the microphone setup. The transcription itself held up well."),
    (.call, "Okay. Let's put the setup guide on the agenda for Thursday."),
]

private func fakeCall(_ database: URL, every: Double, count: Int) async throws {
    let store = try CallStore(url: database)
    let call = try store.createCall(NewCall(appBundleID: fakeCallBundleID, appName: "voice-cli fake-call",
                                            split: true, title: "Fake call from voice-cli"))
    try store.tagCall(call.id, add: ["fake"])
    print(call.id)
    fflush(stdout)

    // Ctrl-C or a kill finishes the call, so it doesn't stay the current call forever.
    let callID = call.id
    let stops = [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler {
            try? store.finishCall(callID)
            log("finished \(callID)")
            exit(0)
        }
        source.resume()
        return source
    }

    let step = Int(every * 1000)
    for i in 0..<count {
        try await Task.sleep(for: .milliseconds(step))
        let (channel, text) = script[i % script.count]
        let segment = NewCallSegment(channel: channel, startMs: i * step, endMs: (i + 1) * step - 200, text: text,
                                     avgLogprob: -0.2, noSpeechProb: 0.01, compressionRatio: 1.4)
        let written = try store.appendSegments(callID, [segment])
        log("\(i + 1)/\(count) cursor \(written.last?.id ?? 0) \(channel.rawValue): \(text)")
    }
    try store.finishCall(callID)
    log("finished \(callID)")
    _ = stops
}

private func removeFakeCalls(_ database: URL) throws {
    let store = try CallStore(url: database)
    let fakes = try store.calls(limit: 100_000).filter { $0.appBundleID == fakeCallBundleID }
    for call in fakes { try store.deleteCall(call.id) }
    print("removed \(fakes.count) fake call\(fakes.count == 1 ? "" : "s")")
}
