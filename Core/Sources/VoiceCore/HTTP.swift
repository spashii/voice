import Foundation
import Network

/// Just enough HTTP/1.1 for MCP's one endpoint: requests with a body by length or in
/// chunks, keep-alive, and one JSON answer each.
struct HTTPRequest: Sendable {
    var method: String
    /// The path without its query string.
    var path: String
    /// Names in lowercase; repeated headers joined with commas.
    var headers: [String: String]
    var body: Data
    var keepAlive: Bool
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [(String, String)] = []
    var body: Data = Data()

    static func json(_ status: Int, _ body: Data, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers, body: body)
    }

    /// An error for a client that isn't speaking JSON-RPC yet, as a small JSON object.
    static func error(_ status: Int, _ message: String, headers: [(String, String)] = []) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return json(status, body, headers: headers)
    }

    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }
}

struct HTTPParser {
    enum Outcome {
        case request(HTTPRequest)
        /// More bytes are needed. `expectsContinue` once the headers are in and the client
        /// waits for "100 Continue" before sending the body, as curl does with larger ones.
        case incomplete(expectsContinue: Bool)
    }

    enum Failure: Error {
        case malformed
        case tooLarge
    }

    static let maxHead = 64 * 1024
    static let maxBody = 4 * 1024 * 1024
    /// Without a token the answer is 401 whatever the body says, so there is no reason to
    /// take in more than this from whoever is asking.
    static let maxBodyWithoutToken = 64 * 1024

    var buffer = Data()

    /// Takes the next whole request off the front of the buffer.
    mutating func next() throws -> Outcome {
        guard let headEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHead { throw Failure.tooLarge }
            return .incomplete(expectsContinue: false)
        }
        let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { throw Failure.malformed }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }

        let bodyStart = headEnd.upperBound
        let limit = headers["authorization"] == nil ? Self.maxBodyWithoutToken : Self.maxBody
        let body: Data
        let end: Data.Index
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let (decoded, after) = try Self.dechunk(buffer, from: bodyStart, limit: limit) else {
                return .incomplete(expectsContinue: Self.expectsContinue(headers))
            }
            body = decoded
            end = after
        } else {
            guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { throw Failure.malformed }
            guard length <= limit else { throw Failure.tooLarge }
            guard buffer.endIndex - bodyStart >= length else {
                return .incomplete(expectsContinue: Self.expectsContinue(headers))
            }
            body = buffer[bodyStart..<bodyStart + length]
            end = bodyStart + length
        }

        var target = String(start[1])
        // A proxy may send the absolute form, http://host/mcp.
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            target = URLComponents(string: target)?.path ?? target
        }
        let path = String(target.prefix { $0 != "?" && $0 != "#" })
        let connection = headers["connection"]?.lowercased() ?? ""
        let keepAlive = start[2] == "HTTP/1.1" ? !connection.contains("close") : connection.contains("keep-alive")
        buffer = Data(buffer[end...])
        return .request(HTTPRequest(method: String(start[0]).uppercased(), path: path, headers: headers,
                                    body: Data(body), keepAlive: keepAlive))
    }

    private static func expectsContinue(_ headers: [String: String]) -> Bool {
        headers["expect"]?.lowercased() == "100-continue"
    }

    /// The body of a chunked request and where it ends, or nil until the last chunk is in.
    private static func dechunk(_ data: Data, from start: Data.Index, limit: Int) throws -> (Data, Data.Index)? {
        var body = Data()
        var at = start
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data[at...].firstRange(of: crlf) else { return nil }
            let line = String(decoding: data[at..<lineEnd.lowerBound], as: UTF8.self)
            guard let size = Int(line.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0 else { throw Failure.malformed }
            at = lineEnd.upperBound
            if size == 0 {
                // Trailers, if any, then the blank line that ends the message.
                while true {
                    guard let trailerEnd = data[at...].firstRange(of: crlf) else { return nil }
                    let empty = trailerEnd.lowerBound == at
                    at = trailerEnd.upperBound
                    if empty { return (body, at) }
                }
            }
            guard body.count + size <= limit else { throw Failure.tooLarge }
            guard data.endIndex - at >= size + 2 else { return nil }
            body.append(data[at..<at + size])
            at += size + 2
        }
    }
}

/// One client's TCP connection: reads a request, answers it, then reads the next. Every
/// change to its state runs on the server's queue.
final class HTTPConnection: @unchecked Sendable {
    /// A connection with no request in flight is closed after this long.
    static let idleTimeout: TimeInterval = 120

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let respond: @Sendable (HTTPRequest) async -> HTTPResponse
    private let onClose: @Sendable (HTTPConnection) -> Void
    private var parser = HTTPParser()
    private var sentContinue = false
    private var idle: DispatchWorkItem?
    private var closed = false
    private var receiving = false
    /// The request being answered. Closing the connection cancels it, so a client that goes
    /// away mid wait_for_transcript doesn't leave the wait running.
    private var inFlight: Task<Void, Never>?

    init(_ connection: NWConnection, queue: DispatchQueue, respond: @escaping @Sendable (HTTPRequest) async -> HTTPResponse,
         onClose: @escaping @Sendable (HTTPConnection) -> Void) {
        self.connection = connection
        self.queue = queue
        self.respond = respond
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        queue.async { self.close() }
    }

    private func receive() {
        guard !closed else { return }
        if inFlight == nil { armIdleTimer() }
        guard !receiving else { return }
        receiving = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.receiving = false
            if let data { self.parser.buffer.append(data) }
            guard error == nil else { return self.close() }
            guard self.inFlight == nil else {
                // Mid-request, reading only watches for the client leaving. A pipelined
                // request waits in the buffer, and past a head's worth reading pauses.
                if isComplete {
                    self.close()
                } else if self.parser.buffer.count <= HTTPParser.maxHead {
                    self.receive()
                }
                return
            }
            self.process(peerClosed: isComplete)
        }
    }

    private func process(peerClosed: Bool) {
        guard !closed else { return }
        do {
            switch try parser.next() {
            case .request(let request):
                idle?.cancel()
                sentContinue = false
                inFlight = Task {
                    let response = await self.respond(request)
                    self.queue.async {
                        self.inFlight = nil
                        self.send(response, keepAlive: request.keepAlive && !peerClosed)
                    }
                }
                // A client that sent its request and closed its side still gets the answer.
                if !peerClosed { receive() }
            case .incomplete(let expectsContinue):
                guard !peerClosed else { return close() }
                if expectsContinue, !sentContinue {
                    sentContinue = true
                    connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
                }
                receive()
            }
        } catch {
            let status = error as? HTTPParser.Failure == .tooLarge ? 413 : 400
            send(.error(status, status == 413 ? "Request too large." : "Malformed HTTP request."), keepAlive: false)
        }
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool) {
        guard !closed else { return }
        connection.send(content: response.serialized(keepAlive: keepAlive), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if keepAlive, error == nil {
                // A client may have sent its next request already.
                self.process(peerClosed: false)
            } else {
                self.close()
            }
        })
    }

    private func armIdleTimer() {
        idle?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.close() }
        idle = item
        queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: item)
    }

    private func close() {
        guard !closed else { return }
        closed = true
        idle?.cancel()
        inFlight?.cancel()
        inFlight = nil
        connection.cancel()
        onClose(self)
    }
}
