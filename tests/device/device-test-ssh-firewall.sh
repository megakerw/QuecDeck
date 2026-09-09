#!/bin/sh
# SSH firewall verification. Confirms that installing and uninstalling SSH adds
# and removes the firewall rules for the CONFIGURED SSH port, keeps the firewall
# itself intact, and leaves the web server alone.
#
# The port is resolved from the live SSH state, never assumed to be 22: it is
# settable from the SSH page and a reinstall preserves whatever was saved.
#
# lighttpd MUST NOT be cycled. install_sshd.sh's apply_firewall rebuilds the
# rules by running firewall.sh directly whenever the firewall unit is already
# active, so the unit is not restarted and lighttpd does not follow it down via
# PartOf=. A changed MainPID means the firewall was down beforehand and the
# restart branch applied, which does cycle lighttpd. The baseline records which
# branch applied so the report can say which.
#
# Run me THREE times, doing the SSH action between runs (no arguments needed):
#
#   sh device-test-ssh-firewall.sh     # 1) BEFORE install -> saves a baseline
#   ... Install SSH: the SSH page, or sh quecdeck.sh -> 4 -> install ...
#   sh device-test-ssh-firewall.sh     # 2) AFTER install  -> checks the add
#   ... Uninstall SSH from the SSH page ...
#   sh device-test-ssh-firewall.sh     # 3) AFTER uninstall -> checks the removal
#
# Run as root on a device where QuecDeck (lighttpd + firewall) is up. It only
# reads iptables and systemd state. It never changes the firewall itself.

DIR=/tmp/quecdeck-sshfw
SSH_ACCESS_HELPER=/usrdata/quecdeck/script/ssh_access.sh
SSHD_CONFIG=/opt/etc/ssh/sshd_config

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# lighttpd is not expected to cycle, but poll anyway: if the unit was restarted
# lighttpd may still be coming back up, and reporting it as down would hide the
# more useful "it was cycled" finding.
wait_lighttpd_up() { _w=0; while [ "$_w" -lt 8 ]; do systemctl is-active lighttpd >/dev/null 2>&1 && return 0; sleep 1; _w=$((_w+1)); done; return 1; }
lighttpd_pid() { systemctl show lighttpd -p MainPID 2>/dev/null | cut -d= -f2; }
count_jumps()  { iptables -S INPUT 2>/dev/null | grep -c -- '-j QUECDECK'; }
firewall_active() { systemctl is-active --quiet firewall 2>/dev/null && echo 1 || echo 0; }

# The port the firewall should be opening, from the same helper firewall.sh
# reads. Falls back to sshd_config so the test still works if the helper is
# unavailable, and prints nothing when SSH is not installed at all.
resolve_ssh_port() {
    _p=""
    if [ -x "$SSH_ACCESS_HELPER" ]; then
        _p=$("$SSH_ACCESS_HELPER" status 2>/dev/null | cut -f2)
    fi
    [ -n "$_p" ] || _p=$(sed -n 's/^Port \([0-9][0-9]*\)$/\1/p' "$SSHD_CONFIG" 2>/dev/null | head -1)
    case "$_p" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$_p"
}

# Count rules for one port inside a snapshot's stored ruleset, so the baseline
# can be re-counted for a port that was only discovered after the install.
count_port_in() { # count_port_in <snapshot> <port>
    rules_of "$1" | grep -cE -- "--dport $2( |\$)"
}

# Write a labelled snapshot: lighttpd PID, INPUT->QUECDECK jump count, whether
# the firewall unit was up, then the full QUECDECK ruleset.
snapshot() {
    {
        echo "PID=$(lighttpd_pid)"
        echo "JUMPS=$(count_jumps)"
        echo "FWACTIVE=$(firewall_active)"
        echo "SSHPORT=$(resolve_ssh_port 2>/dev/null)"
        echo "--RULES--"
        iptables -S QUECDECK 2>/dev/null
    } > "$1"
}
getval() { grep "^$2=" "$1" | cut -d= -f2; }
rules_of() { sed -n '/--RULES--/,$p' "$1"; }

