#!/bin/sh
# Bind-fragment verification. The LAN address lighttpd and sshd bind lives in a
# tmpfs Include fragment under /run/quecdeck rather than in either config file,
# so the installed configs stay byte-identical to their release manifest. This
# exercises every way that fragment can go missing:
#
#   1. Units carry the publisher: lighttpd and sshd both republish in
#      ExecStartPre, and sshd republishes in ExecReload BEFORE the SIGHUP
#      (read-only).
#   2. lighttpd fails closed: with the fragment gone its config will not parse
#      (include of a missing literal path is fatal), so it can never fall back
#      to a wildcard bind. Parse-only, does not touch the running server.
#   3. lighttpd recovers: delete the fragment, restart, ExecStartPre republishes
#      it and the server comes back on the LAN address.
#   4. Both publishers refuse a symlinked runtime dir and write nothing through
#      the symlink.
#   5. sshd reload is safe: delete the fragment, `systemctl reload sshd`, and
#      the daemon stays on the LAN address because ExecReload republishes first.
#   6. NEGATIVE CONTROL: a raw SIGHUP with the fragment gone binds every
#      interface. sshd tolerates a missing Include and then has no
#      ListenAddress at all. This is the bug check 5 prevents, and it is why
#      ExecReload must not be a bare kill.
#
# Run as root with QuecDeck installed. Checks 5 and 6 additionally need sshd
# installed; they are skipped if it is not.
#
#     sh device-test-bind-fragment.sh        # prompts before disrupting
#     sh device-test-bind-fragment.sh -y     # skip the prompt
#
# DISRUPTIVE: the web UI drops for a few seconds in check 3, and sshd is
# started, reloaded and restarted in checks 5-6. Run from adb, not over ssh.
#
# If no authorized key exists, a throwaway is generated to make sshd startable
# and removed afterwards. Its private half is destroyed before sshd starts, so
# the key is unusable by anyone for the whole run. An existing authorized_keys
# is used as-is and never modified. The brief wildcard bind in check 6 stays
# behind the firewall's LAN-only rule for the SSH port. Everything is restored
# on exit, including Ctrl-C, by an EXIT trap.

RUNTIME_DIR=/run/quecdeck
LIGHTTPD_FRAG="$RUNTIME_DIR/lighttpd-listen.conf"
SSHD_FRAG="$RUNTIME_DIR/sshd-listen.conf"
LIGHTTPD_CONF=/usrdata/quecdeck/lighttpd.conf
LIGHTTPD_PRESTART=/usrdata/quecdeck/script/lighttpd_prestart.sh
SSHD_PUBLISHER=/usrdata/quecdeck/optional/sshd/update_sshd_ip.sh
SSHD_UNIT=/lib/systemd/system/sshd.service
SSHD_CONFIG=/opt/etc/ssh/sshd_config
ENABLED_MARKER=/opt/etc/ssh/quecdeck_enabled
ROOT_SSH_DIR=/usrdata/root/.ssh
KEYS="$ROOT_SSH_DIR/authorized_keys"
DIR=/tmp/quecdeck-bindfrag

YES=0
case "$1" in -y|--yes) YES=1 ;; esac

pass=0; fail=0; skip=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }
note() { echo "  SKIP: $1"; skip=$((skip+1)); }

# Local address column only. netstat prints "0.0.0.0:*" as the FOREIGN address
# on every LISTEN row, so matching the whole line reports a false wildcard.
listen_addrs() { # listen_addrs <process pattern>
    netstat -tlnp 2>/dev/null | awk -v p="$1" '$0 ~ p {print $4}'
}
is_wildcard() { # is_wildcard <process pattern>
    listen_addrs "$1" | grep -qE '^(0\.0\.0\.0|:::|\[::\])'
}
bound_to() { # bound_to <process pattern> <address>
    listen_addrs "$1" | grep -q "^$2:"
}

