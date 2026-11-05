import Foundation
import Testing
@testable import VoiceCore

private func devices(_ json: String) throws -> BlendDevices {
    try JSONDecoder().decode(BlendDevices.self, from: Data(json.utf8))
}

private let micAndSystem = """
    {"deviceUID": "app.blend.mix.split", "id": "split", "name": "Mic and system audio", "split": true, "sources": [
      {"channel": "left", "kind": "device", "name": "MacBook Air Microphone", "uid": "BuiltInMicrophoneDevice"},
      {"channel": "right", "kind": "system", "name": "System audio"}]}
    """

private let mixedWithSystem = """
    {"deviceUID": "app.blend.mix.mixed", "id": "mixed", "name": "Everything", "split": false, "sources": [
      {"channel": "both", "kind": "device", "name": "Mic", "uid": "BuiltInMicrophoneDevice"},
      {"channel": "both", "kind": "system", "name": "System audio"}]}
    """

private let micOnly = """
    {"deviceUID": "app.blend.mix.mic", "id": "mic", "name": "Blend Mic", "split": false, "sources": [
      {"channel": "both", "kind": "device", "name": "Mic", "uid": "BuiltInMicrophoneDevice"}]}
    """

@Suite struct CallSourceTests {
    @Test func prefersTheSplitMix() throws {
        let blend = try devices(#"{"version": 1, "mixes": [\#(micOnly), \#(mixedWithSystem), \#(micAndSystem)]}"#)
        let source = CallSources.choose(blend)
        #expect(source.deviceUID == "app.blend.mix.split")
        #expect(source.channels == [.me, .call])
        #expect(source.split && source.fromBlend)
    }

    @Test func fallsBackToAMixWithSystemAudioAsOneChannel() throws {
        let blend = try devices(#"{"version": 1, "mixes": [\#(micOnly), \#(mixedWithSystem)]}"#)
        let source = CallSources.choose(blend)
        #expect(source.deviceUID == "app.blend.mix.mixed")
        #expect(source.channels == [.mix])
        #expect(source.fromBlend)
    }

    @Test func withoutAUsableMixRecordsTheDefaultMicrophone() throws {
        #expect(CallSources.choose(nil) == .defaultMicrophone)
        #expect(CallSources.choose(try devices(#"{"version": 1, "mixes": [\#(micOnly)]}"#)) == .defaultMicrophone)
        #expect(!CallSource.defaultMicrophone.fromBlend)
    }

    @Test func skipsAMixWhoseDeviceIsMissing() throws {
        let blend = try devices(#"{"version": 1, "mixes": [\#(micAndSystem), \#(mixedWithSystem)]}"#)
        let source = CallSources.choose(blend) { $0 != "app.blend.mix.split" }
        #expect(source.deviceUID == "app.blend.mix.mixed")
    }

    @Test func labelsChannelsByWhatTheyCarry() throws {
        let swapped = try devices("""
            {"mixes": [{"deviceUID": "d", "name": "Swapped", "split": true, "sources": [
              {"channel": "left", "kind": "app", "name": "Zoom", "bundleID": "us.zoom.xos"},
              {"channel": "right", "kind": "device", "name": "Mic", "uid": "m"}]}]}
            """)
        #expect(CallSources.choose(swapped).channels == [.call, .me])
        let twoMics = try devices("""
            {"mixes": [{"deviceUID": "d", "name": "Two mics", "split": true, "sources": [
              {"channel": "left", "kind": "device", "name": "A", "uid": "a"},
              {"channel": "right", "kind": "device", "name": "B", "uid": "b"}]}]}
            """)
        #expect(CallSources.choose(twoMics).channels == [.me, .call])
        #expect(CallSources.choose(twoMics).speakers == ["A", "B"])
        #expect(CallSources.choose(swapped).speakers == nil)
        #expect(CallSegment.Channel.me.label == "Me" && CallSegment.Channel.call.label == "Call")
    }

    @Test func twoAppsGoByTheirNames() throws {
        let twoApps = try devices("""
            {"mixes": [{"deviceUID": "d", "name": "Two apps", "split": true, "sources": [
              {"channel": "left", "kind": "app", "name": "Zoom", "bundleID": "us.zoom.xos"},
              {"channel": "right", "kind": "system", "name": "System audio"}]}]}
            """)
        let source = CallSources.choose(twoApps)
        #expect(source.channels == [.me, .call])
        #expect(source.speakers == ["Zoom", "System audio"])
        #expect(try CallSources.choose(devices(#"{"version": 1, "mixes": [\#(micAndSystem)]}"#)).speakers == nil)

        let segments = [
            CallSegment(id: 1, callID: "c", channel: .me, startMs: 0, endMs: 1000, text: "hi", avgLogprob: nil,
                        noSpeechProb: nil, compressionRatio: nil, createdAt: Date()),
            CallSegment(id: 2, callID: "c", channel: .call, startMs: 1500, endMs: 2000, text: "hello", avgLogprob: nil,
                        noSpeechProb: nil, compressionRatio: nil, createdAt: Date()),
        ]
        #expect(CallTranscript.text(segments, speakers: source.speakers) == "[00:00] Zoom: hi\n[00:01] System audio: hello")
        #expect(CallTranscript.text(segments) == "[00:00] Me: hi\n[00:01] Call: hello")
    }

    @Test func aCallKeepsItsSpeakers() throws {
        let store = try CallStore(url: temporaryCallDatabase())
        let named = try store.createCall(NewCall(split: true, speakers: ["Zoom", "Teams"]))
        let plain = try store.createCall(NewCall(split: true))
        try store.appendSegments(named.id, [sampleSegment(.me, 0, "left side"), sampleSegment(.call, 2000, "right side")])
        #expect(try store.call(named.id)?.speakers == ["Zoom", "Teams"])
        #expect(try store.call(plain.id)?.speakers == nil)
        #expect(try store.transcript(named.id) == "[00:00] Zoom: left side\n[00:02] Teams: right side")
    }

    @Test func detectorClassifiesAppsAndHelpers() {
        #expect(CallApps.kind("us.zoom.xos")?.kind == .communication)
        #expect(CallApps.kind("com.google.Chrome.helper")?.id == "com.google.Chrome")
        #expect(CallApps.kind("com.google.Chrome.helper")?.kind == .browser)
        #expect(CallApps.kind("io.github.spashii.voice") == nil)
        #expect(CallApps.kind("ru.starmel.OpenSuperWhisper") == nil)
        #expect(CallApps.kind("com.apple.Music") == nil)
    }

    @Test func aCallAppOrItsHelperReadingTheMixIsFound() {
        let zoom = DetectedCall(bundleID: "us.zoom.xos", name: "zoom.us")
        let chrome = DetectedCall(bundleID: "com.google.Chrome", name: "Google Chrome")
        #expect(CallApps.reads(zoom, readers: ["us.zoom.xos"]))
        #expect(CallApps.reads(chrome, readers: ["com.google.Chrome.helper"]))
        #expect(!CallApps.reads(zoom, readers: ["us.zoom.xosx", "com.google.Chrome"]))
        #expect(!CallApps.reads(zoom, readers: []))
        #expect(CallSource.readsMixNotice("Zoom") == "Zoom is using the Blend mix as its microphone, so the call "
            + "side can't be recorded. Set Zoom back to your microphone.")
    }
}

@Suite struct SpeechChunkerTests {
    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { 0.2 * sin(Float($0) * 0.2) }
    }

    private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }

    @Test func cutsAtPausesWithTimesFromTheStart() {
        var chunker = SpeechChunker()
        let cut = chunker.append(silence(1) + tone(2) + silence(1) + tone(1.5) + silence(1))
        #expect(cut.count == 2)
        // Each chunk starts a little before its speech and covers all of it.
        #expect(abs(Double(cut[0].start) / 16_000 - 0.7) < 0.1)
        #expect(Double(cut[0].samples.count) / 16_000 > 2)
        #expect(abs(Double(cut[1].start) / 16_000 - 3.7) < 0.1)
        #expect(chunker.flush() == nil)
    }

    @Test func flushKeepsTheTailAndLongSpeechIsCapped() {
        var chunker = SpeechChunker()
        let cut = chunker.append(tone(17))
        #expect(cut.count == 1)
        #expect(cut[0].samples.count <= SpeechChunker.maxSamples + SpeechChunker.frame)
        let tail = chunker.flush()
        #expect(tail != nil)
        #expect(tail!.start == cut[0].samples.count)
    }
}
