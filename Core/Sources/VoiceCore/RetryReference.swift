import AVFoundation
import Foundation
import IOKit
import IOKit.ps

/// The text retries are scored against, without hand labels: each recording that has retry
/// records is decoded again, slowly and at best settings, while the Mac is idle. A
/// dictation is decoded whole; a call side in stretches of up to half a minute, so a
/// recording that starts cuts short only the stretch in progress. Everything stays in
/// voice.sqlite, and `voice-cli retry-report` scores it.
public final class RetryReferences: @unchecked Sendable {
    /// One thing to decode: a dictation, or a stretch of one side of a call.
    public struct Unit: Sendable, Equatable {
        /// "dictation", or the call side: "me", "call" or "mix".
        public var source: String
        public var dictationID: String?
        public var callID: String?
        public var audioPath: String
        /// The file's channel to read, or nil for all of them together.
        public var channel: Int?
        /// Seconds on the recording's timeline.
        public var t0: Double
        public var t1: Double
    }

    /// A call side's stretches end at a pause this long, or before they pass maxSeconds.
    static let spanGap = 2.0
    static let spanMaxSeconds = 28.0
    /// Audio kept around a stretch's first and last segment, as the call chunker keeps.
    static let spanPadding = 0.3

    private let db: SQLiteConnection
    private let queue = DispatchQueue(label: "voice.references")

    public init(url: URL) throws {
        // Store runs the migrations, so the tables exist before the first query.
        _ = try Store(url: url)
        db = try SQLiteConnection(url: url)
    }

    /// Best settings for a reference: beam 5 with whisper.cpp's standard temperature
    /// fallback, whisper reading its own previous window as OpenAI's decoder does, the key
    /// terms as the prompt, and voice activity detection that only drops silences of two
    /// seconds or more, where whisper would otherwise make up text.
    public static func options(language: String, keyTerms: [String]) -> WhisperOptions {
        var options = WhisperOptions()
        options.language = language
        options.keyTerms = keyTerms
        options.beamSize = 5
        options.conditionOnPrevious = true
        options.vadMinSilenceMs = 2000
        options.vadPaddingMs = 500
        return options
    }

    /// The next thing to decode: dictations newest first, then calls. Only recordings with
    /// retry records count, since only those can be scored.
    public func next() throws -> Unit? {
        try queue.sync {
            if let dictation = try db.query("""
                SELECT d.id, d.audio_path, d.duration FROM dictations d
                WHERE EXISTS (SELECT 1 FROM segment_retries r WHERE r.dictation_id = d.id)
                  AND NOT EXISTS (SELECT 1 FROM retry_references x WHERE x.dictation_id = d.id)
                ORDER BY d.created_at DESC LIMIT 1
                """, [], { row in
                Unit(source: "dictation", dictationID: row.text(0), audioPath: row.text(1), channel: nil,
                     t0: 0, t1: row.double(2))
            }).first {
                return dictation
            }
            let calls = try db.query("""
                SELECT DISTINCT c.id, c.audio_path FROM calls c JOIN segment_retries r ON r.call_id = c.id
                WHERE c.status = 'done' AND c.audio_path IS NOT NULL ORDER BY c.started_at DESC
                """) { ($0.text(0), $0.text(1)) }
            for (callID, path) in calls {
                let done = try db.query("SELECT source, t0 FROM retry_references WHERE call_id = ?", [callID]) {
                    "\($0.text(0)) \(Int(($0.double(1) * 1000).rounded()))"
                }
                let segments = try db.query("""
                    SELECT source, t0, t1 FROM segment_retries WHERE call_id = ? ORDER BY source, t0
                    """, [callID]) { (source: $0.text(0), t0: $0.double(1), t1: $0.double(2)) }
                for source in ["me", "call", "mix"] {
                    let side = segments.filter { $0.source == source }.map { (t0: $0.t0, t1: $0.t1) }
                    for span in Self.spans(side) where !done.contains("\(source) \(Int((span.t0 * 1000).rounded()))") {
                        return Unit(source: source, callID: callID, audioPath: path,
                                    channel: source == "mix" ? nil : (source == "me" ? 0 : 1), t0: span.t0, t1: span.t1)
                    }
                }
            }
            return nil
        }
    }

    /// Groups one side's segments into stretches: a new one starts after a pause of
    /// spanGap, or where adding the segment would pass spanMaxSeconds. Each keeps
    /// spanPadding of audio on both sides.
    static func spans(_ segments: [(t0: Double, t1: Double)]) -> [(t0: Double, t1: Double)] {
        var spans: [(t0: Double, t1: Double)] = []
        for segment in segments.sorted(by: { $0.t0 < $1.t0 }) {
            if let last = spans.last, segment.t0 - last.t1 < spanGap, segment.t1 - last.t0 <= spanMaxSeconds {
                spans[spans.count - 1].t1 = max(last.t1, segment.t1)
            } else {
                spans.append(segment)
            }
        }
        return spans.map { (max(0, $0.t0 - spanPadding), $0.t1 + spanPadding) }
    }

