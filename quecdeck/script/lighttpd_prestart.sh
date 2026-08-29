#!/bin/sh

PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
LIGHTTPD_CONF="/usrdata/quecdeck/lighttpd.conf"
QUECDECK_DIR="/usrdata/quecdeck"
RUNTIME_DIR=/run/quecdeck
LISTEN_CONF="$RUNTIME_DIR/lighttpd-listen.conf"

# Credential reset protection depends on www-data being unable to remove the
# root-owned htpasswd files. Refuse to start the web tier if the Entware config
# directory is a symlink, is not root-owned, or is writable by group or other.
secure_entware_config_dir() { # secure_entware_config_dir [path]
    _etc_dir=${1:-/opt/etc}
    [ -d "$_etc_dir" ] && [ ! -L "$_etc_dir" ] || return 1
    [ "$(stat -c %u "$_etc_dir" 2>/dev/null)" = 0 ] || return 1
    _etc_mode=$(stat -c %a "$_etc_dir" 2>/dev/null)
    case "$_etc_mode" in ''|*[!0-7]*) return 1 ;; esac
    [ $((0$_etc_mode & 022)) -eq 0 ]
}

if ! command -v stat >/dev/null 2>&1; then
    echo "FATAL: stat is unavailable, so /opt/etc permissions cannot be verified." >&2
    exit 1
fi
if ! secure_entware_config_dir; then
    echo "FATAL: /opt/etc must be a root-owned directory without group or other write access." >&2
    exit 1
fi

. /usrdata/quecdeck/script/lan-ip-lib.sh || exit 1
resolve_lan_ip

# Publish the bind address to tmpfs instead of editing the configuration file.
# lighttpd.conf is checksummed, so rewriting it in place moved the installed
# copy away from its manifest hash on the first boot after every install and
# made the file impossible to verify afterwards. Every failure here exits
# non-zero, and this runs as ExecStartPre, so the server never starts against a
# stale or missing fragment. That, not lighttpd's include behaviour, is what
# keeps a bad read from reaching a listening socket.
[ ! -L "$RUNTIME_DIR" ] || exit 1
mkdir -p "$RUNTIME_DIR" || exit 1
[ -d "$RUNTIME_DIR" ] && [ ! -L "$RUNTIME_DIR" ] || exit 1
chown root:root "$RUNTIME_DIR" && chmod 755 "$RUNTIME_DIR" || exit 1
[ ! -L "$LISTEN_CONF" ] || exit 1
_tmp="$LISTEN_CONF.tmp.$$"
if ! printf 'var.lan_ip = "%s"\n' "$LAN_IP" > "$_tmp" ||
   ! chown root:root "$_tmp" || ! chmod 644 "$_tmp" ||
   ! mv -f "$_tmp" "$LISTEN_CONF"; then
    rm -f "$_tmp"
    exit 1
fi

# One-time migration off the old in-place edit. Rewritten only when a literal
# address is still present, so the steady state costs no write to flash.
if grep -qE '^(server\.bind = "[0-9.]+"|\$SERVER\["socket"\] == "[0-9.]+:443")' "$LIGHTTPD_CONF" 2>/dev/null; then
    sed -i 's/^server\.bind = "[0-9.]*"/server.bind = var.lan_ip/' "$LIGHTTPD_CONF" || exit 1
    sed -i 's/^\$SERVER\["socket"\] == "[0-9.]*:443"/$SERVER["socket"] == var.lan_ip + ":443"/' "$LIGHTTPD_CONF" || exit 1
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
