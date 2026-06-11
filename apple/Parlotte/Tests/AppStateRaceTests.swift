import Testing
import ParlotteSDK
@testable import ParlotteLib

/// Races where a network response lands after the user switched rooms or
/// logged out. The fix is a `(roomId, sessionEpoch)` recheck after every
/// await before writing to message/room state.
@MainActor
@Suite("AppState stale-response races")
struct AppStateRaceTests {
    private func makeMessage(_ eventId: String, sender: String, body: String) -> MessageInfo {
        MessageInfo(
            eventId: eventId, sender: sender, body: body, formattedBody: nil,
            messageType: "text", timestampMs: 1_700_000_000_000, isEdited: false,
            repliedToEventId: nil, mediaSource: nil, mediaMimeType: nil,
            mediaWidth: nil, mediaHeight: nil, mediaSize: nil, reactions: []
        )
    }

    private func setup() -> (AppState, MockMatrixClient) {
        let mock = MockMatrixClient()
        let appState = AppState(profile: "test")
        appState.loggedInUserId = "@me:x.com"
        appState.client = mock
        return (appState, mock)
    }

    /// Spin the MainActor until the gated `messages` call has suspended.
    private func awaitGateArmed(_ mock: MockMatrixClient) async {
        var spins = 0
        while !mock.isGateArmed {
            await Task.yield()
            spins += 1
            #expect(spins < 100_000, "gate never armed")
            if spins >= 100_000 { return }
        }
    }

    @Test("refreshMessages drops a response that arrives after a room switch")
    mutating func refreshMessagesStaleDropped() async {
        let (appState, mock) = setup()
        mock.messagesResultByRoom = [
            "!a:x.com": MessageBatch(messages: [makeMessage("$a", sender: "@x:x.com", body: "room A")], endToken: nil),
            "!b:x.com": MessageBatch(messages: [makeMessage("$b", sender: "@x:x.com", body: "room B")], endToken: nil),
        ]
        mock.gatedRoom = "!a:x.com"

        appState.selectedRoomId = "!a:x.com"
        let taskA = appState.roomRefreshTask
        await awaitGateArmed(mock)

        // Switch to B while A's fetch is suspended; B resolves immediately.
        appState.selectedRoomId = "!b:x.com"
        await appState.roomRefreshTask?.value
        #expect(appState.messages.map(\.eventId) == ["$b"])

        // A's fetch now resumes — it must NOT overwrite B's timeline.
        mock.releaseGate()
        await taskA?.value
        #expect(appState.messages.map(\.eventId) == ["$b"], "stale room A response clobbered room B")
    }

    @Test("appendNewMessages drops a response that arrives after a room switch")
    mutating func appendNewMessagesStaleDropped() async {
        let (appState, mock) = setup()
        // Seed room B's view with its own messages so we can detect corruption.
        appState.selectedRoomId = "!b:x.com"
        await appState.roomRefreshTask?.value
        appState.messages = [makeMessage("$b1", sender: "@x:x.com", body: "B one")]

        mock.messagesResultByRoom = [
            "!a:x.com": MessageBatch(messages: [makeMessage("$a1", sender: "@x:x.com", body: "A one")], endToken: nil),
        ]
        // Pretend a sync tick for room A is in flight: call appendNewMessages
        // with A selected, gate it, then switch to B before it resolves.
        appState.selectedRoomId = "!a:x.com"
        await appState.roomRefreshTask?.value
        appState.messages = [makeMessage("$a0", sender: "@x:x.com", body: "A zero")]

        mock.gatedRoom = "!a:x.com"
        let appendTask = Task { await appState.appendNewMessages() }
        await awaitGateArmed(mock)

        appState.selectedRoomId = "!b:x.com"
        await appState.roomRefreshTask?.value
        appState.messages = [makeMessage("$b1", sender: "@x:x.com", body: "B one")]

        mock.releaseGate()
        await appendTask.value
        // B's timeline must be intact: not deleted, not appended-to with A's events.
        #expect(appState.messages.map(\.eventId) == ["$b1"], "stale append corrupted room B")
    }

    @Test("refreshMessages drops a response that arrives after logout")
    mutating func refreshMessagesDroppedAfterLogout() async {
        let (appState, mock) = setup()
        appState.isLoggedIn = true
        mock.messagesResultByRoom = [
            "!a:x.com": MessageBatch(messages: [makeMessage("$a", sender: "@x:x.com", body: "room A")], endToken: nil),
        ]
        mock.gatedRoom = "!a:x.com"

        appState.selectedRoomId = "!a:x.com"
        let taskA = appState.roomRefreshTask
        await awaitGateArmed(mock)

        await appState.logout()
        #expect(appState.messages.isEmpty)

        mock.releaseGate()
        await taskA?.value
        #expect(appState.messages.isEmpty, "a post-logout response repopulated message state")
    }

    @Test("loadMoreMessages advances the cursor on a fully-overlapping page")
    mutating func loadMoreAdvancesCursorOnOverlap() async {
        let (appState, mock) = setup()
        appState.selectedRoomId = "!a:x.com"
        await appState.roomRefreshTask?.value

        // Seed an end-token via the pagination path (matches existing tests).
        mock.messagesResult = MessageBatch(
            messages: [makeMessage("$dup", sender: "@x:x.com", body: "dup")],
            endToken: "tok1"
        )
        await appState.refreshMessages()
        #expect(appState.hasMoreMessages == true)

        // A page that fully overlaps what we already have, but the server
        // still offers a next token — must keep paginating, not declare
        // end-of-history (the old code stopped on an all-duplicate page).
        mock.messagesResult = MessageBatch(
            messages: [makeMessage("$dup", sender: "@x:x.com", body: "dup")],
            endToken: "tok2"
        )
        await appState.loadMoreMessages()
        #expect(appState.hasMoreMessages == true, "overlap page must not stop pagination when a token remains")
    }
}
