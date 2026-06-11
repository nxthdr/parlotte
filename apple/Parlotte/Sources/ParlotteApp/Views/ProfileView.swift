import AppKit
import ParlotteLib
import ParlotteSDK
import SwiftUI
import UniformTypeIdentifiers

struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var editingName = ""
    @State private var isEditingName = false
    @State private var avatarData: Data?
    @State private var isShowingRecoveryEntry = false
    @State private var isConfirmingReset = false

    var body: some View {
        ScrollView {
            contentStack
        }
        .frame(width: 360, height: 560)
        .task {
            if let url = appState.avatarUrl {
                avatarData = await appState.loadMedia(mxcUri: url)
            }
            await appState.refreshRecoveryState()
        }
        .sheet(isPresented: Binding(
            get: { appState.pendingRecoveryKey != nil },
            set: { if !$0 { appState.dismissPendingRecoveryKey() } }
        )) {
            if let key = appState.pendingRecoveryKey {
                RecoveryKeyDisplaySheet(recoveryKey: key) {
                    appState.dismissPendingRecoveryKey()
                }
            }
        }
        .sheet(isPresented: $isShowingRecoveryEntry) {
            RecoveryKeyEntrySheet {
                isShowingRecoveryEntry = false
            }
            .environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.resetIdentityApprovalUrl != nil },
            set: { if !$0 { Task { await appState.cancelResetIdentity() } } }
        )) {
            if let url = appState.resetIdentityApprovalUrl {
                ResetIdentityApprovalSheet(
                    approvalUrl: url,
                    isWorking: appState.isResettingIdentity,
                    errorMessage: appState.recoveryErrorMessage,
                    onContinue: {
                        Task { await appState.finishResetIdentity() }
                    },
                    onCancel: {
                        Task { await appState.cancelResetIdentity() }
                    }
                )
            }
        }
        .alert(
            "Reset encryption?",
            isPresented: $isConfirmingReset,
            actions: {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    Task { await appState.beginResetIdentity() }
                }
            },
            message: {
                Text("This discards your existing encrypted backup and generates a new recovery key. Messages that can only be decrypted with the old key will stay unreadable. Other devices that were using the old identity will need to re-verify.")
            }
        )
    }

    @ViewBuilder
    private var contentStack: some View {
        VStack(spacing: Spacing.xl) {
            Text("Profile")
                .font(.system(size: 18, weight: .semibold))

            // Avatar
            VStack(spacing: Spacing.sm) {
                avatarView
                    .frame(width: AvatarSize.profile, height: AvatarSize.profile)
                    .clipShape(Circle())

                HStack(spacing: Spacing.md) {
                    Button("Change") {
                        pickAvatar()
                    }

                    if appState.avatarUrl != nil {
                        Button("Remove", role: .destructive) {
                            Task { await appState.removeAvatar() }
                        }
                    }
                }
                .font(.system(size: 12, weight: .medium))
            }

            Divider()
                .opacity(0.5)

            // Display name
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Display Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColor.textTertiary)
                    .textCase(.uppercase)

                if isEditingName {
                    HStack {
                        TextField("Display name", text: $editingName)
                            .textFieldStyle(.roundedBorder)
                            .font(.messageBody)
                            .onSubmit { saveDisplayName() }

                        Button("Save") { saveDisplayName() }
                            .disabled(editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Cancel") { isEditingName = false }
                    }
                } else {
                    HStack {
                        Text(appState.displayName ?? localpart(from: appState.loggedInUserId ?? ""))
                            .font(.messageBody)

                        Spacer()

                        Button {
                            editingName = appState.displayName ?? ""
                            isEditingName = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(AppColor.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // User ID (read-only)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("User ID")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColor.textTertiary)
                    .textCase(.uppercase)

                Text(appState.loggedInUserId ?? "")
                    .font(.messageBody)
                    .foregroundStyle(AppColor.textSecondary)
                    .textSelection(.enabled)
            }

            Divider()
                .opacity(0.5)

            // Appearance
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Appearance")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColor.textTertiary)
                    .textCase(.uppercase)

                Picker("", selection: Binding(
                    get: { appState.appearance },
                    set: { appState.appearance = $0 }
                )) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayLabel).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Notifications
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Notifications")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColor.textTertiary)
                    .textCase(.uppercase)

                Toggle("Show banners for new messages", isOn: Binding(
                    get: { appState.notificationsEnabled },
                    set: { appState.notificationsEnabled = $0 }
                ))
                .font(.messageBody)
            }

            if appState.isUpdatingProfile {
                ProgressView()
                    .controlSize(.small)
            }

            Divider()
                .opacity(0.5)

            recoverySection

            Divider()
                .opacity(0.5)

            verificationSection

            if !appState.ignoredUsers.isEmpty {
                Divider()
                    .opacity(0.5)

                ignoredUsersSection
            }

            Spacer(minLength: Spacing.md)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(Spacing.xxl)
    }

    @ViewBuilder
    private var ignoredUsersSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Ignored Users")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColor.textTertiary)
                .textCase(.uppercase)

            Text("You won't see messages from these users in any room.")
                .font(.system(size: 11))
                .foregroundStyle(AppColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(appState.ignoredUsers.sorted(), id: \.self) { userId in
                HStack {
                    Text(userId)
                        .font(.messageBody)
                        .textSelection(.enabled)

                    Spacer()

                    Button("Unignore") {
                        Task { await appState.unignoreUser(userId: userId) }
                    }
                    .font(.system(size: 12, weight: .medium))
                }
            }
        }
    }

    @ViewBuilder
    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Encrypted Backup")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColor.textTertiary)
                .textCase(.uppercase)

            HStack(spacing: Spacing.sm) {
                Image(systemName: recoveryIconName)
                    .foregroundStyle(recoveryIconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recoveryStatusTitle)
                        .font(.messageBody)
                    Text(recoveryStatusSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            HStack(spacing: Spacing.sm) {
                switch appState.recoveryState {
                case .disabled, .unknown:
                    Button("Enable Backup") {
                        Task { await appState.enableRecovery() }
                    }
                    .disabled(appState.isUpdatingRecovery)
                case .incomplete:
                    Button("Enter Recovery Key") {
                        isShowingRecoveryEntry = true
                    }
                    .disabled(appState.isUpdatingRecovery || appState.isResettingIdentity)

                    Button("Reset Encryption", role: .destructive) {
                        isConfirmingReset = true
                    }
                    .disabled(appState.isUpdatingRecovery || appState.isResettingIdentity)
                case .enabled:
                    Button("New Recovery Key") {
                        Task { await appState.resetRecoveryKey() }
                    }
                    .disabled(appState.isUpdatingRecovery)
                    .help("Generate a fresh recovery key (the old one stops working). Use this if you lost or never saved your key.")

                    Button("Disable", role: .destructive) {
                        Task { await appState.disableRecovery() }
                    }
                    .disabled(appState.isUpdatingRecovery)
                }

                if appState.isUpdatingRecovery || appState.isResettingIdentity {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let error = appState.recoveryErrorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var verificationSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Device Verification")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColor.textTertiary)
                .textCase(.uppercase)

            Text("Verify this device against another signed-in device to confirm your identity across sessions.")
                .font(.system(size: 11))
                .foregroundStyle(AppColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Verify this Device") {
                Task { await appState.requestSelfVerification() }
            }
            .disabled(appState.isProcessingVerification || appState.activeVerification != nil)

            if appState.isProcessingVerification {
                ProgressView().controlSize(.small)
            }

            if let error = appState.verificationErrorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private var recoveryIconName: String {
        switch appState.recoveryState {
        case .enabled: return "lock.shield.fill"
        case .incomplete: return "exclamationmark.shield.fill"
        case .disabled, .unknown: return "lock.shield"
        }
    }

    private var recoveryIconColor: Color {
        switch appState.recoveryState {
        case .enabled: return .green
        case .incomplete: return .orange
        case .disabled, .unknown: return AppColor.textSecondary
        }
    }

    private var recoveryStatusTitle: String {
        switch appState.recoveryState {
        case .enabled: return "Enabled"
        case .incomplete: return "Recovery key required"
        case .disabled: return "Disabled"
        case .unknown: return "Checking…"
        }
    }

    private var recoveryStatusSubtitle: String {
        switch appState.recoveryState {
        case .enabled:
            return "Encrypted history can be restored on a new device."
        case .incomplete:
            return "Enter your recovery key to finish setting up this device."
        case .disabled:
            return "If you log out or reinstall, you'll lose access to encrypted messages."
        case .unknown:
            return "Fetching status from the server."
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        if let data = avatarData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            let name = appState.displayName ?? localpart(from: appState.loggedInUserId ?? "?")
            let initial = String(name.prefix(1)).uppercased()
            ZStack {
                Circle()
                    .fill(AppColor.accent.opacity(0.2))
                Text(initial)
                    .font(.system(size: AvatarSize.profile * 0.4, weight: .semibold))
                    .foregroundStyle(AppColor.accent)
            }
        }
    }

    private func saveDisplayName() {
        let name = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isEditingName = false
        Task { await appState.updateDisplayName(name) }
    }

    private func pickAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an avatar image"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let data = try? Data(contentsOf: url) else { return }
        let mimeType = detectMimeType(for: url)

        // Show preview immediately
        avatarData = data

        Task {
            await appState.updateAvatar(data: data, mimeType: mimeType)
        }
    }

    private func detectMimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "image/png"
    }

    private func localpart(from userId: String) -> String {
        if userId.hasPrefix("@"), let colon = userId.firstIndex(of: ":") {
            return String(userId[userId.index(after: userId.startIndex)..<colon])
        }
        return userId
    }
}

private struct RecoveryKeyDisplaySheet: View {
    let recoveryKey: String
    let onDismiss: () -> Void

    @State private var hasCopied = false
    @State private var hasConfirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Save your recovery key")
                    .font(.system(size: 16, weight: .semibold))
                Text("This key restores encrypted messages on a new device. Store it in a password manager — we can't show it again.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(recoveryKey)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(AppColor.surfaceHover)
                )

            HStack(spacing: Spacing.sm) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(recoveryKey, forType: .string)
                    hasCopied = true
                } label: {
                    Label(hasCopied ? "Copied" : "Copy", systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                }

                Spacer()

                Toggle("I've saved this key", isOn: $hasConfirmed)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }

            Button("Done") { onDismiss() }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasConfirmed)
                .frame(maxWidth: .infinity)
        }
        .padding(Spacing.xxl)
        .frame(width: 420)
    }
}

