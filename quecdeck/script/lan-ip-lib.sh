#!/bin/sh
# Shared LAN address resolution for the boot-time publishers.
#
# The firewall, the web server, and sshd must all agree on which address they
# bind and protect. Three copies of this parsing drifted apart once already, so
# it lives here. POSIX sh: /bin/sh and /bin/bash callers both source it.
#
# cgi-lib.sh deliberately keeps its own reader. It batches through mobileap_read
# and has NO fallback on purpose, because a guessed value there would seed the
# settings form and be written back to the modem as if the user chose it.

QUECDECK_MOBILEAP_CFG=/etc/data/mobileap_cfg.xml
QUECDECK_DEFAULT_LAN_IP=192.168.225.1

# Sets LAN_IP to the modem's configured LAN address, falling back to the
# documented default when the value is absent or malformed. Always succeeds:
# every caller needs an address to bind or protect, and the validation keeps
# malformed XML content from reaching a sed or an iptables rule.
#
# First octet 0 is rejected because 0.0.0.0 passes every range check and binds
# a wildcard, which would put the web server and sshd on the WAN interface.
# Loopback and multicast or reserved space are rejected as bind addresses no
# access point serves from. The check stays this narrow on purpose: any address
# the modem can actually hold must survive it, because substituting the default
# for a live LAN address binds an address the box does not have.
resolve_lan_ip() { # resolve_lan_ip -> sets LAN_IP
    LAN_IP=""
    if [ -f "$QUECDECK_MOBILEAP_CFG" ]; then
        LAN_IP=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' "$QUECDECK_MOBILEAP_CFG" |
            sed 's/<APIPAddr>//;s/<\/APIPAddr>//')
    fi
    if ! printf '%s' "$LAN_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' ||
       ! printf '%s' "$LAN_IP" |
           awk -F. '$1>255||$2>255||$3>255||$4>255{exit 1}
                    $1==0||$1==127||$1>=224{exit 1}'; then
        LAN_IP=$QUECDECK_DEFAULT_LAN_IP
    fi
}
