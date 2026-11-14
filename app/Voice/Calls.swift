import AppKit
import KeyboardShortcuts
import Observation
import os
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
    /// Blend mixes whose devices are connected, and every input the Mac has, listed off the
    /// main thread.
    private(set) var mixes: [CallSource] = []
    private(set) var devices: [InputDevice] = []
    /// Apps the call audio picker offers, kept current while Microphones is open.
    private(set) var running: [RunningCallApp] = []
    private(set) var capturePermission = AudioCapture.permission()
    /// Where the other side of a call comes from. Automatic is the call app Dictate finds.
    var audioChoice: CallAudioChoice {
        didSet {
            UserDefaults.standard.set(audioChoice.stored, forKey: "callAudio")
            updateMix()
        }
    }
    /// Takes the call out of the microphone when it plays on speakers. On by default.
    var cancelEcho: Bool {
        didSet { UserDefaults.standard.set(cancelEcho, forKey: "cancelCallEcho") }
    }
    /// The microphone for calls, by UID; empty follows the system default.
    var microphoneUID: String {
        didSet { UserDefaults.standard.set(microphoneUID, forKey: "callMicrophoneUID") }
    }
    /// The Blend mix the next call would read, while one is chosen and connected: a call app
    /// reading it would record as silence.
    private(set) var mix: CallSource?
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
    /// The call that just stopped, while its pill offers the transcript.
    private(set) var stoppedCall: Call?
    /// The pill's Copy Transcript put the transcript on the clipboard.
    private(set) var stoppedCallCopied = false
    /// How far each import being transcribed has got, 0 to 1 by whole percents, keyed by call
    /// id; and the imports still waiting their turn.
    private(set) var importProgress: [String: Double] = [:]
    private(set) var importsWaiting: Set<String> = []

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var store: CallStore?
    @ObservationIgnored private var recorder: CallRecorder?
    @ObservationIgnored private var detector: CallDetector?
    /// Apps whose prompt got "Not now", until their call ends.
    @ObservationIgnored private var dismissed: Set<String> = []
    /// The app a recording was started for: when its call ends, the recording does too.
    @ObservationIgnored private var recordingFor: String?
    @ObservationIgnored private lazy var prompt = CallPrompt(calls: self)
    @ObservationIgnored private lazy var stoppedPill = StoppedCallPanel(calls: self)
    @ObservationIgnored private var stoppedPillHides: Task<Void, Never>?
    @ObservationIgnored private var stoppedPillEnds = ContinuousClock.now
    /// How long the pill offers a stopped call's transcript, at most.
    static let copyOffer: Duration = .seconds(5)
    /// Imports run one file at a time, in the order they were added.
    @ObservationIgnored private var importQueue: [PendingImport] = []
    @ObservationIgnored private var importWorker: Task<Void, Never>?
    @ObservationIgnored private var importRunning: (id: String, task: Task<Call?, Never>)?
    /// Set once Dictate is quitting: the queue is left as it is for the next launch.
    @ObservationIgnored private var importsStopped = false
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var quieting: Task<Void, Never>?
    /// Titles are made one call at a time, in the order the calls ended.
    @ObservationIgnored private var titling: Task<Void, Never>?
    /// The request an Ollama model is answering now; a dictation cancels it.
    @ObservationIgnored private var ollamaRequest: Task<String?, Never>?
    /// An Ollama model is naming a call, so the Mac is not quiet: nothing should restart it.
    private(set) var ollamaTitling = false
    /// Recordings whose title is being made, for History's "Generating title\u{2026}".
    private(set) var naming: Set<String> = []
    /// Recordings with an explicit Generate or Regenerate Title waiting or running. Marked at the
    /// click, so a job queued behind a slow one still shows and can't be queued twice.
    private(set) var requested: Set<String> = []
    func isNaming(_ ref: String) -> Bool { naming.contains(ref) || requested.contains(ref) }
    /// Told a title the moment it is made, before the call leaves `naming`, so History can
    /// show it without a frame of the date in between.
    @ObservationIgnored var titled: (_ callID: String, _ title: String, _ replacing: String??) -> Void = { _, _, _ in }
    private static let quiet: Duration = .seconds(20)

    init() {
        let defaults = UserDefaults.standard
        askToRecord = defaults.object(forKey: "askToRecordCalls") as? Bool ?? true
        cancelEcho = defaults.object(forKey: "cancelCallEcho") as? Bool ?? true
        if let stored = defaults.string(forKey: "callAudio") {
            audioChoice = CallAudioChoice(stored: stored)
            microphoneUID = defaults.string(forKey: "callMicrophoneUID") ?? ""
        } else {
            // From the one "Record from" input of earlier versions. Whether it was a Blend
            // mix is only known once the mixes are listed, in `refreshSources`.
            audioChoice = .automatic
            microphoneUID = ""
        }
    }

    #if DEBUG
    /// The app-shots run shows a call whose title is being made.
    func setNamingForSnapshots(_ ids: Set<String>) { naming = ids }

    /// The app-shots run fills the menu's Recent list without a database behind it.
    func setRecentForSnapshots(_ calls: [Call]) { recent = calls }

    /// The app-shots run shows an import part way through its transcript.
    func setImportProgressForSnapshots(_ progress: [String: Double]) { importProgress = progress }

    /// The app-shots run asks the prompt to show for an app without a detector.
    func promptForSnapshots(_ app: DetectedCall, model: AppModel) {
        self.model = model
        detected = [app]
    }
    #endif

    private func migrateLegacyInput() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "callAudio") == nil else { return }
        // Until the stored input is a connected device the old key stays, and the next refresh tries again.
        guard let migrated = CallAudioChoice.migrate(legacyInput: defaults.string(forKey: "callSource"),
                                                     mixUIDs: Set(mixes.compactMap(\.deviceUID)),
                                                     connectedUIDs: Set(devices.map(\.uid))) else { return }
        audioChoice = migrated.choice
        microphoneUID = migrated.microphoneUID
        defaults.removeObject(forKey: "callSource")
    }

    /// Marks calls a crash or quit cut off, rebuilds their transcripts from their audio, and
    /// starts watching for calls.
    func launch(model: AppModel) {
        self.model = model
        Task {
            do {
                let store = try await Task.detached { try CallStore(url: Paths.database) }.value
                let live = try store.liveCalls().filter { call in
                    call.audioPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                }
                let interrupted = live.filter { $0.fileName == nil }
                // An import that kept its copy is read again through the import queue, which
                // shows its progress and lets it be cancelled or deleted.
                let resumed = live.filter { $0.fileName != nil }
                // Those with audio stay live until their rebuild finishes or fails them.
                try store.failInterruptedCalls(except: Set(live.map(\.id)))
                self.store = store
                let recorder = CallRecorder(store: store, onInputLost: { call in
                    Task { @MainActor in self.inputWentAway(call) }
                }, onNotice: { text in
                    Task { @MainActor in self.model?.notice(text) }
                })
                self.recorder = recorder
                // The store didn't exist when the app first applied retention. Before the
                // rebuilds and conversions below, which would spend their time on calls
                // about to be deleted.
                model.applyRetention()
                recorder.sweepPartials()
                for call in resumed {
                    importsWaiting.insert(call.id)
                    importQueue.append(PendingImport(callID: call.id))
                }
                refreshRecent()
                transcribing = true
                for call in interrupted {
                    let rebuilt = try? await recorder.rebuild(call.id, transcriber: model.currentPipeline().transcriber,
                                                              whisper: model.preferences.whisper)
                    if rebuilt != nil { title(call.id) }
                }
                transcribing = false
                // Rebuilt calls are finished now, so Until transcribed may take their audio.
                model.applyRetention()
                runImports()
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
        // An import is cancelled without failing its row, and its worker is awaited, so whisper
        // is idle when the model is unloaded. The next launch reads the stored copy again.
        importsStopped = true
        importQueue.removeAll()
        importRunning?.task.cancel()
        await importWorker?.value
    }

    /// Blend's devices.json, the connected inputs and the permission, read off the main
    /// thread: asking coreaudiod can hang.
    func refreshSources() async {
        let found = await Task.detached(priority: .utility) {
            (CallSources.all(BlendDevices.load(), devices: InputDevices.list()), InputDevices.list(),
             AudioCapture.permission())
        }.value
        mixes = found.0.filter(\.fromBlend)
        devices = found.1
        capturePermission = found.2
        migrateLegacyInput()
        updateMix()
    }

    func refreshCapturePermission() {
        capturePermission = AudioCapture.permission()
    }

    /// Shows macOS's question the first time; after a refusal only System Settings can
    /// change the answer, so it opens there.
    func askForCaptureAccess() {
        guard capturePermission != .denied else {
            NSWorkspace.shared.open(AudioCapture.settingsURL)
            return
        }
        Task {
            let answer = await AudioCapture.request()
            refreshCapturePermission()
            // macOS wouldn't say, so the answer is for the person to give there.
            if answer == .unknown, capturePermission != .authorized {
                NSWorkspace.shared.open(AudioCapture.settingsURL)
            }
        }
    }

    /// Running apps with what each does with sound, for the picker.
    func refreshRunning() async {
        running = await Task.detached(priority: .utility) { CallApps.running() }.value
    }

    private func updateMix() {
        if case .blendMix(let uid) = audioChoice {
            mix = mixes.first { $0.deviceUID == uid }
        } else {
            mix = nil
        }
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
        guard let recorder, let model else { throw VoiceError.store("Dictate is still starting.") }
        try RecordingGate.check(model.activation)
        if let recording { return recording }
        guard !starting else { throw VoiceError.store("A call recording is already starting.") }
        dismissStoppedCall()
        // A call's chunks load whisper as a dictation does.
        yieldToDictation()
        starting = true
        defer { starting = false }
        await refreshSources()
        await refreshRunning()
        let plan = CallPlanner.plan(CallPlanner.Inputs(
            choice: audioChoice, microphoneUID: microphoneUID, detected: detected, running: running.map(\.target),
            mixes: mixes, devices: devices, permission: capturePermission, cancelEcho: cancelEcho,
            ownBundleID: Bundle.main.bundleIdentifier), appStarted: app)
        let call: Call
        do {
            let started = try await recorder.start(plan, transcriber: model.currentPipeline().transcriber,
                                                   whisper: model.preferences.whisper, appBundleID: app?.bundleID,
                                                   appName: app?.name, title: title)
            call = started.call
            if !started.notices.isEmpty { model.notice(started.notices.joined(separator: " ")) }
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
        return call
    }

    func recordFromMenu(_ app: DetectedCall?) {
        guard model?.requireActivation() != false else { return }
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
        model?.applyRetention()
        updatePrompt()
        if let call {
            title(call.id)
            offerTranscript(call)
        }
        return call
    }

    /// The call pill comes back once the stopped call's words are all in, with Copy Transcript
    /// for five seconds. Its own task, so the stop and an agent waiting on it return at once.
    /// Nothing heard means no pill, and neither does a top of the screen already taken by a
    /// new call or a dictation.
    private func offerTranscript(_ call: Call) {
        guard let store else { return }
        Task {
            let hasText = await Task.detached(priority: .userInitiated) {
                TranscriptCopy.text(.call(call.id), in: store) != nil
            }.value
            guard hasText, recording == nil, !starting, model?.phase == .idle else { return }
            stoppedCall = call
            stoppedCallCopied = false
            stoppedPillEnds = .now + Self.copyOffer
            stoppedPill.show(call)
            hideStoppedCall(after: Self.copyOffer)
        }
    }

    /// The pill's button: "Copied" for a moment, then the pill goes, never later than the
    /// five seconds it was offered for.
    func copyStoppedCall() {
        guard let call = stoppedCall, TranscriptCopy.copy(.call(call.id), in: store) else {
            dismissStoppedCall()
            return
        }
        stoppedCallCopied = true
        hideStoppedCall(after: min(.milliseconds(1200), stoppedPillEnds - .now))
    }

    /// Hides the pill after a call at once, for whatever needs the top of the screen.
    func dismissStoppedCall() {
        stoppedPillHides?.cancel()
        stoppedPillHides = nil
        guard stoppedCall != nil else { return }
        stoppedCall = nil
        stoppedCallCopied = false
        stoppedPill.hide()
    }

    private func hideStoppedCall(after delay: Duration) {
        stoppedPillHides?.cancel()
        stoppedPillHides = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismissStoppedCall()
        }
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
        if let call { title(call.id) }
    }

    /// Names a call whose transcript is complete, in the background and behind any title
    /// already being made. Only the chosen model is asked, and nothing shows while it works
    /// or when it fails: the call keeps today's label. Ollama's model competes with whisper
    /// for the GPU, so it waits for a quiet Mac and then takes whisper's memory first, as
    /// the fix step does; Apple's belongs to the system and answers at once.
    private func title(_ callID: String) {
        guard model?.preferences.titleCalls == true, let store else { return }
        let previous = titling
        let asked = ContinuousClock.now
        titling = Task { [weak self] in
            await previous?.value
            await self?.makeTitle(callID, store: store, since: asked)
        }
    }

    /// An explicit Generate or Regenerate Title: the same model and the same queue, whatever the
    /// recording's title or the automatic setting is. The old title stays unless a new one is made.
    func generateTitle(_ kind: HistoryEntry.Kind, _ ref: String) {
        guard let store, !isNaming(ref) else { return }
        requested.insert(ref)
        let previous = titling
        let asked = ContinuousClock.now
        titling = Task { [weak self] in
            await previous?.value
            defer { self?.requested.remove(ref) }
            await self?.makeTitle(ref, kind: kind, force: true, store: store, since: asked)
        }
    }

    private func makeTitle(_ callID: String, kind: HistoryEntry.Kind = .call, force: Bool = false, store: CallStore,
                           since asked: ContinuousClock.Instant) async {
        guard let model, force || model.preferences.titleCalls else { return }
        let choice = model.effectiveModel
        if case .ollama = choice { await model.refreshOllama() } else { model.appleModelState = AppleModel.state }
        let models = CallTitles.models(choice: choice, appleAvailable: model.appleModelAvailable,
                                       ollamaModels: model.ollamaModels, ollamaURL: model.preferences.ollamaEndpoint)
        guard !models.isEmpty else { return }
        let usesOllama: Bool
        if case .ollama = choice { usesOllama = true } else { usesOllama = false }

        // Cheap and off the main actor, so a call that can't be titled never waits for a
        // quiet Mac or takes whisper's memory, and never shows as being named.
        guard await Task.detached(priority: .utility, operation: {
            force ? CallTitler().canTitle(kind, callID, in: store) : CallTitler().isEligible(callID, in: store)
        }).value else { return }
        defer { naming.remove(callID) }
        // What an explicit title may replace on screen: the one the recording has now.
        let old: String?? = force ? .some(await Task.detached { (try? store.recordingTitle(kind, callID))?.title }.value) : nil

        if usesOllama {
            // A dictation can start while whisper unloads, so the Mac is checked again after.
            var ready = false
            while !ready {
                guard await TitleGate.waitUntilQuiet(activity: { model.activity }) else { return }
                guard force || model.preferences.titleCalls, model.effectiveModel == choice else { return }
                await model.currentPipeline().transcriber.unload()
                ready = TitleGate.mayAsk(model.activity)
            }
        }

        // Marked only once the model is asked: the wait for a quiet Mac shows nothing.
        naming.insert(callID)
        let work = Task.detached(priority: .utility) {
            let timing: ModelTimings.Kind = usesOllama ? .ollama : .apple
            if force {
                return await CallTitler().timedRetitle(kind, callID, in: store, models: models, kind: timing, since: asked)
            }
            return await CallTitler().timedTitle(callID, in: store, models: models, kind: timing, since: asked)
        }
        if usesOllama {
            ollamaRequest = work
            ollamaTitling = true
        }
        let made = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        if usesOllama {
            ollamaRequest = nil
            ollamaTitling = false
        }
        if let title = made {
            // Out of the set first, so the row goes from "Generating title" to the title.
            naming.remove(callID)
            self.titled(callID, title, old)
            model.refreshRecents()
        }
    }

    /// A dictation is starting: whisper is about to load, and Ollama's model must not sit
    /// beside it (16 GB Macs run out of GPU memory) or make the fix wait behind a title. The
    /// request is cancelled and its title dropped, and Ollama is told to unload.
    func yieldToDictation() {
        guard let request = ollamaRequest, let model else { return }
        request.cancel()
        let settings = model.preferences.cleanup(using: .ollama(model.preferences.ollamaModel))
        Task.detached(priority: .utility) { await Ollama().unload(settings) }
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

    /// What the retention sweep works on; nil until the call database is open. Call audio goes
    /// through the recorder, which never deletes under a running compression.
    var retentionTargets: (store: CallStore, deleteAudio: (@Sendable (String) -> Bool)?)? {
        guard let store else { return nil }
        guard let recorder else { return (store, nil) }
        return (store, { recorder.deleteAudio($0) })
    }

    /// Whether a call that finishes takes its audio with it, which Until transcribed asks for.
    func setDeletesAudioWhenDone(_ on: Bool) {
        recorder?.setDeletesAudioWhenDone(on)
    }

    func copyTranscript(_ call: Call) {
        TranscriptCopy.copy(.call(call.id), in: store)
    }

    /// Whether a call has words to copy, for the menu's Copy Transcript.
    func hasTranscript(_ call: Call) -> Bool {
        TranscriptCopy.text(.call(call.id), in: store) != nil
    }

    /// Whether a call's chunks hold whisper. Dictation then skips the Ollama fix: the fix
    /// unloads whisper for Ollama's model, the call's next chunk reloads it, and the two
    /// together are more than the GPU has.
    var usesWhisper: Bool { recording != nil || transcribing || isImporting }

    /// A file is being transcribed or waits for its turn.
    var isImporting: Bool { !importProgress.isEmpty || !importsWaiting.isEmpty }

    /// The app the prompt asks about: the first in a call that wasn't dismissed.
    var promptApp: DetectedCall? {
        guard askToRecord, recording == nil, model?.activation.isActivated == true else { return nil }
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
        guard let uid = mix?.deviceUID, !apps.isEmpty else {
            warning = nil
            return
        }
        let readers = await Task.detached(priority: .utility) { CallApps.readers(ofDeviceUID: uid) }.value
        let text = apps.first { CallApps.reads($0, readers: readers) }.map { CallSource.readsMixNotice($0.name) }
        if let text, text != warning { model?.notice(text) }
        warning = text
    }

    /// The prompt follows whether Dictate may record.
    func activationChanged() {
        updatePrompt()
    }

    private func updatePrompt() {
        if promptApp != nil { prompt.show() } else { prompt.hide() }
    }

    func refreshRecent() {
        recent = (try? store?.recentCalls(limit: 3)) ?? []
    }
}

extension CallsModel: RecordingControl {
    nonisolated func stopRecording() async throws -> Call {
        guard let call = await stop() else { throw VoiceError.store("No call is being recorded.") }
        return call
    }

    nonisolated func importAudioFile(path: String) async throws -> CallRecorder.ImportStart {
        try await importForAgent(path: path)
    }
}

// MARK: Importing files

private struct PendingImport {
    let callID: String
}

extension CallsModel {
    /// Imports the files in order, from History's menu or a drop, and returns the History id to
    /// select: the last file that was new, else the one that was already there.
    func importFiles(_ urls: [URL]) async -> String? {
        guard let model, model.requireActivation() else { return nil }
        guard recorder != nil else {
            model.notice("Dictate is still starting.")
            return nil
        }
        var fresh: String?
        var existing: String?
        for url in urls {
            let source: URL
            do {
                source = try AudioImport.validate(path: url.path)
            } catch {
                model.notice("\(error)")
                continue
            }
            do {
                let start = try await beginImport(source)
                if start.duplicate {
                    model.notice("Already in History.")
                    existing = "call:\(start.call.id)"
                } else {
                    fresh = "call:\(start.call.id)"
                }
            } catch {
                model.notice("\(error)")
            }
        }
        return fresh ?? existing
    }

    /// Starts an import for an agent. The call comes back at once; the gate is the only thing
    /// that is said aloud.
    func importForAgent(path: String) async throws -> CallRecorder.ImportStart {
        guard let model else { throw VoiceError.store("Dictate is still starting.") }
        try RecordingGate.check(model.activation)
        let start = try await beginImport(try AudioImport.validate(path: path))
        if !start.duplicate, let name = start.call.fileName {
            model.notice("An agent imported \(name).")
        }
        return start
    }

    private func beginImport(_ source: URL) async throws -> CallRecorder.ImportStart {
        guard let recorder else { throw VoiceError.store("Dictate is still starting.") }
        let start = try await recorder.beginImport(source)
        if !start.duplicate {
            importsWaiting.insert(start.call.id)
            importQueue.append(PendingImport(callID: start.call.id))
            runImports()
        }
        return start
    }

    private func runImports() {
        guard importWorker == nil else { return }
        importWorker = Task {
            await drainImports()
            importWorker = nil
        }
    }

    private func drainImports() async {
        while !importQueue.isEmpty, !importsStopped {
            let next = importQueue.removeFirst()
            await transcribe(next)
        }
    }

    private func transcribe(_ next: PendingImport) async {
        guard let model, let recorder else { return }
        let id = next.callID
        importsWaiting.remove(id)
        importProgress[id] = 0
        let transcriber = model.currentPipeline().transcriber
        let whisper = model.preferences.whisper
        // Whisper reports far more often than a row needs; the main actor hears of a change
        // only when the whole percent does.
        let reported = OSAllocatedUnfairLock(initialState: 0)
        let task = Task<Call?, Never> {
            await recorder.transcribeImport(id, transcriber: transcriber, whisper: whisper) { [weak self] part in
                let percent = Int(part * 100)
                guard reported.withLock({ last in
                    defer { last = percent }
                    return percent != last
                }) else { return }
                Task { @MainActor in self?.importProgressed(id, Double(percent) / 100) }
            }
        }
        importRunning = (id, task)
        let ended = await task.value
        importRunning = nil
        importProgress[id] = nil
        if ended?.status == .done { title(id) }
        refreshRecent()
        model.refreshRecents()
        model.applyRetention()
    }

    private func importProgressed(_ id: String, _ value: Double) {
        guard let now = importProgress[id], value > now else { return }
        importProgress[id] = value
    }

    /// Stops an import that waits or is being transcribed, so that deleting it is allowed.
    func cancelImport(_ callID: String) async {
        if let index = importQueue.firstIndex(where: { $0.callID == callID }) {
            importQueue.remove(at: index)
            importsWaiting.remove(callID)
            try? store?.failCall(callID, error: "The import was cancelled.")
        } else if let running = importRunning, running.id == callID {
            running.task.cancel()
            _ = await running.task.value
            // The cancelled row is still transcribing, which a delete refuses.
            if (try? store?.call(callID))?.status.isLive == true {
                try? store?.failCall(callID, error: "The import was cancelled.")
            }
        }
    }
}

/// "Record this call?" in a pill like the dictation indicator, just below where that one
/// sits. It never takes focus from the call.
@MainActor
final class CallPrompt {
    private unowned let calls: CallsModel
    private var panel: NSPanel?
    private static let size = NSSize(width: 420, height: 56)

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

    /// Under the question, so the person knows nothing is recorded unless they say so.
    static let note = "Ask before you record."
    /// What Copy notice puts on the clipboard, to paste into the call's chat.
    static let notice = "This call is being transcribed by Dictate, on my Mac only."

    @State private var noticeCopied = false

    var body: some View {
        HStack(spacing: 8) {
            if let app = calls.promptApp {
                Image(systemName: "phone.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text("Record this call?").lineLimit(1)
                        Text(app.name).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .medium))
                    HStack(spacing: 6) {
                        Text(Self.note)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Button(noticeCopied ? "Copied" : "Copy notice") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.notice, forType: .string)
                            noticeCopied = true
                        }
                        .buttonStyle(.link)
                    }
                    .font(.system(size: 11))
                }
                Spacer(minLength: 4)
                Button("Not now") { calls.notNow(app) }
                    .font(.system(size: 12, weight: .medium))
                    .controlSize(.small)
                // No default action: the panel never takes focus from the call, so Return
                // goes to the call app, and a highlighted button would suggest otherwise.
                Button("Record") { calls.recordFromMenu(app) }
                    .font(.system(size: 12, weight: .medium))
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The call pill once a recording stops, in a panel of its own the pill's size, so it takes
/// clicks only on itself. Like the prompt it never takes focus from the call app.
@MainActor
final class StoppedCallPanel {
    private unowned let calls: CallsModel
    private var panel: NSPanel?
    private let content: FirstClickHostingView<AnyView>

    init(calls: CallsModel) {
        self.calls = calls
        content = FirstClickHostingView(rootView: AnyView(EmptyView()))
    }

    func show(_ call: Call) {
        // Set outright rather than observed, so the size read next is this call's pill.
        content.rootView = AnyView(StoppedCallView(call: call).environment(calls))
        let size = content.fittingSize
        let panel = panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            // Where the call pill sat while it recorded, at the top of the indicator.
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - 12 - size.height,
                                  width: size.width, height: size.height), display: false)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered,
                            defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = content
        return panel
    }
}

