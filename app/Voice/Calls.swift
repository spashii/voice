import AppKit
import KeyboardShortcuts
import Observation
import SwiftUI
import VoiceCore

/// Call recording in the app: notices calls, offers to record them, records through
/// CallRecorder on the call shortcut or the menu, and starts and stops recordings for
/// agents over MCP. Whisper is the dictation pipeline's, so dictating during a call queues
/// behind the call's chunks rather than loading a second model onto the GPU.
@MainActor @Observable
final class CallsModel {
    /// On by default; off means no prompt, though the menu still offers to record.
    var askToRecord: Bool {
        didSet {
            UserDefaults.standard.set(askToRecord, forKey: "askToRecordCalls")
            updatePrompt()
        }
    }
    /// What Settings offers under Record from: Blend's mixes, the system default and the
    /// other inputs, listed off the main thread.
    private(set) var sources: [CallSource] = [.systemDefault]
    /// The input chosen under Record from, by UID, empty for the system default. Nil until
    /// one is chosen, so the split mix records as soon as Blend has one.
    var chosenSource: String? {
        didSet {
            UserDefaults.standard.set(chosenSource, forKey: "callSource")
            source = CallSources.choose(sources, chosen: chosenSource)
        }
    }
    /// What the next call records from: the chosen input, or the automatic one while the
    /// chosen one isn't connected.
    private(set) var source = CallSource.systemDefault
    /// Apps in a call now, by the detector.
    private(set) var detected: [DetectedCall] = []
    private(set) var recording: Call? {
        didSet {
            if (oldValue == nil) != (recording == nil) { model?.refreshIndicator() }
        }
    }
    /// The recording's newest lines for its pill, as they are transcribed. Emptied after
    /// `quiet` with nothing new, which shrinks the pill back until the next line.
    private(set) var live = LiveCallLines()
    /// Between the shortcut and the recorder starting, so a second press doesn't start a
    /// second call.
    private(set) var starting = false
    /// A stopped or cut-off call's chunks still going through whisper.
    private(set) var transcribing = false
    private(set) var recent: [Call] = []
    private(set) var error: String?
    /// Set while a call app reads the mix being recorded or offered: Blend leaves a mix's
    /// readers out of its System audio, so that app's side of the call records as silence.
    private(set) var warning: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var store: CallStore?
    @ObservationIgnored private var recorder: CallRecorder?
    @ObservationIgnored private var detector: CallDetector?
    /// Apps whose prompt got "Not now", until their call ends.
    @ObservationIgnored private var dismissed: Set<String> = []
    /// The app a recording was started for: when its call ends, the recording does too.
    @ObservationIgnored private var recordingFor: String?
    @ObservationIgnored private lazy var prompt = CallPrompt(calls: self)
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var quieting: Task<Void, Never>?
    private static let quiet: Duration = .seconds(20)

    init() {
        askToRecord = UserDefaults.standard.object(forKey: "askToRecordCalls") as? Bool ?? true
        chosenSource = UserDefaults.standard.string(forKey: "callSource")
    }

