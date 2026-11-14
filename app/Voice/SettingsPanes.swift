import KeyboardShortcuts
import SwiftUI
import VoiceCore

/// What gets the first dictation working, until it is done, then how long to keep things.
struct SetupPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                ActivationStep()
                MicrophoneStep()
                AccessibilityStep()
                CallAudioStep()
                SpeechModelStep(whisperModel: preferences.whisperModel)
            } footer: {
                Text("Press \(KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "the shortcut") in any text field and speak. Press it again to paste.")
            }
            Section {
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            }
            Section {
                Picker(RetentionText.audioLabel, selection: Binding(
                    get: { _ = model.retentionRevision; return preferences.shownAudioRetention },
                    set: { model.setRetention(audio: $0) })) {
                    ForEach(RetentionText.audioOptions(developerMode: preferences.developerMode), id: \.self) {
                        Text(RetentionText.title($0)).tag($0)
                    }
                }
                Picker(RetentionText.historyLabel, selection: Binding(
                    get: { _ = model.retentionRevision; return preferences.shownTranscriptRetention },
                    set: { model.setRetention(transcripts: $0) })) {
                    ForEach(RetentionText.transcriptOptions, id: \.self) {
                        Text(RetentionText.title($0)).tag($0)
                    }
                }
            } header: {
                Text(RetentionText.groupTitle)
            } footer: {
                if preferences.developerMode { Text(RetentionText.developerModeFooter) }
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutsPane: View {
    @Environment(CallsModel.self) private var calls

    var body: some View {
        @Bindable var calls = calls
        Form {
            Section("Dictate") {
                KeyboardShortcuts.Recorder("Shortcut", name: .dictate)
                Text("Press once to start, again to stop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Record call") {
                KeyboardShortcuts.Recorder("Shortcut", name: .recordCall)
                Toggle("Ask to record when a call starts", isOn: $calls.askToRecord)
            }
        }
        .formStyle(.grouped)
    }
}

struct MicrophonesPane: View {
    @Environment(AppModel.self) private var model
    @Environment(CallsModel.self) private var calls

    var body: some View {
        @Bindable var preferences = model.preferences
        @Bindable var calls = calls
        // A Blend mix is picked under Call audio, not as a microphone.
        let microphones = model.devices.filter { device in !calls.mixes.contains { $0.deviceUID == device.uid } }
        Form {
            Section {
                Picker("Microphone for dictation", selection: $preferences.microphoneUID) {
                    Text("System default").tag("")
                    ForEach(microphones) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if !preferences.microphoneUID.isEmpty,
                       !microphones.contains(where: { $0.uid == preferences.microphoneUID }) {
                        Text("Not connected").tag(preferences.microphoneUID)
                    }
                }
                Picker("Microphone for calls", selection: $calls.microphoneUID) {
                    Text("System default").tag("")
                    ForEach(microphones) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if !calls.microphoneUID.isEmpty, !microphones.contains(where: { $0.uid == calls.microphoneUID }) {
                        Text("Not connected").tag(calls.microphoneUID)
                    }
                }
                Toggle("Cancel echo from the call", isOn: $calls.cancelEcho)
            } footer: {
                Text("On speakers, Dictate takes the call out of what your microphone hears.")
            }
            Section {
                BlendMicNote()
                    .font(.callout)
                    .foregroundStyle(.secondary)
                CallAudioPermissionRow()
                CallAudioPicker()
                if let warning = calls.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }
            } header: {
                Text("Call audio")
            }
        }
        .formStyle(.grouped)
        .task { await calls.refreshSources() }
        .onAppear { model.refreshDevices() }
    }
}

/// Why a call's audio has a choice at all: Dictate records it itself, and a Blend Mic mix is
/// the alternative for people who already use Blend Mic.
struct BlendMicNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("Dictate records a call\u{2019}s audio itself. If you use Blend Mic, you can record its mix instead.")
        LabeledContent("Blend Mic") {
            if BlendMic.isInstalled(inputNames: model.devices.map(\.name)) {
                Text("Installed")
            } else {
                Link("Get Blend Mic", destination: BlendMic.website)
            }
        }
    }
}

/// Shown only while Dictate can't yet record other apps' sound.
struct CallAudioPermissionRow: View {
    @Environment(CallsModel.self) private var calls

