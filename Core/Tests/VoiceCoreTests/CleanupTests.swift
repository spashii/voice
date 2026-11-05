import Darwin
import XCTest
@testable import VoiceCore

/// Stands in for Ollama. Requests to `StubOllama.host` never leave the process, and no test
/// uses a real Ollama address: the host does not resolve, so a stub that failed to register
/// would fail the test instead of reaching a model on this Mac.
final class StubOllama: URLProtocol, @unchecked Sendable {
    static let host = "ollama.stub.invalid"
    static let url = URL(string: "http://\(host):11434")!

    enum Reply {
        case json(status: Int = 200, [String: Any])
        case raw(status: Int, Data)
        case failure(URLError.Code)
    }

    struct Captured {
        var request: URLRequest
        var body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    nonisolated(unsafe) static var reply: Reply = .json([:])
    nonisolated(unsafe) static var captured: [Captured] = []
    private static let lock = NSLock()

    static func install(_ reply: Reply) {
        lock.withLock {
            self.reply = reply
            captured = []
        }
        URLProtocol.registerClass(StubOllama.self)
    }

    static func uninstall() {
        URLProtocol.unregisterClass(StubOllama.self)
        lock.withLock { captured = [] }
    }

    static var requests: [Captured] { lock.withLock { captured } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buffer, maxLength: 4096)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        } else if let direct = request.httpBody {
            body = direct
        }
        let reply = Self.lock.withLock { () -> Reply in
            Self.captured.append(Captured(request: request, body: body))
            return Self.reply
        }
        switch reply {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .json(let status, let object):
            send(status: status, data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        case .raw(let status, let data):
            send(status: status, data: data)
        }
    }

