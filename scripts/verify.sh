#!/usr/bin/env bash
# verify.sh — validate the produced xcframeworks in dist/.
#
# Checks:
#   1. codesign --verify --deep --strict on each framework slice.
#   2. codesign -dvvv to confirm the signing identity + team.
#   3. CFBundleIdentifier starts with com.edgefirst.anglesdk (not org.chromium.ost).
#   4. PrivacyInfo.xcprivacy exists in each slice.
#   5. spctl assess on the macOS slice (Gatekeeper).
#   6. dlopen the macOS slice binary (catches install-name / Hardened Runtime issues).
#
# Usage: bash scripts/verify.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PKG_DIR/dist"

log() { printf '\033[1;34m[verify]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[verify WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[verify FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

FAILURES=0
record_fail() { warn "FAIL: $*"; FAILURES=$((FAILURES + 1)); }

for xcf in EGL.xcframework GLESv2.xcframework; do
    XCF_DIR="$DIST_DIR/$xcf"
    [[ -d "$XCF_DIR" ]] || { record_fail "$XCF_DIR not found"; continue; }

    log "=== Verifying $xcf ==="

    # Each xcframework has per-platform subdirectories containing the .framework.
    for fw in "$XCF_DIR"/*/lib*.framework; do
        [[ -d "$fw" ]] || continue
        slice_dir="$(dirname "$fw")"
        slice_name="$(basename "$slice_dir")"
        fw_name="$(basename "$fw")"

        log "  [$slice_name] $fw_name"

        # 1. Signature verification.
        if codesign --verify --deep --strict "$fw" 2>/dev/null; then
            log "    codesign --verify: OK"
        else
            record_fail "[$slice_name/$fw_name] codesign --verify failed"
            codesign --verify --deep --strict "$fw" 2>&1 | sed 's/^/      /' >&2
        fi

        # 2. Signing identity details.
        local_sign_info=$(codesign -dvvv "$fw" 2>&1 || true)
        if echo "$local_sign_info" | grep -q "Authority=Developer ID"; then
            log "    signing identity: Developer ID (real cert)"
        elif echo "$local_sign_info" | grep -q "flags=0x2(adhoc)"; then
            warn "    signing identity: ad-hoc (no real cert)"
        else
            record_fail "[$slice_name/$fw_name] unexpected signing state"
        fi

        # 3. Bundle ID check.
        plist="$fw/Info.plist"
        if [[ -f "$plist" ]]; then
            bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || echo "")
            if [[ "$bundle_id" == com.edgefirst.anglesdk.* ]]; then
                log "    bundle ID: $bundle_id (correct)"
            elif [[ "$bundle_id" == org.chromium.ost.* ]]; then
                record_fail "[$slice_name/$fw_name] bundle ID is upstream Chromium ($bundle_id) — gn arg not applied"
            else
                warn "    bundle ID: $bundle_id (unexpected prefix)"
            fi
        fi

        # 4. Privacy manifest.
        if [[ -f "$fw/PrivacyInfo.xcprivacy" ]]; then
            log "    PrivacyInfo.xcprivacy: present"
        else
            record_fail "[$slice_name/$fw_name] missing PrivacyInfo.xcprivacy"
        fi

        # 5. spctl assess (macOS slice only — Gatekeeper).
        # After notarization, spctl assess passes (the ticket is verified).
        # Before notarization, it fails — expected, not a hard failure.
        if [[ "$slice_name" == macos* ]]; then
            # Find the binary inside the framework.
            fw_binary="$fw/$(basename "$fw" .framework)"
            if [[ -f "$fw_binary" ]]; then
                if spctl assess --type execute "$fw_binary" 2>/dev/null; then
                    log "    spctl assess: OK (notarized)"
                else
                    # Check if notarization was attempted (BUILD_INFO has Notarized line).
                    if grep -q "^Notarized:" "$DIST_DIR/BUILD_INFO.txt" 2>/dev/null; then
                        record_fail "[$slice_name/$fw_name] spctl assess failed despite notarization record in BUILD_INFO.txt"
                    else
                        warn "    spctl assess: rejected (not notarized yet; run 'make notarize' to enable)"
                    fi
                fi
            fi
        fi
    done
done

# 6. dlopen the macOS framework binary (catches install-name / Hardened Runtime issues).
log "=== dlopen check (macOS slice) ==="
MACOS_BIN="$DIST_DIR/EGL.xcframework/macos-arm64/libEGL.framework/libEGL"
if [[ -f "$MACOS_BIN" ]]; then
    # Use a tiny C program to dlopen; avoids depending on python ctypes.
    cat > /tmp/angle_dlopen_test.c <<'CEOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <path>\n", argv[0]); return 2; }
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1; }
    printf("dlopen OK\n");
    dlclose(h);
    return 0;
}
CEOF
    if cc -o /tmp/angle_dlopen_test /tmp/angle_dlopen_test.c 2>/dev/null; then
        if /tmp/angle_dlopen_test "$MACOS_BIN"; then
            log "  dlopen $MACOS_BIN: OK"
        else
            record_fail "dlopen of macOS EGL framework failed (install-name or Hardened Runtime issue)"
        fi
        rm -f /tmp/angle_dlopen_test /tmp/angle_dlopen_test.c
    else
        warn "  cc not available; skipping dlopen test"
    fi
else
    warn "  macOS EGL binary not found at $MACOS_BIN; skipping dlopen test"
fi

# Summary.
echo
if [[ "$FAILURES" -eq 0 ]]; then
    log "✅ All checks passed."
else
    die "❌ $FAILURES check(s) failed. See warnings above."
fi
