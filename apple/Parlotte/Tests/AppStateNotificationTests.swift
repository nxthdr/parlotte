import Foundation
import Testing
import ParlotteSDK
@testable import ParlotteLib

@MainActor
final class MockNotificationDispatcher: NotificationDispatcher {
    var requestAuthorizationCalls = 0
    var authorizationResult = true
    var postedNotifications: [(roomId: String, title: String, body: String)] = []

    func requestAuthorization() async -> Bool {
        requestAuthorizationCalls += 1
        return authorizationResult
    }

    func postMessageNotification(roomId: String, title: String, body: String) {
        postedNotifications.append((roomId, title, body))
    }
}

@MainActor
@Suite("AppState Notifications")
struct AppStateNotificationTests {
    private var appState: AppState
    private var mock: MockMatrixClient
    private var dispatcher: MockNotificationDispatcher

    init() async {
        mock = MockMatrixClient()
        dispatcher = MockNotificationDispatcher()
        // Unique profile per test so UserDefaults writes (e.g. notificationsEnabled)
        // don't leak into sibling tests when Swift Testing runs them in parallel.
        appState = AppState(profile: "test-notifications-\(UUID().uuidString)")
        appState.loggedInUserId = "@alice:example.com"
        appState.client = mock
        appState.notificationDispatcher = dispatcher
        // Default to "app is active" — individual tests override when needed.
        appState.isAppActiveProvider = { true }
    }

    private func room(
        id: String,
        name: String = "Room",
        unread: UInt64 = 0,
        isInvited: Bool = false
    ) -> RoomInfo {
        RoomInfo(
            id: id,
            displayName: name,
            isEncrypted: false,
            isPublic: false,
            isDirect: false,
            topic: nil,
            isInvited: isInvited,
            unreadCount: unread
        )
    }

    private func message(sender: String = "@bob:example.com", body: String = "Hello") -> MessageInfo {
        MessageInfo(
            eventId: "$msg:example.com",
            sender: sender,
            body: body,
            formattedBody: nil,
            messageType: "text",
            timestampMs: 1_700_000_000_000,
            isEdited: false,
            repliedToEventId: nil,
            mediaSource: nil,
            mediaMimeType: nil,
            mediaWidth: nil,
            mediaHeight: nil,
            mediaSize: nil,
            reactions: []
        )
    }

    @Test("First refresh never notifies — no prior state to diff against")
    mutating func firstRefreshSuppressesNotifications() async {
        mock.roomsResult = [room(id: "!a", unread: 5), room(id: "!b", unread: 0)]
        mock.messagesResult = MessageBatch(messages: [message()], endToken: nil)

        await appState.refreshRooms()

        #expect(dispatcher.postedNotifications.isEmpty)
    }

    @Test("Unread count increase for a non-selected room posts a notification")
    mutating func deltaTriggersNotification() async {
        mock.roomsResult = [room(id: "!a", name: "Alpha", unread: 0)]
        mock.messagesResult = MessageBatch(messages: [], endToken: nil)
        await appState.refreshRooms()

        mock.roomsResult = [room(id: "!a", name: "Alpha", unread: 2)]
        mock.messagesResult = MessageBatch(
            messages: [message(sender: "@bob:example.com", body: "Hey there")],
            endToken: nil
        )
        await appState.refreshRooms()

        #expect(dispatcher.postedNotifications.count == 1)
        #expect(dispatcher.postedNotifications[0].roomId == "!a")
        #expect(dispatcher.postedNotifications[0].title == "Alpha")
        #expect(dispatcher.postedNotifications[0].body == "bob: Hey there")
    }

    @Test("Selected room is skipped while app is active")
    mutating func selectedRoomSkippedWhenActive() async {
        appState.selectedRoomId = "!a"
        await appState.roomRefreshTask?.value
        mock.roomsResult = [room(id: "!a", unread: 0)]
        await appState.refreshRooms()

        mock.roomsResult = [room(id: "!a", unread: 1)]
        await appState.refreshRooms()

        #expect(dispatcher.postedNotifications.isEmpty)
    }

    @Test("Selected room still notifies when app is inactive")
    mutating func selectedRoomNotifiesWhenInactive() async {
        appState.selectedRoomId = "!a"
        await appState.roomRefreshTask?.value
        appState.isAppActiveProvider = { false }

        mock.roomsResult = [room(id: "!a", unread: 0)]
        await appState.refreshRooms()

        mock.roomsResult = [room(id: "!a", unread: 1)]
        mock.messagesResult = MessageBatch(messages: [message()], endToken: nil)
        await appState.refreshRooms()

        #expect(dispatcher.postedNotifications.count == 1)
    }

