import Foundation
import Security

/// The secret agents send as "Authorization: Bearer <token>". Every request needs it, from
/// this Mac too: anything local can reach 127.0.0.1, and the tailnet reaches it through
/// Tailscale Serve, which arrives from 127.0.0.1 as well.
public enum MCPToken {
    public static var file: URL { Paths.support.appending(path: "mcp-token") }

    /// Reads the token, making one on first run: 32 random bytes in hex, in a file only this
    /// user can read. Delete the file to make a new one; agents then need the new token.
    public static func load(from url: URL = file) throws -> String {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let token = try read(url) { return token }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw VoiceError.store("Couldn't make a random token.")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        // O_EXCL: when the app and voice-cli start together, one writes the token and the
        // other reads it, instead of each keeping a different one.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            guard errno == EEXIST else { throw VoiceError.store("Can't create \(url.path).") }
            for _ in 0..<20 {
                if let token = try read(url) { return token }
                usleep(50_000)
            }
            throw VoiceError.store("\(url.path) doesn't hold a token; delete it to make a new one.")
        }
        defer { close(fd) }
        let line = Array((token + "\n").utf8)
        guard write(fd, line, line.count) == line.count else { throw VoiceError.store("Can't write \(url.path).") }
        return token
    }

    /// The token in the file, or nil when there is no file or it is still being written.
    private static func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let token = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count == 64, token.allSatisfy(\.isHexDigit) else { return nil }
        // Keeps it private even if something loosened the mode.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }
}