    var body: some View {
        if calls.capturePermission != .authorized {
            LabeledContent {
                Button(calls.capturePermission == .denied ? "Open System Settings\u{2026}" : "Allow\u{2026}") {
                    calls.askForCaptureAccess()
                }
            } label: {
                Label("Dictate can\u{2019}t record call audio yet", systemImage: "exclamationmark.circle")
                if calls.capturePermission == .denied {
                    Text("Turn on Dictate under System Audio Recording.")
                }
            }
        }
    }
}

struct ModelPane: View {
    @Environment(AppModel.self) private var model

    private var noModel: Bool {
        LocalModelChoice.noModelCanRun(apple: model.appleModelState, ollamaModels: model.ollamaModels)
    }

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                Picker("Speech model", selection: Binding(get: { preferences.whisperModel },
                                                   set: { model.chooseWhisperModel($0) })) {
                    ForEach(WhisperModel.allCases) { whisperModel in
                        Text(whisperModel == .largeV3Turbo ? "\(whisperModel.title) (recommended)" : whisperModel.title)
                            .tag(whisperModel)
                    }
                }
                SpeechModelStatus(whisperModel: preferences.whisperModel)
                Toggle(isOn: $preferences.retrySegments) {
                    Text("Retry unsure words")
                    Text("Words Whisper was unsure of are transcribed again, more carefully. This can add a moment before the paste.")
                }
                RetryStatsView()
                TextField(text: $preferences.keyTerms, axis: .vertical) {
                    Text("Key terms")
                    Text("Words Whisper gets wrong, spelled your way.")
                }
                SuggestedTermsView()
            }
            Section {
                LocalModelRow()
                Toggle(isOn: $preferences.runPrompt) {
                    Text("Fix the text before pasting")
                    Text("Reads the text with your key terms and can change a few misheard words. This adds a moment before the paste.")
                }
                .disabled(noModel)
                Toggle(isOn: $preferences.titleCalls) {
                    Text("Add a title to each call automatically")
                }
                .disabled(noModel)
            }
        }
        .formStyle(.grouped)
        // Ollama and Apple's model can come up while Settings is open; the toggles wake without a reopen.
        .task {
            while !Task.isCancelled {
                await model.refreshOllama()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onChange(of: preferences.whisperModel) { _, whisperModel in
            model.downloads.download(whisperModel)
        }
    }
}

/// The intelligence model for the fix and for titles. Always listed, with Apple's entry saying
/// why it can't be used when it can't, and Ollama's saying when it isn't running.
struct LocalModelRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let preferences = model.preferences
        let options = LocalModelChoice.pickerOptions(apple: model.appleModelState, current: model.effectiveModel,
                                                     ollamaModels: model.ollamaModels, ollamaModel: preferences.ollamaModel)
        let selection = Binding<String>(
            get: { LocalModelChoice.tag(model.effectiveModel) },
            set: { tag in
                guard let choice = LocalModelChoice.model(tag: tag) else { return }
                if case .ollama(let name) = choice { preferences.ollamaModel = name }
                preferences.localModel = choice
            })
        Picker(selection: selection) {
            Text(options.apple.title).tag(LocalModelChoice.tag(options.apple.model))
            Divider()
            ForEach(options.ollama, id: \.self) { entry in
                Text(entry.title).tag(LocalModelChoice.tag(entry.model))
            }
        } label: {
            Text("Intelligence model")
            if LocalModelChoice.noModelCanRun(apple: model.appleModelState, ollamaModels: model.ollamaModels) {
                Text(LocalModelChoice.noModelHint(apple: model.appleModelState, ollamaModels: model.ollamaModels))
            }
        }
    }
}

struct SpeechModelStatus: View {
    @Environment(AppModel.self) private var model
    let whisperModel: WhisperModel

    var body: some View {
        let size = SpeechModelStep.size(whisperModel)
        switch model.downloads.state(whisperModel) {
        case .ready:
            EmptyView()
        case .downloading(let fraction):
            LabeledContent("Downloading \(size)") {
                ProgressView(value: fraction).frame(width: 160)
            }
        case .missing:
            LabeledContent("Not downloaded") {
                Button("Download \(size)") { model.downloads.download(whisperModel) }
            }
        case .failed(let error):
            LabeledContent(error) {
                Button("Try Again") { model.downloads.download(whisperModel) }
            }
        }
    }
}

