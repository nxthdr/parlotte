import Testing
import ParlotteSDK
@testable import ParlotteLib

private struct TestError: Error {}

@MainActor
@Suite("AppState")
struct AppStateTests {
    private var appState: AppState
    private var mock: MockMatrixClient

    init() async {
        mock = MockMatrixClient()
        appState = AppState(profile: "test")
        appState.loggedInUserId = "@alice:example.com"
        appState.selectedRoomId = "!room:example.com"
        appState.client = mock
        // selectedRoomId.didSet spawns a Task (refreshMessages + sendReadReceipt).
        // Await it to prevent it from racing with test bodies.
        await appState.roomRefreshTask?.value
        // Reset call tracking so background setup doesn't pollute test assertions.
        mock.messagesCalls.removeAll()
        mock.sendReadReceiptCalls.removeAll()
    }

    // MARK: - Helpers

    private func makeMessage(
        eventId: String = "$evt1:example.com",
        sender: String = "@bob:example.com",
        body: String = "Hello",
        repliedToEventId: String? = nil,
        reactions: [ReactionInfo] = []
    ) -> MessageInfo {
        MessageInfo(
            eventId: eventId,
            sender: sender,
            body: body,
            formattedBody: nil,
            messageType: "text",
            timestampMs: 1_700_000_000_000,
            isEdited: false,
            repliedToEventId: repliedToEventId,
            mediaSource: nil,
            mediaMimeType: nil,
            mediaWidth: nil,
            mediaHeight: nil,
            mediaSize: nil,
            reactions: reactions
        )
    }

    // MARK: - Send Message

    @Test("Send message appends optimistic placeholder")
    mutating func sendMessageAppendsOptimistically() async {
        await appState.sendMessage(body: "Hello world")

        #expect(appState.messages.count == 1)
        #expect(appState.messages[0].body == "Hello world")
        #expect(appState.messages[0].sender == "@alice:example.com")
        #expect(appState.messages[0].eventId.hasPrefix("~optimistic:"))
    }

    @Test("Send message trims whitespace")
    mutating func sendMessageTrimsWhitespace() async {
        await appState.sendMessage(body: "  spaced  ")

        #expect(mock.sendMessageCalls.count == 1)
        #expect(mock.sendMessageCalls[0].body == "spaced")
    }

    @Test("Send message ignores empty body")
    mutating func sendMessageIgnoresEmpty() async {
        await appState.sendMessage(body: "   ")

        #expect(appState.messages.count == 0)
        #expect(mock.sendMessageCalls.count == 0)
    }

    @Test("Send message removes placeholder on failure")
    mutating func sendMessageRemovesPlaceholderOnFailure() async {
        mock.sendMessageError = ParlotteError.Room(message: "server error")

        await appState.sendMessage(body: "Will fail")

        #expect(appState.messages.count == 0, "Placeholder should be removed on failure")
        #expect(appState.errorMessage != nil)
    }

    @Test("Send message requires selected room")
    mutating func sendMessageRequiresSelectedRoom() async {
        appState.selectedRoomId = nil

        await appState.sendMessage(body: "No room")

        #expect(appState.messages.count == 0)
        #expect(mock.sendMessageCalls.count == 0)
    }

    // MARK: - Send Reply

    @Test("Send reply appends optimistic placeholder with reply ID")
    mutating func sendReplyAppendsOptimisticallyWithReplyId() async {
        let original = makeMessage(eventId: "$original:example.com")
        appState.messages = [original]

        await appState.sendReply(eventId: "$original:example.com", body: "My reply")

        #expect(appState.messages.count == 2)
        let reply = appState.messages[1]
        #expect(reply.body == "My reply")
        #expect(reply.repliedToEventId == "$original:example.com")
        #expect(reply.eventId.hasPrefix("~optimistic:"))
    }

    @Test("Send reply calls server with correct args")
    mutating func sendReplyCallsServerWithCorrectArgs() async {
        await appState.sendReply(eventId: "$evt:x.com", body: "reply text")

        #expect(mock.sendReplyCalls.count == 1)
        #expect(mock.sendReplyCalls[0].roomId == "!room:example.com")
        #expect(mock.sendReplyCalls[0].eventId == "$evt:x.com")
        #expect(mock.sendReplyCalls[0].body == "reply text")
    }

    @Test("Send reply removes placeholder on failure")
    mutating func sendReplyRemovesPlaceholderOnFailure() async {
        mock.sendReplyError = ParlotteError.Room(message: "failed")

        await appState.sendReply(eventId: "$evt:x.com", body: "Will fail")

        #expect(appState.messages.count == 0)
        #expect(appState.errorMessage != nil)
    }

    // MARK: - Edit Message

    @Test("Edit message updates body optimistically")
    mutating func editMessageUpdatesBodyOptimistically() async {
        appState.messages = [makeMessage(eventId: "$e1:x.com", body: "Original")]

        await appState.editMessage(eventId: "$e1:x.com", newBody: "Updated")

        #expect(appState.messages[0].body == "Updated")
        #expect(appState.messages[0].isEdited == true)
        #expect(appState.messages[0].formattedBody == nil)
    }

    @Test("Edit message calls server")
    mutating func editMessageCallsServer() async {
        appState.messages = [makeMessage(eventId: "$e1:x.com", body: "Original")]

        await appState.editMessage(eventId: "$e1:x.com", newBody: "Updated")

        #expect(mock.editMessageCalls.count == 1)
        #expect(mock.editMessageCalls[0].newBody == "Updated")
    }

    @Test("Edit message reverts on failure")
    mutating func editMessageRevertsOnFailure() async {
        let msg = makeMessage(eventId: "$e1:x.com", body: "Original")
        appState.messages = [msg]
        mock.editMessageError = ParlotteError.Room(message: "forbidden")

        await appState.editMessage(eventId: "$e1:x.com", newBody: "Updated")

        #expect(appState.messages[0].body == "Original", "Should revert to original body")
        #expect(appState.messages[0].isEdited == false, "Should revert isEdited flag")
        #expect(appState.errorMessage != nil)
    }

    @Test("Edit nonexistent message is no-op")
    mutating func editNonexistentMessageIsNoOp() async {
        appState.messages = [makeMessage(eventId: "$e1:x.com")]

        await appState.editMessage(eventId: "$nonexistent:x.com", newBody: "Update")

        #expect(mock.editMessageCalls.count == 0)
    }

    // MARK: - Delete Message

    @Test("Delete message removes optimistically")
    mutating func deleteMessageRemovesOptimistically() async {
        appState.messages = [
            makeMessage(eventId: "$e1:x.com", body: "First"),
            makeMessage(eventId: "$e2:x.com", body: "Second"),
        ]

        await appState.deleteMessage(eventId: "$e1:x.com")

        #expect(appState.messages.count == 1)
        #expect(appState.messages[0].eventId == "$e2:x.com")
    }

    @Test("Delete message calls server")
    mutating func deleteMessageCallsServer() async {
        appState.messages = [makeMessage(eventId: "$e1:x.com")]

        await appState.deleteMessage(eventId: "$e1:x.com")

        #expect(mock.redactMessageCalls.count == 1)
        #expect(mock.redactMessageCalls[0].eventId == "$e1:x.com")
    }

    @Test("Delete message reverts on failure")
    mutating func deleteMessageRevertsOnFailure() async {
        appState.messages = [
            makeMessage(eventId: "$e1:x.com", body: "Keep me"),
        ]
        mock.redactMessageError = ParlotteError.Room(message: "forbidden")

        await appState.deleteMessage(eventId: "$e1:x.com")

        #expect(appState.messages.count == 1, "Should revert deletion")
        #expect(appState.messages[0].body == "Keep me")
        #expect(appState.errorMessage != nil)
    }

