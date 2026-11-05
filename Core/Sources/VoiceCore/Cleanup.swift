import Foundation

/// The optional step after whisper: a local model through Ollama rewrites the text by the
/// prompt the user writes.
public struct CleanupSettings: Sendable, Codable, Equatable {
    public var ollamaURL: URL
    public var model: String
    public var prompt: String
    /// Names and words whisper tends to get wrong, spelled as they should appear.
    public var keyTerms: [String]
    /// Low, so a dictation comes back the same way twice; Qwen advises against 0. The
    /// evaluation sets 0 to make runs repeatable.
    public var temperature: Double

    public init(ollamaURL: URL = URL(string: "http://127.0.0.1:11434")!,
                model: String = "qwen3.5:9b",
                prompt: String = CleanupSettings.defaultPrompt,
                keyTerms: [String] = [], temperature: Double = 0.2) {
        self.ollamaURL = ollamaURL
        self.model = model
        self.prompt = prompt
        self.keyTerms = keyTerms
        self.temperature = temperature
    }

    public static let defaultPrompt = """
        You clean up dictated text. Fix words the speech recognizer misheard, especially the \
        key terms, and fix punctuation and capitalization. Keep the speaker's wording, \
        language and meaning: do not add, answer, summarize or explain anything. Output only \
        the corrected text.
        """

    /// The system message: the prompt, then the key terms.
    public var system: String {
        let terms = keyTerms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return terms.isEmpty ? prompt : prompt + "\n\nKey terms: " + terms.joined(separator: ", ")
    }
}

public struct CleanupResult: Sendable, Codable {
    public var text: String
    public var seconds: Double
    /// Seconds Ollama spent loading the model; near 0 when it was already in memory.
    public var loadSeconds: Double
    public var promptTokens: Int
    public var outputTokens: Int
    public var outputSeconds: Double
}

public struct Ollama: Sendable {
    public init() {}

    public func cleanup(_ text: String, settings: CleanupSettings) async throws -> CleanupResult {
        var request = URLRequest(url: settings.ollamaURL.appending(path: "api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A cold 27B model takes about 16 s to load on a 16 GB Mac before it writes anything.
        request.timeoutInterval = 180
        let body: [String: Any] = [
            "model": settings.model,
            "system": settings.system,
            "prompt": text,
            // Thinking would multiply the wait for an edit that doesn't need it.
            "think": false,
            "stream": false,
            // A 27B model takes 11 GB of a 16 GB Mac; kept for 15 minutes it pushed macOS into
            // 9.7 GB of swap. Two minutes covers a run of dictations, then gives it back.
            "keep_alive": "2m",
            "options": ["temperature": settings.temperature],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let start = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw VoiceError.cleanup("Ollama isn't answering at \(settings.ollamaURL.absoluteString).")
        }
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VoiceError.cleanup("Ollama: \(reply["error"] as? String ?? "status \((response as? HTTPURLResponse)?.statusCode ?? 0)")")
        }
        // A runner that failed on the GPU answers 200 with an empty, unfinished reply.
        guard reply["done"] as? Bool == true else {
            throw VoiceError.cleanup("Ollama's model failed to answer; its server.log says why (often GPU memory).")
        }
        let output = Self.stripThinking(reply["response"] as? String ?? "")
        let nanos = { (key: String) in Double(reply[key] as? Int ?? 0) / 1e9 }
        return CleanupResult(
            text: output,
            seconds: (ContinuousClock.now - start).seconds,
            loadSeconds: nanos("load_duration"),
            promptTokens: reply["prompt_eval_count"] as? Int ?? 0,
            outputTokens: reply["eval_count"] as? Int ?? 0,
            outputSeconds: nanos("eval_duration"))
    }

    /// Asks Ollama to drop the model from memory, so the next call measures a cold start.
    public func unload(_ settings: CleanupSettings) async {
        var request = URLRequest(url: settings.ollamaURL.appending(path: "api/generate"))
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": settings.model, "keep_alive": 0])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Some models still wrap a stray thought in <think> tags; only the answer is pasted.
    static func stripThinking(_ text: String) -> String {
        var text = text
        while let open = text.range(of: "<think>"), let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
