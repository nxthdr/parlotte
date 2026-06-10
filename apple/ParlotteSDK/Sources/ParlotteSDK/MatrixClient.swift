import Foundation
@_exported import ParlotteFFI

/// Thread-safe async wrapper around the blocking UniFFI ParlotteClientFfi.
/// All blocking Rust calls are dispatched off the main thread via Task.detached.
public actor MatrixClient {
    private let ffi: ParlotteClientFfi

    public init(homeserverURL: String, storePath: String?) throws {
        self.ffi = try ParlotteClientFfi(homeserverUrl: homeserverURL, storePath: storePath)
    }

    public func login(username: String, password: String) async throws -> SessionInfo {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.login(username: username, password: password)
        }.value
    }

    public func session() -> MatrixSessionData? {
        ffi.session()
    }

    public func restoreSession(_ sessionData: MatrixSessionData) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.restoreSession(sessionData: sessionData)
        }.value
    }

    public func logout() async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.logout()
        }.value
    }

    public func rooms() async throws -> [RoomInfo] {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.rooms()
        }.value
    }

    public func syncOnce() async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.syncOnce()
        }.value
    }

    public func createRoom(name: String, isPublic: Bool = false) async throws -> String {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.createRoom(name: name, isPublic: isPublic)
        }.value
    }

    public func publicRooms() async throws -> [PublicRoomInfo] {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.publicRooms()
        }.value
    }

    public func joinRoom(roomId: String) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.joinRoom(roomId: roomId)
        }.value
    }

    public func leaveRoom(roomId: String) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.leaveRoom(roomId: roomId)
        }.value
    }

    public func roomMembers(roomId: String) async throws -> [RoomMemberInfo] {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.roomMembers(roomId: roomId)
        }.value
    }

    public func inviteUser(roomId: String, userId: String) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.inviteUser(roomId: roomId, userId: userId)
        }.value
    }

    public func sendMessage(roomId: String, body: String) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.sendMessage(roomId: roomId, body: body)
        }.value
    }

    public func sendReply(roomId: String, eventId: String, body: String) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.sendReply(roomId: roomId, eventId: eventId, body: body)
        }.value
    }

    public func editMessage(roomId: String, eventId: String, newBody: String) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.editMessage(roomId: roomId, eventId: eventId, newBody: newBody)
        }.value
    }

    public func redactMessage(roomId: String, eventId: String) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.redactMessage(roomId: roomId, eventId: eventId)
        }.value
    }

    public func sendReaction(roomId: String, eventId: String, key: String) async throws -> String {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.sendReaction(roomId: roomId, eventId: eventId, key: key)
        }.value
    }

    public func redactReaction(roomId: String, reactionEventId: String) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.redactReaction(roomId: roomId, reactionEventId: reactionEventId)
        }.value
    }

    public func sendReadReceipt(roomId: String, eventId: String) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.sendReadReceipt(roomId: roomId, eventId: eventId)
        }.value
    }

    public func sendTypingNotice(roomId: String, isTyping: Bool) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.sendTypingNotice(roomId: roomId, isTyping: isTyping)
        }.value
    }

    public func sendAttachment(
        roomId: String,
        filename: String,
        mimeType: String,
        data: Data,
        width: UInt32? = nil,
        height: UInt32? = nil
    ) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.sendAttachment(
                roomId: roomId,
                filename: filename,
                mimeType: mimeType,
                data: data,
                width: width,
                height: height
            )
        }.value
    }

    public func downloadMedia(mxcUri: String) async throws -> Data {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.downloadMedia(mxcUri: mxcUri)
        }.value
    }

    public func messages(roomId: String, limit: UInt64 = 50, from: String? = nil) async throws -> MessageBatch {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.messages(roomId: roomId, limit: limit, from: from)
        }.value
    }

    public func loginMethods() async throws -> LoginMethods {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.loginMethods()
        }.value
    }

    public func ssoLoginUrl(redirectUrl: String, idpId: String? = nil) async throws -> String {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.ssoLoginUrl(redirectUrl: redirectUrl, idpId: idpId)
        }.value
    }

    public func loginSsoCallback(callbackUrl: String) async throws -> SessionInfo {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.loginSsoCallback(callbackUrl: callbackUrl)
        }.value
    }

    public func oidcLoginUrl(redirectUri: String) async throws -> String {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.oidcLoginUrl(redirectUri: redirectUri)
        }.value
    }

    public func oidcFinishLogin(callbackUrl: String) async throws -> SessionInfo {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.oidcFinishLogin(callbackUrl: callbackUrl)
        }.value
    }

    public func oidcSession() -> OidcSessionData? {
        ffi.oidcSession()
    }

    public func oidcRestoreSession(_ sessionData: OidcSessionData) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.oidcRestoreSession(sessionData: sessionData)
        }.value
    }

    public nonisolated func setSessionChangeListener(_ listener: ParlotteSessionChangeListener) {
        ffi.setSessionChangeListener(listener: listener)
    }

    public func getProfile() async throws -> UserProfile {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.getProfile()
        }.value
    }

    public func setDisplayName(name: String) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.setDisplayName(name: name)
        }.value
    }

    public func setAvatar(mimeType: String, data: Data) async throws -> String {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.setAvatar(mimeType: mimeType, data: data)
        }.value
    }

    public func removeAvatar() async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.removeAvatar()
        }.value
    }

    public func setRoomName(roomId: String, name: String) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.setRoomName(roomId: roomId, name: name)
        }.value
    }

    public func setRoomTopic(roomId: String, topic: String) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.setRoomTopic(roomId: roomId, topic: topic)
        }.value
    }

    public func setUserPowerLevel(roomId: String, userId: String, level: Int64) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.setUserPowerLevel(roomId: roomId, userId: userId, level: level)
        }.value
    }

    public func kickUser(roomId: String, userId: String, reason: String?) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.kickUser(roomId: roomId, userId: userId, reason: reason)
        }.value
    }

    public func banUser(roomId: String, userId: String, reason: String?) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.banUser(roomId: roomId, userId: userId, reason: reason)
        }.value
    }

    public func unbanUser(roomId: String, userId: String, reason: String?) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.unbanUser(roomId: roomId, userId: userId, reason: reason)
        }.value
    }

    public func ignoreUser(userId: String) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.ignoreUser(userId: userId)
        }.value
    }

    public func unignoreUser(userId: String) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.unignoreUser(userId: userId)
        }.value
    }

    public func ignoredUsers() async throws -> [String] {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.ignoredUsers()
        }.value
    }

    public nonisolated func startSync(listener: ParlotteSyncListener) throws {
        try ffi.startSync(listener: listener)
    }

    public nonisolated func stopSync() {
        ffi.stopSync()
    }

    public nonisolated var isSyncing: Bool {
        ffi.isSyncing()
    }

    public func recoveryState() async -> RecoveryState {
        let ffi = self.ffi
        return await Task.detached {
            ffi.recoveryState()
        }.value
    }

    public func enableRecovery(passphrase: String?) async throws -> String {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.enableRecovery(passphrase: passphrase)
        }.value
    }

    public func disableRecovery() async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.disableRecovery()
        }.value
    }

    public func recover(recoveryKey: String) async throws {
        let ffi = self.ffi
        try await Task.detached {
            try ffi.recover(recoveryKey: recoveryKey)
        }.value
    }

    public func beginResetIdentity() async throws -> String? {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.beginResetIdentity()
        }.value
    }

    public func finishResetIdentity() async throws -> String {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.finishResetIdentity()
        }.value
    }

    public func cancelResetIdentity() async {
        let ffi = self.ffi
        await Task.detached {
            ffi.cancelResetIdentity()
        }.value
    }

    public func isLastDevice() async throws -> Bool? {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.isLastDevice()
        }.value
    }

    // MARK: - Verification

    public nonisolated func setVerificationListener(_ listener: ParlotteVerificationListener) {
        ffi.setVerificationListener(listener: listener)
    }

    public func requestSelfVerification() async throws -> VerificationRequestInfo {
        let ffi = self.ffi
        return try await Task.detached {
            try ffi.requestSelfVerification()
        }.value
    }

    public func acceptVerification() async throws {
        let ffi = self.ffi
        try await Task.detached { try ffi.acceptVerification() }.value
    }

    public func startSasVerification() async throws {
        let ffi = self.ffi
        try await Task.detached { try ffi.startSasVerification() }.value
    }

    public func confirmSasVerification() async throws {
        let ffi = self.ffi
        try await Task.detached { try ffi.confirmSasVerification() }.value
    }

    public func sasMismatch() async throws {
        let ffi = self.ffi
        try await Task.detached { try ffi.sasMismatch() }.value
    }

    public func cancelVerification() async throws {
        let ffi = self.ffi
        try await Task.detached { try ffi.cancelVerification() }.value
    }

    public func verificationState() async -> VerificationState? {
        let ffi = self.ffi
        return await Task.detached { ffi.verificationState() }.value
    }

    public func clearVerification() async {
        let ffi = self.ffi
        await Task.detached { ffi.clearVerification() }.value
    }
}
