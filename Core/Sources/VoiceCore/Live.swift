import Foundation
import os

/// Cuts a stream of 16 kHz samples into chunks at pauses, so each can be decoded while the
/// recording goes on. It gates on loudness rather than running Silero: a pause only needs
/// to be found, not judged, and the decode still runs Silero on every chunk to drop the
/// silence before whisper sees it.
public struct Chunker: Sendable {
    /// 20 ms frames: short enough to place a cut between words.
    public static let frame = 320
    /// Shorter chunks give whisper too little context and cost more boundary errors.
    public var minSeconds = 4.0
    /// Whisper reads 30 s windows; a chunk longer than this would be split by whisper itself.
    public var maxSeconds = 25.0
    /// Silence that closes a chunk; a long chunk takes a shorter pause, so it closes before
    /// the cap forces a cut.
    public var pause = 0.6
    public var shortPause = 0.3
    public var shortPauseAfter = 15.0
    /// A frame is silent when it is this far above the recent noise floor or less.
    public var marginDb: Float = 10

    private var pending: [Float] = []
    private var levels: [Float] = []
    private var chunkStart = 0
    private var silentRun = 0
    private var threshold: Float = -50

    public init() {}

    /// Adds samples and returns the cuts they close, as sample offsets from the start.
    public mutating func append(_ samples: UnsafeBufferPointer<Float>) -> [Int] {
        pending.append(contentsOf: samples)
        var cuts: [Int] = []
        var used = 0
        while pending.count - used >= Self.frame {
            let frame = pending[used..<(used + Self.frame)]
            used += Self.frame
            let power = frame.reduce(0) { $0 + $1 * $1 } / Float(Self.frame)
            levels.append(10 * log10(max(power, 1e-10)))
            if levels.count % 25 == 0 { updateThreshold() }
            silentRun = levels.last! <= threshold ? silentRun + 1 : 0
            if let cut = nextCut() {
                cuts.append(cut * Self.frame)
                chunkStart = cut
                silentRun = 0
            }
        }
        pending.removeFirst(used)
        return cuts
    }

    private func frames(_ seconds: Double) -> Int { Int(seconds * Audio.sampleRate) / Self.frame }

    private func nextCut() -> Int? {
        let length = levels.count - chunkStart
        guard length >= frames(minSeconds) else { return nil }
        let needed = frames(length >= frames(shortPauseAfter) ? shortPause : pause)
        // In the middle of the pause, so each side keeps some of the silence, but never
        // short of the minimum: a long silence would otherwise cut itself into slivers.
        if silentRun >= needed { return max(levels.count - silentRun / 2, chunkStart + frames(minSeconds)) }
        guard length >= frames(maxSeconds) else { return nil }
        // No pause came: cut at the quietest 0.3 s, which is between words far more often
        // than not.
        let window = frames(0.3)
        var best = levels.count - window / 2
        var bestSum = Float.infinity
        var sum = levels[(chunkStart + frames(minSeconds) - window)..<(chunkStart + frames(minSeconds))].reduce(0, +)
        for end in (chunkStart + frames(minSeconds))..<levels.count {
            sum += levels[end] - levels[end - window]
            if sum < bestSum {
                bestSum = sum
                best = end - window / 2
            }
        }
        return best
    }

    /// The noise floor is the 15th percentile of the last 10 s, which follows a room
    /// getting louder or quieter without speech pulling it up. Kept well under the loud
    /// end too, so 10 s of unbroken speech doesn't read as its own floor.
    private mutating func updateThreshold() {
        let recent = levels.suffix(500).sorted()
        threshold = min(recent[recent.count * 15 / 100] + marginDb, recent[recent.count * 90 / 100] - 15)
    }
}

/// Transcribes a recording while it is made: the chunker closes a chunk at each pause, and
/// one worker decodes the chunks in order with the previous chunk's text as context. Audio
/// is only ever appended, so a worker that falls behind catches up instead of losing any.
/// The WAV on disk stays the record; this is a faster route to the same text.
public final class LiveTranscription: @unchecked Sendable {
    public struct Chunk: Sendable {
        public let index: Int
        public let start: Double
        public let end: Double
        public let text: String
        /// Seconds whisper took, and seconds from the chunk closing to its text.
        public let decodeSeconds: Double
        public let lagSeconds: Double
    }

