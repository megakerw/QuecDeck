#!/bin/bash
# On-device latency measurement for the AT command path. Run as root:
#   /tmp/device-test-atlatency.sh
# Dev tool, not deployed; copy to the device manually. Read-only: sends only
# the no-op 'AT' command, touches nothing.
#
# Measures atcmd_run round trips via the daemon socket against the --direct
# per-command port open as the baseline. Timing uses /proc/uptime
# centiseconds (BusyBox date has no %N; bash may predate EPOCHREALTIME),
# so per-call figures are averaged over enough iterations to be meaningful.

set -u
ATLIB=/usrdata/quecdeck/script/at-lib.sh
[ -f "$ATLIB" ] || { echo "FATAL: $ATLIB missing"; exit 1; }
. "$ATLIB"

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

_at_socket() { atcmd_run 'AT' 2000; }
_at_direct() { "$_ATCLI" --direct -t 2000 'AT'; }

# --help execs and exits without touching the modem, so this is pure process
# startup cost, paid by every per-command client exec (the daemon pays it
# once at boot).
echo "--- exec cost (--help, no modem I/O)"
_help() { "$_ATCLI" --help; }
avg_ms "exec" 20 _help

echo ""
echo "--- end-to-end round trips (no-op 'AT' command)"
if [ -S "$_ATCLI_SOCK" ]; then
    avg_ms "atcmd_run via daemon socket" 20 _at_socket
else
    echo "SKIP: daemon not running (atcmd_run returns empty when the daemon is down)"
fi

# The direct baseline needs the daemon stopped: its always-pending reader
# would steal the responses and every direct call would time out.
if systemctl is-active atcmd-daemon >/dev/null 2>&1; then
    systemctl stop atcmd-daemon
    avg_ms "--direct per-command open baseline" 20 _at_direct
    systemctl start atcmd-daemon
else
    avg_ms "--direct per-command open baseline" 20 _at_direct
fi

echo ""
echo "Interpretation: the daemon should win by the per-command port open"
echo "cost; if socket is not clearly faster, investigate."
