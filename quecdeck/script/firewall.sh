#!/bin/bash

# Standalone uninstallers use this exact marker before passing --remove. Older
# deployed copies ignore unknown arguments and would reapply the policy instead.
QUECDECK_FIREWALL_REMOVE_API=1

# Remove only the chains owned by QuecDeck. This path deliberately runs before
# the startup delay and LAN checks so uninstall also works while networking is
# down. Missing jumps and chains mean the policy is already clean. Command
# failures still fail the removal.
remove_chain() { # remove_chain <iptables command> <chain>
    local table_command=$1 chain=$2 rules jump_count

    if ! rules=$("$table_command" -w 5 -S 2>&1); then
        echo "firewall: could not inspect rules while removing $chain." >&2
        echo "firewall: $rules" >&2
        return 1
    fi

    jump_count=$(printf '%s\n' "$rules" | grep -c "^-A INPUT -j $chain\$")
    while [ "$jump_count" -gt 0 ]; do
        if ! "$table_command" -w 5 -D INPUT -j "$chain"; then
            echo "firewall: failed to remove a $chain INPUT jump." >&2
            return 1
        fi
        jump_count=$((jump_count - 1))
    done

    if printf '%s\n' "$rules" | grep -q "^-N $chain\$"; then
        "$table_command" -w 5 -F "$chain" &&
            "$table_command" -w 5 -X "$chain" || {
                echo "firewall: failed to remove the $chain chain." >&2
                return 1
            }
    fi

    return 0
}

if [ "${1:-}" = "--remove" ]; then
    failed=0
    command -v ip6tables >/dev/null 2>&1 && remove_chain ip6tables QUECDECK6 || failed=1
    command -v iptables >/dev/null 2>&1 && remove_chain iptables QUECDECK || failed=1
    exit "$failed"
fi

# TCP ports to allow on LAN IP and block everywhere else
PORTS=("80" "443")
SSH_HELPER=/usrdata/quecdeck/script/ssh_keys.sh

# ssh_keys.sh owns sshd_config and the root-owned enable marker, and its status
# action reports both already validated. Asking it keeps the rule here from
# drifting from the port sshd actually binds. Both scripts are root-only, and
# status never calls back into this one. A missing helper means SSH is not
# managed here. Any other failure refuses to change the existing policy.
ssh_enabled=0
ssh_port=""
if [ -x "$SSH_HELPER" ]; then
    ssh_status=$("$SSH_HELPER" status 2>/dev/null)
    ssh_status_rc=$?
    case "$ssh_status_rc" in
        0) IFS=$'\t' read -r ssh_enabled ssh_port <<< "$ssh_status" ;;
        3) ;;
        *)
            echo "firewall: SSH state is unreadable. Refusing to apply the policy." >&2
            exit 1
            ;;
    esac
fi
if [ "$ssh_enabled" = 1 ]; then
    # The policy bounds live in ssh_keys.sh. Assert only the shape before the
    # value reaches iptables.
    case "$ssh_port" in ''|*[!0-9]*)
        echo "firewall: SSH reported a non-numeric port. Refusing to apply the policy." >&2
        exit 1
        ;;
    esac
    PORTS=("$ssh_port" "${PORTS[@]}")
fi

# The firmware units ordered before firewall.service report started before their
# asynchronous IPPT, Ethernet, dnsmasq, and iptables work has settled. During
# boot, defer policy installation to a fixed uptime boundary. A later service
# start (including install, update, or manual restart) proceeds immediately.
firmware_settle_delay() { # firmware_settle_delay <whole uptime seconds>
    local uptime_secs=$1
    case "$uptime_secs" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$uptime_secs" -lt 60 ]; then
        echo $((60 - uptime_secs))
    else
        echo 0
    fi
}

if ! read -r uptime_value _ < /proc/uptime ||
   ! settle_delay=$(firmware_settle_delay "${uptime_value%.*}"); then
    echo "firewall: could not read system uptime. Refusing to apply the policy." >&2
    exit 1
fi
[ "$settle_delay" -eq 0 ] || sleep "$settle_delay"

