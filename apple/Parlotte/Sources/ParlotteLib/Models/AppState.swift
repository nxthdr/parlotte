import AppKit
import Foundation
import ParlotteSDK
import UniformTypeIdentifiers

/// UI appearance preference. Mapped to SwiftUI's `ColorScheme?` at the view layer.
public enum AppearanceMode: String, CaseIterable, Sendable {
    case system
    case light
    case dark
}

@Observable
@MainActor
public final class AppState {
    public let profile: String

    public var isLoggedIn = false
    public var isLoading = false
    public var isCheckingSession = true
    public var errorMessage: String?
    public var loggedInUserId: String?
    public var isSyncActive = false
    /// True once the first sync response has been processed since login. Until
    /// then the room list is genuinely empty (the initial `/sync` hasn't
    /// returned yet), so the UI shows a "connecting" state rather than the
    /// misleading "No rooms yet". Reset on logout.
    public var hasCompletedInitialSync = false

    /// The user-facing connection phase, as a single legible value the UI reads
    /// instead of interpreting the raw flags itself. It is *derived* from those
    /// flags (which remain the stored state) so there is one place that defines
    /// what "connecting" vs "syncing" vs "offline" means — e.g. the sidebar dot
    /// and the room-list placeholder both key off this rather than re-deriving
    /// from `isSyncActive`/`hasCompletedInitialSync` independently.
    public enum ConnectionState {
        /// App launch: still restoring a saved session, outcome unknown.
        case checkingSession
        /// No session — the login screen is shown.
        case loggedOut
        /// Authenticated, but the initial `/sync` hasn't returned yet.
        case connecting
        /// Authenticated and the sync loop is running normally.
        case syncing
        /// Authenticated but the sync loop gave up after repeated failures.
        case offline
    }

    public var connectionState: ConnectionState {
        if isCheckingSession { return .checkingSession }
        if !isLoggedIn { return .loggedOut }
        if !hasCompletedInitialSync { return .connecting }
        return isSyncActive ? .syncing : .offline
    }

    // User profile
    public var displayName: String?
    public var avatarUrl: String?
    public var isUpdatingProfile = false

    // Recovery (key backup + secret storage)
    public var recoveryState: RecoveryState = .unknown
    public var isUpdatingRecovery = false
    /// Set after a successful `enableRecovery` so the UI can show the key
    /// in a save/copy modal. Cleared when the user dismisses it.
    public var pendingRecoveryKey: String?
    /// Last error from a recovery op, scoped so it doesn't get mixed with
    /// the global `errorMessage`. Cleared at the start of each recovery op.
    public var recoveryErrorMessage: String?
    /// Set when login restores a session and finds `recoveryState == .incomplete`.
    /// Drives a post-login prompt urging the user to enter their recovery key.
    /// Cleared when the user enters the key or explicitly dismisses.
    public var isPromptingRecoveryEntry = false
    /// Set when logout detects this is the only device AND recovery isn't enabled.
    /// Drives a confirmation dialog before the logout actually proceeds.
    public var isConfirmingLastDeviceLogout = false

    // Cross-signing identity reset ("lost recovery key" path).
    /// OAuth approval URL returned by `beginResetIdentity`. Non-nil means the
    /// user must open this in the browser, approve, and then confirm to
    /// finalise the reset. Cleared when the user cancels or finishes.
    public var resetIdentityApprovalUrl: String?
    /// `true` while any reset step is in flight (begin/finish/cancel). Used to
    /// disable the reset button and show a progress indicator.
    public var isResettingIdentity = false

    // Device verification (cross-signing via SAS)
    /// Metadata about the active verification (incoming or outgoing). Non-nil
    /// means the verification modal should be shown.
    public var activeVerification: VerificationRequestInfo?
    /// Current state of the active verification, refreshed on each sync tick.
    public var verificationStateValue: VerificationState?
    /// Loading flag set while we're issuing a verification-related FFI call.
    public var isProcessingVerification = false
    /// Error from the last verification op (request/accept/confirm/etc).
    public var verificationErrorMessage: String?

    /// UI appearance preference. Persisted per-profile in UserDefaults.
    public var appearance: AppearanceMode = .system {
        didSet {
            guard appearance != oldValue else { return }
            Self.defaults.set(appearance.rawValue, forKey: key("appearance"))
        }
    }

    /// Whether to post OS notifications for new messages in non-focused rooms.
    /// Persisted per-profile. Defaults to `true`.
    public var notificationsEnabled: Bool = true {
        didSet {
            guard notificationsEnabled != oldValue else { return }
            Self.defaults.set(notificationsEnabled, forKey: key("notificationsEnabled"))
        }
    }

    /// Dispatcher for OS notifications. Injected by the app at launch; tests
    /// use a mock to observe which notifications would fire. Nil means no-op.
    public var notificationDispatcher: NotificationDispatcher?

    /// Returns true when the app has keyboard focus. Overridden in tests where
    /// `NSApplication.shared.isActive` is unreliable.
    public var isAppActiveProvider: () -> Bool = { NSApplication.shared.isActive }

    /// Prior `unreadCount` per room, captured after the previous `refreshRooms`.
    /// Used to compute deltas and suppress the initial-sync flood.
    private var previousUnreadCounts: [String: UInt64] = [:]

    public var rooms: [RoomInfo] = []
    public var selectedRoomId: String? {
        didSet {
            // Cancel typing indicator for the room we're leaving
            if let oldRoom = oldValue, let client {
                Task {
                    try? await client.sendTypingNotice(roomId: oldRoom, isTyping: false)
                }
            }
            // Tear down the previous room's timeline subscription; clear the
            // view state so a stale snapshot can never paint the new room.
            client?.stopTimeline()
            messages = []
            lastReceiptEventId = nil
            // A freshly-opened room may have older history to page in; the
            // first back-pagination updates this from the timeline.
            hasMoreMessages = true
            memberProfiles = [:]
            if let roomId = selectedRoomId {
                // Optimistically clear unread count immediately
                if let idx = rooms.firstIndex(where: { $0.id == roomId }) {
                    rooms[idx].unreadCount = 0
                }
                // Subscribe to the room's matrix-sdk Timeline. Snapshots arrive
                // via `handleTimelineUpdate`; the first one populates `messages`.
                startTimeline(roomId: roomId)
                roomRefreshTask = Task {
                    await refreshMemberProfiles()
                }
            }
        }
    }
    /// Task spawned by `selectedRoomId.didSet` to refresh messages.
    /// Exposed as internal so tests can await its completion before asserting.
    var roomRefreshTask: Task<Void, Never>?

    /// Bumped on logout / token invalidation. A network call captures the
    /// epoch before its `await`; if it changed by the time the call returns,
    /// the session was torn down underneath it and the result must be dropped
    /// instead of repopulating logged-out state.
    private var sessionEpoch = 0

    /// True if work that captured `epoch` before an await should discard its
    /// result because the session was reset during the suspension (logout /
    /// token invalidation). Used by the room-list refresh.
    private func isStaleEpoch(_ epoch: Int) -> Bool {
        epoch != sessionEpoch
    }
    /// The room's messages, oldest-first. Owned entirely by the matrix-sdk
    /// Timeline: every value here is a snapshot delivered to
    /// `handleTimelineUpdate`. We never mutate it directly — sends, edits,
    /// redactions and reactions all round-trip through the timeline and come
    /// back as a fresh snapshot.
    public var messages: [MessageInfo] = []
    public var hasMoreMessages = false
    public var isLoadingMoreMessages = false

