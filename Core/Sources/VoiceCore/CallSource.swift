import Foundation

/// What a call is recorded from, and which side of the call each input channel carries.
public struct CallSource: Sendable, Equatable {
    /// The input's Core Audio UID; nil records the default microphone.
    public var deviceUID: String?
    public var name: String
    /// One label per input channel recorded: [.me, .call] (or [.call, .me]) for a split
    /// Blend mix, [.mix] otherwise.
    public var channels: [CallSegment.Channel]
    /// Whether this is a Blend mix, so the hint about making one can stay hidden.
    public var fromBlend: Bool
    /// The two sides' names, in channel order, when they are of the same kind and so
    /// neither is me nor the call.
    public var speakers: [String]?

    public init(deviceUID: String?, name: String, channels: [CallSegment.Channel], fromBlend: Bool,
                speakers: [String]? = nil) {
        self.deviceUID = deviceUID
        self.name = name
        self.channels = channels
        self.fromBlend = fromBlend
        self.speakers = speakers
    }

    public var split: Bool { channels.count == 2 }

    public static let defaultMicrophone = CallSource(deviceUID: nil, name: "Default microphone", channels: [.mix],
                                                     fromBlend: false)

    /// Shown once in Settings when no Blend mix carries the other side of a call.
    public static let blendHint = "For both sides, make a Mic and system audio mix in Blend"

    /// Shown in Settings under a Blend mix: Blend leaves every app reading a mix out of that
    /// mix's System audio, so a call app reading it would record as silence.
    public static let mixRule = "Keep your call app on its usual microphone. Only Voice reads this mix."

    /// The notice when a call app reads the mix being recorded, for the same reason.
    public static func readsMixNotice(_ app: String) -> String {
        "\(app) is using the Blend mix as its microphone, so the call side can't be recorded. "
            + "Set \(app) back to your microphone."
    }
}

/// Blend's description of its mixes, which it rewrites whenever one changes. The format is
/// in Blend's docs/MIXES-FOR-APPS.md.
public struct BlendDevices: Decodable, Sendable {
    public struct Source: Decodable, Sendable {
        public var kind: String
        public var channel: String?
        public var name: String?
        public var uid: String?
        public var bundleID: String?

        /// Sound from this Mac's apps rather than a microphone: the other side of a call.
        var isCallAudio: Bool { kind == "system" || kind == "app" }
    }

    public struct Mix: Decodable, Sendable {
        public var deviceUID: String
        public var name: String
        public var sources: [Source]
        public var split: Bool
    }

    public var mixes: [Mix]

    public static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Blend/devices.json")
    }

    /// Nil when Blend has never run, is uninstalled, or wrote something this can't read.
    public static func load(_ url: URL = file) -> BlendDevices? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BlendDevices.self, from: data)
    }
}

public enum CallSources {
    /// A split mix first, since only it tells the two sides apart; then any mix carrying
    /// System audio, recorded as one channel; then the default microphone, which hears only
    /// this side unless the call plays through speakers. A mix whose device isn't connected
    /// (Blend isn't running) is passed over rather than recorded as silence.
    public static func choose(_ blend: BlendDevices?, connected: (String) -> Bool = { _ in true }) -> CallSource {
        let mixes = (blend?.mixes ?? []).filter { connected($0.deviceUID) }
        if let mix = mixes.first(where: { $0.split && $0.sources.count == 2 && labels($0) != nil }),
           let (channels, speakers) = labels(mix) {
            return CallSource(deviceUID: mix.deviceUID, name: mix.name, channels: channels, fromBlend: true,
                              speakers: speakers)
        }
        if let mix = mixes.first(where: { $0.sources.contains { $0.kind == "system" } }) {
            return CallSource(deviceUID: mix.deviceUID, name: mix.name, channels: [.mix], fromBlend: true)
        }
        return .defaultMicrophone
    }

    /// The side each channel of a split mix carries. A microphone is me and app or system
    /// sound is the call, whichever side Blend put them on. Two of a kind, two apps or two
    /// microphones, are neither: they keep their order and go by their sources' names.
    static func labels(_ mix: BlendDevices.Mix) -> (channels: [CallSegment.Channel], speakers: [String]?)? {
        guard mix.split, mix.sources.count == 2 else { return nil }
        let left = mix.sources.first { $0.channel == "left" } ?? mix.sources[0]
        let right = mix.sources.first { $0.channel == "right" } ?? mix.sources[1]
        if left.isCallAudio == right.isCallAudio {
            return ([.me, .call], [left.name ?? "Left", right.name ?? "Right"])
        }
        return (left.isCallAudio ? [.call, .me] : [.me, .call], nil)
    }
}
