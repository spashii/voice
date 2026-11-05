import AVFoundation
import Foundation
import os
import Testing
@testable import VoiceCore

private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "voice-tests-\(UUID().uuidString)",
                                                               directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// One second of quiet noise at 48 kHz, too soft to be cut as speech.
private func quietBuffer(channels: AVAudioChannelCount) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    buffer.frameLength = 48_000
    for c in 0..<Int(channels) {
        for f in 0..<48_000 { buffer.floatChannelData![c][f] = Float.random(in: -0.0001...0.0001) }
    }
    return buffer
}

/// A transcriber whose model doesn't exist: quiet audio never reaches it.
private let noModel = Transcriber(modelURL: URL(fileURLWithPath: "/nonexistent/ggml.bin"), vadModelURL: nil)

final class Counter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    func bump() { lock.withLock { $0 += 1 } }
    var value: Int { lock.withLock { $0 } }
}

@Suite struct InputLossTests {
    @Test func theWatchFiresForItsEngineOnlyAndNotAfterCancel() {
        let center = NotificationCenter()
        let engine = NSObject()
        let other = NSObject()
        let count = Counter()
        let watch = InputWatch(engine, center: center) { count.bump() }
        center.post(name: .AVAudioEngineConfigurationChange, object: other)
        #expect(count.value == 0)
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        #expect(count.value == 1)

        let later = Counter()
        let cancelled = InputWatch(engine, center: center) { later.bump() }
        cancelled.cancel()
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        #expect(later.value == 0)
        withExtendedLifetime(watch) {}
    }

    @Test func aDictationKeepsWhatWasRecordedWhenTheInputGoesAway() async throws {
        let dir = try temporaryDirectory()
        let url = dir.appending(path: "dictation.wav")
        let (lost, signal) = AsyncStream<Void>.makeStream()
        let recorder = Recorder(onInputLost: { signal.yield() })
        let input = quietBuffer(channels: 1)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Audio.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        // Only the sink holds the file, so closing it writes the header.
        let sink = Sink(file: try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                              interleaved: false), converter: AVAudioConverter(from: input.format, to: Audio.format)!,
                        onLevel: { _ in }, onSamples: nil)
        recorder.adopt(sink, url: url, engine: nil)
        sink.write(input)
        recorder.inputWentAway()
        recorder.inputWentAway()
        var events = lost.makeAsyncIterator()
        await events.next()

        let recording = try #require(await recorder.stop())
        #expect(recording.inputLost)
        #expect(abs(recording.duration - 1) < 0.05)
        #expect(try Audio.load(url).count > 15_000)
        #expect(await recorder.stop() == nil)
    }

    @Test func aCallFailsAndKeepsItsAudioWhenTheInputGoesAway() async throws {
        let dir = try temporaryDirectory()
        let store = try CallStore(url: dir.appending(path: "voice.sqlite"))
        let (lost, signal) = AsyncStream<Call?>.makeStream()
        let recorder = CallRecorder(store: store, directory: dir) { signal.yield($0) }
        let input = quietBuffer(channels: 2)
        let session = try recorder.begin(format: input.format, labels: [.me, .call], order: [0, 1], deviceUID: "mix",
                                         noModel, WhisperOptions(), appBundleID: "us.zoom.xos", appName: "Zoom",
                                         title: nil)
        session.ingest(input)
        recorder.inputWentAway()
        var events = lost.makeAsyncIterator()
        let call = try #require(await events.next() ?? nil)

        #expect(call.status == .failed)
        #expect(call.error == CallRecorder.inputLost)
        #expect(call.endedAt != nil)
        #expect(recorder.callID == nil)
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: try #require(call.audioPath)))
        #expect(audio.length == 48_000)
        #expect(audio.fileFormat.channelCount == 2)
    }
}
