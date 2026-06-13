# Parlotte Roadmap (macOS app)

## Core
- [x] Login / logout with session persistence
- [x] Apple build pipeline (Rust -> XCFramework -> Swift bindings)
- [x] Multi-profile support (`--profile` flag for testing)
- [x] Debug logging (`--debug` flag)
- [x] Background sync (persistent connection instead of 5s polling)
- [ ] Adopt `matrix-sdk-ui` `SyncService` + `RoomListService` (Simplified Sliding Sync, MSC4186) — near-instant startup at scale; replaces the manual `/sync` loop (`sync.rs`) and our hand-rolled room enumeration + recency sort (`client.rs::rooms` / `room.rs::sort_rooms_by_recency`)

## Rooms
- [x] Room list with public/private/encrypted indicators
- [x] Sidebar split between "Direct messages" and "Rooms" (Matrix `m.direct`)
- [x] Room list sorted by most recent activity (pending invites pinned on top, then latest-event timestamp most-recent-first)
- [x] Create rooms (public or private)
- [x] Create direct messages (1:1 room flagged `m.direct`, auto-invite, sorts into DM section)
- [x] User directory search / invite autocomplete (`/user_directory/search`, instead of typing full Matrix IDs)
- [x] Private rooms encrypted by default (Megolm E2EE)
- [x] Public room directory (explore and join)
- [x] Invite users to rooms
- [x] Accept invites
- [x] Leave room
- [x] Room member list
- [x] Room settings (name, topic)
- [ ] Member sort and filter (by role, presence, name)
- [ ] Room aliases / canonical address management
- [x] Power levels editor (kick, ban, change roles)
- [ ] Tombstoned room handling (follow upgrade, retire old room)

## Spaces
- [ ] Join and browse spaces
- [ ] Space sidebar with hierarchy
- [ ] Space lobby / room directory view
- [ ] Create spaces (public or private)
- [ ] Add existing rooms to a space
- [ ] Space settings (name, topic, visibility)
- [ ] Space permissions / power levels

## Messaging
- [x] Timeline-backed message handling (matrix-sdk-ui `Timeline`: snapshot-driven
      UI, automatic local echoes, edit/redaction/reaction aggregation, UTD
      decryption-retry healing, back-pagination — replaces the hand-rolled
      `/messages` reconciliation, optimistic-placeholder and redaction-heuristic code)
- [x] Send and receive text messages
- [x] Message history with pagination on scroll
- [x] Message editing
- [x] Message deletion
- [x] Reply to messages
- [x] Typing indicators
- [x] Reactions (emoji)
- [x] Rich text rendering (HTML formatted messages, sanitised)
- [x] Non-text message indicators (image, file, video, audio, location)
- [x] Media messages (display images, download files)
- [x] Media upload (send images, files)
- [ ] Threads
- [ ] Pinned messages
- [ ] Message search (server-assisted)
- [ ] URL previews (opt-in)
- [ ] Reaction viewer (who reacted with what)
- [ ] Per-message read-receipts viewer
- [ ] Custom emoji and sticker packs (MSC2545 image packs)
- [ ] Slash commands and `@` / `:` autocomplete in composer
- [ ] In-app PDF viewer and basic image editor (crop, rotate)
- [ ] Jump to date / jump to message

## Calls
- [ ] Voice and video calls (Element Call / matrix-rtc embed)
- [ ] Call notifications and join-from-banner
- [ ] In-call controls (mute, video, screen share)

## Notifications
- [x] Unread indicators / notification badges
- [x] Read receipts (mark rooms as read)
- [x] Local notifications (banners for new messages in non-focused rooms, tap-to-open, profile toggle)
- [ ] Per-room notification mode (all / mentions / muted)
- [ ] Keyword and mention rules editor
- [ ] Server push rules UI (`m.push_rules`)
- [ ] Remote push (APNs + Sygnal push gateway, pusher registration, NSE for E2EE decryption) — deferred to the iOS port

## Security
- [x] Legacy SSO login (browser-based, works with most Synapse servers)
- [x] Native OIDC login (MAS / OpenID Connect) — MSC3861 via matrix-sdk OAuth, `ASWebAuthenticationSession` on Apple, dynamic client registration, refresh-token persistence
- [x] Device verification (cross-signing)
  - [x] Self-verification via SAS emoji (initiator + receiver flows)
  - [x] Core + FFI: request, accept, start SAS, confirm/mismatch, cancel
  - [x] Incoming verification request listener wired through sync
  - [x] Modal UI for emoji comparison (both ends)
  - [ ] QR code verification
  - [ ] Cross-user verification from member list
  - [ ] Per-device trust badges in member list
