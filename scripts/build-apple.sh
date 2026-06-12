#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Parlotte ships Apple Silicon only (arm64). The Rust core statically links the
# entire matrix-sdk tree (~150 MB of code), so shipping a universal binary
# would nearly double the download for an x86_64 slice no supported user needs.
# The Xcode project pins ARCHS=arm64 to match, so a single-arch lib links
# cleanly. (To restore Intel support, add "x86_64-apple-darwin" here AND set
# ARCHS back to "$(ARCHS_STANDARD)" in apple/Parlotte/project.yml.)
TARGET_TRIPLES=("aarch64-apple-darwin")
FFI_LIB_NAME="parlotte_ffi"
BUILD_MODE="${1:-release}"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
log() { echo -e "${GREEN}[build-apple]${NC} $*"; }
err() { echo -e "${RED}[build-apple]${NC} $*" >&2; }

cd "$REPO_ROOT"

# Match the deployment target to the Swift package's minimum (macOS 14).
# Without this, the Rust lib inherits the host SDK version, causing
# "built for newer macOS" linker warnings when linking into the app.
export MACOSX_DEPLOYMENT_TARGET="14.0"

if [ "$BUILD_MODE" = "debug" ]; then
    CARGO_MODE_FLAG=""
    MODE_DIR="debug"
else
    CARGO_MODE_FLAG="--release"
    MODE_DIR="release"
fi

# Step 1: Build the Rust static library for each architecture.
PER_ARCH_LIBS=()
for triple in "${TARGET_TRIPLES[@]}"; do
    log "Building Rust static library ($BUILD_MODE, $triple)..."
    # Idempotent; ensures the target is present on a fresh machine / CI.
    rustup target add "$triple" >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    cargo build -p parlotte-ffi $CARGO_MODE_FLAG --target "$triple"

    lib="$REPO_ROOT/target/$triple/$MODE_DIR/lib${FFI_LIB_NAME}.a"
    if [ ! -f "$lib" ]; then
        err "Static library not found at $lib"
        exit 1
    fi
    PER_ARCH_LIBS+=("$lib")
done

# Step 2: Assemble the lib the Swift package links against. `lipo -create`
# handles one or many arches, so this still works if Intel is re-added later.
LIB_OUT="$REPO_ROOT/apple/ParlotteSDK/RustFramework"
mkdir -p "$LIB_OUT"
UNIVERSAL_LIB="$LIB_OUT/lib${FFI_LIB_NAME}.a"
log "Assembling static library (${TARGET_TRIPLES[*]})..."
lipo -create "${PER_ARCH_LIBS[@]}" -output "$UNIVERSAL_LIB"
log "Static library: $UNIVERSAL_LIB ($(lipo -archs "$UNIVERSAL_LIB"))"

# Step 3: Generate Swift bindings. Bindings are architecture-independent, so
# any one per-arch lib works as the metadata source.
log "Generating Swift bindings..."
STAGING="$REPO_ROOT/target/uniffi-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"

cargo run -p parlotte-ffi --bin uniffi-bindgen generate \
    --library "${PER_ARCH_LIBS[0]}" \
    --language swift \
    --out-dir "$STAGING"

for f in "${FFI_LIB_NAME}.swift" "${FFI_LIB_NAME}FFI.h" "${FFI_LIB_NAME}FFI.modulemap"; do
    if [ ! -f "$STAGING/$f" ]; then
        err "Expected generated file not found: $STAGING/$f"
        exit 1
    fi
done
log "Generated: $(ls "$STAGING" | tr '\n' ' ')"

# Step 4: Copy generated Swift bindings to ParlotteSDK
log "Copying generated files to ParlotteSDK..."
FFI_SOURCES="$REPO_ROOT/apple/ParlotteSDK/Sources/ParlotteFFI"
mkdir -p "$FFI_SOURCES"
cp "$STAGING/${FFI_LIB_NAME}.swift" "$FFI_SOURCES/"

# Step 5: Set up the C headers for the FFI module
HEADERS_DIR="$REPO_ROOT/apple/ParlotteSDK/Sources/ParlotteFFIHeaders"
rm -rf "$HEADERS_DIR"
mkdir -p "$HEADERS_DIR"
cp "$STAGING/${FFI_LIB_NAME}FFI.h" "$HEADERS_DIR/"
cp "$STAGING/${FFI_LIB_NAME}FFI.modulemap" "$HEADERS_DIR/module.modulemap"

log "Done! Build pipeline complete."
log ""
log "Static lib:  apple/ParlotteSDK/RustFramework/lib${FFI_LIB_NAME}.a (universal)"
log "Swift code:  apple/ParlotteSDK/Sources/ParlotteFFI/${FFI_LIB_NAME}.swift"
log "C headers:   apple/ParlotteSDK/Sources/ParlotteFFIHeaders/include/"