ssh_installed() { [ -x /opt/sbin/sshd ] && [ -f "$SSHD_UNIT" ]; }

LAN_IP=""
resolve_expected_ip() {
    . /usrdata/quecdeck/script/lan-ip-lib.sh 2>/dev/null || return 1
    resolve_lan_ip
    [ -n "$LAN_IP" ]
}

SSH_PORT=$(sed -n 's/^Port \([0-9][0-9]*\)$/\1/p' "$SSHD_CONFIG" 2>/dev/null | head -1)
[ -n "$SSH_PORT" ] || SSH_PORT=22

KEY_PLANTED=0
SSHDIR_CREATED=0
MARKER_PLANTED=0
SSHD_WAS_ACTIVE=0
RUNTIME_MOVED=0

restore() {
    if [ "$RUNTIME_MOVED" = "1" ]; then
        [ -L "$RUNTIME_DIR" ] && rm -f "$RUNTIME_DIR"
        [ -d "$DIR/runtime" ] && mv "$DIR/runtime" "$RUNTIME_DIR"
        RUNTIME_MOVED=0
    fi
    [ -f "$LIGHTTPD_FRAG" ] || sh "$LIGHTTPD_PRESTART" >/dev/null 2>&1
    if ssh_installed; then
        [ -f "$SSHD_FRAG" ] || sh "$SSHD_PUBLISHER" >/dev/null 2>&1
        [ "$SSHD_WAS_ACTIVE" = "1" ] || systemctl stop sshd >/dev/null 2>&1
    fi
    if [ "$KEY_PLANTED" = "1" ]; then
        rm -f "$KEYS"
        KEY_PLANTED=0
    fi
    if [ "$SSHDIR_CREATED" = "1" ]; then
        rmdir "$ROOT_SSH_DIR" 2>/dev/null
        SSHDIR_CREATED=0
    fi
    if [ "$MARKER_PLANTED" = "1" ]; then
        rm -f "$ENABLED_MARKER"
        MARKER_PLANTED=0
    fi
    systemctl is-active --quiet lighttpd 2>/dev/null || systemctl start lighttpd >/dev/null 2>&1
    systemctl reset-failed lighttpd sshd >/dev/null 2>&1
    rm -rf "$DIR"
}
trap restore EXIT INT TERM

[ "$(id -u)" = 0 ] || { echo "Must run as root."; exit 1; }
[ -f "$LIGHTTPD_CONF" ] || { echo "QuecDeck is not installed."; exit 1; }

if [ "$YES" != "1" ]; then
    echo "This drops the web UI for a few seconds and cycles sshd."
    printf "Continue? [y/N] "
    read _a
    case "$_a" in y|Y) ;; *) echo "Aborted."; exit 1 ;; esac
fi

rm -rf "$DIR"; mkdir -p "$DIR" || { echo "Cannot create $DIR"; exit 1; }
resolve_expected_ip || { echo "Cannot resolve the expected LAN address."; exit 1; }
echo "Expected LAN address: $LAN_IP    SSH port: $SSH_PORT"

echo
echo "=== 1. units carry the publisher ==="
if grep -q '^ExecStartPre=.*lighttpd_prestart\.sh' /lib/systemd/system/lighttpd.service 2>/dev/null; then
    ok "lighttpd republishes in ExecStartPre"
else
    bad "lighttpd unit does not republish in ExecStartPre"
fi
if ssh_installed; then
    if grep -q '^ExecStartPre=.*update_sshd_ip\.sh' "$SSHD_UNIT"; then
        ok "sshd republishes in ExecStartPre"
    else
        bad "sshd unit does not republish in ExecStartPre"
    fi
    _pub=$(grep -n '^ExecReload=.*update_sshd_ip\.sh' "$SSHD_UNIT" | head -1 | cut -d: -f1)
    _kill=$(grep -n '^ExecReload=.*kill' "$SSHD_UNIT" | head -1 | cut -d: -f1)
    if [ -n "$_pub" ] && [ -n "$_kill" ] && [ "$_pub" -lt "$_kill" ]; then
        ok "sshd republishes in ExecReload before the signal"
    else
        bad "sshd ExecReload signals without republishing first"
    fi
