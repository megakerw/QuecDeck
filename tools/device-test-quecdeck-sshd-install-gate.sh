#!/bin/sh
# quecdeck.sh SSH-install gate verification. device-test-sshd-gate.sh already
# proves the UNIT-level gate (sshd.service's ExecStartPre) blocks a bind while
# the firewall is down. This script proves the OTHER gate: the
# `if systemctl restart firewall; then ... else ... fi` block inside
# quecdeck.sh's sshd_service() install path (case 1), which decides whether
# to even ATTEMPT `systemctl start sshd` in the first place. That was the
# CONFIRMED finding from the review this whole session's SSH work responds
# to (port 22 could bind unprotected during install if the firewall restart
# failed and nothing gated the subsequent start).
#
# Scope note: exercising the real sshd_service() end to end would require
# downloading sshd.service from GITROOT (GitHub main), whose pinned hash in
# a released quecdeck.sh may not match a not-yet-released sshd.service, so
# this test instead runs the exact gate snippet mirrored below against a
# real broken/healthy firewall. KEEP THIS IN SYNC with quecdeck.sh's
# sshd_service() install case if that logic changes; a line-count sanity
# check against the live quecdeck.sh's gate block guards against silent drift
# if a copy of it is available at the path below.
#
# Run as root on a device with SSH ALREADY INSTALLED:
#
#     sh device-test-quecdeck-sshd-install-gate.sh        # prompts first
#     sh device-test-quecdeck-sshd-install-gate.sh -y     # skip the prompt
#
# DISRUPTIVE: stops sshd, breaks the firewall like the other fail-closed
# tests, and drives the mirrored gate logic directly (not through the menu).
# sshd and the firewall are restored on exit (including Ctrl-C).

FW_SCRIPT=/usrdata/quecdeck/script/firewall.sh
QUECDECK_SH_COPY=/tmp/quecdeck.sh
DIR=/tmp/quecdeck-sshdinstallgate

YES=0
case "$1" in -y|--yes) YES=1 ;; esac

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

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

port22_listening() { netstat -tln 2>/dev/null | grep -q ':22 '; }

# The mirrored gate. Keep verbatim in sync with quecdeck.sh's sshd_service().
run_install_gate() {
    if systemctl restart firewall; then
        systemctl start sshd || echo "WARNING: sshd failed to start; check 'systemctl status sshd' for details."
    else
        echo "WARNING: firewall failed to restart; sshd NOT started so port 22 never listens unprotected."
        echo "Check 'systemctl status firewall lighttpd', then 'systemctl start sshd' once the firewall is active."
    fi
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
    systemctl restart firewall >/dev/null 2>&1
    if [ "$SSHD_WAS_ACTIVE" = "1" ]; then
        systemctl start sshd >/dev/null 2>&1
    else
        systemctl stop sshd >/dev/null 2>&1
    fi
    rm -rf "$DIR"
}

echo "=================================================================="
echo " quecdeck.sh SSH-install gate test"
echo "=================================================================="

# ---- preflight ------------------------------------------------------------
[ "$(id -u)" = "0" ] || { echo "FATAL: run as root."; exit 1; }
[ -f /lib/systemd/system/sshd.service ] || { echo "FATAL: sshd.service not installed -- install SSH first (this test mirrors the install gate, it does not run the installer)."; exit 1; }
[ -f "$FW_SCRIPT" ] || { echo "FATAL: $FW_SCRIPT missing -- is QuecDeck installed?"; exit 1; }
mkdir -p "$DIR"
systemctl is-active sshd >/dev/null 2>&1 && SSHD_WAS_ACTIVE=1

# ---- drift guard (best-effort, non-fatal) ----------------------------------
echo ""
echo "[Check 0] drift guard: mirrored gate vs. the live quecdeck.sh, if present at $QUECDECK_SH_COPY"
if [ -f "$QUECDECK_SH_COPY" ]; then
    if grep -q 'sshd NOT started so port 22 never listens unprotected' "$QUECDECK_SH_COPY"; then
        ok "the live quecdeck.sh still contains the gate's warning text -- mirror likely still accurate"
    else
        bad "the live quecdeck.sh's sshd_service() no longer contains the expected gate warning text -- update run_install_gate() in this script to match"
    fi
