#!/bin/bash
# Does this modem ever put a call-progress terminator on the AT port?
#
# atcli treats BUSY / NO ANSWER / NO CARRIER / NO DIALTONE as ordinary
# terminators: whichever arrives first ends the reply and is taken as that
# command's answer. That is only safe while the port never emits one on its own,
# since an unsolicited one would cut a reply short and leave the port desynced.
# Measured 2026-08-05 on this device: 3 radio cycles produced 16 captured lines,
# all replies to this script's own commands. Re-run after a firmware or USB-mode
# change; if it ever fails, atcli needs to tell the two cases apart again.
#
# Run as root, from the LAN:
#   CONFIRM=yes /tmp/device-test-urc-terminators.sh
#
# DESTRUCTIVE. It stops atcmd-daemon (the UI fails closed meanwhile) and cycles
# the radio, so the device is off the network for roughly a minute per cycle.
# Do NOT run it over an SSH session carried by the cellular link: AT+CFUN=0
# drops that link and takes the terminal with it. Run it from the LAN, or
# detached:
#   CONFIRM=yes setsid /tmp/device-test-urc-terminators.sh \
#       </dev/null >/tmp/urc-test.out 2>&1 &
#
# Never AT+CFUN=1,1 anywhere below. On this device the reset parameter reboots
# Linux, not just the modem, so it would end the run rather than cycle it.
#
# atcli's own harness covers what the daemon DOES with such a line (AT+URCEND
# in the atcli repository's host harness, against a fake modem). Only the device can say
# whether one ever arrives.

set -u
PORT="${PORT:-/dev/smd11}"
UNIT="${UNIT:-atcmd-daemon}"
CYCLES="${CYCLES:-3}"
# Whole seconds: busybox sleep here may not take a fraction, and a rejected
# argument returns instantly, which would collapse every wait below.
IDLE_S="${IDLE_S:-20}"   # baseline with nothing provoked
OFF_S="${OFF_S:-20}"     # deregistered dwell
ON_S="${ON_S:-60}"       # time to find the network again

CAP=/tmp/urc-capture.log
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "PASS: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL: $1${2:+ ($2)}"; }
note() { echo "NOTE: $1"; }

[ "$(id -u)" = 0 ] || { echo "FATAL: run as root (port and systemctl)"; exit 1; }
[ -c "$PORT" ]     || { echo "FATAL: $PORT is not a character device"; exit 1; }
[ "${CONFIRM:-}" = yes ] || {
    echo "FATAL: this drops the network for ~$(( (OFF_S + ON_S) * CYCLES ))s."
    echo "       Re-run with CONFIRM=yes once you are not on the cellular link."
    exit 1
}

CATPID=""
# The radio must come back and the daemon must be serving even if this exits
# early, or the box is left deregistered with no AT access and no UI.
cleanup() {
    [ -n "$CATPID" ] && kill "$CATPID" 2>/dev/null
    printf 'AT+CFUN=1\r\n' > "$PORT" 2>/dev/null
    systemctl start "$UNIT" >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

systemctl stop "$UNIT" >/dev/null 2>&1
# The daemon's reader thread and this capture would race for the same bytes,
# so the port has to be ours alone for the run to see everything.
sleep 2

: > "$CAP"
cat "$PORT" >> "$CAP" &
CATPID=$!
sleep 1
kill -0 "$CATPID" 2>/dev/null || { echo "FATAL: capture died; is $PORT held?"; exit 1; }

note "capturing $PORT for $(( IDLE_S + (OFF_S + ON_S) * CYCLES ))s over $CYCLES cycle(s)"
sleep "$IDLE_S"

c=1
while [ "$c" -le "$CYCLES" ]; do
    note "cycle $c/$CYCLES: radio off"
    printf 'AT+CFUN=0\r\n' > "$PORT"
    sleep "$OFF_S"
    note "cycle $c/$CYCLES: radio on"
    printf 'AT+CFUN=1\r\n' > "$PORT"
    sleep "$ON_S"
    c=$((c + 1))
done

# Ask where we ended up, so the capture records whether the radio actually
# recovered rather than leaving that to be inferred.
printf 'AT+CEREG?\r\n' > "$PORT"
sleep 3

kill "$CATPID" 2>/dev/null
CATPID=""
systemctl start "$UNIT" >/dev/null 2>&1

# The modem frames with CRLF; strip the \r so the anchors below mean what they
# look like. The atcli client does the same before matching.
strip() { tr -d '\r' < "$CAP"; }

# Sanity gate first. A capture with none of our own OKs in it means the
# commands never landed and the whole run proved nothing - which would
# otherwise read as a clean pass.
oks=$(strip | grep -c '^OK$')
if [ "$oks" -ge "$((CYCLES * 2))" ]; then
    ok "port accepted all $((CYCLES * 2)) CFUN commands ($oks OK lines)"
else
    bad "port did not accept every CFUN command" "$oks OK lines, wanted >= $((CYCLES * 2))"
fi

# The measurement. Line-anchored, as atcli matches these at the start of a
# line: the same words inside a reply body are content, not terminators.
hits=$(strip | grep -cE '^(BUSY|NO ANSWER|NO CARRIER|NO DIALTONE)$')
if [ "$hits" -eq 0 ]; then
    ok "no call-progress terminator on $PORT across $CYCLES cycle(s)"
    note "atcli's flat terminator table holds on this device"
else
    bad "call-progress terminator seen on $PORT" "$hits line(s)"
    note "atcli must distinguish solicited terminators again; see its TERMINATORS"
    strip | grep -nE '^(BUSY|NO ANSWER|NO CARRIER|NO DIALTONE)$' | sed 's/^/      /'
fi

# Line types seen, whatever the verdict. NOT filtered to unsolicited ones: this
# script's own AT+CEREG? answer lands here too, so a keyword appearing once is
# as likely to be a reply as a URC. The total below is the reading that needs no
# such care - a capture holding only this script's traffic is a silent port.
note "line types seen (includes replies to this script's own commands):"
strip | grep -E '^(\+[A-Z0-9]+:|RDY|RING|POWERED DOWN)' \
      | sed 's/:.*/:/' | sort | uniq -c | sort -rn | sed 's/^/      /'
note "capture totals: $(wc -l < "$CAP") lines, $(wc -c < "$CAP") bytes for \
$((CYCLES * 2 + 1)) commands sent"
note "full capture kept at $CAP"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
