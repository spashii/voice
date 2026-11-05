import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os

extension Paths {
    /// Call audio lives apart from dictation recordings, so dictation recovery never takes a
    /// call's WAV for a lost dictation.
    public static var calls: URL { support.appending(path: "calls", directoryHint: .isDirectory) }
}

/// Records a call from a Blend mix or a microphone and transcribes it while it runs.
///
/// While the call runs the WAV is the source of truth: it is written as the audio arrives, at
/// the device's own rate, with me on the left and the call on the right whatever order the
/// device uses, so `rebuild` can redo a call's transcript from the file alone. Once the
/// transcript is complete the WAV is replaced by an AAC .m4a of the same audio (see
/// CallAudio), which `rebuild` reads just as well. Each side is cut at pauses,
/// brought to 16 kHz and transcribed on its own; whisper takes one decode at a time, so
/// call chunks and dictations share the transcriber and queue behind each other.
///
/// Device calls run on the recorder's own queue, as in Recorder: a coreaudiod that stops
/// answering stalls this queue, not the main thread.
public final class CallRecorder: @unchecked Sendable {
    public let store: CallStore
    private let queue = DispatchQueue(label: "voice.call-recorder", qos: .userInitiated)
    private let lock = OSAllocatedUnfairLock()
    private var engine: AVAudioEngine?
    private var watch: InputWatch?
    private var session: CallSession?
    /// Calls whose audio is being compressed, so one call is never converted twice at once.
    private var compressing: Set<String> = []
    private var conversions: [Task<Void, Never>] = []
    private let directory: URL
    private let onInputLost: @Sendable (Call?) -> Void

    /// What a call cut short by its input going away is failed with.
    public static let inputLost = "The input went away"

    /// `onInputLost` gets the call once it is finished as failed because the input went
    /// away mid-call.
    public init(store: CallStore, directory: URL = Paths.calls,
                onInputLost: @escaping @Sendable (Call?) -> Void = { _ in }) {
        self.store = store
        self.directory = directory
        self.onInputLost = onInputLost
    }

    /// The call being recorded, if any.
    public var callID: String? { lock.withLockUnchecked { session?.callID } }

    /// Starts recording the source's device, or the default microphone when it has none.
    public func start(_ source: CallSource, transcriber: Transcriber, whisper: WhisperOptions = WhisperOptions(),
                      appBundleID: String? = nil, appName: String? = nil, title: String? = nil) async throws -> Call {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Call, Error>) in
            queue.async {
                do {
                    done.resume(returning: try self.startDevice(source, transcriber, whisper, appBundleID, appName,
                                                                title))
                } catch {
                    self.stopEngine()
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// Stops recording and returns once the last words are transcribed. Nil when nothing was
    /// recording.
    @discardableResult
    public func stop() async -> Call? {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.stopEngine()
                done.resume()
            }
        }
        guard let session = lock.withLockUnchecked({ () -> CallSession? in
            defer { self.session = nil }
            return self.session
        }) else { return nil }
        return await finish(session)
    }

