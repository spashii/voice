import XCTest
@testable import VoiceCore

/// The pipeline's own seams that need no whisper model: what it does before whisper runs,
/// and that a failure there leaves no half-written history row behind.
final class PipelineBeforeWhisperTests: XCTestCase {
    private var dir: URL!
    private var store: Store!

    override func setUpWithError() throws {
        dir = try makeTempDir(self)
        store = try Store(url: dir.appending(path: "voice.sqlite"))
    }

    private func pipeline(modelAt model: URL) -> Pipeline {
        Pipeline(transcriber: Transcriber(modelURL: model, vadModelURL: nil), store: store)
    }

    private func recording(seconds: Double = 1) throws -> URL {
        let url = dir.appending(path: "1700000000000.wav")
        try writeAudio(to: url, sampleRate: 16_000, channels: 1, frames: Int(16_000 * seconds), sample: sine(440, rate: 16_000))
        return url
    }

    func testAMissingRecordingThrowsBeforeAnythingIsStored() async throws {
        let pipeline = pipeline(modelAt: dir.appending(path: "model.bin"))

        do {
            _ = try await pipeline.run(dir.appending(path: "gone.wav"))
            XCTFail("expected an error")
        } catch {}

        XCTAssertEqual(store.audioPaths(), [])
    }

    func testAMissingWhisperModelIsReportedAndStoresNothing() async throws {
        let model = dir.appending(path: "ggml-missing.bin")
        let audio = try recording()

        do {
            _ = try await pipeline(modelAt: model).run(audio)
            XCTFail("expected an error")
        } catch VoiceError.whisper(let message) {
            XCTAssertEqual(message, "The whisper model isn't at \(model.path).")
        } catch {
            XCTFail("expected VoiceError.whisper, got \(error)")
        }

        XCTAssertEqual(store.audioPaths(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path), "a failure never touches the recording")
    }

    func testAModelFileThatIsNotAModelIsReportedAndStoresNothing() async throws {
        let model = try writeFile(Data("this is not a ggml file".utf8), named: "ggml-broken.bin", in: dir)
        let audio = try recording()

        do {
            _ = try await pipeline(modelAt: model).run(audio)
            XCTFail("expected an error")
        } catch VoiceError.whisper(let message) {
            XCTAssertEqual(message, "Whisper couldn't load ggml-broken.bin.")
        } catch {
            XCTFail("expected VoiceError.whisper, got \(error)")
        }

        XCTAssertEqual(store.audioPaths(), [])
    }

    func testTheFailingStageIsReportedAsTranscribing() async throws {
        nonisolated(unsafe) var stages: [String] = []
        let lock = NSLock()
        let audio = try recording()

        _ = try? await pipeline(modelAt: dir.appending(path: "none.bin")).run(audio, cleanup: CleanupSettings(ollamaURL: StubOllama.url)) { stage in
            lock.withLock { stages.append("\(stage)") }
        }

        XCTAssertEqual(lock.withLock { stages }, ["transcribing"], "cleanup is never reached when whisper fails")
    }

    func testStageTimesAreWholeMilliseconds() {
        XCTAssertEqual(Pipeline.ms(0), 0)
        XCTAssertEqual(Pipeline.ms(2), 2000)
        XCTAssertEqual(Pipeline.ms(0.4004), 400)
        XCTAssertEqual(Pipeline.ms(0.0004), 0)
        XCTAssertEqual(Pipeline.ms(1.2506), 1251)
    }
}

final class TranscriberHelperTests: XCTestCase {
    func testTextThatRepeatsItselfCompressesFarBeyondWhispersLimit() {
        let loop = String(repeating: "thank you for watching ", count: 40)

        XCTAssertGreaterThan(Transcriber.compressionRatio(loop), 2.4)
    }

    func testOrdinarySpeechStaysUnderWhispersLimit() {
        let text = "So the plan for the week is to finish the recovery tests, then look at how the history is pruned."

        let ratio = Transcriber.compressionRatio(text)

        XCTAssertGreaterThan(ratio, 0)
        XCTAssertLessThan(ratio, 2.4)
    }

    func testEmptyTextHasNoRatio() {
        XCTAssertEqual(Transcriber.compressionRatio(""), 0)
    }

    func testTheRatioIsTheSameEveryTime() {
        let text = "Repeatable, repeatable, repeatable results."

        XCTAssertEqual(Transcriber.compressionRatio(text), Transcriber.compressionRatio(text))
    }