. /usrdata/quecdeck/script/lan-ip-lib.sh || exit 1
resolve_lan_ip

# bridge0 is the tested LAN ingress for both routed/NAT and IPPT modes. An
# interface name can be loaded into iptables before it exists, which would make
# the unit look healthy while the following DROP rules quietly lock out every
# client. Verify both the interface and its address instead. A transient QCMAP
# delay fails this run, and systemd retries in 10 seconds. A firmware topology change
# stays fail-closed and leaves a useful error rather than weakening the policy.
if ! ip link show bridge0 >/dev/null 2>&1; then
    echo "firewall: LAN bridge bridge0 does not exist. Refusing to apply the policy." >&2
    exit 1
fi
if ! ip -4 addr show dev bridge0 2>/dev/null | grep -qE "[[:space:]]inet[[:space:]]+$LAN_IP/"; then
    echo "firewall: LAN address $LAN_IP is not assigned to bridge0. Refusing to apply the policy." >&2
    exit 1
fi

# Both address families are part of the declared policy. Refuse to modify one
# family when the other cannot be managed, rather than silently running with
# only half of the firewall installed.
for command_name in iptables iptables-restore ip6tables ip6tables-restore; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "firewall: required command $command_name is unavailable. Refusing to apply the policy." >&2
        exit 1
    fi
done

# Build the chain body once. Both address families derive from it. The
# declared chain line (:QUECDECK) is flushed-and-refilled atomically by
# iptables-restore --noflush (device semantics verified on the 1.8.4 legacy
# build by tests/device/device-test-noflush-semantics.sh), and --noflush leaves
# every other chain (QCMAP's INPUT et al) untouched.
v4_rules="*filter
:QUECDECK - [0:0]
"
v6_rules="*filter
:QUECDECK6 - [0:0]
"

# Every protected IPv4 service has the same policy: accept only traffic entering
# through the LAN bridge and addressed to the LAN endpoint, then drop all other
# traffic to that protocol/port. Keep rule generation here so a newly protected
# service cannot accidentally receive only half of the policy. The expected counter tracks
# the generated body for the post-apply accumulation check below.
expected=0
expected_v6=0
add_v4_lan_only() { # add_v4_lan_only <protocol> <port>
    local protocol=$1 port=$2
    v4_rules+="-A QUECDECK -i bridge0 -d $LAN_IP -p $protocol --dport $port -j ACCEPT
-A QUECDECK -p $protocol --dport $port -j DROP
"
    expected=$((expected + 2))
}

add_v6_lan_only() { # add_v6_lan_only <protocol> <port>
    local protocol=$1 port=$2
    v6_rules+="-A QUECDECK6 -i bridge0 -d fe80::/10 -p $protocol --dport $port -j ACCEPT
-A QUECDECK6 -p $protocol --dport $port -j DROP
"
    expected_v6=$((expected_v6 + 2))
}

# QCMAP's dnsmasq also binds the IPPT-assigned address on bridge0. DHCP is
# intentionally untouched because its initial request is broadcast.
add_v4_lan_only udp 53
add_v4_lan_only tcp 53
add_v6_lan_only udp 53
add_v6_lan_only tcp 53

for port in "${PORTS[@]}"; do
    add_v4_lan_only tcp "$port"
    # IPv6: block all (admin UI is not expected to be reachable via IPv6)
    v6_rules+="-A QUECDECK6 -p tcp --dport $port -j DROP
"
    expected_v6=$((expected_v6 + 1))
done
v4_rules+="COMMIT
"
v6_rules+="COMMIT
"

# The one load-bearing apply is atomic and uses one bounded lock acquisition.
# A bare -w waits forever, and a oneshot unit has no start timeout to break a
# wedged lock. Any failure applies NOTHING and fails the unit (fail closed,
# so lighttpd's Requires= keeps the UI down rather than serving unfirewalled).
# Restart=on-failure retries in 10s.
if ! printf '%s' "$v4_rules" | iptables-restore --noflush -w 5; then
    echo "firewall: iptables-restore failed. Refusing to continue." >&2
    exit 1
fi