    private func send(status: Int, data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A finished Ollama reply, with nanosecond durations as Ollama writes them.
private func ollamaReply(_ text: String, done: Bool = true) -> [String: Any] {
    [
        "model": "qwen3.5:9b", "response": text, "done": done,
        "load_duration": 1_500_000_000, "prompt_eval_count": 42, "eval_count": 17,
        "eval_duration": 2_000_000_000, "total_duration": 4_000_000_000,
    ]
}

class StubbedOllamaTestCase: XCTestCase {
    override func tearDown() {
        StubOllama.uninstall()
        super.tearDown()
    }

    func settings(terms: [String] = [], temperature: Double = 0.2, model: String = "qwen3.5:9b",
                  prompt: String = CleanupSettings.defaultPrompt) -> CleanupSettings {
        CleanupSettings(ollamaURL: StubOllama.url, model: model, prompt: prompt, keyTerms: terms,
                        temperature: temperature)
    }

    /// The message of the cleanup error Ollama's step raised, or nil when it succeeded.
    func cleanupError(_ text: String = "hello", settings: CleanupSettings? = nil) async -> String? {
        do {
            _ = try await Ollama().cleanup(text, settings: settings ?? self.settings())
            return nil
        } catch VoiceError.cleanup(let message) {
            return message
        } catch {
            XCTFail("expected VoiceError.cleanup, got \(error)")
            return nil
        }
    }
}

final class CleanupSystemMessageTests: XCTestCase {
    func testWithoutKeyTermsTheSystemMessageIsThePromptAlone() {
        let settings = CleanupSettings(prompt: "Fix the text.")

        XCTAssertEqual(settings.system, "Fix the text.")
    }

    func testKeyTermsFollowThePromptAfterABlankLine() {
        let settings = CleanupSettings(prompt: "Fix the text.", keyTerms: ["Acme", "Globex", "Final Cut"])

        XCTAssertEqual(settings.system, "Fix the text.\n\nKey terms: Acme, Globex, Final Cut")
    }

    func testKeyTermsKeepTheirOrder() {
        let settings = CleanupSettings(prompt: "P", keyTerms: ["Zed", "Alpha", "Mid"])

        XCTAssertEqual(settings.system, "P\n\nKey terms: Zed, Alpha, Mid")
    }

    func testKeyTermsAreTrimmedAndBlankOnesDropped() {
        let settings = CleanupSettings(prompt: "P", keyTerms: ["  Acme ", "", "   ", "\tOllama\t", "Qwen"])

        XCTAssertEqual(settings.system, "P\n\nKey terms: Acme, Ollama, Qwen")
    }

    func testOnlyBlankKeyTermsLeaveNoKeyTermsLine() {
        let settings = CleanupSettings(prompt: "P", keyTerms: ["", "  ", "\t"])

        XCTAssertEqual(settings.system, "P")
    }

    func testTermsWithSpacesInsideStayWhole() {
        let settings = CleanupSettings(prompt: "P", keyTerms: ["Larkspur Labs"])

        XCTAssertEqual(settings.system, "P\n\nKey terms: Larkspur Labs")
    }

    func testTheDefaultSettingsUseTheDefaultPromptAndAskForLowTemperature() {
        let settings = CleanupSettings()

        XCTAssertEqual(settings.prompt, CleanupSettings.defaultPrompt)
        XCTAssertEqual(settings.system, CleanupSettings.defaultPrompt)
        XCTAssertEqual(settings.temperature, 0.2)
        XCTAssertEqual(settings.ollamaURL.absoluteString, "http://127.0.0.1:11434")
        XCTAssertEqual(settings.model, "qwen3.5:9b")
        XCTAssertTrue(settings.keyTerms.isEmpty)
    }

    func testTheDefaultPromptTellsTheModelToOutputOnlyTheText() {
        let prompt = CleanupSettings.defaultPrompt

        XCTAssertTrue(prompt.contains("Output only the corrected text."))
        XCTAssertTrue(prompt.contains("key terms"))
        XCTAssertFalse(prompt.contains("\\"), "the line continuations must not leak backslashes")
    }

    func testSettingsSurviveEncodingAndDecoding() throws {
        let settings = CleanupSettings(ollamaURL: URL(string: "http://example.test:1234")!, model: "m", prompt: "p",
                                       keyTerms: ["a", "b"], temperature: 0)

        let decoded = try JSONDecoder().decode(CleanupSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded, settings)
    }
}

final class OllamaRequestTests: StubbedOllamaTestCase {
    func testItPostsToApiGenerateWithAJSONBody() async throws {
        StubOllama.install(.json(ollamaReply("ok")))

        _ = try await Ollama().cleanup("hello there", settings: settings())

        let sent = try XCTUnwrap(StubOllama.requests.first)
        XCTAssertEqual(StubOllama.requests.count, 1)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.url?.path, "/api/generate")
        XCTAssertEqual(sent.request.url?.port, 11434)
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testTheBodyCarriesTheModelTheSystemMessageAndTheText() async throws {
        StubOllama.install(.json(ollamaReply("ok")))
        let s = settings(terms: ["Acme", "Globex"], model: "qwen3.5:27b", prompt: "Fix it.")

        _ = try await Ollama().cleanup("um hello acme", settings: s)

        let body = try XCTUnwrap(StubOllama.requests.first).json
        XCTAssertEqual(body["model"] as? String, "qwen3.5:27b")
        XCTAssertEqual(body["system"] as? String, "Fix it.\n\nKey terms: Acme, Globex")
        XCTAssertEqual(body["system"] as? String, s.system)
        XCTAssertEqual(body["prompt"] as? String, "um hello acme")
    }

    func testTheBodyAsksForOneUnthoughtReplyAndFreesTheModelAfterTwoMinutes() async throws {
        StubOllama.install(.json(ollamaReply("ok")))

        _ = try await Ollama().cleanup("x", settings: settings(temperature: 0.35))

        let body = try XCTUnwrap(StubOllama.requests.first).json
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["think"] as? Bool, false)
        XCTAssertEqual(body["keep_alive"] as? String, "2m")
        XCTAssertEqual((body["options"] as? [String: Any])?["temperature"] as? Double, 0.35)
    }

    func testTheTemperatureOfZeroIsSentAsZero() async throws {
        StubOllama.install(.json(ollamaReply("ok")))

        _ = try await Ollama().cleanup("x", settings: settings(temperature: 0))

        let options = try XCTUnwrap(StubOllama.requests.first).json["options"] as? [String: Any]
        XCTAssertEqual(options?["temperature"] as? Double, 0)
    }

    func testAColdModelGetsALongTimeout() async throws {
        StubOllama.install(.json(ollamaReply("ok")))

        _ = try await Ollama().cleanup("x", settings: settings())

        XCTAssertEqual(try XCTUnwrap(StubOllama.requests.first).request.timeoutInterval, 180)
    }

    func testTheDictationIsSentWordForWord() async throws {
        StubOllama.install(.json(ollamaReply("ok")))
        let text = "He said \"it's 5 o'clock\".\nNew line, tab\there, emoji \u{1F600}, \\backslash, café 日本語."

        _ = try await Ollama().cleanup(text, settings: settings())

        XCTAssertEqual(try XCTUnwrap(StubOllama.requests.first).json["prompt"] as? String, text)
    }

    func testATrailingSlashOnTheAddressDoesNotDoubleTheSlash() async throws {
        StubOllama.install(.json(ollamaReply("ok")))
        var s = settings()
        s.ollamaURL = URL(string: "http://\(StubOllama.host):11434/")!

        _ = try await Ollama().cleanup("x", settings: s)

        XCTAssertEqual(try XCTUnwrap(StubOllama.requests.first).request.url?.path, "/api/generate")
    }

    func testAnAddressOnAnotherPortIsUsedAsGiven() async throws {
        StubOllama.install(.json(ollamaReply("ok")))
        var s = settings()
        s.ollamaURL = URL(string: "http://\(StubOllama.host):9999")!

        _ = try await Ollama().cleanup("x", settings: s)

        XCTAssertEqual(try XCTUnwrap(StubOllama.requests.first).request.url?.port, 9999)
    }
}

final class OllamaReplyTests: StubbedOllamaTestCase {
    func testTheReplyTextAndTimingsAreRead() async throws {
        StubOllama.install(.json(ollamaReply("Hello there.")))

        let result = try await Ollama().cleanup("hello there", settings: settings())

        XCTAssertEqual(result.text, "Hello there.")
        XCTAssertEqual(result.loadSeconds, 1.5, accuracy: 1e-9)
        XCTAssertEqual(result.outputSeconds, 2.0, accuracy: 1e-9)
        XCTAssertEqual(result.promptTokens, 42)
        XCTAssertEqual(result.outputTokens, 17)
        XCTAssertGreaterThanOrEqual(result.seconds, 0)
        XCTAssertLessThan(result.seconds, 30)
    }

