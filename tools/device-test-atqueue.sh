#!/bin/bash
# On-device verification of the AT queue deadline protocol. Run as root:
#   /tmp/device-test-atqueue.sh
# Dev tool, not deployed; copy it to the device manually (safe: it does not
# touch at-lib/daemon files, so the restart-after-manual-copy rule does not
# apply). Takes ~15 s and sends only fast, read-only AT commands; the one
# heavy command injected (QSCAN) is pre-expired and must be SKIPPED, which
# is the behavior under test.

set -u
ATLIB=/usrdata/quecdeck/script/at-lib.sh
pass=0; fail=0; skip=0
ok()   { pass=$((pass+1)); echo "PASS: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL: $1${2:+ ($2)}"; }
skp()  { skip=$((skip+1)); echo "SKIP: $1"; }

[ -f "$ATLIB" ] || { echo "FATAL: $ATLIB missing"; exit 1; }

# ---- pick a way to run shell as www-data (queue is www-data's world) ------
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
    ok "daemon active"
else
    bad "daemon active" "start atcmd-daemon first"; echo "aborting"; exit 1
fi
daemon_pid=$(systemctl show -p MainPID --value atcmd-daemon)
[ -p /tmp/quecdeck/atcmd.notify ] && ok "notify fifo present" || bad "notify fifo present"

if [ -z "$RUNNER" ]; then
    skp "www-data tests: no systemd-run --uid or su available"
    echo "Manual fallback: send ATI from the web AT console (round-trip),"
    echo "then run a cell scan and confirm the dashboard repopulates within"
    echo "seconds of scan end (expiry)."
    exit 2
fi
echo "(www-data runner: $RUNNER)"

# ---- T1: round-trip through the 4-field protocol ---------------------------
out=$(as_www ". $ATLIB; atcmd_run 'AT+QGMR' 5000")
if [ -n "$out" ] && printf '%s' "$out" | grep -q "OK"; then
    ok "T1 round-trip (4-field send -> parse -> dispatch -> response)"
else
    bad "T1 round-trip" "got: '$(printf '%s' "$out" | head -1)'"
fi

# ---- T2: pre-expired heavy line is skipped, not executed -------------------
# Deadline 1 is uptime second one; if the daemon executed this QSCAN anyway,
# the follow-up command would block for minutes. Fast follow-up = skipped.
out=$(as_www ". $ATLIB
  printf '999_1_1\tAT+QSCAN=3,1\t215000\t1\n' > \"\$_ATCMD_NOTIFY\"
  start=\$SECONDS
  r=\$(atcmd_run 'AT+QGMR' 10000)
  echo \"ELAPSED=\$((SECONDS-start))\"
  printf '%s' \"\$r\" | grep -q OK && echo GOTOK")
elapsed=$(printf '%s' "$out" | grep -o 'ELAPSED=[0-9]*' | cut -d= -f2)
if printf '%s' "$out" | grep -q GOTOK && [ "${elapsed:-99}" -le 5 ]; then
    ok "T2 expired line skipped (follow-up answered in ${elapsed}s)"
else
    bad "T2 expired line skipped" "elapsed=${elapsed:-?}s, expected <=5"
fi

# ---- T3: concurrent clients all served (serialization intact) --------------
out=$(as_www ". $ATLIB
  for i in 1 2 3; do
    ( r=\$(atcmd_run 'AT+QGMR' 8000); printf '%s' \"\$r\" | grep -q OK && echo OK\$i ) &
  done
  wait")
n=$(printf '%s' "$out" | grep -c '^OK[123]$')
[ "$n" = "3" ] && ok "T3 three concurrent clients all served" \
               || bad "T3 concurrent clients" "$n/3 served"

# ---- T4: legacy 3-field client still dispatched (no deadline = no expiry) --
out=$(as_www "
  f=/tmp/quecdeck/queue/888_8_8.resp.fifo
  mkfifo \"\$f\" 2>/dev/null && exec 8<>\"\$f\" || { echo NOFIFO; exit 0; }
  printf '888_8_8\tAT+QGMR\t5000\n' > /tmp/quecdeck/atcmd.notify
  IFS= read -r -t 6 line <&8 && echo \"FIRST=\$line\"
  exec 8>&-; rm -f \"\$f\"")
if printf '%s' "$out" | grep -q '^FIRST='; then
    ok "T4 legacy 3-field line dispatched (backward compatible)"
else
    bad "T4 legacy 3-field line" "no response ($(printf '%s' "$out" | head -1))"
fi

# ---- T5: garbage lines neither execute nor kill the daemon -----------------
as_www "printf 'no-tabs-here\n' > /tmp/quecdeck/atcmd.notify
        printf '../evil\tAT+QGMR\t5000\t99999999\n' > /tmp/quecdeck/atcmd.notify" >/dev/null
out=$(as_www ". $ATLIB; atcmd_run 'AT+QGMR' 5000")
printf '%s' "$out" | grep -q OK && ok "T5 daemon survives malformed lines" \
                                || bad "T5 daemon survives malformed lines"

# ---- T6: root cannot write the queue (documents the atcli_direct rationale)
if printf 'x\n' > /tmp/quecdeck/atcmd.notify 2>/dev/null; then
    echo "NOTE: root CAN write the notify fifo on this build (atcli_direct"
    echo "      remains correct but the SELinux rationale comment overstates)"
else
    ok "T6 root write to queue blocked (atcli_direct rationale holds)"
fi

# ---- post: daemon unchanged, no leaked fifos --------------------------------
[ "$(systemctl show -p MainPID --value atcmd-daemon)" = "$daemon_pid" ] \
    && ok "daemon PID unchanged ($daemon_pid)" || bad "daemon PID changed (crashed and restarted?)"
leaks=$(find /tmp/quecdeck/queue -name '*.resp.fifo' 2>/dev/null | wc -l)
[ "$leaks" = "0" ] && ok "no leaked response fifos" || bad "leaked fifos" "$leaks left"

echo ""
echo "passed: $pass, failed: $fail, skipped: $skip"
[ "$fail" = "0" ] || exit 1
exit 0
