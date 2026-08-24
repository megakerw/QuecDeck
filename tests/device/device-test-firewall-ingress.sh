#!/bin/sh
# Identify the real LAN ingress interface and exercise QuecDeck's bridge-bound
# policy. The host running adb should request https://<LAN_IP>/ once
# during each announced window.
#
# DISRUPTIVE: temporarily replaces the QUECDECK IPv4 chain. The complete
# filter table is restored byte-for-byte on every normal/signal exit.

BACKUP=/run/quecdeck-fw-ingress.backup
PROBE=QD_INGRESS_PROBE
WINDOW=${1:-10}

case "$WINDOW" in ''|*[!0-9]*) echo "Usage: sh $0 [window-seconds]"; exit 2 ;; esac
[ "$WINDOW" -ge 5 ] || WINDOW=5
[ "$(id -u)" = 0 ] || { echo "FATAL: run as root"; exit 1; }

LAN_IP=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' /etc/data/mobileap_cfg.xml 2>/dev/null | sed 's/<[^>]*>//g')
case "$LAN_IP" in
    ''|*[!0-9.]*) LAN_IP=192.168.225.1 ;;
esac
iptables-save -t filter > "$BACKUP" || exit 1
cleanup() {
    [ -s "$BACKUP" ] || return
    if iptables-restore < "$BACKUP" 2>/dev/null; then
        rm -f "$BACKUP"
    else
        echo "FATAL: could not restore the saved filter table. Backup retained at $BACKUP" >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

iptables -N "$PROBE"
iptables -A "$PROBE" -i bridge0 -p tcp --dport 443 -j RETURN
iptables -A "$PROBE" -i eth0 -p tcp --dport 443 -j RETURN
iptables -A "$PROBE" -i rmnet+ -p tcp --dport 443 -j RETURN
iptables -A "$PROBE" -p tcp --dport 443 -j RETURN
iptables -I INPUT 1 -j "$PROBE"

echo "PHASE1_READY: request https://$LAN_IP/ within ${WINDOW}s"
sleep "$WINDOW"
echo "PHASE1_COUNTERS"
iptables -L "$PROBE" -n -v --line-numbers

iptables -D INPUT -j "$PROBE"
iptables -F "$PROBE"
iptables -X "$PROBE"

# QuecDeck policy: accept the configured LAN address only on the bridge that
# actually delivered the host's phase-one request. Every other ingress path
# falls through to DROP, independent of QCMAP's rules or WAN interface names.
PORTS="80 443"
[ -f /lib/systemd/system/sshd.service ] && PORTS="22 $PORTS"
iptables -F QUECDECK
for port in $PORTS; do
    iptables -A QUECDECK -i bridge0 -d "$LAN_IP" -p tcp --dport "$port" -j ACCEPT
    iptables -A QUECDECK -p tcp --dport "$port" -j DROP
done

echo "PHASE2_READY: QuecDeck LAN ingress=bridge0. Request https://$LAN_IP/ within ${WINDOW}s"
sleep "$WINDOW"
echo "PHASE2_RULES"
iptables -L QUECDECK -n -v --line-numbers
echo "RESTORING_ORIGINAL"
