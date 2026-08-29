#!/bin/sh
# Read-only verification for the SSH enable and port contract. Run after saving
# either enabled or disabled settings on the Security page.

CONFIG=/opt/etc/ssh/sshd_config
MARKER=/opt/etc/ssh/quecdeck_enabled

pass=0
fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

[ "$(id -u)" = 0 ] || { echo "FATAL: run as root"; exit 1; }
[ -f /lib/systemd/system/sshd.service ] || { echo "FATAL: SSH is not installed"; exit 1; }

SSH_PORT=$(sed -n 's/^Port \([0-9][0-9]*\)$/\1/p' "$CONFIG")
case "$SSH_PORT" in ''|*[!0-9]*) echo "FATAL: configured SSH port is invalid"; exit 1 ;; esac
[ "$SSH_PORT" = 22 ] || { [ "$SSH_PORT" -ge 1024 ] && [ "$SSH_PORT" -le 65535 ]; } || {
    echo "FATAL: configured SSH port is not 22 or within 1024 to 65535"
    exit 1
}

rules=$(iptables -S QUECDECK 2>/dev/null | grep -cE -- "--dport $SSH_PORT( |$)")
if [ -f "$MARKER" ]; then
    [ "$(stat -c '%u %a' "$MARKER" 2>/dev/null)" = "0 600" ] &&
        grep -qx enabled "$MARKER" && ok "enable marker is root-only and valid" ||
        bad "enable marker ownership, mode, or content is invalid"
    [ "$rules" = 2 ] && ok "firewall has LAN accept and catch-all drop rules for port $SSH_PORT" ||
        bad "firewall has $rules rules for enabled SSH port $SSH_PORT, expected 2"
    if systemctl is-active --quiet sshd; then
        netstat -tln 2>/dev/null | grep -q ":$SSH_PORT " &&
            ok "active SSH server listens on port $SSH_PORT" ||
            bad "SSH is active but does not listen on port $SSH_PORT"
    else
        [ ! -s /usrdata/root/.ssh/authorized_keys ] &&
            ok "SSH remains inactive because no authorized key is available" ||
            bad "SSH is enabled with a key but is not active"
    fi
else
    systemctl is-active --quiet sshd && bad "SSH is active without its enable marker" ||
        ok "disabled SSH server is inactive"
    [ "$rules" = 0 ] && ok "disabled SSH port has no firewall allowance" ||
        bad "disabled SSH port still has $rules firewall rules"
fi

# The posture assertions in ssh_keys.sh and install_sshd.sh grep the CANONICAL
# spelling sshd prints, which is not always the spelling accepted in the config
# file. A mismatch refuses every start, so pin it against the real daemon here.
effective=$(/opt/sbin/sshd -T 2>/dev/null)
if [ -z "$effective" ]; then
    bad "sshd -T produced no output"
else
    for directive in \
        "passwordauthentication no" \
        "kbdinteractiveauthentication no" \
        "permitrootlogin prohibit-password" \
        "pubkeyauthentication yes" \
        "authenticationmethods publickey" \
        "authorizedkeysfile /usrdata/root/.ssh/authorized_keys" \
        "allowtcpforwarding no" \
        "allowagentforwarding no" \
        "allowstreamlocalforwarding no" \
        "gatewayports no" \
        "permittunnel no" \
        "x11forwarding no"
    do
        if printf '%s\n' "$effective" | grep -qx "$directive"; then
            ok "sshd reports: $directive"
        else
            bad "sshd does NOT report '$directive' (got: $(printf '%s\n' "$effective" | grep -i "^${directive%% *} " || echo absent))"
        fi
    done
fi

echo "Result: $pass passed, $fail failed"
[ "$fail" = 0 ]
