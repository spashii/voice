import XCTest

final class SupportItemsTests: XCTestCase {
    func testMenuOrder() {
        XCTAssertEqual(SupportItem.allCases.map(\.title),
                       ["Check for Updates…", "Report an Issue…", "Send Feedback…"])
    }

    func testRepository() {
        XCTAssertEqual(SupportItem.repository.absoluteString, "https://github.com/spashii/dictate")
    }

    func testIssueBodyHoldsOnlyTheVersions() throws {
        let url = SupportItem.issueURL(appVersion: "0.11.0", macOS: "Version 26.6.2 (Build 25G100)")
        XCTAssertEqual(url.absoluteString,
                       "https://github.com/spashii/dictate/issues/new?body=App%20version:%200.11.0%0AmacOS:%20Version%2026.6.2%20(Build%2025G100)%0A%0A")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items, [URLQueryItem(name: "body",
                                            value: "App version: 0.11.0\nmacOS: Version 26.6.2 (Build 25G100)\n\n")])
    }

    /// A + would reach GitHub as a space, and an & or = would start another parameter.
    func testIssueBodyEncodesQuerySeparators() throws {
        let url = SupportItem.issueURL(appVersion: "1.0+dev&title=x", macOS: "Version 26.0")
        XCTAssertTrue(url.absoluteString.contains("1.0%2Bdev%26title%3Dx"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["body"])
        XCTAssertEqual(items.first?.value, "App version: 1.0+dev&title=x\nmacOS: Version 26.0\n\n")
    }
}

extension SupportItemsTests {
    func testVersionLine() {
        XCTAssertEqual(SupportItem.versionTitle(appVersion: "0.15.0"), "Version 0.15.0")
    }
}

extension SupportItemsTests {
    func testFeedbackURLCarriesTheIDAndVersions() {
        let url = SupportItem.feedbackURL(activationID: "Z05Z-JFFK", appVersion: "0.16.0", macOS: "26.6.2")
        XCTAssertEqual(url.absoluteString, "https://dictate.firstversion.in/feedback?id=Z05Z-JFFK&v=0.16.0&os=26.6.2")
    }

    func testFeedbackURLWithoutActivation() {
        let url = SupportItem.feedbackURL(activationID: nil, appVersion: "0.16.0", macOS: "15.5.0")
        XCTAssertEqual(url.absoluteString, "https://dictate.firstversion.in/feedback?v=0.16.0&os=15.5.0")
    }
}
