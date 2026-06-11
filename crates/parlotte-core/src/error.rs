use thiserror::Error;

/// Errors that can occur in parlotte-core operations.
#[derive(Debug, Error)]
pub enum ParlotteError {
    #[error("authentication failed: {message}")]
    Auth { message: String },

    #[error("network error: {message}")]
    Network { message: String },

    #[error("room error: {message}")]
    Room { message: String },

    #[error("store error: {message}")]
    Store { message: String },

    #[error("sync error: {message}")]
    Sync { message: String },

    #[error("unknown error: {message}")]
    Unknown { message: String },
}

// NOTE: there are deliberately no `From<matrix_sdk::Error>` impls. Every call
// site maps SDK errors explicitly with `.map_err(...)` to attach a contextual
// message, so a blanket `?` conversion would only hide where an error came
// from. Earlier blanket impls existed but were never used (no `?` relied on
// them) and went untested — removed rather than left as dead code.

pub type Result<T> = std::result::Result<T, ParlotteError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_display_messages() {
        let err = ParlotteError::Auth {
            message: "bad password".into(),
        };
        assert_eq!(err.to_string(), "authentication failed: bad password");

        let err = ParlotteError::Network {
            message: "timeout".into(),
        };
        assert_eq!(err.to_string(), "network error: timeout");

        let err = ParlotteError::Room {
            message: "not found".into(),
        };
        assert_eq!(err.to_string(), "room error: not found");

        let err = ParlotteError::Store {
            message: "corrupt".into(),
        };
        assert_eq!(err.to_string(), "store error: corrupt");

        let err = ParlotteError::Sync {
            message: "failed".into(),
        };
        assert_eq!(err.to_string(), "sync error: failed");

        let err = ParlotteError::Unknown {
            message: "wat".into(),
        };
        assert_eq!(err.to_string(), "unknown error: wat");
    }

    #[test]
    fn error_variants_are_debug() {
        let err = ParlotteError::Auth {
            message: "test".into(),
        };
        let debug = format!("{:?}", err);
        assert!(debug.contains("Auth"));
        assert!(debug.contains("test"));
    }

    #[test]
    #[allow(clippy::unnecessary_literal_unwrap)]
    fn result_type_alias_works() {
        let ok: Result<i32> = Ok(42);
        assert_eq!(ok.unwrap(), 42);

        let err: Result<i32> = Err(ParlotteError::Unknown {
            message: "oops".into(),
        });
        assert!(err.is_err());
    }
}
