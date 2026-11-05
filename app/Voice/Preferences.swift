import Foundation
import Observation
import VoiceCore

/// What Settings changes, kept in UserDefaults.
@MainActor @Observable
final class Preferences {
    /// Empty: the names worth listing are your own.
    static let defaultKeyTerms = ""

    enum History: String, CaseIterable, Identifiable {
        case forever
        case thirtyDays

        var id: String { rawValue }

        var title: String {
            switch self {
            case .forever: "Forever"
            case .thirtyDays: "30 days"
            }
        }
    }

    /// The input's UID; empty follows the system default.
    var microphoneUID: String { didSet { save(microphoneUID, "microphoneUID") } }
    /// Whisper's language code, or "auto" to detect it.
    var language: String { didSet { save(language, "language") } }
    /// Whether whisper's text goes through the prompt before it's pasted.
    var runPrompt: Bool { didSet { UserDefaults.standard.set(runPrompt, forKey: "runPrompt") } }
    var ollamaModel: String { didSet { save(ollamaModel, "ollamaModel") } }
    var prompt: String { didSet { save(prompt, "prompt") } }
    /// Comma or newline separated.
    var keyTerms: String { didSet { save(keyTerms, "keyTerms") } }
    var whisperModel: WhisperModel { didSet { save(whisperModel.rawValue, "whisperModel") } }
    /// Forever by default: past dictations are the test set for whisper and the prompt.
    var history: History { didSet { save(history.rawValue, "history") } }
    /// Decodes the segments whisper was least sure of a second time, within half the first
    /// decode's time. On by default.
    var retrySegments: Bool { didSet { UserDefaults.standard.set(retrySegments, forKey: "retrySegments") } }
    /// Not in Settings: Ollama is on this Mac on its own port, and nothing else is expected.
    let ollamaURL: String
    /// voice-cli mcp writes the key terms from another process; this brings them in.
    @ObservationIgnored private var keyTermsObserver: DefaultsObserver?

    init() {
        let defaults = UserDefaults.standard
        microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        language = defaults.string(forKey: "language") ?? "en"
        runPrompt = defaults.object(forKey: "runPrompt") as? Bool ?? false
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? "qwen3.5:9b"
        prompt = defaults.string(forKey: "prompt") ?? CleanupSettings.defaultPrompt
        keyTerms = defaults.string(forKey: "keyTerms") ?? Self.defaultKeyTerms
        whisperModel = defaults.string(forKey: "whisperModel").flatMap(WhisperModel.init) ?? .largeV3Turbo
        history = defaults.string(forKey: "history").flatMap(History.init) ?? .forever
        retrySegments = defaults.object(forKey: "retrySegments") as? Bool ?? true
        ollamaURL = defaults.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434"
        keyTermsObserver = DefaultsObserver("keyTerms") { [weak self] in
            Task { @MainActor in self?.reloadKeyTerms() }
        }
    }

    private func reloadKeyTerms() {
        let stored = UserDefaults.standard.string(forKey: "keyTerms") ?? Self.defaultKeyTerms
        if stored != keyTerms { keyTerms = stored }
    }

    var cleanup: CleanupSettings {
        CleanupSettings(
            ollamaURL: URL(string: ollamaURL) ?? URL(string: "http://127.0.0.1:11434")!,
            model: ollamaModel, prompt: prompt,
            keyTerms: KeyTerms.parse(keyTerms))
    }

    /// The key terms open whisper's prompt: on a set of real dictations that took exactly
    /// spelled names from 5 of 13 to 9 of 13 at no measurable cost. Fallback stays at
    /// whisper.cpp's defaults. Segment retries follow the switch, with SegmentRetry's
    /// threshold and budget: on open test sets beam 5 with the previous text cut errors
    /// by 28%, and every segment keeps a record so the app can measure them on real use.
    var whisper: WhisperOptions {
        var options = WhisperOptions()
        options.language = language
        options.keyTerms = KeyTerms.parse(keyTerms)
        options.retry.enabled = retrySegments
        return options
    }

    private func save(_ value: String, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

/// Agents' key-term changes when Voice hosts the MCP server: through Preferences, so the
/// Settings field and the next decode both have them at once.
struct PreferencesKeyTerms: KeyTermsSettings {
    let preferences: Preferences

    func keyTerms() async -> String {
        await preferences.keyTerms
    }

    func setKeyTerms(_ text: String) async {
        await MainActor.run { preferences.keyTerms = text }
    }
}

/// Calls back when a default changes, in this process or another: UserDefaults reports
/// another process's writes to key-value observers.
private final class DefaultsObserver: NSObject {
    private let key: String
    private let changed: @Sendable () -> Void

    init(_ key: String, changed: @escaping @Sendable () -> Void) {
        self.key = key
        self.changed = changed
        super.init()
        UserDefaults.standard.addObserver(self, forKeyPath: key, options: [], context: nil)
    }

    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: key)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        changed()
    }
}
