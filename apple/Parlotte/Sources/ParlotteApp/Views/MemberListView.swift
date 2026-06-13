import ParlotteLib
import ParlotteSDK
import SwiftUI

struct MemberListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var members: [RoomMemberInfo] = []
    @State private var isLoading = true
    @State private var pendingKick: RoomMemberInfo?
    @State private var pendingBan: RoomMemberInfo?
    @State private var pendingIgnore: RoomMemberInfo?
    @State private var actionInFlight = false
    @State private var showInvite = false

    let roomId: String

    private var myPowerLevel: Int64 {
        guard let me = appState.loggedInUserId else { return 0 }
        return members.first(where: { $0.userId == me })?.powerLevel ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if showInvite {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showInvite = false }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Back to members")

                    Text("Invite User")
                        .font(.system(size: 16, weight: .semibold))
                } else {
                    Text("Members")
                        .font(.system(size: 16, weight: .semibold))
                }

                Spacer()

                if !showInvite {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showInvite = true }
                    } label: {
                        Label("Invite", systemImage: "person.badge.plus")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xs)
                            .background(AppColor.surfaceHover, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Invite a user to this room")
                }

                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
            }
            .padding(Spacing.lg)

            Divider()
                .opacity(0.5)

            if showInvite {
                UserSearchPicker(placeholder: "Search by name or @user:server") { userId in
                    Task {
                        await appState.inviteUser(userId: userId)
                        await loadMembers()
                    }
                    withAnimation(.easeInOut(duration: 0.15)) { showInvite = false }
                }
                .padding(Spacing.lg)
                .environment(appState)
            } else if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if members.isEmpty {
                Spacer()
                Text("No members found")
                    .foregroundStyle(AppColor.textTertiary)
                Spacer()
            } else {
                List(members, id: \.userId) { member in
                    memberRow(member)
                        .padding(.vertical, Spacing.xxs)
                        .contextMenu { menuItems(for: member) }
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 350, minHeight: 380)
        .task {
            await loadMembers()
        }
        .confirmationDialog(
            "Kick \(pendingKick?.displayName ?? pendingKick?.userId ?? "user")?",
            isPresented: Binding(
                get: { pendingKick != nil },
                set: { if !$0 { pendingKick = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingKick
        ) { member in
            Button("Kick", role: .destructive) {
                Task { await performKick(member) }
            }
            Button("Cancel", role: .cancel) { pendingKick = nil }
        } message: { _ in
            Text("They can rejoin if the room allows it.")
        }
        .confirmationDialog(
            "Ban \(pendingBan?.displayName ?? pendingBan?.userId ?? "user")?",
            isPresented: Binding(
                get: { pendingBan != nil },
                set: { if !$0 { pendingBan = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingBan
        ) { member in
            Button("Ban", role: .destructive) {
                Task { await performBan(member) }
            }
            Button("Cancel", role: .cancel) { pendingBan = nil }
        } message: { _ in
            Text("They cannot rejoin until unbanned.")
        }
        .confirmationDialog(
            "Ignore \(pendingIgnore?.displayName ?? pendingIgnore?.userId ?? "user")?",
            isPresented: Binding(
                get: { pendingIgnore != nil },
                set: { if !$0 { pendingIgnore = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingIgnore
        ) { member in
            Button("Ignore", role: .destructive) {
                Task { await performIgnore(member) }
            }
            Button("Cancel", role: .cancel) { pendingIgnore = nil }
        } message: { _ in
            Text("You won't see their messages in any room. You can unignore them later from this menu or your profile.")
        }
    }

    @ViewBuilder
    private func memberRow(_ member: RoomMemberInfo) -> some View {
        HStack(spacing: Spacing.md) {
            MemberAvatar(userId: member.userId, size: 32)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(member.displayName ?? localpart(from: member.userId))
                    .font(.senderName)

                if member.displayName != nil {
                    Text(member.userId)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textTertiary)
                }
            }

            Spacer()

            Text(member.role.capitalized)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xxs)
                .background(roleBadgeColor(for: member.role))
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func menuItems(for member: RoomMemberInfo) -> some View {
        let isSelf = member.userId == appState.loggedInUserId
        let canModerate = !isSelf && myPowerLevel >= 50 && myPowerLevel > member.powerLevel

        if canModerate {
            if myPowerLevel >= 100 && member.powerLevel != 100 {
                Button("Make Admin") {
                    Task { await performSetLevel(member, level: 100) }
                }
            }
            if myPowerLevel >= 100 && member.powerLevel != 50 {
                Button("Make Moderator") {
                    Task { await performSetLevel(member, level: 50) }
                }
            }
            if member.powerLevel > 0 {
                Button("Reset to Member") {
                    Task { await performSetLevel(member, level: 0) }
                }
            }
            Divider()
            Button("Kick…", role: .destructive) {
                pendingKick = member
            }
            Button("Ban…", role: .destructive) {
                pendingBan = member
            }
        }

        if isSelf {
            Text("That's you")
        } else {
            if canModerate {
                Divider()
            }
            if appState.ignoredUsers.contains(member.userId) {
                Button("Unignore") {
                    Task { await performUnignore(member) }
                }
            } else {
                Button("Ignore…", role: .destructive) {
                    pendingIgnore = member
                }
            }
        }
    }

    private func loadMembers() async {
        members = await appState.fetchRoomMembers(roomId: roomId)
        isLoading = false
    }

    private func performSetLevel(_ member: RoomMemberInfo, level: Int64) async {
        guard !actionInFlight else { return }
        actionInFlight = true
        await appState.setMemberPowerLevel(userId: member.userId, level: level)
        await loadMembers()
        actionInFlight = false
    }

    private func performKick(_ member: RoomMemberInfo) async {
        guard !actionInFlight else { return }
        actionInFlight = true
        await appState.kickMember(userId: member.userId, reason: nil)
        pendingKick = nil
        await loadMembers()
        actionInFlight = false
    }

    private func performIgnore(_ member: RoomMemberInfo) async {
        guard !actionInFlight else { return }
        actionInFlight = true
        await appState.ignoreUser(userId: member.userId)
        pendingIgnore = nil
        actionInFlight = false
    }

    private func performUnignore(_ member: RoomMemberInfo) async {
        guard !actionInFlight else { return }
        actionInFlight = true
        await appState.unignoreUser(userId: member.userId)
        actionInFlight = false
    }

    private func performBan(_ member: RoomMemberInfo) async {
        guard !actionInFlight else { return }
        actionInFlight = true
        await appState.banMember(userId: member.userId, reason: nil)
        pendingBan = nil
        await loadMembers()
        actionInFlight = false
    }

    private func localpart(from userId: String) -> String {
        if userId.hasPrefix("@"), let colon = userId.firstIndex(of: ":") {
            return String(userId[userId.index(after: userId.startIndex)..<colon])
        }
        return userId
    }

    private func roleBadgeColor(for role: String) -> Color {
        switch role {
        case "admin": return .orange.opacity(0.15)
        case "moderator": return AppColor.accent.opacity(0.15)
        default: return AppColor.surfaceHover
        }
    }
}