/// Takes the first click. The panel never becomes key, and a view that waits for its window
/// to be key before taking clicks would let Copy Transcript's click fall through unanswered.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct StoppedCallView: View {
    @Environment(CallsModel.self) private var calls
    let call: Call

    var body: some View {
        StoppedCallPill(name: call.displayName,
                        length: HistoryTime.elapsed((call.endedAt ?? Date()).timeIntervalSince(call.startedAt)),
                        copied: calls.stoppedCallCopied) { calls.copyStoppedCall() }
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
                Text("Fix the text is paused during calls")
            }
            Button("Stop Recording" + keys) { Task { await calls.stop() } }
        } else {
            let app = calls.detected.first
            Button((app == nil ? "Record a Call" : "Record This Call") + keys) { calls.recordFromMenu(app) }
                .disabled(calls.starting)
        }
        if calls.recording == nil, calls.isImporting, model.preferences.runPrompt {
            Text("Fix the text is paused while importing")
        }
        if let warning = calls.warning {
            Text(warning)
        }
        if let error = calls.error {
            Text(error)
        }
    }
}

/// A recent call with a phone; a click copies the transcript, and a right click offers Copy
/// Transcript.
struct RecentCall: View {
    @Environment(CallsModel.self) private var calls
    let call: Call
    private var symbol: String { call.fileName == nil ? "phone" : "waveform" }

    var body: some View {
        Button {
            if RowMenu.rightClicked {
                if calls.hasTranscript(call) { RowMenu.copyTranscript { calls.copyTranscript(call) } }
            } else {
                calls.copyTranscript(call)
            }
        } label: {
            let lines = RecentCallLabel.lines(call)
            if let title = lines.title {
                Label(title, systemImage: symbol)
                Text(lines.detail)
            } else {
                Label(lines.detail, systemImage: symbol)
            }
        }
    }
}