    private final class State: @unchecked Sendable {
        let lock = OSAllocatedUnfairLock()
        var samples: [Float] = []
        var chunker = Chunker()
        var start = 0
        var finished = false
    }

    public let transcriber: Transcriber
    private let state = State()
    private typealias Closed = (range: Range<Int>, at: ContinuousClock.Instant, last: Bool)
    private let queue: AsyncStream<Closed>.Continuation
    private let worker: Task<Transcript, Error>

    /// onChunk runs on the worker after each chunk, with the chunk and the text so far.
    public init(transcriber: Transcriber, options: WhisperOptions,
                onChunk: @escaping @Sendable (Chunk, String) -> Void = { _, _ in }) {
        self.transcriber = transcriber
        let (stream, queue) = AsyncStream.makeStream(of: Closed.self)
        self.queue = queue
        let state = state
        let shortTail = Int(state.chunker.minSeconds * Audio.sampleRate)
        worker = Task {
            var parts: [(range: Range<Int>, prompt: String, transcript: Transcript)] = []
            var total = Transcript(text: "", segments: [], seconds: 0)
            var index = 0
            func text() -> String { parts.map(\.transcript.text).filter { !$0.isEmpty }.joined(separator: " ") }
            for await closed in stream {
                var range = closed.range
                var prompt = parts.last.map { Self.context($0.transcript.text, or: $0.prompt) } ?? options.initialPrompt
                // A last few words after a pause can come to under the second whisper
                // needs once Silero drops the silence, and it skips them; decoded with the
                // chunk before, they are kept.
                if closed.last, range.count < shortTail, let previous = parts.popLast() {
                    range = previous.range.lowerBound..<range.upperBound
                    prompt = previous.prompt
                }
                let audio = state.lock.withLockUnchecked { Array(state.samples[range]) }
                var chunkOptions = options
                chunkOptions.initialPrompt = prompt
                var part = try await transcriber.transcribe(audio, options: chunkOptions)
                let offset = Double(range.lowerBound) / Audio.sampleRate
                for i in part.segments.indices {
                    part.segments[i].t0 += offset
                    part.segments[i].t1 += offset
                }
                total.retried += part.retried
                total.retrySeconds += part.retrySeconds
                parts.append((range, prompt, part))
                onChunk(Chunk(index: index, start: offset, end: Double(range.upperBound) / Audio.sampleRate,
                              text: part.text, decodeSeconds: part.seconds,
                              lagSeconds: (ContinuousClock.now - closed.at).seconds), text())
                index += 1
            }
            try Task.checkCancellation()
            total.text = text()
            total.segments = parts.flatMap(\.transcript.segments)
            return total
        }
    }

    deinit { cancel() }

    /// Whisper keeps the end of a long prompt and drops its start, which is where the key
    /// terms are; 50 words of the chunk before stay well inside it.
    private static func context(_ text: String, or fallback: String) -> String {
        text.isEmpty ? fallback : text.split(separator: " ").suffix(50).joined(separator: " ")
    }

    public var duration: Double {
        state.lock.withLockUnchecked { Double(state.samples.count) / Audio.sampleRate }
    }

    /// Takes 16 kHz mono samples; cheap enough for the audio thread.
    public func append(_ samples: UnsafeBufferPointer<Float>) {
        state.lock.withLockUnchecked {
            guard !state.finished else { return }
            state.samples.append(contentsOf: samples)
            for cut in state.chunker.append(samples) {
                queue.yield((state.start..<cut, .now, false))
                state.start = cut
            }
        }
    }

    /// Closes the open tail and waits for every chunk. Its seconds are the wait, which is
    /// what stopping costs; throws if any chunk failed, so the caller can decode the file.
    public func finish() async throws -> Transcript {
        let started = ContinuousClock.now
        state.lock.withLockUnchecked {
            guard !state.finished else { return }
            state.finished = true
            if state.samples.count > state.start { queue.yield((state.start..<state.samples.count, .now, true)) }
        }
        queue.finish()
        var transcript = try await worker.value
        transcript.seconds = (ContinuousClock.now - started).seconds
        return transcript
    }

    /// Stops decoding; for a recording that is thrown away or kept without transcribing.
    public func cancel() {
        state.lock.withLockUnchecked { state.finished = true }
        queue.finish()
        worker.cancel()
    }
}
