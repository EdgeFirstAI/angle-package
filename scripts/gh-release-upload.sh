#!/usr/bin/env bash
# gh-release-upload.sh — add assets to a GitHub release, creating it if absent.
#
# Shared by publish-release.sh (Mac: xcframeworks) and the Windows workflow
# (windows.yml: DLL zips) so EITHER side can publish first onto the same tag:
#   1. If the release exists: upload the assets with --clobber and append this
#      side's BUILD_INFO to the notes (once, keyed on its first line).
#   2. Otherwise: create it as a DRAFT with the notes, upload, then undraft —
#      so a half-uploaded release is never visible.
#
# Usage:
#   bash scripts/gh-release-upload.sh <tag> [--title T] [--notes-file F]
#        [--prerelease] [--target SHA] -- <asset>...
#
# Needs `gh` authenticated (GH_TOKEN or `gh auth login`). The repo is taken
# from GH_REPO if set, else from the current git remote.
set -euo pipefail

log() { printf '\033[1;34m[gh-release]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[gh-release error]\033[0m %s\n' "$*" >&2; exit 1; }

TAG="${1:-}"
[[ -n "$TAG" ]] || die "usage: $0 <tag> [--title T] [--notes-file F] [--prerelease] [--target SHA] -- <asset>..."
shift

TITLE=""
NOTES_FILE=""
PRERELEASE=0
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --title)      TITLE="$2"; shift 2 ;;
        --notes-file) NOTES_FILE="$2"; shift 2 ;;
        --prerelease) PRERELEASE=1; shift ;;
        --target)     TARGET="$2"; shift 2 ;;
        --)           shift; break ;;
        *)            die "unknown option: $1" ;;
    esac
done
ASSETS=("$@")
[[ ${#ASSETS[@]} -gt 0 ]] || die "no assets given (put them after --)"
for a in "${ASSETS[@]}"; do [[ -f "$a" ]] || die "asset not found: $a"; done
[[ -z "$NOTES_FILE" || -f "$NOTES_FILE" ]] || die "notes file not found: $NOTES_FILE"

command -v gh >/dev/null 2>&1 || die "gh CLI not installed"
REPO="${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
[[ -n "$REPO" ]] || die "cannot determine the GitHub repo (set GH_REPO=owner/name)"
[[ -n "$TITLE" ]] || TITLE="ANGLE $TAG"

CREATED=0
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    log "release $TAG exists on $REPO — adding assets"
else
    log "creating draft release $TAG on $REPO"
    create_args=(--repo "$REPO" --draft --title "$TITLE")
    [[ -n "$NOTES_FILE" ]] && create_args+=(--notes-file "$NOTES_FILE")
    [[ "$PRERELEASE" -eq 1 ]] && create_args+=(--prerelease)
    [[ -n "$TARGET" ]] && create_args+=(--target "$TARGET")
    if gh release create "$TAG" "${create_args[@]}"; then
        CREATED=1
    else
        # Lost a create race with the other machine: treat as existing.
        gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 || die "failed to create release $TAG"
        log "release $TAG appeared concurrently — adding assets"
    fi
fi

log "uploading: ${ASSETS[*]}"
gh release upload "$TAG" --repo "$REPO" --clobber "${ASSETS[@]}"

# Append this side's notes to an existing release, once.
if [[ "$CREATED" -eq 0 && -n "$NOTES_FILE" ]]; then
    marker="$(head -1 "$NOTES_FILE")"
    body="$(gh release view "$TAG" --repo "$REPO" --json body -q .body)"
    if ! grep -qF -- "$marker" <<<"$body"; then
        tmp="$(mktemp)"
        printf '%s\n\n%s\n' "$body" "$(cat "$NOTES_FILE")" > "$tmp"
        gh release edit "$TAG" --repo "$REPO" --notes-file "$tmp"
        rm -f "$tmp"
        log "appended notes from $NOTES_FILE"
    fi
fi

if [[ "$CREATED" -eq 1 ]]; then
    gh release edit "$TAG" --repo "$REPO" --draft=false
    log "published $TAG"
fi
log "https://github.com/$REPO/releases/tag/$TAG"
