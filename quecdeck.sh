#!/bin/bash

# Define toolkit paths
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin:/usrdata/root/bin
GITUSER="megakerw"
REPONAME="QuecDeck"
GITTREE="main"
GITROOT="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITTREE"
QUECDECK_DIR="/usrdata/quecdeck"
# Function to remount file system as read-write
remount_rw() {
    mount -o remount,rw /
}

# Function to remount file system as read-only
remount_ro() {
    mount -o remount,ro /
}

# Check for existing Entware/opkg installation, install if not installed
ensure_entware_installed() {
    trap 'remount_ro' EXIT  # ensures RO is restored on any exit path
    remount_rw
    if [ ! -f "/opt/bin/opkg" ]; then
        echo -e "\e[1;32mInstalling Entware/OPKG...\e[0m"
        cd /tmp && wget -O installentware.sh "$GITROOT/installentware.sh"
        echo "7b4546ccf4d37b3e3b85f40e2dd204933070354a8d3f735f0ad158b484612c1a  installentware.sh" | sha256sum -c >/dev/null || { echo -e "\e[1;31mInstallentware integrity check failed.\e[0m"; rm -f /tmp/installentware.sh; exit 1; }
        echo -e "\e[1;32mIntegrity verified: installentware.sh\e[0m"
        chmod +x installentware.sh && ./installentware.sh
        if [ "$?" -ne 0 ]; then
            echo -e "\e[1;31mEntware/OPKG installation failed. Please check your internet connection or the repository URL.\e[0m"
            rm -f /tmp/installentware.sh
            exit 1
        fi
        rm -f /tmp/installentware.sh
        cd /
    else
        if [ "$(readlink /bin/login)" != "/opt/bin/login" ]; then
            [ ! -f /bin/login.shadow ] && cp /bin/login /bin/login.shadow
            [ ! -f /usr/bin/passwd.shadow ] && [ -f /usr/bin/passwd ] && cp /usr/bin/passwd /usr/bin/passwd.shadow
            opkg update && opkg install shadow-login shadow-passwd shadow-useradd
            if [ "$?" -ne 0 ]; then
                echo -e "\e[1;31mPackage installation failed. Please check your internet connection and try again.\e[0m"
                exit 1
            fi

            # Replace the login and passwd binaries and set home for root to a writable directory
            rm -f /opt/etc/shadow
            rm -f /opt/etc/passwd
            cp /etc/shadow /opt/etc/
            cp /etc/passwd /opt/etc
            mkdir -p /usrdata/root/bin
            touch /usrdata/root/.profile
            echo "# Set PATH for all shells" > /usrdata/root/.profile
            echo "export PATH=/bin:/usr/sbin:/usr/bin:/sbin:/opt/sbin:/opt/bin:/usrdata/root/bin" >> /usrdata/root/.profile
            chmod +x /usrdata/root/.profile
            sed -i '1s|/home/root:/bin/sh|/usrdata/root:/bin/bash|' /opt/etc/passwd
            rm -f /bin/login /usr/bin/passwd
            ln -sf /opt/bin/login /bin
            ln -sf /opt/bin/passwd /usr/bin/
            ln -sf /opt/bin/useradd /usr/bin/
            echo -e "\e[1;31mPlease set the root password.\e[0m"
            /opt/bin/passwd

            # Install basic and useful utilities
            opkg install mc htop dfc lsof
            ln -sf /opt/bin/mc /bin
            ln -sf /opt/bin/htop /bin
            ln -sf /opt/bin/dfc /bin
            ln -sf /opt/bin/lsof /bin
        fi

        if [ ! -f "/usrdata/root/.profile" ]; then
            opkg update && opkg install shadow-useradd
            mkdir -p /usrdata/root/bin
            touch /usrdata/root/.profile
            echo "# Set PATH for all shells" > /usrdata/root/.profile
            echo "export PATH=/bin:/usr/sbin:/usr/bin:/sbin:/opt/sbin:/opt/bin:/usrdata/root/bin" >> /usrdata/root/.profile
            chmod +x /usrdata/root/.profile
            sed -i '1s|/home/root:/bin/sh|/usrdata/root:/bin/bash|' /opt/etc/passwd
        fi
    fi
    if [ ! -f "/opt/sbin/useradd" ]; then
        echo "useradd does not exist. Installing shadow-useradd..."
        opkg install shadow-useradd
    fi

    if [ ! -f "/usr/bin/curl" ] && [ ! -f "/opt/bin/curl" ]; then
        echo "Installing curl..."
        opkg update && opkg install curl
        if [ "$?" -ne 0 ]; then
            echo -e "\e[1;31mFailed to install curl. Please check your internet connection and try again.\e[0m"
            exit 1
        fi
    fi
    remount_ro
    trap - EXIT
}

