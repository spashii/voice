import Foundation
import VoiceCore

// Call recording without the app:
//
//   voice-cli call --file STEREO.wav [--fast] [--db PATH]
//       plays the WAV through CallRecorder as if it were a live call, in real time unless
//       --fast: left is me, right is the call (a mono file is one mixed side). Prints each
//       segment as it is stored, with how long after its words ended
//   voice-cli call --record SECONDS [--db PATH]
//       records the source the app would choose (a Blend mix, else the default microphone)
//   voice-cli call --rebuild ID [--db PATH]
//       transcribes a call again from its audio, WAV or m4a
//   voice-cli call --remove [--db PATH]
//       deletes every call `call --file` wrote, with its audio
//   voice-cli watch-calls [--raw]
//       prints call detection as it happens; --raw adds every process using audio each second

/// Marks the calls `call --file` writes, so --remove deletes those and nothing else.
let testCallBundleID = "io.github.spashii.voice-cli.call"

func callCommand(_ arguments: [String], transcriber: Transcriber, whisper: WhisperOptions, dbPath: String?) async {
    var arguments = arguments
    func option(_ name: String) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        defer { arguments.removeSubrange(i...(i + 1)) }
        return arguments[i + 1]
    }
    do {
        let store = try CallStore(url: dbPath.map { URL(fileURLWithPath: $0) } ?? Paths.database)
        let recorder = CallRecorder(store: store)
        // Loaded first, as the app does at launch, so the first words don't wait for it.
        try await transcriber.load()
        if arguments.contains("--remove") {
            let tests = try store.calls(limit: 100_000).filter { $0.appBundleID == testCallBundleID }
            for call in tests {
                try store.deleteCall(call.id)
                if let path = call.audioPath { try? FileManager.default.removeItem(atPath: path) }
            }
            print("removed \(tests.count) test call\(tests.count == 1 ? "" : "s")")
        } else if let id = option("--rebuild") {
            let call = try await recorder.rebuild(id, transcriber: transcriber, whisper: whisper)
            await recorder.waitForCompression()
            print(try store.transcript(call.id))
            print("\(call.status.rawValue) \(call.error ?? "")")
        } else if let seconds = option("--record").flatMap(Double.init) {
            let source = CallSources.choose(BlendDevices.load()) { InputDevices.id(forUID: $0) != nil }
            print("source \(source.name) \(source.channels.map(\.rawValue)) \(source.deviceUID ?? "default")")
            let call = try await recorder.start(source, transcriber: transcriber, whisper: whisper,
                                                appBundleID: testCallBundleID, appName: "voice-cli call")
            print("call \(call.id) split \(call.split) audio \(call.audioPath ?? "")")
            fflush(stdout)
            try await Task.sleep(for: .seconds(seconds))
            let done = await recorder.stop()
            await recorder.waitForCompression()
            print("\(done?.status.rawValue ?? "nothing recorded") \(done?.error ?? "")")
        } else if let file = option("--file") {
            let realTime = !arguments.contains("--fast")
            let printer = Task.detached { try await follow(store) }
            let call = try await recorder.play(URL(fileURLWithPath: file), transcriber: transcriber,
                                               whisper: whisper, realTime: realTime, appBundleID: testCallBundleID,
                                               appName: "voice-cli call", title: "voice-cli call") { call in
                print("call \(call.id) split \(call.split) audio \(call.audioPath ?? "")")
                fflush(stdout)
            }
            try? store.tagCall(call.id, add: ["test"])
            await recorder.waitForCompression()
            try await Task.sleep(for: .milliseconds(600))
            printer.cancel()
            print("\(call.status.rawValue) \(call.error ?? "")")
            print(try store.transcript(call.id))
        } else {
            fail("usage: voice-cli call --file STEREO.wav [--fast] | --record SECONDS | --rebuild ID | --remove")
        }
    } catch {
        fail("voice-cli call: \(error)")
    }
}

/// Prints the current call's segments as they land: lag is from the end of the words,
/// in call time, to when the segment was stored.
private func follow(_ store: CallStore) async throws {
    var cursor = try store.latestCursor()
    while !Task.isCancelled {
        let batch = try await store.waitForSegments(nil, after: cursor, timeout: .seconds(5))
        for segment in batch.segments {
            let lag = batch.call.map { segment.createdAt.timeIntervalSince($0.startedAt) - Double(segment.endMs) / 1000 }
            print(String(format: "[%@] %@ lag %.2fs: %@", CallTranscript.clock(segment.startMs),
                         segment.channel.rawValue, lag ?? 0, segment.text))
            fflush(stdout)
        }
        cursor = batch.cursor
    }
}

func watchCalls(raw: Bool) async -> Never {
    var tick: (@Sendable ([CallDetector.Usage]) -> Void)?
    if raw {
        tick = { (usage: [CallDetector.Usage]) in
            let all = CallApps.processes().map { process in
                "\(process.bundleID)(\(process.pid))" + (process.input ? " in" : "") + (process.output ? " out" : "")
            }
            let apps = usage.map { (app: CallDetector.Usage) -> String in
                app.name + (app.input ? " in" : "") + (app.output ? " out" : "")
            }
            print("call apps: \(apps.joined(separator: ", ")) | all: \(all.joined(separator: ", "))")
            fflush(stdout)
        }
    }
    let detector = CallDetector(onChange: { (calls: [DetectedCall]) in
        let names = calls.map { "\($0.name) (\($0.bundleID))" }
        print("\(ISO8601DateFormatter().string(from: Date())) in a call: \(calls.isEmpty ? "none" : names.joined(separator: ", "))")
        fflush(stdout)
    }, onTick: tick)
    detector.start()
    print("watching; Ctrl-C to stop")
    fflush(stdout)
    while true { try? await Task.sleep(for: .seconds(3600)) }
}
