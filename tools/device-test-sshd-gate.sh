#!/bin/sh
# sshd firewall-gate verification. Exercises the ExecStartPre gate added to
# sshd.service (sshd must never bind port 22 while the firewall is not
# active) and its recovery loop:
#
#   1. Loaded sshd unit carries the gate and RestartSec=10 (read-only).
#   2. Happy path: firewall active -> sshd starts and listens on 22.
#   3. Gate: with the firewall failed (stubbed script), `systemctl start
#      sshd` fails and NOTHING listens on 22.
#   4. Recovery: restore the firewall; it self-heals (Restart=on-failure),
#      then sshd's own retry loop brings sshd up with no manual start.
#   5. Session survival: a normal `systemctl restart firewall` leaves the
#      running sshd untouched (same MainPID) -- the reason the gate is an
#      ExecStartPre and not Requires=.
#
# Run as root with QuecDeck AND the NEW sshd.service installed:
#
#     sh device-test-sshd-gate.sh        # prompts before disrupting
#     sh device-test-sshd-gate.sh -y     # skip the prompt
#
# DISRUPTIVE: stubs the firewall like device-test-firewall-failclosed.sh,
# so the web UI is down for up to ~60s mid-test, and sshd is stopped and
# started. Active SSH sessions will drop in checks 3-4 (run from adb, not
# ssh). Everything is restored on exit (including Ctrl-C) by an EXIT trap.

FW_SCRIPT=/usrdata/quecdeck/script/firewall.sh
DIR=/tmp/quecdeck-sshdgate

YES=0
case "$1" in -y|--yes) YES=1 ;; esac

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

port22_listening() { netstat -tln 2>/dev/null | grep -q ':22 '; }

wait_state() {
    _ws_u="$1"; _ws_want="$2"; _ws_t="${3:-15}"; _ws_i=0
    while [ "$_ws_i" -lt "$_ws_t" ]; do
        _ws_s=$(systemctl is-active "$_ws_u" 2>/dev/null)
        if [ "$_ws_want" = "active" ]; then
            [ "$_ws_s" = "active" ] && return 0
        else
            [ "$_ws_s" != "active" ] && [ "$_ws_s" != "activating" ] && return 0
        fi
        sleep 1; _ws_i=$((_ws_i+1))
    done
    return 1
}

STUBBED=0
SSHD_WAS_ACTIVE=0
restore() {
    if [ "$STUBBED" = "1" ] && [ -f "$DIR/firewall.sh.bak" ]; then
        cat "$DIR/firewall.sh.bak" > "$FW_SCRIPT"
        chown root:root "$FW_SCRIPT"; chmod 700 "$FW_SCRIPT"
        STUBBED=0
    fi
    systemctl reset-failed firewall lighttpd sshd >/dev/null 2>&1
    systemctl start lighttpd >/dev/null 2>&1
    systemctl start firewall >/dev/null 2>&1
    if [ "$SSHD_WAS_ACTIVE" = "1" ]; then
        systemctl start sshd >/dev/null 2>&1
    else
        systemctl stop sshd >/dev/null 2>&1
    fi
    rm -rf "$DIR"
}

echo "=================================================================="
echo " QuecDeck sshd firewall-gate test"
echo "=================================================================="

# ---- preflight ----------------------------------------------------------
[ "$(id -u)" = "0" ] || { echo "FATAL: run as root."; exit 1; }
[ -f /lib/systemd/system/sshd.service ] || { echo "FATAL: sshd.service not installed -- install SSH first."; exit 1; }
[ -f "$FW_SCRIPT" ] || { echo "FATAL: $FW_SCRIPT missing -- is QuecDeck installed?"; exit 1; }
mkdir -p "$DIR"
systemctl is-active sshd >/dev/null 2>&1 && SSHD_WAS_ACTIVE=1

# ---- Check 1: loaded unit carries the gate (read-only) ------------------
echo ""
echo "[Check 1] loaded sshd unit has the firewall gate and paced restarts"
if systemctl show sshd -p ExecStartPre 2>/dev/null | grep -q 'is-active firewall'; then
    ok "ExecStartPre firewall gate present in the loaded unit"
else
    bad "no firewall gate in the loaded sshd unit -- pushed the new sshd.service and daemon-reload'ed?"
fi
_rsec=$(systemctl show sshd -p RestartUSec 2>/dev/null | cut -d= -f2)
[ "$_rsec" = "10s" ] && ok "RestartSec is 10s (retry loop stays under the start-rate limiter)" \
    || bad "RestartUSec is '$_rsec' (expected 10s); a fast loop can hit start-limit and never recover"

