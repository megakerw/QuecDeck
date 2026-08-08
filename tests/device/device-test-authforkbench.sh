#!/bin/bash
# A/B latency benchmark for the auth.lua setup-check fork removal. Runs on
# the DEV MACHINE (git bash / linux), not on the device: pushes each auth.lua
# variant over adb, then times unauthenticated keep-alive GETs of an exempt
# static asset. That is the cheapest path through auth.lua, so the
# per-request os.execute fork is the dominant difference between variants.
# Rounds alternate old/new to cancel drift. Requests per round must stay
# under lighttpd's max-keep-alive-requests (256) so a round is one TLS
# connection. Restores the device's original auth.lua on exit.
#
# Usage: device-test-authforkbench.sh [device_ip] [requests_per_round] [rounds]
# Defaults: 192.168.225.1, 100, 3.
# Old variant = v1.0.18's auth.lua (shell test as the only setup check);
# new variant = the working tree's quecdeck/auth.lua (lighty.c.stat, shell
# test kept only as fallback).

set -u

IP=${1:-192.168.225.1}
N=${2:-100}
ROUNDS=${3:-3}
DEVICE_FILE=/usrdata/quecdeck/auth.lua
URL="https://$IP/favicon.ico"

for c in adb curl git; do
    command -v "$c" >/dev/null || { echo "FATAL: $c not found"; exit 1; }
done

cd "$(git rev-parse --show-toplevel)" || exit 1

# Git bash on Windows rewrites arguments starting with "/" into Windows
# paths, mangling device paths passed to adb (a native exe). Scoped to adb:
# curl's -o /dev/null relies on that same conversion. Local paths handed to
# adb push must then be converted explicitly (native_path).
adb() { MSYS_NO_PATHCONV=1 command adb "$@"; }
native_path() {
    if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi
}

work=$(mktemp -d)
cp quecdeck/auth.lua "$work/new.lua"
git show v1.0.18:quecdeck/auth.lua > "$work/old.lua" || { echo "FATAL: cannot extract v1.0.18 auth.lua"; rm -rf "$work"; exit 1; }
# lighty.c.stat is the discriminator: present only in the new variant (the
# shell test appears in BOTH, as old main path and new fallback).
grep -q 'lighty\.c\.stat' "$work/new.lua" || { echo "FATAL: working-tree auth.lua lacks the lighty.c.stat change"; rm -rf "$work"; exit 1; }
grep -q 'lighty\.c\.stat' "$work/old.lua" && { echo "FATAL: v1.0.18 auth.lua already has the stat change (wrong baseline?)"; rm -rf "$work"; exit 1; }

adb shell "cp -p $DEVICE_FILE /tmp/auth.lua.bench.bak" || { echo "FATAL: cannot back up device auth.lua"; rm -rf "$work"; exit 1; }
restore() {
    adb shell "cp /tmp/auth.lua.bench.bak $DEVICE_FILE && chown root:root $DEVICE_FILE && chmod 644 $DEVICE_FILE && rm -f /tmp/auth.lua.bench.bak"
    rm -rf "$work"
}
trap restore EXIT

push_variant() {
    adb push "$(native_path "$1")" "$DEVICE_FILE" >/dev/null || return 1
    adb shell "chown root:root $DEVICE_FILE && chmod 644 $DEVICE_FILE" || return 1
    # Warm-up: triggers the mtime reload and primes the stat cache; the
    # response body check catches a variant that 500s (Lua error).
    local code
    code=$(curl -sk -o /dev/null -w '%{http_code}' "$URL")
    [ "$code" = "200" ] || { echo "FATAL: $URL returned $code after pushing $1"; return 1; }
    curl -sk -o /dev/null "$URL?w=[1-5]"
}

# One keep-alive burst; per-transfer total time in seconds, one per line.
measure() {
    curl -sk -o /dev/null -w '%{time_total}\n' "$URL?b=[1-$N]"
}

median_ms() { # file of seconds -> median in ms (one decimal)
    sort -n "$1" | awk '{a[NR]=$1} END {printf "%.1f", a[int((NR+1)/2)]*1000}'
}

echo "Benchmarking $URL, $ROUNDS rounds x $N requests per variant"
: > "$work/old.times"; : > "$work/new.times"
for r in $(seq 1 "$ROUNDS"); do
    for v in old new; do
        push_variant "$work/$v.lua" || exit 1
        measure > "$work/round.times" || exit 1
        cat "$work/round.times" >> "$work/$v.times"
        echo "round $r $v: median $(median_ms "$work/round.times") ms"
    done
done

echo ""
old_med=$(median_ms "$work/old.times")
new_med=$(median_ms "$work/new.times")
echo "overall old (os.execute): median $old_med ms"
echo "overall new (lighty.c.stat): median $new_med ms"
awk -v o="$old_med" -v n="$new_med" 'BEGIN {
    d = o - n
    printf "delta: %.1f ms/request\n", d
    if (d >= 2)       print "RESULT: WIN - fork removal is a clear per-request improvement."
    else if (d > -2)  print "RESULT: NO MEASURABLE DIFFERENCE - within noise."
    else              print "RESULT: REGRESSION?! new variant is slower; investigate."
}'