// MARK: Agents

struct AgentsPane: View {
    @Environment(AppModel.self) private var model
    @State private var hostText = ""
    @State private var portText = ""
    @State private var addressError: String?
    @State private var confirmRegenerate = false
    @State private var showingSetup = false
    @FocusState private var focus: Field?

    private enum Field { case host, port }

    var body: some View {
        @Bindable var agents = model.agents
        Form {
            Section {
                Toggle(isOn: $agents.enabled) {
                    Text("Agents can read transcripts")
                    Text("Over MCP, with the token below.")
                }
            }
            if agents.enabled {
                server(agents)
                connect()
                tools(agents)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hostText = agents.host
            portText = String(agents.port)
        }
        .sheet(isPresented: $showingSetup) { ConnectSheet(agents: agents) }
        .confirmationDialog("Make a new token?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { agents.regenerateToken() }
        } message: {
            Text("Agents using the old token stop working until you give them the new one.")
        }
    }

    private func server(_ agents: AgentAccess) -> some View {
        Section {
            TextField("Host", text: $hostText)
                .multilineTextAlignment(.trailing)
                .focused($focus, equals: .host)
                .onSubmit(commitAddress)
            TextField("Port", text: $portText)
                .multilineTextAlignment(.trailing)
                .focused($focus, equals: .port)
                .onSubmit(commitAddress)
            LabeledContent("Token") {
                HStack {
                    Text(agents.maskedToken).monospaced().foregroundStyle(.secondary)
                    Button("Copy") { agents.copyToken() }
                    Button("Regenerate") { confirmRegenerate = true }
                }
            }
        } header: {
            Text("Server")
        } footer: {
            if let addressError {
                Text(addressError).foregroundStyle(.red)
            } else if case .failed(let message) = agents.status {
                Text(message).foregroundStyle(.red)
            } else if let warning = MCPEndpoint.exposureWarning(host: hostText) {
                Text(warning).foregroundStyle(.orange)
            }
        }
        .onChange(of: focus) { old, new in
            // Leaving a field applies what was typed, as Return does.
            if old != nil, new != old { commitAddress() }
        }
    }

    private func connect() -> some View {
        Section {
            LabeledContent {
                Button("Show Config") { showingSetup = true }
            } label: {
                Text("Connect an agent app")
            }
        }
    }

    private func tools(_ agents: AgentAccess) -> some View {
        Section {
            Text("Tools that record or change anything start off.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(MCPServer.toolCatalog) { tool in
                Toggle(isOn: Binding(get: { !agents.disabledTools.contains(tool.name) },
                                     set: { agents.setTool(tool.name, on: $0) })) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(tool.name).font(.system(size: 12, design: .monospaced)).frame(width: 190, alignment: .leading)
                        Text(tool.summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        } header: {
            HStack {
                Text("Tools")
                Spacer()
                Button("Turn all on") { agents.setAllTools(on: true) }
                Button("Turn all off") { agents.setAllTools(on: false) }
            }
        }
    }

    /// Moves the server when both fields are valid; otherwise says which isn't.
    private func commitAddress() {
        guard let host = MCPEndpoint.address(host: hostText) else {
            addressError = "The host is an IPv4 address such as 127.0.0.1, or localhost."
            return
        }
        guard let port = MCPEndpoint.port(portText) else {
            addressError = "The port is a number from 1024 to 65535."
            return
        }
        addressError = nil
        hostText = host
        portText = String(port)
        model.agents.setAddress(host: host, port: port)
    }
}

/// The config an agent app needs, with the real token. The token is read when the sheet opens
/// and dropped when it closes, and it is shown nowhere else.
private struct ConnectSheet: View {
    let agents: AgentAccess
    @Environment(\.dismiss) private var dismiss
    @State private var setup: MCPSetup?
    @State private var copiedMessage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect an agent app").font(.title3.weight(.semibold))
            if let setup {
                step("1. Choose tools", "Close this window, then switch on the tools your agent may use under Tools.")
                VStack(alignment: .leading, spacing: 10) {
                    step("2. Copy", "Paste the setup message into Claude or another agent app. It tells the agent how to connect.")
                    HStack {
                        Button(copiedMessage ? "Copied" : "Copy setup message") {
                            agents.copy(setup.message)
                            copiedMessage = true
                        }
                        Text("The token works like a password for your transcripts.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    snippet("JSON config", setup.json)
                    snippet("Claude Code", setup.command)
                }
                step("3. Start a new session", "Open a new session in your agent app so the Dictate tools appear.")
            } else {
                Text("The token could not be read.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { setup = agents.setupWithToken() }
        .onDisappear { setup = nil }
    }

    private func step(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { agents.copy(text) }
            }
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: About

struct AboutPane: View {
    @Environment(AppModel.self) private var model
    @State private var showingNotices = false
    @State private var copiedID = false
    @State private var showingAllReleases: Bool
    private static let changelog: [Changelog.Entry] = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Changelog.parse(text)
    }()

    init(showingAllReleases: Bool = false) {
        _showingAllReleases = State(initialValue: showingAllReleases)
    }

    var body: some View {
        @Bindable var updates = model.updates
        @Bindable var preferences = model.preferences
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppName.name).font(.title2.weight(.semibold))
                        Text("Version \(Self.version)").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                if let id = model.activation.activationID {
                    LabeledContent("Activation ID") {
                        HStack {
                            Text(verbatim: id).monospaced().textSelection(.enabled)
                            Button(copiedID ? "Copied" : "Copy") { copy(id) }
                        }
                    }
                }
                LabeledContent("Feedback") {
                    Button("Send Feedback\u{2026}") {
                        NSWorkspace.shared.open(SupportItem.feedbackURL(activationID: model.activation.activationID))
                    }
                }
            }
            if let update = model.updates.available {
                Section {
                    LabeledContent {
                        Button("Update") { model.updates.install() }
                            .buttonStyle(.borderedProminent)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Update available")
                            Text("Version \(update.version)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if !update.notes.isEmpty { BulletList(items: update.notes) }
                }
            }
            Section {
                LabeledContent("Updates") {
                    Button("Check for Updates\u{2026}") { model.updates.check() }
                        .disabled(!model.updates.canCheck)
                }
                Toggle("Check for updates automatically", isOn: $updates.automatic)
            }
            if !Self.changelog.isEmpty {
                Section("What\u{2019}s new") {
                    ForEach(Changelog.visible(Self.changelog, showingAll: showingAllReleases), id: \.version) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(verbatim: entry.version).font(.headline)
                                Spacer()
                                if let date = Self.dateText(entry.date) {
                                    Text(verbatim: date).foregroundStyle(.secondary)
                                }
                            }
                            BulletList(items: entry.items)
                        }
                        .padding(.vertical, 4)
                    }
                    if !showingAllReleases && Self.changelog.count > Changelog.recentCount {
                        Button("View more") { showingAllReleases = true }
                            .buttonStyle(.link)
                    }
                }
            }
            Section {
                Toggle("Developer mode", isOn: Binding(get: { _ = model.retentionRevision; return preferences.developerMode }, set: { model.setDeveloperMode($0) }))
            }
            Section {
                Link(destination: URL(string: "https://spashii.github.io/dictate/")!) {
                    Label("spashii.github.io/dictate", systemImage: "arrow.up.right.square")
                }
            } footer: {
                HStack(spacing: 4) {
                    Text("Source available under the Functional Source License (FSL-1.1-MIT), \u{00A9} 2026 The Dictate authors. Each version becomes MIT two years after its release.")
                    Button("Third-party notices") { showingNotices = true }
                        .buttonStyle(.link)
                }
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingNotices) { NoticesSheet() }
    }

    private func copy(_ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        copiedID = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedID = false
        }
    }

    private static func dateText(_ components: DateComponents?) -> String? {
        guard let components, let date = Calendar(identifier: .gregorian).date(from: components) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}

/// Release notes as bullets with a hanging indent.
private struct BulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline) {
                    Text("\u{2022}")
                    Text(Changelog.styled(item)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// THIRD_PARTY_NOTICES.md, bundled with the app, as the licenses of what it includes require.
private struct NoticesSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let blocks: [NoticesDocument.Block] = {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [.paragraph("The notices file is missing from this copy of Dictate.")]
        }
        return NoticesDocument.parse(text)
    }()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .heading(let level, let text):
                            Text(text).font(level <= 1 ? .title2.bold() : .headline).padding(.top, 6)
                        case .paragraph(let text):
                            Text(text)
                        case .code(let text):
                            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 520)
    }
}
