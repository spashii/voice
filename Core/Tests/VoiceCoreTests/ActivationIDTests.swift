import Testing
@testable import VoiceCore

@Suite struct ActivationIDTests {
    /// The same vectors as dictate-web test/feedback.test.mjs, so the app and the site agree.
    @Test func matchesTheSite() {
        #expect(ActivationID.make(signupID: "s1a2b3c4d5e6") == "Z05Z-JFFK")
        #expect(ActivationID.make(signupID: "s000000000000") == "KJWN-6YXK")
        #expect(ActivationID.make(signupID: "sffffffffffff") == "4Y7C-NWPB")
    }
}
