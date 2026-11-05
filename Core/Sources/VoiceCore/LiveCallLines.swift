import Foundation

/// The newest lines of a call while it records, for the call pill. Segments from the same
/// side in a row join one line; a line is labelled with its side, Me and Call or the call's
/// speakers as the transcript names them, and has no label when the audio isn't split.
/// Newest last.
public struct LiveCallLines: Sendable, Equatable {
    public struct Line: Sendable, Equatable, Identifiable {
        /// The first segment's id, so a line keeps its place on screen as it grows.
        public var id: Int64
        public var channel: CallSegment.Channel
        public var label: String?
        public var text: String

        public init(id: Int64, channel: CallSegment.Channel, label: String?, text: String) {
            self.id = id
            self.channel = channel
            self.label = label
            self.text = text
        }
    }

    /// Lines kept, and so shown.
    public static let shown = 3
    /// The end of a line kept, from a word boundary: the pill shows only a line's last words,
    /// and one side talking for minutes would otherwise grow a line without end.
    static let keptCharacters = 240

    public private(set) var lines: [Line] = []
    private let speakers: [String]?

    public init(speakers: [String]? = nil) {
        self.speakers = speakers
    }

    public mutating func add(_ segments: [CallSegment]) {
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = lines.last, last.channel == segment.channel {
                lines[lines.count - 1].text = Self.end(last.text + " " + text)
            } else {
                lines.append(Line(id: segment.id, channel: segment.channel, label: label(segment.channel),
                                  text: Self.end(text)))
            }
        }
        if lines.count > Self.shown { lines.removeFirst(lines.count - Self.shown) }
    }

    /// Empties the pill after a quiet spell, so the next words start fresh.
    public mutating func clear() {
        lines = []
    }

    func label(_ channel: CallSegment.Channel) -> String? {
        let named: String? = switch channel {
        case .me: speakers?.first
        case .call: speakers.flatMap { $0.count > 1 ? $0[1] : nil }
        case .mix: nil
        }
        return named ?? channel.label
    }

    static func end(_ text: String) -> String {
        guard text.count > keptCharacters else { return text }
        let end = text.suffix(keptCharacters)
        return String(end.firstIndex(of: " ").map { end[end.index(after: $0)...] } ?? end)
    }
}
