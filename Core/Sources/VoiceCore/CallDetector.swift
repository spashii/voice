import AppKit
import CoreAudio
import Foundation

/// An app that looks like it is in a call.
public struct DetectedCall: Sendable, Hashable {
    public var bundleID: String
    public var name: String
}

/// Watches which apps use the microphone, through Core Audio's process objects, and reports
/// the ones in a call: a call app using the input for 5 s, or a browser using both input
/// and output for 10 s (a meeting in a tab; a browser only listening is more often
/// dictation or a voice search). CallTracker decides when a call ends.
///
/// Every query runs on the detector's own queue. A wedged coreaudiod blocks whoever asks
/// it, and on the main thread that freezes the menu bar.
public final class CallDetector: @unchecked Sendable {
    public enum Kind: Sendable { case communication, browser }

    /// One app's use of audio right now, every process it owns taken together.
    public struct Usage: Sendable, Hashable {
        public var bundleID: String
        public var name: String
        public var kind: Kind
        public var input: Bool
        public var output: Bool
    }

    private let queue = DispatchQueue(label: "voice.call-detector", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var tracker = CallTracker()
    private var browsers = CallApps.browsers
    private let onChange: @Sendable ([DetectedCall]) -> Void
    private let onTick: (@Sendable ([Usage]) -> Void)?

    /// `onChange` gets every app in a call each time that set changes, on the detector's
    /// queue. `onTick` sees each poll's raw usage, for voice-cli watch-calls.
    public init(onChange: @escaping @Sendable ([DetectedCall]) -> Void,
                onTick: (@Sendable ([Usage]) -> Void)? = nil) {
        self.onChange = onChange
        self.onTick = onTick
    }

    public func start(every interval: Duration = .seconds(1)) {
        queue.async {
            guard self.timer == nil else { return }
            // Whatever opens web links counts as a browser too, so an unlisted one still does.
            if let page = URL(string: "https://example.com"),
               let handler = NSWorkspace.shared.urlForApplication(toOpen: page),
               let id = Bundle(url: handler)?.bundleIdentifier {
                self.browsers.insert(id)
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: interval.seconds, leeway: .milliseconds(200))
            timer.setEventHandler { self.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func poll() {
        let usage = CallApps.usage(browsers: browsers)
        onTick?(usage)
        if let calls = tracker.update(usage, at: Date()) { onChange(calls) }
    }
}

/// Turns each poll's usage into the apps in a call. A call starts when a call app uses the
/// input for 5 s, or a browser input and output for 10 s, and ends only once the app has
/// used neither for `grace`: muted, a call app may close its input, and switching devices
/// closes both for a moment, and neither should split one call into two recordings.
struct CallTracker {
    static let grace: TimeInterval = 15

    private var since: [String: Date] = [:]
    private var lastSeen: [String: Date] = [:]
    private var reported: Set<DetectedCall> = []

    /// The apps in a call, sorted by name, when that set changed; nil when it didn't.
    mutating func update(_ usage: [CallDetector.Usage], at now: Date) -> [DetectedCall]? {
        var calls: Set<DetectedCall> = []
        for app in usage {
            let starts = app.kind == .communication ? app.input : app.input && app.output
            let goesOn = since[app.bundleID] != nil && (app.input || app.output)
            guard starts || goesOn else { continue }
            lastSeen[app.bundleID] = now
            let start = since[app.bundleID] ?? now
            since[app.bundleID] = start
            let needed: TimeInterval = app.kind == .communication ? 5 : 10
            if now.timeIntervalSince(start) >= needed { calls.insert(DetectedCall(bundleID: app.bundleID, name: app.name)) }
        }
        for (id, seen) in lastSeen where now.timeIntervalSince(seen) > Self.grace {
            lastSeen[id] = nil
            since[id] = nil
        }
        for call in reported where since[call.bundleID] != nil { calls.insert(call) }
        guard calls != reported else { return nil }
        reported = calls
        return calls.sorted { $0.name < $1.name }
    }
}

/// Which apps count as call apps and browsers, as in Blend's AudioCatalog, and what Core
/// Audio says each process is doing.
public enum CallApps {
    public static let communication: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.FaceTime",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "org.whispersystems.signal-desktop",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark", "com.skype.skype", "im.riot.app",
    ]

    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
        "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "org.chromium.Chromium", "com.kagi.kagimacOS",
        "app.zen-browser.zen", "com.duckduckgo.macos.browser", "org.torproject.torbrowser",
    ]

    /// Listening is their job, not a call: Voice and voice-cli, Blend reading its sources,
    /// another dictation app, Siri and macOS dictation.
    public static let excluded: Set<String> = [
        "io.github.spashii.voice", "app.blend.Blend", "ru.starmel.OpenSuperWhisper",
        "com.apple.siri", "com.apple.Siri", "com.apple.assistantd", "com.apple.assistant_service",
        "com.apple.DictationIM", "com.apple.SpeechRecognitionCore", "com.apple.corespeechd",
        "com.apple.dictationd",
    ]

    /// The id itself or one of its helpers ("com.google.Chrome.helper").
    static func member(_ id: String, of set: Set<String>) -> String? {
        if set.contains(id) { return id }
        return set.first { id.hasPrefix($0 + ".") }
    }

    public static func kind(_ id: String, browsers: Set<String> = browsers) -> (id: String, kind: CallDetector.Kind)? {
        if member(id, of: excluded) != nil { return nil }
        if let app = member(id, of: communication) { return (app, .communication) }
        if let app = member(id, of: browsers) { return (app, .browser) }
        return nil
    }

    /// Call apps and browsers using audio right now. A browser or call app records through
    /// helper processes, so each process is credited to the app responsible for it.
    static func usage(browsers: Set<String>) -> [CallDetector.Usage] {
        var apps: [String: CallDetector.Usage] = [:]
        for process in processes() {
            let owner = process.pid > 0 ? NSRunningApplication(processIdentifier: responsible(process.pid)) : nil
            // Excluded if either the process or the app behind it is.
            if member(process.bundleID, of: excluded) != nil
                || owner?.bundleIdentifier.flatMap({ member($0, of: excluded) }) != nil { continue }
            let byOwner = owner?.bundleIdentifier.flatMap { kind($0, browsers: browsers) }
            guard let match = byOwner ?? kind(process.bundleID, browsers: browsers) else { continue }
            let id = match.id
            let name = byOwner != nil ? owner?.localizedName ?? id : displayName(id)
            var usage = apps[id]
                ?? CallDetector.Usage(bundleID: id, name: name, kind: match.kind, input: false, output: false)
            usage.input = usage.input || process.input
            usage.output = usage.output || process.output
            apps[id] = usage
        }
        return apps.values.sorted { $0.name < $1.name }
    }

    /// Blend's driver lists the processes reading a mix, as [{pid, bundleID}], under this
    /// property of the mix's device ('BLus').
    static let mixClientsProperty: AudioObjectPropertySelector = 0x424C_7573

    /// The bundle IDs of the processes reading this device and of the apps responsible for
    /// them, Voice left out. Empty for a device that isn't a Blend mix.
    public static func readers(ofDeviceUID uid: String) -> Set<String> {
        guard let device = InputDevices.id(forUID: uid) else { return [] }
        var address = address(mixClientsProperty)
        guard AudioObjectHasProperty(device, &address) else { return [] }
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let clients = value?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var ids: Set<String> = []
        for client in clients {
            let pid = (client["pid"] as? NSNumber)?.int32Value ?? 0
            if pid == getpid() { continue }
            if let id = client["bundleID"] as? String, !id.isEmpty { ids.insert(id) }
            if pid > 0, let owner = NSRunningApplication(processIdentifier: responsible(pid))?.bundleIdentifier {
                ids.insert(owner)
            }
        }
        return ids
    }

    /// Whether the app, or one of its helpers, is among a mix's readers.
    public static func reads(_ app: DetectedCall, readers: Set<String>) -> Bool {
        readers.contains { $0 == app.bundleID || $0.hasPrefix(app.bundleID + ".") }
    }

    /// Every process using audio now, as Core Audio reports it.
    public static func processes() -> [(bundleID: String, pid: pid_t, input: Bool, output: Bool)] {
        objects().compactMap { object in
            let input = flag(object, kAudioProcessPropertyIsRunningInput)
            let output = flag(object, kAudioProcessPropertyIsRunningOutput)
            guard input || output else { return nil }
            var pid: pid_t = -1
            var size = UInt32(MemoryLayout<pid_t>.size)
            var address = address(kAudioProcessPropertyPID)
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid)
            return (string(object, kAudioProcessPropertyBundleID) ?? "", pid, input, output)
        }
    }

    private static func displayName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// The process macOS holds responsible for this one: the app behind a helper.
    private static func responsible(_ pid: pid_t) -> pid_t {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return pid }
        let owner = unsafeBitCast(symbol, to: Responsible.self)(pid)
        return owner > 0 ? owner : pid
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func objects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
