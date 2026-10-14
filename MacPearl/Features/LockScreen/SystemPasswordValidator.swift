import Foundation
import OpenDirectory

nonisolated protocol SystemPasswordValidating: Sendable {
    func validate(_ password: String) throws
}

nonisolated struct SystemPasswordValidator: SystemPasswordValidating {
    func validate(_ password: String) throws {
        guard !password.isEmpty else { throw ProtectedCredentialError.passwordVerificationFailed }
        do {
            let node = try ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
        } catch {
            // Do not expose directory errors or include credentials in logs.
            throw ProtectedCredentialError.passwordVerificationFailed
        }
    }
}
