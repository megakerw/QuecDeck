#!/bin/bash
# Triggered by the QuecDeck web UI to perform an update.
# Called via sudo by the trigger_update CGI.
# Usage: run_update.sh <tag>  For example: run_update.sh v1.2.3

TAG="${1:-}"
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022
case "$TAG" in
    --clear-status) [ "$#" -eq 1 ] || exit 1 ;;
    --fetch)        [ "$#" -eq 2 ] || exit 1 ;;
    --service|--service-run) [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || exit 1 ;;
    *)              [ "$#" -eq 1 ] || { echo "Usage: run_update.sh <tag>"; exit 1; } ;;
esac
# Validate before touching runtime state. A tag is inserted into ExecStart,
# so matching just one line (grep) would allow additional unit directives.
case "$TAG" in
    --clear-status|--service|--service-run) ;;
    --fetch) [[ "${2:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1 ;;
    *) [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1 ;;
esac

# The sudo entry point must verify credentials itself, even when the caller
# bypasses the CGI. Read exactly two bounded lines; never put secrets in the
# service file, environment or command arguments. Exit 3 means authentication
# failed (2 is reserved for a busy dispatcher), and 75 means unavailable.
verify_service_credentials() {
    local payload admin developer extra admin_rc developer_rc
    payload=$(head -c 515; printf .)
    payload=${payload%.}
    [ "${#payload}" -le 514 ] || return 3
    payload=${payload%$'\n'}
    {
        IFS= read -r admin || return 3
        IFS= read -r developer || return 3
        IFS= read -r extra && return 3
    } <<< "$payload"
    [ -n "$admin" ] && [ "${#admin}" -le 256 ] || return 3
    [ -n "$developer" ] && [ "${#developer}" -le 256 ] || return 3
    # Always check both so failure timing does not identify the wrong secret.
    printf '%s\n' "$admin" | /usrdata/quecdeck/script/check_password.sh admin admin
    admin_rc=${PIPESTATUS[1]}
    printf '%s\n' "$developer" | /usrdata/quecdeck/script/check_password.sh dev devadmin
    developer_rc=${PIPESTATUS[1]}
    [ "$admin_rc" != 75 ] && [ "$developer_rc" != 75 ] || return 75
    [ "$admin_rc" = 0 ] && [ "$developer_rc" = 0 ] || return 3
}
# Root-owned runtime state lives in /run/quecdeck, never in /tmp: www-data
# cannot plant a name there, so these writes need no symlink ceremony.
# Rule and rationale: tests/host/guards/runtime-path.sh.
RUNDIR=/run/quecdeck
LOG="$RUNDIR/install.log"
STATUS_FILE="$RUNDIR/update.status"
# What the current status describes. The UI labels its progress panel from this,
# and it is what stops a QuecDeck version from being reported as the outcome of
# an SSH action.
KIND_FILE="$RUNDIR/update.kind"
# Last answer from install_sshd.sh --check. World-readable so the web tier can
# read it without another root call.
SSHD_CHECK="$RUNDIR/sshd-check"
# Serialises dispatch, not the work. The activity check, the shared status, the
# transient unit and the start are one decision: without a lock two requests can
# both pass the check, then race to define the unit systemd actually runs, and
# both report that their own action started. The installer's lock cannot cover
# this because only the action systemd picked ever reaches it.
DISPATCH_LOCK="$RUNDIR/dispatch.lock"
UPDATE_TMP="$RUNDIR/update"
CHECKSUMS="$UPDATE_TMP/quecdeck_update_checksums.sha256"
UPDATE_SCRIPT="$UPDATE_TMP/quecdeck_update.sh"

# Create it before anything else because every entry point writes here. Check
# the result. If creation fails, the fetch unit never starts and no status is written, so
# the UI would sit on "idle" as though nothing had been requested.
if ! mkdir -p "$RUNDIR" || ! chmod 755 "$RUNDIR"; then
    echo "FATAL: cannot create $RUNDIR. Refusing to start an update that could not report its own status."
    exit 1
fi

# Atomic status writes are mandatory: starting work without a readable outcome
# would leave the UI stuck on stale or misleading state.
write_status() {
    printf '%s\n' "$1" > "${STATUS_FILE}.tmp" &&
        chmod 644 "${STATUS_FILE}.tmp" &&
        mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

# Bounded, and held only across dispatch. A caller that cannot take it is
# looking at a dispatch already under way, which is the same answer the activity
# check below gives, so it exits 2 like any other in-progress result.
take_dispatch_lock() {
    . /usrdata/quecdeck/script/lock-lib.sh || return 1
    exec 8>>"$DISPATCH_LOCK" || return 1
    chown root:root "$DISPATCH_LOCK" && chmod 644 "$DISPATCH_LOCK" || return 1
    flock_wait 8 5
}

# Written before the status it describes, so a UI that reads a fresh "running"
# never finds the kind missing and mislabels the panel.
write_kind() {
    printf '%s\n' "$1" > "${KIND_FILE}.tmp" &&
        chmod 644 "${KIND_FILE}.tmp" &&
        mv "${KIND_FILE}.tmp" "$KIND_FILE"
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
        done|failed|failed:rollback_ok|failed:rollback_failed|failed:code:*)
            rm -f "$STATUS_FILE" "$KIND_FILE" ;;
    esac
    exit 0
fi

# SSH component actions, in the same two stages a QuecDeck update uses: --service
# starts a transient unit and returns, --service-run is that unit's entry point.
# A unit is required because an opkg install outlives a CGI request, and because
# install and uninstall restart the firewall, which takes lighttpd down with the
# CGI attached to it.
if [ "$TAG" = "--service" ] || [ "$TAG" = "--service-run" ]; then
    SSHD_ACTION="${2:-}"
    SSHD_PORT="${3:-}"
    case "$SSHD_ACTION" in
        check|update|uninstall)
            [ "$#" -eq 2 ] || { echo "The $SSHD_ACTION action takes no port."; exit 1; }
            ;;
        install)
            [ "$#" -eq 3 ] || { echo "Install needs a port."; exit 1; }
            # Shape only. install_sshd.sh holds the range, so the bound lives in
            # one place.
            case "$SSHD_PORT" in ''|*[!0-9]*) echo "Invalid SSH port."; exit 1 ;; esac
            ;;
        *) echo "Unknown SSH action."; exit 1 ;;
    esac
