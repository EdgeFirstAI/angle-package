#!/usr/bin/env bash
# notarize.sh — submit the built xcframeworks to Apple's notarization service
# and staple the resulting ticket to the macOS framework binaries.
#
# Prerequisites:
#   - dist/ must exist (run `make all` first).
#   - A notarytool keychain profile named "angle-package" must be stored:
#       xcrun notarytool store-credentials "angle-package" \
#           --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUERID>
#     (Override the profile name with NOTARY_PROFILE env var.)
#
# What this does:
#   1. ditto-zips dist/ into a single submission zip.
#   2. Submits to Apple via `notarytool submit --wait` (blocks 2–5 min).
#   3. Staples the notarization ticket to each macOS framework binary
#      (`stapler staple` only works on .app/.dmg/.pkg — for bare frameworks
#      the ticket is stored in the notarization service and verified online;
#      we staple what we can and document the limitation).
#   4. Prints the notarization log on failure.
#
# Usage: bash scripts/notarize.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PKG_DIR/dist"

NOTARY_PROFILE="${NOTARY_PROFILE:-angle-package}"
SUBMISSION_ZIP="$PKG_DIR/build/notarization-submission.zip"

log() { printf '\033[1;34m[notarize]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[notarize error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -d "$DIST_DIR/EGL.xcframework" ]] || die "dist/ not found — run 'make all' first."

# Verify the keychain profile exists.
log "Checking notarytool keychain profile '$NOTARY_PROFILE'..."
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    die "notarytool profile '$NOTARY_PROFILE' not found or invalid. \
Store it with: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --key <AuthKey.p8> --key-id <KEYID> --issuer <ISSUERID>"
fi
log "  profile OK"

# ── 1. Create the submission zip ──────────────────────────────────────────
log "Creating submission zip..."
mkdir -p "$(dirname "$SUBMISSION_ZIP")"
rm -f "$SUBMISSION_ZIP"
# ditto preserves the directory structure + extended attributes (code signatures).
( cd "$PKG_DIR" && ditto -c -k --keepParent dist "$SUBMISSION_ZIP" )
log "  → $SUBMISSION_ZIP ($(du -h "$SUBMISSION_ZIP" | cut -f1))"

# ── 2. Submit to Apple ────────────────────────────────────────────────────
log "Submitting to Apple notarization service (this blocks ~2–5 min)..."
SUBMIT_OUTPUT=$(xcrun notarytool submit "$SUBMISSION_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || {
    # On failure, fetch and print the detailed log.
    SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | grep -oE 'id: [a-f0-9-]+' | head -1 | awk '{print $2}')
    if [[ -n "$SUBMISSION_ID" ]]; then
        log "Fetching detailed notarization log for submission $SUBMISSION_ID..."
        xcrun notarytool log "$SUBMISSION_ID" \
            --keychain-profile "$NOTARY_PROFILE" 2>&1 | tail -50
    fi
    die "notarization failed. See log above."
}

# Extract the submission ID and status.
SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | grep -oE 'id: [a-f0-9-]+' | head -1 | awk '{print $2}')
STATUS=$(echo "$SUBMIT_OUTPUT" | grep -oE 'status: [A-Za-z]+' | tail -1 | awk '{print $2}')

log "Notarization $SUBMISSION_ID: $STATUS"

if [[ "$STATUS" != "Accepted" ]]; then
    log "Fetching detailed notarization log..."
    xcrun notarytool log "$SUBMISSION_ID" \
        --keychain-profile "$NOTARY_PROFILE" 2>&1 | tail -50
    die "notarization was not accepted (status: $STATUS). See log above."
fi

# ── 3. Staple the ticket to macOS framework binaries ──────────────────────
# NOTE: `stapler staple` officially supports .app, .dmg, and .pkg. For bare
# .framework bundles it returns an error. The notarization ticket is still
# registered with Apple and verified online at runtime — stapling is an
# offline-verification optimization. We attempt it and document the limitation.
log "Stapling notarization tickets to macOS framework binaries..."
for xcf in EGL.xcframework GLESv2.xcframework; do
    for fw in "$DIST_DIR/$xcf"/macos-*/lib*.framework; do
        [[ -d "$fw" ]] || continue
        fw_binary="$fw/$(basename "$fw" .framework)"
        if [[ -f "$fw_binary" ]]; then
            # Try to staple. This may fail for bare frameworks (expected —
            # stapling is for .app/.dmg/.pkg). The ticket is still valid online.
            if xcrun stapler staple "$fw_binary" 2>/dev/null; then
                log "  stapled: $(basename "$fw_binary")"
            else
                log "  staple skipped (bare framework — ticket verified online at runtime): $(basename "$fw_binary")"
            fi
        fi
    done
done

# ── 4. Verify notarization ────────────────────────────────────────────────
log "Verifying notarization via spctl..."
MACOS_BIN="$DIST_DIR/EGL.xcframework/macos-arm64/libEGL.framework/libEGL"
if [[ -f "$MACOS_BIN" ]]; then
    # spctl assess checks the notarization ticket. Without stapling this
    # requires network access; with stapling it works offline.
    if spctl assess --type execute "$MACOS_BIN" 2>/dev/null; then
        log "  spctl assess: ✅ notarization verified"
    else
        log "  spctl assess: ⚠️ ticket not found locally (bare frameworks can't be stapled)"
        log "    The notarization is registered with Apple; consumers' apps pick it up"
        log "    when the whole .app bundle is notarized together."
    fi
fi

# Record the submission ID in BUILD_INFO.txt.
if [[ -f "$DIST_DIR/BUILD_INFO.txt" ]]; then
    echo "Notarized:    $SUBMISSION_ID ($STATUS)" >> "$DIST_DIR/BUILD_INFO.txt"
fi

log "✅ Notarization complete: $SUBMISSION_ID"
