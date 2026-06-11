import ParlotteLib
import ParlotteSDK
import SwiftUI

/// Reusable user picker backed by the homeserver's user-directory search.
/// Debounces input, shows matching users, and offers a manual-ID fallback so
/// you can still reach someone the directory doesn't surface. Used by the
/// New Direct Message flow and the room invite flow.
struct UserSearchPicker: View {
    @Environment(AppState.self) private var appState
    let placeholder: String
    /// Called with the chosen Matrix user ID.
    let onSelect: (String) -> Void

    @State private var term = ""
    @State private var results: [UserSearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            TextField(placeholder, text: $term)
                .textFieldStyle(.roundedBorder)
                .onChange(of: term) { scheduleSearch() }
                .onSubmit {
                    if looksLikeUserId(term) { onSelect(term) }
                }

            if isSearching {
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Searching…")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textTertiary)
                }
            }

            // Manual-ID fallback for a full Matrix ID the directory didn't return.
            if looksLikeUserId(term), !results.contains(where: { $0.userId == term }) {
                resultRow(userId: term, displayName: nil)
            }

            List(results, id: \.userId) { user in
                resultRow(userId: user.userId, displayName: user.displayName)
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func resultRow(userId: String, displayName: String?) -> some View {
        Button {
            onSelect(userId)
        } label: {
            HStack(spacing: Spacing.md) {
                MemberAvatar(userId: userId, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName ?? localpart(userId))
                        .font(.senderName)
                    Text(userId)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textTertiary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            // Debounce so we don't fire a request per keystroke.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let found = await appState.searchUsers(term: query)
            if Task.isCancelled { return }
            results = found
            isSearching = false
        }
    }

    private func looksLikeUserId(_ s: String) -> Bool {
        s.hasPrefix("@") && s.contains(":")
    }

    private func localpart(_ userId: String) -> String {
        if userId.hasPrefix("@"), let colon = userId.firstIndex(of: ":") {
            return String(userId[userId.index(after: userId.startIndex)..<colon])
        }
        return userId
    }
}

/// Sheet to start a 1:1 direct message: search for a user and pick them.
struct NewDirectMessageView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Direct Message")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
            }
            .padding(Spacing.lg)

            Divider().opacity(0.5)

            UserSearchPicker(placeholder: "Search by name or @user:server") { userId in
                Task {
                    await appState.createDirectMessage(userId: userId)
                    dismiss()
                }
            }
            .padding(Spacing.lg)
        }
        .frame(minWidth: 360, minHeight: 380)
    }
}
