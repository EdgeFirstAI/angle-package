#!/usr/bin/env bash
# assemble-xcframework.sh — sign the built slices and assemble the final
# EGL.xcframework and GLESv2.xcframework in dist/.
#
# Prerequisite: build-slice.sh has been run for ios-device, ios-sim, and macos
# (i.e. build/<slice>/libEGL.framework + libGLESv2.framework exist).
#
# Usage: bash scripts/assemble-xcframework.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_DIR="$PKG_DIR/build"
DIST_DIR="$PKG_DIR/dist"

log() { printf '\033[1;34m[assemble]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[assemble error]\033[0m %s\n' "$*" >&2; exit 1; }

SLICES=("ios-device" "ios-sim" "macos")

# Verify all slices are built.
for slice in "${SLICES[@]}"; do
    for fw in libEGL.framework libGLESv2.framework; do
        [[ -d "$BUILD_DIR/$slice/$fw" ]] || \
            die "Missing $BUILD_DIR/$slice/$fw — run 'make $slice' (or build-slice.sh $slice) first."
    done
done

# Sign each slice's frameworks.
for slice in "${SLICES[@]}"; do
    for fw in libEGL.framework libGLESv2.framework; do
        bash "$SCRIPT_DIR/sign-framework.sh" "$BUILD_DIR/$slice/$fw" "$slice"
    done
done

# Assemble the xcframeworks.
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

assemble_one() {
    local fw_name="$1"  # libEGL or libGLESv2
    local xcf_name="$2" # EGL or GLESv2
    local out_xcf="$DIST_DIR/${xcf_name}.xcframework"

    log "Assembling $xcf_name.xcframework..."
    xcodebuild -create-xcframework \
        -framework "$BUILD_DIR/ios-device/${fw_name}.framework" \
        -framework "$BUILD_DIR/ios-sim/${fw_name}.framework" \
        -framework "$BUILD_DIR/macos/${fw_name}.framework" \
        -output "$out_xcf"
    log "  → $out_xcf"
}

assemble_one "libEGL" "EGL"
assemble_one "libGLESv2" "GLESv2"

# Write BUILD_INFO.txt for traceability.
# ANGLE doesn't tag releases; its version is the commit position
# (git rev-list HEAD --count = ANGLE_COMMIT_POSITION in the built binary's
# GL_VERSION string, e.g. "ANGLE 2.1.28252"). We capture it here so the
# release version can default to it (see publish-release.sh).
ANGLE_SRC="${ANGLE_SRC:-$PKG_DIR/../angle}"
ANGLE_REV=$(cd "$ANGLE_SRC" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
ANGLE_COMMIT_POS=$(cd "$ANGLE_SRC" && git rev-list HEAD --count 2>/dev/null || echo "unknown")
ANGLE_BRANCH=$(cd "$ANGLE_SRC" && git branch --show-current 2>/dev/null || echo "unknown")
ANGLE_COMMIT_DATE=$(cd "$ANGLE_SRC" && git log -1 --format=%ci 2>/dev/null || echo "unknown")

SIGN_INFO=$(security find-identity -p codesigning 2>/dev/null \
    | grep -oE '"Developer ID Application: Au-Zone Technologies Inc[^"]*"' \
    | head -1 || echo "ad-hoc")

cat > "$DIST_DIR/BUILD_INFO.txt" <<EOF
ANGLE xcframework build
=======================
Built:              $(date -u +%Y-%m-%dT%H:%M:%SZ)
ANGLE source:       $ANGLE_SRC
ANGLE commit:       $ANGLE_REV (position $ANGLE_COMMIT_POS)
ANGLE commit date:  $ANGLE_COMMIT_DATE
ANGLE branch:       $ANGLE_BRANCH
GL_VERSION string:  OpenGL ES 3.0 (ANGLE 2.1.$ANGLE_COMMIT_POS ...)
Build host:         $(hostname -s) ($(uname -m))
Slices:             ios-arm64, ios-arm64-simulator, macos-arm64
Signing:            ${SIGN_INFO:-ad-hoc}
EOF

log "Wrote $DIST_DIR/BUILD_INFO.txt"
log "Done. xcframeworks at $DIST_DIR"