    @Test("Delete nonexistent message is no-op")
    mutating func deleteNonexistentMessageIsNoOp() async {
        appState.messages = [makeMessage(eventId: "$e1:x.com")]

        await appState.deleteMessage(eventId: "$nonexistent:x.com")

        #expect(appState.messages.count == 1)
        #expect(mock.redactMessageCalls.count == 0)
    }

    // MARK: - Append New Messages (sync handler)

    @Test("Append new messages replaces a sent message's placeholder with its echo")
    mutating func appendNewMessagesReplacesOptimisticPlaceholders() async {
        // Send through the real flow so the placeholder's real event ID is
        // tracked; only then should its echo replace it.
        mock.sendMessageResult = "$real:example.com"
        await appState.sendMessage(body: "Hello")
        #expect(appState.messages.count == 1)
        #expect(appState.messages[0].eventId.hasPrefix("~optimistic:"))

        mock.messagesResult = MessageBatch(
            messages: [makeMessage(eventId: "$real:example.com", sender: "@alice:example.com", body: "Hello")],
            endToken: nil
        )

        await appState.appendNewMessages()

        #expect(appState.messages.count == 1)
        #expect(appState.messages[0].eventId == "$real:example.com", "Placeholder should be replaced")
    }

    @Test("Append new messages deduplicates")
    mutating func appendNewMessagesDeduplicates() async {
        let existing = makeMessage(eventId: "$e1:x.com", body: "Exists")
        appState.messages = [existing]
        mock.messagesResult = MessageBatch(messages: [existing], endToken: nil)

        await appState.appendNewMessages()

        #expect(appState.messages.count == 1, "Should not duplicate")
    }

    @Test("Append new messages adds genuinely new ones")
    mutating func appendNewMessagesAddsGenuinelyNew() async {
        appState.messages = [makeMessage(eventId: "$e1:x.com", body: "Old")]
        mock.messagesResult = MessageBatch(
            messages: [
                makeMessage(eventId: "$e1:x.com", body: "Old"),
                makeMessage(eventId: "$e2:x.com", body: "New"),
            ],
            endToken: nil
        )

        await appState.appendNewMessages()

        #expect(appState.messages.count == 2)
        #expect(appState.messages[1].body == "New")
    }

    @Test("Append new messages picks up edits")
    mutating func appendNewMessagesPicksUpEdits() async {
        appState.messages = [makeMessage(eventId: "$e1:x.com", body: "Original")]
        mock.messagesResult = MessageBatch(
            messages: [
                MessageInfo(
                    eventId: "$e1:x.com", sender: "@bob:example.com",
                    body: "Edited", formattedBody: nil, messageType: "text",
                    timestampMs: 1_700_000_000_000, isEdited: true, repliedToEventId: nil,
                    mediaSource: nil, mediaMimeType: nil, mediaWidth: nil, mediaHeight: nil, mediaSize: nil,
                    reactions: []
                ),
            ],
            endToken: nil
        )

        await appState.appendNewMessages()

        #expect(appState.messages.count == 1)
        #expect(appState.messages[0].body == "Edited")
        #expect(appState.messages[0].isEdited == true)
    }

    @Test("Append new messages removes redacted messages")
    mutating func appendNewMessagesRemovesRedacted() async {
        appState.messages = [
            makeMessage(eventId: "$e1:x.com", body: "Keep"),
            makeMessage(eventId: "$e2:x.com", body: "Redacted"),
        ]
        // Server only returns the non-redacted message
        mock.messagesResult = MessageBatch(
            messages: [makeMessage(eventId: "$e1:x.com", body: "Keep")],
            endToken: nil
        )

        await appState.appendNewMessages()

        #expect(appState.messages.count == 1)
        #expect(appState.messages[0].eventId == "$e1:x.com")
    }

    @Test("Append new messages preserves optimistic placeholders when server has not confirmed")
    mutating func appendNewMessagesPreservesOptimisticBeforeConfirmation() async {
        appState.messages = [
            makeMessage(eventId: "$e1:x.com", body: "Old"),
            MessageInfo(
                eventId: "~optimistic:abc", sender: "@alice:example.com",
                body: "Sending...", formattedBody: nil, messageType: "text",
                timestampMs: 1_700_000_001_000, isEdited: false, repliedToEventId: nil,
                mediaSource: nil, mediaMimeType: nil, mediaWidth: nil, mediaHeight: nil, mediaSize: nil,
                reactions: []
            ),
        ]
        // Server returns the old message but not the optimistic one yet
        mock.messagesResult = MessageBatch(
            messages: [makeMessage(eventId: "$e1:x.com", body: "Old")],
            endToken: nil
        )

        await appState.appendNewMessages()

        #expect(appState.messages.count == 2, "Optimistic placeholder should be preserved")
        #expect(appState.messages[1].eventId == "~optimistic:abc")
    }

    @Test("Append new messages does not mutate array when nothing changed")
    mutating func appendNewMessagesNoMutationWhenUnchanged() async {
        let msg = makeMessage(eventId: "$e1:x.com", body: "Same")
        appState.messages = [msg]
        mock.messagesResult = MessageBatch(messages: [msg], endToken: nil)

        await appState.appendNewMessages()

        #expect(appState.messages.count == 1)
        #expect(appState.messages[0].body == "Same")
    }

    @Test("Append new messages skips when messages is empty")
    mutating func appendNewMessagesSkipsWhenEmpty() async {
        appState.messages = []
        mock.messagesResult = MessageBatch(
            messages: [makeMessage(eventId: "$e1:x.com", body: "Server msg")],
            endToken: nil
        )

        await appState.appendNewMessages()

        #expect(appState.messages.isEmpty, "Should bail early when messages is empty")
        #expect(mock.messagesCalls.isEmpty, "Should not call server")
    }

    @Test("Sync with empty messages falls back to refreshMessages")
    mutating func syncWithEmptyMessagesFallsBackToRefresh() async {
        appState.messages = []
        mock.messagesResult = MessageBatch(
            messages: [makeMessage(eventId: "$e1:x.com", body: "History")],
            endToken: nil
        )

        // Simulate what the sync handler does
        if appState.messages.isEmpty {
            await appState.refreshMessages()
        } else {
            await appState.appendNewMessages()
        }

        #expect(appState.messages.count == 1)
        #expect(appState.messages[0].body == "History")
    }

    // MARK: - Message Pagination

    @Test("Load more messages prepends older messages")
    mutating func loadMoreMessagesPrepends() async {
        appState.messages = [makeMessage(eventId: "$e3:x.com", body: "Latest")]
        appState.hasMoreMessages = true
        mock.messagesResult = MessageBatch(
            messages: [makeMessage(eventId: "$e3:x.com", body: "Latest")],
            endToken: "token123"
        )
        await appState.refreshMessages()

        mock.messagesResult = MessageBatch(
            messages: [makeMessage(eventId: "$e1:x.com", body: "Oldest")],
            endToken: "token456"
        )
        await appState.loadMoreMessages()

        #expect(appState.messages.count == 2)
        #expect(appState.messages[0].body == "Oldest")
        #expect(appState.messages[1].body == "Latest")
    }

    // MARK: - Room Selection

    @Test("Selecting room clears messages")
    mutating func selectingRoomClearsMessages() {
        appState.messages = [makeMessage()]
        appState.hasMoreMessages = true

        appState.selectedRoomId = "!other:example.com"

        #expect(appState.messages.isEmpty)
        #expect(appState.hasMoreMessages == false)
    }

    @Test("Selecting nil room clears messages")
    mutating func selectingNilRoomClearsMessages() {
        appState.messages = [makeMessage()]

        appState.selectedRoomId = nil

        #expect(appState.messages.isEmpty)
    }

    // MARK: - Refresh Rooms

    @Test("Refresh rooms updates room list")
    mutating func refreshRoomsUpdatesRoomList() async {
        mock.roomsResult = [
            RoomInfo(id: "!a:x.com", displayName: "Alpha", isEncrypted: false, isPublic: false, isDirect: false, topic: nil, isInvited: false, unreadCount: 0),
        ]

        await appState.refreshRooms()

        #expect(appState.rooms.count == 1)
        #expect(appState.rooms[0].displayName == "Alpha")
    }

