import Foundation
import Observation
import Sparkle

/// Updates come through Sparkle: it reads the appcast through apps.idea2prod.in, which passes
/// the one on Voice's website through and counts the checks, checks each update against the
/// signing key in Info.plist, and asks before installing. On the second launch it asks
/// whether to check automatically. Apart from the speech model downloads, nothing else in
/// Voice goes online.
@MainActor
@Observable
final class Updates {
    /// Sparkle holds its delegate weakly, so this keeps it alive.
    @ObservationIgnored private let delegate: UpdaterDelegate
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// False while a check is already under way.
    private(set) var canCheck = false
    var automatic: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automatic }
    }

    init() {
        let delegate = UpdaterDelegate()
        self.delegate = delegate
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate,
                                                  userDriverDelegate: nil)
        automatic = controller.updater.automaticallyChecksForUpdates
        canCheck = controller.updater.canCheckForUpdates
        // Sparkle changes both on the main thread.
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated { self?.canCheck = value }
            },
            // Sparkle's own first-run question changes this behind the toggle's back.
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated {
                    if self?.automatic != value { self?.automatic = value }
                }
            },
        ]
    }

    func check() {
        controller.checkForUpdates(nil)
    }
}

/// Marks update checks from the owner's own Macs (the OwnerMac default), so the counts at
/// apps.idea2prod.in can leave them out. Sparkle adds the pair to the appcast's query; every
/// other Mac sends no parameters, and the system profile stays off.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
        UserDefaults.standard.bool(forKey: "OwnerMac") ? [["key": "self", "value": "1"]] : []
    }
}
