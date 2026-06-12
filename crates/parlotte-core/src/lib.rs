#![recursion_limit = "512"]

pub mod client;
pub mod error;
pub mod message;
pub mod recovery;
pub mod room;
pub mod session;
pub mod sync;
pub mod timeline;
pub mod verification;

pub use client::ParlotteClient;
pub use error::ParlotteError;
pub use message::{
    LoginMethods, MatrixSessionData, MessageBatch, MessageInfo, OidcSessionData, ReactionInfo,
    SessionInfo, SsoProvider, UserProfile,
};
pub use recovery::RecoveryState;
pub use room::{PublicRoomInfo, RoomInfo, RoomMemberInfo, UserSearchResult};
pub use session::{SessionChangeEvent, SessionChangeListener};
pub use sync::SyncListener;
pub use timeline::TimelineListener;
pub use verification::{
    EmojiInfo, VerificationListener, VerificationRequestInfo, VerificationState,
};