#Uninstall Entware if the Users chooses
uninstall_entware() {
    echo -e "\e[1;32mUninstalling Entware/OPKG...\e[0m"

    result_sshd="SKIPPED"
    result_opt_unmount="SKIPPED"
    result_entware_data="SKIPPED"
    result_login="SKIPPED"
    result_passwd="SKIPPED"

    # Stop services before touching the filesystem
    systemctl stop rc.unslung.service 2>/dev/null
    [ -f /opt/etc/init.d/rc.unslung ] && /opt/etc/init.d/rc.unslung stop
    systemctl stop opt.mount 2>/dev/null

    # Stop sshd if installed — it is an Entware package and won't survive Entware removal
    [ -f /lib/systemd/system/sshd.service ] && result_sshd="REMOVED"
    systemctl stop sshd 2>/dev/null

    # Unmount /opt before removing it
    if mountpoint -q /opt; then
        umount /opt \
            && result_opt_unmount="OK" \
            || { result_opt_unmount="WARNING"; echo -e "\e[1;31mWARNING: Could not unmount /opt — a reboot may be required to complete removal.\e[0m"; }
    fi

    # Remove Entware data directory (/usrdata is always writable)
    [ -d /usrdata/opt ] && result_entware_data="REMOVED"
    rm -rf /usrdata/opt

    # Remove root fs entries: systemd units, /opt mount point, login binary
    trap 'remount_ro' EXIT  # ensures RO is restored on any exit path
    remount_rw

    rm -f /lib/systemd/system/multi-user.target.wants/rc.unslung.service
    rm -f /lib/systemd/system/rc.unslung.service
    rm -f /lib/systemd/system/multi-user.target.wants/start-opt-mount.service
    rm -f /lib/systemd/system/opt.mount
    rm -f /lib/systemd/system/start-opt-mount.service
    rm -f /lib/systemd/system/sshd.service
    rm -f /lib/systemd/system/multi-user.target.wants/sshd.service
    rm -rf /opt

    # Restore original login binary compiled by Quectel (only if still pointing at Entware)
    if [ "$(readlink /bin/login)" = "/opt/bin/login" ]; then
        if [ -f /bin/login.shadow ]; then
            rm -f /bin/login
            ln /bin/login.shadow /bin/login
            result_login="RESTORED"
        else
            result_login="WARNING"
            echo -e "\e[1;31mWARNING: /bin/login.shadow not found — could not restore login binary. Console login may be broken.\e[0m"
        fi
    fi

    # Restore original passwd binary compiled by Quectel (only if still pointing at Entware)
    if [ "$(readlink /usr/bin/passwd)" = "/opt/bin/passwd" ]; then
        if [ -f /usr/bin/passwd.shadow ]; then
            rm -f /usr/bin/passwd
            ln /usr/bin/passwd.shadow /usr/bin/passwd
            result_passwd="RESTORED"
        else
            rm -f /usr/bin/passwd
            result_passwd="REMOVED"
        fi
    fi

    # Remove symlinks into /opt that are now dangling
    rm -f /bin/opkg
    rm -f /usr/bin/useradd
    rm -f /bin/mc /bin/htop /bin/dfc /bin/lsof

    remount_ro
    trap - EXIT

    systemctl daemon-reload

    echo ""
    echo -e "\e[1;32mUninstall Summary\e[0m"
    echo "============================================"
    case "$result_opt_unmount" in
        OK)      echo -e "  $(printf '%-22s' "/opt unmount") \e[1;32m$result_opt_unmount\e[0m" ;;
        SKIPPED) echo -e "  $(printf '%-22s' "/opt unmount") $result_opt_unmount" ;;
        *)       echo -e "  $(printf '%-22s' "/opt unmount") \e[1;31m$result_opt_unmount\e[0m" ;;
    esac
    case "$result_entware_data" in
        REMOVED) echo -e "  $(printf '%-22s' "Entware data") \e[1;32m$result_entware_data\e[0m" ;;
        *)       echo -e "  $(printf '%-22s' "Entware data") $result_entware_data" ;;
    esac
    case "$result_sshd" in
        REMOVED) echo -e "  $(printf '%-22s' "sshd") \e[1;32m$result_sshd\e[0m" ;;
        *)       echo -e "  $(printf '%-22s' "sshd") $result_sshd" ;;
    esac
    case "$result_login" in
        RESTORED) echo -e "  $(printf '%-22s' "login binary") \e[1;32m$result_login\e[0m" ;;
        SKIPPED)  echo -e "  $(printf '%-22s' "login binary") $result_login" ;;
        *)        echo -e "  $(printf '%-22s' "login binary") \e[1;31m$result_login\e[0m" ;;
    esac
    case "$result_passwd" in
        RESTORED) echo -e "  $(printf '%-22s' "passwd binary") \e[1;32m$result_passwd\e[0m" ;;
        REMOVED)  echo -e "  $(printf '%-22s' "passwd binary") $result_passwd" ;;
        SKIPPED)  echo -e "  $(printf '%-22s' "passwd binary") $result_passwd" ;;
        *)        echo -e "  $(printf '%-22s' "passwd binary") \e[1;31m$result_passwd\e[0m" ;;
    esac
    echo "============================================"
}

