import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os

public struct Recording: Sendable {
    public let url: URL
    public let duration: Double
    /// The input went away mid-recording; the file holds what came before.
    public var inputLost = false
    /// Why writing the file stopped partway, if it did; the file holds what came before.
    public var writeError: String?
}

/// Where recorded audio goes: an AVAudioFile, or in tests one that fails.
protocol AudioWriting: AnyObject {
    func write(from buffer: AVAudioPCMBuffer) throws
}

extension AVAudioFile: AudioWriting {}

/// Records a microphone to a 16 kHz mono WAV, written as it records, so a crash or a quit
/// loses at most the last buffer.
///
/// Every call that touches an audio device runs on the recorder's own queue. When
/// coreaudiod stops answering, those calls block for as long as it does; on this queue
/// that stalls a recording instead of freezing the menu bar.
public final class Recorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "voice.recorder", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var watch: InputWatch?
    private var sink: Sink?
    private var url: URL?
    private var inputLost = false

    /// Called from the audio thread with the microphone level, 0 to 1.
    public let onLevel: @Sendable (Float) -> Void
    /// Called once when the input goes away mid-recording. The recording has stopped
    /// listening but stays open: stop() closes it and says the input was lost.
    public let onInputLost: @Sendable () -> Void

    public init(onLevel: @escaping @Sendable (Float) -> Void = { _ in },
                onInputLost: @escaping @Sendable () -> Void = {}) {
        self.onLevel = onLevel
        self.onInputLost = onInputLost
    }

    /// Starts recording the input with this UID, or the system default when it is nil.
    /// Returns false when that input isn't connected and the default is recording instead.
    /// onSamples gets each 16 kHz buffer once it is in the file, on the audio thread.
    @discardableResult
    public func start(to url: URL, deviceUID: String? = nil,
                      onSamples: (@Sendable (UnsafeBufferPointer<Float>) -> Void)? = nil) async throws -> Bool {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Bool, Error>) in
            queue.async {
                do {
                    done.resume(returning: try self.startOnQueue(url, deviceUID: deviceUID, onSamples: onSamples))
                } catch {
                    self.teardown()
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// Stops and closes the file. Nil when nothing was recording.
    public func stop() async -> Recording? {
        await withCheckedContinuation { done in
            queue.async {
                let sink = self.sink
                let url = self.url
                let inputLost = self.inputLost
                self.teardown()
                let frames = sink?.frames ?? 0
                done.resume(returning: url.map {
                    Recording(url: $0, duration: Double(frames) / Audio.sampleRate, inputLost: inputLost,
                              writeError: sink?.writeError)
                })
            }
        }
    }

    private func startOnQueue(_ url: URL, deviceUID: String?,
                              onSamples: (@Sendable (UnsafeBufferPointer<Float>) -> Void)?) throws -> Bool {
        teardown()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        var usedChosen = true
        if let deviceUID {
            // The input node follows the system default unless its unit is pointed at a
            // device. Its output format doesn't follow, which deviceFormat accounts for.
            if var device = InputDevices.id(forUID: deviceUID), let unit = input.audioUnit {
                usedChosen = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                  &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
            } else {
                usedChosen = false
            }
        }
        guard let inputFormat = input.deviceFormat else {
            throw VoiceError.audio("No microphone is available.")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Audio.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let converter = AVAudioConverter(from: inputFormat, to: Audio.format) else {
            throw VoiceError.audio("Can't convert the microphone's \(Int(inputFormat.sampleRate)) Hz audio.")
        }
        converter.downmix = true
        let sink = Sink(file: file, converter: converter, onLevel: onLevel, onSamples: onSamples)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            sink.write(buffer)
        }
        engine.prepare()
        try engine.start()
        adopt(sink, url: url, engine: engine)
        return usedChosen
    }

    /// Keeps the sink's recording, from a started engine or, in tests, from none.
    func adopt(_ sink: Sink, url: URL, engine: AVAudioEngine?) {
        self.engine = engine
        self.sink = sink
        self.url = url
        inputLost = false
        watch = engine.map { InputWatch($0) { [weak self] in self?.inputWentAway() } }
    }

    /// The engine stopped itself: its input went away or changed under it. Stops listening
    /// and leaves the file for stop() to close, so what was recorded is kept. An engine
    /// still running had a change that didn't touch its input, and records on.
    func inputWentAway() {
        queue.async {
            guard self.sink != nil, !self.inputLost, self.engine?.isRunning != true else { return }
            self.inputLost = true
            self.stopEngine()
            self.onInputLost()
        }
    }

    private func stopEngine() {
        watch?.cancel()
        watch = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    private func teardown() {
        stopEngine()
        sink?.close()
        sink = nil
        url = nil
        inputLost = false
    }
}

/// Calls back when an engine's configuration changes. When the change touched its input,
/// the engine has stopped itself and records nothing more until it is started again.
final class InputWatch: @unchecked Sendable {
    private let center: NotificationCenter
    private var token: (any NSObjectProtocol)?

    init(_ engine: AnyObject, center: NotificationCenter = .default, onChange: @escaping @Sendable () -> Void) {
        self.center = center
        token = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
            onChange()
        }
    }

    func cancel() {
        if let token { center.removeObserver(token) }
        token = nil
    }

    deinit { cancel() }
}

/// Converts the microphone's buffers to 16 kHz mono and appends them to the file. Runs on
/// the tap's thread; the lock keeps a late buffer from reaching a closed file.
final class Sink: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var file: (any AudioWriting)?
    private let converter: AVAudioConverter
    private let onLevel: @Sendable (Float) -> Void
    private let onSamples: (@Sendable (UnsafeBufferPointer<Float>) -> Void)?
    private(set) var frames: AVAudioFramePosition = 0
    /// The first write that failed; nothing is written after it, so the file stays whole.
    private(set) var writeError: String?

    init(file: any AudioWriting, converter: AVAudioConverter, onLevel: @escaping @Sendable (Float) -> Void,
         onSamples: (@Sendable (UnsafeBufferPointer<Float>) -> Void)?) {
        self.file = file
        self.converter = converter
        self.onLevel = onLevel
        self.onSamples = onSamples
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        onLevel(Self.level(buffer))
        let ratio = Audio.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Audio.format, frameCapacity: capacity) else { return }
        lock.withLockUnchecked {
            guard let file else { return }
            let feed = OneShot(buffer, ends: false)
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in feed.next(status) }
            guard error == nil, output.frameLength > 0 else { return }
            do {
                try file.write(from: output)
                frames += AVAudioFramePosition(output.frameLength)
                // After the write, so live text never holds audio the file doesn't.
                onSamples?(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            } catch {
                writeError = "\(error)"
                self.file = nil
            }
        }
    }

    func close() {
        lock.withLock { file = nil }
    }

    /// Peak-free loudness for the indicator: RMS in dBFS, mapped from -60..0 to 0..1.
    private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 60) / 60, 0), 1)
    }
}
