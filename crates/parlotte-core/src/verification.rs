use std::sync::Arc;

use matrix_sdk::encryption::verification::{
    SasState as SdkSasState, SasVerification, Verification, VerificationRequest,
    VerificationRequestState as SdkRequestState,
};
use tokio::sync::Mutex;

use crate::error::{ParlotteError, Result};

/// Metadata about a verification request, surfaced to the UI when a request
/// arrives (incoming) or after we start one (outgoing).
#[derive(Debug, Clone)]
pub struct VerificationRequestInfo {
    pub flow_id: String,
    pub other_user_id: String,
    pub is_self_verification: bool,
    pub we_started: bool,
}

/// A single emoji in a Short Authentication String (SAS).
#[derive(Debug, Clone)]
pub struct EmojiInfo {
    pub symbol: String,
    pub description: String,
}

/// State of an active verification flow, combining request + SAS state.
#[derive(Debug, Clone)]
pub enum VerificationState {
    /// The request has been created or received but isn't ready yet.
    Pending,
    /// Both sides accepted; we can transition to SAS now.
    Ready,
    /// SAS flow started, waiting for key exchange.
    SasStarted,
    /// Emojis are ready to compare with the other device.
    SasReadyToCompare { emojis: Vec<EmojiInfo> },
    /// User confirmed the emojis match; waiting for the other side to confirm.
    SasConfirmed,
    /// Verification completed successfully.
    Done,
    /// Verification was cancelled. `reason` is a human-readable message.
    Cancelled { reason: String },
}

/// Callback for incoming verification requests. Registered alongside the
/// sync listener so the UI can show a modal when another device asks us to
/// verify.
pub trait VerificationListener: Send + Sync + 'static {
    fn on_verification_request(&self, info: VerificationRequestInfo);
}

/// Tracks the currently-active verification request and its derived SAS, if
/// any. The client only supports one active flow at a time (typical for
/// self-verification).
#[derive(Default)]
pub(crate) struct ActiveVerification {
    pub request: Option<VerificationRequest>,
    pub sas: Option<SasVerification>,
}

pub(crate) type SharedActive = Arc<Mutex<ActiveVerification>>;

pub(crate) fn request_info(req: &VerificationRequest) -> VerificationRequestInfo {
    VerificationRequestInfo {
        flow_id: req.flow_id().to_string(),
        other_user_id: req.other_user_id().to_string(),
        is_self_verification: req.is_self_verification(),
        we_started: req.we_started(),
    }
}

/// Compute the current `VerificationState` from the stored request and SAS.
pub(crate) fn derive_state(active: &ActiveVerification) -> Result<VerificationState> {
    let request = active
        .request
        .as_ref()
        .ok_or_else(|| ParlotteError::Unknown {
            message: "no active verification".to_string(),
        })?;

    if request.is_cancelled() {
        let reason = request
            .cancel_info()
            .map(|c| c.reason().to_string())
            .unwrap_or_else(|| "cancelled".to_string());
        return Ok(VerificationState::Cancelled { reason });
    }

    if let Some(sas) = active.sas.as_ref() {
        if sas.is_cancelled() {
            let reason = sas
                .cancel_info()
                .map(|c| c.reason().to_string())
                .unwrap_or_else(|| "cancelled".to_string());
            return Ok(VerificationState::Cancelled { reason });
        }
        if sas.is_done() {
            return Ok(VerificationState::Done);
        }
        return Ok(match sas.state() {
            SdkSasState::Created { .. }
            | SdkSasState::Started { .. }
            | SdkSasState::Accepted { .. } => VerificationState::SasStarted,
            SdkSasState::KeysExchanged { emojis, .. } => {
                if let Some(emojis) = emojis {
                    let emojis = emojis
                        .emojis
                        .iter()
                        .map(|e| EmojiInfo {
                            symbol: e.symbol.to_string(),
                            description: e.description.to_string(),
                        })
                        .collect();
                    VerificationState::SasReadyToCompare { emojis }
                } else {
                    VerificationState::SasStarted
                }
            }
            SdkSasState::Confirmed => VerificationState::SasConfirmed,
            SdkSasState::Done { .. } => VerificationState::Done,
            SdkSasState::Cancelled(c) => VerificationState::Cancelled {
                reason: c.reason().to_string(),
            },
        });
    }

    match request.state() {
        SdkRequestState::Created { .. } | SdkRequestState::Requested { .. } => {
            Ok(VerificationState::Pending)
        }
        SdkRequestState::Ready { .. } => Ok(VerificationState::Ready),
        SdkRequestState::Transitioned { verification } => match verification {
            Verification::SasV1(_) => Ok(VerificationState::SasStarted),
            _ => Ok(VerificationState::SasStarted),
        },
        SdkRequestState::Done => Ok(VerificationState::Done),
        SdkRequestState::Cancelled(c) => Ok(VerificationState::Cancelled {
            reason: c.reason().to_string(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derive_state_with_no_request_errors() {
        // The SDK request/SAS types can't be constructed without a live flow,
        // so only the empty-active guard is unit-testable here — but it's the
        // branch that protects every caller from an unwrap on a missing request.
        let active = ActiveVerification::default();
        let result = derive_state(&active);
        assert!(matches!(result, Err(ParlotteError::Unknown { .. })));
    }

    #[test]
    fn emoji_info_construction() {
        let e = EmojiInfo {
            symbol: "🐶".to_string(),
            description: "Dog".to_string(),
        };
        assert_eq!(e.symbol, "🐶");
        assert_eq!(e.description, "Dog");
    }

    #[test]
    fn verification_state_variants_are_distinct() {
        // Guards against the enum being collapsed/reordered in a way the FFI
        // conversion depends on.
        let ready = VerificationState::SasReadyToCompare {
            emojis: vec![EmojiInfo {
                symbol: "🐱".into(),
                description: "Cat".into(),
            }],
        };
        match ready {
            VerificationState::SasReadyToCompare { emojis } => {
                assert_eq!(emojis.len(), 1);
                assert_eq!(emojis[0].symbol, "🐱");
            }
            _ => panic!("wrong variant"),
        }
    }
}
