#!/usr/bin/env bash
# wrap-macos-framework.sh — wrap ANGLE's bare macOS .dylibs into .framework
# bundles that xcodebuild -create-xcframework can consume.
#
# ANGLE's `angle_shared_library` GN template only switches to
# `ios_framework_bundle` when `is_ios`. On macOS it produces plain `.dylib`
# files. This script wraps each dylib into the `.framework` directory
# structure (binary + Info.plist) so the macOS slice has the same shape as
# the iOS slices.
#
# Usage: bash scripts/wrap-macos-framework.sh <dylib-source-dir> <output-dir>
#   <dylib-source-dir>  — the gn/ninja output dir containing libEGL.dylib etc.
#   <output-dir>        — where to create libEGL.framework / libGLESv2.framework
set -euo pipefail

DYLIB_DIR="${1:?usage: wrap-macos-framework.sh <dylib-source-dir> <output-dir>}"
OUT_DIR="${2:?usage: wrap-macos-framework.sh <dylib-source-dir> <output-dir>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BUNDLE_PREFIX="com.edgefirst.anglesdk"

log() { printf '\033[1;34m[wrap-macos]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[wrap-macos error]\033[0m %s\n' "$*" >&2; exit 1; }

# Generate a minimal Info.plist for a macOS framework.
# Writes to stdout; caller redirects to the plist file.
generate_info_plist() {
    local bundle_id="$1" exec_name="$2"
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>English</string>
	<key>CFBundleExecutable</key>
	<string>${exec_name}</string>
	<key>CFBundleIdentifier</key>
	<string>${bundle_id}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${exec_name}</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF
}

wrap_one() {
    local dylib_name="$1"  # e.g. libEGL.dylib
    local exec_name="${dylib_name%.dylib}"  # e.g. libEGL

    local src="$DYLIB_DIR/$dylib_name"
    [[ -f "$src" ]] || die "dylib not found: $src"

    local fw_dir="$OUT_DIR/$exec_name.framework"
    rm -rf "$fw_dir"
    mkdir -p "$fw_dir"

    # Copy the dylib as the framework binary.
    cp "$src" "$fw_dir/$exec_name"
    chmod +x "$fw_dir/$exec_name"

    # Fix the install name so consumers find it via @rpath after embedding.
    # ANGLE's default install name is just the basename (e.g. "libEGL.dylib");
    # we rewrite it to the framework path so @rpath lookup works.
    install_name_tool -id "@rpath/${exec_name}.framework/${exec_name}" \
        "$fw_dir/$exec_name"

    # Generate the Info.plist.
    generate_info_plist "${BUNDLE_PREFIX}.${exec_name}" "$exec_name" > "$fw_dir/Info.plist"

    # Copy in the privacy manifest (sign-framework.sh will cover it in the sig).
    cp "$PKG_DIR/config/PrivacyInfo.xcprivacy" "$fw_dir/" 2>/dev/null || true

    # Set the right architectures / file type on the binary (validate).
    local archs
    archs=$(lipo -archs "$fw_dir/$exec_name" 2>/dev/null || echo "unknown")
    log "  wrapped $exec_name.framework (arch: $archs, install-name: @rpath/${exec_name}.framework/${exec_name})"
}

log "Wrapping macOS dylibs from $DYLIB_DIR → $OUT_DIR"
wrap_one "libEGL.dylib"
wrap_one "libGLESv2.dylib"
log "Done."