set_quecdeck_passwd(){
    mkdir -p /usrdata/root/bin
    wget -q -O /usrdata/root/bin/quecdeckpasswd $GITROOT/quecdeck/quecdeckpasswd || { echo -e "\e[1;31mFailed to download quecdeckpasswd.\e[0m"; return 1; }
    echo "a8a54427b71e33ba79fc63d1281fea059a91bcd9c986aef2d399f5394f84ee1e  /usrdata/root/bin/quecdeckpasswd" | sha256sum -c >/dev/null || { echo -e "\e[1;31mIntegrity check failed for quecdeckpasswd.\e[0m"; return 1; }
    echo -e "\e[1;32mIntegrity verified: quecdeckpasswd\e[0m"
    chmod +x /usrdata/root/bin/quecdeckpasswd
    wget -q -O /usrdata/root/bin/quecdeckdevpasswd $GITROOT/quecdeck/quecdeckdevpasswd || { echo -e "\e[1;31mFailed to download quecdeckdevpasswd.\e[0m"; return 1; }
    echo "d57de363de9fa3e8936762bfd6fae56e474cb5649fc7dedc99f2ce776f355844  /usrdata/root/bin/quecdeckdevpasswd" | sha256sum -c >/dev/null || { echo -e "\e[1;31mIntegrity check failed for quecdeckdevpasswd.\e[0m"; return 1; }
    echo -e "\e[1;32mIntegrity verified: quecdeckdevpasswd\e[0m"
    chmod +x /usrdata/root/bin/quecdeckdevpasswd
    if [ -f /opt/etc/.htpasswd ]; then
        echo -e "\e[1;32mExisting password kept.\e[0m"
    fi
}

set_adminpasswd() {
    /usrdata/root/bin/quecdeckpasswd
}

set_devpasswd() {
    /usrdata/root/bin/quecdeckdevpasswd
}

set_root_passwd() {
    echo -e "\e[1;31mPlease set the root/console password.\e[0m"
    /opt/bin/passwd
}

# Function to install/update QuecDeck
install_quecdeck() {
    echo -e "\e[1;32mInstalling/updating QuecDeck...\e[0m"
    ensure_entware_installed
    set_quecdeck_passwd || return 1
    mkdir -p /tmp/quecdeck
    wget -q -O /tmp/quecdeck/update_quecdeck.sh $GITROOT/update_quecdeck.sh || { echo -e "\e[1;31mFailed to download update_quecdeck.sh.\e[0m"; return 1; }
    echo "b09a40238ea964161451a84c0435faa69573ee5d238c0eab6760d80cfafb7390  /tmp/quecdeck/update_quecdeck.sh" | sha256sum -c >/dev/null || { echo -e "\e[1;31mIntegrity check failed for update_quecdeck.sh.\e[0m"; rm -f /tmp/quecdeck/update_quecdeck.sh; return 1; }
    echo -e "\e[1;32mIntegrity verified: update_quecdeck.sh\e[0m"
    chmod +x /tmp/quecdeck/update_quecdeck.sh
    /tmp/quecdeck/update_quecdeck.sh || { echo -e "\e[1;31mQuecDeck update failed.\e[0m"; rm -f /tmp/quecdeck/update_quecdeck.sh; return 1; }
    rm -f /tmp/quecdeck/update_quecdeck.sh
    if [ ! -f /opt/etc/.htpasswd ]; then
        lan_ip=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' /etc/data/mobileap_cfg.xml 2>/dev/null | sed 's/<APIPAddr>//;s/<\/APIPAddr>//')
        [ -z "$lan_ip" ] && lan_ip="192.168.225.1"
        echo ""
        echo -e "\e[1;33mOpen https://${lan_ip} in your browser to complete setup.\e[0m"
    fi
}

