import Foundation
import VoiceCore
import whisper

// Runs recordings through the same pipeline as the app, with no microphone, sound or window.
//
//   voice-cli transcribe FILE [--cleanup] [options]   one recording, printed as JSON
//   voice-cli eval DIR [--cleanup N] [options]        every DIR/NAME.wav against DIR/NAME.txt
//   voice-cli batch MANIFEST OUT [--beam N] [--context FIRST] [--scored-only]
//       transcribes a JSON lines manifest of utterances into OUT, a JSON line each; with
//       --context, each prompt is FIRST's text for the utterance spoken just before it
//   voice-cli cleanup-batch IN OUT [--uids FILE] [--temperature T]
//       runs the prompt over IN's texts (batch output), a JSON line per utterance
//   voice-cli live FILE [--speed X]                    feeds FILE through the live chunker at X
//       times real time (1; 0 is as fast as it decodes), printing each chunk, then compares
//       the joined chunks with a whole-file decode
//   voice-cli defaults                                   whisper.cpp's decoding defaults
//   voice-cli call ..., voice-cli watch-calls            call recording; see Calls.swift
//   voice-cli import-osw [PATH]                          OpenSuperWhisper's history into Voice's;
//       see ImportOSW.swift
//
// Whisper options for batch: --whisper-terms (the key terms open whisper's prompt),
// --entry-terms (a manifest entry's own terms instead), --no-fallback (temperature
// fallback off), --retry [--retry-budget X] (segment retries), --uids FILE (only these).
//
// batch and cleanup-batch skip what OUT already holds, so an interrupted run picks up.
//
// Options: --model PATH, --vad-model PATH, --no-vad, --db PATH, --ollama-model NAME,
// --prompt TEXT, --terms "A, B, C".

// None by default, as in the app; --terms sets them.
let defaultTerms: [String] = []

var args = Array(CommandLine.arguments.dropFirst())

@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

@MainActor func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let model = option("--model").map { URL(fileURLWithPath: $0) } ?? Paths.whisperModel
let vadModel = option("--vad-model").map { URL(fileURLWithPath: $0) } ?? Paths.vadModel
let dbPath = option("--db")
// mcp and fake-call (Agents.swift) need no whisper model, so they run here and exit.
if let command = args.first, ["mcp", "fake-call"].contains(command) {
    await agentCommand(command, Array(args.dropFirst()), dbPath: dbPath)
    exit(0)
}
if args.first == "import-osw" { importOpenSuperWhisper(Array(args.dropFirst()), dbPath: dbPath) }
if args.first == "watch-calls" { await watchCalls(raw: flag("--raw")) }
var whisper = WhisperOptions()
whisper.vad = !flag("--no-vad")
var cleanup = CleanupSettings(keyTerms: defaultTerms)
if let name = option("--ollama-model") { cleanup.model = name }
if let prompt = option("--prompt") { cleanup.prompt = prompt }
if let terms = option("--terms") { cleanup.keyTerms = terms.split(separator: ",").map { String($0) } }
if let temperature = option("--temperature").flatMap(Double.init) { cleanup.temperature = temperature }
let cleanupCount = option("--cleanup").flatMap(Int.init)
let cleanupOne = flag("--cleanup")
if let beam = option("--beam").flatMap(Int.init) { whisper.beamSize = beam }
let contextPath = option("--context")
let whisperTerms = flag("--whisper-terms")
let entryTerms = flag("--entry-terms")
if flag("--no-fallback") { whisper.temperatureIncrement = 0 }
if flag("--retry") { whisper.retry.enabled = true }
if let budget = option("--retry-budget").flatMap(Double.init) { whisper.retry.budget = budget }
if whisperTerms { whisper.keyTerms = cleanup.keyTerms }
let uidsPath = option("--uids")
/// Stop after this many new items, so a caller can pause between chunks.
let maxItems = option("--max").flatMap(Int.init) ?? Int.max
let scoredOnly = flag("--scored-only")
let speed = option("--speed").flatMap(Double.init) ?? 1

if args.first == "call" {
    let transcriber = Transcriber(modelURL: model, vadModelURL: vadModel)
    await callCommand(Array(args.dropFirst()), transcriber: transcriber, whisper: whisper, dbPath: dbPath)
    // ggml's Metal device asserts at exit while a model still holds it.
    await transcriber.unload()
    exit(0)
}

