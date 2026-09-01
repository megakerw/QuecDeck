# Firewall host tests.
# Sourced by tests/host/run-tests.sh.

# ------------------------------------------------ firewall ingress policy ---
# Destination address alone is not a LAN boundary: QCMAP places its rmnet
# drops before QUECDECK in IPPT mode but after it in routed mode. Both modes
# were device-probed and deliver real LAN HTTPS through bridge0.
eval "$(extract_fn quecdeck/script/firewall.sh firmware_settle_delay)"
t "firewall waits to uptime boundary from early boot" "36" "$(firmware_settle_delay 24)"
t "firewall has no delay at uptime boundary"          "0"  "$(firmware_settle_delay 60)"
t "firewall has no delay after boot settles"          "0"  "$(firmware_settle_delay 125)"
t "firewall rejects invalid uptime"                   "1"  "$(firmware_settle_delay invalid >/dev/null 2>&1; echo $?)"
t "firewall orders after late firmware network units" "yes" \
  "$(grep '^After=.*init_sys_mss.service.*ethernet-config.service.*ql-netd.service' quecdeck/systemd/firewall.service >/dev/null && echo yes || echo no)"
t "firewall helper requires LAN bridge and address" "yes" \
  "$(grep -q 'v4_rules+="-A QUECDECK -i bridge0 -d \$LAN_IP -p \$protocol --dport \$port -j ACCEPT' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall helper supplies paired catch-all DROP" "yes" \
  "$(grep -q -- '-A QUECDECK -p \$protocol --dport \$port -j DROP' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall has no destination-only ACCEPT template" "yes" \
  "$(! grep -q 'v4_rules+="-A QUECDECK -d \$LAN_IP .* -j ACCEPT' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall fails closed when bridge0 is absent" "yes" \
  "$(grep -q 'if ! ip link show bridge0' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall verifies LAN address belongs to bridge0" "yes" \
  "$(grep -q 'ip -4 addr show dev bridge0.*LAN_IP' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall protects UDP DNS through helper" "yes" \
  "$(grep -q '^add_v4_lan_only udp 53$' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall protects TCP DNS through helper" "yes" \
  "$(grep -q '^add_v4_lan_only tcp 53$' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall permits link-local UDP DNS through IPv6 helper" "yes" \
  "$(grep -q 'v6_rules+="-A QUECDECK6 -i bridge0 -d fe80::/10 -p \$protocol --dport \$port -j ACCEPT' quecdeck/script/firewall.sh && grep -q '^add_v6_lan_only udp 53$' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall permits link-local TCP DNS through IPv6 helper" "yes" \
  "$(grep -q '^add_v6_lan_only tcp 53$' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall IPv6 helper supplies catch-all DROP" "yes" \
  "$(grep -q -- '-A QUECDECK6 -p \$protocol --dport \$port -j DROP' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall requires both IPv6 commands" "yes" \
  "$(grep -q 'iptables iptables-restore ip6tables ip6tables-restore' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall treats IPv6 restore failure as fatal" "yes" \
  "$(grep -q 'if ! printf.*v6_rules.*ip6tables-restore' quecdeck/script/firewall.sh && ! grep 'ip6tables-restore' quecdeck/script/firewall.sh | grep -q '|| true' && echo yes || echo no)"
t "firewall verifies IPv6 rule count" "yes" \
  "$(grep -q '\[ "\$actual_v6" -ne "\$expected_v6" \]' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall protects every admin TCP port through helper" "yes" \
  "$(grep -q '^[[:space:]]*add_v4_lan_only tcp "\$port"$' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall helper updates rule-count check" "yes" \
  "$(grep -q 'expected=\$((expected + 2))' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall derives SSH exposure from the ssh_access status action" "yes" \
  "$(grep -q '^SSH_ACCESS_HELPER=/usrdata/quecdeck/script/ssh_access.sh$' quecdeck/script/firewall.sh && grep -q '"\$SSH_ACCESS_HELPER" status' quecdeck/script/firewall.sh && grep -q 'PORTS=("\$ssh_port"' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall keeps one SSH port parser" "yes" \
  "$(! grep -qE '^(SSHD_CONFIG|SSHD_ENABLED)=' quecdeck/script/firewall.sh && ! grep -q '^valid_ssh_port()' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall refuses policy on an unreadable SSH state" "yes" \
  "$(grep -q 'SSH state is unreadable' quecdeck/script/firewall.sh && grep -q 'SSH reported a non-numeric port' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall fails closed when managed SSH loses its helper" "yes" \
  "$(grep -q '^elif managed_ssh_artifacts_exist; then$' quecdeck/script/firewall.sh && grep -q 'SSH is managed but its access helper is missing' quecdeck/script/firewall.sh && echo yes || echo no)"
