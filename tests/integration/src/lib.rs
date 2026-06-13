/// Integration tests for parlotte-core.
/// These tests require a running Synapse server (see docker-compose.yml).
///
/// Run with: cargo test -p parlotte-integration
///
/// The tests use the Synapse registration API to create fresh users for each
/// test, so they are fully isolated and can run in parallel.

#[cfg(test)]
mod tests {
    use parlotte_core::ParlotteClient;
    use serde::Deserialize;
    use std::sync::atomic::{AtomicU32, Ordering};

    const HOMESERVER_URL: &str = "http://localhost:8008";

    static USER_COUNTER: AtomicU32 = AtomicU32::new(0);

    /// Generate a unique username for each test to avoid conflicts.
    fn unique_username(prefix: &str) -> String {
        let id = USER_COUNTER.fetch_add(1, Ordering::SeqCst);
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis();
        format!("{prefix}_{id}_{ts}")
    }

    #[derive(Deserialize)]
    struct RegisterResponse {
        user_id: String,
    }

    /// Register a user via Synapse's registration API and return a logged-in ParlotteClient.
    fn register_and_login(prefix: &str) -> (ParlotteClient, String) {
        let username = unique_username(prefix);
        let password = "test-password-123";

        // Register via the Matrix client API (open registration is enabled)
        let rt = tokio::runtime::Runtime::new().unwrap();
        let user_id = rt.block_on(async {
            let client = reqwest::Client::new();
            let resp = client
                .post(format!("{HOMESERVER_URL}/_matrix/client/v3/register"))
                .json(&serde_json::json!({
                    "username": username,
                    "password": password,
                    "auth": {
                        "type": "m.login.dummy"
                    }
                }))
                .send()
                .await
                .expect("failed to send registration request");

            let status = resp.status();
            let body = resp.text().await.unwrap();
            assert!(
                status.is_success(),
                "registration failed ({status}): {body}"
            );

            let reg: RegisterResponse = serde_json::from_str(&body).unwrap();
            reg.user_id
        });
        drop(rt);

        // Now create a ParlotteClient and login
        let client =
            ParlotteClient::new(HOMESERVER_URL, None).expect("failed to create parlotte client");
        let session = client
            .login(&username, password)
            .expect("login failed after registration");

        assert_eq!(session.user_id, user_id);
        assert!(!session.device_id.is_empty());

        (client, user_id)
    }

    /// Check if Synapse is reachable. Panics if not.
    fn require_synapse() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let reachable = rt.block_on(async {
            reqwest::get(format!("{HOMESERVER_URL}/health"))
                .await
                .map(|r| r.status().is_success())
                .unwrap_or(false)
        });
        drop(rt);