# Function to Uninstall QuecDeck and dependencies
uninstall_quecdeck_components() {
    echo -e "\e[1;31mThis will completely uninstall QuecDeck and all its components.\e[0m"
    read -p "Are you sure? (y/n): " confirm
    case "$confirm" in
        y|Y) ;;
        *) echo -e "\e[1;33mUninstallation cancelled.\e[0m"; return ;;
    esac

    echo -e "\e[1;32mUninstalling QuecDeck...\e[0m"

    _show_uninstall_result() {
        local label="$1" val="$2"
        case "$val" in
            REMOVED) echo -e "  $(printf '%-22s' "$label") \e[1;32m$val\e[0m" ;;
            SKIPPED) echo -e "  $(printf '%-22s' "$label") $val" ;;
            *)       echo -e "  $(printf '%-22s' "$label") \e[1;31m$val\e[0m" ;;
        esac
    }

    result_watchcat="SKIPPED"
    result_scheduled_restart="SKIPPED"
    result_lean_mode="SKIPPED"
    result_atcmd="SKIPPED"
    result_connection_logger="SKIPPED"
    result_firewall="SKIPPED"
    result_ttyd="SKIPPED"
    result_lighttpd="SKIPPED"
    result_files="SKIPPED"

    trap 'remount_ro' EXIT  # ensures RO is restored on any exit path
    remount_rw

    # Uninstall watchcat
    systemctl stop watchcat > /dev/null 2>&1
    [ -f /lib/systemd/system/watchcat.service ] && result_watchcat="REMOVED"
    rm -f /lib/systemd/system/watchcat.service
    rm -f /lib/systemd/system/multi-user.target.wants/watchcat.service

    # Uninstall scheduled restart
    systemctl stop scheduled_restart > /dev/null 2>&1
    [ -f /lib/systemd/system/scheduled_restart.service ] && result_scheduled_restart="REMOVED"
    rm -f /lib/systemd/system/scheduled_restart.service
    rm -f /lib/systemd/system/multi-user.target.wants/scheduled_restart.service

    # Uninstall lean mode
    systemctl stop lean-mode 2>/dev/null
    [ -f /lib/systemd/system/lean-mode.service ] && result_lean_mode="REMOVED"
    rm -f /lib/systemd/system/lean-mode.service
    rm -f /lib/systemd/system/multi-user.target.wants/lean-mode.service

    # Uninstall atcmd daemon
    systemctl stop atcmd-daemon > /dev/null 2>&1
    [ -f /lib/systemd/system/atcmd-daemon.service ] && result_atcmd="REMOVED"
    rm -f /lib/systemd/system/atcmd-daemon.service
    rm -f /lib/systemd/system/multi-user.target.wants/atcmd-daemon.service

    # Uninstall connection logger
    systemctl stop connection-logger > /dev/null 2>&1
    [ -f /lib/systemd/system/connection-logger.service ] && result_connection_logger="REMOVED"
    rm -f /lib/systemd/system/connection-logger.service
    rm -f /lib/systemd/system/multi-user.target.wants/connection-logger.service

    # Uninstall firewall
    systemctl stop firewall > /dev/null 2>&1
    [ -f /lib/systemd/system/firewall.service ] && result_firewall="REMOVED"
    rm -f /lib/systemd/system/firewall.service
    rm -f /lib/systemd/system/multi-user.target.wants/firewall.service

    # Uninstall ttyd
    systemctl stop ttyd > /dev/null 2>&1
    [ -f /lib/systemd/system/ttyd.service ] && result_ttyd="REMOVED"
    rm -f /lib/systemd/system/ttyd.service
    rm -f /lib/systemd/system/multi-user.target.wants/ttyd.service
    rm -f /bin/ttyd

    # Check if Lighttpd service is installed and remove it if present
    if [ -f "/lib/systemd/system/lighttpd.service" ]; then
        systemctl stop lighttpd 2>/dev/null
        opkg --force-remove --force-removal-of-dependent-packages remove lighttpd-mod-authn_file lighttpd-mod-auth lighttpd-mod-magnet lighttpd-mod-cgi lighttpd-mod-openssl lighttpd-mod-proxy lighttpd \
            && result_lighttpd="REMOVED" || result_lighttpd="FAILED"
        rm -f /lib/systemd/system/lighttpd.service
        rm -f /lib/systemd/system/multi-user.target.wants/lighttpd.service
    fi

    rm -f /opt/etc/sudoers.d/www-data
    rm -f /opt/etc/.htpasswd
    rm -f /opt/etc/.htpasswd_dev
    # Revert root home/shell patch applied during Entware setup
    [ -f /opt/etc/passwd ] && sed -i '1s|/usrdata/root:/bin/bash|/home/root:/bin/sh|' /opt/etc/passwd
    rm -f /usrdata/root/.profile
    rm -f /usrdata/root/bin/menu
    rm -f /usrdata/root/bin/atcli
    rm -f /usrdata/root/bin/quecdeckpasswd
    rm -f /usrdata/root/bin/quecdeckdevpasswd
    rmdir /usrdata/root/bin 2>/dev/null
    rmdir /usrdata/root 2>/dev/null
    systemctl daemon-reload
    [ -d "$QUECDECK_DIR" ] && result_files="REMOVED"
    rm -rf "$QUECDECK_DIR"

    remount_ro
    trap - EXIT

    echo ""
    echo -e "\e[1;32mUninstall Summary\e[0m"
    echo "============================================"
    _show_uninstall_result "Watchcat"           "$result_watchcat"
    _show_uninstall_result "Scheduled restart"  "$result_scheduled_restart"
    _show_uninstall_result "Lean mode"          "$result_lean_mode"
    _show_uninstall_result "atcmd daemon"       "$result_atcmd"
    _show_uninstall_result "Connection logger"  "$result_connection_logger"
    _show_uninstall_result "Firewall"           "$result_firewall"
    _show_uninstall_result "ttyd"               "$result_ttyd"
    _show_uninstall_result "Lighttpd"           "$result_lighttpd"
    _show_uninstall_result "QuecDeck files"     "$result_files"
    echo "============================================"
}