if args == ["defaults"] {
    let p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
    print("temperature \(p.temperature) temperature_inc \(p.temperature_inc) entropy_thold \(p.entropy_thold) "
          + "logprob_thold \(p.logprob_thold) no_speech_thold \(p.no_speech_thold) greedy.best_of \(p.greedy.best_of) "
          + "beam_size \(p.beam_search.beam_size)")
    exit(0)
}
guard args.count == 2 || (args.count == 3 && ["batch", "cleanup-batch"].contains(args[0])) else {
    fail("usage: voice-cli transcribe FILE [--cleanup] | voice-cli eval DIR [--cleanup N] | voice-cli batch MANIFEST OUT | voice-cli cleanup-batch IN OUT")
}
let command = args[0]
let target = URL(fileURLWithPath: args[1])
let transcriber = Transcriber(modelURL: model, vadModelURL: vadModel)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
encoder.dateEncodingStrategy = .iso8601

func printJSON(_ value: some Encodable) {
    print(String(decoding: try! encoder.encode(value), as: UTF8.self))
}

switch command {
case "transcribe":
    let store = try dbPath.map { try Store(url: URL(fileURLWithPath: $0)) }
    let pipeline = Pipeline(transcriber: transcriber, store: store)
    let dictation = try await pipeline.run(target, whisper: whisper, cleanup: cleanupOne ? cleanup : nil)
    printJSON(dictation)

case "eval":
    try await evaluate(target)

case "live":
    try await live(target)

case "batch":
    try await batch(manifest: target, output: URL(fileURLWithPath: args[2]))

case "cleanup-batch":
    try await cleanupBatch(input: target, output: URL(fileURLWithPath: args[2]))

default:
    fail("unknown command \(command)")
}
await transcriber.unload()

/// Feeds a recording to LiveTranscription in the tap's buffer size, paced like a
/// microphone, then times stop-to-text for it and for the whole-file decode the app did
/// before, with the model already loaded in both.
@MainActor func live(_ url: URL) async throws {
    let samples = try Audio.load(url)
    _ = try await transcriber.load()
    let clock = ContinuousClock()
    let began = clock.now
    @Sendable func f(_ x: Double) -> String { String(format: "%.2f", x) }
    let session = LiveTranscription(transcriber: transcriber, options: whisper) { chunk, _ in
        print("chunk \(chunk.index) \(f(chunk.start))-\(f(chunk.end)) s  decode \(f(chunk.decodeSeconds)) s  "
              + "lag \(f(chunk.lagSeconds)) s  | \(chunk.text)")
    }
    // A 4096-frame tap at 48 kHz.
    let block = 1365
    var i = 0
    while i < samples.count {
        let n = min(block, samples.count - i)
        samples.withUnsafeBufferPointer { session.append(UnsafeBufferPointer(rebasing: $0[i..<(i + n)])) }
        i += n
        if speed > 0 { try await Task.sleep(until: began + .seconds(Double(i) / Audio.sampleRate / speed), clock: clock) }
    }
    let joined = try await session.finish()
    let start = clock.now
    let whole = try await transcriber.transcribe(try Audio.load(url), options: whisper)
    let elapsed = (clock.now - start).components
    let wholeSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    let diff = wordEdits(whole.text, joined.text)
    print("audio \(f(Double(samples.count) / Audio.sampleRate)) s  stop-to-text live \(f(joined.seconds)) s  "
          + "whole-file \(f(wholeSeconds)) s")
    print("live vs whole-file: \(diff.edits) word edits over \(diff.words) words")
    let reference = url.deletingPathExtension().appendingPathExtension("txt")
    if let text = try? String(contentsOf: reference, encoding: .utf8) {
        let a = wordEdits(text, whole.text), b = wordEdits(text, joined.text)
        print("vs \(reference.lastPathComponent): whole-file \(a.edits), live \(b.edits) edits over \(a.words) words")
    }
    print("LIVE: \(joined.text)")
    print("WHOLE: \(whole.text)")
}

