#!/bin/bash

# Define toolkit paths
# The legacy root bin may have been world-writable. Use only trusted command
# directories. Installed login shells add root/bin after it has been hardened.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin
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

# Point root's home at the writable /usrdata/root and its shell at bash in the
# Entware passwd. Matches root's line by field, so it works regardless of the
# firmware's current root home/shell values. The previous exact-string sed
# ('1s|/home/root:/bin/sh|...') silently did nothing on any firmware whose root
# entry differed, quietly breaking the console menu and password tools. Warns on
# failure so a missed patch is visible instead of silent.
patch_root_passwd() {
    [ -f /opt/etc/passwd ] || { echo -e "\e[1;31mWarning: /opt/etc/passwd not found; cannot set root home.\e[0m"; return 1; }
    sed -i 's|^\(root:[^:]*:[^:]*:[^:]*:[^:]*:\)[^:]*:[^:]*$|\1/usrdata/root:/bin/bash|' /opt/etc/passwd
    if ! grep -q '^root:[^:]*:[^:]*:[^:]*:[^:]*:/usrdata/root:/bin/bash$' /opt/etc/passwd; then
        echo -e "\e[1;31mWarning: could not repoint root's home to /usrdata/root in /opt/etc/passwd.\e[0m"
        echo -e "\e[1;31mThe console menu and password tools may not work until root's entry is corrected.\e[0m"
        return 1
    fi
}

# Root-owned runtime dir for everything root writes. /run is root-owned and not
# world-writable, so nothing can pre-plant a name here.
ensure_rundir() {
    mkdir -p /run/quecdeck && chmod 755 /run/quecdeck
}

# One-time repair marker. Before this existed, /usrdata/root and bin were 0777.
# Their contents therefore cannot be trusted merely by changing the mode.
ROOT_HOME_HARDENED=/usrdata/root/.quecdeck-home-hardened

write_root_profile() {
    rm -f /usrdata/root/.profile
    printf '%s\n' '# Set PATH for all shells' \
        'export PATH=/bin:/usr/sbin:/usr/bin:/sbin:/opt/sbin:/opt/bin:/usrdata/root/bin' \
        > /usrdata/root/.profile
    chown root:root /usrdata/root/.profile
    chmod 644 /usrdata/root/.profile
}

# Seal root's home before inspecting children. On the first hardened run,
# quarantine the old bin entry out of PATH and recreate it: its former 0777
# mode made every existing entry untrustworthy. The quarantine is retained for
# manual recovery of legitimate custom files.
root_home_dirs() {
    mkdir -p /usrdata/root || return 1
    chown root:root /usrdata/root && chmod 700 /usrdata/root || return 1

    _hardened=0
    if [ ! -L "$ROOT_HOME_HARDENED" ] && [ -f "$ROOT_HOME_HARDENED" ] && \
       [ "$(stat -c '%U %a' "$ROOT_HOME_HARDENED" 2>/dev/null)" = "root 600" ] && \
       grep -qx '1' "$ROOT_HOME_HARDENED" 2>/dev/null; then
        _hardened=1
    fi

    if [ "$_hardened" = "0" ]; then
        if [ -e /usrdata/root/bin ] || [ -L /usrdata/root/bin ]; then
            _quarantine="/usrdata/root/bin.pre-quecdeck-hardening.$(date +%s).$$"
            while [ -e "$_quarantine" ] || [ -L "$_quarantine" ]; do
                _quarantine="${_quarantine}.x"
            done
            mv /usrdata/root/bin "$_quarantine" || return 1
            echo "Previous root bin quarantined at $_quarantine"
        fi
        mkdir -m 755 /usrdata/root/bin || return 1
        chown root:root /usrdata/root/bin || return 1
        write_root_profile || return 1
        rm -f "$ROOT_HOME_HARDENED"
        printf '1\n' > "$ROOT_HOME_HARDENED" || return 1
        chown root:root "$ROOT_HOME_HARDENED" && chmod 600 "$ROOT_HOME_HARDENED" || return 1
    elif [ -L /usrdata/root/bin ] || [ ! -d /usrdata/root/bin ]; then
        echo -e "\e[1;31mRefusing unsafe /usrdata/root/bin after hardening.\e[0m"
        return 1
    else
        chown root:root /usrdata/root/bin && chmod 755 /usrdata/root/bin || return 1
    fi
}

