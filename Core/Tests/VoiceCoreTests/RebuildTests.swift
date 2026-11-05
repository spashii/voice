import AVFoundation
import Foundation
import Testing
@testable import VoiceCore

@Suite struct RebuildTests {
    private let store: CallStore
    private let dir: URL

    init() throws {
        let database = temporaryCallDatabase()
        dir = database.deletingLastPathComponent()
        store = try CallStore(url: database)
    }

    /// A live call with two segments from while it recorded, and its WAV.
    private func liveCall(wav: Bool) throws -> Call {
        let audio = dir.appending(path: "\(UUID().uuidString).wav")
        if wav {
            // Two seconds of tone on each side, loud enough to be cut as speech.
            try writeAudio(to: audio, sampleRate: 48_000, channels: 2, frames: 48_000 * 3,
                           sample: { c, i in i < 96_000 ? sine(c == 0 ? 300 : 500, rate: 48_000)(c, i) : 0 })
        } else {
            try Data("not a wav".utf8).write(to: audio)
        }
        let call = try store.createCall(NewCall(split: true, audioPath: audio.path))
        try store.appendSegments(call.id, [sampleSegment(.me, 0, "live words"), sampleSegment(.call, 500, "more")])
        return call
    }

    private let noModel = Transcriber(modelURL: URL(fileURLWithPath: "/nonexistent/ggml.bin"), vadModelURL: nil)

    @Test func launchFailsOnlyTheCallsItWontRebuild() throws {
        let kept = try liveCall(wav: true)
        let lost = try store.createCall(NewCall(split: false))
        #expect(try store.failInterruptedCalls(except: [kept.id]) == 1)
        #expect(try store.call(kept.id)?.status == .recording)
        #expect(try store.call(lost.id)?.status == .failed)
    }

    @Test func aRebuildThatDecodesNothingKeepsTheOldSegments() async throws {
        let call = try liveCall(wav: true)
        let rebuilt = try await CallRecorder(store: store, directory: dir).rebuild(call.id, transcriber: noModel)
        #expect(rebuilt.status == .failed)
        #expect(try store.segments(call.id).map(\.text) == ["live words", "more"])
    }

    @Test func anUnreadableWAVFailsTheCallAndKeepsItsSegments() async throws {
        let call = try liveCall(wav: false)
        await #expect(throws: (any Error).self) {
            try await CallRecorder(store: store, directory: dir).rebuild(call.id, transcriber: noModel)
        }
        let after = try #require(try store.call(call.id))
        #expect(after.status == .failed)
        #expect(after.error?.hasPrefix("Can't read its audio") == true)
        #expect(try store.segments(call.id).count == 2)
    }
}
