import KeyboardShortcuts
import SwiftUI
import VoiceCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section("Dictate") {
                KeyboardShortcuts.Recorder("Shortcut:", name: .dictate)
                Help("Press once to start, again to stop. Nothing else stops a recording.")
                Picker("Microphone", selection: $preferences.microphoneUID) {
                    Text("System default").tag("")
                    ForEach(model.devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if !preferences.microphoneUID.isEmpty,
                       !model.devices.contains(where: { $0.uid == preferences.microphoneUID }) {
                        Text("Not connected").tag(preferences.microphoneUID)
                    }
                }
                Picker("Language", selection: $preferences.language) {
                    Text("Detect").tag("auto")
                    Divider()
                    ForEach(WhisperLanguages.all, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
            }

            Section("Fix the text") {
                Toggle("Fix the text before pasting", isOn: $preferences.runPrompt)
                Help("A model on this Mac fixes misheard words and punctuation. If it is off or fails, whisper's text is pasted as it is.")
                OllamaModelRow()
                VStack(alignment: .trailing, spacing: 6) {
                    TextEditor(text: $preferences.prompt)
                        .font(.body)
                        .frame(minHeight: 110)
                    Button("Restore default") { preferences.prompt = CleanupSettings.defaultPrompt }
                        .controlSize(.small)
                        .disabled(preferences.prompt == CleanupSettings.defaultPrompt)
                }
                TextField("Key terms", text: $preferences.keyTerms, axis: .vertical)
                Help("Names and words whisper gets wrong, as they should be spelled.")
            }

            Section("Speech model") {
                Picker("Model", selection: Binding(get: { preferences.whisperModel },
                                                   set: { model.chooseWhisperModel($0) })) {
                    ForEach(WhisperModel.allCases) { whisperModel in
                        Text(whisperModel == .largeV3Turbo ? "\(whisperModel.title) (recommended)" : whisperModel.title)
                            .tag(whisperModel)
                    }
                }
                SpeechModelStatus(whisperModel: preferences.whisperModel)
                Toggle("Retry unsure segments", isOn: $preferences.retrySegments)
                Help("Words whisper was unsure of are transcribed again, more carefully. This can add a moment before the paste.")
            }

            CallsSettingsSection()

            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                Picker("Keep history", selection: $preferences.history) {
                    Text(Preferences.History.thirtyDays.title).tag(Preferences.History.thirtyDays)
                    Text(Preferences.History.forever.title).tag(Preferences.History.forever)
                }
                Help("Each dictation's and call's audio and text. Click one in the menu to copy it.")
                AccessibilityStep()
                AgentAccessRow()
            }

            AboutSection()
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear {
            model.refreshDevices()
            model.refreshPermissions()
            Task { await model.refreshOllama() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
        .onChange(of: preferences.whisperModel) { _, whisperModel in
            model.downloads.download(whisperModel)
        }
        .onChange(of: preferences.history) {
            model.pruneHistory()
        }
    }
}

/// The version, updates and licenses.
private struct AboutSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updates = model.updates
        Section("About") {
            LabeledContent("Version") {
                HStack {
                    Text(Self.version)
                    Button("Check for Updates…") { model.updates.check() }
                        .disabled(!model.updates.canCheck)
                }
            }
            Toggle("Check for updates automatically", isOn: $updates.automatic)
            Help("Voice works on this Mac, and your audio stays on it. It goes online only to download the speech model and to check for updates. The fix step uses Ollama on this Mac, and the MCP server leaves it only if you put it on your tailnet.")
            Button("Licenses") { Self.openLicenses() }
                .help("Voice's license and those of the libraries it includes")
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private static func openLicenses() {
        guard let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil) else {
            return
        }
        NSWorkspace.shared.open([license, notices],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The models Ollama has, or why there are none to pick.
private struct OllamaModelRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        if let models = model.ollamaModels {
            Picker("Model", selection: $preferences.ollamaModel) {
                ForEach(models, id: \.self) { name in
                    Text(name).tag(name)
                }
                if !AppModel.contains(models, preferences.ollamaModel) {
                    Text("\(preferences.ollamaModel) (not installed)").tag(preferences.ollamaModel)
                }
            }
        } else {
            LabeledContent("Model") {
                Text("Ollama is not running").foregroundStyle(.secondary)
            }
        }
    }
}

private struct SpeechModelStatus: View {
    @Environment(AppModel.self) private var model
    let whisperModel: WhisperModel

    var body: some View {
        let size = SpeechModelStep.size(whisperModel)
        switch model.downloads.state(whisperModel) {
        case .ready:
            LabeledContent("Status") { Text("Ready") }
        case .downloading(let fraction):
            LabeledContent("Downloading \(size)") {
                ProgressView(value: fraction).frame(width: 160)
            }
        case .missing:
            LabeledContent("Status") {
                Button("Download \(size)") { model.downloads.download(whisperModel) }
            }
        case .failed(let error):
            LabeledContent(error) {
                Button("Try Again") { model.downloads.download(whisperModel) }
            }
        }
    }
}

private struct Help: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
