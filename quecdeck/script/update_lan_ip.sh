#!/bin/sh

CONFIG_FILE="/etc/data/mobileap_cfg.xml"
LIGHTTPD_CONF="/usrdata/quecdeck/lighttpd.conf"
QUECDECK_DIR="/usrdata/quecdeck"

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

# Update lighttpd.conf binding if the IP has changed (e.g. after an update
# that resets the conf to 0.0.0.0) and restart sshd to rebind.
current_ip=$(grep -o 'server\.bind = "[0-9.]*"' "$LIGHTTPD_CONF" | grep -o '"[0-9.]*"' | tr -d '"')
if [ "$current_ip" != "$LAN_IP" ]; then
    LAN_IP_ESC=$(printf '%s' "$LAN_IP" | sed 's/[\/&]/\\&/g')
    sed -i "s/server\.bind = \"[0-9.]*\"/server.bind = \"$LAN_IP_ESC\"/" "$LIGHTTPD_CONF"
    sed -i "s/== \"[0-9.]*:443\"/== \"$LAN_IP_ESC:443\"/" "$LIGHTTPD_CONF"
    systemctl is-active sshd >/dev/null 2>&1 && systemctl restart sshd
fi

# Regenerate TLS cert only if its SAN doesn't already match the current LAN IP.
# Checking the cert SAN directly (rather than the conf binding) avoids spurious
# regeneration after updates that reset lighttpd.conf to 0.0.0.0.
_cert_san=""
if [ -f "$QUECDECK_DIR/server.crt" ]; then
    _cert_san=$(openssl x509 -in "$QUECDECK_DIR/server.crt" -noout -text 2>/dev/null \
        | grep -o 'IP Address:[0-9.]*' | head -1 | sed 's/IP Address://')
fi
if [ "$_cert_san" = "$LAN_IP" ]; then
    exit 0
fi

_tmpconf=$(mktemp)
printf '[req]\ndistinguished_name=dn\n[dn]\n[san]\nsubjectAltName=IP:%s\n' "$LAN_IP" > "$_tmpconf"
openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
    -subj "/O=QuecDeck/CN=QuecDeck" \
    -config "$_tmpconf" -extensions san \
    -keyout "$QUECDECK_DIR/server.key" -out "$QUECDECK_DIR/server.crt"
rm -f "$_tmpconf"
chmod 600 "$QUECDECK_DIR/server.key"
