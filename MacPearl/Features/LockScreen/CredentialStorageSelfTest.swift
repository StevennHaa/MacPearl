import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Invoked explicitly by release tooling before SwiftUI/session construction.
/// Uses only a disposable, randomly named record and synthetic password.
nonisolated enum CredentialStorageSelfTest {
    static func run(interactive: Bool) -> Int32 {
        let vault = LegacyEnclaveRecordStore(service: "com.stevenha.MacPearl.credential-self-test." + UUID().uuidString)
        do {
            guard Bundle.main.object(forInfoDictionaryKey: "MacPearlCredentialStorage") as? String
                    == CredentialStoreSelection.freeStorage else {
                throw Failure(message: "Free credential backend was not selected in the packaged app")
            }
            guard SecureEnclave.isAvailable else { throw ProtectedCredentialError.secureEnclaveUnavailable }
            // Check real file-based Keychain CRUD from this exact signed process.
            let marker = Data(UUID().uuidString.utf8)
            try vault.write(marker)
            guard try vault.read() == marker else { throw Failure(message: "Keychain create/read mismatch") }
            let replacement = Data(UUID().uuidString.utf8)
            try vault.write(replacement)
            guard try vault.read() == replacement else { throw Failure(message: "Keychain update mismatch") }
            try vault.delete()
            guard try vault.read() == nil else { throw Failure(message: "Keychain deletion failed") }
            print("PASS: packaged-app file-based Keychain create/read/update/delete")

            let context = LAContext()
            context.interactionNotAllowed = true
            do {
                _ = try SecureEnclaveKeyProtector().create(context: context)
                throw Failure(message: "Protected Enclave operation unexpectedly bypassed user presence")
            } catch {
                let failure = error as NSError
                guard (failure.domain == LAError.errorDomain && failure.code == LAError.notInteractive.rawValue)
                    || (failure.domain == NSOSStatusErrorDomain && failure.code == Int(errSecInteractionNotAllowed)) else {
                    throw error
                }
            }
            context.invalidate()
            print("PASS: protected Enclave operation refuses noninteractive access")
            if interactive {
                let store = EnclaveProtectedCredentialStore(records: vault)
                let password = "synthetic-credential-" + UUID().uuidString
                let saved = try store.save(password: password)
                guard try store.credentialHealth() == .complete else { throw Failure(message: "Saved record incomplete") }
                guard let raw = try vault.read(), raw.range(of: Data(password.utf8)) == nil else {
                    throw Failure(message: "Credential was not encrypted")
                }
                let restored = try store.loadAuthorizedMaterial()
                let envelope = try JSONDecoder().decode(ProtectedCredentialEnvelope.self, from: restored.envelopeData)
                guard saved.keyData == restored.keyData,
                      try ProtectedCredentialCodec().open(envelope, using: restored.keyData) == password else {
                    throw Failure(message: "Authorized encrypted credential round-trip failed")
                }
                try store.delete()
                guard try store.credentialHealth() == .absent else { throw Failure(message: "Credential deletion failed") }
                print("PASS: user-authorized save, fresh authorization, decryption and deletion of synthetic credential")
            }
            print(interactive ? "PASS: interactive credential self-test" : "PASS: noninteractive credential self-test; interactive authorization still requires user verification")
            return 0
        } catch {
            print("FAIL: credential self-test: \(error.localizedDescription)")
            do { try vault.delete() }
            catch { print("FAIL: disposable record cleanup: \(error.localizedDescription)") }
            return 1
        }
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
