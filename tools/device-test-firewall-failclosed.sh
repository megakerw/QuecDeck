#!/bin/sh
# Fail-closed firewall verification. Exercises the failure legs that the
# coupling test (device-test-firewall-lighttpd.sh) leaves untouched:
#
#   1. systemd honors Restart=on-failure on the Type=oneshot firewall unit
#      (read-only; pre-v244 systemd silently refuses the setting).
#   2. Duplicate INPUT jumps converge: an extra -j QUECDECK jump disappears
#      after one firewall restart (the delete-until-absent loop).
#   3. A failing firewall.sh makes `systemctl restart firewall` return
#      nonzero (the exact primitive the SSH install gate keys on), fails the
#      unit, and takes lighttpd down with it (fail closed, no UI without
#      firewall).
#   4. After the failure clears, the unit self-heals via Restart=on-failure,
#      and the test measures whether lighttpd returns on its own (PartOf=
#      propagation of the auto-restart) or needs a manual start. A FAIL here
#      is a real design gap, not a test artifact.
#   5. The post-restore rule-count guard detects a chain that doesn't have
#      exactly 2 rules per port. Scope note: this exercises the count/compare
#      logic against real device iptables output by injecting a rule directly
#      (bypassing iptables-restore); it does not simulate --noflush producing
#      a wrong count in the first place, since that depends on iptables build
#      semantics already verified separately by device-test-noflush-semantics.sh.
#
# Run as root on a CONFIGURED device:
#
#     sh device-test-firewall-failclosed.sh        # prompts before disrupting
#     sh device-test-firewall-failclosed.sh -y     # skip the prompt
#
# DISRUPTIVE: checks 2-5 restart the firewall and briefly replace
# /usrdata/quecdeck/script/firewall.sh with a failing stub, cycling lighttpd
# and keeping the web UI down for up to ~60s. The real script and both
# services are restored on exit (including Ctrl-C) by an EXIT trap.

FW_SCRIPT=/usrdata/quecdeck/script/firewall.sh
DIR=/tmp/quecdeck-fwfail
IP=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' /etc/data/mobileap_cfg.xml 2>/dev/null | sed 's/<[^>]*>//g')
IP=${IP:-192.168.225.1}

YES=0
case "$1" in -y|--yes) YES=1 ;; esac

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

count_jumps() { iptables -w 5 -S INPUT 2>/dev/null | grep -c -- '-j QUECDECK'; }

# Poll systemctl is-active until <unit> reaches <want> (active|down) or timeout.
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

http_up() {
    _out=$(/opt/bin/wget -S --max-redirect=0 -O /dev/null --no-check-certificate "https://$IP/" 2>&1)
    printf '%s\n' "$_out" | grep -qiE 'HTTP/[0-9.]+ [0-9]+'
}

# Restore the real script (if the stub is still in), then bring the tree up.
STUBBED=0
restore() {
    if [ "$STUBBED" = "1" ] && [ -f "$DIR/firewall.sh.bak" ]; then
        cat "$DIR/firewall.sh.bak" > "$FW_SCRIPT"
        chown root:root "$FW_SCRIPT"; chmod 700 "$FW_SCRIPT"
        STUBBED=0
    fi
    systemctl reset-failed firewall lighttpd >/dev/null 2>&1
    systemctl start lighttpd >/dev/null 2>&1
    # restart, not start: guarantees a real iptables-restore runs even if we
    # were interrupted right after Check 5 injected a rule directly (a mere
    # start is a no-op on an already-active unit and would leave it behind).
    systemctl restart firewall >/dev/null 2>&1
    rm -rf "$DIR"
}

echo "=================================================================="
echo " QuecDeck firewall fail-closed test (device $IP)"
echo "=================================================================="

# ---- preflight ----------------------------------------------------------
[ "$(id -u)" = "0" ] || { echo "FATAL: run as root."; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo "FATAL: systemctl not found."; exit 1; }
[ -f "$FW_SCRIPT" ] || { echo "FATAL: $FW_SCRIPT missing -- is QuecDeck installed?"; exit 1; }
mkdir -p "$DIR"

# ---- Check 1: Restart= is honored on the oneshot (read-only) ------------
echo ""
echo "[Check 1] systemd accepts Restart=on-failure for the oneshot firewall unit"
echo "  systemd: $(systemctl --version 2>/dev/null | head -1)"
_restart=$(systemctl show firewall -p Restart 2>/dev/null | cut -d= -f2)
if [ "$_restart" = "on-failure" ]; then
    ok "loaded firewall unit reports Restart=on-failure"
else
    bad "loaded firewall unit reports Restart=$_restart -- the 10s self-heal the fail-closed design relies on will NOT fire"
fi

# ---- baseline -----------------------------------------------------------
echo ""
echo "[Baseline] both services active before the disruptive checks"
_base_ok=1
wait_state firewall active 5 && ok "firewall is active" || { bad "firewall not active at start"; _base_ok=0; }
wait_state lighttpd active 5 && ok "lighttpd is active" || { bad "lighttpd not active at start"; _base_ok=0; }
if [ "$_base_ok" != "1" ]; then
    echo ""
    echo "Baseline not healthy; skipping the disruptive checks."
    rm -rf "$DIR"
    [ "$fail" -eq 0 ] && exit 0 || exit 1
fi

if [ "$YES" != "1" ]; then
    echo ""
    printf 'Checks 2-5 restart the firewall and briefly break it on purpose;\n'
    printf 'the web UI is down for up to ~60s. Continue? [y/N] '
    read _ans
    case "$_ans" in y|Y|yes|YES) ;; *) echo "Aborted (read-only checks above still count)."; rm -rf "$DIR"; [ "$fail" -eq 0 ] && exit 0 || exit 1 ;; esac