    func testNonLatinTextHasARatio() {
        XCTAssertGreaterThan(Transcriber.compressionRatio("日本語のテキストです。日本語のテキストです。"), 0)
    }

    func testDurationsConvertToSeconds() {
        XCTAssertEqual(Duration.seconds(2).seconds, 2, accuracy: 1e-12)
        XCTAssertEqual(Duration.milliseconds(250).seconds, 0.25, accuracy: 1e-12)
        XCTAssertEqual(Duration.microseconds(1).seconds, 1e-6, accuracy: 1e-15)
        XCTAssertEqual(Duration.zero.seconds, 0)
    }

    func testAVADModelThatIsNotThereIsDropped() throws {
        let dir = try makeTempDir(self)
        let model = try writeFile(Data([1]), named: "ggml-x.bin", in: dir)
        let vad = try writeFile(Data([1]), named: "vad.bin", in: dir)

        XCTAssertNil(Transcriber(modelURL: model, vadModelURL: dir.appending(path: "no-vad.bin")).vadModelURL)
        XCTAssertEqual(Transcriber(modelURL: model, vadModelURL: vad).vadModelURL, vad)
        XCTAssertNil(Transcriber(modelURL: model, vadModelURL: nil).vadModelURL)
    }

    func testTheModelNameIsTheFileNameWithoutItsExtension() {
        let transcriber = Transcriber(modelURL: URL(fileURLWithPath: "/tmp/ggml-large-v3-turbo.bin"), vadModelURL: nil)

        XCTAssertEqual(transcriber.modelName, "ggml-large-v3-turbo")
    }

    func testTranscribingWithoutAModelThrowsInsteadOfCrashing() async {
        let transcriber = Transcriber(modelURL: URL(fileURLWithPath: "/nonexistent/ggml-none.bin"), vadModelURL: nil)

        do {
            _ = try await transcriber.transcribe([Float](repeating: 0, count: 16_000))
            XCTFail("expected an error")
        } catch VoiceError.whisper {
        } catch {
            XCTFail("expected VoiceError.whisper, got \(error)")
        }
        await transcriber.unload()
    }

    func testUnloadingATranscriberThatNeverLoadedIsFine() async {
        let transcriber = Transcriber(modelURL: URL(fileURLWithPath: "/nonexistent/ggml-none.bin"), vadModelURL: nil)

        await transcriber.unload()
        await transcriber.unload()
    }
}

final class ModelAndPathTests: XCTestCase {
    func testVoiceKeepsItsFilesUnderApplicationSupport() {
        let support = Paths.support.path

        XCTAssertTrue(support.hasSuffix("/Library/Application Support/Voice"), support)
        XCTAssertEqual(Paths.models.path, support + "/models")
        XCTAssertEqual(Paths.recordings.path, support + "/recordings")
        XCTAssertEqual(Paths.database.path, support + "/voice.sqlite")
        XCTAssertEqual(Paths.whisperModel.lastPathComponent, "ggml-large-v3-turbo.bin")
        XCTAssertTrue(Paths.vadModel.lastPathComponent.hasPrefix("ggml-silero"))
    }

    func testEveryWhisperModelHasAFileAndADownloadAddress() {
        XCTAssertEqual(WhisperModel.allCases.count, 2)
        for model in WhisperModel.allCases {
            XCTAssertEqual(model.id, model.rawValue)
            XCTAssertEqual(model.file.lastPathComponent, "\(model.rawValue).bin")
            XCTAssertEqual(model.url.lastPathComponent, "\(model.rawValue).bin")
            XCTAssertEqual(model.url.scheme, "https")
            XCTAssertGreaterThan(model.bytes, 1_000_000_000)
            XCTAssertFalse(model.title.isEmpty)
        }
        XCTAssertNotEqual(WhisperModel.largeV3.file, WhisperModel.largeV3Turbo.file)
        XCTAssertEqual(WhisperModel.largeV3Turbo.file, Paths.whisperModel)
    }

    func testTheLanguageListIsSortedByNameAndKnowsEnglishAndDutch() {
        let all = WhisperLanguages.all

        XCTAssertGreaterThan(all.count, 90)
        XCTAssertEqual(all.map(\.name), all.map(\.name).sorted())
        XCTAssertEqual(all.first { $0.code == "en" }?.name, "English")
        XCTAssertEqual(all.first { $0.code == "nl" }?.name, "Dutch")
        XCTAssertEqual(Set(all.map(\.code)).count, all.count, "codes are unique")
    }

