import Foundation
import Testing
@testable import VoiceCore

private func head(_ lines: [String]) -> Data {
    Data(((["POST /mcp HTTP/1.1", "Host: 127.0.0.1"] + lines).joined(separator: "\r\n") + "\r\n\r\n").utf8)
}

@Suite struct MCPLimitTests {
    private func router() throws -> MCPRouter {
        MCPRouter(store: try CallStore(url: temporaryCallDatabase()), recording: nil, recordingUnavailable: "",
                  version: "0")
    }

    private func pings(_ count: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: (0..<count).map { ["jsonrpc": "2.0", "id": $0, "method": "ping"] })
    }

    @Test func aBatchHoldsAtMostTen() async throws {
        let router = try router()
        let (ok, answers) = await router.handle(try pings(MCPRouter.maxBatch))
        #expect(ok == 200)
        #expect((try JSONSerialization.jsonObject(with: try #require(answers)) as? [Any])?.count == 10)

        let (status, body) = await router.handle(try pings(MCPRouter.maxBatch + 1))
        #expect(status == 400)
        let error = try JSONSerialization.jsonObject(with: try #require(body)) as? [String: Any]
        #expect((error?["error"] as? [String: Any])?["code"] as? Int == -32600)
    }

    @Test func withoutATokenALargeBodyIsRefusedBeforeItArrives() throws {
        var anonymous = HTTPParser()
        anonymous.buffer = head(["Content-Type: application/json", "Content-Length: \(64 * 1024 + 1)"])
        #expect(throws: HTTPParser.Failure.tooLarge) { try anonymous.next() }

        var chunked = HTTPParser()
        chunked.buffer = head(["Transfer-Encoding: chunked"]) + Data("10001\r\n".utf8)
            + Data(repeating: 0x20, count: 64 * 1024 + 1) + Data("\r\n0\r\n\r\n".utf8)
        #expect(throws: HTTPParser.Failure.tooLarge) { try chunked.next() }

        // With a token, the same length is read as usual.
        var authorized = HTTPParser()
        authorized.buffer = head(["Authorization: Bearer x", "Content-Length: \(64 * 1024 + 1)"])
        guard case .incomplete = try authorized.next() else {
            Issue.record("expected to wait for the body")
            return
        }

        var small = HTTPParser()
        small.buffer = head(["Content-Length: 2"]) + Data("{}".utf8)
        guard case .request(let request) = try small.next() else {
            Issue.record("expected a request")
            return
        }
        #expect(request.body == Data("{}".utf8))
    }
}