    @Test("Refresh rooms zeroes unread count on selected room")
    mutating func refreshRoomsZeroesUnreadOnSelectedRoom() async {
        appState.selectedRoomId = "!a:x.com"
        mock.roomsResult = [
            RoomInfo(id: "!a:x.com", displayName: "Selected", isEncrypted: false, isPublic: false, isDirect: false, topic: nil, isInvited: false, unreadCount: 5),
            RoomInfo(id: "!b:x.com", displayName: "Other", isEncrypted: false, isPublic: false, isDirect: false, topic: nil, isInvited: false, unreadCount: 3),
        ]

        let hasNew = await appState.refreshRooms()

        #expect(hasNew == true, "Should report new messages in selected room")
        #expect(appState.rooms[0].unreadCount == 0, "Selected room unread should be zeroed")
        #expect(appState.rooms[1].unreadCount == 3, "Other room unread should be preserved")
    }

    @Test("Refresh rooms returns false when no unread in selected room")
    mutating func refreshRoomsReturnsFalseWhenNoUnread() async {
        appState.selectedRoomId = "!a:x.com"
        mock.roomsResult = [
            RoomInfo(id: "!a:x.com", displayName: "Selected", isEncrypted: false, isPublic: false, isDirect: false, topic: nil, isInvited: false, unreadCount: 0),
        ]

        let hasNew = await appState.refreshRooms()

        #expect(hasNew == false)
    }

    @Test("Refresh rooms sets error on failure")
    mutating func refreshRoomsSetsErrorOnFailure() async {
        mock.roomsError = ParlotteError.Room(message: "forbidden")

        let hasNew = await appState.refreshRooms()

        #expect(hasNew == false)
        #expect(appState.errorMessage != nil)
    }

    // MARK: - Leave Room

    @Test("Leave selected room clears selection")
    mutating func leaveSelectedRoomClearsSelection() async {
        appState.selectedRoomId = "!room:example.com"

        await appState.leaveRoom(roomId: "!room:example.com")

        #expect(appState.selectedRoomId == nil)
        #expect(mock.leaveRoomCalls.count == 1)
    }

    @Test("Leave non-selected room preserves selection")
    mutating func leaveNonSelectedRoomPreservesSelection() async {
        appState.selectedRoomId = "!room:example.com"

        await appState.leaveRoom(roomId: "!other:example.com")

        #expect(appState.selectedRoomId == "!room:example.com")
        #expect(mock.leaveRoomCalls.count == 1)
    }

    @Test("Leave room sets error on failure")
    mutating func leaveRoomSetsErrorOnFailure() async {
        mock.leaveRoomError = ParlotteError.Room(message: "forbidden")

        await appState.leaveRoom(roomId: "!room:example.com")

        #expect(appState.errorMessage != nil)
        #expect(appState.selectedRoomId == "!room:example.com", "Selection should not change on failure")
    }

    // MARK: - Logout

    @Test("Logout resets all state")
    mutating func logoutResetsAllState() async {
        appState.isLoggedIn = true
        appState.loggedInUserId = "@alice:example.com"
        appState.isSyncActive = true
        appState.rooms = [
            RoomInfo(id: "!a:x.com", displayName: "Room", isEncrypted: false, isPublic: false, isDirect: false, topic: nil, isInvited: false, unreadCount: 0),
        ]
        appState.messages = [makeMessage()]

        await appState.logout()

        #expect(appState.isLoggedIn == false)
        #expect(appState.loggedInUserId == nil)
        #expect(appState.isSyncActive == false)
        #expect(appState.rooms.isEmpty)
        #expect(appState.typingUsers.isEmpty)
        #expect(appState.selectedRoomId == nil)
        #expect(appState.messages.isEmpty)
        #expect(appState.client == nil)
    }

    @Test("Logout stops sync and calls server")
    mutating func logoutStopsSyncAndCallsServer() async {
        appState.isSyncActive = true

        await appState.logout()

        #expect(mock.stopSyncCalls == 1)
        #expect(mock.logoutCalls == 1)
    }

    @Test("handleUnknownToken clears all session state to prevent cross-account leakage")
    mutating func handleUnknownTokenClearsState() async {
        appState.isLoggedIn = true
        appState.loggedInUserId = "@alice:example.com"
        appState.isSyncActive = true
        appState.rooms = [
            RoomInfo(id: "!a:x.com", displayName: "Room", isEncrypted: false, isPublic: false, isDirect: false, topic: nil, isInvited: false, unreadCount: 0),
        ]
        appState.messages = [makeMessage()]
        appState.ignoredUsers = ["@bob:example.com"]

        appState.handleUnknownToken(softLogout: true)

        // No remnants of the invalidated account may survive for the next login.
        #expect(appState.isLoggedIn == false)
        #expect(appState.loggedInUserId == nil)
        #expect(appState.isSyncActive == false)
        #expect(appState.rooms.isEmpty)
        #expect(appState.messages.isEmpty)
        #expect(appState.selectedRoomId == nil)
        #expect(appState.ignoredUsers.isEmpty)
        #expect(appState.client == nil)
        #expect(appState.errorMessage != nil)
    }

    // MARK: - Typing Indicators

    @Test("Typing update filters out own user")
    mutating func handleTypingUpdateFiltersOwnUser() {
        appState.handleTypingUpdate(
            roomId: "!room:example.com",
            userIds: ["@alice:example.com", "@bob:example.com", "@carol:example.com"]
        )

        let typing = appState.typingUsers["!room:example.com"]
        #expect(typing == ["@bob:example.com", "@carol:example.com"])
    }

    @Test("Typing update replaces previous state")
    mutating func handleTypingUpdateReplacesState() {
        appState.handleTypingUpdate(roomId: "!room:example.com", userIds: ["@bob:example.com"])
        appState.handleTypingUpdate(roomId: "!room:example.com", userIds: ["@carol:example.com"])

        let typing = appState.typingUsers["!room:example.com"]
        #expect(typing == ["@carol:example.com"])
    }

    @Test("currentRoomTypingUsers returns selected room's typing users")
    mutating func currentRoomTypingUsersReturnsSelectedRoom() {
        appState.handleTypingUpdate(roomId: "!room:example.com", userIds: ["@bob:example.com"])
        appState.handleTypingUpdate(roomId: "!other:example.com", userIds: ["@carol:example.com"])

        #expect(appState.currentRoomTypingUsers == ["@bob:example.com"])
    }

    @Test("currentRoomTypingUsers empty when no room selected")
    mutating func currentRoomTypingUsersEmptyWhenNoRoom() {
        appState.selectedRoomId = nil
        appState.handleTypingUpdate(roomId: "!room:example.com", userIds: ["@bob:example.com"])

        #expect(appState.currentRoomTypingUsers.isEmpty)
    }

    @Test("Empty typing update clears state for room")
    mutating func emptyTypingUpdateClearsState() {
        appState.handleTypingUpdate(roomId: "!room:example.com", userIds: ["@bob:example.com"])
        appState.handleTypingUpdate(roomId: "!room:example.com", userIds: [])

        #expect(appState.currentRoomTypingUsers.isEmpty)
    }

    @Test("Logout clears typing state")
    mutating func logoutClearsTypingState() async {
        appState.handleTypingUpdate(roomId: "!room:example.com", userIds: ["@bob:example.com"])

        await appState.logout()

        #expect(appState.typingUsers.isEmpty)
    }

    @Test("Send typing notice calls client")
    mutating func sendTypingNoticeCallsClient() async {
        await appState.sendTypingNotice(isTyping: true)

        #expect(mock.sendTypingNoticeCalls.count == 1)
        #expect(mock.sendTypingNoticeCalls[0].roomId == "!room:example.com")
        #expect(mock.sendTypingNoticeCalls[0].isTyping == true)
    }

