#![recursion_limit = "512"]

uniffi::setup_scaffolding!();

/// Initialize logging with the given level filter (e.g. "debug", "info", "warn").
/// Only the first call has effect; subsequent calls are ignored.
#[uniffi::export]
pub fn init_logging(level: String) {
    use tracing_subscriber::EnvFilter;

    let filter = EnvFilter::try_new(format!("parlotte_core={level}"))
        .unwrap_or_else(|_| EnvFilter::new("parlotte_core=info"));

    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .try_init();
}

use parlotte_core::{
    EmojiInfo as CoreEmojiInfo, LoginMethods as CoreLoginMethods,
    MatrixSessionData as CoreMatrixSessionData, MessageBatch as CoreMessageBatch,
    MessageInfo as CoreMessageInfo, OidcSessionData as CoreOidcSessionData,
    ParlotteClient as CoreClient, ParlotteError as CoreError, PublicRoomInfo as CorePublicRoomInfo,
    ReactionInfo as CoreReactionInfo, RecoveryState as CoreRecoveryState, RoomInfo as CoreRoomInfo,
    RoomMemberInfo as CoreRoomMemberInfo, SessionChangeEvent as CoreSessionChangeEvent,
    SessionInfo as CoreSessionInfo, SsoProvider as CoreSsoProvider, UserProfile as CoreUserProfile,
    UserSearchResult as CoreUserSearchResult,
    VerificationRequestInfo as CoreVerificationRequestInfo,
    VerificationState as CoreVerificationState,
};
use std::fmt;
use std::sync::Arc;

// -- Error type exposed via UniFFI --

#[derive(Debug, uniffi::Error)]
pub enum ParlotteError {
    Auth { message: String },
    Network { message: String },
    Room { message: String },
    Store { message: String },
    Sync { message: String },
    Unknown { message: String },
}

impl fmt::Display for ParlotteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Auth { message } => write!(f, "authentication failed: {message}"),
            Self::Network { message } => write!(f, "network error: {message}"),
            Self::Room { message } => write!(f, "room error: {message}"),
            Self::Store { message } => write!(f, "store error: {message}"),
            Self::Sync { message } => write!(f, "sync error: {message}"),
            Self::Unknown { message } => write!(f, "unknown error: {message}"),
        }
    }
}

impl From<CoreError> for ParlotteError {
    fn from(err: CoreError) -> Self {
        match err {
            CoreError::Auth { message } => ParlotteError::Auth { message },
            CoreError::Network { message } => ParlotteError::Network { message },
            CoreError::Room { message } => ParlotteError::Room { message },
            CoreError::Store { message } => ParlotteError::Store { message },
            CoreError::Sync { message } => ParlotteError::Sync { message },
            CoreError::Unknown { message } => ParlotteError::Unknown { message },
        }
    }
}

// -- Record types --

#[derive(uniffi::Record)]
pub struct RoomInfo {
    pub id: String,
    pub display_name: String,
    pub is_encrypted: bool,
    pub is_public: bool,
    pub is_direct: bool,
    pub topic: Option<String>,
    pub is_invited: bool,
    pub unread_count: u64,
    /// Timestamp (ms since the Unix epoch) of the room's latest known event.
    /// `None` when no event is known yet. The room list is returned sorted
    /// most-recent-first using this value.
    #[uniffi(default = None)]
    pub last_activity_ts: Option<u64>,
}

impl From<CoreRoomInfo> for RoomInfo {
    fn from(r: CoreRoomInfo) -> Self {
        Self {
            id: r.id,
            display_name: r.display_name,
            is_encrypted: r.is_encrypted,
            is_public: r.is_public,
            is_direct: r.is_direct,
            topic: r.topic,
            is_invited: r.is_invited,
            unread_count: r.unread_count,
            last_activity_ts: r.last_activity_ts,
        }
    }
}

#[derive(uniffi::Record)]
pub struct ReactionInfo {
    pub event_id: String,
    pub key: String,
    pub sender: String,
}

impl From<CoreReactionInfo> for ReactionInfo {
    fn from(r: CoreReactionInfo) -> Self {
        Self {
            event_id: r.event_id,
            key: r.key,
            sender: r.sender,
        }
    }
}

#[derive(uniffi::Record)]
pub struct MessageInfo {
    pub item_id: String,
    pub send_state: String,
    pub event_id: String,
    pub sender: String,
    pub body: String,
    pub formatted_body: Option<String>,
    pub message_type: String,
    pub timestamp_ms: u64,
    pub is_edited: bool,
    pub replied_to_event_id: Option<String>,
    pub media_source: Option<String>,
    pub media_mime_type: Option<String>,
    pub media_width: Option<u32>,
    pub media_height: Option<u32>,
    pub media_size: Option<u64>,
    pub reactions: Vec<ReactionInfo>,
}

