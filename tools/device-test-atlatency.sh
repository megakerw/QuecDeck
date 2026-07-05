#!/bin/bash
# On-device latency measurement for the AT queue path. Run as root:
#   /tmp/device-test-atlatency.sh
# Dev tool, not deployed; copy to the device manually. Read-only: sends only
# the no-op 'AT' command, touches nothing.
#
# Measures (a) the awk fork _atq_uptime currently costs per call, (b) the
# proposed builtin-read replacement, (c) end-to-end atcmd_run round trips,
# (d) atcli_direct as the no-queue baseline. Timing uses /proc/uptime
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

_uptime_awk()     { awk '{print int($1)}' /proc/uptime; }
_uptime_builtin() { local u; read -r u _ < /proc/uptime; echo "${u%%.*}"; }
_at_queued()      { atcmd_run 'AT' 2000; }
_at_direct()      { atcli_direct 'AT' 2000; }

echo "--- fork cost: _atq_uptime implementations"
avg_ms "awk fork (current)" 50 _uptime_awk;     awk_t=$_last_tenths
avg_ms "builtin read"       50 _uptime_builtin; blt_t=$_last_tenths
delta=$(( (awk_t - blt_t) * 2 ))
echo "=> added latency per queued AT command (2 calls): $(( delta / 10 )).$(( delta % 10 )) ms"

echo ""
echo "--- end-to-end round trips (no-op 'AT' command)"
if [ -p /tmp/quecdeck/atcmd.notify ]; then
    avg_ms "atcmd_run via queue" 10 _at_queued
else
    echo "SKIP: queue daemon not running (atcmd_run would fall back to direct)"
fi
avg_ms "atcli_direct baseline" 10 _at_direct

echo ""
echo "Interpretation: queue overhead = queued minus direct; the awk delta"
echo "above is the share the deadline change added and a builtin read removes."
