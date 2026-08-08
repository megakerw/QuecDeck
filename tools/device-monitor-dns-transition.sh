#!/bin/sh
# Read-only monitor for QCMAP/IPPT DNS transitions. Prints a snapshot only
# when relevant state changes. Trigger the IPPT toggle separately from the UI.

DURATION=${1:-120}
case "$DURATION" in ''|*[!0-9]*) echo "Usage: sh $0 [seconds]"; exit 2 ;; esac

snapshot() {
    echo "ADDR4"
    ip -br -4 addr 2>/dev/null
    echo "ROUTE4"
    ip route 2>/dev/null
    echo "DNS_DHCP_LISTEN"
    (ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null) | \
        awk 'NR == 1 || $4 ~ /:(53|67)$/'
    echo "DNSMASQ"
    _pid=$(pidof dnsmasq 2>/dev/null)
    echo "pid=${_pid:-none}"
    [ -n "$_pid" ] && tr '\000' ' ' < "/proc/${_pid%% *}/cmdline" 2>/dev/null
    echo
    echo "FILTER53_67"
    iptables -S INPUT 2>/dev/null | grep -E -- '--dport (53|67)( |$)' || true
    echo "RESOLVER"
    ls -l /etc/resolv.conf 2>/dev/null
    sed -n '1,80p' /etc/resolv.conf 2>/dev/null
    echo "DNSMASQ_CONFIG"
    sed -n '1,160p' /var/run/data/dnsmasq.conf.bridge 2>/dev/null
}

last=""
i=0
while [ "$i" -le "$DURATION" ]; do
    current=$(snapshot)
    if [ "$current" != "$last" ]; then
        echo "=================================================================="
        echo "CHANGE t=${i}s wall=$(date +%s)"
        printf '%s\n' "$current"
        last=$current
    fi
    i=$((i + 1))
    sleep 1
done