sshd_service() {
    if [ -f /opt/sbin/sshd ] && [ -L /lib/systemd/system/multi-user.target.wants/sshd.service ]; then
        echo -e "\e[1;32msshd is currently: INSTALLED\e[0m"
    else
        echo -e "\e[1;31msshd is currently: NOT INSTALLED\e[0m"
    fi
    echo "OpenSSH Server — allows SSH login to the modem."
    echo -e "\e[1;32m1) Install/Update sshd\e[0m"
    echo -e "\e[1;31m2) Uninstall sshd\e[0m"
    echo -e "\e[1;33m3) Cancel\e[0m"
    read -p "Enter your choice (1-3): " sshd_choice

    case $sshd_choice in
        1)
            ensure_entware_installed

            # Refuse to install if root has no password — sshd with PermitRootLogin yes
            # and no password set would leave the device wide open on the LAN.
            root_pw=$(grep "^root:" /opt/etc/shadow 2>/dev/null | cut -d: -f2)
            case "$root_pw" in
                ""|"!"|"*"|"!!")
                    echo -e "\e[1;31mNo root password is set.\e[0m"
                    echo -e "\e[1;31msshd requires a root password before it can be installed safely.\e[0m"
                    read -p "Set a root password now? (y/n): " set_pw_now
                    case "$set_pw_now" in
                        y|Y)
                            /opt/bin/passwd
                            # Re-check after passwd
                            root_pw=$(grep "^root:" /opt/etc/shadow 2>/dev/null | cut -d: -f2)
                            case "$root_pw" in
                                ""|"!"|"*"|"!!")
                                    echo -e "\e[1;31mPassword not set. Aborting sshd installation.\e[0m"
                                    return
                                    ;;
                            esac
                            ;;
                        *)
                            echo -e "\e[1;31mAborting sshd installation.\e[0m"
                            return
                            ;;
                    esac
                    ;;
            esac

            # Warn if firewall is not active — port 22 will be exposed on WAN
            if ! systemctl is-active firewall >/dev/null 2>&1; then
                echo -e "\e[1;31mWARNING: Firewall is not running.\e[0m"
                echo -e "\e[1;31mWithout it, SSH port 22 will be accessible from the WAN interface.\e[0m"
                read -p "Install sshd anyway? (y/n): " fw_warning_confirm
                case "$fw_warning_confirm" in
                    y|Y) ;;
                    *) echo -e "\e[1;31mAborting sshd installation.\e[0m"; return ;;
                esac
            fi

            echo -e "\e[1;32mInstalling sshd...\e[0m"
            opkg install --force-maintainer openssh-server-pam || { echo -e "\e[1;31mFailed to install openssh-server-pam.\e[0m"; return; }

            # Remove opkg init.d scripts so rc.unslung doesn't manage it
            for script in /opt/etc/init.d/*sshd*; do
                [ -f "$script" ] && rm -f "$script"
            done

            /opt/bin/ssh-keygen -A

            sed -i "s/^.*UsePAM .*/UsePAM yes/" /opt/etc/ssh/sshd_config
            grep -q "^UsePAM" /opt/etc/ssh/sshd_config || echo "UsePAM yes" >> /opt/etc/ssh/sshd_config
            sed -i "s/^.*PermitRootLogin .*/PermitRootLogin yes/" /opt/etc/ssh/sshd_config
            grep -q "^PermitRootLogin" /opt/etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /opt/etc/ssh/sshd_config
            sed -i "s/^.*MaxAuthTries .*/MaxAuthTries 3/" /opt/etc/ssh/sshd_config
            grep -q "^MaxAuthTries" /opt/etc/ssh/sshd_config || echo "MaxAuthTries 3" >> /opt/etc/ssh/sshd_config

            # Ensure the sshd privilege-separation user exists
            grep -q "sshd:x:106" /opt/etc/passwd || \
                echo "sshd:x:106:65534:Linux User,,,:/opt/run/sshd:/bin/nologin" >> /opt/etc/passwd

            # Download and install service file
            mkdir -p /tmp/quecdeck
            wget -q -O /tmp/quecdeck/sshd.service "$GITROOT/optional/sshd/sshd.service" || { echo -e "\e[1;31mFailed to download sshd.service.\e[0m"; return; }
            echo "9a1e5b5fd1030dea0b11f601249f8932ac615051dad3bf2081ab00423afac1a5  /tmp/quecdeck/sshd.service" | sha256sum -c >/dev/null || { echo -e "\e[1;31mIntegrity check failed for sshd.service.\e[0m"; rm -f /tmp/quecdeck/sshd.service; return; }
            echo -e "\e[1;32mIntegrity verified: sshd.service\e[0m"
            trap 'remount_ro' EXIT  # ensures RO is restored on any exit path
            remount_rw
            cp -f /tmp/quecdeck/sshd.service /lib/systemd/system/sshd.service
            rm -f /tmp/quecdeck/sshd.service
            ln -sf /lib/systemd/system/sshd.service /lib/systemd/system/multi-user.target.wants/sshd.service
            remount_ro
            trap - EXIT
            systemctl daemon-reload
            systemctl start sshd || { echo -e "\e[1;31mWARNING: sshd failed to start — check 'systemctl status sshd' for details.\e[0m"; }
            # Reload firewall so port 22 LAN-only rule takes effect immediately
            systemctl restart firewall 2>/dev/null || true
            echo ""
            echo -e "\e[1;32msshd installed.\e[0m"
            ;;
        2)
            echo -e "\e[1;32mUninstalling sshd...\e[0m"
            systemctl stop sshd 2>/dev/null
            opkg remove openssh-server-pam >/dev/null 2>&1
            rm -rf /opt/etc/ssh
            trap 'remount_ro' EXIT  # ensures RO is restored on any exit path
            remount_rw
            rm -f /lib/systemd/system/sshd.service
            rm -f /lib/systemd/system/multi-user.target.wants/sshd.service
            remount_ro
            trap - EXIT
            systemctl daemon-reload
            # Reload firewall so port 22 rule is removed immediately
            systemctl restart firewall 2>/dev/null || true
            echo ""
            echo -e "\e[1;32msshd uninstalled.\e[0m"
            ;;
        3)
            ;;
        *)
            echo -e "\e[1;31mInvalid option\e[0m"
            ;;
    esac
}

