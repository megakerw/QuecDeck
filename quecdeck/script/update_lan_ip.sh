#!/bin/sh

CONFIG_FILE="/etc/data/mobileap_cfg.xml"
LIGHTTPD_CONF="/usrdata/quecdeck/lighttpd.conf"

LAN_IP=""
if [ -f "$CONFIG_FILE" ]; then
    LAN_IP=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' "$CONFIG_FILE" | sed 's/<APIPAddr>//;s/<\/APIPAddr>//')
fi
# Validate extracted IP: dotted-decimal format with each octet in 0-255.
# Guards against malformed or malicious content in the XML reaching sed.
if ! printf '%s' "$LAN_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || \
   ! printf '%s' "$LAN_IP" | awk -F. '$1>255||$2>255||$3>255||$4>255{exit 1}'; then
    LAN_IP="192.168.225.1"
fi

current_ip=$(grep -o 'server\.bind = "[0-9.]*"' "$LIGHTTPD_CONF" | grep -o '"[0-9.]*"' | tr -d '"')
if [ "$current_ip" = "$LAN_IP" ]; then
    exit 0
fi

LAN_IP_ESC=$(printf '%s' "$LAN_IP" | sed 's/[\/&]/\\&/g')
sed -i "s/server\.bind = \"[0-9.]*\"/server.bind = \"$LAN_IP_ESC\"/" "$LIGHTTPD_CONF"
sed -i "s/== \"[0-9.]*:443\"/== \"$LAN_IP_ESC:443\"/" "$LIGHTTPD_CONF"

# Restart sshd if running so it rebinds to the new LAN IP
systemctl is-active sshd >/dev/null 2>&1 && systemctl restart sshd
