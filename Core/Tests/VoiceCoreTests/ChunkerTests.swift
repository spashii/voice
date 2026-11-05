import XCTest
@testable import VoiceCore

final class ChunkerTests: XCTestCase {
    /// Speech stood in for by a tone over a quiet hiss, so the noise floor is real.
    private func signal(_ parts: [(seconds: Double, loud: Bool)]) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        var samples: [Float] = []
        for part in parts {
            for i in 0..<Int(part.seconds * Audio.sampleRate) {
                let hiss = Float.random(in: -0.002...0.002, using: &generator)
                samples.append(hiss + (part.loud ? 0.3 * sin(Float(i) * 0.1) : 0))
            }
        }
        return samples
    }

    private func cuts(_ samples: [Float]) -> [Int] {
        var chunker = Chunker()
        var cuts: [Int] = []
        // In the tap's buffer size, so frames straddle appends.
        for start in stride(from: 0, to: samples.count, by: 1365) {
            let end = min(start + 1365, samples.count)
            cuts += samples.withUnsafeBufferPointer { chunker.append(UnsafeBufferPointer(rebasing: $0[start..<end])) }
        }
        return cuts
    }

    func testCutsInsideAPause() {
        let samples = signal([(6, true), (1, false), (6, true)])
        let result = cuts(samples)
        XCTAssertEqual(result.count, 1)
        let seconds = Double(result[0]) / Audio.sampleRate
        XCTAssert(seconds > 6.0 && seconds < 7.0, "cut at \(seconds) s")
    }

    func testIgnoresAPauseBeforeTheMinimum() {
        XCTAssertEqual(cuts(signal([(2, true), (1, false), (2, true)])), [])
    }

    func testCapsAChunkWithNoPause() {
        let result = cuts(signal([(60, true)]))
        XCTAssertFalse(result.isEmpty)
        var previous = 0
        for cut in result + [Int(60 * Audio.sampleRate)] {
            XCTAssertLessThanOrEqual(Double(cut - previous) / Audio.sampleRate, 25.0 + 0.02)
            previous = cut
        }
    }
}
