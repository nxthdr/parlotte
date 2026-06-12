/// A single reaction on a message.
#[derive(Debug, Clone)]
pub struct ReactionInfo {
    /// The event ID of the m.reaction event itself (needed for redaction/toggle).
    pub event_id: String,
    /// The emoji key (e.g. "👍").
    pub key: String,
    /// The sender's Matrix user ID.
    pub sender: String,
}

/// A single message from a room timeline.
#[derive(Debug, Clone)]
pub struct MessageInfo {
    /// Stable identity for this timeline item, used as the UI list key and
    /// scroll anchor. Provided by the matrix-sdk Timeline and preserved across
    /// a local echo's transition to a remote event, so the UI doesn't see the
    /// row re-identify when a sent message is confirmed.
    pub item_id: String,
    /// Send state for local echoes: empty for remote events, otherwise
    /// "sending", "sent", or "failed". The UI uses this to style un-confirmed
    /// messages and to disable actions (reply/edit/react) until the event has
    /// a real ID.
    pub send_state: String,
    /// The Matrix event ID. Empty while a local echo is still being sent.
    pub event_id: String,
    /// The sender's Matrix user ID.
    pub sender: String,
    /// The text body of the message (plain text fallback).
    pub body: String,
    /// HTML-formatted body, if the sender provided one.
    pub formatted_body: Option<String>,
    /// The message type (e.g. "text", "image", "file", "video", "audio", "notice", "emote").
    pub message_type: String,
    /// Unix timestamp in milliseconds when the message was sent (origin server ts).
    pub timestamp_ms: u64,
    /// Whether this message has been edited.
    pub is_edited: bool,
    /// The event ID this message is replying to, if any.
    pub replied_to_event_id: Option<String>,
    /// The mxc:// URI for media messages (image, file, video, audio).
    pub media_source: Option<String>,
    /// MIME type for media messages.
    pub media_mime_type: Option<String>,
    /// Width in pixels for image/video messages.
    pub media_width: Option<u32>,
    /// Height in pixels for image/video messages.
    pub media_height: Option<u32>,
    /// Size in bytes of the media file.
    pub media_size: Option<u64>,
    /// Reactions on this message.
    pub reactions: Vec<ReactionInfo>,
}

/// A batch of messages with a pagination token for loading more.
#[derive(Debug, Clone)]
pub struct MessageBatch {
    /// The messages in this batch (oldest first).
    pub messages: Vec<MessageInfo>,
    /// Opaque token to fetch the next (older) batch. None if no more history.
    pub end_token: Option<String>,
}

/// User profile information (display name and avatar).
#[derive(Debug, Clone)]
pub struct UserProfile {
    /// The user's display name, if set.
    pub display_name: Option<String>,
    /// The mxc:// URI of the user's avatar, if set.
    pub avatar_url: Option<String>,
}

/// An SSO identity provider offered by the homeserver.
#[derive(Debug, Clone)]
pub struct SsoProvider {
    /// The provider's unique ID.
    pub id: String,
    /// Human-readable name for the provider.
    pub name: String,
}

/// Login methods supported by the homeserver.
#[derive(Debug, Clone)]
pub struct LoginMethods {
    /// Whether username/password login is supported.
    pub supports_password: bool,
    /// Whether SSO login is supported.
    pub supports_sso: bool,
    /// Available SSO identity providers (empty if SSO is not supported).
    pub sso_providers: Vec<SsoProvider>,
    /// Whether the server supports native OIDC (MSC3861). When true, prefer
    /// `oidc_login_url` / `oidc_finish_login` over the legacy SSO flow.
    pub supports_oidc: bool,
}

/// Information about the current session.
#[derive(Debug, Clone)]
pub struct SessionInfo {
    /// The authenticated user's Matrix ID.
    pub user_id: String,
    /// The device ID for this session.
    pub device_id: String,
}

/// Full session data needed to restore a previous login.
#[derive(Debug, Clone)]
pub struct MatrixSessionData {
    /// The authenticated user's Matrix ID.
    pub user_id: String,
    /// The device ID for this session.
    pub device_id: String,
    /// The access token for this session.
    pub access_token: String,
}

