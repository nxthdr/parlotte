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
    /// Timestamp (ms since the Unix epoch) of the room's latest known event,
    /// used to order the room list most-recent-first. `None` when no event is
    /// known yet (e.g. a fresh invite, or a room not yet hydrated).
    pub last_activity_ts: Option<u64>,
}

/// Sort the room list for display: pending invites first (above everything
/// else), then the remaining rooms most-recent-activity first. Rooms with an
/// unknown last-event timestamp sort last within their group; ties break on
/// room ID so the order is stable across refreshes.
pub(crate) fn sort_rooms_by_recency(rooms: &mut [RoomInfo]) {
    rooms.sort_by(|a, b| {
        // `is_invited` true sorts before false.
        b.is_invited
            .cmp(&a.is_invited)
            .then_with(|| b.last_activity_ts.cmp(&a.last_activity_ts))
            .then_with(|| a.id.cmp(&b.id))
    });
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
            last_activity_ts: Some(1_000),
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
            last_activity_ts: None,
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
            last_activity_ts: None,
        };
        let cloned = room.clone();
        assert_eq!(room.id, cloned.id);
        assert_eq!(room.display_name, cloned.display_name);
    }

    fn room_with(id: &str, last_activity_ts: Option<u64>) -> RoomInfo {
        room_full(id, last_activity_ts, false)
    }

    fn room_full(id: &str, last_activity_ts: Option<u64>, is_invited: bool) -> RoomInfo {
        RoomInfo {
            id: id.into(),
            display_name: id.into(),
            is_encrypted: false,
            is_public: false,
            is_direct: false,
            topic: None,
            is_invited,
            unread_count: 0,
            last_activity_ts,
        }
    }

    #[test]
    fn sort_orders_most_recent_first_with_unknown_last() {
        let mut rooms = vec![
            room_with("!old:x", Some(100)),
            room_with("!none:x", None),
            room_with("!new:x", Some(300)),
            room_with("!mid:x", Some(200)),
        ];
        sort_rooms_by_recency(&mut rooms);
        let order: Vec<&str> = rooms.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(order, ["!new:x", "!mid:x", "!old:x", "!none:x"]);
    }

    #[test]
    fn sort_breaks_ties_by_id_for_stability() {
        let mut rooms = vec![
            room_with("!b:x", Some(100)),
            room_with("!a:x", Some(100)),
            room_with("!d:x", None),
            room_with("!c:x", None),
        ];
        sort_rooms_by_recency(&mut rooms);
        let order: Vec<&str> = rooms.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(order, ["!a:x", "!b:x", "!c:x", "!d:x"]);
    }

    #[test]
    fn sort_pins_invites_above_everything_else() {
        // A very-recent joined room must still sort below any invite, even an
        // invite with no known last-event timestamp.
        let mut rooms = vec![
            room_with("!recent:x", Some(9_999)),
            room_full("!invite-b:x", Some(100), true),
            room_with("!old:x", Some(50)),
            room_full("!invite-a:x", None, true),
        ];
        sort_rooms_by_recency(&mut rooms);
        let order: Vec<&str> = rooms.iter().map(|r| r.id.as_str()).collect();
        // Invites first (most-recent invite first, unknown-ts invite last),
        // then joined rooms by recency.
        assert_eq!(
            order,
            ["!invite-b:x", "!invite-a:x", "!recent:x", "!old:x"]
        );
    }
}
