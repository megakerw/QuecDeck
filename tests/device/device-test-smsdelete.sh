#!/bin/bash
# On-device probe for the SMS delete path. Run as root:
#   /tmp/device-test-smsdelete.sh
# Dev tool, not deployed; copy it to the device manually and delete it after.
#
# DELETES NOTHING. Every CMGD sent here names a slot ABOVE the capacity
# AT+CPMS? reports, so no message can occupy it. Do NOT lower those indices to
# "make the test more realistic": CMGD on an occupied slot erases it for real,
# and this inbox is the only test fixture.
#
# Settles what cgi-bin/delete_sms cannot show on its own:
#   1. Which storage the modem defaults to, since index numbering is per-store.
#   2. Does a chained command really abort at its first error, so one bad index
#      cancels every delete after it?
#   3. What does a long CMGD chain cost against the 10000 ms budget?
# The command-line caps live in device-test-atcaps.sh.

set -u
ATLIB=/usrdata/quecdeck/script/at-lib.sh
[ -f "$ATLIB" ] || { echo "FATAL: $ATLIB missing"; exit 1; }
. "$ATLIB"

pass=0; fail=0; skip=0
ok()   { pass=$((pass+1)); echo "PASS: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL: $1${2:+ ($2)}"; }
skp()  { skip=$((skip+1)); echo "SKIP: $1"; }
note() { echo "NOTE: $1"; }

# ------------------------------------------------- storage and safe slots ----
# The SET form answers +CPMS: <used1>,<total1>,<used2>,<total2>,<used3>,<total3>
# with NO store names; only the read form (AT+CPMS?) carries them. Capacity is
# therefore the SECOND field. Parsing it as if names were present captured
# <used2> instead, which on this device read 128 against a real capacity of 255
# and put every "safe" probe slot INSIDE the store. Nothing was lost, but the
# safety claim this whole script rests on was not true.
echo "--- storage"
cpms=$(atcmd_run 'AT+CPMS="ME","ME","ME"' 3000)
echo "$cpms" | grep '^+CPMS:' || note "no +CPMS line in the reply"
used=$(printf '%s' "$cpms" | sed -n 's/^+CPMS: *\([0-9][0-9]*\),.*/\1/p' | head -1)
total=$(printf '%s' "$cpms" | sed -n 's/^+CPMS: *[0-9][0-9]*,\([0-9][0-9]*\).*/\1/p' | head -1)
case "$total" in
    ''|*[!0-9]*) skp "could not read ME capacity - refusing to guess safe slots"
                 echo ""; echo "pass=$pass fail=$fail skip=$skip"; exit 1 ;;
esac
SAFE=$(( total + 100 ))
# Belt and braces: the probe slot must be past capacity, whatever the parse did.
if [ "$SAFE" -le "$total" ]; then
    bad "probe slot $SAFE is not above capacity $total - refusing to send CMGD"
    echo ""; echo "pass=$pass fail=$fail skip=$skip"; exit 1
fi
echo "ME store: ${used:-?} used of $total; probe slots start at $SAFE (past capacity)"

# What the modem currently thinks storage is, before anything sets it. If this
# is not ME, then delete_sms not setting CPMS was a live bug, not a theory.
echo ""
echo "--- storage the modem defaults to"
now=$(atcmd_run 'AT+CPMS?' 3000)
echo "$now" | grep '^+CPMS:'
case "$now" in
    *'"ME"'*) ok "CPMS reads ME here" ;;
    *)        note "CPMS is NOT ME - index numbering in delete_sms would not match get_sms" ;;
esac

# ------------------------------------------------------ abort on first error --
# Echo is on: the reply opens with the command itself, so AT lines are dropped
# or the "did the chain continue" test compares against the echo.
model=$(atcmd_run 'AT+CGMM' 3000 | grep -v '^AT' | grep -v '^OK$' | grep -v '^$' | head -1)
echo ""
echo "model line: ${model:-<none>}"
# Non-destructive abort test: put a guaranteed-bad CMGD first, then a read-only
# +CGMM. If the model line comes back, the chain continued past the error; if
# not, everything after the first bad index was discarded.
echo ""
echo "--- does a chain continue past a bad command?"
if [ -z "$model" ]; then
    skp "no model string to look for"
else
    reply=$(atcmd_run "AT+CMGD=${SAFE};+CGMM" 5000)
    printf 'reply: %s\n' "$(printf '%s' "$reply" | tr '\n' '|')"
    case "$reply" in
        *"$model"*) note "the chain CONTINUED past the bad index on this firmware" ;;
        *)          ok "the chain ABORTED at the bad index - one stale slot cancels every delete after it" ;;
    esac
fi

# A bad index must also be reported as an error rather than silently ignored.
echo ""
echo "--- a bad index is reported"
reply=$(atcmd_run "AT+CMGD=${SAFE}" 5000)
printf 'reply: %s\n' "$(printf '%s' "$reply" | tr '\n' '|')"
case "$reply" in
    *ERROR*) ok "CMGD on a non-existent slot answers ERROR" ;;
    *OK*)    note "CMGD on a non-existent slot answers OK - stale indices would pass silently" ;;
    *)       skp "no terminator" ;;
esac

# ---------------------------------------------------------------- timing ----
# All slots are past capacity, so this measures parse + reject cost, which is a
# floor for the real thing, not the flash-erase cost of a live delete.
echo ""
echo "--- wall time for chained CMGD (floor: these slots are empty)"
for n in 10 40 120; do
    cmd="AT+CMGD=${SAFE}"
    i=1
    while [ "$i" -lt "$n" ]; do cmd="$cmd;+CMGD=$(( SAFE + i ))"; i=$((i+1)); done
    start=$SECONDS
    reply=$(atcmd_run "$cmd" 20000)
    elapsed=$(( SECONDS - start ))
    case "$reply" in
        *OK*) t="OK" ;; *ERROR*) t="ERROR" ;; '') t="NO REPLY" ;; *) t="no terminator" ;;
    esac
    printf '  %3d chained CMGD (%4d chars): %ss, %s\n' "$n" "${#cmd}" "$elapsed" "$t"
done
note "a real delete also erases flash, so live timings run above these"

echo ""
echo "pass=$pass fail=$fail skip=$skip"
echo "Nothing was deleted. Remove this script from the device when done."