lean_mode_service() {
    if [ -L /lib/systemd/system/multi-user.target.wants/lean-mode.service ]; then
        echo -e "\e[1;32mLean Mode is currently: INSTALLED\e[0m"
    else
        echo -e "\e[1;31mLean Mode is currently: NOT INSTALLED\e[0m"
    fi
    echo "Lean Mode stops the GPS and location stack on boot (loc_launcher,"
    echo "location_hal_daemon, edgnss-daemon). These services are not needed"
    echo "for data-only RGMII operation. Freeing them reduces background"
    echo "resource usage and may improve stability."
    echo -e "\e[1;32m1) Install Lean Mode\e[0m"
    echo -e "\e[1;31m2) Uninstall Lean Mode\e[0m"
    echo -e "\e[1;33m3) Cancel\e[0m"
    read -p "Enter your choice (1-3): " lean_choice

    case $lean_choice in
        1)
            echo -e "\e[1;32mInstalling Lean Mode...\e[0m"
            mkdir -p /usrdata/quecdeck/script /usrdata/quecdeck/systemd
            wget -q -O /usrdata/quecdeck/script/lean_mode.sh "$GITROOT/quecdeck/script/lean_mode.sh" || { echo -e "\e[1;31mDownload failed.\e[0m"; return; }
            echo "d6ede9ef2a3b6716ae0cf58a8934c62ec1f2f6e1b8a88e2f01f52eefec2f2a54  /usrdata/quecdeck/script/lean_mode.sh" | sha256sum -c >/dev/null || { echo -e "\e[1;31mIntegrity check failed for lean_mode.sh.\e[0m"; rm -f /usrdata/quecdeck/script/lean_mode.sh; return; }
            echo -e "\e[1;32mIntegrity verified: lean_mode.sh\e[0m"
            wget -q -O /usrdata/quecdeck/systemd/lean-mode.service "$GITROOT/quecdeck/systemd/lean-mode.service" || { echo -e "\e[1;31mDownload failed.\e[0m"; return; }
            echo "146beb37b2840d5aaad4323b6979dcc9a03373ea56ee2e9d7dcfabaad6ff91d0  /usrdata/quecdeck/systemd/lean-mode.service" | sha256sum -c >/dev/null || { echo -e "\e[1;31mIntegrity check failed for lean-mode.service.\e[0m"; rm -f /usrdata/quecdeck/systemd/lean-mode.service; return; }
            echo -e "\e[1;32mIntegrity verified: lean-mode.service\e[0m"
            chmod +x /usrdata/quecdeck/script/lean_mode.sh
            trap 'remount_ro' EXIT  # ensures RO is restored on any exit path
            remount_rw
            cp -f /usrdata/quecdeck/systemd/lean-mode.service /lib/systemd/system/lean-mode.service
            ln -sf /lib/systemd/system/lean-mode.service /lib/systemd/system/multi-user.target.wants/lean-mode.service
            remount_ro
            trap - EXIT
            systemctl daemon-reload
            echo ""
            echo -e "\e[1;32mLean Mode installed. Takes effect on next reboot.\e[0m"
            ;;
        2)
            echo -e "\e[1;32mUninstalling Lean Mode...\e[0m"
            trap 'remount_ro' EXIT  # ensures RO is restored on any exit path
            remount_rw
            rm -f /lib/systemd/system/lean-mode.service
            rm -f /lib/systemd/system/multi-user.target.wants/lean-mode.service
            remount_ro
            trap - EXIT
            systemctl daemon-reload
            echo ""
            echo -e "\e[1;32mLean Mode uninstalled.\e[0m"
            ;;
        3)
            ;;
        *)
            echo -e "\e[1;31mInvalid option\e[0m"
            ;;
    esac
}