fi

if [ "$TAG" = "--service-run" ]; then
    # Only the unit may enter this mode. A direct www-data sudo call would bypass
    # the exclusion guard below, and sudo's env_reset strips the marker from
    # anything it starts. The unit sets it through Environment=.
    # Not abort: refusing an invalid entry point must not overwrite the recorded
    # outcome of whatever last ran.
    if [ "${QD_SERVICE_UNIT:-}" != "1" ]; then
        echo "--service-run is started by the install_quecdeck_sshd unit only."
        exit 1
    fi

    case "$SSHD_ACTION" in
        check)
            # stdout is the machine-readable answer, stderr carries the step
            # lines. Both reach the log through the unit, and the answer is also
            # kept for the UI to read after the run ends.
            _answer=$(/usrdata/quecdeck/script/install_sshd.sh --check)
            rc=$?
            printf '%s\n' "$_answer"
            if [ "$rc" -eq 0 ]; then
                printf '%s\n' "$_answer" > "${SSHD_CHECK}.tmp" &&
                    chmod 644 "${SSHD_CHECK}.tmp" &&
                    mv "${SSHD_CHECK}.tmp" "$SSHD_CHECK" ||
                    rm -f "${SSHD_CHECK}.tmp"
            fi
            ;;
        install)
            /usrdata/quecdeck/script/install_sshd.sh --install "$SSHD_PORT"
            rc=$?
            ;;
        update)
            /usrdata/quecdeck/script/install_sshd.sh --update
            rc=$?
            ;;
        uninstall)
            /usrdata/quecdeck/script/install_sshd.sh --uninstall
            rc=$?
            ;;
    esac

    # Any action that changes what is installed invalidates the last check.
    # A stale "update available" would otherwise survive the update that
    # applied it.
    [ "$SSHD_ACTION" = check ] || rm -f "$SSHD_CHECK"

    if [ "$rc" -eq 0 ]; then
        write_status done || {
            rm -f "${STATUS_FILE}.tmp"
            echo "FATAL: could not record the completed status." >&2
            exit 1
        }
        exit 0
    fi
    # The installer's exit code is the outcome, carried through the status file
    # so the UI can say which failure this was without reading the log.
    write_status "failed:code:$rc" || {
        rm -f "${STATUS_FILE}.tmp"
        echo "FATAL: could not record the failed status." >&2
    }
    exit "$rc"
fi

