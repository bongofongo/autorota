import Foundation
import AutorotaKit

extension FfiError {
    /// Stable code surfaced from Rust. Used as the lookup key into the
    /// Fluent translation bundle in `autorota-core`.
    var code: ErrorCode {
        switch self {
        case .Db(let code, _):
            return code
        case .NotFound(let code, _):
            return code
        case .InvalidArgument(let code, _):
            return code
        }
    }

    /// English developer detail. Useful for logs / Sentry, not for direct
    /// user display — call `userFacingMessage(_:)` for the localized version.
    var devDetail: String {
        switch self {
        case .Db(_, let msg):
            return msg
        case .NotFound(_, let msg):
            return msg
        case .InvalidArgument(_, let msg):
            return msg
        }
    }
}

/// Extracts a localized user-facing message from any Error.
///
/// `FfiError` codes are routed through Rust's Fluent bundle so translations
/// stay co-located with the error definition. Non-FFI errors fall back to
/// `localizedDescription`.
func userFacingMessage(_ error: Error) -> String {
    if let ffi = error as? FfiError {
        return localizeError(code: ffi.code, localeId: Locale.current.identifier)
    }
    return error.localizedDescription
}