eval "$(extract_fn quecdeck/script/firewall.sh managed_ssh_artifacts_exist)"
t "firewall recognizes the managed SSH service link" "yes" \
  "$(readlink() { echo /usrdata/quecdeck/optional/sshd/sshd.service; }; managed_ssh_artifacts_exist && echo yes || echo no)"
t "firewall treats an uninstalled SSH as no exposure" "yes" \
  "$(grep -q '^        3) ;;$' quecdeck/script/firewall.sh && echo yes || echo no)"
t "SSH unit follows the checksummed release asset" "yes" \
  "$(grep -q 'ln -sf "\$ASSET_DIR/sshd.service" /lib/systemd/system/sshd.service' quecdeck/script/install_sshd.sh && grep -q '\$QUECDECK_DIR/optional/sshd/\$_u' update_quecdeck.sh && echo yes || echo no)"
eval "$(extract_fn quecdeck/script/sshd-policy-lib.sh valid_ssh_port)"
eval "$(extract_fn quecdeck/script/ssh_access.sh configured_port)"
_ssh_port_fixture=$(mktemp)
SSHD_CONFIG=$_ssh_port_fixture
printf 'Port 2222\n' > "$_ssh_port_fixture"
t "ssh_access accepts one configured unprivileged SSH port" "2222" "$(configured_port)"
printf 'Port 22\n' > "$_ssh_port_fixture"
t "ssh_access accepts the standard SSH port" "22" "$(configured_port)"
printf 'Port 80\n' > "$_ssh_port_fixture"
t "ssh_access rejects other privileged ports" "1" "$(configured_port >/dev/null 2>&1; echo $?)"
printf 'Port 2222\nPort 2223\n' > "$_ssh_port_fixture"
t "ssh_access rejects ambiguous SSH ports" "1" "$(configured_port >/dev/null 2>&1; echo $?)"
rm -f "$_ssh_port_fixture"
unset _ssh_port_fixture SSHD_CONFIG
t "firewall leaves DHCP outside its policy" "yes" \
  "$(! grep -q -- '--dport 67' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall never deletes jumps until absent" "yes" \
  "$(! grep -q 'while .*tables .* -D INPUT' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall inserts jump only from zero case" "yes" \
  "$(sed -n '/case "\$jump_count" in/,/esac/p' quecdeck/script/firewall.sh | grep -A2 '0)' | grep -q -- '-I INPUT -j "\$chain"' && echo yes || echo no)"
t "firewall removes jump only from duplicate case" "yes" \
  "$(sed -n '/case "\$jump_count" in/,/esac/p' quecdeck/script/firewall.sh | grep -A2 '\*)' | grep -q -- '-D INPUT -j "\$chain"' && echo yes || echo no)"
t "firewall bounds jump convergence" "yes" \
  "$(grep -q 'while \[ "\$jump_attempts" -lt 10 \]' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall verifies exactly one final jump" "yes" \
  "$(grep -q '\[ "\$jump_count" -ne 1 \]' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall converges both family jumps" "2" \
  "$(grep -c '^converge_input_jump .* QUECDECK' quecdeck/script/firewall.sh)"
t "firewall uninstall explicitly removes owned rules" "yes" \
  "$(sed -n '/# Uninstall firewall/,/# Remove ttyd files/p' quecdeck.sh | grep -q 'firewall.sh --remove' && echo yes || echo no)"
t "firewall helper declares remove API" "yes" \
  "$(grep -qx 'QUECDECK_FIREWALL_REMOVE_API=1' quecdeck/script/firewall.sh && echo yes || echo no)"
t "uninstall checks remove API before invoking helper" "yes" \
  "$(_fw_block=$(sed -n '/# Uninstall firewall/,/# Remove ttyd files/p' quecdeck.sh); _check_line=$(printf '%s\n' "$_fw_block" | grep -n 'QUECDECK_FIREWALL_REMOVE_API=1' | cut -d: -f1); _run_line=$(printf '%s\n' "$_fw_block" | grep -n 'firewall.sh --remove' | cut -d: -f1); [ -n "$_check_line" ] && [ "$_check_line" -lt "$_run_line" ] && echo yes || echo no)"
t "unsupported firewall helper requires reboot" "yes" \
  "$(sed -n '/# Uninstall firewall/,/# Remove ttyd files/p' quecdeck.sh | grep -q 'result_firewall="REBOOT REQUIRED"' && grep -q 'REBOOT REQUIRED: restart the modem' quecdeck.sh && echo yes || echo no)"
