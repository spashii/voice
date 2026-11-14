import AVFoundation
import KeyboardShortcuts
import os
import ServiceManagement
import SwiftUI
import VoiceCore

extension KeyboardShortcuts.Name {
    /// The shortcut OpenSuperWhisper used, so the habit carries over.
    /// The only way to start and stop: nothing else ends a recording, so no stray key can
    /// throw one away.
    /// A development build has none, so it never answers the installed app's key.
    static let dictate = Self("dictate", initial: BuildFlavor.isDev ? nil : .init(.backtick, modifiers: [.option]))
    /// Starts a call recording whether or not a call app is in a call, and stops it. Its own
    /// key, so dictating stays on Option+` during a call.
    static let recordCall = Self("recordCall", initial: BuildFlavor.isDev ? nil : .init(.backtick, modifiers: [.option, .shift]))
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
        /// After a paste, the words the retries and the fix changed, for a moment.
        case edits([WordDiff.Change])
    }

    enum NoticeAction: Equatable {
        case allowAccessibility
        case activate

        var title: String {
            switch self {
            case .allowAccessibility: "Allow\u{2026}"
            case .activate: "Activate in Browser"
            }
        }
    }

    var phase: Phase = .idle {
        // The pill after a call sits where this one shows, so it gives way.
        didSet { if phase != .idle { calls?.dismissStoppedCall() } }
    }
    var level: Float = 0
    /// The text of the chunks decoded so far while recording, for the indicator.
    var liveText = ""
    /// Ticks once a second while recording, for the menu's timer.
    var now = Date()
    var recent: [Dictation] = []
    /// What Ollama has installed; nil while it isn't running.
    var ollamaModels: [String]?
    /// Whether Apple's on-device model can answer, and if not why; refreshed with `ollamaModels`.
    var appleModelState = AppleModel.state
    var appleModelAvailable: Bool { appleModelState == .available }
    var devices: [InputDevice] = []
    /// The app holding macOS secure keyboard input, which silences global shortcuts; nil when none does.
    private(set) var secureInput: SecureInput.Holder?
    var microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    var accessibilityAllowed = Paster.hasAccess
    var openAtLogin = SMAppService.mainApp.status == .enabled
    let preferences = Preferences()
    let downloads = ModelDownloads()
    let agents = AgentAccess()
    let updates = Updates()
    let activation: Activation
    /// Held only while Dictate may record.
    /// What a locked Dictate keeps off.
    private(set) var lock = LockPolicy(unlocked: false)
    @ObservationIgnored let hotkeys = Hotkeys(
        enable: { KeyboardShortcuts.enable(.dictate, .recordCall) },
        disable: { KeyboardShortcuts.disable(.dictate, .recordCall) })

    /// Set at launch; dictation asks it whether a call is using whisper.
    @ObservationIgnored weak var calls: CallsModel?
    @ObservationIgnored private var recorder: Recorder!
    @ObservationIgnored private var store: Store?
    @ObservationIgnored private var sweeping = false
    @ObservationIgnored private var sweepAgain = false
    @ObservationIgnored private var sweepNow: Date?
    @ObservationIgnored private var sweptPolicy: RetentionPolicy?
    /// Bumped when the policy changes, so a running sweep under the old one stops early.
    @ObservationIgnored private let sweepGeneration = OSAllocatedUnfairLock(initialState: 0)
    @ObservationIgnored private var pipeline: Pipeline?
    @ObservationIgnored private var pipelineModel: WhisperModel?
    @ObservationIgnored private var startTask: Task<Bool, Never>?
    @ObservationIgnored private var live: LiveTranscription?
    @ObservationIgnored private var fellBackToDefault = false
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private lazy var indicator = Indicator(model: self)
    @ObservationIgnored private lazy var mainWindow = MainWindow(model: self)

    init(activation: Activation = Activation(store: KeychainActivationStore())) {
        self.activation = activation
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

    /// What Dictate is doing now, from the dictation's phase and the calls.
    var activity: Activity {
        var activity = Activity()
        switch phase {
        case .recording: activity.dictationRecording = true
        case .transcribing: activity.dictationTranscribing = true
        case .cleaningUp: activity.fixing = true
        case .idle, .notice, .edits: break
        }
        if let calls {
            activity.callRecording = calls.recording != nil || calls.starting
            activity.callTranscribing = calls.transcribing || calls.isImporting
            activity.callAppInCall = !calls.detected.isEmpty
            activity.titling = calls.ollamaTitling
        }
        return activity
    }

    /// Installs a staged update the first time Dictate is quiet. Until then it watches the
    /// phase and the calls, and checks again when either changes.
    func installUpdateWhenQuiet() {
        guard updates.hasStagedUpdate else { return }
        if activity.isQuiet {
            updates.installStagedUpdate()
            return
        }
        withObservationTracking { _ = activity } onChange: { [weak self] in
            Task { @MainActor in self?.installUpdateWhenQuiet() }
        }
    }

    var isWorking: Bool {
        phase == .transcribing || phase == .cleaningUp
    }

    /// The model that fixes the text and titles calls.
    var effectiveModel: LocalModel {
        #if DEBUG
        if let snapshotModel { return snapshotModel }
        #endif
        return preferences.effectiveModel
    }

    var setupComplete: Bool {
        #if DEBUG
        if snapshotSetupComplete { return true }
        #endif
        return microphoneAllowed && accessibilityAllowed && downloads.state(preferences.whisperModel) == .ready
    }

    /// The menu bar glyph, from Assets: three pills like the app icon, outlined when idle,
    /// the center one filled while dictating, dots while working, and all filled with a dot
    /// while a call records. A dictation shows over the call, which the indicator still shows.
    var menuBarImage: String {
        switch phase {
        case .recording: "MenuBarDictating"
        case .transcribing, .cleaningUp: "MenuBarWorking"
        case .idle, .notice, .edits: calls?.recording != nil ? "MenuBarCall" : "MenuBarIdle"
        }
    }

    /// The first line of the menu.
    var statusText: String {
        switch phase {
        case .idle, .notice, .edits: "Ready"
        case .recording(_, let began): "Listening " + Self.clock(now.timeIntervalSince(began))
        case .transcribing: "Transcribing"
        case .cleaningUp: "Fixing the text"
        }
    }

    func launch() {
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in self?.toggle() }
        applyLock()
        do {
            store = try Store(url: Paths.database)
            // Read before the sweep starts: a long prune holds the store.
            recent = store?.recent(5) ?? []
            applyRetention()
        } catch {
            show("Can't open the history: \(error)")
        }
        setDefaultLoginItem()
        refreshDevices()
        agents.launch()
        updates.onStaged = { [weak self] in self?.installUpdateWhenQuiet() }
        installUpdateWhenQuiet()
        // Retention also runs when the app stays open for days.
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                applyRetention()
            }
        }
        // Ollama can start or stop at any time; a localhost check every half minute keeps
        // the model status honest without asking on every keypress.
        Task {
            while !Task.isCancelled {
                await refreshOllama()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // One flag check every few seconds; the app holding it is looked up only while it is set.
        Task {
            while !Task.isCancelled {
                let holder = lock.showsRecordingMenu ? SecureInput.holder() : nil
                if holder != secureInput { secureInput = holder }
                try? await Task.sleep(for: .seconds(4))
            }
        }
        if setupComplete {
            // Loaded ahead, so the first dictation doesn't wait for it.
            let pipeline = currentPipeline()
            Task { try? await pipeline.transcriber.load() }
            recoverRecordings()
        } else {
            if downloads.state(preferences.whisperModel) == .missing { downloads.download(preferences.whisperModel) }
        }
        // The model keeps downloading behind Welcome, so Setup is ready once Dictate is activated.
        if !activation.isActivated {
            openMainWindow(.welcome)
        } else if !setupComplete {
            openMainWindow(.setup)
        }
        #if DEBUG
        // Lets a test start a recording without the shortcut, then kill Dictate mid-way.
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
        case .idle, .notice, .edits:
            guard requireActivation() else { return }
            start(preferences.runPrompt && calls?.usesWhisper != true ? .fix : .plain)
        case .recording: stop()
        case .transcribing, .cleaningUp: break
        }
    }

    func copy(_ dictation: Dictation) {
        TranscriptCopy.copy(.dictation(dictation), in: nil)
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
                store?.setOrigin(retried.id, dictation.origin, createdAt: dictation.createdAt,
                                 timeZone: dictation.timeZone)
                store?.delete(dictation.id)
                recent = store?.recent(5) ?? recent
                applyRetention()
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
        #if DEBUG
        if snapshotModelsHeld { return }
        #endif
        appleModelState = AppleModel.state
        ollamaModels = try? await Ollama().installedModels(at: preferences.ollamaEndpoint)
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
        calls?.refreshCapturePermission()
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

    /// Deletes what the retention choices allow, off the main thread. Never two sweeps at
    /// once: a request during a sweep runs one more after it. `now` is the moment a
    /// confirmation counted at, so what goes matches the numbers shown.
    func applyRetention(now: Date? = nil) {
        let targets = calls?.retentionTargets
        guard store != nil || targets != nil else { return }
        calls?.setDeletesAudioWhenDone(preferences.retention.audio == .untilTranscribed)
        let policy = preferences.retention
        if let sweptPolicy, sweptPolicy != policy { sweepGeneration.withLock { $0 += 1 } }
        sweptPolicy = policy
        if sweeping {
            sweepAgain = true
            sweepNow = now ?? sweepNow
            return
        }
        sweeping = true
        let dictations = store
        let generation = sweepGeneration.withLock { $0 }
        let generations = sweepGeneration
        let at = now ?? Date()
        Task {
            let counts = await Task.detached(priority: .utility) {
                RetentionSweep.run(policy, dictations: dictations, calls: targets?.store,
                                   deleteCallAudio: targets?.deleteAudio, now: at,
                                   shouldContinue: { generations.withLock { $0 } == generation })
            }.value
            sweeping = false
            if !counts.isEmpty {
                Self.retentionLog.info("deleted \(counts.recordings, privacy: .public) recordings and the audio of \(counts.audioOnly, privacy: .public) more")
                refreshRecents()
                mainWindow.reloadHistory()
            }
            if sweepAgain {
                sweepAgain = false
                let next = sweepNow
                sweepNow = nil
                applyRetention(now: next)
            }
        }
    }

    private static let retentionLog = Logger(subsystem: "io.github.spashii.voice", category: "retention")

    /// What a policy would delete now, counted off the main thread; empty before any database is open.
    private func retentionPreview(_ policy: RetentionPolicy, now: Date) async -> RetentionCounts {
        let targets = calls?.retentionTargets
        let dictations = store
        guard dictations != nil || targets != nil else { return RetentionCounts() }
        return await Task.detached(priority: .userInitiated) {
            RetentionSweep.preview(policy, dictations: dictations, calls: targets?.store, now: now)
        }.value
    }

    /// A picker changed. Asks first when the new policy would delete something now; the
    /// picker keeps showing the stored choice until it is confirmed.
    func setRetention(audio: AudioRetention? = nil, transcripts: TranscriptRetention? = nil) {
        var choices = preferences.retentionChoices
        if let audio { choices.audio = audio }
        if let transcripts { choices.transcripts = transcripts }
        changeRetention(choices, developerMode: preferences.developerMode, alert: RetentionText.deleteOldRecordings)
    }

    /// The Developer mode switch. Turning it off lets the policy delete again, and an audio
    /// choice of Forever falls back to the default, so what that would delete is confirmed.
    func setDeveloperMode(_ on: Bool) {
        guard preferences.developerMode != on else { return }
        if on {
            preferences.developerMode = true
            applyRetention()
            return
        }
        changeRetention(preferences.retentionChoices.afterDeveloperModeOff(), developerMode: false,
                        alert: RetentionText.turnOffDeveloperMode)
    }

    private func changeRetention(_ choices: RetentionChoices, developerMode: Bool,
                                 alert: @escaping (RetentionCounts, RetentionPolicy) -> RetentionText.Alert) {
        let policy = RetentionPolicy.effective(audio: choices.audio, transcripts: choices.transcripts,
                                               developerMode: developerMode)
        Task {
            let now = Date()
            let counts = await retentionPreview(policy, now: now)
            if !counts.isEmpty, !(await confirm(alert(counts, policy))) {
                retentionRevision += 1
                return
            }
            preferences.retentionChoices = choices
            preferences.developerMode = developerMode
            applyRetention(now: now)
        }
    }

    /// Bumped when a confirmation is cancelled, so a picker that already moved shows the stored value again.
    private(set) var retentionRevision = 0

    /// The confirmation as the app shows it, one place so the app-shots draw the same alert.
    static func retentionAlert(_ text: RetentionText.Alert) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.title
        alert.informativeText = text.body
        let destructive = alert.addButton(withTitle: text.confirm)
        destructive.hasDestructiveAction = true
        alert.addButton(withTitle: text.cancel)
        return alert
    }

    private func confirm(_ text: RetentionText.Alert) async -> Bool {
        let alert = Self.retentionAlert(text)
        if let window = mainWindow.visibleWindow {
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    func noticeAction(_ action: NoticeAction) {
        switch action {
        case .allowAccessibility: Paster.askForAccess()
        case .activate: beginActivation()
        }
        phase = .idle
        refreshIndicator()
    }

    /// Shows the indicator while a dictation, a notice or a call needs it, and hides it once
    /// none does.
    func refreshIndicator() {
        if phase == .idle && calls?.recording == nil { indicator.hide() } else { indicator.show() }
    }

    private func start(_ mode: Dictation.Mode) {
        noticeTask?.cancel()
        calls?.yieldToDictation()
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
                show("Allow the microphone for Dictate in System Settings.")
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
        // Retries after this moment are what the paste waits for.
        let stoppedAt = ContinuousClock.now
        tickTask?.cancel()
        phase = .transcribing
        let recordMs = Int(Date().timeIntervalSince(began) * 1000)
        // A call that started mid-dictation holds whisper too.
        let cleanup = mode == .fix && calls?.usesWhisper != true ? preferences.cleanup(using: effectiveModel) : nil
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
                    stoppedAt: stoppedAt, onStage: { stage in
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
    /// Dictate is otherwise idle: whisper reloading while the prompt's model runs would run the
    /// GPU out of memory. Nothing recovered is pasted.
    private func recoverRecordings() {
        guard let store else { return }
        let orphans = Recovery.orphans(in: Paths.recordings, known: store.audioPaths())
        guard !orphans.isEmpty else { return }
        Task {
            for url in orphans {
                while phase != .idle {
                    if case .notice = phase { break }
                    if case .edits = phase { break }
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
            applyRetention()
        }
    }

    /// After History renames or deletes a recording.
    func refreshRecents() {
        recent = store?.recent(5) ?? recent
        calls?.refreshRecent()
    }

    private func finish(_ dictation: Dictation, inputLost: Bool = false, writeError: String? = nil) async {
        recent = store?.recent(5) ?? recent
        applyRetention()
        let lost = "The microphone went away, so Dictate stopped"
        guard !dictation.finalText.isEmpty else {
            show(writeError.map { "Couldn't write the recording: \($0)" }
                ?? (inputLost ? "\(lost) and heard nothing before it did." : "Heard nothing."))
            return
        }
        // Cmd+V in Dictate's own window would land in History's search field, so the text is
        // copied and the notice starts with that.
        let ownWindow = !PasteDecision.pastes(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                             ownPID: ProcessInfo.processInfo.processIdentifier)
        let pasted: Bool
        if ownWindow {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(dictation.finalText, forType: .string)
            pasted = true
        } else {
            let start = ContinuousClock.now
            pasted = await Paster.paste(dictation.finalText)
            let elapsed = ContinuousClock.now - start
            store?.setPasteTime(dictation.id, ms: Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
        }
        let changes = Self.changes(dictation)
        let copied = ownWindow ? "Copied. " : ""
        if let writeError {
            // Ahead of the rest: the recording is missing its end, and this says why.
            show(copied + "Couldn't keep writing the recording, so only what came before was transcribed: \(writeError)")
        } else if !pasted {
            show("Copied. Allow Dictate in Accessibility to paste for you.", action: .allowAccessibility)
        } else if let error = dictation.error {
            show((ownWindow ? "Copied Whisper's text. " : "Pasted Whisper's text. ") + "Fix the text before pasting failed: \(error)")
            await refreshOllama()
        } else if inputLost {
            show("\(lost) and \(ownWindow ? "copied" : "pasted") what it heard before.")
        } else if fellBackToDefault {
            show(copied + "The chosen microphone isn't connected, so the default one recorded.")
        } else if ownWindow && changes.isEmpty {
            show("Copied.")
        } else if !changes.isEmpty {
            // In Dictate's own window the text is on the clipboard too; the edits are what is worth showing.
            showEdits(changes)
        } else {
            phase = .idle
            refreshIndicator()
        }
    }

    /// What the retries and the fix changed in a dictation's words, retries first. A fix
    /// that only changed capitals still shows, since that is how a name gets put right.
    static func changes(_ dictation: Dictation) -> [WordDiff.Change] {
        let retried = dictation.segments.compactMap(\.retry).filter { $0.kept && $0.changed }
            .flatMap { WordDiff($0.firstText, $0.retriedText ?? "").changes }
        let fixed = (dictation.fixEdits ?? []).filter(\.applied).flatMap { edit in
            let diff = WordDiff(edit.span, edit.replacement, ignoringCase: false).changes
            return diff.isEmpty ? [WordDiff.Change(before: [edit.span], after: [edit.replacement])] : diff
        }
        return retried + fixed
    }

    /// Shown only once the text is pasted, so it never adds to the wait.
    private func showEdits(_ changes: [WordDiff.Change]) {
        phase = .edits(changes)
        indicator.show()
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, case .edits = phase else { return }
            phase = .idle
            refreshIndicator()
        }
    }

    /// The main window, on a pane. It is only ever opened by the person, from the menu or
    /// Cmd+,, and at launch while setup is unfinished.
    func openMainWindow(_ pane: MainPane) {
        guard let calls else { return }
        mainWindow.show(lock.landing(for: pane), calls: calls)
    }

    #if DEBUG
    /// Set by the app-shots run so the window draws as it does on a finished install.
    var snapshotSetupComplete = false

    func unlockForSnapshots() { lock = LockPolicy(activation) }

    /// What Settings, Model shows is set here and never stored: the choice is held in memory
    /// instead of Preferences, which would write it to the defaults, and the refresh that asks
    /// Ollama is switched off so no real model server is contacted.
    private(set) var snapshotModel: LocalModel?
    private var snapshotModelsHeld = false

    func setModelsForSnapshots(apple: AppleModelState, ollama: [String]?, choice: LocalModel) {
        snapshotModelsHeld = true
        appleModelState = apple
        ollamaModels = ollama
        snapshotModel = choice
    }
    #endif

    func openHistory() { openMainWindow(.history) }

    /// Dictate was opened again while running, from Spotlight, Finder or the Dock.
    func reopen() {
        openMainWindow(FirstLaunch.reopenPane(activated: activation.isActivated, setupComplete: setupComplete))
    }

    /// Told when activation changes, so the Dock icon follows it.
    @ObservationIgnored var onActivationChange: (() -> Void)?

    /// After an update: About when the person chose it, a pill when it installed on its own.
    func announceUpdateIfNeeded() {
        let defaults = UserDefaults.standard
        let current = Updates.currentVersion
        let announcement = FirstLaunch.announcement(last: defaults.string(forKey: FirstLaunch.lastLaunchedKey),
                                                    current: current,
                                                    chosenVersion: defaults.string(forKey: FirstLaunch.chosenUpdateKey),
                                                    activated: activation.isActivated)
        defaults.set(current, forKey: FirstLaunch.lastLaunchedKey)
        defaults.removeObject(forKey: FirstLaunch.chosenUpdateKey)
        switch announcement {
        case .none: break
        case .about: openMainWindow(.about)
        case .pill(let version): notice("Updated to \(version)")
        }
    }

    /// Cmd+, and the menu's Settings: the first settings pane.
    func openSettings() { openMainWindow(.setup) }

    /// True when recording may start. Otherwise the pill offers to activate.
    func requireActivation() -> Bool {
        activation.refresh()
        guard (try? RecordingGate.check(activation)) != nil else {
            notice("Activate Dictate to start recording", action: .activate)
            return false
        }
        return true
    }

    /// Opens the activation page in the browser with this Mac's nonce, and Welcome here.
    func beginActivation() {
        activationProblem = nil
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        NSWorkspace.shared.open(activation.pageURL(page: BuildFlavor.activationPage, version: version,
                                                   scheme: BuildFlavor.isDev ? BuildFlavor.urlScheme : nil))
        openMainWindow(.welcome)
    }

    /// Why the last activation failed, kept on Welcome until the next try.
    var activationProblem: String?

    func acceptActivation(url: URL) {
        let wasActivated = activation.isActivated
        let result = activation.accept(url: url)
        // The same link opened again on an activated Mac changes nothing, so it says nothing.
        if wasActivated, case .success = result { return }
        finishActivation(result)
    }

    private func finishActivation(_ result: Result<Void, Activation.Refusal>) {
        switch result {
        case .success:
            activationProblem = nil
            activationChanged()
            openMainWindow(.setup)
            notice("Dictate is activated")
        case .failure(.otherRequest):
            activationProblem = "This activation was for another request. Press Activate in Browser again."
            openMainWindow(.welcome)
        case .failure(.invalid), .failure(.notSaved):
            activationProblem = "Dictate could not use that activation. Press Activate in Browser again."
            openMainWindow(.welcome)
        }
    }

    /// Brings what a locked Dictate keeps off in line with the state: the shortcuts, the agent
    /// server and the call prompt. Runs at launch and after activation.
    func applyLock(force: Bool = false) {
        activation.refresh()
        lock = LockPolicy(activation)
        hotkeys.apply(lock, force: force)
        agents.setUnlocked(lock.startsAgentServer)
        calls?.activationChanged()
    }

    private func activationChanged() {
        applyLock()
        onActivationChange?()
    }

    /// A notice from outside dictation. Mid-dictation the indicator stays on the dictation
    /// and the menu carries the message instead.
    func notice(_ text: String, action: NoticeAction? = nil) {
        switch phase {
        case .idle, .notice, .edits: show(text, action: action)
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
            refreshIndicator()
        }
    }

    /// Open at login is on by default, once: after that the switch in Settings decides.
    private func setDefaultLoginItem() {
        let key = "loginItemDefaulted"
        guard !BuildFlavor.isDev, !UserDefaults.standard.bool(forKey: key) else { return }
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

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
