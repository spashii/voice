import SwiftUI
import VoiceCore

/// Shown for the whole of a call recording, so it is never left running unnoticed: the
/// clock and the key that stops it, and under them the newest lines as they are
/// transcribed, laid out like the dictation pill's live text. Older lines fade, and a long
/// line keeps its end.
struct CallPill: View {
    let startedAt: Date
    let stopHint: String
    let lines: [LiveCallLines.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Recording call")
                Text(startedAt, style: .timer).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                Text(stopHint).foregroundStyle(.secondary)
            }
            .frame(height: 16)
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let label = line.label {
                        Text(label)
                            .foregroundStyle(Self.color(line.channel))
                            .fixedSize()
                    }
                    Text(line.text)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .frame(maxWidth: 400, alignment: .leading)
                .opacity(Self.opacity(age: lines.count - 1 - index))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 28)
        // A capsule while it is one line, a rounded box once lines open under it, as the
        // dictation pill does.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: lines.isEmpty ? 14 : 16, style: .continuous))
        .animation(.easeOut(duration: 0.25), value: lines)
    }

    /// The newest line in full, each older one fainter.
    static func opacity(age: Int) -> Double {
        [1, 0.6, 0.35][min(age, 2)]
    }

    /// The two sides apart at a glance, without either shouting.
    static func color(_ channel: CallSegment.Channel) -> Color {
        channel == .me ? Color.blue.opacity(0.75) : Color.purple.opacity(0.75)
    }
}
