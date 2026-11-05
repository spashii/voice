import Foundation
import Testing
@testable import VoiceCore

func temporaryCallDatabase() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "voice-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "voice.sqlite")
}

func sampleDictation(_ text: String, at date: Date = Date()) -> Dictation {
    Dictation(id: UUID().uuidString, createdAt: date, audioPath: "/tmp/\(UUID().uuidString).wav", duration: 2,
              mode: .plain, whisperModel: "test", rawText: text, finalText: text, cleanupModel: nil,
              cleanupSystem: nil, timings: .init(), segments: [], error: nil)
}

func sampleSegment(_ channel: CallSegment.Channel, _ startMs: Int, _ text: String) -> NewCallSegment {
    NewCallSegment(channel: channel, startMs: startMs, endMs: startMs + 1500, text: text)
}

@Suite struct CallStoreMigrationTests {
    @Test func addsCallsToADatabaseThatHasDictations() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        try store.insert(sampleDictation("the budget for the pilot is approved"))

        let calls = try CallStore(url: url)
        #expect(try calls.appliedMigrations() == ["calls-1", "search-1", "speakers-1", "retries-1", "retries-2", "edits-1"])
        #expect(store.recent(10).map(\.finalText) == ["the budget for the pilot is approved"])
        // Dictations made before the index existed are in it.
        #expect(try calls.search("budget").map(\.kind) == [.dictation])
    }

    @Test func runsEachMigrationOnce() throws {
        let url = temporaryCallDatabase()
        let first = try CallStore(url: url)
        try first.createCall(NewCall(split: true))
        let second = try CallStore(url: url)
        #expect(try second.appliedMigrations() == ["calls-1", "search-1", "speakers-1", "retries-1", "retries-2", "edits-1"])
        #expect(try second.calls().count == 1)
    }

    @Test func startsFromAnEmptyFile() throws {
        let url = temporaryCallDatabase()
        let calls = try CallStore(url: url)
        #expect(try calls.calls().isEmpty)
        // Store opened second still works, and its rows reach the index.
        let store = try Store(url: url)
        try store.insert(sampleDictation("hello from an empty file"))
        #expect(store.recent(5).count == 1)
        #expect(try calls.search("empty").count == 1)
    }
}

@Suite struct TranscriptSearchTests {
    @Test func findsCallSegmentsAndDictations() throws {
        let url = temporaryCallDatabase()
        let calls = try CallStore(url: url)
        let store = try Store(url: url)
        let call = try calls.createCall(NewCall(split: true, title: "Pilot review"))
        try calls.appendSegments(call.id, [
            sampleSegment(.me, 0, "Shall we talk about the municipalities?"),
            sampleSegment(.call, 2000, "Yes, the council approved the pilot."),
        ])
        try store.insert(sampleDictation("Remind me to email the council tomorrow"))

        let hits = try calls.search("council")
        #expect(hits.count == 2)
        let fromCall = try #require(hits.first { $0.kind == .call })
        #expect(fromCall.id == call.id)
        #expect(fromCall.channel == .call)
        #expect(fromCall.startMs == 2000)
        #expect(fromCall.title == "Pilot review")
        #expect(fromCall.snippet.contains("[council]"))
        #expect(hits.contains { $0.kind == .dictation })
    }

    @Test func stemsWordsAndFallsBackToAnyWord() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: false))
        try calls.appendSegments(call.id, [sampleSegment(.mix, 0, "They approved the budget")])
        #expect(try calls.search("approve").count == 1)
        // No segment has both words, so either one will do.
        #expect(try calls.search("budget zebra").count == 1)
    }

    @Test func treatsOperatorsAndPunctuationAsText() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: false))
        try calls.appendSegments(call.id, [sampleSegment(.mix, 0, "I don't think Final Cut is NEAR done")])
        for query in ["don't", "\"", "-", "NEAR(", "OR", "a*b", "Final Cut", "(done)", "   "] {
            _ = try calls.search(query)
        }
        #expect(try calls.search("don't").count == 1)
        #expect(try calls.search("Final Cut").count == 1)
        #expect(try calls.search("   ").isEmpty)
    }

    @Test func followsDeletesAndEdits() throws {
        let url = temporaryCallDatabase()
        let calls = try CallStore(url: url)
        let store = try Store(url: url)
        let call = try calls.createCall(NewCall(split: true))
        try calls.appendSegments(call.id, [sampleSegment(.me, 0, "Pineapple on the agenda")])
        let kept = sampleDictation("pineapple pizza order")
        let gone = sampleDictation("pineapple juice order")
        try store.insert(kept)
        try store.insert(gone)
        #expect(try calls.search("pineapple").count == 3)

        store.delete(gone.id)
        try calls.deleteCall(call.id)
        #expect(try calls.search("pineapple").map(\.id) == [kept.id])

        // Store writes with INSERT OR REPLACE: the replaced text must not linger.
        var edited = kept
        edited.finalText = "mango pizza order"
        try store.insert(edited)
        #expect(try calls.search("pineapple").isEmpty)
        #expect(try calls.search("mango").map(\.id) == [kept.id])

        store.prune(before: Date().addingTimeInterval(60))
        #expect(try calls.search("mango").isEmpty)
    }
}