# Report the lighttpd outcome against the branch apply_firewall took, named by
# the firewall state recorded BEFORE the action.
check_lighttpd() { # check_lighttpd <before-snapshot> <after-snapshot> <label>
    _fw=$(getval "$1" FWACTIVE)
    _bp=$(getval "$1" PID)
    _ap=$(getval "$2" PID)
    if ! wait_lighttpd_up; then
        bad "lighttpd is NOT up after $3 (MainPID $_bp -> $_ap)"
        return
    fi
    if [ "$_fw" = "1" ]; then
        if [ "$_bp" = "$_ap" ]; then
            ok "lighttpd untouched by $3 (MainPID $_ap unchanged, rules rebuilt in place)"
        else
            bad "lighttpd was CYCLED by $3 (MainPID $_bp -> $_ap) although the firewall unit was already active. apply_firewall should have run firewall.sh directly instead of restarting the unit"
        fi
    else
        ok "lighttpd is up after $3 (MainPID $_bp -> $_ap; the firewall unit was down beforehand, so the restart branch applied and a cycle is expected)"
    fi
}

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
    echo "  firewall unit active:      $(getval "$DIR/baseline" FWACTIVE)"
    b_port=$(getval "$DIR/baseline" SSHPORT)
    if [ -n "$b_port" ]; then
        echo "  NOTE: SSH already reports port $b_port. Is it already installed?"
        echo "        Uninstall it first for a clean baseline."
    fi
    if [ "$(getval "$DIR/baseline" FWACTIVE)" != "1" ]; then
        echo "  NOTE: the firewall unit is not active. Bring it up first, or the"
        echo "        lighttpd checks will exercise the restart branch instead."
    fi
    echo ""
    echo "Next: INSTALL SSH (the SSH page, or sh quecdeck.sh -> 4 -> install), then run this again."
    exit 0
fi

# ---- Stage 2: after install ---------------------------------------------
if [ ! -f "$DIR/after_install" ]; then
    snapshot "$DIR/after_install"
    echo "=================================================================="
    echo " Stage 2/3: after SSH install (compared to baseline)"
    echo "=================================================================="
    a_j=$(getval "$DIR/after_install" JUMPS)
    a_port=$(getval "$DIR/after_install" SSHPORT)

    if [ -z "$a_port" ]; then
        bad "SSH reports no configured port after install. Did the install actually complete?"
    else
        echo "  configured SSH port: $a_port"
        b_n=$(count_port_in "$DIR/baseline" "$a_port")
        a_n=$(count_port_in "$DIR/after_install" "$a_port")
        # A fresh install defaults to enabled, so the firewall opens the port:
        # one LAN ACCEPT plus the paired catch-all DROP.
        if [ "$a_n" = "2" ]; then
            ok "port $a_port has its ACCEPT and catch-all DROP after install"
        elif [ "$a_n" = "$b_n" ]; then
            bad "no rules added for port $a_port (still $a_n). Did the SSH install actually complete, or is SSH saved as disabled?"
        else
            bad "expected 2 rules for port $a_port (ACCEPT+DROP), found $a_n"
        fi
    fi
    check_lighttpd "$DIR/baseline" "$DIR/after_install" "the SSH install"
    [ "$a_j" -ge 1 ] && ok "INPUT still jumps to QUECDECK, firewall intact" \
        || bad "INPUT jump to QUECDECK is missing. The firewall is DOWN"

    echo ""
    echo " Stage 2 result: $pass passed, $fail failed"
    echo "Next: UNINSTALL SSH from the SSH page, then run this again."
    exit 0
fi

# ---- Stage 3: after uninstall -------------------------------------------
snapshot "$DIR/after_uninstall"
echo "=================================================================="
echo " Stage 3/3: after SSH uninstall (compared to baseline)"
echo "=================================================================="
u_j=$(getval "$DIR/after_uninstall" JUMPS)
# SSH is gone by now, so its port cannot be resolved live. Use the one the
# install stage recorded: that is the port whose rules must have been removed.
a_port=$(getval "$DIR/after_install" SSHPORT)

if [ -z "$a_port" ]; then
    bad "no SSH port was recorded at install time, cannot check rule removal"
else
    b_n=$(count_port_in "$DIR/baseline" "$a_port")
    u_n=$(count_port_in "$DIR/after_uninstall" "$a_port")
    [ "$u_n" = "$b_n" ] && ok "rules for port $a_port removed, back to baseline ($u_n)" \
        || bad "rules for port $a_port not cleaned up (found $u_n, baseline had $b_n)"
fi
check_lighttpd "$DIR/after_install" "$DIR/after_uninstall" "the SSH uninstall"
[ "$u_j" -ge 1 ] && ok "INPUT still jumps to QUECDECK, firewall intact" \
    || bad "INPUT jump to QUECDECK is missing. The firewall is DOWN"

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
    echo " SSH firewall behavior correct: the configured port's rules toggle"
    echo " cleanly, the firewall stays up, and lighttpd is left alone."
    rm -rf "$DIR"        # clean state for a fresh run next time
    exit 0
else
    echo " Failures above. State kept in $DIR for inspection. Remove it to reset."
    exit 1
fi