    /// Marks calls a crash or quit cut off, rebuilds their transcripts from their audio, and
    /// starts watching for calls.
    func launch(model: AppModel) {
        self.model = model
        Task {
            do {
                let store = try await Task.detached { try CallStore(url: Paths.database) }.value
                let interrupted = try store.liveCalls().filter { call in
                    call.audioPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                }
                // Those with audio stay live until their rebuild finishes or fails them.
                try store.failInterruptedCalls(except: Set(interrupted.map(\.id)))
                self.store = store
                // Before the rebuilds and conversions below, which would spend their time on
                // calls about to be deleted. The store didn't exist when the app first pruned.
                model.pruneHistory()
                let recorder = CallRecorder(store: store) { call in
                    Task { @MainActor in self.inputWentAway(call) }
                }
                self.recorder = recorder
                refreshRecent()
                transcribing = true
                for call in interrupted {
                    _ = try? await recorder.rebuild(call.id, transcriber: model.currentPipeline().transcriber,
                                                    whisper: model.preferences.whisper)
                }
                transcribing = false
                refreshRecent()
                // Calls that finished before audio was compressed, or whose conversion was
                // cut off by quitting. Runs off the main thread.
                await recorder.compressFinishedCalls()
                refreshRecent()
            } catch {
                self.error = "Can't open the call history: \(error)"
            }
        }
        let detector = CallDetector { [weak self] calls in
            Task { @MainActor in self?.detectedChanged(calls) }
        }
        detector.start()
        self.detector = detector
        KeyboardShortcuts.onKeyUp(for: .recordCall) { [weak self] in self?.toggleRecording() }
        Task { await refreshSources() }
        // The call app can switch its microphone at any point in a call, so this is polled
        // rather than checked once.
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkMixReaders()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Closes the WAV without waiting for the transcript; the next launch finishes it from
    /// the file, which keeps quitting quick.
    func shutDown() async {
        detector?.stop()
        await recorder?.abandon()
    }

    /// Blend's devices.json and the connected inputs, read off the main thread: listing
    /// inputs asks coreaudiod, which can hang.
    func refreshSources() async {
        sources = await Task.detached(priority: .utility) {
            CallSources.all(BlendDevices.load(), devices: InputDevices.list())
        }.value
        source = CallSources.choose(sources, chosen: chosenSource)
    }

    /// The call shortcut: stops the recording, or starts one now. A call app in a call names
    /// the recording and ends it when its call ends; with none, it records until stopped.
    func toggleRecording() {
        if recording != nil {
            Task { await stop() }
        } else if !starting {
            recordFromMenu(detected.first)
        }
    }

    func record(_ app: DetectedCall? = nil, title: String? = nil) async throws -> Call {
        guard let recorder, let model else { throw VoiceError.store("Voice is still starting.") }
        if let recording { return recording }
        guard !starting else { throw VoiceError.store("A call recording is already starting.") }
        starting = true
        defer { starting = false }
        await refreshSources()
        let source = source
        let call: Call
        do {
            call = try await recorder.start(source, transcriber: model.currentPipeline().transcriber,
                                            whisper: model.preferences.whisper, appBundleID: app?.bundleID,
                                            appName: app?.name, title: title)
        } catch {
            // On screen too: a recording an agent asked for has no menu open to show it, and
            // a call failed at the start (a split mix missing a side) is in the history now.
            self.error = "\(error)"
            model.notice("\(error)")
            refreshRecent()
            throw error
        }
        recording = call
        recordingFor = app?.bundleID
        error = nil
        follow(call)
        updatePrompt()
        if let chosenSource, chosenSource != source.id {
            model.notice("The input chosen for calls isn't connected, so \(source.name) is recording.")
        }
        return call
    }

    func recordFromMenu(_ app: DetectedCall?) {
        Task {
            do {
                _ = try await record(app)
            } catch {
                self.error = "\(error)"
            }
        }
    }

    @discardableResult
    func stop() async -> Call? {
        guard recording != nil, let recorder else { return nil }
        // The menu stops showing the call at once; the tail is transcribed after.
        recording = nil
        recordingFor = nil
        unfollow()
        transcribing = true
        let call = await recorder.stop()
        transcribing = false
        refreshRecent()
        updatePrompt()
        return call
    }

    /// The recorder has already finished the call as failed and kept its audio.
    private func inputWentAway(_ call: Call?) {
        guard recording != nil else { return }
        recording = nil
        recordingFor = nil
        unfollow()
        let text = "The input went away, so the call stopped recording. What was recorded is kept."
        error = text
        model?.notice(text)
        refreshRecent()
        updatePrompt()
    }

    /// Reads the call's segments as they are written, from the store's wait, the one
    /// wait_for_transcript uses. The wait looks at the file twice a second, off the main
    /// thread; only new lines come back to it.
    private func follow(_ call: Call) {
        unfollow()
        live = LiveCallLines(speakers: call.speakers)
        guard let store else { return }
        following = Task.detached(priority: .utility) { [weak self] in
            var cursor: Int64 = 0
            while !Task.isCancelled {
                guard let batch = try? await store.waitForSegments(call.id, after: cursor, timeout: .seconds(60))
                else { return }
                cursor = batch.cursor
                if !batch.segments.isEmpty { await self?.show(batch.segments) }
                if batch.call?.status.isLive != true { return }
            }
        }
    }

    private func show(_ segments: [CallSegment]) {
        guard recording != nil else { return }
        live.add(segments)
        quieting?.cancel()
        quieting = Task { [weak self] in
            try? await Task.sleep(for: Self.quiet)
            guard !Task.isCancelled else { return }
            self?.live.clear()
        }
    }

    private func unfollow() {
        following?.cancel()
        following = nil
        quieting?.cancel()
        quieting = nil
        live.clear()
    }

    func notNow(_ app: DetectedCall) {
        dismissed.insert(app.bundleID)
        updatePrompt()
    }

    /// Deletes calls that started before the cutoff, with their audio. Never one that is
    /// still recording or being transcribed.
    func pruneHistory(before cutoff: Date) {
        guard let store else { return }
        do {
            if try store.prune(before: cutoff) > 0 { refreshRecent() }
        } catch {
            self.error = "Couldn't clear old calls: \(error)"
        }
    }

    func copyTranscript(_ call: Call) {
        guard let text = try? store?.transcript(call.id), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Whether a call's chunks hold whisper. Dictation then skips the Ollama fix: the fix
    /// unloads whisper for Ollama's model, the call's next chunk reloads it, and the two
    /// together are more than the GPU has.
    var usesWhisper: Bool { recording != nil || transcribing }

    /// The app the prompt asks about: the first in a call that wasn't dismissed.
    var promptApp: DetectedCall? {
        guard askToRecord, recording == nil else { return nil }
        return detected.first { !dismissed.contains($0.bundleID) }
    }

    private func detectedChanged(_ calls: [DetectedCall]) {
        detected = calls
        let ids = Set(calls.map(\.bundleID))
        dismissed.formIntersection(ids)
        if let app = recordingFor, !ids.contains(app) {
            Task { await stop() }
        }
        updatePrompt()
    }

    /// Warns once when a call app starts reading the mix, while a call records or the prompt
    /// shows; the menu keeps the warning for as long as it holds.
    private func checkMixReaders() async {
        let apps = recording != nil || promptApp != nil ? detected : []
        guard source.fromBlend, let uid = source.deviceUID, !apps.isEmpty else {
            warning = nil
            return
        }
        let readers = await Task.detached(priority: .utility) { CallApps.readers(ofDeviceUID: uid) }.value
        let text = apps.first { CallApps.reads($0, readers: readers) }.map { CallSource.readsMixNotice($0.name) }
        if let text, text != warning { model?.notice(text) }
        warning = text
    }

    private func updatePrompt() {
        if promptApp != nil { prompt.show() } else { prompt.hide() }
    }

    private func refreshRecent() {
        recent = (try? store?.calls(limit: 3)) ?? []
    }
}

extension CallsModel: RecordingControl {
    nonisolated func startRecording(title: String?) async throws -> Call {
        try await record(title: title)
    }

    nonisolated func stopRecording() async throws -> Call {
        guard let call = await stop() else { throw VoiceError.store("No call is being recorded.") }
        return call
    }
}

/// "Record this call?" in a pill like the dictation indicator, just below where that one
/// sits. It never takes focus from the call.
@MainActor
final class CallPrompt {
    private unowned let calls: CallsModel
    private var panel: NSPanel?
    private static let size = NSSize(width: 340, height: 44)

    init(calls: CallsModel) {
        self.calls = calls
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.maxY - Self.size.height - 52))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: CallPromptView().environment(calls))
        return panel
    }
}

