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

    /// Seed a valid end-token so loadMoreMessages proceeds past the guard.
    /// Uses the pagination path: initial messages() call returns endToken.
    private mutating func seedEndToken(_ token: String = "tok-1") async {
        mock.messagesResult = MessageBatch(
            messages: [makeMessage(eventId: "$seed:example.com")],
            endToken: token
        )
        await appState.refreshMessages()
        mock.messagesCalls.removeAll()
    }

    // MARK: - loadMoreMessages

    @Test("loadMoreMessages clears isLoadingMoreMessages after an error")
    mutating func loadMoreMessagesErrorClearsLoadingFlag() async {
        await seedEndToken()
        mock.messagesError = ParlotteError.Network(message: "boom")

        await appState.loadMoreMessages()

        #expect(appState.isLoadingMoreMessages == false)
    }

    @Test("loadMoreMessages bails while another load is in flight")
    mutating func loadMoreMessagesConcurrencyGuard() async {
        await seedEndToken()
        appState.isLoadingMoreMessages = true

        await appState.loadMoreMessages()

        // Guard should prevent any network call.
        #expect(mock.messagesCalls.isEmpty)
        // We only set the flag, never cleared it — the method must not have
        // touched it (no isLoadingMoreMessages = false side-effect).
        #expect(appState.isLoadingMoreMessages == true)
    }

    @Test("loadMoreMessages keeps paginating on an all-duplicate page that still has a token")
    mutating func loadMoreMessagesAllDuplicatesWithToken() async {
        await seedEndToken()
        // Server returns only duplicates, but still offers a next token — the
        // timeline grew between the initial fetch and this call. We must NOT
        // treat "nothing new" as "no more history": advance to the token.
        mock.messagesResult = MessageBatch(
            messages: [makeMessage(eventId: "$seed:example.com")],
            endToken: "tok-2"
        )

        await appState.loadMoreMessages()

        #expect(appState.hasMoreMessages == true)
        // The cursor advanced, so a further call does hit the network again.
        mock.messagesCalls.removeAll()
        await appState.loadMoreMessages()
        #expect(mock.messagesCalls.first?.from == "tok-2")
    }

    @Test("loadMoreMessages stops paginating only when the server returns no token")
    mutating func loadMoreMessagesStopsOnNilToken() async {
        await seedEndToken()
        mock.messagesResult = MessageBatch(
            messages: [makeMessage(eventId: "$older:example.com")],
            endToken: nil
        )

        await appState.loadMoreMessages()

        #expect(appState.hasMoreMessages == false)
        // nil token ends history: a second call is a no-op (guard fires).
        mock.messagesCalls.removeAll()
        await appState.loadMoreMessages()
        #expect(mock.messagesCalls.isEmpty)
    }

    // MARK: - appendNewMessages edit echo

    @Test("appendNewMessages applies a formatted-only edit echo")
    mutating func appendNewMessagesAppliesFormattedEdit() async {
        // Mirrors an optimistic edit: body set, formattedBody cleared, isEdited
        // true. The server echo has the same body/isEdited but a rich
        // formattedBody — it must replace the plain optimistic version.
        let optimistic = MessageInfo(
            eventId: "$e:example.com", sender: "@me:x.com", body: "hello",
            formattedBody: nil, messageType: "text", timestampMs: 1_700_000_000_000,
            isEdited: true, repliedToEventId: nil, mediaSource: nil, mediaMimeType: nil,
            mediaWidth: nil, mediaHeight: nil, mediaSize: nil, reactions: []
        )
        appState.messages = [optimistic]

        let serverEcho = MessageInfo(
            eventId: "$e:example.com", sender: "@me:x.com", body: "hello",
            formattedBody: "<strong>hello</strong>", messageType: "text",
            timestampMs: 1_700_000_000_000, isEdited: true, repliedToEventId: nil,
            mediaSource: nil, mediaMimeType: nil, mediaWidth: nil, mediaHeight: nil,
            mediaSize: nil, reactions: []
        )
        mock.messagesResult = MessageBatch(messages: [serverEcho], endToken: nil)

        await appState.appendNewMessages()

        #expect(appState.messages.count == 1)
        #expect(appState.messages[0].formattedBody == "<strong>hello</strong>",
                "formatted-only edit echo should be applied")
    }

    // MARK: - toggleReaction

    @Test("toggleReaction on a nonexistent message is a no-op")
    mutating func toggleReactionMissingMessage() async {
        appState.messages = [makeMessage(eventId: "$known:example.com")]
        mock.sendReactionCalls.removeAll()

        await appState.toggleReaction(eventId: "$nonexistent:example.com", key: "👍")

        #expect(mock.sendReactionCalls.isEmpty)
        #expect(mock.redactReactionCalls.isEmpty)
        #expect(appState.messages[0].reactions.isEmpty)
        #expect(appState.errorMessage == nil)
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

    // MARK: - deleteMessage revert

    @Test("deleteMessage revert restores the message at its original index")
    mutating func deleteMessageRevertPreservesPosition() async {
        appState.messages = [
            makeMessage(eventId: "$a:example.com", body: "first"),
            makeMessage(eventId: "$b:example.com", body: "middle"),
            makeMessage(eventId: "$c:example.com", body: "last"),
        ]
        mock.redactMessageError = ParlotteError.Room(message: "forbidden")

        await appState.deleteMessage(eventId: "$b:example.com")

        #expect(appState.messages.count == 3)
        #expect(appState.messages[0].eventId == "$a:example.com")
        #expect(appState.messages[1].eventId == "$b:example.com")
        #expect(appState.messages[2].eventId == "$c:example.com")
        #expect(appState.errorMessage != nil)
    }
}
