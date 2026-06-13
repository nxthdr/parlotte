---
description: Test the Parlotte macOS app UI via a JSON IPC endpoint (fastest), the ax-inspect accessibility tool (for real UI events), or osascript as a last resort
match:
  - test ui
  - test the app
  - test visually
  - check the app
  - verify the ui
  - feedback loop
  - test scroll
  - test pagination
  - launch the app
---

# Parlotte UI Testing

Three tools, in preference order. **Always reach for the higher tier first.**

| Tier | Tool | Cost | Use for |
|---|---|---|---|
| 1 | `curl` → Debug IPC | ~5–20 ms | Anything you can express as "read state" or "call a method on AppState" |
| 2 | `ax-inspect` | ~300–500 ms | Real UI events that must go through the view layer (clicks, typing, keystrokes, waits) |
| 3 | `osascript` / `screencapture` | 2–10 s | Only when tiers 1 and 2 can't do it (OAuth browser flows, visual regressions) |

Tier 1 is usually ~100× cheaper per check than tier 3. Token-wise too: IPC returns structured JSON, not text dumps.

## Prereqs

- macOS Accessibility permissions for the terminal (System Settings → Privacy & Security → Accessibility). Needed only for tier 2/3.
- `ax-inspect` is a compiled Swift binary at `.claude/skills/ax-inspect`. Rebuild after editing:
  ```bash
  swiftc .claude/skills/ax-inspect.swift -o .claude/skills/ax-inspect \
    -framework AppKit -framework ApplicationServices
  ```

## Launching

Always launch with the debug IPC port so tier 1 is available:

```bash
cd /Users/matthieugouel/Documents/Code/parlotte/apple/Parlotte && \
  swift run Parlotte --debug-ipc-port 9999 > /tmp/parlotte.log 2>&1 &
```

Session state is persisted per profile, so if the user was logged in last time, the app restores automatically. For multi-instance testing: `--profile alice` / `--profile bob` use separate stores.

Wait for the app to be ready before interacting:

```bash
.claude/skills/ax-inspect wait-for "General" 10    # or any known room name
```

---

## Tier 1 — Debug IPC (primary)

Base URL: `http://127.0.0.1:9999` (bound to loopback only).

### `GET /state` — full AppState snapshot

Returns JSON with all the fields the UI is rendering:

```
profile, isLoggedIn, isLoading, isCheckingSession, isSyncActive,
loggedInUserId, homeserverURL, errorMessage,
selectedRoomId, rooms[], messages[], hasMoreMessages, isLoadingMoreMessages,
typingUsers{}, currentRoomTypingUsers[]
```

Common idioms:

```bash
# Is the expected room selected?
curl -s http://127.0.0.1:9999/state | jq -r .selectedRoomId

# How many messages are loaded?
curl -s http://127.0.0.1:9999/state | jq '.messages | length'

# What's the last message body?
curl -s http://127.0.0.1:9999/state | jq -r '.messages | last | .body'

# Did an error surface?
curl -s http://127.0.0.1:9999/state | jq -r .errorMessage

# Compact room list
curl -s http://127.0.0.1:9999/state | jq '.rooms[] | {displayName, unreadCount}'
```

### `POST /cmd` — drive AppState directly

Request body is `{"op": "...", ...args}`. Response is `{"ok": true}` or `{"ok": false, "error": "..."}`.

| op | args | Effect |
|---|---|---|
| `select_room` | `id` **or** `name` | Sets `selectedRoomId`, triggers message refresh |
| `send_message` | `body` | Awaits full send (optimistic + server confirm) |
| `load_older` | — | Pagination; no-op if no endToken |
| `refresh` | — | `refreshRooms` + `refreshMessages` if a room is selected |
| `logout` | — | Full logout + store clear |

```bash
curl -s -d '{"op":"select_room","name":"Alerts"}' http://127.0.0.1:9999/cmd
curl -s -d '{"op":"send_message","body":"hello"}' http://127.0.0.1:9999/cmd
curl -s -d '{"op":"load_older"}' http://127.0.0.1:9999/cmd
curl -s -d '{"op":"refresh"}' http://127.0.0.1:9999/cmd
```

**This is the answer to "does the state agree with the UI?"** — `/cmd` mutates, then `/state` proves it.

---

## Tier 2 — `ax-inspect` (real UI events)

For anything the IPC can't do: clicking buttons, typing into fields, sending keystrokes, waiting for visible text.

```bash
alias ax='.claude/skills/ax-inspect'
```

### Commands