    /// Stops recording and closes the WAV without transcribing what is left, so quitting
    /// stays quick. The call stays marked recording, and the next launch rebuilds it.
    public func abandon() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.stopEngine()
                done.resume()
            }
        }
        lock.withLockUnchecked {
            session?.close()
            session = nil
        }
    }

    /// Feeds a WAV through the same path as a live call, in real time unless told not to:
    /// what `voice-cli call --file` tests. Left is me and right is the call when it has
    /// two channels.
    public func play(_ file: URL, transcriber: Transcriber, whisper: WhisperOptions = WhisperOptions(),
                     realTime: Bool = true, appBundleID: String? = nil, appName: String? = nil,
                     title: String? = nil, onStart: @Sendable (Call) -> Void = { _ in }) async throws -> Call {
        let audio = try AVAudioFile(forReading: file)
        let format = audio.processingFormat
        let labels: [CallSegment.Channel] = format.channelCount >= 2 ? [.me, .call] : [.mix]
        let session = try begin(format: format, labels: labels, order: Array(0..<min(Int(format.channelCount), 2)),
                                deviceUID: nil, transcriber, whisper, appBundleID: appBundleID, appName: appName,
                                title: title)
        if let call = try store.call(session.callID) { onStart(call) }
        let step = AVAudioFrameCount(format.sampleRate / 10)
        let clock = ContinuousClock()
        let began = clock.now
        var read = 0.0
        while audio.framePosition < audio.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: step) else { break }
            try audio.read(into: buffer, frameCount: step)
            session.ingest(buffer)
            read += Double(buffer.frameLength) / format.sampleRate
            if realTime { try? await clock.sleep(until: began + .seconds(read)) }
        }
        lock.withLockUnchecked { self.session = nil }
        guard let call = await finish(session) else { throw VoiceError.store("Call \(session.callID) is gone.") }
        return call
    }

    /// Transcribes a call again from its audio, replacing its segments: for a call whose
    /// recording was cut off by a crash, or whose transcription failed. The old segments go
    /// only once the first chunk has decoded, so audio or a model that can't be read leaves
    /// the call with the transcript it had.
    public func rebuild(_ callID: String, transcriber: Transcriber,
                        whisper: WhisperOptions = WhisperOptions()) async throws -> Call {
        guard let call = try store.call(callID), let path = call.audioPath else {
            throw VoiceError.store("Call \(callID) has no audio to rebuild from.")
        }
        let url = URL(fileURLWithPath: path)
        // Only a WAV's header can be left unfinished by a crash.
        if CallAudio.isWAV(path) { Recovery.repairHeader(url) }
        let audio: AVAudioFile
        do {
            audio = try AVAudioFile(forReading: url)
        } catch {
            // A call left live by a crash would otherwise stay "recording" for good.
            if call.status.isLive { try? store.failCall(callID, error: "Can't read its audio: \(error)") }
            throw error
        }
        let format = audio.processingFormat
        // A split call's file always has two channels; one that doesn't has lost a side, and
        // transcribing it as one would finish the call as if it hadn't.
        if call.split && format.channelCount != 2 {
            let reason = CallChannels.sidesMissing(Int(format.channelCount))
            try? store.failCall(callID, error: reason)
            throw VoiceError.audio(reason)
        }
        let labels: [CallSegment.Channel] = call.split ? [.me, .call] : [.mix]
        try store.markTranscribing(callID, endedAt: call.endedAt ?? Date())
        let session = try CallSession(callID: callID, format: format, labels: labels,
                                      order: Array(0..<min(Int(format.channelCount), 2)), wav: nil,
                                      replacingSegments: true, store: store, transcriber: transcriber,
                                      whisper: whisper)
        let step = AVAudioFrameCount(format.sampleRate)
        while audio.framePosition < audio.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: step) else { break }
            try audio.read(into: buffer, frameCount: step)
            session.ingest(buffer)
        }
        return await finish(session) ?? call
    }

    /// Replaces a finished call's WAV with an AAC .m4a, off the calling thread. The call's
    /// path moves to the .m4a and the WAV goes only once the .m4a has opened with the WAV's
    /// duration and channels; on any failure the WAV and the path stay as they were, so
    /// the next launch tries again. Returns whether the call's audio is now the .m4a.
    @discardableResult
    public func compressAudio(_ callID: String) async -> Bool {
        guard let call = try? store.call(callID), call.status == .done, let path = call.audioPath,
              CallAudio.isWAV(path), claim(callID) else { return false }
        defer { release(callID) }
        let wav = URL(fileURLWithPath: path)
        do {
            let m4a = try await Task.detached(priority: .utility) { try CallAudio.encode(wav) }.value
            do {
                try store.setAudioPath(callID, m4a.path)
            } catch {
                try? FileManager.default.removeItem(at: m4a)
                throw error
            }
            try? FileManager.default.removeItem(at: wav)
            return true
        } catch {
            Self.log.error("Kept the WAV of call \(callID, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Compresses every finished call still holding a WAV: those that finished before this
    /// existed, whose conversion failed, or that were cut off by quitting mid-conversion.
    /// The app runs it at launch, after the interrupted calls are rebuilt.
    public func compressFinishedCalls() async {
        for call in (try? store.callsAwaitingCompression()) ?? [] {
            await compressAudio(call.id)
        }
    }

    /// Returns once every conversion started by a finished call is over, for a process that
    /// would otherwise exit with one half written. The app doesn't wait: quitting leaves the
    /// WAV, and the next launch converts it.
    public func waitForCompression() async {
        let tasks = lock.withLockUnchecked { () -> [Task<Void, Never>] in
            defer { conversions = [] }
            return conversions
        }
        for task in tasks { await task.value }
    }

    private static let log = Logger(subsystem: "io.github.spashii.voice", category: "call-audio")

    private func claim(_ callID: String) -> Bool {
        lock.withLockUnchecked { compressing.insert(callID).inserted }
    }

    private func release(_ callID: String) {
        lock.withLockUnchecked { _ = compressing.remove(callID) }
    }

    /// The engine stopped itself: the input went away or changed under it mid-call. The WAV
    /// keeps what came before, and the call is finished as failed with its transcript as
    /// far as the audio went. An engine still running had a change that didn't touch its
    /// input, and records on.
    func inputWentAway() {
        queue.async {
            if self.engine?.isRunning == true { return }
            self.stopEngine()
            guard let session = self.lock.withLockUnchecked({ () -> CallSession? in
                defer { self.session = nil }
                return self.session
            }) else { return }
            Task {
                let call = await self.finish(session, failure: Self.inputLost)
                self.onInputLost(call)
            }
        }
    }

    // MARK: Internals

    private func startDevice(_ source: CallSource, _ transcriber: Transcriber, _ whisper: WhisperOptions,
                             _ appBundleID: String?, _ appName: String?, _ title: String?) throws -> Call {
        guard callID == nil else { throw VoiceError.audio("A call is already being recorded.") }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = source.deviceUID {
            guard var device = InputDevices.id(forUID: uid), let unit = input.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                throw VoiceError.audio("\(source.name) isn't available. Is Blend running?")
            }
        }
        guard let format = input.deviceFormat else {
            throw VoiceError.audio("No microphone is available.")
        }
        let session = try open(source, format: format, transcriber, whisper, appBundleID: appBundleID,
                               appName: appName, title: title)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in session.ingest(buffer) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            lock.withLockUnchecked { self.session = nil }
            try? store.failCall(session.callID, error: "The input wouldn't start: \(error)")
            throw error
        }
        self.engine = engine
        watch = InputWatch(engine) { [weak self] in self?.inputWentAway() }
        return try store.call(session.callID)!
    }

    /// Starts the session for a source's audio in this format. A split source whose audio
    /// doesn't come as two channels is failed before it records anything, since it would
    /// end as a finished call with a side missing. The failed call keeps its file and stays
    /// in the history with the reason, and the same reason is thrown.
    func open(_ source: CallSource, format: AVAudioFormat, _ transcriber: Transcriber, _ whisper: WhisperOptions,
              appBundleID: String?, appName: String?, title: String?) throws -> CallSession {
        let channels: CallChannels
        do {
            channels = try CallChannels(source, inputChannels: Int(format.channelCount))
        } catch {
            let session = try begin(format: format, labels: [.mix], order: [0], deviceUID: source.deviceUID,
                                    transcriber, whisper, appBundleID: appBundleID, appName: appName, title: title)
            lock.withLockUnchecked { self.session = nil }
            session.close()
            try? store.failCall(session.callID, error: "\(error)")
            throw error
        }
        return try begin(format: format, labels: channels.labels, order: channels.order, deviceUID: source.deviceUID,
                         transcriber, whisper, appBundleID: appBundleID, appName: appName, title: title,
                         speakers: channels.speakers)
    }

    func begin(format: AVAudioFormat, labels: [CallSegment.Channel], order: [Int], deviceUID: String?,
               _ transcriber: Transcriber, _ whisper: WhisperOptions, appBundleID: String?,
               appName: String?, title: String?, speakers: [String]? = nil) throws -> CallSession {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let started = Date()
        let wav = directory.appending(path: "\(Int(started.timeIntervalSince1970 * 1000))-\(id.prefix(8)).wav")
        try store.createCall(NewCall(id: id, startedAt: started, appBundleID: appBundleID, appName: appName,
                                     deviceUID: deviceUID, split: labels.count == 2, audioPath: wav.path,
                                     title: title, speakers: speakers))
        do {
            let session = try CallSession(callID: id, format: format, labels: labels, order: order, wav: wav,
                                          store: store, transcriber: transcriber, whisper: whisper)
            lock.withLockUnchecked { self.session = session }
            return session
        } catch {
            try? store.failCall(id, error: "\(error)")
            throw error
        }
    }

    /// `failure` is why the call ended early, which outranks a chunk that failed to transcribe.
    private func finish(_ session: CallSession, failure: String? = nil) async -> Call? {
        try? store.markTranscribing(session.callID)
        let transcription = await session.finish()
        if let failure = failure ?? transcription {
            try? store.failCall(session.callID, error: failure)
        } else {
            try? store.finishCall(session.callID)
            // Left to run on its own: stopping a call returns once its words are in.
            let id = session.callID
            let conversion = Task(priority: .utility) { _ = await self.compressAudio(id) }
            lock.withLockUnchecked { conversions.append(conversion) }
        }
        return try? store.call(session.callID)
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
}

/// One call's audio on its way to the WAV and to whisper. `ingest` runs on the audio tap's
/// thread; the lock keeps a late buffer away from a closed file.
final class CallSession: @unchecked Sendable {
    let callID: String
    private let lock = OSAllocatedUnfairLock()
    private var file: (any AudioWriting)?
    /// The first write that failed. The call goes on being transcribed, and is failed with
    /// this when it finishes, since its WAV stops here and can't rebuild the rest.
    private var writeError: String?
    private let fileFormat: AVAudioFormat
    private let order: [Int]
    private var lanes: [Lane]
    private var closed = false
    private let chunks: AsyncStream<SpeechChunk>.Continuation
    private let worker: Task<String?, Never>

    /// One side of the call: a channel of the file (or all of them, for a mix) at 16 kHz.
    private struct Lane {
        let channel: CallSegment.Channel
        let source: Int?
        let mono: AVAudioFormat
        let converter: AVAudioConverter
        var chunker = SpeechChunker()
    }

    /// `order` picks the input channels written to the file, in file order; the lanes read
    /// the file's channels, so labels[0] is the file's left.
    init(callID: String, format: AVAudioFormat, labels: [CallSegment.Channel], order: [Int], wav: URL?,
         writer: (any AudioWriting)? = nil, replacingSegments: Bool = false, store: CallStore,
         transcriber: Transcriber, whisper: WhisperOptions) throws {
        self.callID = callID
        self.order = order
        fileFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate,
                                   channels: AVAudioChannelCount(order.count))!
        if let wav {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: order.count,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            file = try AVAudioFile(forWriting: wav, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        }
        if let writer { file = writer }
        let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
        lanes = try labels.enumerated().map { index, channel in
            guard let converter = AVAudioConverter(from: mono, to: Audio.format) else {
                throw VoiceError.audio("Can't convert \(Int(format.sampleRate)) Hz audio to 16 kHz.")
            }
            return Lane(channel: channel, source: labels.count == 1 ? nil : index, mono: mono, converter: converter)
        }
        let (stream, continuation) = AsyncStream<SpeechChunk>.makeStream()
        chunks = continuation
        worker = Task.detached(priority: .userInitiated) {
            await Self.transcribe(stream, callID: callID, replacing: replacingSegments, store: store,
                                  transcriber: transcriber, whisper: whisper)
        }
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let input = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        lock.withLockUnchecked {
            guard !closed, let picked = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: buffer.frameLength),
                  let out = picked.floatChannelData else { return }
            picked.frameLength = buffer.frameLength
            for (to, from) in order.enumerated() {
                out[to].update(from: input[min(from, Int(buffer.format.channelCount) - 1)], count: frames)
            }
            do {
                try file?.write(from: picked)
            } catch {
                writeError = "Couldn't write the call's audio: \(error)"
                file = nil
            }
            for i in lanes.indices {
                for chunk in lanes[i].chunker.append(resample(picked, lane: lanes[i])) {
                    chunks.yield(SpeechChunk(channel: lanes[i].channel, start: chunk.start, samples: chunk.samples))
                }
            }
        }
    }

    func close() {
        lock.withLockUnchecked {
            closed = true
            file = nil
            chunks.finish()
        }
    }

    /// Cuts the tail, closes the file and waits for the transcription to catch up. Returns
    /// the write error if writing the WAV failed, or else the last transcription error.
    func finish() async -> String? {
        lock.withLockUnchecked {
            closed = true
            file = nil
            for i in lanes.indices {
                if let chunk = lanes[i].chunker.flush() {
                    chunks.yield(SpeechChunk(channel: lanes[i].channel, start: chunk.start, samples: chunk.samples))
                }
            }
            chunks.finish()
        }
        let transcription = await worker.value
        return lock.withLockUnchecked { writeError } ?? transcription
    }

    private func resample(_ buffer: AVAudioPCMBuffer, lane: Lane) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard let mono = AVAudioPCMBuffer(pcmFormat: lane.mono, frameCapacity: buffer.frameLength),
              let channels = buffer.floatChannelData else { return [] }
        mono.frameLength = buffer.frameLength
        let target = mono.floatChannelData![0]
        if let source = lane.source {
            target.update(from: channels[source], count: frames)
        } else {
            let count = Int(buffer.format.channelCount)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<count { sum += channels[c][f] }
                target[f] = sum / Float(count)
            }
        }
        let capacity = AVAudioFrameCount(Double(frames) * Audio.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Audio.format, frameCapacity: capacity) else { return [] }
        let feed = OneShot(mono, ends: false)
        var error: NSError?
        lane.converter.convert(to: output, error: &error) { _, status in feed.next(status) }
        guard error == nil, output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// Transcribes chunks in the order they were cut, each with the same side's last words
    /// as whisper's context, and stores the segments as soon as each is done. `replacing`
    /// clears the call's old segments just before the first new ones are stored.
    private static func transcribe(_ stream: AsyncStream<SpeechChunk>, callID: String, replacing: Bool,
                                   store: CallStore, transcriber: Transcriber,
                                   whisper: WhisperOptions) async -> String? {
        var previous: [CallSegment.Channel: String] = [:]
        var failure: String?
        var replace = replacing
        for await chunk in stream {
            var options = whisper
            options.initialPrompt = previous[chunk.channel] ?? ""
            let offset = Double(chunk.start) / Audio.sampleRate
            let length = Double(chunk.samples.count) / Audio.sampleRate
            do {
                let transcript = try await transcriber.transcribe(chunk.samples, options: options)
                let segments = transcript.segments.filter { !$0.text.isEmpty }.map { segment in
                    var segment = segment
                    // Whisper pads a short chunk to a second; its times stay inside the audio.
                    segment.t1 = min(segment.t1, length)
                    return NewCallSegment(channel: chunk.channel, segment: segment, offset: offset)
                }
                if replace {
                    try store.deleteSegments(callID)
                    replace = false
                }
                try store.appendSegments(callID, segments)
                if !transcript.text.isEmpty { previous[chunk.channel] = transcript.text }
            } catch {
                failure = "\(error)"
            }
        }
        return failure
    }
}

