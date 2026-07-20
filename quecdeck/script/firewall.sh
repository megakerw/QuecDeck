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

# Build the chain body once; both address families derive from it. The
# declared chain line (:QUECDECK) is flushed-and-refilled atomically by
# iptables-restore --noflush (device semantics verified on the 1.8.4 legacy
# build by tools/device-test-noflush-semantics.sh), and --noflush leaves
# every other chain (QCMAP's INPUT et al) untouched.
v4_rules="*filter
:QUECDECK - [0:0]
"
v6_rules="*filter
:QUECDECK6 - [0:0]
"
for port in "${PORTS[@]}"; do
    # IPv4: allow from LAN IP only, block all other interfaces
    v4_rules+="-A QUECDECK -d $LAN_IP -p tcp --dport $port -j ACCEPT
-A QUECDECK -p tcp --dport $port -j DROP
"
    # IPv6: block all (admin UI is not expected to be reachable via IPv6)
    v6_rules+="-A QUECDECK6 -p tcp --dport $port -j DROP
"
done
v4_rules+="COMMIT
"
v6_rules+="COMMIT
"

# The one load-bearing apply: atomic, single lock acquisition (-w 5 bounded;
# a bare -w waits forever and a oneshot unit has no start timeout to break a
# wedged lock). Any failure applies NOTHING and fails the unit (fail closed,
# so lighttpd's Requires= keeps the UI down rather than serving unfirewalled);
# Restart=on-failure retries in 10s.
if ! printf '%s' "$v4_rules" | iptables-restore --noflush -w 5; then
    echo "firewall: iptables-restore failed; refusing to continue." >&2
    exit 1
fi

# Guard the flush-on-declare semantics: on an iptables build where --noflush
# APPENDS to declared chains instead, rules would accumulate silently on every
# restart. Exactly 2 rules per port or fail the unit loudly. A failed query
# (e.g. -w 5 lock timeout) is distinguished from a real mismatch so the error
# doesn't misdirect debugging toward a rules problem that isn't there.
if ! quecdeck_query=$(iptables -w 5 -S QUECDECK 2>&1); then
    echo "firewall: could not read back the QUECDECK chain to verify it; refusing to continue." >&2
    echo "firewall: $quecdeck_query" >&2
    exit 1
fi
expected=$(( 2 * ${#PORTS[@]} ))
actual=$(printf '%s\n' "$quecdeck_query" | grep -c '^-A QUECDECK')
if [ "$actual" -ne "$expected" ]; then
    echo "firewall: QUECDECK has $actual rules, expected $expected; refusing to continue." >&2
    exit 1
fi

# IPv6 stays best-effort: missing binaries can't fail the unit. One guard for
# chain body AND jumps so they always land together or not at all.
if command -v ip6tables-restore >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1; then
    printf '%s' "$v6_rules" | ip6tables-restore --noflush -w 5 2>/dev/null || true
    while ip6tables -w 5 -D INPUT -j QUECDECK6 2>/dev/null; do :; done
    ip6tables -w 5 -I INPUT -j QUECDECK6 2>/dev/null || true
fi

# Reinsert the IPv4 INPUT jump (outside the restore: its format cannot express
# delete-until-absent or insert-at-top). Delete until absent so duplicate
# jumps from any earlier run converge to the single insert; the insert is
# load-bearing and fails the unit on error, same rationale as the restore.
while iptables -w 5 -D INPUT -j QUECDECK 2>/dev/null; do :; done
if ! iptables -w 5 -I INPUT -j QUECDECK; then
    echo "firewall: failed to install the IPv4 INPUT jump; refusing to continue." >&2
    exit 1
fi

exit 0
