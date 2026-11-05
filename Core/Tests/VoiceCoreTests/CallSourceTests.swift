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

/// The inputs Core Audio would list with these Blend mixes connected, and the built-in microphone.
private func inputs(_ uids: String...) -> [InputDevice] {
    uids.map { InputDevice(uid: $0, name: $0 == "BuiltInMicrophoneDevice" ? "MacBook Air Microphone" : $0) }
}

/// The first mix in a devices.json, as a source.
private func first(_ blend: BlendDevices) -> CallSource {
    CallSources.source(blend.mixes[0])
}

@Suite struct CallSourceTests {
    @Test func prefersTheSplitMix() throws {
        let blend = try devices(#"{"version": 1, "mixes": [\#(micOnly), \#(mixedWithSystem), \#(micAndSystem)]}"#)
        let sources = CallSources.all(blend, devices: inputs("app.blend.mix.mic", "app.blend.mix.mixed",
                                                            "app.blend.mix.split", "BuiltInMicrophoneDevice"))
        let source = CallSources.automatic(sources)
        #expect(source.deviceUID == "app.blend.mix.split")
        #expect(source.channels == [.me, .call])
        #expect(source.split && source.fromBlend)
        #expect(CallSources.choose(sources, chosen: nil) == source)
    }

    @Test func withoutASplitMixRecordsTheSystemDefault() throws {
        let blend = try devices(#"{"version": 1, "mixes": [\#(micOnly), \#(mixedWithSystem)]}"#)
        let devices = inputs("app.blend.mix.mic", "app.blend.mix.mixed", "BuiltInMicrophoneDevice")
        #expect(CallSources.automatic(CallSources.all(blend, devices: devices)) == .systemDefault)
        #expect(CallSources.automatic(CallSources.all(nil, devices: devices)) == .systemDefault)
        #expect(CallSources.automatic([]) == .systemDefault)
        #expect(!CallSource.systemDefault.fromBlend && CallSource.systemDefault.deviceUID == nil)
    }

    @Test func skipsAMixWhoseDeviceIsMissing() throws {
        let blend = try devices(#"{"version": 1, "mixes": [\#(micAndSystem), \#(mixedWithSystem)]}"#)
        let sources = CallSources.all(blend, devices: inputs("app.blend.mix.mixed", "BuiltInMicrophoneDevice"))
        #expect(!sources.contains { $0.deviceUID == "app.blend.mix.split" })
        #expect(CallSources.automatic(sources) == .systemDefault)
    }

    @Test func aChosenInputIsUsedWhileItIsConnected() throws {
        let blend = try devices(#"{"version": 1, "mixes": [\#(micAndSystem)]}"#)
        let sources = CallSources.all(blend, devices: inputs("app.blend.mix.split", "BuiltInMicrophoneDevice"))
        #expect(CallSources.choose(sources, chosen: "BuiltInMicrophoneDevice").deviceUID == "BuiltInMicrophoneDevice")
        #expect(CallSources.choose(sources, chosen: "") == .systemDefault)
        // Unplugged since it was chosen: the split mix records rather than nothing.
        #expect(CallSources.choose(sources, chosen: "USBMic").deviceUID == "app.blend.mix.split")
    }

    @Test func listsMixesFirstLabelledByTheirSides() throws {
        let blend = try devices(#"{"version": 1, "mixes": [\#(micOnly), \#(micAndSystem), \#(mixedWithSystem)]}"#)
        let sources = CallSources.all(blend, devices: inputs("app.blend.mix.mic", "app.blend.mix.mixed",
                                                            "app.blend.mix.split", "BuiltInMicrophoneDevice",
                                                            "ZoomAudioDevice"))
        #expect(sources.map(\.label) == [
            "Blend Mic (mix)",
            "Mic and system audio (you left, call right)",
            "Everything (mix)",
            "System default (mix)",
            "MacBook Air Microphone (mix)",
            "ZoomAudioDevice (mix)",
        ])
        #expect(sources.map(\.id) == ["app.blend.mix.mic", "app.blend.mix.split", "app.blend.mix.mixed", "",
                                      "BuiltInMicrophoneDevice", "ZoomAudioDevice"])
        #expect(sources.map(\.fromBlend) == [true, true, true, false, false, false])
        // A non-split input is one channel, whichever device it is.
        #expect(sources.filter { !$0.split }.allSatisfy { $0.channels == [.mix] })

        let swapped = try devices("""
            {"mixes": [{"deviceUID": "d", "name": "Blend Call", "split": true, "sources": [
              {"channel": "left", "kind": "app", "name": "Zoom", "bundleID": "us.zoom.xos"},
              {"channel": "right", "kind": "device", "name": "Mic", "uid": "m"}]}]}
            """)
        #expect(first(swapped).label == "Blend Call (call left, you right)")
        let twoApps = try devices("""
            {"mixes": [{"deviceUID": "d", "name": "Two apps", "split": true, "sources": [
              {"channel": "left", "kind": "app", "name": "Zoom", "bundleID": "us.zoom.xos"},
              {"channel": "right", "kind": "system", "name": "System audio"}]}]}
            """)
        #expect(first(twoApps).label == "Two apps (Zoom left, System audio right)")
        // Split in Blend but with one source: nothing to tell apart, so it is one channel.
        let lone = try devices("""
            {"mixes": [{"deviceUID": "d", "name": "Lone", "split": true, "sources": [
              {"channel": "left", "kind": "device", "name": "Mic", "uid": "m"}]}]}
            """)
        #expect(first(lone).label == "Lone (mix)" && !first(lone).split)
    }

    @Test func labelsChannelsByWhatTheyCarry() throws {
        let swapped = try devices("""
            {"mixes": [{"deviceUID": "d", "name": "Swapped", "split": true, "sources": [
              {"channel": "left", "kind": "app", "name": "Zoom", "bundleID": "us.zoom.xos"},
              {"channel": "right", "kind": "device", "name": "Mic", "uid": "m"}]}]}
            """)
        #expect(first(swapped).channels == [.call, .me])
        let twoMics = try devices("""
            {"mixes": [{"deviceUID": "d", "name": "Two mics", "split": true, "sources": [
              {"channel": "left", "kind": "device", "name": "A", "uid": "a"},
              {"channel": "right", "kind": "device", "name": "B", "uid": "b"}]}]}
            """)
        #expect(first(twoMics).channels == [.me, .call])
        #expect(first(twoMics).speakers == ["A", "B"])
        #expect(first(swapped).speakers == nil)
        #expect(CallSegment.Channel.me.label == "Me" && CallSegment.Channel.call.label == "Call")
    }

    @Test func twoAppsGoByTheirNames() throws {
        let twoApps = try devices("""
            {"mixes": [{"deviceUID": "d", "name": "Two apps", "split": true, "sources": [
              {"channel": "left", "kind": "app", "name": "Zoom", "bundleID": "us.zoom.xos"},
              {"channel": "right", "kind": "system", "name": "System audio"}]}]}
            """)
        let source = first(twoApps)
        #expect(source.channels == [.me, .call])
        #expect(source.speakers == ["Zoom", "System audio"])
        #expect(try first(devices(#"{"version": 1, "mixes": [\#(micAndSystem)]}"#)).speakers == nil)

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
