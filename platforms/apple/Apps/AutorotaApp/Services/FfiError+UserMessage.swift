import Foundation
import AutorotaKit

extension FfiError {
    /// A user-facing message extracted from the FFI error, without the Swift enum wrapper.
    var userMessage: String {
        switch self {
        case .Db(let msg):
            return msg
        case .NotFound(let msg):
            return msg
        case .InvalidArgument(let msg):
            return msg
        }
    }
}

/// Extracts a clean, user-facing message from any Error.
/// For `FfiError`, strips the enum wrapper. For others, uses `localizedDescription`.
func userFacingMessage(_ error: Error) -> String {
    if let ffi = error as? FfiError {
        return ffi.userMessage
    }
    return error.localizedDescription
}
