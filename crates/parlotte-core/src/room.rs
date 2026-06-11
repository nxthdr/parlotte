/// Summary information about a joined or invited room.
#[derive(Debug, Clone)]
pub struct RoomInfo {
    /// The Matrix room ID (e.g., `!abc123:example.com`).
    pub id: String,
    /// Human-readable display name for the room.
    pub display_name: String,
    /// Whether the room has encryption enabled.
    pub is_encrypted: bool,
    /// Whether the room is publicly joinable.
    pub is_public: bool,
    /// Whether the room is a direct message (flagged via `m.direct`).
    pub is_direct: bool,
    /// The topic of the room, if set.
    pub topic: Option<String>,
    /// Whether this is a pending invite (not yet joined).
    pub is_invited: bool,
    /// Number of unread notifications in this room.
    pub unread_count: u64,
}

/// Summary of a room from the public directory.
#[derive(Debug, Clone)]
pub struct PublicRoomInfo {
    /// The Matrix room ID.
    pub id: String,
    /// The room name, if set.
    pub name: Option<String>,
    /// The room topic, if set.
    pub topic: Option<String>,
    /// Number of joined members.
    pub member_count: u64,
    /// The canonical room alias (e.g., `#general:example.com`).
    pub alias: Option<String>,
}

/// Information about a room member.
#[derive(Debug, Clone)]
pub struct RoomMemberInfo {
    /// The Matrix user ID (e.g., `@alice:example.com`).
    pub user_id: String,
    /// Display name, if set.
    pub display_name: Option<String>,
    /// The mxc:// URI of the member's avatar, if set.
    pub avatar_url: Option<String>,
    /// Power level (0-100).
    pub power_level: i64,
    /// Role: "administrator", "moderator", or "member".
    pub role: String,
}

/// A user returned by the homeserver's user-directory search.
#[derive(Debug, Clone)]
pub struct UserSearchResult {
    /// The Matrix user ID (e.g., `@alice:example.com`).
    pub user_id: String,
    /// Display name, if the server exposes one.
    pub display_name: Option<String>,
    /// The mxc:// URI of the user's avatar, if any.
    pub avatar_url: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn room_info_construction() {
        let room = RoomInfo {
            id: "!abc:example.com".into(),
            display_name: "Test Room".into(),
            is_encrypted: true,
            is_public: false,
            is_direct: false,
            topic: Some("A topic".into()),
            is_invited: false,
            unread_count: 0,
        };
        assert_eq!(room.id, "!abc:example.com");
        assert_eq!(room.display_name, "Test Room");
        assert!(room.is_encrypted);
        assert!(!room.is_public);
        assert!(!room.is_direct);
        assert_eq!(room.topic.as_deref(), Some("A topic"));
        assert!(!room.is_invited);
    }

    #[test]
    fn room_info_without_topic() {
        let room = RoomInfo {
            id: "!xyz:example.com".into(),
            display_name: "No Topic".into(),
            is_encrypted: false,
            is_public: true,
            is_direct: true,
            topic: None,
            is_invited: false,
            unread_count: 0,
        };
        assert!(!room.is_encrypted);
        assert!(room.is_public);
        assert!(room.is_direct);
        assert!(room.topic.is_none());
    }

    #[test]
    fn room_info_clone() {
        let room = RoomInfo {
            id: "!abc:example.com".into(),
            display_name: "Cloned".into(),
            is_encrypted: false,
            is_public: false,
            is_direct: false,
            topic: None,
            is_invited: false,
            unread_count: 0,
        };
        let cloned = room.clone();
        assert_eq!(room.id, cloned.id);
        assert_eq!(room.display_name, cloned.display_name);
    }
}
