import Foundation
import Network

/// Lets an agent stop the call recording in progress and import files. Agents can't start a
/// recording: only a person does. The app provides it; dictate-cli can't record, so its server
/// has none.
public protocol RecordingControl: Sendable {
    func stopRecording() async throws -> Call
    /// Imports an audio or video file the router has already validated: the call comes back
    /// at once and is transcribed in the background.
    func importAudioFile(path: String) async throws -> CallRecorder.ImportStart
}

extension RecordingControl {
    /// For a host that doesn't import files, such as one that only records.
    public func importAudioFile(path: String) async throws -> CallRecorder.ImportStart {
        throw ToolError("Importing files is only available in the Dictate app.")
    }
}

public enum MCPServerError: Error, CustomStringConvertible {
    case portInUse(UInt16)
    case failed(String)
    /// The address isn't on any interface right now; start() retries before giving up.
    case addressNotAvailable(String)

    public var description: String {
        switch self {
        case .portInUse(let port): "Port \(port) is in use: Dictate or dictate-cli mcp is already serving it."
        case .failed(let message): "The MCP server couldn't start: \(message)"
        case .addressNotAvailable(let address): "The MCP server couldn't start: \(address) isn't available on this Mac."
        }
    }
}

/// MCP over Streamable HTTP, for agents to read calls and dictations: JSON-RPC posted to
/// /mcp on 127.0.0.1 unless another address is set, every request carrying the bearer
/// token. Each POST gets one JSON answer, with no event stream, which the spec leaves
/// optional; that keeps a 60 second wait_for_transcript on its own request without holding
/// up others. The session id only carries the client's name, for the edits it makes;
/// nothing is kept per session.
///
/// It is written on Network.framework rather than the MCP Swift SDK (0.12.1): the SDK's HTTP
/// server transports leave the listener to the host, so this would be needed anyway, and its
/// stateless transport matches each answer to its request by JSON-RPC id alone, so two
/// agents that send the same id at once would receive each other's answers.
public final class MCPServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 7766
    public static let endpointPath = "/mcp"

    private let router: MCPRouter
    private let token: Data
    private let requestedPort: UInt16
    private let host: String
    private let queue = DispatchQueue(label: "voice.mcp")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    /// `recordingUnavailable` is what stop_recording and import_audio_file answer when there
    /// is no `recording` to call. `keyTerms` is where the key-term tools read and write; with
    /// none they answer with an error. Their token counts use whisper.cpp's tokenizer on the
    /// speech model on disk unless `tokenizer` stands in for it.
    public init(store: CallStore, token: String, port: UInt16 = defaultPort, recording: (any RecordingControl)? = nil,
                recordingUnavailable: String = "Recording is only available in the Dictate app; this server runs from dictate-cli.",
                keyTerms: (any KeyTermsSettings)? = nil, tokenizer: (any PromptTokenizer)? = nil,
                version: String = "0", host: String = MCPEndpoint.defaultHost, disabledTools: Set<String> = []) {
        router = MCPRouter(store: store, recording: recording, recordingUnavailable: recordingUnavailable,
                           version: version,
                           keyTerms: keyTerms.map { KeyTermsEditor(settings: $0, tokenizer: tokenizer ?? WhisperTokenizer(),
                                                                   store: store) },
                           switches: ToolSwitches(disabled: disabledTools))
        self.host = host
        self.token = Data(token.utf8)
        requestedPort = port
    }

    /// The tools agents can't see or call, changed while the server runs.
    public var disabledTools: Set<String> {
        get { router.switches.disabled }
        set { router.switches.disabled = newValue }
    }

    /// The address the listener is bound to, once started.
    public private(set) var listenAddress: String?

    /// Listens on the one address it was given, 127.0.0.1 unless Settings says otherwise, and
    /// returns the port, which differs from the one asked for only when that was 0. A
    /// restart can bind while the old socket is still in TIME_WAIT, and an address whose
    /// interface isn't up yet (a VPN or Tailscale address at login) is retried for a few
    /// seconds instead of failing the first time.
    @discardableResult
    public func start(retryAddressFor seconds: Int = 10) async throws -> UInt16 {
        guard let address = MCPEndpoint.address(host: host), let ipv4 = IPv4Address(address) else {
            throw MCPServerError.failed("\(host) isn't an IPv4 address.")
        }
        var attempt = 0
        var busy = 0
        while true {
            do {
                let (listener, port) = try await bind(ipv4)
                queue.sync { self.listener = listener }
                listenAddress = address
                return port
            } catch MCPServerError.portInUse(let port) {
                // A restart's old listener closes a moment after stop() returns.
                busy += 1
                guard busy <= 6 else { throw MCPServerError.portInUse(port) }
                try await Task.sleep(for: .milliseconds(250))
            } catch MCPServerError.addressNotAvailable(let unavailable) {
                attempt += 1
                guard attempt <= seconds else { throw MCPServerError.failed("\(unavailable) isn't available on this Mac.") }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func bind(_ ipv4: IPv4Address) async throws -> (NWListener, UInt16) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(ipv4),
                                                     port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw MCPServerError.failed("\(error)")
        }
        let requestedPort = requestedPort
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(.success(listener.port?.rawValue ?? requestedPort))
                case .failed(let error), .waiting(let error):
                    if case .posix(let code) = error, code == .EADDRINUSE {
                        once.resume(.failure(MCPServerError.portInUse(requestedPort)))
                    } else if case .posix(let code) = error, code == .EADDRNOTAVAIL {
                        once.resume(.failure(MCPServerError.addressNotAvailable("\(ipv4)")))
                    } else {
                        once.resume(.failure(MCPServerError.failed("\(error)")))
                    }
                    listener.cancel()
                case .cancelled:
                    once.resume(.failure(MCPServerError.failed("stopped while starting")))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
        return (listener, port)
    }

    /// Stops listening and closes every connection, including requests still waiting.
    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.cancel() }
        }
    }

    private func accept(_ nw: NWConnection) {
        let connection = HTTPConnection(nw, queue: queue, respond: { [weak self] request in
            guard let self else { return .error(503, "The server is stopping.") }
            return await self.respond(request)
        }, onClose: { [weak self] connection in
            self?.connections[ObjectIdentifier(connection)] = nil
        })
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    func respond(_ request: HTTPRequest) async -> HTTPResponse {
        guard authorized(request) else {
            return .error(401, "Send the token from ~/Library/Application Support/Dictate/mcp-token as \"Authorization: Bearer <token>\".",
                          headers: [("WWW-Authenticate", "Bearer realm=\"dictate\"")])
        }
        guard request.path == Self.endpointPath || request.path == Self.endpointPath + "/" else {
            return .error(404, "The MCP endpoint is \(Self.endpointPath).")
        }
        // DNS rebinding: a web page can't read the token, but it shouldn't get to try either.
        if let origin = request.headers["origin"], !Self.allowed(origin: origin, host: request.headers["host"]) {
            return .error(403, "Origin \(origin) isn't allowed.")
        }
        guard request.method == "POST" else {
            // No server-to-client event stream (GET) and no sessions to end (DELETE).
            return .error(405, "POST JSON-RPC messages to \(Self.endpointPath).", headers: [("Allow", "POST")])
        }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            return .error(415, "Send Content-Type: application/json.")
        }
        if let version = request.headers["mcp-protocol-version"], !MCPRouter.protocolVersions.contains(version) {
            return .error(400, "Unsupported MCP-Protocol-Version \(version).")
        }
        // Clients send the session id initialize gave them; one that sends none is named by
        // its User-Agent instead.
        let client = request.headers["mcp-session-id"].flatMap(MCPRouter.client(session:))
            ?? request.headers["user-agent"].map { "user-agent \($0.prefix(100))" }
        let (status, body) = await router.handle(request.body, client: client)
        let session = MCPRouter.session(initializing: request.body).map { [("Mcp-Session-Id", $0)] } ?? []
        return body.map { HTTPResponse.json(status, $0, headers: session) } ?? HTTPResponse(status: status)
    }

    private func authorized(_ request: HTTPRequest) -> Bool {
        guard let header = request.headers["authorization"],
              header.count > 7, header.prefix(7).lowercased() == "bearer " else { return false }
        let given = Data(header.dropFirst(7).trimmingCharacters(in: .whitespaces).utf8)
        // Compares every byte, so the time taken doesn't say how much of a guess was right.
        guard given.count == token.count else { return false }
        return zip(given, token).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func allowed(origin: String, host: String?) -> Bool {
        guard let originHost = URLComponents(string: origin)?.host?.lowercased() else { return false }
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(originHost) { return true }
        let requestHost = host.flatMap { URLComponents(string: "http://\($0)")?.host?.lowercased() }
        return originHost == requestHost
    }
}

/// Resumes a continuation once, whichever listener state comes first.
private final class Once<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, any Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, any Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