root_home_profile() {
    root_home_dirs || return 1
    write_root_profile
}

# Check for existing Entware/opkg installation, install if not installed
ensure_entware_installed() {
    trap 'remount_ro' EXIT  # ensures RO is restored on any exit path
    if ! remount_rw; then
        echo -e "\e[1;31mCannot remount / read-write; Entware setup aborted.\e[0m"
        trap - EXIT
        return 1
    fi
    if [ ! -f "/opt/bin/opkg" ]; then
        echo -e "\e[1;32mInstalling Entware/OPKG...\e[0m"
        # Staged in root-owned /run/quecdeck, not /tmp: this downloads, verifies
        # and then EXECUTES as root at a fixed, predictable name. In sticky /tmp
        # another uid can pre-create that name, which blocks root's own write
        # (fs.protected_regular) and leaves the verify-then-exec sequence resting
        # on sysctls rather than on directory ownership.
        ensure_rundir
        _ent=/run/quecdeck/installentware.sh
        rm -f "$_ent"
        wget --timeout=30 --tries=2 -O "$_ent" "$GITROOT/installentware.sh"
        echo "fea6ce198087f4869ef8def1a57d4f1a2a3b821c7ae86396363fc840c43493ff  $_ent" | sha256sum -c >/dev/null || { echo -e "\e[1;31mInstallentware integrity check failed.\e[0m"; rm -f "$_ent"; exit 1; } # installentware.sh pin
        echo -e "\e[1;32mIntegrity verified: installentware.sh\e[0m"
        # Run with the staging dir as CWD, matching the previous "cd /tmp" so a
        # relative write by the installer still lands in scratch tmpfs.
        chmod 755 "$_ent" && cd /run/quecdeck && "$_ent"
        if [ "$?" -ne 0 ]; then
            echo -e "\e[1;31mEntware/OPKG installation failed. Please check your internet connection or the repository URL.\e[0m"
            rm -f "$_ent"
            cd /
            exit 1
        fi
        rm -f "$_ent"
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
            root_home_profile || exit 1
            patch_root_passwd
            rm -f /bin/login /usr/bin/passwd
            ln -sf /opt/bin/login /bin
            ln -sf /opt/bin/passwd /usr/bin/
            ln -sf /opt/bin/useradd /usr/bin/
            echo -e "\e[1;31mPlease set the root password.\e[0m"
            /opt/bin/passwd
        fi

        if [ ! -f "/usrdata/root/.profile" ]; then
            opkg update && opkg install shadow-useradd
            root_home_profile || exit 1
            patch_root_passwd
        fi
    fi
    if [ ! -f "/opt/sbin/useradd" ]; then
        echo "useradd does not exist. Installing shadow-useradd..."
        opkg install shadow-useradd
    fi

    if ! opkg list-installed 2>/dev/null | grep -q '^wget-ssl '; then
        echo "Installing wget-ssl and ca-certificates..."
        opkg update
        opkg install wget-ssl ca-certificates || { echo -e "\e[1;31mFailed to install wget-ssl.\e[0m"; exit 1; }
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

    # Stop sshd if installed (it is an Entware package and won't survive Entware removal)
    [ -f /lib/systemd/system/sshd.service ] && result_sshd="REMOVED"
    systemctl stop sshd 2>/dev/null

    # Unmount /opt before removing it
    if mountpoint -q /opt; then
        umount /opt \
            && result_opt_unmount="OK" \
            || { result_opt_unmount="WARNING"; echo -e "\e[1;31mWARNING: Could not unmount /opt; a reboot may be required to complete removal.\e[0m"; }
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
            echo -e "\e[1;31mWARNING: /bin/login.shadow not found; could not restore login binary. Console login may be broken.\e[0m"
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
    root_home_dirs || return 1
    /opt/bin/wget --timeout=30 --tries=2 -q -O /usrdata/root/bin/quecdeckpasswd $GITROOT/quecdeck/quecdeckpasswd || { echo -e "\e[1;31mFailed to download quecdeckpasswd.\e[0m"; return 1; }
    echo "f92fb393702895662aa1fd7a04f6644e79ee899d67accac691cd87e81c2d6f4f  /usrdata/root/bin/quecdeckpasswd" | sha256sum -c >/dev/null || { echo -e "\e[1;31mIntegrity check failed for quecdeckpasswd.\e[0m"; return 1; }
    echo -e "\e[1;32mIntegrity verified: quecdeckpasswd\e[0m"
    chmod 755 /usrdata/root/bin/quecdeckpasswd
    /opt/bin/wget --timeout=30 --tries=2 -q -O /usrdata/root/bin/quecdeckdevpasswd $GITROOT/quecdeck/quecdeckdevpasswd || { echo -e "\e[1;31mFailed to download quecdeckdevpasswd.\e[0m"; return 1; }
    echo "d93fe9ab90dd7c640d7843de08ed8037f456a0d3c9475ee012dfa0630b4e70c9  /usrdata/root/bin/quecdeckdevpasswd" | sha256sum -c >/dev/null || { echo -e "\e[1;31mIntegrity check failed for quecdeckdevpasswd.\e[0m"; return 1; }
    echo -e "\e[1;32mIntegrity verified: quecdeckdevpasswd\e[0m"
    chmod 755 /usrdata/root/bin/quecdeckdevpasswd
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

# Downloads, verifies, and runs update_quecdeck.sh from the given release root.
# $1: tag_root, e.g. https://raw.githubusercontent.com/$GITUSER/$REPONAME/main
# $2: tag to pass through to update_quecdeck.sh (may be empty, meaning "main")
fetch_and_run_installer() {
    _tag_root="$1"
    _tag="$2"
    # Root-owned staging under /run, not /tmp: nothing else can create a name
    # here, so the download target cannot be pre-planted.
    ensure_rundir
    _fetch_dir=/run/quecdeck/update-cli

    rm -rf "$_fetch_dir"
    mkdir -m 700 "$_fetch_dir" || { echo -e "\e[1;31mFailed to create $_fetch_dir.\e[0m"; return 1; }

    _checksums="$_fetch_dir/checksums.sha256"
    _installer="$_fetch_dir/update_quecdeck.sh"

    /opt/bin/wget --timeout=30 --tries=2 -q -O "$_checksums" "$_tag_root/quecdeck/checksums.sha256" || {
        echo -e "\e[1;31mFailed to download checksums.\e[0m"
        return 1
    }
    _expected=$(grep -E '^[a-f0-9]{64} \*update_quecdeck\.sh$' "$_checksums" | awk '{print $1}')
    rm -f "$_checksums"
    if [ -z "$_expected" ]; then
        echo -e "\e[1;31mCould not find hash for update_quecdeck.sh in checksums.\e[0m"
        return 1
    fi

    /opt/bin/wget --timeout=30 --tries=2 -q -O "$_installer" "$_tag_root/update_quecdeck.sh" || {
        echo -e "\e[1;31mFailed to download update_quecdeck.sh.\e[0m"
        return 1
    }
    _actual=$(sha256sum "$_installer" | awk '{print $1}')
    if [ "$_actual" != "$_expected" ]; then
        echo -e "\e[1;31mIntegrity check failed for update_quecdeck.sh.\e[0m"
        rm -rf "$_fetch_dir"
        return 1
    fi
    echo -e "\e[1;32mIntegrity verified: update_quecdeck.sh\e[0m"
    chmod +x "$_installer"
    if [ -n "$_tag" ]; then
        "$_installer" "$_tag"
    else
        "$_installer"
    fi || {
        echo -e "\e[1;31mQuecDeck update failed.\e[0m"
        rm -rf "$_fetch_dir"
        return 1
    }
    rm -rf "$_fetch_dir"
}

# Function to install/update QuecDeck from latest GitHub release
install_quecdeck_release() {
    echo -e "\e[1;32mInstalling latest QuecDeck release...\e[0m"
    ensure_entware_installed
    set_quecdeck_passwd || return 1

    echo "Fetching latest release info..."
    _api=$(/opt/bin/wget --timeout=10 --tries=1 -q -O - \
        "https://api.github.com/repos/$GITUSER/$REPONAME/releases/latest" 2>/dev/null)
    if [ -z "$_api" ]; then
        echo -e "\e[1;31mCould not reach GitHub API. Aborting.\e[0m"
        return 1
    fi
    if printf '%s' "$_api" | grep -qi "rate limit"; then
        echo -e "\e[1;31mGitHub API rate limit exceeded. Try again later.\e[0m"
        return 1
    fi
    _tag=$(printf '%s' "$_api" | grep -o '"tag_name" *: *"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"')
    if [ -z "$_tag" ]; then
        echo -e "\e[1;31mCould not determine latest release. Aborting.\e[0m"
        return 1
    fi
    echo -e "\e[1;32mLatest release: $_tag\e[0m"

    fetch_and_run_installer "https://raw.githubusercontent.com/$GITUSER/$REPONAME/$_tag" "$_tag" || return 1

    if [ ! -f /opt/etc/.htpasswd ]; then
        lan_ip=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' /etc/data/mobileap_cfg.xml 2>/dev/null | sed 's/<APIPAddr>//;s/<\/APIPAddr>//')
        [ -z "$lan_ip" ] && lan_ip="192.168.225.1"
        echo ""
        echo -e "\e[1;33mOpen https://${lan_ip} in your browser to complete setup.\e[0m"
    fi
}

# Function to install/update QuecDeck from main branch
install_quecdeck() {
    echo -e "\e[1;32mInstalling/updating QuecDeck...\e[0m"
    ensure_entware_installed
    set_quecdeck_passwd || return 1

    fetch_and_run_installer "$GITROOT" "" || return 1

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
            "REBOOT REQUIRED") echo -e "  $(printf '%-22s' "$label") \e[1;33m$val\e[0m" ;;
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
    result_runtime_state="SKIPPED"
    firewall_reboot_required=0

    trap 'remount_ro' EXIT  # ensures RO is restored on any exit path
    if ! remount_rw; then
        echo -e "\e[1;31mCannot remount / read-write; uninstall aborted before removing anything.\e[0m"
        trap - EXIT
        return 1
    fi

    # Remove any transient update unit. Newer installs write it to /run. Older
    # ones wrote it to /lib, where a failed update could strand it. Harmless if
    # absent.
    rm -f /run/systemd/system/install_quecdeck.service /lib/systemd/system/install_quecdeck.service
    rm -f /run/systemd/system/install_quecdeck_fetch.service

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
    # Ordinary service stops intentionally leave the policy in place. Remove
    # owned chains only here. Stop lighttpd explicitly as a backstop in case
    # the firewall unit or its loaded PartOf= relationship is already missing.
    systemctl stop firewall > /dev/null 2>&1
    systemctl stop lighttpd > /dev/null 2>&1
    _firewall_helper=/usrdata/quecdeck/script/firewall.sh
    if [ -f "$_firewall_helper" ] &&
       grep -qx 'QUECDECK_FIREWALL_REMOVE_API=1' "$_firewall_helper"; then
        if /bin/bash /usrdata/quecdeck/script/firewall.sh --remove; then
            result_firewall="REMOVED"
        else
            result_firewall="FAILED"
            echo -e "\e[1;31mWARNING: QuecDeck firewall rules could not be removed.\e[0m"
            firewall_reboot_required=1
        fi
    elif [ -f "$_firewall_helper" ] || [ -f /lib/systemd/system/firewall.service ]; then
        # Pre-remove-API releases ignore unknown arguments and would reapply the
        # firewall while claiming success. Leave their in-memory chains alone.
        # The reboot requested in the summary clears the runtime rules.
        result_firewall="REBOOT REQUIRED"
        firewall_reboot_required=1
    fi
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
        # Remove only lighttpd: --force-removal-of-dependent-packages cascades to
        # the lighttpd-mod-* packages (they depend on it). Listing them explicitly
        # is redundant and prints harmless "Package ... is not installed" errors,
        # since the cascade has already removed them by the time opkg reaches them.
        opkg --force-remove --force-removal-of-dependent-packages remove lighttpd \
            && result_lighttpd="REMOVED" || result_lighttpd="FAILED"
        rm -f /lib/systemd/system/lighttpd.service
        rm -f /lib/systemd/system/multi-user.target.wants/lighttpd.service
    fi

    # Safety net for units this uninstaller no longer names. A release can drop a
    # unit and delete its removal line in the same commit, leaving the file
    # installed and enabled forever with nothing left that remembers it. Every
    # unit we ship executes something out of /usrdata/quecdeck, so the file on
    # disk identifies itself no matter what any list remembers. Match Exec*
    # directives only: a path mentioned in a comment is not ownership evidence.
    # The named blocks above have already taken current units, so this catches
    # leftovers. Marker presence is asserted by tests/host/ci-checks.sh.
    for _f in /lib/systemd/system/*.service; do
        [ -f "$_f" ] || continue
        grep -qE '^Exec(Start|StartPre|StartPost|Reload|Stop|StopPost)=.*/usrdata/quecdeck(/|[[:space:]]|$)' "$_f" 2>/dev/null || continue
        _u=$(basename "$_f")
        echo -e "\e[1;33mRemoving orphaned unit from an earlier release: $_u\e[0m"
        # stop + explicit rm, matching every other removal here: the enable
        # symlinks are hand-made, not systemctl-managed.
        systemctl stop "${_u%.service}" >/dev/null 2>&1
        rm -f "$_f" "/lib/systemd/system/multi-user.target.wants/$_u"
    done

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
    # Removing this marker makes an uninstall followed by reinstall a clean
    # first migration. Any quarantine is retained for manual recovery and will
    # intentionally keep the otherwise user-owned root home from being rmdir'd.
    rm -f "$ROOT_HOME_HARDENED"
    rmdir /usrdata/root/bin 2>/dev/null
    rmdir /usrdata/root 2>/dev/null
    systemctl daemon-reload
    [ -d "$QUECDECK_DIR" ] && result_files="REMOVED"
    rm -rf "$QUECDECK_DIR" "${QUECDECK_DIR}.old" "${QUECDECK_DIR}.new" /usrdata/quecdeck_last_update.log

    # /tmp is tmpfs, so it survives an uninstall (only a reboot clears it):
    # without this, sessions, auth-failure/lockout counters, and logs from the
    # old install would silently carry into the next one.
    # Two trees, one per writer: /run/quecdeck is everything root writes,
    # /tmp/quecdeck everything www-data writes. _legacy holds the pre-split
    # paths from before the split, so an upgrade-then-uninstall leaves nothing.
    _legacy="/tmp/quecdeck_update.status /tmp/quecdeck_preflight.sha256 /tmp/install_quecdeck.log /tmp/install_quecdeck.sh /tmp/installentware.sh /tmp/.quecdeck-update /tmp/.quecdeck-update-cli /tmp/.quecdeck-release.tar.gz /tmp/.quecdeck-release-extract" # tmpguard-ok: never opened, only passed to rm below
    { [ -e /tmp/quecdeck ] || [ -e /run/quecdeck ]; } && result_runtime_state="REMOVED" # tmpguard-ok: existence test, no open
    # tmpguard-ok: uninstall removes fixed top-level names only. The rm command does not
    # follow a symlink supplied as the final path component.
    rm -rf /tmp/quecdeck /run/quecdeck $_legacy

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
    _show_uninstall_result "Runtime state"       "$result_runtime_state"
    echo "============================================"
    if [ "$firewall_reboot_required" = "1" ]; then
        echo ""
        echo -e "\e[1;33mREBOOT REQUIRED: restart the modem to clear the remaining firewall rules.\e[0m"
    fi
}


