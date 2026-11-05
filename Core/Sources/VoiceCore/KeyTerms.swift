import Foundation
import whisper

/// The key terms list Settings shows: one string, the terms separated by commas or new lines.
/// Agents change it through add and remove, which keep the user's own formatting and only
/// touch the terms they name.
public enum KeyTerms {
    /// The terms in order, trimmed, without empty ones, and each only once whatever its case:
    /// the first spelling wins.
    public static func parse(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The text with `terms` appended, skipping those already there in any case. New terms go
    /// one per line when the list is already written that way, otherwise after a comma.
    public static func adding(_ terms: [String], to text: String) -> (text: String, added: [String], present: [String]) {
        var known = Set(parse(text).map { $0.lowercased() })
        var added: [String] = []
        var present: [String] = []
        for term in terms.flatMap(parse) {
            if known.insert(term.lowercased()).inserted { added.append(term) } else { present.append(term) }
        }
        guard !added.isEmpty else { return (text, [], present) }
        let separator = text.contains(where: \.isNewline) ? "\n" : ", "
        var base = text
        while let last = base.last, last.isWhitespace { base.removeLast() }
        let joined = added.joined(separator: separator)
        if base.isEmpty { return (joined, added, present) }
        return (base + (base.hasSuffix(",") ? " " : separator) + joined, added, present)
    }

    /// The text without `terms`, compared without case. Each term goes with the separator
    /// before it (after it, for the first), so removing what `adding` added gives back the
    /// text it started from.
    public static func removing(_ terms: [String], from text: String) -> (text: String, removed: [String], missing: [String]) {
        let wanted = terms.flatMap(parse)
        let targets = Set(wanted.map { $0.lowercased() })
        // Pieces alternate: entry, separator, entry, ... with separators kept as written.
        var pieces: [(entry: String, separator: String)] = []
        var entry = ""
        for character in text {
            if character == "," || character.isNewline {
                pieces.append((entry, String(character)))
                entry = ""
            } else {
                entry.append(character)
            }
        }
        pieces.append((entry, ""))
        var removed: [String] = []
        var kept: [(entry: String, separator: String)] = []
        for piece in pieces {
            let term = piece.entry.trimmingCharacters(in: .whitespaces)
            if !term.isEmpty, targets.contains(term.lowercased()) {
                if !removed.contains(where: { $0.lowercased() == term.lowercased() }) { removed.append(term) }
                if piece.separator.isEmpty, !kept.isEmpty {
                    // The last entry: the separator before it goes instead.
                    kept[kept.count - 1].separator = ""
                }
                continue
            }
            kept.append(piece)
        }
        var result = kept.map { $0.entry + $0.separator }.joined()
        // A removed first entry leaves the space that followed its comma.
        if let first = result.first, first == " ", !(text.first?.isWhitespace ?? false) {
            result.removeFirst()
        }
        let gone = Set(removed.map { $0.lowercased() })
        var missing: [String] = []
        for term in wanted where !gone.contains(term.lowercased()) && !missing.contains(term) { missing.append(term) }
        return (result, removed, missing)
    }

    /// What whisper reads from the list: the same prompt the app builds before each decode.
    public static func prompt(_ terms: [String]) -> String {
        var options = WhisperOptions()
        options.keyTerms = terms
        return options.prompt
    }
}

/// Where the key terms live. The app reads and writes them through its Preferences, so
/// Settings changes as an agent edits; voice-cli writes the app's defaults directly.
public protocol KeyTermsSettings: Sendable {
    func keyTerms() async -> String
    func setKeyTerms(_ text: String) async
}

/// The app's own defaults, for voice-cli. The app observes the key, so a running Voice takes
/// the change at once.
public struct AppDefaultsKeyTerms: KeyTermsSettings {
    public static let domain = "io.github.spashii.voice"
    public static let key = "keyTerms"

    public init() {}

    public func keyTerms() async -> String {
        defaults.string(forKey: Self.key) ?? ""
    }

    public func setKeyTerms(_ text: String) async {
        defaults.set(text, forKey: Self.key)
    }

