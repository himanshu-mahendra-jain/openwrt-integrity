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

config_error() {
    echo "ERROR: routers.conf entry $1: \"$2\""
    echo "$3"
    echo "Expected \"<user@address> key <private key>\","
    echo "\"<user@address> agent [public key]\", or \"<user@address> password\"."
    exit 1
}

# Each entry is split into its address and authentication. The
# key path is the rest of the entry, so it may contain spaces;
# for agent routers it is optional.
ROUTER_ADDRS=()
declare -A ROUTER_AUTH=()
declare -A ROUTER_KEY=()
declare -A ROUTER_NUM=()

for I in "${!ROUTERS[@]}"; do
    read -r ADDR AUTH KEY <<< "${ROUTERS[$I]}"

    case "${AUTH:-}" in
        key)
            [[ -n "$KEY" ]] ||
                config_error "$((I + 1))" "${ROUTERS[$I]}" "No private key given."
            ;;
        agent) ;;
        password)
            [[ -z "$KEY" ]] ||
                config_error "$((I + 1))" "${ROUTERS[$I]}" "Password entries take no key."
            ;;
        "")
            config_error "$((I + 1))" "${ROUTERS[$I]}" "No authentication method given."
            ;;
        *)
            config_error "$((I + 1))" "${ROUTERS[$I]}" "Unknown authentication method: $AUTH"
            ;;
    esac

    ROUTER_ADDRS+=("$ADDR")
    ROUTER_AUTH["$ADDR"]="$AUTH"
    ROUTER_KEY["$ADDR"]="$KEY"
    ROUTER_NUM["$ADDR"]="$I"
done

unset I ADDR AUTH KEY

# The keepalive options abort a session that stops responding
# mid-command instead of hanging indefinitely.
SSH_OPTS=(
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
    for ROUTER in "${ROUTER_ADDRS[@]}"; do
        router_name "$ROUTER"
    done | sort | uniq -d
)"

[[ -z "$DUPLICATE_NAMES" ]] || {
    echo "ERROR: Several routers in routers.conf map to the same"
    echo "baseline directory: $DUPLICATE_NAMES"
    exit 1
}

# ------------------------------------------------------------
# SSH agent and master connections
# ------------------------------------------------------------
OWN_SSH_AGENT=0
SSH_SOCKETS=""

# The user's agent, used by agent routers. The agent this script
# starts for key routers replaces SSH_AUTH_SOCK, so each ssh call
# is given the right one.
USER_AGENT="${SSH_AUTH_SOCK:-}"
OWN_AGENT=""

# Every key is loaded once, so routers sharing a key ask for
# its passphrase only once per run.
start_ssh() {
    local ROUTER KEY
    local KEYS=() MISSING=()
    local USES_AGENT=0
    declare -A SEEN=()

    for ROUTER in "${ROUTER_ADDRS[@]}"; do
        KEY="${ROUTER_KEY[$ROUTER]}"

        [[ "${ROUTER_AUTH[$ROUTER]}" == agent ]] && USES_AGENT=1

        [[ -n "$KEY" && -z "${SEEN[$KEY]:-}" ]] || continue
        SEEN["$KEY"]=1

        if [[ ! -f "$KEY" ]]; then
            MISSING+=("$KEY")
        elif [[ "${ROUTER_AUTH[$ROUTER]}" == key ]]; then
            KEYS+=("$KEY")
        fi
    done

    (( ${#MISSING[@]} == 0 )) || {
        echo "ERROR: SSH key not found:"
        printf '  %s\n' "${MISSING[@]}"
        exit 1
    }

    if (( USES_AGENT )) && [[ ! -S "$USER_AGENT" ]]; then
        echo "ERROR: Routers set to \"agent\" need a running ssh-agent,"
        echo "but SSH_AUTH_SOCK does not point to one."
        exit 1
    fi

    # Created in the system temp directory, as socket paths are
    # limited to about 100 characters.
    SSH_SOCKETS="$(mktemp -d)"

    (( ${#KEYS[@]} > 0 )) || return 0

    eval "$(ssh-agent -s)" > /dev/null
    OWN_SSH_AGENT=1
    OWN_AGENT="$SSH_AUTH_SOCK"

    for KEY in "${KEYS[@]}"; do
        ssh-add "$KEY"
    done
}

# Closes the master connections and stops the agent. Only an
# agent started by this script is stopped, never one inherited
# from the user's environment.
stop_ssh() {
    local ROUTER

    if [[ -n "$SSH_SOCKETS" ]]; then
        for ROUTER in "${ROUTER_ADDRS[@]}"; do
            set_router_opts "$ROUTER"
            SSH_AUTH_SOCK="$ROUTER_AGENT" \
                ssh "${SSH_OPTS[@]}" "${ROUTER_OPTS[@]}" -O exit "$ROUTER" \
                > /dev/null 2>&1 || true
        done

        rm -rf -- "$SSH_SOCKETS"
        SSH_SOCKETS=""
    fi

    if (( OWN_SSH_AGENT )); then
        ssh-agent -k > /dev/null 2>&1 || true
        OWN_SSH_AGENT=0
    fi
}

# Sets ROUTER_OPTS to the router's own options and ROUTER_AGENT
# to its agent socket. ControlPath lets every command reuse one
# master connection per router, so a password is asked for only
# once. Each router has its own socket, even when ~/.ssh/config
# aliases point several entries at one host. The authentication
# options are passed on every call, so if the master connection
# is lost a new connection still authenticates the right way.
set_router_opts() {
    local KEY="${ROUTER_KEY[$1]}"

    ROUTER_OPTS=(-o ControlPath="$SSH_SOCKETS/${ROUTER_NUM[$1]}")
    ROUTER_AGENT="${SSH_AUTH_SOCK:-}"

    case "${ROUTER_AUTH[$1]}" in
        key)
            ROUTER_OPTS+=(-i "$KEY" -o IdentitiesOnly=yes)
            ROUTER_AGENT="$OWN_AGENT"
            ;;
        agent)
            # A public key limits ssh to that one agent key.
            if [[ -n "$KEY" ]]; then
                ROUTER_OPTS+=(-i "$KEY" -o IdentitiesOnly=yes)
            fi
            ROUTER_AGENT="$USER_AGENT"
            ;;
        password)
            ROUTER_OPTS+=(-o PubkeyAuthentication=no)
            ;;
    esac
}

# Runs a command on a router: router_ssh <router> <command>
router_ssh() {
    local ROUTER="$1"
    shift

    set_router_opts "$ROUTER"
    SSH_AUTH_SOCK="$ROUTER_AGENT" \
        ssh "${SSH_OPTS[@]}" "${ROUTER_OPTS[@]}" "$ROUTER" "$@"
}

# Opens the master connection that later commands to the router
# reuse. Batch mode stops key and agent authentication from
# falling back to a password prompt; for password routers, ssh
# prompts on the terminal even when output is redirected.
open_ssh_master() {
    set_router_opts "$1"

    if [[ "${ROUTER_AUTH[$1]}" != password ]]; then
        ROUTER_OPTS+=(-o BatchMode=yes)
    fi

    SSH_AUTH_SOCK="$ROUTER_AGENT" \
        ssh "${SSH_OPTS[@]}" "${ROUTER_OPTS[@]}" -fNM "$1"
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
