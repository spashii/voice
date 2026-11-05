import AVFoundation
import Foundation
import Testing
@testable import VoiceCore

/// A split source as Voice chooses it from Blend's devices.json, with the call on either side.
private func splitMix(callOnLeft: Bool = false, speakers: [String]? = nil) -> CallSource {
    CallSource(deviceUID: "app.blend.mix.split", name: "Mic and system audio",
               channels: callOnLeft ? [.call, .me] : [.me, .call], fromBlend: true, speakers: speakers)
}

private let mixedMix = CallSource(deviceUID: "app.blend.mix.mixed", name: "Everything", channels: [.mix],
                                  fromBlend: true)

private let noModel = Transcriber(modelURL: URL(fileURLWithPath: "/nonexistent/ggml.bin"), vadModelURL: nil)

/// One second at 48 kHz with a different tone on each input channel.
private func tones(_ frequencies: [Double]) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(frequencies.count))!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    buffer.frameLength = 48_000
    for (c, frequency) in frequencies.enumerated() {
        let tone = sine(frequency, rate: 48_000)
        for f in 0..<48_000 { buffer.floatChannelData![c][f] = tone(c, f) }
    }
    return buffer
}

@Suite struct CallChannelsTests {
    @Test func aSplitMixKeepsMeOnTheLeft() throws {
        let plain = try CallChannels(splitMix(), inputChannels: 2)
        #expect(plain.labels == [.me, .call])
        #expect(plain.order == [0, 1])
        #expect(try CallChannels(splitMix(callOnLeft: true), inputChannels: 2).order == [1, 0])
        let named = try CallChannels(splitMix(speakers: ["Zoom", "Teams"]), inputChannels: 2)
        #expect(named.order == [0, 1])
        #expect(named.speakers == ["Zoom", "Teams"])
    }

    @Test func aMixRecordsAtMostTwoChannelsAsOne() throws {
        for (inputs, order) in [(1, [0]), (2, [0, 1]), (4, [0, 1])] {
            let channels = try CallChannels(mixedMix, inputChannels: inputs)
            #expect(channels.labels == [.mix])
            #expect(channels.order == order)
            #expect(channels.speakers == nil)
        }
        #expect(try CallChannels(.defaultMicrophone, inputChannels: 1).order == [0])
    }

    @Test func aSplitMixWithoutTwoChannelsIsRefused() {
        #expect(throws: VoiceError.self) { try CallChannels(splitMix(), inputChannels: 1) }
        #expect(throws: VoiceError.self) { try CallChannels(splitMix(), inputChannels: 4) }
        #expect(CallChannels.sidesMissing(1) == "Got 1 channel from the call mix, so the call side is missing.")
        #expect(CallChannels.sidesMissing(4).hasPrefix("Got 4 channels from the call mix rather than 2"))
    }

    @Test func aSplitCallGivenOneChannelFailsAtOnceAndKeepsItsFile() throws {
        let database = temporaryCallDatabase()
        let dir = database.deletingLastPathComponent()
        let store = try CallStore(url: database)
        let recorder = CallRecorder(store: store, directory: dir)
        let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        do {
            _ = try recorder.open(splitMix(), format: mono, noModel, WhisperOptions(), appBundleID: nil, appName: nil,
                                  title: "Guard")
            Issue.record("A split call with one channel was recorded.")
        } catch {
            #expect("\(error)" == "Got 1 channel from the call mix, so the call side is missing.")
        }
        #expect(recorder.callID == nil)
        let call = try #require(try store.calls(limit: 10).first)
        #expect(call.status == .failed)
        #expect(call.error == "Got 1 channel from the call mix, so the call side is missing.")
        #expect(call.title == "Guard")
        let path = try #require(call.audioPath)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func aSplitCallWritesMeLeftAndTheCallRightWhicheverSideBlendUses() async throws {
        let database = temporaryCallDatabase()
        let dir = database.deletingLastPathComponent()
        let store = try CallStore(url: database)
        let recorder = CallRecorder(store: store, directory: dir)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let session = try recorder.open(splitMix(callOnLeft: true), format: stereo, noModel, WhisperOptions(),
                                        appBundleID: nil, appName: nil, title: nil)
        let call = try #require(try store.call(session.callID))
        #expect(call.split)
        // Blend put the call (300 Hz) on the left and me (700 Hz) on the right.
        session.ingest(tones([300, 700]))
        await recorder.abandon()
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: try #require(call.audioPath)))
        #expect(file.processingFormat.channelCount == 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let left = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let right = Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength)))
        #expect(abs(frequency(of: left[...], rate: 48_000) - 700) < 10)
        #expect(abs(frequency(of: right[...], rate: 48_000) - 300) < 10)
    }

    @Test func rebuildingASplitCallFromOneChannelFailsIt() async throws {
        let database = temporaryCallDatabase()
        let dir = database.deletingLastPathComponent()
        let store = try CallStore(url: database)
        let audio = dir.appending(path: "mono.wav")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeAudio(to: audio, sampleRate: 48_000, channels: 1, frames: 48_000, sample: sine(300, rate: 48_000))
        let call = try store.createCall(NewCall(split: true, audioPath: audio.path))
        try store.appendSegments(call.id, [sampleSegment(.me, 0, "live words")])
        await #expect(throws: VoiceError.self) {
            try await CallRecorder(store: store, directory: dir).rebuild(call.id, transcriber: noModel)
        }
        let after = try #require(try store.call(call.id))
        #expect(after.status == .failed)
        #expect(after.error == "Got 1 channel from the call mix, so the call side is missing.")
        #expect(try store.segments(call.id).map(\.text) == ["live words"])
    }
}