    /// UserDefaults won't open a suite named after the running bundle, which is the domain
    /// itself in that case.
    private var defaults: UserDefaults {
        Bundle.main.bundleIdentifier == Self.domain ? .standard : UserDefaults(suiteName: Self.domain) ?? .standard
    }
}

/// Counts a prompt in whisper's tokens, and says how many of them whisper reads.
public protocol PromptTokenizer: Sendable {
    func tokens(_ text: String) throws -> Int
    /// whisper.cpp keeps the last n_text_ctx / 2 tokens of the prompt, 224 for every model
    /// Voice offers, and drops the rest from the front, which is where the key terms sit.
    func limit() throws -> Int
}

/// whisper.cpp's own tokenizer, without the model's weights: the file's header and
/// vocabulary are handed to whisper.cpp as a model with no tensors, which it accepts (it
/// warns and loads an empty model, as for its own tests). That reads well under a megabyte
/// and touches no GPU, so voice-cli can count tokens without loading a 1.6 GB model.
public final class WhisperTokenizer: PromptTokenizer, @unchecked Sendable {
    private let lock = NSLock()
    private let modelURL: URL?
    private var vocabulary: Data?

    /// The first speech model on disk: every model Voice offers has the same text tokens.
    public init(modelURL: URL? = WhisperModel.allCases.first(where: \.isDownloaded)?.file) {
        self.modelURL = modelURL
    }

    public func tokens(_ text: String) throws -> Int {
        guard !text.isEmpty else { return 0 }
        return try withContext { context in
            // With no room for tokens whisper_tokenize returns minus the number it needs.
            let count = whisper_tokenize(context, text, nil, 0)
            return count < 0 ? -Int(count) : Int(count)
        }
    }

    public func limit() throws -> Int {
        try withContext { Int(whisper_model_n_text_ctx($0)) / 2 }
    }

    private func withContext<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if vocabulary == nil { vocabulary = try Self.header(modelURL) }
        var params = whisper_context_default_params()
        params.use_gpu = false
        params.flash_attn = false
        Transcriber.silenceLogs()
        guard let context = vocabulary!.withUnsafeBytes({ bytes in
            whisper_init_from_buffer_with_params_no_state(UnsafeMutableRawPointer(mutating: bytes.baseAddress),
                                                          bytes.count, params)
        }) else {
            throw VoiceError.whisper("Whisper couldn't read the vocabulary in \(modelURL?.lastPathComponent ?? "the model").")
        }
        defer { whisper_free(context) }
        return try body(context)
    }

