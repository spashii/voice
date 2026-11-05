import Foundation
import whisper

/// The whisper models Settings offers. Turbo is about as accurate on English and several
/// times faster, so it is the default; large v3 is there for the languages turbo does worse.
public enum WhisperModel: String, CaseIterable, Sendable, Identifiable {
    case largeV3Turbo = "ggml-large-v3-turbo"
    case largeV3 = "ggml-large-v3"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .largeV3Turbo: "Large v3 turbo"
        case .largeV3: "Large v3"
        }
    }

    public var bytes: Int64 {
        switch self {
        case .largeV3Turbo: 1_624_555_275
        case .largeV3: 3_095_033_483
        }
    }

    public var url: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(rawValue).bin")!
    }

    public var file: URL { Paths.models.appending(path: "\(rawValue).bin") }

    /// OpenSuperWhisper keeps the same files; a copy of one is an APFS clone, which takes
    /// no space.
    public var openSuperWhisperFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/ru.starmel.OpenSuperWhisper/whisper-models/\(rawValue).bin")
    }

    public var isDownloaded: Bool { FileManager.default.fileExists(atPath: file.path) }
}

/// The voice activity model that cuts silence before whisper, downloaded with whisper's.
public enum VADModel {
    public static let url = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!
    public static var file: URL { Paths.vadModel }
    public static var isDownloaded: Bool { FileManager.default.fileExists(atPath: file.path) }
}

/// The languages whisper knows, by code and English name, sorted by name.
public enum WhisperLanguages {
    public static let all: [(code: String, name: String)] = (0...whisper_lang_max_id())
        .compactMap { id -> (code: String, name: String)? in
            guard let code = whisper_lang_str(id), let name = whisper_lang_str_full(id) else { return nil }
            return (String(cString: code), String(cString: name).capitalized)
        }
        .sorted { $0.name < $1.name }
}

extension Ollama {
    /// The models Ollama has installed. Throws when it isn't running.
    public func installedModels(at url: URL) async throws -> [String] {
        var request = URLRequest(url: url.appending(path: "api/tags"))
        // Ollama answers on localhost at once when it runs; waiting longer only delays the
        // "not running" state.
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = reply["models"] as? [[String: Any]] else {
            throw VoiceError.cleanup("Ollama answered without a model list.")
        }
        return models.compactMap { $0["name"] as? String }.sorted()
    }
}
