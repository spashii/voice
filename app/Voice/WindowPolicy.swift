import AppKit

/// Dictate lives in the menu bar and has no Dock icon, until it opens a window: then it is an
/// ordinary app, so the window comes forward and can be found in the Dock and the app
/// switcher. When the last window closes it goes back to the menu bar, except before
/// activation: until then the Dock icon stays, so a closed Welcome can be brought back.
enum WindowPolicy {
    /// What decides whether a window counts, read off the NSWindow so the rule can be tested.
    struct Info {
        var isPanel: Bool
        var isTitled: Bool
        var isVisible: Bool
        var isMiniaturized: Bool
        /// The window's class name, to tell Sparkle's windows apart.
        var className: String = ""
    }

    /// A window the person works in. Panels are excluded: the live pills and the call prompt
    /// float over other apps and must not take focus, and open and save panels belong to a
    /// window that already counts. A minimized window still counts, since the Dock holds it.
    ///
    /// Sparkle's update windows are the updater's own and come and go as it works, and alerts
    /// are answered and gone; neither should turn Dictate into a Dock app or pull it forward.
    static func counts(_ window: Info) -> Bool {
        !window.isPanel && window.isTitled && (window.isVisible || window.isMiniaturized) && !isTransient(window.className)
    }

    static func isTransient(_ className: String) -> Bool {
        className.hasPrefix("SU") || className.hasPrefix("SPU") || className.contains("Alert")
    }

    static func policy(openWindows: Int, activated: Bool = true) -> NSApplication.ActivationPolicy {
        openWindows > 0 || !activated ? .regular : .accessory
    }
}

/// Applies WindowPolicy as windows open and close.
@MainActor
final class WindowActivation {
    private var observers: [NSObjectProtocol] = []
    /// Read each time the policy is decided; false keeps the Dock icon.
    var isActivated: () -> Bool = { true }

    func start() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                // Delivered on the main queue, so the window is only ever touched there.
                nonisolated(unsafe) let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    if let window, Self.counts(window) { Self.bringForward() }
                }
            })
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                nonisolated(unsafe) let closing = note.object as? NSWindow
                MainActor.assumeIsolated { self?.settle(closing: closing) }
            })
        }
    }

    /// Opens the Dock icon and brings the app forward. The policy has to be regular before
    /// the activation, or an accessory app is left behind the app that was in front.
    ///
    /// Since macOS 14 an app comes forward only when the active app yields or the system hands
    /// it the activation, which it does for a launch the person asked for. The request is made
    /// again on the next turns of the run loop, because the first can land before the policy
    /// change has taken effect and leave the window behind the app that was in front.
    static func bringForward() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
        for delay in [0.05, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !NSApp.isActive else { return }
                NSApp.activate()
                NSRunningApplication.current.activate(options: [.activateAllWindows])
            }
        }
    }

    /// Back to the menu bar once no window is left. A window that is closing still reads as
    /// visible while its notification runs, so it is left out of the count.
    func settle(closing: NSWindow?) {
        let open = NSApp.windows.filter { $0 !== closing && Self.counts($0) }.count
        let policy = WindowPolicy.policy(openWindows: open, activated: isActivated())
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    private static func counts(_ window: NSWindow) -> Bool {
        WindowPolicy.counts(.init(isPanel: window is NSPanel, isTitled: window.styleMask.contains(.titled),
                                  isVisible: window.isVisible, isMiniaturized: window.isMiniaturized,
                                  className: NSStringFromClass(type(of: window))))
    }
}
