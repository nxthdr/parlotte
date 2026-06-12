#if DEBUG
import Foundation
import Network
import ParlotteSDK

/// Local-only JSON IPC server for AI-driven UI testing.
///
/// Exposes two endpoints on `127.0.0.1`:
/// - `GET /state` — snapshot of `AppState` as JSON
/// - `POST /cmd`  — invoke a command (`{"op": "...", ...args}`) against `AppState`
///
/// Intended to be opt-in via the `--debug-ipc-port` CLI flag. Not suitable for
/// production. Binds to the loopback interface only and requires a
/// bearer-token `Authorization` header — without it any local process (or a
/// DNS-rebinding web page) could read the recovery key or drive cross-signing.
public final class DebugServer: @unchecked Sendable {
    private let appState: AppState
    private let queue = DispatchQueue(label: "parlotte.debug-ipc")
    private var listener: NWListener?
    /// Required bearer token for every request. Empty string disables auth
    /// (only used by the test suite, which supplies its own `DebugClient`).
    private let authToken: String

    public init(appState: AppState, authToken: String = "") {
        self.appState = appState
        self.authToken = authToken
    }

    /// Start listening on `127.0.0.1:port`. Pass `0` for an OS-assigned port.
    /// Returns the actual port once the listener is ready.
    @discardableResult
    public func start(port: UInt16) throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Restrict to the loopback interface — no external access.
        params.requiredInterfaceType = .loopback