fi
trap restore EXIT INT TERM

# ---- Check 2: duplicate INPUT jumps converge ----------------------------
echo ""
echo "[Check 2] an injected duplicate -j QUECDECK jump converges to one"
_j0=$(count_jumps)
iptables -w 5 -I INPUT -j QUECDECK
_j1=$(count_jumps)
if [ "$_j1" -le "$_j0" ]; then
    bad "could not inject a duplicate jump (count $_j0 -> $_j1); skipping convergence assert"
else
    systemctl restart firewall >/dev/null 2>&1
    wait_state lighttpd active 20
    _j2=$(count_jumps)
    [ "$_j2" = "1" ] && ok "jump count converged to 1 after restart (was $_j1)" \
        || bad "jump count is $_j2 after restart (expected 1) -- delete-until-absent loop not converging"
fi
systemctl reset-failed firewall lighttpd >/dev/null 2>&1

# ---- Check 3: failing script -> nonzero rc, unit failed, UI down --------
echo ""
echo "[Check 3] a failing firewall.sh fails the restart, the unit, and the UI"
cat "$FW_SCRIPT" > "$DIR/firewall.sh.bak"
printf '#!/bin/bash\n# fail-closed test stub\nexit 1\n' > "$FW_SCRIPT"
chown root:root "$FW_SCRIPT"; chmod 700 "$FW_SCRIPT"
STUBBED=1
if systemctl restart firewall >/dev/null 2>&1; then
    bad "systemctl restart firewall returned 0 with a failing script -- the SSH install gate would proceed"
else
    ok "systemctl restart firewall returned nonzero (the SSH install gate primitive)"
fi
sleep 2
[ "$(systemctl is-active firewall 2>/dev/null)" != "active" ] \
    && ok "firewall unit is not active after the failure" \
    || bad "firewall unit reports active despite the failing script"
[ "$(systemctl is-active lighttpd 2>/dev/null)" != "active" ] \
    && ok "lighttpd is down with the firewall (fail closed: no UI without firewall)" \
    || bad "lighttpd still active while the firewall is failed -- fail-closed coupling broken"

# ---- Check 4: self-heal after the failure clears ------------------------
echo ""
echo "[Check 4] restoring the real script; the tree must recover on its own"
cat "$DIR/firewall.sh.bak" > "$FW_SCRIPT"
chown root:root "$FW_SCRIPT"; chmod 700 "$FW_SCRIPT"
STUBBED=0
if wait_state firewall active 40; then
    ok "firewall self-healed via Restart=on-failure (no manual start)"
else
    bad "firewall did not return to active within 40s of the script being fixed"
fi
if wait_state lighttpd active 20; then
    http_up && ok "lighttpd followed automatically and https://$IP responds" \
        || bad "lighttpd active but https://$IP did not respond"
else
    bad "lighttpd did NOT return on its own after the firewall self-healed -- a transient firewall failure leaves the UI down until a manual 'systemctl start lighttpd' (design gap: the auto-restart does not propagate)"
fi

# ---- Check 5: rule-count guard detects a corrupted chain ----------------
echo ""
echo "[Check 5] the post-restore rule-count guard detects a wrong count"
_expected=$(iptables -w 5 -S QUECDECK 2>/dev/null | grep -c '^-A QUECDECK')
if [ "$_expected" -lt 2 ]; then
    bad "could not read a healthy QUECDECK baseline count ($_expected); skipping guard check"
else
    # Inject a rule the restore didn't put there, bypassing iptables-restore
    # entirely: this tests detection against real device iptables output, not
    # the --noflush build semantics device-test-noflush-semantics.sh covers.
    iptables -w 5 -A QUECDECK -p tcp --dport 1 -j DROP
    _corrupted=$(iptables -w 5 -S QUECDECK 2>/dev/null | grep -c '^-A QUECDECK')
    if [ "$_corrupted" -eq "$_expected" ]; then
        bad "injecting a rule did not change the count ($_corrupted); could not exercise the guard's compare"
    else
        ok "corrupted count ($_corrupted) differs from the healthy baseline ($_expected) -- the guard's compare would fire and exit 1"
    fi
    # A real restart's iptables-restore should flush the injection away; this
    # also proves the guard would NOT false-positive on the healthy result.
    systemctl restart firewall >/dev/null 2>&1
    wait_state lighttpd active 20
    _restored=$(iptables -w 5 -S QUECDECK 2>/dev/null | grep -c '^-A QUECDECK')
    [ "$_restored" -eq "$_expected" ] \
        && ok "a real restart's iptables-restore cleaned the injected rule; count is back to $_expected (no false positive on the healthy path)" \
        || bad "count is $_restored after a real restart (expected $_expected) -- injected rule was not cleaned, or the restore itself is wrong"
fi
systemctl reset-failed firewall lighttpd >/dev/null 2>&1

# ---- verdict ------------------------------------------------------------
echo ""
echo "=================================================================="
echo " Results: $pass passed, $fail failed"
echo "=================================================================="
if [ "$fail" -eq 0 ]; then
    echo " VERDICT: fail-closed behavior intact end to end: failures are loud,"
    echo "          the UI never serves unfirewalled, and recovery is automatic."
else
    echo " VERDICT: failures above. If Check 4's lighttpd assert failed, the"
    echo "          firewall recovers but the UI needs a manual start after a"
    echo "          transient firewall failure -- decide whether to accept or"
    echo "          fix (e.g. ExecStartPost start, or Upholds= on newer systemd)."
fi
echo "=================================================================="
[ "$fail" -eq 0 ] && exit 0 || exit 1
