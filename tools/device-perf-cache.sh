#!/bin/bash
# Times the AT response cache and the batches behind it. Run as root:
#   /tmp/device-perf-cache.sh [iterations]
# Dev tool, not deployed; copy it to the device manually and delete it after.
#
# Read-only AT queries only. _CACHE_DIR is redirected at a scratch dir, so the
# live cache is neither read nor written. Correctness is device-test-cache.sh;
# this answers "what does it cost", and feeds tools/device-costs.md.
#
# Every figure here is BOOSTED-CLOCK: a tight loop holds the ondemand governor
# at 1805 MHz. A page polling every few seconds runs nearer the 345 MHz floor
# and is roughly 3.5x slower. Compare like with like.

set -u
LIB=/usrdata/quecdeck/script/cgi-lib.sh
[ -f "$LIB" ] || { echo "FATAL: $LIB missing"; exit 1; }
. "$LIB" 2>/dev/null

N_CHEAP=${1:-200}     # fork-free shell work
N_AT=20               # anything that reaches the modem

D=/tmp/qdperfcache.$$
_CACHE_DIR=$D/cache
mkdir -p "$_CACHE_DIR" || exit 1
trap 'rm -rf "$D"' EXIT

now_cs() { read -r u _ < /proc/uptime; echo "${u%.*}${u#*.}"; }

# Prints microseconds per call. Warms once so the first-call cost of a cold
# page cache does not land in the average.
bench() {
    local label=$1 n=$2; shift 2
    "$@" >/dev/null 2>&1
    local t0 t1 i=0
    t0=$(now_cs)
    while [ "$i" -lt "$n" ]; do "$@" >/dev/null 2>&1; i=$((i + 1)); done
    t1=$(now_cs)
    printf '  %-40s %7s us\n' "$label" "$(( (t1 - t0) * 10 * 1000 / n ))"
}

STATS='AT+QTEMP;+QENG="servingcell";+QCAINFO;+CSQ;+QGDNRCNT?;+QGDCNT?;+QUIMSLOT?;+QSPN;+QSIMSTAT?'
CONN='AT+QMAP="WWANIP";+CGCONTRDP'
SIM='AT+CIMI;+ICCID;+CNUM'

echo "iterations: $N_CHEAP cheap, $N_AT AT; governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
echo

echo "--- shell primitives on the read path (no modem)"
F=$_CACHE_DIR/bench
cache_write "$F" "$(printf '+QTEMP: 42\n+CSQ: 20,99\nOK')"
bench "_cache_load (one open, no fork)"   "$N_CHEAP" _cache_load "$F"
bench "cache_is_fresh (load + age)"       "$N_CHEAP" cache_is_fresh "$F" 3600
bench "cache_read (load + emit)"          "$N_CHEAP" cache_read "$F"
bench "cache_write (temp + mv)"           "$N_CHEAP" cache_write "$F" "payload"
bench "_epoch_now"                        "$N_CHEAP" _epoch_now
# What the cache replaced, for scale.
f_stat() { m=$(stat -c %Y "$F"); }
f_subst() { c=$(<"$F"); }
bench "stat -c %Y (removed from this path)" "$N_CHEAP" f_stat
bench "c=\$(<file) (removed from this path)" "$N_CHEAP" f_subst

echo
echo "--- AT batches, no cache wrapper"
bench "AT+CSQ (1 command)"                "$N_AT" atcmd_run 'AT+CSQ' 2000
bench "device_sim (3 commands)"           "$N_AT" atcmd_run "$SIM" 2000
bench "modem_conn (2 commands)"           "$N_AT" atcmd_run "$CONN" 2000
bench "modem_stats (9 commands)"          "$N_AT" atcmd_run "$STATS" 2000

echo
echo "--- cache_get_or_fetch, hit against miss"
# HIT: a long ttl over a warm file, so it never reaches the modem.
cache_write "$_CACHE_DIR/hit" "$(atcmd_run "$STATS" 2000)"
bench "modem_stats HIT (ttl 3600)"        "$N_CHEAP" \
      cache_get_or_fetch "$_CACHE_DIR/hit" 3600 "$STATS" 2000
# MISS: ttl 0 forces a fetch every call, which is also what the dashboard does
# at ttl 2 against a 3 s poll.
bench "modem_stats MISS (ttl 0)"          "$N_AT" \
      cache_get_or_fetch "$_CACHE_DIR/miss" 0 "$STATS" 2000
bench "modem_conn MISS (ttl 0)"           "$N_AT" \
      cache_get_or_fetch "$_CACHE_DIR/miss2" 0 "$CONN" 2000

echo
echo "A dashboard poll is modem_stats + modem_conn. At ttl 2 with a 3 s poll"
echo "every one is a miss; the HIT figure is what a second concurrent reader"
echo "in the same tick costs instead."