        let listener: NWListener
        if port == 0 {
            listener = try NWListener(using: params)
        } else {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw DebugServerError.invalidPort(port)
            }
            listener = try NWListener(using: params, on: nwPort)
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var readyPort: UInt16 = 0
        nonisolated(unsafe) var listenerError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readyPort = listener.port?.rawValue ?? port
                semaphore.signal()
            case .failed(let error):
                listenerError = error
                semaphore.signal()
            default:
                break
            }
        }

        listener.start(queue: queue)
        semaphore.wait()

        if let err = listenerError {
            throw err
        }
        return readyPort
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            if error != nil {
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data { buffer.append(data) }

            if let request = Self.parseRequest(buffer) {
                self.dispatch(request: request, connection: connection)
                return
            }

            if isComplete {
                self.respond(connection, status: 400, body: Data("bad request\n".utf8))
                return
            }

            // Haven't seen the full request yet — read more.
            self.receive(connection, accumulated: buffer)
        }
    }

    private func dispatch(request: HTTPRequest, connection: NWConnection) {
        Task { [weak self] in
            guard let self else { connection.cancel(); return }
            if !self.isAuthorized(request) {
                self.respond(connection, status: 401, body: Self.errorBody("unauthorized"))
                return
            }
            let (status, body) = await self.handle(request)
            self.respond(connection, status: status, body: body)
        }
    }

    /// Constant-time comparison of the `Authorization: Bearer <token>`
    /// header against the token generated at startup. When `authToken` is
    /// empty (test-only), anything goes.
    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard !authToken.isEmpty else { return true }
        guard let header = request.headers["authorization"] else { return false }
        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else { return false }
        let actual = String(header.dropFirst(prefix.count))
        let a = Array(actual.utf8)
        let e = Array(authToken.utf8)
        guard a.count == e.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ e[i] }
        return diff == 0
    }

    private func respond(_ connection: NWConnection, status: Int, body: Data) {
        let reason = Self.reasonPhrase(for: status)
        let header =
            "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routing

    private func handle(_ request: HTTPRequest) async -> (Int, Data) {
        switch (request.method, request.path) {
        case ("GET", "/state"):
            let snapshot = await MainActor.run { DebugSnapshot.from(appState: self.appState) }
            return encode(snapshot)

        case ("POST", "/cmd"):
            return await handleCommand(body: request.body)

        default:
            return (404, Self.errorBody("not found"))
        }
    }

    private func handleCommand(body: Data) async -> (Int, Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let op = obj["op"] as? String else {
            return (400, Self.errorBody("invalid command: expected JSON object with \"op\""))
        }

        switch op {
        case "select_room":
            return await cmdSelectRoom(args: obj)
        case "send_message":
            return await cmdSendMessage(args: obj)
        case "load_older":
            return await cmdLoadOlder()
        case "refresh":
            return await cmdRefresh()
        case "logout":
            return await cmdLogout()
        case "refresh_recovery":
            return await cmdRefreshRecovery()
        case "enable_recovery":
            return await cmdEnableRecovery()
        case "disable_recovery":
            return await cmdDisableRecovery()
        case "recover":
            return await cmdRecover(args: obj)
        case "request_verification":
            return await cmdRequestVerification()
        case "accept_verification":
            return await cmdAcceptVerification()
        case "start_sas":
            return await cmdStartSas()
        case "confirm_sas":
            return await cmdConfirmSas()
        case "mismatch_sas":
            return await cmdSasMismatch()
        case "cancel_verification":
            return await cmdCancelVerification()
        case "dismiss_verification":
            return await cmdDismissVerification()
        case "refresh_verification":
            return await cmdRefreshVerification()
        case "login":
            return await cmdLogin(args: obj)
        default:
            return (400, Self.errorBody("unknown op: \(op)"))
        }
    }

    // MARK: - Commands

    private func cmdSelectRoom(args: [String: Any]) async -> (Int, Data) {
        let targetId: String? = await MainActor.run {
            if let id = args["id"] as? String { return id }
            if let name = args["name"] as? String {
                return self.appState.rooms.first(where: { $0.displayName == name })?.id
            }
            return nil
        }

        guard let roomId = targetId else {
            return (404, Self.errorBody("room not found (provide \"id\" or \"name\")"))
        }

        let refreshTask: Task<Void, Never>? = await MainActor.run {
            self.appState.selectedRoomId = roomId
            return self.appState.roomRefreshTask
        }
        await refreshTask?.value
        return okResponse(["selectedRoomId": roomId])
    }

    private func cmdSendMessage(args: [String: Any]) async -> (Int, Data) {
        guard let body = args["body"] as? String else {
            return (400, Self.errorBody("missing \"body\""))
        }
        await appState.sendMessage(body: body)
        return okResponse([:])
    }

    private func cmdLoadOlder() async -> (Int, Data) {
        await appState.loadMoreMessages()
        return okResponse([:])
    }

    private func cmdRefresh() async -> (Int, Data) {
        // Messages are driven by the open room's timeline subscription, which
        // pushes snapshots on its own; only the room list needs a manual pull.
        await appState.refreshRooms()
        return okResponse([:])
    }

    private func cmdLogout() async -> (Int, Data) {
        await appState.logout()
        return okResponse([:])
    }

    private func cmdRefreshRecovery() async -> (Int, Data) {
        await appState.refreshRecoveryState()
        let state = await MainActor.run { String(describing: appState.recoveryState) }
        return okResponse(["recoveryState": state])
    }

    private func cmdEnableRecovery() async -> (Int, Data) {
        await appState.enableRecovery()
        let (state, key, err) = await MainActor.run {
            (String(describing: appState.recoveryState), appState.pendingRecoveryKey, appState.errorMessage)
        }
        if let err { return (500, Self.errorBody(err)) }
        var extra: [String: Any] = ["recoveryState": state]
        if let key { extra["recoveryKey"] = key }
        return okResponse(extra)
    }

    private func cmdDisableRecovery() async -> (Int, Data) {
        await appState.disableRecovery()
        let (state, err) = await MainActor.run { (String(describing: appState.recoveryState), appState.errorMessage) }
        if let err { return (500, Self.errorBody(err)) }
        return okResponse(["recoveryState": state])
    }

    private func cmdRecover(args: [String: Any]) async -> (Int, Data) {
        guard let key = args["key"] as? String else {
            return (400, Self.errorBody("missing \"key\""))
        }
        await appState.recover(recoveryKey: key)
        let (state, err) = await MainActor.run { (String(describing: appState.recoveryState), appState.errorMessage) }
        if let err { return (500, Self.errorBody(err)) }
        return okResponse(["recoveryState": state])
    }

    private func cmdLogin(args: [String: Any]) async -> (Int, Data) {
        guard let homeserver = args["homeserver"] as? String,
              let username = args["username"] as? String,
              let password = args["password"] as? String else {
            return (400, Self.errorBody("missing homeserver/username/password"))
        }
        await MainActor.run {
            appState.homeserverURL = homeserver
            appState.username = username
            appState.password = password
        }
        await appState.login()
        let (loggedIn, err) = await MainActor.run {
            (appState.isLoggedIn, appState.errorMessage)
        }
        if let err, !loggedIn { return (500, Self.errorBody(err)) }
        return okResponse(["isLoggedIn": loggedIn])
    }

    private func cmdRequestVerification() async -> (Int, Data) {
        await appState.requestSelfVerification()
        let err = await MainActor.run { appState.verificationErrorMessage }
        if let err { return (500, Self.errorBody(err)) }
        return okResponse([:])
    }

    private func cmdAcceptVerification() async -> (Int, Data) {
        await appState.acceptVerification()
        let err = await MainActor.run { appState.verificationErrorMessage }
        if let err { return (500, Self.errorBody(err)) }
        return okResponse([:])
    }

    private func cmdStartSas() async -> (Int, Data) {
        await appState.startSasVerification()
        let err = await MainActor.run { appState.verificationErrorMessage }
        if let err { return (500, Self.errorBody(err)) }
        return okResponse([:])
    }

    private func cmdConfirmSas() async -> (Int, Data) {
        await appState.confirmSasVerification()
        let err = await MainActor.run { appState.verificationErrorMessage }
        if let err { return (500, Self.errorBody(err)) }
        return okResponse([:])
    }

    private func cmdSasMismatch() async -> (Int, Data) {
        await appState.sasMismatch()
        return okResponse([:])
    }

    private func cmdCancelVerification() async -> (Int, Data) {
        await appState.cancelVerification()
        return okResponse([:])
    }

    private func cmdDismissVerification() async -> (Int, Data) {
        await appState.dismissVerification()
        return okResponse([:])
    }

    private func cmdRefreshVerification() async -> (Int, Data) {
        await appState.refreshVerificationState()
        return okResponse([:])
    }

    // MARK: - Helpers

    private func encode<T: Encodable>(_ value: T) -> (Int, Data) {
        do {
            let data = try JSONEncoder.debug.encode(value)
            return (200, data)
        } catch {
            return (500, Self.errorBody("encode failed"))
        }
    }

    private func okResponse(_ extra: [String: Any]) -> (Int, Data) {
        var obj: [String: Any] = ["ok": true]
        for (k, v) in extra { obj[k] = v }
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{\"ok\":true}".utf8)
        return (200, data)
    }

    private static func errorBody(_ message: String) -> Data {
        let payload: [String: Any] = ["ok": false, "error": message]
        return (try? JSONSerialization.data(withJSONObject: payload))
            // Static fallback — interpolating `message` here would let a
            // quote/newline inside it produce invalid JSON.
            ?? Data(#"{"ok":false,"error":"serialization failed"}"#.utf8)
    }

    // MARK: - HTTP parsing

    struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private static func parseRequest(_ data: Data) -> HTTPRequest? {
        // Find end of headers (\r\n\r\n)
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }

        let headerData = data[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        var contentLength = 0
        for line in lines.dropFirst() {
            guard let sep = line.firstIndex(of: ":") else { continue }
            let name = line[..<sep].lowercased()
            let value = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
            if name == "content-length" {
                contentLength = Int(value) ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        let available = data.count - bodyStart
        if available < contentLength {
            return nil // need more data
        }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}

// MARK: - Errors

public enum DebugServerError: Error, CustomStringConvertible {
    case invalidPort(UInt16)

    public var description: String {
        switch self {
        case .invalidPort(let p): return "Invalid port: \(p)"
        }
    }
}

// MARK: - Snapshot DTOs

struct DebugRoom: Encodable {
    let id: String
    let displayName: String
    let unreadCount: UInt64
    let isEncrypted: Bool
    let isPublic: Bool
    let isDirect: Bool
    let isInvited: Bool
    let topic: String?

    init(_ r: RoomInfo) {
        self.id = r.id
        self.displayName = r.displayName
        self.unreadCount = r.unreadCount
        self.isEncrypted = r.isEncrypted
        self.isPublic = r.isPublic
        self.isDirect = r.isDirect
        self.isInvited = r.isInvited
        self.topic = r.topic
    }
}

struct DebugReaction: Encodable {
    let eventId: String
    let key: String
    let sender: String

    init(_ r: ReactionInfo) {
        self.eventId = r.eventId
        self.key = r.key
        self.sender = r.sender
    }
}

struct DebugMessage: Encodable {
    let eventId: String
    let sender: String
    let body: String
    let messageType: String
    let timestampMs: UInt64
    let isEdited: Bool
    let repliedToEventId: String?
    let reactions: [DebugReaction]
    let mediaMimeType: String?
    let mediaSize: UInt64?

    init(_ m: MessageInfo) {
        self.eventId = m.eventId
        self.sender = m.sender
        self.body = m.body
        self.messageType = m.messageType
        self.timestampMs = m.timestampMs
        self.isEdited = m.isEdited
        self.repliedToEventId = m.repliedToEventId
        self.reactions = m.reactions.map(DebugReaction.init)
        self.mediaMimeType = m.mediaMimeType
        self.mediaSize = m.mediaSize
    }
}

struct DebugSnapshot: Encodable {
    let profile: String
    let isLoggedIn: Bool
    let isLoading: Bool
    let isCheckingSession: Bool
    let isSyncActive: Bool
    let loggedInUserId: String?
    let homeserverURL: String
    let errorMessage: String?
    let selectedRoomId: String?
    let rooms: [DebugRoom]
    let messages: [DebugMessage]
    let hasMoreMessages: Bool
    let isLoadingMoreMessages: Bool
    let typingUsers: [String: [String]]
    let currentRoomTypingUsers: [String]
    let recoveryState: String
    let isUpdatingRecovery: Bool
    let pendingRecoveryKey: String?
    let activeVerification: DebugVerificationRequest?
    let verificationState: String?
    let verificationEmojis: [DebugEmoji]?
    let verificationError: String?

    @MainActor
    static func from(appState: AppState) -> DebugSnapshot {
        let emojis: [DebugEmoji]?
        let stateStr: String?
        if let state = appState.verificationStateValue {
            switch state {
            case .pending: stateStr = "pending"; emojis = nil
            case .ready: stateStr = "ready"; emojis = nil
            case .sasStarted: stateStr = "sasStarted"; emojis = nil
            case .sasReadyToCompare(let e):
                stateStr = "sasReadyToCompare"
                emojis = e.map { DebugEmoji(symbol: $0.symbol, description: $0.description) }
            case .sasConfirmed: stateStr = "sasConfirmed"; emojis = nil
            case .done: stateStr = "done"; emojis = nil
            case .cancelled(let r): stateStr = "cancelled:\(r)"; emojis = nil
            }
        } else {
            stateStr = nil; emojis = nil
        }

        return DebugSnapshot(
            profile: appState.profile,
            isLoggedIn: appState.isLoggedIn,
            isLoading: appState.isLoading,
            isCheckingSession: appState.isCheckingSession,
            isSyncActive: appState.isSyncActive,
            loggedInUserId: appState.loggedInUserId,
            homeserverURL: appState.homeserverURL,
            errorMessage: appState.errorMessage,
            selectedRoomId: appState.selectedRoomId,
            rooms: appState.rooms.map(DebugRoom.init),
            messages: appState.messages.map(DebugMessage.init),
            hasMoreMessages: appState.hasMoreMessages,
            isLoadingMoreMessages: appState.isLoadingMoreMessages,
            typingUsers: appState.typingUsers,
            currentRoomTypingUsers: appState.currentRoomTypingUsers,
            recoveryState: String(describing: appState.recoveryState),
            isUpdatingRecovery: appState.isUpdatingRecovery,
            pendingRecoveryKey: appState.pendingRecoveryKey,
            activeVerification: appState.activeVerification.map {
                DebugVerificationRequest(
                    flowId: $0.flowId,
                    otherUserId: $0.otherUserId,
                    isSelfVerification: $0.isSelfVerification,
                    weStarted: $0.weStarted
                )
            },
            verificationState: stateStr,
            verificationEmojis: emojis,
            verificationError: appState.verificationErrorMessage
        )
    }
}

struct DebugVerificationRequest: Encodable {
    let flowId: String
    let otherUserId: String
    let isSelfVerification: Bool
    let weStarted: Bool
}

struct DebugEmoji: Encodable {
    let symbol: String
    let description: String
}

// MARK: - Shared encoder

extension JSONEncoder {
    static let debug: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

// MARK: - DebugClient (test helper)

/// Thin HTTP client for driving `DebugServer` from Swift Testing, which can't
/// `import Foundation` in the command-line toolchain (the `_Testing_Foundation`
/// shim module has no swiftmodule there). Living inside ParlotteLib gives tests
/// a Foundation-free surface.
public struct DebugClient: Sendable {
    public let baseURL: URL
    public let authToken: String?

    public init(port: UInt16, authToken: String? = nil) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.authToken = authToken
    }

    public func get(_ path: String) async throws -> (status: Int, body: [String: Any]) {
        let (data, response) = try await URLSession.shared.data(for: request(url(path), method: "GET", body: nil))
        return (Self.statusCode(response), Self.decodeJSON(data))
    }

    public func post(_ path: String, body: [String: Any]) async throws -> (status: Int, body: [String: Any]) {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request(url(path), method: "POST", body: payload))
        return (Self.statusCode(response), Self.decodeJSON(data))
    }

    /// Post a raw string body. Used to test malformed-JSON handling.
    public func postText(_ path: String, text: String) async throws -> Int {
        let (_, response) = try await URLSession.shared.data(for: request(url(path), method: "POST", body: Data(text.utf8)))
        return Self.statusCode(response)
    }

    private func url(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private func request(_ url: URL, method: String, body: Data?) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        if let token = authToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private static func statusCode(_ response: URLResponse) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private static func decodeJSON(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
#endif