t "uninstall stops UI before firewall cleanup" "yes" \
  "$(_uninstall=$(sed -n '/^uninstall_quecdeck_components() {/,/^}/p' quecdeck.sh); _stop_line=$(printf '%s\n' "$_uninstall" | grep -n 'systemctl stop lighttpd' | head -1 | cut -d: -f1); _remove_line=$(printf '%s\n' "$_uninstall" | grep -n 'firewall.sh --remove' | cut -d: -f1); [ -n "$_stop_line" ] && [ "$_stop_line" -lt "$_remove_line" ] && echo yes || echo no)"
t "normal firewall service stop does not remove policy" "yes" \
  "$(! grep -q '^ExecStop=.*firewall.sh --remove' quecdeck/systemd/firewall.service && echo yes || echo no)"

# Execute the real convergence function against a stateful iptables mock. The
# The source checks above catch accidental deletion of the design. These scenarios
# prove its behavior and, critically, that a failed duplicate deletion never
# removes the final working jump.
eval "$(extract_fn quecdeck/script/firewall.sh converge_input_jump)"
_jump_case() { # <initial> <fail-insert> <fail-delete> <external-churn>
    (
        _jumps=$1 _fail_i=$2 _fail_d=$3 _churn=$4 _ops=0 _min=$1
        iptables() {
            case "$*" in
                *"-S INPUT"*)
                    _n=0
                    [ "$_churn" = 1 ] && _reported=0 || _reported=$_jumps
                    echo '-P INPUT ACCEPT'
                    while [ "$_n" -lt "$_reported" ]; do
                        echo '-A INPUT -j QUECDECK'
                        _n=$((_n + 1))
                    done
                    ;;
                *"-I INPUT -j QUECDECK"*)
                    [ "$_fail_i" = 1 ] && return 1
                    _jumps=$((_jumps + 1)); _ops=$((_ops + 1))
                    ;;
                *"-D INPUT -j QUECDECK"*)
                    [ "$_fail_d" = 1 ] && return 1
                    [ "$_jumps" -gt 0 ] || return 1
                    _jumps=$((_jumps - 1)); _ops=$((_ops + 1))
                    [ "$_jumps" -lt "$_min" ] && _min=$_jumps
                    ;;
                *) return 2 ;;
            esac
        }
        converge_input_jump >/dev/null 2>&1
        _rc=$?
        [ "$_churn" = 1 ] && _jumps=0
        printf '%s:%s:%s:%s\n' "$_rc" "$_jumps" "$_min" "$_ops"
    )
}
t "firewall jump behavior zero to one"     "0:1:0:1"  "$(_jump_case 0 0 0 0)"
t "firewall jump behavior one is no-op"     "0:1:1:0"  "$(_jump_case 1 0 0 0)"
t "firewall jump behavior three to one"     "0:1:1:2"  "$(_jump_case 3 0 0 0)"
t "firewall jump insert failure is loud"    "1:0:0:0"  "$(_jump_case 0 1 0 0)"
t "firewall duplicate failure preserves all" "1:3:3:0" "$(_jump_case 3 0 1 0)"
t "firewall jump churn is bounded at ten"   "1:0:0:10" "$(_jump_case 0 0 0 1)"

# Execute the real removal helper against a stateful mock. Foreign chains and
# jumps are included in every fixture and must never appear in the operation log.
eval "$(extract_fn quecdeck/script/firewall.sh remove_chain)"
_remove_case() { # <initial-jumps> <chain-exists>
    (
        _jumps=$1 _chain=$2 _ops=""
        iptables() {
            case "$*" in
                *"-S")
                    echo '-P INPUT ACCEPT'
                    echo '-N VENDOR'
                    echo '-A INPUT -j VENDOR'
                    _n=0
                    while [ "$_n" -lt "$_jumps" ]; do
                        echo '-A INPUT -j QUECDECK'
                        _n=$((_n + 1))
                    done
                    [ "$_chain" = 1 ] && echo '-N QUECDECK'
                    return 0
                    ;;
                *"-D INPUT -j QUECDECK") _jumps=$((_jumps - 1)); _ops="${_ops}D" ;;
                *"-F QUECDECK") _ops="${_ops}F" ;;
                *"-X QUECDECK") _chain=0; _ops="${_ops}X" ;;
                *) return 2 ;;
            esac
        }
        remove_chain iptables QUECDECK >/dev/null 2>&1
        printf '%s:%s:%s:%s\n' "$?" "$_jumps" "$_chain" "$_ops"
    )
}
t "firewall removal handles absent state"    "0:0:0:"    "$(_remove_case 0 0)"
t "firewall removal deletes one owned chain" "0:0:0:DFX" "$(_remove_case 1 1)"
t "firewall removal deletes duplicate jumps" "0:0:0:DDFX" "$(_remove_case 2 1)"