# Guard the flush-on-declare semantics: on an iptables build where --noflush
# APPENDS to declared chains instead, rules would accumulate silently on every
# restart. The helper counts every generated pair so changes to the service list
# cannot drift from this check. A query failure (such as a -w 5 lock timeout) is
# distinguished from a real mismatch so the error points to the correct cause.
if ! quecdeck_query=$(iptables -w 5 -S QUECDECK 2>&1); then
    echo "firewall: could not read back the QUECDECK chain to verify it. Refusing to continue." >&2
    echo "firewall: $quecdeck_query" >&2
    exit 1
fi
actual=$(printf '%s\n' "$quecdeck_query" | grep -c '^-A QUECDECK')
if [ "$actual" -ne "$expected" ]; then
    echo "firewall: QUECDECK has $actual rules, expected $expected. Refusing to continue." >&2
    exit 1
fi

# IPv6 is load-bearing too. Its chain is replaced atomically and read back
# before the INPUT jump is touched, matching the IPv4 failure semantics.
if ! printf '%s' "$v6_rules" | ip6tables-restore --noflush -w 5; then
    echo "firewall: ip6tables-restore failed. Refusing to continue." >&2
    exit 1
fi
if ! quecdeck6_query=$(ip6tables -w 5 -S QUECDECK6 2>&1); then
    echo "firewall: could not read back the QUECDECK6 chain. Refusing to continue." >&2
    echo "firewall: $quecdeck6_query" >&2
    exit 1
fi
actual_v6=$(printf '%s\n' "$quecdeck6_query" | grep -c '^-A QUECDECK6')
if [ "$actual_v6" -ne "$expected_v6" ]; then
    echo "firewall: QUECDECK6 has $actual_v6 rules, expected $expected_v6. Refusing to continue." >&2
    exit 1
fi

# Converge the IPv4 INPUT jump to exactly one without first deleting the last
# working jump. The restore format cannot express this conditional mutation.
# Insert a missing jump. Remove duplicate jumps one at a time without deleting
# the last one. Re-read after every operation so a concurrent QCMAP rebuild cannot
# make a stale count drive an unsafe delete. Bound the loop so repeated external
# mutation fails the unit instead of hanging its startup indefinitely.
converge_input_jump() {
    local table_command=${1:-iptables} chain=${2:-QUECDECK}
    local jump_attempts=0 input_query jump_count
    while [ "$jump_attempts" -lt 10 ]; do
        if ! input_query=$("$table_command" -w 5 -S INPUT 2>&1); then
            echo "firewall: could not read INPUT while verifying the $chain jump. Refusing to continue." >&2
            echo "firewall: $input_query" >&2
            return 1
        fi
        jump_count=$(printf '%s\n' "$input_query" | grep -c "^-A INPUT -j $chain\$")
        case "$jump_count" in
            1) break ;;
            0)
                if ! "$table_command" -w 5 -I INPUT -j "$chain"; then
                    echo "firewall: failed to install the $chain INPUT jump. Refusing to continue." >&2
                    return 1
                fi
                ;;
            *)
                if ! "$table_command" -w 5 -D INPUT -j "$chain"; then
                    echo "firewall: failed to remove a duplicate $chain INPUT jump. Refusing to continue." >&2
                    return 1
                fi
                ;;
        esac
        jump_attempts=$((jump_attempts + 1))
    done

    # The tenth operation may itself have reached the target, so verify current
    # state rather than judging the count observed immediately before it.
    if ! input_query=$("$table_command" -w 5 -S INPUT 2>&1); then
        echo "firewall: could not perform the final INPUT jump check. Refusing to continue." >&2
        echo "firewall: $input_query" >&2
        return 1
    fi
    jump_count=$(printf '%s\n' "$input_query" | grep -c "^-A INPUT -j $chain\$")
    if [ "$jump_count" -ne 1 ]; then
        echo "firewall: $chain INPUT jump did not converge to one after $jump_attempts attempts. Refusing to continue." >&2
        return 1
    fi
}

converge_input_jump ip6tables QUECDECK6 || exit 1
converge_input_jump iptables QUECDECK || exit 1

exit 0