        if !reachable {
            panic!(
                "Synapse not reachable at {HOMESERVER_URL}. \
                 Start it with: docker compose -f tests/integration/docker-compose.yml up -d"
            );
        }
    }

    // -- Test: Login with valid credentials --

    #[test]
    fn login_with_valid_credentials() {
        require_synapse();
        let (client, user_id) = register_and_login("login_valid");

        // Verify session info
        assert!(user_id.starts_with('@'));
        assert!(user_id.contains(":parlotte.test"));

        // Rooms should be empty for a fresh user
        let rooms = client.rooms().unwrap();
        assert!(rooms.is_empty());
    }

    // -- Test: Login with invalid credentials --

    #[test]
    fn login_with_invalid_credentials() {
        require_synapse();

        let client = ParlotteClient::new(HOMESERVER_URL, None).unwrap();
        let result = client.login("nonexistent_user_xyz", "wrong_password");

        assert!(result.is_err());
        match result.unwrap_err() {
            parlotte_core::ParlotteError::Auth { message } => {
                assert!(!message.is_empty());
            }
            other => panic!("expected Auth error, got: {other}"),
        }
    }

    // -- Test: Create room and list rooms --

    #[test]
    fn create_room_and_list() {
        require_synapse();
        let (client, _) = register_and_login("create_room");

        // Create a room
        let room_id = client.create_room("Test Room", false).unwrap();
        assert!(room_id.starts_with('!'));
        assert!(room_id.contains(":parlotte.test"));

        // Sync to pick up the room
        client.sync_once().unwrap();

        // List rooms — should contain our new room
        let rooms = client.rooms().unwrap();
        assert_eq!(rooms.len(), 1);
        assert_eq!(rooms[0].id, room_id);
        assert_eq!(rooms[0].display_name, "Test Room");
        // Note: modern Synapse enables encryption by default for new rooms
    }

    // -- Test: Two users send and receive messages --

    #[test]
    fn two_users_messaging() {
        require_synapse();
        let (alice, _alice_id) = register_and_login("alice");
        let (bob, bob_id) = register_and_login("bob");

        // Alice creates a room and invites Bob
        let room_id = alice.create_room("Chat Room", false).unwrap();
        alice.sync_once().unwrap();
        alice.invite_user(&room_id, &bob_id).unwrap();

        // Bob syncs to see the invite
        bob.sync_once().unwrap();

        // Verify the invited room appears in Bob's room list
        let bob_rooms = bob.rooms().unwrap();
        let invited = bob_rooms.iter().find(|r| r.id == room_id);
        assert!(invited.is_some(), "Bob should see the invited room");
        assert!(
            invited.unwrap().is_invited,
            "Room should be marked as invited"
        );

        bob.join_room(&room_id).unwrap();

        // Both sync to see Bob's join
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // After joining, room should no longer be marked as invited
        let bob_rooms = bob.rooms().unwrap();
        let joined = bob_rooms.iter().find(|r| r.id == room_id);
        assert!(
            joined.is_some(),
            "Bob should still see the room after joining"
        );
        assert!(
            !joined.unwrap().is_invited,
            "Room should not be marked as invited after joining"
        );

        // Alice sends a message
        alice.send_message(&room_id, "Hello Bob!").unwrap();

        // Both sync to receive the message
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Verify both users see the room
        let alice_rooms = alice.rooms().unwrap();
        let bob_rooms = bob.rooms().unwrap();
        assert!(alice_rooms.iter().any(|r| r.id == room_id));
        assert!(bob_rooms.iter().any(|r| r.id == room_id));

        // Verify Alice's message is visible to both users
        let alice_msgs = alice.messages(&room_id, 50, None).unwrap().messages;
        let bob_msgs = bob.messages(&room_id, 50, None).unwrap().messages;

        assert!(
            alice_msgs.iter().any(|m| m.body == "Hello Bob!"),
            "Alice should see her own message"
        );
        assert!(
            bob_msgs.iter().any(|m| m.body == "Hello Bob!"),
            "Bob should see Alice's message"
        );
    }

    // -- Test: Multi-message conversation between two users --

    #[test]
    fn two_users_conversation() {
        require_synapse();
        let (alice, _alice_id) = register_and_login("conv_alice");
        let (bob, bob_id) = register_and_login("conv_bob");

        // Alice creates a room and invites Bob
        let room_id = alice.create_room("Conversation", false).unwrap();
        alice.sync_once().unwrap();
        alice.invite_user(&room_id, &bob_id).unwrap();

        bob.sync_once().unwrap();
        bob.join_room(&room_id).unwrap();

        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Exchange several messages
        alice
            .send_message(&room_id, "Hey Bob, how are you?")
            .unwrap();
        bob.sync_once().unwrap();

        bob.send_message(&room_id, "I'm good Alice! You?").unwrap();
        alice.sync_once().unwrap();

        alice.send_message(&room_id, "Great, thanks!").unwrap();
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Both should see all three messages
        let alice_msgs = alice.messages(&room_id, 50, None).unwrap().messages;
        let bob_msgs = bob.messages(&room_id, 50, None).unwrap().messages;

        let expected = [
            "Hey Bob, how are you?",
            "I'm good Alice! You?",
            "Great, thanks!",
        ];
        for body in &expected {
            assert!(
                alice_msgs.iter().any(|m| m.body == *body),
                "Alice missing message: {body}"
            );
            assert!(
                bob_msgs.iter().any(|m| m.body == *body),
                "Bob missing message: {body}"
            );
        }

        // Messages should be ordered by timestamp (oldest first)
        let alice_texts: Vec<&str> = alice_msgs.iter().map(|m| m.body.as_str()).collect();
        assert_eq!(
            alice_texts.iter().position(|b| *b == expected[0]).unwrap()
                < alice_texts.iter().position(|b| *b == expected[1]).unwrap(),
            true,
            "Messages should be in chronological order"
        );
    }

    // -- Test: Room display name resolution --

    #[test]
    fn room_display_name() {
        require_synapse();
        let (client, _) = register_and_login("display_name");

        // Create rooms with different names
        let room1_id = client.create_room("Living Room", false).unwrap();
        let room2_id = client.create_room("Kitchen", false).unwrap();

        client.sync_once().unwrap();

        let rooms = client.rooms().unwrap();
        assert_eq!(rooms.len(), 2);

        let room1 = rooms.iter().find(|r| r.id == room1_id).unwrap();
        let room2 = rooms.iter().find(|r| r.id == room2_id).unwrap();

        assert_eq!(room1.display_name, "Living Room");
        assert_eq!(room2.display_name, "Kitchen");
    }

    // -- Test: Leave room --

    #[test]
    fn leave_room() {
        require_synapse();
        let (client, _) = register_and_login("leave");

        let room_id = client.create_room("Goodbye Room", false).unwrap();
        client.sync_once().unwrap();
        assert_eq!(client.rooms().unwrap().len(), 1);

        client.leave_room(&room_id).unwrap();
        client.sync_once().unwrap();
        assert_eq!(client.rooms().unwrap().len(), 0);
    }

    // -- Test: Room members --

    #[test]
    fn room_members_list() {
        require_synapse();
        let (alice, _alice_id) = register_and_login("members_alice");
        let (bob, bob_id) = register_and_login("members_bob");

        // Alice creates a room and invites Bob
        let room_id = alice.create_room("Members Test", false).unwrap();
        alice.sync_once().unwrap();
        alice.invite_user(&room_id, &bob_id).unwrap();

        bob.sync_once().unwrap();
        bob.join_room(&room_id).unwrap();
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Alice should see both members
        let members = alice.room_members(&room_id).unwrap();
        assert_eq!(members.len(), 2, "Room should have 2 members");

        // Alice is the creator, should be admin
        let alice_member = members.iter().find(|m| m.user_id == _alice_id).unwrap();
        assert_eq!(alice_member.role, "admin");

        // Bob is a regular member
        let bob_member = members.iter().find(|m| m.user_id == bob_id).unwrap();
        assert_eq!(bob_member.role, "member");
    }

    // -- Test: Multiple syncs are idempotent --

    #[test]
    fn multiple_syncs_idempotent() {
        require_synapse();
        let (client, _) = register_and_login("multi_sync");

        client.create_room("Stable Room", false).unwrap();

        // Sync multiple times — room count should stay at 1
        client.sync_once().unwrap();
        client.sync_once().unwrap();
        client.sync_once().unwrap();

        let rooms = client.rooms().unwrap();
        assert_eq!(rooms.len(), 1);
    }

    // -- Test: Invite with persistent store --

    #[test]
    fn invite_visible_with_persistent_store() {
        require_synapse();

        let alice_user = unique_username("store_alice");
        let bob_user = unique_username("store_bob");
        let password = "test-password-123";

        // Register both users
        let rt = tokio::runtime::Runtime::new().unwrap();
        let (_alice_id, bob_id) = rt.block_on(async {
            let http = reqwest::Client::new();
            let a = http.post(format!("{HOMESERVER_URL}/_matrix/client/v3/register"))
                .json(&serde_json::json!({"username": alice_user, "password": password, "auth": {"type": "m.login.dummy"}}))
                .send().await.unwrap().json::<RegisterResponse>().await.unwrap();
            let b = http.post(format!("{HOMESERVER_URL}/_matrix/client/v3/register"))
                .json(&serde_json::json!({"username": bob_user, "password": password, "auth": {"type": "m.login.dummy"}}))
                .send().await.unwrap().json::<RegisterResponse>().await.unwrap();
            (a.user_id, b.user_id)
        });
        drop(rt);

        // Create clients with persistent stores (like the app does)
        let alice_store = format!("{}/alice_store", std::env::temp_dir().display());
        let bob_store = format!("{}/bob_store", std::env::temp_dir().display());
        let _ = std::fs::remove_dir_all(&alice_store);
        let _ = std::fs::remove_dir_all(&bob_store);

        let alice = ParlotteClient::new(HOMESERVER_URL, Some(&alice_store)).unwrap();
        alice.login(&alice_user, password).unwrap();
        alice.sync_once().unwrap();

        let bob = ParlotteClient::new(HOMESERVER_URL, Some(&bob_store)).unwrap();
        bob.login(&bob_user, password).unwrap();
        bob.sync_once().unwrap();

        // Bob has no rooms yet
        let bob_rooms = bob.rooms().unwrap();
        assert_eq!(bob_rooms.len(), 0, "Bob should start with no rooms");

        // Alice creates a private room and invites Bob
        let room_id = alice.create_room("StoreTest", false).unwrap();
        alice.sync_once().unwrap();
        alice.invite_user(&room_id, &bob_id).unwrap();

        // Bob syncs — should see the invite
        bob.sync_once().unwrap();
        let bob_rooms = bob.rooms().unwrap();
        let invited = bob_rooms
            .iter()
            .filter(|r| r.is_invited)
            .collect::<Vec<_>>();
        assert_eq!(
            invited.len(),
            1,
            "Bob should see 1 invited room, got {}",
            invited.len()
        );
        assert_eq!(invited[0].id, room_id);

        // Cleanup
        let _ = std::fs::remove_dir_all(&alice_store);
        let _ = std::fs::remove_dir_all(&bob_store);
    }

    // -- Test: Message editing --

    #[test]
    fn edit_message() {
        require_synapse();
        let (alice, _) = register_and_login("edit_alice");

        let room_id = alice.create_room("Edit Test", false).unwrap();
        alice.sync_once().unwrap();

        alice.send_message(&room_id, "Original message").unwrap();
        alice.sync_once().unwrap();

        let msgs = alice.messages(&room_id, 50, None).unwrap().messages;
        let event_id = &msgs
            .iter()
            .find(|m| m.body == "Original message")
            .unwrap()
            .event_id;

        alice
            .edit_message(&room_id, event_id, "Edited message")
            .unwrap();
        alice.sync_once().unwrap();

        let msgs = alice.messages(&room_id, 50, None).unwrap().messages;
        let edited = msgs.iter().find(|m| m.event_id == *event_id).unwrap();
        assert_eq!(edited.body, "Edited message");
        assert!(edited.is_edited, "Message should be marked as edited");
    }

    // -- Test: A cross-sender edit must not rewrite another user's message --

    #[test]
    fn edit_from_other_user_is_ignored() {
        require_synapse();
        let (alice, _alice_id) = register_and_login("spoof_alice");
        let (bob, bob_id) = register_and_login("spoof_bob");

        let room_id = alice.create_room("Spoof Test", true).unwrap();
        alice.sync_once().unwrap();
        alice.invite_user(&room_id, &bob_id).unwrap();
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();
        bob.join_room(&room_id).unwrap();
        bob.sync_once().unwrap();

        alice.send_message(&room_id, "Alice's message").unwrap();
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Bob locates Alice's event. Our own edit_message refuses to edit
        // another user's event, so simulate a malicious client by sending a
        // raw m.replace authored by Bob that targets Alice's event over the
        // Matrix client API directly.
        let msgs = bob.messages(&room_id, 50, None).unwrap().messages;
        let target = msgs
            .iter()
            .find(|m| m.body == "Alice's message")
            .expect("bob should see alice's message");
        let bob_token = bob.session().expect("bob session").access_token;

        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let http = reqwest::Client::new();
            let url = format!(
                "{HOMESERVER_URL}/_matrix/client/v3/rooms/{room_id}/send/m.room.message/spoof_txn_1"
            );
            let resp = http
                .put(&url)
                .bearer_auth(&bob_token)
                .json(&serde_json::json!({
                    "msgtype": "m.text",
                    "body": "* Bob's spoofed edit",
                    "m.new_content": {
                        "msgtype": "m.text",
                        "body": "Bob's spoofed edit"
                    },
                    "m.relates_to": {
                        "rel_type": "m.replace",
                        "event_id": target.event_id
                    }
                }))
                .send()
                .await
                .expect("send raw replace");
            assert!(
                resp.status().is_success(),
                "raw m.replace send failed: {}",
                resp.text().await.unwrap_or_default()
            );
        });
        drop(rt);

        alice.sync_once().unwrap();

        // Alice's client must still show the original text, unedited — the
        // cross-sender replacement must be rejected at aggregation time.
        let msgs = alice.messages(&room_id, 50, None).unwrap().messages;
        let original = msgs
            .iter()
            .find(|m| m.event_id == target.event_id)
            .expect("alice's event should still be present");
        assert_eq!(
            original.body, "Alice's message",
            "cross-sender edit must not rewrite the message"
        );
        assert!(
            !original.is_edited,
            "cross-sender edit must not flag the message as edited"
        );
    }

    // -- Test: Message deletion (redaction) --

    #[test]
    fn redact_message() {
        require_synapse();
        let (alice, _) = register_and_login("redact_alice");

        let room_id = alice.create_room("Redact Test", false).unwrap();
        alice.sync_once().unwrap();

        alice.send_message(&room_id, "Delete me").unwrap();
        alice.sync_once().unwrap();

        let msgs = alice.messages(&room_id, 50, None).unwrap().messages;
        assert!(msgs.iter().any(|m| m.body == "Delete me"));
        let event_id = &msgs
            .iter()
            .find(|m| m.body == "Delete me")
            .unwrap()
            .event_id;

        alice.redact_message(&room_id, event_id).unwrap();
        alice.sync_once().unwrap();

        let msgs = alice.messages(&room_id, 50, None).unwrap().messages;
        assert!(
            !msgs.iter().any(|m| m.body == "Delete me"),
            "Redacted message should not appear"
        );
    }

    // -- Test: Unread count and read receipts --

    #[test]
    fn unread_count_and_read_receipt() {
        require_synapse();
        let (alice, _alice_id) = register_and_login("unread_alice");
        let (bob, bob_id) = register_and_login("unread_bob");

        // Alice creates a room and invites Bob
        let room_id = alice.create_room("Unread Test", false).unwrap();
        alice.sync_once().unwrap();
        alice.invite_user(&room_id, &bob_id).unwrap();

        bob.sync_once().unwrap();
        bob.join_room(&room_id).unwrap();
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Alice sends a message
        alice.send_message(&room_id, "Unread message").unwrap();
        bob.sync_once().unwrap();

        // Bob should have unread notifications
        let bob_rooms = bob.rooms().unwrap();
        let room = bob_rooms.iter().find(|r| r.id == room_id).unwrap();
        assert!(
            room.unread_count > 0,
            "Bob should have unread notifications"
        );

        // Bob reads the messages and sends a read receipt
        let bob_msgs = bob.messages(&room_id, 50, None).unwrap().messages;
        let last_event_id = &bob_msgs.last().unwrap().event_id;
        bob.send_read_receipt(&room_id, last_event_id).unwrap();
        // With the event cache enabled (required by the Timeline API), the
        // computed unread count clears once the public read receipt has
        // round-tripped through sync — one extra sync cycle, which the app's
        // continuous sync loop performs automatically. A single sync_once can
        // observe the receipt mid-flight, so settle over two cycles.
        bob.sync_once().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(500));
        bob.sync_once().unwrap();

        // After the read receipt settles, the unread count should be 0
        let bob_rooms = bob.rooms().unwrap();
        let room = bob_rooms.iter().find(|r| r.id == room_id).unwrap();
        assert_eq!(
            room.unread_count, 0,
            "Unread count should be 0 after read receipt"
        );
    }

    // -- Test: Public room discovery and join --

    #[test]
    fn public_room_discovery_and_join() {
        require_synapse();
        let (alice, _) = register_and_login("pub_alice");
        let (bob, _) = register_and_login("pub_bob");

        // Alice creates a public room
        let room_id = alice.create_room("Public Lounge", true).unwrap();
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Bob discovers it via the directory
        let public = bob.public_rooms().unwrap();
        assert!(
            public.iter().any(|r| r.id == room_id),
            "Public room should appear in directory"
        );

        let found = public.iter().find(|r| r.id == room_id).unwrap();
        assert_eq!(found.name.as_deref(), Some("Public Lounge"));

        // Bob joins the public room (no invite needed)
        bob.join_room(&room_id).unwrap();
        bob.sync_once().unwrap();

        let bob_rooms = bob.rooms().unwrap();
        assert!(bob_rooms.iter().any(|r| r.id == room_id));

        // Both can exchange messages
        alice.send_message(&room_id, "Welcome!").unwrap();
        bob.sync_once().unwrap();

        let msgs = bob.messages(&room_id, 50, None).unwrap().messages;
        assert!(msgs.iter().any(|m| m.body == "Welcome!"));
    }

    #[test]
    fn message_pagination() {
        require_synapse();
        let (alice, _) = register_and_login("page_alice");

        let room_id = alice.create_room("Pagination Test", false).unwrap();
        alice.sync_once().unwrap();

        // Send 8 messages
        for i in 1..=8 {
            alice.send_message(&room_id, &format!("msg-{i}")).unwrap();
        }
        alice.sync_once().unwrap();

        // Fetch first batch (limit 3) — should get the 3 most recent (6, 7, 8)
        let batch1 = alice.messages(&room_id, 3, None).unwrap();
        assert_eq!(batch1.messages.len(), 3);
        // Messages should be oldest-first within the batch
        assert_eq!(batch1.messages[0].body, "msg-6");
        assert_eq!(batch1.messages[1].body, "msg-7");
        assert_eq!(batch1.messages[2].body, "msg-8");
        assert!(
            batch1.end_token.is_some(),
            "Should have a pagination token for more messages"
        );

        // Verify chronological order (timestamps non-decreasing)
        for w in batch1.messages.windows(2) {
            assert!(
                w[0].timestamp_ms <= w[1].timestamp_ms,
                "Messages should be in chronological order"
            );
        }

        // Fetch second batch using the pagination token
        let batch2 = alice
            .messages(&room_id, 3, batch1.end_token.as_deref())
            .unwrap();
        assert_eq!(batch2.messages.len(), 3);
        assert_eq!(batch2.messages[0].body, "msg-3");
        assert_eq!(batch2.messages[1].body, "msg-4");
        assert_eq!(batch2.messages[2].body, "msg-5");

        // Second batch should be older than first batch
        assert!(
            batch2.messages.last().unwrap().timestamp_ms
                <= batch1.messages.first().unwrap().timestamp_ms,
            "Second batch should be older than first batch"
        );

        // Fetch third batch
        let batch3 = alice
            .messages(&room_id, 3, batch2.end_token.as_deref())
            .unwrap();
        // Should get remaining messages (msg-1, msg-2, and possibly room creation event)
        assert!(
            batch3.messages.iter().any(|m| m.body == "msg-1"),
            "Third batch should contain msg-1"
        );
        assert!(
            batch3.messages.iter().any(|m| m.body == "msg-2"),
            "Third batch should contain msg-2"
        );
    }

    // -- Test: Reply to a message --

    #[test]
    fn reply_to_message() {
        require_synapse();
        let (alice, _alice_id) = register_and_login("reply_alice");
        let (bob, bob_id) = register_and_login("reply_bob");

        // Alice creates a room and invites Bob
        let room_id = alice.create_room("Reply Test", false).unwrap();
        alice.sync_once().unwrap();
        alice.invite_user(&room_id, &bob_id).unwrap();
        bob.sync_once().unwrap();
        bob.join_room(&room_id).unwrap();
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Alice sends the original message
        alice.send_message(&room_id, "Original message").unwrap();
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Bob finds the original message's event ID
        let bob_msgs = bob.messages(&room_id, 50, None).unwrap().messages;
        let original = bob_msgs
            .iter()
            .find(|m| m.body == "Original message")
            .expect("Bob should see Alice's original message");
        let original_event_id = original.event_id.clone();
        assert!(
            original.replied_to_event_id.is_none(),
            "Original message should not be a reply"
        );

        // Bob replies to Alice's message
        bob.send_reply(&room_id, &original_event_id, "This is a reply")
            .unwrap();
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Both users should see the reply with the correct replied_to_event_id
        let alice_msgs = alice.messages(&room_id, 50, None).unwrap().messages;
        let alice_reply = alice_msgs
            .iter()
            .find(|m| m.body == "This is a reply")
            .expect("Alice should see Bob's reply");
        assert_eq!(
            alice_reply.replied_to_event_id.as_deref(),
            Some(original_event_id.as_str()),
            "Reply should reference the original message"
        );

        let bob_msgs = bob.messages(&room_id, 50, None).unwrap().messages;
        let bob_reply = bob_msgs
            .iter()
            .find(|m| m.body == "This is a reply")
            .expect("Bob should see his own reply");
        assert_eq!(
            bob_reply.replied_to_event_id.as_deref(),
            Some(original_event_id.as_str()),
            "Reply should reference the original message for Bob too"
        );
    }

    // -- Test: Typing indicators between two users --

    #[test]
    fn typing_indicator_between_users() {
        require_synapse();
        let (alice, alice_id) = register_and_login("typing_alice");
        let (bob, bob_id) = register_and_login("typing_bob");

        // Alice creates a room and invites Bob
        let room_id = alice.create_room("Typing Test", false).unwrap();
        alice.sync_once().unwrap();
        alice.invite_user(&room_id, &bob_id).unwrap();

        bob.sync_once().unwrap();
        bob.join_room(&room_id).unwrap();
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Alice starts typing
        alice.send_typing_notice(&room_id, true).unwrap();

        // Bob syncs with a listener that captures typing updates
        let typing_updates: std::sync::Arc<std::sync::Mutex<Vec<(String, Vec<String>)>>> =
            std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));

        struct TypingListener {
            updates: std::sync::Arc<std::sync::Mutex<Vec<(String, Vec<String>)>>>,
        }
        impl parlotte_core::SyncListener for TypingListener {
            fn on_sync_update(&self) {}
            fn on_typing_update(&self, room_id: String, user_ids: Vec<String>) {
                self.updates.lock().unwrap().push((room_id, user_ids));
            }
        }

        let listener = std::sync::Arc::new(TypingListener {
            updates: typing_updates.clone(),
        });

        // Start sync for Bob and wait for typing to arrive
        bob.start_sync(listener).unwrap();

        // Wait up to 10 seconds for a typing update
        let start = std::time::Instant::now();
        let mut found_typing = false;
        while start.elapsed() < std::time::Duration::from_secs(10) {
            let updates = typing_updates.lock().unwrap();
            if updates
                .iter()
                .any(|(rid, uids)| *rid == room_id && uids.contains(&alice_id))
            {
                found_typing = true;
                break;
            }
            drop(updates);
            std::thread::sleep(std::time::Duration::from_millis(200));
        }

        bob.stop_sync();

        assert!(
            found_typing,
            "Bob should have received a typing update showing Alice is typing"
        );
    }

    // -- Test: Persistent sync loop start -> callback -> stop --

    #[test]
    fn persistent_sync_loop_lifecycle() {
        use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

        require_synapse();
        let (alice, _alice_id) = register_and_login("syncloop_alice");
        let (bob, bob_id) = register_and_login("syncloop_bob");

        let room_id = alice.create_room("Sync Loop", false).unwrap();
        alice.sync_once().unwrap();
        alice.invite_user(&room_id, &bob_id).unwrap();
        bob.sync_once().unwrap();
        bob.join_room(&room_id).unwrap();
        bob.sync_once().unwrap();

        struct CountingListener {
            updates: Arc<AtomicU32>,
            stopped: Arc<AtomicBool>,
            stopped_error: Arc<std::sync::Mutex<Option<String>>>,
        }
        impl parlotte_core::SyncListener for CountingListener {
            fn on_sync_update(&self) {
                self.updates.fetch_add(1, Ordering::SeqCst);
            }
            fn on_sync_stopped(&self, error: Option<String>) {
                *self.stopped_error.lock().unwrap() = error;
                self.stopped.store(true, Ordering::SeqCst);
            }
        }
        use std::sync::Arc;

        let updates = Arc::new(AtomicU32::new(0));
        let stopped = Arc::new(AtomicBool::new(false));
        let stopped_error = Arc::new(std::sync::Mutex::new(None));
        let listener = Arc::new(CountingListener {
            updates: updates.clone(),
            stopped: stopped.clone(),
            stopped_error: stopped_error.clone(),
        });

        bob.start_sync(listener).unwrap();
        assert!(bob.is_syncing(), "is_syncing should be true after start");

        // Drive at least one sync response: Alice sends a message.
        alice.send_message(&room_id, "wake up bob").unwrap();

        let start = std::time::Instant::now();
        while start.elapsed() < std::time::Duration::from_secs(10) {
            if updates.load(Ordering::SeqCst) > 0 {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(200));
        }
        assert!(
            updates.load(Ordering::SeqCst) > 0,
            "on_sync_update should have fired at least once"
        );

        bob.stop_sync();

        // After a clean stop the loop must report stopped with no error and
        // is_syncing must be false; no further updates should accumulate.
        let start = std::time::Instant::now();
        while start.elapsed() < std::time::Duration::from_secs(5) {
            if stopped.load(Ordering::SeqCst) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        assert!(!bob.is_syncing(), "is_syncing should be false after stop");
        assert!(
            stopped.load(Ordering::SeqCst),
            "on_sync_stopped should fire on a clean stop"
        );
        assert!(
            stopped_error.lock().unwrap().is_none(),
            "a clean stop must report no error"
        );

        let after_stop = updates.load(Ordering::SeqCst);
        alice.send_message(&room_id, "are you there").unwrap();
        std::thread::sleep(std::time::Duration::from_secs(2));
        assert_eq!(
            updates.load(Ordering::SeqCst),
            after_stop,
            "no sync updates should fire after stop"
        );
    }

    // -- Test: Create a direct message (m.direct, encrypted, is_direct) --

    #[test]
    fn create_direct_message() {
        require_synapse();
        let (alice, _alice_id) = register_and_login("dm_alice");
        let (bob, bob_id) = register_and_login("dm_bob");

        let room_id = alice.create_dm(&bob_id).unwrap();
        alice.sync_once().unwrap();

        // The room must be flagged as a direct message and encrypted.
        let rooms = alice.rooms().unwrap();
        let dm = rooms
            .iter()
            .find(|r| r.id == room_id)
            .expect("DM should appear in alice's room list");
        assert!(dm.is_direct, "DM must be flagged m.direct");
        assert!(dm.is_encrypted, "DM should be encrypted by default");

        // Bob should receive the invite to the DM.
        bob.sync_once().unwrap();
        let bob_rooms = bob.rooms().unwrap();
        assert!(
            bob_rooms.iter().any(|r| r.id == room_id),
            "bob should see the DM invite"
        );
    }

    // -- Test: Creating a DM twice reuses the same room (no duplicate) --

    #[test]
    fn create_dm_twice_reuses_room() {
        require_synapse();
        let (alice, _alice_id) = register_and_login("dmdup_alice");
        let (_bob, bob_id) = register_and_login("dmdup_bob");

        let first = alice.create_dm(&bob_id).unwrap();
        alice.sync_once().unwrap();
        // A second create for the same user must return the existing DM, not a
        // new room.
        let second = alice.create_dm(&bob_id).unwrap();
        assert_eq!(
            first, second,
            "second create_dm should reuse the existing DM"
        );
    }

    // -- Test: User directory search finds a registered user --

    #[test]
    fn search_users_finds_registered_user() {
        require_synapse();
        // Register the searchee with a distinctive localpart so the directory
        // match is unambiguous.
        let (target, target_id) = register_and_login("searchtarget");
        target.sync_once().unwrap();

        let (searcher, _id) = register_and_login("searcher");

        // The user directory is populated by a background process, so retry a
        // few times to absorb indexing lag.
        let mut found = false;
        for _ in 0..10 {
            let results = searcher.search_users("searchtarget", 10).unwrap();
            if results.iter().any(|u| u.user_id == target_id) {
                found = true;
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
        assert!(found, "search should find the registered target user");
    }

    // -- Test: Dropping the client with sync active must not abort --

    #[test]
    fn dropping_client_with_active_sync_does_not_panic() {
        use std::sync::Arc;
        require_synapse();
        let (client, _id) = register_and_login("drop_active_sync");

        struct NoopListener;
        impl parlotte_core::SyncListener for NoopListener {
            fn on_sync_update(&self) {}
        }

        client.sync_once().unwrap();
        client.start_sync(Arc::new(NoopListener)).unwrap();
        // Let the loop get in-flight (so its Client clone is live).
        std::thread::sleep(std::time::Duration::from_millis(500));

        // Drop WITHOUT calling stop_sync() — this is the teardown path that
        // aborted the process: the SQLite store was dropped after the runtime,
        // outside a reactor. If Drop panics/aborts, the test process dies and
        // the test fails; reaching the assert means teardown was clean.
        drop(client);
        assert!(true, "client dropped with active sync without aborting");
    }

    // -- Test: Restarting sync does not leave a second loop running --

    #[test]
    fn restart_sync_does_not_duplicate_loop() {
        use std::sync::atomic::{AtomicU32, Ordering};
        use std::sync::Arc;

        require_synapse();
        let (alice, _alice_id) = register_and_login("syncrestart_alice");
        let (bob, bob_id) = register_and_login("syncrestart_bob");

        let room_id = alice.create_room("Restart", false).unwrap();
        alice.sync_once().unwrap();
        alice.invite_user(&room_id, &bob_id).unwrap();
        bob.sync_once().unwrap();
        bob.join_room(&room_id).unwrap();
        bob.sync_once().unwrap();

        struct CountingListener {
            updates: Arc<AtomicU32>,
        }
        impl parlotte_core::SyncListener for CountingListener {
            fn on_sync_update(&self) {
                self.updates.fetch_add(1, Ordering::SeqCst);
            }
        }

        // First generation, then immediately restart (the logout/login shape
        // that previously spawned a second concurrent loop).
        let first = Arc::new(AtomicU32::new(0));
        bob.start_sync(Arc::new(CountingListener {
            updates: first.clone(),
        }))
        .unwrap();

        let second = Arc::new(AtomicU32::new(0));
        bob.start_sync(Arc::new(CountingListener {
            updates: second.clone(),
        }))
        .unwrap();

        // Let the surviving loop settle, then drive a single message.
        std::thread::sleep(std::time::Duration::from_secs(1));
        let first_baseline = first.load(Ordering::SeqCst);
        alice.send_message(&room_id, "single delivery").unwrap();
        std::thread::sleep(std::time::Duration::from_secs(3));

        // The first generation must be dead: its counter must not advance
        // after the restart. If the old race were present it would keep
        // ticking alongside the new loop.
        assert_eq!(
            first.load(Ordering::SeqCst),
            first_baseline,
            "the replaced sync loop must stop ticking after restart"
        );
        assert!(
            second.load(Ordering::SeqCst) > 0,
            "the current sync loop should be delivering updates"
        );

        bob.stop_sync();
        assert!(!bob.is_syncing());
    }

    // -- Test: Attachment upload + download round-trip --

    /// Build the smallest valid PNG (1x1 transparent pixel).
    /// Used to verify the attachment round-trip without needing real image data.
    fn tiny_png() -> Vec<u8> {
        vec![
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0D, 0x49,
            0x44, 0x41, 0x54, // IDAT chunk
            0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4,
            0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, // IEND chunk
            0xAE, 0x42, 0x60, 0x82,
        ]
    }

    #[test]
    fn attachment_upload_and_download() {
        require_synapse();
        let (alice, _alice_id) = register_and_login("attach_alice");
        let (bob, bob_id) = register_and_login("attach_bob");

        // Alice creates a room and invites Bob (public, unencrypted to keep it simple).
        let room_id = alice.create_room("Media Room", true).unwrap();
        alice.sync_once().unwrap();
        alice.invite_user(&room_id, &bob_id).unwrap();

        bob.sync_once().unwrap();
        bob.join_room(&room_id).unwrap();

        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Alice sends a PNG attachment.
        let payload = tiny_png();
        alice
            .send_attachment(
                &room_id,
                "pixel.png",
                "image/png",
                payload.clone(),
                Some(1),
                Some(1),
            )
            .expect("alice failed to send attachment");

        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Bob should see the image event with a media_source mxc URI.
        let bob_msgs = bob.messages(&room_id, 50, None).unwrap().messages;
        let image_msg = bob_msgs
            .iter()
            .find(|m| m.message_type == "image")
            .expect("Bob should see the image message");

        assert_eq!(image_msg.body, "pixel.png");
        assert_eq!(image_msg.media_mime_type.as_deref(), Some("image/png"));
        let media_source = image_msg
            .media_source
            .as_deref()
            .expect("image message should carry media_source");
        // media_source is JSON-serialised MediaSource; it should contain an mxc URI
        assert!(
            media_source.contains("mxc://"),
            "expected mxc:// inside media_source, got {media_source}"
        );

        // Bob downloads the media and verifies bytes match Alice's payload.
        let downloaded = bob
            .download_media(media_source)
            .expect("download_media failed");
        assert_eq!(
            downloaded, payload,
            "downloaded bytes should match what Alice uploaded"
        );
    }

    // -- Test: Send and receive reactions --

    #[test]
    fn send_and_receive_reaction() {
        require_synapse();
        let (alice, _alice_id) = register_and_login("react_alice");
        let (bob, bob_id) = register_and_login("react_bob");

        let room_id = alice.create_room("Reaction Room", true).unwrap();
        alice.sync_once().unwrap();
        alice.invite_user(&room_id, &bob_id).unwrap();

        bob.sync_once().unwrap();
        bob.join_room(&room_id).unwrap();
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Alice sends a message
        alice.send_message(&room_id, "React to this!").unwrap();
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Bob finds the message and reacts with thumbs up
        let bob_msgs = bob.messages(&room_id, 50, None).unwrap().messages;
        let target = bob_msgs
            .iter()
            .find(|m| m.body == "React to this!")
            .unwrap();
        let reaction_event_id = bob
            .send_reaction(&room_id, &target.event_id, "\u{1f44d}")
            .expect("bob should be able to react");
        assert!(
            reaction_event_id.starts_with('$'),
            "reaction should return a valid event ID"
        );

        // Both sync
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Alice should see the reaction on the message
        let alice_msgs = alice.messages(&room_id, 50, None).unwrap().messages;
        let reacted = alice_msgs
            .iter()
            .find(|m| m.body == "React to this!")
            .unwrap();
        assert!(
            reacted.reactions.iter().any(|r| r.key == "\u{1f44d}"),
            "Alice should see Bob's thumbs up reaction, got: {:?}",
            reacted.reactions
        );
    }

    // -- Test: User profile (display name + avatar) --

    #[test]
    fn user_profile_display_name_and_avatar() {
        require_synapse();
        let (alice, _alice_id) = register_and_login("profile_alice");

        alice.sync_once().unwrap();

        // Initially, profile should have no display name or avatar
        let profile = alice.get_profile().unwrap();
        // Display name may or may not be set after registration; avatar should be None
        assert!(profile.avatar_url.is_none());

        // Set display name
        alice.set_display_name("Alice Wonderland").unwrap();
        let profile = alice.get_profile().unwrap();
        assert_eq!(profile.display_name.as_deref(), Some("Alice Wonderland"));

        // Update display name
        alice.set_display_name("Alice W.").unwrap();
        let profile = alice.get_profile().unwrap();
        assert_eq!(profile.display_name.as_deref(), Some("Alice W."));

        // Upload avatar
        let avatar_data = tiny_png();
        let mxc_url = alice.set_avatar("image/png", avatar_data).unwrap();
        assert!(
            mxc_url.starts_with("mxc://"),
            "avatar upload should return mxc URL, got: {mxc_url}"
        );

        let profile = alice.get_profile().unwrap();
        assert!(profile.avatar_url.is_some());
        assert!(profile.avatar_url.as_deref().unwrap().starts_with("mxc://"));

        // Remove avatar
        alice.remove_avatar().unwrap();
        let profile = alice.get_profile().unwrap();
        assert!(profile.avatar_url.is_none(), "avatar should be removed");
    }

    #[test]
    fn room_settings_name_and_topic() {
        require_synapse();
        let (alice, _alice_id) = register_and_login("room_settings");

        // Create a room and sync to pick it up.
        let room_id = alice.create_room("Original Name", false).unwrap();
        alice.sync_once().unwrap();
        let rooms = alice.rooms().unwrap();
        let room = rooms.iter().find(|r| r.id == room_id).unwrap();
        assert_eq!(room.display_name, "Original Name");
        assert!(room.topic.is_none());

        // Rename the room.
        alice.set_room_name(&room_id, "Renamed Room").unwrap();
        alice.sync_once().unwrap();
        let rooms = alice.rooms().unwrap();
        let room = rooms.iter().find(|r| r.id == room_id).unwrap();
        assert_eq!(room.display_name, "Renamed Room");

        // Set a topic.
        alice
            .set_room_topic(&room_id, "A room for testing")
            .unwrap();
        alice.sync_once().unwrap();
        let rooms = alice.rooms().unwrap();
        let room = rooms.iter().find(|r| r.id == room_id).unwrap();
        assert_eq!(room.topic.as_deref(), Some("A room for testing"));

        // Update the topic.
        alice.set_room_topic(&room_id, "Updated topic").unwrap();
        alice.sync_once().unwrap();
        let rooms = alice.rooms().unwrap();
        let room = rooms.iter().find(|r| r.id == room_id).unwrap();
        assert_eq!(room.topic.as_deref(), Some("Updated topic"));
    }

    #[test]
    fn redact_reaction() {
        require_synapse();
        let (alice, _alice_id) = register_and_login("redact_react_alice");
        let (bob, bob_id) = register_and_login("redact_react_bob");

        let room_id = alice.create_room("Redact Reaction Room", true).unwrap();
        alice.sync_once().unwrap();
        alice.invite_user(&room_id, &bob_id).unwrap();

        bob.sync_once().unwrap();
        bob.join_room(&room_id).unwrap();
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Alice sends a message
        alice.send_message(&room_id, "React and unreact").unwrap();
        alice.sync_once().unwrap();
        bob.sync_once().unwrap();

        // Bob reacts
        let bob_msgs = bob.messages(&room_id, 50, None).unwrap().messages;
        let target = bob_msgs
            .iter()
            .find(|m| m.body == "React and unreact")
            .unwrap();
        let reaction_event_id = bob
            .send_reaction(&room_id, &target.event_id, "\u{2764}\u{fe0f}")
            .unwrap();

        bob.sync_once().unwrap();
        alice.sync_once().unwrap();

        // Verify the reaction exists
        let alice_msgs = alice.messages(&room_id, 50, None).unwrap().messages;
        let reacted = alice_msgs
            .iter()
            .find(|m| m.body == "React and unreact")
            .unwrap();
        assert!(
            reacted
                .reactions
                .iter()
                .any(|r| r.key == "\u{2764}\u{fe0f}"),
            "reaction should exist before redaction"
        );

        // Bob redacts the reaction
        bob.redact_reaction(&room_id, &reaction_event_id).unwrap();
        bob.sync_once().unwrap();
        alice.sync_once().unwrap();

        // Alice should no longer see the reaction
        let alice_msgs = alice.messages(&room_id, 50, None).unwrap().messages;
        let after = alice_msgs
            .iter()
            .find(|m| m.body == "React and unreact")
            .unwrap();
        assert!(
            !after.reactions.iter().any(|r| r.key == "\u{2764}\u{fe0f}"),
            "reaction should be gone after redaction, got: {:?}",
            after.reactions
        );
    }

    // -- Test: Recovery enable returns a key and flips state --

    #[test]
    fn recovery_enable_and_disable_roundtrip() {
        use parlotte_core::RecoveryState;
        require_synapse();
        let (client, _user) = register_and_login("recovery_roundtrip");

        // Sync at least once so the recovery state machine is initialised.
        client.sync_once().unwrap();

        // Fresh account: no secret storage yet.
        assert!(matches!(
            client.recovery_state(),
            RecoveryState::Disabled | RecoveryState::Unknown
        ));

        let recovery_key = client
            .enable_recovery(None)
            .expect("enable_recovery should succeed on a fresh account");
        assert!(
            !recovery_key.trim().is_empty(),
            "recovery key must not be empty"
        );

        client.sync_once().unwrap();
        assert_eq!(client.recovery_state(), RecoveryState::Enabled);

        client.disable_recovery().expect("disable_recovery failed");
        client.sync_once().unwrap();
        assert_eq!(client.recovery_state(), RecoveryState::Disabled);
    }

    // -- Test: Ignore and unignore a user --

    #[test]
    fn ignore_and_unignore_user_roundtrip() {
        require_synapse();
        let (alice, _alice_id) = register_and_login("ignore_alice");
        let (_bob, bob_id) = register_and_login("ignore_bob");

        // Fresh account: nobody ignored.
        assert!(alice.ignored_users().unwrap().is_empty());

        alice.ignore_user(&bob_id).expect("ignore_user failed");
        alice.sync_once().unwrap();
        let ignored = alice.ignored_users().unwrap();
        assert_eq!(ignored, vec![bob_id.clone()]);

        alice.unignore_user(&bob_id).expect("unignore_user failed");
        alice.sync_once().unwrap();
        assert!(
            alice.ignored_users().unwrap().is_empty(),
            "ignore list should be empty after unignore"
        );
    }

    // -- Timeline API: display, local echo, and back-pagination --

    use parlotte_core::{MessageInfo, SyncListener, TimelineListener};
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    /// Stores the most recent timeline snapshot delivered by the core.
    struct SnapshotCollector {
        latest: Mutex<Vec<MessageInfo>>,
    }

    impl SnapshotCollector {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                latest: Mutex::new(Vec::new()),
            })
        }
        fn snapshot(&self) -> Vec<MessageInfo> {
            self.latest.lock().unwrap().clone()
        }
    }

    impl TimelineListener for SnapshotCollector {
        fn on_timeline_update(&self, messages: Vec<MessageInfo>) {
            *self.latest.lock().unwrap() = messages;
        }
    }

    /// Drives the persistent sync loop so the timeline receives remote echoes.
    struct NoopSync;
    impl SyncListener for NoopSync {
        fn on_sync_update(&self) {}
    }

    /// Poll the collector until `predicate` holds or `timeout` elapses; returns
    /// the last observed snapshot either way.
    fn wait_for(
        collector: &SnapshotCollector,
        timeout: Duration,
        predicate: impl Fn(&[MessageInfo]) -> bool,
    ) -> Vec<MessageInfo> {
        let start = Instant::now();
        loop {
            let snap = collector.snapshot();
            if predicate(&snap) || start.elapsed() > timeout {
                return snap;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    #[test]
    fn timeline_displays_messages_and_local_echo() {
        require_synapse();
        let (alice, alice_id) = register_and_login("tl_alice");

        let room_id = alice.create_room("Timeline Test", false).unwrap();
        alice.sync_once().unwrap();

        // A message sent the classic (room-based) way, before subscribing.
        alice.send_message(&room_id, "first message").unwrap();
        alice.sync_once().unwrap();

        // Keep sync running so the timeline gets remote echoes / send confirms.
        alice.start_sync(Arc::new(NoopSync)).unwrap();

        let collector = SnapshotCollector::new();
        alice.start_timeline(&room_id, collector.clone()).unwrap();

        // The initial snapshot (or a near-immediate one) shows the existing message.
        let snap = wait_for(&collector, Duration::from_secs(15), |m| {
            m.iter().any(|x| x.body == "first message")
        });
        assert!(
            snap.iter().any(|m| m.body == "first message"),
            "timeline should show the existing message; got {:?}",
            snap.iter().map(|m| m.body.clone()).collect::<Vec<_>>()
        );

        // Send through the timeline: a local echo should appear, then resolve
        // to a confirmed message with a real event id.
        alice.timeline_send_message(&room_id, "echo test").unwrap();
        let snap = wait_for(&collector, Duration::from_secs(15), |m| {
            m.iter()
                .any(|x| x.body == "echo test" && !x.event_id.is_empty())
        });
        let echo = snap
            .iter()
            .find(|m| m.body == "echo test")
            .expect("local echo should appear in the timeline");
        assert_eq!(echo.sender, alice_id, "echo should be from the sender");
        assert!(
            !echo.event_id.is_empty(),
            "echo should resolve to a real event id once sent"
        );

        alice.stop_timeline();
        alice.stop_sync();
    }

    #[test]
    fn timeline_paginates_backwards() {
        require_synapse();
        let (alice, _) = register_and_login("tl_page_alice");
        let room_id = alice.create_room("Pagination Test", false).unwrap();
        alice.sync_once().unwrap();

        for i in 0..6 {
            alice.send_message(&room_id, &format!("msg {i}")).unwrap();
        }
        alice.sync_once().unwrap();

        let collector = SnapshotCollector::new();
        alice.start_timeline(&room_id, collector.clone()).unwrap();
        wait_for(&collector, Duration::from_secs(15), |m| {
            m.iter().any(|x| x.body.starts_with("msg "))
        });

        // Live back-pagination is lazy: the first call is served from the
        // cache and reports "not at start" even on a tiny room; a later call
        // actually paginates and reports hitting the start. This mirrors the
        // app's scroll-to-load (hasMoreMessages stays true until a paginate
        // confirms the start). Loop, bounded, until it reports the start.
        let mut reached_start = false;
        for _ in 0..6 {
            reached_start = alice.paginate_timeline_back(&room_id, 50).unwrap();
            if reached_start {
                break;
            }
        }
        assert!(
            reached_start,
            "repeated back-pagination should reach the start of a small room"
        );

        let snap = collector.snapshot();
        assert!(
            snap.iter().filter(|m| m.body.starts_with("msg ")).count() >= 1,
            "timeline should retain the sent messages after pagination"
        );

        alice.stop_timeline();
    }
}
