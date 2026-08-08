#!/bin/sh
# SSH firewall verification. Confirms that installing/uninstalling SSH adds and
# removes the port-22 firewall rule correctly, keeps the firewall itself intact,
# and that the web server recovers afterward. The SSH flow restarts the firewall
# service, which cycles lighttpd with it via PartOf= (a deliberate, brief blip on
# a rare operation), so lighttpd's MainPID is EXPECTED to change -- what matters
# is that it comes back up.
#
# Run me THREE times, doing the menu action between runs (no arguments needed):
#
#   sh device-test-ssh-firewall.sh     # 1) BEFORE install -> saves a baseline
#   ... install SSH:   sh quecdeck.sh -> 3 -> install ...
#   sh device-test-ssh-firewall.sh     # 2) AFTER install  -> checks the add + recovery
#   ... uninstall SSH: sh quecdeck.sh -> 3 -> uninstall ...
#   sh device-test-ssh-firewall.sh     # 3) AFTER uninstall -> checks the removal + recovery
#
# Run as root on a device where QuecDeck (lighttpd + firewall) is up. It only
# reads iptables and systemd state; it never changes the firewall itself.

DIR=/tmp/quecdeck-sshfw

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# lighttpd is cycled by the firewall restart and may still be coming up when the
# checkpoint runs; poll briefly for it to be active again.
wait_lighttpd_up() { _w=0; while [ "$_w" -lt 8 ]; do systemctl is-active lighttpd >/dev/null 2>&1 && return 0; sleep 1; _w=$((_w+1)); done; return 1; }
lighttpd_pid() { systemctl show lighttpd -p MainPID 2>/dev/null | cut -d= -f2; }
count_jumps()  { iptables -S INPUT 2>/dev/null | grep -c -- '-j QUECDECK'; }
count_port22() { iptables -S QUECDECK 2>/dev/null | grep -cE -- '--dport 22( |$)'; }

# Write a labelled snapshot: lighttpd PID, INPUT->QUECDECK jump count, port-22
# rule count, then the full QUECDECK ruleset (for an exact baseline compare).
snapshot() {
    {
        echo "PID=$(lighttpd_pid)"
        echo "JUMPS=$(count_jumps)"
        echo "PORT22=$(count_port22)"
        echo "--RULES--"
        iptables -S QUECDECK 2>/dev/null
    } > "$1"
}
getval() { grep "^$2=" "$1" | cut -d= -f2; }
rules_of() { sed -n '/--RULES--/,$p' "$1"; }

[ "$(id -u)" = "0" ] || { echo "FATAL: run as root."; exit 1; }
command -v iptables >/dev/null 2>&1 || { echo "FATAL: iptables not found."; exit 1; }
mkdir -p "$DIR"

# ---- Stage 1: baseline --------------------------------------------------
if [ ! -f "$DIR/baseline" ]; then
    snapshot "$DIR/baseline"
    echo "=================================================================="
    echo " Stage 1/3: baseline captured (SSH should NOT be installed yet)"
    echo "=================================================================="
    echo "  lighttpd MainPID:          $(getval "$DIR/baseline" PID)"
    echo "  INPUT jumps to QUECDECK:   $(getval "$DIR/baseline" JUMPS)"
    echo "  port-22 rules in QUECDECK: $(getval "$DIR/baseline" PORT22)"
    [ "$(getval "$DIR/baseline" PORT22)" != "0" ] && \
        echo "  NOTE: a port-22 rule is already present -- is SSH already installed? Uninstall it first for a clean baseline."
    echo ""
    echo "Next: INSTALL SSH via the menu (sh quecdeck.sh -> 3 -> install), then run this again."
    exit 0
fi

# ---- Stage 2: after install ---------------------------------------------
if [ ! -f "$DIR/after_install" ]; then
    snapshot "$DIR/after_install"
    echo "=================================================================="
    echo " Stage 2/3: after SSH install (compared to baseline)"
    echo "=================================================================="
    b_pid=$(getval "$DIR/baseline" PID);   a_pid=$(getval "$DIR/after_install" PID)
    a_j=$(getval "$DIR/after_install" JUMPS)
    b_22=$(getval "$DIR/baseline" PORT22); a_22=$(getval "$DIR/after_install" PORT22)

    if [ "$a_22" -ge 2 ]; then
        ok "port-22 rules present after install ($a_22 in QUECDECK)"
    elif [ "$a_22" = "$b_22" ]; then
        bad "no port-22 rules added (still $a_22) -- did the SSH install actually complete?"
    else
        bad "expected 2 port-22 rules (ACCEPT+DROP), found $a_22"
    fi
    if wait_lighttpd_up; then
        ok "lighttpd is up after install (MainPID $b_pid -> $a_pid; cycled by the firewall restart and recovered)"
    else
        bad "lighttpd is NOT up after install -- it did not recover from the firewall restart"
    fi
    [ "$a_j" -ge 1 ] && ok "INPUT still jumps to QUECDECK -- firewall intact" \
        || bad "INPUT jump to QUECDECK is missing -- the firewall is DOWN"

    echo ""
    echo " Stage 2 result: $pass passed, $fail failed"
    echo "Next: UNINSTALL SSH via the menu (sh quecdeck.sh -> 3 -> uninstall), then run this again."
    exit 0
fi

# ---- Stage 3: after uninstall -------------------------------------------
snapshot "$DIR/after_uninstall"
echo "=================================================================="
echo " Stage 3/3: after SSH uninstall (compared to baseline)"
echo "=================================================================="
b_22=$(getval "$DIR/baseline" PORT22);      u_22=$(getval "$DIR/after_uninstall" PORT22)
i_pid=$(getval "$DIR/after_install" PID);   u_pid=$(getval "$DIR/after_uninstall" PID)
u_j=$(getval "$DIR/after_uninstall" JUMPS)

[ "$u_22" = "$b_22" ] && ok "port-22 rules removed -- back to baseline ($u_22)" \
    || bad "port-22 rules not cleaned up (found $u_22, baseline had $b_22)"
if wait_lighttpd_up; then
    ok "lighttpd is up after uninstall (MainPID $i_pid -> $u_pid; cycled by the firewall restart and recovered)"
else
    bad "lighttpd is NOT up after uninstall -- it did not recover from the firewall restart"
fi
[ "$u_j" -ge 1 ] && ok "INPUT still jumps to QUECDECK -- firewall intact" \
    || bad "INPUT jump to QUECDECK is missing -- the firewall is DOWN"

# The whole ruleset should be byte-identical to the baseline.
rules_of "$DIR/baseline" > "$DIR/b.rules"
rules_of "$DIR/after_uninstall" > "$DIR/u.rules"
if diff "$DIR/b.rules" "$DIR/u.rules" >/dev/null 2>&1; then
    ok "full QUECDECK ruleset identical to the baseline"
else
    bad "QUECDECK ruleset differs from baseline (run: diff $DIR/baseline $DIR/after_uninstall)"
fi

echo ""
echo "=================================================================="
echo " Verdict: $pass passed, $fail failed"
echo "=================================================================="
if [ "$fail" -eq 0 ]; then
    echo " SSH firewall behavior correct: the port-22 rule toggles cleanly, the"
    echo " firewall stays up, and the web UI recovers after the restart."
    rm -rf "$DIR"        # clean state for a fresh run next time
    exit 0
else
    echo " Failures above. State kept in $DIR for inspection; remove it to reset."
    exit 1
fi