@Suite struct CallLifecycleTests {
    @Test func recordsACallFromStartToFinish() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(appBundleID: "us.zoom.xos", appName: "zoom.us", deviceUID: "Blend",
                                                split: true, audioPath: "/tmp/call.wav"))
        #expect(call.status == .recording)
        #expect(try calls.currentCall()?.id == call.id)

        let written = try calls.appendSegments(call.id, [sampleSegment(.me, 0, "Hello"), sampleSegment(.call, 900, "Hi there")])
        #expect(written.map(\.id) == written.map(\.id).sorted())
        try calls.markTranscribing(call.id)
        #expect(try calls.currentCall()?.status == .transcribing)
        try calls.finishCall(call.id)

        let done = try #require(try calls.call(call.id))
        #expect(done.status == .done)
        #expect(done.endedAt != nil)
        #expect(done.appName == "zoom.us")
        #expect(try calls.currentCall() == nil)
    }

    @Test func failsAndRecoversInterruptedCalls() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let failed = try calls.createCall(NewCall(split: true))
        try calls.failCall(failed.id, error: "The mix went away.")
        #expect(try calls.call(failed.id)?.error == "The mix went away.")

        let stuck = try calls.createCall(NewCall(split: true))
        #expect(try calls.failInterruptedCalls() == 1)
        #expect(try calls.call(stuck.id)?.status == .failed)
        #expect(try calls.currentCall() == nil)
    }

    @Test func refusesSegmentsForAMissingCall() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        #expect(throws: VoiceError.self) { try calls.appendSegments("nope", [sampleSegment(.me, 0, "x")]) }
        #expect(throws: VoiceError.self) { try calls.finishCall("nope") }
    }

    @Test func mergesTheTranscriptByTime() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: true))
        // The two channels are transcribed apart, so they arrive out of time order.
        try calls.appendSegments(call.id, [sampleSegment(.me, 0, "Hello?"), sampleSegment(.me, 5000, "Good, and you?")])
        try calls.appendSegments(call.id, [sampleSegment(.call, 2000, " Hi, how are you? "), sampleSegment(.call, 3_725_000, "Bye.")])
        #expect(try calls.transcript(call.id) == """
            [00:00] Me: Hello?
            [00:02] Call: Hi, how are you?
            [00:05] Me: Good, and you?
            [1:02:05] Call: Bye.
            """)
        #expect(try calls.transcript(call.id, channel: .me) == "[00:00] Hello?\n[00:05] Good, and you?")
    }

    @Test func tagsAndFiltersCalls() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let old = try calls.createCall(NewCall(startedAt: Date().addingTimeInterval(-86400 * 3), split: true))
        let new = try calls.createCall(NewCall(split: true))
        #expect(try calls.tagCall(new.id, add: ["Globex", " pilot ", ""]) == ["Globex", "pilot"])
        #expect(try calls.tagCall(new.id, add: ["globex"], remove: ["PILOT"]) == ["Globex"])
        try calls.tagCall(old.id, add: ["globex"])

        #expect(try calls.calls().map(\.id) == [new.id, old.id])
        #expect(try calls.calls(tag: "GLOBEX").count == 2)
        #expect(try calls.calls(since: Date().addingTimeInterval(-3600)).map(\.id) == [new.id])
        #expect(try calls.calls(limit: 1).map(\.id) == [new.id])
    }
}

@Suite struct WaitForSegmentsTests {
    @Test func returnsWhatIsAlreadyThere() async throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: true))
        let written = try calls.appendSegments(call.id, [sampleSegment(.me, 0, "one"), sampleSegment(.call, 1000, "two")])

        let all = try await calls.waitForSegments(call.id, after: 0, timeout: .seconds(5))
        #expect(all.segments.map(\.text) == ["one", "two"])
        #expect(all.cursor == written.last?.id)

        let rest = try await calls.waitForSegments(call.id, after: written[0].id, timeout: .seconds(5))
        #expect(rest.segments.map(\.text) == ["two"])
    }

    @Test func timesOutWithTheSameCursor() async throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: true))
        let started = ContinuousClock.now
        let batch = try await calls.waitForSegments(call.id, after: 7, timeout: .milliseconds(700))
        #expect(batch.segments.isEmpty)
        #expect(batch.cursor == 7)
        #expect(!batch.ended)
        #expect(ContinuousClock.now - started >= .milliseconds(700))
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func seesSegmentsAnotherConnectionWrites() async throws {
        let url = temporaryCallDatabase()
        let reader = try CallStore(url: url)
        let writer = try CallStore(url: url)
        let call = try writer.createCall(NewCall(split: true))
        let cursor = try reader.latestCursor()

        let started = ContinuousClock.now
        async let batch = reader.waitForSegments(call.id, after: cursor, timeout: .seconds(10))
        try await Task.sleep(for: .milliseconds(300))
        try writer.appendSegments(call.id, [sampleSegment(.call, 0, "Are you there?")])
        let result = try await batch
        #expect(result.segments.map(\.text) == ["Are you there?"])
        #expect(result.cursor > cursor)
        // Within a poll or two of the write, not at the timeout.
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func followsTheCurrentCallAndItsEnd() async throws {
        let url = temporaryCallDatabase()
        let reader = try CallStore(url: url)
        let writer = try CallStore(url: url)

        let nothing = try await reader.waitForSegments(nil, after: 0, timeout: .milliseconds(300))
        #expect(nothing.call == nil)
        #expect(!nothing.ended)

        // Waiting before the call starts picks it up once it does.
        async let first = reader.waitForSegments(nil, after: 0, timeout: .seconds(10))
        try await Task.sleep(for: .milliseconds(300))
        let call = try writer.createCall(NewCall(split: true))
        try writer.appendSegments(call.id, [sampleSegment(.me, 0, "Starting now")])
        let started = try await first
        #expect(started.call?.id == call.id)
        #expect(started.segments.map(\.text) == ["Starting now"])

        try writer.finishCall(call.id)
        let ended = try await reader.waitForSegments(call.id, after: started.cursor, timeout: .seconds(10))
        #expect(ended.ended)
        #expect(ended.cursor == started.cursor)
    }

    @Test func pagesALongBacklog() async throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: false))
        try calls.appendSegments(call.id, (0..<5).map { sampleSegment(.mix, $0 * 1000, "line \($0)") })
        let page = try await calls.waitForSegments(call.id, after: 0, timeout: .zero, limit: 3)
        #expect(page.segments.count == 3)
        #expect(page.more)
        let next = try await calls.waitForSegments(call.id, after: page.cursor, timeout: .zero, limit: 3)
        #expect(next.segments.map(\.text) == ["line 3", "line 4"])
        #expect(!next.more)
    }

    @Test func cursorsNeverGoBackAfterADelete() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let first = try calls.createCall(NewCall(split: false))
        let old = try calls.appendSegments(first.id, [sampleSegment(.mix, 0, "old")])
        try calls.deleteCall(first.id)
        let second = try calls.createCall(NewCall(split: false))
        let new = try calls.appendSegments(second.id, [sampleSegment(.mix, 0, "new")])
        #expect(new[0].id > old[0].id)
    }
}

@Suite struct DictationReadTests {
    @Test func listsAndReadsDictations() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        var older = sampleDictation("older", at: Date().addingTimeInterval(-7200))
        older.segments = [Segment(t0: 0, t1: 1.5, text: "older", avgLogprob: -.infinity, noSpeechProb: 0.1,
                                  compressionRatio: 1, speechSeconds: 1.2, wordsPerSecond: 0.8)]
        try store.insert(older)
        try store.insert(sampleDictation("newer"))
        var short = sampleDictation("")
        short.duration = 0.1
        try store.insert(short)

        #expect(try calls.dictations().map(\.finalText) == ["newer", "older"])
        #expect(try calls.dictations(since: Date().addingTimeInterval(-3600)).map(\.finalText) == ["newer"])
        let read = try #require(try calls.dictation(older.id))
        #expect(read.segments.count == 1)
        #expect(read.segments[0].avgLogprob == -.infinity)
        #expect(try calls.dictation("missing") == nil)
    }
}
