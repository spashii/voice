import Foundation
import Testing
@testable import VoiceCore

private func zoom(input: Bool, output: Bool) -> CallDetector.Usage {
    CallDetector.Usage(bundleID: "us.zoom.xos", name: "zoom.us", kind: .communication, input: input, output: output)
}

@Suite struct CallTrackerTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// Feeds one poll a second, from `from` to `to` seconds, and returns every change.
    private func run(_ tracker: inout CallTracker, _ from: Int, _ to: Int,
                     _ usage: [CallDetector.Usage]) -> [[String]] {
        (from...to).compactMap { tracker.update(usage, at: start.addingTimeInterval(Double($0))) }
            .map { $0.map(\.bundleID) }
    }

    @Test func muteAndADeviceSwitchKeepOneCall() {
        var tracker = CallTracker()
        #expect(run(&tracker, 0, 10, [zoom(input: true, output: true)]) == [["us.zoom.xos"]])
        // Muted: the input closes, the call still plays.
        #expect(run(&tracker, 11, 60, [zoom(input: false, output: true)]).isEmpty)
        // A device switch: nothing at all for a few seconds.
        #expect(run(&tracker, 61, 72, []).isEmpty)
        #expect(run(&tracker, 73, 80, [zoom(input: true, output: true)]).isEmpty)
    }

    @Test func endsAfterFifteenSecondsWithNeitherInputNorOutput() {
        var tracker = CallTracker()
        _ = run(&tracker, 0, 10, [zoom(input: true, output: false)])
        #expect(run(&tracker, 11, 25, []).isEmpty)
        #expect(run(&tracker, 26, 26, []) == [[]])
    }

    @Test func outputAloneNeverStartsACall() {
        var tracker = CallTracker()
        #expect(run(&tracker, 0, 30, [zoom(input: false, output: true)]).isEmpty)
    }
}
