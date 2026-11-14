import Foundation

/// The items between Settings… and Quit in the menu bar menu, in the order it shows them.
/// The menu draws this list, so VoiceTests checks the menu's order by reading it.
enum SupportItem: CaseIterable {
    case checkForUpdates
    case reportIssue
    case sendFeedback

    var title: String {
        switch self {
        case .checkForUpdates: "Check for Updates…"
        case .reportIssue: "Report an Issue…"
        case .sendFeedback: "Send Feedback…"
        }
    }

    /// The disabled line under Check for Updates….
    static func versionTitle(appVersion: String) -> String { "Version \(appVersion)" }

    /// CFBundleShortVersionString of this copy of Dictate.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    static let repository = URL(string: "https://github.com/spashii/dictate")!

    /// A new issue whose body holds the two versions and nothing else from this Mac: no logs,
    /// no dictations, no settings.
    static func issueURL(appVersion: String, macOS: String) -> URL {
        let body = "App version: \(appVersion)\nmacOS: \(macOS)\n\n"
        var components = URLComponents(url: repository.appending(path: "issues/new"),
                                       resolvingAgainstBaseURL: false)!
        // Encoded here because URLQueryItem leaves a + as it is, and GitHub reads it as a space.
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "body", value: body.addingPercentEncoding(withAllowedCharacters: queryValue)),
        ]
        return components.url!
    }

    /// The issue link for this copy of Dictate on this Mac.
    static var issueURL: URL {
        issueURL(appVersion: appVersion,
                 macOS: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    static let feedbackPage = URL(string: "https://dictate.firstversion.in/feedback")!

    /// The feedback page with this activation's ID and the two versions, which the page shows
    /// above its Send button. Without an ID the page asks for an email instead. The site reads
    /// these names (id, v, os), so they stay as they are once released.
    static func feedbackURL(activationID: String?, appVersion: String, macOS: String) -> URL {
        var components = URLComponents(url: feedbackPage, resolvingAgainstBaseURL: false)!
        components.queryItems = (activationID.map { [URLQueryItem(name: "id", value: $0)] } ?? [])
            + [URLQueryItem(name: "v", value: appVersion), URLQueryItem(name: "os", value: macOS)]
        return components.url!
    }

    /// The feedback link for this copy of Dictate on this Mac.
    static func feedbackURL(activationID: String?) -> URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return feedbackURL(activationID: activationID, appVersion: appVersion,
                           macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }

    private static let queryValue = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))
}
