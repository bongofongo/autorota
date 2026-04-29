import Foundation
import Testing
import CloudKit
@testable import AutorotaApp

@Suite("AutorotaSyncEngine — CKError classification")
struct SyncFailureClassificationTests {

    private func ckError(_ code: CKError.Code, retryAfter: Double? = nil) -> CKError {
        var userInfo: [String: Any] = [:]
        if let retryAfter {
            userInfo[CKErrorRetryAfterKey] = retryAfter
        }
        let nsError = NSError(
            domain: CKErrorDomain,
            code: code.rawValue,
            userInfo: userInfo
        )
        return CKError(_nsError: nsError)
    }

    @Test func networkErrorsAreRetriable() {
        for code in [
            CKError.Code.networkUnavailable,
            .networkFailure,
            .serviceUnavailable,
            .requestRateLimited,
            .zoneBusy,
            .accountTemporarilyUnavailable,
        ] {
            let result = AutorotaSyncEngine.classify(error: ckError(code))
            switch result {
            case .retriable:
                break
            default:
                Issue.record("\(code) should be retriable, got \(result)")
            }
        }
    }

    @Test func retryAfterHintIsSurfaced() {
        let err = ckError(.requestRateLimited, retryAfter: 17.5)
        guard case .retriable(let after) = AutorotaSyncEngine.classify(error: err) else {
            Issue.record("expected retriable, got something else")
            return
        }
        #expect(after == 17.5)
    }

    @Test func quotaAndAuthAndSchemaErrorsArePermanent() {
        let permanentCases: [(CKError.Code, String)] = [
            (.quotaExceeded, "quotaExceeded"),
            (.permissionFailure, "permissionFailure"),
            (.invalidArguments, "invalidArguments"),
            (.notAuthenticated, "notAuthenticated"),
            (.userDeletedZone, "userDeletedZone"),
            (.managedAccountRestricted, "managedAccountRestricted"),
        ]
        for (code, expectedReason) in permanentCases {
            let result = AutorotaSyncEngine.classify(error: ckError(code))
            guard case .permanent(let reason) = result else {
                Issue.record("\(code) should be permanent, got \(result)")
                continue
            }
            #expect(reason == expectedReason, "expected reason \(expectedReason), got \(reason)")
        }
    }

    @Test func nonCKErrorsAreUnknown() {
        struct CustomError: Error {}
        let result = AutorotaSyncEngine.classify(error: CustomError())
        #expect(result == .unknown)
    }
}
