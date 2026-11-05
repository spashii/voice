import Foundation
import Observation
import os
import VoiceCore

/// Downloads whisper's models, with the voice activity model alongside, and reports
/// progress for Setup and Settings.
@MainActor @Observable
final class ModelDownloads {
    enum State: Equatable {
        case missing
        case downloading(Double)
        case ready
        case failed(String)
    }

    private var progress: [WhisperModel: Double] = [:]
    private var errors: [WhisperModel: String] = [:]
    /// Bumped when a download finishes, so views that read files on disk look again.
    private var finished = 0
    @ObservationIgnored private var observations: [WhisperModel: NSKeyValueObservation] = [:]

    func state(_ model: WhisperModel) -> State {
        _ = finished
        if let fraction = progress[model] { return .downloading(fraction) }
        if let error = errors[model] { return .failed(error) }
        return model.isDownloaded && VADModel.isDownloaded ? .ready : .missing
    }

    func download(_ model: WhisperModel) {
        guard progress[model] == nil, state(model) != .ready else { return }
        errors[model] = nil
        progress[model] = 0
        Task {
            do {
                try FileManager.default.createDirectory(at: Paths.models, withIntermediateDirectories: true)
                if !VADModel.isDownloaded {
                    try await fetch(VADModel.url, to: VADModel.file, reporting: nil)
                }
                if !model.isDownloaded {
                    if FileManager.default.fileExists(atPath: model.openSuperWhisperFile.path) {
                        try FileManager.default.copyItem(at: model.openSuperWhisperFile, to: model.file)
                    } else {
                        try await fetch(model.url, to: model.file, reporting: model)
                    }
                }
            } catch {
                errors[model] = "The download stopped: \(error.localizedDescription)"
            }
            progress[model] = nil
            observations[model] = nil
            finished += 1
        }
    }

    /// Downloads to a temporary file and moves it into place only when it is complete, so a
    /// half-downloaded model is never taken for a ready one.
    private func fetch(_ url: URL, to destination: URL, reporting model: WhisperModel?) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
                done.resume(with: Result {
                    if let error { throw error }
                    guard let temporary, (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw VoiceError.whisper("The server didn't send the file.")
                    }
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                })
            }
            if let model {
                // Progress changes with every chunk; the view only needs each half percent.
                let last = OSAllocatedUnfairLock(initialState: -1)
                observations[model] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                    let fraction = progress.fractionCompleted
                    let step = Int(fraction * 200)
                    guard last.withLock({ old in
                        defer { old = step }
                        return old != step
                    }) else { return }
                    Task { @MainActor in
                        if self?.progress[model] != nil { self?.progress[model] = fraction }
                    }
                }
            }
            task.resume()
        }
    }
}
