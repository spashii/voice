import AppKit
import Observation
import SwiftUI
import VoiceCore

/// The MCP server agents read dictations and call transcripts through, hosted while Voice
/// runs. voice-cli mcp serves the same thing when Voice isn't running; only one of them can
/// hold the port.
@MainActor @Observable
final class AgentAccess {
    enum Status: Equatable {
        case off
        case starting
        case on
        case failed(String)
    }

    /// On by default: an agent also needs the token, and nothing reaches the server from
    /// another device unless Tailscale Serve is set up to forward to it.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "agentAccess")
            apply()
        }
    }
    private(set) var status: Status = .off
    /// Where devices on the tailnet reach the server, when Tailscale Serve forwards to it.
    private(set) var tailnetAddress: String?
    let localAddress = "http://127.0.0.1:\(MCPServer.defaultPort)\(MCPServer.endpointPath)"

    /// What start_recording and stop_recording go through; set before launch.
    @ObservationIgnored var recording: (any RecordingControl)?
    /// Where agents' key-term changes go: Preferences, so Settings shows them as they land.
    @ObservationIgnored var keyTerms: (any KeyTermsSettings)?
    @ObservationIgnored private var server: MCPServer?
    /// Counts starts and stops, so a start that finishes after the switch moved again is dropped.
    @ObservationIgnored private var generation = 0

    init() {
        enabled = UserDefaults.standard.object(forKey: "agentAccess") as? Bool ?? true
    }

    func launch() {
        apply()
    }

    func copyToken() {
        guard let token = try? MCPToken.load() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
    }

    func refreshTailnet() async {
        tailnetAddress = await Task.detached(priority: .utility) { Self.servedAddress() }.value
    }

    private func apply() {
        generation += 1
        let current = generation
        server?.stop()
        server = nil
        guard enabled else {
            status = .off
            return
        }
        status = .starting
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let recording = recording
        let keyTerms = keyTerms
        Task {
            do {
                // Opening the store can migrate the database; that stays off the main thread.
                let server = try await Task.detached {
                    MCPServer(store: try CallStore(url: Paths.database), token: try MCPToken.load(),
                              recording: recording, keyTerms: keyTerms, version: version)
                }.value
                try await server.start()
                guard current == generation else { return server.stop() }
                self.server = server
                status = .on
            } catch {
                guard current == generation else { return }
                status = .failed("\(error)")
            }
        }
    }

    /// https://<this Mac's tailnet name>:<port>/mcp when Tailscale Serve forwards that port
    /// to the server, else nil.
    nonisolated private static func servedAddress() -> String? {
        let cli = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        guard FileManager.default.isExecutableFile(atPath: cli),
              let data = run(cli, ["serve", "status", "--json"]),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = config["Web"] as? [String: Any] else { return nil }
        let target = "127.0.0.1:\(MCPServer.defaultPort)"
        for (hostPort, site) in web {
            let handlers = (site as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]
            for (path, handler) in handlers {
                guard let proxy = (handler as? [String: Any])?["Proxy"] as? String, proxy.contains(target) else { continue }
                let base = path.hasSuffix("/") ? String(path.dropLast()) : path
                return "https://\(hostPort)\(base)\(MCPServer.endpointPath)"
            }
        }
        return nil
    }

    /// A command's output, or nil when it fails or takes longer than five seconds.
    nonisolated private static func run(_ path: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

/// The General row in Settings: the switch, both addresses and the token.
struct AgentAccessRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var agents = model.agents
        Toggle("Agents can read transcripts", isOn: $agents.enabled)
        Text("Claude Code and other agents read your dictations and call transcripts over MCP, with the token.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if agents.enabled {
            LabeledContent("This Mac") {
                Text(agents.localAddress).textSelection(.enabled)
            }
            LabeledContent("Tailnet") {
                Text(agents.tailnetAddress ?? "Not served").textSelection(.enabled)
            }
            LabeledContent(statusText) {
                Button("Copy token") { agents.copyToken() }
            }
            .task { await agents.refreshTailnet() }
        }
    }

    private var statusText: String {
        switch model.agents.status {
        case .off: "Off"
        case .starting: "Starting"
        case .on: "Running"
        case .failed(let message): message
        }
    }
}