    /// A reference with no text records why, so the unit isn't tried again forever.
    public func save(_ unit: Unit, model: String, text: String?, error: String? = nil, seconds: Double) throws {
        _ = try queue.sync {
            try db.run("""
                INSERT INTO retry_references (source, dictation_id, call_id, t0, t1, model, text, error, seconds,
                  created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """, [unit.source, unit.dictationID, unit.callID, unit.t0, unit.t1, model, text, error, seconds, Date()])
        }
    }

    /// Decodes the next unit and stores its reference. Returns false when nothing is left.
    /// A stop cuts the decode short and stores nothing, so the unit comes up again.
    @discardableResult
    public func runNext(transcriber: Transcriber, options: WhisperOptions, stop: DecodeStop) async throws -> Bool {
        guard let unit = try next() else { return false }
        let samples: [Float]
        do {
            samples = try Self.samples(URL(fileURLWithPath: unit.audioPath), channel: unit.channel,
                                       from: unit.t0, to: unit.t1)
        } catch {
            try save(unit, model: transcriber.modelName, text: nil, error: "Can't read the audio: \(error)", seconds: 0)
            return true
        }
        guard samples.count >= Int(Audio.sampleRate * Dictation.tooShort) else {
            try save(unit, model: transcriber.modelName, text: nil, error: "Too short", seconds: 0)
            return true
        }
        let transcript = try await transcriber.transcribeInBackground(samples, options: options, stop: stop)
        try save(unit, model: transcriber.modelName, text: transcript.text, seconds: transcript.seconds)
        return true
    }

    /// 16 kHz mono samples of one channel (or all, averaged) between two times.
    static func samples(_ url: URL, channel: Int?, from: Double, to: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        let start = AVAudioFramePosition(max(0, from) * rate)
        let end = min(file.length, AVAudioFramePosition(to * rate))
        guard end > start else { return [] }
        file.framePosition = start
        let count = AVAudioFrameCount(end - start)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let mono = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!,
                                          frameCapacity: count) else {
            throw VoiceError.audio("Couldn't read \(url.lastPathComponent).")
        }
        try file.read(into: buffer, frameCount: count)
        let frames = Int(buffer.frameLength)
        mono.frameLength = buffer.frameLength
        let input = buffer.floatChannelData!
        let target = mono.floatChannelData![0]
        let channels = Int(format.channelCount)
        if let channel, channel < channels {
            target.update(from: input[channel], count: frames)
        } else {
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += input[c][f] }
                target[f] = sum / Float(channels)
            }
        }
        if rate == Audio.sampleRate { return Array(UnsafeBufferPointer(start: target, count: frames)) }
        guard let converter = AVAudioConverter(from: mono.format, to: Audio.format),
              let output = AVAudioPCMBuffer(pcmFormat: Audio.format,
                                            frameCapacity: AVAudioFrameCount(Double(frames) * Audio.sampleRate / rate) + 4096)
        else { throw VoiceError.audio("Can't convert \(url.lastPathComponent) to 16 kHz.") }
        let feed = OneShot(mono)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in feed.next(status) }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

/// When the reference pass may run: nothing recording, nobody at the Mac for ten minutes, on
/// mains power, memory to spare and Ollama holding no model, so a slow decode at best
/// settings takes nothing anyone would notice. The pass checks this between decodes, and a
/// watcher stops a decode in progress once it stops holding.
public struct IdleState: Sendable, Equatable {
    public var recording: Bool
    public var userIdleSeconds: Double
    public var onACPower: Bool
    public var memoryPressure: Bool
    public var ollamaLoaded: Bool

    public static let userIdleNeeded = 600.0

    public init(recording: Bool, userIdleSeconds: Double, onACPower: Bool, memoryPressure: Bool,
                ollamaLoaded: Bool) {
        self.recording = recording
        self.userIdleSeconds = userIdleSeconds
        self.onACPower = onACPower
        self.memoryPressure = memoryPressure
        self.ollamaLoaded = ollamaLoaded
    }

    public var allowsReference: Bool {
        !recording && userIdleSeconds >= Self.userIdleNeeded && onACPower && !memoryPressure && !ollamaLoaded
    }

    /// Seconds since the last keyboard, mouse or trackpad event, from IOHIDSystem.
    public static func userIdleSeconds() -> Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return ((value as? NSNumber)?.doubleValue ?? 0) / 1e9
    }

    public static func onACPowerNow() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSACPowerValue
    }

    /// The kernel's pressure level: 1 is normal, 2 a warning, 4 critical.
    public static func memoryPressureNow() -> Bool {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return false }
        return level > 1
    }

    /// Whether Ollama has a model in memory. Not running counts as no.
    public static func ollamaLoadedNow(_ base: URL) async -> Bool {
        var request = URLRequest(url: base.appending(path: "api/ps"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return !((reply["models"] as? [Any]) ?? []).isEmpty
    }
}
