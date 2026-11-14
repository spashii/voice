import CryptoKit
import Foundation
import Observation

/// What is kept between launches, apart from the nonce: the signed token. Deleting the
/// Keychain item that holds it returns Dictate to a fresh install.
public struct ActivationRecord: Codable, Equatable, Sendable {
    public var token: String?

    public init(token: String? = nil) {
        self.token = token
    }
}

/// Where the record lives: the login Keychain in the app, memory in tests, since a headless
/// test run cannot answer a Keychain prompt.
public protocol ActivationStore: AnyObject {
    func load() -> ActivationRecord
    func save(_ record: ActivationRecord)
}

public final class MemoryActivationStore: ActivationStore {
    public var record: ActivationRecord

    public init(_ record: ActivationRecord = ActivationRecord()) {
        self.record = record
    }

    public func load() -> ActivationRecord { record }
    public func save(_ record: ActivationRecord) { self.record = record }
}

/// Whether this Mac may dictate and record calls, and the steps that change that.
@MainActor @Observable
public final class Activation {
    public enum State: Equatable, Sendable {
        case locked
        case activated
    }

    public enum Refusal: Error, Equatable, Sendable {
        /// Not a token this app trusts: wrong text, tampered, or signed with an unknown key.
        case invalid
        /// A genuine token, but for a request this Mac did not make.
        case otherRequest
        /// The token was good but the Keychain would not keep it.
        case notSaved
    }

    public static let nonceLifetime: TimeInterval = 24 * 3600

    private enum Key {
        static let nonce = "activationNonce"
        static let nonceDate = "activationNonceDate"
    }

    @ObservationIgnored private let store: ActivationStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let keys: [String: Curve25519.Signing.PublicKey]
    @ObservationIgnored private let makeNonce: () -> String

    public private(set) var state: State = .locked
    /// Shown in About and sent with feedback; nil until this Mac is activated.
    public private(set) var activationID: String?

    public init(store: ActivationStore, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
                keys: [String: Curve25519.Signing.PublicKey] = ActivationKeys.all,
                makeNonce: @escaping () -> String = Activation.randomNonce) {
        self.store = store
        self.defaults = defaults
        self.now = now
        self.keys = keys
        self.makeNonce = makeNonce
        refresh()
    }

    /// Dictation and call recording ask this.
    public var isActivated: Bool { state == .activated }

    /// Recomputes the state from the store, which the Keychain can change under the app.
    public func refresh() {
        if let text = store.load().token, let token = try? ActivationToken.verify(text, keys: keys) {
            state = .activated
            activationID = ActivationID.make(signupID: token.signupID)
        } else {
            state = .locked
            activationID = nil
        }
    }

    /// The nonce for the activation page. One made less than a day ago is reused, so a page
    /// left open in an older tab still works.
    @discardableResult
    public func begin() -> String {
        let nonce = pendingNonce ?? makeNonce()
        if pendingNonce == nil {
            defaults.set(nonce, forKey: Key.nonce)
            defaults.set(now(), forKey: Key.nonceDate)
        }
        refresh()
        return nonce
    }

    /// The address to open: `page`, with the nonce and version in the fragment so they
    /// never go to a server in a request.
    /// A build with its own URL scheme (the Debug one) names it as `s`, so the page returns to it.
    public func pageURL(page: URL, version: String, scheme: String? = nil) -> URL {
        let nonce = begin()
        let own = scheme.map { "&s=\($0)" } ?? ""
        return URL(string: page.absoluteString + "#n=\(nonce)&v=\(version)\(own)")!
    }

    /// A link in the app's scheme: `<scheme>://activate?t=<token>`.
    @discardableResult
    public func accept(url: URL) -> Result<Void, Refusal> {
        guard url.host == "activate",
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                  .first(where: { $0.name == "t" })?.value
        else { return .failure(.invalid) }
        return accept(text: token)
    }

    /// Nothing is stored unless the token is genuine and carries this Mac's pending nonce.
    @discardableResult
    func accept(text: String) -> Result<Void, Refusal> {
        let token: ActivationToken
        do { token = try ActivationToken.verify(text, keys: keys) } catch { return .failure(.invalid) }
        // A second press of Open Dictate on an activated Mac carries a genuine token whose nonce
        // was used already; there is nothing to store and nothing to warn about.
        if state == .activated, token.nonce != pendingNonce { return .success(()) }
        guard let nonce = pendingNonce, token.nonce == nonce else { return .failure(.otherRequest) }
        var record = store.load()
        record.token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        store.save(record)
        defaults.removeObject(forKey: Key.nonce)
        defaults.removeObject(forKey: Key.nonceDate)
        refresh()
        return state == .activated ? .success(()) : .failure(.notSaved)
    }

    private var pendingNonce: String? {
        guard let nonce = defaults.string(forKey: Key.nonce),
              let made = defaults.object(forKey: Key.nonceDate) as? Date,
              now().timeIntervalSince(made) < Self.nonceLifetime else { return nil }
        return nonce
    }

    public nonisolated static func randomNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return Base64URL.encode(Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }
}
