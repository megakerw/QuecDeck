#!/bin/sh
# Firewall <-> lighttpd coupling test. Verifies the systemd dependency wiring
# that keeps the web UI from ever serving without the LAN-only firewall, and
# that a firewall restart brings lighttpd back automatically:
#
#   lighttpd.service: Requires=firewall.service  (no UI unless firewall is up,
#                                                 + boot ordering via After=)
#                     PartOf=firewall.service    (a firewall stop/restart
#                                                 propagates to lighttpd)
#
# Run as root on a CONFIGURED device (setup done), ADB'd over to anywhere:
#
#     sh device-test-firewall-lighttpd.sh            # single pass, prompts first
#     sh device-test-firewall-lighttpd.sh -y         # skip the prompt
#     sh device-test-firewall-lighttpd.sh -n 20      # stress: 20 restart cycles
#     sh device-test-firewall-lighttpd.sh -n 20 -y
#
# DISRUPTIVE: the runtime checks restart, then stop, the firewall, which cycles
# lighttpd with it. The web UI is interrupted for a few seconds per cycle. Both
# services are restored on exit (including Ctrl-C) by an EXIT trap. The
# read-only checks (unit validity + loaded directives) run first, no prompt.
#
# It checks:
#   1. lighttpd.service is valid and the LOADED unit carries Requires=,
#      After=, and PartOf= on firewall.service (catches a missing daemon-reload
#      or a unit that never picked up the directives).
#   2. Restart propagation, repeated -n times (default 1): each
#      `systemctl restart firewall` must cycle lighttpd (new MainPID) and it
#      must return to active and serving on its own. This is the property the
#      shell scripts stopped hand-holding once PartOf= went in; -n hammers it
#      to surface an intermittent recovery failure a single pass would miss.
#   3. Stop propagation: `systemctl stop firewall` takes lighttpd down with it
#      (Requires=/PartOf=), then the tree is restored.
#
# The loop paces itself and runs `systemctl reset-failed` between cycles so it
# never trips systemd's start-rate limiter (default 5 starts / 10s), which would
# otherwise self-inflict a failure and could park a unit in the failed state.

IP=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' /etc/data/mobileap_cfg.xml 2>/dev/null | sed 's/<[^>]*>//g')
IP=${IP:-192.168.225.1}
UNIT_FILE=/lib/systemd/system/lighttpd.service

# ---- args ---------------------------------------------------------------
YES=0
ITER=1
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)          YES=1 ;;
        -n|--iterations)   shift; ITER="$1" ;;
        -n*)               ITER="${1#-n}" ;;
        -h|--help)         sed -n '2,25p' "$0"; exit 0 ;;
        *)                 echo "Unknown argument: $1 (see -h)"; exit 2 ;;
    esac
    shift
done
case "$ITER" in ''|*[!0-9]*) echo "FATAL: -n must be a positive integer."; exit 2 ;; esac
[ "$ITER" -ge 1 ] || ITER=1

pass=0; fail=0; warn=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }
note() { echo "  WARN: $1"; warn=$((warn+1)); }

main_pid()  { systemctl show "$1" -p MainPID 2>/dev/null | cut -d= -f2; }
show_prop() { systemctl show "$1" -p "$2" 2>/dev/null | cut -d= -f2-; }

# Poll systemctl is-active until <unit> reaches <want> (active|down) or timeout.
# "down" means anything that is not active/activating (inactive, failed, dead).
# Uniquely prefixed internals (_ws_*): POSIX sh has no locals, so a plain _i
# here would clobber a caller's loop counter of the same name.
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

# 0 if lighttpd answers an HTTPS request on the LAN IP (any status line = the
# server is up; / normally 302s to /login.html).
http_up() {
    _out=$(/opt/bin/wget -S --max-redirect=0 -O /dev/null --no-check-certificate "https://$IP/" 2>&1)
    printf '%s\n' "$_out" | grep -qiE 'HTTP/[0-9.]+ [0-9]+'
}

# Best effort: leave both services up however the script exits. Starting
# lighttpd pulls firewall up too (Requires=), recovering the whole tree from
# any interrupted check.
restore() {
    systemctl reset-failed firewall lighttpd >/dev/null 2>&1
    systemctl start lighttpd >/dev/null 2>&1
    systemctl start firewall >/dev/null 2>&1
}

echo "=================================================================="
echo " QuecDeck firewall <-> lighttpd coupling test (device $IP)"
echo "=================================================================="

# ---- preflight ----------------------------------------------------------
[ "$(id -u)" = "0" ] || { echo "FATAL: run as root."; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo "FATAL: systemctl not found."; exit 1; }
[ -f "$UNIT_FILE" ] || { echo "FATAL: $UNIT_FILE missing -- is QuecDeck installed?"; exit 1; }

# ---- Check 1: unit validity + loaded directives (read-only) -------------
echo ""
echo "[Check 1] lighttpd.service is valid and the loaded unit is coupled to firewall"
if command -v systemd-analyze >/dev/null 2>&1; then
    if systemd-analyze verify "$UNIT_FILE" 2>&1 | grep -q .; then
        note "systemd-analyze verify emitted warnings for $UNIT_FILE (review above)"
    else
        ok "systemd-analyze verify clean"
    fi
else
    note "systemd-analyze not present; skipped unit-file verification"
fi