else
    note "sshd not installed, unit checks skipped"
fi

echo
echo "=== 2. lighttpd fails closed without the fragment ==="
cp "$LIGHTTPD_FRAG" "$DIR/lighttpd-frag.bak" 2>/dev/null
rm -f "$LIGHTTPD_FRAG"
/opt/sbin/lighttpd -tt -f "$LIGHTTPD_CONF" >"$DIR/parse.out" 2>&1
_rc=$?
if [ "$_rc" -ne 0 ]; then
    ok "config refuses to parse without the fragment (rc=$_rc)"
else
    bad "config parsed WITHOUT the fragment: a wildcard bind is reachable"
    sed 's/^/    /' "$DIR/parse.out"
fi
sh "$LIGHTTPD_PRESTART" >/dev/null 2>&1
[ -f "$LIGHTTPD_FRAG" ] || bad "could not republish the lighttpd fragment"

echo
echo "=== 3. lighttpd recovers on restart ==="
rm -f "$LIGHTTPD_FRAG"
systemctl restart lighttpd >/dev/null 2>&1
_i=0
while [ "$_i" -lt 15 ]; do
    systemctl is-active --quiet lighttpd 2>/dev/null && break
    sleep 1; _i=$((_i+1))
done
if [ -f "$LIGHTTPD_FRAG" ]; then
    ok "ExecStartPre republished the fragment"
else
    bad "fragment was not republished on restart"
fi
if systemctl is-active --quiet lighttpd 2>/dev/null; then
    ok "lighttpd active after restart"
else
    bad "lighttpd did not come back"
fi
if is_wildcard lighttpd; then
    bad "lighttpd bound a wildcard address"
else
    ok "lighttpd bound no wildcard address"
fi
if bound_to lighttpd "$LAN_IP"; then
    ok "lighttpd bound $LAN_IP"
else
    bad "lighttpd is not bound to $LAN_IP"
fi

echo
echo "=== 4. publishers refuse a symlinked runtime dir ==="
mv "$RUNTIME_DIR" "$DIR/runtime" && RUNTIME_MOVED=1
if [ "$RUNTIME_MOVED" = "1" ]; then
    ln -s "$DIR/symlink-target" "$RUNTIME_DIR"
    sh "$LIGHTTPD_PRESTART" >/dev/null 2>&1
    [ "$?" -ne 0 ] && ok "lighttpd publisher refused the symlink" \
                   || bad "lighttpd publisher accepted a symlinked runtime dir"
    if ssh_installed; then
        sh "$SSHD_PUBLISHER" >/dev/null 2>&1
        [ "$?" -ne 0 ] && ok "sshd publisher refused the symlink" \
                       || bad "sshd publisher accepted a symlinked runtime dir"
    fi
    if [ -e "$DIR/symlink-target" ]; then
        bad "a publisher wrote THROUGH the symlink"
    else
        ok "nothing was written through the symlink"
    fi
    rm -f "$RUNTIME_DIR"
    mv "$DIR/runtime" "$RUNTIME_DIR" && RUNTIME_MOVED=0
    if [ -d "$RUNTIME_DIR" ] && [ ! -L "$RUNTIME_DIR" ]; then
        ok "runtime dir restored"
    else
        bad "runtime dir NOT restored"
    fi
else
    bad "could not move the runtime dir, symlink checks skipped"
fi

if ! ssh_installed; then
    echo
    note "sshd not installed, reload checks skipped"
    echo
    echo "passed: $pass  failed: $fail  skipped: $skip"
    [ "$fail" -eq 0 ] || exit 1
    exit 0
fi

