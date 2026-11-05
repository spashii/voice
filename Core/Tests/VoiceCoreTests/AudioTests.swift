import AVFoundation
import XCTest
@testable import VoiceCore

final class AudioLoadTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeTempDir(self)
    }

    private func middle(_ samples: [Float]) -> ArraySlice<Float> {
        samples[(samples.count / 10)..<(samples.count - samples.count / 10)]
    }

    // MARK: The format

    func testWhisperTakes16kHzMonoFloats() {
        let format = Audio.format

        XCTAssertEqual(format.sampleRate, 16_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(format.isInterleaved)
        XCTAssertEqual(Audio.sampleRate, 16_000)
    }

    // MARK: Files that need no conversion

    func testARecordingInVoicesOwnFormatLoadsSampleForSample() throws {
        let url = dir.appending(path: "own.wav")
        try writeAudio(to: url, sampleRate: 16_000, channels: 1, frames: 16_000, sample: sine(440, rate: 16_000))

        let samples = try Audio.load(url)

        XCTAssertEqual(samples.count, 16_000)
        let expected = sine(440, rate: 16_000)
        for i in stride(from: 0, to: samples.count, by: 97) {
            XCTAssertEqual(samples[i], expected(0, i), accuracy: 2.0 / 32768, "sample \(i)")
        }
    }

    func testA32BitFloatWAVLoadsUnchanged() throws {
        let url = dir.appending(path: "float.wav")
        try writeAudio(to: url, sampleRate: 16_000, channels: 1, frames: 8_000, bitDepth: 32, isFloat: true,
                       sample: sine(1000, rate: 16_000, amplitude: 0.8))

        let samples = try Audio.load(url)

        XCTAssertEqual(samples.count, 8_000)
        XCTAssertEqual(samples.map(abs).max() ?? 0, 0.8, accuracy: 0.001)
    }

    func testARecordingWithNothingInItLoadsAsNoSamples() throws {
        let url = dir.appending(path: "silent-header.wav")
        try writeAudio(to: url, sampleRate: 16_000, channels: 1, frames: 0, sample: { _, _ in 0 })

        XCTAssertEqual(try Audio.load(url), [])
    }

    func testDigitalSilenceLoadsAsZeros() throws {
        let url = dir.appending(path: "silence.wav")
        try writeAudio(to: url, sampleRate: 16_000, channels: 1, frames: 4_000, sample: { _, _ in 0 })

        let samples = try Audio.load(url)

        XCTAssertEqual(samples.count, 4_000)
        XCTAssertEqual(samples.map(abs).max(), 0)
    }

    // MARK: Resampling and mixing down

    func testHigherRatesComeOutAs16kHzWithTheSameToneAndLevel() throws {
        for rate in [22_050.0, 24_000, 32_000, 44_100, 48_000, 96_000] {
            let url = dir.appending(path: "rate-\(Int(rate)).wav")
            try writeAudio(to: url, sampleRate: rate, channels: 1, frames: Int(rate * 2), sample: sine(440, rate: rate))

            let samples = try Audio.load(url)

            XCTAssertEqual(Double(samples.count), 32_000, accuracy: 200, "length from \(Int(rate)) Hz")
            XCTAssertEqual(rms(middle(samples)), 0.5 / 2.0.squareRoot(), accuracy: 0.02, "level from \(Int(rate)) Hz")
            XCTAssertEqual(frequency(of: middle(samples), rate: 16_000), 440, accuracy: 8, "tone from \(Int(rate)) Hz")
        }
    }

    func testLowerRatesAreResampledUp() throws {
        for rate in [8_000.0, 11_025] {
            let url = dir.appending(path: "low-\(Int(rate)).wav")
            try writeAudio(to: url, sampleRate: rate, channels: 1, frames: Int(rate * 2), sample: sine(300, rate: rate))

            let samples = try Audio.load(url)

            XCTAssertEqual(Double(samples.count), 32_000, accuracy: 200, "length from \(Int(rate)) Hz")
            XCTAssertEqual(frequency(of: middle(samples), rate: 16_000), 300, accuracy: 6, "tone from \(Int(rate)) Hz")
        }
    }

    func testStereoIsMixedDownToMonoWithoutLosingLevel() throws {
        let url = dir.appending(path: "stereo.wav")
        try writeAudio(to: url, sampleRate: 44_100, channels: 2, frames: 88_200, sample: sine(500, rate: 44_100))

        let samples = try Audio.load(url)

        XCTAssertEqual(Double(samples.count), 32_000, accuracy: 200)
        // Two identical channels mixed down must not come out louder than either, or a
        // loud stereo recording would clip.
        XCTAssertEqual(rms(middle(samples)), 0.5 / 2.0.squareRoot(), accuracy: 0.03)
        XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 0, 1.0)
    }

    func testSixteenKilohertzStereoIsMixedDownWithoutResampling() throws {
        let url = dir.appending(path: "stereo16.wav")
        try writeAudio(to: url, sampleRate: 16_000, channels: 2, frames: 16_000, sample: sine(440, rate: 16_000))

        let samples = try Audio.load(url)

        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 100)
        XCTAssertEqual(rms(middle(samples)), 0.5 / 2.0.squareRoot(), accuracy: 0.03)
    }

    func testAStereoFileWithOnlyOneChannelStillHasItsSound() throws {
        let url = dir.appending(path: "left-only.wav")
        try writeAudio(to: url, sampleRate: 48_000, channels: 2, frames: 96_000) { channel, i in
            channel == 0 ? sine(440, rate: 48_000)(0, i) : 0
        }

        let samples = try Audio.load(url)

        XCTAssertGreaterThan(rms(middle(samples)), 0.1, "a one-sided recording is not silence")
    }

    func testAStereoFileWithSoundOnlyInTheRightChannelIsNotSilence() throws {
        // A headset that puts the voice on one side must still be heard.
        let url = dir.appending(path: "right-only.wav")
        try writeAudio(to: url, sampleRate: 48_000, channels: 2, frames: 96_000) { channel, i in
            channel == 1 ? sine(440, rate: 48_000)(0, i) : 0
        }

        let samples = try Audio.load(url)

        XCTAssertGreaterThan(rms(middle(samples)), 0.1)
    }

    func testAVeryShortFileKeepsItsFewSamples() throws {
        let url = dir.appending(path: "blip.wav")
        try writeAudio(to: url, sampleRate: 48_000, channels: 1, frames: 480, sample: sine(1000, rate: 48_000))

        let samples = try Audio.load(url)

        XCTAssertEqual(Double(samples.count), 160, accuracy: 40)
    }

    func testResamplingDoesNotOvershootFullScale() throws {
        let url = dir.appending(path: "loud.wav")
        try writeAudio(to: url, sampleRate: 48_000, channels: 1, frames: 48_000, sample: sine(440, rate: 48_000, amplitude: 0.95))

        let samples = try Audio.load(url)

        XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 0, 1.0)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.9)
    }

    func testOtherContainersLoadToo() throws {
        let url = dir.appending(path: "other.caf")
        try writeAudio(to: url, sampleRate: 44_100, channels: 1, frames: 44_100, sample: sine(440, rate: 44_100))

        let samples = try Audio.load(url)

        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 100)
        XCTAssertEqual(frequency(of: middle(samples), rate: 16_000), 440, accuracy: 8)
    }

    func testACompressedM4AIsDecodedAndResampled() throws {
        let url = dir.appending(path: "compressed.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100)!
            buffer.frameLength = 44_100
            let tone = sine(440, rate: 44_100)
            for i in 0..<44_100 { buffer.floatChannelData![0][i] = tone(0, i) }
            try file.write(from: buffer)
        }

        let samples = try Audio.load(url)

        // AAC adds priming frames at the start, so the length is only close.
        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 1_200)
        XCTAssertEqual(frequency(of: middle(samples), rate: 16_000), 440, accuracy: 10)
    }

    // MARK: Files that are not readable

    func testAMissingFileThrows() {
        XCTAssertThrowsError(try Audio.load(dir.appending(path: "nothing.wav")))
    }

    func testAZeroByteFileThrows() throws {
        let url = try writeFile(Data(), named: "zero.wav", in: dir)

        XCTAssertThrowsError(try Audio.load(url))
    }

    func testATextFileThrows() throws {
        let url = try writeFile(Data("not audio at all".utf8), named: "text.wav", in: dir)

        XCTAssertThrowsError(try Audio.load(url))
    }

    func testAWAVCutInsideItsHeaderHasNoAudio() throws {
        let full = WAVFile(audio: pcm16Sine(frames: 100)).build().bytes
        for length in [4, 12, 20, 30, 40] {
            let url = try writeFile(Data(full.prefix(length)), named: "cut-\(length).wav", in: dir)

            // Reading may refuse the file or find it empty, but it never invents audio.
            XCTAssertEqual((try? Audio.load(url)) ?? [], [], "header cut at \(length) bytes")
        }
    }

    // MARK: A crash and its repair

    func testACrashedRecordingReadsAsNothingUntilItsHeaderIsRepaired() throws {
        let built = WAVFile(audio: pcm16Sine(frames: 32_000)).crashed()
        let url = try writeFile(built.bytes, named: "crashed.wav", in: dir)

        // The header says empty, so a reader sees no audio. This is why repair exists.
        let before = (try? Audio.load(url)) ?? []
        XCTAssertEqual(before.count, 0)

        Recovery.repairHeader(url)

        let after = try Audio.load(url)
        XCTAssertEqual(after.count, 32_000)
        XCTAssertGreaterThan(rms(after[...]), 0.3)
    }

    func testARecoveredRecordingWithAStrayByteStillLoads() throws {
        let built = WAVFile(audio: pcm16Sine(frames: 4_000) + Data([0x42])).crashed()
        let url = try writeFile(built.bytes, named: "stray.wav", in: dir)

        Recovery.repairHeader(url)

        XCTAssertEqual(try Audio.load(url).count, 4_000)
    }

    func testARecoveredStereoRecordingLoadsAsMono() throws {
        var wav = WAVFile(audio: pcm16Sine(frames: 24_000, rate: 48_000, channels: 2))
        wav.channels = 2
        wav.sampleRate = 48_000
        let url = try writeFile(wav.crashed().bytes, named: "stereo-crashed.wav", in: dir)

        XCTAssertEqual(try XCTUnwrap(Recovery.repairHeader(url)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Double(try Audio.load(url).count), 8_000, accuracy: 100)
    }
}

