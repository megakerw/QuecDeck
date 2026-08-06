#!/bin/bash
# Pins the two caps that bound a chained AT line, both of which are currently
# recorded as approximations. Run as root:
#   /tmp/device-test-atcaps.sh
# Dev tool, not deployed; copy it to the device manually and delete it after.
#
# DELETES NOTHING and changes no modem state. Part A sends syntactically
# invalid commands, which the modem can only reject. Part B repeats +CGMM and
# +CSQ, both read-only.
#
# Part A: CMD_MAX drift check.
#   The atcli repo settles the rule (src/daemon.rs: cmd.len() > CMD_MAX, with
#   CMD_MAX 512), so 512 is sent and 513 is refused, which is what at-lib.sh's
#   _AT_CMD_MAX assumes. This part checks the DEPLOYED binary still behaves
#   that way, since at-lib.sh duplicates the constant with nothing to catch
#   drift and the vendored binary is prebuilt. The "malformed" counter
#   attributes each silence instead of leaving it to inference.
#
# Part B: what the cap near 80 commands actually counts.
#   Measured only with repeated +CGMM, where command count and response volume
#   rise together, so "80 commands" and "~1600 bytes of response" fit equally.
#   +CSQ answers ~11 bytes against +CGMM's ~20 and costs 5 chars per command
#   against 6, so it reaches a higher count inside CMD_MAX. If +CSQ stops near
#   80 too, the cap counts commands. If it runs well past, it does not.

set -u
ATLIB=/usrdata/quecdeck/script/at-lib.sh
[ -f "$ATLIB" ] || { echo "FATAL: $ATLIB missing"; exit 1; }
. "$ATLIB"

counter() { "$_ATCLI" --status -s "$_ATCLI_SOCK" 2>/dev/null | awk -v k="$1" '$1 == k {print $2}'; }

have_counter=1
[ -z "$(counter malformed)" ] && have_counter=0
[ "$have_counter" = "0" ] && echo "NOTE: no malformed counter available; silence cannot be attributed"

# ------------------------------------------------- Part A: exact CMD_MAX -----
# "AT" plus filler to an exact length. The modem rejects it, so a reply of any
# kind proves the line got past the daemon.
echo "--- Part A: exact CMD_MAX boundary (1-char steps)"
echo "len  reply      malformed  verdict"
last_ok=0
first_refused=0
len=500
while [ "$len" -le 525 ]; do
    pad=$(( len - 2 ))
    cmd="AT$(head -c "$pad" /dev/zero | tr '\0' C)"
    mal0=$(counter malformed); mal0=${mal0:-0}
    reply=$(atcmd_run "$cmd" 3000)
    mal1=$(counter malformed); mal1=${mal1:-0}
    d=$(( mal1 - mal0 ))
    if [ -n "$reply" ]; then
        verdict="reached the modem"
        last_ok="$len"
    elif [ "$d" -gt 0 ]; then
        verdict="REFUSED by the daemon"
        [ "$first_refused" = "0" ] && first_refused="$len"
    else
        verdict="silent, not counted (timeout?)"
    fi
    printf '%-4s %-10s %-10s %s\n' "$len" "${#reply}b" "+$d" "$verdict"
    len=$(( len + 1 ))
done
echo ""
echo "largest length that reached the modem: $last_ok"
echo "smallest length the daemon refused:    $first_refused"
if [ "$last_ok" -ge 512 ]; then
    echo "=> _AT_CMD_MAX=512 in at-lib.sh is SAFE (512 is accepted)"
else
    echo "=> _AT_CMD_MAX=512 is TOO HIGH. Set it to $last_ok in quecdeck/script/at-lib.sh"
fi

# ------------------------------- Part B: what the ~80 cap counts -------------
# Returns "<verdict> <reply_bytes>" for n repetitions of a token.
probe() {
    local tok="$1" n="$2" cmd="AT$1" i=1 reply verdict
    while [ "$i" -lt "$n" ]; do cmd="$cmd;$tok"; i=$((i+1)); done
    reply=$(atcmd_run "$cmd" 8000)
    case "$reply" in
        '')      verdict="SILENT" ;;
        *OK*)    verdict="OK" ;;
        *ERROR*) verdict="ERROR" ;;
        *)       verdict="SILENT" ;;
    esac
    printf '%s %s %s' "$verdict" "${#reply}" "${#cmd}"
}

echo ""
echo "--- Part B: single-command response sizes"
for tok in +CGMM +CSQ; do
    set -- $(probe "$tok" 1)
    echo "  $tok: $1, ${2}b reply"
done

# The unreplicated datum the whole "79 commands" claim rests on.
echo ""
echo "--- Part B: replicate the +CGMM boundary (5x each)"
for n in 79 80; do
    line=""
    i=0
    while [ "$i" -lt 5 ]; do
        set -- $(probe +CGMM "$n")
        line="$line $1(${2}b)"
        i=$((i+1))
    done
    printf '  n=%-3s %s\n' "$n" "$line"
done

# +CSQ is 5 chars per command, so n=99 is 496 chars, still inside CMD_MAX.
# If the cap counted commands at ~80, +CSQ would stop there too.
echo ""
echo "--- Part B: +CSQ, which reaches a higher count inside CMD_MAX"
for n in 40 79 80 90 99; do
    set -- $(probe +CSQ "$n")
    printf '  n=%-3s %-7s %5sb reply  %5s chars sent\n' "$n" "$1" "$2" "$3"
done

echo ""
echo "Read it like this: if +CSQ fails at 79-80 like +CGMM, the cap counts"
echo "COMMANDS. If +CSQ still answers at 99, it does not, and the +CGMM"
echo "boundary is about response volume instead."
echo ""
echo "Nothing was deleted. Remove this script from the device when done."