    func testVoiceErrorsDescribeThemselvesWithTheirMessage() {
        XCTAssertEqual("\(VoiceError.audio("a"))", "a")
        XCTAssertEqual("\(VoiceError.whisper("w"))", "w")
        XCTAssertEqual("\(VoiceError.store("s"))", "s")
        XCTAssertEqual("\(VoiceError.cleanup("c"))", "c")
    }

    func testTooShortIsThreeTenthsOfASecond() {
        XCTAssertEqual(Dictation.tooShort, 0.3)
    }
}

/// The pipeline with a real whisper model and a stubbed Ollama, for what only the two
/// together show: that a failed cleanup still leaves whisper's words in the history.
///
/// Whisper needs a model file, so these run only when `VOICE_TEST_WHISPER_MODEL` points at
/// one (ggml-tiny.en.bin is enough, 75 MB). The speech is made with `say` writing to a
/// file, so nothing is played. Ollama is never contacted: its address does not resolve.
final class PipelineWithWhisperTests: StubbedOllamaTestCase {
    private var dir: URL!
    private var store: Store!
    private var transcriber: Transcriber!
    private let phrase = "Hello, this is a test of the dictation pipeline."

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICE_TEST_WHISPER_MODEL"], !path.isEmpty else {
            throw XCTSkip("Set VOICE_TEST_WHISPER_MODEL to a ggml whisper model, for example ggml-tiny.en.bin, to run the pipeline against whisper.")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("VOICE_TEST_WHISPER_MODEL points at \(path), which isn't there.")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/say") else {
            throw XCTSkip("/usr/bin/say makes the test speech and isn't here.")
        }
        dir = try makeTempDir(self)
        store = try Store(url: dir.appending(path: "voice.sqlite"))
        let transcriber = Transcriber(modelURL: URL(fileURLWithPath: path), vadModelURL: nil)
        self.transcriber = transcriber
        // ggml's Metal device asserts at exit while a model is still loaded.
        addTeardownBlock { await transcriber.unload() }
    }

    /// Speech as a 16 kHz mono WAV, written to a file by the system voice.
    private func speech(_ text: String? = nil, name: String = "1700000000000.wav") throws -> URL {
        let url = dir.appending(path: name)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEI16@16000", text ?? phrase]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0)
        return url
    }

    private func pipeline() -> Pipeline { Pipeline(transcriber: transcriber, store: store) }

    private func collectStages() -> (record: @Sendable (Pipeline.Stage) -> Void, read: () -> [String]) {
        nonisolated(unsafe) var stages: [String] = []
        let lock = NSLock()
        return ({ stage in lock.withLock { stages.append("\(stage)") } }, { lock.withLock { stages } })
    }

    func testAFailedCleanupStillPastesWhispersTextAndRecordsTheError() async throws {
        StubOllama.install(.failure(.cannotConnectToHost))
        let audio = try speech()
        let settings = settings(terms: ["Acme"])

        let dictation = try await pipeline().run(audio, cleanup: settings)

        XCTAssertTrue(dictation.rawText.lowercased().contains("test"), "whisper heard: \(dictation.rawText)")
        XCTAssertEqual(dictation.finalText, dictation.rawText, "the fallback is whisper's text, untouched")
        XCTAssertEqual(dictation.error, "Ollama isn't answering at \(StubOllama.url.absoluteString).")
        XCTAssertEqual(dictation.mode, .cleanup)
        XCTAssertEqual(dictation.cleanupModel, settings.model)
        XCTAssertEqual(dictation.cleanupSystem, settings.system)
        XCTAssertNil(dictation.timings.cleanup)

        let stored = try XCTUnwrap(store.recent(5).first)
        XCTAssertEqual(stored.id, dictation.id)
        XCTAssertEqual(stored.finalText, dictation.rawText)
        XCTAssertEqual(stored.error, dictation.error)
        XCTAssertEqual(stored.audioPath, audio.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(StubOllama.requests.count, 1)
        XCTAssertEqual(StubOllama.requests.first?.json["prompt"] as? String, dictation.rawText)
    }

    func testAnErrorStatusFromOllamaFallsBackTheSameWay() async throws {
        StubOllama.install(.json(status: 404, ["error": "model 'qwen3.5:9b' not found"]))

        let dictation = try await pipeline().run(try speech(), cleanup: settings())

        XCTAssertFalse(dictation.rawText.isEmpty)
        XCTAssertEqual(dictation.finalText, dictation.rawText)
        XCTAssertEqual(dictation.error, "Ollama: model 'qwen3.5:9b' not found")
    }

    func testAModelThatFailedOnTheGPUFallsBackTheSameWay() async throws {
        StubOllama.install(.json(["response": "", "done": false]))

        let dictation = try await pipeline().run(try speech(), cleanup: settings())

        XCTAssertEqual(dictation.finalText, dictation.rawText)
        XCTAssertNotNil(dictation.error)
    }

    func testAWorkingCleanupReplacesTheFinalTextAndKeepsWhispersAsRaw() async throws {
        StubOllama.install(.json(["response": "<think>fix it</think>Hello, this is a test.", "done": true,
                                  "load_duration": 0, "eval_count": 5, "prompt_eval_count": 9, "eval_duration": 1_000_000]))

        let dictation = try await pipeline().run(try speech(), cleanup: settings())

        XCTAssertEqual(dictation.finalText, "Hello, this is a test.")
        XCTAssertNotEqual(dictation.rawText, "")
        XCTAssertNil(dictation.error)
        XCTAssertNotNil(dictation.timings.cleanup)
        let stored = try XCTUnwrap(store.recent(5).first)
        XCTAssertEqual(stored.finalText, "Hello, this is a test.")
        XCTAssertEqual(stored.rawText, dictation.rawText)
    }

    func testAnEmptyCleanupAnswerKeepsWhispersText() async throws {
        StubOllama.install(.json(["response": "", "done": true]))

        let dictation = try await pipeline().run(try speech(), cleanup: settings())

        XCTAssertFalse(dictation.rawText.isEmpty)
        XCTAssertEqual(dictation.finalText, dictation.rawText)
        XCTAssertNil(dictation.error)
    }

    func testWithoutCleanupOllamaIsNeverAsked() async throws {
        StubOllama.install(.failure(.cannotConnectToHost))

        let dictation = try await pipeline().run(try speech())

        XCTAssertEqual(StubOllama.requests.count, 0)
        XCTAssertEqual(dictation.mode, .plain)
        XCTAssertNil(dictation.cleanupModel)
        XCTAssertNil(dictation.error)
        XCTAssertEqual(dictation.finalText, dictation.rawText)
        XCTAssertFalse(dictation.segments.isEmpty)
        XCTAssertEqual(dictation.duration, Double(try Audio.load(dictation.audioPath.asURL).count) / 16_000, accuracy: 1e-9)
    }

    func testStagesAreReportedInOrder() async throws {
        StubOllama.install(.json(["response": "Hi.", "done": true]))
        let withCleanup = collectStages()
        let plain = collectStages()

        _ = try await pipeline().run(try speech(), cleanup: settings(), onStage: withCleanup.record)
        _ = try await pipeline().run(try speech(name: "1700000001000.wav"), onStage: plain.record)

        XCTAssertEqual(withCleanup.read(), ["transcribing", "cleaningUp"])
        XCTAssertEqual(plain.read(), ["transcribing"])
    }

    func testARecordingWhoseHeaderCrashedIsTranscribedOnceRepaired() async throws {
        let audio = try speech()
        var bytes = try Data(contentsOf: audio)
        let chunk = try XCTUnwrap(findDataChunk(bytes), "say writes a data chunk")
        let frames = (bytes.count - chunk.start) / 2
        bytes.replaceSubrange(chunk.sizeOffset..<chunk.sizeOffset + 4, with: Data(count: 4))
        bytes.replaceSubrange(4..<8, with: Data(count: 4))
        try bytes.write(to: audio)

        let seconds = try XCTUnwrap(Recovery.repairHeader(audio))
        let dictation = try await pipeline().run(audio)

        XCTAssertEqual(seconds, Double(frames) / 16_000, accuracy: 1e-9)
        XCTAssertTrue(dictation.rawText.lowercased().contains("test"), "whisper heard: \(dictation.rawText)")
        XCTAssertEqual(dictation.duration, seconds, accuracy: 0.01)
    }
}

private extension String {
    var asURL: URL { URL(fileURLWithPath: self) }
}