    @Test("Send typing notice requires selected room")
    mutating func sendTypingNoticeRequiresSelectedRoom() async {
        appState.selectedRoomId = nil

        await appState.sendTypingNotice(isTyping: true)

        #expect(mock.sendTypingNoticeCalls.isEmpty)
    }

    @Test("Send typing notice is best-effort")
    mutating func sendTypingNoticeIsBestEffort() async {
        mock.sendTypingNoticeError = ParlotteError.Room(message: "network error")

        await appState.sendTypingNotice(isTyping: true)

        #expect(appState.errorMessage == nil, "Typing notice errors should be swallowed")
    }

    // MARK: - Attachments

    @Test("Send attachment appends optimistic placeholder with media fields")
    mutating func sendAttachmentAppendsOptimistically() async {
        let data = MediaTestHelpers.pngMagicBytes()
        let url = MediaTestHelpers.makeTempFile(name: "photo.png", contents: data)
        defer { MediaTestHelpers.removeTempFile(at: url) }

        await appState.sendAttachment(fileURL: url)

        #expect(appState.messages.count == 1)
        let msg = appState.messages[0]
        #expect(msg.eventId.hasPrefix("~optimistic:"))
        #expect(msg.messageType == "image")
        #expect(msg.body == "photo.png")
        #expect(msg.mediaMimeType == "image/png")
        #expect(msg.mediaSize == UInt64(data.count))
        #expect(appState.pendingAttachments[msg.eventId] == data)
    }

    @Test("Send attachment classifies non-image as file")
    mutating func sendAttachmentClassifiesNonImageAsFile() async {
        let data = MediaTestHelpers.stringBytes("hello")
        let url = MediaTestHelpers.makeTempFile(name: "notes.txt", contents: data)
        defer { MediaTestHelpers.removeTempFile(at: url) }

        await appState.sendAttachment(fileURL: url)

        #expect(appState.messages.count == 1)
        #expect(appState.messages[0].messageType == "file")
    }

    @Test("Send attachment removes placeholder and clears pending on failure")
    mutating func sendAttachmentRemovesPlaceholderOnFailure() async {
        mock.sendAttachmentError = ParlotteError.Room(message: "upload failed")
        let url = MediaTestHelpers.makeTempFile(name: "fail.bin", contents: MediaTestHelpers.bytes([0x00]))
        defer { MediaTestHelpers.removeTempFile(at: url) }

        await appState.sendAttachment(fileURL: url)

        #expect(appState.messages.isEmpty)
        #expect(appState.pendingAttachments.isEmpty)
        #expect(appState.errorMessage != nil)
    }

    @Test("Send attachment calls client with correct args")
    mutating func sendAttachmentCallsClientWithArgs() async {
        let data = MediaTestHelpers.stringBytes("pdf bytes")
        let url = MediaTestHelpers.makeTempFile(name: "doc.pdf", contents: data)
        defer { MediaTestHelpers.removeTempFile(at: url) }

        await appState.sendAttachment(fileURL: url)

        #expect(mock.sendAttachmentCalls.count == 1)
        let call = mock.sendAttachmentCalls[0]
        #expect(call.roomId == "!room:example.com")
        #expect(call.filename == "doc.pdf")
        #expect(call.mimeType == "application/pdf")
        #expect(call.data == data)
    }

    @Test("Send attachment requires selected room")
    mutating func sendAttachmentRequiresSelectedRoom() async {
        appState.selectedRoomId = nil
        let url = MediaTestHelpers.makeTempFile(name: "x.txt", contents: MediaTestHelpers.stringBytes("x"))
        defer { MediaTestHelpers.removeTempFile(at: url) }

        await appState.sendAttachment(fileURL: url)

        #expect(mock.sendAttachmentCalls.isEmpty)
    }

    @Test("Load media caches downloaded bytes")
    mutating func loadMediaCachesBytes() async {
        let bytes = MediaTestHelpers.stringBytes("image-bytes")
        mock.downloadMediaResult = bytes

        let first = await appState.loadMedia(mxcUri: "mxc://a/1")
        let second = await appState.loadMedia(mxcUri: "mxc://a/1")

        #expect(first == bytes)
        #expect(second == bytes)
        #expect(mock.downloadMediaCalls.count == 1, "second call should hit cache")
    }

    @Test("Load media returns nil on error")
    mutating func loadMediaReturnsNilOnError() async {
        mock.downloadMediaError = ParlotteError.Network(message: "unreachable")

        let result = await appState.loadMedia(mxcUri: "mxc://a/1")

        #expect(result == nil)
    }

    @Test("Append new messages drops pending attachments for replaced placeholders")
    mutating func appendNewMessagesClearsPendingAttachments() async {
        let url = MediaTestHelpers.makeTempFile(name: "img.png", contents: MediaTestHelpers.bytes([0xFF]))
        defer { MediaTestHelpers.removeTempFile(at: url) }

        mock.sendAttachmentResult = "$attach:x.com"
        await appState.sendAttachment(fileURL: url)
        #expect(appState.pendingAttachments.count == 1)

        // Server confirms with the same event ID sendAttachment returned.
        let realMsg = makeMessage(eventId: "$attach:x.com", sender: "@alice:example.com", body: "img.png")
        mock.messagesResult = MessageBatch(messages: [realMsg], endToken: nil)

        await appState.appendNewMessages()

        #expect(appState.pendingAttachments.isEmpty)
        #expect(!appState.messages.contains { $0.eventId.hasPrefix("~optimistic:") })
    }

    @Test("Logout clears pending attachments")
    mutating func logoutClearsMediaState() async {
        appState.pendingAttachments["~optimistic:foo"] = MediaTestHelpers.bytes([0x42])

        await appState.logout()

        #expect(appState.pendingAttachments.isEmpty)
    }

    // MARK: - Reactions

    @Test("Toggle reaction adds optimistic reaction")
    mutating func toggleReactionAddsOptimistically() async {
        let msg = makeMessage()
        appState.messages = [msg]

        await appState.toggleReaction(eventId: msg.eventId, key: "\u{1f44d}")

        #expect(appState.messages[0].reactions.count == 1)
        #expect(appState.messages[0].reactions[0].key == "\u{1f44d}")
        #expect(appState.messages[0].reactions[0].sender == "@alice:example.com")
        // Optimistic ID should be replaced with real one
        #expect(appState.messages[0].reactions[0].eventId == "$reaction:example.com")
    }

    @Test("Toggle reaction calls client with correct args")
    mutating func toggleReactionCallsClient() async {
        let msg = makeMessage()
        appState.messages = [msg]

        await appState.toggleReaction(eventId: msg.eventId, key: "\u{1f44d}")

        #expect(mock.sendReactionCalls.count == 1)
        #expect(mock.sendReactionCalls[0].roomId == "!room:example.com")
        #expect(mock.sendReactionCalls[0].eventId == msg.eventId)
        #expect(mock.sendReactionCalls[0].key == "\u{1f44d}")
    }

    @Test("Toggle reaction removes own existing reaction")
    mutating func toggleReactionRemovesOwn() async {
        let reaction = ReactionInfo(
            eventId: "$r1:example.com",
            key: "\u{1f44d}",
            sender: "@alice:example.com"
        )
        let msg = makeMessage(reactions: [reaction])
        appState.messages = [msg]

        await appState.toggleReaction(eventId: msg.eventId, key: "\u{1f44d}")

        #expect(appState.messages[0].reactions.isEmpty)
        #expect(mock.redactReactionCalls.count == 1)
        #expect(mock.redactReactionCalls[0].reactionEventId == "$r1:example.com")
    }

    @Test("Toggle reaction failure reverts optimistic add")
    mutating func toggleReactionRevertsAddOnFailure() async {
        mock.sendReactionError = ParlotteError.Room(message: "failed")
        let msg = makeMessage()
        appState.messages = [msg]

        await appState.toggleReaction(eventId: msg.eventId, key: "\u{1f44d}")

        #expect(appState.messages[0].reactions.isEmpty)
        #expect(appState.errorMessage != nil)
    }

