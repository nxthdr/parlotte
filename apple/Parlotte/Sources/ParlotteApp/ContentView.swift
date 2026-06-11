import AppKit
import ParlotteLib
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    private static let loginSize    = NSSize(width: 360, height: 560)
    private static let loginMinSize = NSSize(width: 360, height: 560)
    private static let mainSize     = NSSize(width: 1100, height: 750)
    private static let mainMinSize  = NSSize(width: 700, height: 450)

    var body: some View {
        Group {
            if appState.isCheckingSession {
                Color.clear
            } else if appState.isLoggedIn {
                MainView()
            } else {
                LoginView()
            }
        }
        .task {
            await appState.restoreSession()
        }
        .onChange(of: appState.isCheckingSession) { _, checking in
            guard !checking else { return }
            applyWindowSize(loggedIn: appState.isLoggedIn)
        }
        .onChange(of: appState.isLoggedIn) { _, loggedIn in
            guard !appState.isCheckingSession else { return }
            applyWindowSize(loggedIn: loggedIn)
        }
    }

    private func applyWindowSize(loggedIn: Bool) {
        if loggedIn {
            resizeWindow(to: Self.mainSize, minSize: Self.mainMinSize)
        } else {
            resizeWindow(to: Self.loginSize, minSize: Self.loginMinSize)
        }
    }

    private func resizeWindow(to size: NSSize, minSize: NSSize) {
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first else { return }
        window.minSize = minSize
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let oldFrame = window.frame
        let newOrigin = NSPoint(
            x: oldFrame.midX - size.width / 2,
            y: oldFrame.midY - size.height / 2
        )
        let newFrame = NSRect(origin: newOrigin, size: size)
        window.setFrame(newFrame, display: true, animate: true)
    }
}

struct MainView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            RoomListView()
                .padding(.top, 28)
                .frame(width: Layout.sidebarWidth)
                .background(AppColor.sidebarBackground)

            Divider()
                .opacity(0.3)

            if let roomId = appState.selectedRoomId {
                RoomDetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(roomId)
            } else {
                // Empty state
                VStack(spacing: Spacing.md) {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(AppColor.textTertiary)
                    Text("No Room Selected")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppColor.textSecondary)
                    Text("Select a room from the sidebar to start chatting.")
                        .font(.system(size: 13))
                        .foregroundStyle(AppColor.textTertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: Binding(
            get: { appState.isPromptingRecoveryEntry },
            set: { appState.isPromptingRecoveryEntry = $0 }
        )) {
            RecoveryKeyEntrySheet {
                appState.isPromptingRecoveryEntry = false
            }
            .environment(appState)
        }
        .confirmationDialog(
            "Log out without encrypted backup?",
            isPresented: Binding(
                get: { appState.isConfirmingLastDeviceLogout },
                set: { appState.isConfirmingLastDeviceLogout = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button("Log Out Anyway", role: .destructive) {
                Task { await appState.logout() }
            }
            Button("Cancel", role: .cancel) {
                appState.isConfirmingLastDeviceLogout = false
            }
        } message: {
            Text("This is your only device. Without encrypted backup enabled, you'll permanently lose access to encrypted messages when you log out.")
        }
        .sheet(isPresented: Binding(
            get: { appState.activeVerification != nil },
            set: { newValue in
                if !newValue {
                    Task { await appState.dismissVerification() }
                }
            }
        )) {
            VerificationSheet()
        }
    }
}
