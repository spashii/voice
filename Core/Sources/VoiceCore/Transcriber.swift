import Compression
import Foundation
import whisper

/// One stretch of text from whisper, with the signals the smart-retries checker will judge
/// it by. Times are seconds on the recording's own timeline.
public struct Segment: Sendable, Codable, Equatable {
    public var t0: Double
    public var t1: Double
    public var text: String
    /// Mean log probability of the text tokens; low means whisper was guessing.
    public var avgLogprob: Double
    /// Whisper's own estimate that the window held no speech.
    public var noSpeechProb: Double
    /// Text length over its zlib-compressed length; high means repeated text.
    public var compressionRatio: Double
    /// Seconds of the segment that the voice activity detector marked as speech.
    public var speechSeconds: Double
    public var wordsPerSecond: Double
    /// Set when the segment was decoded again and the second text kept: the first text.
    public var replaced: String?
    /// What the retry pass made of this segment; nil when it didn't look at it.
    public var retry: SegmentRetry.Record?
}

public struct Transcript: Sendable {
    public var text: String
    public var segments: [Segment]
    /// All of it, retries included.
    public var seconds: Double
    /// The segments decoded again, and the seconds that took (part of `seconds`).
    public var retried = 0
    public var retrySeconds = 0.0
    /// When each second decode ran, so a dictation can count the part after its stop.
    public var retrySpans: [Range<ContinuousClock.Instant>] = []
    /// Retry seconds spent after the recording stopped: what retries added before the paste.
    public var retryAfterStop = 0.0
}

public struct WhisperOptions: Sendable, Codable {
    public var language = "en"
    /// Names and words to spell as given. They open whisper's prompt, which steers it toward
    /// those spellings.
    public var keyTerms: [String] = []
    /// Text that came just before this audio, such as the previous segment; whisper reads it
    /// as context, after the key terms.
    public var initialPrompt = ""
    /// Drop silence before decoding, so whisper can't invent text for it.
    public var vad = true
    /// 0 decodes greedily, which is whisper's default and the fastest.
    public var beamSize = 0
    /// whisper.cpp's temperature fallback: a 30 s window whose text repeats itself (entropy
    /// below entropyThreshold) or that whisper is unsure of (mean log probability below
    /// logprobThreshold) is decoded again this much hotter, up to 1. 0 turns it off. These
    /// are whisper.cpp's own defaults, set here so they're a decision rather than an accident.
    public var temperatureIncrement: Float = 0.2
    public var entropyThreshold: Float = 2.4
    public var logprobThreshold: Float = -1.0
    /// A window whisper thinks is silence (above this) and is unsure of is left empty.
    public var noSpeechThreshold: Float = 0.6
    public var retry = SegmentRetry()

    public init() {}

