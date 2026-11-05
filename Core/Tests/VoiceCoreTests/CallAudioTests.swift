import AVFoundation
import Foundation
import Testing
@testable import VoiceCore

@Suite struct CallAudioTests {
    private let store: CallStore
    private let dir: URL

    init() throws {
        let database = temporaryCallDatabase()
        dir = database.deletingLastPathComponent()
        store = try CallStore(url: database)
    }

    /// A WAV with a different tone on each side, like a split call.
    private func stereoWAV(seconds: Double = 3, rate: Double = 48_000) throws -> URL {
        let url = dir.appending(path: "\(UUID().uuidString).wav")
        try writeAudio(to: url, sampleRate: rate, channels: 2, frames: Int(rate * seconds),
                       sample: { c, i in sine(c == 0 ? 300 : 500, rate: rate)(c, i) })
        return url
    }

    private func finishedCall(_ wav: URL) throws -> Call {
        let call = try store.createCall(NewCall(split: true, audioPath: wav.path))
        try store.finishCall(call.id)
        return call
    }

    @Test func conversionKeepsDurationChannelsAndEachSide() throws {
        let wav = try stereoWAV()
        let m4a = try CallAudio.encode(wav)

        #expect(m4a.pathExtension == "m4a")
        let before = try AVAudioFile(forReading: wav)
        let after = try AVAudioFile(forReading: m4a)
        #expect(after.processingFormat.channelCount == 2)
        #expect(after.processingFormat.sampleRate == 48_000)
        #expect(abs(Double(after.length) - Double(before.length)) / 48_000 <= CallAudio.durationTolerance)

        // Each side still carries its own tone, so the channels weren't mixed or swapped.
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: after.processingFormat, frameCapacity: 48_000))
        after.framePosition = 24_000
        try after.read(into: buffer, frameCount: 48_000)
        let sides = try #require(buffer.floatChannelData)
        let count = Int(buffer.frameLength)
        #expect(abs(frequency(of: Array(UnsafeBufferPointer(start: sides[0], count: count))[...], rate: 48_000) - 300) < 15)
        #expect(abs(frequency(of: Array(UnsafeBufferPointer(start: sides[1], count: count))[...], rate: 48_000) - 500) < 15)

        let wavBytes = try FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int ?? 0
        let m4aBytes = try FileManager.default.attributesOfItem(atPath: m4a.path)[.size] as? Int ?? 0
        #expect(m4aBytes > 0 && m4aBytes * 4 < wavBytes)
    }

    @Test func aMixedCallStaysOneChannelAtItsOwnRate() throws {
        let wav = dir.appending(path: "\(UUID().uuidString).wav")
        try writeAudio(to: wav, sampleRate: 44_100, channels: 1, frames: 44_100 * 2, sample: sine(400, rate: 44_100))
        let m4a = try CallAudio.encode(wav)

        let after = try AVAudioFile(forReading: m4a)
        #expect(after.processingFormat.channelCount == 1)
        #expect(after.processingFormat.sampleRate == 44_100)
    }

    @Test func compressingAFinishedCallSwapsTheFileAndThePath() async throws {
        let wav = try stereoWAV()
        let call = try finishedCall(wav)

        #expect(await CallRecorder(store: store, directory: dir).compressAudio(call.id))

        let path = try #require(try store.call(call.id)?.audioPath)
        #expect(path == wav.deletingPathExtension().appendingPathExtension("m4a").path)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: wav.path))
    }

    @Test func aFailedConversionKeepsTheWAVAndThePath() async throws {
        let wav = dir.appending(path: "\(UUID().uuidString).wav")
        try Data("not a wav".utf8).write(to: wav)
        let call = try finishedCall(wav)

        #expect(await CallRecorder(store: store, directory: dir).compressAudio(call.id) == false)

        #expect(try store.call(call.id)?.audioPath == wav.path)
        #expect(FileManager.default.fileExists(atPath: wav.path))
        #expect(!FileManager.default.fileExists(atPath: wav.deletingPathExtension().appendingPathExtension("m4a").path))
    }

    @Test func anAACOfTheWrongLengthIsNotTrusted() throws {
        let wav = try stereoWAV(seconds: 2)
        let m4a = try CallAudio.encode(wav)

        #expect(throws: (any Error).self) {
            try CallAudio.verify(m4a, against: .init(seconds: 2 + CallAudio.durationTolerance + 0.5, channels: 2,
                                                     sampleRate: 48_000))
        }
        #expect(throws: (any Error).self) {
            try CallAudio.verify(m4a, against: .init(seconds: 2, channels: 1, sampleRate: 48_000))
        }
    }

    @Test func aFailedConversionLeavesNoPartialFileAndAStaleOneIsReplaced() throws {
        let wav = dir.appending(path: "\(UUID().uuidString).wav")
        try Data("not a wav".utf8).write(to: wav)
        #expect(throws: (any Error).self) { try CallAudio.encode(wav) }
        #expect(!FileManager.default.fileExists(atPath: wav.deletingPathExtension().appendingPathExtension("m4a").path))

        let good = try stereoWAV(seconds: 1)
        let stale = good.deletingPathExtension().appendingPathExtension("m4a")
        try Data("half written".utf8).write(to: stale)
        let m4a = try CallAudio.encode(good)
        #expect(try AVAudioFile(forReading: m4a).length > 0)
    }

    @Test func onlyAFinishedCallIsCompressed() async throws {
        let wav = try stereoWAV(seconds: 1)
        let live = try store.createCall(NewCall(split: true, audioPath: wav.path))
        let failed = try store.createCall(NewCall(split: true, audioPath: wav.path))
        try store.failCall(failed.id, error: "no")
        let recorder = CallRecorder(store: store, directory: dir)

        #expect(await recorder.compressAudio(live.id) == false)
        #expect(await recorder.compressAudio(failed.id) == false)
        #expect(FileManager.default.fileExists(atPath: wav.path))
    }

    @Test func aCallThatFinishesIsCompressedAfterwards() async throws {
        // Silence is never cut as speech, so no chunk reaches the transcriber and the call
        // finishes done without a model.
        let silent = dir.appending(path: "silence.wav")
        try writeAudio(to: silent, sampleRate: 48_000, channels: 2, frames: 48_000 * 2, sample: { _, _ in 0 })
        let recorder = CallRecorder(store: store, directory: dir)
        let noModel = Transcriber(modelURL: URL(fileURLWithPath: "/nonexistent/ggml.bin"), vadModelURL: nil)

        let call = try await recorder.play(silent, transcriber: noModel, realTime: false)
        await recorder.waitForCompression()

        #expect(call.status == .done)
        let after = try #require(try store.call(call.id))
        let path = try #require(after.audioPath)
        #expect(path.hasSuffix(".m4a"))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".wav") }
            == ["silence.wav"])
    }

    @Test func finishedCallsLeftWithAWAVAreFoundAndCompressed() async throws {
        let old = try finishedCall(try stereoWAV(seconds: 1))
        let compressed = try finishedCall(try stereoWAV(seconds: 1))
        try store.setAudioPath(compressed.id, "/calls/already.m4a")
        #expect(try store.callsAwaitingCompression().map(\.id) == [old.id])

        await CallRecorder(store: store, directory: dir).compressFinishedCalls()

        #expect(try store.callsAwaitingCompression().isEmpty)
        #expect(try store.call(old.id)?.audioPath?.hasSuffix(".m4a") == true)
    }

    @Test func rebuildReadsTheCompressedAudio() async throws {
        let m4a = try CallAudio.encode(try stereoWAV())
        let call = try store.createCall(NewCall(split: true, audioPath: m4a.path))
        try store.appendSegments(call.id, [sampleSegment(.me, 0, "live words")])
        let noModel = Transcriber(modelURL: URL(fileURLWithPath: "/nonexistent/ggml.bin"), vadModelURL: nil)

        // It opens and decodes, so the failure is the missing model's and the transcript stays.
        let rebuilt = try await CallRecorder(store: store, directory: dir).rebuild(call.id, transcriber: noModel)

        #expect(rebuilt.status == .failed)
        #expect(rebuilt.error?.hasPrefix("Can't read its audio") != true)
        #expect(try store.segments(call.id).map(\.text) == ["live words"])
        #expect(rebuilt.audioPath == m4a.path)
    }
}

