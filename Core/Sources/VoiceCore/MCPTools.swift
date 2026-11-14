import Foundation

/// The tools a person has turned off in Settings. An agent neither sees a disabled tool in
/// tools/list nor can call it. The router reads this on every request, so a change applies
/// to connected agents without restarting the server.
public final class ToolSwitches: @unchecked Sendable {
    private let lock = NSLock()
    private var off: Set<String>

    public init(disabled: Set<String> = []) {
        off = disabled
    }

    public var disabled: Set<String> {
        get { lock.withLock { off } }
        set { lock.withLock { off = newValue } }
    }

    func isOn(_ name: String) -> Bool {
        lock.withLock { !off.contains(name) }
    }
}

/// A tool as Settings lists it.
public struct MCPToolInfo: Sendable, Equatable, Identifiable {
    public var name: String
    /// The first sentence of the tool's description.
    public var summary: String

    public var id: String { name }
}

extension MCPServer {
    /// The tools that stop a recording or change stored data. They are off until a person
    /// turns them on: what the other side of a call says is read by a connected agent, and
    /// could be written to steer it.
    public static let offByDefault: Set<String> = [
        "stop_recording", "correct_dictation", "correct_segment",
        "add_key_terms", "remove_key_terms", "tag_call", "undo_edit", "set_recording_title",
        "import_audio_file",
    ]

    /// Every tool the server offers, in the order tools/list gives them.
    public static var toolCatalog: [MCPToolInfo] {
        MCPRouter.tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            let description = tool["description"] as? String ?? ""
            let first = description.firstIndex(of: ".").map { String(description[..<$0]) } ?? description
            return MCPToolInfo(name: name, summary: first + ".")
        }
    }
}

/// Where the server listens, as a person types it in Settings.
public enum MCPEndpoint {
    /// "localhost" or an IPv4 address; nil for anything else. Not a host name: the server binds
    /// to one address, and a name could resolve to several.
    public static func address(host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "localhost" { return "127.0.0.1" }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) && Int($0)! <= 255 })
        else { return nil }
        return parts.map { String(Int($0)!) }.joined(separator: ".")
    }

    /// A port above the ones only root can open.
    public static func port(_ text: String) -> UInt16? {
        guard let value = UInt16(text.trimmingCharacters(in: .whitespaces)), value >= 1024 else { return nil }
        return value
    }

    public static let defaultHost = "127.0.0.1"

    /// What to tell a person who sets an address other than this Mac's own: the token is sent
    /// in clear text over plain HTTP, so anyone on that network path can read it.
    public static func exposureWarning(host: String) -> String? {
        guard let address = address(host: host), !address.hasPrefix("127.") else { return nil }
        return "\(address == "0.0.0.0" ? "0.0.0.0 listens on every network this Mac is on" : "\(address) is not this Mac's own address"). The token travels unencrypted, so use it only on a network you trust."
    }
}

/// What to give an agent app so it can connect: the URL, a JSON config for apps that take one,
/// and the Claude Code command.
public struct MCPSetup: Sendable, Equatable {
    public var url: String
    public var json: String
    public var command: String
    /// A message to paste into an agent, saying what to install and how. Holds the token.
    public var message: String

    /// `token` is written as it is, so pass "<token>" for text shown on screen and the real one
    /// for text that is copied. A server bound to 0.0.0.0 is reached on 127.0.0.1 from this Mac.
    public init(host: String, port: UInt16, token: String) {
        let reach = host == "0.0.0.0" ? "127.0.0.1" : host
        url = "http://\(reach):\(port)\(MCPServer.endpointPath)"
        json = """
            {
              "mcpServers": {
                "dictate": {
                  "type": "http",
                  "url": "\(url)",
                  "headers": { "Authorization": "Bearer \(token)" }
                }
              }
            }
            """
        command = "claude mcp add --transport http --scope user dictate \(url) --header \"Authorization: Bearer \(token)\""
        message = """
            Please connect to my Dictate app, which keeps my dictations and call transcripts on this Mac. It is an MCP server.

            Server URL: \(url)
            Header: Authorization: Bearer \(token)

            In Claude Code, run this command:
            \(command)

            In any other agent app, add the server to its MCP settings with this JSON:
            \(json)

            Then start a new session, so the Dictate tools appear.
            """
    }

    /// The JSON, then the command, as one block to paste.
    public var copied: String { json + "\n\n" + command }
}
