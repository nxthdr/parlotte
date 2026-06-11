import ParlotteLib
import ParlotteSDK
import SwiftUI

struct RoomListView: View {
    @Environment(AppState.self) private var appState
    @State private var showCreateRoom = false
    @State private var showNewDM = false
    @State private var showExploreRooms = false
    @State private var showProfile = false

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            // User header
            Button { showProfile = true } label: {
                HStack(spacing: Spacing.md) {
                    if let userId = appState.loggedInUserId {
                        MemberAvatar(userId: userId, size: AvatarSize.sidebarHeader)

                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(appState.displayName ?? localpart(from: userId))
                                .font(.sidebarDisplayName)
                                .foregroundStyle(AppColor.textPrimary)
                                .lineLimit(1)

                            HStack(spacing: Spacing.xs) {
                                Text(serverName(from: userId))
                                    .font(.sidebarHandle)
                                    .foregroundStyle(AppColor.textTertiary)
                                    .lineLimit(1)

                                Circle()
                                    .fill(appState.isSyncActive ? AppColor.online : AppColor.offline)
                                    .frame(width: 6, height: 6)
                                    .help(appState.isSyncActive ? "Connected" : "Disconnected")
                            }
                        }

                        Spacer()
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)

            Divider()
                .opacity(0.3)

            // Room list
            List(selection: $appState.selectedRoomId) {
                let invites = appState.rooms.filter { $0.isInvited }
                let directs = appState.rooms.filter { !$0.isInvited && $0.isDirect }
                let rooms = appState.rooms.filter { !$0.isInvited && !$0.isDirect }

                if !invites.isEmpty {
                    Section("Invites") {
                        ForEach(invites, id: \.id) { room in
                            roomRow(room)
                        }
                    }
                }

                if !directs.isEmpty {
                    Section("Direct messages") {
                        ForEach(directs, id: \.id) { room in
                            roomRow(room)
                        }
                    }
                }

                Section("Rooms") {
                    if rooms.isEmpty {
                        Text("No rooms yet")
                            .font(.roomPreview)
                            .foregroundStyle(AppColor.textTertiary)
                    } else {
                        ForEach(rooms, id: \.id) { room in
                            roomRow(room)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
                .opacity(0.3)

            // Bottom action bar
            HStack(spacing: Spacing.lg) {
                Button { showCreateRoom = true } label: {
                    Image(systemName: "plus.circle")
                        .font(.body)
                        .foregroundStyle(AppColor.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Create Room")

                Button { showNewDM = true } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.body)
                        .foregroundStyle(AppColor.textSecondary)
                }
                .buttonStyle(.plain)
                .help("New Direct Message")

                Button { showExploreRooms = true } label: {
                    Image(systemName: "globe")
                        .font(.body)
                        .foregroundStyle(AppColor.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Explore Public Rooms")

                Button { Task { await appState.refreshRooms() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                        .foregroundStyle(AppColor.textSecondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button { Task { await appState.requestLogout() } } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.body)
                        .foregroundStyle(AppColor.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Logout")
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
        }
        .sheet(isPresented: $showProfile) {
            ProfileView()
                .environment(appState)
        }
        .sheet(isPresented: $showCreateRoom) {
            CreateRoomView()
                .environment(appState)
        }
        .sheet(isPresented: $showNewDM) {
            NewDirectMessageView()
                .environment(appState)
        }
        .sheet(isPresented: $showExploreRooms) {
            ExploreRoomsView()
                .environment(appState)
        }
    }

    @ViewBuilder
    private func roomRow(_ room: RoomInfo) -> some View {
        RoomRow(room: room, isSelected: room.id == appState.selectedRoomId)
            .tag(room.id)
            .listRowInsets(EdgeInsets(
                top: Spacing.xs,
                leading: Spacing.sm,
                bottom: Spacing.xs,
                trailing: Spacing.sm
            ))
    }

    private func localpart(from userId: String) -> String {
        if userId.hasPrefix("@"), let colon = userId.firstIndex(of: ":") {
            return String(userId[userId.index(after: userId.startIndex)..<colon])
        }
        return userId
    }

    private func serverName(from userId: String) -> String {
        if let colon = userId.firstIndex(of: ":") {
            return String(userId[userId.index(after: colon)...])
        }
        return ""
    }
}

// MARK: - Room Row

private struct RoomRow: View {
    let room: RoomInfo
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Spacing.md) {
            RoomAvatar(
                roomName: room.displayName,
                roomId: room.id,
                isPublic: room.isPublic,
                size: AvatarSize.roomList
            )

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack {
                    Text(room.displayName)
                        .font(.roomName)
                        .foregroundStyle(AppColor.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    if room.isInvited {
                        Text("Invite")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xxs)
                            .background(AppColor.accent.opacity(0.15))
                            .foregroundStyle(AppColor.accent)
                            .clipShape(Capsule())
                    }
                }

                HStack {
                    if let topic = room.topic, !topic.isEmpty {
                        Text(topic)
                            .font(.roomPreview)
                            .foregroundStyle(AppColor.textTertiary)
                            .lineLimit(1)
                    } else {
                        Text(room.isEncrypted ? "Encrypted room" : (room.isPublic ? "Public room" : "Private room"))
                            .font(.roomPreview)
                            .foregroundStyle(AppColor.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if room.unreadCount > 0 {
                        Text("\(room.unreadCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xxs)
                            .background(AppColor.unreadBadge)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}
