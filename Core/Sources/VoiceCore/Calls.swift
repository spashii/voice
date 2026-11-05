import Foundation

/// A recorded call: a Blend mix, either split (this Mac's microphone on the left, the
/// call's audio on the right) or mixed into one channel.
public struct Call: Sendable, Codable, Identifiable, Equatable {
    public enum Status: String, Sendable, Codable, CaseIterable {
        case recording
        /// Recording has stopped and the last of the audio is still being transcribed.
        case transcribing
        case done
        case failed

        /// Whether segments can still arrive.
        public var isLive: Bool { self == .recording || self == .transcribing }
    }

    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    /// The app the call ran in, such as us.zoom.xos, when the recorder could tell.
    public var appBundleID: String?
    public var appName: String?
    /// The input recorded, by Core Audio UID.
    public var deviceUID: String?
    /// Whether the two sides were recorded apart, so segments say who spoke.
    public var split: Bool
    public var audioPath: String?
    public var status: Status
    public var title: String?
    public var error: String?
    public var tags: [String]
    /// What the two sides of a split call are called, left then right, when neither is me:
    /// two apps, or two microphones. Nil means me on the left and the call on the right.
    public var speakers: [String]?
}

/// A stretch of transcript from one side of a call.
public struct CallSegment: Sendable, Codable, Equatable, Identifiable {
    public enum Channel: String, Sendable, Codable, CaseIterable {
        /// This Mac's microphone: the left channel of a split mix.
        case me
        /// Everyone else: the right channel of a split mix.
        case call
        /// Both sides in one channel, when the mix wasn't split.
        case mix

        /// How a merged transcript names the speaker; mixed audio has no single speaker.
        public var label: String? {
            switch self {
            case .me: "Me"
            case .call: "Call"
            case .mix: nil
            }
        }
    }

    /// Rises with every segment written to any call and is never reused, so the last one an
    /// agent has seen is the cursor for asking what came after.
    public var id: Int64
    public var callID: String
    public var channel: Channel
    /// Milliseconds from the start of the call.
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var avgLogprob: Double?
    public var noSpeechProb: Double?
    public var compressionRatio: Double?
    public var createdAt: Date
    /// Whisper's text, when an agent has corrected the segment and `text` is the correction.
    public var originalText: String? = nil

    public var corrected: Bool { originalText != nil }
}

/// What the recorder knows when a call starts.
public struct NewCall: Sendable {
    public var id: String
    public var startedAt: Date
    public var appBundleID: String?
    public var appName: String?
    public var deviceUID: String?
    public var split: Bool
    public var audioPath: String?
    public var title: String?
    public var speakers: [String]?

    public init(id: String = UUID().uuidString, startedAt: Date = Date(), appBundleID: String? = nil,
                appName: String? = nil, deviceUID: String? = nil, split: Bool, audioPath: String? = nil,
                title: String? = nil, speakers: [String]? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.appBundleID = appBundleID
        self.appName = appName
        self.deviceUID = deviceUID
        self.split = split
        self.audioPath = audioPath
        self.title = title
        self.speakers = speakers
    }
}

/// A segment as the recorder hands it over, before the store numbers it.
public struct NewCallSegment: Sendable {
    public var channel: CallSegment.Channel
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var avgLogprob: Double?
    public var noSpeechProb: Double?
    public var compressionRatio: Double?
    /// What the retry pass did with it, stored beside the segment.
    public var retry: SegmentRetry.Record?

    public init(channel: CallSegment.Channel, startMs: Int, endMs: Int, text: String, avgLogprob: Double? = nil,
                noSpeechProb: Double? = nil, compressionRatio: Double? = nil, retry: SegmentRetry.Record? = nil) {
        self.channel = channel
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.avgLogprob = avgLogprob
        self.noSpeechProb = noSpeechProb
        self.compressionRatio = compressionRatio
        self.retry = retry
    }

    /// Whisper's segment from a chunk of audio that began `offset` seconds into the call.
    public init(channel: CallSegment.Channel, segment: Segment, offset: Double) {
        self.init(channel: channel, startMs: Int(((offset + segment.t0) * 1000).rounded()),
                  endMs: Int(((offset + segment.t1) * 1000).rounded()), text: segment.text,
                  avgLogprob: segment.avgLogprob, noSpeechProb: segment.noSpeechProb,
                  compressionRatio: segment.compressionRatio, retry: segment.retry)
    }
}

/// What a wait for new segments found.
public struct SegmentBatch: Sendable {
    /// The call waited on; nil when asked for the current call and none was live.
    public var call: Call?
    /// In the order they were written.
    public var segments: [CallSegment]
    /// The cursor to wait from next: the last segment returned, or the one passed in.
    public var cursor: Int64
    /// More segments were waiting than one batch holds; ask again at once.
    public var more: Bool

    /// The call is over and nothing after the cursor is left to read.
    public var ended: Bool {
        guard let call else { return false }
        return !call.status.isLive && segments.isEmpty
    }
}

/// A match from the search over call transcripts and dictations.
public struct SearchHit: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case call
        case dictation
    }

    public var kind: Kind
    /// The call's id or the dictation's.
    public var id: String
    /// When the call started, or when the dictation was made.
    public var at: Date
    public var title: String?
    /// For a call: which side said it, the segment's id and where it starts in the call.
    public var channel: CallSegment.Channel?
    public var segmentID: Int64?
    public var startMs: Int?
    /// The matching text, with the matched words in [brackets].
    public var snippet: String
    /// True when the match is in an agent's correction; nil otherwise, so it is left out.
    public var corrected: Bool? = nil
}

public enum CallTranscript {
    /// One line per segment in time order, as "[01:02] Me: text". A single channel, or
    /// audio that wasn't split, has no speaker to name, so its lines have no label.
    /// `speakers` names the left and right sides in place of Me and Call.
    public static func text(_ segments: [CallSegment], labels: Bool = true, speakers: [String]? = nil) -> String {
        segments
            .sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
            .map { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = speakers.flatMap { names -> String? in
                    switch segment.channel {
                    case .me: names.first
                    case .call: names.count > 1 ? names[1] : nil
                    case .mix: nil
                    }
                } ?? segment.channel.label
                let speaker = labels ? name.map { "\($0): " } ?? "" : ""
                return "[\(clock(segment.startMs))] \(speaker)\(text)"
            }
            .joined(separator: "\n")
    }

    /// m:ss, or h:mm:ss past the first hour.
    public static func clock(_ ms: Int) -> String {
        let s = max(0, ms / 1000)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
