import Testing
import ParlotteSDK
@testable import ParlotteLib

/// Session-restore behaviour: a transient failure at launch (offline) must
/// bring the user in against the local store and keep the saved session,
/// while a genuine auth failure (bad/expired token) discards it. The old
/// code wiped the session — and the encrypted store with it — on *any* error.
@MainActor
@Suite("AppState session restore", .serialized)
struct AppStateRestoreTests {
    // Each test gets a unique profile so the per-profile Keychain/UserDefaults
    // session storage can't interfere across tests.
    private func setup(profile: String) -> (AppState, MockMatrixClient) {
        let mock = MockMatrixClient()
        let appState = AppState(profile: profile)
        appState.clientFactory = { _, _ in mock }
        return (appState, mock)
    }

    private func seedSavedSession(_ appState: AppState) {
        appState.saveSession(
            MatrixSessionData(
                userId: "@me:x.com",
                deviceId: "DEV",
                accessToken: "tok"
            ),
            homeserverURL: "http://localhost:8008"
        )
    }

    @Test("Transient sync failure keeps the session and brings the user in")
    mutating func transientFailureKeepsSession() async {
        let (appState, mock) = setup(profile: "restore-transient")
        seedSavedSession(appState)
        defer { appState.clearSavedSession() }

        // syncOnce fails with a network error (offline launch).
        mock.syncOnceError = ParlotteError.Network(message: "offline")

        await appState.restoreSession()

        #expect(appState.isLoggedIn == true, "should bring the user in offline")
        #expect(appState.client != nil)
        #expect(appState.loadSession() != nil, "saved session must be preserved")
    }

    @Test("Auth failure discards the saved session")
    mutating func authFailureDiscardsSession() async {
        let (appState, mock) = setup(profile: "restore-auth")
        seedSavedSession(appState)
        defer { appState.clearSavedSession() }

        // syncOnce fails with an auth error (expired/invalid token).
        mock.syncOnceError = ParlotteError.Auth(message: "M_UNKNOWN_TOKEN")

        await appState.restoreSession()

        #expect(appState.isLoggedIn == false)
        #expect(appState.client == nil)
        #expect(appState.loadSession() == nil, "bad-token session must be cleared")
    }

    @Test("Clean restore logs in and starts sync")
    mutating func cleanRestoreSucceeds() async {
        let (appState, _) = setup(profile: "restore-clean")
        seedSavedSession(appState)
        defer { appState.clearSavedSession() }

        await appState.restoreSession()

        #expect(appState.isLoggedIn == true)
        #expect(appState.isCheckingSession == false)
        #expect(appState.loggedInUserId == "@me:x.com")
    }
}
