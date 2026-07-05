#!/bin/bash
# On-device measurement of large-AT-response handling (SMS list). Run as root:
#   bash /tmp/device-test-smsresp.sh
# Dev tool, not deployed. Reads the SMS list once via raw atcli (bypassing
# the queue), then times the two \r-strip strategies on the real payload.

set -u
ATLIB=/usrdata/quecdeck/script/at-lib.sh
[ -f "$ATLIB" ] || { echo "FATAL: $ATLIB missing"; exit 1; }
. "$ATLIB"

now_cs() { local u; read -r u _ < /proc/uptime; echo "$(( ${u%.*} * 100 + 10#${u#*.} ))"; }

echo "--- raw atcli fetch of the full SMS list (8 s budget, bypasses queue)"
t0=$(now_cs)
raw=$(timeout 15 "$_ATCLI" -t 8000 'AT+CPMS="ME","ME","ME";+CMGF=1;+CSCS="UCS2";+CMGL="ALL"' 2>/dev/null)
t1=$(now_cs)
lines=$(printf '%s' "$raw" | wc -l)
echo "atcli time: $(( (t1 - t0) * 10 )) ms, response: ${#raw} bytes, $lines lines"
case "$raw" in *OK*) echo "terminator: OK present" ;; *) echo "terminator: NO OK (truncated at atcli level!)" ;; esac

echo ""
echo "--- \\r strip strategies on that payload"
echo "timing bash strip (may take a while, that is the point)..."
t0=$(now_cs)
s=${raw//$'\r'/}
t1=$(now_cs)
echo "bash \${var//} strip: $(( (t1 - t0) * 10 )) ms (${#s} bytes after)"

t0=$(now_cs)
s2=$(printf '%s' "$raw" | tr -d '\r')
t1=$(now_cs)
echo "tr fork strip:        $(( (t1 - t0) * 10 )) ms (${#s2} bytes after)"

echo ""
echo "--- surviving builtin patterns on the same payload (10 iterations each)"
. /usrdata/quecdeck/script/cgi-lib.sh 2>/dev/null
t0=$(now_cs)
for _ in 1 2 3 4 5 6 7 8 9 10; do at_response_ok "$s"; done
t1=$(now_cs)
echo "at_response_ok x10:   $(( (t1 - t0) * 10 )) ms total"

f=$(mktemp /tmp/smsresp.XXXXXX); printf '%s' "$s" > "$f"
t0=$(now_cs)
for _ in 1 2 3 4 5 6 7 8 9 10; do out=$(printf '%s' "$(<"$f")"); done
t1=$(now_cs)
echo "\$(<file) read x10:    $(( (t1 - t0) * 10 )) ms total (${#out} bytes)"
rm -f "$f"

echo ""
echo "--- end-to-end through the queue (as get_sms does, 3 s timeout)"
t0=$(now_cs)
resp=$(atcmd_run 'AT+CPMS="ME","ME","ME";+CMGF=1;+CSCS="UCS2";+CMGL="ALL"' 3000)
t1=$(now_cs)
echo "atcmd_run time: $(( (t1 - t0) * 10 )) ms, response: ${#resp} bytes"
case "$resp" in *OK) echo "queue result: complete" ;; '') echo "queue result: EMPTY (timeout or deadline skip)" ;; *) echo "queue result: TRUNCATED" ;; esac