    /// Event ID of the message we last sent a read receipt for, so a stream of
    /// timeline snapshots doesn't fire a receipt on every redraw.
    private var lastReceiptEventId: String?

    /// Member profiles for the selected room: userId -> (displayName, avatarUrl).
    /// Populated automatically when a room is selected.
    public var memberProfiles: [String: (displayName: String?, avatarUrl: String?)] = [:]

    /// Globally ignored users (`m.ignored_user_list`). Loaded after login,
    /// refreshed on every sync tick, cleared on logout.
    public var ignoredUsers: Set<String> = []

    /// Timeline messages with ignored senders filtered out. The raw `messages`
    /// array keeps them so sync dedup and pagination tokens stay consistent;
    /// the server stops sending their events going forward, but cached history
    /// and paginated batches may still contain them.
    public var visibleMessages: [MessageInfo] {
        if ignoredUsers.isEmpty { return messages }
        return messages.filter { !ignoredUsers.contains($0.sender) }
    }

    /// Maps room ID to the list of user IDs currently typing (excluding own user).
    public var typingUsers: [String: [String]] = [:]

    /// User IDs typing in the currently selected room.
    public var currentRoomTypingUsers: [String] {
        guard let roomId = selectedRoomId else { return [] }
        return typingUsers[roomId] ?? []
    }

    public var homeserverURL = "http://localhost:8008"
    public var username = ""
    public var password = ""

    // SSO state
    public var ssoProviders: [SsoProvider] = []
    public var supportsPassword = true
    public var supportsSso = false
    public var supportsOidc = false
    public var isDetectingLoginMethods = false

    public var client: (any MatrixClientProtocol)?

    /// Builds the Matrix client. Overridable in tests to inject a mock so the
    /// login/restore flows are exercisable without a real homeserver. The
    /// default builds the real UniFFI-backed client.
    var clientFactory: (_ homeserverURL: String, _ storePath: String) throws -> any MatrixClientProtocol = {
        try MatrixClient(homeserverURL: $0, storePath: $1)
    }

    public init(profile: String = "default") {
        self.profile = profile
        // Load persisted appearance preference. didSet doesn't fire in init,
        // so this won't round-trip back to defaults.
        if let raw = Self.defaults.string(forKey: "parlotte.\(profile).appearance"),
           let mode = AppearanceMode(rawValue: raw) {
            self.appearance = mode
        }
        if let enabled = Self.defaults.object(forKey: "parlotte.\(profile).notificationsEnabled") as? Bool {
            self.notificationsEnabled = enabled
        }
    }

    public func detectLoginMethods() async {
        isDetectingLoginMethods = true
        errorMessage = nil

        do {
            let storePath = storePath()
            let client = try clientFactory(homeserverURL, storePath)
            let methods = try await client.loginMethods()
            supportsPassword = methods.supportsPassword
            supportsSso = methods.supportsSso
            supportsOidc = methods.supportsOidc
            ssoProviders = methods.ssoProviders
            // Keep client around for SSO flow
            self.client = client
        } catch {
            supportsPassword = true
            supportsSso = false
            supportsOidc = false
            ssoProviders = []
        }

        isDetectingLoginMethods = false
    }

    public func loginWithSso(idpId: String? = nil) async {
        isLoading = true
        errorMessage = nil

        do {
            self.client = nil
            clearStore()
            let storePath = storePath()
            let client = try clientFactory(homeserverURL, storePath)
            self.client = client

            // Random state parameter binds the browser redirect back to this
            // login attempt — anything that tries to deliver a callback
            // without it is rejected by `SsoCallbackServer`.
            let ssoState = Self.randomToken(byteCount: 32)
            let server = SsoCallbackServer(expectedState: ssoState)
            let port = try await server.start()
            var redirectComponents = URLComponents()
            redirectComponents.scheme = "http"
            redirectComponents.host = "localhost"
            redirectComponents.port = Int(port)
            redirectComponents.queryItems = [URLQueryItem(name: "state", value: ssoState)]
            guard let redirectUrl = redirectComponents.url?.absoluteString else {
                throw OidcAuthError.noCallback
            }

            let ssoUrl = try await client.ssoLoginUrl(redirectUrl: redirectUrl, idpId: idpId)

            // Open SSO URL in system browser
            if let url = URL(string: ssoUrl) {
                NSWorkspace.shared.open(url)
            }

            // Wait for the browser to redirect back with the login token
            let callbackUrl = try await server.waitForCallback()

            let session = try await client.loginSsoCallback(callbackUrl: callbackUrl)
            let sessionData = await client.session()
            saveSession(sessionData, homeserverURL: homeserverURL)
            self.loggedInUserId = session.userId
            password = ""
            isLoggedIn = true
            isSyncActive = true
            try await client.syncOnce()
            await fetchProfile()
            await refreshIgnoredUsers()
            await refreshRecoveryState()
            if recoveryState == .incomplete {
                isPromptingRecoveryEntry = true
            }
            await refreshRooms()
            startSyncLoop()
        } catch {
            errorMessage = error.displayMessage
        }

        isLoading = false
    }

    public func loginWithOidc() async {
        isLoading = true
        errorMessage = nil

        do {
            self.client = nil
            clearStore()
            let storePath = storePath()
            let client = try clientFactory(homeserverURL, storePath)
            self.client = client

            let redirectUri = OidcAuthSession.callbackURL
            let authUrl = try await client.oidcLoginUrl(redirectUri: redirectUri)
            guard let authorizationURL = URL(string: authUrl) else {
                throw OidcAuthError.noCallback
            }

            let authSession = OidcAuthSession()
            let callbackURL = try await authSession.authenticate(authorizationURL: authorizationURL)

            let session = try await client.oidcFinishLogin(callbackUrl: callbackURL.absoluteString)
            let oidcData = await client.oidcSession()
            saveOidcSession(oidcData, homeserverURL: homeserverURL)
            self.loggedInUserId = session.userId
            password = ""
            try await enterAuthenticatedState()
        } catch {
            errorMessage = error.displayMessage
        }

        isLoading = false
    }

    public func login() async {
        isLoading = true
        errorMessage = nil

        do {
            clearStore()
            let storePath = storePath()
            let client = try clientFactory(homeserverURL, storePath)
            _ = try await client.login(username: username, password: password)
            let session = await client.session()
            saveSession(session, homeserverURL: homeserverURL)
            self.client = client
            self.loggedInUserId = session?.userId
            password = ""
            try await enterAuthenticatedState()
        } catch {
            errorMessage = error.displayMessage
        }

        isLoading = false
    }

    /// Shared post-authentication bring-up, invoked by every login and restore
    /// path once a `client` has been built and its session established (and
    /// assigned to `self.client`). Runs the initial sync — tolerating a
    /// transient/offline failure so it never skips `startSyncLoop`, but
    /// rethrowing an auth error so the caller can surface it / clear the saved
    /// session — then loads profile, ignored users, recovery and room state,
    /// and starts the persistent sync loop. Centralising this here is what lets
    /// the four entry points stay thin and consistent.
    private func enterAuthenticatedState() async throws {
        isLoggedIn = true
        isSyncActive = true
        do {
            try await client?.syncOnce()
        } catch {
            if error.isAuthError { throw error }
        }
        await fetchProfile()
        await refreshIgnoredUsers()
        await refreshRecoveryState()
        if recoveryState == .incomplete {
            isPromptingRecoveryEntry = true
        }
        await refreshRooms()
        hasCompletedInitialSync = true
        startSyncLoop()
    }

