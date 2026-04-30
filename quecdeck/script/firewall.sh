#!/bin/bash

# TCP ports to allow on LAN IP and block everywhere else
PORTS=("80" "443")
# Open port 22 only when sshd is installed
# Check the service file on rootfs rather than the binary in /opt,
# since /opt may not be mounted yet when the firewall starts.
[ -f /lib/systemd/system/sshd.service ] && PORTS=("22" "${PORTS[@]}")

# Wait for QCMAP to finish its async iptables setup before touching anything.
# Skipped if the system has been up for more than 60 seconds (e.g. during install/update).
uptime_secs=$(awk '{print int($1)}' /proc/uptime)
[ "$uptime_secs" -lt 60 ] && sleep 20

# Read LAN IP from mobileap config, fall back to default
LAN_IP=""
if [ -f "/etc/data/mobileap_cfg.xml" ]; then
    LAN_IP=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' /etc/data/mobileap_cfg.xml | sed 's/<APIPAddr>//;s/<\/APIPAddr>//')
fi
# Validate extracted IP: dotted-decimal format with each octet in 0-255.
if ! printf '%s' "$LAN_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || \
   ! printf '%s' "$LAN_IP" | awk -F. '$1>255||$2>255||$3>255||$4>255{exit 1}'; then
    LAN_IP="192.168.225.1"
fi

# Set up custom chains so rules survive QCMAP INPUT chain rebuilds
iptables  -N FW  2>/dev/null
iptables  -F FW
ip6tables -N FW6 2>/dev/null
ip6tables -F FW6

# Add rules to custom chains
for port in "${PORTS[@]}"; do
    # IPv4: allow from LAN IP only, block all other interfaces
    iptables  -A FW  -d "$LAN_IP" -p tcp --dport "$port" -j ACCEPT
    iptables  -A FW  -p tcp --dport "$port" -j DROP
    # IPv6: block all (admin UI is not expected to be reachable via IPv6)
    ip6tables -A FW6 -p tcp --dport "$port" -j DROP 2>/dev/null || true
done

# Insert jumps from INPUT into our chains
iptables  -D INPUT -j FW  2>/dev/null || true
iptables  -I INPUT -j FW
ip6tables -D INPUT -j FW6 2>/dev/null || true
ip6tables -I INPUT -j FW6
