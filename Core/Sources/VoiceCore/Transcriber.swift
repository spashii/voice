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
}

public struct Transcript: Sendable {
    public var text: String
    public var segments: [Segment]
    /// All of it, retries included.
    public var seconds: Double
    /// The segments decoded again, and the seconds that took (part of `seconds`).
    public var retried = 0
    public var retrySeconds = 0.0
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
    public var enabled = false
    /// Segments whose mean token log probability is below this are candidates. Of the
    /// checker's signals it is the one that finds bad segments (AUC 0.80 on open test sets);
    /// compression ratio and words per second barely do.
    public var logprobBelow = -0.6
    /// Retry time allowed, as a share of the first decode's.
    public var budget = 0.5
    public var beamSize = 5
    /// Seconds of audio kept on each side of the segment.
    public var padding = 0.5

    public init() {}
}

/// Runs whisper.cpp on the GPU. One decode at a time, on its own queue, since a context
/// can't run two.
public final class Transcriber: @unchecked Sendable {
    public let modelURL: URL
    public let vadModelURL: URL?
    private let queue = DispatchQueue(label: "voice.whisper", qos: .userInitiated)
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
            return options.retry.enabled ? try self.retry(first, samples, options) : first
        }
    }

    private func retry(_ first: Transcript, _ samples: [Float], _ options: WhisperOptions) throws -> Transcript {
        var transcript = first
        let budget = first.seconds * options.retry.budget
        let candidates = first.segments.indices
            .filter { !first.segments[$0].text.isEmpty && first.segments[$0].avgLogprob < options.retry.logprobBelow }
            .sorted { first.segments[$0].avgLogprob < first.segments[$1].avgLogprob }
        for i in candidates {
            guard transcript.retrySeconds < budget else { break }
            let segment = transcript.segments[i]
            let from = max(0, Int((segment.t0 - options.retry.padding) * Audio.sampleRate))
            let to = min(samples.count, Int((segment.t1 + options.retry.padding) * Audio.sampleRate))
            guard to > from else { continue }
            var again = options
            again.beamSize = options.retry.beamSize
            again.vad = false
            again.initialPrompt = i > 0 ? transcript.segments[i - 1].text : options.initialPrompt
            let second = try decode(Array(samples[from..<to]), again)
            transcript.retried += 1
            transcript.retrySeconds += second.seconds
            let text = second.segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            let characters = second.segments.reduce(0.0) { $0 + Double($1.text.count) }
            let logprob = characters > 0
                ? second.segments.reduce(0.0) { $0 + $1.avgLogprob * Double($1.text.count) } / characters
                : -Double.infinity
            if !text.isEmpty && logprob > segment.avgLogprob {
                var kept = segment
                kept.replaced = segment.text
                kept.text = text
                kept.avgLogprob = logprob
                kept.compressionRatio = Self.compressionRatio(text)
                let words = text.split(whereSeparator: \.isWhitespace).count
                kept.wordsPerSecond = kept.speechSeconds > 0.05 ? Double(words) / kept.speechSeconds : 0
                transcript.segments[i] = kept
            }
        }
        transcript.seconds += transcript.retrySeconds
        transcript.text = transcript.segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        return transcript
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