    public func restoreSession() async {
        if let savedOidc = loadOidcSession() {
            await restoreOidcSession(savedOidc)
            return
        }

        guard let saved = loadSession() else {
            isCheckingSession = false
            return
        }

        do {
            let storePath = storePath()
            let client = try clientFactory(saved.homeserverURL, storePath)
            try await client.restoreSession(MatrixSessionData(
                userId: saved.userId,
                deviceId: saved.deviceId,
                accessToken: saved.accessToken
            ))
            self.homeserverURL = saved.homeserverURL
            self.client = client
            self.loggedInUserId = saved.userId
            isCheckingSession = false

            // Bring the session up. A failed initial sync must not invalidate
            // the session (offline at launch != bad token) — enterAuthenticated
            // State tolerates that and only rethrows a genuine auth error, which
            // the catch below treats as unusable saved credentials.
            try await enterAuthenticatedState()
        } catch {
            isCheckingSession = false
            guard error.isAuthError else {
                // Transient/store error: keep the saved session and the
                // encrypted store so a later launch can recover. Don't strand
                // the user as logged-in against a client we couldn't restore.
                self.client = nil
                return
            }
            // Bad token: discard the saved session and reset to logged-out
            // (the helper may already have flipped isLoggedIn on before the
            // auth error surfaced).
            clearSavedSession()
            clearStore()
            resetInMemorySessionState()
        }
    }

    private func restoreOidcSession(_ saved: SavedOidcSession) async {
        do {
            let storePath = storePath()
            let client = try clientFactory(saved.homeserverURL, storePath)
            try await client.oidcRestoreSession(OidcSessionData(
                userId: saved.userId,
                deviceId: saved.deviceId,
                accessToken: saved.accessToken,
                refreshToken: saved.refreshToken,
                clientId: saved.clientId
            ))
            self.homeserverURL = saved.homeserverURL
            self.client = client
            self.loggedInUserId = saved.userId
            isCheckingSession = false

            // As in restoreSession: tolerate a transient initial-sync failure
            // (offline launch) and only discard the session on an auth error.
            try await enterAuthenticatedState()
        } catch {
            isCheckingSession = false
            guard error.isAuthError else {
                self.client = nil
                return
            }
            clearSavedOidcSession()
            clearSavedSession()
            clearStore()
            resetInMemorySessionState()
        }
    }

    /// Entry point for the logout button. Checks whether this is the user's
    /// last device with no recovery enabled — if so, raises a confirmation
    /// flag instead of logging out immediately. Callers who have already
    /// confirmed (or don't need the warning) should call `logout()` directly.
    public func requestLogout() async {
        guard let client else { return }
        if recoveryState != .enabled {
            let last = (try? await client.isLastDevice()) ?? nil
            if last == true {
                isConfirmingLastDeviceLogout = true
                return
            }
        }
        await logout()
    }

    /// Clear all in-memory session state. Shared by `logout()` and
    /// `handleUnknownToken` so neither can leave the previous account's rooms,
    /// messages, selected room, profiles, or crypto/verification state visible
    /// — which on a shared machine would leak one account's data into the next
    /// login. Bumps `sessionEpoch` so in-flight refreshes discard their
    /// results. Does not touch persisted storage or call the network.
    private func resetInMemorySessionState() {
        sessionEpoch &+= 1
        client?.stopTimeline()
        client?.stopSync()
        isSyncActive = false
        hasCompletedInitialSync = false
        client = nil
        isLoggedIn = false
        loggedInUserId = nil
        displayName = nil
        avatarUrl = nil
        rooms = []
        memberProfiles = [:]
        ignoredUsers = []
        pendingIgnored = []
        pendingUnignored = []
        typingUsers = [:]
        selectedRoomId = nil
        recoveryState = .unknown
        pendingRecoveryKey = nil
        recoveryErrorMessage = nil
        isPromptingRecoveryEntry = false
        resetIdentityApprovalUrl = nil
        isResettingIdentity = false
        activeVerification = nil
        verificationStateValue = nil
        verificationErrorMessage = nil
        isProcessingVerification = false
        mediaCache.removeAllObjects()
        previousUnreadCounts = [:]
    }

    public func logout() async {
        isConfirmingLastDeviceLogout = false
        // Bump the epoch before the network await so an in-flight refresh that
        // resumes during it discards its result instead of repopulating state.
        let client = self.client
        sessionEpoch &+= 1
        try? await client?.logout()
        // Clears in-memory state and stops sync (once) before dropping the client.
        resetInMemorySessionState()
        errorMessage = nil
        clearSavedSession()
        clearSavedOidcSession()
        clearStore()
    }

    /// In-memory cache of downloaded media bytes keyed on mxc:// URI.
    /// Auto-evicts under memory pressure.
    public let mediaCache = NSCache<NSString, NSData>()

    /// Refresh the room list. Returns true if the selected room has new unread messages.
    @discardableResult
    public func refreshRooms() async -> Bool {
        guard let client else { return false }
        let epoch = sessionEpoch
        do {
            var updated = try await client.rooms()
            // Don't repopulate room state if logout ran during the fetch.
            guard epoch == sessionEpoch else { return false }

            let candidates = notificationCandidates(in: updated)

            // Record the server's actual unread counts BEFORE locally zeroing
            // the selected room. Recording the zeroed value would make every
            // subsequent tick see the still-nonzero server count as "new"
            // (until the read receipt propagates) and re-notify each time.
            let serverUnreadCounts = Dictionary(
                uniqueKeysWithValues: updated.map { ($0.id, $0.unreadCount) }
            )

            var hasNewMessages = false
            if let selected = selectedRoomId,
               let idx = updated.firstIndex(where: { $0.id == selected }) {
                hasNewMessages = updated[idx].unreadCount > 0
                updated[idx].unreadCount = 0
            }
            rooms = updated
            previousUnreadCounts = serverUnreadCounts

            await dispatchNotifications(for: candidates)

            return hasNewMessages
        } catch {
            errorMessage = error.displayMessage
            return false
        }
    }

    /// Rooms with an `unreadCount` strictly greater than the value captured
    /// on the previous refresh. Rooms without a prior value (the first sync
    /// or a freshly joined room) are skipped to avoid spamming the user with
    /// historical counts. The currently-selected room is also skipped while
    /// the app has focus, since the user is actively reading it.
    private func notificationCandidates(in updated: [RoomInfo]) -> [(roomId: String, roomName: String)] {
        guard notificationsEnabled, notificationDispatcher != nil else { return [] }
        let appIsActive = isAppActiveProvider()
        var result: [(roomId: String, roomName: String)] = []
        for room in updated where !room.isInvited {
            guard let prev = previousUnreadCounts[room.id] else { continue }
            guard room.unreadCount > prev else { continue }
            if room.id == selectedRoomId && appIsActive { continue }
            result.append((room.id, room.displayName))
        }
        return result
    }

    /// Fetch the latest message for each candidate room and post a notification.
    /// Previews fall back to "New message" when we can't retrieve the content
    /// (e.g., undecryptable events or transient fetch failures).
    private func dispatchNotifications(for candidates: [(roomId: String, roomName: String)]) async {
        guard let dispatcher = notificationDispatcher, !candidates.isEmpty else { return }
        guard let client else { return }
        for candidate in candidates {
            var body = "New message"
            if let batch = try? await client.messages(roomId: candidate.roomId, limit: 1, from: nil),
               let latest = batch.messages.last {
                let sender = shortSenderName(latest.sender)
                let preview = previewText(latest.body)
                body = "\(sender): \(preview)"
            }
            dispatcher.postMessageNotification(
                roomId: candidate.roomId,
                title: candidate.roomName,
                body: body
            )
        }
    }