    @Test("Toggle reaction failure reverts optimistic remove")
    mutating func toggleReactionRevertsRemoveOnFailure() async {
        mock.redactReactionError = ParlotteError.Room(message: "failed")
        let reaction = ReactionInfo(
            eventId: "$r1:example.com",
            key: "\u{1f44d}",
            sender: "@alice:example.com"
        )
        let msg = makeMessage(reactions: [reaction])
        appState.messages = [msg]

        await appState.toggleReaction(eventId: msg.eventId, key: "\u{1f44d}")

        #expect(appState.messages[0].reactions.count == 1)
        #expect(appState.messages[0].reactions[0].eventId == "$r1:example.com")
        #expect(appState.errorMessage != nil)
    }

    @Test("Toggle reaction requires selected room")
    mutating func toggleReactionRequiresSelectedRoom() async {
        appState.selectedRoomId = nil
        let msg = makeMessage()
        appState.messages = [msg]

        await appState.toggleReaction(eventId: msg.eventId, key: "\u{1f44d}")

        #expect(mock.sendReactionCalls.isEmpty)
    }

    // MARK: - Profile

    @Test("Fetch profile sets display name and avatar URL")
    mutating func fetchProfileSetsState() async {
        mock.getProfileResult = UserProfile(
            displayName: "Alice Wonderland",
            avatarUrl: "mxc://example.com/avatar123"
        )

        await appState.fetchProfile()

        #expect(appState.displayName == "Alice Wonderland")
        #expect(appState.avatarUrl == "mxc://example.com/avatar123")
        #expect(mock.getProfileCalls == 1)
    }

    @Test("Fetch profile handles nil values")
    mutating func fetchProfileHandlesNil() async {
        mock.getProfileResult = UserProfile(displayName: nil, avatarUrl: nil)

        await appState.fetchProfile()

        #expect(appState.displayName == nil)
        #expect(appState.avatarUrl == nil)
    }

    @Test("Fetch profile is best-effort")
    mutating func fetchProfileIsBestEffort() async {
        mock.getProfileError = ParlotteError.Network(message: "unreachable")

        await appState.fetchProfile()

        #expect(appState.errorMessage == nil, "Profile fetch errors should be swallowed")
    }

    @Test("Update display name sets optimistically and calls client")
    mutating func updateDisplayNameOptimistic() async {
        appState.displayName = "OldName"

        await appState.updateDisplayName("NewName")

        #expect(appState.displayName == "NewName")
        #expect(mock.setDisplayNameCalls == ["NewName"])
        #expect(appState.isUpdatingProfile == false)
    }

    @Test("Update display name reverts on failure")
    mutating func updateDisplayNameRevertsOnFailure() async {
        appState.displayName = "OldName"
        mock.setDisplayNameError = ParlotteError.Network(message: "failed")

        await appState.updateDisplayName("NewName")

        #expect(appState.displayName == "OldName")
        #expect(appState.errorMessage != nil)
    }

    @Test("Update display name ignores whitespace-only input")
    mutating func updateDisplayNameIgnoresWhitespace() async {
        appState.displayName = "Alice"

        await appState.updateDisplayName("   ")

        #expect(appState.displayName == "Alice")
        #expect(mock.setDisplayNameCalls.isEmpty)
    }

    @Test("Update avatar sets URL and calls client")
    mutating func updateAvatarSetsUrl() async {
        let data = MediaTestHelpers.bytes([0xFF, 0xD8, 0xFF])
        mock.setAvatarResult = "mxc://example.com/new_avatar"

        await appState.updateAvatar(data: data, mimeType: "image/jpeg")

        #expect(appState.avatarUrl == "mxc://example.com/new_avatar")
        #expect(mock.setAvatarCalls.count == 1)
        #expect(mock.setAvatarCalls[0].mimeType == "image/jpeg")
        #expect(mock.setAvatarCalls[0].data == data)
    }

    @Test("Update avatar reverts on failure")
    mutating func updateAvatarRevertsOnFailure() async {
        appState.avatarUrl = "mxc://example.com/old"
        mock.setAvatarError = ParlotteError.Network(message: "upload failed")

        await appState.updateAvatar(data: MediaTestHelpers.bytes([0x00]), mimeType: "image/png")

        #expect(appState.avatarUrl == "mxc://example.com/old")
        #expect(appState.errorMessage != nil)
    }

    @Test("Remove avatar clears URL and calls client")
    mutating func removeAvatarClearsUrl() async {
        appState.avatarUrl = "mxc://example.com/old"

        await appState.removeAvatar()

        #expect(appState.avatarUrl == nil)
        #expect(mock.removeAvatarCalls == 1)
    }

    @Test("Remove avatar reverts on failure")
    mutating func removeAvatarRevertsOnFailure() async {
        appState.avatarUrl = "mxc://example.com/old"
        mock.removeAvatarError = ParlotteError.Network(message: "failed")

        await appState.removeAvatar()

        #expect(appState.avatarUrl == "mxc://example.com/old")
        #expect(appState.errorMessage != nil)
    }

    @Test("Logout clears profile state")
    mutating func logoutClearsProfileState() async {
        appState.displayName = "Alice"
        appState.avatarUrl = "mxc://example.com/avatar"

        await appState.logout()

        #expect(appState.displayName == nil)
        #expect(appState.avatarUrl == nil)
    }

    // MARK: - Member Profiles

    private func member(
        _ userId: String,
        displayName: String? = nil,
        avatarUrl: String? = nil
    ) -> RoomMemberInfo {
        RoomMemberInfo(
            userId: userId,
            displayName: displayName,
            avatarUrl: avatarUrl,
            powerLevel: 0,
            role: "member"
        )
    }

    @Test("refreshMemberProfiles populates cache from server")
    mutating func refreshMemberProfilesPopulates() async {
        mock.roomMembersResult = [
            member("@alice:example.com", displayName: "Alice", avatarUrl: "mxc://srv/a"),
            member("@bob:example.com",   displayName: "Bob",   avatarUrl: "mxc://srv/b"),
        ]

        await appState.refreshMemberProfiles()

        #expect(appState.memberDisplayName(for: "@bob:example.com") == "Bob")
        #expect(appState.avatarUrl(for: "@bob:example.com") == "mxc://srv/b")
    }

    @Test("refreshMemberProfiles overlays own local profile over stale server data")
    mutating func refreshMemberProfilesOwnLocalWins() async {
        // Local state has the freshest avatar (just updated optimistically).
        appState.displayName = "Alice (local)"
        appState.avatarUrl = "mxc://local/new"

        // Server hasn't caught up yet — returns the stale member event.
        mock.roomMembersResult = [
            member("@alice:example.com", displayName: "Alice (old)", avatarUrl: "mxc://srv/old"),
            member("@bob:example.com",   displayName: "Bob",         avatarUrl: "mxc://srv/b"),
        ]

        await appState.refreshMemberProfiles()

        // Own profile reflects local state, not server's stale view.
        #expect(appState.avatarUrl(for: "@alice:example.com") == "mxc://local/new")
        #expect(appState.memberDisplayName(for: "@alice:example.com") == "Alice (local)")
        // Other users still come from server.
        #expect(appState.avatarUrl(for: "@bob:example.com") == "mxc://srv/b")
    }

    @Test("Sync update refreshes member profiles — picks up remote avatar changes")
    mutating func syncUpdatePicksUpRemoteAvatarChange() async {
        // Initial state: Bob has avatar A.
        mock.roomMembersResult = [member("@bob:example.com", avatarUrl: "mxc://srv/old")]
        await appState.refreshMemberProfiles()
        #expect(appState.avatarUrl(for: "@bob:example.com") == "mxc://srv/old")

        // Bob updates his avatar — sync brings the new state.
        mock.roomMembersResult = [member("@bob:example.com", avatarUrl: "mxc://srv/new")]

        await appState.handleSyncUpdate()

        // Cache should reflect the new avatar without needing to switch rooms.
        #expect(appState.avatarUrl(for: "@bob:example.com") == "mxc://srv/new")
    }

