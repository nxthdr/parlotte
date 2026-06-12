# Parlotte

A fast, responsive, polished Matrix client — an alternative to the Element ecosystem. Built with a Rust core and native platform UIs.

## Vision

Parlotte aims to be a commercial-quality Matrix client. It should feel fast, look beautiful, and be a joy to use. The Matrix ecosystem needs clients that compete with proprietary messaging apps on UX.

## Architecture

```
parlotte/
├── crates/
│   ├── parlotte-core/     # Pure Rust. Wraps matrix-rust-sdk. All platform-agnostic logic.
│   └── parlotte-ffi/      # UniFFI bridge. Exposes core to Swift (and future bindings).
├── apple/                 # macOS + iOS SwiftUI app (future)
├── tests/integration/     # Integration tests against a real Synapse server (Docker)
└── scripts/               # Build and test automation
```

### Core (`parlotte-core`)

The core is the heart of parlotte. It wraps `matrix-sdk` (v0.18) behind a clean, platform-agnostic API. Every platform UI consumes only this API — no platform-specific code touches the Matrix SDK directly.

Key type: `ParlotteClient` — owns a `matrix_sdk::Client` and a `tokio::Runtime`. All public methods are synchronous (using `runtime.block_on()`), making them trivial to call from any FFI boundary.

Modules:
- `client.rs` — `ParlotteClient`: login, logout, rooms, messages, sync, event listener
- `error.rs` — `ParlotteError` enum with `From<matrix_sdk::Error>` conversions
- `room.rs` — `RoomInfo` data type
- `message.rs` — `MessageInfo`, `SessionInfo` data types
- `sync.rs` — `SyncManager` for background sync lifecycle
- `timeline.rs` — `TimelineManager`: wraps the `matrix-sdk-ui` `Timeline` for the
  active room. Subscribes to the diff stream and emits full `MessageInfo`
  snapshots via a `TimelineListener` callback; handles back-pagination and
  local-echo sends (message/reply/reaction). The event cache is enabled in
  `ParlotteClient::new` because the Timeline is backed by it.

### FFI (`parlotte-ffi`)

Uses UniFFI **proc-macro approach** (not UDL files). Types are annotated with `#[derive(uniffi::Object)]`, `#[derive(uniffi::Record)]`, `#[derive(uniffi::Error)]`, and `#[uniffi::export]`.

The FFI crate re-wraps core types with UniFFI annotations rather than annotating core types directly — this keeps `parlotte-core` free of FFI concerns.

### Apple (`apple/`)

macOS app (macOS 14+), with iOS (17+) planned. SwiftUI only — no UIKit, no AppKit, no legacy frameworks. The Swift code consumes `ParlotteSDK` (a Swift package wrapping the UniFFI-generated bindings).

Structure:
- `apple/ParlotteSDK/` — Swift package with 3 targets: `RustFramework` (static lib), `ParlotteFFI` (UniFFI-generated Swift), `ParlotteSDK` (hand-written async actor wrapper)
- `apple/Parlotte/` — SwiftUI app package, depends on ParlotteSDK
  - `Sources/ParlotteLib/` — Library target with AppState and models (testable)
  - `Sources/ParlotteApp/` — Executable target with @main entry point and views
  - `Sources/TestRunner/` — Executable test runner (works without Xcode)
  - `Tests/` — Swift Testing test suite for AppState state management
- `scripts/build-apple.sh` — Builds Rust static lib, generates Swift bindings, copies to ParlotteSDK

## Development Commands

```bash
# Build everything (Rust)
cargo build

# Run unit tests (no Docker needed)
cargo test -p parlotte-core

# Run integration tests (requires Docker)
./scripts/run-integration-tests.sh --test-threads=1

# Run integration tests and keep Synapse running after
KEEP_RUNNING=1 ./scripts/run-integration-tests.sh --test-threads=1

# Build Apple XCFramework + Swift bindings
./scripts/build-apple.sh

# Build and run macOS app
cd apple/Parlotte && swift run Parlotte

# Run with a named profile (for multi-instance testing)
cd apple/Parlotte && swift run Parlotte --profile alice

# Run with debug logging from the Rust core
cd apple/Parlotte && swift run Parlotte --debug

# Run Swift state management tests (no Xcode required)
cd apple/Parlotte && swift run TestRunner
```

