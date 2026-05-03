#!/bin/sh

CONFIG_FILE="/etc/data/mobileap_cfg.xml"
SSHD_CONF="/opt/etc/ssh/sshd_config"

LAN_IP=""
if [ -f "$CONFIG_FILE" ]; then
    LAN_IP=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' "$CONFIG_FILE" | sed 's/<APIPAddr>//;s/<\/APIPAddr>//')
fi
if ! printf '%s' "$LAN_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || \
   ! printf '%s' "$LAN_IP" | awk -F. '$1>255||$2>255||$3>255||$4>255{exit 1}'; then
    LAN_IP="192.168.225.1"
fi

current=$(grep "^ListenAddress" "$SSHD_CONF" 2>/dev/null | head -1 | awk '{print $2}')
if [ "$current" != "$LAN_IP" ]; then
    sed -i "/ListenAddress/d" "$SSHD_CONF"
    echo "ListenAddress $LAN_IP" >> "$SSHD_CONF"
fi
