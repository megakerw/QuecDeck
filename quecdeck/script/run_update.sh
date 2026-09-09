#!/bin/bash
# Usage: run_update.sh <tag> <operation-id>

TAG="${1:-}"
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022
case "$TAG" in
    --clear-status) [ "$#" -eq 2 ] || exit 1 ;;
    --fetch)        [ "$#" -eq 3 ] || exit 1 ;;
    --service)      [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || exit 1 ;;
    --service-run)  [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || exit 1 ;;
    *)              [ "$#" -eq 2 ] || { echo "Usage: run_update.sh <tag> <operation-id>"; exit 1; } ;;
esac
# Tags enter systemd unit text and must match one complete line.
case "$TAG" in
    --clear-status|--service|--service-run) ;;
    --fetch) [[ "${2:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1 ;;
    *) [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1 ;;
esac
case "$TAG" in
    --clear-status) OPERATION_ID=${2:-} ;;
    --fetch) OPERATION_ID=${3:-} ;;
    --service|--service-run) OPERATION_ID=${3:-} ;;
    *) OPERATION_ID=${2:-} ;;
esac
[[ "$OPERATION_ID" =~ ^[a-f0-9]{32}$ ]] || exit 1

# The root boundary accepts one bounded credential line.
# Credentials must not enter unit files, environment, or arguments.
# Authentication returns 3 for rejection and 75 when unavailable.
verify_service_credentials() {
    local payload developer extra developer_rc
    payload=$(head -c 258; printf .)
    payload=${payload%.}
    [ "${#payload}" -le 257 ] || return 3
    payload=${payload%$'\n'}
    {
        IFS= read -r developer || return 3
        IFS= read -r extra && return 3
    } <<< "$payload"
    [ -n "$developer" ] && [ "${#developer}" -le 256 ] || return 3
    printf '%s\n' "$developer" | /usrdata/quecdeck/script/check_password.sh dev devadmin
    developer_rc=${PIPESTATUS[1]}
    [ "$developer_rc" != 75 ] || return 75
    [ "$developer_rc" = 0 ] || return 3
}
# www-data cannot create names under the root-owned runtime directory.
RUNDIR=/run/quecdeck
LOG="$RUNDIR/install.log"
OPERATION_FILE="$RUNDIR/update.operation"
SSHD_CHECK="$RUNDIR/sshd-check"
# Dispatch lock covers the unit check, record publication, definition, and start.
DISPATCH_LOCK="$RUNDIR/dispatch.lock"
UPDATE_TMP="$RUNDIR/update"
CHECKSUMS="$UPDATE_TMP/quecdeck_update_checksums.sha256"
UPDATE_SCRIPT="$UPDATE_TMP/quecdeck_update.sh"

if ! mkdir -p "$RUNDIR" || ! chmod 755 "$RUNDIR"; then
    echo "FATAL: cannot create $RUNDIR. Refusing to start an update that could not report its own status."
    exit 1
fi

write_operation() { # write_operation <kind> <status> [code] [rollback]
    printf '%s %s %s %s %s\n' "$OPERATION_ID" "$1" "$2" "${3:-0}" "${4:-none}" > "${OPERATION_FILE}.tmp" &&
        chmod 644 "${OPERATION_FILE}.tmp" &&
        mv "${OPERATION_FILE}.tmp" "$OPERATION_FILE"
}

# Lock contention and an active unit share the busy exit code.
take_dispatch_lock() {
    . /usrdata/quecdeck/script/lock-lib.sh || return 1
    exec 8>>"$DISPATCH_LOCK" || return 1
    chown root:root "$DISPATCH_LOCK" && chmod 644 "$DISPATCH_LOCK" || return 1
    flock_wait 8 5
}

# Fetch-unit failures must publish a terminal operation state.
abort() {
    echo "$1"
    write_operation "$OPERATION_KIND" failed || {
        rm -f "${OPERATION_FILE}.tmp"
        echo "FATAL: could not record the failed update status." >&2
    }
    exit 1
}

# Only the matching terminal operation can be acknowledged.
if [ "$TAG" = "--clear-status" ]; then
    # Compare-and-delete shares the dispatch lock with record creation.
    take_dispatch_lock || exit 2
    read -r current_id current_kind current_status current_code current_rollback < "$OPERATION_FILE" 2>/dev/null || exit 0
    if [ "$current_id" = "$OPERATION_ID" ]; then
        case "$current_status" in done|failed) rm -f "$OPERATION_FILE" ;; esac
    fi
    exit 0
fi

# Package actions run in systemd because firewall restart drops the CGI process.
if [ "$TAG" = "--service" ] || [ "$TAG" = "--service-run" ]; then
    SSHD_ACTION="${2:-}"
    SSHD_PORT="${4:-}"
    OPERATION_KIND="sshd:$SSHD_ACTION"
    case "$SSHD_ACTION" in
        check|update|uninstall)
            [ "$#" -eq 3 ] || { echo "The $SSHD_ACTION action takes no port."; exit 1; }
            ;;
        install)
            [ "$#" -eq 4 ] || { echo "Install needs a port."; exit 1; }
            case "$SSHD_PORT" in ''|*[!0-9]*) echo "Invalid SSH port."; exit 1 ;; esac
            ;;
        *) echo "Unknown SSH action."; exit 1 ;;
    esac