/// Word-level difference between two texts, as the edits to turn one into the other,
/// after lowercasing and dropping punctuation.
func wordEdits(_ reference: String, _ hypothesis: String) -> (edits: Int, words: Int) {
    func words(_ text: String) -> [Substring] {
        text.lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .split(separator: " ")
    }
    let a = words(reference), b = words(hypothesis)
    if a.isEmpty { return (b.count, 0) }
    var row = Array(0...b.count)
    for i in 1...a.count {
        var previous = row[0]
        row[0] = i
        for j in stride(from: 1, through: b.count, by: 1) {
            let current = row[j]
            row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
            previous = current
        }
    }
    return (row[b.count], a.count)
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let mid = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

struct FileResult: Codable {
    var name: String
    var seconds: Double
    var decodeSeconds: Double
    var decodePerAudioSecond: Double
    var referenceWords: Int
    var edits: Int
    var reference: String
    var whisper: String
    var flaggedSegments: Int
}

struct CleanupSample: Codable {
    var name: String
    var cold: Bool
    var seconds: Double
    var loadSeconds: Double
    var outputTokens: Int
    var before: String
    var after: String
}

/// A segment the smart-retries checker would look at again, by the thresholds in the spec.
func flagged(_ s: Segment) -> Bool {
    s.avgLogprob < -0.8 || s.compressionRatio > 2.4 || (s.wordsPerSecond > 0 && (s.wordsPerSecond < 0.8 || s.wordsPerSecond > 4.5))
}

@MainActor
func evaluate(_ dir: URL) async throws {
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let store = try Store(url: URL(fileURLWithPath: dbPath ?? dir.appending(path: "eval.sqlite").path))
    let pipeline = Pipeline(transcriber: transcriber, store: store)
    let loadSeconds = try await transcriber.load()
    FileHandle.standardError.write(Data("model loaded in \(String(format: "%.1f", loadSeconds)) s\n".utf8))

    var results: [FileResult] = []
    for file in files {
        let referenceURL = file.deletingPathExtension().appendingPathExtension("txt")
        guard let reference = try? String(contentsOf: referenceURL, encoding: .utf8) else { continue }
        let dictation = try await pipeline.run(file, whisper: whisper)
        let decode = Double(dictation.timings.transcribe ?? 0) / 1000
        let (edits, words) = wordEdits(reference, dictation.rawText)
        let result = FileResult(
            name: file.deletingPathExtension().lastPathComponent, seconds: dictation.duration,
            decodeSeconds: decode, decodePerAudioSecond: dictation.duration > 0 ? decode / dictation.duration : 0,
            referenceWords: words, edits: edits, reference: reference.trimmingCharacters(in: .whitespacesAndNewlines),
            whisper: dictation.rawText, flaggedSegments: dictation.segments.filter(flagged).count)
        results.append(result)
        FileHandle.standardError.write(Data(String(
            format: "%@  %5.1f s audio  %5.2f s decode  %.3f s/s  %d/%d words differ\n",
            result.name, result.seconds, decode, result.decodePerAudioSecond, edits, words).utf8))
    }

    var samples: [CleanupSample] = []
    if let cleanupCount, cleanupCount > 0 {
        // Spread across lengths, shortest to longest; the first runs cold.
        let byLength = results.sorted { $0.seconds < $1.seconds }
        let picks = (0..<min(cleanupCount, byLength.count)).map {
            byLength[cleanupCount == 1 ? byLength.count / 2 : $0 * (byLength.count - 1) / (cleanupCount - 1)]
        }
        let ollama = Ollama()
        await transcriber.unload()
        await ollama.unload(cleanup)
        for (i, pick) in picks.enumerated() {
            let result: CleanupResult
            do {
                result = try await ollama.cleanup(pick.whisper, settings: cleanup)
            } catch {
                FileHandle.standardError.write(Data("cleanup \(pick.name): \(error)\n".utf8))
                continue
            }
            samples.append(CleanupSample(name: pick.name, cold: i == 0, seconds: result.seconds,
                                         loadSeconds: result.loadSeconds, outputTokens: result.outputTokens,
                                         before: pick.whisper, after: result.text))
            FileHandle.standardError.write(Data(String(
                format: "cleanup %@ %@  %.1f s (load %.1f s, %d tokens)\n",
                pick.name, i == 0 ? "cold" : "warm", result.seconds, result.loadSeconds, result.outputTokens).utf8))
        }
    }

    let rates = results.map(\.decodePerAudioSecond)
    let worst = results.max { $0.decodePerAudioSecond < $1.decodePerAudioSecond }
    let edits = results.reduce(0) { $0 + $1.edits }, words = results.reduce(0) { $0 + $1.referenceWords }
    struct Summary: Codable {
        var files: Int
        var audioSeconds: Double
        var vad: Bool
        var modelLoadSeconds: Double
        var medianDecodePerAudioSecond: Double
        var worstDecodePerAudioSecond: Double
        var worstFile: String
        var wordDifferenceRate: Double
        var medianFileDifferenceRate: Double
        var identicalFiles: Int
        var flaggedSegments: Int
        var results: [FileResult]
        var cleanup: [CleanupSample]
    }
    let summary = Summary(
        files: results.count, audioSeconds: results.reduce(0) { $0 + $1.seconds }, vad: whisper.vad,
        modelLoadSeconds: loadSeconds, medianDecodePerAudioSecond: median(rates),
        worstDecodePerAudioSecond: worst?.decodePerAudioSecond ?? 0, worstFile: worst?.name ?? "",
        wordDifferenceRate: words > 0 ? Double(edits) / Double(words) : 0,
        medianFileDifferenceRate: median(results.map { $0.referenceWords > 0 ? Double($0.edits) / Double($0.referenceWords) : 0 }),
        identicalFiles: results.filter { $0.edits == 0 }.count,
        flaggedSegments: results.reduce(0) { $0 + $1.flaggedSegments },
        results: results, cleanup: samples)
    printJSON(summary)
}

struct ManifestEntry: Codable {
    var uid: String
    var wav: String
    var scored: Bool
    var context: String?
    /// Names this utterance's recording is known to contain, for --entry-terms.
    var terms: [String]?
}

struct BatchLine: Codable {
    var uid: String
    var text: String
    var prompt: String
    var beam: Int
    var duration: Double
    var decodeSeconds: Double
    var segments: [Segment]
    var retried: Int?
    var retrySeconds: Double?
}

struct CleanupLine: Codable {
    var uid: String
    var before: String
    var after: String
    var seconds: Double
    var loadSeconds: Double
    var outputTokens: Int
    var error: String?
}

/// The JSON lines a file already holds, decoded; an absent file holds none.
func readLines<T: Decodable>(_ url: URL, as type: T.Type) -> [T] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
    return text.split(separator: "\n").compactMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
}