    /// Shortens a Matrix user ID (`@alice:example.com`) to just the localpart
    /// (`alice`). Used as a fallback display name for senders in rooms whose
    /// member profiles haven't been loaded into memory.
    private func shortSenderName(_ userId: String) -> String {
        if userId.hasPrefix("@"), let colon = userId.firstIndex(of: ":") {
            return String(userId[userId.index(after: userId.startIndex)..<colon])
        }
        return userId
    }

    private func previewText(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLen = 120
        if trimmed.count <= maxLen { return trimmed }
        return String(trimmed.prefix(maxLen)) + "…"
    }

    /// Programmatic entry point for the notification-tap handler. Switches to
    /// the given room if it exists in the current joined-rooms list.
    public func openRoom(_ roomId: String) {
        guard rooms.contains(where: { $0.id == roomId }) else { return }
        selectedRoomId = roomId
    }

    /// Subscribe to the matrix-sdk Timeline for `roomId`. The listener captures
    /// the room it was started for, so a snapshot that arrives after the user
    /// has navigated away is discarded in `handleTimelineUpdate`.
    private func startTimeline(roomId: String) {
        guard let client else { return }
        let handler = TimelineUpdateHandler(appState: self, roomId: roomId)
        do {
            try client.startTimeline(roomId: roomId, listener: handler)
        } catch {
            // Non-fatal: the room will simply show no messages until retried.
        }
    }

    /// Apply a full message snapshot delivered by the timeline. This is the
    /// single entry point for message state: the timeline has already merged
    /// local echoes, edits, redactions, reactions and decryption retries, so we
    /// just replace the array. `roomId` guards against a late snapshot from a
    /// room we've since left.
    public func handleTimelineUpdate(roomId: String, messages newMessages: [MessageInfo]) {
        guard roomId == selectedRoomId else { return }
        messages = newMessages
        // Acknowledge the newest message we can, when the room is focused.
        if isAppActiveProvider() {
            Task { await sendReadReceiptForLatestMessage() }
        }
    }

    /// Load older history in the open room by paginating the timeline
    /// backwards. New items arrive through the snapshot; we only track whether
    /// the start of the room has been reached.
    public func loadMoreMessages() async {
        guard let client, let roomId = selectedRoomId,
              hasMoreMessages, !isLoadingMoreMessages else { return }

        isLoadingMoreMessages = true
        do {
            let reachedStart = try await client.paginateTimelineBack(roomId: roomId, numEvents: 50)
            // Only apply if we're still in the same room.
            if roomId == selectedRoomId {
                hasMoreMessages = !reachedStart
            }
        } catch {
            // Non-fatal
        }
        isLoadingMoreMessages = false
    }

    /// Send a file attachment. Shows an optimistic placeholder while the upload
    /// completes; the placeholder is replaced by the real event on the next sync,
    /// or removed if the upload fails.
    public func sendAttachment(fileURL: URL) async {
        guard let client, let roomId = selectedRoomId else { return }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            errorMessage = error.displayMessage
            return
        }

        let filename = fileURL.lastPathComponent
        let mimeType = Self.detectMimeType(for: fileURL)
        let isImage = mimeType.hasPrefix("image/")

        var width: UInt32?
        var height: UInt32?
        if isImage, let image = NSImage(data: data) {
            let size = image.size
            if size.width > 0 { width = UInt32(size.width) }
            if size.height > 0 { height = UInt32(size.height) }
        }

