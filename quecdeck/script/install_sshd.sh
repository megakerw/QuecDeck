#!/bin/bash
# Root-only installer for the SSH component shipped with this QuecDeck release.
# It uses only bundled, checksummed assets so installation does not depend on
# the branch or release selected by a separately downloaded console script.
#
# Actions, so the console menu and the web UI drive one implementation:
#   --check             refresh the package index and report an available update
#   --install <port>    first installation on the given port
#   --update            reinstall the packages, keeping the current settings
#   --uninstall         remove the packages, configuration and authorized keys
#   (no argument)       interactive console menu
#
# Exit codes are the interface between this script and its front ends. Neither
# parses the log: the console maps a code to a message, the web UI maps the same
# code to its own copy. Add a code rather than overloading one.

PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
QUECDECK_DIR=/usrdata/quecdeck
ASSET_DIR=$QUECDECK_DIR/optional/sshd
MANIFEST=$QUECDECK_DIR/checksums.sha256
# ssh_access.sh's lock, deliberately the same file. Key and settings changes go
# straight through that helper while install and removal run in a unit, so two
# separate locks would exclude nothing between them. Covers every SSH change,
# not just keys, which is what the name says.
LOCK=/usrdata/root/.quecdeck-ssh.lock

. $QUECDECK_DIR/script/sshd-policy-lib.sh || exit 1
. $QUECDECK_DIR/script/lock-lib.sh || exit 1

RC_OK=0
RC_USAGE=1
RC_NOT_INSTALLED=10
RC_ALREADY_INSTALLED=11
RC_SETTINGS=12
RC_ENTWARE=13
RC_ASSETS=14
RC_ACCOUNT=15
RC_PACKAGES=16
RC_CONFIG=17
RC_UNIT=18
RC_FIREWALL=19
# Removal reached its commit point and then failed. The daemon is stopped, the
# configuration and keys are gone, and packages remain. Distinct from every code
# above, which all mean nothing was changed.
RC_PARTIAL_REMOVAL=20
RC_BUSY=21
RC_SSHD_START=22
RC_INDEX=23
# Removed, but the rules were not reapplied. Distinct from 20: the packages are
# gone and what is left behind is a stale firewall, which can also mean the web
# server never came back.
RC_REMOVAL_FIREWALL=24

ACTION=menu
PORT=""
case "${1:-}" in
    '')          [ "$#" -eq 0 ] || exit "$RC_USAGE" ;;
    --check)     [ "$#" -eq 1 ] || exit "$RC_USAGE" ; ACTION=check ;;
    --install)   [ "$#" -eq 2 ] || exit "$RC_USAGE" ; ACTION=install ; PORT="$2" ;;
    --update)    [ "$#" -eq 1 ] || exit "$RC_USAGE" ; ACTION=update ;;
    --uninstall) [ "$#" -eq 1 ] || exit "$RC_USAGE" ; ACTION=uninstall ;;
    *)           exit "$RC_USAGE" ;;
esac
[ "$(id -u)" = 0 ] || exit "$RC_USAGE"

# One marked line per real step. The web UI renders the last one as its status
# line. Stderr, so stdout stays the machine-readable channel for --check. The
# unit appends both streams to one log.
step() { # step <message>
    if [ -t 2 ]; then
        printf '\e[1;32m==> %s\e[0m\n' "$1" >&2
    else
        printf '==> %s\n' "$1" >&2
    fi
}

remount_rw() { mount -o remount,rw /; }
remount_ro() { mount -o remount,ro /; }

# Rebuild the rules without cycling the unit. lighttpd.service is
# PartOf=firewall.service, so restarting it takes the web UI down and back up
# through the unit's ExecStartPost, and firewall.sh applies its rules atomically
# on its own. Restart only when the unit is inactive: a direct rebuild would
# leave it that way, and sshd's ExecStartPre gate refuses to start against an
# inactive firewall. Same shape as apply_network_policy in ssh_access.sh, which
# is why a port change from the settings panel does not drop the page.
apply_firewall() {
    if systemctl is-active --quiet firewall 2>/dev/null; then
        /bin/bash "$QUECDECK_DIR/script/firewall.sh" >/dev/null 2>&1
    else
        systemctl restart firewall
    fi
}

