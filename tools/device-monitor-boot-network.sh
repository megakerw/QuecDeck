#!/bin/bash
# Capture the modem's network transition sequence from early boot without
# generating traffic or changing modem/network configuration.
#
# Usage as root (copy this file to the modem first):
#   bash device-monitor-boot-network.sh --install [seconds]
#   reboot
#   bash /usrdata/quecdeck-boot-network-monitor.sh --status
#   bash /usrdata/quecdeck-boot-network-monitor.sh --uninstall
#
# The installed service starts before network.target/QCMAP, records one compact
# counter sample per second plus a detailed block whenever topology changes, and
# exits after the requested duration (default 180 seconds). The persistent log
# is /usrdata/quecdeck_boot_network.log.

set -u

SELF_INSTALLED=/usrdata/quecdeck-boot-network-monitor.sh
UNIT=/lib/systemd/system/quecdeck-boot-network-monitor.service
WANT=/lib/systemd/system/sysinit.target.wants/quecdeck-boot-network-monitor.service
LOG=/usrdata/quecdeck_boot_network.log
SNAPSHOT_INTERVAL=2

usage() {
    echo "Usage: $0 --install [seconds] | --capture [seconds] | --status | --uninstall"
    exit 2
}

valid_duration() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 30 ] && [ "$1" -le 900 ]
}

remount_root() { # remount_root rw|ro
    mount -o "remount,$1" / >/dev/null 2>&1
}

install_monitor() {
    local duration=${1:-180} source
    [ "$(id -u)" = 0 ] || { echo "FATAL: run as root" >&2; return 1; }
    valid_duration "$duration" || { echo "Duration must be 30-900 seconds." >&2; return 1; }
    source=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")

    [ "$source" = "$SELF_INSTALLED" ] || cp -f "$source" "$SELF_INSTALLED" || return 1
    chown root:root "$SELF_INSTALLED" && chmod 700 "$SELF_INSTALLED" || return 1

    if ! remount_root rw; then
        echo "FATAL: could not remount / read-write." >&2
        return 1
    fi
    trap 'remount_root ro' RETURN
    cat > "$UNIT" <<EOF
[Unit]
Description=One-shot QuecDeck boot network transition monitor
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target network.target QCMAP_ConnectionManagerd.service

[Service]
Type=simple
ExecStart=/bin/bash $SELF_INSTALLED --capture $duration
StandardOutput=null
StandardError=null

[Install]
WantedBy=sysinit.target
EOF
    chmod 644 "$UNIT" || return 1
    mkdir -p "$(dirname "$WANT")" || return 1
    ln -sf "$UNIT" "$WANT" || return 1
    systemctl daemon-reload || return 1
    remount_root ro || { echo "WARNING: could not restore / read-only." >&2; return 1; }
    trap - RETURN

    echo "Installed boot monitor for ${duration}s. Reboot when ready."
    echo "After reconnecting: bash $SELF_INSTALLED --status"
}

uninstall_monitor() {
    [ "$(id -u)" = 0 ] || { echo "FATAL: run as root" >&2; return 1; }
    systemctl stop quecdeck-boot-network-monitor >/dev/null 2>&1 || true
    if ! remount_root rw; then
        echo "FATAL: could not remount / read-write." >&2
        return 1
    fi
    rm -f "$WANT" "$UNIT"
    systemctl daemon-reload
    remount_root ro || { echo "WARNING: could not restore / read-only." >&2; return 1; }
    rm -f "$SELF_INSTALLED"
    echo "Boot monitor removed. Capture retained at $LOG"
}

interface_sample() {
    local dev path state carrier rx_bytes tx_bytes rx_packets tx_packets
    for path in /sys/class/net/*; do
        [ -e "$path" ] || continue
        dev=${path##*/}
        case "$dev" in lo|teql*|tunl*|gre*|gretap*|erspan*|sit*|ip6tnl*|ip6gre*) continue ;; esac
        read -r state < "$path/operstate" 2>/dev/null || state=?
        read -r carrier < "$path/carrier" 2>/dev/null || carrier=?
        read -r rx_bytes < "$path/statistics/rx_bytes" 2>/dev/null || rx_bytes=?
        read -r tx_bytes < "$path/statistics/tx_bytes" 2>/dev/null || tx_bytes=?
        read -r rx_packets < "$path/statistics/rx_packets" 2>/dev/null || rx_packets=?
        read -r tx_packets < "$path/statistics/tx_packets" 2>/dev/null || tx_packets=?
        printf ' %s=%s/c%s,rx%s/%s,tx%s/%s' \
            "$dev" "$state" "$carrier" "$rx_bytes" "$rx_packets" "$tx_bytes" "$tx_packets"
    done
}

