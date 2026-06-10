import Testing
import ParlotteSDK
@testable import ParlotteLib

private struct TestError: Error {}

@MainActor
@Suite("AppState ignore users")
struct AppStateIgnoreTests {
    private var appState: AppState
    private var mock: MockMatrixClient

    init() async {
        mock = MockMatrixClient()
        appState = AppState(profile: "test")
        appState.loggedInUserId = "@alice:example.com"
        appState.selectedRoomId = "!room:example.com"
        appState.client = mock
        await appState.roomRefreshTask?.value
        mock.messagesCalls.removeAll()
        mock.sendReadReceiptCalls.removeAll()
    }

    private func makeMessage(
        eventId: String = "$evt1:example.com",
        sender: String = "@bob:example.com",
        body: String = "Hello"
    ) -> MessageInfo {
        MessageInfo(
            eventId: eventId,
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

    // MARK: - Ignore / unignore actions

    @Test("Ignore user adds to set optimistically and calls client")
    mutating func ignoreUserOptimistic() async {
        await appState.ignoreUser(userId: "@bob:example.com")

        #expect(appState.ignoredUsers == ["@bob:example.com"])
        #expect(mock.ignoreUserCalls == ["@bob:example.com"])
    }

    @Test("Ignore user reverts on failure")
    mutating func ignoreUserRevertsOnFailure() async {
        mock.ignoreUserError = TestError()
        await appState.ignoreUser(userId: "@bob:example.com")

        #expect(appState.ignoredUsers.isEmpty)
        #expect(appState.errorMessage != nil)
    }

    @Test("Unignore user removes from set and calls client")
    mutating func unignoreUserRemoves() async {
        appState.ignoredUsers = ["@bob:example.com"]
        await appState.unignoreUser(userId: "@bob:example.com")

        #expect(appState.ignoredUsers.isEmpty)
        #expect(mock.unignoreUserCalls == ["@bob:example.com"])
    }

    @Test("Unignore user reverts on failure")
    mutating func unignoreUserRevertsOnFailure() async {
        appState.ignoredUsers = ["@bob:example.com"]
        mock.unignoreUserError = TestError()
        await appState.unignoreUser(userId: "@bob:example.com")

        #expect(appState.ignoredUsers == ["@bob:example.com"])
        #expect(appState.errorMessage != nil)
    }

    // MARK: - Timeline filtering

    @Test("visibleMessages hides messages from ignored senders")
    mutating func visibleMessagesFiltersIgnored() async {
        appState.messages = [
            makeMessage(eventId: "$1:example.com", sender: "@bob:example.com"),
            makeMessage(eventId: "$2:example.com", sender: "@carol:example.com"),
            makeMessage(eventId: "$3:example.com", sender: "@bob:example.com"),
        ]
        appState.ignoredUsers = ["@bob:example.com"]

        #expect(appState.visibleMessages.map(\.eventId) == ["$2:example.com"])
        // Raw array is untouched so pagination/dedup state stays consistent.
        #expect(appState.messages.count == 3)
    }

    @Test("visibleMessages passes everything through when nobody is ignored")
    mutating func visibleMessagesUnfilteredByDefault() async {
        appState.messages = [makeMessage()]

        #expect(appState.visibleMessages.count == 1)
    }

    // MARK: - Refresh from account data

    @Test("Refresh loads ignored users from client")
    mutating func refreshLoadsFromClient() async {
        mock.ignoredUsersResult = ["@bob:example.com", "@mallory:example.com"]
        await appState.refreshIgnoredUsers()

        #expect(appState.ignoredUsers == ["@bob:example.com", "@mallory:example.com"])
    }

    @Test("Refresh keeps a just-ignored user the server hasn't echoed yet")
    mutating func refreshKeepsPendingIgnore() async {
        await appState.ignoreUser(userId: "@bob:example.com")

        // Server list doesn't include bob yet (sync echo lag).
        mock.ignoredUsersResult = []
        await appState.refreshIgnoredUsers()
        #expect(appState.ignoredUsers == ["@bob:example.com"])

        // Once the server echoes it, the pin is dropped and the server wins.
        mock.ignoredUsersResult = ["@bob:example.com"]
        await appState.refreshIgnoredUsers()
        mock.ignoredUsersResult = []
        await appState.refreshIgnoredUsers()
        #expect(appState.ignoredUsers.isEmpty)
    }

    @Test("Refresh keeps a just-unignored user out while the server still lists them")
    mutating func refreshKeepsPendingUnignore() async {
        appState.ignoredUsers = ["@bob:example.com"]
        await appState.unignoreUser(userId: "@bob:example.com")

        // Server list still contains bob (sync echo lag).
        mock.ignoredUsersResult = ["@bob:example.com"]
        await appState.refreshIgnoredUsers()
        #expect(appState.ignoredUsers.isEmpty)

        // Once the server drops bob, a later re-ignore from another device sticks.
        mock.ignoredUsersResult = []
        await appState.refreshIgnoredUsers()
        mock.ignoredUsersResult = ["@bob:example.com"]
        await appState.refreshIgnoredUsers()
        #expect(appState.ignoredUsers == ["@bob:example.com"])
    }

    @Test("Refresh failure keeps the current set")
    mutating func refreshFailureKeepsState() async {
        appState.ignoredUsers = ["@bob:example.com"]
        mock.ignoredUsersError = TestError()
        await appState.refreshIgnoredUsers()

        #expect(appState.ignoredUsers == ["@bob:example.com"])
    }

    // MARK: - Sync and logout triggers

    @Test("Sync update refreshes the ignored user list")
    mutating func syncUpdateRefreshesIgnored() async {
        mock.ignoredUsersResult = ["@bob:example.com"]
        await appState.handleSyncUpdate()

        #expect(appState.ignoredUsers == ["@bob:example.com"])
    }

    @Test("Logout clears ignored users")
    mutating func logoutClearsIgnored() async {
        appState.ignoredUsers = ["@bob:example.com"]
        await appState.logout()

        #expect(appState.ignoredUsers.isEmpty)
    }
}
