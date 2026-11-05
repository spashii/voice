import AVFoundation
import Foundation
import SQLite3
import XCTest
@testable import VoiceCore

// Shared helpers. Everything here writes under a temporary folder that the test removes
// afterwards: no test touches ~/Library/Application Support/Voice.

/// A new empty folder under the system temp directory, removed when the test finishes.
func makeTempDir(_ test: XCTestCase) throws -> URL {
    // The real path: /var is a link to /private/var, and FileManager lists files under the
    // real one, so a path built from the link would not compare equal to what it lists.
    let base = realPath(FileManager.default.temporaryDirectory)
    let dir = base.appending(path: "VoiceCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
}

extension Data {
    mutating func appendLE32(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendLE16(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func le32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * UInt32($1)) }
    }

    func le16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }
}

/// A hand-built RIFF/WAVE file, so a test can say exactly what the header claims and what
/// the file actually holds. The defaults are Voice's own recording format: 16 kHz, mono,
/// 16-bit PCM.
struct WAVFile {
    var channels: UInt16 = 1
    var sampleRate: UInt32 = 16_000
    var bitsPerSample: UInt16 = 16
    /// Overrides for headers that lie or are damaged.
    var byteRate: UInt32?
    var blockAlign: UInt16?
    /// Extra bytes after the 16 byte fmt body (an 18 byte fmt has 2, an extensible one 24).
    var fmtExtra = 0
    /// Chunks between fmt and data, as (id, body). Odd-sized bodies get a pad byte.
    var chunksBeforeData: [(String, Data)] = []
    /// Chunks after the data chunk, as written by tools that tag a finished file.
    var chunksAfterData: [(String, Data)] = []
    /// The audio bytes actually in the file.
    var audio = Data()
    /// What the header claims, when it should not match the audio. Nil means the truth.
    var claimedDataSize: UInt32?
    var claimedRIFFSize: UInt32?

    struct Built {
        var bytes: Data
        /// Where the data chunk's size field and its first audio byte sit.
        var dataSizeOffset: Int
        var dataStart: Int
    }

    var bytesPerFrame: Int { Int(channels) * Int(bitsPerSample) / 8 }

    func build() -> Built {
        var out = Data()
        func chunk(_ id: String, _ body: Data) {
            out.append(contentsOf: Array(id.utf8))
            out.appendLE32(UInt32(body.count))
            out.append(body)
            if body.count & 1 == 1 { out.append(0) }
        }
        out.append(contentsOf: Array("RIFF".utf8))
        out.appendLE32(0)  // patched below
        out.append(contentsOf: Array("WAVE".utf8))

        var fmt = Data()
        fmt.appendLE16(1)
        fmt.appendLE16(channels)
        fmt.appendLE32(sampleRate)
        fmt.appendLE32(byteRate ?? sampleRate * UInt32(bytesPerFrame))
        fmt.appendLE16(blockAlign ?? UInt16(bytesPerFrame))
        fmt.appendLE16(bitsPerSample)
        fmt.append(Data(count: fmtExtra))
        chunk("fmt ", fmt)

        for (id, body) in chunksBeforeData { chunk(id, body) }

        out.append(contentsOf: Array("data".utf8))
        let dataSizeOffset = out.count
        out.appendLE32(claimedDataSize ?? UInt32(audio.count))
        let dataStart = out.count
        out.append(audio)
        if audio.count & 1 == 1 && !chunksAfterData.isEmpty { out.append(0) }
        for (id, body) in chunksAfterData { chunk(id, body) }

        let riff = claimedRIFFSize ?? UInt32(out.count - 8)
        var patched = Data()
        patched.appendLE32(riff)
        out.replaceSubrange(4..<8, with: patched)
        return Built(bytes: out, dataSizeOffset: dataSizeOffset, dataStart: dataStart)
    }

    /// The file a crash leaves behind: all the audio, and a header that still says empty.
    func crashed() -> Built {
        var copy = self
        copy.claimedDataSize = 0
        copy.claimedRIFFSize = 36
        return copy.build()
    }
}

/// 16-bit little-endian PCM of a sine wave.
func pcm16Sine(frames: Int, frequency: Double = 440, rate: Double = 16_000, amplitude: Double = 0.5,
               channels: Int = 1) -> Data {
    var data = Data()
    for i in 0..<frames {
        let value = Int16((sin(2 * .pi * frequency * Double(i) / rate) * amplitude * 32767).rounded())
        for _ in 0..<channels { data.appendLE16(UInt16(bitPattern: value)) }
    }
    return data
}