impl From<CoreMessageInfo> for MessageInfo {
    fn from(m: CoreMessageInfo) -> Self {
        Self {
            item_id: m.item_id,
            send_state: m.send_state,
            event_id: m.event_id,
            sender: m.sender,
            body: m.body,
            formatted_body: m.formatted_body,
            message_type: m.message_type,
            timestamp_ms: m.timestamp_ms,
            is_edited: m.is_edited,
            replied_to_event_id: m.replied_to_event_id,
            media_source: m.media_source,
            media_mime_type: m.media_mime_type,
            media_width: m.media_width,
            media_height: m.media_height,
            media_size: m.media_size,
            reactions: m.reactions.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(uniffi::Record)]
pub struct MessageBatch {
    pub messages: Vec<MessageInfo>,
    pub end_token: Option<String>,
}

impl From<CoreMessageBatch> for MessageBatch {
    fn from(b: CoreMessageBatch) -> Self {
        Self {
            messages: b.messages.into_iter().map(Into::into).collect(),
            end_token: b.end_token,
        }
    }
}

#[derive(uniffi::Record)]
pub struct SessionInfo {
    pub user_id: String,
    pub device_id: String,
}

impl From<CoreSessionInfo> for SessionInfo {
    fn from(s: CoreSessionInfo) -> Self {
        Self {
            user_id: s.user_id,
            device_id: s.device_id,
        }
    }
}

#[derive(uniffi::Record)]
pub struct MatrixSessionData {
    pub user_id: String,
    pub device_id: String,
    pub access_token: String,
}

impl From<CoreMatrixSessionData> for MatrixSessionData {
    fn from(s: CoreMatrixSessionData) -> Self {
        Self {
            user_id: s.user_id,
            device_id: s.device_id,
            access_token: s.access_token,
        }
    }
}

impl From<MatrixSessionData> for CoreMatrixSessionData {
    fn from(s: MatrixSessionData) -> Self {
        Self {
            user_id: s.user_id,
            device_id: s.device_id,
            access_token: s.access_token,
        }
    }
}

#[derive(uniffi::Record)]
pub struct OidcSessionData {
    pub user_id: String,
    pub device_id: String,
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub client_id: String,
}

impl From<CoreOidcSessionData> for OidcSessionData {
    fn from(s: CoreOidcSessionData) -> Self {
        Self {
            user_id: s.user_id,
            device_id: s.device_id,
            access_token: s.access_token,
            refresh_token: s.refresh_token,
            client_id: s.client_id,
        }
    }
}

impl From<OidcSessionData> for CoreOidcSessionData {
    fn from(s: OidcSessionData) -> Self {
        Self {
            user_id: s.user_id,
            device_id: s.device_id,
            access_token: s.access_token,
            refresh_token: s.refresh_token,
            client_id: s.client_id,
        }
    }
}

#[derive(uniffi::Record)]
pub struct PublicRoomInfo {
    pub id: String,
    pub name: Option<String>,
    pub topic: Option<String>,
    pub member_count: u64,
    pub alias: Option<String>,
}

impl From<CorePublicRoomInfo> for PublicRoomInfo {
    fn from(r: CorePublicRoomInfo) -> Self {
        Self {
            id: r.id,
            name: r.name,
            topic: r.topic,
            member_count: r.member_count,
            alias: r.alias,
        }
    }
}

#[derive(uniffi::Record)]
pub struct RoomMemberInfo {
    pub user_id: String,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
    pub power_level: i64,
    pub role: String,
}

impl From<CoreRoomMemberInfo> for RoomMemberInfo {
    fn from(m: CoreRoomMemberInfo) -> Self {
        Self {
            user_id: m.user_id,
            display_name: m.display_name,
            avatar_url: m.avatar_url,
            power_level: m.power_level,
            role: m.role,
        }
    }
}

#[derive(uniffi::Record)]
pub struct UserSearchResult {
    pub user_id: String,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
}

impl From<CoreUserSearchResult> for UserSearchResult {
    fn from(u: CoreUserSearchResult) -> Self {
        Self {
            user_id: u.user_id,
            display_name: u.display_name,
            avatar_url: u.avatar_url,
        }
    }
}

#[derive(uniffi::Record)]
pub struct SsoProvider {
    pub id: String,
    pub name: String,
}

impl From<CoreSsoProvider> for SsoProvider {
    fn from(p: CoreSsoProvider) -> Self {
        Self {
            id: p.id,
            name: p.name,
        }
    }
}

#[derive(uniffi::Record)]
pub struct LoginMethods {
    pub supports_password: bool,
    pub supports_sso: bool,
    pub sso_providers: Vec<SsoProvider>,
    pub supports_oidc: bool,
}

impl From<CoreLoginMethods> for LoginMethods {
    fn from(m: CoreLoginMethods) -> Self {
        Self {
            supports_password: m.supports_password,
            supports_sso: m.supports_sso,
            sso_providers: m.sso_providers.into_iter().map(Into::into).collect(),
            supports_oidc: m.supports_oidc,
        }
    }
}

#[derive(uniffi::Record)]
pub struct UserProfile {
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
}

impl From<CoreUserProfile> for UserProfile {
    fn from(p: CoreUserProfile) -> Self {
        Self {
            display_name: p.display_name,
            avatar_url: p.avatar_url,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RecoveryState {
    Unknown,
    Enabled,
    Disabled,
    Incomplete,
}

impl From<CoreRecoveryState> for RecoveryState {
    fn from(s: CoreRecoveryState) -> Self {
        match s {
            CoreRecoveryState::Unknown => RecoveryState::Unknown,
            CoreRecoveryState::Enabled => RecoveryState::Enabled,
            CoreRecoveryState::Disabled => RecoveryState::Disabled,
            CoreRecoveryState::Incomplete => RecoveryState::Incomplete,
        }
    }
}

// -- Verification types --

#[derive(Debug, Clone, uniffi::Record)]
pub struct VerificationRequestInfo {
    pub flow_id: String,
    pub other_user_id: String,
    pub is_self_verification: bool,
    pub we_started: bool,
}

impl From<CoreVerificationRequestInfo> for VerificationRequestInfo {
    fn from(i: CoreVerificationRequestInfo) -> Self {
        Self {
            flow_id: i.flow_id,
            other_user_id: i.other_user_id,
            is_self_verification: i.is_self_verification,
            we_started: i.we_started,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct VerificationEmoji {
    pub symbol: String,
    pub description: String,
}

impl From<CoreEmojiInfo> for VerificationEmoji {
    fn from(e: CoreEmojiInfo) -> Self {
        Self {
            symbol: e.symbol,
            description: e.description,
        }
    }
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum VerificationState {
    Pending,
    Ready,
    SasStarted,
    SasReadyToCompare { emojis: Vec<VerificationEmoji> },
    SasConfirmed,
    Done,
    Cancelled { reason: String },
}

impl From<CoreVerificationState> for VerificationState {
    fn from(s: CoreVerificationState) -> Self {
        match s {
            CoreVerificationState::Pending => VerificationState::Pending,
            CoreVerificationState::Ready => VerificationState::Ready,
            CoreVerificationState::SasStarted => VerificationState::SasStarted,
            CoreVerificationState::SasReadyToCompare { emojis } => {
                VerificationState::SasReadyToCompare {
                    emojis: emojis.into_iter().map(Into::into).collect(),
                }
            }
            CoreVerificationState::SasConfirmed => VerificationState::SasConfirmed,
            CoreVerificationState::Done => VerificationState::Done,
            CoreVerificationState::Cancelled { reason } => VerificationState::Cancelled { reason },
        }
    }
}

// -- Callback interfaces --

/// Callback for incoming verification requests from another device.
#[uniffi::export(callback_interface)]
pub trait ParlotteVerificationListener: Send + Sync {
    fn on_verification_request(&self, info: VerificationRequestInfo);
}

struct VerificationListenerBridge {
    inner: Box<dyn ParlotteVerificationListener>,
}

impl parlotte_core::VerificationListener for VerificationListenerBridge {
    fn on_verification_request(&self, info: CoreVerificationRequestInfo) {
        self.inner.on_verification_request(info.into());
    }
}

/// Callback for persistent sync updates.
/// Called after each successful sync response.
#[uniffi::export(callback_interface)]
pub trait ParlotteSyncListener: Send + Sync {
    fn on_sync_update(&self);
    fn on_typing_update(&self, room_id: String, user_ids: Vec<String>);
    /// Called when the sync loop has stopped. `error` is `None` for a clean
    /// stop and `Some(message)` if it gave up after repeated failures.
    fn on_sync_stopped(&self, error: Option<String>);
}

/// Bridge from the FFI callback to the core SyncListener trait.
struct SyncListenerBridge {
    inner: Box<dyn ParlotteSyncListener>,
}

impl parlotte_core::SyncListener for SyncListenerBridge {
    fn on_sync_update(&self) {
        self.inner.on_sync_update();
    }

    fn on_typing_update(&self, room_id: String, user_ids: Vec<String>) {
        self.inner.on_typing_update(room_id, user_ids);
    }

    fn on_sync_stopped(&self, error: Option<String>) {
        self.inner.on_sync_stopped(error);
    }
}

/// Callback for room timeline updates. `on_timeline_update` is invoked with a
/// complete, ordered (oldest-first) snapshot of the active room's messages on
/// every change.
#[uniffi::export(callback_interface)]
pub trait ParlotteTimelineListener: Send + Sync {
    fn on_timeline_update(&self, messages: Vec<MessageInfo>);
}

/// Bridge from the FFI callback to the core TimelineListener trait.
struct TimelineListenerBridge {
    inner: Box<dyn ParlotteTimelineListener>,
}

impl parlotte_core::TimelineListener for TimelineListenerBridge {
    fn on_timeline_update(&self, messages: Vec<CoreMessageInfo>) {
        self.inner
            .on_timeline_update(messages.into_iter().map(Into::into).collect());
    }
}

/// A session-level event emitted by the matrix-sdk. See
/// [`ParlotteSessionChangeListener`].
#[derive(uniffi::Enum)]
pub enum SessionChangeEvent {
    /// OIDC tokens were rotated. Persist `session` immediately.
    TokensRefreshed { session: OidcSessionData },
    /// The server returned `M_UNKNOWN_TOKEN`. User must sign in again.
    UnknownToken { soft_logout: bool },
}

impl From<CoreSessionChangeEvent> for SessionChangeEvent {
    fn from(e: CoreSessionChangeEvent) -> Self {
        match e {
            CoreSessionChangeEvent::TokensRefreshed { session } => {
                SessionChangeEvent::TokensRefreshed {
                    session: session.into(),
                }
            }
            CoreSessionChangeEvent::UnknownToken { soft_logout } => {
                SessionChangeEvent::UnknownToken { soft_logout }
            }
        }
    }
}

/// Callback fired whenever OIDC tokens refresh or the server invalidates
/// our token. Register once after login/restore so rotated refresh tokens
/// can be persisted.
#[uniffi::export(callback_interface)]
pub trait ParlotteSessionChangeListener: Send + Sync {
    fn on_session_change(&self, event: SessionChangeEvent);
}

struct SessionChangeListenerBridge {
    inner: Box<dyn ParlotteSessionChangeListener>,
}

impl parlotte_core::SessionChangeListener for SessionChangeListenerBridge {
    fn on_session_change(&self, event: CoreSessionChangeEvent) {
        self.inner.on_session_change(event.into());
    }
}

// -- Main client object --

#[derive(uniffi::Object)]
pub struct ParlotteClientFFI {
    inner: CoreClient,
}

#[uniffi::export]
impl ParlotteClientFFI {
    #[uniffi::constructor]
    pub fn new(homeserver_url: String, store_path: Option<String>) -> Result<Self, ParlotteError> {
        let client = CoreClient::new(&homeserver_url, store_path.as_deref())?;
        Ok(Self { inner: client })
    }

    pub fn login(&self, username: String, password: String) -> Result<SessionInfo, ParlotteError> {
        Ok(self.inner.login(&username, &password)?.into())
    }

    pub fn session(&self) -> Option<MatrixSessionData> {
        self.inner.session().map(Into::into)
    }

    pub fn restore_session(&self, session_data: MatrixSessionData) -> Result<(), ParlotteError> {
        Ok(self.inner.restore_session(session_data.into())?)
    }

    pub fn logout(&self) -> Result<(), ParlotteError> {
        Ok(self.inner.logout()?)
    }

    pub fn rooms(&self) -> Result<Vec<RoomInfo>, ParlotteError> {
        Ok(self.inner.rooms()?.into_iter().map(Into::into).collect())
    }

    pub fn send_message(&self, room_id: String, body: String) -> Result<String, ParlotteError> {
        Ok(self.inner.send_message(&room_id, &body)?)
    }

    pub fn send_reply(
        &self,
        room_id: String,
        event_id: String,
        body: String,
    ) -> Result<String, ParlotteError> {
        Ok(self.inner.send_reply(&room_id, &event_id, &body)?)
    }

    pub fn messages(
        &self,
        room_id: String,
        limit: u64,
        from: Option<String>,
    ) -> Result<MessageBatch, ParlotteError> {
        Ok(self
            .inner
            .messages(&room_id, limit, from.as_deref())?
            .into())
    }

    pub fn sync_once(&self) -> Result<(), ParlotteError> {
        Ok(self.inner.sync_once()?)
    }

    pub fn create_room(&self, name: String, is_public: bool) -> Result<String, ParlotteError> {
        Ok(self.inner.create_room(&name, is_public)?)
    }

    pub fn create_dm(&self, user_id: String) -> Result<String, ParlotteError> {
        Ok(self.inner.create_dm(&user_id)?)
    }

    pub fn search_users(
        &self,
        term: String,
        limit: u64,
    ) -> Result<Vec<UserSearchResult>, ParlotteError> {
        Ok(self
            .inner
            .search_users(&term, limit)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn public_rooms(&self) -> Result<Vec<PublicRoomInfo>, ParlotteError> {
        Ok(self
            .inner
            .public_rooms()?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn invite_user(&self, room_id: String, user_id: String) -> Result<(), ParlotteError> {
        Ok(self.inner.invite_user(&room_id, &user_id)?)
    }

    pub fn join_room(&self, room_id: String) -> Result<(), ParlotteError> {
        Ok(self.inner.join_room(&room_id)?)
    }

    pub fn leave_room(&self, room_id: String) -> Result<(), ParlotteError> {
        Ok(self.inner.leave_room(&room_id)?)
    }

    pub fn set_user_power_level(
        &self,
        room_id: String,
        user_id: String,
        level: i64,
    ) -> Result<(), ParlotteError> {
        Ok(self.inner.set_user_power_level(&room_id, &user_id, level)?)
    }

    pub fn kick_user(
        &self,
        room_id: String,
        user_id: String,
        reason: Option<String>,
    ) -> Result<(), ParlotteError> {
        Ok(self.inner.kick_user(&room_id, &user_id, reason)?)
    }

    pub fn ban_user(
        &self,
        room_id: String,
        user_id: String,
        reason: Option<String>,
    ) -> Result<(), ParlotteError> {
        Ok(self.inner.ban_user(&room_id, &user_id, reason)?)
    }

    pub fn unban_user(
        &self,
        room_id: String,
        user_id: String,
        reason: Option<String>,
    ) -> Result<(), ParlotteError> {
        Ok(self.inner.unban_user(&room_id, &user_id, reason)?)
    }

    pub fn room_members(&self, room_id: String) -> Result<Vec<RoomMemberInfo>, ParlotteError> {
        Ok(self
            .inner
            .room_members(&room_id)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn send_read_receipt(
        &self,
        room_id: String,
        event_id: String,
    ) -> Result<(), ParlotteError> {
        Ok(self.inner.send_read_receipt(&room_id, &event_id)?)
    }

    pub fn send_typing_notice(
        &self,
        room_id: String,
        is_typing: bool,
    ) -> Result<(), ParlotteError> {
        Ok(self.inner.send_typing_notice(&room_id, is_typing)?)
    }

    pub fn send_attachment(
        &self,
        room_id: String,
        filename: String,
        mime_type: String,
        data: Vec<u8>,
        width: Option<u32>,
        height: Option<u32>,
    ) -> Result<String, ParlotteError> {
        Ok(self
            .inner
            .send_attachment(&room_id, &filename, &mime_type, data, width, height)?)
    }

    pub fn download_media(&self, mxc_uri: String) -> Result<Vec<u8>, ParlotteError> {
        Ok(self.inner.download_media(&mxc_uri)?)
    }

    pub fn edit_message(
        &self,
        room_id: String,
        event_id: String,
        new_body: String,
    ) -> Result<(), ParlotteError> {
        Ok(self.inner.edit_message(&room_id, &event_id, &new_body)?)
    }

    pub fn redact_message(&self, room_id: String, event_id: String) -> Result<(), ParlotteError> {
        Ok(self.inner.redact_message(&room_id, &event_id)?)
    }

    pub fn send_reaction(
        &self,
        room_id: String,
        event_id: String,
        key: String,
    ) -> Result<String, ParlotteError> {
        Ok(self.inner.send_reaction(&room_id, &event_id, &key)?)
    }

    pub fn redact_reaction(
        &self,
        room_id: String,
        reaction_event_id: String,
    ) -> Result<(), ParlotteError> {
        Ok(self.inner.redact_reaction(&room_id, &reaction_event_id)?)
    }

    pub fn login_methods(&self) -> Result<LoginMethods, ParlotteError> {
        Ok(self.inner.login_methods()?.into())
    }

    pub fn sso_login_url(
        &self,
        redirect_url: String,
        idp_id: Option<String>,
    ) -> Result<String, ParlotteError> {
        Ok(self.inner.sso_login_url(&redirect_url, idp_id.as_deref())?)
    }

    pub fn login_sso_callback(&self, callback_url: String) -> Result<SessionInfo, ParlotteError> {
        Ok(self.inner.login_sso_callback(&callback_url)?.into())
    }

    pub fn oidc_login_url(&self, redirect_uri: String) -> Result<String, ParlotteError> {
        Ok(self.inner.oidc_login_url(&redirect_uri)?)
    }

    pub fn oidc_finish_login(&self, callback_url: String) -> Result<SessionInfo, ParlotteError> {
        Ok(self.inner.oidc_finish_login(&callback_url)?.into())
    }

    pub fn oidc_session(&self) -> Option<OidcSessionData> {
        self.inner.oidc_session().map(Into::into)
    }

    pub fn oidc_restore_session(&self, session_data: OidcSessionData) -> Result<(), ParlotteError> {
        Ok(self.inner.oidc_restore_session(session_data.into())?)
    }

    pub fn set_session_change_listener(&self, listener: Box<dyn ParlotteSessionChangeListener>) {
        self.inner
            .set_session_change_listener(Arc::new(SessionChangeListenerBridge { inner: listener }));
    }

    pub fn get_profile(&self) -> Result<UserProfile, ParlotteError> {
        Ok(self.inner.get_profile()?.into())
    }

    pub fn set_display_name(&self, name: String) -> Result<(), ParlotteError> {
        Ok(self.inner.set_display_name(&name)?)
    }

    pub fn set_avatar(&self, mime_type: String, data: Vec<u8>) -> Result<String, ParlotteError> {
        Ok(self.inner.set_avatar(&mime_type, data)?)
    }

    pub fn remove_avatar(&self) -> Result<(), ParlotteError> {
        Ok(self.inner.remove_avatar()?)
    }

    pub fn ignore_user(&self, user_id: String) -> Result<(), ParlotteError> {
        Ok(self.inner.ignore_user(&user_id)?)
    }

    pub fn unignore_user(&self, user_id: String) -> Result<(), ParlotteError> {
        Ok(self.inner.unignore_user(&user_id)?)
    }

    pub fn ignored_users(&self) -> Result<Vec<String>, ParlotteError> {
        Ok(self.inner.ignored_users()?)
    }

    pub fn set_room_name(&self, room_id: String, name: String) -> Result<(), ParlotteError> {
        Ok(self.inner.set_room_name(&room_id, &name)?)
    }

    pub fn set_room_topic(&self, room_id: String, topic: String) -> Result<(), ParlotteError> {
        Ok(self.inner.set_room_topic(&room_id, &topic)?)
    }

    pub fn start_sync(&self, listener: Box<dyn ParlotteSyncListener>) -> Result<(), ParlotteError> {
        let bridge = Arc::new(SyncListenerBridge { inner: listener });
        Ok(self.inner.start_sync(bridge)?)
    }

    pub fn stop_sync(&self) {
        self.inner.stop_sync();
    }

    pub fn is_syncing(&self) -> bool {
        self.inner.is_syncing()
    }

    // -- Timeline (active room) --

    pub fn start_timeline(
        &self,
        room_id: String,
        listener: Box<dyn ParlotteTimelineListener>,
    ) -> Result<(), ParlotteError> {
        let bridge = Arc::new(TimelineListenerBridge { inner: listener });
        Ok(self.inner.start_timeline(&room_id, bridge)?)
    }

    pub fn stop_timeline(&self) {
        self.inner.stop_timeline();
    }

    pub fn is_timeline_active(&self, room_id: String) -> bool {
        self.inner.is_timeline_active(&room_id)
    }

    pub fn paginate_timeline_back(
        &self,
        room_id: String,
        num_events: u16,
    ) -> Result<bool, ParlotteError> {
        Ok(self.inner.paginate_timeline_back(&room_id, num_events)?)
    }

    pub fn timeline_send_message(
        &self,
        room_id: String,
        body: String,
    ) -> Result<(), ParlotteError> {
        Ok(self.inner.timeline_send_message(&room_id, &body)?)
    }

    pub fn timeline_send_reply(
        &self,
        room_id: String,
        in_reply_to: String,
        body: String,
    ) -> Result<(), ParlotteError> {
        Ok(self
            .inner
            .timeline_send_reply(&room_id, &in_reply_to, &body)?)
    }

    pub fn timeline_toggle_reaction(
        &self,
        room_id: String,
        target_event_id: String,
        key: String,
    ) -> Result<(), ParlotteError> {
        Ok(self
            .inner
            .timeline_toggle_reaction(&room_id, &target_event_id, &key)?)
    }

    pub fn recovery_state(&self) -> RecoveryState {
        self.inner.recovery_state().into()
    }

    pub fn enable_recovery(&self, passphrase: Option<String>) -> Result<String, ParlotteError> {
        Ok(self.inner.enable_recovery(passphrase.as_deref())?)
    }

    pub fn disable_recovery(&self) -> Result<(), ParlotteError> {
        Ok(self.inner.disable_recovery()?)
    }

    pub fn recover(&self, recovery_key: String) -> Result<(), ParlotteError> {
        Ok(self.inner.recover(&recovery_key)?)
    }

    pub fn reset_recovery_key(&self) -> Result<String, ParlotteError> {
        Ok(self.inner.reset_recovery_key()?)
    }

    pub fn download_room_keys(&self, room_id: String) -> Result<(), ParlotteError> {
        Ok(self.inner.download_room_keys(&room_id)?)
    }

    pub fn begin_reset_identity(&self) -> Result<Option<String>, ParlotteError> {
        Ok(self.inner.begin_reset_identity()?)
    }

    pub fn finish_reset_identity(&self) -> Result<String, ParlotteError> {
        Ok(self.inner.finish_reset_identity()?)
    }

    pub fn cancel_reset_identity(&self) {
        self.inner.cancel_reset_identity();
    }

    pub fn is_last_device(&self) -> Result<Option<bool>, ParlotteError> {
        Ok(self.inner.is_last_device()?)
    }

    // -- Verification --

    pub fn set_verification_listener(&self, listener: Box<dyn ParlotteVerificationListener>) {
        self.inner
            .set_verification_listener(Arc::new(VerificationListenerBridge { inner: listener }));
    }

    pub fn request_self_verification(&self) -> Result<VerificationRequestInfo, ParlotteError> {
        Ok(self.inner.request_self_verification()?.into())
    }

    pub fn accept_verification(&self) -> Result<(), ParlotteError> {
        Ok(self.inner.accept_verification()?)
    }

    pub fn start_sas_verification(&self) -> Result<(), ParlotteError> {
        Ok(self.inner.start_sas_verification()?)
    }

    pub fn confirm_sas_verification(&self) -> Result<(), ParlotteError> {
        Ok(self.inner.confirm_sas_verification()?)
    }

    pub fn sas_mismatch(&self) -> Result<(), ParlotteError> {
        Ok(self.inner.sas_mismatch()?)
    }

    pub fn cancel_verification(&self) -> Result<(), ParlotteError> {
        Ok(self.inner.cancel_verification()?)
    }

    pub fn verification_state(&self) -> Option<VerificationState> {
        self.inner.verification_state().map(Into::into)
    }

    pub fn clear_verification(&self) {
        self.inner.clear_verification();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // -- RoomInfo round-trip --

    #[test]
    fn room_info_converts_all_fields() {
        let core = CoreRoomInfo {
            id: "!room:example.com".into(),
            display_name: "General".into(),
            is_encrypted: true,
            is_public: false,
            is_direct: false,
            topic: Some("Welcome".into()),
            is_invited: false,
            unread_count: 42,
            last_activity_ts: Some(1_700_000_000_000),
        };
        let ffi: RoomInfo = core.into();
        assert_eq!(ffi.id, "!room:example.com");
        assert_eq!(ffi.display_name, "General");
        assert!(ffi.is_encrypted);
        assert!(!ffi.is_public);
        assert!(!ffi.is_direct);
        assert_eq!(ffi.topic.as_deref(), Some("Welcome"));
        assert!(!ffi.is_invited);
        assert_eq!(ffi.unread_count, 42);
        assert_eq!(ffi.last_activity_ts, Some(1_700_000_000_000));
    }

    #[test]
    fn room_info_converts_none_topic() {
        let core = CoreRoomInfo {
            id: "!r:x.com".into(),
            display_name: "No Topic".into(),
            is_encrypted: false,
            is_public: true,
            is_direct: true,
            topic: None,
            is_invited: true,
            unread_count: 0,
            last_activity_ts: None,
        };
        let ffi: RoomInfo = core.into();
        assert!(ffi.topic.is_none());
        assert!(ffi.is_public);
        assert!(ffi.is_direct);
        assert!(ffi.is_invited);
        assert!(ffi.last_activity_ts.is_none());
    }

    // -- MessageInfo round-trip --

    #[test]
    fn message_info_converts_all_fields() {
        let core = CoreMessageInfo {
            item_id: "$evt:example.com".into(),
            send_state: String::new(),
            event_id: "$evt:example.com".into(),
            sender: "@alice:example.com".into(),
            body: "Hello".into(),
            formatted_body: Some("<b>Hello</b>".into()),
            message_type: "text".into(),
            timestamp_ms: 1700000000000,
            is_edited: true,
            replied_to_event_id: Some("$parent:example.com".into()),
            media_source: None,
            media_mime_type: None,
            media_width: None,
            media_height: None,
            media_size: None,
            reactions: vec![],
        };
        let ffi: MessageInfo = core.into();
        assert_eq!(ffi.event_id, "$evt:example.com");
        assert_eq!(ffi.sender, "@alice:example.com");
        assert_eq!(ffi.body, "Hello");
        assert_eq!(ffi.formatted_body.as_deref(), Some("<b>Hello</b>"));
        assert_eq!(ffi.message_type, "text");
        assert_eq!(ffi.timestamp_ms, 1700000000000);
        assert!(ffi.is_edited);
        assert_eq!(
            ffi.replied_to_event_id.as_deref(),
            Some("$parent:example.com")
        );
    }

    #[test]
    fn message_info_converts_none_formatted_body() {
        let core = CoreMessageInfo {
            item_id: "$e:x.com".into(),
            send_state: String::new(),
            event_id: "$e:x.com".into(),
            sender: "@b:x.com".into(),
            body: "plain".into(),
            formatted_body: None,
            message_type: "notice".into(),
            timestamp_ms: 0,
            is_edited: false,
            replied_to_event_id: None,
            media_source: None,
            media_mime_type: None,
            media_width: None,
            media_height: None,
            media_size: None,
            reactions: vec![],
        };
        let ffi: MessageInfo = core.into();
        assert!(ffi.formatted_body.is_none());
        assert_eq!(ffi.message_type, "notice");
        assert!(!ffi.is_edited);
        assert!(ffi.replied_to_event_id.is_none());
    }

    #[test]
    fn message_info_converts_media_fields() {
        let core = CoreMessageInfo {
            item_id: "$img:example.com".into(),
            send_state: String::new(),
            event_id: "$img:example.com".into(),
            sender: "@alice:example.com".into(),
            body: "photo.png".into(),
            formatted_body: None,
            message_type: "image".into(),
            timestamp_ms: 1700000000000,
            is_edited: false,
            replied_to_event_id: None,
            media_source: Some("mxc://example.com/abc123".into()),
            media_mime_type: Some("image/png".into()),
            media_width: Some(1920),
            media_height: Some(1080),
            media_size: Some(204800),
            reactions: vec![],
        };
        let ffi: MessageInfo = core.into();
        assert_eq!(
            ffi.media_source.as_deref(),
            Some("mxc://example.com/abc123")
        );
        assert_eq!(ffi.media_mime_type.as_deref(), Some("image/png"));
        assert_eq!(ffi.media_width, Some(1920));
        assert_eq!(ffi.media_height, Some(1080));
        assert_eq!(ffi.media_size, Some(204800));
    }

    // -- ReactionInfo round-trip --

    #[test]
    fn reaction_info_converts_all_fields() {
        let core = CoreReactionInfo {
            event_id: "$reaction:example.com".into(),
            key: "\u{1f44d}".into(),
            sender: "@alice:example.com".into(),
        };
        let ffi: ReactionInfo = core.into();
        assert_eq!(ffi.event_id, "$reaction:example.com");
        assert_eq!(ffi.key, "\u{1f44d}");
        assert_eq!(ffi.sender, "@alice:example.com");
    }

    #[test]
    fn message_info_converts_reactions() {
        let core = CoreMessageInfo {
            item_id: "$msg:example.com".into(),
            send_state: String::new(),
            event_id: "$msg:example.com".into(),
            sender: "@bob:example.com".into(),
            body: "Hello".into(),
            formatted_body: None,
            message_type: "text".into(),
            timestamp_ms: 1700000000000,
            is_edited: false,
            replied_to_event_id: None,
            media_source: None,
            media_mime_type: None,
            media_width: None,
            media_height: None,
            media_size: None,
            reactions: vec![
                CoreReactionInfo {
                    event_id: "$r1:example.com".into(),
                    key: "\u{1f44d}".into(),
                    sender: "@alice:example.com".into(),
                },
                CoreReactionInfo {
                    event_id: "$r2:example.com".into(),
                    key: "\u{2764}\u{fe0f}".into(),
                    sender: "@carol:example.com".into(),
                },
            ],
        };
        let ffi: MessageInfo = core.into();
        assert_eq!(ffi.reactions.len(), 2);
        assert_eq!(ffi.reactions[0].key, "\u{1f44d}");
        assert_eq!(ffi.reactions[1].sender, "@carol:example.com");
    }

    // -- MessageBatch round-trip --

    #[test]
    fn message_batch_converts_with_token() {
        let core = CoreMessageBatch {
            messages: vec![CoreMessageInfo {
                item_id: "$1:x.com".into(),
                send_state: String::new(),
                event_id: "$1:x.com".into(),
                sender: "@a:x.com".into(),
                body: "msg".into(),
                formatted_body: None,
                message_type: "text".into(),
                timestamp_ms: 100,
                is_edited: false,
                replied_to_event_id: None,
                media_source: None,
                media_mime_type: None,
                media_width: None,
                media_height: None,
                media_size: None,
                reactions: vec![],
            }],
            end_token: Some("t47_42_0_1".into()),
        };
        let ffi: MessageBatch = core.into();
        assert_eq!(ffi.messages.len(), 1);
        assert_eq!(ffi.messages[0].body, "msg");
        assert_eq!(ffi.end_token.as_deref(), Some("t47_42_0_1"));
    }

    #[test]
    fn message_batch_converts_without_token() {
        let core = CoreMessageBatch {
            messages: vec![],
            end_token: None,
        };
        let ffi: MessageBatch = core.into();
        assert!(ffi.messages.is_empty());
        assert!(ffi.end_token.is_none());
    }

    // -- SessionInfo round-trip --

    #[test]
    fn session_info_converts() {
        let core = CoreSessionInfo {
            user_id: "@alice:example.com".into(),
            device_id: "ABCDEF".into(),
        };
        let ffi: SessionInfo = core.into();
        assert_eq!(ffi.user_id, "@alice:example.com");
        assert_eq!(ffi.device_id, "ABCDEF");
    }

    // -- MatrixSessionData round-trip (bidirectional) --

    #[test]
    fn matrix_session_data_core_to_ffi() {
        let core = CoreMatrixSessionData {
            user_id: "@bob:matrix.org".into(),
            device_id: "DEV999".into(),
            access_token: "syt_secret".into(),
        };
        let ffi: MatrixSessionData = core.into();
        assert_eq!(ffi.user_id, "@bob:matrix.org");
        assert_eq!(ffi.device_id, "DEV999");
        assert_eq!(ffi.access_token, "syt_secret");
    }

    #[test]
    fn matrix_session_data_ffi_to_core() {
        let ffi = MatrixSessionData {
            user_id: "@carol:example.com".into(),
            device_id: "PHONE1".into(),
            access_token: "tok_abc".into(),
        };
        let core: CoreMatrixSessionData = ffi.into();
        assert_eq!(core.user_id, "@carol:example.com");
        assert_eq!(core.device_id, "PHONE1");
        assert_eq!(core.access_token, "tok_abc");
    }

    // -- PublicRoomInfo round-trip --

    #[test]
    fn public_room_info_converts_all_fields() {
        let core = CorePublicRoomInfo {
            id: "!pub:example.com".into(),
            name: Some("Lobby".into()),
            topic: Some("Welcome all".into()),
            member_count: 150,
            alias: Some("#lobby:example.com".into()),
        };
        let ffi: PublicRoomInfo = core.into();
        assert_eq!(ffi.id, "!pub:example.com");
        assert_eq!(ffi.name.as_deref(), Some("Lobby"));
        assert_eq!(ffi.topic.as_deref(), Some("Welcome all"));
        assert_eq!(ffi.member_count, 150);
        assert_eq!(ffi.alias.as_deref(), Some("#lobby:example.com"));
    }

    #[test]
    fn public_room_info_converts_none_optionals() {
        let core = CorePublicRoomInfo {
            id: "!empty:x.com".into(),
            name: None,
            topic: None,
            member_count: 0,
            alias: None,
        };
        let ffi: PublicRoomInfo = core.into();
        assert!(ffi.name.is_none());
        assert!(ffi.topic.is_none());
        assert!(ffi.alias.is_none());
    }

    // -- RoomMemberInfo round-trip --

    #[test]
    fn room_member_info_converts() {
        let core = CoreRoomMemberInfo {
            user_id: "@mod:example.com".into(),
            display_name: Some("Moderator".into()),
            avatar_url: Some("mxc://example.com/avatar".into()),
            power_level: 50,
            role: "moderator".into(),
        };
        let ffi: RoomMemberInfo = core.into();
        assert_eq!(ffi.user_id, "@mod:example.com");
        assert_eq!(ffi.display_name.as_deref(), Some("Moderator"));
        assert_eq!(ffi.avatar_url.as_deref(), Some("mxc://example.com/avatar"));
        assert_eq!(ffi.power_level, 50);
        assert_eq!(ffi.role, "moderator");
    }

    // -- SsoProvider round-trip --

    #[test]
    fn sso_provider_converts() {
        let core = CoreSsoProvider {
            id: "oidc-github".into(),
            name: "GitHub".into(),
        };
        let ffi: SsoProvider = core.into();
        assert_eq!(ffi.id, "oidc-github");
        assert_eq!(ffi.name, "GitHub");
    }

    // -- LoginMethods round-trip --

    #[test]
    fn login_methods_converts_with_providers() {
        let core = CoreLoginMethods {
            supports_password: true,
            supports_sso: true,
            sso_providers: vec![
                CoreSsoProvider {
                    id: "google".into(),
                    name: "Google".into(),
                },
                CoreSsoProvider {
                    id: "github".into(),
                    name: "GitHub".into(),
                },
            ],
            supports_oidc: true,
        };
        let ffi: LoginMethods = core.into();
        assert!(ffi.supports_password);
        assert!(ffi.supports_sso);
        assert!(ffi.supports_oidc);
        assert_eq!(ffi.sso_providers.len(), 2);
        assert_eq!(ffi.sso_providers[0].id, "google");
        assert_eq!(ffi.sso_providers[1].name, "GitHub");
    }

    #[test]
    fn login_methods_converts_empty_providers() {
        let core = CoreLoginMethods {
            supports_password: true,
            supports_sso: false,
            sso_providers: vec![],
            supports_oidc: false,
        };
        let ffi: LoginMethods = core.into();
        assert!(ffi.supports_password);
        assert!(!ffi.supports_sso);
        assert!(!ffi.supports_oidc);
        assert!(ffi.sso_providers.is_empty());
    }

    // -- UserProfile round-trip --

    #[test]
    fn user_profile_converts_all_fields() {
        let core = CoreUserProfile {
            display_name: Some("Alice".into()),
            avatar_url: Some("mxc://example.com/abc123".into()),
        };
        let ffi: UserProfile = core.into();
        assert_eq!(ffi.display_name.as_deref(), Some("Alice"));
        assert_eq!(ffi.avatar_url.as_deref(), Some("mxc://example.com/abc123"));
    }

    #[test]
    fn user_profile_converts_none_optionals() {
        let core = CoreUserProfile {
            display_name: None,
            avatar_url: None,
        };
        let ffi: UserProfile = core.into();
        assert!(ffi.display_name.is_none());
        assert!(ffi.avatar_url.is_none());
    }

    // -- RecoveryState round-trip --

    #[test]
    fn recovery_state_converts_all_variants() {
        assert_eq!(
            RecoveryState::from(CoreRecoveryState::Unknown),
            RecoveryState::Unknown
        );
        assert_eq!(
            RecoveryState::from(CoreRecoveryState::Enabled),
            RecoveryState::Enabled
        );
        assert_eq!(
            RecoveryState::from(CoreRecoveryState::Disabled),
            RecoveryState::Disabled
        );
        assert_eq!(
            RecoveryState::from(CoreRecoveryState::Incomplete),
            RecoveryState::Incomplete
        );
    }

    // -- Error conversion --

    #[test]
    fn error_converts_all_variants() {
        let cases = vec![
            (
                CoreError::Auth {
                    message: "bad".into(),
                },
                "Auth",
            ),
            (
                CoreError::Network {
                    message: "timeout".into(),
                },
                "Network",
            ),
            (
                CoreError::Room {
                    message: "gone".into(),
                },
                "Room",
            ),
            (
                CoreError::Store {
                    message: "corrupt".into(),
                },
                "Store",
            ),
            (
                CoreError::Sync {
                    message: "failed".into(),
                },
                "Sync",
            ),
            (
                CoreError::Unknown {
                    message: "wat".into(),
                },
                "Unknown",
            ),
        ];

        for (core_err, expected_variant) in cases {
            let msg = match &core_err {
                CoreError::Auth { message } => message.clone(),
                CoreError::Network { message } => message.clone(),
                CoreError::Room { message } => message.clone(),
                CoreError::Store { message } => message.clone(),
                CoreError::Sync { message } => message.clone(),
                CoreError::Unknown { message } => message.clone(),
            };
            let ffi_err: ParlotteError = core_err.into();
            let debug = format!("{:?}", ffi_err);
            assert!(
                debug.contains(expected_variant),
                "expected {expected_variant} in {debug}"
            );
            assert!(debug.contains(&msg), "expected message '{msg}' in {debug}");
        }
    }

    #[test]
    fn error_preserves_message_content() {
        let core = CoreError::Auth {
            message: "invalid credentials for @user:matrix.org".into(),
        };
        let ffi: ParlotteError = core.into();
        assert_eq!(
            ffi.to_string(),
            "authentication failed: invalid credentials for @user:matrix.org"
        );
    }

    // -- OidcSessionData round-trip (carries access + refresh tokens) --

    #[test]
    fn oidc_session_data_round_trips_both_directions() {
        let core = CoreOidcSessionData {
            user_id: "@me:x.com".into(),
            device_id: "DEV".into(),
            access_token: "access-abc".into(),
            refresh_token: Some("refresh-xyz".into()),
            client_id: "client-123".into(),
        };
        let ffi: OidcSessionData = core.clone().into();
        assert_eq!(ffi.user_id, "@me:x.com");
        assert_eq!(ffi.device_id, "DEV");
        assert_eq!(ffi.access_token, "access-abc");
        assert_eq!(ffi.refresh_token.as_deref(), Some("refresh-xyz"));
        assert_eq!(ffi.client_id, "client-123");

        // Round-trip back to core: a field swap here would corrupt persisted
        // sessions, so assert every field survives both directions.
        let back: CoreOidcSessionData = ffi.into();
        assert_eq!(back.user_id, core.user_id);
        assert_eq!(back.device_id, core.device_id);
        assert_eq!(back.access_token, core.access_token);
        assert_eq!(back.refresh_token, core.refresh_token);
        assert_eq!(back.client_id, core.client_id);
    }

    #[test]
    fn oidc_session_data_handles_no_refresh_token() {
        let core = CoreOidcSessionData {
            user_id: "@me:x.com".into(),
            device_id: "DEV".into(),
            access_token: "a".into(),
            refresh_token: None,
            client_id: "c".into(),
        };
        let ffi: OidcSessionData = core.into();
        assert_eq!(ffi.refresh_token, None);
    }

    // -- Verification conversions --

    #[test]
    fn verification_request_info_converts() {
        let core = CoreVerificationRequestInfo {
            flow_id: "flow-1".into(),
            other_user_id: "@other:x.com".into(),
            is_self_verification: true,
            we_started: false,
        };
        let ffi: VerificationRequestInfo = core.into();
        assert_eq!(ffi.flow_id, "flow-1");
        assert_eq!(ffi.other_user_id, "@other:x.com");
        assert!(ffi.is_self_verification);
        assert!(!ffi.we_started);
    }

    #[test]
    fn verification_state_maps_emoji_vector_in_order() {
        let core = CoreVerificationState::SasReadyToCompare {
            emojis: vec![
                CoreEmojiInfo {
                    symbol: "🐶".into(),
                    description: "Dog".into(),
                },
                CoreEmojiInfo {
                    symbol: "🐱".into(),
                    description: "Cat".into(),
                },
            ],
        };
        let ffi: VerificationState = core.into();
        match ffi {
            VerificationState::SasReadyToCompare { emojis } => {
                assert_eq!(emojis.len(), 2);
                assert_eq!(emojis[0].symbol, "🐶");
                assert_eq!(emojis[0].description, "Dog");
                assert_eq!(emojis[1].symbol, "🐱");
            }
            other => panic!("expected SasReadyToCompare, got {other:?}"),
        }
    }

    #[test]
    fn verification_state_maps_simple_variants() {
        assert!(matches!(
            VerificationState::from(CoreVerificationState::Pending),
            VerificationState::Pending
        ));
        assert!(matches!(
            VerificationState::from(CoreVerificationState::Done),
            VerificationState::Done
        ));
        match VerificationState::from(CoreVerificationState::Cancelled {
            reason: "user rejected".into(),
        }) {
            VerificationState::Cancelled { reason } => assert_eq!(reason, "user rejected"),
            other => panic!("expected Cancelled, got {other:?}"),
        }
    }
}
