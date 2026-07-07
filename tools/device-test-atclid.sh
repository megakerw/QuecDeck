#!/bin/bash
# On-device verification of the atcli daemon (atcli --daemon, unit
# atcmd-daemon). Run as root:
#   /tmp/device-test-atclid.sh
# Dev tool, not deployed; copy it to the device manually. Sends only fast,
# read-only AT commands. The wire contract itself is covered by the atcli
# repo's harness; this checks what only the device can: SELinux domain
# pairings on the live socket, the privilege drop, and systemd wiring.

set -u
ATLIB=/usrdata/quecdeck/script/at-lib.sh
pass=0; fail=0; skip=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1${2:+ ($2)}"; }
skp() { skip=$((skip+1)); echo "SKIP: $1"; }

[ -f "$ATLIB" ] || { echo "FATAL: $ATLIB missing"; exit 1; }
. "$ATLIB"

# ---- pick a way to run shell as www-data (lighttpd's uid) ------------------
RUNNER=""
if systemd-run --uid=www-data --pipe --wait -q /bin/true >/dev/null 2>&1; then
    RUNNER=systemd
elif su www-data -s /bin/sh -c true >/dev/null 2>&1; then
    RUNNER=su
fi
as_www() {
    case "$RUNNER" in
        systemd) systemd-run --uid=www-data --pipe --wait -q /bin/bash -c "$1" 2>/dev/null ;;
        su)      su www-data -s /bin/bash -c "$1" ;;
        *)       return 99 ;;
    esac
}

# ---- preflight -------------------------------------------------------------
if systemctl is-active atcmd-daemon >/dev/null 2>&1; then
    ok "daemon unit active"
else
    bad "daemon unit active" "start atcmd-daemon first"; echo "aborting"; exit 1
fi

# ---- privilege drop and socket modes ---------------------------------------
daemon_pid=$(systemctl show -p MainPID --value atcmd-daemon)
if [ "$(stat -c %U "/proc/$daemon_pid" 2>/dev/null)" = "www-data" ]; then
    ok "daemon runs as www-data (dropped from root)"
else
    bad "daemon runs as www-data" "uid: $(stat -c %U "/proc/$daemon_pid" 2>/dev/null)"
fi
[ -S "$_ATCLI_SOCK" ] && ok "socket present" || bad "socket present" "$_ATCLI_SOCK"
mode=$(stat -c %a "$_ATCLI_SOCK" 2>/dev/null)
[ "$mode" = "660" ] && ok "socket mode 660" || bad "socket mode 660" "is $mode"
if [ -u "$_ATCLI" ]; then
    bad "binary not setuid (zero-setuid policy)" "$(stat -c %a "$_ATCLI")"
else
    ok "binary not setuid (zero-setuid policy)"
fi

# ---- root path (watchcat/scheduled_restart context) ------------------------
resp=$(atcmd_run 'AT+QGMR')
case "$resp" in
    *OK) ok "root atcmd_run round trip" ;;
    *)   bad "root atcmd_run round trip" "$resp" ;;
esac

status=$("$_ATCLI" --status -s "$_ATCLI_SOCK")
served0=$(printf '%s\n' "$status" | awk '$1 == "served" {print $2}')
case "$served0" in
    ''|*[!0-9]*) bad "STATUS served counter" "$status" ;;
    *)           ok  "STATUS served counter ($served0)" ;;
esac

# ---- www-data path (CGI context) -------------------------------------------
if [ -n "$RUNNER" ]; then
    resp=$(as_www ". $ATLIB; atcmd_run 'AT+QGMR'")
    case "$resp" in
        *OK) ok "www-data atcmd_run round trip (via $RUNNER)" ;;
        *)   bad "www-data atcmd_run round trip" "$resp" ;;
    esac
else
    skp "www-data round trip (no systemd-run/su runner)"
fi

# ---- detach ----------------------------------------------------------------
atcmd_fire 'AT'
sleep 1
served1=$("$_ATCLI" --status -s "$_ATCLI_SOCK" | awk '$1 == "served" {print $2}')
if [ -n "$served1" ] && [ "$served1" -gt "${served0:-0}" ]; then
    ok "detached command executed after client exit"
else
    bad "detached command executed" "served $served0 -> $served1"
fi

# ---- explicit --direct + no implicit fallback (daemon must be stopped: its
# reader thread and a --direct client would race for the same port's
# responses, so it has to be down for this section) --------------------------
systemctl stop atcmd-daemon
resp=$("$_ATCLI" --direct -t 3000 'AT' 2>/dev/null)
case "$resp" in
    *OK) ok "--direct with daemon stopped (root port access)" ;;
    *)   bad "--direct with daemon stopped" "$resp" ;;
esac
# No implicit fallback: a plain atcmd_run must NOT reach the modem when the
# daemon is down; it returns empty (matching the www-data experience).
resp=$(atcmd_run 'AT')
case "$resp" in
    '') ok "atcmd_run empty while daemon down (no implicit direct fallback)" ;;
    *)  bad "atcmd_run must not reach the modem without the daemon" "$resp" ;;
esac
systemctl start atcmd-daemon
sleep 2
if systemctl is-active atcmd-daemon >/dev/null 2>&1 && [ -S "$_ATCLI_SOCK" ]; then
    ok "daemon back up after direct-path test"
else
    bad "daemon back up after direct-path test"
fi

echo "----"
echo "PASS=$pass FAIL=$fail SKIP=$skip"
[ "$fail" -eq 0 ]
