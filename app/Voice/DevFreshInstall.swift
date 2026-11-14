#if DEBUG
import CryptoKit
import Foundation
import VoiceCore

/// A development build can start as a Mac that was never activated, or as one that is, without
/// reading or writing the Keychain item of an installed Dictate:
/// `-DictateFreshInstall YES` or `-DictateFreshInstall activated`. The record lives in memory
/// and, for the activated case, is signed with a key made for this launch.
@MainActor
enum DevFreshInstall {
    static func activation() -> Activation? {
        guard BuildFlavor.isDev, let mode = UserDefaults.standard.string(forKey: "DictateFreshInstall") else { return nil }
        guard mode.lowercased() == "activated" else {
            return Activation(store: MemoryActivationStore())
        }
        let key = Curve25519.Signing.PrivateKey()
        let payload = encode(Data(#"{"kid":"dev","sid":"devfreshinst","n":"n0nce","iat":1794000000}"#.utf8))
        let signature = encode((try? key.signature(for: Data("dct1.\(payload)".utf8))) ?? Data())
        let record = ActivationRecord(token: "dct1.\(payload).\(signature)")
        return Activation(store: MemoryActivationStore(record), keys: ["dev": key.publicKey])
    }

    private static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
#endif
