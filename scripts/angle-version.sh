#!/usr/bin/env bash
# angle-version.sh — single source of truth for the ANGLE pin (config/angle.lock).
#
# The Mac (Apple slices) and the Windows workflow build on different machines;
# the lock file is how both build the SAME ANGLE commit, so one release tag
# v2.1.<ANGLE_COMMIT_POSITION> names one source revision.
#
# Usage:
#   bash scripts/angle-version.sh [print]   # KEY=VALUE lines, values validated
#                                           # and shell-quoted (safe to eval)
#   bash scripts/angle-version.sh version   # v2.1.<ANGLE_COMMIT_POSITION>
#   bash scripts/angle-version.sh check     # assert $ANGLE_SRC is at the pinned
#                                           # commit AND rev-list --count matches
#   bash scripts/angle-version.sh write     # derive from $ANGLE_SRC and rewrite
#                                           # config/angle.lock (`make pin`)
#
# Environment:
#   ANGLE_SRC   ANGLE checkout (default: ../angle next to this package).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK="$PKG_DIR/config/angle.lock"
ANGLE_SRC="${ANGLE_SRC:-$PKG_DIR/../angle}"

die() { printf '\033[1;31m[angle-version error]\033[0m %s\n' "$*" >&2; exit 1; }

# Bind the lock's ANGLE_* keys as shell variables in this process. No `eval`:
# each line is matched structurally, the value is restricted to the charset
# a sha / integer / ISO date / branch name needs, and the assignment goes
# through `printf -v`, so a hostile edit to config/angle.lock cannot run
# commands here or in the callers that eval `print`'s (%q-quoted) output.
LOCK_KEYS=()
load_lock() {
    [[ -f "$LOCK" ]] || die "missing $LOCK (run 'make pin' on a machine with an ANGLE checkout)"
    local line key value
    LOCK_KEYS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        # A checkout with core.autocrlf=true (Git for Windows' default, so
        # the GitHub Windows runners) hands us CRLF lines; .gitattributes
        # pins the lock to LF, this is the belt to those braces.
        line="${line%$'\r'}"
        [[ "$line" =~ ^(ANGLE_[A-Z_]+)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        [[ "$value" =~ ^[A-Za-z0-9._:+/-]*$ ]] || \
            die "refusing $key in $LOCK: value must only use [A-Za-z0-9._:+/-] (got: $value)"
        printf -v "$key" '%s' "$value"
        LOCK_KEYS+=("$key")
    done < "$LOCK"
    [[ -n "${ANGLE_COMMIT:-}" && -n "${ANGLE_COMMIT_POSITION:-}" ]] || \
        die "$LOCK lacks ANGLE_COMMIT / ANGLE_COMMIT_POSITION (run 'make pin')"
}

# KEY=VALUE lines with shell-quoted values; safe for callers to `eval`.
print_lock() {
    local key
    for key in "${LOCK_KEYS[@]}"; do
        printf '%s=%q\n' "$key" "${!key}"
    done
}

derive() {
    [[ -d "$ANGLE_SRC/.git" ]] || die "no ANGLE checkout at $ANGLE_SRC (set ANGLE_SRC)"
    [[ "$(git -C "$ANGLE_SRC" rev-parse --is-shallow-repository)" == "false" ]] || \
        die "ANGLE checkout at $ANGLE_SRC is shallow; the commit position (rev-list --count) would be wrong"
    echo "ANGLE_COMMIT=$(git -C "$ANGLE_SRC" rev-parse HEAD)"
    echo "ANGLE_COMMIT_POSITION=$(git -C "$ANGLE_SRC" rev-list HEAD --count)"
    echo "ANGLE_COMMIT_DATE=$(git -C "$ANGLE_SRC" log -1 --format=%cI)"
    local branch
    branch="$(git -C "$ANGLE_SRC" branch --show-current 2>/dev/null || true)"
    echo "ANGLE_BRANCH=${branch:-detached}"
}

case "${1:-print}" in
    print)
        load_lock
        print_lock
        ;;
    version)
        load_lock
        echo "v2.1.${ANGLE_COMMIT_POSITION}"
        ;;
    check)
        load_lock
        [[ -d "$ANGLE_SRC/.git" ]] || die "no ANGLE checkout at $ANGLE_SRC (set ANGLE_SRC)"
        head_sha="$(git -C "$ANGLE_SRC" rev-parse HEAD)"
        [[ "$head_sha" == "$ANGLE_COMMIT" ]] || \
            die "ANGLE checkout is at $head_sha, pin is $ANGLE_COMMIT. Run 'git -C $ANGLE_SRC checkout --detach $ANGLE_COMMIT' (then 'gclient sync'), or 'make pin' to move the pin."
        pos="$(git -C "$ANGLE_SRC" rev-list HEAD --count)"
        [[ "$pos" == "$ANGLE_COMMIT_POSITION" ]] || \
            die "commit position $pos != pinned $ANGLE_COMMIT_POSITION (shallow clone? run 'git fetch --unshallow')"
        echo "angle-version: $ANGLE_SRC is at pinned $ANGLE_COMMIT (position $ANGLE_COMMIT_POSITION)"
        ;;
    write)
        {
            cat <<'EOF'
# Pinned ANGLE revision — the single source of truth for what every slice
# builds. The Mac (`make all`) and the Windows workflow
# (.github/workflows/windows.yml) both build exactly this commit, so the
# release tag v2.1.<ANGLE_COMMIT_POSITION> names the same source everywhere.
#
# Update with `make pin` after checking out the desired commit in ../angle
# (a full-history checkout: ANGLE_COMMIT_POSITION is `git rev-list HEAD
# --count`, which is what the built binary reports in GL_VERSION).
# Read/validate with scripts/angle-version.sh.
EOF
            derive
        } > "$LOCK.tmp"
        mv "$LOCK.tmp" "$LOCK"
        cat "$LOCK"
        ;;
    *)
        die "usage: $0 [print|version|check|write]"
        ;;
esac