# The LOADED unit is what matters (a stale unit without a daemon-reload would
# still show the old dependencies), so query the running manager, not the file.
_has_partof=0
for _prop in Requires After PartOf; do
    if show_prop lighttpd "$_prop" | tr ' ' '\n' | grep -qx firewall.service; then
        ok "loaded lighttpd unit has $_prop=firewall.service"
        [ "$_prop" = "PartOf" ] && _has_partof=1
    else
        bad "loaded lighttpd unit is MISSING $_prop=firewall.service (run 'systemctl daemon-reload' after installing the new unit)"
    fi
done

# ---- baseline (read-only) -----------------------------------------------
echo ""
echo "[Baseline] both services active before the disruptive checks"
_base_ok=1
wait_state firewall active 5 && ok "firewall is active" || { bad "firewall not active at start"; _base_ok=0; }
wait_state lighttpd active 5 && ok "lighttpd is active" || { bad "lighttpd not active at start"; _base_ok=0; }
if [ "$_base_ok" != "1" ]; then
    echo ""
    echo "Baseline not healthy; skipping the disruptive checks. Bring both services"
    echo "up ('systemctl start lighttpd') and re-run."
elif [ "$_has_partof" != "1" ]; then
    echo ""
    echo "The loaded lighttpd unit has no PartOf=firewall.service, so a firewall"
    echo "restart cannot cycle lighttpd -- the restart/stop checks would just fail"
    echo "every cycle. Deploy the new lighttpd.service and run 'systemctl"
    echo "daemon-reload', then re-run. Skipping the disruptive checks."
else
    # ---- confirm before disrupting --------------------------------------
    if [ "$YES" != "1" ]; then
        echo ""
        printf 'Checks 2-3 restart (x%s) then stop the firewall, briefly interrupting\n' "$ITER"
        printf 'the web UI (both are restored on exit). Continue? [y/N] '
        read _ans
        case "$_ans" in y|Y|yes|YES) ;; *) echo "Aborted (read-only checks above still count)."; restore; [ "$fail" -eq 0 ] && exit 0 || exit 1 ;; esac
    fi
    trap restore EXIT INT TERM

    # ---- Check 2: restart propagation (PartOf=), repeated ---------------
    echo ""
    echo "[Check 2] 'systemctl restart firewall' cycles lighttpd and it self-recovers ($ITER cycle(s))"
    _c2_fail=0
    _cyc=1
    while [ "$_cyc" -le "$ITER" ]; do
        _pid_before=$(main_pid lighttpd)
        systemctl restart firewall >/dev/null 2>&1
        if wait_state lighttpd active 20; then
            _pid_after=$(main_pid lighttpd)
            if [ -n "$_pid_before" ] && [ "$_pid_before" = "$_pid_after" ]; then
                echo "    cycle $_cyc/$ITER: FAIL - lighttpd active but MainPID unchanged ($_pid_after); restart did not propagate"
                _c2_fail=$((_c2_fail+1))
            elif ! http_up; then
                echo "    cycle $_cyc/$ITER: FAIL - lighttpd active but https://$IP did not respond"
                _c2_fail=$((_c2_fail+1))
            fi
        else
            echo "    cycle $_cyc/$ITER: FAIL - lighttpd did not return to active within 20s (stopped via Requires=, not restarted via PartOf=)"
            _c2_fail=$((_c2_fail+1))
        fi
        # Clear the start-limit burst counter so repeated cycles don't trip
        # systemd's rate limiter and self-inflict a failure.
        systemctl reset-failed firewall lighttpd >/dev/null 2>&1
        # Progress heartbeat on long runs.
        [ "$ITER" -ge 10 ] && [ $((_cyc % 10)) -eq 0 ] && echo "    ...$_cyc/$ITER cycles done ($_c2_fail failed so far)"
        [ "$_cyc" -lt "$ITER" ] && sleep 2
        _cyc=$((_cyc+1))
    done
    if [ "$_c2_fail" -eq 0 ]; then
        ok "all $ITER restart cycle(s) recovered lighttpd (new PID + HTTP up)"
    else
        bad "$_c2_fail of $ITER restart cycles did not recover lighttpd cleanly (details above)"
    fi

    # ---- Check 3: stop propagation (Requires=/PartOf=) ------------------
    echo ""
    echo "[Check 3] 'systemctl stop firewall' takes lighttpd down with it"
    systemctl stop firewall >/dev/null 2>&1
    if wait_state lighttpd down 15; then
        ok "lighttpd stopped when the firewall was stopped"
    else
        bad "lighttpd stayed active after the firewall was stopped -- the coupling does not enforce 'no UI without firewall' at runtime"
    fi
    # Restore the tree (start lighttpd pulls firewall up via Requires=).
    echo "  ... restoring both services"
    systemctl reset-failed firewall lighttpd >/dev/null 2>&1
    systemctl start lighttpd >/dev/null 2>&1
    if wait_state firewall active 20 && wait_state lighttpd active 20; then
        ok "both services restored to active"
    else
        bad "could not restore firewall/lighttpd to active -- check 'systemctl status firewall lighttpd' and recover manually"
    fi
fi

# ---- verdict ------------------------------------------------------------
echo ""
echo "=================================================================="
echo " Results: $pass passed, $fail failed, $warn warnings"
echo "=================================================================="
if [ "$fail" -eq 0 ]; then
    echo " VERDICT: coupling intact. lighttpd is bound to the firewall and a"
    echo "          firewall restart cycles it back up on its own."
else
    echo " VERDICT: coupling FAILURE above. If Check 2 failed, PartOf= is not"
    echo "          reliably taking effect -- keep the explicit 'systemctl start"
    echo "          lighttpd' backstops until this passes clean."
fi
echo "=================================================================="
[ "$fail" -eq 0 ] && exit 0 || exit 1
