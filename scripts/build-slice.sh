#!/usr/bin/env bash
# build-slice.sh — build ONE ANGLE platform slice.
#
# Usage: bash scripts/build-slice.sh <ios-device|ios-sim|macos>
#
# Reads config/gn-args-<slice>.gnargs, runs `gn gen` + `ninja` in the ANGLE
# source tree, and stages the built frameworks into build/<slice>/.
# For macos, also calls wrap-macos-framework.sh to package the bare .dylibs
# into .framework bundles (ANGLE only produces frameworks on iOS natively).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ANGLE_SRC="${ANGLE_SRC:-$PKG_DIR/../angle}"

SLICE="${1:-}"
if [[ -z "$SLICE" ]]; then
    echo "Usage: $0 <ios-device|ios-sim|macos>" >&2
    exit 2
fi

CONFIG="$PKG_DIR/config/gn-args-${SLICE}.gnargs"
if [[ ! -f "$CONFIG" ]]; then
    echo "ERROR: no GN args config for slice '$SLICE' at $CONFIG" >&2
    exit 1
fi

# Auto-detect sibling depot_tools if gn isn't on PATH.
if ! command -v gn >/dev/null 2>&1; then
    DEPOT_TOOLS="$PKG_DIR/../depot_tools"
    if [[ -x "$DEPOT_TOOLS/gn" ]]; then
        export PATH="$DEPOT_TOOLS:$PATH"
    else
        echo "ERROR: gn not found. Install depot_tools or set PATH." >&2
        exit 1
    fi
fi
command -v ninja >/dev/null 2>&1 || {
    export PATH="$PKG_DIR/../depot_tools:$PATH"
}
command -v autoninja >/dev/null 2>&1 || true  # optional; ninja is fine

OUT_DIR="$PKG_DIR/build/$SLICE"
GN_OUT="$ANGLE_SRC/out/angle-pkg-$SLICE"

log() { printf '\033[1;34m[build-slice:%s]\033[0m %s\n' "$SLICE" "$*" >&2; }
die() { printf '\033[1;31m[build-slice:%s error]\033[0m %s\n' "$SLICE" "$*" >&2; exit 1; }

[[ -d "$ANGLE_SRC" ]] || die "ANGLE source not found at $ANGLE_SRC (set ANGLE_SRC to override)"
[[ -n "$(ls -A "$ANGLE_SRC/third_party/abseil-cpp" 2>/dev/null)" ]] || \
    die "ANGLE tree at $ANGLE_SRC is not synced (third_party/abseil-cpp is empty). Run 'gclient sync' in $ANGLE_SRC first."

# The checkout must be at the pinned ANGLE commit (config/angle.lock) so this
# slice and the Windows workflow's slice describe the same source revision.
# ANGLE_PIN_CHECK=0 skips the check for local experiments.
if [[ "${ANGLE_PIN_CHECK:-1}" != "0" ]]; then
    ANGLE_SRC="$ANGLE_SRC" bash "$SCRIPT_DIR/angle-version.sh" check || \
        die "ANGLE pin check failed (set ANGLE_PIN_CHECK=0 to bypass)"
fi

# Build the gn args string from the config file (strip comments + blank lines).
GN_ARGS=$(grep -v '^\s*#' "$CONFIG" | grep -v '^\s*$' | tr '\n' ' ' | sed 's/ $//')

log "ANGLE source : $ANGLE_SRC"
log "GN output    : $GN_OUT"
log "Staging dir  : $OUT_DIR"

# ── gn gen ────────────────────────────────────────────────────────────────
log "Running gn gen..."
( cd "$ANGLE_SRC" && gn gen "$GN_OUT" --args="$GN_ARGS" )

# ── ninja build ───────────────────────────────────────────────────────────
# Use the REAL ninja binary, not depot_tools' wrapper (which prints a Siso
# migration warning and refuses to run on dirs with Siso state). The Homebrew
# / system ninja at /opt/homebrew/bin/ninja or /usr/local/bin/ninja is the
# real binary; depot_tools' ninja is a Python wrapper with Siso baggage.
log "Building libEGL + libGLESv2 with ninja..."
NINJA_BIN=""
for candidate in /opt/homebrew/bin/ninja /usr/local/bin/ninja ninja; do
    if command -v "$candidate" >/dev/null 2>&1; then
        # Verify it's a real binary, not the depot_tools wrapper.
        if file "$(command -v "$candidate" 2>/dev/null || echo "$candidate")" 2>/dev/null | grep -q "Mach-O\|ELF"; then
            NINJA_BIN="$candidate"
            break
        fi
    fi
done
if [[ -z "$NINJA_BIN" ]]; then
    # Last resort: autoninja (may print Siso warnings but still works on clean dirs).
    NINJA_BIN="autoninja"
fi
$NINJA_BIN -C "$GN_OUT" libEGL libGLESv2

# ── Stage the frameworks into build/<slice>/ ──────────────────────────────
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

if [[ "$SLICE" == "macos" ]]; then
    # macOS: ANGLE produces bare .dylibs; wrap them into .framework bundles.
    log "Wrapping macOS dylibs into .framework bundles..."
    bash "$SCRIPT_DIR/wrap-macos-framework.sh" "$GN_OUT" "$OUT_DIR"
else
    # iOS: ANGLE produces .framework bundles directly.
    for fw in libEGL.framework libGLESv2.framework; do
        src_fw="$GN_OUT/$fw"
        [[ -d "$src_fw" ]] || die "Expected framework not found: $src_fw"
        cp -R "$src_fw" "$OUT_DIR/"
        log "  staged: $OUT_DIR/$fw"
    done
fi

# Copy in the privacy manifest to each framework.
for fw in "$OUT_DIR"/lib*.framework; do
    if [[ -d "$fw" ]]; then
        cp "$PKG_DIR/config/PrivacyInfo.xcprivacy" "$fw/"
    fi
done

log "Done. Frameworks staged at $OUT_DIR"
ls -la "$OUT_DIR"/lib*.framework 2>/dev/null | head