func appendLine(_ value: some Encodable, to handle: FileHandle) throws {
    let lineEncoder = JSONEncoder()
    lineEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // A log probability can be -inf; JSON has no literal for it.
    lineEncoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
    try handle.write(contentsOf: lineEncoder.encode(value) + Data("\n".utf8))
}

func openForAppend(_ url: URL) throws -> FileHandle {
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    return handle
}

@MainActor
func batch(manifest: URL, output: URL) async throws {
    let base = manifest.deletingLastPathComponent()
    var entries = readLines(manifest, as: ManifestEntry.self)
    if scoredOnly { entries = entries.filter(\.scored) }
    if let uidsPath {
        let wanted = Set(try String(contentsOfFile: uidsPath, encoding: .utf8).split(separator: "\n").map(String.init))
        entries = entries.filter { wanted.contains($0.uid) }
    }
    let done = Set(readLines(output, as: BatchLine.self).map(\.uid))
    let context = Dictionary(
        readLines(contextPath.map { URL(fileURLWithPath: $0) } ?? output, as: BatchLine.self).map { ($0.uid, $0.text) },
        uniquingKeysWith: { first, _ in first })
    let handle = try openForAppend(output)
    defer { try? handle.close() }
    _ = try await transcriber.load()
    var count = 0
    for entry in entries where !done.contains(entry.uid) {
        if count >= maxItems { break }
        var options = whisper
        if contextPath != nil, let previous = entry.context.flatMap({ context[$0] }) {
            options.initialPrompt = previous
        }
        if entryTerms, let terms = entry.terms { options.keyTerms = terms }
        let samples = try Audio.load(base.appending(path: entry.wav))
        let transcript = try await transcriber.transcribe(samples, options: options)
        try appendLine(BatchLine(uid: entry.uid, text: transcript.text,
                                 prompt: ([options.keyTerms.joined(separator: ", ")] + [options.initialPrompt]).filter { !$0.isEmpty }.joined(separator: " | "),
                                 beam: options.beamSize, duration: Double(samples.count) / Audio.sampleRate,
                                 decodeSeconds: transcript.seconds, segments: transcript.segments,
                                 retried: transcript.retried, retrySeconds: transcript.retrySeconds), to: handle)
        count += 1
        if count % 50 == 0 {
            FileHandle.standardError.write(Data("\(count) of \(entries.count - done.count)\n".utf8))
        }
    }
    FileHandle.standardError.write(Data("batch: \(count) transcribed, \(done.count) already done\n".utf8))
    print(count)
}

@MainActor
func cleanupBatch(input: URL, output: URL) async throws {
    var lines = readLines(input, as: BatchLine.self)
    if let uidsPath {
        let wanted = Set(try String(contentsOfFile: uidsPath, encoding: .utf8).split(separator: "\n").map(String.init))
        lines = lines.filter { wanted.contains($0.uid) }
    }
    let done = Set(readLines(output, as: CleanupLine.self).map(\.uid))
    let handle = try openForAppend(output)
    defer { try? handle.close() }
    let ollama = Ollama()
    var count = 0
    for line in lines where !done.contains(line.uid) && !line.text.isEmpty {
        if count >= maxItems { break }
        do {
            let result = try await ollama.cleanup(line.text, settings: cleanup)
            try appendLine(CleanupLine(uid: line.uid, before: line.text, after: result.text, seconds: result.seconds,
                                       loadSeconds: result.loadSeconds, outputTokens: result.outputTokens), to: handle)
        } catch {
            try appendLine(CleanupLine(uid: line.uid, before: line.text, after: line.text, seconds: 0,
                                       loadSeconds: 0, outputTokens: 0, error: "\(error)"), to: handle)
        }
        count += 1
        if count % 25 == 0 {
            FileHandle.standardError.write(Data("\(count) cleaned\n".utf8))
        }
    }
    // Gives the model's memory back to the Mac as soon as the run ends.
    await ollama.unload(cleanup)
    FileHandle.standardError.write(Data("cleanup-batch: \(count) cleaned, \(done.count) already done\n".utf8))
    print(count)
}
