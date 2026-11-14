import KeyboardShortcuts
import SwiftUI
import VoiceCore

@main
struct VoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(delegate.model)
                .environment(delegate.calls)
        } label: {
            Image(delegate.model.menuBarImage)
                .accessibilityLabel("Dictate")
        }

        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") { delegate.model.openSettings() }
                    .keyboardShortcut(",")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let calls: CallsModel
    private let windows = WindowActivation()

    /// What the data folder move found, for a notice once the app is up.
    private let migration: DataMigration.Outcome

    /// Order matters. A bundle that was renamed starts again from its new path first, before
    /// anything is initialised. An older copy still running is dealt with before the data
    /// folder moves under its open database. The agent defaults are settled before anything
    /// creates the folders that would make a new install look like an old one.
    override init() {
        #if DEBUG
        // The app-shots run draws views and quits: no other copy to check, nothing to migrate.
        if Snapshots.folder != nil {
            migration = .nothingToDo
            model = AppModel(activation: Activation(store: MemoryActivationStore()))
            calls = CallsModel()
            super.init()
            return
        }
        #endif
        if let renamed = BundleRename.renameIfNeeded() { BundleRename.relaunchAndExit(renamed) }
        guard OtherInstance.ensureSole() else { exit(0) }
        _ = AgentSettings.disabledTools(in: .standard, existingInstall: AgentSettings.isExistingInstall())
        migration = DataMigration.run()
        model = AppModel()
        calls = CallsModel()
        super.init()
    }

    private var launched = false

    /// Activation comes back as a link in the app's own scheme. The log line says whether the
    /// link arrived on a cold launch or while running, and never holds the token.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            DevLog.write("open \(url.scheme ?? "")://\(url.host ?? "") query=\(url.query?.count ?? 0) launched=\(launched)")
            model.acceptActivation(url: url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let folder = Snapshots.folder {
            Task { await Snapshots.run(into: folder) }
            return
        }
        #endif
        launched = true
        DevLog.write("launched")
        model.agents.recording = calls
        model.agents.keyTerms = PreferencesKeyTerms(preferences: model.preferences)
        model.calls = calls
        CommonWords.onMainThread.isSet = true
        windows.start()
        if migration == .bothExist { explainBothFolders() }
        model.launch()
        calls.launch(model: model)
        // After both shortcut handlers exist, so a locked Dictate registers neither.
        model.applyLock(force: true)
    }

    /// Both Application Support/Voice and Dictate exist, so nothing was moved. Said once, with
    /// the folder that is in use, because the history in the other one is not shown.
    private func explainBothFolders() {
        let key = "bothFoldersNoticeShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let alert = NSAlert()
        alert.messageText = "Two data folders found"
        alert.informativeText = "Dictate is using \(Paths.support.path). A second folder from the older Voice app is still at \(DataMigration.applicationSupport.appending(path: DataMigration.oldName).path). Dictate doesn't merge them or change the old one, so recordings kept only there aren't shown."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Whisper's model has to be freed before the process exits: ggml's Metal device
    /// asserts at exit while a model still holds it, and the quit would end in a crash report.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await calls.shutDown()
            await model.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// A dictation or a call in the menu's Recent list, newest first.
enum RecentItem: Identifiable {
    case dictation(Dictation)
    case call(Call)

    var id: String {
        switch self {
        case .dictation(let dictation): "d" + dictation.id
        case .call(let call): "c" + call.id
        }
    }

    var date: Date {
        switch self {
        case .dictation(let dictation): dictation.createdAt
        case .call(let call): call.startedAt
        }
    }

    static let count = 5

    static func newest(dictations: [Dictation], calls: [Call]) -> [RecentItem] {
        Array((dictations.map(RecentItem.dictation) + calls.map(RecentItem.call))
            .sorted { $0.date > $1.date }.prefix(count))
    }
}

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(CallsModel.self) private var calls

    var body: some View {
        // Groups are Sections, which the menu separates with real separators. No item has a
        // tooltip: one firing in the open menu is the likely cause of the highlight drawn a
        // row too high, over the separator.
        if !model.activation.isActivated {
            Section {
                Button("Activate in Browser") { model.beginActivation() }
            }
        }
        if model.lock.showsRecordingMenu {
            Section {
                Text(model.statusText)
                if let holder = model.secureInput {
                    Text(holder.menuText)
                }
                Button(model.isRecording ? "Stop and Paste" : "Dictate  \(KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "")") {
                    model.toggle()
                }
                .disabled(model.isWorking)
                CallMenuItems()
            }
            let recent = RecentItem.newest(dictations: model.recent, calls: calls.recent)
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent) { item in
                        switch item {
                        case .dictation(let dictation):
                            Button(Self.label(dictation)) {
                                if RowMenu.rightClicked, !dictation.finalText.isEmpty {
                                    RowMenu.copyTranscript { model.copy(dictation) }
                                } else {
                                    model.open(dictation)
                                }
                            }
                            .disabled(dictation.finalText.isEmpty && dictation.error == nil)
                        case .call(let call):
                            RecentCall(call: call)
                        }
                    }
                }
            }
            Section {
                Button("Open History\u{2026}") { model.openHistory() }
                Button("Settings\u{2026}") { model.openSettings() }
                    .keyboardShortcut(",")
            }
        }
        Section {
            ForEach(SupportItem.allCases, id: \.self) { item in
                Button(item.title) { open(item) }
                    .disabled(item == .checkForUpdates && !model.updates.canCheck)
                if item == .checkForUpdates {
                    Text(SupportItem.versionTitle(appVersion: SupportItem.appVersion))
                }
            }
            Button("Quit Dictate") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func open(_ item: SupportItem) {
        switch item {
        case .checkForUpdates: model.updates.check()
        case .reportIssue: NSWorkspace.shared.open(SupportItem.issueURL)
        case .sendFeedback: NSWorkspace.shared.open(SupportItem.feedbackURL(activationID: model.activation.activationID))
        }
    }

    private static func label(_ dictation: Dictation) -> String {
        let text: String
        if dictation.finalText.isEmpty {
            text = "Couldn't transcribe, click to try again"
        } else {
            text = preview(dictation.finalText)
        }
        return dictation.origin == .recovered ? "Recovered a recording: " + text : text
    }

    private static func preview(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(60)) + "…" : text
    }
}

/// A Recent row's right-click menu. NSMenu has no context menu for its items, but a right
/// click still picks one, so the row's action asks which button picked it: a right click
/// opens Copy Transcript at the pointer, and a left click does what it always did. Should
/// macOS not pass the right click through, the row acts as if left-clicked.
@MainActor
enum RowMenu {
    static var rightClicked: Bool {
        let type = NSApp.currentEvent?.type
        return type == .rightMouseUp || type == .rightMouseDown
    }

    static func copyTranscript(_ copy: @escaping @MainActor () -> Void) {
        let action = MenuAction(copy)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Copy Transcript", action: #selector(MenuAction.fire), keyEquivalent: "")
        item.target = action
        menu.addItem(item)
        let location = NSEvent.mouseLocation
        // Once the menu bar's menu has finished closing, so the two never track at once.
        Task {
            withExtendedLifetime(action) {
                _ = menu.popUp(positioning: nil, at: location, in: nil)
            }
        }
    }
}

@MainActor
private final class MenuAction: NSObject {
    private let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        self.run = run
    }

    @objc func fire() {
        run()
    }
}
