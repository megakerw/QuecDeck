#!/bin/sh
# Publishes the LAN address sshd must bind, as an Include fragment on tmpfs
# rather than as an edit to sshd_config. The daemon reads it while parsing its
# configuration, so the configuration file itself stays byte-identical to what
# the installer wrote and verified, and no boot writes ever reach flash.
#
# Every failure path below exits non-zero, and this runs as an ExecStartPre, so
# the daemon never starts against a missing or stale fragment. That ordering,
# not sshd's Include behaviour, is what keeps a failed read off a listening
# socket: an include that tolerates a missing path would otherwise leave sshd
# with no ListenAddress at all, which means every interface.

RUNTIME_DIR=/run/quecdeck
LISTEN_CONF="$RUNTIME_DIR/sshd-listen.conf"

. /usrdata/quecdeck/script/lan-ip-lib.sh || exit 1
resolve_lan_ip

# Root-owned runtime dir, never a symlink: nothing unprivileged can pre-plant
# the fragment the daemon is about to read.
[ ! -L "$RUNTIME_DIR" ] || exit 1
mkdir -p "$RUNTIME_DIR" || exit 1
[ -d "$RUNTIME_DIR" ] && [ ! -L "$RUNTIME_DIR" ] || exit 1
chown root:root "$RUNTIME_DIR" && chmod 755 "$RUNTIME_DIR" || exit 1
[ ! -L "$LISTEN_CONF" ] || exit 1

_tmp="$LISTEN_CONF.tmp.$$"
if ! printf 'ListenAddress %s\n' "$LAN_IP" > "$_tmp" ||
   ! chown root:root "$_tmp" || ! chmod 644 "$_tmp" ||
   ! mv -f "$_tmp" "$LISTEN_CONF"; then
    rm -f "$_tmp"
    exit 1
fi

# Entware's rc.unslung runs every S* script in /opt/etc/init.d/ at boot, and the
# openssh package's postinst recreates one on any opkg upgrade. That second
# daemon reads this same hardened config, so the risk is not weak crypto: it is
# that it starts outside this unit and therefore past every gate on it, with no
# enable marker, no firewall check, and no bind fragment. The installer reaps it
# too, this covers an upgrade done by hand afterwards.
# Never fatal: a stray init script must not block a legitimate start.
rm -f /opt/etc/init.d/*sshd* 2>/dev/null || :