        // The sent attachment surfaces in the timeline snapshot once it has
        // uploaded and round-tripped through the send queue.
        do {
            _ = try await client.sendAttachment(
                roomId: roomId,
                filename: filename,
                mimeType: mimeType,
                data: data,
                width: width,
                height: height
            )
        } catch {
            errorMessage = error.displayMessage
        }
    }

    /// Fetch media bytes for the given mxc URI. Checks the in-memory cache first,
    /// then downloads via the client and caches the result.
    public func loadMedia(mxcUri: String) async -> Data? {
        let key = mxcUri as NSString
        if let cached = mediaCache.object(forKey: key) {
            return cached as Data
        }
        guard let client else { return nil }
        do {
            let data = try await client.downloadMedia(mxcUri: mxcUri)
            mediaCache.setObject(data as NSData, forKey: key)
            return data
        } catch {
            return nil
        }
    }

    private static func detectMimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    public func sendMessage(body: String) async {
        guard let client, let roomId = selectedRoomId else { return }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // The timeline produces a local echo immediately and a fresh snapshot
        // follows, so we don't manage an optimistic placeholder ourselves.
        do {
            try await client.timelineSendMessage(roomId: roomId, body: trimmed)
        } catch {
            errorMessage = error.displayMessage
        }
    }

    public func createRoom(name: String, isPublic: Bool) async {
        guard let client else { return }
        do {
            _ = try await client.createRoom(name: name, isPublic: isPublic)
        } catch {
            errorMessage = error.displayMessage
        }
    }

    /// Create (or reuse) a 1:1 direct message with `userId`, refresh the room
    /// list, and select the new room. Returns the room ID, or nil on failure.
    @discardableResult
    public func createDirectMessage(userId: String) async -> String? {
        guard let client else { return nil }
        do {
            let roomId = try await client.createDm(userId: userId)
            await refreshRooms()
            selectedRoomId = roomId
            return roomId
        } catch {
            errorMessage = error.displayMessage
            return nil
        }
    }

    /// Search the homeserver's user directory. Returns [] on empty input or
    /// failure — search errors are non-fatal and shouldn't hijack the global
    /// error banner while the user is typing.
    public func searchUsers(term: String, limit: UInt64 = 10) async -> [UserSearchResult] {
        guard let client else { return [] }
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return (try? await client.searchUsers(term: trimmed, limit: limit)) ?? []
    }

    public func fetchPublicRooms() async -> [PublicRoomInfo] {
        guard let client else { return [] }
        do {
            return try await client.publicRooms()
        } catch {
            errorMessage = error.displayMessage
            return []
        }
    }

    public func joinRoom(roomId: String) async {
        guard let client else { return }
        do {
            try await client.joinRoom(roomId: roomId)
        } catch {
            errorMessage = error.displayMessage
        }
    }

    public func fetchRoomMembers(roomId: String) async -> [RoomMemberInfo] {
        guard let client else { return [] }
        do {
            return try await client.roomMembers(roomId: roomId)
        } catch {
            errorMessage = error.displayMessage
            return []
        }
    }

    public func leaveRoom(roomId: String) async {
        guard let client else { return }
        do {
            try await client.leaveRoom(roomId: roomId)
            if selectedRoomId == roomId {
                selectedRoomId = nil
            }
        } catch {
            errorMessage = error.displayMessage
        }
    }

    public func sendReply(eventId: String, body: String) async {
        guard let client, let roomId = selectedRoomId else { return }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try await client.timelineSendReply(roomId: roomId, inReplyTo: eventId, body: trimmed)
        } catch {
            errorMessage = error.displayMessage
        }
    }

    /// Add or remove the current user's reaction. The timeline handles the
    /// add/remove decision and emits a local echo, so we don't track reaction
    /// state ourselves — the next snapshot reflects the change.
    public func toggleReaction(eventId: String, key: String) async {
        guard let client, let roomId = selectedRoomId else { return }
        // A local echo has no event ID yet; reactions need a remote target.
        guard !eventId.isEmpty else { return }
        do {
            try await client.timelineToggleReaction(roomId: roomId, targetEventId: eventId, key: key)
        } catch {
            errorMessage = error.displayMessage
        }
    }

    public func editMessage(eventId: String, newBody: String) async {
        guard let client, let roomId = selectedRoomId else { return }
        guard !eventId.isEmpty else { return }
        // The edit round-trips and the timeline aggregates it into the original
        // item, surfacing as an updated snapshot.
        do {
            try await client.editMessage(roomId: roomId, eventId: eventId, newBody: newBody)
        } catch {
            errorMessage = error.displayMessage
        }
    }

    public func deleteMessage(eventId: String) async {
        guard let client, let roomId = selectedRoomId else { return }
        guard !eventId.isEmpty else { return }
        // The redaction round-trips and the timeline removes/redacts the item.
        do {
            try await client.redactMessage(roomId: roomId, eventId: eventId)
        } catch {
            errorMessage = error.displayMessage
        }
    }

    public func sendReadReceipt(roomId: String) async {
        guard let client else { return }
        // Skip local echoes (no event ID yet) and de-dupe: timeline snapshots
        // arrive frequently, but we only need to acknowledge each new newest
        // message once.
        guard let lastEventId = messages.last(where: { !$0.eventId.isEmpty })?.eventId,
              lastEventId != lastReceiptEventId else { return }
        lastReceiptEventId = lastEventId
        do {
            try await client.sendReadReceipt(roomId: roomId, eventId: lastEventId)
        } catch {
            // Non-fatal — read receipts are best-effort
        }
    }

    /// Send a typing notice for the currently selected room. Best-effort.
    public func sendTypingNotice(isTyping: Bool) async {
        guard let client, let roomId = selectedRoomId else { return }
        do {
            try await client.sendTypingNotice(roomId: roomId, isTyping: isTyping)
        } catch {
            // Non-fatal — typing notices are best-effort
        }
    }

    /// Called by SyncUpdateHandler when typing state changes in a room.
    public func handleTypingUpdate(roomId: String, userIds: [String]) {
        let others = userIds.filter { $0 != loggedInUserId }
        typingUsers[roomId] = others
    }

    /// Tracks whether a room-settings save is in flight. Views can disable their
    /// save button on this to avoid double-submits.
    public var isUpdatingRoomSettings = false

    /// Rename the given room. Optimistic update on `rooms`; reverts if the
    /// server rejects the change.
    public func updateRoomName(roomId: String, name: String) async {
        guard let client else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = rooms.firstIndex(where: { $0.id == roomId }) else { return }

        let oldName = rooms[idx].displayName
        rooms[idx].displayName = trimmed
        isUpdatingRoomSettings = true

        do {
            try await client.setRoomName(roomId: roomId, name: trimmed)
        } catch {
            if let idx = rooms.firstIndex(where: { $0.id == roomId }) {
                rooms[idx].displayName = oldName
            }
            errorMessage = error.displayMessage
        }

        isUpdatingRoomSettings = false
    }

    /// Set the topic of the given room. Optimistic update on `rooms`; reverts
    /// if the server rejects the change. Empty string clears the topic.
    public func updateRoomTopic(roomId: String, topic: String) async {
        guard let client else { return }
        guard let idx = rooms.firstIndex(where: { $0.id == roomId }) else { return }

        let oldTopic = rooms[idx].topic
        let newTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        rooms[idx].topic = newTopic.isEmpty ? nil : newTopic
        isUpdatingRoomSettings = true

        do {
            try await client.setRoomTopic(roomId: roomId, topic: newTopic)
        } catch {
            if let idx = rooms.firstIndex(where: { $0.id == roomId }) {
                rooms[idx].topic = oldTopic
            }
            errorMessage = error.displayMessage
        }

        isUpdatingRoomSettings = false
    }

    public func inviteUser(userId: String) async {
        guard let client, let roomId = selectedRoomId else { return }
        do {
            try await client.inviteUser(roomId: roomId, userId: userId)
        } catch {
            errorMessage = error.displayMessage
        }
    }

    /// Ignore a user globally. Optimistically hides their messages; reverts on failure.
    public func ignoreUser(userId: String) async {
        guard let client else { return }
        let inserted = ignoredUsers.insert(userId).inserted
        // Pin BEFORE the await. The local store reflects the change only after
        // the server echoes it in a sync response, and a sync tick can run
        // during this call — without the pin in place first, that tick's
        // refreshIgnoredUsers would flash the user's messages back.
        let pinned = pendingIgnored.insert(userId).inserted
        pendingUnignored.remove(userId)
        do {
            try await client.ignoreUser(userId: userId)
        } catch {
            if inserted { ignoredUsers.remove(userId) }
            if pinned { pendingIgnored.remove(userId) }
            errorMessage = error.displayMessage
        }
    }

    /// Remove a user from the global ignore list. Optimistic; reverts on failure.
    public func unignoreUser(userId: String) async {
        guard let client else { return }
        let removed = ignoredUsers.remove(userId) != nil
        let pinned = pendingUnignored.insert(userId).inserted
        pendingIgnored.remove(userId)
        do {
            try await client.unignoreUser(userId: userId)
        } catch {
            if removed { ignoredUsers.insert(userId) }
            if pinned { pendingUnignored.remove(userId) }
            errorMessage = error.displayMessage
        }
    }

    /// Local ignore/unignore ops confirmed by the server but not yet echoed
    /// back through sync into the account-data store.
    private var pendingIgnored: Set<String> = []
    private var pendingUnignored: Set<String> = []

    /// Reload the ignore list from `m.ignored_user_list` account data,
    /// overlaying ops the server hasn't echoed back yet.
    public func refreshIgnoredUsers() async {
        guard let client else { return }
        guard let list = try? await client.ignoredUsers() else { return }
        var server = Set(list)
        pendingIgnored.subtract(server)
        pendingUnignored.formIntersection(server)
        server.formUnion(pendingIgnored)
        server.subtract(pendingUnignored)
        ignoredUsers = server
    }

    public func setMemberPowerLevel(userId: String, level: Int64) async {
        guard let client, let roomId = selectedRoomId else { return }
        do {
            try await client.setUserPowerLevel(roomId: roomId, userId: userId, level: level)
        } catch {
            errorMessage = error.displayMessage
        }
    }

    public func kickMember(userId: String, reason: String? = nil) async {
        guard let client, let roomId = selectedRoomId else { return }
        do {
            try await client.kickUser(roomId: roomId, userId: userId, reason: reason)
        } catch {
            errorMessage = error.displayMessage
        }
    }

    public func banMember(userId: String, reason: String? = nil) async {
        guard let client, let roomId = selectedRoomId else { return }
        do {
            try await client.banUser(roomId: roomId, userId: userId, reason: reason)
        } catch {
            errorMessage = error.displayMessage
        }
    }

    public func unbanMember(userId: String, reason: String? = nil) async {
        guard let client, let roomId = selectedRoomId else { return }
        do {
            try await client.unbanUser(roomId: roomId, userId: userId, reason: reason)
        } catch {
            errorMessage = error.displayMessage
        }
    }

    // MARK: - Member Profiles

    /// Fetch member profiles for the selected room (display names + avatar URLs).
    public func refreshMemberProfiles() async {
        guard let client, let roomId = selectedRoomId else { return }
        do {
            let members = try await client.roomMembers(roomId: roomId)
            var profiles: [String: (displayName: String?, avatarUrl: String?)] = [:]
            for m in members {
                profiles[m.userId] = (displayName: m.displayName, avatarUrl: m.avatarUrl)
            }
            // Own local profile always wins — server view may lag behind a
            // recent setAvatar/setDisplayName call.
            if let ownId = loggedInUserId {
                profiles[ownId] = (displayName: displayName, avatarUrl: avatarUrl)
            }
            // Only update if still on the same room
            if selectedRoomId == roomId {
                memberProfiles = profiles
            }
        } catch {
            // Non-fatal
        }
    }

    /// Look up the avatar mxc:// URL for a user in the current room.
    public func avatarUrl(for userId: String) -> String? {
        memberProfiles[userId]?.avatarUrl
    }

    /// Look up display name for a user in the current room.
    public func memberDisplayName(for userId: String) -> String? {
        memberProfiles[userId]?.displayName
    }

    // MARK: - Profile

    public func fetchProfile() async {
        guard let client else { return }
        do {
            let profile = try await client.getProfile()
            displayName = profile.displayName
            avatarUrl = profile.avatarUrl
        } catch {
            // Non-fatal — profile may not be available yet
        }
    }

    public func updateDisplayName(_ name: String) async {
        guard let client else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let oldName = displayName
        displayName = trimmed
        isUpdatingProfile = true

        do {
            try await client.setDisplayName(name: trimmed)
            updateOwnMemberProfile()
        } catch {
            displayName = oldName
            errorMessage = error.displayMessage
        }

        isUpdatingProfile = false
    }

    public func updateAvatar(data: Data, mimeType: String) async {
        guard let client else { return }

        let oldUrl = avatarUrl
        isUpdatingProfile = true

        do {
            let mxcUrl = try await client.setAvatar(mimeType: mimeType, data: data)
            avatarUrl = mxcUrl
            if let old = oldUrl {
                mediaCache.removeObject(forKey: old as NSString)
            }
            updateOwnMemberProfile()
        } catch {
            avatarUrl = oldUrl
            errorMessage = error.displayMessage
        }

        isUpdatingProfile = false
    }

    public func removeAvatar() async {
        guard let client else { return }

        let oldUrl = avatarUrl
        avatarUrl = nil
        isUpdatingProfile = true

        do {
            try await client.removeAvatar()
            if let url = oldUrl {
                mediaCache.removeObject(forKey: url as NSString)
            }
            updateOwnMemberProfile()
        } catch {
            avatarUrl = oldUrl
            errorMessage = error.displayMessage
        }

        isUpdatingProfile = false
    }

    public func refreshRecoveryState() async {
        guard let client else { return }
        recoveryState = await client.recoveryState()
    }

    public func enableRecovery() async {
        guard let client, !isUpdatingRecovery else { return }
        isUpdatingRecovery = true
        recoveryErrorMessage = nil
        do {
            let key = try await client.enableRecovery(passphrase: nil)
            pendingRecoveryKey = key
            recoveryState = await client.recoveryState()
        } catch {
            recoveryErrorMessage = error.displayMessage
            recoveryState = await client.recoveryState()
        }
        isUpdatingRecovery = false
    }

    public func disableRecovery() async {
        guard let client, !isUpdatingRecovery else { return }
        isUpdatingRecovery = true
        recoveryErrorMessage = nil
        do {
            try await client.disableRecovery()
            recoveryState = await client.recoveryState()
        } catch {
            recoveryErrorMessage = error.displayMessage
        }
        isUpdatingRecovery = false
    }

    /// Attempt recovery with the given key. Returns `true` if the key was
    /// accepted (secret storage opened and recovery is now enabled); `false`
    /// if it was rejected (wrong key / typo) or the backup is incomplete —
    /// in which case `recoveryErrorMessage` holds a user-facing explanation.
    /// A `true` result means the *key* is valid; some history may still be
    /// undecryptable if those keys aren't in the backup.
    @discardableResult
    public func recover(recoveryKey: String) async -> Bool {
        guard let client, !isUpdatingRecovery else { return false }
        isUpdatingRecovery = true
        recoveryErrorMessage = nil
        var accepted = false
        do {
            try await client.recover(recoveryKey: recoveryKey)
            recoveryState = await client.recoveryState()
            isPromptingRecoveryEntry = false
            accepted = true
            // Recovery imports the backup decryption key; the room (megolm)
            // keys then download from the server-side key backup. Sync so the
            // keys arrive — the open room's Timeline retries decryption on
            // previously-undecryptable events and emits a healed snapshot on its
            // own. (Keys can keep arriving in the background, so later ticks
            // continue to heal the rest.)
            try? await client.syncOnce()
            await refreshRooms()
        } catch {
            recoveryErrorMessage = error.displayMessage
        }
        isUpdatingRecovery = false
        return accepted
    }

    /// Rotate the recovery key: generate a fresh one (re-keying secret storage
    /// under it, keeping identity + backup) and surface it via
    /// `pendingRecoveryKey` so the UI shows it once to save. Use when the old
    /// key was lost or is stale.
    public func resetRecoveryKey() async {
        guard let client, !isUpdatingRecovery else { return }
        isUpdatingRecovery = true
        recoveryErrorMessage = nil
        do {
            let key = try await client.resetRecoveryKey()
            pendingRecoveryKey = key
            recoveryState = await client.recoveryState()
        } catch {
            recoveryErrorMessage = error.displayMessage
        }
        isUpdatingRecovery = false
    }

    public func dismissPendingRecoveryKey() {
        pendingRecoveryKey = nil
    }

    /// Start the "lost recovery key" reset. On success, if the server needs
    /// browser approval, `resetIdentityApprovalUrl` is set and the caller
    /// should present it + open it. If no approval is needed,
    /// `finishResetIdentity` is invoked immediately to generate a fresh key.
    public func beginResetIdentity() async {
        guard let client, !isResettingIdentity else { return }
        isResettingIdentity = true
        recoveryErrorMessage = nil
        do {
            let url = try await client.beginResetIdentity()
            if let url {
                resetIdentityApprovalUrl = url
                isResettingIdentity = false
            } else {
                // No auth needed — finalise right away.
                isResettingIdentity = false
                await finishResetIdentity()
            }
        } catch {
            recoveryErrorMessage = error.displayMessage
            isResettingIdentity = false
        }
    }

    /// Complete a reset started by `beginResetIdentity`. For the OAuth path,
    /// call this after the user has approved the reset in their browser;
    /// the SDK polls the upload until the approval lands, then generates a
    /// fresh recovery key surfaced via `pendingRecoveryKey`.
    public func finishResetIdentity() async {
        guard let client, !isResettingIdentity else { return }
        isResettingIdentity = true
        recoveryErrorMessage = nil
        do {
            let key = try await client.finishResetIdentity()
            resetIdentityApprovalUrl = nil
            pendingRecoveryKey = key
            recoveryState = await client.recoveryState()
        } catch {
            recoveryErrorMessage = error.displayMessage
            recoveryState = await client.recoveryState()
        }
        isResettingIdentity = false
    }

    /// Cancel an in-progress identity reset. Safe to call when no reset is
    /// pending. Clears the approval URL so the UI dismisses its sheet.
    public func cancelResetIdentity() async {
        guard let client else {
            resetIdentityApprovalUrl = nil
            return
        }
        await client.cancelResetIdentity()
        resetIdentityApprovalUrl = nil
        isResettingIdentity = false
    }

    /// Push the current displayName/avatarUrl into the memberProfiles cache
    /// so message avatars update immediately without waiting for a server round-trip.
    private func updateOwnMemberProfile() {
        guard let userId = loggedInUserId else { return }
        memberProfiles[userId] = (displayName: displayName, avatarUrl: avatarUrl)
    }

    /// Called from the matrix-sdk sync listener whenever a sync tick brings new
    /// state from the server. Refreshes rooms and the member-profile cache so
    /// other users' display name/avatar changes are picked up without switching
    /// rooms. Message state is *not* refreshed here — the open room's matrix-sdk
    /// Timeline drives `messages` directly via `handleTimelineUpdate`.
    public func handleSyncUpdate() async {
        // A successful tick means we're connected; clear the retry budget so a
        // later isolated failure gets a fresh set of restart attempts.
        syncRestartAttempts = 0
        await refreshVerificationState()
        await refreshIgnoredUsers()
        await refreshRooms()
        // The first tick has now populated the room list from the initial
        // /sync; the UI can stop showing the "connecting" placeholder.
        hasCompletedInitialSync = true
        if selectedRoomId != nil {
            // Pick up member profile changes (e.g., other users updating avatars)
            await refreshMemberProfiles()
        }
    }

    fileprivate func sendReadReceiptForLatestMessage() async {
        guard let roomId = selectedRoomId else { return }
        await sendReadReceipt(roomId: roomId)
    }

    private func startSyncLoop() {
        guard let client else { return }
        isSyncActive = true

        client.setVerificationListener(VerificationRequestHandler(appState: self))
        client.setSessionChangeListener(SessionChangeHandler(appState: self))

        let listener = SyncUpdateHandler(appState: self)
        do {
            try client.startSync(listener: listener)
        } catch {
            isSyncActive = false
        }
    }

    /// Invoked by `SyncUpdateHandler` when the core sync loop stops. A `nil`
    /// error is a clean stop (logout/restart) and needs no action. A non-nil
    /// error means the loop exhausted its retries; surface an offline state
    /// and attempt a bounded number of restarts so a long outage doesn't
    /// leave the app permanently disconnected without spinning.
    func handleSyncStopped(error: String?) async {
        guard error != nil else {
            syncRestartAttempts = 0
            return
        }
        // Only restart if we still believe we're logged in and weren't asked
        // to stop (logout sets isSyncActive = false before stopping).
        guard isLoggedIn, isSyncActive, client != nil else { return }

        if syncRestartAttempts >= maxSyncRestartAttempts {
            isSyncActive = false
            errorMessage = "Connection lost. Reopen the app to reconnect."
            return
        }
        syncRestartAttempts += 1
        startSyncLoop()
    }

    private var syncRestartAttempts = 0
    private let maxSyncRestartAttempts = 5

    /// Invoked by `SessionChangeHandler` when matrix-sdk rotates the OIDC
    /// tokens. MAS invalidates the previous refresh token on use, so we must
    /// persist the new one immediately — otherwise the next app launch
    /// restores with an already-invalid refresh token.
    func handleTokensRefreshed(_ session: OidcSessionData) {
        saveOidcSession(session, homeserverURL: homeserverURL)
    }

    /// Invoked when the server returns `M_UNKNOWN_TOKEN`. Both paths require a
    /// fresh login. We clear all in-memory state (so the next user on this
    /// machine can't see the previous account's rooms/messages) and the saved
    /// session tokens, but preserve the encrypted store so a re-login can still
    /// restore E2EE history.
    func handleUnknownToken(softLogout: Bool) {
        resetInMemorySessionState()
        clearSavedOidcSession()
        clearSavedSession()
        errorMessage = softLogout
            ? "Your session expired. Please sign in again."
            : "Your session was invalidated by the server. Please sign in again."
    }

    func clearStore() {
        let dir = Self.storeDir(profile: profile)
        try? FileManager.default.removeItem(at: dir)
    }

    func storePath() -> String {
        let dir = Self.storeDir(profile: profile)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private static func storeDir(profile: String) -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Parlotte", isDirectory: true)
            .appendingPathComponent(profile, isDirectory: true)
    }

    // MARK: - Session persistence

    struct SavedSession {
        let homeserverURL: String
        let userId: String
        let deviceId: String
        let accessToken: String
    }

    private static let defaults = UserDefaults.standard

    private func key(_ name: String) -> String {
        "parlotte.\(profile).\(name)"
    }

    func saveSession(_ data: MatrixSessionData?, homeserverURL: String) {
        guard let data else { return }
        let d = Self.defaults
        d.set(homeserverURL, forKey: key("homeserver"))
        d.set(data.userId,   forKey: key("userId"))
        d.set(data.deviceId, forKey: key("deviceId"))
        // Access token goes to the Keychain, not UserDefaults — it was
        // previously plaintext under `~/Library/Containers/.../Preferences`.
        // Only drop any stale plaintext copy if the Keychain write succeeded.
        if ParlotteKeychain.set(data.accessToken, account: key("accessToken")) {
            d.removeObject(forKey: key("accessToken"))
        } else {
            errorMessage = "Couldn't securely save your session; you may need to sign in again next launch."
        }
    }

    func loadSession() -> SavedSession? {
        let d = Self.defaults
        guard
            let hs  = d.string(forKey: key("homeserver")),
            let uid = d.string(forKey: key("userId")),
            let did = d.string(forKey: key("deviceId"))
        else { return nil }
        // Prefer Keychain; fall back to UserDefaults once to migrate users who
        // signed in before the Keychain switch, then clear the plaintext copy.
        let token: String
        if let kc = ParlotteKeychain.get(key("accessToken")) {
            token = kc
        } else if let legacy = d.string(forKey: key("accessToken")) {
            // Migrate the legacy plaintext token — but keep it until the
            // Keychain write is confirmed, or a failed migration would destroy
            // the only copy and silently log the user out.
            if ParlotteKeychain.set(legacy, account: key("accessToken")) {
                d.removeObject(forKey: key("accessToken"))
            }
            token = legacy
        } else {
            return nil
        }
        return SavedSession(
            homeserverURL: hs,
            userId: uid,
            deviceId: did,
            accessToken: token
        )
    }

    func clearSavedSession() {
        let d = Self.defaults
        d.removeObject(forKey: key("homeserver"))
        d.removeObject(forKey: key("userId"))
        d.removeObject(forKey: key("deviceId"))
        d.removeObject(forKey: key("accessToken"))
        ParlotteKeychain.remove(key("accessToken"))
    }

    struct SavedOidcSession {
        let homeserverURL: String
        let userId: String
        let deviceId: String
        let accessToken: String
        let refreshToken: String?
        let clientId: String
    }

    func saveOidcSession(_ data: OidcSessionData?, homeserverURL: String) {
        guard let data else { return }
        let d = Self.defaults
        d.set(homeserverURL, forKey: key("oidc.homeserver"))
        d.set(data.userId,   forKey: key("oidc.userId"))
        d.set(data.deviceId, forKey: key("oidc.deviceId"))
        d.set(data.clientId, forKey: key("oidc.clientId"))
        // Access + refresh tokens live in the Keychain. The OIDC refresh
        // token is especially sensitive: it's long-lived and grants full
        // account access without re-auth.
        let accessOk = ParlotteKeychain.set(data.accessToken, account: key("oidc.accessToken"))
        if accessOk {
            d.removeObject(forKey: key("oidc.accessToken"))
        }
        var refreshOk = true
        if let refresh = data.refreshToken {
            refreshOk = ParlotteKeychain.set(refresh, account: key("oidc.refreshToken"))
        } else {
            ParlotteKeychain.remove(key("oidc.refreshToken"))
        }
        d.removeObject(forKey: key("oidc.refreshToken"))
        if !accessOk || !refreshOk {
            // A failed write of a rotated OIDC token is unrecoverable: MAS
            // invalidates the old refresh token on use, so the next launch
            // would restore with a dead token. Warn rather than fail silently.
            errorMessage = "Couldn't securely save your session; you may need to sign in again next launch."
        }
    }

    func loadOidcSession() -> SavedOidcSession? {
        let d = Self.defaults
        guard
            let hs       = d.string(forKey: key("oidc.homeserver")),
            let uid      = d.string(forKey: key("oidc.userId")),
            let did      = d.string(forKey: key("oidc.deviceId")),
            let clientId = d.string(forKey: key("oidc.clientId"))
        else { return nil }
        let token: String
        if let kc = ParlotteKeychain.get(key("oidc.accessToken")) {
            token = kc
        } else if let legacy = d.string(forKey: key("oidc.accessToken")) {
            if ParlotteKeychain.set(legacy, account: key("oidc.accessToken")) {
                d.removeObject(forKey: key("oidc.accessToken"))
            }
            token = legacy
        } else {
            return nil
        }
        let refresh: String?
        if let kc = ParlotteKeychain.get(key("oidc.refreshToken")) {
            refresh = kc
        } else if let legacy = d.string(forKey: key("oidc.refreshToken")) {
            if ParlotteKeychain.set(legacy, account: key("oidc.refreshToken")) {
                d.removeObject(forKey: key("oidc.refreshToken"))
            }
            refresh = legacy
        } else {
            refresh = nil
        }
        return SavedOidcSession(
            homeserverURL: hs,
            userId: uid,
            deviceId: did,
            accessToken: token,
            refreshToken: refresh,
            clientId: clientId
        )
    }

    func clearSavedOidcSession() {
        let d = Self.defaults
        d.removeObject(forKey: key("oidc.homeserver"))
        d.removeObject(forKey: key("oidc.userId"))
        d.removeObject(forKey: key("oidc.deviceId"))
        d.removeObject(forKey: key("oidc.accessToken"))
        d.removeObject(forKey: key("oidc.refreshToken"))
        d.removeObject(forKey: key("oidc.clientId"))
        ParlotteKeychain.remove(key("oidc.accessToken"))
        ParlotteKeychain.remove(key("oidc.refreshToken"))
    }

    // MARK: - Random token

    /// Cryptographically-random URL-safe token of the given byte length,
    /// hex-encoded. Used as the SSO `state` parameter and the debug-IPC
    /// bearer token.
    public static func randomToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            // Fall back to Foundation's RNG, which is still seeded from the
            // kernel. This path is effectively unreachable on macOS.
            for i in 0..<byteCount {
                bytes[i] = UInt8.random(in: 0...255)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Device verification

    /// Called from the verification-listener bridge when an incoming
    /// `m.key.verification.request` to-device event arrives.
    public func handleIncomingVerificationRequest(_ info: VerificationRequestInfo) {
        activeVerification = info
        verificationErrorMessage = nil
        Task { await refreshVerificationState() }
    }

    public func requestSelfVerification() async {
        guard let client else { return }
        isProcessingVerification = true
        verificationErrorMessage = nil
        do {
            let info = try await client.requestSelfVerification()
            activeVerification = info
            await refreshVerificationState()
        } catch {
            verificationErrorMessage = error.displayMessage
        }
        isProcessingVerification = false
    }

    public func acceptVerification() async {
        guard let client else { return }
        isProcessingVerification = true
        verificationErrorMessage = nil
        do {
            try await client.acceptVerification()
            await refreshVerificationState()
        } catch {
            verificationErrorMessage = error.displayMessage
        }
        isProcessingVerification = false
    }

    public func startSasVerification() async {
        guard let client else { return }
        isProcessingVerification = true
        verificationErrorMessage = nil
        do {
            try await client.startSasVerification()
            await refreshVerificationState()
        } catch {
            verificationErrorMessage = error.displayMessage
        }
        isProcessingVerification = false
    }

    public func confirmSasVerification() async {
        guard let client else { return }
        isProcessingVerification = true
        verificationErrorMessage = nil
        do {
            try await client.confirmSasVerification()
            await refreshVerificationState()
        } catch {
            verificationErrorMessage = error.displayMessage
        }
        isProcessingVerification = false
    }

    public func sasMismatch() async {
        guard let client else { return }
        isProcessingVerification = true
        verificationErrorMessage = nil
        do {
            try await client.sasMismatch()
            await refreshVerificationState()
        } catch {
            verificationErrorMessage = error.displayMessage
        }
        isProcessingVerification = false
    }

    public func cancelVerification() async {
        guard let client else { return }
        verificationErrorMessage = nil
        try? await client.cancelVerification()
        await refreshVerificationState()
    }

    public func dismissVerification() async {
        await client?.clearVerification()
        activeVerification = nil
        verificationStateValue = nil
        verificationErrorMessage = nil
    }

    public func refreshVerificationState() async {
        guard let client else { return }
        let state = await client.verificationState()
        verificationStateValue = state
        if state == nil {
            activeVerification = nil
        }
    }
}

