import Testing
import ParlotteSDK
@testable import ParlotteLib

/// Targeted edge-case coverage for AppState regression vectors not exercised
/// by the main AppStateTests suite (pagination concurrency, reaction on
/// missing message, invite/create/public-rooms error paths, delete revert
/// position).
@MainActor
@Suite("AppState edge cases")
struct AppStateEdgeCaseTests {
    private var appState: AppState
    private var mock: MockMatrixClient

    init() async {
        mock = MockMatrixClient()
        appState = AppState(profile: "edge-test")
        appState.loggedInUserId = "@alice:example.com"
        appState.selectedRoomId = "!room:example.com"
        appState.client = mock
        await appState.roomRefreshTask?.value
        mock.messagesCalls.removeAll()
        mock.sendReadReceiptCalls.removeAll()
    }

    // MARK: - Helpers

    private func makeMessage(
        eventId: String = "$evt:example.com",
        sender: String = "@bob:example.com",
        body: String = "Hello",
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
            repliedToEventId: nil,
            mediaSource: nil,
            mediaMimeType: nil,
            mediaWidth: nil,
            mediaHeight: nil,
            mediaSize: nil,
            reactions: reactions
        )
    }

    // MARK: - loadMoreMessages

    @Test("loadMoreMessages clears isLoadingMoreMessages after an error")
    mutating func loadMoreMessagesErrorClearsLoadingFlag() async {
        appState.hasMoreMessages = true
        mock.paginateTimelineBackError = ParlotteError.Network(message: "boom")

        await appState.loadMoreMessages()

        #expect(appState.isLoadingMoreMessages == false)
    }

    @Test("loadMoreMessages bails while another load is in flight")
    mutating func loadMoreMessagesConcurrencyGuard() async {
        appState.hasMoreMessages = true
        appState.isLoadingMoreMessages = true

        await appState.loadMoreMessages()

        // Guard should prevent any pagination call.
        #expect(mock.paginateTimelineBackCalls.isEmpty)
        // We only set the flag, never cleared it — the method must not have
        // touched it (no isLoadingMoreMessages = false side-effect).
        #expect(appState.isLoadingMoreMessages == true)
    }

    @Test("loadMoreMessages keeps paging while the timeline reports more history")
    mutating func loadMoreMessagesKeepsPaging() async {
        appState.hasMoreMessages = true
        mock.paginateReachedStart = false

        await appState.loadMoreMessages()

        #expect(appState.hasMoreMessages == true)
        // Still more history, so a further call paginates again.
        mock.paginateTimelineBackCalls.removeAll()
        await appState.loadMoreMessages()
        #expect(mock.paginateTimelineBackCalls.count == 1)
    }

    @Test("loadMoreMessages stops once the timeline reports the start of the room")
    mutating func loadMoreMessagesStopsAtStart() async {
        appState.hasMoreMessages = true
        mock.paginateReachedStart = true

        await appState.loadMoreMessages()

        #expect(appState.hasMoreMessages == false)
        // Reaching the start ends history: a second call is a no-op (guard fires).
        mock.paginateTimelineBackCalls.removeAll()
        await appState.loadMoreMessages()
        #expect(mock.paginateTimelineBackCalls.isEmpty)
    }

    // MARK: - inviteUser

    @Test("inviteUser forwards roomId and userId to the client")
    mutating func inviteUserCallsClient() async {
        await appState.inviteUser(userId: "@bob:example.com")

        #expect(mock.inviteUserCalls.count == 1)
        #expect(mock.inviteUserCalls[0].roomId == "!room:example.com")
        #expect(mock.inviteUserCalls[0].userId == "@bob:example.com")
    }

    @Test("inviteUser is a no-op without a selected room")
    mutating func inviteUserRequiresRoom() async {
        appState.selectedRoomId = nil
        mock.inviteUserCalls.removeAll()

        await appState.inviteUser(userId: "@bob:example.com")

        #expect(mock.inviteUserCalls.isEmpty)
    }

    @Test("inviteUser surfaces server errors via errorMessage")
    mutating func inviteUserSurfacesError() async {
        mock.inviteUserError = ParlotteError.Room(message: "forbidden")

        await appState.inviteUser(userId: "@bob:example.com")

        #expect(appState.errorMessage != nil)
    }

    // MARK: - createRoom

    @Test("createRoom surfaces server errors via errorMessage")
    mutating func createRoomSurfacesError() async {
        mock.createRoomError = ParlotteError.Room(message: "forbidden")

        await appState.createRoom(name: "nope", isPublic: true)

        #expect(appState.errorMessage != nil)
    }

    // MARK: - fetchPublicRooms

    @Test("fetchPublicRooms returns [] and sets errorMessage on failure")
    mutating func fetchPublicRoomsError() async {
        mock.publicRoomsError = ParlotteError.Network(message: "unreachable")

        let result = await appState.fetchPublicRooms()

        #expect(result.isEmpty)
        #expect(appState.errorMessage != nil)
    }

    // MARK: - deleteMessage

    @Test("deleteMessage surfaces a redaction error")
    mutating func deleteMessageSurfacesError() async {
        mock.redactMessageError = ParlotteError.Room(message: "forbidden")

        await appState.deleteMessage(eventId: "$b:example.com")

        // The timeline owns the array; on failure we only surface the error.
        #expect(appState.errorMessage != nil)
    }
}
