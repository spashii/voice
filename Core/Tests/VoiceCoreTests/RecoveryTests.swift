import AVFoundation
import XCTest
@testable import VoiceCore

/// A recording that a crash left behind has to come back whole, and a file that is not a
/// recording must be left alone.
final class RecoveryRepairTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeTempDir(self)
    }

    // MARK: A header that still says "empty"

    func testCrashedHeaderIsRepairedFromTheFileSize() throws {
        let wav = WAVFile(audio: pcm16Sine(frames: 16_000))  // one second
        let built = wav.crashed()
        XCTAssertEqual(built.bytes.le32(at: built.dataSizeOffset), 0, "the fixture should look crashed")
        let url = try writeFile(built.bytes, named: "crashed.wav", in: dir)

        let seconds = Recovery.repairHeader(url)

        XCTAssertEqual(try XCTUnwrap(seconds), 1.0, accuracy: 1e-9)
        let fixed = try Data(contentsOf: url)
        XCTAssertEqual(fixed.le32(at: built.dataSizeOffset), 32_000)
        XCTAssertEqual(fixed.le32(at: 4), UInt32(fixed.count - 8), "the RIFF size covers the whole file")
        XCTAssertEqual(fixed.count, built.bytes.count, "repair only rewrites sizes, it never changes the length")
    }

    func testRepairKeepsEveryAudioByte() throws {
        let audio = pcm16Sine(frames: 8_000)
        let built = WAVFile(audio: audio).crashed()
        let url = try writeFile(built.bytes, named: "keep.wav", in: dir)

        Recovery.repairHeader(url)

        let fixed = try Data(contentsOf: url)
        XCTAssertEqual(fixed.suffix(audio.count), audio)
    }

    func testRepairedFileIsReadableAndHasAllItsFrames() throws {
        let built = WAVFile(audio: pcm16Sine(frames: 24_000)).crashed()
        let url = try writeFile(built.bytes, named: "readable.wav", in: dir)

        Recovery.repairHeader(url)

        let samples = try Audio.load(url)
        XCTAssertEqual(samples.count, 24_000)
        XCTAssertGreaterThan(rms(samples[...]), 0.3, "the audio itself survived, not silence")
    }

    func testHeaderWithPlaceholderSizesIsRepaired() throws {
        // Some writers leave 0xFFFFFFFF while streaming.
        var wav = WAVFile(audio: pcm16Sine(frames: 4_000))
        wav.claimedDataSize = 0xFFFF_FFFF
        wav.claimedRIFFSize = 0xFFFF_FFFF
        let built = wav.build()
        let url = try writeFile(built.bytes, named: "placeholder.wav", in: dir)

        let seconds = Recovery.repairHeader(url)

        XCTAssertEqual(try XCTUnwrap(seconds), 0.25, accuracy: 1e-9)
        let fixed = try Data(contentsOf: url)
        XCTAssertEqual(fixed.le32(at: built.dataSizeOffset), 8_000)
        XCTAssertEqual(fixed.le32(at: 4), UInt32(fixed.count - 8))
    }

    func testHeaderClaimingMoreAudioThanTheFileHoldsIsCutBack() throws {
        // The app was killed before the last buffers reached the disk.
        var wav = WAVFile(audio: pcm16Sine(frames: 1_000))
        wav.claimedDataSize = 64_000
        let built = wav.build()
        let url = try writeFile(built.bytes, named: "short.wav", in: dir)

        let seconds = Recovery.repairHeader(url)

        XCTAssertEqual(try XCTUnwrap(seconds), 1_000.0 / 16_000, accuracy: 1e-9)
        XCTAssertEqual(try Data(contentsOf: url).le32(at: built.dataSizeOffset), 2_000)
    }

    func testRepairIsIdempotent() throws {
        let url = try writeFile(WAVFile(audio: pcm16Sine(frames: 5_000)).crashed().bytes, named: "twice.wav", in: dir)

        let first = Recovery.repairHeader(url)
        let afterFirst = try Data(contentsOf: url)
        let second = Recovery.repairHeader(url)

        XCTAssertEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: url), afterFirst)
    }

    func testAHealthyFileIsLeftByteForByteAlone() throws {
        let built = WAVFile(audio: pcm16Sine(frames: 16_000)).build()
        let url = try writeFile(built.bytes, named: "healthy.wav", in: dir)

        let seconds = Recovery.repairHeader(url)

        XCTAssertEqual(try XCTUnwrap(seconds), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try Data(contentsOf: url), built.bytes)
    }

    // MARK: Odd byte counts

    func testHalfAFrameAtTheEndIsNotCounted() throws {
        // 1001 bytes of 16-bit mono: 500 whole frames and one stray byte.
        var audio = pcm16Sine(frames: 500)
        audio.append(0x7F)
        let built = WAVFile(audio: audio).crashed()
        XCTAssertEqual(built.bytes.count, built.dataStart + 1001)
        let url = try writeFile(built.bytes, named: "odd.wav", in: dir)

        let seconds = Recovery.repairHeader(url)

        XCTAssertEqual(try XCTUnwrap(seconds), 500.0 / 16_000, accuracy: 1e-9)
        let fixed = try Data(contentsOf: url)
        XCTAssertEqual(fixed.le32(at: built.dataSizeOffset), 1000, "whole frames only")
        XCTAssertEqual(fixed.le32(at: 4), UInt32(built.dataStart + 1000 - 8))
    }

    func testStereoFramesAreRoundedDownToFourBytes() throws {
        // 16-bit stereo has 4 bytes a frame; 4003 bytes is 1000 frames and 3 stray bytes.
        var wav = WAVFile(audio: pcm16Sine(frames: 1000, channels: 2) + Data([1, 2, 3]))
        wav.channels = 2
        let built = wav.crashed()
        let url = try writeFile(built.bytes, named: "stereo.wav", in: dir)

        let seconds = Recovery.repairHeader(url)

        XCTAssertEqual(try XCTUnwrap(seconds), 1000.0 / 16_000, accuracy: 1e-9)
        XCTAssertEqual(try Data(contentsOf: url).le32(at: built.dataSizeOffset), 4000)
    }

    func testSingleByteOfAudioIsLessThanAFrame() throws {
        let built = WAVFile(audio: Data([0x55])).crashed()
        let url = try writeFile(built.bytes, named: "onebyte.wav", in: dir)

        let seconds = Recovery.repairHeader(url)

        XCTAssertEqual(try XCTUnwrap(seconds), 0)
        XCTAssertEqual(try Data(contentsOf: url).le32(at: built.dataSizeOffset), 0)
    }

    func testHeaderWithNoAudioAtAllIsZeroSeconds() throws {
        let built = WAVFile(audio: Data()).crashed()
        XCTAssertEqual(built.bytes.count, 44)
        let url = try writeFile(built.bytes, named: "empty-data.wav", in: dir)

        let seconds = Recovery.repairHeader(url)

        XCTAssertEqual(try XCTUnwrap(seconds), 0)
        let fixed = try Data(contentsOf: url)
        XCTAssertEqual(fixed.le32(at: built.dataSizeOffset), 0)
        XCTAssertEqual(fixed.le32(at: 4), 36)
    }

    // MARK: Truncated headers, zero-length files and files that are not WAVs

    func testZeroLengthFileReturnsNilAndStaysEmpty() throws {
        let url = try writeFile(Data(), named: "zero.wav", in: dir)

        XCTAssertNil(Recovery.repairHeader(url))
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(Recovery.repairHeader(dir.appending(path: "nothing-here.wav")))
    }

    func testEveryTruncationOfTheHeaderReturnsNilAndWritesNothing() throws {
        let full = WAVFile(audio: pcm16Sine(frames: 100)).crashed().bytes
        // 44 bytes is the whole header. Anything shorter has no data chunk to repair.
        for length in 0..<44 {
            let truncated = full.prefix(length)
            let url = try writeFile(Data(truncated), named: "cut-\(length).wav", in: dir)

            XCTAssertNil(Recovery.repairHeader(url), "a header cut at \(length) bytes")
            XCTAssertEqual(try Data(contentsOf: url), Data(truncated), "cut at \(length) bytes must stay as it was")
        }
    }

    func testHeaderCutRightAfterTheDataIdIsNil() throws {
        // "data" with no size field: 40 bytes.
        let full = WAVFile(audio: Data()).crashed().bytes
        let url = try writeFile(Data(full.prefix(40)), named: "no-size.wav", in: dir)

        XCTAssertNil(Recovery.repairHeader(url))
    }

    func testTwelveByteRIFFWAVEStubReturnsNil() throws {
        var stub = Data("RIFF".utf8)
        stub.appendLE32(4)
        stub.append(contentsOf: Array("WAVE".utf8))
        let url = try writeFile(stub, named: "stub.wav", in: dir)

        XCTAssertNil(Recovery.repairHeader(url))
        XCTAssertEqual(try Data(contentsOf: url), stub)
    }

    func testElevenBytesReturnsNil() throws {
        let url = try writeFile(Data("RIFF....WAV".utf8), named: "eleven.wav", in: dir)
        XCTAssertNil(Recovery.repairHeader(url))
    }

    func testRandomBytesAreNotTouched() throws {
        let junk = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let url = try writeFile(junk, named: "junk.wav", in: dir)

        XCTAssertNil(Recovery.repairHeader(url))
        XCTAssertEqual(try Data(contentsOf: url), junk)
    }

    func testRIFFThatIsNotWAVEIsRejected() throws {
        var bytes = WAVFile(audio: pcm16Sine(frames: 100)).crashed().bytes
        bytes.replaceSubrange(8..<12, with: Array("AVI ".utf8))
        let url = try writeFile(bytes, named: "avi.wav", in: dir)

        XCTAssertNil(Recovery.repairHeader(url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testAnMP3WithAWAVExtensionIsRejected() throws {
        let url = try writeFile(Data("ID3".utf8) + Data(count: 2048), named: "renamed.wav", in: dir)
        XCTAssertNil(Recovery.repairHeader(url))
    }

    func testFmtWithZeroBlockAlignOrByteRateIsRejectedWithoutDividingByZero() throws {
        var noAlign = WAVFile(audio: pcm16Sine(frames: 100))
        noAlign.blockAlign = 0
        let a = try writeFile(noAlign.crashed().bytes, named: "no-align.wav", in: dir)
        XCTAssertNil(Recovery.repairHeader(a))

        var noRate = WAVFile(audio: pcm16Sine(frames: 100))
        noRate.byteRate = 0
        let b = try writeFile(noRate.crashed().bytes, named: "no-rate.wav", in: dir)
        XCTAssertNil(Recovery.repairHeader(b))
    }

    func testDataChunkBeforeFmtIsRejected() throws {
        // Without a fmt chunk there is no frame size to round to.
        var bytes = Data("RIFF".utf8)
        bytes.appendLE32(0)
        bytes.append(contentsOf: Array("WAVE".utf8))
        bytes.append(contentsOf: Array("data".utf8))
        bytes.appendLE32(0)
        bytes.append(Data(count: 1000))
        let url = try writeFile(bytes, named: "no-fmt.wav", in: dir)

        XCTAssertNil(Recovery.repairHeader(url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    // MARK: Other layouts a real writer produces

    func testChunksBeforeTheDataAreSkipped() throws {
        var wav = WAVFile(audio: pcm16Sine(frames: 2_000))
        // An odd-sized LIST body is followed by a pad byte; a filler chunk pads to a block.
        wav.chunksBeforeData = [("LIST", Data(count: 5)), ("FLLR", Data(count: 4000))]
        let built = wav.crashed()
        let url = try writeFile(built.bytes, named: "chunks.wav", in: dir)

        let seconds = Recovery.repairHeader(url)

        XCTAssertEqual(try XCTUnwrap(seconds), 0.125, accuracy: 1e-9)
        XCTAssertEqual(try Data(contentsOf: url).le32(at: built.dataSizeOffset), 4_000)
    }

    func testExtendedFmtChunksAreRead() throws {
        for extra in [2, 24] {
            var wav = WAVFile(audio: pcm16Sine(frames: 800))
            wav.fmtExtra = extra
            let built = wav.crashed()
            let url = try writeFile(built.bytes, named: "fmt-\(extra).wav", in: dir)

            XCTAssertEqual(try XCTUnwrap(Recovery.repairHeader(url)), 0.05, accuracy: 1e-9, "fmt extra \(extra)")
        }
    }

    func testDurationUsesTheByteRateOfOtherFormats() throws {
        var wav = WAVFile(audio: Data(count: 48_000 * 4 * 2))  // 2 s of 48 kHz 16-bit stereo
        wav.sampleRate = 48_000
        wav.channels = 2
        let url = try writeFile(wav.crashed().bytes, named: "48k.wav", in: dir)

        XCTAssertEqual(try XCTUnwrap(Recovery.repairHeader(url)), 2.0, accuracy: 1e-9)
    }

    func testLongRecordingIsRepairedToTheExactSecond() throws {
        // Ten minutes: 19.2 MB.
        let built = WAVFile(audio: Data(count: 16_000 * 2 * 600)).crashed()
        let url = try writeFile(built.bytes, named: "long.wav", in: dir)

        XCTAssertEqual(try XCTUnwrap(Recovery.repairHeader(url)), 600.0, accuracy: 1e-9)
        XCTAssertEqual(try Data(contentsOf: url).le32(at: built.dataSizeOffset), 19_200_000)
    }

    // MARK: What AVAudioFile, which the recorder uses, writes

    func testAnAVAudioFileWAVSurvivesACrashedHeader() throws {
        let url = dir.appending(path: "real.wav")
        try writeAudio(to: url, sampleRate: 16_000, channels: 1, frames: 32_000,
                       sample: sine(440, rate: 16_000))
        var bytes = try Data(contentsOf: url)
        let chunk = try XCTUnwrap(findDataChunk(bytes), "AVAudioFile's WAV has a data chunk")
        // Put the header back the way a crash leaves it.
        bytes.replaceSubrange(chunk.sizeOffset..<chunk.sizeOffset + 4, with: Data(count: 4))
        bytes.replaceSubrange(4..<8, with: Data(count: 4))
        try bytes.write(to: url)

        let seconds = Recovery.repairHeader(url)

        XCTAssertEqual(try XCTUnwrap(seconds), 2.0, accuracy: 1e-9)
        XCTAssertEqual(try Audio.load(url).count, 32_000)
    }

    func testAProperlyClosedAVAudioFileIsNotChangedByRepair() throws {
        // After a crash during transcription the finished recording is an orphan too, and
        // repair runs on it.
        let url = dir.appending(path: "closed.wav")
        try writeAudio(to: url, sampleRate: 16_000, channels: 1, frames: 20_000,
                       sample: sine(300, rate: 16_000))
        let before = try Data(contentsOf: url)

        let seconds = Recovery.repairHeader(url)

        XCTAssertEqual(try XCTUnwrap(seconds), 1.25, accuracy: 1e-9)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
}

final class RecoveryFindingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeTempDir(self)
    }

    func testOrphansAreTheWAVsNoRowPointsAt() throws {
        let kept = try writeFile(Data([1]), named: "1700000000000.wav", in: dir)
        let orphan = try writeFile(Data([1]), named: "1700000001000.wav", in: dir)

        let found = Recovery.orphans(in: dir, known: [kept.path])

        XCTAssertEqual(found.map(\.lastPathComponent), [orphan.lastPathComponent])
    }

    func testOrphansAreOldestFirst() throws {
        for name in ["1700000003000.wav", "1700000001000.wav", "1700000002000.wav"] {
            try writeFile(Data([1]), named: name, in: dir)
        }

        let found = Recovery.orphans(in: dir, known: [])

        XCTAssertEqual(found.map(\.lastPathComponent),
                       ["1700000001000.wav", "1700000002000.wav", "1700000003000.wav"])
    }

    func testOrphansIgnoreOtherFilesAndMatchTheExtensionInAnyCase() throws {
        try writeFile(Data([1]), named: "notes.txt", in: dir)
        try writeFile(Data([1]), named: ".DS_Store", in: dir)
        try writeFile(Data([1]), named: "voice.sqlite", in: dir)
        try writeFile(Data([1]), named: "100.WAV", in: dir)
        try writeFile(Data([1]), named: "200.wav", in: dir)

        let found = Recovery.orphans(in: dir, known: [])

        XCTAssertEqual(found.map(\.lastPathComponent), ["100.WAV", "200.wav"])
    }

    func testOrphansOfAMissingOrEmptyFolderAreNone() {
        XCTAssertEqual(Recovery.orphans(in: dir.appending(path: "nope"), known: []), [])
        XCTAssertEqual(Recovery.orphans(in: dir, known: []), [])
    }

    func testNoOrphansWhenEveryFileIsKnown() throws {
        let a = try writeFile(Data([1]), named: "1.wav", in: dir)
        let b = try writeFile(Data([1]), named: "2.wav", in: dir)

        XCTAssertEqual(Recovery.orphans(in: dir, known: [a.path, b.path]), [])
    }

    func testRecordedAtReadsTheStartTimeFromTheName() {
        let url = dir.appending(path: "1700000123456.wav")

        XCTAssertEqual(Recovery.recordedAt(url).timeIntervalSince1970, 1_700_000_123.456, accuracy: 1e-6)
    }

    func testRecordedAtFallsBackToTheFilesCreationDate() throws {
        let url = try writeFile(Data([1]), named: "morning dictation.wav", in: dir)

        let date = Recovery.recordedAt(url)

        XCTAssertEqual(date.timeIntervalSinceNow, 0, accuracy: 60)
    }

    func testRecordedAtForAMissingUnnumberedFileIsNow() {
        let date = Recovery.recordedAt(dir.appending(path: "gone.wav"))

        XCTAssertEqual(date.timeIntervalSinceNow, 0, accuracy: 5)
    }

    func testARowThatKeepsOnlyTheAudio() {
        let audio = dir.appending(path: "1700000000000.wav")
        let created = Date(timeIntervalSince1970: 1_700_000_000)

        let row = Dictation(audio: audio, createdAt: created, duration: 0.1, mode: .plain,
                            whisperModel: "ggml-test", error: "Too short to transcribe.", origin: .recovered)

        XCTAssertEqual(row.audioPath, audio.path)
        XCTAssertEqual(row.createdAt, created)
        XCTAssertEqual(row.duration, 0.1)
        XCTAssertEqual(row.rawText, "")
        XCTAssertEqual(row.finalText, "")
        XCTAssertNil(row.cleanupModel)
        XCTAssertTrue(row.segments.isEmpty)
        XCTAssertEqual(row.error, "Too short to transcribe.")
        XCTAssertEqual(row.origin, .recovered)
        XCTAssertFalse(row.id.isEmpty)
        XCTAssertNotEqual(row.id, Dictation(audio: audio, duration: 0, mode: .plain, whisperModel: "m", error: "e").id)
    }
}

/// What the app does at launch with these pieces: find recordings no row points at, repair
/// them, and file each one in the history so the next launch doesn't find it again.
final class RecoveryLaunchFlowTests: StoreTestCase {
    func testEveryOrphanGetsARowAndNoneIsFoundAgainOnTheNextLaunch() throws {
        let recordings = dir.appending(path: "recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)

        let finished = try writeFile(WAVFile(audio: pcm16Sine(frames: 16_000)).build().bytes, named: "1700000000000.wav", in: recordings)
        try store.insert(try dictation("finished", audio: finished))
        let crashed = try writeFile(WAVFile(audio: pcm16Sine(frames: 32_000)).crashed().bytes, named: "1700000100000.wav", in: recordings)
        let blip = try writeFile(WAVFile(audio: pcm16Sine(frames: 1_600)).crashed().bytes, named: "1700000200000.wav", in: recordings)
        let junkBytes = Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let junk = try writeFile(junkBytes, named: "1700000300000.wav", in: recordings)
        try writeFile(Data("hello".utf8), named: "notes.txt", in: recordings)

        let orphans = Recovery.orphans(in: recordings, known: store.audioPaths())
        XCTAssertEqual(orphans.map(\.lastPathComponent), ["1700000100000.wav", "1700000200000.wav", "1700000300000.wav"])

        for url in orphans {
            let duration = Recovery.repairHeader(url) ?? 0
            let reason = duration >= Dictation.tooShort ? "Couldn't transcribe." : "Too short to transcribe."
            try store.insert(Dictation(audio: url, createdAt: Recovery.recordedAt(url), duration: duration, mode: .plain,
                                       whisperModel: "m", error: reason, origin: .recovered))
        }

        // Next launch: every file has a row.
        XCTAssertEqual(Recovery.orphans(in: recordings, known: store.audioPaths()), [])
        XCTAssertEqual(count("SELECT count(*) FROM dictations"), 4)
        // Only the recovered recording long enough to transcribe is offered for a retry.
        let listed = store.recent(10)
        XCTAssertEqual(listed.map(\.audioPath), [finished.path, crashed.path])
        let recovered = try XCTUnwrap(listed.last)
        XCTAssertEqual(recovered.origin, .recovered)
        XCTAssertEqual(recovered.duration, 2.0, accuracy: 1e-9)
        XCTAssertEqual(recovered.createdAt.timeIntervalSince1970, 1_700_000_100, accuracy: 1e-3)
        // The recovered file is now readable, the others are as they were.
        XCTAssertEqual(try Audio.load(crashed).count, 32_000)
        XCTAssertEqual(try Data(contentsOf: junk), junkBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blip.path))
        XCTAssertEqual(store.audioPaths().count, 4)
    }
}

final class DictationCodingTests: XCTestCase {
    func testADictationSurvivesJSON() throws {
        let segment = Segment(t0: 0, t1: 1.5, text: "hi", avgLogprob: -0.3, noSpeechProb: 0.02, compressionRatio: 1.1,
                              speechSeconds: 1.2, wordsPerSecond: 1.6)
        let original = Dictation(
            id: "x", createdAt: Date(timeIntervalSince1970: 1_700_000_000), audioPath: "/a/b.wav", duration: 2.5,
            mode: .cleanup, whisperModel: "ggml-test", rawText: "raw", finalText: "final", cleanupModel: "qwen",
            cleanupSystem: "sys", timings: .init(record: 1, load: 2, transcribe: 3, cleanup: 4, paste: 5),
            segments: [segment], error: "oops", origin: .recovered)

        let decoded = try JSONDecoder().decode(Dictation.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded.id, "x")
        XCTAssertEqual(decoded.mode, .cleanup)
        XCTAssertEqual(decoded.finalText, "final")
        XCTAssertEqual(decoded.origin, .recovered)
        XCTAssertEqual(decoded.segments, [segment])
        XCTAssertEqual(decoded.timings.paste, 5)
        XCTAssertEqual(decoded.error, "oops")
    }

    func testJSONWrittenBeforeOriginExistedStillDecodes() throws {
        let json = """
            {"id":"old","createdAt":700000000,"audioPath":"/a.wav","duration":1,"mode":"plain","whisperModel":"m",
             "rawText":"r","finalText":"f","timings":{},"segments":[]}
            """

        let decoded = try JSONDecoder().decode(Dictation.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.id, "old")
        XCTAssertNil(decoded.origin)
        XCTAssertNil(decoded.error)
        XCTAssertNil(decoded.cleanupModel)
    }
}
