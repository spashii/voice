import AVFoundation
import KeyboardShortcuts
import ServiceManagement
import SwiftUI
import VoiceCore

extension KeyboardShortcuts.Name {
    /// The shortcut OpenSuperWhisper used, so the habit carries over.
    /// The only way to start and stop: nothing else ends a recording, so no stray key can
    /// throw one away.
    static let dictate = Self("dictate", initial: .init(.backtick, modifiers: [.option]))
}

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case recording(Dictation.Mode, Date)
        case transcribing
        case cleaningUp
        /// Shown in the indicator for a few seconds, then back to idle; some carry a button.
        case notice(String, NoticeAction?)
    }

    enum NoticeAction: Equatable {
        case allowAccessibility
    }

    var phase: Phase = .idle
    var level: Float = 0
    /// The text of the chunks decoded so far while recording, for the indicator.
    var liveText = ""
    /// Ticks once a second while recording, for the menu's timer.
    var now = Date()
    var recent: [Dictation] = []
    /// What Ollama has installed; nil while it isn't running.
    var ollamaModels: [String]?
    var devices: [InputDevice] = []
    var microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    var accessibilityAllowed = Paster.hasAccess
    var openAtLogin = SMAppService.mainApp.status == .enabled
    let preferences = Preferences()
    let downloads = ModelDownloads()
    let agents = AgentAccess()
    let updates = Updates()

    /// Set at launch; dictation asks it whether a call is using whisper.
    @ObservationIgnored weak var calls: CallsModel?
    @ObservationIgnored private var recorder: Recorder!
    @ObservationIgnored private var store: Store?
    @ObservationIgnored private var pipeline: Pipeline?
    @ObservationIgnored private var pipelineModel: WhisperModel?
    @ObservationIgnored private var startTask: Task<Bool, Never>?
    @ObservationIgnored private var live: LiveTranscription?
    @ObservationIgnored private var fellBackToDefault = false
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private lazy var indicator = Indicator(model: self)
    @ObservationIgnored private lazy var setupWindow = SetupWindow(model: self)

    init() {
        recorder = Recorder(onLevel: { [weak self] level in
            Task { @MainActor in self?.level = level }
        }, onInputLost: { [weak self] in
            Task { @MainActor in
                // Stopped as if by the shortcut, so what was recorded is transcribed and pasted.
                if let self, self.isRecording { self.stop() }
            }
        })
    }

    var isRecording: Bool {
        if case .recording = phase { true } else { false }
    }

    var isWorking: Bool {
        phase == .transcribing || phase == .cleaningUp
    }

    /// Whether the prompt will run: it is on, and Ollama has the model.
    var fixesText: Bool {
        guard preferences.runPrompt, let models = ollamaModels else { return false }
        return Self.contains(models, preferences.ollamaModel)
    }

    var setupComplete: Bool {
        microphoneAllowed && accessibilityAllowed && downloads.state(preferences.whisperModel) == .ready
    }

    var menuBarSymbol: String {
        switch phase {
        case .recording: "record.circle.fill"
        case .transcribing, .cleaningUp: "ellipsis.circle"
        case .idle, .notice: "waveform"
        }
    }

    /// The first line of the menu.
    var statusText: String {
        switch phase {
        case .idle, .notice: fixesText ? "Ready" : "Ready, whisper only"
        case .recording(_, let began): "Listening " + Self.clock(now.timeIntervalSince(began))
        case .transcribing: "Transcribing"
        case .cleaningUp: "Fixing the text"
        }
    }

    func launch() {
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in self?.toggle() }
        do {
            store = try Store(url: Paths.database)
            pruneHistory()
            recent = store?.recent(5) ?? []
        } catch {
            show("Can't open the history: \(error)")
        }
        setDefaultLoginItem()
        refreshDevices()
        agents.launch()
        // Ollama can start or stop at any time; a localhost check every half minute keeps
        // the menu's "whisper only" honest without asking on every keypress.
        Task {
            while !Task.isCancelled {
                await refreshOllama()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        if setupComplete {
            // Loaded ahead, so the first dictation doesn't wait for it.
            let pipeline = currentPipeline()
            Task { try? await pipeline.transcriber.load() }
            recoverRecordings()
        } else {
            setupWindow.show()
        }
        #if DEBUG
        // Lets a test start a recording without the shortcut, then kill Voice mid-way.
        if UserDefaults.standard.bool(forKey: "VoiceDebugStartRecording") {
            toggle()
        }
        #endif
    }

    /// A recording in progress is closed and kept, not transcribed: quitting stays quick,
    /// and the next launch finds the file and transcribes it into the history.
    func shutDown() async {
        live?.cancel()
        live = nil
        _ = await recorder.stop()
        await pipeline?.transcriber.unload()
    }

    /// Starts a recording, or stops the one running. Whether the prompt runs is decided at
    /// the start, so changing the setting mid-dictation doesn't change what this one does.
    func toggle() {
        switch phase {
        case .idle, .notice: start(preferences.runPrompt && calls?.usesWhisper != true ? .cleanup : .plain)
        case .recording: stop()
        case .transcribing, .cleaningUp: break
        }
    }

    func copy(_ dictation: Dictation) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dictation.finalText, forType: .string)
    }

    /// A row from the menu's Recent list: copies its text, or tries a failed transcription
    /// again and copies the result.
    func open(_ dictation: Dictation) {
        guard dictation.finalText.isEmpty, dictation.error != nil else {
            copy(dictation)
            return
        }
        guard !isRecording, !isWorking else { return }
        phase = .transcribing
        indicator.show()
        let pipeline = currentPipeline()
        let whisper = preferences.whisper
        Task {
            do {
                let retried = try await pipeline.run(URL(fileURLWithPath: dictation.audioPath), whisper: whisper)
                store?.setOrigin(retried.id, dictation.origin, createdAt: dictation.createdAt)
                store?.delete(dictation.id)
                recent = store?.recent(5) ?? recent
                if retried.finalText.isEmpty {
                    show("Heard nothing in it.")
                } else {
                    copy(retried)
                    show("Transcribed and copied.")
                }
            } catch {
                show("Still couldn't transcribe it: \(error)")
            }
        }
    }

    func refreshOllama() async {
        let url = URL(string: preferences.ollamaURL) ?? URL(string: "http://127.0.0.1:11434")!
        ollamaModels = try? await Ollama().installedModels(at: url)
    }

    /// Lists inputs off the main thread: with coreaudiod stuck, the call would freeze the app.
    func refreshDevices() {
        Task {
            devices = await Task.detached(priority: .userInitiated) { InputDevices.list() }.value
        }
    }

    func refreshPermissions() {
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityAllowed = Paster.hasAccess
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func askForMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task {
                microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
            }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show("Couldn't change Open at login: \(error.localizedDescription)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Under "30 days", deletes dictations and calls older than that, with their audio.
    func pruneHistory() {
        guard preferences.history == .thirtyDays else { return }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        calls?.pruneHistory(before: cutoff)
        guard let store else { return }
        store.prune(before: cutoff)
        recent = store.recent(5)
    }

    func noticeAction(_ action: NoticeAction) {
        switch action {
        case .allowAccessibility: Paster.askForAccess()
        }
        phase = .idle
        indicator.hide()
    }

    private func start(_ mode: Dictation.Mode) {
        noticeTask?.cancel()
        let url = Paths.recordings.appending(path: "\(Int(Date().timeIntervalSince1970 * 1000)).wav")
        let began = Date()
        phase = .recording(mode, began)
        now = began
        level = 0
        liveText = ""
        fellBackToDefault = false
        indicator.show()
        tickTask?.cancel()
        tickTask = Task {
            while !Task.isCancelled, isRecording {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
        let uid = preferences.microphoneUID.isEmpty ? nil : preferences.microphoneUID
        live?.cancel()
        let session = LiveTranscription(transcriber: currentPipeline().transcriber, options: preferences.whisper) {
            [weak self] _, text in
            Task { @MainActor in
                // Only while this recording is the one showing.
                guard let self, case .recording(_, let current) = self.phase, current == began else { return }
                self.liveText = text
            }
        }
        live = session
        startTask = Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                show("Voice needs the microphone: System Settings, Privacy & Security, Microphone.")
                return false
            }
            do {
                fellBackToDefault = !(try await recorder.start(to: url, deviceUID: uid,
                                                                     onSamples: { session.append($0) }))
                return true
            } catch {
                show("Couldn't record: \(error)")
                return false
            }
        }
    }

    private func stop() {
        guard case .recording(let mode, let began) = phase else { return }
        tickTask?.cancel()
        phase = .transcribing
        let recordMs = Int(Date().timeIntervalSince(began) * 1000)
        // A call that started mid-dictation holds whisper too.
        let cleanup = mode == .cleanup && calls?.usesWhisper != true ? preferences.cleanup : nil
        let whisper = preferences.whisper
        let pipeline = currentPipeline()
        var live = self.live
        self.live = nil
        // The model changed mid-recording: the chunks came from the other one.
        if live?.transcriber !== pipeline.transcriber {
            live?.cancel()
            live = nil
        }
        Task { [live] in
            guard await startTask?.value == true else {
                live?.cancel()
                return
            }
            guard let recording = await recorder.stop() else {
                live?.cancel()
                show("Nothing was recorded.")
                return
            }
            // Every recording gets a history row, so none is left behind as a stray file.
            guard recording.duration >= Dictation.tooShort else {
                live?.cancel()
                let reason = recording.writeError.map { "Couldn't write the recording: \($0)" } ?? "Too short to transcribe."
                try? store?.insert(Dictation(audio: recording.url, duration: recording.duration, mode: mode,
                                             whisperModel: pipeline.transcriber.modelName, error: reason))
                show(reason)
                return
            }
            do {
                let dictation = try await pipeline.run(
                    recording.url, recordMs: recordMs, whisper: whisper, cleanup: cleanup, live: live,
                    onStage: { stage in
                        Task { @MainActor in
                            if stage == .cleaningUp, self.phase == .transcribing { self.phase = .cleaningUp }
                        }
                    })
                await finish(dictation, inputLost: recording.inputLost, writeError: recording.writeError)
            } catch {
                try? store?.insert(Dictation(audio: recording.url, duration: recording.duration, mode: mode,
                                             whisperModel: pipeline.transcriber.modelName, error: "\(error)"))
                recent = store?.recent(5) ?? recent
                show("Couldn't transcribe. It's saved: click it under Recent to try again.")
            }
        }
    }

    /// Transcribes recordings the history doesn't know about, one at a time and only while
    /// Voice is otherwise idle: whisper reloading while the prompt's model runs would run the
    /// GPU out of memory. Nothing recovered is pasted.
    private func recoverRecordings() {
        guard let store else { return }
        let orphans = Recovery.orphans(in: Paths.recordings, known: store.audioPaths())
        guard !orphans.isEmpty else { return }
        Task {
            for url in orphans {
                while phase != .idle {
                    if case .notice = phase { break }
                    try? await Task.sleep(for: .seconds(1))
                }
                let duration = Recovery.repairHeader(url) ?? 0
                let recordedAt = Recovery.recordedAt(url)
                let pipeline = currentPipeline()
                guard duration >= Dictation.tooShort else {
                    try? store.insert(Dictation(audio: url, createdAt: recordedAt, duration: duration, mode: .plain,
                                                whisperModel: pipeline.transcriber.modelName,
                                                error: "Too short to transcribe.", origin: .recovered))
                    continue
                }
                do {
                    let dictation = try await pipeline.run(url, whisper: preferences.whisper)
                    store.setOrigin(dictation.id, .recovered, createdAt: recordedAt)
                } catch {
                    try? store.insert(Dictation(audio: url, createdAt: recordedAt, duration: duration, mode: .plain,
                                                whisperModel: pipeline.transcriber.modelName, error: "\(error)",
                                                origin: .recovered))
                }
                recent = store.recent(5)
            }
        }
    }

    private func finish(_ dictation: Dictation, inputLost: Bool = false, writeError: String? = nil) async {
        pruneHistory()
        recent = store?.recent(5) ?? recent
        let lost = "The microphone went away, so Voice stopped"
        guard !dictation.finalText.isEmpty else {
            show(writeError.map { "Couldn't write the recording: \($0)" }
                ?? (inputLost ? "\(lost) and heard nothing before it did." : "Heard nothing."))
            return
        }
        let start = ContinuousClock.now
        let pasted = await Paster.paste(dictation.finalText)
        let elapsed = ContinuousClock.now - start
        store?.setPasteTime(dictation.id, ms: Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
        if let writeError {
            // Ahead of the rest: the recording is missing its end, and this says why.
            show("Couldn't keep writing the recording, so only what came before was transcribed: \(writeError)")
        } else if !pasted {
            show("Copied. Allow Voice in Accessibility to paste for you.", action: .allowAccessibility)
        } else if let error = dictation.error {
            show("Pasted whisper's text; the prompt failed: \(error)")
            await refreshOllama()
        } else if inputLost {
            show("\(lost) and pasted what it heard before.")
        } else if fellBackToDefault {
            show("The chosen microphone isn't connected, so the default one recorded.")
        } else {
            phase = .idle
            indicator.hide()
        }
    }

    /// A notice from outside dictation. Mid-dictation the indicator stays on the dictation
    /// and the menu carries the message instead.
    func notice(_ text: String) {
        switch phase {
        case .idle, .notice: show(text)
        case .recording, .transcribing, .cleaningUp: break
        }
    }

    private func show(_ text: String, action: NoticeAction? = nil) {
        tickTask?.cancel()
        phase = .notice(text, action)
        indicator.show()
        noticeTask?.cancel()
        noticeTask = Task {
            // A notice with a button stays long enough to reach it.
            try? await Task.sleep(for: .seconds(action == nil ? 4 : 10))
            guard !Task.isCancelled, case .notice = phase else { return }
            phase = .idle
            indicator.hide()
        }
    }

    /// Open at login is on by default, once: after that the switch in Settings decides.
    private func setDefaultLoginItem() {
        let key = "loginItemDefaulted"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setOpenAtLogin(true)
    }

    /// Refused while a call records: its chunks keep going to the model it started with, and
    /// a second model loaded beside it is more than the GPU has.
    func chooseWhisperModel(_ choice: WhisperModel) {
        guard choice != preferences.whisperModel else { return }
        if calls?.recording != nil {
            notice("The speech model can't change during a call. Change it once the call ends.")
            return
        }
        preferences.whisperModel = choice
    }

    /// One pipeline per whisper model. While the chosen model downloads, the one already on
    /// disk keeps working, and while a call uses whisper the model stays the one it has.
    func currentPipeline() -> Pipeline {
        let chosen = preferences.whisperModel
        let model = chosen.isDownloaded ? chosen : WhisperModel.allCases.first(where: \.isDownloaded) ?? chosen
        if let pipeline, pipelineModel == model || calls?.usesWhisper == true { return pipeline }
        let old = pipeline
        Task { await old?.transcriber.unload() }
        let pipeline = Pipeline(transcriber: Transcriber(modelURL: model.file, vadModelURL: VADModel.file), store: store)
        self.pipeline = pipeline
        pipelineModel = model
        return pipeline
    }

    /// Ollama lists "name:latest" for a model pulled as "name".
    static func contains(_ models: [String], _ name: String) -> Bool {
        models.contains(name) || models.contains(name + ":latest")
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