| Command | What it does |
|---|---|
| `dump` | All text/button/field elements with their role and value |
| `first N` | First N text elements (header first, then content) |
| `find TEXT` | Case-insensitive text search; exits 1 if nothing matches |
| `tree [--json]` | Full accessibility tree. `--json` → pretty JSON, easier to parse |
| `wait-for TEXT [TIMEOUT]` | Poll every 100 ms until TEXT appears (default 5 s). Exit 0 match / 1 timeout |
| `select ROOM` | Select a sidebar row by exact displayed name |
| `click-text LABEL` | Click the first AXButton whose title/description contains LABEL |
| `click-button X1 Y1 X2 Y2` | Click the first AXButton in a bounding box (last resort) |
| `set-field QUERY VALUE` | Set an AXTextField/AXTextArea whose title/desc/placeholder contains QUERY |
| `type VALUE` | Set VALUE on the currently focused editable element |
| `press KEY` | Send a key. Modifiers allowed: `cmd+k`, `shift+tab`, `ctrl+alt+a`. Keys: return, escape, tab, space, delete, up/down/left/right, home/end, pageup/pagedown, a-z, 0-9 |

### Common patterns

```bash
# Set the message composer and submit via the Send button.
# set-field types via real keystrokes so SwiftUI @State updates.
# NOTE: The composer is a multi-line TextField — press return inserts a
#       newline, it does NOT submit. Use click-text "Send" instead.
ax set-field "Send a message" "hello from the test"
ax click-text "Send"

# Load older messages (replaces brittle coordinate-based click)
ax click-text "Load older messages"

# Wait for a specific message to appear after sync
ax wait-for "Deploy succeeded" 10

# Keyboard shortcuts (modifiers: cmd / shift / ctrl / alt)
ax press cmd+,           # e.g. a chorded shortcut
ax press escape          # dismiss modal
ax press return          # submit (single-line fields only)
```

### When to pick tier 2 over tier 1

| Want to do | Use |
|---|---|
| Check the message list | `curl /state | jq` |
| Send a message | `curl /cmd send_message` |
| Click a SwiftUI button with no exposed command | `ax click-text` |
| Fill a form field and submit | `ax set-field` + `ax click-text` (or `ax press return` for single-line fields) |
| Trigger a keyboard shortcut | `ax press` |
| Verify a message is rendered (not just in state) | `ax wait-for` (if you need the UI confirmation) |

---

## Typical workflow

```bash
# 1. Launch
swift run Parlotte --debug-ipc-port 9999 > /tmp/parlotte.log 2>&1 &
ax wait-for "General" 10

# 2. Drive via IPC
curl -s -d '{"op":"select_room","name":"General"}' http://127.0.0.1:9999/cmd
curl -s -d '{"op":"send_message","body":"smoke test"}' http://127.0.0.1:9999/cmd

# 3. Verify via IPC (cheap)
curl -s http://127.0.0.1:9999/state | jq -r '.messages | last | .body'

# 4. UI event for something IPC can't reach
ax click-text "Load older messages"
ax wait-for "2026-03-28" 5   # verify the older date header rendered
```

## Rebuilding and relaunching

```bash
kill $(pgrep Parlotte) 2>/dev/null
cd /Users/matthieugouel/Documents/Code/parlotte/apple/Parlotte && swift build
swift run Parlotte --debug-ipc-port 9999 > /tmp/parlotte.log 2>&1 &
```

If Rust code changed, rebuild the XCFramework first:

```bash
./scripts/build-apple.sh
```

---

## Tier 3 — fallbacks (only when tiers 1–2 can't do it)

### OAuth / SSO browser login

IPC can't drive a browser. For SSO flows, the user must complete the browser-side login manually, or you can pre-seed a session in the profile's store.

### Screenshot (visual verification)

```bash
screencapture -x $TMPDIR/parlotte.png
```

Then `Read` the resulting PNG. Only use when a visual regression matters and neither `/state` nor `ax-inspect` can express the check — screenshots are the most token-expensive option.

### Raw osascript

Reserved for attributes that `ax-inspect` doesn't expose. Example — window position/size:

```bash
osascript -e 'tell application "System Events" to tell process "Parlotte" to return {position of window 1, size of window 1}'
```

Per-element traversal via osascript (5–10 s per call) is obsolete — `ax-inspect tree --json` is strictly better.

---

## Limitations

- OAuth/SSO login can't be automated (browser handoff).
- IPC surface is intentionally small — extend `DebugServer.handleCommand` in `apple/Parlotte/Sources/ParlotteLib/Debug/DebugServer.swift` when a new flow needs an op.
- `ax-inspect type` needs a pre-focused editable element. Prefer `set-field` for the common case (find + set in one shot).