topology_snapshot() {
    echo "LINK"
    ip -br link 2>/dev/null
    echo "ADDR4"
    ip -br -4 addr 2>/dev/null
    echo "ADDR6"
    ip -br -6 addr 2>/dev/null
    echo "BRIDGE_MEMBERS"
    ip -o link show master bridge0 2>/dev/null
    echo "ROUTE4"
    ip -4 route 2>/dev/null
    echo "ROUTE6"
    ip -6 route 2>/dev/null
    echo "NEIGHBOURS"
    ip neigh 2>/dev/null
    echo "DNS_WEB_LISTENERS"
    (ss -lnutp 2>/dev/null || netstat -lnutp 2>/dev/null) | \
        awk 'NR == 1 || $4 ~ /:(53|80|443)$/'
    echo "SERVICES"
    systemctl is-active QCMAP_ConnectionManagerd firewall lighttpd 2>/dev/null
    echo "FIREWALL_HOOKS"
    iptables -S INPUT 2>/dev/null | grep -E 'QUECDECK|--dport (53|80|443)' || true
    ip6tables -S INPUT 2>/dev/null | grep -E 'QUECDECK6|--dport (53|80|443)' || true
    echo "DNSMASQ"
    _dns_pid=$(pidof dnsmasq 2>/dev/null)
    echo "pid=${_dns_pid:-none}"
}

capture_boot() {
    local duration=${1:-180} started now elapsed last current uptime_line next_snapshot
    valid_duration "$duration" || usage
    umask 077
    : > "$LOG" || exit 1
    exec >> "$LOG" 2>&1

    echo "QuecDeck boot network capture"
    echo "duration=${duration}s started_wall=$(date +%s) kernel=$(uname -r)"
    echo "SAMPLE format: monotonic uptime followed by state/carrier and byte/packet counters"
    last=""
    read -r uptime_line _ < /proc/uptime
    started=${uptime_line%.*}
    elapsed=0
    next_snapshot=0
    while [ "$elapsed" -le "$duration" ]; do
        read -r uptime_line _ < /proc/uptime
        now=${uptime_line%.*}
        elapsed=$((now - started))
        printf 'SAMPLE elapsed=%s uptime=%s' "$elapsed" "$uptime_line"
        interface_sample
        echo

        if [ "$elapsed" -ge "$next_snapshot" ]; then
            current=$(topology_snapshot)
            if [ "$current" != "$last" ]; then
                echo "=================================================================="
                echo "CHANGE elapsed=${elapsed}s uptime=$uptime_line wall=$(date +%s)"
                printf '%s\n' "$current"
                last=$current
            fi
            next_snapshot=$((elapsed + SNAPSHOT_INTERVAL))
        fi
        [ "$elapsed" -ge "$duration" ] && break
        sleep 1
    done
    echo "=================================================================="
    echo "KERNEL NETWORK EVENTS"
    dmesg 2>/dev/null | grep -Ei '(^|[^[:alnum:]_])(eth|bridge|rmnet|ecm|rndis|usb)[^:]*:|link (is )?(up|down)|carrier (on|off)' || true
    echo "CAPTURE COMPLETE uptime=$uptime_line wall=$(date +%s)"
}

show_status() {
    systemctl status quecdeck-boot-network-monitor --no-pager -l 2>/dev/null || true
    echo ""
    if [ -f "$LOG" ]; then
        ls -l "$LOG"
        echo "Last 40 lines:"
        tail -40 "$LOG"
    else
        echo "No capture found at $LOG"
    fi
}

case "${1:-}" in
    --install)   install_monitor "${2:-180}" ;;
    --capture)   capture_boot "${2:-180}" ;;
    --status)    show_status ;;
    --uninstall) uninstall_monitor ;;
    *) usage ;;
esac
