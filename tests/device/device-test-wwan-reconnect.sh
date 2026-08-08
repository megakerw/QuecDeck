#!/bin/bash
# Exercise QCMAP/IPPT recovery after a real RF detach. Run as root over ADB.
# DISRUPTIVE: WWAN is disabled for 20 seconds. An EXIT/signal trap always asks
# the modem to return to full functionality if the test exits while detached.

set -u

. /usrdata/quecdeck/script/at-lib.sh

OUTAGE=${1:-20}
RECOVERY=${2:-180}
case "$OUTAGE:$RECOVERY" in *[!0-9:]*) echo "Usage: $0 [outage-seconds] [recovery-seconds]"; exit 2 ;; esac
[ "$(id -u)" = 0 ] || { echo "FATAL: run as root" >&2; exit 1; }

detached=0
restore_rf() {
    if [ "$detached" = 1 ]; then
        echo "RECOVERY_TRAP: requesting AT+CFUN=1"
        atcmd_run 'AT+CFUN=1' 10000 >/dev/null 2>&1 || true
    fi
}
trap restore_rf EXIT
trap 'exit 130' INT TERM HUP

snapshot() {
    echo "ADDR4"
    ip -br -4 addr 2>/dev/null
    echo "ROUTE4"
    ip -4 route 2>/dev/null
    echo "DNS53"
    (ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null) | awk 'NR == 1 || $4 ~ /:53$/'
    echo "SERVICES"
    systemctl is-active QCMAP_ConnectionManagerd firewall lighttpd 2>/dev/null
    echo "FIREWALL"
    iptables -S INPUT 2>/dev/null | grep QUECDECK || true
    iptables -S QUECDECK 2>/dev/null || true
}

last=""
show_change() {
    local phase=$1 elapsed=$2 current
    current=$(snapshot)
    if [ "$current" != "$last" ]; then
        echo "=================================================================="
        echo "CHANGE phase=$phase t=${elapsed}s wall=$(date +%s)"
        printf '%s\n' "$current"
        last=$current
    fi
}

echo "BASELINE_CFUN"
atcmd_run 'AT+CFUN?' 5000 || exit 1
show_change baseline 0

echo "DETACHING_RF"
detach_reply=$(atcmd_run 'AT+CFUN=4' 10000) || {
    printf '%s\n' "$detach_reply"
    echo "FATAL: AT+CFUN=4 did not complete" >&2
    exit 1
}
printf '%s\n' "$detach_reply"
printf '%s\n' "$detach_reply" | grep -q '^OK$' || {
    echo "FATAL: modem did not accept AT+CFUN=4" >&2
    exit 1
}
detached=1

i=0
while [ "$i" -le "$OUTAGE" ]; do
    show_change outage "$i"
    sleep 1
    i=$((i + 1))
done

echo "RESTORING_RF"
restore_reply=$(atcmd_run 'AT+CFUN=1' 10000) || {
    printf '%s\n' "$restore_reply"
    echo "FATAL: AT+CFUN=1 did not complete; recovery trap remains armed" >&2
    exit 1
}
printf '%s\n' "$restore_reply"
printf '%s\n' "$restore_reply" | grep -q '^OK$' || {
    echo "FATAL: modem did not accept AT+CFUN=1; recovery trap remains armed" >&2
    exit 1
}
detached=0

expected_rules=8
[ -f /lib/systemd/system/sshd.service ] && expected_rules=10
recovery_ready() {
    local bridge_addresses rule_count
    bridge_addresses=$(ip -4 -o addr show dev bridge0 2>/dev/null | awk '{print $4}')
    rule_count=$(iptables -S QUECDECK 2>/dev/null | grep -c '^-A QUECDECK')
    ip -4 route show default 2>/dev/null | grep -q . &&
    printf '%s\n' "$bridge_addresses" | grep -q '^192\.168\.225\.1/' &&
    [ "$(printf '%s\n' "$bridge_addresses" | grep -cv '^192\.168\.225\.1/')" -ge 1 ] &&
    (ss -lnut 2>/dev/null || netstat -lnut 2>/dev/null) | grep -q '192\.168\.225\.1:53' &&
    [ "$(iptables -S INPUT 2>/dev/null | grep -c '^-A INPUT -j QUECDECK$')" = 1 ] &&
    [ "$rule_count" = "$expected_rules" ] &&
    [ "$(systemctl is-active firewall 2>/dev/null)" = active ] &&
    [ "$(systemctl is-active lighttpd 2>/dev/null)" = active ]
}

recovered=0
i=0
while [ "$i" -le "$RECOVERY" ]; do
    show_change recovery "$i"
    # In IPPT mode the modem hands the bearer address to the attached host and
    # may not be able to originate a useful Internet ping itself. Treat the
    # firmware's complete IPPT topology as recovery: LAN plus a second /32 on
    # bridge0, a default route, rebound LAN DNS, and intact service/firewall
    # state. QCMAP may place stricter rmnet drops before our jump during its
    # rebuild, so require one jump rather than requiring it to remain first.
    # Host-side reachability is checked separately by the runner.
    if recovery_ready; then
        recovered=1
        break
    fi
    sleep 1
    i=$((i + 1))
done

recovery_time=$i
[ "$recovered" = 1 ] || { echo "FATAL: recovery timed out after ${RECOVERY}s" >&2; exit 1; }

# QCMAP performs another rules rebuild after the topology first looks healthy.
# Observe through that delayed window and then re-check the complete policy.
settle=0
while [ "$settle" -lt 30 ]; do
    show_change settle "$settle"
    sleep 1
    settle=$((settle + 1))
done
show_change final "$settle"
recovery_ready || { echo "FATAL: recovered state did not survive the 30s settling window" >&2; exit 1; }

echo "FINAL_CFUN"
atcmd_run 'AT+CFUN?' 5000 || true
echo "RECOVERED in ${recovery_time}s; stable after 30s"