/// Full OIDC session data needed to restore a previous MSC3861 login.
#[derive(Debug, Clone)]
pub struct OidcSessionData {
    pub user_id: String,
    pub device_id: String,
    pub access_token: String,
    pub refresh_token: Option<String>,
    /// OAuth client ID obtained from dynamic registration.
    pub client_id: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn user_profile_construction() {
        let profile = UserProfile {
            display_name: Some("Alice".into()),
            avatar_url: Some("mxc://example.com/abc123".into()),
        };
        assert_eq!(profile.display_name.as_deref(), Some("Alice"));
        assert_eq!(
            profile.avatar_url.as_deref(),
            Some("mxc://example.com/abc123")
        );
    }

    #[test]
    fn user_profile_empty() {
        let profile = UserProfile {
            display_name: None,
            avatar_url: None,
        };
        assert!(profile.display_name.is_none());
        assert!(profile.avatar_url.is_none());
    }

    #[test]
    fn user_profile_clone() {
        let profile = UserProfile {
            display_name: Some("Bob".into()),
            avatar_url: None,
        };
        let cloned = profile.clone();
        assert_eq!(profile.display_name, cloned.display_name);
        assert_eq!(profile.avatar_url, cloned.avatar_url);
    }

    #[test]
    fn message_info_construction() {
        let msg = MessageInfo {
            item_id: "$event1:example.com".into(),
            send_state: String::new(),
            event_id: "$event1:example.com".into(),
            sender: "@alice:example.com".into(),
            body: "Hello!".into(),
            formatted_body: Some("<b>Hello!</b>".into()),
            message_type: "text".into(),
            timestamp_ms: 1700000000000,
            is_edited: false,
            replied_to_event_id: Some("$parent:example.com".into()),
            media_source: None,
            media_mime_type: None,
            media_width: None,
            media_height: None,
            media_size: None,
            reactions: vec![],
        };
        assert_eq!(msg.event_id, "$event1:example.com");
        assert_eq!(msg.sender, "@alice:example.com");
        assert_eq!(msg.body, "Hello!");
        assert_eq!(msg.formatted_body.as_deref(), Some("<b>Hello!</b>"));
        assert_eq!(msg.message_type, "text");
        assert_eq!(msg.timestamp_ms, 1700000000000);
        assert_eq!(
            msg.replied_to_event_id.as_deref(),
            Some("$parent:example.com")
        );
    }

    #[test]
    fn message_info_clone() {
        let msg = MessageInfo {
            item_id: "$e:x.com".into(),
            send_state: String::new(),
            event_id: "$e:x.com".into(),
            sender: "@a:x.com".into(),
            body: "hi".into(),
            formatted_body: None,
            message_type: "text".into(),
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
        let cloned = msg.clone();
        assert_eq!(msg.body, cloned.body);
        assert_eq!(msg.timestamp_ms, cloned.timestamp_ms);
    }

    #[test]
    fn session_info_construction() {
        let session = SessionInfo {
            user_id: "@alice:example.com".into(),
            device_id: "DEVICEABC".into(),
        };
        assert_eq!(session.user_id, "@alice:example.com");
        assert_eq!(session.device_id, "DEVICEABC");
    }

    #[test]
    fn session_info_clone() {
        let session = SessionInfo {
            user_id: "@bob:example.com".into(),
            device_id: "DEV123".into(),
        };
        let cloned = session.clone();
        assert_eq!(session.user_id, cloned.user_id);
        assert_eq!(session.device_id, cloned.device_id);
    }

    #[test]
    fn matrix_session_data_construction() {
        let data = MatrixSessionData {
            user_id: "@alice:example.com".into(),
            device_id: "DEVICEABC".into(),
            access_token: "syt_token_123".into(),
        };
        assert_eq!(data.user_id, "@alice:example.com");
        assert_eq!(data.device_id, "DEVICEABC");
        assert_eq!(data.access_token, "syt_token_123");
    }

    #[test]
    fn matrix_session_data_clone() {
        let data = MatrixSessionData {
            user_id: "@bob:example.com".into(),
            device_id: "DEV456".into(),
            access_token: "tok".into(),
        };
        let cloned = data.clone();
        assert_eq!(data.user_id, cloned.user_id);
        assert_eq!(data.device_id, cloned.device_id);
        assert_eq!(data.access_token, cloned.access_token);
    }
}
