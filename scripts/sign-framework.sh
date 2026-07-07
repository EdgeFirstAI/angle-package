#!/usr/bin/env bash
# sign-framework.sh — post-build code signing for one .framework directory.
#
# Usage: bash scripts/sign-framework.sh <framework-dir> <slice>
#   <framework-dir>  — path to the lib*.framework directory to sign.
#   <slice>          — ios-device | ios-sim | macos (controls Hardened Runtime).
#
# Signs the framework with the Au-Zone Developer ID Application identity
# (overridable via ANGLE_SIGNING_IDENTITY). Falls back to ad-hoc signing
# (-s -) with a warning if the cert isn't in the keychain, so contributors
# without the cert can still build.
#
# macOS slices get Hardened Runtime (--options runtime) — required for
# notarization-readiness and for the framework to load in a notarized macOS
# app. iOS slices don't (Hardened Runtime is macOS-only; iOS apps re-sign
# embedded frameworks with the app's own team during "Embed & Sign" anyway).
set -euo pipefail

FW_DIR="${1:?usage: sign-framework.sh <framework-dir> <slice>}"
SLICE="${2:?usage: sign-framework.sh <framework-dir> <slice>}"

BUNDLE_PREFIX="com.edgefirst.anglesdk"

log() { printf '\033[1;34m[sign-framework]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[sign-framework error]\033[0m %s\n' "$*" >&2; exit 1; }

# Derive the framework's executable name from the directory name.
FW_NAME="$(basename "$FW_DIR" .framework)"  # e.g. libEGL
IDENTIFIER="${BUNDLE_PREFIX}.${FW_NAME}"

# Determine the signing identity.
DEFAULT_IDENTITY="Developer ID Application: Au-Zone Technologies Inc. (F39422DDCA)"
IDENTITY="${ANGLE_SIGNING_IDENTITY:-$DEFAULT_IDENTITY}"

# Check whether the requested identity is actually available.
has_identity() {
    security find-identity -p codesigning 2>/dev/null \
        | grep -qF "$IDENTITY"
}

if ! has_identity; then
    if [[ "$IDENTITY" == *"Developer ID"* ]] || [[ "$IDENTITY" == *"Apple"* ]]; then
        # Requested a real cert but it's not in the keychain — fall back to ad-hoc.
        log "WARNING: signing identity '$IDENTITY' not found in keychain."
        log "  Falling back to ad-hoc signing (-s -)."
        log "  The resulting frameworks are unsigned-for-distribution; consumers"
        log "  must re-sign during their app build (Embed & Sign does this)."
        IDENTITY="-"
    fi
fi

# Build the codesign flags.
# macOS slice: Hardened Runtime + secure timestamp (notarization-ready).
# iOS slices:  secure timestamp only.
TIMESTAMP_FLAG=""
if [[ "$IDENTITY" != "-" ]]; then
    TIMESTAMP_FLAG="--timestamp"
fi

if [[ "$SLICE" == "macos" ]]; then
    if [[ "$IDENTITY" != "-" ]]; then
        SIGN_OPTS=(--force --sign "$IDENTITY" $TIMESTAMP_FLAG --options runtime)
    else
        # Ad-hoc on macOS: can't use --timestamp or --options runtime without a real identity.
        SIGN_OPTS=(--force --sign - --options runtime)
    fi
else
    if [[ "$IDENTITY" != "-" ]]; then
        SIGN_OPTS=(--force --sign "$IDENTITY" $TIMESTAMP_FLAG)
    else
        SIGN_OPTS=(--force --sign -)
    fi
fi

log "Signing $FW_NAME ($SLICE) with identity: ${IDENTITY:0:60}..."
log "  identifier: $IDENTIFIER"
log "  flags: ${SIGN_OPTS[*]}"

codesign "${SIGN_OPTS[@]}" \
    --identifier "$IDENTIFIER" \
    "$FW_DIR"

# Verify the signature we just applied.
if ! codesign --verify --strict "$FW_DIR" 2>/dev/null; then
    die "codesign --verify failed for $FW_DIR after signing"
fi
log "  verified OK"
