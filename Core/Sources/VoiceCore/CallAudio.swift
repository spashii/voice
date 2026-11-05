import AVFoundation
import Foundation

/// How a call's audio is kept. While the call records it is a WAV, which stays readable
/// however the app ends. Once the transcript is complete nothing needs that any more, and
/// an hour of 48 kHz stereo is about 690 MB, so the WAV is replaced by AAC at about a
/// sixteenth of the size: speech stays clear, and a recording habit can't fill a disk.
public enum CallAudio {
    /// 96 kbps for stereo, 48 for a mixed-down call.
    public static let bitRatePerChannel = 48_000
    /// How far the AAC's length may differ from the WAV's before it is not trusted as the
    /// same recording.
    public static let durationTolerance: TimeInterval = 0.5

    public static func isWAV(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "wav"
    }

    /// Writes the WAV as an .m4a beside it, at its own sample rate and channel count, and
    /// opens the result to check it. Returns the .m4a. On any failure nothing is left
    /// behind but the WAV, which this never changes.
    ///
    /// Reads and writes the whole file, so call it off the main thread.
    public static func encode(_ wav: URL) throws -> URL {
        let output = wav.deletingPathExtension().appendingPathExtension("m4a")
        // Whatever is here is what an earlier attempt left when the app quit mid-write; the
        // call's path still names the WAV, so nothing refers to it.
        try? FileManager.default.removeItem(at: output)
        do {
            let source = try write(wav, to: output)
            try verify(output, against: source)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    /// What the WAV has, which the AAC has to match.
    struct Source {
        let seconds: Double
        let channels: AVAudioChannelCount
        let sampleRate: Double
    }

    private static func write(_ wav: URL, to output: URL) throws -> Source {
        let input = try AVAudioFile(forReading: wav)
        let format = input.processingFormat
        guard input.length > 0 else { throw VoiceError.audio("The WAV holds no audio.") }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: bitRatePerChannel * Int(format.channelCount),
        ]
        let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let step = AVAudioFrameCount(format.sampleRate)
        while input.framePosition < input.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: step) else {
                throw VoiceError.audio("Out of memory while converting the call's audio.")
            }
            try input.read(into: buffer, frameCount: step)
            guard buffer.frameLength > 0 else { break }
            try file.write(from: buffer)
        }
        // The encoder writes its last packets and the file's index when it closes.
        file.close()
        return Source(seconds: Double(input.length) / format.sampleRate, channels: format.channelCount,
                      sampleRate: format.sampleRate)
    }

    static func verify(_ output: URL, against source: Source) throws {
        let encoded = try AVAudioFile(forReading: output)
        let format = encoded.processingFormat
        guard format.channelCount == source.channels, format.sampleRate == source.sampleRate else {
            throw VoiceError.audio("The AAC has \(format.channelCount) channels at \(Int(format.sampleRate)) Hz, "
                                   + "not \(source.channels) at \(Int(source.sampleRate)).")
        }
        let seconds = Double(encoded.length) / format.sampleRate
        guard abs(seconds - source.seconds) <= durationTolerance else {
            throw VoiceError.audio("The AAC runs \(seconds) s and the WAV \(source.seconds) s.")
        }
        // A file can open and report a length without its audio decoding.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return }
        try encoded.read(into: buffer, frameCount: 4096)
        guard buffer.frameLength > 0 else { throw VoiceError.audio("The AAC doesn't decode.") }
    }
}
