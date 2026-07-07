#!/usr/bin/env bash
# publish-release.sh — package dist/ and publish to GitHub Releases.
#
# Creates a versioned GitHub release with the signed+notarized xcframeworks
# as downloadable assets. Team members consume the release via the download
# URLs (or a SwiftPM binary target pointing at the zip).
#
# Prerequisites:
#   - dist/ exists and is signed + notarized (run `make all && make notarize`).
#   - gh CLI is authenticated (gh auth login).
#   - The git repo has a GitHub remote (the script creates one if missing).
#
# Usage:
#   bash scripts/publish-release.sh <version>     # e.g. v0.1.0
#   bash scripts/publish-release.sh v0.1.0 --prerelease
#
# What this does:
#   1. Creates a versioned zip of dist/ (angle-xcframeworks-<version>.zip).
#   2. Computes a SHA256 checksum.
#   3. Ensures the GitHub repo exists (creates it if missing).
#   4. Creates a git tag <version> and pushes it.
#   5. Creates a GitHub release with the zip + checksum as assets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PKG_DIR/dist"

VERSION="${1:?usage: publish-release.sh <version> [--prerelease]}"
shift || true
PRERELEASE=0
[[ "${1:-}" == "--prerelease" ]] && PRERELEASE=1

log() { printf '\033[1;34m[publish]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[publish error]\033[0m %s\n' "$*" >&2; exit 1; }

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