    @Test("Sync update does not fetch members when no room is selected")
    mutating func syncUpdateSkipsMembersWhenNoRoom() async {
        appState.selectedRoomId = nil
        await appState.roomRefreshTask?.value
        mock.roomMembersCalls.removeAll()

        await appState.handleSyncUpdate()

        #expect(mock.roomMembersCalls.isEmpty)
    }

    @Test("Update avatar populates own member profile entry")
    mutating func updateAvatarPopulatesOwnMemberProfile() async {
        mock.setAvatarResult = "mxc://example.com/fresh"

        await appState.updateAvatar(
            data: MediaTestHelpers.bytes([0xFF, 0xD8, 0xFF]),
            mimeType: "image/jpeg"
        )

        // The on-screen MemberAvatar reads from memberProfiles, not avatarUrl —
        // so updating the cache is what makes own messages reflect the new avatar
        // immediately, without waiting for a round-trip.
        #expect(appState.avatarUrl(for: "@alice:example.com") == "mxc://example.com/fresh")
    }

    @Test("Update display name populates own member profile entry")
    mutating func updateDisplayNamePopulatesOwnMemberProfile() async {
        await appState.updateDisplayName("Alice 2.0")

        #expect(appState.memberDisplayName(for: "@alice:example.com") == "Alice 2.0")
    }

    @Test("Selecting a room fetches member profiles")
    mutating func selectingRoomFetchesMembers() async {
        // Reset selection state from init.
        appState.selectedRoomId = nil
        await appState.roomRefreshTask?.value
        mock.roomMembersCalls.removeAll()
        mock.roomMembersResult = [member("@bob:example.com", avatarUrl: "mxc://srv/b")]

        appState.selectedRoomId = "!other:example.com"
        await appState.roomRefreshTask?.value

        #expect(mock.roomMembersCalls == ["!other:example.com"])
        #expect(appState.avatarUrl(for: "@bob:example.com") == "mxc://srv/b")
    }

    // MARK: - Sync update propagation

    @Test("Sync update refreshes rooms — picks up server-side room list changes")
    mutating func syncUpdateRefreshesRooms() async {
        // Initial sync brings one room.
        mock.roomsResult = [RoomInfo(
            id: "!room:example.com",
            displayName: "Original",
            isEncrypted: false,
            isPublic: true,
            isDirect: false,
            topic: nil,
            isInvited: false,
            unreadCount: 0
        )]
        await appState.handleSyncUpdate()
        #expect(appState.rooms.first?.displayName == "Original")

        // Server changes the room name; next sync tick should reflect it.
        mock.roomsResult = [RoomInfo(
            id: "!room:example.com",
            displayName: "Renamed",
            isEncrypted: false,
            isPublic: true,
            isDirect: false,
            topic: nil,
            isInvited: false,
            unreadCount: 0
        )]

        await appState.handleSyncUpdate()

        #expect(appState.rooms.first?.displayName == "Renamed")
    }

    @Test("Sync update appends new messages when room has messages")
    mutating func syncUpdateAppendsNewMessages() async {
        appState.messages = [makeMessage(eventId: "$old:x.com", body: "Old")]
        mock.messagesResult = MessageBatch(
            messages: [
                makeMessage(eventId: "$old:x.com", body: "Old"),
                makeMessage(eventId: "$new:x.com", body: "New"),
            ],
            endToken: nil
        )

        await appState.handleSyncUpdate()

        #expect(appState.messages.count == 2)
        #expect(appState.messages.contains(where: { $0.eventId == "$new:x.com" }))
    }

    @Test("Sync update falls back to refreshMessages when room is empty")
    mutating func syncUpdateFallsBackToRefreshForEmptyRoom() async {
        appState.messages = []
        mock.messagesResult = MessageBatch(
            messages: [makeMessage(eventId: "$e1:x.com", body: "History")],
            endToken: nil
        )

        await appState.handleSyncUpdate()

        // refreshMessages populates from scratch (appendNewMessages bails on empty).
        #expect(appState.messages.count == 1)
        #expect(appState.messages[0].body == "History")
    }

    // MARK: - Media cache eviction

    @Test("Update avatar evicts old mxc from media cache")
    mutating func updateAvatarEvictsOldCache() async {
        let oldMxc = "mxc://example.com/old"
        appState.avatarUrl = oldMxc
        // Prime the cache via loadMedia.
        mock.downloadMediaResult = MediaTestHelpers.stringBytes("old-bytes")
        _ = await appState.loadMedia(mxcUri: oldMxc)
        #expect(mock.downloadMediaCalls.count == 1)

        mock.setAvatarResult = "mxc://example.com/new"
        await appState.updateAvatar(
            data: MediaTestHelpers.bytes([0xFF]),
            mimeType: "image/png"
        )

        // Old URL should no longer be cached: another loadMedia call must
        // hit the network again. Without eviction, stale pixels linger.
        _ = await appState.loadMedia(mxcUri: oldMxc)
        #expect(mock.downloadMediaCalls.count == 2, "old mxc should have been evicted")
    }

    // MARK: - Appearance

    @Test("Appearance defaults to system when no preference is stored")
    func appearanceDefaultsToSystem() async {
        MediaTestHelpers.removeDefault(forKey: "parlotte.appearance-default.appearance")
        let fresh = AppState(profile: "appearance-default")
        #expect(fresh.appearance == .system)
    }

    @Test("Setting appearance persists to UserDefaults")
    func appearanceSettingPersists() async {
        MediaTestHelpers.removeDefault(forKey: "parlotte.appearance-set.appearance")
        let state = AppState(profile: "appearance-set")

        state.appearance = .dark

        #expect(MediaTestHelpers.getDefaultString(forKey: "parlotte.appearance-set.appearance") == "dark")

        MediaTestHelpers.removeDefault(forKey: "parlotte.appearance-set.appearance")
    }

    @Test("Appearance loads from UserDefaults on init")
    func appearanceLoadsFromDefaults() async {
        MediaTestHelpers.setDefault("light", forKey: "parlotte.appearance-load.appearance")
        defer { MediaTestHelpers.removeDefault(forKey: "parlotte.appearance-load.appearance") }

        let state = AppState(profile: "appearance-load")

        #expect(state.appearance == .light)
    }

    @Test("Appearance ignores unknown persisted values")
    func appearanceIgnoresUnknownStoredValue() async {
        MediaTestHelpers.setDefault("neon", forKey: "parlotte.appearance-bad.appearance")
        defer { MediaTestHelpers.removeDefault(forKey: "parlotte.appearance-bad.appearance") }

        let state = AppState(profile: "appearance-bad")

        #expect(state.appearance == .system)
    }

    @Test("Setting the same appearance does not write redundantly")
    func appearanceNoRedundantWrite() async {
        MediaTestHelpers.removeDefault(forKey: "parlotte.appearance-noop.appearance")
        let state = AppState(profile: "appearance-noop")

        state.appearance = .system

        #expect(MediaTestHelpers.getDefaultString(forKey: "parlotte.appearance-noop.appearance") == nil)
    }

    @Test("Remove avatar evicts old mxc from media cache")
    mutating func removeAvatarEvictsOldCache() async {
        let oldMxc = "mxc://example.com/old"
        appState.avatarUrl = oldMxc
        mock.downloadMediaResult = MediaTestHelpers.stringBytes("old-bytes")
        _ = await appState.loadMedia(mxcUri: oldMxc)
        #expect(mock.downloadMediaCalls.count == 1)

        await appState.removeAvatar()

        _ = await appState.loadMedia(mxcUri: oldMxc)
        #expect(mock.downloadMediaCalls.count == 2, "old mxc should have been evicted")
    }

