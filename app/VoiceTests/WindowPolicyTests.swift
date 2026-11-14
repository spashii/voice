import AppKit
import XCTest

final class WindowPolicyTests: XCTestCase {
    private func window(panel: Bool = false, titled: Bool = true, visible: Bool = true,
                        minimized: Bool = false) -> WindowPolicy.Info {
        .init(isPanel: panel, isTitled: titled, isVisible: visible, isMiniaturized: minimized)
    }

    func testNoWindowMeansMenuBarOnly() {
        XCTAssertEqual(WindowPolicy.policy(openWindows: 0), .accessory)
    }

    /// Until activation the Dock icon stays, so a closed Welcome can be brought back from it.
    func testBeforeActivationTheDockIconStaysWithoutWindows() {
        XCTAssertEqual(WindowPolicy.policy(openWindows: 0, activated: false), .regular)
        XCTAssertEqual(WindowPolicy.policy(openWindows: 0, activated: true), .accessory)
        XCTAssertEqual(WindowPolicy.policy(openWindows: 1, activated: true), .regular)
    }

    func testAnyWindowMeansDockIcon() {
        XCTAssertEqual(WindowPolicy.policy(openWindows: 1), .regular)
        XCTAssertEqual(WindowPolicy.policy(openWindows: 3), .regular)
    }

    func testAVisibleTitledWindowCounts() {
        XCTAssertTrue(WindowPolicy.counts(window()))
    }

    /// The pills and the call prompt float over other apps and must not pull Dictate forward.
    func testPanelsDoNotCount() {
        XCTAssertFalse(WindowPolicy.counts(window(panel: true)))
        XCTAssertFalse(WindowPolicy.counts(window(panel: true, titled: false)))
    }

    /// The menu bar's own window and anything else without a title bar.
    func testUntitledWindowsDoNotCount() {
        XCTAssertFalse(WindowPolicy.counts(window(titled: false)))
    }

    func testHiddenWindowDoesNotCountButMinimizedOneDoes() {
        XCTAssertFalse(WindowPolicy.counts(window(visible: false)))
        XCTAssertTrue(WindowPolicy.counts(window(visible: false, minimized: true)))
    }

    func testSparkleAndAlertWindowsDoNotCount() {
        for name in ["SUUpdateAlert", "SPUStandardUpdaterWindow", "NSAlertPanel", "_NSAlertWindow"] {
            var info = window()
            info.className = name
            XCTAssertFalse(WindowPolicy.counts(info), name)
        }
        var ours = window()
        ours.className = "SwiftUI.AppKitWindow"
        XCTAssertTrue(WindowPolicy.counts(ours))
    }
}