sshd_service() {
    if [ -f /opt/sbin/sshd ] && [ -L /lib/systemd/system/multi-user.target.wants/sshd.service ]; then
        echo -e "\e[1;32msshd is currently: INSTALLED\e[0m"
    else
        echo -e "\e[1;31msshd is currently: NOT INSTALLED\e[0m"
    fi
    echo "OpenSSH Server: allows SSH login to the modem."
    echo -e "\e[1;32m1) Install/Update sshd\e[0m"
    echo -e "\e[1;31m2) Uninstall sshd\e[0m"
    echo -e "\e[1;33m3) Cancel\e[0m"
    read -p "Enter your choice (1-3): " sshd_choice

    case $sshd_choice in
        1)
            ensure_entware_installed

# Refuse to install if root has no password. The SSH daemon with PermitRootLogin enabled
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

            # Warn if firewall is not active (port 22 will be exposed on WAN)
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

            # Download and install service file and IP update script.
            # Staged in root-owned /run/quecdeck, NOT /tmp/quecdeck: that dir
            # belongs to www-data, which could both plant a symlink for wget to
            # follow and swap the file between sha256sum and cp, installing an
            # unverified unit as root.
            ensure_rundir
            _stage=/run/quecdeck
            /opt/bin/wget --timeout=30 --tries=2 -q -O $_stage/sshd.service "$GITROOT/optional/sshd/sshd.service" || { echo -e "\e[1;31mFailed to download sshd.service.\e[0m"; return; }
            echo "12f5725cbaa915a0b98fa83180b60eb179a5235a98598183799dc570ee8b4d5c  $_stage/sshd.service" | sha256sum -c >/dev/null || { echo -e "\e[1;31mIntegrity check failed for sshd.service.\e[0m"; rm -f $_stage/sshd.service; return; }
            echo -e "\e[1;32mIntegrity verified: sshd.service\e[0m"
            /opt/bin/wget --timeout=30 --tries=2 -q -O $_stage/update_sshd_ip.sh "$GITROOT/optional/sshd/update_sshd_ip.sh" || { echo -e "\e[1;31mFailed to download update_sshd_ip.sh.\e[0m"; return; }
            echo "dc10b79739f1d788cfcdfc805e4f84fe1f7da5df29aacc3e3f7f76f0cc1eef19  $_stage/update_sshd_ip.sh" | sha256sum -c >/dev/null || { echo -e "\e[1;31mIntegrity check failed for update_sshd_ip.sh.\e[0m"; rm -f $_stage/update_sshd_ip.sh; return; }
            echo -e "\e[1;32mIntegrity verified: update_sshd_ip.sh\e[0m"
            trap 'remount_ro' EXIT  # ensures RO is restored on any exit path
            remount_rw
            cp -f $_stage/sshd.service /lib/systemd/system/sshd.service
            rm -f $_stage/sshd.service
            cp -f $_stage/update_sshd_ip.sh /opt/etc/ssh/update_sshd_ip.sh
            chown root:root /opt/etc/ssh/update_sshd_ip.sh
            chmod 700 /opt/etc/ssh/update_sshd_ip.sh
            rm -f $_stage/update_sshd_ip.sh
            ln -sf /lib/systemd/system/sshd.service /lib/systemd/system/multi-user.target.wants/sshd.service
            remount_ro
            trap - EXIT
            systemctl daemon-reload
            # Apply the port-22 rule before starting sshd (firewall.sh keys it off
            # the sshd.service file) so 22 is LAN-restricted first. Restart the
            # service, not firewall.sh directly, to stay fail-closed. This cycles
            # lighttpd via PartOf=, sshd unaffected.
            # The sshd start is gated on the restart: without the port-22 rules,
            # sshd would listen unrestricted (WAN included) while the UI is down.
            if systemctl restart firewall; then
                systemctl start sshd || { echo -e "\e[1;31mWARNING: sshd failed to start; check 'systemctl status sshd' for details.\e[0m"; }
            else
                echo -e "\e[1;31mWARNING: firewall failed to restart; sshd NOT started so port 22 never listens unprotected.\e[0m"
                echo -e "\e[1;31mCheck 'systemctl status firewall lighttpd', then 'systemctl start sshd' once the firewall is active.\e[0m"
            fi
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
            # Drop the port-22 rule (sshd.service removed above, so firewall.sh
            # rebuilds without it). Restart the service, not firewall.sh directly,
            # to stay fail-closed. This also cycles lighttpd through PartOf=.
            systemctl restart firewall || echo -e "\e[1;31mWARNING: firewall failed to restart; the web UI may be down. Check 'systemctl status firewall lighttpd'.\e[0m"
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
            /opt/bin/wget --timeout=30 --tries=2 -q -O /usrdata/quecdeck/script/lean_mode.sh "$GITROOT/quecdeck/script/lean_mode.sh" || { echo -e "\e[1;31mDownload failed.\e[0m"; return; }
            echo "1289206e9c115c3e20e66f5fb4ca92bb230a1be1a2ad06d1c23e0583d3995f42  /usrdata/quecdeck/script/lean_mode.sh" | sha256sum -c >/dev/null || { echo -e "\e[1;31mIntegrity check failed for lean_mode.sh.\e[0m"; rm -f /usrdata/quecdeck/script/lean_mode.sh; return; }
            echo -e "\e[1;32mIntegrity verified: lean_mode.sh\e[0m"
            /opt/bin/wget --timeout=30 --tries=2 -q -O /usrdata/quecdeck/systemd/lean-mode.service "$GITROOT/quecdeck/systemd/lean-mode.service" || { echo -e "\e[1;31mDownload failed.\e[0m"; return; }
            echo "e4700f2d27ef2fceaa80e8519bfd46cdae6c3fc09583ef0c781d573518108bd8  /usrdata/quecdeck/systemd/lean-mode.service" | sha256sum -c >/dev/null || { echo -e "\e[1;31mIntegrity check failed for lean-mode.service.\e[0m"; rm -f /usrdata/quecdeck/systemd/lean-mode.service; return; }
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
    rm -f /usrdata/quecdeck/var/watchcat_reboot_state.json
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
    echo -e "\e[93m1) Install/Update QuecDeck (latest release)\e[0m"
    echo -e "\e[93m2) Install/Update QuecDeck (main branch)\e[0m"
    echo -e "\e[93m3) SSH server (install/uninstall)\e[0m"
    echo -e "\e[33m4) Lean Mode (install/uninstall) [EXPERIMENTAL]\e[0m"
    echo -e "\e[91m5) Disable monitoring services (Watchcat & Scheduled Restart)\e[0m"
    echo -e "\e[91m6) Uninstall QuecDeck\e[0m"
    echo -e "\e[91m7) Uninstall Entware/OPKG\e[0m"
    echo -e "\e[95m8) Set QuecDeck (admin) password\e[0m"
    echo -e "\e[95m9) Set Developer access (devadmin) password\e[0m"
    echo -e "\e[94m10) Set Console/ttyd (root) password\e[0m"
    echo -e "\e[91m11) Reboot\e[0m"
    echo -e "\e[93m12) Exit\e[0m"
    read -p "Enter your choice: " choice

    case $choice in
        1)
            install_quecdeck_release
            echo ""
            read -p "Press Enter to return to menu..."
            ;;
        2)
            install_quecdeck
            echo ""
            read -p "Press Enter to return to menu..."
            ;;
        3)
            sshd_service
            ;;
        4)
            lean_mode_service
            ;;
        5)
            echo -e "\e[1;31mThis will disable Watchcat and Scheduled Restart.\e[0m"
            read -p "Are you sure? (y/n): " confirm
            case "$confirm" in
                y|Y) disable_monitoring_services ;;
                *) echo -e "\e[1;33mCancelled.\e[0m" ;;
            esac
            ;;
        6)
            uninstall_quecdeck_components
            ;;
        7)
            if [ -d "$QUECDECK_DIR/www" ]; then
                echo -e "\e[1;31mWARNING: QuecDeck is still installed.\e[0m"
                echo -e "\e[1;31mUninstalling Entware will break QuecDeck and all its services.\e[0m"
                echo -e "\e[1;31mRun option 6 to uninstall QuecDeck first.\e[0m"
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
        8)
            read -p "Set QuecDeck (admin) password? (y/n): " pw_confirm
            case "$pw_confirm" in
                y|Y) set_adminpasswd ;;
                *) echo -e "\e[1;33mCancelled.\e[0m" ;;
            esac
            ;;
        9)
            read -p "Set Developer access (devadmin) password? (y/n): " pw_confirm
            case "$pw_confirm" in
                y|Y) set_devpasswd ;;
                *) echo -e "\e[1;33mCancelled.\e[0m" ;;
            esac
            ;;
        10)
            read -p "Set Console/ttyd (root) password? (y/n): " pw_confirm
            case "$pw_confirm" in
                y|Y) set_root_passwd ;;
                *) echo -e "\e[1;33mCancelled.\e[0m" ;;
            esac
            ;;
        11)
            read -p "Reboot the modem? (y/n): " reboot_confirm
            case "$reboot_confirm" in
                y|Y)
                    reboot
                    for i in 5 4 3 2 1; do
                        printf "\rDisconnecting in %d second%s... " "$i" "$([ "$i" -eq 1 ] && echo '' || echo 's')"
                        sleep 1
                    done
                    echo "" ;;
                *) echo -e "\e[1;33mReboot cancelled.\e[0m" ;;
            esac
            ;;
        12)
            echo -e "\e[1;32mGoodbye!\e[0m"
            break
            ;;
        *)
            echo -e "\e[1;31mInvalid option\e[0m"
            ;;
    esac
done
