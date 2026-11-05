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
                .accessibilityLabel("Voice")
        }

        Settings {
            SettingsView()
                .environment(delegate.model)
                .environment(delegate.calls)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let calls = CallsModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.agents.recording = calls
        model.calls = calls
        model.launch()
        calls.launch(model: model)
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

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(CallsModel.self) private var calls
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.statusText)
        Button(model.isRecording ? "Stop and paste" : "Dictate  \(KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "")") {
            model.toggle()
        }
        .disabled(model.isWorking)
        CallMenuItems()
        if !model.recent.isEmpty || !calls.recent.isEmpty {
            Divider()
            Section("Recent") {
                ForEach(model.recent) { dictation in
                    Button(Self.label(dictation)) { model.open(dictation) }
                        .help(dictation.finalText.isEmpty && dictation.error != nil ? "Click to try again" : "Click to copy")
                        .disabled(dictation.finalText.isEmpty && dictation.error == nil)
                }
                RecentCalls()
            }
        }
        Divider()
        // A menu bar app isn't active, so Settings would open behind the frontmost window.
        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Button("Quit Voice") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private static func label(_ dictation: Dictation) -> String {
        let text: String
        if dictation.finalText.isEmpty {
            text = dictation.error == nil ? "Heard nothing" : "Couldn't transcribe, click to try again"
        } else {
            text = preview(dictation.finalText)
        }
        return dictation.origin == .recovered ? "Recovered a recording: " + text : text
    }

    private static func preview(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(60)) + "…" : text
    }
}
