#!/bin/bash
# On-device verification of the AT response cache. Run as root:
#   /tmp/device-test-cache.sh
# Dev tool, not deployed; copy it to the device manually and delete it after.
#
# Sources the INSTALLED cgi-lib.sh but redirects _CACHE_DIR at a scratch dir,
# so the live cache is never read or written. Sends no AT commands except in
# the daemon-down section, which stops and restarts atcmd-daemon (the UI will
# see a brief gap; device-test-atclid.sh does the same).
#
# Covers what the host suite cannot:
#   1. Bash 3.2.57 and BusyBox actually run the constructs (read -d '',
#      ${var%%$'\n'*} patterns, mkdir -p -m, 64-bit arithmetic on the header).
#   2. The centisecond clock agrees with date(1) and is monotonic.
#   3. Freshness boundaries at the resolution the dashboard actually lands on.
#   4. A cache still serves when the AT daemon is down, which is the whole
#      point of keeping stale data.
#   5. Concurrent readers never see a torn file.

set -u
LIB=/usrdata/quecdeck/script/cgi-lib.sh
[ -f "$LIB" ] || { echo "FATAL: $LIB missing"; exit 1; }
. "$LIB" 2>/dev/null

pass=0; fail=0; skip=0
ok()   { pass=$((pass+1)); echo "PASS: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL: $1${2:+ ($2)}"; }
skp()  { skip=$((skip+1)); echo "SKIP: $1"; }
note() { echo "NOTE: $1"; }
t() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

D=/tmp/qdcachetest.$$
_CACHE_DIR=$D/cache
F=$_CACHE_DIR/c
mkdir -p "$D" || exit 1
# The daemon-down section below stops atcmd-daemon. Interrupting the script
# there would otherwise leave the device with no AT layer at all, so the restart
# belongs in the trap rather than only on the happy path.
_stopped_daemon=0
cleanup() {
    rm -rf "$D"
    if [ "$_stopped_daemon" -eq 1 ]; then
        echo "restarting atcmd-daemon (interrupted while it was stopped)"
        systemctl start atcmd-daemon
    fi
}
trap cleanup EXIT INT TERM

echo "bash $BASH_VERSION on $(uname -m)"
echo

# ---- the clock ---------------------------------------------------------------
echo "--- centisecond clock"
_epoch_now
t "_NOW is _NOW_CS floored" "$_NOW" "$(( _NOW_CS / 100 ))"
d=$(date +%s)
t "_epoch_now agrees with date(1)" "ok" \
  "$([ $((_NOW - d)) -ge -2 ] && [ $((_NOW - d)) -le 2 ] && echo ok || echo "off by $((_NOW - d))s")"
cs1=$_NOW_CS; _epoch_now
t "_NOW_CS is monotonic" "ok" \
  "$([ "$_NOW_CS" -ge "$cs1" ] && echo ok || echo "went back $((cs1 - _NOW_CS))cs")"
# The header is ~1.8e11, so a 32-bit shell would wrap it and every comparison
# below would be meaningless rather than merely wrong.
t "arithmetic is 64-bit" "2147483648" "$(( 2147483647 + 1 ))"
# If the fraction were always 00 the centisecond format would buy nothing.
i=0; frac=""
while [ $i -lt 40 ]; do _epoch_now; frac="$frac$(( _NOW_CS % 100 ))
"; i=$((i+1)); done
n=$(printf '%s' "$frac" | sort -u | wc -l | tr -d ' ')
t "the centisecond fraction is live" "ok" \
  "$([ "$n" -gt 1 ] && echo ok || echo "only $n distinct value")"

# ---- format ------------------------------------------------------------------
echo "--- file format"
payload='+QTEMP: 42
+CSQ: 20,99
OK'
cache_write "$F" "$payload"
t "cache_write/cache_read round trip" "$payload" "$(cache_read "$F")"
t "the dir was created 700" "700" "$(ls -ld "$_CACHE_DIR" | cut -c2-10 | \
    sed 's/rwx/7/g;s/r-x/5/g;s/---/0/g')"
