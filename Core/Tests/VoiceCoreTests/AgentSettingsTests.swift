import Foundation
import Testing
@testable import VoiceCore

@Suite struct AgentSettingsTests {
    private func defaults() -> UserDefaults { defaults(named: "dictate-tests-\(UUID().uuidString)") }

    private func defaults(named name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func support(folders: [String] = []) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "dictate-support-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for folder in folders {
            try FileManager.default.createDirectory(at: url.appending(path: folder), withIntermediateDirectories: true)
        }
        return url
    }

    @Test func aNewInstallStartsWithTheWritingToolsOffAndKeepsThatChoice() {
        let store = defaults()
        #expect(AgentSettings.disabledTools(in: store, existingInstall: false) == MCPServer.offByDefault)
        // Stored, so a later launch (when the data folder exists) doesn't read it as an old install.
        #expect(store.stringArray(forKey: AgentSettings.disabledToolsKey) != nil)
        #expect(AgentSettings.disabledTools(in: store, existingInstall: true) == MCPServer.offByDefault)
    }

    @Test func anExistingInstallKeepsEveryToolItHadOnAndGetsANewOneOff() {
        let store = defaults()
        #expect(AgentSettings.disabledTools(in: store, existingInstall: true) == ["import_audio_file", "set_recording_title"])
        #expect(store.stringArray(forKey: AgentSettings.disabledToolsKey) == ["import_audio_file", "set_recording_title"])
        #expect(AgentSettings.disabledTools(in: store, existingInstall: false) == ["import_audio_file", "set_recording_title"])
    }

    @Test func aStoredChoiceWinsExceptForToolsItNeverSaw() {
        let store = defaults()
        store.set(["list_calls"], forKey: AgentSettings.disabledToolsKey)
        #expect(AgentSettings.disabledTools(in: store, existingInstall: false) == ["import_audio_file", "list_calls", "set_recording_title"])
        #expect(store.stringArray(forKey: AgentSettings.disabledToolsKey) == ["import_audio_file", "list_calls", "set_recording_title"])
    }

    @Test func aToolTurnedOnStaysOnAcrossLaunches() {
        let store = defaults()
        store.set(["list_calls"], forKey: AgentSettings.disabledToolsKey)
        _ = AgentSettings.disabledTools(in: store, existingInstall: true)
        store.set(["list_calls"], forKey: AgentSettings.disabledToolsKey)
        #expect(AgentSettings.disabledTools(in: store, existingInstall: true) == ["list_calls"])
        #expect(AgentSettings.disabledTools(in: store, existingInstall: true) == ["list_calls"])
        #expect(Set(store.stringArray(forKey: AgentSettings.seenToolsKey) ?? []) == MCPServer.offByDefault)
    }

    @Test func aNewInstallHasSeenEveryToolSoTurningOneOnSticks() {
        let store = defaults()
        _ = AgentSettings.disabledTools(in: store, existingInstall: false)
        store.set([String](), forKey: AgentSettings.disabledToolsKey)
        #expect(AgentSettings.disabledTools(in: store, existingInstall: true).isEmpty)
    }

    @Test func agentAccessIsOffForANewInstallAndStaysSo() {
        let store = defaults()
        #expect(!AgentSettings.settleAccess(in: store, existingInstall: false))
        #expect(store.object(forKey: AgentSettings.accessKey) as? Bool == false)
        // The folder the first launch made must not turn it on at the next one.
        #expect(!AgentSettings.settleAccess(in: store, existingInstall: true))
    }

    @Test func anExistingInstallWithNoChoiceGetsAccessOnceAndKeepsItsOwnChoice() {
        let store = defaults()
        #expect(AgentSettings.settleAccess(in: store, existingInstall: true))
        #expect(store.object(forKey: AgentSettings.accessKey) as? Bool == true)
        store.set(false, forKey: AgentSettings.accessKey)
        #expect(!AgentSettings.settleAccess(in: store, existingInstall: true))
    }

    @Test func startRecordingIsDroppedFromStoredListsAndNoSwitchIsLeft() {
        let store = defaults()
        store.set(["start_recording", "list_calls"], forKey: AgentSettings.disabledToolsKey)
        store.set(["start_recording", "stop_recording"], forKey: AgentSettings.seenToolsKey)
        let disabled = AgentSettings.disabledTools(in: store, existingInstall: true)
        #expect(!disabled.contains("start_recording"))
        #expect(disabled.contains("list_calls"))
        #expect(store.stringArray(forKey: AgentSettings.disabledToolsKey)?.contains("start_recording") == false)
        #expect(store.stringArray(forKey: AgentSettings.seenToolsKey)?.contains("start_recording") == false)
        #expect(!MCPServer.toolCatalog.map(\.name).contains("start_recording"))
        #expect(!AgentSettings.disabledToolsForReading(in: store).contains("start_recording"))
    }

    @Test func eitherDataFolderMeansAnExistingInstall() throws {
        let name = "dictate-tests-\(UUID().uuidString)"
        let store = defaults(named: name)
        #expect(try AgentSettings.isExistingInstall(support: support(folders: ["Voice"]), defaults: store, domain: name))
        #expect(try AgentSettings.isExistingInstall(support: support(folders: ["Dictate"]), defaults: store, domain: name))
        #expect(try !AgentSettings.isExistingInstall(support: support(), defaults: store, domain: name))
    }

    @Test func anyEarlierPreferenceMeansAnExistingInstall() throws {
        let name = "dictate-tests-\(UUID().uuidString)"
        let store = defaults(named: name)
        store.set(true, forKey: "agentAccess")
        #expect(try AgentSettings.isExistingInstall(support: support(), defaults: store, domain: name))
    }

    @Test func theCLIReadsTheAppsEndpointAndFallsBackToTheDefaults() {
        let store = defaults()
        #expect(AgentSettings.endpoint(in: store) == (MCPEndpoint.defaultHost, MCPServer.defaultPort))
        store.set("localhost", forKey: AgentSettings.hostKey)
        store.set(8123, forKey: AgentSettings.portKey)
        #expect(AgentSettings.endpoint(in: store) == ("127.0.0.1", 8123))
        store.set("nonsense", forKey: AgentSettings.hostKey)
        #expect(AgentSettings.endpoint(in: store).host == MCPEndpoint.defaultHost)
    }

    @Test func theCLIAppliesTheAppsToolSwitchesWithoutWritingThem() {
        let store = defaults()
        #expect(AgentSettings.disabledToolsForReading(in: store) == MCPServer.offByDefault)
        #expect(store.stringArray(forKey: AgentSettings.disabledToolsKey) == nil)
        store.set(["get_call"], forKey: AgentSettings.disabledToolsKey)
        #expect(AgentSettings.disabledToolsForReading(in: store) == ["get_call", "import_audio_file", "set_recording_title"])
        #expect(store.stringArray(forKey: AgentSettings.seenToolsKey) == nil)
    }

    @Test func theCLICountsAToolTheAppHasSeenAsTheStoredListSaysAndAnUnseenOneAsOff() {
        let store = defaults()
        store.set(["get_call"], forKey: AgentSettings.disabledToolsKey)
        store.set(Array(MCPServer.offByDefault), forKey: AgentSettings.seenToolsKey)
        #expect(AgentSettings.disabledToolsForReading(in: store) == ["get_call"])
    }
}