    // MARK: - Room Settings (name, topic)

    @Test("Update room name applies optimistically and calls client")
    mutating func updateRoomNameOptimistic() async {
        let roomId = "!room:example.com"
        appState.rooms = [
            RoomInfo(id: roomId, displayName: "Old Name", isEncrypted: false, isPublic: false, isDirect: false,
                     topic: nil, isInvited: false, unreadCount: 0)
        ]

        await appState.updateRoomName(roomId: roomId, name: "New Name")

        #expect(appState.rooms[0].displayName == "New Name")
        #expect(mock.setRoomNameCalls.count == 1)
        #expect(mock.setRoomNameCalls[0].roomId == roomId)
        #expect(mock.setRoomNameCalls[0].name == "New Name")
        #expect(appState.isUpdatingRoomSettings == false)
    }

    @Test("Update room name reverts on failure")
    mutating func updateRoomNameRevertsOnFailure() async {
        let roomId = "!room:example.com"
        appState.rooms = [
            RoomInfo(id: roomId, displayName: "Old Name", isEncrypted: false, isPublic: false, isDirect: false,
                     topic: nil, isInvited: false, unreadCount: 0)
        ]
        mock.setRoomNameError = ParlotteError.Network(message: "nope")

        await appState.updateRoomName(roomId: roomId, name: "New Name")

        #expect(appState.rooms[0].displayName == "Old Name")
        #expect(appState.errorMessage != nil)
    }

    @Test("Update room name trims whitespace and ignores empty input")
    mutating func updateRoomNameIgnoresEmpty() async {
        let roomId = "!room:example.com"
        appState.rooms = [
            RoomInfo(id: roomId, displayName: "Original", isEncrypted: false, isPublic: false, isDirect: false,
                     topic: nil, isInvited: false, unreadCount: 0)
        ]

        await appState.updateRoomName(roomId: roomId, name: "   ")

        #expect(appState.rooms[0].displayName == "Original")
        #expect(mock.setRoomNameCalls.isEmpty)
    }

    @Test("Update room name is a no-op for unknown room")
    mutating func updateRoomNameUnknownRoom() async {
        appState.rooms = []

        await appState.updateRoomName(roomId: "!missing:example.com", name: "Whatever")

        #expect(mock.setRoomNameCalls.isEmpty)
    }

    @Test("Update room topic applies optimistically and calls client")
    mutating func updateRoomTopicOptimistic() async {
        let roomId = "!room:example.com"
        appState.rooms = [
            RoomInfo(id: roomId, displayName: "R", isEncrypted: false, isPublic: false, isDirect: false,
                     topic: "Old topic", isInvited: false, unreadCount: 0)
        ]

        await appState.updateRoomTopic(roomId: roomId, topic: "Fresh topic")

        #expect(appState.rooms[0].topic == "Fresh topic")
        #expect(mock.setRoomTopicCalls.count == 1)
        #expect(mock.setRoomTopicCalls[0].topic == "Fresh topic")
    }

    @Test("Update room topic reverts on failure")
    mutating func updateRoomTopicRevertsOnFailure() async {
        let roomId = "!room:example.com"
        appState.rooms = [
            RoomInfo(id: roomId, displayName: "R", isEncrypted: false, isPublic: false, isDirect: false,
                     topic: "Old topic", isInvited: false, unreadCount: 0)
        ]
        mock.setRoomTopicError = ParlotteError.Network(message: "fail")

        await appState.updateRoomTopic(roomId: roomId, topic: "New topic")

        #expect(appState.rooms[0].topic == "Old topic")
        #expect(appState.errorMessage != nil)
    }

    @Test("Update room topic with empty string clears the topic")
    mutating func updateRoomTopicClears() async {
        let roomId = "!room:example.com"
        appState.rooms = [
            RoomInfo(id: roomId, displayName: "R", isEncrypted: false, isPublic: false, isDirect: false,
                     topic: "Stale", isInvited: false, unreadCount: 0)
        ]

        await appState.updateRoomTopic(roomId: roomId, topic: "")

        #expect(appState.rooms[0].topic == nil)
        #expect(mock.setRoomTopicCalls.count == 1)
        #expect(mock.setRoomTopicCalls[0].topic == "")
    }

    @Test("Room settings changes from sync propagate to rooms list")
    mutating func roomSettingsPropagateViaSync() async {
        let roomId = "!room:example.com"
        appState.rooms = [
            RoomInfo(id: roomId, displayName: "Before", isEncrypted: false, isPublic: false, isDirect: false,
                     topic: "Before topic", isInvited: false, unreadCount: 0)
        ]
        // Simulate the server reflecting a rename + topic change in the next sync.
        mock.roomsResult = [
            RoomInfo(id: roomId, displayName: "After", isEncrypted: false, isPublic: false, isDirect: false,
                     topic: "After topic", isInvited: false, unreadCount: 0)
        ]

        await appState.handleSyncUpdate()

        #expect(appState.rooms[0].displayName == "After")
        #expect(appState.rooms[0].topic == "After topic")
    }

    // MARK: - Power Levels & Moderation

    @Test("setMemberPowerLevel forwards to the client with the selected room")
    mutating func setMemberPowerLevelForwards() async {
        await appState.setMemberPowerLevel(userId: "@bob:example.com", level: 50)

        #expect(mock.setUserPowerLevelCalls.count == 1)
        #expect(mock.setUserPowerLevelCalls[0].roomId == "!room:example.com")
        #expect(mock.setUserPowerLevelCalls[0].userId == "@bob:example.com")
        #expect(mock.setUserPowerLevelCalls[0].level == 50)
        #expect(appState.errorMessage == nil)
    }

    @Test("setMemberPowerLevel surfaces errors")
    mutating func setMemberPowerLevelSurfacesErrors() async {
        mock.setUserPowerLevelError = ParlotteError.Room(message: "denied")

        await appState.setMemberPowerLevel(userId: "@bob:example.com", level: 100)

        #expect(appState.errorMessage != nil)
    }

    @Test("kickMember calls client with reason")
    mutating func kickMemberCallsClient() async {
        await appState.kickMember(userId: "@bob:example.com", reason: "spam")

        #expect(mock.kickUserCalls.count == 1)
        #expect(mock.kickUserCalls[0].roomId == "!room:example.com")
        #expect(mock.kickUserCalls[0].userId == "@bob:example.com")
        #expect(mock.kickUserCalls[0].reason == "spam")
    }

    @Test("banMember forwards to the client")
    mutating func banMemberForwards() async {
        await appState.banMember(userId: "@bob:example.com")

        #expect(mock.banUserCalls.count == 1)
        #expect(mock.banUserCalls[0].userId == "@bob:example.com")
        #expect(mock.banUserCalls[0].reason == nil)
        #expect(appState.errorMessage == nil)
    }

    @Test("banMember surfaces errors")
    mutating func banMemberSurfacesErrors() async {
        mock.banUserError = ParlotteError.Room(message: "denied")

        await appState.banMember(userId: "@bob:example.com")

        #expect(appState.errorMessage != nil)
    }

    @Test("unbanMember calls client")
    mutating func unbanMemberCallsClient() async {
        await appState.unbanMember(userId: "@bob:example.com")

        #expect(mock.unbanUserCalls.count == 1)
        #expect(mock.unbanUserCalls[0].userId == "@bob:example.com")
    }

    @Test("Moderation actions are no-ops with no selected room")
    mutating func moderationNoOpsWithoutSelectedRoom() async {
        appState.selectedRoomId = nil

        await appState.setMemberPowerLevel(userId: "@bob:example.com", level: 50)
        await appState.kickMember(userId: "@bob:example.com")
        await appState.banMember(userId: "@bob:example.com")
        await appState.unbanMember(userId: "@bob:example.com")

        #expect(mock.setUserPowerLevelCalls.isEmpty)
        #expect(mock.kickUserCalls.isEmpty)
        #expect(mock.banUserCalls.isEmpty)
        #expect(mock.unbanUserCalls.isEmpty)
    }

