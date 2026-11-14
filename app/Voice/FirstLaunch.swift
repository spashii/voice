import Foundation

/// What Dictate shows when it is opened or comes back after an update. Kept apart from the
/// windows so each rule can be tested.
enum FirstLaunch {
    /// The pane for a launch from Spotlight, Finder or the Dock while Dictate already runs.
    static func reopenPane(activated: Bool, setupComplete: Bool) -> MainPane {
        if !activated { return .welcome }
        return setupComplete ? .history : .setup
    }

    /// True once Dictate runs a newer version than the one that last launched. A first install
    /// has no earlier version and is not an update.
    static func justUpdated(last: String?, current: String) -> Bool {
        guard let last, !last.isEmpty else { return false }
        return current.compare(last, options: .numeric) == .orderedDescending
    }

    enum UpdateAnnouncement: Equatable {
        case none
        /// The person chose the update: Settings opens on About, which shows what's new.
        case about
        /// The update installed on its own: a pill that never takes focus.
        case pill(version: String)
    }

    /// `chosenVersion` is the version the person pressed Install for, remembered across the
    /// relaunch. It only counts when it is the version now running, so a choice that never
    /// finished does not turn a later silent update into a chosen one. An app that is not
    /// activated already shows Welcome, so it announces nothing.
    static func announcement(last: String?, current: String, chosenVersion: String?, activated: Bool) -> UpdateAnnouncement {
        guard activated, justUpdated(last: last, current: current) else { return .none }
        return chosenVersion == current ? .about : .pill(version: current)
    }

    /// The line on Welcome. The shortcut is named only when one is set.
    static func menuBarLine(shortcut: String?) -> String {
        let base = "Dictate lives in the menu bar, near the clock."
        guard let shortcut, !shortcut.isEmpty else { return base }
        return base + " Once it is activated, press \(shortcut) to start dictating."
    }

    static let lastLaunchedKey = "lastLaunchedVersion"
    static let chosenUpdateKey = "updateChosenVersion"
}
