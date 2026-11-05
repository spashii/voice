import Foundation
import VoiceCore

/// Decodes references for the retry report while the Mac is idle (see IdleState), in the
/// background at utility priority. Its decodes share whisper's one queue with dictation
/// and calls, and any sign of use stops the one in progress, so a dictation never waits on
/// it for more than a decoding step. Large v3 when it is downloaded, as a model apart from
/// the one being scored; turbo otherwise.
@MainActor
final class ReferencePass {
    private weak var model: AppModel?
    private var task: Task<Void, Never>?
    private let stop = DecodeStop()

    /// How often an idle Mac is looked for, and how long to wait once nothing is left.
    private static let poll: Duration = .seconds(60)
    private static let rest: Duration = .seconds(600)

    init(model: AppModel) {
        self.model = model
    }

    func launch() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let rest = await self?.round() ?? ReferencePass.poll
                try? await Task.sleep(for: rest)
            }
        }
    }

    /// Called when a dictation or a call starts, so a reference decode gives way at once.
    func yield() {
        stop.request()
    }

    /// Waits for a decode in progress to stop and its model to unload.
    func shutDown() async {
        task?.cancel()
        stop.request()
        await task?.value
    }

    /// Runs references while the Mac stays idle. Returns how long to wait before looking again.
    private func round() async -> Duration {
        guard let model, let references = model.references, await idle() else { return Self.poll }
        let pipeline = model.currentPipeline()
        let chosen: WhisperModel = WhisperModel.largeV3.isDownloaded ? .largeV3 : .largeV3Turbo
        // The pipeline's transcriber when it already runs this model, so no second copy loads.
        let own = pipeline.transcriber.modelURL != chosen.file
        let transcriber = own ? Transcriber(modelURL: chosen.file, vadModelURL: VADModel.file) : pipeline.transcriber
        let options = RetryReferences.options(language: model.preferences.language,
                                              keyTerms: model.preferences.whisper.keyTerms)
        stop.reset()
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if await !self.idle(quick: true) { self.stop.request() }
            }
        }
        var rest = Self.poll
        while !stop.requested {
            do {
                guard try await references.runNext(transcriber: transcriber, options: options, stop: stop) else {
                    rest = Self.rest
                    break
                }
            } catch {
                break
            }
        }
        watcher.cancel()
        // Its GPU memory goes back before anything else needs it: the fix step's model
        // doesn't fit beside two whisper models on a 16 GB Mac.
        if own { await transcriber.unload() }
        return rest
    }

    /// `quick` skips asking Ollama, for the once-a-second watcher; a model Ollama loads
    /// mid-decode comes from a dictation's fix step, which a recording starts first.
    private func idle(quick: Bool = false) async -> Bool {
        guard let model else { return false }
        let recording = model.phase != .idle || model.calls?.usesWhisper == true || model.calls?.starting == true
        let base = URL(string: model.preferences.ollamaURL) ?? URL(string: "http://127.0.0.1:11434")!
        let state = IdleState(recording: recording, userIdleSeconds: IdleState.userIdleSeconds(),
                              onACPower: IdleState.onACPowerNow(), memoryPressure: IdleState.memoryPressureNow(),
                              ollamaLoaded: quick ? false : await IdleState.ollamaLoadedNow(base))
        return state.allowsReference
    }
}