    func testMissingTimingsCountAsZero() async throws {
        StubOllama.install(.json(["response": "Fine.", "done": true]))

        let result = try await Ollama().cleanup("fine", settings: settings())

        XCTAssertEqual(result.text, "Fine.")
        XCTAssertEqual(result.loadSeconds, 0)
        XCTAssertEqual(result.promptTokens, 0)
        XCTAssertEqual(result.outputTokens, 0)
        XCTAssertEqual(result.outputSeconds, 0)
    }

    func testThinkingInsideTheReplyIsNotPasted() async throws {
        StubOllama.install(.json(ollamaReply("<think>the user said hello</think>\n\nHello.")))

        let result = try await Ollama().cleanup("hello", settings: settings())

        XCTAssertEqual(result.text, "Hello.")
    }

    func testTheReplyIsTrimmed() async throws {
        StubOllama.install(.json(ollamaReply("\n  Hello.  \n")))

        let result = try await Ollama().cleanup("hello", settings: settings())

        XCTAssertEqual(result.text, "Hello.")
    }

    func testAnEmptyReplyIsReturnedEmptySoTheCallerCanKeepWhispersText() async throws {
        StubOllama.install(.json(ollamaReply("")))

        let result = try await Ollama().cleanup("hello", settings: settings())

        XCTAssertEqual(result.text, "")
    }

    func testAReplyThatIsOnlyThinkingComesBackEmpty() async throws {
        StubOllama.install(.json(ollamaReply("<think>hmm</think>")))

        let result = try await Ollama().cleanup("hello", settings: settings())

        XCTAssertEqual(result.text, "")
    }

