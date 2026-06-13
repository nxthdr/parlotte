# Parlotte — developer convenience targets.
#
# Run `make` (or `make help`) to list everything.
#
# Common flows:
#   make run                 # build bindings + launch the app once
#   make pair                # Synapse up, register alice/bob, launch both apps
#   make alice / make bob    # launch a single profile (use two terminals)
#   make test                # fast Rust unit tests (no Docker)

APPLE_DIR   := apple/Parlotte
COMPOSE     := docker compose -f tests/integration/docker-compose.yml

.DEFAULT_GOAL := help

# ----------------------------------------------------------------------------
# Rust core
# ----------------------------------------------------------------------------

.PHONY: build
build: ## Build the Rust workspace
	cargo build

.PHONY: test
test: ## Run Rust unit tests (core + ffi, no Docker)
	cargo test -p parlotte-core -p parlotte-ffi

.PHONY: test-integration
test-integration: ## Run integration tests against Synapse in Docker
	./scripts/run-integration-tests.sh --test-threads=1

.PHONY: fmt
fmt: ## Format Rust code
	cargo fmt

.PHONY: clippy
clippy: ## Lint Rust code (warnings are errors)
	cargo clippy --all-targets -- -D warnings

# ----------------------------------------------------------------------------
# Apple build
# ----------------------------------------------------------------------------

.PHONY: bindings
bindings: ## Build the Rust static lib + regenerate Swift bindings
	./scripts/build-apple.sh

.PHONY: app
app: ## Build a real Parlotte.app bundle (notifications/keychain work)
	./scripts/build-app.sh

.PHONY: test-swift
test-swift: bindings ## Run the Swift state-management tests (no Xcode)
	cd $(APPLE_DIR) && swift run TestRunner

# ----------------------------------------------------------------------------
# Run the app
# ----------------------------------------------------------------------------

.PHONY: run
run: bindings ## Run the macOS app (default profile, debug logging)
	cd $(APPLE_DIR) && swift run Parlotte --debug

# ----------------------------------------------------------------------------
# Local Synapse + alice/bob multi-instance testing
# ----------------------------------------------------------------------------

.PHONY: synapse
synapse: ## Start local Synapse (Docker), wait for ready, register alice + bob
	./scripts/create-test-users.sh

.PHONY: synapse-reset
synapse-reset: ## Wipe the Synapse volume, restart, and re-register alice + bob
	./scripts/create-test-users.sh --reset

.PHONY: synapse-down
synapse-down: ## Stop Synapse and delete its data volume
	$(COMPOSE) down -v --remove-orphans

.PHONY: alice
alice: bindings ## Run the app as alice (run in its own terminal)
	cd $(APPLE_DIR) && swift run Parlotte --profile alice --debug

.PHONY: bob
bob: bindings ## Run the app as bob (run in its own terminal)
	cd $(APPLE_DIR) && swift run Parlotte --profile bob --debug

.PHONY: pair
pair: bindings synapse ## Synapse up + register users, then launch alice (background) and bob (foreground)
	cd $(APPLE_DIR) && swift build
	@echo ""
	@echo "Launching two instances. Log in at http://localhost:8008 as alice/bob (password: password123)."
	@echo "Quit bob to return to this terminal; alice keeps running until you quit its window."
	@echo ""
	cd $(APPLE_DIR) && ( ./.build/debug/Parlotte --profile alice --debug & ) && \
		./.build/debug/Parlotte --profile bob --debug

# ----------------------------------------------------------------------------
# Release / TestFlight
#
# Before archiving, bump CURRENT_PROJECT_VERSION in apple/Parlotte/project.yml
# (App Store Connect rejects duplicate build numbers). Requires a one-time
# credential setup — see CLAUDE.md "Releasing to TestFlight".
# ----------------------------------------------------------------------------

.PHONY: archive
archive: ## Build a signed App Store .pkg (build/export/Parlotte.pkg)
	./scripts/archive.sh

.PHONY: upload
upload: ## Validate + upload the exported .pkg to App Store Connect / TestFlight
	./scripts/upload.sh

.PHONY: release
release: archive upload ## Archive then upload a new TestFlight build (bump build number first!)

# ----------------------------------------------------------------------------
# Help
# ----------------------------------------------------------------------------

.PHONY: help
help: ## List available targets
	@echo "Parlotte — make targets:"
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