@Suite struct CallPruneTests {
    private let store: CallStore
    private let dir: URL
    private let day: TimeInterval = 24 * 3600

    init() throws {
        let database = temporaryCallDatabase()
        dir = database.deletingLastPathComponent()
        store = try CallStore(url: database)
    }

    /// A call that started `ageDays` ago, with an audio file of the given extension.
    private func call(_ ageDays: Double, ext: String = "wav", status: Call.Status = .done,
                      audio: URL? = nil) throws -> (Call, URL) {
        let file = audio ?? dir.appending(path: "\(UUID().uuidString).\(ext)")
        if !FileManager.default.fileExists(atPath: file.path) { try Data([1, 2, 3]).write(to: file) }
        let call = try store.createCall(NewCall(startedAt: Date().addingTimeInterval(-ageDays * day), split: true,
                                                audioPath: file.path))
        try store.appendSegments(call.id, [sampleSegment(.me, 0, "budget review")])
        try store.tagCall(call.id, add: ["team"])
        switch status {
        case .done: try store.finishCall(call.id)
        case .failed: try store.failCall(call.id, error: "no")
        case .transcribing: try store.markTranscribing(call.id)
        case .recording: break
        }
        return (call, file)
    }

    private var thirtyDays: Date { Date().addingTimeInterval(-30 * day) }

