import Foundation
@_exported import ParlotteFFI

public extension Error {
    /// User-facing message for the error. For `ParlotteError` (a UniFFI-
    /// generated enum whose `localizedDescription` falls back to a reflection
    /// dump like `ParlotteFFI.ParlotteError.Unknown(message: "...")`), this
    /// unwraps the inner message. For anything else, falls through to
    /// `localizedDescription`.
    var displayMessage: String {
        if let ffi = self as? ParlotteError {
            switch ffi {
            case .Auth(let message),
                 .Network(let message),
                 .Room(let message),
                 .Store(let message),
                 .Sync(let message),
                 .Unknown(let message):
                return message
            }
        }
        return localizedDescription
    }

    /// True when the error indicates the credentials themselves are bad
    /// (expired/invalid token), as opposed to a transient network/sync
    /// failure. Callers use this to decide whether a failed session restore
    /// should discard the saved session or be retried later.
    var isAuthError: Bool {
        if let ffi = self as? ParlotteError, case .Auth = ffi {
            return true
        }
        return false
    }
}