    /// What whisper reads before the audio: the key terms, then the text before.
    var prompt: String {
        let terms = keyTerms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let glossary = terms.isEmpty ? "" : terms.joined(separator: ", ") + "."
        return [glossary, initialPrompt].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Our own second look at the segments whisper was least sure of: each is cut out with a
/// little padding and decoded again with beam search and the segment before it as context,
/// and the version whisper is surer of is kept. Worst first, until the budget is spent.
public struct SegmentRetry: Sendable, Codable {
    /// On in the app, behind the "Retry unsure segments" switch. Off here so voice-cli's
    /// batch measures the first pass unless told otherwise.
    public var enabled = false
    /// Segments whose mean token log probability is below this are candidates. Of the
    /// checker's signals it is the one that finds bad segments (AUC 0.80 on open test sets);
    /// compression ratio and words per second barely do.
    public var logprobBelow = -0.6
    /// Retry time allowed, as a share of the first decode's. On VoxPopuli a retry of every
    /// flagged segment cost 12.7 times the first decode; within half of it a second decode
    /// still caught about 7.5% of the errors.
    public var budget = 0.5
    public var beamSize = 5
    /// Seconds of audio kept on each side of the segment.
    public var padding = 0.5

    public init() {}

    /// Why a flagged segment wasn't decoded again, stored as its raw value.
    public enum Skip: String, Sendable, Codable, Equatable {
        /// The "Retry unsure segments" switch was off.
        case off
        /// The retries before it had spent the budget.
        case budget
        /// Its times fell outside the audio, so there was nothing to decode.
        case noAudio = "no-audio"
    }

    /// What the retry pass did with one segment, kept per segment so retries can be measured
    /// on real use: the first text, whether it was flagged, and the second decode if it ran.
    public struct Record: Sendable, Codable, Equatable {
        public var firstText: String
        public var firstLogprob: Double
        public var flagged: Bool
        /// The second decode's text and mean log probability; nil when it didn't run.
        public var retriedText: String?
        public var retriedLogprob: Double?
        public var seconds = 0.0
        /// The second text replaced the first.
        public var kept = false
        /// The kept text differs from the first once case and punctuation are set aside.
        public var changed = false
        /// Set on a flagged segment the second decode never reached.
        public var skipped: Skip?

        public init(firstText: String, firstLogprob: Double, flagged: Bool, retriedText: String? = nil,
                    retriedLogprob: Double? = nil, seconds: Double = 0, kept: Bool = false, changed: Bool = false,
                    skipped: Skip? = nil) {
            self.firstText = firstText
            self.firstLogprob = firstLogprob
            self.flagged = flagged
            self.retriedText = retriedText
            self.retriedLogprob = retriedLogprob
            self.seconds = seconds
            self.kept = kept
            self.changed = changed
            self.skipped = skipped
        }
    }

    /// The flagged segments' indices, worst first.
    func candidates(_ segments: [Segment]) -> [Int] {
        segments.indices
            .filter { !segments[$0].text.isEmpty && segments[$0].avgLogprob < logprobBelow }
            .sorted { segments[$0].avgLogprob < segments[$1].avgLogprob }
    }

    /// Records every non-empty segment and, when on, decodes the flagged ones again, worst
    /// first, while the retry time stays under the budget. A retry that starts under it runs
    /// to the end, so the last can go over. A flagged segment left alone records why, so the
    /// share retried can be told apart from the share the budget or the switch held back.
    /// `decode` is whisper in the app and a stand-in in the tests.
    func run(_ first: Transcript, samples: [Float], options: WhisperOptions,
             decode: ([Float], WhisperOptions) throws -> Transcript) throws -> Transcript {
        var transcript = first
        for i in transcript.segments.indices where !transcript.segments[i].text.isEmpty {
            let segment = transcript.segments[i]
            let flagged = segment.avgLogprob < logprobBelow
            transcript.segments[i].retry = Record(firstText: segment.text, firstLogprob: segment.avgLogprob,
                                                  flagged: flagged, skipped: flagged && !enabled ? .off : nil)
        }
        guard enabled else { return transcript }
        let allowed = first.seconds * budget
        for i in candidates(first.segments) {
            guard transcript.retrySeconds < allowed else {
                transcript.segments[i].retry?.skipped = .budget
                continue
            }
            let segment = transcript.segments[i]
            let from = max(0, Int((segment.t0 - padding) * Audio.sampleRate))
            let to = min(samples.count, Int((segment.t1 + padding) * Audio.sampleRate))
            guard to > from else {
                transcript.segments[i].retry?.skipped = .noAudio
                continue
            }
            var again = options
            again.beamSize = beamSize
            again.vad = false
            again.initialPrompt = i > 0 ? transcript.segments[i - 1].text : options.initialPrompt
            let started = ContinuousClock.now
            let second = try decode(Array(samples[from..<to]), again)
            transcript.retrySpans.append(started..<ContinuousClock.now)
            transcript.retried += 1
            transcript.retrySeconds += second.seconds
            let text = second.segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            let characters = second.segments.reduce(0.0) { $0 + Double($1.text.count) }
            let logprob = characters > 0
                ? second.segments.reduce(0.0) { $0 + $1.avgLogprob * Double($1.text.count) } / characters
                : -Double.infinity
            var record = segment.retry!
            record.retriedText = text
            record.retriedLogprob = characters > 0 ? logprob : nil
            record.seconds = second.seconds
            if !text.isEmpty && logprob > segment.avgLogprob {
                var kept = segment
                kept.replaced = segment.text
                kept.text = text
                kept.avgLogprob = logprob
                kept.compressionRatio = Transcriber.compressionRatio(text)
                let words = text.split(whereSeparator: \.isWhitespace).count
                kept.wordsPerSecond = kept.speechSeconds > 0.05 ? Double(words) / kept.speechSeconds : 0
                record.kept = true
                record.changed = !WordDiff(segment.text, text).isEmpty
                kept.retry = record
                transcript.segments[i] = kept
            } else {
                transcript.segments[i].retry = record
            }
        }
        transcript.seconds += transcript.retrySeconds
        transcript.text = transcript.segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        return transcript
    }

    /// Seconds of retrying that fell after `stop`: what retries added to the wait for a
    /// dictation's paste. Spans before the stop overlapped the speaking and cost nothing.
    public static func seconds(after stop: ContinuousClock.Instant, of spans: [Range<ContinuousClock.Instant>]) -> Double {
        spans.reduce(0) { total, span in
            guard span.upperBound > stop else { return total }
            return total + (span.upperBound - max(span.lowerBound, stop)).seconds
        }
    }
}

/// Runs whisper.cpp on the GPU. One decode at a time across every model, on one queue all
/// transcribers share: a context can't run two, and two models decoding at once (the old
/// one finishing while Settings switches) would contend for the same GPU.
public final class Transcriber: @unchecked Sendable {
    public let modelURL: URL
    public let vadModelURL: URL?
    private static let queue = DispatchQueue(label: "voice.whisper", qos: .userInitiated)
    private var queue: DispatchQueue { Self.queue }
    private var context: OpaquePointer?

    public init(modelURL: URL, vadModelURL: URL?) {
        self.modelURL = modelURL
        self.vadModelURL = vadModelURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        Self.silenceLogs()
    }

    deinit {
        if let context { whisper_free(context) }
    }

    public var modelName: String { modelURL.deletingPathExtension().lastPathComponent }

    /// Loads the model if it isn't yet; returns the seconds that took (0 when loaded).
    @discardableResult
    public func load() async throws -> Double {
        try await onQueue { try self.loadOnQueue() }
    }

    /// Frees the model and its GPU memory; the next transcription loads it again, which
    /// takes about 0.4 s once the file is in the page cache. A process must also call this
    /// before it exits: ggml's Metal device asserts at exit while a model still holds it.
    public func unload() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                if let context = self.context { whisper_free(context) }
                self.context = nil
                done.resume()
            }
        }
    }

    public func transcribe(_ samples: [Float], options: WhisperOptions = WhisperOptions()) async throws -> Transcript {
        try await onQueue {
            _ = try self.loadOnQueue()
            let first = try self.decode(samples, options)
            return try options.retry.run(first, samples: samples, options: options) { try self.decode($0, $1) }
        }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { done in
            queue.async { done.resume(with: Result { try work() }) }
        }
    }

    private func loadOnQueue() throws -> Double {
        if context != nil { return 0 }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw VoiceError.whisper("The whisper model isn't at \(modelURL.path).")
        }
        let start = ContinuousClock.now
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let context = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw VoiceError.whisper("Whisper couldn't load \(modelURL.lastPathComponent).")
        }
        self.context = context
        return (ContinuousClock.now - start).seconds
    }

    private func decode(_ samples: [Float], _ options: WhisperOptions) throws -> Transcript {
        guard let context else { throw VoiceError.whisper("No model loaded.") }
        let start = ContinuousClock.now
        // Whisper needs at least a second; shorter recordings are padded with silence.
        var samples = samples
        if samples.count < Int(Audio.sampleRate) {
            samples += [Float](repeating: 0, count: Int(Audio.sampleRate) - samples.count)
        }
        var params = whisper_full_default_params(options.beamSize > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(min(8, max(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        // Each recording stands alone, so a mistake in one can't steer the next.
        params.no_context = true
        params.suppress_nst = true
        params.temperature = 0
        params.temperature_inc = options.temperatureIncrement
        params.entropy_thold = options.entropyThreshold
        params.logprob_thold = options.logprobThreshold
        params.no_speech_thold = options.noSpeechThreshold
        if options.beamSize > 1 { params.beam_search.beam_size = Int32(options.beamSize) }

        let language: UnsafeMutablePointer<CChar>? = strdup(options.language)
        let promptText = options.prompt
        let prompt: UnsafeMutablePointer<CChar>? = promptText.isEmpty ? nil : strdup(promptText)
        let vadPath: UnsafeMutablePointer<CChar>? = options.vad ? vadModelURL.flatMap { strdup($0.path) } : nil
        defer {
            free(language)
            free(prompt)
            free(vadPath)
        }
        params.language = UnsafePointer(language)
        params.initial_prompt = UnsafePointer(prompt)
        if let vadPath {
            params.vad = true
            params.vad_model_path = UnsafePointer(vadPath)
        }

        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        guard status == 0 else { throw VoiceError.whisper("Whisper failed (\(status)).") }

        var speech: [(Double, Double)] = []
        for i in 0..<whisper_full_n_vad_segments(context) {
            speech.append((Double(whisper_full_get_vad_segment_t0(context, i)) / 100,
                           Double(whisper_full_get_vad_segment_t1(context, i)) / 100))
        }
        let eot = whisper_token_eot(context)
        var segments: [Segment] = []
        for i in 0..<whisper_full_n_segments(context) {
            let text = String(cString: whisper_full_get_segment_text(context, i))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let t0 = Double(whisper_full_get_segment_t0(context, i)) / 100
            let t1 = Double(whisper_full_get_segment_t1(context, i)) / 100
            var logprobs: [Double] = []
            for j in 0..<whisper_full_n_tokens(context, i) {
                let token = whisper_full_get_token_data(context, i, j)
                if token.id < eot { logprobs.append(Double(token.plog)) }
            }
            let speechSeconds = speech.isEmpty
                ? max(t1 - t0, 0)
                : speech.reduce(0) { $0 + max(0, min(t1, $1.1) - max(t0, $1.0)) }
            let words = text.split(whereSeparator: \.isWhitespace).count
            segments.append(Segment(
                t0: t0, t1: t1, text: text,
                avgLogprob: logprobs.isEmpty ? 0 : logprobs.reduce(0, +) / Double(logprobs.count),
                noSpeechProb: Double(whisper_full_get_segment_no_speech_prob(context, i)),
                compressionRatio: Self.compressionRatio(text),
                speechSeconds: speechSeconds,
                wordsPerSecond: speechSeconds > 0.05 ? Double(words) / speechSeconds : 0,
                replaced: nil))
        }
        let text = segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        return Transcript(text: text, segments: segments, seconds: (ContinuousClock.now - start).seconds)
    }

    /// The ratio OpenAI's whisper flags above 2.4: bytes of text over bytes of
    /// zlib.compress(text). Apple's encoder writes raw deflate, so zlib's 6 bytes of header
    /// and checksum are added back.
    static func compressionRatio(_ text: String) -> Double {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return 0 }
        var output = [UInt8](repeating: 0, count: bytes.count + 64)
        let size = compression_encode_buffer(&output, output.count, bytes, bytes.count, nil, COMPRESSION_ZLIB)
        guard size > 0 else { return 0 }
        return Double(bytes.count) / Double(size + 6)
    }

    /// whisper.cpp and ggml log every step to stderr; VOICE_WHISPER_LOG=1 keeps them.
    private static func silenceLogs() {
        guard ProcessInfo.processInfo.environment["VOICE_WHISPER_LOG"] == nil else { return }
        whisper_log_set({ _, _, _ in }, nil)
    }
}

extension Duration {
    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}
