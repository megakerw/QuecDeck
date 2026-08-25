#!/bin/bash
# On-device latency measurement for the AT command path. Run as root:
#   /tmp/device-test-atlatency.sh
# Dev tool, not deployed. Copy it to the device manually. It sends only the
# read-only no-op AT command. The direct baseline briefly stops the daemon,
# and the cleanup trap restores it if the test exits or is interrupted.
#
# Invokes the same atcli binary through the daemon socket and with --direct, so
# the comparison isolates daemon dispatch from the per-command port open.
# Timing uses /proc/uptime
# centiseconds because BusyBox date has no %N and Bash may predate EPOCHREALTIME,
# so per-call figures are averaged over enough iterations to be meaningful.

set -u
ATLIB=/usrdata/quecdeck/script/at-lib.sh
[ -f "$ATLIB" ] || { echo "FATAL: $ATLIB missing"; exit 1; }
. "$ATLIB"
N=${N:-20}
restart_daemon=0

restore_daemon() {
    [ "$restart_daemon" = "1" ] || return 0
    if systemctl start atcmd-daemon; then
        restart_daemon=0
        return 0
    fi
    echo "ERROR: could not restart atcmd-daemon" >&2
    return 1
}
trap restore_daemon EXIT
trap 'exit 130' INT TERM

now_cs() { # uptime in centiseconds
    local u
    read -r u _ < /proc/uptime
    echo "$(( ${u%.*} * 100 + 10#${u#*.} ))"
}

# avg_ms <name> <iterations> <cmd...>: run cmd N times, print avg ms/call.
avg_ms() {
    local name="$1" n="$2"; shift 2
    local t0 t1 i
    t0=$(now_cs)
    i=0; while [ "$i" -lt "$n" ]; do "$@" >/dev/null 2>&1; i=$((i+1)); done
    t1=$(now_cs)
    # tenths of ms per call, printed as x.y ms
    local tenths=$(( (t1 - t0) * 100 / n ))
    echo "${name}: $(( tenths / 10 )).$(( tenths % 10 )) ms/call (n=$n)"
    _last_tenths=$tenths
}

_at_socket() { "$_ATCLI" -s "$_ATCLI_SOCK" -t 2000 'AT'; }
_at_direct() { "$_ATCLI" --direct -t 2000 'AT'; }

# --help execs and exits without touching the modem, so this is pure process
# startup cost, paid by every per-command client exec (the daemon pays it
# once at boot).
echo "--- exec cost (--help, no modem I/O)"
_help() { "$_ATCLI" --help; }
avg_ms "exec" "$N" _help

echo ""
echo "--- end-to-end round trips (no-op 'AT' command)"
if [ -S "$_ATCLI_SOCK" ]; then
    avg_ms "atcli via daemon socket" "$N" _at_socket
else
    echo "SKIP: daemon not running (atcmd_run returns empty when the daemon is down)"
fi

# The direct baseline needs the daemon stopped: its always-pending reader
# would steal the responses and every direct call would time out.
if systemctl is-active atcmd-daemon >/dev/null 2>&1; then
    # Bank the restart before stopping. If a signal arrives while systemctl is
    # still waiting, the EXIT trap must already know that restoration is due.
    restart_daemon=1
    if ! systemctl stop atcmd-daemon; then
        echo "FATAL: could not stop atcmd-daemon" >&2
        exit 1
    fi
    avg_ms "--direct per-command open baseline" "$N" _at_direct
    restore_daemon || exit 1
else
    avg_ms "--direct per-command open baseline" "$N" _at_direct
fi

echo ""
echo "Interpretation: the daemon should win by the per-command port open"
echo "cost. If the socket is not clearly faster, investigate."