_isnum() { case $1 in ''|*[!0-9]*) return 1 ;; esac; }
_cache_load "$F"
t "_cache_load splits the header" "ok" "$(_isnum "$_CACHE_TS" && echo ok || echo bad)"
t "_cache_load splits the payload" "$payload" "$_CACHE_PAYLOAD"
_epoch_now
t "the header is centiseconds, not seconds" "ok" \
  "$([ $((_NOW_CS - _CACHE_TS)) -ge 0 ] && [ $((_NOW_CS - _CACHE_TS)) -lt 500 ] \
     && echo ok || echo "age $((_NOW_CS - _CACHE_TS))cs")"

# ---- freshness boundaries ----------------------------------------------------
echo "--- freshness"
mk() { _epoch_now; printf '%s\n%s' "$(( _NOW_CS - $1 ))" "$payload" > "$F"; }
is_fresh() { _cache_load "$1" && _cache_ts_fresh "$2"; }
is_fresh "$F" 60; t "fresh right after write" "0" "$?"
is_fresh "$F" 0;  t "ttl 0 forces a miss"     "1" "$?"
# A 3 s dashboard poll reads ~290 cs old. That is fresh at ttl 3 (so the page
# would re-render the previous snapshot) and stale at ttl 2, which is the whole
# reason the TTL sits below the poll interval.
mk 290; is_fresh "$F" 3; t "290cs fresh at ttl 3" "0" "$?"
mk 290; is_fresh "$F" 2; t "290cs stale at ttl 2" "1" "$?"
mk 150; is_fresh "$F" 2; t "150cs fresh at ttl 2" "0" "$?"
mk -100000; is_fresh "$F" 10; t "a future header reads stale" "1" "$?"
printf '+QTEMP: 42\nOK' > "$F"
is_fresh "$F" 10; t "a headerless file reads stale" "1" "$?"
t "and yields no payload" "" "$(cache_read "$F" 2>/dev/null)"
cache_read "$D/nosuch" 2>/dev/null; t "cache_read on a missing file" "1" "$?"

# ---- serving when the modem cannot be reached --------------------------------
# The reason stale data is kept at all. If this regresses, a daemon restart
# blanks every panel instead of showing slightly old values.
echo "--- daemon down"
if ! systemctl is-active atcmd-daemon >/dev/null 2>&1; then
    skp "atcmd-daemon not active, skipping the daemon-down section"
else
    cache_write "$D/cache/live" "$(printf '+X: from-cache\nOK')"
    systemctl stop atcmd-daemon
    _stopped_daemon=1
    sleep 1
    got=$(cache_get_or_fetch "$D/cache/live" 0 'AT+CSQ' 2000)
    t "a stale cache still serves with the daemon down" \
      "$(printf '+X: from-cache\nOK')" "$got"
    got2=$(cache_get_or_fetch "$D/cache/absent" 0 'AT+CSQ' 2000)
    t "and no cache yields nothing, not a partial" "" "$got2"
    systemctl start atcmd-daemon
    _stopped_daemon=0
    i=0
    while [ $i -lt 15 ]; do
        [ -S "${_ATCLI_SOCK:-/tmp/quecdeck/atcli.sock}" ] && break
        sleep 1; i=$((i+1))
    done
    if systemctl is-active atcmd-daemon >/dev/null 2>&1; then
        ok "daemon restarted after the test"
    else
        bad "daemon restarted after the test" "still not active"
    fi
fi

# ---- concurrent readers ------------------------------------------------------
# cache_get_or_fetch takes no lock by design. The mv(2) operation is atomic within a
# filesystem, so a reader sees the old file or the new one, never a splice.
# This hammers that: writers churn while readers assert every read is a
# complete payload.
echo "--- concurrency"
CF=$D/cache/race
cache_write "$CF" "$payload"
( i=0; while [ $i -lt 60 ]; do cache_write "$CF" "$payload"; i=$((i+1)); done ) &
wpid=$!
torn=0; reads=0
while kill -0 "$wpid" 2>/dev/null; do
    got=$(cache_read "$CF" 2>/dev/null)
    reads=$((reads + 1))
    [ -n "$got" ] && [ "$got" != "$payload" ] && torn=$((torn + 1))
done
wait "$wpid" 2>/dev/null
t "no torn read across $reads concurrent reads" "0" "$torn"

echo
echo "pass=$pass fail=$fail skip=$skip"
[ "$fail" -eq 0 ]
