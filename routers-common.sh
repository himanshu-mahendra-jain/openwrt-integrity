# ------------------------------------------------------------
# Shared code for routers-generate-baseline.sh and
# routers-integrity-checker.sh. Both scripts run the exact same
# remote commands, so baseline and current output compare
# byte for byte.
# ------------------------------------------------------------

# shellcheck source=routers.conf
source "$(dirname "${BASH_SOURCE[0]}")/routers.conf"

(( ${#ROUTERS[@]} > 0 )) || {
    echo "ERROR: No routers configured in routers.conf"
    exit 1
}

# The keepalive options abort a session that stops responding
# mid-command instead of hanging indefinitely.
SSH_OPTS=(
    -i "$SSH_KEY"
    -o IdentitiesOnly=yes
    -o ConnectTimeout=10
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=3
)

# Baseline directory name for a router, e.g. root@192.168.1.1.
# Names are derived from the address, so adding, removing, or
# reordering routers never shifts them onto another baseline.
router_name() {
    echo "${1//[^A-Za-z0-9@._-]/_}"
}

DUPLICATE_NAMES="$(
    for ROUTER in "${ROUTERS[@]}"; do
        router_name "$ROUTER"
    done | sort | uniq -d
)"

[[ -z "$DUPLICATE_NAMES" ]] || {
    echo "ERROR: Several routers in routers.conf map to the same"
    echo "baseline directory: $DUPLICATE_NAMES"
    exit 1
}

# ------------------------------------------------------------
# SSH agent
# ------------------------------------------------------------
OWN_SSH_AGENT=0

start_ssh_agent() {
    [[ -f "$SSH_KEY" ]] || {
        echo "ERROR: SSH key not found: $SSH_KEY"
        exit 1
    }

    eval "$(ssh-agent -s)" > /dev/null
    OWN_SSH_AGENT=1
    ssh-add "$SSH_KEY"
}

# Only stops the agent started by this script, never an
# agent inherited from the user's environment.
stop_ssh_agent() {
    if (( OWN_SSH_AGENT )); then
        ssh-agent -k > /dev/null 2>&1 || true
        OWN_SSH_AGENT=0
    fi
}

# ------------------------------------------------------------
# Remote commands
#
# A command that fails partway through prints an "ERROR  <what>"
# line instead of silently leaving data out. The baseline script
# refuses to save such output and the checker reports it.
# ------------------------------------------------------------

# Reads paths on stdin and prints one line per path: the SHA-256
# for regular files, the target for symlinks (e.g. /etc/rc.d),
# and a marker for other entries (e.g. overlay whiteouts).
# Paths that do not exist are skipped, so a file appearing or
# disappearing later shows up as a difference.
REMOTE_HASH_PATHS='
hash_paths() {
    while IFS= read -r f; do
        [ -n "$f" ] || continue

        if [ -L "$f" ]; then
            printf "link:%s  %s\n" "$(readlink "$f")" "$f"
        elif [ -f "$f" ]; then
            sha256sum -- "$f" || printf "ERROR  %s\n" "$f"
        elif [ -e "$f" ]; then
            printf "special  %s\n" "$f"
        fi
    done
}
'

REMOTE_SYSTEM='
echo "### /etc/openwrt_release"
cat /etc/openwrt_release 2>/dev/null || true
echo
echo "### uname"
uname -a
'

# Files that change during normal operation: the entropy seed is
# rewritten on every boot, and LuCI stores uploads here.
REMOTE_EXCLUDE='(etc/urandom\.seed|etc/luci-uploads/.*)'

# All of /etc is listed on every run, so files added after the
# baseline was generated are detected.
REMOTE_FILES="$REMOTE_HASH_PATHS"'
{ find /etc ! -type d -print || echo "ERROR  find /etc"; } |
grep -Evx "/'"$REMOTE_EXCLUDE"'" |
sort |
hash_paths
'

# On squashfs installs, /overlay/upper holds every file changed
# since flashing, including modified binaries outside /etc.
# Shell history changes on every interactive login and is ignored.
REMOTE_OVERLAY="$REMOTE_HASH_PATHS"'
if [ -d /overlay/upper ]; then
    { find /overlay/upper ! -type d -print || echo "ERROR  find /overlay/upper"; } |
    grep -Evx "/overlay/upper/(root/\.ash_history|'"$REMOTE_EXCLUDE"')" |
    sort |
    hash_paths
else
    echo "### /overlay/upper not present"
fi
'

REMOTE_PACKAGES='{ apk list --installed || echo "ERROR  apk list"; } | sort'

REMOTE_UID0="awk -F: '\$3 == 0 {print \$1}' /etc/passwd"

REMOTE_KEYS='
for f in \
    /root/.ssh/authorized_keys \
    /etc/dropbear/authorized_keys
do
    if [ -f "$f" ]; then
        echo "### $f"
        cat "$f" || echo "ERROR  $f"
    fi
done
'

REMOTE_CRON='
for f in /etc/crontabs/*; do
    [ -f "$f" ] || continue

    echo "### $f"
    cat "$f" || echo "ERROR  $f"
done
'
