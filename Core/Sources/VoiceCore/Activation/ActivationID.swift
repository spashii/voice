import CryptoKit
import Foundation

/// The short ID About shows and Send Feedback puts in the page's address: the first 40 bits of
/// SHA-256("dictate-activation-id:" + signup id) in Crockford base32, as XXXX-XXXX. It is one way,
/// so it never gives away the signup id or the token, and it unlocks nothing. The site computes
/// the same value (dictate-web src/activation-id.js) to match feedback to a signup, so the recipe
/// cannot change without both sides moving; the tests on both sides share the same vectors.
public enum ActivationID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func make(signupID: String) -> String {
        let digest = Array(SHA256.hash(data: Data("dictate-activation-id:\(signupID)".utf8)))
        let bits = digest.prefix(5).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let chars = (0..<8).map { alphabet[Int((bits >> UInt64(35 - 5 * $0)) & 31)] }
        return String(chars.prefix(4)) + "-" + String(chars.suffix(4))
    }
}