/// Which input channels a call records, in file order, and what each side is called.
struct CallChannels: Equatable {
    /// labels[0] is the file's left.
    let labels: [CallSegment.Channel]
    /// The input channel written to each of the file's channels.
    let order: [Int]
    let speakers: [String]?

    /// A split source takes exactly two input channels, one per side, and throws on any
    /// other count: one channel holds a single side, and more can't be matched to Blend's
    /// left and right. A split mix with the call on the left is written swapped, so every
    /// WAV has me on the left and rebuild needs nothing but the file.
    init(_ source: CallSource, inputChannels: Int) throws {
        guard source.split else {
            labels = [.mix]
            order = Array(0..<min(inputChannels, 2))
            speakers = nil
            return
        }
        guard inputChannels == 2 else { throw VoiceError.audio(Self.sidesMissing(inputChannels)) }
        labels = [.me, .call]
        order = source.channels[0] == .me ? [0, 1] : [1, 0]
        speakers = source.speakers
    }

    static func sidesMissing(_ channels: Int) -> String {
        if channels > 2 {
            return "Got \(channels) channels from the call mix rather than 2, so its sides can't be told apart."
        }
        return "Got \(channels) channel\(channels == 1 ? "" : "s") from the call mix, so the call side is missing."
    }
}

struct SpeechChunk: Sendable {
    let channel: CallSegment.Channel
    /// Where it starts, in 16 kHz samples from the start of the call.
    let start: Int
    let samples: [Float]
}