    // MARK: stripThinking

    func testStripThinkingRemovesEveryBlock() {
        XCTAssertEqual(Ollama.stripThinking("<think>a</think>One <think>b\nc</think>two"), "One two")
    }

    func testStripThinkingLeavesPlainTextAlone() {
        XCTAssertEqual(Ollama.stripThinking("Plain text, no tags."), "Plain text, no tags.")
        XCTAssertEqual(Ollama.stripThinking(""), "")
        XCTAssertEqual(Ollama.stripThinking("   \n"), "")
    }

    func testStripThinkingKeepsTextAroundAnUnclosedTag() {
        // Nothing marks where a thought that never closed ends, so nothing is cut.
        XCTAssertEqual(Ollama.stripThinking("Answer <think>unfinished"), "Answer <think>unfinished")
    }

    func testStripThinkingIgnoresACloseTagWithoutAnOpenOne() {
        XCTAssertEqual(Ollama.stripThinking("Answer </think> more"), "Answer </think> more")
    }

    func testStripThinkingKeepsAWordThatMentionsTheTag() {
        XCTAssertEqual(Ollama.stripThinking("The <think> tag opens a thought."), "The <think> tag opens a thought.")
    }
}

/// Every way the step can fail ends in `VoiceError.cleanup` and nothing else, which is what
/// lets the pipeline keep whisper's text and carry on.
final class OllamaFailureTests: StubbedOllamaTestCase {
    func testOllamaNotRunningNamesTheAddress() async {
        StubOllama.install(.failure(.cannotConnectToHost))

        let message = await cleanupError()

        XCTAssertEqual(message, "Ollama isn't answering at \(StubOllama.url.absoluteString).")
    }

    func testATimeoutIsTheSameFailure() async {
        StubOllama.install(.failure(.timedOut))

        let message = await cleanupError()

        XCTAssertEqual(message, "Ollama isn't answering at \(StubOllama.url.absoluteString).")
    }

    func testALostConnectionIsTheSameFailure() async {
        StubOllama.install(.failure(.networkConnectionLost))

        let message = await cleanupError()

        XCTAssertEqual(message, "Ollama isn't answering at \(StubOllama.url.absoluteString).")
    }

    func testAModelThatIsNotInstalledShowsOllamasOwnMessage() async {
        StubOllama.install(.json(status: 404, ["error": "model 'qwen3.5:27b' not found"]))

        let message = await cleanupError()

        XCTAssertEqual(message, "Ollama: model 'qwen3.5:27b' not found")
    }

    func testAServerErrorWithoutAMessageShowsItsStatus() async {
        StubOllama.install(.raw(status: 503, Data("Service Unavailable".utf8)))

        let message = await cleanupError()

        XCTAssertEqual(message, "Ollama: status 503")
    }

    func testAnErrorStatusWithAnEmptyBodyShowsItsStatus() async {
        StubOllama.install(.raw(status: 500, Data()))

        let message = await cleanupError()

        XCTAssertEqual(message, "Ollama: status 500")
    }

    func testARunnerThatFailedOnTheGPUAnswers200ButIsNotDone() async throws {
        StubOllama.install(.json(["model": "qwen3.5:9b", "response": "", "done": false]))

        let reported = await cleanupError()
        let message = try XCTUnwrap(reported)

        XCTAssertTrue(message.contains("failed to answer"), message)
        XCTAssertTrue(message.contains("server.log"), message)
    }

    func testAnUnfinishedReplyDoesNotLeakItsPartialText() async throws {
        StubOllama.install(.json(["response": "Half of the sen", "done": false]))

        let reported = await cleanupError()
        let message = try XCTUnwrap(reported)

        XCTAssertFalse(message.contains("Half of the sen"))
    }

    func testAReplyThatIsNotJSONIsAFailureNotACrash() async throws {
        StubOllama.install(.raw(status: 200, Data("<html>proxy page</html>".utf8)))

        let reported = await cleanupError()
        let message = try XCTUnwrap(reported)

        XCTAssertTrue(message.contains("failed to answer"), message)
    }

