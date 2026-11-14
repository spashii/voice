import XCTest

final class FirstLaunchTests: XCTestCase {
    func testReopenBeforeActivationShowsWelcome() {
        XCTAssertEqual(FirstLaunch.reopenPane(activated: false, setupComplete: false), .welcome)
        XCTAssertEqual(FirstLaunch.reopenPane(activated: false, setupComplete: true), .welcome)
    }

    func testReopenWithSetupUnfinishedShowsSetup() {
        XCTAssertEqual(FirstLaunch.reopenPane(activated: true, setupComplete: false), .setup)
    }

    func testReopenOtherwiseShowsHistory() {
        XCTAssertEqual(FirstLaunch.reopenPane(activated: true, setupComplete: true), .history)
    }

    func testFirstInstallIsNotAnUpdate() {
        XCTAssertFalse(FirstLaunch.justUpdated(last: nil, current: "0.15.3"))
        XCTAssertFalse(FirstLaunch.justUpdated(last: "", current: "0.15.3"))
    }

    func testSameVersionIsNotAnUpdate() {
        XCTAssertFalse(FirstLaunch.justUpdated(last: "0.15.3", current: "0.15.3"))
    }

    func testNewerVersionIsAnUpdateAndComparesNumerically() {
        XCTAssertTrue(FirstLaunch.justUpdated(last: "0.15.2", current: "0.15.3"))
        XCTAssertTrue(FirstLaunch.justUpdated(last: "0.9.0", current: "0.10.0"))
    }

    func testOlderVersionIsNotAnUpdate() {
        XCTAssertFalse(FirstLaunch.justUpdated(last: "0.15.3", current: "0.15.2"))
    }

    func testChosenUpdateOpensAbout() {
        XCTAssertEqual(FirstLaunch.announcement(last: "0.15.2", current: "0.15.3", chosenVersion: "0.15.3", activated: true), .about)
    }

    func testSilentUpdateShowsThePill() {
        XCTAssertEqual(FirstLaunch.announcement(last: "0.15.2", current: "0.15.3", chosenVersion: nil, activated: true), .pill(version: "0.15.3"))
    }

    func testAStaleChoiceForAnotherVersionDoesNotCount() {
        XCTAssertEqual(FirstLaunch.announcement(last: "0.15.2", current: "0.15.4", chosenVersion: "0.15.3", activated: true), .pill(version: "0.15.4"))
    }

    func testNothingIsAnnouncedWithoutAnUpdateOrBeforeActivation() {
        XCTAssertEqual(FirstLaunch.announcement(last: "0.15.3", current: "0.15.3", chosenVersion: nil, activated: true), .none)
        XCTAssertEqual(FirstLaunch.announcement(last: "0.15.2", current: "0.15.3", chosenVersion: nil, activated: false), .none)
    }

    func testMenuBarLineNamesTheShortcutOnlyWhenSet() {
        XCTAssertEqual(FirstLaunch.menuBarLine(shortcut: nil), "Dictate lives in the menu bar, near the clock.")
        XCTAssertTrue(FirstLaunch.menuBarLine(shortcut: "\u{2325}`").contains("press \u{2325}` to start dictating"))
        XCTAssertFalse(FirstLaunch.menuBarLine(shortcut: nil).contains("press"))
    }
}