@discardableResult
func writeFile(_ data: Data, named name: String, in dir: URL) throws -> URL {
    let url = dir.appending(path: name)
    try data.write(to: url)
    return url
}

/// Writes a real audio file through AVAudioFile, in the same way the recorder does.
/// `sample(channel, frame)` gives each value in -1...1.
func writeAudio(to url: URL, sampleRate: Double, channels: Int, frames: Int,
                bitDepth: Int = 16, isFloat: Bool = false,
                sample: (Int, Int) -> Float) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: bitDepth,
        AVLinearPCMIsFloatKey: isFloat,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let chunk = 4096
    var written = 0
    while written < frames {
        let count = min(chunk, frames - written)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<channels {
            let pointer = buffer.floatChannelData![channel]
            for i in 0..<count { pointer[i] = sample(channel, written + i) }
        }
        try file.write(from: buffer)
        written += count
    }
}

func sine(_ frequency: Double, rate: Double, amplitude: Double = 0.5) -> (Int, Int) -> Float {
    { _, i in Float(sin(2 * .pi * frequency * Double(i) / rate) * amplitude) }
}

func rms(_ samples: ArraySlice<Float>) -> Double {
    guard !samples.isEmpty else { return 0 }
    return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
}

/// Upward zero crossings per second, a plain way to read a sine's frequency.
func frequency(of samples: ArraySlice<Float>, rate: Double) -> Double {
    var crossings = 0
    var previous: Float?
    for s in samples {
        if let p = previous, p < 0, s >= 0 { crossings += 1 }
        previous = s
    }
    return Double(crossings) / (Double(samples.count) / rate)
}

/// Reads SQLite directly, to check what the store left in its tables.
func scalarInt(_ database: URL, _ sql: String) -> Int {
    var db: OpaquePointer?
    guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : -1
}

/// Finds the data chunk by walking the chunks from the start, as a WAV reader does.
func findDataChunk(_ file: Data) -> (sizeOffset: Int, start: Int)? {
    var offset = 12
    while offset + 8 <= file.count {
        let id = String(decoding: file[file.startIndex + offset..<file.startIndex + offset + 4], as: UTF8.self)
        let size = Int(file.le32(at: offset + 4))
        if id == "data" { return (offset + 4, offset + 8) }
        offset += 8 + size + (size & 1)
    }
    return nil
}

func realPath(_ url: URL) -> URL {
    guard let resolved = realpath(url.path, nil) else { return url }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

/// The history is the one place a transcription outlives the clipboard, so a row has to
/// come back exactly as it went in.
class StoreTestCase: XCTestCase {
    var dir: URL!
    var databaseURL: URL!
    var store: Store!

    override func setUpWithError() throws {
        dir = try makeTempDir(self)
        databaseURL = dir.appending(path: "voice.sqlite")
        store = try Store(url: databaseURL)
    }

    func segment(_ text: String = "hello", t0: Double = 0, t1: Double = 1) -> Segment {
        Segment(t0: t0, t1: t1, text: text, avgLogprob: -0.25, noSpeechProb: 0.01, compressionRatio: 1.2,
                speechSeconds: 0.9, wordsPerSecond: 2.5)
    }

    /// A finished dictation whose audio file really exists in the temp folder.
    func dictation(_ id: String = UUID().uuidString, ageDays: Double = 0, duration: Double = 3,
                   mode: Dictation.Mode = .plain, text: String = "hello world", error: String? = nil,
                   segments: [Segment]? = nil, audio: URL? = nil, makeAudio: Bool = true) throws -> Dictation {
        let url = audio ?? dir.appending(path: "\(id).wav")
        if makeAudio, !FileManager.default.fileExists(atPath: url.path) { try Data([1, 2, 3]).write(to: url) }
        return Dictation(
            id: id, createdAt: Date().addingTimeInterval(-ageDays * 24 * 3600), audioPath: url.path,
            duration: duration, mode: mode, whisperModel: "ggml-test", rawText: text, finalText: text,
            cleanupModel: mode == .cleanup ? "qwen" : nil, cleanupSystem: mode == .cleanup ? "system" : nil,
            timings: .init(record: 3000, load: 10, transcribe: 400, cleanup: nil, paste: nil),
            segments: segments ?? [segment()], error: error)
    }

    func count(_ sql: String) -> Int { scalarInt(databaseURL, sql) }

    func exists(_ id: String) -> Bool { FileManager.default.fileExists(atPath: dir.appending(path: "\(id).wav").path) }
}
