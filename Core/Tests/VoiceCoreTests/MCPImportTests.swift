import AVFoundation
import Foundation
import Testing
@testable import VoiceCore

private let words = "Northwind budget review with Alex"

private struct FakeTranscriber: ChunkTranscribing {
    func transcribe(_ samples: [Float], options: WhisperOptions) async throws -> Transcript {
        let segment = Segment(t0: 0, t1: 1, text: words, avgLogprob: -0.2, noSpeechProb: 0.01, compressionRatio: 1.1,
                              speechSeconds: 1, wordsPerSecond: 3)
        return Transcript(text: words, segments: [segment], seconds: 0.01)
    }
}

/// What the app does for the tool: a real recorder on a temporary store, with a fake model.
private final class FakeRecording: RecordingControl, @unchecked Sendable {
    let recorder: CallRecorder
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    init(store: CallStore, directory: URL) {
        recorder = CallRecorder(store: store, directory: directory)
    }

    func stopRecording() async throws -> Call { throw ToolError("not used") }

    func importAudioFile(path: String) async throws -> CallRecorder.ImportStart {
        let url = URL(fileURLWithPath: path)
        let start = try await recorder.beginImport(url)
        if !start.duplicate {
            let task = Task { [recorder] in
                _ = await recorder.transcribeImport(start.call.id, transcriber: FakeTranscriber())
            }
            lock.withLock { tasks.append(task) }
        }
        return start
    }

    func finished() async {
        let all = lock.withLock { tasks }
        for task in all { await task.value }
        await recorder.waitForCompression()
    }
}

@Suite struct MCPImportTests {
    private struct Fixture {
        let root: URL
        let store: CallStore
        let recording: FakeRecording
        let router: MCPRouter

