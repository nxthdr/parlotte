import AppKit
import ParlotteLib
import ParlotteSDK
import SwiftUI
import UniformTypeIdentifiers

struct RoomDetailView: View {
    @Environment(AppState.self) private var appState
    @State private var messageText = ""
    @State private var showInvite = false
    @State private var showLeaveConfirm = false
    @State private var showMembers = false
    @State private var showSettings = false
    @State private var replyingTo: MessageInfo?

    private var selectedRoom: some View {
        let room = appState.rooms.first { $0.id == appState.selectedRoomId }
        return Group {
            if let room {
                HStack(spacing: Spacing.md) {
                    // Room identity: avatar + name/topic
                    RoomAvatar(roomName: room.displayName, roomId: room.id, isPublic: room.isPublic, size: AvatarSize.roomHeader)

                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        HStack(spacing: Spacing.sm) {
                            Text(room.displayName)
                                .font(.roomTitle)
                                .lineLimit(1)

                            if room.isEncrypted {
                                Image(systemName: "lock.shield.fill")
                                    .font(.caption)
                                    .foregroundStyle(AppColor.online)
                                    .help("End-to-end encrypted")
                            }
                        }

                        if let topic = room.topic, !topic.isEmpty {
                            Text(topic)
                                .font(.roomTopic)
                                .foregroundStyle(AppColor.textTertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // Members pill
                    Button { showMembers = true } label: {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "person.2")
                                .font(.caption)
                            Text("Members")
                                .font(.caption)
                        }
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .background(AppColor.surfaceHover, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Members")

                    // Overflow menu
                    Menu {
                        Button { showSettings = true } label: {
                            Label("Room Settings", systemImage: "gearshape")
                        }
                        Button { showInvite = true } label: {
                            Label("Invite User", systemImage: "person.badge.plus")
                        }
                        Divider()
                        Button(role: .destructive) { showLeaveConfirm = true } label: {
                            Label("Leave Room", systemImage: "arrow.right.square")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body)
                            .foregroundStyle(AppColor.textSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var currentRoom: RoomInfo? {
        appState.rooms.first { $0.id == appState.selectedRoomId }
    }

    var body: some View {
        if let room = currentRoom, room.isInvited {
            VStack(spacing: 16) {
                Spacer()
                RoomAvatar(roomName: room.displayName, roomId: room.id, isPublic: room.isPublic, size: 56)
                Text("You've been invited to")
                    .font(.system(size: 14))
                    .foregroundStyle(AppColor.textTertiary)
                    .padding(.top, Spacing.sm)
                Text(room.displayName)
                    .font(.system(size: 20, weight: .semibold))
                Button("Accept Invite") {
                    Task { await appState.joinRoom(roomId: room.id) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, Spacing.sm)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            roomContent
        }
    }

    private var roomContent: some View {
        VStack(spacing: 0) {
            // Room header
            selectedRoom
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)

            Divider()
                .opacity(0.5)

            // Message list
            messageList

            // Typing indicator
            if !appState.currentRoomTypingUsers.isEmpty {
                TypingIndicator(userIds: appState.currentRoomTypingUsers)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.xs)
            }

            // Compose area
            VStack(spacing: 0) {
                if let reply = replyingTo {
                    HStack(spacing: Spacing.sm) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(AppColor.accent)
                            .frame(width: 3, height: 28)

                        VStack(alignment: .leading, spacing: 0) {
                            Text(reply.sender)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(AppColor.accent)
                            Text(reply.body)
                                .font(.caption)
                                .foregroundStyle(AppColor.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            replyingTo = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AppColor.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                }

                HStack(alignment: .bottom, spacing: Spacing.sm) {
                    Button { attachFile() } label: {
                        Image(systemName: "paperclip")
                            .font(.body)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Attach file")

                    let roomName = appState.rooms.first { $0.id == appState.selectedRoomId }?.displayName ?? "..."
                    TextField("Message \(roomName)", text: $messageText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.messageBody)
                        .lineLimit(1...8)
                        .onSubmit { send() }
                        .onChange(of: messageText) { oldValue, newValue in
                            let wasEmpty = oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            let isEmpty = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            if wasEmpty && !isEmpty {
                                Task { await appState.sendTypingNotice(isTyping: true) }
                            } else if !wasEmpty && isEmpty {
                                Task { await appState.sendTypingNotice(isTyping: false) }
                            }
                        }

                    let canSend = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button { send() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(canSend ? AppColor.accent : AppColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Radius.lg)
                        .fill(AppColor.surfaceRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.lg)
                        .strokeBorder(AppColor.border, lineWidth: 1)
                )
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.md)
                .padding(.top, Spacing.sm)
            }
        }
        .sheet(isPresented: $showInvite) {
            VStack(spacing: 0) {
                HStack {
                    Text("Invite User")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button("Done") { showInvite = false }
                        .buttonStyle(.plain)
                }
                .padding(Spacing.lg)

                Divider().opacity(0.5)

                UserSearchPicker(placeholder: "Search by name or @user:server") { userId in
                    Task { await appState.inviteUser(userId: userId) }
                    showInvite = false
                }
                .padding(Spacing.lg)
            }
            .frame(minWidth: 360, minHeight: 380)
            .environment(appState)
        }
        .sheet(isPresented: $showMembers) {
            if let roomId = appState.selectedRoomId {
                MemberListView(roomId: roomId)
                    .environment(appState)
            }
        }
        .sheet(isPresented: $showSettings) {
            if let roomId = appState.selectedRoomId {
                RoomSettingsView(roomId: roomId)
                    .environment(appState)
            }
        }
        .alert("Leave Room", isPresented: $showLeaveConfirm) {
            Button("Leave", role: .destructive) {
                if let roomId = appState.selectedRoomId {
                    Task { await appState.leaveRoom(roomId: roomId) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to leave this room?")
        }
        .onChange(of: appState.selectedRoomId) {
            replyingTo = nil
        }
    }

    private var messageList: some View {
        // Snapshot once. `visibleMessages` is a computed property that re-filters
        // on every access, so enumerating it and *also* subscripting it with
        // `[index - 1]` can desync (a sync tick or sheet presentation re-renders
        // mid-flight) and crash with "Index out of range". Bind it to a single
        // local so the enumerated array and the subscripts are the same value.
        let visible = appState.visibleMessages
        return MessageScrollView(
            lastItemId: visible.last?.eventId,
            firstItemId: visible.first?.eventId,
            onScrollToTop: {
                if appState.hasMoreMessages && !appState.isLoadingMoreMessages {
                    Task { await appState.loadMoreMessages() }
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if appState.hasMoreMessages {
                    HStack {
                        Spacer()
                        if appState.isLoadingMoreMessages {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, Spacing.sm)
                            Text("Loading...")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppColor.textTertiary)
                        } else {
                            Button {
                                Task { await appState.loadMoreMessages() }
                            } label: {
                                HStack(spacing: Spacing.xs) {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("Load older messages")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(AppColor.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(.vertical, Spacing.md)
                }

                ForEach(Array(visible.enumerated()), id: \.element.eventId) { index, message in
                    if index == 0 {
                        DateSeparator(timestamp: message.timestampMs)
                    } else {
                        let prevDate = Self.calendarDay(visible[index - 1].timestampMs)
                        let thisDate = Self.calendarDay(message.timestampMs)
                        if prevDate != thisDate {
                            DateSeparator(timestamp: message.timestampMs)
                        }
                    }

                    let isGrouped: Bool = {
                        guard index > 0, index - 1 < visible.count else { return false }
                        let prev = visible[index - 1]
                        guard prev.sender == message.sender else { return false }
                        // Group if within 5 minutes
                        let gap = message.timestampMs > prev.timestampMs
                            ? message.timestampMs - prev.timestampMs
                            : 0
                        if gap > 5 * 60 * 1000 { return false }
                        // Don't group across day boundaries
                        let prevDay = Self.calendarDay(prev.timestampMs)
                        let thisDay = Self.calendarDay(message.timestampMs)
                        return prevDay == thisDay
                    }()

                    MessageBubble(
                        message: message,
                        isOwnMessage: message.sender == appState.loggedInUserId,
                        isGrouped: isGrouped,
                        repliedMessage: message.repliedToEventId.flatMap { replyId in
                            visible.first { $0.eventId == replyId }
                        },
                        onReply: {
                            replyingTo = message
                        },
                        onEdit: { newBody in
                            Task { await appState.editMessage(eventId: message.eventId, newBody: newBody) }
                        },
                        onDelete: {
                            Task { await appState.deleteMessage(eventId: message.eventId) }
                        },
                        onReact: { key in
                            Task { await appState.toggleReaction(eventId: message.eventId, key: key) }
                        }
                    )
                }

                // Empty conversation state
                if visible.isEmpty && !appState.hasMoreMessages {
                    VStack(spacing: Spacing.md) {
                        Spacer()
                            .frame(height: 80)
                        if let room = appState.rooms.first(where: { $0.id == appState.selectedRoomId }) {
                            RoomAvatar(roomName: room.displayName, roomId: room.id, isPublic: room.isPublic, size: 56)
                            Text(room.displayName)
                                .font(.system(size: 18, weight: .semibold))
                            Text("This is the beginning of your conversation.")
                                .font(.system(size: 13))
                                .foregroundStyle(AppColor.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.md)
        }
    }

    private func send() {
        let body = messageText
        let reply = replyingTo
        messageText = ""
        replyingTo = nil
        Task {
            if let reply {
                await appState.sendReply(eventId: reply.eventId, body: body)
            } else {
                await appState.sendMessage(body: body)
            }
        }
    }

    private func attachFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .pdf, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await appState.sendAttachment(fileURL: url) }
    }
}

private struct TypingIndicator: View {
    let userIds: [String]

    private var displayText: String {
        let names = userIds.map { userId -> String in
            if userId.hasPrefix("@"), let colon = userId.firstIndex(of: ":") {
                return String(userId[userId.index(after: userId.startIndex)..<colon])
            }
            return userId
        }
        switch names.count {
        case 1: return "\(names[0]) is typing..."
        case 2: return "\(names[0]) and \(names[1]) are typing..."
        default: return "Several people are typing..."
        }
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(displayText)
                .font(.system(size: 12))
                .foregroundStyle(AppColor.textTertiary)
                .italic()
            Spacer()
        }
    }
}

struct MessageBubble: View {
    @Environment(AppState.self) private var appState
    let message: MessageInfo
    let isOwnMessage: Bool
    let isGrouped: Bool
    let repliedMessage: MessageInfo?
    let onReply: () -> Void
    let onEdit: (String) -> Void
    let onDelete: () -> Void
    let onReact: (String) -> Void

    @State private var isEditing = false
    @State private var editText = ""
    @State private var isHovered = false
    @State private var showDeleteConfirm = false
    @State private var showReactionPicker = false

    private var senderName: String {
        let userId = message.sender
        if userId.hasPrefix("@"), let colonIndex = userId.firstIndex(of: ":") {
            return String(userId[userId.index(after: userId.startIndex)..<colonIndex])
        }
        return userId
    }

    var body: some View {
        HStack(alignment: .top, spacing: Layout.avatarGutter) {
            if isGrouped {
                // Show timestamp on hover in the avatar column
                if isHovered && !isEditing {
                    Text(formattedTimeShort)
                        .font(.messageTimestamp)
                        .foregroundStyle(AppColor.textTertiary)
                        .frame(width: AvatarSize.message, alignment: .center)
                } else {
                    Color.clear
                        .frame(width: AvatarSize.message, height: 1)
                }
            } else {
                MemberAvatar(userId: message.sender, size: AvatarSize.message)
            }

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if !isGrouped {
                    HStack(spacing: Spacing.sm) {
                        Text(appState.memberDisplayName(for: message.sender) ?? senderName)
                            .font(.senderName)
                            .foregroundStyle(AppColor.textPrimary)

                        Text(formattedTime)
                            .font(.messageTimestamp)
                            .foregroundStyle(AppColor.textTertiary)

                        if message.isEdited {
                            Text("(edited)")
                                .font(.messageTimestamp)
                                .foregroundStyle(AppColor.textTertiary)
                        }
                    }
                }

                if let replied = repliedMessage {
                    HStack(spacing: Spacing.sm) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(AppColor.accent.opacity(0.6))
                            .frame(width: 3, height: 28)

                        VStack(alignment: .leading, spacing: 0) {
                            Text(replied.sender)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(AppColor.accent)
                            Text(replied.body)
                                .font(.caption2)
                                .foregroundStyle(AppColor.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
                }

                if isEditing {
                    HStack(spacing: Spacing.sm) {
                        TextField("Edit message...", text: $editText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.messageBody)
                            .lineLimit(1...5)
                            .onSubmit {
                                let text = editText
                                isEditing = false
                                onEdit(text)
                            }

                        Button("Save") {
                            let text = editText
                            isEditing = false
                            onEdit(text)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("Cancel") {
                            isEditing = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    messageContent
                        .font(.messageBody)
                        .textSelection(.enabled)
                }

                if !message.reactions.isEmpty {
                    ReactionBar(
                        reactions: message.reactions,
                        currentUserId: appState.loggedInUserId ?? "",
                        onToggle: onReact
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, isGrouped ? Spacing.xxs : Spacing.xs)
        .padding(.horizontal, Spacing.xs)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(isHovered ? AppColor.surfaceHover : .clear)
        )
        .overlay(alignment: .topTrailing) {
            if (isHovered || showReactionPicker) && !isEditing {
                actionToolbar
                    .padding(.trailing, Spacing.md)
                    .offset(y: -Spacing.sm)
                    .transition(.opacity)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .alert("Delete Message", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this message?")
        }
    }

    @ViewBuilder
    private var actionToolbar: some View {
        HStack(spacing: Spacing.xs) {
            Button { onReply() } label: {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Reply")

            Button { showReactionPicker = true } label: {
                Image(systemName: "face.smiling")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("React")
            .popover(isPresented: $showReactionPicker) {
                ReactionPicker { key in
                    showReactionPicker = false
                    onReact(key)
                }
            }

            if isOwnMessage {
                Button {
                    editText = message.body
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Edit")

                Button { showDeleteConfirm = true } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(AppColor.surfaceRaised)
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        )
    }

    @ViewBuilder
    private var messageContent: some View {
        let attributed = MessageRenderCache.attributedString(for: message.formattedBody)
        switch message.messageType {
        case "image":
            MediaImageView(message: message)
        case "file":
            MediaFileView(message: message)
        case "video":
            Label(message.body, systemImage: "film")
                .foregroundStyle(.secondary)
        case "audio":
            Label(message.body, systemImage: "waveform")
                .foregroundStyle(.secondary)
        case "location":
            Label(message.body, systemImage: "location")
                .foregroundStyle(.secondary)
        case "emote":
            if let attributed {
                Text("* \(senderName) ") + Text(attributed)
            } else {
                Text("* \(senderName) \(message.body)")
                    .italic()
            }
        default:
            if let attributed {
                Text(attributed)
            } else {
                Text(message.body)
            }
        }
    }

    private var formattedTime: String {
        let date = Date(timeIntervalSince1970: Double(message.timestampMs) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var formattedTimeShort: String {
        let date = Date(timeIntervalSince1970: Double(message.timestampMs) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Date Separator

private struct DateSeparator: View {
    let timestamp: UInt64

    var body: some View {
        HStack(spacing: Spacing.md) {
            line
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColor.textTertiary)
                .layoutPriority(1)
            line
        }
        .padding(.vertical, Spacing.md)
    }

    private var line: some View {
        Rectangle()
            .fill(AppColor.borderSubtle)
            .frame(height: 1)
    }

    private var label: String {
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }
}

// MARK: - Reactions

private struct ReactionBar: View {
    let reactions: [ReactionInfo]
    let currentUserId: String
    let onToggle: (String) -> Void

    private var grouped: [(key: String, count: Int, userReacted: Bool)] {
        var dict: [String: (count: Int, userReacted: Bool)] = [:]
        for r in reactions {
            var entry = dict[r.key, default: (count: 0, userReacted: false)]
            entry.count += 1
            if r.sender == currentUserId { entry.userReacted = true }
            dict[r.key] = entry
        }
        return dict.map { (key: $0.key, count: $0.value.count, userReacted: $0.value.userReacted) }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(grouped, id: \.key) { group in
                Button {
                    onToggle(group.key)
                } label: {
                    HStack(spacing: Spacing.xxs) {
                        Text(group.key)
                            .font(.system(size: 13))
                        if group.count > 1 {
                            Text("\(group.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(AppColor.textSecondary)
                        }
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxs)
                    .background(
                        Capsule()
                            .fill(group.userReacted
                                  ? AppColor.accent.opacity(0.15)
                                  : AppColor.surfaceHover)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(group.userReacted ? AppColor.accent.opacity(0.4) : AppColor.borderSubtle, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ReactionPicker: View {
    let onPick: (String) -> Void

    private let commonEmoji = [
        "\u{1f44d}", "\u{1f44e}", "\u{2764}\u{fe0f}", "\u{1f602}",
        "\u{1f60d}", "\u{1f914}", "\u{1f389}", "\u{1f44f}",
        "\u{1f525}", "\u{1f440}", "\u{2705}", "\u{274c}",
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 4), spacing: 4) {
            ForEach(commonEmoji, id: \.self) { emoji in
                Button {
                    onPick(emoji)
                } label: {
                    Text(emoji)
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
    }
}

// MARK: - Helpers

extension RoomDetailView {
    static func calendarDay(_ timestampMs: UInt64) -> DateComponents {
        let date = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)
        return Calendar.current.dateComponents([.year, .month, .day], from: date)
    }
}

// MARK: - Deterministic avatar color

private func deterministicColor(for identifier: String) -> Color {
    let hash = abs(identifier.hashValue)
    let colors: [Color] = [
        Color(red: 0.40, green: 0.35, blue: 0.85),  // indigo
        Color(red: 0.65, green: 0.30, blue: 0.70),  // purple
        Color(red: 0.80, green: 0.35, blue: 0.50),  // pink
        Color(red: 0.85, green: 0.50, blue: 0.25),  // orange
        Color(red: 0.25, green: 0.65, blue: 0.60),  // teal
        Color(red: 0.30, green: 0.45, blue: 0.80),  // blue
        Color(red: 0.35, green: 0.70, blue: 0.45),  // green
        Color(red: 0.55, green: 0.40, blue: 0.75),  // violet
    ]
    return colors[hash % colors.count]
}

private func localpart(from userId: String) -> String {
    if userId.hasPrefix("@"), let colon = userId.firstIndex(of: ":") {
        return String(userId[userId.index(after: userId.startIndex)..<colon])
    }
    return userId
}

// MARK: - Member Avatar

struct MemberAvatar: View {
    @Environment(AppState.self) private var appState
    let userId: String
    let size: CGFloat

    @State private var avatarImage: NSImage?

    private var initial: String {
        let name = appState.memberDisplayName(for: userId) ?? localpart(from: userId)
        return String(name.prefix(1)).uppercased()
    }

    var body: some View {
        Group {
            if let image = avatarImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle()
                        .fill(deterministicColor(for: userId))
                    Text(initial)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: appState.avatarUrl(for: userId)) {
            guard let mxcUrl = appState.avatarUrl(for: userId) else {
                avatarImage = nil
                return
            }
            if let data = await appState.loadMedia(mxcUri: mxcUrl) {
                avatarImage = NSImage(data: data)
            }
        }
    }
}

// MARK: - Room Avatar

struct RoomAvatar: View {
    let roomName: String
    let roomId: String
    let isPublic: Bool
    let size: CGFloat

    private var initial: String {
        String(roomName.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(deterministicColor(for: roomId))
            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Media

private struct MediaImageView: View {
    @Environment(AppState.self) private var appState
    let message: MessageInfo

    @State private var imageData: Data?
    @State private var loadFailed = false
    @State private var showFullSize = false

    private var aspectRatio: CGFloat {
        guard let w = message.mediaWidth, let h = message.mediaHeight,
              w > 0, h > 0 else { return 4.0 / 3.0 }
        return CGFloat(w) / CGFloat(h)
    }

    private var maxWidth: CGFloat { 300 }

    @State private var decodedImage: NSImage?

    var body: some View {
        Group {
            if let nsImage = decodedImage {
                Button {
                    showFullSize = true
                } label: {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: maxWidth)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showFullSize) {
                    FullSizeImageView(image: nsImage, filename: message.body) {
                        showFullSize = false
                    }
                }
            } else if loadFailed {
                Label("Failed to load image", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.1))
                    ProgressView()
                }
                .frame(width: maxWidth, height: maxWidth / aspectRatio)
            }
        }
        .task(id: message.eventId) {
            // Optimistic path: bytes we just uploaded are held locally.
            let bytes: Data?
            if let pending = appState.pendingAttachments[message.eventId] {
                bytes = pending
            } else if let mxc = message.mediaSource {
                bytes = await appState.loadMedia(mxcUri: mxc)
            } else {
                bytes = nil
            }

            if let bytes, let img = NSImage(data: bytes) {
                decodedImage = img
            } else {
                loadFailed = true
            }
        }
    }
}

private struct FullSizeImageView: View {
    let image: NSImage
    let filename: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(filename)
                    .font(.headline)
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

private struct MediaFileView: View {
    @Environment(AppState.self) private var appState
    let message: MessageInfo

    @State private var isDownloading = false
    @State private var errorText: String?

    private var sizeLabel: String {
        guard let size = message.mediaSize else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(message.body)
                    .font(.body)
                if !sizeLabel.isEmpty {
                    Text(sizeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            if isDownloading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    saveFile()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .help("Download")
                .disabled(message.mediaSource == nil)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func saveFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = message.body
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isDownloading = true
        errorText = nil
        Task {
            defer { isDownloading = false }
            // Pending (just-uploaded) bytes are stored locally.
            if let pending = appState.pendingAttachments[message.eventId] {
                do {
                    try pending.write(to: destination)
                } catch {
                    errorText = error.displayMessage
                }
                return
            }
            guard let mxc = message.mediaSource else {
                errorText = "No media source"
                return
            }
            guard let data = await appState.loadMedia(mxcUri: mxc) else {
                errorText = "Download failed"
                return
            }
            do {
                try data.write(to: destination)
            } catch {
                errorText = error.displayMessage
            }
        }
    }
}
