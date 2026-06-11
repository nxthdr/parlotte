import Foundation
@_exported import ParlotteFFI

/// Protocol abstracting MatrixClient for testability.
/// AppState depends on this protocol, allowing mock injection in tests.
public protocol MatrixClientProtocol: Sendable {
    func login(username: String, password: String) async throws -> SessionInfo
    func session() async -> MatrixSessionData?
    func restoreSession(_ sessionData: MatrixSessionData) async throws
    func logout() async throws
    func rooms() async throws -> [RoomInfo]
    func syncOnce() async throws
    func createRoom(name: String, isPublic: Bool) async throws -> String
    func createDm(userId: String) async throws -> String
    func searchUsers(term: String, limit: UInt64) async throws -> [UserSearchResult]
    func publicRooms() async throws -> [PublicRoomInfo]
    func joinRoom(roomId: String) async throws
    func leaveRoom(roomId: String) async throws
    func roomMembers(roomId: String) async throws -> [RoomMemberInfo]
    func inviteUser(roomId: String, userId: String) async throws
    @discardableResult
    func sendMessage(roomId: String, body: String) async throws -> String
    @discardableResult
    func sendReply(roomId: String, eventId: String, body: String) async throws -> String
    func editMessage(roomId: String, eventId: String, newBody: String) async throws
    func redactMessage(roomId: String, eventId: String) async throws
    func sendReaction(roomId: String, eventId: String, key: String) async throws -> String
    func redactReaction(roomId: String, reactionEventId: String) async throws
    func sendReadReceipt(roomId: String, eventId: String) async throws
    func sendTypingNotice(roomId: String, isTyping: Bool) async throws
    @discardableResult
    func sendAttachment(roomId: String, filename: String, mimeType: String, data: Data, width: UInt32?, height: UInt32?) async throws -> String
    func downloadMedia(mxcUri: String) async throws -> Data
    func messages(roomId: String, limit: UInt64, from: String?) async throws -> MessageBatch
    func loginMethods() async throws -> LoginMethods
    func ssoLoginUrl(redirectUrl: String, idpId: String?) async throws -> String
    func loginSsoCallback(callbackUrl: String) async throws -> SessionInfo
    func oidcLoginUrl(redirectUri: String) async throws -> String
    func oidcFinishLogin(callbackUrl: String) async throws -> SessionInfo
    func oidcSession() async -> OidcSessionData?
    func oidcRestoreSession(_ sessionData: OidcSessionData) async throws
    func setSessionChangeListener(_ listener: ParlotteSessionChangeListener)
    func getProfile() async throws -> UserProfile
    func setDisplayName(name: String) async throws
    func setAvatar(mimeType: String, data: Data) async throws -> String
    func removeAvatar() async throws
    func setRoomName(roomId: String, name: String) async throws
    func setRoomTopic(roomId: String, topic: String) async throws
    func setUserPowerLevel(roomId: String, userId: String, level: Int64) async throws
    func kickUser(roomId: String, userId: String, reason: String?) async throws
    func banUser(roomId: String, userId: String, reason: String?) async throws
    func unbanUser(roomId: String, userId: String, reason: String?) async throws
    func ignoreUser(userId: String) async throws
    func unignoreUser(userId: String) async throws
    func ignoredUsers() async throws -> [String]
    func startSync(listener: ParlotteSyncListener) throws
    func stopSync()
    var isSyncing: Bool { get }
    func recoveryState() async -> RecoveryState
    func enableRecovery(passphrase: String?) async throws -> String
    func disableRecovery() async throws
    func recover(recoveryKey: String) async throws
    func resetRecoveryKey() async throws -> String
    func downloadRoomKeys(roomId: String) async throws
    func beginResetIdentity() async throws -> String?
    func finishResetIdentity() async throws -> String
    func cancelResetIdentity() async
    func isLastDevice() async throws -> Bool?
    func setVerificationListener(_ listener: ParlotteVerificationListener)
    func requestSelfVerification() async throws -> VerificationRequestInfo
    func acceptVerification() async throws
    func startSasVerification() async throws
    func confirmSasVerification() async throws
    func sasMismatch() async throws
    func cancelVerification() async throws
    func verificationState() async -> VerificationState?
    func clearVerification() async
}

extension MatrixClient: MatrixClientProtocol {}