sshd_is_installed() {
    [ -x /opt/sbin/sshd ] && [ -f /lib/systemd/system/sshd.service ]
}

verify_asset() { # verify_asset <name>
    local name="$1" path expected actual
    case "$name" in sshd.service|update_sshd_ip.sh) ;; *) return 1 ;; esac
    path="$ASSET_DIR/$name"
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    expected=$(awk -v p="*quecdeck/optional/sshd/$name" '$2 == p {print $1}' "$MANIFEST")
    [ -n "$expected" ] || return 1
    actual=$(sha256sum "$path" | awk '{print $1}')
    [ "$actual" = "$expected" ]
}

# Sets saved_ssh_enabled and saved_ssh_port. saved-state, not status: it still
# answers after a partial installation that wrote the configuration but not the
# service link. Invalid settings abort before anything is touched, because
# reinstalling against a guess moves the port out from under the firewall rule.
# Nothing managed yet is a first installation, so the defaults stand.
resolve_saved_settings() {
    local status rc candidate_enabled candidate_port
    saved_ssh_enabled=1
    saved_ssh_port=22
    if [ ! -x "$QUECDECK_DIR/script/ssh_access.sh" ]; then
        echo -e "\e[1;31mThe bundled SSH access helper is missing or not executable. Update QuecDeck and try again.\e[0m"
        return "$RC_SETTINGS"
    fi
    status=$("$QUECDECK_DIR/script/ssh_access.sh" saved-state 2>/dev/null)
    rc=$?
    case "$rc" in
        0)
            IFS=$'\t' read -r candidate_enabled candidate_port <<< "$status"
            case "$candidate_enabled" in 0|1) ;; *) candidate_enabled=invalid ;; esac
            if [ "$candidate_enabled" = invalid ] || ! valid_ssh_port "$candidate_port"; then
                echo -e "\e[1;31mExisting SSH settings are invalid. No changes were made.\e[0m"
                return "$RC_SETTINGS"
            fi
            saved_ssh_enabled=$candidate_enabled
            saved_ssh_port=$candidate_port
            ;;
        3)
            ;;
        *)
            echo -e "\e[1;31mExisting SSH settings could not be read. No changes were made.\e[0m"
            return "$RC_SETTINGS"
            ;;
    esac
    return "$RC_OK"
}

prepare_ssh_accounts() {
    # OpenSSH needs its own privilege-separation account. Detach Entware's
    # passwd symlink before adding it so the firmware account file is untouched.
    if [ -L /opt/etc/passwd ] || [ ! -s /opt/etc/passwd ]; then
        rm -f /opt/etc/passwd
        cp /etc/passwd /opt/etc/passwd || return 1
    fi
    [ -f /opt/etc/passwd ] && [ ! -L /opt/etc/passwd ] || return 1
    grep -q '^root:' /opt/etc/passwd || return 1
    firmware_root=$(grep '^root:' /etc/passwd 2>/dev/null)
    [ -n "$firmware_root" ] || return 1
    passwd_tmp=$(mktemp /opt/etc/passwd.quecdeck.XXXXXX) || return 1
    if ! {
        printf '%s\n' "$firmware_root"
        grep -v '^root:' /opt/etc/passwd
    } > "$passwd_tmp" ||
       ! chown root:root "$passwd_tmp" || ! chmod 644 "$passwd_tmp" ||
       ! mv -f "$passwd_tmp" /opt/etc/passwd; then
        rm -f "$passwd_tmp"
        return 1
    fi
    awk -F: '$3 == 106 && $1 != "sshd" {exit 1}' /opt/etc/passwd || {
        echo -e "\e[1;31mUID 106 is already assigned. Cannot create the SSH service account.\e[0m"
        return 1
    }
    grep -q '^sshd:x:106:' /opt/etc/passwd ||
        printf '%s\n' 'sshd:x:106:65534:SSH privilege separation:/opt/var/empty:/bin/false' >> /opt/etc/passwd
    chown root:root /opt/etc/passwd && chmod 644 /opt/etc/passwd || return 1
    mkdir -p /opt/var/empty || return 1
    chown root:root /opt/var/empty && chmod 755 /opt/var/empty
}

