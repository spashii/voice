import AVFoundation
import Foundation
import Testing
@testable import VoiceCore

private struct DiskFull: Error, CustomStringConvertible {
    var description: String { "disk full" }
}

private final class FailingWriter: AudioWriting {
    var attempts = 0
    func write(from buffer: AVAudioPCMBuffer) throws {
        attempts += 1
        throw DiskFull()
    }
}

private func tone(_ format: AVAudioFormat) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    buffer.frameLength = 4800
    for c in 0..<Int(format.channelCount) {
        for f in 0..<4800 { buffer.floatChannelData![c][f] = 0.3 * sin(Float(f) * 0.06) }
    }
    return buffer
}

@Suite struct WriteErrorTests {
    @Test func aDictationRemembersTheFirstWriteErrorAndStopsWriting() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let writer = FailingWriter()
        let heard = Counter()
        let sink = Sink(file: writer, converter: AVAudioConverter(from: format, to: Audio.format)!, onLevel: { _ in },
                        onSamples: { _ in heard.bump() })
        sink.write(tone(format))
        sink.write(tone(format))
        #expect(sink.writeError == "disk full")
        #expect(writer.attempts == 1)
        #expect(sink.frames == 0)
        // Live text never holds audio the file doesn't.
        #expect(heard.value == 0)
    }

    @Test func aCallWithAWriteErrorFinishesWithIt() async throws {
        let store = try CallStore(url: temporaryCallDatabase())
        let call = try store.createCall(NewCall(id: UUID().uuidString, startedAt: Date(), appBundleID: nil, appName: nil,
                                                deviceUID: nil, split: true, audioPath: nil, title: nil))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let session = try CallSession(callID: call.id, format: format, labels: [.me, .call], order: [0, 1], wav: nil,
                                      writer: FailingWriter(), store: store,
                                      transcriber: Transcriber(modelURL: URL(fileURLWithPath: "/nonexistent"),
                                                               vadModelURL: nil),
                                      whisper: WhisperOptions())
        session.ingest(tone(format))
        let failure = try #require(await session.finish())
        #expect(failure.hasPrefix("Couldn't write the call's audio"))
        #expect(failure.hasSuffix("disk full"))
    }
}
