import Foundation

/// A recording in, a stored dictation out: whisper, then the cleanup prompt when asked for.
/// The app and voice-cli both go through here, so what the evaluation measures is what
/// gets pasted.
public final class Pipeline: Sendable {
    public enum Stage: Sendable {
        case transcribing
        case cleaningUp
    }

    public let transcriber: Transcriber
    public let store: Store?
    private let ollama = Ollama()

    public init(transcriber: Transcriber, store: Store?) {
        self.transcriber = transcriber
        self.store = store
    }

    public func run(_ audio: URL, recordMs: Int? = nil, whisper: WhisperOptions = WhisperOptions(),
                    cleanup: CleanupSettings? = nil, live: LiveTranscription? = nil,
                    onStage: @escaping @Sendable (Stage) -> Void = { _ in }) async throws -> Dictation {
        onStage(.transcribing)
        var loadSeconds = 0.0
        let transcript: Transcript
        let duration: Double
        // The chunks decoded while recording are the result: a whole-file decode on top
        // would have to wait out the prompt's model and then hold whisper's queue against
        // the next dictation. When a chunk failed, the file is decoded as before.
        if let live, let joined = try? await live.finish() {
            transcript = joined
            duration = live.duration
        } else {
            let samples = try Audio.load(audio)
            loadSeconds = try await transcriber.load()
            transcript = try await transcriber.transcribe(samples, options: whisper)
            duration = Double(samples.count) / Audio.sampleRate
        }
        var dictation = Dictation(
            id: UUID().uuidString, createdAt: Date(), audioPath: audio.path,
            duration: duration,
            mode: cleanup == nil ? .plain : .cleanup, whisperModel: transcriber.modelName,
            rawText: transcript.text, finalText: transcript.text,
            cleanupModel: cleanup?.model, cleanupSystem: cleanup?.system,
            timings: .init(record: recordMs, load: Self.ms(loadSeconds), transcribe: Self.ms(transcript.seconds)),
            segments: transcript.segments)
        if let cleanup, !transcript.text.isEmpty {
            // On a 16 GB Mac, whisper's GPU memory plus a 27B model's is more than Metal
            // allows, and Ollama's runner then fails every request until its model is
            // unloaded. Whisper gives its memory back first; reloading it costs 0.4 s.
            await transcriber.unload()
            onStage(.cleaningUp)
            // A failed cleanup still pastes whisper's text, so the words aren't lost.
            do {
                let result = try await ollama.cleanup(transcript.text, settings: cleanup)
                dictation.timings.cleanup = Self.ms(result.seconds)
                if !result.text.isEmpty { dictation.finalText = result.text }
            } catch {
                dictation.error = "\(error)"
            }
        }
        try store?.insert(dictation)
        return dictation
    }

    static func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }
}