disable_monitoring_services() {
    echo -e "\e[1;32mDisabling monitoring services...\e[0m"
    systemctl stop watchcat 2>/dev/null
    systemctl stop scheduled_restart 2>/dev/null

    trap 'remount_ro' EXIT  # ensures RO is restored on any exit path
    remount_rw

    rm -f /lib/systemd/system/multi-user.target.wants/watchcat.service
    rm -f /lib/systemd/system/multi-user.target.wants/scheduled_restart.service

    remount_ro
    trap - EXIT

    rm -f /usrdata/quecdeck/var/watchcat.json
    rm -f /usrdata/quecdeck/var/scheduled_restart.json
    systemctl daemon-reload
    echo ""
    echo -e "\e[1;32mWatchcat and scheduled restart disabled.\e[0m"
}

# Main menu

ARCH=$(uname -a)
if echo "$ARCH" | grep -q "armv7l"; then
    echo "Architecture is armv7l, continuing..."
else
    uname -a
    echo "Unsupported architecture."
    exit 1
fi

while true; do
    echo ""
    echo -e "\e[92m============================================================\e[0m"
    echo -e "\e[92m  QuecDeck Installer\e[0m"
    echo -e "\e[92m============================================================\e[0m"
    echo ""
    echo "Select an option:"
    echo -e "\e[93m1) Install/Update QuecDeck\e[0m" # Yellow
    echo -e "\e[93m2) sshd (install/uninstall)\e[0m" # Yellow
    echo -e "\e[33m3) Lean Mode (install/uninstall) [EXPERIMENTAL]\e[0m" # Dark Yellow/Orange
    echo -e "\e[91m4) Disable monitoring services (Watchcat & Scheduled Restart)\e[0m" # Light Red
    echo -e "\e[91m5) Uninstall QuecDeck\e[0m" # Light Red
    echo -e "\e[91m6) Uninstall Entware/OPKG\e[0m" # Light Red
    echo -e "\e[95m7) Set QuecDeck (admin) password\e[0m" # Light Purple
    echo -e "\e[95m8) Set Developer access (devadmin) password\e[0m" # Light Purple
    echo -e "\e[94m9) Set Console/ttyd (root) password\e[0m" # Light Blue
    echo -e "\e[91m10) Reboot\e[0m" # Light Red
    echo -e "\e[93m11) Exit\e[0m" # Yellow
    read -p "Enter your choice: " choice

    case $choice in
        1)
            install_quecdeck
            echo ""
            read -p "Press Enter to return to menu..."
            ;;
        2)
            sshd_service
            ;;
        3)
            lean_mode_service
            ;;
        4)
            echo -e "\e[1;31mThis will disable Watchcat and Scheduled Restart.\e[0m"
            read -p "Are you sure? (y/n): " confirm
            case "$confirm" in
                y|Y) disable_monitoring_services ;;
                *) echo -e "\e[1;33mCancelled.\e[0m" ;;
            esac
            ;;
        5)
            uninstall_quecdeck_components
            ;;
        6)
            if [ -d "$QUECDECK_DIR/www" ]; then
                echo -e "\e[1;31mWARNING: QuecDeck is still installed.\e[0m"
                echo -e "\e[1;31mUninstalling Entware will break QuecDeck and all its services.\e[0m"
                echo -e "\e[1;31mRun option 5 to uninstall QuecDeck first.\e[0m"
                read -p "Continue anyway? (y/n): " quecdeck_warn_confirm
                case "$quecdeck_warn_confirm" in
                    y|Y) ;;
                    *) echo -e "\e[1;33mUninstallation cancelled.\e[0m"; continue ;;
                esac
            fi
            echo -e "\e[1;31mAre you sure you want to uninstall Entware/OPKG?\e[0m"
            read -p "Continue? (y/n): " user_choice
            case "$user_choice" in
                y|Y)
                    uninstall_entware
                    ;;
                *)
                    echo -e "\e[1;33mUninstallation cancelled.\e[0m"
                    ;;
            esac
            ;;
        7)
            read -p "Set QuecDeck (admin) password? (y/n): " pw_confirm
            case "$pw_confirm" in
                y|Y) set_adminpasswd ;;
                *) echo -e "\e[1;33mCancelled.\e[0m" ;;
            esac
            ;;
        8)
            read -p "Set Developer access (devadmin) password? (y/n): " pw_confirm
            case "$pw_confirm" in
                y|Y) set_devpasswd ;;
                *) echo -e "\e[1;33mCancelled.\e[0m" ;;
            esac
            ;;
        9)
            read -p "Set Console/ttyd (root) password? (y/n): " pw_confirm
            case "$pw_confirm" in
                y|Y) set_root_passwd ;;
                *) echo -e "\e[1;33mCancelled.\e[0m" ;;
            esac
            ;;
        10)
            read -p "Reboot the modem? (y/n): " reboot_confirm
            case "$reboot_confirm" in
                y|Y) reboot ;;
                *) echo -e "\e[1;33mReboot cancelled.\e[0m" ;;
            esac
            ;;
        11)
            echo -e "\e[1;32mGoodbye!\e[0m"
            break
            ;;
        *)
            echo -e "\e[1;31mInvalid option\e[0m"
            ;;
    esac
done