struct CallPromptView: View {
    @Environment(CallsModel.self) private var calls

    var body: some View {
        HStack(spacing: 8) {
            if let app = calls.promptApp {
                Image(systemName: "phone.fill").foregroundStyle(.green)
                Text("Record this call?")
                Text(app.name).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button("Not now") { calls.notNow(app) }
                    .controlSize(.small)
                // No default action: the panel never takes focus from the call, so Return
                // goes to the call app, and a highlighted button would suggest otherwise.
                Button("Record") { calls.recordFromMenu(app) }
                    .controlSize(.small)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The menu's call items: Record at any time, the clock and Stop while a call records, each
/// with the call shortcut.
struct CallMenuItems: View {
    @Environment(AppModel.self) private var model
    @Environment(CallsModel.self) private var calls

    var body: some View {
        let keys = KeyboardShortcuts.getShortcut(for: .recordCall).map { "  \($0)" } ?? ""
        if let call = calls.recording {
            Text("Recording call " + AppModel.clock(Date().timeIntervalSince(call.startedAt)))
            if model.preferences.runPrompt {
                Text("Whisper only during calls")
            }
            Button("Stop recording" + keys) { Task { await calls.stop() } }
        } else {
            let app = calls.detected.first
            Button((app == nil ? "Record a call" : "Record this call") + keys) { calls.recordFromMenu(app) }
                .disabled(calls.starting)
        }
        if let warning = calls.warning {
            Text(warning)
        }
        if let error = calls.error {
            Text(error)
        }
    }
}

/// Recent calls, after the dictations, each with a phone; a click copies the transcript.
struct RecentCalls: View {
    @Environment(CallsModel.self) private var calls

    var body: some View {
        ForEach(calls.recent) { call in
            Button {
                calls.copyTranscript(call)
            } label: {
                Label(Self.label(call), systemImage: "phone")
            }
            .help("Click to copy the transcript")
        }
    }

    private static func label(_ call: Call) -> String {
        let name = call.title ?? call.appName.map { "\($0) call" } ?? "Call"
        let time = call.startedAt.formatted(date: .omitted, time: .shortened)
        let minutes = call.endedAt.map { " · \(max(1, Int($0.timeIntervalSince(call.startedAt) / 60))) min" } ?? ""
        let state = call.status == .failed ? " · failed" : call.status.isLive ? " · recording" : ""
        return "\(name), \(time)\(minutes)\(state)"
    }
}

/// Settings: the shortcut, what a call records from, and whether to ask. Anything more shows
/// only when it matters: the rule for a split mix, and a call app reading the mix.
struct CallsSettingsSection: View {
    @Environment(CallsModel.self) private var calls

    var body: some View {
        @Bindable var calls = calls
        let selected = calls.chosenSource ?? calls.source.id
        Section("Calls") {
            KeyboardShortcuts.Recorder("Shortcut:", name: .recordCall)
            Picker("Record from", selection: Binding(get: { selected }, set: { calls.chosenSource = $0 })) {
                ForEach(calls.sources) { source in
                    Text(source.label).tag(source.id)
                }
                if !calls.sources.contains(where: { $0.id == selected }) {
                    Text("Not connected").tag(selected)
                }
            }
            if calls.sources.first(where: { $0.id == selected })?.split == true {
                Text(CallSource.mixRule)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let warning = calls.warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Toggle("Ask to record calls", isOn: $calls.askToRecord)
        }
        .task { await calls.refreshSources() }
    }
}
