import Foundation

/// What a call is recorded from, and which side of the call each input channel carries.
public struct CallSource: Sendable, Equatable, Identifiable {
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

    /// What Settings stores for it: the device's UID, or empty for the system default.
    public var id: String { deviceUID ?? "" }

    /// How Settings lists it. A split mix says which side Blend put on each channel; anything
    /// else is recorded as one channel, both sides mixed.
    public var label: String {
        guard split else { return "\(name) (mix)" }
        let sides = speakers ?? channels.map { $0 == .me ? "you" : "call" }
        return "\(name) (\(sides[0]) left, \(sides[1]) right)"
    }

    /// Whichever input macOS has as its default when the call starts.
    public static let systemDefault = CallSource(deviceUID: nil, name: "System default", channels: [.mix],
                                                 fromBlend: false)

    /// Shown in Settings under a split mix: Blend leaves every app reading a mix out of that
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
    /// Every input a call can record from, as Settings lists them: Blend's connected mixes
    /// in Blend's order, then the system default, then the other inputs by name. A mix whose
    /// device isn't connected (Blend isn't running) is left out rather than recorded as
    /// silence.
    public static func all(_ blend: BlendDevices?, devices: [InputDevice]) -> [CallSource] {
        let connected = Set(devices.map(\.uid))
        let mixes = (blend?.mixes ?? []).filter { connected.contains($0.deviceUID) }
        let mixUIDs = Set(mixes.map(\.deviceUID))
        let others = devices.filter { !mixUIDs.contains($0.uid) }.map {
            CallSource(deviceUID: $0.uid, name: $0.name, channels: [.mix], fromBlend: false)
        }
        return mixes.map(source) + [.systemDefault] + others
    }

    /// The split mix if there is one, since only it tells the two sides apart; otherwise the
    /// system default, which hears only this side unless the call plays through speakers.
    public static func automatic(_ sources: [CallSource]) -> CallSource {
        sources.first(where: \.split) ?? .systemDefault
    }

    /// The input chosen in Settings while it is connected, and the automatic one otherwise:
    /// a call is never lost to an unplugged input. `chosen` is nil until one is chosen.
    public static func choose(_ sources: [CallSource], chosen: String?) -> CallSource {
        chosen.flatMap { id in sources.first { $0.id == id } } ?? automatic(sources)
    }

    static func source(_ mix: BlendDevices.Mix) -> CallSource {
        guard let (channels, speakers) = labels(mix) else {
            return CallSource(deviceUID: mix.deviceUID, name: mix.name, channels: [.mix], fromBlend: true)
        }
        return CallSource(deviceUID: mix.deviceUID, name: mix.name, channels: channels, fromBlend: true,
                          speakers: speakers)
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