    // MARK: - Recovery

    @Test("refreshRecoveryState pulls current state from the client")
    mutating func refreshRecoveryStateSyncsValue() async {
        mock.recoveryStateResult = .enabled
        await appState.refreshRecoveryState()
        #expect(appState.recoveryState == .enabled)
        #expect(mock.recoveryStateCalls == 1)
    }

    @Test("enableRecovery stores the returned key and refreshes state")
    mutating func enableRecoverySurfacesKey() async {
        mock.enableRecoveryResult = "Es Tb MY SECRET KEY"
        mock.recoveryStateResult = .enabled

        await appState.enableRecovery()

        #expect(appState.pendingRecoveryKey == "Es Tb MY SECRET KEY")
        #expect(appState.recoveryState == .enabled)
        #expect(appState.isUpdatingRecovery == false)
        #expect(mock.enableRecoveryCalls.count == 1)
    }

    @Test("enableRecovery leaves state untouched on error")
    mutating func enableRecoveryFailureLeavesStateClean() async {
        appState.recoveryState = .disabled
        mock.enableRecoveryError = TestError()

        await appState.enableRecovery()

        #expect(appState.pendingRecoveryKey == nil)
        #expect(appState.recoveryState == .disabled)
        #expect(appState.isUpdatingRecovery == false)
        #expect(appState.recoveryErrorMessage != nil)
    }

    @Test("disableRecovery refreshes state after success")
    mutating func disableRecoveryRefreshes() async {
        appState.recoveryState = .enabled
        mock.recoveryStateResult = .disabled

        await appState.disableRecovery()

        #expect(mock.disableRecoveryCalls == 1)
        #expect(appState.recoveryState == .disabled)
    }

    @Test("recover passes the key to the client")
    mutating func recoverForwardsKey() async {
        mock.recoveryStateResult = .enabled

        await appState.recover(recoveryKey: "Es Tb USER ENTERED KEY")

        #expect(mock.recoverCalls == ["Es Tb USER ENTERED KEY"])
        #expect(appState.recoveryState == .enabled)
    }

    @Test("dismissPendingRecoveryKey clears the stored key")
    mutating func dismissClearsPendingKey() {
        appState.pendingRecoveryKey = "Es Tb SOMETHING"
        appState.dismissPendingRecoveryKey()
        #expect(appState.pendingRecoveryKey == nil)
    }

    @Test("logout resets recovery state")
    mutating func logoutClearsRecoveryState() async {
        appState.recoveryState = .enabled
        appState.pendingRecoveryKey = "Es Tb KEY"

        await appState.logout()

        #expect(appState.recoveryState == .unknown)
        #expect(appState.pendingRecoveryKey == nil)
    }

    @Test("requestLogout prompts when last device without recovery")
    mutating func requestLogoutWarnsWhenLastDeviceNoRecovery() async {
        appState.isLoggedIn = true
        appState.recoveryState = .disabled
        mock.isLastDeviceResult = true

        await appState.requestLogout()

        #expect(appState.isConfirmingLastDeviceLogout == true)
        #expect(appState.isLoggedIn == true)
        #expect(mock.logoutCalls == 0)
    }

    @Test("requestLogout skips warning when recovery is enabled")
    mutating func requestLogoutSkipsWarningWhenRecoveryEnabled() async {
        appState.isLoggedIn = true
        appState.recoveryState = .enabled
        mock.isLastDeviceResult = true

        await appState.requestLogout()

        #expect(appState.isConfirmingLastDeviceLogout == false)
        #expect(appState.isLoggedIn == false)
        #expect(mock.logoutCalls == 1)
    }

    @Test("requestLogout skips warning when not last device")
    mutating func requestLogoutSkipsWarningWhenNotLastDevice() async {
        appState.isLoggedIn = true
        appState.recoveryState = .disabled
        mock.isLastDeviceResult = false

        await appState.requestLogout()

        #expect(appState.isConfirmingLastDeviceLogout == false)
        #expect(appState.isLoggedIn == false)
        #expect(mock.logoutCalls == 1)
    }

    // MARK: - Identity reset

    @Test("beginResetIdentity stores approval URL when server requires approval")
    mutating func beginResetIdentityStoresApprovalUrl() async {
        mock.beginResetIdentityResult = "https://mas.example.com/approve?nonce=x"

        await appState.beginResetIdentity()

        #expect(appState.resetIdentityApprovalUrl == "https://mas.example.com/approve?nonce=x")
        #expect(appState.isResettingIdentity == false)
        #expect(mock.beginResetIdentityCalls == 1)
        #expect(mock.finishResetIdentityCalls == 0)
    }

    @Test("beginResetIdentity finalises immediately when no approval needed")
    mutating func beginResetIdentityAutoFinishes() async {
        mock.beginResetIdentityResult = nil
        mock.finishResetIdentityResult = "Es Tb FRESH KEY"
        mock.recoveryStateResult = .enabled

        await appState.beginResetIdentity()

        #expect(appState.resetIdentityApprovalUrl == nil)
        #expect(appState.pendingRecoveryKey == "Es Tb FRESH KEY")
        #expect(appState.recoveryState == .enabled)
        #expect(mock.beginResetIdentityCalls == 1)
        #expect(mock.finishResetIdentityCalls == 1)
    }

    @Test("beginResetIdentity surfaces errors without leaving a stuck flag")
    mutating func beginResetIdentityErrorClearsFlag() async {
        mock.beginResetIdentityError = TestError()

        await appState.beginResetIdentity()

        #expect(appState.resetIdentityApprovalUrl == nil)
        #expect(appState.isResettingIdentity == false)
        #expect(appState.recoveryErrorMessage != nil)
    }

    @Test("finishResetIdentity surfaces the fresh key and clears the approval URL")
    mutating func finishResetIdentitySurfacesKey() async {
        appState.resetIdentityApprovalUrl = "https://mas.example.com/approve"
        mock.finishResetIdentityResult = "Es Tb FRESH KEY"
        mock.recoveryStateResult = .enabled

        await appState.finishResetIdentity()

        #expect(appState.pendingRecoveryKey == "Es Tb FRESH KEY")
        #expect(appState.resetIdentityApprovalUrl == nil)
        #expect(appState.recoveryState == .enabled)
        #expect(appState.isResettingIdentity == false)
        #expect(mock.finishResetIdentityCalls == 1)
    }

    @Test("finishResetIdentity keeps approval URL on failure so the user can retry")
    mutating func finishResetIdentityFailureKeepsApprovalUrl() async {
        appState.resetIdentityApprovalUrl = "https://mas.example.com/approve"
        mock.finishResetIdentityError = TestError()
        mock.recoveryStateResult = .incomplete

        await appState.finishResetIdentity()

        #expect(appState.pendingRecoveryKey == nil)
        #expect(appState.resetIdentityApprovalUrl == "https://mas.example.com/approve")
        #expect(appState.isResettingIdentity == false)
        #expect(appState.recoveryErrorMessage != nil)
    }

    @Test("cancelResetIdentity clears approval URL and calls through to client")
    mutating func cancelResetIdentityClearsState() async {
        appState.resetIdentityApprovalUrl = "https://mas.example.com/approve"
        appState.isResettingIdentity = true

        await appState.cancelResetIdentity()

        #expect(appState.resetIdentityApprovalUrl == nil)
        #expect(appState.isResettingIdentity == false)
        #expect(mock.cancelResetIdentityCalls == 1)
    }

    @Test("logout clears reset identity state")
    mutating func logoutClearsResetIdentityState() async {
        appState.resetIdentityApprovalUrl = "https://mas.example.com/approve"
        appState.isResettingIdentity = true

        await appState.logout()

        #expect(appState.resetIdentityApprovalUrl == nil)
        #expect(appState.isResettingIdentity == false)
    }
}
