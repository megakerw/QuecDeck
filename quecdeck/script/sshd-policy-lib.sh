#!/bin/bash
# The authentication and forwarding posture every QuecDeck sshd must report.
#
# One definition, checked by the installer against a candidate file and by
# ssh_keys.sh against the live daemon on every start. Keeping it in two places
# is how the permitrootlogin spelling once changed at three sites and passed the
# whole test suite.
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
