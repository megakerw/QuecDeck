#!/bin/bash
# Triggered by the QuecDeck web UI to perform an update.
# Called via sudo by the trigger_update CGI.
# Usage: run_update.sh <tag>  e.g. run_update.sh v1.2.3

TAG="${1:-}"
LOG=/tmp/install_quecdeck.log
STATUS_FILE=/tmp/quecdeck_update.status
UPDATE_TMP=/tmp/.quecdeck-update
CHECKSUMS="$UPDATE_TMP/quecdeck_update_checksums.sha256"
UPDATE_SCRIPT="$UPDATE_TMP/quecdeck_update.sh"

# Fails the run: log + status. Runs inside the fetch unit, whose stdout
# already appends to $LOG.
abort() {
    echo "$1"
    echo "failed" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    exit 1
}

# Clear a terminal status file at the UI's request. The status file is root
# owned in sticky /tmp, so the www-data get_update_log CGI cannot unlink it and
# calls this via the existing sudo entry. Only terminal states are cleared, so
# an ack racing a live update never wipes a "running" status.
if [ "$TAG" = "--clear-status" ]; then
    case "$(cat "$STATUS_FILE" 2>/dev/null)" in
        done|failed|failed:rollback_ok|failed:rollback_failed)
            rm -f "$STATUS_FILE" ;;
    esac
    exit 0
fi

# Fetch phase: runs as the install_quecdeck_fetch transient unit (started at
# the bottom of this file). Downloads and verifies the installer, then execs
# its bootstrap in the foreground so the unit's lifetime spans the update.
if [ "$TAG" = "--fetch" ]; then
    # Only the fetch unit may enter this mode: a direct sudo call would bypass
    # the exclusion guard below. sudo's env_reset strips the marker from any
    # www-data attempt; the unit sets it via Environment=.
    [ "${QD_FETCH_UNIT:-}" = "1" ] || abort "--fetch is started by the install_quecdeck_fetch unit only."
    TAG="${2:-}"
    echo "$TAG" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || abort "Invalid tag format: $TAG"
    GITROOT="https://raw.githubusercontent.com/megakerw/QuecDeck/$TAG"

    if ! /opt/bin/opkg list-installed 2>/dev/null | grep -q '^wget-ssl '; then
        /opt/bin/opkg update
        /opt/bin/opkg install wget-ssl ca-certificates || abort "Failed to install wget-ssl."
    fi

    # Safe as a fixed path: only one fetch unit can exist at a time.
    rm -rf "$UPDATE_TMP"
    mkdir -m 700 "$UPDATE_TMP" || abort "Security: failed to create $UPDATE_TMP."

    /opt/bin/wget --timeout=30 --tries=2 -q -O "$CHECKSUMS" "$GITROOT/quecdeck/checksums.sha256" || abort "Failed to download checksums."
    expected_hash=$(grep -E '^[a-f0-9]{64} \*update_quecdeck\.sh$' "$CHECKSUMS" | awk '{print $1}')
    rm -f "$CHECKSUMS"
    [ -z "$expected_hash" ] && abort "Could not find hash for update_quecdeck.sh in checksums."

    /opt/bin/wget --timeout=30 --tries=2 -q -O "$UPDATE_SCRIPT" "$GITROOT/update_quecdeck.sh" || abort "Failed to download update_quecdeck.sh."
    actual_hash=$(sha256sum "$UPDATE_SCRIPT" | awk '{print $1}')
    if [ "$actual_hash" != "$expected_hash" ]; then
        rm -f "$UPDATE_SCRIPT"
        abort "FATAL: Hash mismatch for update_quecdeck.sh."
    fi
    echo "update_quecdeck.sh integrity verified."
    chmod +x "$UPDATE_SCRIPT"

    echo "Update started (tag: $TAG)."
    exec "$UPDATE_SCRIPT" "$TAG"
fi

if [ -z "$TAG" ]; then
    echo "Usage: run_update.sh <tag>"
    exit 1
fi

if ! echo "$TAG" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Invalid tag format: $TAG"
    exit 1
fi

# Mutual exclusion via systemd for BOTH stages: the install runs as the
# install_quecdeck oneshot, the download window as the install_quecdeck_fetch
# transient unit. "activating" is a oneshot's running state, "active" covers
# RemainAfterExit. reset-failed clears leftovers from prior runs so the fetch
# window reads as running, not failed, in get_update_log.
for _unit in install_quecdeck install_quecdeck_fetch; do
    state=$(systemctl is-active "$_unit" 2>/dev/null)
    if [ "$state" = "activating" ] || [ "$state" = "active" ]; then
        echo "An update is already in progress; not starting another." >> "$LOG" 2>/dev/null
        exit 2
    fi
    systemctl reset-failed "$_unit" 2>/dev/null
done

mkdir -p /tmp/quecdeck
echo "running" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
> "$LOG"
chmod 644 "$LOG"

# Start the fetch phase as a oneshot written to /run, the same field-proven
# pattern the bootstrap uses for the install unit (do NOT swap in systemd-run:
# its D-Bus path is unverified from the CGI-sudo SELinux domain). systemd runs
# at most one instance per unit name, so a concurrent trigger coalesces into
# this start instead of racing the download window (the is-active check above
# cannot see a fetch that has not started yet). The unit detaches from the CGI
# on its own; no nohup, no lock file.
FETCH_UNIT_FILE=/run/systemd/system/install_quecdeck_fetch.service
mkdir -p /run/systemd/system
rm -f "$FETCH_UNIT_FILE"
cat <<UNIT > "$FETCH_UNIT_FILE"
[Unit]
Description=QuecDeck update fetch

[Service]
Type=oneshot
# Spans fetch + the bootstrap it execs (which blocks on the install unit, own
# cap 900s). Expiry force-fails a hung fetch so it can never block future
# updates; the guard's reset-failed clears it on the next trigger.
TimeoutStartSec=1500
Environment=QD_FETCH_UNIT=1
ExecStart=/bin/bash /usrdata/quecdeck/script/run_update.sh --fetch $TAG
StandardOutput=append:$LOG
StandardError=append:$LOG
UNIT
systemctl daemon-reload
systemctl start --no-block install_quecdeck_fetch 2>>"$LOG"
sleep 1
if [ "$(systemctl is-active install_quecdeck_fetch 2>/dev/null)" = "failed" ]; then
    echo "The update fetch unit failed to start." | tee -a "$LOG"
    exit 1
fi
echo "Downloading installer..." | tee -a "$LOG"
