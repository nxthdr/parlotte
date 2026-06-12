#if DEBUG
import Testing
import ParlotteSDK
@testable import ParlotteLib

@MainActor
@Suite("DebugServer")
struct DebugServerTests {
    private let appState: AppState
    private let mock: MockMatrixClient
    private let server: DebugServer
    private let client: DebugClient

    init() async throws {
        mock = MockMatrixClient()
        appState = AppState(profile: "debug-test")
        appState.loggedInUserId = "@alice:example.com"
        appState.client = mock

        server = DebugServer(appState: appState)
        let port = try server.start(port: 0)
        client = DebugClient(port: port)
    }

    // MARK: - Fixtures

    private func makeRoom(id: String = "!room1:example.com", name: String = "General") -> RoomInfo {
        RoomInfo(
            id: id,
            displayName: name,
            isEncrypted: false,
            isPublic: true,
            isDirect: false,
            topic: nil,
            isInvited: false,
            unreadCount: 0
        )
    }

    private func makeMessage(
        eventId: String = "$evt1:example.com",
        body: String = "Hello"
    ) -> MessageInfo {
        MessageInfo(
            eventId: eventId,
            sender: "@bob:example.com",
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

    // MARK: - /state

    @Test("GET /state returns a snapshot with core fields")
    func stateReturnsSnapshot() async throws {
        appState.rooms = [makeRoom()]
        appState.isLoggedIn = true

        let (status, body) = try await client.get("/state")

        #expect(status == 200)
        #expect(body["profile"] as? String == "debug-test")
        #expect(body["isLoggedIn"] as? Bool == true)
        #expect(body["loggedInUserId"] as? String == "@alice:example.com")
        let rooms = body["rooms"] as? [[String: Any]]
        #expect(rooms?.count == 1)
        #expect(rooms?.first?["displayName"] as? String == "General")
    }

    @Test("GET /state reflects messages and typing users")
    func stateReflectsMessages() async throws {
        appState.rooms = [makeRoom()]
        appState.selectedRoomId = "!room1:example.com"
        await appState.roomRefreshTask?.value
        appState.messages = [makeMessage(body: "hi there")]
        appState.typingUsers = ["!room1:example.com": ["@bob:example.com"]]

        let (status, body) = try await client.get("/state")

        #expect(status == 200)
        let messages = body["messages"] as? [[String: Any]]
        #expect(messages?.count == 1)
        #expect(messages?.first?["body"] as? String == "hi there")
        let typing = body["currentRoomTypingUsers"] as? [String]
        #expect(typing == ["@bob:example.com"])
    }

    // MARK: - /cmd select_room

    @Test("POST /cmd select_room by id")
    func selectRoomById() async throws {
        appState.rooms = [makeRoom(id: "!alerts:example.com", name: "Alerts")]

        let (status, body) = try await client.post("/cmd", body: [
            "op": "select_room",
            "id": "!alerts:example.com"
        ])

        #expect(status == 200)
        #expect(body["ok"] as? Bool == true)
        #expect(appState.selectedRoomId == "!alerts:example.com")
    }

    @Test("POST /cmd select_room by name")
    func selectRoomByName() async throws {
        appState.rooms = [
            makeRoom(id: "!a:example.com", name: "Alerts"),
            makeRoom(id: "!b:example.com", name: "General"),
        ]

        let (status, body) = try await client.post("/cmd", body: [
            "op": "select_room",
            "name": "General"
        ])

        #expect(status == 200)
        #expect(body["ok"] as? Bool == true)
        #expect(appState.selectedRoomId == "!b:example.com")
    }

    @Test("POST /cmd select_room with unknown room returns 404")
    func selectRoomUnknown() async throws {
        appState.rooms = [makeRoom()]

        let (status, body) = try await client.post("/cmd", body: [
            "op": "select_room",
            "name": "DoesNotExist"
        ])

        #expect(status == 404)
        #expect(body["ok"] as? Bool == false)
    }

    // MARK: - /cmd send_message

    @Test("POST /cmd send_message sends through the timeline")
    func sendMessageAppendsPlaceholder() async throws {
        appState.selectedRoomId = "!room1:example.com"
        await appState.roomRefreshTask?.value

        let (status, body) = try await client.post("/cmd", body: [
            "op": "send_message",
            "body": "Hello from IPC"
        ])

        #expect(status == 200)
        #expect(body["ok"] as? Bool == true)
        // Sends route through the timeline; the local echo would arrive via a
        // snapshot, not a manual placeholder.
        #expect(mock.timelineSendMessageCalls.count == 1)
        #expect(mock.timelineSendMessageCalls.first?.body == "Hello from IPC")
    }

    @Test("POST /cmd send_message without body returns 400")
    func sendMessageMissingBody() async throws {
        let (status, _) = try await client.post("/cmd", body: ["op": "send_message"])
        #expect(status == 400)
    }

    // MARK: - /cmd refresh

    @Test("POST /cmd refresh triggers a room-list fetch")
    func refreshCallsClient() async throws {
        appState.selectedRoomId = "!room1:example.com"
        await appState.roomRefreshTask?.value
        mock.roomsResult = [makeRoom(id: "!room1:example.com", name: "RefreshedName")]

        let (status, _) = try await client.post("/cmd", body: ["op": "refresh"])

        #expect(status == 200)
        // Messages are driven by the timeline subscription, so refresh only
        // pulls the room list.
        #expect(appState.rooms.first?.displayName == "RefreshedName")
    }

    // MARK: - /cmd load_older

    @Test("POST /cmd load_older is a no-op without endToken")
    func loadOlderNoToken() async throws {
        appState.selectedRoomId = "!room1:example.com"
        await appState.roomRefreshTask?.value
        mock.messagesCalls.removeAll()

        let (status, body) = try await client.post("/cmd", body: ["op": "load_older"])

        #expect(status == 200)
        #expect(body["ok"] as? Bool == true)
        // No endToken was set, so loadMoreMessages is a no-op.
        #expect(mock.messagesCalls.isEmpty)
    }

    // MARK: - /cmd errors

    @Test("POST /cmd with unknown op returns 400")
    func unknownOp() async throws {
        let (status, body) = try await client.post("/cmd", body: ["op": "totally_fake"])
        #expect(status == 400)
        #expect((body["error"] as? String)?.contains("totally_fake") == true)
    }

    @Test("POST /cmd with invalid JSON returns 400")
    func invalidJson() async throws {
        let status = try await client.postText("/cmd", text: "not json")
        #expect(status == 400)
    }

    @Test("Unknown path returns 404")
    func unknownPath() async throws {
        let (status, _) = try await client.get("/nope")
        #expect(status == 404)
    }
}

@MainActor
@Suite("DebugServer auth")
struct DebugServerAuthTests {
    @Test("Requests without bearer token are rejected with 401")
    func missingTokenRejected() async throws {
        let state = AppState(profile: "debug-auth-missing")
        state.client = MockMatrixClient()
        let server = DebugServer(appState: state, authToken: "correct-horse-battery-staple")
        let port = try server.start(port: 0)
        defer { server.stop() }
        let client = DebugClient(port: port) // no token
        let (status, _) = try await client.get("/state")
        #expect(status == 401)
    }

    @Test("Requests with the wrong token are rejected with 401")
    func wrongTokenRejected() async throws {
        let state = AppState(profile: "debug-auth-wrong")
        state.client = MockMatrixClient()
        let server = DebugServer(appState: state, authToken: "correct-horse")
        let port = try server.start(port: 0)
        defer { server.stop() }
        let client = DebugClient(port: port, authToken: "different")
        let (status, _) = try await client.get("/state")
        #expect(status == 401)
    }

    @Test("Requests with the correct token are accepted")
    func correctTokenAccepted() async throws {
        let state = AppState(profile: "debug-auth-ok")
        state.client = MockMatrixClient()
        let token = "correct-horse"
        let server = DebugServer(appState: state, authToken: token)
        let port = try server.start(port: 0)
        defer { server.stop() }
        let client = DebugClient(port: port, authToken: token)
        let (status, _) = try await client.get("/state")
        #expect(status == 200)
    }
}
#endif