/// Recovery-key entry. Drives `appState.recover` itself and stays open to
/// report the outcome — so the user gets clear feedback on whether the key was
/// accepted, rather than the sheet vanishing before recovery finishes.
struct RecoveryKeyEntrySheet: View {
    @Environment(AppState.self) private var appState
    /// Called to dismiss (on cancel or after a successful unlock).
    let onClose: () -> Void

    @State private var recoveryKey = ""
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle
        case working
        case succeeded
        case failed(String)
    }

    private var trimmedKey: String {
        recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Enter your recovery key")
                    .font(.system(size: 16, weight: .semibold))
                Text("Paste the recovery key you saved when you enabled encrypted backup.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Recovery key", text: $recoveryKey, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(3...5)
                .disabled(phase == .working || phase == .succeeded)

            statusLine

            HStack {
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(phase == .working)
                Spacer()
                Button(isFailed ? "Try Again" : "Unlock") {
                    Task { await unlock() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedKey.isEmpty || phase == .working || phase == .succeeded)
            }
        }
        .padding(Spacing.xxl)
        .frame(width: 420)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .working:
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Checking your recovery key…")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColor.textSecondary)
            }
        case .succeeded:
            Label("Recovery key accepted — restoring your encrypted history.",
                  systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func unlock() async {
        guard !trimmedKey.isEmpty else { return }
        phase = .working
        let accepted = await appState.recover(recoveryKey: trimmedKey)
        if accepted {
            phase = .succeeded
            // Brief confirmation, then close.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            onClose()
        } else {
            phase = .failed(appState.recoveryErrorMessage
                ?? "That recovery key wasn't accepted. Check for typos and try again.")
        }
    }
}

private struct ResetIdentityApprovalSheet: View {
    let approvalUrl: String
    let isWorking: Bool
    let errorMessage: String?
    let onContinue: () -> Void
    let onCancel: () -> Void

    @State private var hasOpened = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Approve encryption reset")
                    .font(.system(size: 16, weight: .semibold))
                Text("Your homeserver needs you to approve resetting your encryption keys. Open the link below, sign in if asked, and approve the reset — then come back here and press Continue.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(approvalUrl)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(AppColor.surfaceHover)
                )

            Button {
                if let url = URL(string: approvalUrl) {
                    NSWorkspace.shared.open(url)
                    hasOpened = true
                }
            } label: {
                Label(hasOpened ? "Reopen in Browser" : "Open in Browser", systemImage: "safari")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(spacing: Spacing.sm) {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Button("Continue") { onContinue() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || !hasOpened)
            }
        }
        .padding(Spacing.xxl)
        .frame(width: 460)
    }
}
