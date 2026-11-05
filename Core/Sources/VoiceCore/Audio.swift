import AVFoundation
import Foundation

public enum VoiceError: Error, CustomStringConvertible {
    case audio(String)
    case whisper(String)
    case store(String)
    case cleanup(String)

    public var description: String {
        switch self {
        case .audio(let text), .whisper(let text), .store(let text), .cleanup(let text): text
        }
    }
}

/// Where Voice keeps its models, recordings and database.
public enum Paths {
    public static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Voice", directoryHint: .isDirectory)
    }
    public static var models: URL { support.appending(path: "models", directoryHint: .isDirectory) }
    public static var recordings: URL { support.appending(path: "recordings", directoryHint: .isDirectory) }
    public static var database: URL { support.appending(path: "voice.sqlite") }
    public static var whisperModel: URL { models.appending(path: "ggml-large-v3-turbo.bin") }
    public static var vadModel: URL { models.appending(path: "ggml-silero-v5.1.2.bin") }
}

public enum Audio {
    /// Whisper takes 16 kHz mono, so recordings are kept in that form too.
    public static let sampleRate = 16_000.0

    public static var format: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    /// Reads any audio file as 16 kHz mono samples.
    public static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let input = file.processingFormat
        guard file.length > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw VoiceError.audio("Couldn't read \(url.lastPathComponent).")
        }
        try file.read(into: buffer)
        if input.sampleRate == sampleRate && input.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        guard let converter = AVAudioConverter(from: input, to: format) else {
            throw VoiceError.audio("Can't convert \(url.lastPathComponent) to 16 kHz mono.")
        }
        converter.downmix = true
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / input.sampleRate) + 4096
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        let feed = OneShot(buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in feed.next(status) }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

extension AVAudioInputNode {
    /// The format to tap the input in: its device's own rate and channels, or nil when there
    /// is no input. Pointing the node's unit at a device updates the unit's device side at
    /// once, but the node's output format stays the one it took from the default input, and
    /// the unit hands over only that many of the device's channels: a two-channel Blend mix
    /// read in the built-in microphone's format arrives as its left channel alone. A tap
    /// installed in this format sets the output to match, since nothing else is connected
    /// to the node.
    var deviceFormat: AVAudioFormat? {
        let device = inputFormat(forBus: 0)
        guard device.sampleRate > 0, device.channelCount > 0 else { return nil }
        if device.isStandard { return device }
        if let layout = device.channelLayout {
            return AVAudioFormat(standardFormatWithSampleRate: device.sampleRate, channelLayout: layout)
        }
        return AVAudioFormat(standardFormatWithSampleRate: device.sampleRate, channels: device.channelCount)
    }
}

/// Hands a converter one buffer, then reports the end of the stream.
final class OneShot: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    private let ends: Bool

    /// `ends` false says "no more for now" instead, so a converter that is fed buffer by
    /// buffer keeps its filter state between them.
    init(_ buffer: AVAudioPCMBuffer, ends: Bool = true) {
        self.buffer = buffer
        self.ends = ends
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = ends ? .endOfStream : .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
