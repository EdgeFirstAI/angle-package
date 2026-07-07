#!/usr/bin/env bash
# publish-release.sh — package dist/ and publish to GitHub Releases.
#
# Creates a versioned GitHub release with the signed+notarized xcframeworks
# as downloadable assets. Team members consume the release via the download
# URLs (or a SwiftPM binary target pointing at the zip).
#
# Versioning follows ANGLE's own scheme: v2.1.<commit-position> (e.g.
# v2.1.28252). The commit position is ANGLE_COMMIT_POSITION = git rev-list
# HEAD --count, which appears in the GL_VERSION string as "ANGLE 2.1.28252".
# Add -N suffix for packaging revisions within the same ANGLE commit
# (e.g. v2.1.28252-1 for a signing/notarization fix on the same ANGLE build).
#
# Prerequisites:
#   - dist/ exists and is signed + notarized (run `make all && make notarize`).
#   - gh CLI is authenticated (gh auth login).
#
# Usage:
#   bash scripts/publish-release.sh                  # auto: v2.1.<position>
#   bash scripts/publish-release.sh v2.1.28252       # explicit
#   bash scripts/publish-release.sh v2.1.28252-1     # packaging revision
#   bash scripts/publish-release.sh v2.1.28252 --prerelease
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PKG_DIR/dist"

# Define log/die BEFORE any code that calls them (previous version had them
# after the version-detection block, which shadowed the system `log` command).
log() { printf '\033[1;34m[publish]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[publish error]\033[0m %s\n' "$*" >&2; exit 1; }

VERSION="${1:-}"
shift || true
PRERELEASE=0
[[ "${1:-}" == "--prerelease" ]] && PRERELEASE=1

# If no version given, derive from ANGLE's commit position: v2.1.<position>.
# ANGLE doesn't tag releases; its version is ANGLE_COMMIT_POSITION
# (git rev-list HEAD --count), rendered in GL_VERSION as "ANGLE 2.1.<pos>".
# The "2.1" is a legacy OpenGL ES conformance prefix that never changes.
if [[ -z "$VERSION" ]]; then
    ANGLE_SRC="${ANGLE_SRC:-$PKG_DIR/../angle}"
    COMMIT_POS=$(cd "$ANGLE_SRC" && git rev-list HEAD --count 2>/dev/null)
    if [[ -n "$COMMIT_POS" ]]; then
        VERSION="v2.1.${COMMIT_POS}"
        log "No version specified; derived from ANGLE commit position: $VERSION"
    else
        die "No version specified and couldn't determine ANGLE commit position. \
Usage: publish-release.sh <version> (e.g. v2.1.28252)"
    fi
fi

[[ -d "$DIST_DIR/EGL.xcframework" ]] || die "dist/ not found — run 'make all' first."
command -v gh >/dev/null 2>&1 || die "gh CLI not installed (brew install gh)."
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run 'gh auth login')."

# ── 1. Create the release zip ─────────────────────────────────────────────
RELEASE_ZIP="$PKG_DIR/build/angle-xcframeworks-${VERSION}.zip"
CHECKSUM_FILE="$PKG_DIR/build/angle-xcframeworks-${VERSION}.zip.sha256"
mkdir -p "$(dirname "$RELEASE_ZIP")"
rm -f "$RELEASE_ZIP" "$CHECKSUM_FILE"

log "Creating release zip: angle-xcframeworks-${VERSION}.zip..."
# ditto preserves directory structure + extended attributes (code signatures).
( cd "$PKG_DIR" && ditto -c -k --keepParent dist "$RELEASE_ZIP" )
log "  → $(du -h "$RELEASE_ZIP" | cut -f1)"

# ── 2. Checksum ───────────────────────────────────────────────────────────
log "Computing SHA256..."
shasum -a 256 "$RELEASE_ZIP" | awk '{print $1}' > "$CHECKSUM_FILE"
log "  → $(cat "$CHECKSUM_FILE")"

# ── 3. Ensure the GitHub repo exists ──────────────────────────────────────
# Determine the repo name from the git remote, or default to angle-package.
REPO_SLUG=$(cd "$PKG_DIR" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
if [[ -z "$REPO_SLUG" ]]; then
    # No remote yet — create a private GitHub repo.
    REPO_NAME="angle-package"
    log "Creating private GitHub repo '$REPO_NAME'..."
    gh repo create "$REPO_NAME" --private --confirm 2>&1 | tee /tmp/gh-create.log
    REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
    [[ -n "$REPO_SLUG" ]] || die "Failed to create GitHub repo. See /tmp/gh-create.log"
    log "  → $REPO_SLUG"
fi

# ── 4. Git tag ────────────────────────────────────────────────────────────
# Ensure we're on a clean working tree (the release zip is gitignored).
cd "$PKG_DIR"
if git diff --quiet && git diff --cached --quiet; then
    log "Working tree clean."
else
    log "Working tree has uncommitted changes — committing..."
    git add -A
    git commit -m "Release $VERSION" || true
fi

log "Creating git tag $VERSION..."
if git rev-parse "$VERSION" >/dev/null 2>&1; then
    log "  tag $VERSION already exists — skipping creation."
else
    git tag -m "Release $VERSION" "$VERSION"
fi

log "Pushing to GitHub..."
git push --quiet origin HEAD "$VERSION" 2>/dev/null || \
    git push --quiet origin "$VERSION" 2>/dev/null || \
    log "  push failed (may need 'git push -u origin main' first)"

# ── 5. Create the GitHub release ──────────────────────────────────────────
log "Creating GitHub release $VERSION..."
RELEASE_TITLE="ANGLE xcframeworks $VERSION"
RELEASE_NOTES=$(cat "$DIST_DIR/BUILD_INFO.txt" 2>/dev/null || echo "Signed + notarized ANGLE xcframeworks.")

GH_ARGS=(--title "$RELEASE_TITLE" --notes "$RELEASE_NOTES")
[[ "$PRERELEASE" -eq 1 ]] && GH_ARGS+=(--prerelease)

gh release create "$VERSION" \
    "${GH_ARGS[@]}" \
    "$RELEASE_ZIP" "$CHECKSUM_FILE" \
    --repo "$REPO_SLUG"

log ""
log "✅ Published: $VERSION"
log "   Release:  https://github.com/$REPO_SLUG/releases/tag/$VERSION"
log "   Asset:    angle-xcframeworks-${VERSION}.zip ($(du -h "$RELEASE_ZIP" | cut -f1))"
log "   Checksum: $(cat "$CHECKSUM_FILE")"
