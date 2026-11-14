import AppKit
import Observation
import SwiftUI
import VoiceCore

/// The MCP server agents read dictations and call transcripts through, hosted while Dictate
/// runs. dictate-cli mcp serves the same thing when Dictate isn't running; only one of them can
/// hold the port.
@MainActor @Observable
final class AgentAccess {
    enum Status: Equatable {
        case off
        case starting
        case on
        case failed(String)
    }

    /// Off for a new install; the app settles it at launch (AgentSettings.settleAccess), so an
    /// install that had it on stays on. A development build never defaults on: it would fight
    /// the installed app for the port.
    var enabled: Bool {
        didSet {
            #if DEBUG
            if snapshotHeld { return }
            #endif
            UserDefaults.standard.set(enabled, forKey: AgentSettings.accessKey)
            apply()
        }
    }
    private(set) var status: Status = .off
    private(set) var host: String
    private(set) var port: UInt16
    /// The tools an agent can't see or call. Changes reach a running server at once.
    private(set) var disabledTools: Set<String>
    /// The current token, read when Settings needs it.
    private(set) var token: String?

    /// What stop_recording and import_audio_file go through; set before launch.
    @ObservationIgnored var recording: (any RecordingControl)?
    /// Where agents' key-term changes go: Preferences, so Settings shows them as they land.
    @ObservationIgnored var keyTerms: (any KeyTermsSettings)?
    @ObservationIgnored private var server: MCPServer?
    /// Counts starts and stops, so a start that finishes after the switch moved again is dropped.
    @ObservationIgnored private var generation = 0

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: AgentSettings.accessKey) as? Bool ?? false
        host = defaults.string(forKey: "agentHost").flatMap(MCPEndpoint.address(host:)) ?? MCPEndpoint.defaultHost
        port = (defaults.object(forKey: "agentPort") as? Int).flatMap { UInt16(exactly: $0) } ?? MCPServer.defaultPort
        // An explicit choice, even all on, is kept; the new-install defaults apply only to a Mac
        // that never ran Dictate (AppDelegate settles that before anything else starts).
        disabledTools = AgentSettings.disabledTools(in: defaults, existingInstall: true)
        token = try? MCPToken.load()
    }

    #if DEBUG
    @ObservationIgnored private var snapshotHeld = false

    /// The app-shots run shows the pane with the server on and a fresh install's tool switches,
    /// held in memory: nothing is stored, no server starts and no real token is shown.
    func holdForSnapshots() {
        snapshotHeld = true
        enabled = true
        disabledTools = MCPServer.offByDefault
        token = "shots-token-0000"
    }
    #endif

    /// The server runs only while Dictate may record; set by the lock.
    @ObservationIgnored private var unlocked = false

    func launch() {
        apply()
    }

    func setUnlocked(_ on: Bool) {
        guard on != unlocked else { return }
        unlocked = on
        apply()
    }

    var localAddress: String { MCPSetup(host: host, port: port, token: "").url }

    /// The token with all but its last four characters hidden.
    var maskedToken: String {
        guard let token else { return "" }
        return String(repeating: "\u{2022}", count: 12) + token.suffix(4)
    }

    func copyToken() {
        guard let token = token ?? (try? MCPToken.load()) else { return }
        copy(token)
    }

    /// The JSON and the command with this Mac's address and the real token. Read when the
    /// sheet that shows them opens, and held only while it is open.
    func setupWithToken() -> MCPSetup? {
        guard let token = token ?? (try? MCPToken.load()) else { return nil }
        return MCPSetup(host: host, port: port, token: token)
    }

    /// A new token. Agents holding the old one are refused until they get this one, and the
    /// server restarts so it checks against it.
    func regenerateToken() {
        token = try? MCPToken.regenerate()
        apply()
    }

    /// Moves the server to the address. Nothing changes when either part isn't valid; the
    /// caller has already said so.
    func setAddress(host: String, port: UInt16) {
        guard let host = MCPEndpoint.address(host: host), host != self.host || port != self.port else { return }
        self.host = host
        self.port = port
        UserDefaults.standard.set(host, forKey: "agentHost")
        UserDefaults.standard.set(Int(port), forKey: "agentPort")
        apply()
    }

    func setTool(_ name: String, on: Bool) {
        if on { disabledTools.remove(name) } else { disabledTools.insert(name) }
        toolsChanged()
    }

    func setAllTools(on: Bool) {
        disabledTools = on ? [] : Set(MCPServer.toolCatalog.map(\.name))
        toolsChanged()
    }

    private func toolsChanged() {
        UserDefaults.standard.set(disabledTools.sorted(), forKey: "agentDisabledTools")
        server?.disabledTools = disabledTools
    }

    /// Everything copied here holds the token, so clipboard managers are told to skip it.
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }

    private func apply() {
        generation += 1
        let current = generation
        server?.stop()
        server = nil
        guard enabled, unlocked else {
            status = .off
            return
        }
        status = .starting
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let recording = recording
        let keyTerms = keyTerms
        let host = host, port = port, disabled = disabledTools
        Task {
            do {
                // Opening the store can migrate the database; that stays off the main thread.
                let server = try await Task.detached {
                    MCPServer(store: try CallStore(url: Paths.database), token: try MCPToken.load(), port: port,
                              recording: recording, keyTerms: keyTerms, version: version, host: host,
                              disabledTools: disabled)
                }.value
                try await server.start()
                guard current == generation else { return server.stop() }
                // A switch flipped while the server was starting.
                server.disabledTools = disabledTools
                self.server = server
                status = .on
            } catch {
                guard current == generation else { return }
                status = .failed("\(error)")
            }
        }
    }
}
