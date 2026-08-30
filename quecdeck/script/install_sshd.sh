#!/bin/bash
# Root-only installer for the SSH component shipped with this QuecDeck release.
# It uses only bundled, checksummed assets so installation does not depend on
# the branch or release selected by a separately downloaded console script.

PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
QUECDECK_DIR=/usrdata/quecdeck
ASSET_DIR=$QUECDECK_DIR/optional/sshd
MANIFEST=$QUECDECK_DIR/checksums.sha256

. $QUECDECK_DIR/script/sshd-policy-lib.sh || exit 1

[ "$#" -eq 0 ] || exit 1
[ "$(id -u)" = 0 ] || exit 1

remount_rw() { mount -o remount,rw /; }
remount_ro() { mount -o remount,ro /; }

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

configure_key_only_ssh() (
    config_tmp="/opt/etc/ssh/sshd_config.quecdeck.$$"
    umask 077
    cat > "$config_tmp" <<'EOF'
Port 22
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
    chown root:root "$config_tmp" && chmod 600 "$config_tmp" || {
        rm -f "$config_tmp"
        return 1
    }
    /opt/sbin/sshd -t -f "$config_tmp" || { rm -f "$config_tmp"; return 1; }
    effective=$(/opt/sbin/sshd -T -f "$config_tmp" 2>/dev/null) || {
        rm -f "$config_tmp"
        return 1
    }
    # One shared definition of the posture, enforced again by ssh_keys.sh on
    # every daemon start. Failing here gives a clear install-time message
    # instead of a later refusal to start. AllowUsers is checked separately:
    # it is an install-time choice, not part of the runtime policy.
    sshd_policy_ok "$effective" &&
    printf '%s\n' "$effective" | grep -qx 'allowusers root' || {
        rm -f "$config_tmp"
        return 1
    }
    mv -f "$config_tmp" /opt/etc/ssh/sshd_config || return 1
    printf 'enabled\n' > /opt/etc/ssh/quecdeck_enabled &&
        chown root:root /opt/etc/ssh/quecdeck_enabled &&
        chmod 600 /opt/etc/ssh/quecdeck_enabled
)

install_sshd() {
    [ -x /opt/bin/opkg ] || {
        echo -e "\e[1;31mEntware is not installed. Install QuecDeck first.\e[0m"
        return 1
    }
    verify_asset sshd.service && verify_asset update_sshd_ip.sh || {
        echo -e "\e[1;31mBundled SSH files failed integrity verification. Update QuecDeck and try again.\e[0m"
        return 1
    }
    echo -e "\e[1;32mInstalling sshd...\e[0m"
    prepare_ssh_accounts || {
        echo -e "\e[1;31mFailed to prepare the SSH service account.\e[0m"
        return 1
    }
    opkg install --force-maintainer openssh-server openssh-keygen || {
        echo -e "\e[1;31mFailed to install OpenSSH.\e[0m"
        return 1
    }
    for script in /opt/etc/init.d/*sshd*; do
        [ -f "$script" ] && rm -f "$script"
    done
    /opt/bin/ssh-keygen -A
    # Publish the bind fragment before validating: the configuration Includes it
    # by literal path, so sshd -t fails while it is absent. This is the same
    # verified copy the unit runs, so there is nothing to install separately.
    /bin/sh "$ASSET_DIR/update_sshd_ip.sh" || {
        echo -e "\e[1;31mFailed to publish the SSH bind address.\e[0m"
        return 1
    }
    configure_key_only_ssh || {
        echo -e "\e[1;31mFailed to enforce key-only SSH authentication.\e[0m"
        return 1
    }

    trap 'remount_ro' EXIT
    remount_rw || return 1
    cp -f "$ASSET_DIR/sshd.service" /lib/systemd/system/sshd.service &&
        chown root:root /lib/systemd/system/sshd.service &&
        chmod 644 /lib/systemd/system/sshd.service &&
        ln -sf /lib/systemd/system/sshd.service /lib/systemd/system/multi-user.target.wants/sshd.service || return 1
    remount_ro || return 1
    trap - EXIT
    systemctl daemon-reload

    if systemctl restart firewall; then
        if "$QUECDECK_DIR/script/ssh_keys.sh" ready; then
            systemctl start sshd ||
                echo -e "\e[1;31mWARNING: sshd failed to start. Check 'systemctl status sshd'.\e[0m"
        else
            echo -e "\e[1;33mSSH is installed but inactive. Add a public key on the SSH page to start it.\e[0m"
        fi
    else
        echo -e "\e[1;31mWARNING: firewall failed to restart. Sshd was not started.\e[0m"
        echo -e "\e[1;31mCheck 'systemctl status firewall lighttpd', then start sshd after the firewall is active.\e[0m"
    fi
    echo -e "\e[1;32msshd installed.\e[0m"
}

uninstall_sshd() {
    echo -e "\e[1;32mUninstalling sshd...\e[0m"
    systemctl stop sshd 2>/dev/null
    opkg remove openssh-server openssh-server-pam openssh-keygen >/dev/null 2>&1
    cleanup_ssh_account
    rm -rf /opt/etc/ssh
    # Authorized keys live in root's home, not /opt/etc/ssh, so they outlive the
    # packages. Left behind they are unreachable from the web UI (every
    # ssh_keys.sh arm requires sshd installed) and go live again the moment SSH
    # is reinstalled, which needs no credential. Clear them here instead. The
    # directory stays: it may predate QuecDeck.
    if [ -s /usrdata/root/.ssh/authorized_keys ]; then
        echo -e "\e[1;33mRemoving authorized SSH keys. Re-adding one needs the administrator and developer passwords.\e[0m"
    fi
    rm -f /usrdata/root/.ssh/authorized_keys /usrdata/root/.quecdeck-ssh-keys.lock
    trap 'remount_ro' EXIT
    remount_rw || return 1
    rm -f /lib/systemd/system/sshd.service \
          /lib/systemd/system/multi-user.target.wants/sshd.service
    remount_ro || return 1
    trap - EXIT
    systemctl daemon-reload
    systemctl restart firewall ||
        echo -e "\e[1;31mWARNING: firewall failed to restart. Check 'systemctl status firewall lighttpd'.\e[0m"
    echo -e "\e[1;32msshd uninstalled.\e[0m"
}

if [ -x /opt/sbin/sshd ] && [ -f /lib/systemd/system/sshd.service ]; then
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
    1) install_sshd ;;
    2) uninstall_sshd ;;
    3) ;;
    *) echo -e "\e[1;31mInvalid option\e[0m" ;;
esac
