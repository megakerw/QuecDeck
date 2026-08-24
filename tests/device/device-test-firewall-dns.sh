#!/bin/sh
# Temporarily verify the DNS portion of QuecDeck's firewall policy. During the
# announced window, query both the LAN address and the extra IPPT address from
# the ADB host. The LAN query must succeed and the IPPT-address query must fail.
#
# DISRUPTIVE: briefly filters DNS to the modem itself. The complete filter table
# is restored byte-for-byte on every normal or signal exit.

set -u

WINDOW=${1:-30}
CHAIN=QD_DNS_TEST
BACKUP="/run/quecdeck-firewall-dns-test.$$.rules"

case "$WINDOW" in ''|*[!0-9]*) echo "Usage: sh $0 [window-seconds]"; exit 2 ;; esac
[ "$WINDOW" -ge 10 ] || WINDOW=10
[ "$(id -u)" = 0 ] || { echo "FATAL: run as root" >&2; exit 1; }

LAN_IP=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' /etc/data/mobileap_cfg.xml 2>/dev/null | sed 's/<[^>]*>//g')
case "$LAN_IP" in
    ''|*[!0-9.]*) LAN_IP=192.168.225.1 ;;
esac
ip -4 addr show dev bridge0 2>/dev/null | grep -q "[[:space:]]$LAN_IP/" || {
    echo "FATAL: LAN address $LAN_IP is not assigned to bridge0" >&2
    exit 1
}

iptables-save -t filter > "$BACKUP" || exit 1
cleanup() {
    [ -s "$BACKUP" ] || return
    if iptables-restore < "$BACKUP" 2>/dev/null; then
        rm -f "$BACKUP"
        echo "RESTORED_ORIGINAL"
    else
        echo "FATAL: could not restore filter table. Backup retained at $BACKUP" >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

iptables -N "$CHAIN" || exit 1
iptables -A "$CHAIN" -i bridge0 -d "$LAN_IP" -p udp --dport 53 -j ACCEPT || exit 1
iptables -A "$CHAIN" -i bridge0 -d "$LAN_IP" -p tcp --dport 53 -j ACCEPT || exit 1
iptables -A "$CHAIN" -p udp --dport 53 -j DROP || exit 1
iptables -A "$CHAIN" -p tcp --dport 53 -j DROP || exit 1
iptables -I INPUT 1 -j "$CHAIN" || exit 1

echo "READY: for ${WINDOW}s, DNS to $LAN_IP must work. DNS to any other modem address must fail"
iptables -L "$CHAIN" -n -v --line-numbers
sleep "$WINDOW"
echo "FINAL_COUNTERS"
iptables -L "$CHAIN" -n -v --line-numbers
