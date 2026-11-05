import Foundation
import Testing
@testable import VoiceCore

private func said(_ id: Int64, _ channel: CallSegment.Channel, _ text: String) -> CallSegment {
    CallSegment(id: id, callID: "c", channel: channel, startMs: Int(id) * 1000, endMs: Int(id) * 1000 + 900,
                text: text, avgLogprob: nil, noSpeechProb: nil, compressionRatio: nil, createdAt: Date())
}

@Suite struct LiveCallLinesTests {
    @Test func aSideTalkingOnJoinsOneLineAndATurnStartsTheNext() {
        var live = LiveCallLines()
        live.add([said(1, .me, " Hi, can you hear me?"), said(2, .me, "I'll share my screen.")])
        live.add([said(3, .call, "Yes, loud and clear."), said(4, .me, "Great.")])
        #expect(live.lines == [
            .init(id: 1, channel: .me, label: "Me", text: "Hi, can you hear me? I'll share my screen."),
            .init(id: 3, channel: .call, label: "Call", text: "Yes, loud and clear."),
            .init(id: 4, channel: .me, label: "Me", text: "Great."),
        ])
    }

    @Test func keepsTheNewestThreeNewestLast() {
        var live = LiveCallLines()
        live.add([said(1, .me, "one"), said(2, .call, "two"), said(3, .me, "three"), said(4, .call, "four")])
        #expect(live.lines.map(\.text) == ["two", "three", "four"])
        live.add([said(5, .call, "and more")])
        #expect(live.lines.map(\.text) == ["two", "three", "four and more"])
    }

    @Test func unsplitAudioHasNoLabelAndNamedSidesUseTheirNames() {
        var mixed = LiveCallLines()
        mixed.add([said(1, .mix, "everyone at once"), said(2, .mix, "still")])
        #expect(mixed.lines == [.init(id: 1, channel: .mix, label: nil, text: "everyone at once still")])

        var named = LiveCallLines(speakers: ["Ana", "Ben"])
        named.add([said(1, .me, "left"), said(2, .call, "right")])
        #expect(named.lines.map(\.label) == ["Ana", "Ben"])
    }

    @Test func emptyTextAddsNothingAndClearStartsFresh() {
        var live = LiveCallLines()
        live.add([said(1, .me, "  "), said(2, .call, "hello")])
        live.add([said(3, .me, "")])
        #expect(live.lines.map(\.text) == ["hello"])
        live.clear()
        live.add([said(4, .call, "again")])
        #expect(live.lines == [.init(id: 4, channel: .call, label: "Call", text: "again")])
    }

    @Test func aLongLineKeepsItsEndFromAWordBoundary() {
        var live = LiveCallLines()
        let words = (1...100).map { "word\($0)" }
        for (i, word) in words.enumerated() { live.add([said(Int64(i + 1), .call, word)]) }
        let text = live.lines[0].text
        #expect(live.lines.count == 1)
        #expect(text.count <= LiveCallLines.keptCharacters)
        #expect(text.hasSuffix("word99 word100"))
        #expect(text.hasPrefix("word"))
    }
}