- [x] Key backup and recovery (reinstall must not lose encrypted history)
  - [x] Core + FFI: enable/disable/recover + `RecoveryState`
  - [x] Settings UI: status, enable, recovery-key display, key entry
  - [x] Post-login prompt when `RecoveryState::Incomplete` (new device)
  - [x] `is_last_device` warning before logout
  - [x] Reset recovery from this device (lost-key path)
- [ ] Device management (list other sessions, rename, sign out remotely)
- [x] Ignore / block users (`m.ignored_user_list`, member-list action + profile management, timeline filtering)
- [x] Hardening pass (2026-04)
  - [x] Access + refresh tokens moved from UserDefaults to Keychain (legacy plaintext auto-migrated and wiped)
  - [x] HTML sanitiser on message formatted bodies (blocks `<img>`/`<iframe>`/`<script>`/`<style>`, `on*=` handlers, `javascript:`/`data:` hrefs) — stops arbitrary senders triggering network fetches via NSAttributedString
  - [x] SSO callback server binds loopback-only and validates CSRF state parameter with constant-time compare
  - [x] Debug IPC server requires bearer token (random per launch, printed to stderr); refuses requests without it
  - [x] `--profile` input validated (`[A-Za-z0-9_-]{1,64}`) before it's used in filesystem paths

## UX
- [x] User profile (display name, avatar, avatar upload + remove)
- [x] Light & dark mode
- [x] Design system (spacing tokens, semantic colors, typography scale)
- [x] Message grouping (consecutive same-sender messages collapse)
- [x] Room avatars in sidebar and headers
- [x] Redesigned room list (two-line rows with avatar, name, subtitle)
- [x] Redesigned room header (avatar, consolidated overflow menu)
- [x] Redesigned message composer (rounded surface with border)
- [x] Sidebar header with user avatar and sync status
- [x] Empty conversation state
- [ ] Presence indicators (online / idle / offline)
- [ ] Quick switcher (Cmd+K to jump to a room or DM)

## Testing
- [x] Unit tests for input validation and error paths (parlotte-core)
- [x] Integration tests against real Synapse (Docker)
- [x] FFI round-trip tests (type conversions, error mapping)
- [x] Swift state management tests (optimistic updates, failure revert, dedup)
- [x] AppState edge-case coverage (pagination guards, invite/create error paths, delete revert)
- [x] Debug IPC server (`--debug-ipc-port`) for AI-driven UI testing
- [x] DebugServer test suite (state snapshots, command dispatch, error paths)
- [x] `ax-inspect` accessibility driver (real keystroke typing, button clicks, field input, wait-for)
- [x] Crash reporting: rely on Xcode Organizer (automatic once distributed via TestFlight / App Store; no in-app code needed)
- [x] CI pipeline (GitHub Actions: build, test, clippy, fmt)
- [x] Persistent sync loop integration test (start sync, receive callback, stop; plus restart-doesn't-duplicate-loop)

## Branding
- [x] App icon (SVG master at `branding/icon/parlotte-icon.svg`; full macOS set generated by `scripts/build-icon.sh`)
- [x] App name and bundle identifier finalized (`Parlotte` / `dev.nxthdr.Parlotte`)
- [x] Marketing screenshots for the App Store listing
- [x] App Store description, keywords, category (first-pass copy at `branding/app-store/copy.txt`)
- [x] Support + marketing + privacy-policy URLs hosted and live at `nxthdr.github.io/parlotte/` (Jekyll pages at `docs/`)

## Submission
- [x] Privacy manifest (`PrivacyInfo.xcprivacy`) declaring data collection and required-reason APIs
- [x] Privacy policy URL live (`nxthdr.github.io/parlotte/privacy/`)
- [x] Mac App Store distribution profile and code signing (automatic signing via `scripts/archive.sh`)
- [x] Notarization and hardened runtime (hardened runtime enabled; notarization handled server-side on App Store submission)
- [x] Sandbox entitlements audit (network client/server + user-selected files, see `Resources/Parlotte.entitlements`)
- [x] Apple-Silicon-only (`arm64`) stripped build via `scripts/build-apple.sh` (`archive.sh` forces `ARCHS=arm64`); archive + signed `.pkg` export validated end-to-end
- [x] Export compliance declared (`ITSAppUsesNonExemptEncryption = false`; exemption basis in `COMPLIANCE.md`)
- [x] First TestFlight build uploaded and verified by internal testers
- [ ] App Store product page complete + submitted for review (demo Matrix account in App Review notes)