    @Test("Disabling notifications suppresses dispatch entirely")
    mutating func disabledSuppresses() async {
        mock.roomsResult = [room(id: "!a", unread: 0)]
        await appState.refreshRooms()

        appState.notificationsEnabled = false
        mock.roomsResult = [room(id: "!a", unread: 3)]
        await appState.refreshRooms()

        #expect(dispatcher.postedNotifications.isEmpty)
    }

    @Test("Unchanged unread count does not notify")
    mutating func unchangedCountSilent() async {
        mock.roomsResult = [room(id: "!a", unread: 2)]
        await appState.refreshRooms()
        mock.roomsResult = [room(id: "!a", unread: 2)]
        await appState.refreshRooms()

        #expect(dispatcher.postedNotifications.isEmpty)
    }

    @Test("Invited-but-not-joined rooms are not diffed for notifications")
    mutating func invitedRoomsSkipped() async {
        mock.roomsResult = [room(id: "!a", unread: 0, isInvited: true)]
        await appState.refreshRooms()
        mock.roomsResult = [room(id: "!a", unread: 3, isInvited: true)]
        await appState.refreshRooms()

        #expect(dispatcher.postedNotifications.isEmpty)
    }

    @Test("Message fetch failure falls back to generic body")
    mutating func fetchFailureFallback() async {
        mock.roomsResult = [room(id: "!a", name: "Alpha", unread: 0)]
        await appState.refreshRooms()

        mock.roomsResult = [room(id: "!a", name: "Alpha", unread: 1)]
        mock.messagesError = ParlotteError.Room(message: "nope")
        await appState.refreshRooms()

        #expect(dispatcher.postedNotifications.count == 1)
        #expect(dispatcher.postedNotifications[0].body == "New message")
    }

    @Test("Long message bodies are truncated in the preview")
    mutating func longBodyTruncated() async {
        mock.roomsResult = [room(id: "!a", unread: 0)]
        await appState.refreshRooms()

        let longBody = String(repeating: "x", count: 300)
        mock.roomsResult = [room(id: "!a", unread: 1)]
        mock.messagesResult = MessageBatch(
            messages: [message(body: longBody)],
            endToken: nil
        )
        await appState.refreshRooms()

        #expect(dispatcher.postedNotifications.count == 1)
        #expect(dispatcher.postedNotifications[0].body.hasSuffix("…"))
        // "bob: " prefix + 120 chars + "…"
        #expect(dispatcher.postedNotifications[0].body.count == "bob: ".count + 121)
    }

    @Test("openRoom switches selection when room is joined")
    mutating func openRoomSwitches() async {
        appState.rooms = [room(id: "!a"), room(id: "!b")]
        appState.openRoom("!b")
        #expect(appState.selectedRoomId == "!b")
    }

    @Test("openRoom is a no-op when room is not joined")
    mutating func openRoomUnknown() async {
        appState.rooms = [room(id: "!a")]
        appState.selectedRoomId = "!a"
        await appState.roomRefreshTask?.value
        appState.openRoom("!unknown")
        #expect(appState.selectedRoomId == "!a")
    }

    @Test("Logout clears unread-count tracking so the next login doesn't fire historical notifications")
    mutating func logoutClearsTracking() async {
        mock.roomsResult = [room(id: "!a", unread: 2)]
        await appState.refreshRooms()

        await appState.logout()

        // After logout, the next refresh is effectively a "first" refresh again.
        appState.client = mock
        appState.notificationDispatcher = dispatcher
        mock.roomsResult = [room(id: "!a", unread: 5)]
        await appState.refreshRooms()

        #expect(dispatcher.postedNotifications.isEmpty)
    }

    @Test("Selected room with steady unread does not re-notify on every tick")
    mutating func selectedRoomNoDuplicateNotifications() async {
        // App backgrounded so the selected room is a notification candidate;
        // its read receipt hasn't propagated yet, so the server keeps reporting
        // a nonzero unread count across ticks.
        appState.isAppActiveProvider = { false }
        appState.selectedRoomId = "!sel:x.com"
        await appState.roomRefreshTask?.value
        dispatcher.postedNotifications.removeAll()

        mock.roomsResult = [room(id: "!sel:x.com", name: "Sel", unread: 5)]
        _ = await appState.refreshRooms() // first sight: no prior count, no notify
        _ = await appState.refreshRooms() // steady count: must not notify again

        let selNotifs = dispatcher.postedNotifications.filter { $0.roomId == "!sel:x.com" }
        #expect(selNotifs.isEmpty,
                "a steady server unread must not produce a notification every tick")
    }
}
