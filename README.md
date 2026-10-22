# OpenWrt Integrity

Scripts to create known-good baselines and verify the integrity of OpenWrt routers.

The baseline script records system information, critical file hashes, installed packages, UID 0 accounts, SSH authorized keys, overlay changes, and cron configuration. The verifier compares the current router state against that baseline and reports differences.

Multiple routers are supported, each logging in with its own SSH key, a running `ssh-agent`, or a password.

## Requirements

* Linux system with Bash
* OpenSSH client
* Root SSH access to the OpenWrt routers
* OpenWrt using the `apk` package manager
* A known-good router state for baseline generation

## Configuration

Both scripts read their settings from `routers.conf` and share their remote commands through `routers-common.sh`. Each entry in the `ROUTERS` array sets one router's address and how to log in to it: `key <private key>`, `agent [public key]`, or `password`; the entries below are examples, so change them to match the routers being monitored:

```bash
ROUTERS=(
    "root@192.168.1.1 key $HOME/.ssh/openwrt"
    "root@192.168.1.2 agent $HOME/.ssh/openwrt-office.pub"
    "root@192.168.1.3 password"
)
```

Each router's baseline directory is named after its address (e.g. `root@192.168.1.1`), so routers can be added, removed, or reordered freely, and their login method changed without regenerating the baseline. Write key paths with `$HOME`, as `~` is not expanded inside the quotes.

Keys are loaded into an `ssh-agent` started for the run, so each passphrase is entered once even when several routers share a key; `-o IdentitiesOnly=yes` ensures a router is offered only its own key. Agent routers use the agent already running in your session (`SSH_AUTH_SOCK`), such as one holding a hardware or password-manager key: any key in it, or only the one matching the public key given. A password is asked for once per router. Each router gets one master SSH connection that all its commands reuse; it is closed, and the agent stopped, when the script exits. Connections time out if a router stops responding. Password routers need someone at the terminal, so use keys without a passphrase, or an agent reachable from the job, for cron or other unattended runs.

## Generate a Baseline

```bash
chmod +x routers-*.sh
./routers-generate-baseline.sh                # default: ./known-good/
./routers-generate-baseline.sh ./my-baseline  # custom directory
./routers-generate-baseline.sh --force        # replace existing baseline
```

Routers should be in a known-good state before generating a baseline. After intentional changes such as upgrades or configuration edits, regenerate the baseline so they are not reported as modifications. An existing baseline is never overwritten without `--force`, and the old one is then kept as `known-good.bak-<timestamp>`. The new baseline is built in a temporary directory, so a failed run leaves the existing one untouched. Each router receives its own directory:

```text
known-good/
├── root@192.168.1.1/
│   ├── authorized_keys
│   ├── crontabs.txt
│   ├── files.sha256
│   ├── overlay.sha256
│   ├── packages.txt
│   ├── system.txt
│   └── uid0.txt
└── root@192.168.1.2/
    └── ...
```

## What It Checks

| Check | Source |
|---|---|
| System information | `/etc/openwrt_release`, `uname -a` |
| Critical file hashes (SHA-256) | Every file under `/etc`, except `/etc/urandom.seed` and `/etc/luci-uploads/` |
| Installed packages | `apk list --installed` (sorted) |
| UID 0 accounts | `/etc/passwd` |
| SSH authorized keys | `/root/.ssh/authorized_keys`, `/etc/dropbear/authorized_keys` |
| Overlay changes | Every file under `/overlay/upper` (files changed since flashing on squashfs installs), with the same exclusions plus `/root/.ash_history` |
| Cron persistence | `/etc/crontabs/` |

Changes to the OpenWrt release or running kernel, missing files, added or removed packages, unexpected UID 0 accounts (normally only `root`), and changed keys or cron jobs are all reported. The baseline stores public SSH keys only, never the private key used by the scripts.

All of `/etc` is listed again on every run, so added, removed, and modified files are all detected. Symlinks, such as the `/etc/rc.d` start scripts, are recorded by target.

Baseline generation aborts if no file hashes, packages, or UID 0 accounts can be collected from a router, or if any file cannot be read. Router addresses that would share a baseline directory name are rejected.

## Verify Router Integrity

```bash
./routers-integrity-checker.sh                # default: ./known-good/
./routers-integrity-checker.sh ./my-baseline  # custom directory
```

For each router, the verifier checks:

```text
1. SSH connectivity
2. System information
3. Critical file hashes
4. Installed packages
5. UID 0 accounts
6. SSH authorized keys
7. Overlay changes
8. Cron configuration
```

Each check counts as one `PASS` or `FAIL`; cron is labelled as a persistence check. If SSH connectivity fails, the remaining checks for that router are skipped and it is counted as a failure. If data for a single check cannot be fully collected, for example because a file cannot be read, that check fails and the others still run.

## Verification Result

Each check reports `PASS`, `FAIL`, or `WARN`. Example summary:

```text
========================================
 Overall Result
========================================

PASS: 24
FAIL: 0
WARN: 0

RESULT: ALL CHECKS PASSED
```

Exit codes, for use by automation or monitoring:

```text
0  All checks passed
1  Baseline incomplete or warnings
2  Modification detected
```

Exit code `1` is also returned if the baseline directory does not exist. A failed SSH connection or data collection counts as a failure and results in exit code `2`.

## Security Model

This project uses a **known-good baseline** model: generate a baseline from a trusted state, then compare later states against it. A difference indicates the router state has changed.

A successful verification means the checked data matches the baseline. It does **not** prove the router is uncompromised. If a baseline is generated after a compromise, the compromised state becomes the baseline, so only generate baselines from trusted routers.

Protect the baseline itself: anyone who can edit it can hide changes. Keep a copy offline or on read-only storage, away from the routers.

## Public Repository

The scripts can be published safely, as they contain no secrets. Never commit `~/.ssh/openwrt` or other private keys.

The generated baseline may contain environment-specific information (configuration details, packages, public keys, cron jobs, system information, file hashes), so generate it locally and keep it out of public repositories. The included `.gitignore` already excludes it, along with its backups:

```gitignore
known-good*/
```

## Limitations

The checks do not provide full filesystem or runtime integrity verification. They may not detect:

* Modified executables on installs without an overlay (e.g. ext4 images)
* Kernel-level or memory-only compromise
* Running malicious processes or network-level compromise
* Persistence outside the checked locations
* Firmware modification

This is a lightweight baseline and change-detection tool, not a complete intrusion-detection system.

## License

This project is independent of the OpenWrt project. Refer to the upstream OpenWrt project for its licensing terms.

This project is licensed under the [MIT License](LICENSE).
