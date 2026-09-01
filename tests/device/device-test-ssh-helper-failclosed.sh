#!/bin/sh
# Verifies that the firewall refuses to rebuild when QuecDeck-managed SSH state
# remains but its access helper is unavailable. The helper is moved briefly and
# restored by a trap. The firewall script must fail before touching iptables, so
# the installed rules are compared before and after. No service is restarted.
#
# Run from ADB as root with SSH installed:
#
#   sh device-test-ssh-helper-failclosed.sh

HELPER=/usrdata/quecdeck/script/ssh_access.sh
BACKUP=${HELPER}.device-test-backup
FIREWALL=/usrdata/quecdeck/script/firewall.sh

restore_helper() {
    [ ! -e "$BACKUP" ] || mv -f "$BACKUP" "$HELPER"
}
trap restore_helper EXIT INT TERM

[ "$(id -u)" = 0 ] || { echo "FATAL: run as root"; exit 1; }
[ -x "$HELPER" ] || { echo "FATAL: $HELPER is missing or not executable"; exit 1; }
[ -x "$FIREWALL" ] || { echo "FATAL: $FIREWALL is missing or not executable"; exit 1; }
[ ! -e "$BACKUP" ] || { echo "FATAL: stale test backup exists at $BACKUP"; exit 1; }

if [ ! -e /opt/etc/ssh/quecdeck_enabled ] &&
   [ "$(readlink /lib/systemd/system/sshd.service 2>/dev/null)" != /usrdata/quecdeck/optional/sshd/sshd.service ] &&
   ! grep -Fqx 'Include /run/quecdeck/sshd-listen.conf' /opt/etc/ssh/sshd_config 2>/dev/null; then
    echo "FATAL: no QuecDeck-managed SSH state is installed"
    exit 1
fi

before_v4=$(iptables -S 2>/dev/null) || { echo "FATAL: could not read IPv4 rules"; exit 1; }
before_v6=$(ip6tables -S 2>/dev/null) || { echo "FATAL: could not read IPv6 rules"; exit 1; }

mv "$HELPER" "$BACKUP" || { echo "FATAL: could not move the helper"; exit 1; }
output=$(/bin/bash "$FIREWALL" 2>&1)
rc=$?
restore_helper

after_v4=$(iptables -S 2>/dev/null) || { echo "FAIL: could not read IPv4 rules afterwards"; exit 1; }
after_v6=$(ip6tables -S 2>/dev/null) || { echo "FAIL: could not read IPv6 rules afterwards"; exit 1; }

if [ "$rc" -eq 0 ]; then
    echo "FAIL: firewall accepted managed SSH state without its helper"
    exit 1
fi
printf '%s\n' "$output" | grep -q 'SSH is managed but its access helper is missing' || {
    echo "FAIL: firewall failed for the wrong reason"
    printf '%s\n' "$output"
    exit 1
}
[ "$before_v4" = "$after_v4" ] || { echo "FAIL: IPv4 rules changed"; exit 1; }
[ "$before_v6" = "$after_v6" ] || { echo "FAIL: IPv6 rules changed"; exit 1; }

echo "PASS: managed SSH fails closed without changing firewall rules"
