#!/bin/bash
# Triggered by the QuecDeck web UI to perform an update.
# Called via sudo by the trigger_update CGI.
# Usage: run_update.sh <tag>  For example: run_update.sh v1.2.3

TAG="${1:-}"
umask 022
# Root-owned runtime state lives in /run/quecdeck, never in /tmp: www-data
# cannot plant a name there, so these writes need no symlink ceremony.
# Rule and rationale: tests/host/tmpwrite-guard.sh.
RUNDIR=/run/quecdeck
LOG="$RUNDIR/install.log"
STATUS_FILE="$RUNDIR/update.status"
UPDATE_TMP="$RUNDIR/update"
CHECKSUMS="$UPDATE_TMP/quecdeck_update_checksums.sha256"
UPDATE_SCRIPT="$UPDATE_TMP/quecdeck_update.sh"

# Create it before anything else because every entry point writes here. Check
# the result. If creation fails, the fetch unit never starts and no status is written, so
# the UI would sit on "idle" as though nothing had been requested.
if ! mkdir -p "$RUNDIR" || ! chmod 755 "$RUNDIR"; then
    echo "FATAL: cannot create $RUNDIR; refusing to start an update that could not report its own status."
    exit 1
fi

# Atomic status writes are mandatory: starting work without a readable outcome
# would leave the UI stuck on stale or misleading state.
write_status() {
    printf '%s\n' "$1" > "${STATUS_FILE}.tmp" &&
        chmod 644 "${STATUS_FILE}.tmp" &&
        mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

# Fails the run: log + status. Runs inside the fetch unit, whose stdout already
# appends to $LOG.
abort() {
    echo "$1"
    write_status failed || {
        rm -f "${STATUS_FILE}.tmp"
        echo "FATAL: could not record the failed update status." >&2
    }
    exit 1
}

# Clear a terminal status file at the UI's request. The status file is root
# owned, so the www-data get_update_log CGI cannot unlink it and calls this via
# the existing sudo entry. Only terminal states are cleared, so an ack racing a
# live update never wipes a "running" status.
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
    # the exclusion guard below. The sudo env_reset policy strips the marker from any
    # www-data attempt. The unit sets it through Environment=.
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
# RemainAfterExit. The reset-failed call clears leftovers from prior runs so the fetch
# window reads as running, not failed, in get_update_log.
for _unit in install_quecdeck install_quecdeck_fetch; do
    state=$(systemctl is-active "$_unit" 2>/dev/null)
    if [ "$state" = "activating" ] || [ "$state" = "active" ]; then
        echo "An update is already in progress; not starting another." >> "$LOG" 2>/dev/null
        exit 2
    fi
    systemctl reset-failed "$_unit" 2>/dev/null
done

if ! write_status running; then
    rm -f "${STATUS_FILE}.tmp"
    echo "FATAL: cannot record update status; refusing to start." >&2
    exit 1
fi
# Must stay ahead of the fetch unit start below, which opens $LOG append as root.
if ! : > "$LOG" || ! chmod 644 "$LOG"; then
    abort "FATAL: cannot prepare the update log; refusing to start."
fi

# Start the fetch phase as a oneshot written to /run, the same field-proven
# pattern the bootstrap uses for the install unit (do NOT swap in systemd-run:
# its D-Bus path is unverified from the CGI-sudo context). The systemd unit runs
# at most one instance per unit name, so a concurrent trigger coalesces into
# this start instead of racing the download window (the is-active check above
# cannot see a fetch that has not started yet). The unit detaches from the CGI
# on its own. No nohup or lock file is needed.
FETCH_UNIT_FILE=/run/systemd/system/install_quecdeck_fetch.service
mkdir -p /run/systemd/system || abort "FATAL: cannot create systemd's runtime unit directory."
rm -f "$FETCH_UNIT_FILE" || abort "FATAL: cannot replace the previous fetch unit."
if ! cat <<UNIT > "$FETCH_UNIT_FILE"
[Unit]
Description=QuecDeck update fetch

[Service]
Type=oneshot
# Spans fetch + the bootstrap it execs (which blocks on the install unit, own
# cap 900s). Expiry force-fails a hung fetch so it can never block future
# updates. The guard's reset-failed clears it on the next trigger.
TimeoutStartSec=1500
Environment=QD_FETCH_UNIT=1
ExecStart=/bin/bash /usrdata/quecdeck/script/run_update.sh --fetch $TAG
StandardOutput=append:$LOG
StandardError=append:$LOG
UNIT
then
    abort "FATAL: cannot write the update fetch unit."
fi
chmod 644 "$FETCH_UNIT_FILE" || abort "FATAL: cannot secure the update fetch unit."
systemctl daemon-reload || abort "FATAL: systemd rejected the update fetch unit."
systemctl start --no-block install_quecdeck_fetch 2>>"$LOG" || abort "The update fetch unit was rejected by systemd."
sleep 1
if [ "$(systemctl is-active install_quecdeck_fetch 2>/dev/null)" = "failed" ]; then
    abort "The update fetch unit failed to start."
fi
echo "Downloading installer..." | tee -a "$LOG"