        init(disabled: Set<String> = [], withRecording: Bool = true) throws {
            root = realPath(FileManager.default.temporaryDirectory)
                .appending(path: "MCPImport-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try CallStore(url: root.appending(path: "voice.sqlite"))
            recording = FakeRecording(store: store, directory: root.appending(path: "calls", directoryHint: .isDirectory))
            router = MCPRouter(store: store, recording: withRecording ? recording : nil,
                               recordingUnavailable: "Recording is only available in the Dictate app.", version: "0",
                               switches: ToolSwitches(disabled: disabled))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func send(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
            let (_, answer) = await router.handle(body)
            let data = try #require(answer)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func tool(_ name: String, _ arguments: [String: Any]) async throws -> (object: [String: Any]?, failed: Bool, text: String) {
            let reply = try await send("tools/call", ["name": name, "arguments": arguments])
            let result = try #require(reply["result"] as? [String: Any])
            let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            return (object, result["isError"] as? Bool ?? false, text)
        }

        func wav(_ name: String = "Standup recording.wav") throws -> URL {
            let url = root.appending(path: name)
            let rate = 16_000.0
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                           AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = 3 * 16_000
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames {
                buffer.floatChannelData![0][i] = i < 2 * 16_000 ? Float(sin(2 * .pi * 440 * Double(i) / rate) * 0.5) : 0
            }
            try file.write(from: buffer)
            return url
        }
    }

    private func names(_ reply: [String: Any]) -> [String] {
        let result = reply["result"] as? [String: Any]
        return (result?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    @Test func aFreshInstallHasItOff() {
        let defaults = UserDefaults(suiteName: "dictate-tests-\(UUID().uuidString)")!
        #expect(MCPServer.offByDefault.contains("import_audio_file"))
        #expect(!AgentSettings.offByDefaultBeforeSeenList.contains("import_audio_file"))
        #expect(AgentSettings.disabledTools(in: defaults, existingInstall: false).contains("import_audio_file"))
    }

    @Test func anInstallFromBeforeItGetsItOffAndKeepsItsOwnChoices() {
        let defaults = UserDefaults(suiteName: "dictate-tests-\(UUID().uuidString)")!
        // 0.14: the person turned set_recording_title on, so it is not in the list, but it is seen.
        defaults.set(["tag_call", "list_calls"], forKey: AgentSettings.disabledToolsKey)
        defaults.set(MCPServer.offByDefault.subtracting(["import_audio_file"]).sorted(), forKey: AgentSettings.seenToolsKey)
        let disabled = AgentSettings.disabledTools(in: defaults, existingInstall: true)
        #expect(disabled == ["tag_call", "list_calls", "import_audio_file"])
        #expect(Set(defaults.stringArray(forKey: AgentSettings.seenToolsKey) ?? []) == MCPServer.offByDefault)
    }

    @Test func aPersonWhoTurnedItOnKeepsItOn() {
        let defaults = UserDefaults(suiteName: "dictate-tests-\(UUID().uuidString)")!
        defaults.set(["tag_call"], forKey: AgentSettings.disabledToolsKey)
        defaults.set(MCPServer.offByDefault.sorted(), forKey: AgentSettings.seenToolsKey)
        #expect(!AgentSettings.disabledTools(in: defaults, existingInstall: true).contains("import_audio_file"))
    }

    @Test func whileOffItIsNotListedAndRefusesCalls() async throws {
        let fixture = try Fixture(disabled: ["import_audio_file"])
        defer { fixture.remove() }
        #expect(!names(try await fixture.send("tools/list")).contains("import_audio_file"))
        let reply = try await fixture.send("tools/call", ["name": "import_audio_file",
                                                          "arguments": ["path": try fixture.wav().path]])
        let error = try #require(reply["error"] as? [String: Any])
        #expect((error["message"] as? String)?.contains("turned off") == true)
        #expect(try fixture.store.calls(limit: 10).isEmpty)
    }

    @Test func whenOnItImportsOnceAndTheTranscriptIsReadable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(names(try await fixture.send("tools/list")).contains("import_audio_file"))
        let file = try fixture.wav()

        let first = try await fixture.tool("import_audio_file", ["path": file.path])
        #expect(!first.failed)
        let call = try #require(first.object)
        let id = try #require(call["id"] as? String)
        #expect(["transcribing", "done"].contains(call["status"] as? String))
        #expect(call["file_name"] as? String == "Standup recording.wav")
        #expect(call["already_imported"] as? Bool == false)

        let again = try #require(try await fixture.tool("import_audio_file", ["path": file.path]).object)
        #expect(again["already_imported"] as? Bool == true)
        #expect(again["id"] as? String == id)
        #expect(try fixture.store.calls(limit: 10).count == 1)

        await fixture.recording.finished()
        let text = try await fixture.tool("get_transcript", ["id": id]).text
        #expect(text.contains(words))
        #expect(!text.contains("Me:") && !text.contains("Call:"))
        #expect(text.hasPrefix("Standup recording.wav (done"))
        let listed = try await fixture.tool("get_call", ["id": id]).object
        #expect(listed?["file_name"] as? String == "Standup recording.wav")
    }

    @Test func aBadPathIsAnErrorAndMakesNoCall() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let text = fixture.root.appending(path: "notes.txt")
        try Data("hi".utf8).write(to: text)
        let cases: [(path: String, message: String)] = [
            ("Standup recording.wav", "Use the full path to the file, starting with / or ~/."),
            (fixture.root.appending(path: "missing.wav").path, "No file at \(fixture.root.appending(path: "missing.wav").path)."),
            (fixture.root.path, "\(fixture.root.path) is not a file."),
            (text.path, "Only audio and video files can be imported."),
        ]
        for item in cases {
            let answer = try await fixture.tool("import_audio_file", ["path": item.path])
            #expect(answer.failed, "\(item.path)")
            #expect(answer.text == item.message)
        }
        let missing = try await fixture.tool("import_audio_file", [:])
        #expect(missing.failed && missing.text == "path is required.")
        #expect(try fixture.store.calls(limit: 10).isEmpty)
    }

    @Test func withoutTheAppItSaysSo() async throws {
        let fixture = try Fixture(withRecording: false)
        defer { fixture.remove() }
        let answer = try await fixture.tool("import_audio_file", ["path": try fixture.wav().path])
        #expect(answer.failed)
        #expect(answer.text == "Recording is only available in the Dictate app.")
        #expect(try fixture.store.calls(limit: 10).isEmpty)
    }
}