fi

if [ "$TAG" = "--service-run" ]; then
    # Unit-only mode prevents direct sudo entry past the dispatch guard.
    if [ "${QD_SERVICE_UNIT:-}" != "1" ]; then
        echo "--service-run is started by the install_quecdeck_sshd unit only."
        exit 1
    fi

    case "$SSHD_ACTION" in
        check)
            # Preserve the machine-readable result outside the shared log.
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

    # A package change invalidates the cached availability result.
    [ "$SSHD_ACTION" = check ] || rm -f "$SSHD_CHECK"

    if [ "$rc" -eq 0 ]; then
        write_operation "$OPERATION_KIND" done || {
            rm -f "${OPERATION_FILE}.tmp"
            echo "FATAL: could not record the completed status." >&2
            exit 1
        }
        exit 0
    fi
    # The UI maps the installer exit code to an actionable failure.
    write_operation "$OPERATION_KIND" failed "$rc" || {
        rm -f "${OPERATION_FILE}.tmp"
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
    # SSH and QuecDeck operations share one package and web-server slot.
    for _unit in install_quecdeck install_quecdeck_fetch install_quecdeck_sshd; do
        state=$(systemctl is-active "$_unit" 2>/dev/null)
        if [ "$state" = "activating" ] || [ "$state" = "active" ]; then
            echo "An update is already in progress. Not starting another."
            exit 2
        fi
        systemctl reset-failed "$_unit" 2>/dev/null
    done

    if ! : > "$LOG" || ! chmod 644 "$LOG"; then
        abort "FATAL: cannot prepare the log. Refusing to start."
    fi
    if ! write_operation "$OPERATION_KIND" running; then
        rm -f "${OPERATION_FILE}.tmp"
        echo "FATAL: cannot record the action status. Refusing to start." >&2
        exit 1
    fi

    SSHD_UNIT_FILE=/run/systemd/system/install_quecdeck_sshd.service
    mkdir -p /run/systemd/system || abort "FATAL: cannot create systemd's runtime unit directory."
    rm -f "$SSHD_UNIT_FILE" || abort "FATAL: cannot replace the previous SSH action unit."
    if ! cat <<UNIT > "$SSHD_UNIT_FILE"
[Unit]
Description=QuecDeck SSH component action

[Service]
Type=oneshot
# Bound a hung package operation.
TimeoutStartSec=900
Environment=QD_SERVICE_UNIT=1
ExecStart=/bin/bash /usrdata/quecdeck/script/run_update.sh --service-run $SSHD_ACTION $OPERATION_ID $SSHD_PORT
StandardOutput=append:$LOG
StandardError=append:$LOG
UNIT
    then
        abort "FATAL: cannot write the SSH action unit."
    fi
    chmod 644 "$SSHD_UNIT_FILE" || abort "FATAL: cannot secure the SSH action unit."
    systemctl daemon-reload || abort "FATAL: systemd rejected the SSH action unit."
    systemctl start --no-block install_quecdeck_sshd 2>>"$LOG" || abort "The SSH action unit was rejected by systemd."
    echo "Started."
    exit 0
fi

# Fetch-unit lifetime covers download and bootstrap.
if [ "$TAG" = "--fetch" ]; then
    TAG="${2:-}"
    OPERATION_KIND=quecdeck
    # Unit-only mode prevents direct sudo entry past the dispatch guard.
    if [ "${QD_FETCH_UNIT:-}" != "1" ]; then
        echo "--fetch is started by the install_quecdeck_fetch unit only."
        exit 1
    fi
    GITROOT="https://raw.githubusercontent.com/megakerw/QuecDeck/$TAG"

    # One fetch unit owns this fixed path.
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
    exec "$UPDATE_SCRIPT" "$TAG" "$OPERATION_ID"
fi

if [ -z "$TAG" ]; then
    echo "Usage: run_update.sh <tag> <operation-id>"
    exit 1
fi

# The lock serializes dispatch. Unit state covers work already in progress.
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

OPERATION_KIND=quecdeck
# Must stay ahead of the fetch unit start below, which opens $LOG append as root.
if ! : > "$LOG" || ! chmod 644 "$LOG"; then
    abort "FATAL: cannot prepare the update log. Refusing to start."
fi
if ! write_operation "$OPERATION_KIND" running; then
    rm -f "${OPERATION_FILE}.tmp"
    echo "FATAL: cannot record update status. Refusing to start." >&2
    exit 1
fi

# The fixed unit name coalesces starts. systemd-run is unverified here.
FETCH_UNIT_FILE=/run/systemd/system/install_quecdeck_fetch.service
mkdir -p /run/systemd/system || abort "FATAL: cannot create systemd's runtime unit directory."
rm -f "$FETCH_UNIT_FILE" || abort "FATAL: cannot replace the previous fetch unit."
if ! cat <<UNIT > "$FETCH_UNIT_FILE"
[Unit]
Description=QuecDeck update fetch

[Service]
Type=oneshot
# Bound the combined fetch and install-unit wait.
TimeoutStartSec=1500
Environment=QD_FETCH_UNIT=1
ExecStart=/bin/bash /usrdata/quecdeck/script/run_update.sh --fetch $TAG $OPERATION_ID
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