final class AudioStreamingTests: XCTestCase {
    func testOneShotHandsOverItsBufferOnceThenEndsTheStream() throws {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: Audio.format, frameCapacity: 10))
        let feed = OneShot(buffer)
        var status = AVAudioConverterInputStatus.noDataNow

        XCTAssertTrue(feed.next(&status) === buffer)
        XCTAssertEqual(status, .haveData)

        XCTAssertNil(feed.next(&status))
        XCTAssertEqual(status, .endOfStream)
        XCTAssertNil(feed.next(&status))
        XCTAssertEqual(status, .endOfStream)
    }

    func testOneShotThatDoesNotEndAsksForMoreLater() throws {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: Audio.format, frameCapacity: 10))
        let feed = OneShot(buffer, ends: false)
        var status = AVAudioConverterInputStatus.endOfStream

        XCTAssertTrue(feed.next(&status) === buffer)
        XCTAssertEqual(status, .haveData)
        XCTAssertNil(feed.next(&status))
        XCTAssertEqual(status, .noDataNow)
    }

    /// The recorder converts the microphone buffer by buffer. With `ends: false` the converter
    /// keeps its filter state between buffers, so the join between two buffers is seamless.
    func testBufferByBufferConversionHasNoClicksAtTheJoins() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: Audio.format))
        let tone = sine(440, rate: 48_000)
        var output: [Float] = []

        for chunk in 0..<12 {
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4096))
            input.frameLength = 4096
            for i in 0..<4096 { input.floatChannelData![0][i] = tone(0, chunk * 4096 + i) }
            let converted = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: Audio.format, frameCapacity: 4096 / 3 + 64))
            let feed = OneShot(input, ends: false)
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in feed.next(status) }
            XCTAssertNil(error)
            output += UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength))
        }

        // 12 buffers of 4096 frames at 48 kHz are about 16384 frames at 16 kHz.
        XCTAssertEqual(Double(output.count), 16_384, accuracy: 128)
        // A 440 Hz tone at amplitude 0.5 never moves more than about 0.09 between samples at
        // 16 kHz. A lost filter state would show as a jump at each join.
        let jumps = zip(output.dropFirst(64), output.dropFirst(65)).map { abs($0 - $1) }
        XCTAssertLessThan(jumps.max() ?? 0, 0.15)
    }
}