## Testing Philosophy

**Test our code, not the SDK.** We are clients of `matrix-sdk` — we trust it works. Our tests verify:

- Input validation (invalid room IDs, user IDs, URLs produce the right `ParlotteError` variant)
- Error mapping (`From` impls convert SDK errors into our error types correctly)
- Type construction and invariants
- State management (sync manager lifecycle, optimistic UI updates)
- Event listener registration

**Swift state management tests** (`swift run TestRunner` from `apple/Parlotte`): Test AppState optimistic updates, failure revert, placeholder lifecycle, dedup, and room selection. Uses `MockMatrixClient` with `MatrixClientProtocol` for dependency injection. Uses Swift Testing framework (`import Testing`), not XCTest.

**Unit tests** (`cargo test -p parlotte-core`): Fast, no external dependencies. Embedded in each source file under `#[cfg(test)]`.

**Integration tests** (`cargo test -p parlotte-integration`): Run against a real Synapse homeserver in Docker. Test end-to-end flows: registration, login, room creation, messaging between users, sync. See `tests/integration/docker-compose.yml`.

When adding a new core feature:
1. Write the implementation in `parlotte-core`
2. Add unit tests for validation and error paths
3. Add integration tests for the happy path against Synapse
4. Add UniFFI annotations in `parlotte-ffi`

## Roadmap

`ROADMAP.md` at the repo root tracks shipped and planned features. **Always
update it before committing** — tick off boxes for work that just landed, or
add new entries for features introduced in the commit. The roadmap is the
canonical "what's done" source; commits that ship visible features without a
corresponding roadmap update create drift between intent and reality.

## Coding Conventions

### Rust

- **Edition 2021**, workspace dependencies in root `Cargo.toml`
- `thiserror` for error types, `tracing` for logging
- Public API on `ParlotteClient` is synchronous (`block_on`). Internal code is async.
- `#![recursion_limit = "512"]` needed in `parlotte-core` due to matrix-sdk's deep type nesting
- Use `matches!()` for enum comparisons when the type doesn't implement `PartialEq`
- Tests in the same file under `#[cfg(test)] mod tests`

### Swift

- SwiftUI only, minimum macOS 14 / iOS 17
- `@Observable` macro (not `ObservableObject`/`@Published`)
- Swift concurrency (`async/await`, actors) — no Combine, no callbacks in Swift layer
- `MatrixClient` actor wraps blocking FFI calls with `Task.detached`
- `AppState` is `@Observable @MainActor` — single source of truth for all UI state

### General

- No speculative abstractions. Build what's needed now.
- Keep the core API surface small. Add methods only when a platform UI needs them.
- Every public method on `ParlotteClient` should handle invalid input gracefully (return `ParlotteError`, don't panic).

## Architecture Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Matrix SDK | `matrix-sdk` 0.18 | Official Rust SDK, actively maintained, used by Element X |
| Message handling | `matrix-sdk-ui` `Timeline` | Snapshot-driven UI: SDK merges local echoes, edits, redactions, reactions, UTD-retry and pagination — far less custom reconciliation than the raw `/messages` API |
| Sync strategy | Standard `/sync` | Simpler starting point; migrate to Sliding Sync later for perf |
| FFI | UniFFI proc-macros | No UDL duplication, native async support, maintained by Mozilla |
| Storage | SQLite via `matrix-sdk-sqlite` | Persistent, performant, works on all platforms |
| Async runtime | tokio, owned by `ParlotteClient` | `matrix-sdk` requires tokio; embedding the runtime simplifies FFI |
| Test server | Synapse in Docker | Official reference server; `docker compose` for reproducible setup |
| License | MIT | Permissive license, easy for anyone to use and contribute |

## Integration Test Infrastructure

Docker Compose (`tests/integration/docker-compose.yml`):
- `synapse-init`: One-shot container that generates Synapse config from env vars via `/start.py migrate_config`
- `synapse`: Runs the homeserver on `0.0.0.0:8008`, loads generated config + `extra-config.yaml` (open registration, no rate limits)
- Volume `synapse-data`: Persists between restarts. `docker compose down -v` wipes everything.

The `./scripts/run-integration-tests.sh` script handles the full lifecycle (start, wait, test, teardown). Pass `KEEP_RUNNING=1` to leave Synapse up for debugging.
