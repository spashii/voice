import Foundation
import Testing
@testable import VoiceCore

@MainActor
final class Clock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(hours: Double) { date.addTimeInterval(hours * 3600) }
}

func refusal(_ result: Result<Void, Activation.Refusal>) -> Activation.Refusal? {
    if case .failure(let reason) = result { reason } else { nil }
}

@MainActor
@Suite struct ActivationTests {
    let clock = Clock()
    let store = MemoryActivationStore()
    let defaults: UserDefaults

    init() {
        let name = "activation-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    func make(nonces: [String] = ["n1", "n2", "n3"]) -> Activation {
        var remaining = nonces
        return Activation(store: store, defaults: defaults, now: { [clock] in clock.date }, keys: TokenSupport.keys,
                          makeNonce: { remaining.removeFirst() })
    }

    @Test func startsLockedAndRefusesRecording() {
        let activation = make()
        #expect(activation.state == .locked)
        #expect(!activation.isActivated)
    }

    @Test func beginMakesAPendingNonce() {
        let activation = make()
        #expect(activation.begin() == "n1")
        #expect(!activation.isActivated)
    }

    @Test func beginReusesTheNonceForADay() {
        let activation = make()
        _ = activation.begin()
        clock.advance(hours: 23)
        #expect(activation.begin() == "n1")
        clock.advance(hours: 2)
        #expect(activation.begin() == "n2")
    }

    @Test func aTokenForThePendingNonceActivates() throws {
        let activation = make()
        _ = activation.begin()
        try activation.accept(text: TokenSupport.token(nonce: "n1")).get()
        #expect(activation.state == .activated)
        #expect(activation.isActivated)
        #expect(store.record.token != nil)
    }

    @Test func theActivationIDAppearsOnlyOnceActivated() throws {
        let activation = make()
        #expect(activation.activationID == nil)
        _ = activation.begin()
        try activation.accept(text: TokenSupport.token(sid: "s1a2b3c4d5e6", nonce: "n1")).get()
        #expect(activation.activationID == "Z05Z-JFFK")
    }

    @Test func aLinkActivatesToo() throws {
        let activation = make()
        _ = activation.begin()
        let url = URL(string: "in.firstversion.dictate://activate?t=\(TokenSupport.token(nonce: "n1"))")!
        try activation.accept(url: url).get()
        #expect(activation.state == .activated)
    }

    @Test func aTokenForAnotherNonceStoresNothing() {
        let activation = make()
        _ = activation.begin()
        #expect(refusal(activation.accept(text: TokenSupport.token(nonce: "other"))) == .otherRequest)
        #expect(store.record.token == nil)
        #expect(!activation.isActivated)
    }

    @Test func theSameLinkOpenedAgainOnAnActivatedMacIsAcceptedQuietly() throws {
        let activation = make()
        _ = activation.begin()
        let token = TokenSupport.token(nonce: "n1")
        try activation.accept(text: token).get()
        let saved = store.record.token
        try activation.accept(text: token).get()
        #expect(activation.isActivated)
        #expect(store.record.token == saved)
        // A forged token is still refused.
        var forged = token
        forged.removeLast(3)
        #expect(refusal(activation.accept(text: forged)) == .invalid)
    }

    @Test func aTokenWithNoRequestPendingIsRefused() {
        let activation = make()
        #expect(refusal(activation.accept(text: TokenSupport.token(nonce: "n1"))) == .otherRequest)
        #expect(store.record.token == nil)
    }

    @Test func aTokenAfterTheNonceExpiredIsRefused() {
        let activation = make()
        _ = activation.begin()
        clock.advance(hours: 25)
        #expect(refusal(activation.accept(text: TokenSupport.token(nonce: "n1"))) == .otherRequest)
    }

    @Test func aForgedTokenIsInvalid() {
        let activation = make()
        _ = activation.begin()
        var text = TokenSupport.token(nonce: "n1")
        text.removeLast(4)
        #expect(refusal(activation.accept(text: text)) == .invalid)
        #expect(refusal(activation.accept(text: "hello")) == .invalid)
        #expect(refusal(activation.accept(url: URL(string: "in.firstversion.dictate://elsewhere?t=x")!)) == .invalid)
        #expect(store.record.token == nil)
    }

    @Test func anActivatedStateSurvivesARelaunch() throws {
        let first = make()
        _ = first.begin()
        try first.accept(text: TokenSupport.token(nonce: "n1")).get()
        #expect(make().state == .activated)
    }

    @Test func aStoredTokenOfARemovedKeyDoesNotUnlock() {
        store.record.token = TokenSupport.token(kid: "k0")
        #expect(make().state == .locked)
    }

    @Test func deletingTheRecordLocksAgain() throws {
        let activation = make()
        _ = activation.begin()
        try activation.accept(text: TokenSupport.token(nonce: "n1")).get()
        store.save(ActivationRecord())
        activation.refresh()
        #expect(activation.state == .locked)
    }

    @Test func pageURLCarriesNonceAndVersionInTheFragment() {
        let activation = make()
        let url = activation.pageURL(page: URL(string: "https://spashii.github.io/dictate/activate/")!, version: "0.13.0")
        #expect(url.absoluteString == "https://spashii.github.io/dictate/activate/#n=n1&v=0.13.0")
        #expect(url.query == nil)
    }

    @Test func pageURLNamesAnOwnScheme() {
        let url = make().pageURL(page: URL(string: "http://localhost:8787/activate")!, version: "0.13.0",
                                 scheme: "in.firstversion.dictate.dev")
        #expect(url.absoluteString == "http://localhost:8787/activate#n=n1&v=0.13.0&s=in.firstversion.dictate.dev")
    }

    @Test func aRandomNonceIsLongAndDifferentEachTime() {
        let a = Activation.randomNonce(), b = Activation.randomNonce()
        #expect(a != b)
        #expect(Base64URL.decode(a)?.count == 16)
    }
}
