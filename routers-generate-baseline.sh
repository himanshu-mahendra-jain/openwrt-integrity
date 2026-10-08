#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/routers-common.sh"

# ------------------------------------------------------------
# Arguments
# ------------------------------------------------------------
usage() {
    echo "Usage: $0 [--force] [baseline-directory]"
    echo
    echo "  --force  Replace an existing baseline. The old baseline"
    echo "           is kept as <baseline-directory>.bak-<timestamp>."
    exit 1
}

FORCE=0
BASELINE="./known-good"

while (( $# > 0 )); do
    case "$1" in
        --force) FORCE=1 ;;
        -*) usage ;;
        *) BASELINE="$1" ;;
    esac
    shift
done

BASELINE="${BASELINE%/}"
[[ -n "$BASELINE" ]] || usage

# ------------------------------------------------------------
# Functions
# ------------------------------------------------------------
error() {
    echo
    echo "ERROR: $*"
    echo
    exit 1
}

WORK=""

cleanup() {
    stop_ssh_agent

    if [[ -n "$WORK" ]]; then
        rm -rf -- "$WORK"
    fi
}

trap cleanup EXIT

collect() {
    local ROUTER="$1"
    local CMD="$2"
    local OUT="$3"
    local LABEL="$4"

    ssh "${SSH_OPTS[@]}" "$ROUTER" "$CMD" > "$OUT" ||
        error "Could not collect $LABEL from $ROUTER."

    if grep -q '^ERROR  ' "$OUT"; then
        grep '^ERROR  ' "$OUT"
        error "Could not fully collect $LABEL from $ROUTER."
    fi
}

generate_baseline() {
    local ROUTER="$1"
    local NAME="$2"
    local DIR="$WORK/$NAME"

    mkdir -p "$DIR"

    echo
    echo "========================================"
    echo " Router:   $ROUTER"
    echo " Baseline: $BASELINE/$NAME"
    echo "========================================"
    echo

    echo "[1/7] System information"
    collect "$ROUTER" "$REMOTE_SYSTEM" "$DIR/system.txt" "system information"

    echo "[2/7] Critical file hashes"
    collect "$ROUTER" "$REMOTE_FILES" "$DIR/files.sha256" "file hashes"

    [[ -s "$DIR/files.sha256" ]] ||
        error "No file hashes were generated for $ROUTER."

    echo "[3/7] Installed packages"
    collect "$ROUTER" "$REMOTE_PACKAGES" "$DIR/packages.txt" "package list"

    [[ -s "$DIR/packages.txt" ]] ||
        error "Could not obtain package list from $ROUTER."

    echo "[4/7] UID 0 accounts"
    collect "$ROUTER" "$REMOTE_UID0" "$DIR/uid0.txt" "UID 0 accounts"

    [[ -s "$DIR/uid0.txt" ]] ||
        error "Could not obtain UID 0 accounts from $ROUTER."

    echo "[5/7] SSH authorized keys"
    collect "$ROUTER" "$REMOTE_KEYS" "$DIR/authorized_keys" "SSH authorized keys"

    echo "[6/7] Overlay changes"
    collect "$ROUTER" "$REMOTE_OVERLAY" "$DIR/overlay.sha256" "overlay changes"

    echo "[7/7] Cron configuration"
    collect "$ROUTER" "$REMOTE_CRON" "$DIR/crontabs.txt" "cron configuration"

    echo
    echo "✓ $NAME baseline complete"
    echo
    echo "Files:"
    ls -lh "$DIR"
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
echo "========================================"
echo " OpenWrt Multi-Router Baseline"
echo "========================================"
echo
echo "Baseline directory: $BASELINE"

if [[ -e "$BASELINE" ]] && (( ! FORCE )); then
    error "Baseline already exists: $BASELINE
Use --force to replace it. The old baseline will be kept as a backup."
fi

start_ssh_agent

# Build the new baseline in a temporary directory so a failure
# never leaves a partial or overwritten baseline behind.
mkdir -p "$(dirname "$BASELINE")"
WORK="$(mktemp -d "$BASELINE.new.XXXXXX")"

for ROUTER in "${ROUTERS[@]}"; do
    generate_baseline "$ROUTER" "$(router_name "$ROUTER")"
done

if [[ -e "$BASELINE" ]]; then
    BACKUP="$BASELINE.bak-$(date +%Y%m%d-%H%M%S)"
    mv -- "$BASELINE" "$BACKUP"
    echo
    echo "Previous baseline moved to: $BACKUP"
fi

mv -- "$WORK" "$BASELINE"
WORK=""

echo
echo "========================================"
echo " All baselines generated"
echo "========================================"
echo

find "$BASELINE" -maxdepth 2 -type f -print | sort

echo
echo "IMPORTANT:"
echo "Only generate these baselines when the routers"
echo "are known to be clean."
echo