echo
echo "=== 5. sshd reload republishes before signalling ==="
systemctl is-active --quiet sshd 2>/dev/null && SSHD_WAS_ACTIVE=1
if [ ! -d "$ROOT_SSH_DIR" ]; then
    mkdir -p "$ROOT_SSH_DIR" && chown root:root "$ROOT_SSH_DIR" && chmod 700 "$ROOT_SSH_DIR" \
        && SSHDIR_CREATED=1
fi
if [ ! -s "$KEYS" ]; then
    /opt/bin/ssh-keygen -t ed25519 -N '' -C 'quecdeck-bindfrag-test' -f "$DIR/tkey" >/dev/null 2>&1
    if [ -s "$DIR/tkey.pub" ]; then
        cat "$DIR/tkey.pub" > "$KEYS"
        chown root:root "$KEYS" && chmod 600 "$KEYS"
        KEY_PLANTED=1
        # Destroy the private half before sshd ever starts: the planted key is
        # then unusable by anyone for the rest of the run.
        rm -f "$DIR/tkey" "$DIR/tkey.pub"
        echo "  (planted a throwaway key, private half destroyed)"
    fi
fi
if [ ! -f "$ENABLED_MARKER" ]; then
    printf 'enabled\n' > "$ENABLED_MARKER" && chown root:root "$ENABLED_MARKER" \
        && chmod 600 "$ENABLED_MARKER" && MARKER_PLANTED=1
fi

if [ ! -s "$KEYS" ]; then
    note "no authorized key available, sshd reload checks skipped"
else
    sh "$SSHD_PUBLISHER" >/dev/null 2>&1
    systemctl reset-failed sshd >/dev/null 2>&1
    systemctl start sshd >/dev/null 2>&1
    _i=0
    while [ "$_i" -lt 15 ]; do
        systemctl is-active --quiet sshd 2>/dev/null && break
        sleep 1; _i=$((_i+1))
    done
    if ! systemctl is-active --quiet sshd 2>/dev/null; then
        bad "sshd would not start, reload checks skipped"
    else
        ok "sshd started"
        bound_to sshd "$LAN_IP" && ok "sshd bound $LAN_IP at startup" \
                                || bad "sshd not bound to $LAN_IP at startup"
        _pid1=$(systemctl show sshd -p MainPID --value)

        rm -f "$SSHD_FRAG"
        systemctl reload sshd >/dev/null 2>&1
        sleep 2
        if [ -f "$SSHD_FRAG" ]; then
            ok "ExecReload republished the fragment"
        else
            bad "reload did NOT republish the fragment"
        fi
        systemctl is-active --quiet sshd 2>/dev/null && ok "sshd survived the reload" \
                                                     || bad "sshd died on reload"
        if is_wildcard sshd; then
            bad "sshd bound a WILDCARD after reload"
        else
            ok "sshd bound no wildcard after reload"
        fi
        bound_to sshd "$LAN_IP" && ok "sshd still bound $LAN_IP after reload" \
                                || bad "sshd lost $LAN_IP after reload"

        echo
        echo "=== 6. negative control: raw SIGHUP with no fragment ==="
        _pid2=$(systemctl show sshd -p MainPID --value)
        rm -f "$SSHD_FRAG"
        kill -HUP "$_pid2" 2>/dev/null
        sleep 2
        if is_wildcard sshd; then
            ok "raw SIGHUP binds every interface (the bug ExecReload prevents)"
        else
            bad "raw SIGHUP did not reproduce the wildcard bind: check 5 proves nothing"
        fi
        sh "$SSHD_PUBLISHER" >/dev/null 2>&1
        systemctl restart sshd >/dev/null 2>&1
        sleep 2
        is_wildcard sshd && bad "still wildcard after restore" \
                         || ok "restored to a LAN-only bind"
    fi
fi

echo
echo "passed: $pass  failed: $fail  skipped: $skip"
[ "$fail" -eq 0 ] || exit 1
exit 0