    func testAReplyWithNoDoneFlagIsNotTrusted() async throws {
        StubOllama.install(.json(["response": "Maybe finished"]))

        let message = await cleanupError()
        XCTAssertNotNil(message)
    }

    func testAnEmptyBodyOn200IsAFailure() async throws {
        StubOllama.install(.raw(status: 200, Data()))

        let message = await cleanupError()
        XCTAssertNotNil(message)
    }

    func testAJSONArrayInPlaceOfAnObjectIsAFailure() async throws {
        StubOllama.install(.raw(status: 200, Data("[1, 2, 3]".utf8)))

        let message = await cleanupError()
        XCTAssertNotNil(message)
    }

    func testAnErrorMessageThatIsNotAStringFallsBackToTheStatus() async {
        StubOllama.install(.json(status: 400, ["error": 42]))

        let message = await cleanupError()

        XCTAssertEqual(message, "Ollama: status 400")
    }

    func testNothingListeningOnAPortIsReportedAsNotAnswering() async throws {
        // A real connection refused, on a port that was free a moment ago. It is never 11434.
        let port = try freeLoopbackPort()
        XCTAssertNotEqual(port, 11434)
        var s = settings()
        s.ollamaURL = URL(string: "http://127.0.0.1:\(port)")!

        let message = await cleanupError(settings: s)

        XCTAssertEqual(message, "Ollama isn't answering at http://127.0.0.1:\(port).")
    }

    /// Binds a loopback socket to port 0, reads the port the system chose and closes it.
    private func freeLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        XCTAssertEqual(named, 0)
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// The models list Settings shows.
final class OllamaInstalledModelsTests: StubbedOllamaTestCase {
    func testTheInstalledModelsAreListedByNameInOrder() async throws {
        StubOllama.install(.json(["models": [["name": "qwen3.5:9b"], ["name": "gemma3:4b"], ["name": "llama3:8b"]]]))

        let names = try await Ollama().installedModels(at: StubOllama.url)

        XCTAssertEqual(names, ["gemma3:4b", "llama3:8b", "qwen3.5:9b"])
        let sent = try XCTUnwrap(StubOllama.requests.first)
        XCTAssertEqual(sent.request.url?.path, "/api/tags")
        XCTAssertEqual(sent.request.timeoutInterval, 3)
    }

    func testAnEmptyListIsAnEmptyList() async throws {
        StubOllama.install(.json(["models": [[String: Any]]()]))

        let names = try await Ollama().installedModels(at: StubOllama.url)

        XCTAssertEqual(names, [])
    }

    func testEntriesWithoutANameAreSkipped() async throws {
        StubOllama.install(.json(["models": [["name": "a"], ["size": 1], ["name": "b"]]]))

        let names = try await Ollama().installedModels(at: StubOllama.url)

        XCTAssertEqual(names, ["a", "b"])
    }

    func testAnAnswerWithoutAModelListThrows() async {
        StubOllama.install(.json(["version": "0.1"]))

        do {
            _ = try await Ollama().installedModels(at: StubOllama.url)
            XCTFail("expected an error")
        } catch VoiceError.cleanup(let message) {
            XCTAssertEqual(message, "Ollama answered without a model list.")
        } catch {
            XCTFail("expected VoiceError.cleanup, got \(error)")
        }
    }

    func testAnErrorStatusThrows() async {
        StubOllama.install(.raw(status: 500, Data()))

        do {
            _ = try await Ollama().installedModels(at: StubOllama.url)
            XCTFail("expected an error")
        } catch VoiceError.cleanup {
        } catch {
            XCTFail("expected VoiceError.cleanup, got \(error)")
        }
    }

    func testOllamaNotRunningThrows() async {
        StubOllama.install(.failure(.cannotConnectToHost))

        do {
            _ = try await Ollama().installedModels(at: StubOllama.url)
            XCTFail("expected an error")
        } catch {
            // The caller only needs to know it isn't running.
        }
    }
}