/// Bridge from Rust sync callback to Swift MainActor.
/// Called on a background thread by the Rust sync loop.
private final class SyncUpdateHandler: ParlotteSyncListener, @unchecked Sendable {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func onSyncUpdate() {
        Task { @MainActor [weak appState] in
            await appState?.handleSyncUpdate()
        }
    }

    func onTypingUpdate(roomId: String, userIds: [String]) {
        Task { @MainActor [weak appState] in
            guard let appState else { return }
            appState.handleTypingUpdate(roomId: roomId, userIds: userIds)
        }
    }

    func onSyncStopped(error: String?) {
        Task { @MainActor [weak appState] in
            await appState?.handleSyncStopped(error: error)
        }
    }
}

/// Bridge from the matrix-sdk Timeline diff stream to the main actor. Carries
/// the room it was created for so a snapshot that lands after the user switches
/// rooms is discarded by `handleTimelineUpdate`.
private final class TimelineUpdateHandler: ParlotteTimelineListener, @unchecked Sendable {
    private weak var appState: AppState?
    private let roomId: String

    init(appState: AppState, roomId: String) {
        self.appState = appState
        self.roomId = roomId
    }

    func onTimelineUpdate(messages: [MessageInfo]) {
        Task { @MainActor [weak appState, roomId] in
            appState?.handleTimelineUpdate(roomId: roomId, messages: messages)
        }
    }
}

/// Bridge from the verification event handler in Rust to the main actor.
private final class VerificationRequestHandler: ParlotteVerificationListener, @unchecked Sendable {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func onVerificationRequest(info: VerificationRequestInfo) {
        Task { @MainActor [weak appState] in
            appState?.handleIncomingVerificationRequest(info)
        }
    }
}

/// Bridge from the matrix-sdk session-change broadcast to the main actor.
private final class SessionChangeHandler: ParlotteSessionChangeListener, @unchecked Sendable {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func onSessionChange(event: SessionChangeEvent) {
        Task { @MainActor [weak appState] in
            guard let appState else { return }
            switch event {
            case .tokensRefreshed(let session):
                appState.handleTokensRefreshed(session)
            case .unknownToken(let softLogout):
                appState.handleUnknownToken(softLogout: softLogout)
            }
        }
    }
}
