import Foundation
import Network

/// Lets an agent start and stop recording a call. The app provides it once it records calls;
/// voice-cli can't record, so its server has none.
public protocol RecordingControl: Sendable {
    func startRecording(title: String?) async throws -> Call
    func stopRecording() async throws -> Call
}

public enum MCPServerError: Error, CustomStringConvertible {
    case portInUse(UInt16)
    case failed(String)

    public var description: String {
        switch self {
        case .portInUse(let port): "Port \(port) is in use: Voice or voice-cli mcp is already serving it."
        case .failed(let message): "The MCP server couldn't start: \(message)"
        }
    }
}

/// MCP over Streamable HTTP, for agents to read calls and dictations: JSON-RPC posted to
/// /mcp on 127.0.0.1, every request carrying the bearer token. Each POST gets one JSON
/// answer, with no event stream, which the spec leaves optional; that keeps a 60 second
/// wait_for_transcript on its own request without holding up others. The session id only
/// carries the client's name, for the edits it makes; nothing is kept per session.
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
    private let queue = DispatchQueue(label: "voice.mcp")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    /// `recordingUnavailable` is what start_recording and stop_recording answer when there
    /// is no `recording` to call. `keyTerms` is where the key-term tools read and write; with
    /// none they answer with an error. Their token counts use whisper.cpp's tokenizer on the
    /// speech model on disk unless `tokenizer` stands in for it.
    public init(store: CallStore, token: String, port: UInt16 = defaultPort, recording: (any RecordingControl)? = nil,
                recordingUnavailable: String = "Recording is only available in the Voice app; this server runs from voice-cli.",
                keyTerms: (any KeyTermsSettings)? = nil, tokenizer: (any PromptTokenizer)? = nil,
                version: String = "0") {
        router = MCPRouter(store: store, recording: recording, recordingUnavailable: recordingUnavailable,
                           version: version,
                           keyTerms: keyTerms.map { KeyTermsEditor(settings: $0, tokenizer: tokenizer ?? WhisperTokenizer(),
                                                                   store: store) })
        self.token = Data(token.utf8)
        requestedPort = port
    }

    /// Listens on 127.0.0.1 only and returns the port, which differs from the one asked for
    /// only when that was 0.
    @discardableResult
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
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
        queue.sync { self.listener = listener }
        return port
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
            return .error(401, "Send the token from ~/Library/Application Support/Voice/mcp-token as \"Authorization: Bearer <token>\".",
                          headers: [("WWW-Authenticate", "Bearer realm=\"voice\"")])
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
