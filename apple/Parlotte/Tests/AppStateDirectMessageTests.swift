import Testing
import ParlotteSDK
@testable import ParlotteLib

@MainActor
@Suite("AppState direct messages + user search")
struct AppStateDirectMessageTests {
    private func setup() -> (AppState, MockMatrixClient) {
        let mock = MockMatrixClient()
        let appState = AppState(profile: "test")
        appState.loggedInUserId = "@me:x.com"
        appState.client = mock
        return (appState, mock)
    }

    @Test("createDirectMessage calls the client, refreshes, and selects the room")
    mutating func createDmSelectsRoom() async {
        let (appState, mock) = setup()
        mock.createDmResult = "!dm:x.com"
        mock.roomsResult = [
            RoomInfo(id: "!dm:x.com", displayName: "Bob", isEncrypted: true, isPublic: false, isDirect: true, topic: nil, isInvited: false, unreadCount: 0),
        ]

        let roomId = await appState.createDirectMessage(userId: "@bob:x.com")

        #expect(roomId == "!dm:x.com")
        #expect(mock.createDmCalls == ["@bob:x.com"])
        #expect(appState.selectedRoomId == "!dm:x.com")
        #expect(appState.rooms.contains { $0.id == "!dm:x.com" && $0.isDirect })
    }

    @Test("createDirectMessage surfaces an error and selects nothing on failure")
    mutating func createDmFailure() async {
        let (appState, mock) = setup()
        mock.createDmError = ParlotteError.Room(message: "no such user")

        let roomId = await appState.createDirectMessage(userId: "@ghost:x.com")

        #expect(roomId == nil)
        #expect(appState.errorMessage != nil)
        #expect(appState.selectedRoomId == nil)
    }

    @Test("searchUsers returns directory results")
    mutating func searchUsersReturnsResults() async {
        let (appState, mock) = setup()
        mock.searchUsersResult = [
            UserSearchResult(userId: "@bob:x.com", displayName: "Bob", avatarUrl: nil),
            UserSearchResult(userId: "@bobby:x.com", displayName: nil, avatarUrl: nil),
        ]

        let results = await appState.searchUsers(term: "bob")

        #expect(results.count == 2)
        #expect(mock.searchUsersCalls.first?.term == "bob")
        #expect(results.first?.userId == "@bob:x.com")
    }

    @Test("searchUsers skips empty input without hitting the client")
    mutating func searchUsersEmptyInput() async {
        let (appState, mock) = setup()

        let results = await appState.searchUsers(term: "   ")

        #expect(results.isEmpty)
        #expect(mock.searchUsersCalls.isEmpty)
    }

    @Test("searchUsers swallows errors (non-fatal, no global error banner)")
    mutating func searchUsersErrorIsNonFatal() async {
        let (appState, mock) = setup()
        mock.searchUsersError = ParlotteError.Network(message: "offline")

        let results = await appState.searchUsers(term: "bob")

        #expect(results.isEmpty)
        #expect(appState.errorMessage == nil, "search failures must not hijack the error banner")
    }
}