    @Test func removesOldCallsWithTheirSegmentsTagsAndAudioInEitherFormat() throws {
        let (oldWAV, oldWAVFile) = try call(31)
        let (oldM4A, oldM4AFile) = try call(90, ext: "m4a")
        let (failed, failedFile) = try call(45, status: .failed)
        let (recent, recentFile) = try call(2, ext: "m4a")
        #expect(try store.search("budget").count == 4)

        #expect(try store.prune(before: thirtyDays) == 3)

        #expect(try store.calls(limit: 10).map(\.id) == [recent.id])
        for gone in [oldWAV, oldM4A, failed] { #expect(try store.segments(gone.id).isEmpty) }
        #expect(try store.segments(recent.id).count == 1)
        #expect(try store.call(oldWAV.id) == nil)
        #expect(try store.calls(tag: "team", limit: 10).map(\.id) == [recent.id])
        #expect(try store.search("budget").map(\.id) == [recent.id])
        for file in [oldWAVFile, oldM4AFile, failedFile] { #expect(!FileManager.default.fileExists(atPath: file.path)) }
        #expect(FileManager.default.fileExists(atPath: recentFile.path))
    }

    @Test func neverRemovesACallThatIsStillLive() throws {
        let (recording, recordingFile) = try call(40, status: .recording)
        let (transcribing, transcribingFile) = try call(40, status: .transcribing)

        #expect(try store.prune(before: thirtyDays) == 0)

        #expect(try store.call(recording.id) != nil)
        #expect(try store.call(transcribing.id) != nil)
        #expect(FileManager.default.fileExists(atPath: recordingFile.path))
        #expect(FileManager.default.fileExists(atPath: transcribingFile.path))
    }

    @Test func foreverRemovesNothing() throws {
        let (_, file) = try call(4000)

        #expect(try store.prune(before: .distantPast) == 0)

        #expect(try store.calls(limit: 10).count == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func keepsAFileAKeptCallStillPointsAt() throws {
        let (_, shared) = try call(60)
        _ = try call(1, audio: shared)

        #expect(try store.prune(before: thirtyDays) == 1)

        #expect(FileManager.default.fileExists(atPath: shared.path))
    }

    @Test func aCallWithoutAudioIsStillRemoved() throws {
        let old = try store.createCall(NewCall(startedAt: Date().addingTimeInterval(-50 * day), split: false))
        try store.finishCall(old.id)

        #expect(try store.prune(before: thirtyDays) == 1)
        #expect(try store.call(old.id) == nil)
    }

    @Test func leavesDictationsToTheirOwnPrune() throws {
        let url = temporaryCallDatabase()
        let both = try CallStore(url: url)
        let store = try Store(url: url)
        try store.insert(sampleDictation("old dictation", at: Date().addingTimeInterval(-60 * day)))

        #expect(try both.prune(before: thirtyDays) == 0)
        #expect(store.recent(5).count == 1)
    }
}
