#!/bin/bash
# Read-only inspection of QCMAP's DHCPV4DNS/DHCPV6DNS settings and the
# resulting network state. Proxy changes require a modem reboot to take
# effect, so this test deliberately does not modify either setting.

set -u
. /usrdata/quecdeck/script/at-lib.sh

MODE=${1:---status}
case "$MODE" in
    --status|--require-enabled) ;;
    *) echo "Usage: $0 [--status|--require-enabled]" >&2; exit 2 ;;
esac

query_proxy() { atcmd_run "AT+QMAP=\"$1\"" 5000; }
proxy_state() {
    local setting=$1 reply
    reply=$(query_proxy "$setting") || {
        echo "FATAL: cannot query $setting" >&2
        return 1
    }
    case "$reply" in
        *\"$setting\"*\"enable\"*)  printf '%s\n' enable ;;
        *\"$setting\"*\"disable\"*) printf '%s\n' disable ;;
        *)
            echo "FATAL: unrecognized $setting response:" >&2
            printf '%s\n' "$reply" >&2
            return 1
            ;;
    esac
}

v4_state=$(proxy_state DHCPV4DNS) || exit 1
v6_state=$(proxy_state DHCPV6DNS) || exit 1

echo "DHCPV4DNS=$v4_state DHCPV6DNS=$v6_state"
echo "ADDR4"; ip -br -4 addr 2>/dev/null
echo "ADDR6"; ip -br -6 addr 2>/dev/null
echo "ROUTES4"; ip -4 route 2>/dev/null
echo "ROUTES6"; ip -6 route 2>/dev/null
echo "DNS_LISTEN"
(ss -lnut 2>/dev/null || netstat -lnut 2>/dev/null) | awk 'NR == 1 || $4 ~ /:53$/'
echo "INPUT4"; iptables -S INPUT 2>/dev/null | grep QUECDECK || true
echo "INPUT6"; ip6tables -S INPUT 2>/dev/null | grep QUECDECK6 || true
echo "RESOLVER"; sed -n '1,20p' /etc/resolv.conf 2>/dev/null

if [ "$MODE" = "--require-enabled" ] &&
   { [ "$v4_state" != enable ] || [ "$v6_state" != enable ]; }; then
    echo "FATAL: both onboard DNS proxies must be enabled before this post-reboot check" >&2
    exit 1
fi
