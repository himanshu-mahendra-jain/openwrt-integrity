#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/routers-common.sh"

# ------------------------------------------------------------
# Arguments
# ------------------------------------------------------------
usage() {
    echo "Usage: $0 [baseline-directory]"
    echo
    echo "Verifies every router in routers.conf against its baseline"
    echo "(default: ./known-good)."
    exit 1
}

BASELINE="./known-good"

case "${1:-}" in
    -*) usage ;;
    ?*) BASELINE="$1" ;;
esac

(( $# <= 1 )) || usage

BASELINE="${BASELINE%/}"

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_WARN=0

# ------------------------------------------------------------
# Functions
# ------------------------------------------------------------
pass() {
    echo "✓ PASS: $*"
    TOTAL_PASS=$((TOTAL_PASS + 1))
}

fail() {
    echo "✗ FAIL: $*"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
}

warn() {
    echo "! WARN: $*"
    TOTAL_WARN=$((TOTAL_WARN + 1))
}

WORK=""

cleanup() {
    stop_ssh_agent

    if [[ -n "$WORK" ]]; then
        rm -rf -- "$WORK"
    fi
}

trap cleanup EXIT

# Runs a remote command and compares its output with a baseline file.
check() {
    local ROUTER="$1"
    local NAME="$2"
    local DIR="$3"
    local FILE="$4"
    local LABEL="$5"
    local CMD="$6"

    if [[ ! -f "$DIR/$FILE" ]]; then
        warn "$NAME: $FILE baseline missing"
        return
    fi

    if ! ssh "${SSH_OPTS[@]}" "$ROUTER" "$CMD" \
        > "$WORK/current" 2> "$WORK/error"; then

        fail "$NAME: could not collect $LABEL"
        cat "$WORK/error"
        return
    fi

    if grep -q '^ERROR  ' "$WORK/current"; then
        fail "$NAME: could not fully collect $LABEL"
        grep '^ERROR  ' "$WORK/current"
        cat "$WORK/error"
        return
    fi

    if diff -u \
        --label "baseline/$NAME/$FILE" \
        --label "current/$NAME/$FILE" \
        "$DIR/$FILE" "$WORK/current" \
        > "$WORK/diff"; then

        pass "$NAME: $LABEL"
    else
        fail "$NAME: $LABEL changed"
        cat "$WORK/diff"
    fi
}

verify_router() {
    local ROUTER="$1"
    local NAME="$2"
    local DIR="$BASELINE/$NAME"

    echo
    echo "========================================"
    echo " Router:   $ROUTER"
    echo " Baseline: $DIR"
    echo "========================================"
    echo

    [[ -d "$DIR" ]] || {
        fail "$NAME: baseline directory does not exist"
        return
    }

    echo "[1/8] SSH connectivity"

    if ssh "${SSH_OPTS[@]}" \
        -o BatchMode=yes \
        "$ROUTER" true 2>/dev/null; then

        pass "$NAME: SSH connectivity"
    else
        fail "$NAME: SSH connection failed"
        return
    fi

    echo "[2/8] System information"
    check "$ROUTER" "$NAME" "$DIR" system.txt \
        "system information" "$REMOTE_SYSTEM"

    echo "[3/8] Critical file hashes"
    check "$ROUTER" "$NAME" "$DIR" files.sha256 \
        "critical file hashes" "$REMOTE_FILES"

    echo "[4/8] Installed packages"
    check "$ROUTER" "$NAME" "$DIR" packages.txt \
        "installed packages" "$REMOTE_PACKAGES"

    echo "[5/8] UID 0 accounts"
    check "$ROUTER" "$NAME" "$DIR" uid0.txt \
        "UID 0 accounts" "$REMOTE_UID0"

    echo "[6/8] SSH authorized keys"
    check "$ROUTER" "$NAME" "$DIR" authorized_keys \
        "SSH authorized keys" "$REMOTE_KEYS"

    echo "[7/8] Overlay changes"
    check "$ROUTER" "$NAME" "$DIR" overlay.sha256 \
        "overlay changes" "$REMOTE_OVERLAY"

    echo "[8/8] Cron configuration (persistence)"
    check "$ROUTER" "$NAME" "$DIR" crontabs.txt \
        "cron configuration" "$REMOTE_CRON"
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
echo "========================================"
echo " OpenWrt Multi-Router Integrity Check"
echo "========================================"
echo
echo "Baseline directory: $BASELINE"

[[ -d "$BASELINE" ]] || {
    echo
    echo "ERROR: Baseline directory not found: $BASELINE"
    exit 1
}

start_ssh_agent

WORK="$(mktemp -d)"

for ROUTER in "${ROUTERS[@]}"; do
    verify_router "$ROUTER" "$(router_name "$ROUTER")"
done

echo
echo "========================================"
echo " Overall Result"
echo "========================================"
echo
echo "PASS: $TOTAL_PASS"
echo "FAIL: $TOTAL_FAIL"
echo "WARN: $TOTAL_WARN"
echo

if (( TOTAL_FAIL > 0 )); then
    echo "RESULT: MODIFICATION DETECTED"
    exit 2

elif (( TOTAL_WARN > 0 )); then
    echo "RESULT: BASELINE INCOMPLETE"
    exit 1

else
    echo "RESULT: ALL CHECKS PASSED"
    exit 0
fi
