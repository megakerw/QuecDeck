#!/bin/bash
# Host-side integration test for the AT queue daemon: runs the real daemon
# and atcmd_run against a stub atcli, exercising the notify protocol end to
# end (dispatch, response routing, deadline expiry, malformed input).
# Linux only: needs real FIFO semantics, which Git Bash on Windows lacks.
# Covers the protocol logic; SELinux/systemd/www-data behavior stays on
# device (tools/device-test-atqueue.sh).

set -u
cd "$(dirname "$0")/.."

case "$(uname -s)" in Linux) ;; *) echo "SKIP: requires Linux FIFO semantics"; exit 0 ;; esac

pass=0; fail=0
t() { # t <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

WORK=$(mktemp -d)
DAEMON_PID=""
_teardown() {
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
    wait "$DAEMON_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap _teardown EXIT

# Stub atcli: canned \r\n responses keyed on the command, logs every dispatch
# so tests can assert what did (and did not) reach the "modem".
cat > "$WORK/atcli" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-t" ] && shift 2
echo "$1" >> "${0%/*}/dispatch.log"
case "$1" in
    AT+CSQ)  printf '+CSQ: 20,99\r\nOK\r\n' ;;
    AT+FAIL) printf '+CME ERROR: 3\r\n' ;;
    AT+HANG) sleep 2; printf 'OK\r\n' ;;
    *)       printf 'OK\r\n' ;;
esac
EOF
chmod +x "$WORK/atcli"

export _ATCLI="$WORK/atcli"
export _ATCMD_NOTIFY="$WORK/atcmd.notify"
export _ATCMD_QUEUE="$WORK/queue"

. quecdeck/script/at-lib.sh

# ------------------------------------------- fallback path (daemon down) ---
t "fallback hits atcli directly" $'+CSQ: 20,99\nOK' "$(atcmd_run AT+CSQ)"

# ------------------------------------------------------------ start daemon --
ATLIB="$PWD/quecdeck/script/at-lib.sh" bash quecdeck/script/atcmd_queue_daemon.sh &
DAEMON_PID=$!
for _ in $(seq 50); do [ -p "$_ATCMD_NOTIFY" ] && break; sleep 0.1; done
[ -p "$_ATCMD_NOTIFY" ] || { echo "FATAL: daemon did not create notify FIFO"; exit 1; }
: > "$WORK/dispatch.log"

# ------------------------------------------------------- queued dispatch ---
t "queued multi-line response" $'+CSQ: 20,99\nOK' "$(atcmd_run AT+CSQ)"
t "queued error response"      '+CME ERROR: 3'    "$(atcmd_run AT+FAIL)"
atcmd_run $'AT+GMI\tXX' >/dev/null
t "tabs stripped before notify" "AT+GMI XX" "$(tail -1 "$WORK/dispatch.log")"

# ---------------------------------------------------- deadline expiry ------
# Deadline 1 is always in the past; the daemon must skip it, not dispatch it.
printf 'expired\tAT+EXPIRED\t3000\t1\n' > "$_ATCMD_NOTIFY"
t "live command after expired one" $'+CSQ: 20,99\nOK' "$(atcmd_run AT+CSQ)"
grep -q 'AT+EXPIRED' "$WORK/dispatch.log" && dispatched=yes || dispatched=no
t "expired command never dispatched" "no" "$dispatched"

# ------------------------------------------------- malformed input ---------
printf 'no-tabs-at-all\n' > "$_ATCMD_NOTIFY"
printf '../evil\tAT+EVIL\t1000\t9999999999\n' > "$_ATCMD_NOTIFY"
t "daemon survives malformed lines" $'+CSQ: 20,99\nOK' "$(atcmd_run AT+CSQ)"
grep -q 'AT+EVIL' "$WORK/dispatch.log" && dispatched=yes || dispatched=no
t "bad-id command never dispatched" "no" "$dispatched"

# --------------------------------------------------- client timeout --------
# Stub sleeps past the 1s client timeout: empty response, client FIFO reaped.
t "slow response times out empty" "" "$(atcmd_run AT+HANG 1000)"
leftover=$(find "$_ATCMD_QUEUE" -name '*.resp.fifo' | wc -l)
t "no response FIFOs left behind" "0" "$leftover"

# --------------------------------------------------- daemon cleanup --------
kill -TERM "$DAEMON_PID"
wait "$DAEMON_PID" 2>/dev/null
DAEMON_PID=""
[ -p "$_ATCMD_NOTIFY" ] && cleaned=no || cleaned=yes
t "notify FIFO removed on TERM" "yes" "$cleaned"

# -------------------------------------------------------------- summary ----
echo ""
echo "atqueue tests: $((pass + fail)), passed: $pass, failed: $fail"
[ "$fail" = "0" ] || exit 1
exit 0