/// Cuts one side's 16 kHz audio into stretches of speech at pauses, so each can be
/// transcribed as soon as its speaker stops. Loudness against a tracked noise floor decides
/// speech, which holds up for both a microphone with room noise and system audio that is
/// silent between words; whisper's own VAD then trims what is left inside each chunk.
struct SpeechChunker {
    static let frame = 480                          // 30 ms
    static let pauseFrames = 17                     // 0.5 s of quiet ends a chunk
    static let shortPauseFrames = 8                 // 0.25 s does once it runs past
    static let patience = 5 * 16_000                // 5 s, so someone talking at length is
                                                    // transcribed between breaths
    static let prerollFrames = 10                   // 0.3 s kept before speech starts
    static let tailFrames = 7                       // 0.2 s kept after it ends
    static let minSpeechFrames = 8                  // under 0.25 s of speech is a click
    static let maxSamples = 15 * 16_000             // within whisper's 30 s window, and soon enough

    /// Samples not yet cut, starting at `base`.
    private var buffer: [Float] = []
    private var base = 0
    /// Index in `buffer` of the next frame to judge.
    private var judged = 0
    private var chunkStart: Int?
    private var speechFrames = 0
    private var quietFrames = 0
    private var floor: Float = -60

    init() {}

    mutating func append(_ samples: [Float]) -> [(start: Int, samples: [Float])] {
        buffer += samples
        var cut: [(start: Int, samples: [Float])] = []
        while judged + Self.frame <= buffer.count {
            let frame = buffer[judged..<judged + Self.frame]
            let rms = (frame.reduce(0) { $0 + $1 * $1 } / Float(Self.frame)).squareRoot()
            let db = 20 * log10(max(rms, 1e-7))
            // Falls at once to anything quieter and creeps up 0.3 dB a second, so a long
            // stretch of speech doesn't become the floor.
            floor = min(floor + 0.01, db)
            let speech = db > max(floor + 12, -50)
            judged += Self.frame
            if let start = chunkStart {
                if speech {
                    speechFrames += 1
                    quietFrames = 0
                } else {
                    quietFrames += 1
                }
                let pause = judged - start >= Self.patience ? Self.shortPauseFrames : Self.pauseFrames
                if quietFrames >= pause {
                    let end = judged - max(0, quietFrames - Self.tailFrames) * Self.frame
                    if speechFrames >= Self.minSpeechFrames { cut.append(take(start, end)) }
                    chunkStart = nil
                } else if judged - start >= Self.maxSamples {
                    cut.append(take(start, judged))
                    trim(keeping: 0)
                    chunkStart = 0
                    speechFrames = 0
                }
            } else if speech {
                chunkStart = max(0, judged - (Self.prerollFrames + 1) * Self.frame)
                speechFrames = 1
                quietFrames = 0
            }
            if chunkStart == nil { trim(keeping: Self.prerollFrames * Self.frame) }
        }
        return cut
    }

    /// The speech still open when the call stops.
    mutating func flush() -> (start: Int, samples: [Float])? {
        defer { chunkStart = nil }
        guard let start = chunkStart, speechFrames >= Self.minSpeechFrames else { return nil }
        return take(start, buffer.count)
    }

    /// Positions are indexes into `buffer`; what is returned starts at an absolute sample.
    private mutating func take(_ from: Int, _ to: Int) -> (start: Int, samples: [Float]) {
        (base + from, Array(buffer[from..<max(from, min(to, buffer.count))]))
    }

    /// Drops what lies before the last `count` judged samples.
    private mutating func trim(keeping count: Int) {
        let drop = max(0, judged - count)
        guard drop > 0 else { return }
        buffer.removeFirst(drop)
        base += drop
        judged -= drop
    }
}