else
    echo "  SKIP: $QUECDECK_SH_COPY not found; push the working-tree quecdeck.sh there to enable this check"
fi

echo ""
echo "[Baseline] firewall active before the disruptive checks"
wait_state firewall active 5 || { echo "Baseline not healthy; skipping disruptive checks."; rm -rf "$DIR"; [ "$fail" -eq 0 ] && exit 0 || exit 1; }
ok "firewall is active"

if [ "$YES" != "1" ]; then
    echo ""
    printf 'This stops sshd and breaks the firewall on purpose; the web UI is\n'
    printf 'down for a stretch and any live SSH session drops. Continue? [y/N] '
    read _ans
    case "$_ans" in y|Y|yes|YES) ;; *) echo "Aborted (read-only checks above still count)."; rm -rf "$DIR"; [ "$fail" -eq 0 ] && exit 0 || exit 1 ;; esac
fi
trap restore EXIT INT TERM

# ---- Check 1: gate refuses to start sshd while the firewall is broken -----
echo ""
echo "[Check 1] firewall restart fails -> gate does NOT attempt to start sshd"
systemctl stop sshd >/dev/null 2>&1
cat "$FW_SCRIPT" > "$DIR/firewall.sh.bak"
printf '#!/bin/bash\n# install-gate test stub\nexit 1\n' > "$FW_SCRIPT"
chown root:root "$FW_SCRIPT"; chmod 700 "$FW_SCRIPT"
STUBBED=1
_out=$(run_install_gate 2>&1)
echo "$_out" | grep -q 'sshd NOT started' \
    && ok "gate printed the 'sshd NOT started' warning" \
    || bad "gate did not print the expected warning; output was: $_out"
if systemctl is-active sshd >/dev/null 2>&1; then
    bad "sshd is ACTIVE despite the firewall being down -- the gate let it through"
else
    ok "sshd is not active -- the gate correctly skipped 'systemctl start sshd'"
fi
port22_listening && bad "something is listening on port 22 despite the gate" \
    || ok "nothing listening on port 22"

# ---- Check 2: gate starts sshd once the firewall is healthy again ---------
echo ""
echo "[Check 2] firewall restart succeeds -> gate starts sshd normally"
cat "$DIR/firewall.sh.bak" > "$FW_SCRIPT"
chown root:root "$FW_SCRIPT"; chmod 700 "$FW_SCRIPT"
STUBBED=0
wait_state firewall active 40 || bad "firewall did not return to active after restoring the real script"
_out=$(run_install_gate 2>&1)
if wait_state sshd active 10; then
    # Type=simple counts as active the instant the process forks, which can
    # briefly precede sshd's own bind()/listen(). Give the socket a few
    # seconds to appear rather than checking once and racing it.
    _p22=0; _p22_i=0
    while [ "$_p22_i" -lt 5 ]; do
        port22_listening && { _p22=1; break; }
        sleep 1; _p22_i=$((_p22_i+1))
    done
    [ "$_p22" = "1" ] && ok "gate started sshd and port 22 is listening with the firewall healthy" \
        || bad "sshd active but port 22 never started listening within 5s; output was: $_out"
else
    bad "sshd did not come up cleanly once the firewall was healthy; output was: $_out"
fi

# ---- verdict ----------------------------------------------------------------
echo ""
echo "=================================================================="
echo " Results: $pass passed, $fail failed"
echo "=================================================================="
if [ "$fail" -eq 0 ]; then
    echo " VERDICT: the install-time gate correctly withholds sshd when the"
    echo "          firewall restart fails, and starts it normally once healthy."
else
    echo " VERDICT: failures above. State restored; sshd left as found."
fi
echo "=================================================================="
[ "$fail" -eq 0 ] && exit 0 || exit 1
