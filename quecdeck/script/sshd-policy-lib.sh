#!/bin/bash
# The authentication and forwarding posture every QuecDeck sshd must report.
#
# One definition, checked by the installer against a candidate file and by
# ssh_access.sh against the live daemon on every start.
#
# Spellings are the CANONICAL forms sshd -T prints, which are not always the
# forms sshd_config accepts. Device-verified on OpenSSH here: prohibit-password
# is reported as prohibit-password, not the legacy without-password.
#
# Tuning knobs (LoginGraceTime, ClientAlive*, MaxSessions, MaxStartups) are
# deliberately absent. A mismatch here refuses to start the daemon, so only the
# directives that bound what a key grants belong in this list.

SSHD_POLICY="passwordauthentication no
kbdinteractiveauthentication no
permitrootlogin prohibit-password
pubkeyauthentication yes
authenticationmethods publickey
authorizedkeysfile /usrdata/root/.ssh/authorized_keys
allowtcpforwarding no
allowagentforwarding no
allowstreamlocalforwarding no
gatewayports no
permittunnel no
x11forwarding no"

valid_ssh_port() { # valid_ssh_port <port>
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 5 ] || return 1
    [ "$1" = 22 ] || { [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]; }
}

# Usage: sshd_policy_ok "$(sshd -T ...)"
sshd_policy_ok() { # sshd_policy_ok <sshd -T output>
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # -F: policy lines are literals, not patterns. Without it the dots in
        # the authorizedkeysfile path are wildcards, so a different path could
        # satisfy the assertion.
        printf '%s\n' "$1" | grep -Fqx "$line" || return 1
    done <<< "$SSHD_POLICY"
}
