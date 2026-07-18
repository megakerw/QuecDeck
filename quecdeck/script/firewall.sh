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

# IPv6 rules are best-effort: this wrapper always succeeds, so a missing
# ip6tables can't fail the unit and (via lighttpd's Requires=) block the web UI.
ip6() {
    command -v ip6tables >/dev/null 2>&1 || return 0
    ip6tables "$@" 2>/dev/null || true
}

# Set up custom chains so rules survive QCMAP INPUT chain rebuilds
iptables -N QUECDECK 2>/dev/null
iptables -F QUECDECK
ip6 -N QUECDECK6
ip6 -F QUECDECK6

# Add rules to custom chains
for port in "${PORTS[@]}"; do
    # IPv4: allow from LAN IP only, block all other interfaces
    iptables -A QUECDECK -d "$LAN_IP" -p tcp --dport "$port" -j ACCEPT
    iptables -A QUECDECK -p tcp --dport "$port" -j DROP
    # IPv6: block all (admin UI is not expected to be reachable via IPv6)
    ip6 -A QUECDECK6 -p tcp --dport "$port" -j DROP
done

# Insert the INPUT jumps. The IPv4 jump is load-bearing: if it can't be installed,
# fail the unit (fail closed, so lighttpd's Requires= keeps the UI down rather
# than serving unfirewalled). IPv6 stays best-effort.
iptables -D INPUT -j QUECDECK 2>/dev/null || true
if ! iptables -I INPUT -j QUECDECK; then
    echo "firewall: failed to install the IPv4 INPUT jump; refusing to continue." >&2
    exit 1
fi
ip6 -D INPUT -j QUECDECK6
ip6 -I INPUT -j QUECDECK6

exit 0