cleanup_ssh_account() {
    [ -f /opt/etc/passwd ] && [ ! -L /opt/etc/passwd ] || return 0
    sed -i '/^sshd:x:106:/d' /opt/etc/passwd
    rmdir /opt/var/empty 2>/dev/null || true
}

remove_entware_sshd_init_scripts() {
    local script failed=0
    for script in /opt/etc/init.d/*sshd*; do
        [ -e "$script" ] || [ -L "$script" ] || continue
        rm -f "$script" || failed=1
    done
    return "$failed"
}

install_sshd_unit() {
    cp -f "$ASSET_DIR/sshd.service" /lib/systemd/system/sshd.service &&
        chown root:root /lib/systemd/system/sshd.service &&
        chmod 644 /lib/systemd/system/sshd.service &&
        ln -sf /lib/systemd/system/sshd.service /lib/systemd/system/multi-user.target.wants/sshd.service
}

configure_key_only_ssh() (
    ssh_port=$1
    ssh_enabled=$2
    config_tmp="/opt/etc/ssh/sshd_config.quecdeck.$$"
    umask 077
    if ! {
        printf 'Port %s\n' "$ssh_port"
        cat <<'EOF'
HostKey /opt/etc/ssh/ssh_host_ed25519_key
HostKey /opt/etc/ssh/ssh_host_rsa_key
PermitRootLogin prohibit-password
PubkeyAuthentication yes
AuthenticationMethods publickey
AuthorizedKeysFile /usrdata/root/.ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers root
MaxAuthTries 3
StrictModes yes
UseDNS no
# Forwarding defaults to enabled, which would let a stolen key use the modem as
# a TCP pivot into the LAN without running a single command.
AllowTcpForwarding no
AllowAgentForwarding no
AllowStreamLocalForwarding no
GatewayPorts no
PermitTunnel no
X11Forwarding no
# Bound the pre-authentication window and reap dead sessions.
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
MaxSessions 4
MaxStartups 3:50:10
SetEnv PATH=/bin:/usr/sbin:/usr/bin:/sbin:/opt/sbin:/opt/bin:/usrdata/root/bin
Subsystem sftp internal-sftp
# The bind address is republished to tmpfs on every start, so this file never
# changes after installation. A literal path, not a glob: a missing fragment
# must refuse the start rather than fall back to binding every interface.
Include /run/quecdeck/sshd-listen.conf
EOF
    } > "$config_tmp"; then
        rm -f "$config_tmp"
        return 1
    fi
    chown root:root "$config_tmp" && chmod 600 "$config_tmp" || {
        rm -f "$config_tmp"
        return 1
    }
    /opt/sbin/sshd -t -f "$config_tmp" || { rm -f "$config_tmp"; return 1; }
    effective=$(/opt/sbin/sshd -T -f "$config_tmp" 2>/dev/null) || {
        rm -f "$config_tmp"
        return 1
    }
    # One shared definition of the posture, enforced again by ssh_access.sh on
    # every daemon start. Failing here gives a clear install-time message
    # instead of a later refusal to start. AllowUsers is checked separately:
    # it is an install-time choice, not part of the runtime policy.
    sshd_policy_ok "$effective" &&
    printf '%s\n' "$effective" | grep -qx 'allowusers root' || {
        rm -f "$config_tmp"
        return 1
    }
    mv -f "$config_tmp" /opt/etc/ssh/sshd_config || return 1
    if [ "$ssh_enabled" = 1 ]; then
        printf 'enabled\n' > /opt/etc/ssh/quecdeck_enabled &&
            chown root:root /opt/etc/ssh/quecdeck_enabled &&
            chmod 600 /opt/etc/ssh/quecdeck_enabled
    else
        rm -f /opt/etc/ssh/quecdeck_enabled
    fi
)

# install_sshd <port> <enabled>
# Installs or reinstalls with the settings it is handed. It does not read the
# saved state: the update path passes back what resolve_saved_settings found,
# and a first installation passes the port the caller chose. Every failure
# leaves the previous installation as it was.
install_sshd() {
    local ssh_port="$1" ssh_enabled="$2"
    local was_installed=0 live_enabled="" live_port="" need_firewall=0 live_state
    local package_rc init_cleanup_rc

    sshd_is_installed && was_installed=1
    # Captured before anything is rewritten. A firewall restart takes lighttpd
    # down with it (lighttpd.service is PartOf=firewall.service), so skip it when
    # the rules would not change. Compare against the state the loaded rules were
    # built from, never against which front end asked. An unreadable live state
    # restarts rather than trusting a guess.
    if [ "$was_installed" = 1 ]; then
        live_state=$("$QUECDECK_DIR/script/ssh_access.sh" status 2>/dev/null) &&
            IFS=$'\t' read -r live_enabled live_port <<< "$live_state"
    fi
    if [ "$was_installed" = 0 ] ||
       [ -z "$live_port" ] ||
       [ "$ssh_port" != "$live_port" ] ||
       [ "$ssh_enabled" != "$live_enabled" ]; then
        need_firewall=1
    fi

    [ -x /opt/bin/opkg ] || {
        echo -e "\e[1;31mEntware is not installed. Install QuecDeck first.\e[0m"
        return "$RC_ENTWARE"
    }
    verify_asset sshd.service && verify_asset update_sshd_ip.sh || {
        echo -e "\e[1;31mBundled SSH files failed integrity verification. Update QuecDeck and try again.\e[0m"
        return "$RC_ASSETS"
    }
    step "Preparing the SSH service account"
    prepare_ssh_accounts || {
        echo -e "\e[1;31mFailed to prepare the SSH service account.\e[0m"
        return "$RC_ACCOUNT"
    }
    step "Installing packages"
    opkg install --force-maintainer openssh-server openssh-keygen
    package_rc=$?
    init_cleanup_rc=0
    remove_entware_sshd_init_scripts || init_cleanup_rc=1
    if [ "$package_rc" -ne 0 ]; then
        echo -e "\e[1;31mFailed to install OpenSSH.\e[0m"
        return "$RC_PACKAGES"
    fi
    if [ "$init_cleanup_rc" -ne 0 ]; then
        echo -e "\e[1;31mFailed to remove Entware's unmanaged SSH startup script.\e[0m"
        return "$RC_PACKAGES"
    fi
    step "Generating host keys"
    /opt/bin/ssh-keygen -A
    # Publish the bind fragment before validating: the configuration Includes it
    # by literal path, so sshd -t fails while it is absent. This is the same
    # verified copy the unit runs, so there is nothing to install separately.
    /bin/sh "$ASSET_DIR/update_sshd_ip.sh" || {
        echo -e "\e[1;31mFailed to publish the SSH bind address.\e[0m"
        return "$RC_CONFIG"
    }
    step "Enforcing key-only authentication"
    configure_key_only_ssh "$ssh_port" "$ssh_enabled" || {
        echo -e "\e[1;31mFailed to enforce key-only SSH authentication.\e[0m"
        return "$RC_CONFIG"
    }

    step "Installing the sshd unit"
    trap 'remount_ro' EXIT
    remount_rw || return "$RC_UNIT"
    install_sshd_unit || return "$RC_UNIT"
    remount_ro || return "$RC_UNIT"
    trap - EXIT
    systemctl daemon-reload

    if [ "$need_firewall" = 1 ]; then
        step "Applying the firewall rules"
        if ! apply_firewall; then
            systemctl stop sshd >/dev/null 2>&1 || true
            echo -e "\e[1;31mWARNING: the firewall rules could not be applied. Sshd was not started.\e[0m"
            echo -e "\e[1;31mCheck 'systemctl status firewall lighttpd', then start sshd after the firewall is active.\e[0m"
            return "$RC_FIREWALL"
        fi
    fi

    if [ "$ssh_enabled" = 0 ]; then
        systemctl stop sshd >/dev/null 2>&1 || true
        echo -e "\e[1;33mSSH is installed and remains disabled.\e[0m"
    elif "$QUECDECK_DIR/script/ssh_access.sh" ready; then
        step "Starting sshd"
        systemctl restart sshd || {
            echo -e "\e[1;31mWARNING: sshd failed to start. Check 'systemctl status sshd'.\e[0m"
            return "$RC_SSHD_START"
        }
    else
        echo -e "\e[1;33mSSH is installed but inactive. Add a public key on the SSH page to start it.\e[0m"
    fi
    echo -e "\e[1;32msshd installed.\e[0m"
    return "$RC_OK"
}

uninstall_sshd() {
    step "Stopping sshd"
    systemctl stop sshd 2>/dev/null
    package_failed=0
    package_inventory=$(opkg list-installed 2>/dev/null) || package_failed=1
    step "Removing packages"
    for package in openssh-server openssh-server-pam openssh-keygen; do
        if printf '%s\n' "$package_inventory" | grep -q "^${package} "; then
            opkg remove "$package" >/dev/null 2>&1 || package_failed=1
        fi
    done
    remove_entware_sshd_init_scripts || package_failed=1
    cleanup_ssh_account
    rm -rf /opt/etc/ssh
    # Authorized keys live in root's home, not /opt/etc/ssh, so they outlive the
    # packages. Left behind they are unreachable from the web UI (every
    # ssh_access.sh arm requires sshd installed) and go live again the moment SSH
    # is reinstalled, which needs no credential. Clear them here instead. The
    # directory stays: it may predate QuecDeck.
    if [ -s /usrdata/root/.ssh/authorized_keys ]; then
        echo -e "\e[1;33mRemoving authorized SSH keys. Re-adding one needs the administrator and developer passwords.\e[0m"
    fi
    # The lock file stays. This runs holding it, and unlinking it would leave a
    # waiter holding a lock on an unnamed inode while the next caller locks a
    # freshly created one, so neither would exclude the other.
    rm -f /usrdata/root/.ssh/authorized_keys
    trap 'remount_ro' EXIT
    remount_rw || return "$RC_PARTIAL_REMOVAL"
    rm -f /lib/systemd/system/sshd.service \
          /lib/systemd/system/multi-user.target.wants/sshd.service
    remount_ro || return "$RC_PARTIAL_REMOVAL"
    trap - EXIT
    systemctl daemon-reload
    # Always: the port has to close, and the rules are rebuilt from a state that
    # no longer reports SSH.
    step "Applying the firewall rules"
    firewall_failed=0
    apply_firewall || firewall_failed=1
    # Reported ahead of a leftover package: a stale rule set can also mean the
    # web server did not come back, which is the more urgent of the two.
    if [ "$firewall_failed" -ne 0 ]; then
        echo -e "\e[1;31mSSH was removed, but the firewall rules could not be reapplied. Check 'systemctl status firewall lighttpd'.\e[0m"
        return "$RC_REMOVAL_FIREWALL"
    fi
    if [ "$package_failed" -ne 0 ]; then
        echo -e "\e[1;31mSSH was disabled, but one or more OpenSSH packages could not be removed. Check opkg before reinstalling.\e[0m"
        return "$RC_PARTIAL_REMOVAL"
    fi
    echo -e "\e[1;32msshd uninstalled.\e[0m"
    return "$RC_OK"
}

# Refreshing the index needs the network and is the slow half, so it is split
# from every mutating action: the caller can ask what is available while the
# current daemon keeps serving, and decide afterwards.
# Prints "current" or "available <TAB> <package> <TAB> <version>" per package.
check_packages() {
    local upgradable available=0 pkg line
    sshd_is_installed || {
        echo -e "\e[1;31msshd is not installed.\e[0m" >&2
        return "$RC_NOT_INSTALLED"
    }
    step "Refreshing the package index"
    timeout 120 /opt/bin/opkg update >/dev/null 2>&1 || {
        echo -e "\e[1;31mCould not refresh the package index. No changes were made.\e[0m" >&2
        return "$RC_INDEX"
    }
    upgradable=$(/opt/bin/opkg list-upgradable 2>/dev/null)
    for pkg in openssh-server openssh-keygen; do
        line=$(printf '%s\n' "$upgradable" | grep "^$pkg " | head -1)
        [ -n "$line" ] || continue
        available=1
        printf 'available\t%s\t%s\n' "$pkg" "$(printf '%s' "$line" | awk '{print $NF}')"
    done
    [ "$available" = 1 ] || printf 'current\n'
    return "$RC_OK"
}

# Held across the whole action, so a settings save or a key change cannot land
# between the package install and the daemon restart. Bounded: a caller reports
# busy rather than queueing behind an installation.
take_lock() {
    exec 9>>"$LOCK" || return "$RC_BUSY"
    chown root:root "$LOCK" && chmod 600 "$LOCK" || return "$RC_BUSY"
    flock_wait 9 5 || {
        echo -e "\e[1;31mAnother SSH change is already running.\e[0m"
        return "$RC_BUSY"
    }
    return "$RC_OK"
}

# Reinstalls with whatever is currently configured. Shared by --update and by
# the console menu, which also uses it for a first installation: with nothing
# managed yet, resolve_saved_settings hands back the defaults.
update_sshd() {
    resolve_saved_settings || return $?
    install_sshd "$saved_ssh_port" "$saved_ssh_enabled"
}

case "$ACTION" in
    check)
        # Takes the lock too: opkg update writes the package lists, so it is a
        # package operation like any other and must not overlap an install run
        # from the other front end.
        take_lock || exit $?
        check_packages
        exit $?
        ;;
    install)
        valid_ssh_port "$PORT" || exit "$RC_USAGE"
        sshd_is_installed && exit "$RC_ALREADY_INSTALLED"
        take_lock || exit $?
        install_sshd "$PORT" 1
        exit $?
        ;;
    update)
        sshd_is_installed || exit "$RC_NOT_INSTALLED"
        take_lock || exit $?
        update_sshd
        exit $?
        ;;
    uninstall)
        sshd_is_installed || exit "$RC_NOT_INSTALLED"
        take_lock || exit $?
        uninstall_sshd
        exit $?
        ;;
esac

# Console menu. Without a TTY, stdin could carry the selection itself: a CGI's
# stdin is the request body, and option 2 removes SSH and every authorized key.
[ -t 0 ] || exit "$RC_USAGE"

if sshd_is_installed; then
    echo -e "\e[1;32msshd is currently: INSTALLED\e[0m"
else
    echo -e "\e[1;31msshd is currently: NOT INSTALLED\e[0m"
fi
echo "OpenSSH Server: allows SSH login to the modem."
echo -e "\e[1;32m1) Install/Update sshd\e[0m"
echo -e "\e[1;31m2) Uninstall sshd (also removes authorized keys)\e[0m"
echo -e "\e[1;33m3) Cancel\e[0m"
read -r -p "Enter your choice (1-3): " choice
case "$choice" in
    1) take_lock || exit $? ; update_sshd ;;
    2) take_lock || exit $? ; uninstall_sshd ;;
    3) ;;
    *) echo -e "\e[1;31mInvalid option\e[0m" ;;
esac