if [ "$TAG" = "--service" ]; then
    if [ "$SSHD_ACTION" != check ]; then
        verify_service_credentials || exit $?
    fi
    take_dispatch_lock || {
        echo "An update is already in progress. Not starting another."
        exit 2
    }
    # One in-flight operation across both kinds: an SSH action and a QuecDeck
    # update both drive opkg and both can cycle the web server.
    for _unit in install_quecdeck install_quecdeck_fetch install_quecdeck_sshd; do
        state=$(systemctl is-active "$_unit" 2>/dev/null)
        if [ "$state" = "activating" ] || [ "$state" = "active" ]; then
            echo "An update is already in progress. Not starting another."
            exit 2
        fi
        systemctl reset-failed "$_unit" 2>/dev/null
    done

    if ! write_kind "sshd:$SSHD_ACTION" || ! write_status running; then
        rm -f "${KIND_FILE}.tmp" "${STATUS_FILE}.tmp"
        echo "FATAL: cannot record the action status. Refusing to start." >&2
        exit 1
    fi
    if ! : > "$LOG" || ! chmod 644 "$LOG"; then
        abort "FATAL: cannot prepare the log. Refusing to start."
    fi

    SSHD_UNIT_FILE=/run/systemd/system/install_quecdeck_sshd.service
    mkdir -p /run/systemd/system || abort "FATAL: cannot create systemd's runtime unit directory."
    rm -f "$SSHD_UNIT_FILE" || abort "FATAL: cannot replace the previous SSH action unit."
    if ! cat <<UNIT > "$SSHD_UNIT_FILE"
[Unit]
Description=QuecDeck SSH component action

[Service]
Type=oneshot
# Bounds a hung opkg. Expiry force-fails the unit so it can never block a later
# action, and the guard above clears it on the next trigger.
TimeoutStartSec=900
Environment=QD_SERVICE_UNIT=1
ExecStart=/bin/bash /usrdata/quecdeck/script/run_update.sh --service-run $SSHD_ACTION $SSHD_PORT
StandardOutput=append:$LOG
StandardError=append:$LOG
UNIT
    then
        abort "FATAL: cannot write the SSH action unit."
    fi
    chmod 644 "$SSHD_UNIT_FILE" || abort "FATAL: cannot secure the SSH action unit."
    systemctl daemon-reload || abort "FATAL: systemd rejected the SSH action unit."
    systemctl start --no-block install_quecdeck_sshd 2>>"$LOG" || abort "The SSH action unit was rejected by systemd."
    sleep 1
    if [ "$(systemctl is-active install_quecdeck_sshd 2>/dev/null)" = "failed" ]; then
        abort "The SSH action unit failed to start."
    fi
    echo "Started."
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
    GITROOT="https://raw.githubusercontent.com/megakerw/QuecDeck/$TAG"

    # Safe as a fixed path: only one fetch unit can exist at a time.
    rm -rf "$UPDATE_TMP"
    mkdir -m 700 "$UPDATE_TMP" || abort "Security: failed to create $UPDATE_TMP."

    /usr/bin/curl -q --proto '=https' --proto-redir '=https' --cacert /etc/ssl/certs/ca-certificates.crt -fsSL --connect-timeout 15 --max-time 30 --retry 1 -o "$CHECKSUMS" "$GITROOT/quecdeck/checksums.sha256" || abort "Failed to download checksums."
    expected_hash=$(grep -E '^[a-f0-9]{64} \*update_quecdeck\.sh$' "$CHECKSUMS" | awk '{print $1}')
    rm -f "$CHECKSUMS"
    [ -z "$expected_hash" ] && abort "Could not find hash for update_quecdeck.sh in checksums."

    /usr/bin/curl -q --proto '=https' --proto-redir '=https' --cacert /etc/ssl/certs/ca-certificates.crt -fsSL --connect-timeout 15 --max-time 30 --retry 1 -o "$UPDATE_SCRIPT" "$GITROOT/update_quecdeck.sh" || abort "Failed to download update_quecdeck.sh."
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

# Mutual exclusion via systemd for BOTH stages: the install runs as the
# install_quecdeck oneshot, the download window as the install_quecdeck_fetch
# transient unit. "activating" is a oneshot's running state, "active" covers
# RemainAfterExit. The reset-failed call clears leftovers from prior runs so the fetch
# window reads as running, not failed, in get_update_log.
take_dispatch_lock || {
    echo "An update is already in progress. Not starting another." >> "$LOG" 2>/dev/null
    exit 2
}
for _unit in install_quecdeck install_quecdeck_fetch install_quecdeck_sshd; do
    state=$(systemctl is-active "$_unit" 2>/dev/null)
    if [ "$state" = "activating" ] || [ "$state" = "active" ]; then
        echo "An update is already in progress. Not starting another." >> "$LOG" 2>/dev/null
        exit 2
    fi
    systemctl reset-failed "$_unit" 2>/dev/null
done

if ! write_kind quecdeck || ! write_status running; then
    rm -f "${KIND_FILE}.tmp" "${STATUS_FILE}.tmp"
    echo "FATAL: cannot record update status. Refusing to start." >&2
    exit 1
fi
# Must stay ahead of the fetch unit start below, which opens $LOG append as root.
if ! : > "$LOG" || ! chmod 644 "$LOG"; then
    abort "FATAL: cannot prepare the update log. Refusing to start."
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
