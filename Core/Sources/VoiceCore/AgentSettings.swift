import Foundation

/// The agent server's settings as the app stores them in its defaults, so the app and
/// `dictate-cli mcp` read the same ones.
public enum AgentSettings {
    public static let domain = "io.github.spashii.voice"
    public static let disabledToolsKey = "agentDisabledTools"
    public static let hostKey = "agentHost"
    public static let portKey = "agentPort"
    public static let accessKey = "agentAccess"

    /// Tools that no longer exist. A list stored by an earlier version may still name them;
    /// they are dropped on the next launch so no switch is left for a tool that isn't there.
    static let retiredTools: Set<String> = ["start_recording"]

    /// Whether the agent server starts. It is off for a new install. An install that has run
    /// Dictate before and never stored a choice had it on, so `true` is stored once and its
    /// agents keep working. A stored choice is never changed. Either result is stored at once,
    /// so a later launch can't mistake the folder this launch made for an earlier install.
    @discardableResult
    public static func settleAccess(in defaults: UserDefaults, existingInstall: Bool) -> Bool {
        if let stored = defaults.object(forKey: accessKey) as? Bool { return stored }
        defaults.set(existingInstall, forKey: accessKey)
        return existingInstall
    }

    /// UserDefaults won't open a suite named after the running bundle, which is the domain
    /// itself in that case.
    public static var appDefaults: UserDefaults {
        Bundle.main.bundleIdentifier == domain ? .standard : UserDefaults(suiteName: domain) ?? .standard
    }

    /// The off-by-default tools an install has already had its say on. A stored disabled list
    /// can't tell "left on" from "never offered", so each tool that starts off is listed here
    /// once it has been added to the list or a person has seen it.
    public static let seenToolsKey = "agentSeenTools"

    /// The off-by-default tools that existed before the seen list did. An install with a stored
    /// disabled list and no seen list saw exactly these; anything added since is new to it.
    static let offByDefaultBeforeSeenList: Set<String> = [
        "stop_recording", "correct_dictation", "correct_segment",
        "add_key_terms", "remove_key_terms", "tag_call", "undo_edit",
    ]

    /// The tools an agent can't use. A stored list, even an empty one, is a person's (or an
    /// earlier version's) choice and is kept, except that an off-by-default tool the install
    /// has not seen yet is added to it once, so a tool added in a later version can't start
    /// on for someone who never had the chance to decide. After that the person's switch
    /// wins, so turning it on keeps it on. With no list stored, the writing and recording
    /// tools start off only on an install that has never run: anyone who already used Dictate,
    /// shown by a data folder or earlier preferences, keeps every tool they had on, as before
    /// this version, but still gets the tools they have not seen off. The result is stored at
    /// once, so a second launch can't mistake the folder this launch made for an earlier
    /// install.
    public static func disabledTools(in defaults: UserDefaults, existingInstall: Bool) -> Set<String> {
        let stored = defaults.stringArray(forKey: disabledToolsKey).map { Set($0).subtracting(retiredTools) }
        let unseen = MCPServer.offByDefault.subtracting(seenTools(in: defaults))
        let disabled: Set<String>
        if let stored {
            disabled = stored.union(unseen)
        } else {
            disabled = existingInstall ? unseen : MCPServer.offByDefault
        }
        if defaults.stringArray(forKey: disabledToolsKey).map(Set.init) != disabled {
            defaults.set(disabled.sorted(), forKey: disabledToolsKey)
        }
        defaults.set(MCPServer.offByDefault.union(seenTools(in: defaults)).sorted(), forKey: seenToolsKey)
        return disabled
    }

    /// Without a seen list, an install is taken to have seen the tools that existed before the
    /// list did, so an existing install with no stored disabled list keeps those on and gets
    /// only the newer ones off.
    private static func seenTools(in defaults: UserDefaults) -> Set<String> {
        if let seen = defaults.stringArray(forKey: seenToolsKey) { return Set(seen).subtracting(retiredTools) }
        return offByDefaultBeforeSeenList
    }

    /// True when this Mac has run Dictate (or Voice) before: either data folder exists, or the
    /// defaults hold any key besides the ones this launch may have written.
    public static func isExistingInstall(support root: URL = DataMigration.applicationSupport,
                                         defaults: UserDefaults = appDefaults, domain: String = domain) -> Bool {
        let fm = FileManager.default
        if [DataMigration.oldName, DataMigration.newName].contains(where: { fm.fileExists(atPath: root.appending(path: $0).path) }) {
            return true
        }
        let own = defaults.persistentDomain(forName: domain) ?? [:]
        return !own.isEmpty
    }

    /// The host and port the app's server uses; the defaults when none were set or they are invalid.
    public static func endpoint(in defaults: UserDefaults) -> (host: String, port: UInt16) {
        let host = defaults.string(forKey: hostKey).flatMap(MCPEndpoint.address(host:)) ?? MCPEndpoint.defaultHost
        let port = (defaults.object(forKey: portKey) as? Int).flatMap { UInt16(exactly: $0) } ?? MCPServer.defaultPort
        return (host, port)
    }

    /// The tool switches dictate-cli applies: the app's, with any off-by-default tool the app
    /// has not recorded as seen counted off, or the new-install defaults while the app has
    /// never stored any. It never writes them.
    public static func disabledToolsForReading(in defaults: UserDefaults) -> Set<String> {
        guard let stored = defaults.stringArray(forKey: disabledToolsKey) else { return MCPServer.offByDefault }
        return Set(stored).subtracting(retiredTools).union(MCPServer.offByDefault.subtracting(seenTools(in: defaults)))
    }
}
