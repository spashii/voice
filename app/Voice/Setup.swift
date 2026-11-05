import AppKit
import KeyboardShortcuts
import SwiftUI
import VoiceCore

/// The window that gets a first dictation working: the microphone, Accessibility and the
/// speech model. It opens at launch until all three are done and closes itself once they are.
@MainActor
final class SetupWindow {
    private let model: AppModel
    private var window: NSWindow?
    private var watch: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        if model.downloads.state(model.preferences.whisperModel) == .missing {
            model.downloads.download(model.preferences.whisperModel)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // macOS says nothing when Accessibility is granted, so the window looks every second.
        watch?.cancel()
        watch = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.refreshPermissions()
                if model.setupComplete {
                    close()
                    return
                }
            }
        }
    }

    private func close() {
        watch?.cancel()
        window?.close()
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Set Up Voice"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SetupView().environment(model))
        return window
    }
}

struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                MicrophoneStep()
                AccessibilityStep()
                SpeechModelStep(whisperModel: model.preferences.whisperModel)
            }
            Text("Press \(KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "the shortcut") in any text field, speak, press it again.")
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct MicrophoneStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        StepRow(title: "Microphone", done: model.microphoneAllowed) {
            Button("Allow…") { model.askForMicrophone() }
        }
    }
}

struct AccessibilityStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        StepRow(title: "Accessibility", done: model.accessibilityAllowed,
                detail: "Lets Voice paste into other apps.") {
            Button("Allow…") { Paster.askForAccess() }
        }
    }
}

struct SpeechModelStep: View {
    @Environment(AppModel.self) private var model
    let whisperModel: WhisperModel

    var body: some View {
        switch model.downloads.state(whisperModel) {
        case .ready:
            StepRow(title: "Speech model", done: true)
        case .downloading(let fraction):
            StepRow(title: "Speech model", done: false, detail: "Downloading \(Self.size(whisperModel))") {
                ProgressView(value: fraction).frame(width: 120)
            }
        case .missing:
            StepRow(title: "Speech model", done: false) {
                Button("Download \(Self.size(whisperModel))") { model.downloads.download(whisperModel) }
            }
        case .failed(let error):
            StepRow(title: "Speech model", done: false, detail: error) {
                Button("Try Again") { model.downloads.download(whisperModel) }
            }
        }
    }

    static func size(_ model: WhisperModel) -> String {
        String(format: "%.1f GB", Double(model.bytes) / 1e9)
    }
}

/// One setup step: whether it is done, what it is for while it isn't, and the button that
/// does it. A finished step is just its name and a check mark.
struct StepRow<Action: View>: View {
    let title: String
    let done: Bool
    let detail: String?
    let action: Action

    init(title: String, done: Bool, detail: String? = nil, @ViewBuilder action: () -> Action) {
        self.title = title
        self.done = done
        self.detail = detail
        self.action = action()
    }

    var body: some View {
        HStack(alignment: detail == nil || done ? .center : .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? .green : .secondary)
                .font(.title3)
                .accessibilityLabel(done ? "Done" : "To do")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail, !done {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if !done { action }
        }
        .padding(.vertical, 2)
    }
}

extension StepRow where Action == EmptyView {
    init(title: String, done: Bool, detail: String? = nil) {
        self.init(title: title, done: done, detail: detail) { EmptyView() }
    }
}