    /// The model file up to the end of its vocabulary: magic, 11 hyperparameters, the mel
    /// filters, then each token as a length and its bytes. The tensors follow.
    static func header(_ url: URL?) throws -> Data {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw VoiceError.whisper("No speech model is downloaded to count whisper's tokens with.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        func need(_ count: Int) throws {
            while data.count < count {
                guard let more = try handle.read(upToCount: max(1 << 20, count - data.count)), !more.isEmpty else {
                    throw VoiceError.whisper("\(url.lastPathComponent) ends before its vocabulary does.")
                }
                data.append(more)
            }
        }
        func int32(at offset: Int) throws -> Int {
            try need(offset + 4)
            return Int(data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        }
        guard try int32(at: 0) == 0x6767_6d6c else { throw VoiceError.whisper("\(url.lastPathComponent) isn't a whisper model.") }
        var offset = 4 + 11 * 4
        let mels = try int32(at: offset)
        let fft = try int32(at: offset + 4)
        offset += 8 + mels * fft * 4
        let count = try int32(at: offset)
        offset += 4
        for _ in 0..<count {
            offset += 4 + (try int32(at: offset))
        }
        try need(offset)
        return data.prefix(offset)
    }
}

/// What a key-term change did.
struct KeyTermsChange: Sendable {
    /// The terms added or removed.
    var changed: [String]
    /// The terms already there (for an add) or not there (for a remove).
    var unchanged: [String]
    /// The list after.
    var terms: [String]
    /// Whisper's tokens for the prompt the list makes, and the most it reads; nil when no
    /// speech model is on disk to count with.
    var tokens: Int?
    var limit: Int?
    /// Nil when nothing changed.
    var edit: Edit?
}

/// Agents' changes to the key terms, one at a time, each recorded as an edit. An add that
/// would make whisper's prompt longer than whisper reads is refused whole: whisper.cpp keeps
/// the end of a long prompt, so the first key terms would silently stop counting.
actor KeyTermsEditor {
    let settings: any KeyTermsSettings
    let tokenizer: any PromptTokenizer
    let store: CallStore

    init(settings: any KeyTermsSettings, tokenizer: any PromptTokenizer, store: CallStore) {
        self.settings = settings
        self.tokenizer = tokenizer
        self.store = store
    }

    func list() async -> KeyTermsChange {
        let terms = KeyTerms.parse(await settings.keyTerms())
        let (tokens, limit) = count(terms)
        return KeyTermsChange(changed: [], unchanged: [], terms: terms, tokens: tokens, limit: limit, edit: nil)
    }

    func add(_ terms: [String], client: String?) async throws -> KeyTermsChange {
        let text = await settings.keyTerms()
        let result = KeyTerms.adding(terms, to: text)
        return try await apply(.addKeyTerms, from: text, to: result.text, changed: result.added,
                               unchanged: result.present, client: client)
    }

    func remove(_ terms: [String], client: String?) async throws -> KeyTermsChange {
        let text = await settings.keyTerms()
        let result = KeyTerms.removing(terms, from: text)
        return try await apply(.removeKeyTerms, from: text, to: result.text, changed: result.removed,
                               unchanged: result.missing, client: client)
    }

    /// Takes out what an add added, or puts back what a remove removed, as far as the list
    /// still allows: terms changed since in Settings stay as they are.
    func undo(_ id: Int64, client: String?) async throws -> Edit {
        let edit = try store.checkUndoable(id)
        let before = edit.before?.terms ?? []
        let after = edit.after?.terms ?? []
        let text = await settings.keyTerms()
        let current = KeyTerms.parse(text)
        let next: String
        switch edit.kind {
        case .addKeyTerms:
            next = KeyTerms.removing(Self.minus(after, before), from: text).text
        case .removeKeyTerms:
            let back = KeyTerms.adding(Self.minus(before, after), to: text)
            try check(current, adding: back.added)
            next = back.text
        default:
            throw ToolError("Edit \(id) isn't a key-term change.")
        }
        if next != text { await settings.setKeyTerms(next) }
        return try store.recordUndo(of: id, client: client, before: Edit.Value(terms: current),
                                    after: Edit.Value(terms: KeyTerms.parse(next)))
    }

    private func apply(_ kind: Edit.Kind, from text: String, to next: String, changed: [String], unchanged: [String],
                       client: String?) async throws -> KeyTermsChange {
        let before = KeyTerms.parse(text)
        let after = KeyTerms.parse(next)
        if kind == .addKeyTerms { try check(before, adding: changed) }
        var edit: Edit?
        if !changed.isEmpty {
            await settings.setKeyTerms(next)
            edit = try store.recordEdit(kind, target: Edit.keyTermsTarget, client: client,
                                        before: Edit.Value(terms: before), after: Edit.Value(terms: after))
        }
        let (tokens, limit) = count(after)
        return KeyTermsChange(changed: changed, unchanged: unchanged, terms: after, tokens: tokens, limit: limit,
                              edit: edit)
    }

    /// Throws, naming the tokens left and the new terms that fit in them, in the order given,
    /// when the list with `new` makes a prompt longer than whisper reads.
    private func check(_ current: [String], adding new: [String]) throws {
        guard !new.isEmpty else { return }
        let limit = try tokenizer.limit()
        let tokens = try tokenizer.tokens(KeyTerms.prompt(current + new))
        guard tokens > limit else { return }
        let left = max(0, limit - (try tokenizer.tokens(KeyTerms.prompt(current))))
        var fit: [String] = []
        for term in new {
            if try tokenizer.tokens(KeyTerms.prompt(current + fit + [term])) <= limit { fit.append(term) }
        }
        let fits = fit.isEmpty ? "none of these terms fits." : "these fit: \(fit.joined(separator: ", "))."
        throw ToolError("Nothing added: whisper's prompt would be \(tokens) tokens, and whisper reads at most "
                        + "\(limit). \(left) tokens are left; \(fits)")
    }

    private func count(_ terms: [String]) -> (Int?, Int?) {
        guard let limit = try? tokenizer.limit() else { return (nil, nil) }
        return (try? tokenizer.tokens(KeyTerms.prompt(terms)), limit)
    }

    private static func minus(_ a: [String], _ b: [String]) -> [String] {
        let other = Set(b.map { $0.lowercased() })
        return a.filter { !other.contains($0.lowercased()) }
    }
}
