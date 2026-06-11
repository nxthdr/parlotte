import Testing
import ParlotteSDK
@testable import ParlotteLib

/// Optimistic placeholders must resolve individually: a placeholder is removed
/// only when *its* real echo arrives, never swept just because some other
/// message showed up first.
@MainActor
@Suite("AppState optimistic placeholders")
struct AppStatePlaceholderTests {
    private func makeMessage(_ eventId: String, sender: String, body: String, ts: UInt64 = 1_700_000_000_000) -> MessageInfo {
        MessageInfo(
            eventId: eventId, sender: sender, body: body, formattedBody: nil,
            messageType: "text", timestampMs: ts, isEdited: false,
            repliedToEventId: nil, mediaSource: nil, mediaMimeType: nil,
            mediaWidth: nil, mediaHeight: nil, mediaSize: nil, reactions: []
        )
    }

    private func setup() async -> (AppState, MockMatrixClient) {
        let mock = MockMatrixClient()
        let appState = AppState(profile: "test")
        appState.loggedInUserId = "@me:x.com"
        appState.client = mock
        appState.selectedRoomId = "!room:x.com"
        await appState.roomRefreshTask?.value
        mock.messagesCalls.removeAll()
        return (appState, mock)
    }

    @Test("Another sender's message does not sweep an in-flight send")
    mutating func otherMessageDoesNotSweepInFlightSend() async {
        let (appState, mock) = await setup()
        mock.sendMessageResult = "$mine:x.com"
        await appState.sendMessage(body: "hi")

        #expect(appState.messages.count == 1)
        let placeholderId = appState.messages[0].eventId
        #expect(placeholderId.hasPrefix("~optimistic:"))

        // A sync tick delivers someone else's message — NOT my echo.
        mock.messagesResult = MessageBatch(
            messages: [makeMessage("$other:x.com", sender: "@bob:x.com", body: "yo")],
            endToken: nil
        )
        await appState.appendNewMessages()

        #expect(appState.messages.contains { $0.eventId == placeholderId },
                "in-flight send was wrongly swept by another sender's message")
        #expect(appState.messages.contains { $0.eventId == "$other:x.com" })
    }

    @Test("Placeholder is resolved when its own echo arrives")
    mutating func placeholderResolvedByOwnEcho() async {
        let (appState, mock) = await setup()
        mock.sendMessageResult = "$mine:x.com"
        await appState.sendMessage(body: "hi")
        let placeholderId = appState.messages[0].eventId

        // Sync delivers my real echo.
        mock.messagesResult = MessageBatch(
            messages: [makeMessage("$mine:x.com", sender: "@me:x.com", body: "hi")],
            endToken: nil
        )
        await appState.appendNewMessages()

        #expect(!appState.messages.contains { $0.eventId == placeholderId },
                "placeholder should be removed once its echo arrives")
        #expect(appState.messages.filter { $0.eventId == "$mine:x.com" }.count == 1,
                "echo must appear exactly once (no duplicate)")
    }

    @Test("Echo that races ahead of the send call is reconciled (no duplicate)")
    mutating func echoBeforeSendReturns() async {
        let (appState, mock) = await setup()
        // Simulate the echo already delivered by a sync tick before send returns.
        appState.messages = [makeMessage("$pre:x.com", sender: "@me:x.com", body: "hi")]
        mock.sendMessageResult = "$pre:x.com"

        await appState.sendMessage(body: "hi")

        #expect(appState.messages.filter { $0.eventId.hasPrefix("~optimistic:") }.isEmpty,
                "placeholder should be dropped when its echo is already present")
        #expect(appState.messages.filter { $0.eventId == "$pre:x.com" }.count == 1,
                "must not duplicate the already-present echo")
    }

    @Test("Two rapid sends: an early echo resolves only its own placeholder")
    mutating func twoSendsResolveIndependently() async {
        let (appState, mock) = await setup()
        mock.sendMessageResult = "$first:x.com"
        await appState.sendMessage(body: "first")
        mock.sendMessageResult = "$second:x.com"
        await appState.sendMessage(body: "second")

        let placeholders = appState.messages.filter { $0.eventId.hasPrefix("~optimistic:") }
        #expect(placeholders.count == 2)

        // Only the first message's echo arrives.
        mock.messagesResult = MessageBatch(
            messages: [makeMessage("$first:x.com", sender: "@me:x.com", body: "first")],
            endToken: nil
        )
        await appState.appendNewMessages()

        // First placeholder resolved; second still pending.
        #expect(appState.messages.contains { $0.eventId == "$first:x.com" })
        #expect(appState.messages.filter { $0.eventId.hasPrefix("~optimistic:") }.count == 1,
                "the second in-flight send must survive")
    }
}