echo ""
echo "[Baseline] firewall and lighttpd active"
_base_ok=1
wait_state firewall active 5 && ok "firewall is active" || { bad "firewall not active"; _base_ok=0; }
wait_state lighttpd active 5 && ok "lighttpd is active" || { bad "lighttpd not active"; _base_ok=0; }
if [ "$_base_ok" != "1" ]; then
    echo ""
    echo "Baseline not healthy; skipping the disruptive checks."
    rm -rf "$DIR"
    [ "$fail" -eq 0 ] && exit 0 || exit 1
fi

if [ "$YES" != "1" ]; then
    echo ""
    printf 'Checks 2-5 stop/start sshd and break the firewall on purpose; the\n'
    printf 'web UI is down for up to ~60s and SSH sessions drop. Continue? [y/N] '
    read _ans
    case "$_ans" in y|Y|yes|YES) ;; *) echo "Aborted (read-only checks above still count)."; rm -rf "$DIR"; [ "$fail" -eq 0 ] && exit 0 || exit 1 ;; esac
fi
trap restore EXIT INT TERM

# ---- Check 2: happy path ------------------------------------------------
echo ""
echo "[Check 2] firewall active -> sshd starts and listens"
systemctl stop sshd >/dev/null 2>&1
systemctl reset-failed sshd >/dev/null 2>&1
if systemctl start sshd >/dev/null 2>&1 && wait_state sshd active 10; then
    # Type=simple counts as active the instant the process forks, which can
    # briefly precede sshd's own bind()/listen() (more so on its first-ever
    # start: host key/PAM setup). Give the socket a few seconds to appear
    # rather than checking once and racing it.
    _p22=0; _p22_i=0
    while [ "$_p22_i" -lt 5 ]; do
        port22_listening && { _p22=1; break; }
        sleep 1; _p22_i=$((_p22_i+1))
    done
    [ "$_p22" = "1" ] && ok "sshd started and port 22 is listening with the firewall up" \
        || bad "sshd active but port 22 never started listening within 5s"
else
    bad "sshd did not start cleanly with the firewall active"
fi

# ---- Check 3: gate blocks while the firewall is failed ------------------
echo ""
echo "[Check 3] failed firewall -> sshd start is refused, nothing on port 22"
systemctl stop sshd >/dev/null 2>&1
cat "$FW_SCRIPT" > "$DIR/firewall.sh.bak"
printf '#!/bin/bash\n# sshd-gate test stub\nexit 1\n' > "$FW_SCRIPT"
chown root:root "$FW_SCRIPT"; chmod 700 "$FW_SCRIPT"
STUBBED=1
systemctl restart firewall >/dev/null 2>&1
sleep 2
if systemctl start sshd >/dev/null 2>&1; then
    bad "sshd start SUCCEEDED with the firewall failed -- the gate did not hold"
else
    ok "sshd start refused while the firewall is failed"
fi
port22_listening && bad "something is listening on port 22 despite the gate" \
    || ok "nothing listening on port 22"

# ---- Check 4: automatic recovery ----------------------------------------
echo ""
echo "[Check 4] firewall restored -> firewall self-heals, then sshd follows"
cat "$DIR/firewall.sh.bak" > "$FW_SCRIPT"
chown root:root "$FW_SCRIPT"; chmod 700 "$FW_SCRIPT"
STUBBED=0
wait_state firewall active 40 && ok "firewall self-healed" \
    || bad "firewall did not return within 40s of the script being fixed"
if wait_state sshd active 30 && port22_listening; then
    ok "sshd recovered on its own via its retry loop (no manual start)"
else
    bad "sshd did not recover automatically within 30s of the firewall healing"
fi

# ---- Check 5: firewall restart leaves running sshd alone ----------------
echo ""
echo "[Check 5] a normal firewall restart does not touch the running sshd"
_pid_before=$(systemctl show sshd -p MainPID 2>/dev/null | cut -d= -f2)
systemctl restart firewall >/dev/null 2>&1
wait_state lighttpd active 20
_pid_after=$(systemctl show sshd -p MainPID 2>/dev/null | cut -d= -f2)
if [ -n "$_pid_before" ] && [ "$_pid_before" = "$_pid_after" ] && wait_state sshd active 5; then
    ok "sshd untouched by the firewall restart (MainPID $_pid_before unchanged; sessions survive)"
else
    bad "sshd was disturbed by the firewall restart (MainPID $_pid_before -> $_pid_after)"
fi

# ---- verdict ------------------------------------------------------------
echo ""
echo "=================================================================="
echo " Results: $pass passed, $fail failed"
echo "=================================================================="
if [ "$fail" -eq 0 ]; then
    echo " VERDICT: gate correct: sshd never binds without the firewall,"
    echo "          recovers on its own, and firewall restarts spare sessions."
else
    echo " VERDICT: failures above. State restored; sshd left as found."
fi
echo "=================================================================="
[ "$fail" -eq 0 ] && exit 0 || exit 1
